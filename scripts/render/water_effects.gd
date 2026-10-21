class_name WaterEffects
extends Node3D
## Короткий след на существующей поверхности и фиксированный пул капель.
## Никакой симуляции жидкости: глубину и уровень берём из игрового Heightfield.

const RINGS := 16
const DROPS := 64
const LIFETIME := 1.6

var rings := PackedVector4Array()
var levels := PackedFloat32Array()
var _currents := PackedVector2Array()
var _materials: Array[ShaderMaterial] = []
var _ring := 0
var _drop := 0
var _wait := 0.0
var _wet := [false, false]
var _positions := PackedVector3Array()
var _velocities := PackedVector3Array()
var _life := PackedFloat32Array()
var _water_y := PackedFloat32Array()
var _spray: MultiMeshInstance3D


func setup(water: Node3D) -> void:
	rings.resize(RINGS)
	levels.resize(RINGS)
	_currents.resize(RINGS)
	for node: MeshInstance3D in water.get_children():
		var mat := node.mesh.surface_get_material(0) as ShaderMaterial
		if mat != null:
			_materials.append(mat)
	var mesh := SphereMesh.new()
	mesh.radius = 0.022
	mesh.height = 0.044
	mesh.radial_segments = 4
	mesh.rings = 2
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.65, 0.82, 0.80)
	material.roughness = 0.25
	mesh.material = material
	_spray = MultiMeshInstance3D.new()
	_spray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spray.multimesh = MultiMesh.new()
	_spray.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_spray.multimesh.mesh = mesh
	_spray.multimesh.instance_count = DROPS
	add_child(_spray)
	_positions.resize(DROPS)
	_velocities.resize(DROPS)
	_life.resize(DROPS)
	_water_y.resize(DROPS)
	clear()


func clear() -> void:
	rings.fill(Vector4(0, 0, LIFETIME, 0))
	_life.fill(0.0)
	_wet = [false, false]
	_wait = 0.0
	for i in DROPS:
		_spray.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3.ZERO))
	_upload()


func tick(dt: float, p: PlayerState, b: BikeRide, previous: Vector3, h: Heightfield) -> void:
	for i in RINGS:
		rings[i].z += dt
		if rings[i].z < LIFETIME and _currents[i] != Vector2.ZERO:
			rings[i].x += _currents[i].x * dt
			rings[i].y += _currents[i].y * dt
			var depth := h.depth_at(rings[i].x, rings[i].y)
			if depth <= 0.025:
				rings[i].w = 0.0
			else:
				levels[i] = h.ground_at(rings[i].x, rings[i].y) + depth
	for i in DROPS:
		if _life[i] <= 0.0:
			continue
		_life[i] = maxf(0.0, _life[i] - dt)
		_velocities[i].y -= 9.8 * dt
		_positions[i] += _velocities[i] * dt
		if _positions[i].y < _water_y[i]:
			_life[i] = 0.0
		var size := minf(1.0, _life[i] * 6.0)
		_spray.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * size), _positions[i]))
	_wait -= dt
	var pos := Vector3(p.x, p.feet, p.z)
	var velocity := (pos - previous) / maxf(dt, 0.0001)
	# Переносы с карты и посадка не оставляют длинный след.
	if pos.distance_to(previous) > 2.0:
		clear()
		return
	var pace := Vector2(velocity.x, velocity.z).length()
	var emit := _wait <= 0.0 and pace > 0.15
	var forward := Vector3(-sin(b.heading), 0, -cos(b.heading))
	for i in (2 if b.riding else 1):
		var contact := pos
		if b.riding:
			var offset := BikeRide.AXLE * (1.0 if i == 0 else -1.0)
			contact += forward * offset
			contact.y += sin(b.tilt) * offset
		var depth := h.depth_at(contact.x, contact.z, contact.y)
		var level := h.ground_at(contact.x, contact.z) + depth
		var wet := depth > 0.025 and contact.y < level + 0.015
		if wet and (emit or not _wet[i]):
			var power := clampf(pace * 0.10 + maxf(0, -velocity.y) * 0.12, 0.15, 1.0)
			power *= smoothstep(0.025, 0.25, depth)
			_emit(Vector3(contact.x, level, contact.z), velocity, power, h.current_at(contact.x, contact.z))
		_wet[i] = wet
	if emit:
		_wait = 0.20 if b.riding else 0.32
	_upload()


func _emit(pos: Vector3, velocity: Vector3, power: float, current := Vector2.ZERO) -> void:
	rings[_ring] = Vector4(pos.x, pos.z, 0.0, power)
	levels[_ring] = pos.y
	_currents[_ring] = current
	_ring = (_ring + 1) % RINGS
	for k in 5:
		_positions[_drop] = pos + Vector3(0, 0.035, 0)
		_water_y[_drop] = pos.y
		var angle := k * TAU / 5.0 + _ring * 1.7
		_velocities[_drop] = Vector3(cos(angle), 0, sin(angle)) * (0.3 + power)
		_velocities[_drop] += Vector3(velocity.x, 0, velocity.z) * 0.12
		_velocities[_drop].y = 0.65 + power * (0.7 + k * 0.16)
		_life[_drop] = 0.22 + power * 0.20
		_drop = (_drop + 1) % DROPS


func _upload() -> void:
	for material in _materials:
		material.set_shader_parameter("disturbances", rings)
		material.set_shader_parameter("disturbance_levels", levels)
