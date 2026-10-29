class_name BikeCrash
extends Node3D
## Падение: потеря равновесия → физические кости → подъём пешком у места остановки тела.
## BikeRide по-прежнему решает только, что седок упал (жёсткое приземление или удар в стену); здесь — как это выглядит.
## Физика движка нужна лишь на время падения: под местом падения ставится кусок рельефа (HeightMapShape3D),
## на скелет седока — PhysicalBone3D, велосипед становится RigidBody3D. После подъёма физика удаляется.
## Тела сталкиваются с землёй и ближайшими препятствиями леса, но не друг с другом и не с велосипедом.

const BALANCE := 0.22   # потеря равновесия: велосипед заваливается, седок ещё на нём, с
const LIE_MIN := 1.0    # тело лежит не меньше этого, с
const LIE_MAX := 2.4    # запасной срок для нестабильной позы у опоры, с
const RECOVER := 0.45   # пауза подъёма перед пешим управлением
const SETTLE := 0.2     # остановка должна держаться, а не быть одним тактом в верхней точке полёта
const GROUND_R := 16    # радиус куска рельефа под падением, м
const LAYER_GROUND := 4
const LAYER_BODY := 8
const GRAVITY_SCALE := GameConfig.GRAVITY / 9.8
const MAX_BONE_SPIN := 12.0 # рад/с: ограничение разгона лёгких конечностей решателем суставов
const RECOVERY_PENETRATION := 0.12 # м: мелкие контакты оставляем решателю, не поднимаем тело каждый такт
const EnvironmentContacts = preload("res://scripts/render/crash_environment.gd")
class FallBone extends PhysicalBone3D:
	func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
		# Ограничиваем физическое состояние, а не видимую позу скелета.
		state.angular_velocity = state.angular_velocity.limit_length(MAX_BONE_SPIN)

enum FallStyle { LANDING, OVER_BARS, SIDE_SLIDE, GLANCING }

enum BodyShape { SPHERE, CAPSULE, SHOE }
# Именованные параметры: размеры в метрах, масса в кг, пределы суставов в градусах.
const BODIES := {
	"Hips": {shape = BodyShape.SPHERE, radius = 0.13, length = 0.0, offset = 0.0, mass = 12.0, swing = 0.0, twist = 0.0},
	"Spine": {shape = BodyShape.CAPSULE, radius = 0.14, length = 0.42, offset = 0.15, mass = 20.0, swing = 30.0, twist = 20.0},
	"Head": {shape = BodyShape.CAPSULE, radius = 0.145, length = 0.38, offset = 0.035, mass = 5.0, swing = 40.0, twist = 30.0},
	"UpperArmL": {shape = BodyShape.CAPSULE, radius = 0.06, length = 0.34, offset = 0.15, mass = 2.5, swing = 70.0, twist = 40.0},
	"UpperArmR": {shape = BodyShape.CAPSULE, radius = 0.06, length = 0.34, offset = 0.15, mass = 2.5, swing = 70.0, twist = 40.0},
	"ForearmL": {shape = BodyShape.CAPSULE, radius = 0.05, length = 0.32, offset = 0.15, mass = 1.5, swing = 50.0, twist = 10.0},
	"ForearmR": {shape = BodyShape.CAPSULE, radius = 0.05, length = 0.32, offset = 0.15, mass = 1.5, swing = 50.0, twist = 10.0},
	"HandL": {shape = BodyShape.SPHERE, radius = 0.06, length = 0.0, offset = 0.0, mass = 0.5, swing = 35.0, twist = 15.0},
	"HandR": {shape = BodyShape.SPHERE, radius = 0.06, length = 0.0, offset = 0.0, mass = 0.5, swing = 35.0, twist = 15.0},
	"UpperLegL": {shape = BodyShape.CAPSULE, radius = 0.08, length = 0.46, offset = 0.21, mass = 8.0, swing = 50.0, twist = 20.0},
	"UpperLegR": {shape = BodyShape.CAPSULE, radius = 0.08, length = 0.46, offset = 0.21, mass = 8.0, swing = 50.0, twist = 20.0},
	"LowerLegL": {shape = BodyShape.CAPSULE, radius = 0.06, length = 0.44, offset = 0.21, mass = 4.0, swing = 50.0, twist = 10.0},
	"LowerLegR": {shape = BodyShape.CAPSULE, radius = 0.06, length = 0.44, offset = 0.21, mass = 4.0, swing = 50.0, twist = 10.0},
	"FootL": {shape = BodyShape.SHOE, radius = 0.0, length = 0.0, offset = 0.0, mass = 1.0, swing = 30.0, twist = 15.0},
	"FootR": {shape = BodyShape.SHOE, radius = 0.0, length = 0.0, offset = 0.0, mass = 1.0, swing = 30.0, twist = 15.0},
}

