extends MeshInstance3D
## Пунктир готовых дорог и парящие стрелки проходимых подходов. Геометрия 4 раза/с,
## поиск по событию: цель, отклонение, новая территория или препятствие. Непроходимый путь
## не рисуется. Фаза штрихов привязана к дуге маршрута; красный цвет — движение против него.
const Roads = preload("res://scripts/game/road_navigation.gd")
const REACH := 70.0
const PIECE := 0.75     # длина кусочка штриха, м; штрих — DASH кусочков, пауза — столько же
const DASH := 2
const HALF := 0.14      # полуширина штриха, м
const ARCH := 0.03      # насколько середина штриха выше краёв, м
const STEP := 7.0       # шаг стрелок вне дороги, м
const HOVER := 1.2      # высота середины стрелки над опорой, м
const ARM := 1.15       # длина стрелки в её плоскости, м
const WING := 0.62      # полуширина стрелки, м
const BAND := 0.16      # ширина полосы крыла, м
const TILT := 0.96      # наклон плоскости стрелки к земле, рад: остриё выше вылетов
const FLOW := 3.0       # скорость обратного хода штрихов при движении не туда, м/с
const CORE := Color(1.0, 0.88, 0.55)
const EDGE := Color(0.95, 0.72, 0.3)
const WARN := Color(1.0, 0.3, 0.18)
const WARN_EDGE := Color(0.9, 0.14, 0.08)
var roads: Roads
var path := PackedVector2Array()
var _cum := PackedFloat32Array() # длина маршрута от начала до каждой точки, м
var _world: WorldData
var _heights: Heightfield
var _goal := {}
var _target := Vector2.ZERO
var _road_first := 0 # границы дорожной части пути в _cum
var _road_last := -1
var _last_here := Vector2.ZERO
var _wrong := 0.0   # 1 — движение против маршрута; плавно гаснет
var _flow := 0.0    # сдвиг штрихов навстречу при движении не туда, м
var _timer := 0.0
var _reroute_timer := 0.0
var status := ""
var _revision := ""
var _progress := 0.0

func _network_revision() -> String:
	var outer := _world.outer.get_ledger() if _world.outer != null else {}
	return str([_world.territory_revision, _world.trails.size(), outer.get("trails", []).size(), outer.get("regions", {}).keys().hash()])


func setup(w: WorldData, h: Heightfield) -> void:
	_world = w
	_heights = h
	roads = null
	_revision = ""
	_goal = {}
	path.clear()
	status = ""
	mesh = ImmediateMesh.new()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = material


func set_goal(goal: Dictionary, at: Vector2, feet := INF) -> void:
	_goal = goal
	path.clear()
	(mesh as ImmediateMesh).clear_surfaces()
	_wrong = 0.0
	_flow = 0.0
	_last_here = at
	_progress = 0.0
	status = ""
	_reroute_timer = 0.0
	if goal.is_empty():
		return
	if roads == null:
		roads = Roads.new()
	if _revision != _network_revision():
		roads.build(_world, _heights)
		_revision = _network_revision()
	_target = Vector2(goal.x, goal.y) * GameConfig.TILE
	if goal.kind == "lake":
		_target = Vector2(goal.src.sx, goal.src.sy) * GameConfig.TILE
	_rebuild(at, feet)


func _rebuild(at: Vector2, feet := INF) -> void:
	path = roads.route_to(at, _target, feet)
	status = roads.status
	(mesh as ImmediateMesh).clear_surfaces()
	_progress = 0.0
	_wrong = 0.0
	_flow = 0.0
	_road_first = roads.road_first
	_road_last = roads.road_last
	_last_here = at
	_cum.resize(path.size())
	var total := 0.0
	for i in path.size():
		if i > 0:
			total += path[i - 1].distance_to(path[i])
		_cum[i] = total
	_reroute_timer = 8.0 if path.is_empty() else 2.0
	_timer = 0.0


