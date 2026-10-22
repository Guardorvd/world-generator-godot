class_name BikeCrash
extends Node3D
## Падение с велосипеда (с 7.6): потеря равновесия → тело на физических костях (ragdoll) → возврат в седло.
## BikeRide по-прежнему решает только, что седок упал (жёсткое приземление или удар в стену); здесь — как это выглядит.
## Физика движка нужна лишь на время падения: под местом падения ставится кусок рельефа (HeightMapShape3D),
## на скелет седока — PhysicalBone3D, велосипед становится RigidBody3D. После возврата всё удаляется.
## Тела сталкиваются с землёй и ближайшими препятствиями леса, но не друг с другом и не с велосипедом.

const BALANCE := 0.22   # потеря равновесия: велосипед заваливается, седок ещё на нём, с
const LIE_MIN := 1.0    # тело лежит не меньше этого, с
const LIE_MAX := 2.4    # и не дольше этого, с
const RECOVER := 0.45   # возврат в седло, с (дольше, если велосипед лежит далеко: не быстрее RECOVER_SPEED)
const RECOVER_SPEED := 6.0 # м/с
const SETTLE := 0.2     # остановка должна держаться, а не быть одним тактом в верхней точке полёта
const GROUND_R := 16    # радиус куска рельефа под падением, м
const LAYER_GROUND := 4
const LAYER_BODY := 8
const GRAVITY_SCALE := GameConfig.GRAVITY / 9.8

