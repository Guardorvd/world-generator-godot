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
const ANKLE_OFFSET := Vector3(0.0, 0.055, 0.025)
const PEDAL_CONTACT_LOCAL := Vector3(0.0, -0.055, -0.025)
const TOE_OFFSET := Vector3(0.0, -0.015, -0.095)
# Базовые позы: положение таза и его наклон, смещение груди (спины), вынос локтей (вбок, вверх) и угол кистей.
const BASE_POSES := {
	"coast": {
		hip = Vector3.ZERO, pelvis_pitch = 0.0,
		chest = Vector3.ZERO, elbow = Vector2(0.42, -0.36), wrist = 0.0,
	},
	"calm": {
		hip = Vector3(0.0, -0.002, -0.008), pelvis_pitch = -0.03,
		chest = Vector3(0.0, -0.010, -0.014), elbow = Vector2(0.46, -0.33), wrist = -0.03,
	},
	"climb": {
		hip = Vector3(0.0, 0.048, -0.145), pelvis_pitch = -0.055,
		chest = Vector3(0.0, -0.018, -0.145), elbow = Vector2(0.56, -0.24), wrist = 0.08,
	},
	"descent": {
		hip = Vector3(0.0, 0.028, 0.024), pelvis_pitch = 0.045,
		chest = Vector3(0.0, -0.034, 0.018), elbow = Vector2(0.76, -0.14), wrist = -0.11,
	},
	"brake": {
		hip = Vector3(0.0, 0.004, 0.034), pelvis_pitch = 0.055,
		chest = Vector3(0.0, -0.026, 0.042), elbow = Vector2(0.64, -0.18), wrist = -0.15,
	},
}
var _bones: Dictionary[String, int] = {}
var _poses: Dictionary[int, Transform3D] = {}
var _rig_checked := false
var _rig_valid := false


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


