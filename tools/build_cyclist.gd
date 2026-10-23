extends SceneTree
## Модель v3. Пересборка перезаписывает scenes/cyclist.tscn.
## Один штатный skinned ArrayMesh, прежние 22 кости, без внешних моделей и текстур.
var rider: CyclistRig
var skeleton: Skeleton3D
var rests: Array[Vector3] = []
var surfaces: Dictionary = {}
var navy := material(Color("243747"))
var teal := material(Color("299a9a"))
var panel := material(Color("206c73"))
var skin := material(Color("dba47d"))
var cream := material(Color("f0e5cc"))
var dark := material(Color("17252e"))
var lens := material(Color("315363"), 0.22)
var warm := material(Color("9d6753"))


func material(color: Color, roughness := 0.85) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = roughness
	return result


func _init() -> void:
	rider = CyclistRig.new()
	rider.name = "Rider"
	rider.set_meta("model_version", 3)
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
	root.add_child(rider)
	rider.skeleton = skeleton
	rider.pose(0, 0, Vector3(-0.24, 0.98, -0.43), Vector3(0.24, 0.98, -0.43))
	for i in skeleton.get_bone_count():
		skeleton.set_bone_rest(i, skeleton.get_bone_pose(i))
	_body()
	_head()
	for side in [-1.0, 1.0]:
		_limbs(side)
	var mesh := ArrayMesh.new()
	for mat: Material in surfaces:
		var tool: SurfaceTool = surfaces[mat]
		tool.index()
		tool.commit(mesh)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = mesh
	body.skeleton = NodePath("..")
	body.skin = Skin.new()
	for i in skeleton.get_bone_count():
		body.skin.add_bind(i, skeleton.get_bone_global_rest(i).affine_inverse())
	# Запас для полёта, работы плеч и физической позы: skinned меш не отсекается по старой посадке.
	body.extra_cull_margin = BikeCrash.GROUND_R + 2.0
	skeleton.add_child(body)
	body.owner = rider
	_animation_reset()
	var packed := PackedScene.new()
	var error := packed.pack(rider)
	if error == OK:
		error = ResourceSaver.save(packed, "res://scenes/cyclist.tscn")
	print("Cyclist v3: ", error_string(error), "; surfaces=", mesh.get_surface_count())
	quit(error)


func _body() -> void:
	var hip := skeleton.get_bone_global_pose(skeleton.find_bone("Hips")).origin
	var chest := Vector3(0, 1.37, -0.08)
	var rings: Array[Dictionary] = []
	# Сужение в талии, грудь и линия плеч вместо пересекающихся овалов.
	for spec: Vector3 in [Vector3(0.06, 0.143, 0.099), Vector3(0.32, 0.15, 0.10), Vector3(0.65, 0.175, 0.11), Vector3(0.93, 0.19, 0.105), Vector3(1.03, 0.16, 0.095), Vector3(1.16, 0.064, 0.06)]:
		var t := spec.x
		var lower := "Hips" if t < 0.5 else "Spine"
		var upper := "Spine" if t < 0.5 else "Chest"
		var weight := clampf(t * 2.0 if t < 0.5 else (t - 0.5) * 2.0, 0.0, 1.0)
		rings.append(ring(hip.lerp(chest, t), Basis.IDENTITY, spec.y, spec.z, lower, upper, weight))
	loft(rings, teal, panel)
	local_loft("Hips", [Vector3(0, -0.09, 0), Vector3(0, 0.025, 0), Vector3(0, 0.055, 0)], [Vector2(0.135, 0.09), Vector2(0.15, 0.105), Vector2(0.14, 0.095)], navy)
	ellipsoid("Neck", Vector3(0.052, 0.068, 0.052), Vector3(0, 0, 0.005), skin)
	# Детали лежат на той же поверхности и имеют те же веса: не висят над одеждой.
	patch(rings.slice(0, 5), -PI * 0.5, 0.035, dark)
	patch(rings.slice(3, 5), -PI * 0.5 - 0.42, 0.28, cream)
	patch(rings.slice(3, 5), PI * 0.5, 0.7, cream)
	patch(rings.slice(1, 3), PI * 0.5, 0.68, panel)
	for angle in [PI * 0.5 - 0.24, PI * 0.5 + 0.24]:
		patch(rings.slice(1, 3), angle, 0.018, navy)