enum Phase { NONE, BALANCE, RAGDOLL, RECOVER }

var phase := Phase.NONE
var t := 0.0
var _view: BikeView
var _rider: CyclistRig
var _rider_local := Transform3D()   # место седока в сцене велосипеда
var _vel := Vector3()               # скорость в момент падения, м/с
var _release_velocity := Vector3()  # оставшаяся инерция после контактов при заваливании
var _settled_time := 0.0
var _tumble := 0.0                 # удар вперёд или боковое падение, без случайных рывков
var _forward := 1.0
var _side := 1.0                    # куда заваливается велосипед: 1 — вправо
var _start := Transform3D()         # велосипед в момент падения
var _ground: StaticBody3D
var _bike_body: RigidBody3D
var _sim: PhysicalBoneSimulator3D
var _bones: Dictionary[String, PhysicalBone3D] = {}         # имя кости → PhysicalBone3D
var _from_feet := Vector3()
var _recover_time := RECOVER
var standing_position := Vector3.ZERO # ноги после подъёма, независимо от велосипеда
var _seated_pose: Array[Transform3D] = []
var _procedural_pose := true
var _bone_order: Array[int] = []
var _animation_player: AnimationPlayer
var _animation_active := false
var style := FallStyle.LANDING
var _impact_normal := Vector3.UP
var _severity := 0.0
var _balance_time := BALANCE
var _recover_retry := 0.0


func active() -> bool:
	return phase != Phase.NONE


## Начать падение: velocity — скорость велосипеда до удара (BikeRide.crash_velocity)
func start(view: BikeView, b: BikeRide, velocity: Vector3, heights: Heightfield) -> void:
	abort()
	if not is_instance_valid(view) or not is_instance_valid(view.rider) or not view.rider.is_rig_valid():
		return
	if not velocity.is_finite():
		return
	for bone_name: String in BODIES:
		if view.rider.skeleton.find_bone(bone_name) < 0:
			push_warning("BikeCrash: отсутствует физическая кость %s" % bone_name)
			return
	_view = view
	_rider = view.rider
	_rider_local = _rider.transform
	_procedural_pose = _rider.procedural_pose
	_seated_pose = _rider.capture_pose()
	_rider.procedural_pose = false
	_animation_player = _rider.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if is_instance_valid(_animation_player):
		_animation_active = _animation_player.active
		_animation_player.active = false
	# Дополнительные кости могут иметь произвольные индексы: родители всегда первыми.
	_bone_order.clear()
	for root_bone in _rider.skeleton.get_parentless_bones():
		_bone_order.append(root_bone)
	var cursor := 0
	while cursor < _bone_order.size():
		for child in _rider.skeleton.get_bone_children(_bone_order[cursor]):
			_bone_order.append(child)
		cursor += 1
	_vel = velocity
	_release_velocity = velocity
	_settled_time = 0.0
	_recover_retry = 0.0
	_side = signf(b.lean) if absf(b.lean) > 0.02 else (signf(b.steer) if absf(b.steer) > 0.05 else 1.0)
	_tumble = smoothstep(2.0, 10.0, Vector2(velocity.x, velocity.z).length()) * (1.0 - clampf(absf(b.lean) / 0.4, 0.0, 0.6))
	_start = view.global_transform
	_impact_normal = b.crash_normal.normalized()
	var collision := b.crash_cause == BikeRide.CrashCause.COLLISION
	var normal_speed := maxf(0.0, -velocity.dot(_impact_normal))
	_severity = clampf((normal_speed if collision else absf(velocity.y)) / 18.0, 0.0, 1.0)
	if collision:
		var approach := normal_speed / maxf(velocity.length(), 0.01)
		style = FallStyle.OVER_BARS if approach > 0.7 else FallStyle.GLANCING
		_tumble *= approach
		var away := _impact_normal.dot(_start.basis.x)
		if absf(away) > 0.15:
			_side = signf(away)
	else:
		style = FallStyle.SIDE_SLIDE if absf(b.lean) > 0.15 else FallStyle.LANDING
	if b.crash_cause == BikeRide.CrashCause.BRAKING or b.crash_cause == BikeRide.CrashCause.OBSTACLE:
		style = FallStyle.OVER_BARS
		_tumble = 1.0
		_severity = smoothstep(6.0, 20.0, velocity.length())
	_balance_time = lerpf(0.22, 0.14, _severity) if collision else BALANCE
	_forward = -1.0 if velocity.dot(-_start.basis.z) < -0.1 else 1.0
	_build_ground(Vector3(b.x, b.y, b.z) + Vector3(velocity.x, 0.0, velocity.z) * 0.35, b.y, heights)
	phase = Phase.BALANCE
	t = 0.0


