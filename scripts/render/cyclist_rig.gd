class_name CyclistRig
extends Node3D
## Native rigid low-poly rig. Disable procedural_pose to animate bone tracks normally.
@export var procedural_pose := true
@onready var skeleton: Skeleton3D = get_node_or_null("Skeleton3D") as Skeleton3D
# Порядок родителей важен: глобальная поза родителя вычисляется раньше потомка.
const BONE_PARENTS := {
	"Root": "", "Hips": "Root", "Spine": "Hips", "Chest": "Spine",
	"Neck": "Chest", "Head": "Neck",
	"ClavicleL": "Chest", "UpperArmL": "ClavicleL", "ForearmL": "UpperArmL", "HandL": "ForearmL",
	"UpperLegL": "Hips", "LowerLegL": "UpperLegL", "FootL": "LowerLegL", "ToeL": "FootL",
	"ClavicleR": "Chest", "UpperArmR": "ClavicleR", "ForearmR": "UpperArmR", "HandR": "ForearmR",
	"UpperLegR": "Hips", "LowerLegR": "UpperLegR", "FootR": "LowerLegR", "ToeR": "FootR",
}
const LEG_LENGTH := 0.43
const ARM_LENGTH := 0.31
const SPINE_LENGTH := 0.45213
const CHEST_LENGTH := 0.20346
const SADDLE_POS := Vector3(0.0, 1.015, 0.20)
const CHEST_POS := Vector3(0.0, 1.37, -0.08)
const PEDAL_CONTACT_LOCAL := Vector3(0.0, -0.055, -0.025)
const ANKLE_OFFSET := -PEDAL_CONTACT_LOCAL
const TOE_OFFSET := Vector3(0.0, -0.015, -0.095)
# Базовые позы: положение таза и его наклон, смещение груди (спины), вынос локтей (вбок, вверх) и угол кистей.
enum BaseStance { COAST, CALM, CLIMB, DESCENT, BRAKE }
const BASE_POSES := {
	BaseStance.COAST: {
		hip = Vector3.ZERO, pelvis_pitch = 0.0,
		chest = Vector3.ZERO, elbow = Vector2(0.42, -0.36), wrist = 0.0,
	},
	BaseStance.CALM: {
		hip = Vector3(0.0, -0.002, -0.008), pelvis_pitch = -0.03,
		chest = Vector3(0.0, -0.010, -0.014), elbow = Vector2(0.46, -0.33), wrist = -0.03,
	},
	BaseStance.CLIMB: {
		hip = Vector3(0.0, 0.048, -0.145), pelvis_pitch = -0.055,
		chest = Vector3(0.0, -0.018, -0.145), elbow = Vector2(0.56, -0.24), wrist = 0.08,
	},
	BaseStance.DESCENT: {
		hip = Vector3(0.0, 0.028, 0.063), pelvis_pitch = 0.045,
		chest = Vector3(0.0, -0.058, 0.018), elbow = Vector2(0.80, -0.10), wrist = -0.11,
	},
	BaseStance.BRAKE: {
		hip = Vector3(0.0, -0.012, 0.132), pelvis_pitch = 0.055,
		chest = Vector3(0.0, -0.044, 0.118), elbow = Vector2(0.64, -0.18), wrist = -0.15,
	},
}

## Цели контактов заданы в системе координат скелета. BikeView переиспользует вход между кадрами.
class PoseInput extends RefCounted:
	var left_grip := Vector3.ZERO
	var right_grip := Vector3.ZERO
	var left_pedal := Vector3.ZERO
	var right_pedal := Vector3.ZERO
	var ground_point := Vector3.ZERO
	var ground_up := Vector3.UP
	var motion := Vector3.ZERO # продольный и боковой перенос, присед в метрах
	var crank_angle := 0.0
	var tuck := 0.0
	var stand := 0.0 # +1 подъём стоя, -1 стойка на спуске, 0 сидя
	var effort := 0.0 # усилие на педалях с учётом приоритетов позы
	var brake := 0.0
	var front_load := 0.0
	var rear_load := 0.0
	var balance := 0.0
	var foot_down := 0.0 # знак задаёт сторону опорной ноги
	var pitch := 0.0
	var roll := 0.0
	var ground_lean := 0.0
	var sway := 0.0
	var breath := 0.0
	var look := 0.0
	var turn_support := 0.0 # наружная опора от крена, в диапазоне −1..1
	var body_look := 0.0
	var head_nod := 0.0
	var gaze := Vector2.ZERO
	var hand_rest := 0.0
	var watch := 0.0

	func has_finite_values() -> bool:
		return left_grip.is_finite() and right_grip.is_finite() and left_pedal.is_finite() and right_pedal.is_finite() \
			and ground_point.is_finite() and ground_up.is_finite() and motion.is_finite() \
			and is_finite(crank_angle) and is_finite(tuck) and is_finite(stand) and is_finite(effort) and is_finite(brake) \
			and is_finite(front_load) and is_finite(rear_load) and is_finite(balance) and is_finite(foot_down) \
			and is_finite(pitch) and is_finite(roll) and is_finite(ground_lean) and is_finite(sway) and is_finite(breath) \
			and is_finite(look) and is_finite(turn_support) and is_finite(body_look) and is_finite(head_nod) and gaze.is_finite() \
			and is_finite(hand_rest) and is_finite(watch)