func _head() -> void:
	local_loft("Head", [Vector3(0, -0.135, -0.012), Vector3(0, -0.095, -0.012), Vector3(0, -0.025, 0), Vector3(0, 0.065, 0), Vector3(0, 0.115, 0.005)], [Vector2(0.052, 0.06), Vector2(0.08, 0.086), Vector2(0.103, 0.102), Vector2(0.104, 0.094), Vector2(0.078, 0.074)], skin)
	for side in [-1.0, 1.0]:
		ellipsoid("Head", Vector3(0.022, 0.033, 0.018), Vector3(side * 0.105, -0.005, 0.01), skin)
		box("Head", Vector3(0.086, 0.038, 0.026), Vector3(side * 0.048, 0.018, -0.097), dark)
		box("Head", Vector3(0.068, 0.024, 0.01), Vector3(side * 0.048, 0.019, -0.114), lens)
		box("Head", Vector3(0.013, 0.014, 0.1), Vector3(side * 0.102, 0.021, -0.035), dark)
		# Ремни у висков и под подбородком, без отдельного лицевого рига.
		bar("Head", Vector3(side * 0.11, 0.08, 0.025), Vector3(side * 0.06, -0.115, 0.005), 0.009, navy)
	box("Head", Vector3(0.024, 0.012, 0.018), Vector3(0, 0.02, -0.11), dark)
	ellipsoid("Head", Vector3(0.021, 0.033, 0.034), Vector3(0, -0.025, -0.105), skin)
	box("Head", Vector3(0.036, 0.005, 0.006), Vector3(0, -0.076, -0.091), warm)
	local_loft("Head", [Vector3(0, 0.075, -0.012), Vector3(0, 0.11, -0.018), Vector3(0, 0.17, -0.009), Vector3(0, 0.195, 0.005)], [Vector2(0.129, 0.145), Vector2(0.14, 0.16), Vector2(0.105, 0.133), Vector2(0.04, 0.065)], cream)
	box("Head", Vector3(0.23, 0.018, 0.075), Vector3(0, 0.079, -0.146), navy)
	for x in [-0.066, -0.026, 0.026, 0.066]:
		box("Head", Vector3(0.017, 0.01, 0.09), Vector3(x, 0.174 if absf(x) > 0.04 else 0.191, -0.018), dark)
	box("Head", Vector3(0.014, 0.012, 0.12), Vector3(0, 0.195, -0.012), teal)


func _limbs(side: float) -> void:
	var s := "L" if side < 0 else "R"
	limb("UpperArm" + s, "Forearm" + s, [Vector3(0, 0.066, 0.063), Vector3(0.3, 0.074, 0.068), Vector3(0.7, 0.06, 0.058), Vector3(1, 0.049, 0.048)], teal, "", true)
	limb("Forearm" + s, "Hand" + s, [Vector3(0, 0.049, 0.048), Vector3(0.28, 0.052, 0.048), Vector3(0.75, 0.038, 0.036), Vector3(1, 0.031, 0.03)], skin, "UpperArm" + s)
	ellipsoid("Hand" + s, Vector3(0.047, 0.044, 0.056), Vector3(0, 0.0, -0.009), navy)
	ellipsoid("Hand" + s, Vector3(0.019, 0.03, 0.028), Vector3(-side * 0.036, -0.015, -0.018), navy)
	box("Hand" + s, Vector3(0.045, 0.012, 0.027), Vector3(0, 0.04, -0.008), panel)
	limb("UpperLeg" + s, "LowerLeg" + s, [Vector3(0, 0.084, 0.085), Vector3(0.28, 0.087, 0.085), Vector3(0.68, 0.071, 0.07), Vector3(1, 0.055, 0.054)], navy, "", true)
	limb("LowerLeg" + s, "Foot" + s, [Vector3(0, 0.055, 0.054), Vector3(0.3, 0.06, 0.057), Vector3(0.72, 0.042, 0.04), Vector3(1, 0.031, 0.03)], navy, "UpperLeg" + s)
	local_loft("Foot" + s, [Vector3(0, -0.048, -0.035), Vector3(0, -0.033, -0.035)], [Vector2(0.064, 0.124), Vector2(0.065, 0.125)], dark)
	local_loft("Foot" + s, [Vector3(0, -0.033, -0.035), Vector3(0, -0.005, -0.035), Vector3(0, 0.025, -0.015)], [Vector2(0.065, 0.125), Vector2(0.059, 0.105), Vector2(0.034, 0.055)], cream)
	box("Foot" + s, Vector3(0.1, 0.014, 0.026), Vector3(0, 0.013, -0.065), panel)
	box("Foot" + s, Vector3(0.08, 0.012, 0.023), Vector3(0, 0.026, -0.025), navy)