func update_line(at: Vector3, dt: float, shown: bool) -> void:
	visible = shown and not _goal.is_empty()
	if not visible:
		_last_here = Vector2(at.x, at.z)
		_wrong = 0.0
		return
	_timer -= dt
	_reroute_timer -= dt
	_wrong = maxf(_wrong - dt * 3.0, 0.0)
	if _wrong > 0.0:
		_flow = fmod(_flow + dt * FLOW * _wrong, PIECE * DASH * 2.0)
	if _timer > 0.0:
		return
	_timer = 0.125 if _wrong > 0.0 else 0.25 # при предупреждении штрихи бегут плавнее
	var here := Vector2(at.x, at.z)
	if _revision != _network_revision():
		roads.build(_world, _heights)
		_revision = _network_revision()
		_rebuild(here, at.y)
		return
	if path.is_empty():
		if _reroute_timer <= 0:
			roads.build(_world, _heights)
			_rebuild(here, at.y)
		return
	var segment := -1
	var nearest := Vector2.ZERO
	var distance := INF
	for i in range(1, path.size()):
		var p := Geometry2D.get_closest_point_to_segment(here, path[i - 1], path[i])
		var d := here.distance_to(p)
		var arc: float = _cum[i - 1] + path[i - 1].distance_to(p)
		# На самопересечении предпочитаем прежнюю ветвь, но телепорт/уход с пути может выбрать другую.
		var score := d + minf(absf(arc - _progress) * 0.025, 3.0)
		if score < distance:
			distance = score
			segment = i
			nearest = p
	if distance > 24.0 and _reroute_timer <= 0.0:
		_rebuild(here, at.y)
		return
	var line := mesh as ImmediateMesh
	line.clear_surfaces()
	if segment == -1 or distance > REACH:
		return
	var start: float = _cum[segment - 1] + path[segment - 1].distance_to(nearest)
	_progress = start
	# После перехода на последний участок ближайшая старая дорожная точка уже не должна тянуть назад.
	if _road_last >= 0 and segment > _road_last and _reroute_timer <= 0 and distance > 6.0:
		_rebuild(here, at.y)
		return
	_check_direction(here, nearest, start)
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var ground := at.y + 0.25
	for i in range(segment, path.size()):
		var a0 := path[i - 1]
		var base: float = _cum[i - 1]
		var length: float = _cum[i] - base
		if length <= 0.0:
			continue
		var direction := a0.direction_to(path[i])
		var c0 := maxf(start, base)
		var c1 := _cum[i]
		var next_ground := roads._segment(nearest if i == segment else a0, path[i], ground)
		if next_ground == INF:
			if _reroute_timer <= 0.0:
				roads.build(_world, _heights)
				_rebuild(here, at.y)
			return # не продолжаем рисовать сквозь обновившееся препятствие
		# короткий подход к дороге (до STEP) — тот же пунктир, чтобы не было стрелки под ногами
		var on_road := (i > _road_first and i <= _road_last) or (i == _road_first and length < STEP)
		var reference := maxf(ground, next_ground)
		if on_road:
			_dashes(vertices, colors, a0, direction, base, c0, c1, reference, start, here)
		else:
			_arrows(vertices, colors, a0, direction, base, c0, c1, reference, start, here)
		ground = next_ground
		if c1 - start >= REACH:
			break
	if vertices.is_empty():
		return
	line.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in vertices.size():
		line.surface_set_color(colors[i])
		line.surface_add_vertex(vertices[i])
	line.surface_end()

func can_arrive(at: Vector3) -> bool:
	if _goal.get("kind") != "marker": return true
	if not _heights.known(_target.x, _target.y): return false
	var target_y := _heights.surface_at(_target.x, _target.y, INF)
	return absf(target_y - at.y) < 1.5 and roads != null and roads._segment(Vector2(at.x, at.z), _target, at.y) < INF


## Штрихи на дороге: кусочки по сетке PIECE от начала маршрута; при предупреждении сетка едет назад
func _dashes(vertices: PackedVector3Array, colors: PackedColorArray, a0: Vector2, direction: Vector2,
		base: float, c0: float, c1: float, ground: float, start: float, here: Vector2) -> void:
	var side := Vector2(-direction.y, direction.x) * HALF
	var k := floori((c0 + _flow) / PIECE)
	while k * PIECE - _flow < c1 and k * PIECE - _flow - start < REACH:
		var s0 := maxf(k * PIECE - _flow, c0)
		var s1 := minf((k + 1) * PIECE - _flow, c1)
		if posmod(k, DASH * 2) < DASH and s1 > s0:
			_piece(vertices, colors, a0 + direction * (s0 - base), a0 + direction * (s1 - base), side, ground, s0 - start, here)
		k += 1