## Такт физики игры. true: подъём закончен, можно вернуть пешее управление.
func tick(dt: float, b: BikeRide, w: WorldData, heights: Heightfield) -> bool:
	if not active():
		return false
	if not is_instance_valid(_view) or not is_instance_valid(_rider):
		_finish()
		return true
	if not is_finite(dt) or dt <= 0.0:
		return false
	t += dt
	match phase:
		Phase.BALANCE:
			# велосипед уходит из-под седока: катится по инерции и валится набок, нос клюёт вниз
			var k := clampf(t / _balance_time, 0.0, 1.0)
			var fwd := -_start.basis.z
			var roll := Basis(fwd, -_side * 0.7 * k * k) * Basis(_start.basis.x, -0.25 * _tumble * _forward * k * k)
			var travel := Vector3(_vel.x, 0.0, _vel.z) * t * (1.0 - 0.3 * k)
			var before := _view.global_position
			var prev_t := maxf(0.0, t - dt)
			var prev_k := clampf(prev_t / _balance_time, 0.0, 1.0)
			var prev_travel := Vector3(_vel.x, 0.0, _vel.z) * prev_t * (1.0 - 0.3 * prev_k)
			var delta := travel - prev_travel
			var free := func(px: float, pz: float) -> bool: return b.fits(px, pz, b.heading, w, heights)
			var around := Callable()
			if heights.obstacles != null:
				around = func(px: float, pz: float) -> Vector2: return b.obstacle_normal(px, pz, b.heading, heights)
			var to := PlayerState.slide(free, before.x, before.z, delta.x, delta.z, around)
			var at := Vector3(to[0], _start.origin.y, to[1])
			_release_velocity.x = (at.x - before.x) / maxf(dt, 0.001)
			_release_velocity.z = (at.z - before.z) / maxf(dt, 0.001)
			_view.global_transform = Transform3D(roll * _start.basis, at)
			if t >= _balance_time:
				_begin_ragdoll()
		Phase.RAGDOLL:
			var hips := _bones["Hips"] as PhysicalBone3D
			var ground_center := Vector2(_ground.global_position.x, _ground.global_position.z)
			if Vector2(hips.global_position.x, hips.global_position.z).distance_to(ground_center) > GROUND_R - 4:
				# Долгое падение не заканчивается из-за края временного коллайдера земли.
				_build_ground(hips.global_position, hips.global_position.y, heights)
			_keep_above_ground(heights, dt)
			_view.global_transform = _bike_body.global_transform
			_sync_pose()
			var near_ground := hips.global_position.y - _support_height(hips.global_position, heights) < 0.65
			var head := _bones["Head"] as PhysicalBone3D
			var lying := head.global_position.y - _support_height(head.global_position, heights) < 0.45
			var settled := near_ground and lying and hips.linear_velocity.length() < 0.8 and head.linear_velocity.length() < 0.8 and hips.angular_velocity.length() < 1.0 and _bike_body.linear_velocity.length() < 0.8
			_settled_time = _settled_time + dt if settled else 0.0
			if ((t >= LIE_MIN and _settled_time >= SETTLE) or (t >= LIE_MAX and near_ground)) and t >= _recover_retry:
				_begin_recover(b, w, heights)
		Phase.RECOVER:
			if t >= _recover_time:
				_finish()
				return true
	return false