func limb(bone_name: String, next: String, profile: Array, mat: Material, previous := "", blend_end := false) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var end := skeleton.get_bone_global_pose(skeleton.find_bone(next))
	var rings: Array[Dictionary] = []
	for spec: Vector3 in profile:
		var basis := at.basis
		var other := bone_name
		var weight := 0.0
		if not previous.is_empty() and spec.x < 0.2:
			other = previous
			weight = (1.0 - spec.x / 0.2) * 0.5
			basis = at.basis.slerp(skeleton.get_bone_global_pose(skeleton.find_bone(previous)).basis, weight)
		elif blend_end and spec.x > 0.8:
			other = next
			weight = (spec.x - 0.8) / 0.2 * 0.5
			basis = at.basis.slerp(end.basis, weight)
		rings.append(ring(at.origin.lerp(end.origin, spec.x), basis, spec.y, spec.z, bone_name, other, weight))
	loft(rings, mat)


func local_loft(bone_name: String, centers: Array, sizes: Array, mat: Material) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var rings: Array[Dictionary] = []
	for i in centers.size():
		rings.append(ring(at * centers[i], at.basis, sizes[i].x, sizes[i].y, bone_name))
	loft(rings, mat)


func ring(center: Vector3, basis: Basis, rx: float, rz: float, bone_name: String, other := "", weight := 0.0) -> Dictionary:
	var index := skeleton.find_bone(bone_name)
	var other_index := skeleton.find_bone(other) if not other.is_empty() else index
	return {center = center, basis = basis, rx = rx, rz = rz, bones = PackedInt32Array([index, other_index, 0, 0]), weights = PackedFloat32Array([1.0 - weight, weight, 0, 0])}


func point(r: Dictionary, angle: float) -> Dictionary:
	return {position = r.center + r.basis * Vector3(cos(angle) * r.rx, 0, sin(angle) * r.rz), bones = r.bones, weights = r.weights}


func loft(rings: Array[Dictionary], mat: Material, side_mat: Material = null) -> void:
	const SIDES := 12
	for i in rings.size() - 1:
		for j in SIDES:
			var use_mat := side_mat if side_mat != null and j in [0, 5, 6, 11] else mat
			var a := point(rings[i], TAU * j / SIDES)
			var b := point(rings[i + 1], TAU * j / SIDES)
			var c := point(rings[i], TAU * (j + 1) / SIDES)
			var d := point(rings[i + 1], TAU * (j + 1) / SIDES)
			triangle(a, b, c, use_mat)
			triangle(c, b, d, use_mat)
	for end in [0, rings.size() - 1]:
		var center := point(rings[end], 0)
		center.position = rings[end].center
		for j in SIDES:
			var a := point(rings[end], TAU * j / SIDES)
			var b := point(rings[end], TAU * (j + 1) / SIDES)
			triangle(center, a, b, mat) if end == 0 else triangle(center, b, a, mat)


func patch(rings: Array[Dictionary], angle: float, half_width: float, mat: Material) -> void:
	var angles: Array[float] = [angle - half_width]
	# Разбиваем вставку точно по граням тела, иначе широкая хорда провалится внутрь торса.
	for sector in range(floori((angle - half_width) / (TAU / 12.0)) + 1, ceili((angle + half_width) / (TAU / 12.0))):
		angles.append(sector * TAU / 12.0)
	angles.append(angle + half_width)
	for i in rings.size() - 1:
		for j in angles.size() - 1:
			var a := surface_point(rings[i], angles[j])
			var b := surface_point(rings[i + 1], angles[j])
			var c := surface_point(rings[i], angles[j + 1])
			var d := surface_point(rings[i + 1], angles[j + 1])
			triangle(a, b, c, mat)
			triangle(c, b, d, mat)