## stand (12.3): 1 — привстал над седлом и подался вперёд (подъём, рывок), −1 — привстал на спуске
## («атака»: таз над седлом, вес на ногах), 0 — сидит.
## Поза строится от базовых архетипов (накат, спокойная езда, подъём стоя, спуск, торможение)
## с приоритетами над процедурными реакциями и раздельным приёмом переднего (руки) и заднего (ноги, таз) ударов.
func pose(crank_angle: float, tuck: float, left_grip: Vector3, right_grip: Vector3, motion := Vector3.ZERO, look := 0.0, pitch := 0.0, roll := 0.0, sway := 0.0, breath := 0.0, look_lag := 0.0, stand := 0.0, head_nod := 0.0, effort := -1.0, brake := 0.0, front_load := 0.0, rear_load := 0.0, foot_down := 0.0, ground := 0.0, ground_lean := 0.0, gaze := Vector2.ZERO) -> void:
	if not procedural_pose:
		return
	if not is_rig_valid():
		return
	if not left_grip.is_finite() or not right_grip.is_finite() or not motion.is_finite():
		return
	if not is_finite(crank_angle) or not is_finite(tuck) or not is_finite(look) or not is_finite(pitch) or not is_finite(roll) or not is_finite(sway) or not is_finite(breath) or not is_finite(look_lag) or not is_finite(stand) or not is_finite(head_nod) or not is_finite(effort) or not is_finite(brake) or not is_finite(front_load) or not is_finite(rear_load):
		return
	if not is_finite(foot_down) or not is_finite(ground) or not is_finite(ground_lean) or not gaze.is_finite():
		return
	_poses.clear()
	# 11.11: стоянка — нога fd_side стоит на земле (ground — высота земли в осях велосипеда, ground_lean — его наклон к ноге)
	var fd := smoothstep(0.0, 1.0, clampf(absf(foot_down), 0.0, 1.0))
	var fd_side := -1.0 if foot_down < 0.0 else 1.0
	sway = clampf(sway, -0.13, 0.13)
	breath = clampf(breath, -0.004, 0.004)
	stand = clampf(stand, -1.0, 1.0)
	brake = clampf(brake, 0.0, 1.0)
	front_load = clampf(front_load, 0.0, 1.0)
	rear_load = clampf(rear_load, 0.0, 1.0)
	var up := maxf(stand, 0.0)
	var attack := maxf(-stand, 0.0)
	var standing := clampf(up + attack, 0.0, 1.0)
	var seated := 1.0 - standing
	var raw_effort := clampf(effort if effort >= 0.0 else (absf(sway) / 0.055 if absf(sway) > 0.0001 else up * 0.8), 0.0, 1.25)
	# Приоритеты: торможение и приём удара подавляют педалирование, чтобы они не складывались в случайную позу.
	var shock := clampf(front_load * 0.65 + rear_load * 0.75, 0.0, 1.0)
	var pedal_priority := (1.0 - brake * 0.85) * (1.0 - shock * 0.60)
	var drive_effort := raw_effort * pedal_priority
	var spin := clampf(drive_effort / 0.65, 0.0, 1.0) * seated
	var heavy := smoothstep(0.55, 1.05, drive_effort)
	var drive_side := sin(crank_angle)
	var double_pulse := 1.0 - cos(crank_angle * 2.0)
	var body_look := look + look_lag
	# Поворот: отделяем наклон велосипеда (roll) от положения тела и выделяем наружную/внутреннюю сторону.
	var corner_right := clampf(-roll * 2.2 + motion.y * 6.5 - look * 0.55, -1.0, 1.0)
	var base := _blend_base_pose(drive_effort, up, attack, brake)
	# 1. Опора стоп на педали: стопа качается вокруг точки контакта с педалью, смещая голеностоп.
	# Задний удар и приземление (rear_load), а также упор наружной ногой в повороте опускают пятку вниз.
	var ankles: Dictionary[float, Vector3] = {}
	var foot_bases: Dictionary[float, Basis] = {}
	var foot_pitches: Dictionary[float, float] = {}
	for side: float in [-1.0, 1.0]:
		var outer_leg := maxf(0.0, -side * corner_right)
		var inner_leg := maxf(0.0, side * corner_right)
		var pedal := Vector3(side * 0.14, 0.3 - side * cos(-crank_angle) * 0.17, -side * sin(-crank_angle) * 0.17)
		var top_phase := -side * cos(crank_angle)
		var down_phase := -side * sin(crank_angle)
		var power_phase := maxf(0.0, down_phase)
		var bottom_scrape := maxf(0.0, -top_phase) * smoothstep(-0.4, 0.5, down_phase)
		var spin_pitch := (0.06 * top_phase - 0.11 * maxf(0.0, -top_phase) - 0.05 * down_phase) * spin
		var heavy_pitch := (0.16 * power_phase - 0.13 * bottom_scrape) * heavy * seated
		var stand_pitch := (-0.04 + 0.14 * power_phase - 0.18 * maxf(0.0, -top_phase)) * up
		var corner_pitch := (0.14 * outer_leg - 0.05 * inner_leg) * (1.0 - spin * 0.55)
		var brace_pitch := 0.14 * attack + 0.12 * rear_load + 0.07 * clampf(motion.z * 3.0, 0.0, 1.0) + 0.04 * brake + corner_pitch + 0.04 * top_phase * (1.0 - clampf(drive_effort, 0.0, 1.0))
		var foot_pitch := clampf(spin_pitch + heavy_pitch + stand_pitch + brace_pitch, -0.28, 0.26)
		var foot_yaw := -side * (0.026 - 0.010 * power_phase * (heavy + up * 0.5) + 0.012 * inner_leg)
		var foot_roll := -side * (0.022 * power_phase * (heavy + up * 0.7) + 0.032 * outer_leg)
		var foot_basis := Basis.from_euler(Vector3(foot_pitch, foot_yaw, foot_roll))
		var ankle_at := pedal + foot_basis * ANKLE_OFFSET
		if fd > 0.0 and side == fd_side:
			# стопа идёт с педали на землю по дуге наружу и встаёт плоско, носком чуть в сторону
			var ground_basis := Basis.from_euler(Vector3(0.0, -side * 0.22, side * ground_lean))
			var contact := Vector3(side * 0.27, ground + 0.27 * tan(ground_lean) * fd, -0.06)
			foot_basis = foot_basis.slerp(ground_basis, fd).orthonormalized()
			foot_pitch *= 1.0 - fd
			ankle_at = ankle_at.lerp(contact - ground_basis * PEDAL_CONTACT_LOCAL, fd) + Vector3(side * 0.035, 0.05, 0.0) * sin(fd * PI)
		foot_pitches[side] = foot_pitch
		foot_bases[side] = foot_basis
		ankles[side] = ankle_at
	# 2. Положение и ориентация таза: базовая поза + процедурные реакции опоры.
	# В повороте таз смещается к наружной педали и компенсирует наклон рамы, отделяя баланс тела от крена велосипеда.
	var saddle_slide := clampf(motion.x * 0.32 - heavy * 0.014, -0.045, 0.055)
	var stand_shift := motion.x * (0.70 if motion.x > 0.0 else 0.30)
	var hip_shift_z := saddle_slide * seated + stand_shift * standing - rear_load * 0.008
	var hip_crouch_y := clampf(motion.z, -0.04, 0.16) * (0.30 * seated + 0.42 * up + 0.58 * attack)
	var hip_rear_lift := rear_load * (0.010 * seated * (1.0 - clampf(motion.z * 12.0, 0.0, 1.0)) - 0.022 * standing)
	var hip := SADDLE_POS + (base.hip as Vector3) + Vector3(
		motion.y * (0.22 * seated + 0.34 * standing) - roll * 0.022 - drive_side * 0.004 * spin - (sway * 0.20 + drive_side * 0.016) * up,
		-hip_crouch_y + hip_rear_lift - absf(corner_right) * 0.006 * seated - double_pulse * (drive_effort * 0.002 * seated + 0.006 * up) + minf(0.0, saddle_slide) * 0.05 * seated,
		hip_shift_z
	)
	hip += Vector3(fd_side * 0.045, -0.02, -0.185) * fd
	var pelvis_pitch := clampf(float(base.pelvis_pitch) - 0.08 * tuck - 0.03 * heavy * seated - 0.04 * rear_load, -0.15, 0.09)
	var pelvis_yaw := -sway * (0.28 + 0.12 * heavy) + body_look * 0.12
	var pelvis_roll := fd_side * 0.06 * fd + clampf(-drive_side * (0.016 * spin + 0.042 * heavy + 0.055 * up) - motion.y * 0.18 - roll * (0.26 + 0.14 * standing), -0.14, 0.14)
	var pelvis_basis := Basis.from_euler(Vector3(pelvis_pitch, pelvis_yaw, pelvis_roll))
	# Подъём таза ограничен анатомической длиной обеих ног до реального положения голеностопа.
	for side: float in [-1.0, 1.0]:
		var hip_offset := pelvis_basis * Vector3(side * 0.11, 0.0, 0.0)
		var ankle: Vector3 = ankles[side]
		var horizontal := Vector2(hip.x + hip_offset.x - ankle.x, hip.z + hip_offset.z - ankle.z).length_squared()
		var leg_reach := LEG_LENGTH * 2.0 - 0.004 - (0.012 * fd if side == fd_side else 0.0)
		hip.y = minf(hip.y, ankle.y - hip_offset.y + sqrt(maxf(0.0, leg_reach * leg_reach - horizontal)))
	# 3. Положение корпуса и плеч: базовая поза + реакции, где передний удар (front_load) сначала сжимает руки и подаёт плечи,
	# а в повороте корпус остаётся собранным над пятном контакта отдельно от наклона рамы.
	var effort_brace := heavy * seated * 0.012 + up * 0.008
	var chest := CHEST_POS + (base.chest as Vector3) + Vector3(
		motion.y * 1.08 - roll * 0.032 - drive_side * (0.004 * spin + 0.010 * heavy * seated + 0.016 * up),
		-tuck * 0.25 - motion.z * 1.15 + breath * 1.15 - effort_brace - front_load * 0.022,
		-tuck * 0.45 - motion.z * 0.45 + motion.x - effort_brace * 0.70 + front_load * 0.024 - maxf(0.0, breath) * 0.35
	)
	chest += Vector3(fd_side * 0.02, 0.035, 0.07) * fd
	var spine_len := SPINE_LENGTH + breath * 0.65
	if (chest - hip).length_squared() > 0.000001:
		chest = hip + (chest - hip).normalized() * spine_len
	var upper_basis := Basis.from_euler(Vector3(0.0, body_look * 0.34 + sway * (1.0 + 0.14 * heavy), -sway * (0.38 + 0.14 * heavy) - motion.y * 0.20 - roll * 0.38))
	# Ограничиваем дальность плеч до руля с сохранением фиксированной длины позвоночника.
	var max_arm_reach := ARM_LENGTH * 2.0 - 0.006
	for i in 4:
		for side: float in [-1.0, 1.0]:
			var shoulder := chest + upper_basis * Vector3(side * 0.18, 0.0, 0.0)
			var grip := left_grip if side < 0.0 else right_grip
			var reach := shoulder - grip
			if reach.length() > max_arm_reach:
				chest -= reach.normalized() * (reach.length() - max_arm_reach)
		if (chest - hip).length_squared() > 0.000001:
			chest = hip + (chest - hip).normalized() * spine_len
	for side: float in [-1.0, 1.0]:
		var shoulder := chest + upper_basis * Vector3(side * 0.18, 0.0, 0.0)
		var grip := left_grip if side < 0.0 else right_grip
		var reach := shoulder - grip
		if reach.length() > max_arm_reach:
			var pull := reach.normalized() * (reach.length() - max_arm_reach)
			chest -= pull
			hip -= pull
	# Взгляд компенсирует склон и крен в пределах движения шеи, опережая поворот корпуса.
	var head_basis := Basis.from_euler(Vector3(clampf(-pitch * 0.75 + head_nod + gaze.y, -0.36, 0.36), clampf(look + gaze.x, -0.6, 0.6), -roll * 0.65 + sway * 0.12))
	_set_bone("Root", Vector3.ZERO)
	_set_bone("Hips", hip, pelvis_basis)
	_aim("Spine", hip, chest, sway * 0.22 + body_look * 0.14)
	var spine_dir := (chest - hip).normalized() if (chest - hip).length_squared() > 0.000001 else Vector3.UP
	_aim("Chest", chest - spine_dir * CHEST_LENGTH, chest, body_look * 0.34 + sway * (1.0 + 0.14 * heavy))
	# Основание шеи следует вороту на Chest, а голова вращается через шею с постоянной длиной.
	var chest_pose: Transform3D = _poses[_bones["Chest"]]
	var rest_hip := Vector3(0, 0.97, 0.17)
	var rest_chest := Vector3(0, 1.37, -0.08)
	var rest_upper := Transform3D(Basis(Quaternion(Vector3.UP, (rest_chest - rest_hip).normalized())), rest_hip.lerp(rest_chest, 0.55))
	var neck := chest_pose * (rest_upper.affine_inverse() * Vector3(0, 1.44, -0.1))
	var neck_basis := chest_pose.basis.slerp(head_basis, 0.55).orthonormalized()
	_set_bone("Neck", neck, neck_basis)
	_set_bone("Head", neck + neck_basis * Vector3(0, 0.15, -0.07), head_basis)
	# 4. Решение конечностей от найденного положения таза и грудной клетки.
	var base_elbow: Vector2 = base.elbow
	var base_wrist: float = base.wrist
	for side: float in [-1.0, 1.0]:
		var suffix := "L" if side < 0.0 else "R"
		var outer_leg := maxf(0.0, -side * corner_right)
		var inner_leg := maxf(0.0, side * corner_right)
		var h := hip + pelvis_basis * Vector3(side * 0.11, 0.0, 0.0)
		var ankle: Vector3 = ankles[side]
		var foot_basis: Basis = foot_bases[side]
		var foot_pitch: float = foot_pitches[side]
		var top_phase := -side * cos(crank_angle)
		var down_phase := -side * sin(crank_angle)
		var power_phase := maxf(0.0, down_phase)
		# Траектория колена: в фазе нажатия и на наружной ноге в повороте колено приводится к раме (упор в велосипед),
		# а внутреннее колено в повороте, при заднем ударе и в «атаке» открывается наружу для баланса и амортизации.
		var knee_arc := (0.045 + 0.055 * tuck) * maxf(0.0, top_phase) - (0.045 + 0.045 * heavy + 0.035 * up) * power_phase
		var corner_knee := (0.055 * inner_leg - 0.055 * outer_leg) * (1.0 - spin * 0.5)
		var knee_out := side * (-0.035 + 0.085 * attack + 0.040 * rear_load + 0.020 * up + knee_arc + corner_knee) + clampf(motion.y * 0.35 - sway * 0.25 * up, -0.06, 0.06)
		var knee := _joint(h, ankle, LEG_LENGTH, Vector3(knee_out, 0.32 + 0.08 * power_phase, -1.0))
		var leg_x := (ankle - h).cross(knee - h)
		_set_bone("UpperLeg" + suffix, h, _limb_basis(h, knee, leg_x))
		_set_bone("LowerLeg" + suffix, knee, _limb_basis(knee, ankle, leg_x))
		_set_bone("Foot" + suffix, ankle, foot_basis)
		var toe_basis := foot_basis * Basis(Vector3.RIGHT, clampf(-foot_pitch * 0.35, -0.10, 0.10))
		_set_bone("Toe" + suffix, ankle + foot_basis * TOE_OFFSET, toe_basis)
		var shoulder := chest + upper_basis * Vector3(side * 0.18, maxf(0.0, breath) * 0.45, 0.0)
		var grip := left_grip if side < 0.0 else right_grip
		# Передний удар (front_load) и сжатие вилки сразу принимают руки (сгиб и вынос локтей),
		# в повороте внутренняя рука сгибает локоть шире, направляя руль, а наружная тянется через корпус.
		var arm_pull := power_phase * (0.22 * heavy + 0.30 * up) * (1.0 - brake * 0.85)
		var arm_compress := clampf(motion.z * 2.0 + front_load * 0.65 + tuck * 0.32, -0.15, 0.95)
		var corner_elbow := 0.10 * inner_leg - 0.06 * outer_leg
		var elbow_pole := Vector3(
			side * (base_elbow.x + arm_compress * 0.44 - arm_pull * 0.12 + corner_elbow) - sway * 0.22,
			base_elbow.y + arm_compress * 0.22 - arm_pull * 0.10 + 0.06 * inner_leg,
			0.92
		)
		var elbow := _joint(shoulder, grip, ARM_LENGTH, elbow_pole)
		var arm_x := (elbow - shoulder).cross(grip - shoulder)
		var arm_basis := _limb_basis(shoulder, elbow, arm_x)
		var neutral_arm := _limb_basis(shoulder, shoulder + chest_pose.basis * Vector3(side * 0.22, -0.68, -0.70), chest_pose.basis.x)
		_set_bone("Clavicle" + suffix, shoulder, neutral_arm.slerp(arm_basis, 0.5).orthonormalized())
		_set_bone("UpperArm" + suffix, shoulder, arm_basis)
		_set_bone("Forearm" + suffix, elbow, _limb_basis(elbow, grip, arm_x))
		var bar_yaw := atan2(-(right_grip - left_grip).z, (right_grip - left_grip).x)
		var wrist_pitch := clampf(base_wrist - 0.10 * tuck - 0.08 * front_load - 0.06 * arm_pull, -0.26, 0.16)
		_set_bone("Hand" + suffix, grip, Basis(Vector3.UP, bar_yaw) * Basis(Vector3.RIGHT, wrist_pitch))