## Поза рамы заморожена после физики; перелёта седока в седло больше нет.
func draw() -> void:
	pass


## Положение игрока для камеры, звука и подгрузки мира; после падения не привязано к раме.
func focus(b: BikeRide) -> Vector3:
	match phase:
		Phase.RAGDOLL:
			var hips := (_bones["Hips"] as PhysicalBone3D).global_position
			return Vector3(hips.x, hips.y - 0.5, hips.z)
		Phase.RECOVER:
			return _from_feet.lerp(standing_position, smoothstep(0.0, 1.0, t / _recover_time))
	return standing_position if b.fallen else (_view.global_position if is_instance_valid(_view) else Vector3(b.x, b.y, b.z))


## Прервать падение при переносе/выходе: вернуть модель владельцу и удалить физику.
func abort() -> void:
	if phase == Phase.NONE:
		return
	_finish()


func _begin_ragdoll() -> void:
	phase = Phase.RAGDOLL
	t = 0.0
	var view_at := _view.global_transform
	# седок отделяется от велосипеда и летит по инерции, чуть вверх и через руль
	_rider.reparent(self)
	_build_ragdoll()
	var fling := Vector3(_release_velocity.x * 0.7, maxf(_vel.y, -5.0) * 0.15 + 1.4, _release_velocity.z * 0.7)
	fling += view_at.basis.x * _side * (0.25 + _severity * 0.25)
	if style == FallStyle.OVER_BARS or style == FallStyle.GLANCING:
		# Не проталкиваем тело обратно в стену; касательная скорость сохраняется.
		var into := minf(fling.dot(_impact_normal), 0.0)
		fling -= _impact_normal * into
		fling += _impact_normal * (0.3 + _severity * 0.6)
	for bone: PhysicalBone3D in _bones.values():
		bone.linear_velocity = fling
		bone.angular_velocity = -view_at.basis.x * _forward * lerpf(0.6, 2.5, _tumble) + view_at.basis.z * _side * lerpf(2.2, 1.0, _tumble)
		if bone.bone_name.begins_with("Forearm"):
			bone.angular_velocity += view_at.basis.z * _side * 0.25
	_bike_body = RigidBody3D.new()
	_bike_body.collision_layer = LAYER_BODY
	_bike_body.collision_mask = LAYER_GROUND
	_bike_body.mass = 14.0
	_bike_body.gravity_scale = GRAVITY_SCALE
	_bike_body.angular_damp = 1.5
	_bike_body.linear_damp = 0.7
	_bike_body.continuous_cd = true
	_bike_body.physics_material_override = _material(0.4)
	_add_shape(_bike_body, _box(Vector3(0.12, 0.45, 1.2)), Transform3D(Basis(), Vector3(0, 0.62, 0)))
	for z: float in [-BikeRide.HUB, BikeRide.HUB]:
		var wheel := CylinderShape3D.new()
		wheel.radius = BikeView.WHEEL_Y
		wheel.height = 0.06
		_add_shape(_bike_body, wheel, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3(0, BikeView.WHEEL_Y, z)))
	add_child(_bike_body)
	_bike_body.global_transform = view_at
	_bike_body.linear_velocity = Vector3(_release_velocity.x * 0.6, 0.5, _release_velocity.z * 0.6) - view_at.basis.x * _side * 0.25
	_bike_body.angular_velocity = -view_at.basis.z * _side * 3.0