var _bones: Dictionary[String, int] = {}
var _poses: Array[Transform3D] = [] # родители записываются раньше потомков
var _parents := PackedInt32Array()
var _feet: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _foot_pitch := Vector2.ZERO
var _base_weights := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
var _base_hip := Vector3.ZERO
var _base_pelvis_pitch := 0.0
var _base_chest := Vector3.ZERO
var _base_elbow := Vector2.ZERO
var _base_wrist := 0.0
var _rig_checked := false
var _rig_valid := false
## Изгиб спины дугой (0 — прямая, как в bind-позе; сборщик модели ставит 0 на время сборки).
var spine_bow := 1.0
var pedal_pitch := Vector2.ZERO # rotation about each pedal spindle for this solved pose
var _hand_rest_l := Basis.IDENTITY # поворот кисти относительно предплечья в хвате: свободная рука держит его же
var _hand_rest_r := Basis.IDENTITY
var _neck_anchor := Vector3.ZERO


## Проверяем контракт один раз до изменения костей, в том числе при сборке сцены инструментом.
func _bind_skeleton() -> bool:
	_rig_checked = true
	if not is_instance_valid(skeleton):
		push_warning("CyclistRig: отсутствует Skeleton3D; процедурная поза отключена")
		return false
	for bone_name: String in BONE_PARENTS:
		var index := skeleton.find_bone(bone_name)
		var parent_name: String = BONE_PARENTS[bone_name]
		var parent := -1 if parent_name.is_empty() else skeleton.find_bone(parent_name)
		if index < 0 or (not parent_name.is_empty() and parent < 0) or skeleton.get_bone_parent(index) != parent:
			push_warning("CyclistRig: неверная кость или родитель у %s; процедурная поза отключена" % bone_name)
			return false
		_bones[bone_name] = index
	_parents.resize(skeleton.get_bone_count())
	_poses.resize(skeleton.get_bone_count())
	for i in skeleton.get_bone_count():
		_parents[i] = skeleton.get_bone_parent(i)
	_hand_rest_l = skeleton.get_bone_rest(_bones["HandL"]).basis.orthonormalized()
	_hand_rest_r = skeleton.get_bone_rest(_bones["HandR"]).basis.orthonormalized()
	var rest_hip := Vector3(0, 0.97, 0.17)
	var rest_upper := Transform3D(Basis(Quaternion(Vector3.UP, (CHEST_POS - rest_hip).normalized())), rest_hip.lerp(CHEST_POS, 0.55))
	_neck_anchor = rest_upper.affine_inverse() * Vector3(0, 1.44, -0.1)
	return true


## Проверка доступна анимации и рэгдоллу до передачи управления костями.
func is_rig_valid() -> bool:
	if not _rig_checked:
		_rig_valid = _bind_skeleton()
	return _rig_valid and is_instance_valid(skeleton)


func capture_pose() -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	if is_instance_valid(skeleton):
		for i in skeleton.get_bone_count():
			result.append(skeleton.get_bone_pose(i))
	return result