func surface_point(r: Dictionary, angle: float) -> Dictionary:
	var section := angle / (TAU / 12.0)
	var lower := floorf(section)
	var a := point(r, lower * TAU / 12.0)
	var b := point(r, (lower + 1.0) * TAU / 12.0)
	var position: Vector3 = a.position.lerp(b.position, section - lower)
	a.position = r.center + (position - r.center) * 1.012
	return a


func triangle(a: Dictionary, b: Dictionary, c: Dictionary, mat: Material) -> void:
	var normal: Vector3 = (b.position - a.position).cross(c.position - a.position).normalized()
	if normal.length_squared() < 0.5:
		return
	var tool: SurfaceTool = surfaces.get(mat)
	if tool == null:
		tool = SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		tool.set_material(mat)
		surfaces[mat] = tool
	for vertex: Dictionary in [a, c, b]: # Godot использует обход лицевых треугольников по часовой стрелке.
		tool.set_normal(normal)
		tool.set_bones(vertex.bones)
		tool.set_weights(vertex.weights)
		tool.add_vertex(vertex.position)


func ellipsoid(bone_name: String, size: Vector3, offset: Vector3, mat: Material) -> void:
	var centers: Array[Vector3] = []
	var sizes: Array[Vector2] = []
	for i in 7:
		var angle := -PI * 0.5 + PI * i / 6.0
		centers.append(offset + Vector3(0, sin(angle) * size.y, 0))
		sizes.append(Vector2(size.x, size.z) * maxf(cos(angle), 0.01))
	local_loft(bone_name, centers, sizes, mat)


func box(bone_name: String, size: Vector3, offset: Vector3, mat: Material, basis := Basis.IDENTITY) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var r := ring(at * offset, at.basis, 0, 0, bone_name)
	var vertices: Array[Dictionary] = []
	for corner: Vector3 in [Vector3(-1,-1,-1), Vector3(1,-1,-1), Vector3(1,1,-1), Vector3(-1,1,-1), Vector3(-1,-1,1), Vector3(1,-1,1), Vector3(1,1,1), Vector3(-1,1,1)]:
		vertices.append({position = at * (offset + basis * (corner * size * 0.5)), bones = r.bones, weights = r.weights})
	for face: Array in [[0,3,2,1], [4,5,6,7], [0,4,7,3], [1,2,6,5], [3,7,6,2], [0,1,5,4]]:
		triangle(vertices[face[0]], vertices[face[1]], vertices[face[2]], mat)
		triangle(vertices[face[0]], vertices[face[2]], vertices[face[3]], mat)


func bar(bone_name: String, a: Vector3, b: Vector3, thickness: float, mat: Material) -> void:
	var direction := b - a
	box(bone_name, Vector3(thickness, direction.length(), thickness), (a + b) * 0.5, mat, Basis(Quaternion(Vector3.UP, direction.normalized())))


func bone(bone_name: String, parent: String, origin: Vector3) -> void:
	var index := skeleton.get_bone_count()
	skeleton.add_bone(bone_name)
	var parent_index := skeleton.find_bone(parent)
	skeleton.set_bone_parent(index, parent_index)
	var local := origin - rests[parent_index] if parent_index >= 0 else origin
	skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, local))
	skeleton.set_bone_pose_position(index, local)
	rests.append(origin)


func _animation_reset() -> void:
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	rider.add_child(player)
	player.owner = rider
	var library := AnimationLibrary.new()
	var reset := Animation.new()
	reset.length = 0.0
	library.add_animation("RESET", reset)
	player.add_animation_library("", library)
	for i in skeleton.get_bone_count():
		var path := NodePath("Skeleton3D:" + skeleton.get_bone_name(i))
		var position_track := reset.add_track(Animation.TYPE_POSITION_3D)
		reset.track_set_path(position_track, path)
		reset.position_track_insert_key(position_track, 0, skeleton.get_bone_pose_position(i))
		var rotation_track := reset.add_track(Animation.TYPE_ROTATION_3D)
		reset.track_set_path(rotation_track, path)
		reset.rotation_track_insert_key(rotation_track, 0, skeleton.get_bone_pose_rotation(i))