## Стрелки вне дороги: шаг STEP от начала маршрута, шаг общий с соседними отрезками — без пропусков
func _arrows(vertices: PackedVector3Array, colors: PackedColorArray, a0: Vector2, direction: Vector2,
		base: float, c0: float, c1: float, ground: float, start: float, here: Vector2) -> void:
	var k := floori(c0 / STEP)
	while (k + 0.5) * STEP < c1 and (k + 0.5) * STEP - start < REACH:
		var s := (k + 0.5) * STEP
		if s >= c0:
			_arrow(vertices, colors, a0 + direction * (s - base), direction, ground, s - start, here)
		k += 1


## Кусочек штриха от pa до pb: две половины арки, края на земле и прозрачные, середина выше и ярче
func _piece(vertices: PackedVector3Array, colors: PackedColorArray, pa: Vector2, pb: Vector2, side: Vector2,
		ground: float, along: float, here: Vector2) -> void:
	var fade := (1.0 - smoothstep(50.0, REACH, along)) * smoothstep(1.0, 4.0, here.distance_to((pa + pb) * 0.5))
	if fade <= 0.01:
		return
	var lift := func(p: Vector2, up: float) -> Vector3:
		return Vector3(p.x, _heights.surface_at(p.x, p.y, ground) + 0.10 + up, p.y)
	var al: Vector3 = lift.call(pa - side, 0.0)
	var ac: Vector3 = lift.call(pa, ARCH)
	var ar: Vector3 = lift.call(pa + side, 0.0)
	var bl: Vector3 = lift.call(pb - side, 0.0)
	var bc: Vector3 = lift.call(pb, ARCH)
	var br: Vector3 = lift.call(pb + side, 0.0)
	var edge := Color(EDGE.lerp(WARN_EDGE, _wrong), fade * (0.12 + 0.08 * _wrong))
	var core := Color(CORE.lerp(WARN, _wrong), fade * (0.62 + 0.28 * _wrong))
	for v: Array in [[al, edge], [ac, core], [bc, core], [al, edge], [bc, core], [bl, edge],
			[ac, core], [ar, edge], [br, edge], [ac, core], [br, edge], [bc, core]]:
		vertices.append(v[0])
		colors.append(v[1])


## Одна стрелка: плоскость наклонена к земле, остриё выше вылетов — с седла видно остриё вперёд.
## Две полосы от острия к вылетам; остриё ярче, вылеты гаснут
func _arrow(vertices: PackedVector3Array, colors: PackedColorArray, p: Vector2, dir: Vector2,
		ground: float, along: float, here: Vector2) -> void:
	var fade := (1.0 - smoothstep(50.0, REACH, along)) * smoothstep(2.0, 6.0, here.distance_to(p))
	if fade <= 0.01:
		return
	var base := Vector3(p.x, _heights.surface_at(p.x, p.y, ground) + HOVER, p.y)
	var ahead := Vector3(dir.x, 0.0, dir.y) * cos(TILT) + Vector3.UP * sin(TILT)
	var side := Vector3(-dir.y, 0.0, dir.x)
	var tip := base + ahead * (ARM * 0.5)
	var core := Color(CORE.lerp(WARN, _wrong), fade * (0.65 + 0.25 * _wrong))
	var edge := Color(EDGE.lerp(WARN_EDGE, _wrong), fade * 0.06)
	for w: float in [-1.0, 1.0]:
		var wing := base - ahead * (ARM * 0.5) + side * (WING * w)
		var band := (ahead * (-WING * w) + side * (-ARM)).normalized() * (BAND * 0.5)
		for v: Array in [[tip - band, core], [tip + band, core], [wing + band, edge],
				[tip - band, core], [wing + band, edge], [wing - band, edge]]:
			vertices.append(v[0])
			colors.append(v[1])


## Движение против маршрута: направление пути берём сразу за ближайшей точкой, чтобы развилка
## дороги не путала; шаг меньше 0,3 м направлением не считается
func _check_direction(here: Vector2, nearest: Vector2, start: float) -> void:
	var step := here - _last_here
	_last_here = here
	if step.length_squared() < 0.09:
		return
	var dir := nearest.direction_to(_ahead(start, 1.5))
	if dir.is_zero_approx():
		return
	if step.dot(dir) < -0.3 * step.length():
		_wrong = 1.0


## Точка маршрута через dist метров вперёд от дуги s
func _ahead(s: float, dist: float) -> Vector2:
	var target := s + dist
	for i in range(1, path.size()):
		if _cum[i] >= target:
			var span: float = _cum[i] - _cum[i - 1]
			var t := 0.0 if span <= 0.0 else (target - _cum[i - 1]) / span
			return path[i - 1].lerp(path[i], t)
	return path[path.size() - 1]
