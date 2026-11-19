extends SceneTree
## Проверяет настоящий шейдер по площади пикселей: проявление и уход для всех семейств материалов.
const Plants := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
var fails := 0
var camera: Camera3D
var out := "res://.godot/vegetation_fade"

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	if not ok:
		fails += 1

func capture() -> Image:
	for i in 2:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func pixels(shot: Image) -> int:
	var count := 0
	for y in range(0, shot.get_height(), 2):
		for x in range(0, shot.get_width(), 2):
			var col := shot.get_pixel(x, y)
			if maxf(col.r, maxf(col.g, col.b)) > 0.03:
				count += 1
	return count


func form_pixels(shot: Image) -> Vector3i:
	var counts := Vector3i.ZERO
	for y in range(0, shot.get_height(), 2):
		for x in range(0, shot.get_width(), 2):
			var col := shot.get_pixel(x, y)
			if col.r > maxf(col.g, col.b) + 0.03:
				counts.x += 1
			elif col.g > maxf(col.r, col.b) + 0.03:
				counts.y += 1
			elif col.b > maxf(col.r, col.g) + 0.03:
				counts.z += 1
	return counts


func check_form_pair(mesh: Mesh) -> void:
	var nodes: Array[MultiMeshInstance3D] = []
	for form in [1, 2]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D.IDENTITY)
		mm.set_instance_custom_data(0, Color(0, 0, 2, 20))
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		var mat := VegetationLayer._wind_mat(VegetationLayer.SHADER, VegetationLayer.CALM, false)
		mat.set_shader_parameter("albedo_color", Color.RED if form == 1 else Color.GREEN)
		mat.set_shader_parameter("form_switch", Vector3(25, 20, form))
		node.material_override = mat
		root.add_child(node)
		nodes.append(node)
	var center := mesh.get_aabb().get_center()
	camera.size = mesh.get_aabb().size.length() * 1.2
	camera.look_at_from_position(center + Vector3(2, 1.1, -3), center)
	RenderingServer.global_shader_parameter_set("veg_center", Vector2(25, 0))
	RenderingServer.global_shader_parameter_set("vegetation_clock", 20.0)
	var hidden := form_pixels(await capture())
	RenderingServer.global_shader_parameter_set("vegetation_clock", 20.25)
	var half := form_pixels(await capture())
	RenderingServer.global_shader_parameter_set("vegetation_clock", 20.5)
	var full := form_pixels(await capture())
	check(hidden == Vector3i.ZERO and half.x > full.x * 0.4 and half.x < full.x * 0.6
		and half.y > full.y * 0.4 and half.y < full.y * 0.6, "Both LODs reveal together across the blend: %s / %s / %s" % [hidden, half, full])
	RenderingServer.global_shader_parameter_set("veg_center", Vector2.ZERO)
	var near := form_pixels(await capture())
	RenderingServer.global_shader_parameter_set("veg_center", Vector2(50, 0))
	var far := form_pixels(await capture())
	check(near.x > 30 and near.y == 0 and far.x == 0 and far.y > 30, "The shader chooses detailed or distant LOD as the player moves")
	await check_third_form(nodes[1], Plants.meshes()[Plants.MEADOW])
	for node in nodes:
		node.free()


func colored_mesh(mesh: Mesh, color: Color) -> ArrayMesh:
	var arrays := mesh.surface_get_arrays(0)
	var colors := PackedColorArray()
	colors.resize(arrays[Mesh.ARRAY_VERTEX].size())
	colors.fill(color)
	arrays[Mesh.ARRAY_COLOR] = colors
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result


func check_third_form(node: MultiMeshInstance3D, mesh: Mesh) -> void:
	node.multimesh.mesh = Plants.pack_open_lods(colored_mesh(mesh, Color.GREEN), colored_mesh(mesh, Color.BLUE))
	var mat: ShaderMaterial = node.material_override
	mat.set_shader_parameter("albedo_color", Color.WHITE)
	mat.set_shader_parameter("use_vertex_color", true)
	mat.set_shader_parameter("form_group_lod", Vector3(55, 20, mesh.get_aabb().end.y))
	RenderingServer.global_shader_parameter_set("veg_center", Vector2(40, 0))
	var middle := form_pixels(await capture())
	RenderingServer.global_shader_parameter_set("veg_center", Vector2(55, 0))
	var blend := form_pixels(await capture())
	RenderingServer.global_shader_parameter_set("veg_center", Vector2(70, 0))
	var coarse := form_pixels(await capture())
	check(middle.y > 30 and middle.z == 0 and coarse.y == 0 and coarse.z > 30,
		"Only the intended middle or coarse LOD is visible outside the second blend")
	check(blend.x == 0 and blend.y > middle.y * 0.4 and blend.y < middle.y * 0.6
		and blend.z > coarse.z * 0.4 and blend.z < coarse.z * 0.6,
		"The middle and coarse LODs share pixels during the second blend: %s / %s / %s" % [middle, blend, coarse])