## PhysicalBone3D на костях из BODIES: тело — посередине кости, сустав — в её начале
func _build_ragdoll() -> void:
	var skel := _rider.skeleton
	# Freeze the release pose before adding a modifier or starting physics.
	var release: Dictionary[String, Transform3D] = {}
	for bone_name: String in BODIES:
		release[bone_name] = skel.global_transform * skel.get_bone_global_pose(skel.find_bone(bone_name))
	_sim = PhysicalBoneSimulator3D.new()
	skel.add_child(_sim)
	_bones.clear()
	for bone_name: String in BODIES:
		var spec: Dictionary = BODIES[bone_name]
		var bone := FallBone.new()
		bone.name = bone_name
		bone.bone_name = bone_name
		bone.collision_layer = LAYER_BODY
		bone.collision_mask = LAYER_GROUND
		bone.mass = spec.mass
		bone.friction = 0.45
		bone.gravity_scale = GRAVITY_SCALE
		bone.linear_damp = 0.7
		bone.angular_damp = 3.0
		bone.body_offset = Transform3D(Basis(), Vector3(0, spec.offset, 0))
		bone.joint_offset = Transform3D(Basis(), Vector3(0, -spec.offset, 0))
		var shape: Shape3D
		if spec.shape == BodyShape.SPHERE:
			shape = SphereShape3D.new()
			(shape as SphereShape3D).radius = spec.radius
		elif spec.shape == BodyShape.CAPSULE:
			shape = CapsuleShape3D.new()
			(shape as CapsuleShape3D).radius = spec.radius
			(shape as CapsuleShape3D).height = spec.length
		else:
			shape = _box(Vector3(0.14, 0.10, 0.25))
		var shape_at := Transform3D(Basis(), Vector3(0, -0.01, -0.035)) if spec.shape == BodyShape.SHOE else Transform3D()
		_add_shape(bone, shape, shape_at)
		_sim.add_child(bone)
		# тело сразу на месте кости (в начале кадра симулятор ещё не успел бы его поставить)
		bone.global_transform = release[bone_name] * bone.body_offset
		_bones[bone_name] = bone
	_sim.physical_bones_start_simulation()
	# Starting simulation resets bodies. Restore ALL bodies before creating joints:
	# the engine records the parent anchor from their current world transforms.
	for bone_name: String in _bones:
		var bone := _bones[bone_name]
		bone.global_transform = release[bone_name] * bone.body_offset
	for bone_name: String in _bones:
		var spec: Dictionary = BODIES[bone_name]
		if spec.swing > 0.0:
			var bone := _bones[bone_name]
			bone.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			bone.set("joint_constraints/swing_span", spec.swing)
			bone.set("joint_constraints/twist_span", spec.twist)
	# Позу переносим в _sync_pose сами: второй проход модификатора в кадре не должен её перезаписывать.
	_sim.active = false


func _begin_recover(b: BikeRide, w: WorldData, heights: Heightfield) -> void:
	var destination := _recovery_spot(b, w, heights)
	if destination.is_empty():
		_recover_retry = t + 0.25
		return
	phase = Phase.RECOVER
	t = 0.0
	var hips: Vector3 = (_bones["Hips"] as PhysicalBone3D).global_position
	_from_feet = Vector3(hips.x, hips.y - 0.5, hips.z)
	standing_position = destination.position
	_recover_time = maxf(RECOVER, _from_feet.distance_to(standing_position) / GameConfig.WALK)
	# Сохраняем раму до удаления временных физических тел.
	b.fallen_transform = _bike_body.global_transform
	b.x = b.fallen_transform.origin.x
	b.z = b.fallen_transform.origin.z
	b.y = heights.surface_at(b.x, b.z, b.fallen_transform.origin.y + 0.4)
	b.heading = destination.heading
	b.reset_motion()
	b.fallen = true
	_free_physics()
	_rider.reparent(_view, false)
	_rider.transform = _rider_local
	_rider.restore_pose(_seated_pose)
	_view.snap(b)
	_view.draw(1.0)
	_rider.visible = false


