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
func pose(crank_angle: float, tuck: float, left_grip: Vector3, right_grip: Vector3, motion := Vector3.ZERO, look := 0.0, pitch := 0.0, roll := 0.0, sway := 0.0, breath := 0.0, look_lag := 0.0, stand := 0.0, head_nod := 0.0) -> void:
	if not procedural_pose:
		return
	if not is_rig_valid():
		return
	if not left_grip.is_finite() or not right_grip.is_finite() or not motion.is_finite():
		return
	if not is_finite(crank_angle) or not is_finite(tuck) or not is_finite(look) or not is_finite(pitch) or not is_finite(roll) or not is_finite(sway) or not is_finite(breath) or not is_finite(look_lag) or not is_finite(stand) or not is_finite(head_nod):
		return
	_poses.clear()
	sway = clampf(sway, -0.13, 0.13)
	breath = clampf(breath, -0.004, 0.004)
	stand = clampf(stand, -1.0, 1.0)
	var up := maxf(stand, 0.0)
	var attack := maxf(-stand, 0.0)
	# motion: fore/aft shift, lateral balance, compression. Keep reach within limb lengths.
	# Стоя таз выше и над кареткой (нога внизу почти прямая), плечи ближе к рулю, таз ходит в такт педалям.
	# Сидя таз держится над седлом; подвеску принимает корпус, а не проваливающийся в седло таз.
	var hip_shift := motion.x * (0.7 if motion.x > 0.0 else 0.25)
	var hip := Vector3(motion.y * 0.25 - sway * 0.2 * up, 1.015 - motion.z * 0.45 + up * 0.045 + attack * 0.025, 0.20 + hip_shift - up * 0.14)
	# Подъём таза ограничен длиной обеих ног до педалей, без растягивания голени в нижней точке.
	for side in [-1.0, 1.0]:
		var ankle := Vector3(side * 0.14, 0.355 - side * cos(-crank_angle) * 0.17, 0.025 - side * sin(-crank_angle) * 0.17)
		var horizontal := Vector2(hip.x + side * 0.11 - ankle.x, hip.z - ankle.z).length_squared()
		hip.y = minf(hip.y, ankle.y + sqrt(maxf(0.0, pow(LEG_LENGTH * 2.0 - 0.004, 2.0) - horizontal)))
	var chest := Vector3(motion.y, 1.37 - tuck * 0.25 - motion.z + breath - up * 0.015 - attack * 0.03, -0.08 - tuck * 0.45 + motion.x - up * 0.14)
	var body_look := look + look_lag
	var upper_basis := Basis.from_euler(Vector3(0.0, body_look * 0.3 + sway, -sway * 0.4))
	# Сильный тормоз выпрямляет руки. Ограничиваем дальность плеч до IK,
	# чтобы компенсация назад не растягивала предплечья при повёрнутом руле.
	for i in 3:
		for side in [-1.0, 1.0]:
			var shoulder := chest + upper_basis * Vector3(side * 0.18, 0, 0)
			var grip := left_grip if side < 0 else right_grip
			var reach := shoulder - grip
			if reach.length() > ARM_LENGTH * 2.0 - 0.006:
				chest -= reach.normalized() * (reach.length() - (ARM_LENGTH * 2.0 - 0.006))
	# Взгляд компенсирует склон в пределах движения шеи, сохраняя небольшой наклон по дороге.
	var head_basis := Basis.from_euler(Vector3(clampf(-pitch * 0.75 + head_nod, -0.36, 0.36), clampf(look, -0.5, 0.5), -roll * 0.6 + sway * 0.12))
	_set_bone("Root", Vector3.ZERO)
	_set_bone("Hips", hip, Basis(Vector3.UP, -sway * 0.3))
	_aim("Spine", hip, chest, sway * 0.25)
	_aim("Chest", hip.lerp(chest, 0.55), chest, body_look * 0.3 + sway)
	# Основание шеи следует вороту на Chest, а голова вращается через шею с постоянной длиной.
	# Отдельные смещения головы раньше растягивали кожу и вдавливали подбородок в ворот на подъёме.
	var chest_pose: Transform3D = _poses[_bones["Chest"]]
	var rest_hip := Vector3(0, 0.97, 0.17)
	var rest_chest := Vector3(0, 1.37, -0.08)
	var rest_upper := Transform3D(Basis(Quaternion(Vector3.UP, (rest_chest - rest_hip).normalized())), rest_hip.lerp(rest_chest, 0.55))
	var neck := chest_pose * (rest_upper.affine_inverse() * Vector3(0, 1.44, -0.1))
	var neck_basis := chest_pose.basis.slerp(head_basis, 0.55).orthonormalized()
	_set_bone("Neck", neck, neck_basis)
	_set_bone("Head", neck + neck_basis * Vector3(0, 0.15, -0.07), head_basis)
	for side in [-1.0, 1.0]:
		var suffix := "L" if side < 0 else "R"
		var foot := Vector3(side * 0.14, 0.3 - side * cos(-crank_angle) * 0.17, -side * sin(-crank_angle) * 0.17)
		var h := hip + Vector3(side * 0.11, 0, 0)
		var ankle := foot + Vector3(0, 0.055, 0.025)
		var knee := _joint(h, ankle, LEG_LENGTH, Vector3(0, 0.3, -1))
		_aim("UpperLeg" + suffix, h, knee)
		_aim("LowerLeg" + suffix, knee, ankle)
		_set_bone("Foot" + suffix, ankle)
		_set_bone("Toe" + suffix, foot + Vector3(0, 0.04, -0.07))
		var shoulder := chest + upper_basis * Vector3(side * 0.18, 0, 0)
		var grip := left_grip if side < 0 else right_grip
		_set_bone("Clavicle" + suffix, chest)
		var elbow := _joint(shoulder, grip, ARM_LENGTH, Vector3(side * (0.6 + motion.z * 2.0), 0, 1))
		_aim("UpperArm" + suffix, shoulder, elbow)
		_aim("Forearm" + suffix, elbow, grip)
		_set_bone("Hand" + suffix, grip, Basis(Vector3.UP, atan2(-(right_grip - left_grip).z, (right_grip - left_grip).x)))

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