## Смешивание 5 базовых поз с приоритетами: торможение → стоя (подъём / спуск) → сидя (спокойная езда / накат).
func _blend_base_pose(drive_effort: float, up: float, attack: float, brake: float) -> Dictionary:
	var w_brake := clampf(brake * 0.75, 0.0, 0.75)
	var w_climb := up * (1.0 - w_brake * 0.70)
	var w_descent := attack * (1.0 - w_brake * 0.35)
	var w_seated := maxf(0.0, 1.0 - w_climb - w_descent - w_brake)
	var calm_t := clampf(drive_effort / 0.55, 0.0, 1.0) * (1.0 - w_brake)
	var w_calm := w_seated * calm_t
	var w_coast := w_seated - w_calm
	var total := maxf(w_coast + w_calm + w_climb + w_descent + w_brake, 0.0001)
	var weights := {
		"coast": w_coast / total,
		"calm": w_calm / total,
		"climb": w_climb / total,
		"descent": w_descent / total,
		"brake": w_brake / total,
	}
	var hip := Vector3.ZERO
	var pelvis_pitch := 0.0
	var chest := Vector3.ZERO
	var elbow := Vector2.ZERO
	var wrist := 0.0
	for key: String in weights:
		var w: float = weights[key]
		var p: Dictionary = BASE_POSES[key]
		hip += (p.hip as Vector3) * w
		pelvis_pitch += float(p.pelvis_pitch) * w
		chest += (p.chest as Vector3) * w
		elbow += (p.elbow as Vector2) * w
		wrist += float(p.wrist) * w
	return {hip = hip, pelvis_pitch = pelvis_pitch, chest = chest, elbow = elbow, wrist = wrist, weights = weights}

func _set_bone(bone_name: String, origin: Vector3, basis := Basis.IDENTITY) -> void:
	var index: int = _bones[bone_name]
	var target := Transform3D(basis, origin)
	var parent := skeleton.get_bone_parent(index)
	var local := target
	if parent >= 0:
		local = (_poses[parent] as Transform3D).affine_inverse() * target
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