## Снимки принадлежат этому экземпляру скелета; неверный снимок не применяется частично.
func restore_pose(snapshot: Array[Transform3D]) -> void:
	if not is_instance_valid(skeleton) or snapshot.size() != skeleton.get_bone_count():
		return
	for local in snapshot:
		if not local.is_finite():
			return
	for i in snapshot.size():
		skeleton.set_bone_pose_position(i, snapshot[i].origin)
		skeleton.set_bone_pose_rotation(i, snapshot[i].basis.get_rotation_quaternion())
		skeleton.set_bone_pose_scale(i, snapshot[i].basis.get_scale())


## Базовая поза и реакции корпуса определяют суставы, а IK доводит руки и ноги до заданных опор.
func pose(input: PoseInput) -> void:
	if not procedural_pose or not is_rig_valid() or input == null or not input.has_finite_values():
		return
	var left_grip := input.left_grip
	var right_grip := input.right_grip
	var motion := input.motion
	var tuck := input.tuck
	var roll := input.roll
	var look := input.look
	var balance := input.balance
	var gaze := input.gaze
	# Знак задаёт сторону отдыхающей руки.
	var rest := smoothstep(0.0, 1.0, clampf(absf(input.hand_rest), 0.0, 1.0))
	var rest_side := -1.0 if input.hand_rest < 0.0 else 1.0
	var wrist_view := smoothstep(0.0, 0.90, input.watch)
	var watch_gaze := smoothstep(0.28, 0.95, input.watch)
	var fd := smoothstep(0.0, 1.0, clampf(absf(input.foot_down), 0.0, 1.0))
	var fd_side := -1.0 if input.foot_down < 0.0 else 1.0
	var sway := clampf(input.sway, -0.13, 0.13)
	var breath := clampf(input.breath, -0.0065, 0.0065)
	var stand := clampf(input.stand, -1.0, 1.0)
	var brake := clampf(input.brake, 0.0, 1.0)
	var front_load := clampf(input.front_load, 0.0, 1.0)
	var rear_load := clampf(input.rear_load, 0.0, 1.0)
	var up := maxf(stand, 0.0)
	var attack := maxf(-stand, 0.0)
	var standing := clampf(up + attack, 0.0, 1.0)
	var seated := 1.0 - standing
	var drive_effort := clampf(input.effort, 0.0, 1.25)
	var pedal_up := up * smoothstep(0.0, 0.8, drive_effort)
	var spin := clampf(drive_effort / 0.65, 0.0, 1.0) * seated
	var heavy := smoothstep(0.55, 1.05, drive_effort)
	var drive_side := sin(input.crank_angle)
	var crank_top := cos(input.crank_angle)
	var body_look := input.body_look
	var corner_right := clampf(input.turn_support, -1.0, 1.0)
	_blend_base_pose(drive_effort, up, attack, brake)
	# 1. Опора стоп на педали: стопа качается вокруг точки контакта с педалью, смещая голеностоп.
	# Задний удар и приземление (rear_load), а также упор наружной ногой в повороте опускают пятку вниз.
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var outer_leg := maxf(0.0, -side * corner_right)
		var inner_leg := maxf(0.0, side * corner_right)
		var pedal := input.left_pedal if side < 0.0 else input.right_pedal
		var top_phase := -side * crank_top
		var down_phase := -side * drive_side
		var power_phase := maxf(0.0, down_phase)
		var bottom_scrape := maxf(0.0, -top_phase) * smoothstep(-0.4, 0.5, down_phase)
		var spin_pitch := (0.06 * top_phase - 0.11 * maxf(0.0, -top_phase) - 0.05 * down_phase) * spin
		var heavy_pitch := (0.16 * power_phase - 0.13 * bottom_scrape) * heavy * seated
		var stand_pitch := -0.04 * up + (0.14 * power_phase - 0.18 * maxf(0.0, -top_phase)) * pedal_up
		var corner_pitch := (0.14 * outer_leg - 0.05 * inner_leg) * (1.0 - spin * 0.55)
		# В повороте стопа держит наружную опору: свободный ход голеностопа на накате уступает ей.
		var coast_pitch := 0.04 * top_phase * (1.0 - clampf(drive_effort, 0.0, 1.0)) * (1.0 - absf(corner_right))
		var brace_pitch := 0.14 * attack + 0.12 * rear_load + 0.07 * clampf(motion.z * 3.0, 0.0, 1.0) + 0.04 * brake + corner_pitch + coast_pitch
		var foot_pitch := clampf(spin_pitch + heavy_pitch + stand_pitch + brace_pitch, -0.28, 0.26)
		var foot_yaw := -side * (0.026 - 0.010 * power_phase * (heavy + pedal_up * 0.5) + 0.012 * inner_leg)
		var foot_roll := -side * (0.022 * power_phase * (heavy + pedal_up * 0.7) + 0.032 * outer_leg)
		var foot_basis := Basis.from_euler(Vector3(foot_pitch, foot_yaw, foot_roll))
		var ankle_at := pedal + foot_basis * ANKLE_OFFSET
		if fd > 0.0 and side == fd_side:
			# стопа идёт с педали на землю по дуге наружу и встаёт плоско, носком чуть в сторону
			var ground_basis := Basis.from_euler(Vector3(0.0, -side * 0.22, side * input.ground_lean))
			if not input.ground_up.is_zero_approx():
				ground_basis = Basis(Quaternion(ground_basis.y, input.ground_up.normalized())) * ground_basis
			foot_basis = foot_basis.slerp(ground_basis, fd).orthonormalized()
			foot_pitch *= 1.0 - fd
			ankle_at = ankle_at.lerp(input.ground_point - ground_basis * PEDAL_CONTACT_LOCAL, fd) + Vector3(side * 0.035, 0.05, 0.0) * sin(fd * PI)
		var catch := smoothstep(0.2, 0.9, side * balance) * (1.0 - fd)
		ankle_at += Vector3(side * 0.14, 0.055, -0.055) * catch
		pedal_pitch[i] = foot_pitch * (1.0 - catch)
		_foot_pitch[i] = foot_pitch
		_feet[i] = Transform3D(foot_basis, ankle_at)
	# 2. Положение и ориентация таза: базовая поза + процедурные реакции опоры.
	# В повороте таз смещается к наружной педали и компенсирует наклон рамы, отделяя баланс тела от крена велосипеда.
	var saddle_slide := clampf(motion.x * 0.32 - heavy * 0.014, -0.045, 0.055)
	var stand_shift := motion.x * (0.70 if motion.x > 0.0 else 0.30)
	var hip_shift_z := saddle_slide * seated + stand_shift * standing - rear_load * 0.008
	var hip_crouch_y := clampf(motion.z, -0.04, 0.16) * (0.30 * seated + 0.42 * up + 0.58 * attack)
	var hip_rear_lift := rear_load * (0.010 * seated * (1.0 - clampf(motion.z * 12.0, 0.0, 1.0)) - 0.022 * standing)
	var hip := SADDLE_POS + _base_hip + Vector3(
		motion.y * (0.22 * seated + 0.34 * standing) - roll * 0.022 - drive_side * (0.004 * spin + 0.016 * pedal_up) - sway * 0.20 * up,
		-hip_crouch_y + hip_rear_lift - absf(corner_right) * 0.006 * seated + minf(0.0, saddle_slide) * 0.05 * seated,
		hip_shift_z
	)
	hip += Vector3(fd_side * 0.045, -0.02, -0.185) * fd
	var pelvis_pitch := clampf(_base_pelvis_pitch - 0.08 * tuck - 0.03 * heavy * seated - 0.04 * rear_load, -0.15, 0.09)
	var pelvis_yaw := -sway * (0.28 + 0.12 * heavy) + body_look * 0.12
	var pelvis_roll := fd_side * 0.06 * fd + clampf(-drive_side * (0.016 * spin + 0.042 * heavy + 0.055 * pedal_up) - motion.y * 0.18 - roll * (0.26 + 0.14 * standing), -0.14, 0.14)
	var pelvis_basis := Basis.from_euler(Vector3(pelvis_pitch, pelvis_yaw, pelvis_roll))
	# Подъём таза ограничен анатомической длиной обеих ног с мягким замедлением у предельного разгибания.
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip_offset := pelvis_basis * Vector3(side * 0.11, 0.0, 0.0)
		var ankle := _feet[i].origin
		var horizontal := Vector2(hip.x + hip_offset.x - ankle.x, hip.z + hip_offset.z - ankle.z).length_squared()
		var leg_reach := LEG_LENGTH * 2.0 - 0.004 - (0.012 * fd if side == fd_side else 0.0)
		var max_hip_y := ankle.y - hip_offset.y + sqrt(maxf(0.0, leg_reach * leg_reach - horizontal))
		hip.y = _soft_min(hip.y, max_hip_y, 0.004)
	# 3. Положение корпуса и плеч: базовая поза + реакции, где передний удар (front_load) сначала сжимает руки и подаёт плечи,
	# а в повороте корпус остаётся собранным над пятном контакта отдельно от наклона рамы.
	var effort_brace := heavy * seated * 0.012 + up * 0.008
	var chest := CHEST_POS + _base_chest + Vector3(
		motion.y * 1.08 - roll * 0.032 - drive_side * (0.004 * spin + 0.010 * heavy * seated + 0.016 * pedal_up),
		-tuck * 0.25 - motion.z * 1.15 + breath * 1.15 - effort_brace - front_load * 0.022,
		-tuck * 0.45 - motion.z * 0.45 + motion.x - effort_brace * 0.70 + front_load * 0.024 - maxf(0.0, breath) * 0.35
	)
	chest += Vector3(fd_side * 0.02, 0.035, 0.07) * fd
	chest += Vector3(rest_side * 0.012, 0.02, 0.06) * rest
	chest += Vector3(0.009, 0.018, 0.016) * wrist_view
	# плечо свободной руки уходит назад: корпус чуть разворачивается в её сторону
	var free_yaw := -rest_side * 0.16 * rest + 0.11 * wrist_view
	var spine_len := SPINE_LENGTH + breath * 0.65
	if (chest - hip).length_squared() > 0.000001:
		chest = hip + (chest - hip).normalized() * spine_len
	var upper_basis := Basis.from_euler(Vector3(0.0, body_look * 0.34 + sway * (1.0 + 0.14 * heavy) + free_yaw,-sway * (0.38 + 0.14 * heavy) - motion.y * 0.20 - roll * 0.38))
	# Ограничиваем дальность плеч до руля с сохранением фиксированной длины позвоночника.
	var max_arm_reach := ARM_LENGTH * 2.0 - 0.006
	var max_arm_reach_squared := max_arm_reach * max_arm_reach
	var shoulder_offset := upper_basis.x * 0.18
	var grip_weight := Vector2(1.0 - maxf(rest if rest_side < 0.0 else 0.0, wrist_view),
		1.0 - (rest if rest_side > 0.0 else 0.0))
	const SPINE_PASSES := 4
	for pass_index in SPINE_PASSES + 1:
		var corrected := false
		for i in 2:
			if grip_weight[i] <= 0.0:
				continue
			var shoulder := chest + (-shoulder_offset if i == 0 else shoulder_offset)
			var grip := left_grip if i == 0 else right_grip
			var reach := shoulder - grip
			var squared := reach.length_squared()
			if squared <= max_arm_reach_squared:
				continue
			var distance := sqrt(squared)
			var pull := reach * ((distance - max_arm_reach) / distance * grip_weight[i])
			chest -= pull
			corrected = true
			# Последний проход переносит таз и грудь вместе, если изменения наклона корпуса недостаточно.
			if pass_index == SPINE_PASSES:
				hip -= pull
		if not corrected or pass_index == SPINE_PASSES:
			break
		if (chest - hip).length_squared() > 0.000001:
			chest = hip + (chest - hip).normalized() * spine_len
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip_offset := pelvis_basis * Vector3(side * 0.11, 0.0, 0.0)
		var ankle := _feet[i].origin
		var horizontal := Vector2(hip.x + hip_offset.x - ankle.x, hip.z + hip_offset.z - ankle.z).length_squared()
		var leg_reach := LEG_LENGTH * 2.0 - 0.004 - (0.012 * fd if side == fd_side else 0.0)
		hip.y = minf(hip.y, ankle.y - hip_offset.y + sqrt(maxf(0.0, leg_reach * leg_reach - horizontal)))
	# Взгляд компенсирует склон и крен в пределах движения шеи, опережая поворот корпуса.
	var head_angles := Vector3(clampf(-input.pitch * 0.75 + input.head_nod + gaze.y, -0.36, 0.36),
		clampf(look + gaze.x, -0.6, 0.6), -roll * 0.65 + sway * 0.12 - gaze.x * 0.16)
	_set_bone("Root", Vector3.ZERO)
	_set_bone("Hips", hip, pelvis_basis)
	var spine_dir := (chest - hip).normalized() if (chest - hip).length_squared() > 0.000001 else Vector3.UP
	# 12.11: спина — дуга, а не доска: середина уходит назад-вверх, сильнее в группировке и «атаке»,
	# слабее стоя на педалях и на стоянке (седок выпрямляется).
	var bow := spine_bow * clampf(0.022 + tuck * 0.12 + attack * 0.016 + brake * 0.008 + heavy * seated * 0.008 - up * 0.008 - fd * 0.012 - rest * 0.008, 0.0, 0.05)
	var back_dir := Vector3.BACK - spine_dir * spine_dir.z
	back_dir = back_dir.normalized() if back_dir.length_squared() > 0.0001 else Vector3.BACK
	var chest_base := chest - spine_dir * CHEST_LENGTH + back_dir * bow
	_aim("Spine", hip, chest_base, sway * 0.22 + body_look * 0.14 + free_yaw * 0.4)
	_aim("Chest", chest_base, chest, body_look * 0.34 + sway * (1.0 + 0.14 * heavy) + free_yaw)
	# Основание шеи следует вороту на Chest, а голова вращается через шею с постоянной длиной.
	var chest_pose: Transform3D = _poses[_bones["Chest"]]
	var neck := chest_pose * _neck_anchor
	var wrist_target := chest + upper_basis * Vector3(-0.108, -0.065 + maxf(0.0, breath) * 0.45, -0.39)
	if watch_gaze > 0.0:
		var to_screen := wrist_target + Vector3(0.0, 0.035, 0.025) - (neck + Vector3(0.0, 0.16, -0.11))
		var down := atan2(to_screen.y, Vector2(to_screen.x, to_screen.z).length())
		var toward := atan2(-to_screen.x, -to_screen.z)
		head_angles = head_angles.lerp(Vector3(clampf(down, -0.74, -0.12), clampf(toward, -0.54, 0.54), -0.07), watch_gaze)
	var head_basis := Basis.from_euler(head_angles)
	var neck_basis := chest_pose.basis.slerp(head_basis, 0.55).orthonormalized()
	var head_at := neck + neck_basis * Vector3(0, 0.15, -0.07)
	_set_bone("Neck", neck, neck_basis)
	_set_bone("Head", head_at, head_basis)
	# 4. Решение конечностей от найденного положения таза и грудной клетки.
	var bar_yaw := atan2(left_grip.z - right_grip.z, right_grip.x - left_grip.x)
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var suffix := "L" if side < 0.0 else "R"
		var outer_leg := maxf(0.0, -side * corner_right)
		var inner_leg := maxf(0.0, side * corner_right)
		var h := hip + pelvis_basis * Vector3(side * 0.11, 0.0, 0.0)
		var foot := _feet[i]
		var ankle := foot.origin
		var foot_basis := foot.basis
		var top_phase := -side * crank_top
		var power_phase := maxf(0.0, -side * drive_side)
		# Траектория колена: в фазе нажатия и на наружной ноге в повороте колено приводится к раме (упор в велосипед),
		# а внутреннее колено в повороте, при заднем ударе и в «атаке» открывается наружу для баланса и амортизации.
		var knee_arc := (0.045 + 0.055 * tuck) * maxf(0.0, top_phase) - (0.045 + 0.045 * heavy + 0.035 * pedal_up) * power_phase
		var corner_knee := (0.055 * inner_leg - 0.055 * outer_leg) * (1.0 - spin * 0.5)
		var knee_out := side * (-0.035 + 0.085 * attack + 0.040 * rear_load + 0.020 * up + knee_arc + corner_knee + 0.75 * maxf(0.0, side * balance)) + clampf(motion.y * 0.35 - sway * 0.25 * up, -0.06, 0.06)
		var knee := _joint(h, ankle, LEG_LENGTH, Vector3(knee_out, 0.32 + 0.08 * power_phase, -1.0))
		var leg_x := (ankle - h).cross(knee - h)
		_set_bone("UpperLeg" + suffix, h, _limb_basis(h, knee, leg_x))
		_set_bone("LowerLeg" + suffix, knee, _limb_basis(knee, ankle, leg_x))
		_set_bone("Foot" + suffix, ankle, foot_basis)
		var toe_basis := foot_basis * Basis(Vector3.RIGHT, clampf(-_foot_pitch[i] * 0.35, -0.10, 0.10))
		_set_bone("Toe" + suffix, ankle + foot_basis * TOE_OFFSET, toe_basis)
		var shoulder := chest + upper_basis * Vector3(side * 0.18, maxf(0.0, breath) * 0.45, 0.0)
		var grip := left_grip if side < 0.0 else right_grip
		var free := rest if side == rest_side else 0.0
		if free > 0.0001:
			# На отдыхе кисть лежит на бедре ноги, которая осталась на педали.
			var thigh_dir := (knee - h).normalized()
			var thigh_up := Vector3.UP - thigh_dir * thigh_dir.y
			thigh_up = thigh_up.normalized() if thigh_up.length_squared() > 0.0001 else Vector3.UP
			var target := h.lerp(knee, 0.6) + thigh_up * 0.108 + Vector3(side * 0.015, 0.0, 0.0)
			var to_target := target - shoulder
			if to_target.length() > max_arm_reach:
				target = shoulder + to_target.normalized() * max_arm_reach
			# рука сходит с руля по дуге вверх-наружу, не сквозь грипсу и раму
			grip = grip.lerp(target, free) + Vector3(side * 0.05, 0.05, 0.03) * sin(free * PI)
		# Передний удар (front_load) и сжатие вилки сразу принимают руки (сгиб и вынос локтей),
		# в повороте внутренняя рука сгибает локоть шире, направляя руль, а наружная тянется через корпус.
		var checking_watch := side < 0.0 and wrist_view > 0.0
		if checking_watch:
			# Сначала отрывается от грипсы, затем кисть по дуге приходит к центру.
			grip = grip.lerp(wrist_target, wrist_view) + upper_basis * Vector3(-0.054, 0.058, -0.014) * sin(PI * wrist_view)
			grip = shoulder + (grip - shoulder).limit_length(max_arm_reach)
		var arm_pull := power_phase * (0.22 * heavy + 0.30 * pedal_up)
		var body_compress := motion.z * 2.0
		var arm_compress := clampf(maxf(body_compress, front_load * 0.65 + minf(0.0, body_compress)) + tuck * 0.32, -0.15, 0.95)
		var corner_elbow := 0.10 * inner_leg - 0.06 * outer_leg
		var elbow_pole := Vector3(
			side * (_base_elbow.x + arm_compress * 0.44 - arm_pull * 0.12 + corner_elbow + absf(balance) * 0.30) - sway * 0.22,
			_base_elbow.y + arm_compress * 0.22 - arm_pull * 0.10 + 0.06 * inner_leg,
			0.92
		)
		if checking_watch:
			elbow_pole = elbow_pole.lerp(upper_basis * Vector3(-0.48, -0.86, 0.24), wrist_view)
		var elbow := _joint(shoulder, grip, ARM_LENGTH, elbow_pole)
		var arm_x := (elbow - shoulder).cross(grip - shoulder)
		var arm_basis := _limb_basis(shoulder, elbow, arm_x)
		var neutral_arm := _limb_basis(shoulder, shoulder + chest_pose.basis * Vector3(side * 0.22, -0.68, -0.70), chest_pose.basis.x)
		_set_bone("Clavicle" + suffix, shoulder, neutral_arm.slerp(arm_basis, 0.5).orthonormalized())
		_set_bone("UpperArm" + suffix, shoulder, arm_basis)
		_set_bone("Forearm" + suffix, elbow, _limb_basis(elbow, grip, arm_x))
		var wrist_pitch := clampf(_base_wrist - 0.10 * tuck - 0.08 * front_load - 0.06 * arm_pull, -0.26, 0.16)
		var hand_basis := Basis(Vector3.UP, bar_yaw) * Basis(Vector3.RIGHT, wrist_pitch)
		if free > 0.0001:
			var forearm_basis := _poses[_bones["Forearm" + suffix]].basis
			var loose := forearm_basis * (_hand_rest_l if side < 0.0 else _hand_rest_r)
			hand_basis = hand_basis.slerp(loose.orthonormalized(), free).orthonormalized()
		if checking_watch:
			var wrist_back := (elbow - grip).normalized()
			var screen_right := (head_at + head_basis * Vector3(0, 0.045, -0.07) - grip).cross(wrist_back).normalized()
			if not screen_right.is_zero_approx():
				var screen_up := wrist_back.cross(screen_right)
				var screen_basis := Basis(screen_right, screen_up, wrist_back)
				hand_basis = hand_basis.slerp(screen_basis, wrist_view).orthonormalized()
		_set_bone("Hand" + suffix, grip, hand_basis)


