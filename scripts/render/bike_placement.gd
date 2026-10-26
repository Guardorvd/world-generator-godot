extends Node3D
## Y: локальный предпросмотр единственного велосипеда. До подтверждения состояние не меняется.
const MIN_DISTANCE := 1.8
const MAX_DISTANCE := 5.0
const ROTATE_SPEED := 1.8
var active := false
var valid := false
var reason := ""
var candidate := {}
var heading := 0.0
var distance := MAX_DISTANCE
var _distance_override := false
var _world: WorldData
var _heights: Heightfield
var _origin := Vector3.ZERO
var _ghost: Node3D
var _material := StandardMaterial3D.new()

func begin(w: WorldData, h: Heightfield, origin: Vector3, yaw: float) -> void:
	_world = w
	_heights = h
	_origin = origin
	# Боком к взгляду модель читается сразу; направление пользователь затем выбирает сам.
	heading = wrapf(yaw + PI * 0.5, -PI, PI)
	distance = MAX_DISTANCE
	_distance_override = false
	if not is_instance_valid(_ghost):
		_ghost = load("res://scenes/bike.tscn").instantiate()
		_ghost.set_script(null)
		_ghost.get_node("Rider").free()
		_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		add_child(_ghost)
		_tint(_ghost)
	active = true
	visible = true
	valid = false
	candidate = {}

func _tint(node: Node) -> void:
	if node is MeshInstance3D:
		node.material_override = _material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_tint(child)

func cancel() -> void:
	active = false
	visible = false
	valid = false
	candidate = {}

func rotate_by(angle: float) -> void:
	heading = wrapf(heading + angle, -PI, PI)

func adjust_distance(amount: float) -> void:
	distance = clampf(distance + amount, MIN_DISTANCE, MAX_DISTANCE)
	_distance_override = true

func update_preview(ray_from: Vector3, ray_dir: Vector3, yaw: float) -> void:
	if not active:
		return
	var target := Vector2(_origin.x, _origin.z) + Vector2(-sin(yaw), -cos(yaw)) * distance
	# Луч по текущему уровню поверхности: под мостом не выбираем верх настила сквозь перекрытие.
	for i in range(1, 81):
		var p := ray_from + ray_dir * (i * 0.2)
		if p.y <= _heights.surface_at(p.x, p.z, _origin.y + 0.4):
			target = Vector2(p.x, p.z)
			break
	var delta := target - Vector2(_origin.x, _origin.z)
	if delta.length() < 0.01:
		delta = Vector2(-sin(yaw), -cos(yaw))
	if not _distance_override:
		distance = clampf(delta.length(), MIN_DISTANCE, MAX_DISTANCE)
	target = Vector2(_origin.x, _origin.z) + delta.normalized() * distance
	var y := _heights.surface_at(target.x, target.y, _origin.y + 0.4)
	candidate = {position = Vector3(target.x, y, target.y), heading = heading}
	valid = validate(candidate.position)
	_ghost.position = candidate.position
	var front := Vector2(-sin(heading), -cos(heading)) * BikeRide.HUB
	var grade := (_heights.surface_at(target.x + front.x, target.y + front.y, y) - _heights.surface_at(target.x - front.x, target.y - front.y, y)) / (2 * BikeRide.HUB)
	_ghost.rotation = Vector3(atan(grade), heading, 0)
	_material.albedo_color = Color(0.12, 0.85, 0.42, 0.65) if valid else Color(1.0, 0.15, 0.08, 0.65)

func validate(at: Vector3) -> bool:
	reason = "Здесь нельзя поставить велосипед"
	if not at.is_finite() or Vector2(at.x - _origin.x, at.z - _origin.z).length() > MAX_DISTANCE + 0.01:
		return false
	if absf(at.y - _origin.y) > 1.8 or BikeRecovery.placement(_world, _heights, at, heading, null, true).is_empty():
		reason = "Нужны свободная сухая опора и место для посадки"
		return false
	# Велосипед можно достать из застрявшего положения, но нельзя поставить сквозь стену.
	var eye := _origin + Vector3.UP * 1.2
	var top := at + Vector3.UP * 0.8
	var steps := maxi(1, ceili(eye.distance_to(top) / 0.15))
	for i in range(1, steps + 1):
		var p := eye.lerp(top, float(i) / steps)
		if p.y < _heights.surface_at(p.x, p.z, _origin.y + 0.4) + 0.1 or not PlayerState.is_passable(_world, _heights, p.x, p.z, p.y - 0.4, 0.12, true):
			reason = "Место закрыто препятствием"
			return false
	reason = "Поставить велосипед"
	return true

func confirm(bike: BikeRide) -> bool:
	# Повторная проверка в момент клика: препятствия/доступность могли обновиться после кадра.
	if not active or candidate.is_empty() or not validate(candidate.position):
		valid = false
		return false
	bike.reset_motion()
	bike.fallen = false
	bike.fallen_transform = Transform3D.IDENTITY
	bike.x = candidate.position.x
	bike.y = candidate.position.y
	bike.z = candidate.position.z
	bike.heading = heading
	bike.tilt = 0.0
	cancel()
	return true