## Видимая модель следует телам и в такте физики, включая кости без PhysicalBone у родителей.
func _sync_pose() -> Array[Transform3D]:
	var skel := _rider.skeleton
	var globals: Array[Transform3D] = []
	globals.resize(skel.get_bone_count())
	for i in _bone_order:
		var local := skel.get_bone_pose(i)
		var parent := skel.get_bone_parent(i)
		var global := (globals[parent] as Transform3D) * local if parent >= 0 else local
		var bone := _bones.get(skel.get_bone_name(i)) as PhysicalBone3D
		if bone != null:
			global = skel.global_transform.affine_inverse() * bone.global_transform * bone.body_offset.affine_inverse()
			local = (globals[parent] as Transform3D).affine_inverse() * global if parent >= 0 else global
		globals[i] = global
		skel.set_bone_pose_position(i, local.origin)
		skel.set_bone_pose_rotation(i, local.basis.get_rotation_quaternion())
	# Жёсткие low-poly детали на BoneAttachment должны обновиться в том же такте, что и кости.
	for child: Node in skel.get_children():
		if child is BoneAttachment3D:
			var index := skel.find_bone((child as BoneAttachment3D).bone_name)
			if index >= 0:
				(child as BoneAttachment3D).transform = globals[index]
	return globals


## Страховка редкого пропуска контакта тонкой конечностью или рывка сустава.
## Обычное скольжение решает физика; здесь убираем только проникновение под поверхность.
func _keep_above_ground(heights: Heightfield, dt: float) -> void:
	var body_lift := 0.0
	for bone: PhysicalBone3D in _bones.values():
		var col := bone.get_child(0) as CollisionShape3D
		var at := bone.global_transform * col.transform
		var extent := 0.0
		if col.shape is SphereShape3D:
			extent = (col.shape as SphereShape3D).radius
		elif col.shape is CapsuleShape3D:
			var capsule := col.shape as CapsuleShape3D
			extent = capsule.radius + (capsule.height * 0.5 - capsule.radius) * absf(at.basis.y.y)
		else:
			var half := (col.shape as BoxShape3D).size * 0.5
			extent = absf(at.basis.x.y) * half.x + absf(at.basis.y.y) * half.y + absf(at.basis.z.y) * half.z
		var floor_y := _support_height(at.origin, heights)
		var penetration := floor_y + extent + 0.015 - at.origin.y
		if penetration > -0.04:
			# Короткое затухающее скольжение; склон не должен уносить лежащее тело.
			var drag := exp(-maxf(dt, 0.0) * _surface_drag(at.origin, heights))
			var sliding := bone.linear_velocity
			sliding.x *= drag
			sliding.z *= drag
			bone.linear_velocity = sliding
		var immersion := heights.immersion_at(at.origin.x, at.origin.z, at.origin.y)
		if immersion > 0.0:
			bone.linear_velocity = _water_velocity(bone.linear_velocity, immersion, dt)
			bone.angular_velocity *= exp(-immersion * dt * 3.0)
		body_lift = maxf(body_lift, penetration)
	if body_lift > RECOVERY_PENETRATION:
		# Единый перенос сохраняет расстояния между суставами. Независимые
		# телепорты кистей/ног растягивали связи и накачивали рэгдолл энергией.
		for bone: PhysicalBone3D in _bones.values():
			bone.global_position.y += body_lift
			var velocity := bone.linear_velocity
			velocity.y = maxf(velocity.y, 0.0)
			bone.linear_velocity = velocity

	var water := heights.immersion_at(_bike_body.global_position.x, _bike_body.global_position.z, _bike_body.global_position.y)
	if water > 0.0:
		_bike_body.linear_velocity = _water_velocity(_bike_body.linear_velocity, water, dt)
	# Рама может остаться за пределами участка тела; страхуем колёса от падения сквозь землю.
	var lift := 0.0
	for child in _bike_body.get_children():
		if not child is CollisionShape3D:
			continue
		var col := child as CollisionShape3D
		var at := _bike_body.global_transform * col.transform
		var extent := 0.0
		if col.shape is BoxShape3D:
			var half := (col.shape as BoxShape3D).size * 0.5
			extent = absf(at.basis.x.y) * half.x + absf(at.basis.y.y) * half.y + absf(at.basis.z.y) * half.z
		elif col.shape is CylinderShape3D:
			var cylinder := col.shape as CylinderShape3D
			var vertical := absf(at.basis.y.y)
			extent = cylinder.height * 0.5 * vertical + cylinder.radius * sqrt(maxf(0.0, 1.0 - vertical * vertical))
		lift = maxf(lift, _support_height(at.origin, heights) + extent - at.origin.y)
	if lift > 0.2:
		_bike_body.global_position.y += lift
		var velocity := _bike_body.linear_velocity
		velocity.y = maxf(velocity.y, 0.0)
		_bike_body.linear_velocity = velocity