## Смешивание 5 базовых поз с приоритетами: торможение → стоя (подъём / спуск) → сидя (спокойная езда / накат).
func _blend_base_pose(drive_effort: float, up: float, attack: float, brake: float) -> void:
	var w_brake := clampf(brake * 0.75, 0.0, 0.75)
	var w_climb := up * (1.0 - w_brake * 0.70)
	var w_descent := attack * (1.0 - w_brake * 0.35)
	var w_seated := maxf(0.0, 1.0 - w_climb - w_descent - w_brake)
	var calm_t := clampf(drive_effort / 0.55, 0.0, 1.0) * (1.0 - w_brake)
	var w_calm := w_seated * calm_t
	var w_coast := w_seated - w_calm
	var total := maxf(w_coast + w_calm + w_climb + w_descent + w_brake, 0.0001)
	_base_weights[BaseStance.COAST] = w_coast
	_base_weights[BaseStance.CALM] = w_calm
	_base_weights[BaseStance.CLIMB] = w_climb
	_base_weights[BaseStance.DESCENT] = w_descent
	_base_weights[BaseStance.BRAKE] = w_brake
	_base_hip = Vector3.ZERO
	_base_pelvis_pitch = 0.0
	_base_chest = Vector3.ZERO
	_base_elbow = Vector2.ZERO
	_base_wrist = 0.0
	for stance in BASE_POSES:
		var w := _base_weights[stance] / total
		if w == 0.0:
			continue
		var p: Dictionary = BASE_POSES[stance]
		_base_hip += (p.hip as Vector3) * w
		_base_pelvis_pitch += float(p.pelvis_pitch) * w
		_base_chest += (p.chest as Vector3) * w
		_base_elbow += (p.elbow as Vector2) * w
		_base_wrist += float(p.wrist) * w