func check_carpet_upload(kind: int, label: String) -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var carpet := GroundCarpet.new()
	carpet.setup(parent, WorldData.new(), Heightfield.new(), null)
	var material: ShaderMaterial = carpet.layers[kind * 2].mat
	var mesh: Mesh = carpet.layers[kind * 2].mesh
	var bounds := mesh.get_aabb()
	var center := bounds.get_center()
	camera.size = bounds.size.length() * 1.3
	camera.look_at_from_position(center + Vector3(2.0, 2.2, -3.0), center)
	RenderingServer.global_shader_parameter_set("veg_center", Vector2.ZERO)
	var data := PackedFloat32Array()
	data.resize(GroundCarpet.STRIDE)
	for index in [0, 5, 10, 12, 13, 14, 15]:
		data[index] = 1.0
	material.set_shader_parameter("sway", 0.0)
	material.set_shader_parameter("flutter", 0.0)
	var buckets := []
	for i in carpet.layers.size():
		buckets.append({})
	buckets[kind * 2][Vector2i.ZERO] = {parts = [data], ids = [1], bounds = bounds}
	carpet._prepare_publication(buckets, Vector2.ZERO, Vector2.ZERO, 25.0, false)
	carpet._present_next(30.0)
	var counts := []
	for clock in [30.0, 30.25, 30.5]:
		RenderingServer.global_shader_parameter_set("vegetation_clock", clock)
		counts.append(pixels(await capture()))
	check(counts[0] == 0 and counts[1] > counts[2] * 0.35 and counts[1] < counts[2] * 0.65 and counts[2] > 30,
		"%s fades on the real GPU from the delayed sector upload: %s" % [label, counts])
	carpet.release()
	parent.free()


func run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(640, 480)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color.BLACK
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.8
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -20, 0)
	root.add_child(sun)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	root.add_child(camera)
	camera.current = true
	RenderingServer.global_shader_parameter_set("veg_center", Vector2.ZERO)
	var plants := Plants.meshes()
	var floor_meshes := Floor.meshes()
	var defs := Models.tree_defs()
	var cases := [
		["grass", Models.grass_mesh(), VegetationLayer.SHADER, true],
		["fern", plants[Plants.FERN], VegetationLayer.SHADER, true],
		["bush", plants[Plants.BUSH], VegetationLayer.SHADER, true],
		["young_pine", plants[Plants.YOUNG_PINE], VegetationLayer.SHADER, true],
		["reeds", defs[Biomes.T_REED].crown, VegetationLayer.SHADER, false],
		["log", floor_meshes[Floor.LOG], VegetationLayer.SHADER, true],
		["roots", floor_meshes[Floor.ROOTS], VegetationLayer.SHADER, true],
		["rock", defs[Biomes.T_ROCK].crown, VegetationLayer.SHADER, false],
		["cactus", defs[Biomes.T_CACTUS].trunk, VegetationLayer.TRUNK_SHADER, false],
		["cutout", defs[Biomes.T_OAK].crown, VegetationLayer.CUTOUT_SHADER, false],
	]
	for test: Array in cases:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = test[1]
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D.IDENTITY)
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		var mat := VegetationLayer._wind_mat(test[2], VegetationLayer.CALM, true)
		if test[0] == "cutout":
			mat.set_shader_parameter("albedo_tex", defs[Biomes.T_OAK].crown_texture)
		node.material_override = mat
		root.add_child(node)
		var bounds: AABB = test[1].get_aabb()
		var center := bounds.get_center()
		camera.size = maxf(bounds.size.length() * 1.2, 0.8)
		camera.look_at_from_position(center + Vector3(2, 1.1, -3).normalized() * maxf(5, camera.size * 2), center)
		var counts: Array[int] = []
		for phase in [0.0, 0.25, 0.5]:
			mm.set_instance_custom_data(0, Color(0, 0, 0, 10))
			RenderingServer.global_shader_parameter_set("vegetation_clock", 10.0 + phase)
			var shot := await capture()
			counts.append(pixels(shot))
			shot.save_png(out.path_join("%s_in_%d.png" % [test[0], roundi(phase * 100)]))
		check(counts[0] == 0 and counts[1] > 0 and counts[1] < counts[2] and counts[2] > 30, "%s appears progressively: %s" % [test[0], counts])
		mm.set_instance_custom_data(0, Color(0, 0, 0, -11))
		RenderingServer.global_shader_parameter_set("vegetation_clock", 11.25)
		var half := pixels(await capture())
		RenderingServer.global_shader_parameter_set("vegetation_clock", 11.5)
		var gone := pixels(await capture())
		check(half > 0 and half < counts[2] and gone == 0, "%s dissolves progressively" % test[0])
		node.free()
	await check_form_pair(plants[Plants.BUSH])
	await check_carpet_upload(Models.CARPET_MEADOW, "Ground carpet")
	await check_carpet_upload(Models.CARPET_STONES, "Road gravel")
	print("vegetation_fade_look: %d failures" % fails)
	quit(1 if fails else 0)