## Опора под телом: луч не видит настил над головой, в отличие от одной карты высот.
func _support_height(at: Vector3, heights: Heightfield) -> float:
	# deck_at обычно допускает шаг вверх на STEP; для лежащего тела нужен именно настил ПОД ним.
	var floor_y := heights.surface_at(at.x, at.z, at.y - Heightfield.STEP + 0.05)
	var query := PhysicsRayQueryParameters3D.create(at, at - Vector3.UP * 2.0, LAYER_GROUND)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and (hit.normal as Vector3).y > 0.25:
		floor_y = maxf(floor_y, hit.position.y)
	return floor_y


static func _surface_drag(at: Vector3, heights: Heightfield) -> float:
	var surface := PlayerState.surface(heights.world.tile_info(at.x / GameConfig.TILE, at.z / GameConfig.TILE))
	if heights.road_refinement != null:
		var sample := heights.road_refinement.sample(at.x, at.z, heights.world.W)
		if not sample.is_empty() and sample.surface != RoadSurface.NONE:
			surface = sample.surface
	var grip := 0.85 if surface == RoadSurface.NONE else float(RoadSurface.LIST[surface].grip)
	return 1.0 + grip * 2.0


static func _water_velocity(velocity: Vector3, immersion: float, dt: float) -> Vector3:
	var wet := clampf(immersion, 0.0, 1.0)
	return velocity * exp(-wet * dt * 4.0) + Vector3.UP * wet * dt * 4.0


## Встаём у таза, а не у велосипеда. Ближайшая безопасная поправка у ствола/воды
## допускается только без переноса через стены, настил и свод.
func _recovery_spot(b: BikeRide, w: WorldData, heights: Heightfield) -> Dictionary:
	var hips: Vector3 = _bones["Hips"].global_position
	var from := hips - Vector3.UP * 0.5
	var fwd := -_bike_body.global_basis.z
	var heading := atan2(-fwd.x, -fwd.z) if Vector2(fwd.x, fwd.z).length() > 0.3 else b.heading
	for radius: float in [0.0, 0.35, 0.75, 1.5, 3.0, 5.0, 8.0, 12.0]:
		for i in (1 if radius == 0.0 else 16):
			var spot := from + Vector3(cos(i * TAU / 16.0), 0.0, sin(i * TAU / 16.0)) * radius
			var floor_y := heights.surface_at(spot.x, spot.z, hips.y - Heightfield.STEP + 0.05)
			if absf(floor_y - from.y) > 1.2:
				continue
			if not PlayerState.is_passable(w, heights, spot.x, spot.z, floor_y, PlayerState.BODY_R):
				continue
			if not BikeRecovery.headroom(heights, spot.x, spot.z, floor_y):
				continue
			var goal := Vector3(spot.x, floor_y + 0.8, spot.z)
			var space := get_world_3d().direct_space_state
			if not space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(spot.x, floor_y + 0.1, spot.z), Vector3(spot.x, floor_y + 1.8, spot.z), LAYER_GROUND)).is_empty():
				continue
			if not space.intersect_ray(PhysicsRayQueryParameters3D.create(hips, goal, LAYER_GROUND)).is_empty():
				continue
			return {position = Vector3(spot.x, floor_y, spot.z), heading = heading}
	return {}


