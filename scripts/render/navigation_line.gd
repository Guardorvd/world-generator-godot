extends MeshInstance3D
## Короткий спокойный пунктир на дороге. Перестройка геометрии 4 раза/с, поиск — только по событию.
## 14.3: штрихи стоят на месте маршрута — фаза считается от начала пути (_cum), а не от ближайшей
## к игроку точки, поэтому при перестройке они не скачут. Сечение штриха — пологая арка: середина чуть выше
## и ярче (сердечник), края гаснут, полоска выглядит объёмной и мягкой.
const Roads = preload("res://scripts/game/road_navigation.gd")
const REACH := 70.0
const PIECE := 0.75     # длина кусочка штриха, м; штрих — DASH кусочков, пауза — столько же
const DASH := 2
const HALF := 0.14      # полуширина, м
const ARCH := 0.03      # насколько середина выше краёв, м
const CORE := Color(1.0, 0.88, 0.55)
const EDGE := Color(0.95, 0.72, 0.3)
var roads: Roads
var path := PackedVector2Array()
var _cum := PackedFloat32Array() # длина маршрута от начала до каждой точки, м
var _world: WorldData
var _heights: Heightfield
var _goal := {}
var _finish := -1
var _last_start := -1
var _timer := 0.0
var _reroute_timer := 0.0


func setup(w: WorldData, h: Heightfield) -> void:
	_world = w
	_heights = h
	mesh = ImmediateMesh.new()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = material


func set_goal(goal: Dictionary, at: Vector2) -> void:
	_goal = goal
	path.clear()
	(mesh as ImmediateMesh).clear_surfaces()
	_last_start = -1
	if goal.is_empty():
		return
	if roads == null:
		roads = Roads.new()
		roads.build(_world)
	var target := Vector2(goal.x, goal.y) * GameConfig.TILE
	if goal.kind == "lake":
		target = Vector2(goal.src.sx, goal.src.sy) * GameConfig.TILE
	_finish = roads.nearest(target)
	_rebuild(at)


func _rebuild(at: Vector2) -> void:
	var start := roads.nearest(at)
	if start != _last_start:
		_last_start = start
		path = roads.route(start, _finish)
		_cum.resize(path.size())
		var total := 0.0
		for i in path.size():
			if i > 0:
				total += path[i - 1].distance_to(path[i])
			_cum[i] = total
	_reroute_timer = 2.0
	_timer = 0.0


func update_line(at: Vector3, dt: float, shown: bool) -> void:
	visible = shown and not _goal.is_empty()
	if not visible:
		return
	_timer -= dt
	_reroute_timer -= dt
	if _timer > 0.0:
		return
	_timer = 0.25
	var here := Vector2(at.x, at.z)
	var segment := -1
	var nearest := Vector2.ZERO
	var distance := INF
	for i in range(1, path.size()):
		var p := Geometry2D.get_closest_point_to_segment(here, path[i - 1], path[i])
		var d := here.distance_to(p)
		if d < distance:
			distance = d
			segment = i
			nearest = p
	if distance > 24.0 and _reroute_timer <= 0.0:
		_rebuild(here)
		return
	var line := mesh as ImmediateMesh
	line.clear_surfaces()
	if segment == -1 or distance > REACH:
		return
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var start: float = _cum[segment - 1] + path[segment - 1].distance_to(nearest)
	var ground := at.y + 2.0
	for i in range(segment, path.size()):
		var a0 := path[i - 1]
		var length: float = _cum[i] - _cum[i - 1]
		if length <= 0.0:
			continue
		var direction := a0.direction_to(path[i])
		var side := Vector2(-direction.y, direction.x) * HALF
		# кусочки по сетке PIECE от начала маршрута: от ближайшей точки до конца отрезка
		var k := floori(maxf(start, _cum[i - 1]) / PIECE)
		while k * PIECE < _cum[i] and k * PIECE - start < REACH:
			var s0 := maxf(k * PIECE, maxf(start, _cum[i - 1]))
			var s1 := minf((k + 1) * PIECE, _cum[i])
			if posmod(k, DASH * 2) < DASH and s1 > s0:
				var pa := a0 + direction * (s0 - _cum[i - 1])
				var pb := a0 + direction * (s1 - _cum[i - 1])
				var fade := (1.0 - smoothstep(50.0, REACH, s0 - start)) * smoothstep(1.0, 4.0, here.distance_to((pa + pb) * 0.5))
				if fade > 0.01:
					_piece(vertices, colors, pa, pb, side, ground, fade)
			k += 1
		if _cum[i] - start >= REACH:
			break
	if vertices.is_empty():
		return
	line.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in vertices.size():
		line.surface_set_color(colors[i])
		line.surface_add_vertex(vertices[i])
	line.surface_end()


## Кусочек штриха от pa до pb: две половины арки, края на земле и прозрачные, середина выше и ярче
func _piece(vertices: PackedVector3Array, colors: PackedColorArray, pa: Vector2, pb: Vector2, side: Vector2, ground: float, fade: float) -> void:
	var lift := func(p: Vector2, up: float) -> Vector3:
		return Vector3(p.x, _heights.surface_at(p.x, p.y, ground) + 0.10 + up, p.y)
	var al: Vector3 = lift.call(pa - side, 0.0)
	var ac: Vector3 = lift.call(pa, ARCH)
	var ar: Vector3 = lift.call(pa + side, 0.0)
	var bl: Vector3 = lift.call(pb - side, 0.0)
	var bc: Vector3 = lift.call(pb, ARCH)
	var br: Vector3 = lift.call(pb + side, 0.0)
	var edge := Color(EDGE, fade * 0.12)
	var core := Color(CORE, fade * 0.62)
	for v: Array in [[al, edge], [ac, core], [bc, core], [al, edge], [bc, core], [bl, edge],
			[ac, core], [ar, edge], [br, edge], [ac, core], [br, edge], [bc, core]]:
		vertices.append(v[0])
		colors.append(v[1])
