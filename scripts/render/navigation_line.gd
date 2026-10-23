extends MeshInstance3D
## Короткий спокойный пунктир на дороге. Перестройка геометрии 4 раза/с, поиск — только по событию.
const Roads = preload("res://scripts/game/road_navigation.gd")
const REACH := 70.0
var roads: Roads
var path := PackedVector2Array()
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
	var travelled := 0.0
	var from := nearest
	for i in range(segment, path.size()):
		var to := path[i]
		var length := from.distance_to(to)
		var direction := from.direction_to(to)
		var side := Vector2(-direction.y, direction.x) * 0.11
		var along := 0.0
		while along < length and travelled + along < REACH:
			var end := minf(along + 0.75, length)
			var middle := from + direction * ((along + end) * 0.5)
			var fade := (1.0 - smoothstep(50.0, REACH, travelled + along)) * smoothstep(1.0, 4.0, here.distance_to(middle))
			if fposmod(travelled + along, 3.0) < 1.4 and fade > 0.01:
				var a := from + direction * along
				var b := from + direction * end
				var corners: Array[Vector2] = [a - side, a + side, b + side, a - side, b + side, b - side]
				for p: Vector2 in corners:
					vertices.append(Vector3(p.x, _heights.surface_at(p.x, p.y, at.y + 2.0) + 0.10, p.y))
					colors.append(Color(0.95, 0.77, 0.35, fade * 0.48))
			along += 0.75
		travelled += length
		from = to
		if travelled >= REACH:
			break
	if vertices.is_empty():
		return
	line.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in vertices.size():
		line.surface_set_color(colors[i])
		line.surface_add_vertex(vertices[i])
	line.surface_end()
