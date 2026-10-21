class_name BikeCrash
extends Node3D
## Падение с велосипеда (с 7.6): потеря равновесия → тело на физических костях (ragdoll) → возврат в седло.
## BikeRide по-прежнему решает только, что седок упал (жёсткое приземление или удар в стену); здесь — как это выглядит.
## Физика движка нужна лишь на время падения: под местом падения ставится кусок рельефа (HeightMapShape3D),
## на скелет седока — PhysicalBone3D на 11 костях, велосипед становится RigidBody3D. После возврата всё удаляется.
## Тела сталкиваются только с землёй: ни друг с другом, ни с велосипедом (проще и без взрывов в суставах).

const BALANCE := 0.22   # потеря равновесия: велосипед заваливается, седок ещё на нём, с
const LIE_MIN := 1.0    # тело лежит не меньше этого, с
const LIE_MAX := 2.4    # и не дольше этого, с
const RECOVER := 0.45   # возврат в седло, с (дольше, если велосипед лежит далеко: не быстрее RECOVER_SPEED)
const RECOVER_SPEED := 6.0 # м/с
const GROUND_R := 16    # кусок рельефа под падением: 2·R+1 точек по стороне через 1 м
const LAYER_GROUND := 4
const LAYER_BODY := 8
const GRAVITY_SCALE := GameConfig.GRAVITY / 9.8

# кость: [форма (0 — шар, 1 — капсула), радиус, длина капсулы, центр по оси кости, масса, конус сустава, кручение]
const BODIES := {
	"Hips": [0, 0.13, 0.0, 0.0, 12.0, 0.0, 0.0],
	"Spine": [1, 0.14, 0.42, 0.15, 20.0, 30.0, 20.0],
	"Head": [0, 0.13, 0.0, 0.03, 5.0, 40.0, 30.0],
	"UpperArmL": [1, 0.06, 0.34, 0.15, 2.5, 70.0, 40.0],
	"UpperArmR": [1, 0.06, 0.34, 0.15, 2.5, 70.0, 40.0],
	"ForearmL": [1, 0.05, 0.32, 0.15, 1.5, 50.0, 10.0],
	"ForearmR": [1, 0.05, 0.32, 0.15, 1.5, 50.0, 10.0],
	"UpperLegL": [1, 0.08, 0.46, 0.21, 8.0, 50.0, 20.0],
	"UpperLegR": [1, 0.08, 0.46, 0.21, 8.0, 50.0, 20.0],
	"LowerLegL": [1, 0.06, 0.44, 0.21, 4.0, 50.0, 10.0],
	"LowerLegR": [1, 0.06, 0.44, 0.21, 4.0, 50.0, 10.0],
}

enum Phase { NONE, BALANCE, RAGDOLL, RECOVER }