func _exit_tree() -> void:
	abort()


func _finish() -> void:
	_free_physics()
	if is_instance_valid(_rider):
		if is_instance_valid(_view):
			if _rider.get_parent() != _view:
				_rider.reparent(_view, false)
			_rider.transform = _rider_local
			_rider.restore_pose(_seated_pose)
			_rider.procedural_pose = _procedural_pose
			_view.draw(1.0)
		else:
			_rider.queue_free()
	if is_instance_valid(_ground):
		_ground.queue_free()
	_ground = null
	_seated_pose.clear()
	_bone_order.clear()
	if is_instance_valid(_animation_player):
		_animation_player.active = _animation_active
	_animation_player = null
	_view = null
	_rider = null
	t = 0.0
	phase = Phase.NONE


func _free_physics() -> void:
	if is_instance_valid(_sim):
		_sim.physical_bones_stop_simulation()
		_sim.free()
		_sim = null
	_bones.clear()
	if is_instance_valid(_bike_body):
		_bike_body.free()
		_bike_body = null


## Земля отдельно от объёмных сооружений: под мостом нет искусственной стены или поднятого берега.
func _build_ground(center: Vector3, _y: float, heights: Heightfield) -> void:
	if _ground != null:
		_ground.collision_layer = 0
		_ground.queue_free()
	_ground = StaticBody3D.new()
	_ground.collision_layer = LAYER_GROUND
	_ground.collision_mask = 0
	_ground.physics_material_override = _material(0.35)
	var cx := roundf(center.x)
	var cz := roundf(center.z)
	var n := GROUND_R * 2 + 1
	var data := PackedFloat32Array()
	data.resize(n * n)
	for j in n:
		for i in n:
			data[j * n + i] = heights.ground_at(cx + i - GROUND_R, cz + j - GROUND_R) + 0.025
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = data
	_add_shape(_ground, shape, Transform3D())
	add_child(_ground)
	_ground.global_position = Vector3(cx, 0.0, cz)
	_build_obstacles(heights)
	EnvironmentContacts.build(_ground, heights, GROUND_R)


## Только на время падения: те же простые объёмы леса, что уже используются при езде.
func _build_obstacles(heights: Heightfield) -> void:
	if heights.obstacles == null:
		return
	var data := heights.obstacles.data
	for i in range(0, data.size(), ForestObstacles.STRIDE):
		var a := Vector3(data[i], data[i + 5], data[i + 1])
		var b := Vector3(data[i + 2], data[i + 5], data[i + 3])
		var radius := data[i + 4]
		var center := (a + b) * 0.5
		if Vector2(center.x - _ground.position.x, center.z - _ground.position.z).length() > GROUND_R + a.distance_to(b) * 0.5 + radius:
			continue
		var top := minf(data[i + 6], a.y + 5.0)
		if a.distance_to(b) > 0.01:
			var log_shape := CapsuleShape3D.new()
			log_shape.radius = radius
			log_shape.height = a.distance_to(b) + radius * 2.0
			center.y = (a.y + top) * 0.5
			_add_shape(_ground, log_shape, Transform3D(Basis(Quaternion(Vector3.UP, (b - a).normalized())), center - _ground.position))
		else:
			var trunk := CylinderShape3D.new()
			trunk.radius = radius
			trunk.height = maxf(0.01, top - a.y)
			center.y = (a.y + top) * 0.5
			_add_shape(_ground, trunk, Transform3D(Basis(), center - _ground.position))


static func _add_shape(body: CollisionObject3D, shape: Shape3D, at: Transform3D) -> void:
	var col := CollisionShape3D.new()
	col.shape = shape
	col.transform = at
	body.add_child(col)


static func _box(size: Vector3) -> BoxShape3D:
	var box := BoxShape3D.new()
	box.size = size
	return box


static func _material(friction: float) -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.friction = friction
	m.bounce = 0.0
	return m
