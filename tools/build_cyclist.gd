extends SceneTree
## Rebuild the editable native scene: godot --headless --path . --script res://tools/build_cyclist.gd
var rider: Node3D
var skeleton: Skeleton3D
var rests: Array[Vector3] = []
var navy := material(Color("243747"))
var teal := material(Color("299a9a"))
var skin := material(Color("dba47d"))
var cream := material(Color("f0e5cc"))
var dark := material(Color("17252e"))

func material(color: Color) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = 0.85
	return result

func _init() -> void:
	rider = Node3D.new()
	rider.name = "Rider"
	rider.set_script(load("res://scripts/render/cyclist_rig.gd"))
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	rider.add_child(skeleton)
	skeleton.owner = rider
	bone("Root", "", Vector3.ZERO)
	bone("Hips", "Root", Vector3(0, 0.97, 0.17))
	bone("Spine", "Hips", Vector3(0, 1.08, 0.11))
	bone("Chest", "Spine", Vector3(0, 1.3, -0.04))
	bone("Neck", "Chest", Vector3(0, 1.44, -0.1))
	bone("Head", "Neck", Vector3(0, 1.59, -0.17))
	ellipsoid("Hips", Vector3(0.16, 0.12, 0.12), Vector3.ZERO, navy)
	ellipsoid("Spine", Vector3(0.155, 0.21, 0.12), Vector3(0, 0.15, 0), teal)
	ellipsoid("Chest", Vector3(0.205, 0.15, 0.13), Vector3(0, 0.06, 0), teal)
	ellipsoid("Neck", Vector3(0.065, 0.09, 0.065), Vector3.ZERO, skin)
	ellipsoid("Head", Vector3(0.115, 0.145, 0.115), Vector3.ZERO, skin)
	ellipsoid("Head", Vector3(0.14, 0.1, 0.15), Vector3(0, 0.105, 0), cream)
	box("Head", Vector3(0.2, 0.045, 0.05), Vector3(0, 0.025, -0.105), dark)
	box("Head", Vector3(0.055, 0.018, 0.17), Vector3(0, 0.19, -0.015), teal)
	for side in [-1.0, 1.0]:
		var s := "L" if side < 0 else "R"
		bone("Clavicle" + s, "Chest", Vector3(0, 1.37, -0.08))
		bone("UpperArm" + s, "Clavicle" + s, Vector3(side * 0.18, 1.37, -0.08))
		bone("Forearm" + s, "UpperArm" + s, Vector3(side * 0.25, 1.17, -0.2))
		bone("Hand" + s, "Forearm" + s, Vector3(side * 0.24, 0.98, -0.43))
		bone("UpperLeg" + s, "Hips", Vector3(side * 0.11, 0.97, 0.17))
		bone("LowerLeg" + s, "UpperLeg" + s, Vector3(side * 0.14, 0.65, -0.1))
		bone("Foot" + s, "LowerLeg" + s, Vector3(side * 0.14, 0.35, 0.025))
		bone("Toe" + s, "Foot" + s, Vector3(side * 0.14, 0.34, -0.07))
		ellipsoid("UpperArm" + s, Vector3(0.08, 0.08, 0.08), Vector3.ZERO, teal)
		ellipsoid("Forearm" + s, Vector3(0.052, 0.052, 0.052), Vector3.ZERO, skin)
		ellipsoid("LowerLeg" + s, Vector3(0.065, 0.065, 0.065), Vector3.ZERO, navy)
		ellipsoid("UpperArm" + s, Vector3(0.075, 0.18, 0.075), Vector3(0, 0.14, 0), teal)
		ellipsoid("Forearm" + s, Vector3(0.052, 0.175, 0.052), Vector3(0, 0.15, 0), skin)
		ellipsoid("Hand" + s, Vector3(0.052, 0.05, 0.065), Vector3.ZERO, navy)
		ellipsoid("UpperLeg" + s, Vector3(0.095, 0.24, 0.095), Vector3(0, 0.2, 0), navy)
		ellipsoid("LowerLeg" + s, Vector3(0.06, 0.235, 0.06), Vector3(0, 0.21, 0), navy)
		ellipsoid("Foot" + s, Vector3(0.067, 0.048, 0.12), Vector3(0, -0.01, -0.035), cream)
		ellipsoid("Toe" + s, Vector3(0.067, 0.035, 0.065), Vector3(0, 0, -0.015), dark)
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	rider.add_child(player)
	player.owner = rider
	var library := AnimationLibrary.new()
	var reset := Animation.new()
	reset.length = 0.0
	library.add_animation("RESET", reset)
	player.add_animation_library("", library)
	root.add_child(rider)
	rider.skeleton = skeleton
	rider.pose(0, 0, Vector3(-0.24, 0.98, -0.43), Vector3(0.24, 0.98, -0.43))
	# Save the coherent riding pose as the rest pose, editable without running the game.
	for i in skeleton.get_bone_count():
		skeleton.set_bone_rest(i, skeleton.get_bone_pose(i))
		var path := NodePath("Skeleton3D:" + skeleton.get_bone_name(i))
		var position_track := reset.add_track(Animation.TYPE_POSITION_3D)
		reset.track_set_path(position_track, path)
		reset.position_track_insert_key(position_track, 0, skeleton.get_bone_pose_position(i))
		var rotation_track := reset.add_track(Animation.TYPE_ROTATION_3D)
		reset.track_set_path(rotation_track, path)
		reset.rotation_track_insert_key(rotation_track, 0, skeleton.get_bone_pose_rotation(i))
	var packed := PackedScene.new()
	packed.pack(rider)
	var error := ResourceSaver.save(packed, "res://scenes/cyclist.tscn")
	print("Cyclist scene: ", error_string(error))
	quit(error)

func bone(bone_name: String, parent: String, origin: Vector3) -> void:
	var index := skeleton.get_bone_count()
	skeleton.add_bone(bone_name)
	var parent_index := skeleton.find_bone(parent)
	skeleton.set_bone_parent(index, parent_index)
	var local := origin - rests[parent_index] if parent_index >= 0 else origin
	skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, local))
	skeleton.set_bone_pose_position(index, local)
	rests.append(origin)

func attach(bone_name: String, mesh: Mesh, offset: Vector3, mat: Material, scale := Vector3.ONE) -> void:
	var attachment := BoneAttachment3D.new()
	attachment.name = bone_name + "Part" + str(skeleton.get_child_count())
	skeleton.add_child(attachment)
	attachment.owner = rider
	attachment.bone_name = bone_name
	var part := MeshInstance3D.new()
	attachment.add_child(part)
	part.owner = rider
	part.mesh = mesh
	part.material_override = mat
	part.position = offset
	part.scale = scale

func ellipsoid(bone_name: String, size: Vector3, offset: Vector3, mat: Material) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 1
	mesh.height = 2
	mesh.radial_segments = 10
	mesh.rings = 5
	attach(bone_name, mesh, offset, mat, size)

func box(bone_name: String, size: Vector3, offset: Vector3, mat: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	attach(bone_name, mesh, offset, mat)