var phase := Phase.NONE
var t := 0.0
var _view: BikeView
var _rider: CyclistRig
var _rider_local := Transform3D()   # место седока в сцене велосипеда
var _vel := Vector3()               # скорость в момент падения, м/с
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
	_side = signf(b.lean) if absf(b.lean) > 0.02 else (signf(b.steer) if absf(b.steer) > 0.05 else 1.0)
	_start = view.global_transform
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
			var roll := Basis(fwd, -_side * 0.7 * k * k) * Basis(_start.basis.x, -0.25 * k * k)
			var travel := Vector3(_vel.x, 0.0, _vel.z) * t * (1.0 - 0.3 * k)
			_view.global_transform = Transform3D(roll * _start.basis, _start.origin + travel)
			if t >= BALANCE:
				_begin_ragdoll()
		Phase.RAGDOLL:
			_view.global_transform = _bike_body.global_transform
			var hips := _bones["Hips"] as PhysicalBone3D
			var settled := hips.linear_velocity.length() < 1.0
			var lost := Vector2(hips.global_position.x - _ground.position.x, hips.global_position.z - _ground.position.z).length() > GROUND_R - 2
			if (t >= LIE_MIN and settled) or t >= LIE_MAX or lost:
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
	var fling := Vector3(_vel.x * 0.7, maxf(_vel.y, 0.0) * 0.3 + 1.6, _vel.z * 0.7)
	for bone: PhysicalBone3D in _bones.values():
		bone.linear_velocity = fling
		bone.angular_velocity = -view_at.basis.x * 2.5 + view_at.basis.z * _side * 1.0
	_bike_body = RigidBody3D.new()
	_bike_body.collision_layer = LAYER_BODY
	_bike_body.collision_mask = LAYER_GROUND
	_bike_body.mass = 14.0
	_bike_body.gravity_scale = GRAVITY_SCALE
	_bike_body.angular_damp = 1.5
	_bike_body.linear_damp = 1.0
	_bike_body.physics_material_override = _material(0.6)
	_add_shape(_bike_body, _box(Vector3(0.12, 0.45, 1.2)), Transform3D(Basis(), Vector3(0, 0.62, 0)))
	for z: float in [-BikeRide.HUB, BikeRide.HUB]:
		var wheel := CylinderShape3D.new()
		wheel.radius = BikeView.WHEEL_Y
		wheel.height = 0.06
		_add_shape(_bike_body, wheel, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3(0, BikeView.WHEEL_Y, z)))
	add_child(_bike_body)
	_bike_body.global_transform = view_at
	_bike_body.linear_velocity = Vector3(_vel.x * 0.6, 0.5, _vel.z * 0.6)
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
		bone.friction = 1.0
		bone.gravity_scale = GRAVITY_SCALE
		bone.linear_damp = 1.2
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
		else:
			shape = CapsuleShape3D.new()
			(shape as CapsuleShape3D).radius = spec[1]
			(shape as CapsuleShape3D).height = spec[2]
		_add_shape(bone, shape, Transform3D())
		_sim.add_child(bone)
		# тело сразу на месте кости (в начале кадра симулятор ещё не успел бы его поставить)
		bone.global_transform = skel.global_transform * skel.get_bone_global_pose(skel.find_bone(bone_name)) * bone.body_offset
		_bones[bone_name] = bone
	_sim.physical_bones_start_simulation()


func _begin_recover(b: BikeRide, w: WorldData, heights: Heightfield) -> void:
	phase = Phase.RECOVER
	t = 0.0
	# поза падения: кости с телами — по телам, остальные — как были
	var skel := _rider.skeleton
	var globals: Array = []
	_from_pose.clear()
	for i in skel.get_bone_count():
		var local := Transform3D(Basis(skel.get_bone_pose_rotation(i)), skel.get_bone_pose_position(i))
		var parent := skel.get_bone_parent(i)
		var global := (globals[parent] as Transform3D) * local if parent >= 0 else local
		var bone := _bones.get(skel.get_bone_name(i)) as PhysicalBone3D
		if bone != null:
			global = skel.global_transform.affine_inverse() * bone.global_transform * bone.body_offset.affine_inverse()
			local = (globals[parent] as Transform3D).affine_inverse() * global if parent >= 0 else global
		globals.append(global)
		_from_pose.append(local)
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


## Кусок рельефа под падением: HeightMapShape3D через 1 м, высоты — поверхность игры (с настилами мостов)
func _build_ground(center: Vector3, y: float, heights: Heightfield) -> void:
	if _ground != null:
		_ground.queue_free()
	_ground = StaticBody3D.new()
	_ground.collision_layer = LAYER_GROUND
	_ground.collision_mask = 0
	_ground.physics_material_override = _material(0.9)
	var cx := roundf(center.x)
	var cz := roundf(center.z)
	var n := GROUND_R * 2 + 1
	var data := PackedFloat32Array()
	data.resize(n * n)
	for j in n:
		for i in n:
			data[j * n + i] = heights.surface_at(cx + i - GROUND_R, cz + j - GROUND_R, y + 1.0)
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = data
	_add_shape(_ground, shape, Transform3D())
	add_child(_ground)
	_ground.global_position = Vector3(cx, 0.0, cz)


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
	m.bounce = 0.05
	return m