# кость: [форма (0 — шар, 1 — капсула, 2 — обувь), радиус, длина капсулы, центр по оси кости, масса, конус сустава, кручение]
const BODIES := {
	"Hips": [0, 0.13, 0.0, 0.0, 12.0, 0.0, 0.0],
	"Spine": [1, 0.14, 0.42, 0.15, 20.0, 30.0, 20.0],
	"Head": [1, 0.145, 0.38, 0.035, 5.0, 40.0, 30.0],
	"UpperArmL": [1, 0.06, 0.34, 0.15, 2.5, 70.0, 40.0],
	"UpperArmR": [1, 0.06, 0.34, 0.15, 2.5, 70.0, 40.0],
	"ForearmL": [1, 0.05, 0.32, 0.15, 1.5, 50.0, 10.0],
	"ForearmR": [1, 0.05, 0.32, 0.15, 1.5, 50.0, 10.0],
	"HandL": [0, 0.06, 0.0, 0.0, 0.5, 35.0, 15.0],
	"HandR": [0, 0.06, 0.0, 0.0, 0.5, 35.0, 15.0],
	"UpperLegL": [1, 0.08, 0.46, 0.21, 8.0, 50.0, 20.0],
	"UpperLegR": [1, 0.08, 0.46, 0.21, 8.0, 50.0, 20.0],
	"LowerLegL": [1, 0.06, 0.44, 0.21, 4.0, 50.0, 10.0],
	"LowerLegR": [1, 0.06, 0.44, 0.21, 4.0, 50.0, 10.0],
	"FootL": [2, 0.0, 0.0, 0.0, 1.0, 30.0, 15.0],
	"FootR": [2, 0.0, 0.0, 0.0, 1.0, 30.0, 15.0],
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
var _bones: Dictionary = {}         # имя кости → PhysicalBone3D
var _from_view := Transform3D()     # возврат: откуда едет велосипед
var _from_root := Transform3D()     # и где в мире лежала корневая кость седока
var _from_pose: Array = []          # местные позы костей в конце падения (Transform3D)
var _from_feet := Vector3()
var _recover_time := RECOVER


func active() -> bool:
	return phase != Phase.NONE


## Начать падение: velocity — скорость велосипеда до удара (BikeRide.crash_velocity)
func start(view: BikeView, b: BikeRide, velocity: Vector3, heights: Heightfield) -> void:
	abort()
	_view = view
	_rider = view.rider
	_rider_local = _rider.transform
	_vel = velocity
	_release_velocity = velocity
	_settled_time = 0.0
	_side = signf(b.lean) if absf(b.lean) > 0.02 else (signf(b.steer) if absf(b.steer) > 0.05 else 1.0)
	_tumble = smoothstep(2.0, 10.0, Vector2(velocity.x, velocity.z).length()) * (1.0 - clampf(absf(b.lean) / 0.4, 0.0, 0.6))
	_start = view.global_transform
	_forward = -1.0 if velocity.dot(-_start.basis.z) < -0.1 else 1.0
	_build_ground(Vector3(b.x, b.y, b.z) + Vector3(velocity.x, 0.0, velocity.z) * 0.35, b.y, heights)
	phase = Phase.BALANCE
	t = 0.0


## Такт физики игры (60 в секунду). Возвращает true, когда седок снова в седле.
func tick(dt: float, b: BikeRide, w: WorldData, heights: Heightfield) -> bool:
	t += dt
	match phase:
		Phase.BALANCE:
			# велосипед уходит из-под седока: катится по инерции и валится набок, нос клюёт вниз
			var k := clampf(t / BALANCE, 0.0, 1.0)
			var fwd := -_start.basis.z
			var roll := Basis(fwd, -_side * 0.7 * k * k) * Basis(_start.basis.x, -0.25 * _tumble * _forward * k * k)
			var travel := Vector3(_vel.x, 0.0, _vel.z) * t * (1.0 - 0.3 * k)
			var before := _view.global_position
			var prev_t := maxf(0.0, t - dt)
			var prev_k := clampf(prev_t / BALANCE, 0.0, 1.0)
			var prev_travel := Vector3(_vel.x, 0.0, _vel.z) * prev_t * (1.0 - 0.3 * prev_k)
			var delta := travel - prev_travel
			var free := func(px: float, pz: float) -> bool: return b.fits(px, pz, b.heading, w, heights)
			var around := Callable()
			if heights.obstacles != null:
				around = func(px: float, pz: float) -> Vector2: return b._obstacle_normal(px, pz, b.heading, heights)
			var to := PlayerState.slide(free, before.x, before.z, delta.x, delta.z, around)
			var at := Vector3(to[0], _start.origin.y, to[1])
			_release_velocity.x = (at.x - before.x) / maxf(dt, 0.001)
			_release_velocity.z = (at.z - before.z) / maxf(dt, 0.001)
			_view.global_transform = Transform3D(roll * _start.basis, at)
			if t >= BALANCE:
				_begin_ragdoll()
		Phase.RAGDOLL:
			_view.global_transform = _bike_body.global_transform
			_keep_above_ground(heights, dt)
			_sync_pose()
			var hips := _bones["Hips"] as PhysicalBone3D
			var near_ground := hips.global_position.y - heights.surface_at(hips.global_position.x, hips.global_position.z, hips.global_position.y + 1.0) < 0.65
			var head := _bones["Head"] as PhysicalBone3D
			var lying := head.global_position.y - heights.surface_at(head.global_position.x, head.global_position.z, head.global_position.y + 1.0) < 0.45
			var settled := near_ground and lying and hips.linear_velocity.length() < 0.8 and head.linear_velocity.length() < 0.8 and hips.angular_velocity.length() < 1.0 and _bike_body.linear_velocity.length() < 0.8
			_settled_time = _settled_time + dt if settled else 0.0
			var lost := Vector2(hips.global_position.x - _ground.position.x, hips.global_position.z - _ground.position.z).length() > GROUND_R - 2
			if (t >= LIE_MIN and _settled_time >= SETTLE) or t >= LIE_MAX or lost:
				_begin_recover(b, w, heights)
		Phase.RECOVER:
			if t >= _recover_time:
				_finish()
				return true
	return false


## Кадр: во время возврата седок и велосипед плавно переходят из позы падения в посадку
func draw() -> void:
	if phase != Phase.RECOVER:
		return
	var s := smoothstep(0.0, 1.0, t / _recover_time)
	_view.draw(1.0) # велосипед стоит, седок в обычной посадке: это цель
	var goal := _view.global_transform
	var skel := _rider.skeleton
	var skel_goal := skel.global_transform
	_view.global_transform = _blend(_from_view, goal, s)
	for i in skel.get_bone_count():
		var from: Transform3D = _from_pose[i]
		var to := Transform3D(Basis(skel.get_bone_pose_rotation(i)), skel.get_bone_pose_position(i))
		if i == 0:
			# корень переходит в мире по прямой: из места, где лежал, в седло (велосипед в это время поворачивается)
			to = skel.global_transform.affine_inverse() * _blend(_from_root, skel_goal * to, s)
			from = to
		skel.set_bone_pose_position(i, from.origin.lerp(to.origin, s))
		skel.set_bone_pose_rotation(i, from.basis.get_rotation_quaternion().slerp(to.basis.get_rotation_quaternion(), s))


static func _blend(a: Transform3D, b: Transform3D, s: float) -> Transform3D:
	return Transform3D(a.basis.orthonormalized().slerp(b.basis.orthonormalized(), s), a.origin.lerp(b.origin, s))


## Где сейчас седок (для камеры, звука и подгрузки мира): таз в падении, велосипед в остальное время
func focus(b: BikeRide) -> Vector3:
	match phase:
		Phase.RAGDOLL:
			var hips := (_bones["Hips"] as PhysicalBone3D).global_position
			return Vector3(hips.x, hips.y - 0.5, hips.z)
		Phase.RECOVER:
			return _from_feet.lerp(Vector3(b.x, b.y, b.z), smoothstep(0.0, 1.0, t / _recover_time))
	return _view.global_position


## Прервать падение (быстрое перемещение, выход из мира): седок сразу в седле
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
	var fling := Vector3(_release_velocity.x * 0.7, maxf(_vel.y, 0.0) * 0.3 + 1.6, _release_velocity.z * 0.7)
	for bone: PhysicalBone3D in _bones.values():
		bone.linear_velocity = fling
		bone.angular_velocity = -view_at.basis.x * _forward * lerpf(0.6, 2.5, _tumble) + view_at.basis.z * _side * lerpf(2.2, 1.0, _tumble)
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
	_bike_body.linear_velocity = Vector3(_release_velocity.x * 0.6, 0.5, _release_velocity.z * 0.6)
	_bike_body.angular_velocity = -view_at.basis.z * _side * 3.0


## PhysicalBone3D на костях из BODIES: тело — посередине кости, сустав — в её начале
func _build_ragdoll() -> void:
	var skel := _rider.skeleton
	_sim = PhysicalBoneSimulator3D.new()
	skel.add_child(_sim)
	_bones.clear()
	for bone_name: String in BODIES:
		var spec: Array = BODIES[bone_name]
		var bone := PhysicalBone3D.new()
		bone.name = bone_name
		bone.bone_name = bone_name
		bone.collision_layer = LAYER_BODY
		bone.collision_mask = LAYER_GROUND
		bone.mass = spec[4]
		bone.friction = 0.45
		bone.gravity_scale = GRAVITY_SCALE
		bone.linear_damp = 0.7
		bone.angular_damp = 3.0
		bone.body_offset = Transform3D(Basis(), Vector3(0, spec[3], 0))
		bone.joint_offset = Transform3D(Basis(), Vector3(0, -spec[3], 0))
		if spec[5] > 0.0:
			bone.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			bone.set("joint_constraints/swing_span", spec[5])
			bone.set("joint_constraints/twist_span", spec[6])
		var shape: Shape3D
		if spec[0] == 0:
			shape = SphereShape3D.new()
			(shape as SphereShape3D).radius = spec[1]
		elif spec[0] == 1:
			shape = CapsuleShape3D.new()
			(shape as CapsuleShape3D).radius = spec[1]
			(shape as CapsuleShape3D).height = spec[2]
		else:
			shape = _box(Vector3(0.14, 0.10, 0.25))
		var shape_at := Transform3D(Basis(), Vector3(0, -0.01, -0.035)) if spec[0] == 2 else Transform3D()
		_add_shape(bone, shape, shape_at)
		_sim.add_child(bone)
		# тело сразу на месте кости (в начале кадра симулятор ещё не успел бы его поставить)
		bone.global_transform = skel.global_transform * skel.get_bone_global_pose(skel.find_bone(bone_name)) * bone.body_offset
		_bones[bone_name] = bone
	_sim.physical_bones_start_simulation()
	# Позу переносим в _sync_pose сами: второй проход модификатора в кадре не должен её перезаписывать.
	_sim.active = false


func _begin_recover(b: BikeRide, w: WorldData, heights: Heightfield) -> void:
	phase = Phase.RECOVER
	t = 0.0
	# поза падения: кости с телами — по телам, остальные — как были
	var skel := _rider.skeleton
	var globals := _sync_pose()
	_from_pose.clear()
	for i in skel.get_bone_count():
		_from_pose.append(skel.get_bone_pose(i))
	_from_root = skel.global_transform * (globals[0] as Transform3D)
	var hips: Vector3 = (_bones["Hips"] as PhysicalBone3D).global_position
	_from_feet = Vector3(hips.x, hips.y - 0.5, hips.z)
	_from_view = _bike_body.global_transform
	_free_physics()
	# седок поднимается там, где лёг, и подтягивает велосипед к себе, носом туда, куда тот смотрел;
	# если там стена — велосипед встаёт там, где лежал, или на месте падения
	var fwd := -_from_view.basis.z
	if Vector2(fwd.x, fwd.z).length() > 0.3:
		b.heading = atan2(-fwd.x, -fwd.z)
	for spot: Vector3 in [_from_feet, _from_view.origin]:
		if b.fits(spot.x, spot.z, b.heading, w, heights):
			b.x = spot.x
			b.z = spot.z
			b.y = heights.surface_at(b.x, b.z, spot.y + 1.0)
			break
	b.y = heights.surface_at(b.x, b.z, b.y + 1.0)
	_recover_time = maxf(RECOVER, _from_feet.distance_to(Vector3(b.x, b.y, b.z)) / RECOVER_SPEED)
	_rider.reparent(_view, false)
	_rider.transform = _rider_local
	_view.snap(b)


## Видимая модель следует телам и в такте физики, включая кости без PhysicalBone у родителей.
func _sync_pose() -> Array:
	var skel := _rider.skeleton
	var globals: Array = []
	for i in skel.get_bone_count():
		var local := Transform3D(Basis(skel.get_bone_pose_rotation(i)), skel.get_bone_pose_position(i))
		var parent := skel.get_bone_parent(i)
		var global := (globals[parent] as Transform3D) * local if parent >= 0 else local
		var bone := _bones.get(skel.get_bone_name(i)) as PhysicalBone3D
		if bone != null:
			global = skel.global_transform.affine_inverse() * bone.global_transform * bone.body_offset.affine_inverse()
			local = (globals[parent] as Transform3D).affine_inverse() * global if parent >= 0 else global
		globals.append(global)
		skel.set_bone_pose_position(i, local.origin)
		skel.set_bone_pose_rotation(i, local.basis.get_rotation_quaternion())
	# Жёсткие low-poly детали на BoneAttachment должны обновиться в том же такте, что и кости.
	for child: Node in skel.get_children():
		if child is BoneAttachment3D:
			(child as BoneAttachment3D).transform = globals[skel.find_bone((child as BoneAttachment3D).bone_name)]
	return globals


## Страховка редкого пропуска контакта тонкой конечностью или рывка сустава.
## Обычное скольжение решает физика; здесь убираем только проникновение под поверхность.
func _keep_above_ground(heights: Heightfield, dt: float) -> void:
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
		var floor_y := heights.surface_at(at.origin.x, at.origin.z, at.origin.y + 1.0)
		var penetration := floor_y + extent + 0.015 - at.origin.y
		if penetration > -0.04:
			# Короткое затухающее скольжение; склон не должен уносить лежащее тело.
			var drag := exp(-maxf(dt, 0.0) * 3.0)
			var sliding := bone.linear_velocity
			sliding.x *= drag
			sliding.z *= drag
			bone.linear_velocity = sliding
		if penetration > 0.0:
			bone.global_position.y += penetration
			var velocity := bone.linear_velocity
			velocity.y = maxf(velocity.y, 0.0)
			bone.linear_velocity = velocity


func _finish() -> void:
	_free_physics()
	if _rider != null and _rider.get_parent() != _view:
		_rider.reparent(_view, false)
		_rider.transform = _rider_local
	if _ground != null:
		_ground.queue_free()
		_ground = null
	phase = Phase.NONE


func _free_physics() -> void:
	if _sim != null:
		_sim.physical_bones_stop_simulation()
		_sim.free()
		_sim = null
	_bones.clear()
	if _bike_body != null:
		_bike_body.free()
		_bike_body = null


## Кусок рельефа под падением: высоты поверхности игры с настилами мостов и небольшим запасом от пересечений.
func _build_ground(center: Vector3, y: float, heights: Heightfield) -> void:
	if _ground != null:
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
			data[j * n + i] = heights.surface_at(cx + i - GROUND_R, cz + j - GROUND_R, y + 1.0) + 0.025
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = data
	_add_shape(_ground, shape, Transform3D())
	add_child(_ground)
	_ground.global_position = Vector3(cx, 0.0, cz)
	_build_obstacles(heights)


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
