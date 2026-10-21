class_name CyclistRig
extends Node3D
## Native rigid low-poly rig. Disable procedural_pose to animate bone tracks normally.
@export var procedural_pose := true
@onready var skeleton: Skeleton3D = $Skeleton3D
var _poses: Dictionary = {}

func pose(crank_angle: float, tuck: float, left_grip: Vector3, right_grip: Vector3) -> void:
	if not procedural_pose:
		return
	_poses.clear()
	var hip := Vector3(0, 0.97, 0.17)
	var chest := Vector3(0, 1.37 - tuck * 0.25, -0.08 - tuck * 0.45)
	_set_bone("Root", Vector3.ZERO)
	_set_bone("Hips", hip)
	_aim("Spine", hip, chest)
	_aim("Chest", hip.lerp(chest, 0.55), chest)
	_set_bone("Neck", chest + Vector3(0, 0.07, -0.02))
	_set_bone("Head", Vector3(0, 1.59 - tuck * 0.3, -0.17 - tuck * 0.3))
	for side in [-1.0, 1.0]:
		var suffix := "L" if side < 0 else "R"
		var foot := Vector3(side * 0.14, 0.3 - side * cos(-crank_angle) * 0.17, -side * sin(-crank_angle) * 0.17)
		var h := hip + Vector3(side * 0.11, 0, 0)
		var ankle := foot + Vector3(0, 0.055, 0.025)
		var knee := _joint(h, ankle, 0.43, Vector3(0, 0.3, -1))
		_aim("UpperLeg" + suffix, h, knee)
		_aim("LowerLeg" + suffix, knee, ankle)
		_set_bone("Foot" + suffix, ankle)
		_set_bone("Toe" + suffix, foot + Vector3(0, 0.04, -0.07))
		var shoulder := chest + Vector3(side * 0.18, 0, 0)
		var grip := left_grip if side < 0 else right_grip
		_set_bone("Clavicle" + suffix, chest)
		var elbow := _joint(shoulder, grip, 0.31, Vector3(side * 0.6, 0, 1))
		_aim("UpperArm" + suffix, shoulder, elbow)
		_aim("Forearm" + suffix, elbow, grip)
		_set_bone("Hand" + suffix, grip)

func _set_bone(bone_name: String, origin: Vector3, basis := Basis.IDENTITY) -> void:
	var index := skeleton.find_bone(bone_name)
	var target := Transform3D(basis, origin)
	var parent := skeleton.get_bone_parent(index)
	var local := target
	if parent >= 0:
		local = (_poses[parent] as Transform3D).affine_inverse() * target
	skeleton.set_bone_pose_position(index, local.origin)
	skeleton.set_bone_pose_rotation(index, local.basis.get_rotation_quaternion())
	_poses[index] = target

func _aim(bone_name: String, a: Vector3, b: Vector3) -> void:
	_set_bone(bone_name, a, Basis(Quaternion(Vector3.UP, (b - a).normalized())))

func _joint(a: Vector3, b: Vector3, length: float, pole: Vector3) -> Vector3:
	var delta := b - a
	var distance := clampf(delta.length(), 0.001, length * 2 - 0.001)
	var direction := delta.normalized()
	var bend := (pole - direction * pole.dot(direction)).normalized()
	return a + direction * distance * 0.5 + bend * sqrt(length * length - distance * distance * 0.25)