func _set_bone(bone_name: String, origin: Vector3, basis := Basis.IDENTITY) -> void:
	var index: int = _bones[bone_name]
	var target := Transform3D(basis, origin)
	var parent := _parents[index]
	var local := target
	if parent >= 0:
		local = _poses[parent].affine_inverse() * target
	skeleton.set_bone_pose_position(index, local.origin)
	skeleton.set_bone_pose_rotation(index, local.basis.get_rotation_quaternion())
	_poses[index] = target

func _aim(bone_name: String, a: Vector3, b: Vector3, twist := 0.0) -> void:
	var direction := b - a
	if direction.length_squared() < 0.00000001:
		direction = Vector3.UP
	_set_bone(bone_name, a, Basis(Quaternion(Vector3.UP, direction.normalized())) * Basis(Vector3.UP, twist))

func _limb_basis(a: Vector3, b: Vector3, x_axis: Vector3) -> Basis:
	var direction := b - a
	var y_axis := direction.normalized() if direction.length_squared() > 0.00000001 else Vector3.DOWN
	var x := x_axis - y_axis * x_axis.dot(y_axis)
	if x.length_squared() < 0.00000001:
		var fallback := Vector3.RIGHT if absf(y_axis.x) < 0.9 else Vector3.FORWARD
		x = fallback - y_axis * fallback.dot(y_axis)
	x = x.normalized()
	return Basis(x, y_axis, x.cross(y_axis).normalized())

static func _soft_min(val: float, limit: float, margin: float) -> float:
	if val <= limit - margin or margin <= 0.0:
		return val
	var excess := (val - (limit - margin)) / margin
	return limit - margin + margin * (excess / (1.0 + excess))


func _joint(a: Vector3, b: Vector3, length: float, pole: Vector3) -> Vector3:
	var delta := b - a
	var distance := clampf(delta.length(), 0.001, length * 2 - 0.001)
	var direction := delta.normalized() if delta.length_squared() > 0.00000001 else Vector3.DOWN
	var bend := pole - direction * pole.dot(direction)
	if bend.length_squared() < 0.00000001:
		var fallback := Vector3.RIGHT if absf(direction.x) < 0.9 else Vector3.FORWARD
		bend = fallback - direction * fallback.dot(direction)
	bend = bend.normalized()
	return a + direction * distance * 0.5 + bend * sqrt(length * length - distance * distance * 0.25)
