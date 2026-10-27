extends SceneTree
## Проверяет настоящий шейдер по площади пикселей: проявление и уход для всех семейств материалов.
const Plants := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
var fails := 0
var camera: Camera3D
var out := "res://.godot/vegetation_fade"

func _initialize() -> void:
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
		mat.set_shader_parameter("stream_instances", test[3])
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
			mat.set_shader_parameter("stream_birth", 10.0)
			mm.set_instance_custom_data(0, Color(0, 0, 0, 10))
			RenderingServer.global_shader_parameter_set("vegetation_clock", 10.0 + phase)
			var shot := await capture()
			counts.append(pixels(shot))
			shot.save_png(out.path_join("%s_in_%d.png" % [test[0], roundi(phase * 100)]))
		check(counts[0] == 0 and counts[1] > 0 and counts[1] < counts[2] and counts[2] > 30, "%s appears progressively: %s" % [test[0], counts])
		mat.set_shader_parameter("stream_birth", -11.0)
		mm.set_instance_custom_data(0, Color(0, 0, 0, -11))
		RenderingServer.global_shader_parameter_set("vegetation_clock", 11.25)
		var half := pixels(await capture())
		RenderingServer.global_shader_parameter_set("vegetation_clock", 11.5)
		var gone := pixels(await capture())
		check(half > 0 and half < counts[2] and gone == 0, "%s dissolves progressively" % test[0])
		node.free()
	print("vegetation_fade_look: %d failures" % fails)
	quit(1 if fails else 0)
