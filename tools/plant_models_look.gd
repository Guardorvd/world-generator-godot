extends SceneTree
## Изолированные витрины видов и пучков травы; снимки пишутся в .godot/plant_review.
const OUT := "res://.godot/plant_review"
var camera: Camera3D
var stand: Node3D
var lod := -1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Для витрины нужен графический рендерер")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(OUT)
	var args := OS.get_cmdline_user_args()
	var lod_arg := args.find("--lod")
	if lod_arg >= 0 and lod_arg + 1 < args.size():
		lod = clampi(int(args[lod_arg + 1]), 0, 2)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b9ced2")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("e5e6d7")
	env.environment.ambient_light_energy = 0.8
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	ground.mesh = plane
	var soil := StandardMaterial3D.new()
	soil.albedo_color = Color("738357")
	ground.material_override = soil
	root.add_child(ground)
	stand = Node3D.new()
	root.add_child(stand)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.current = true
	camera.fov = 42.0
	for kind: int in [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_JUNGLE, Biomes.T_PALM, Biomes.T_ACACIA]:
		_clear()
		for variant in ForestModels.VARIANTS:
			var def := ForestModels.definition(kind, variant)
			for part: String in ["trunk", "crown"]:
				if not def.has(part):
					continue
				var node := MeshInstance3D.new()
				var mesh: ArrayMesh = def[part]
				node.mesh = mesh.get_meta("levels")[lod] if lod >= 0 else mesh
				node.position.x = (variant - 1.5) * 6.5
				var mat := StandardMaterial3D.new()
				mat.vertex_color_use_as_albedo = true
				mat.vertex_color_is_srgb = true
				mat.albedo_texture = def.get(part + "_texture")
				if part == "crown":
					mat.albedo_color = def.leaves[variant % def.leaves.size()]
					mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					mat.alpha_scissor_threshold = 0.35
					mat.cull_mode = BaseMaterial3D.CULL_DISABLED
				node.material_override = mat
				stand.add_child(node)
		camera.look_at_from_position(Vector3(0, 5, -26), Vector3(0, 3.8, 0))
		await _shot("trees_%d%s" % [kind, "_lod%d" % lod if lod >= 0 else ""])
	_clear()
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.use_custom_data = true
	multi.mesh = Models.grass_mesh()
	multi.instance_count = 60
	for i in multi.instance_count:
		var x := (i % 12 - 5.5) * 0.65
		var z := (i / 12) * 0.75
		var scale_y := 0.7 + (i % 5) * 0.13
		multi.set_instance_transform(i, Transform3D(Basis(Vector3.UP, i * 2.399).scaled(Vector3(1, scale_y, 1)), Vector3(x, 0, z)))
		multi.set_instance_color(i, Color(0.45 + (i % 3) * 0.04, 0.62, 0.22, 1))
		multi.set_instance_custom_data(i, Color(0.0, fposmod(i * 0.618, 1.0), fposmod(i * 0.337, 1.0), 0))
	var grass := MultiMeshInstance3D.new()
	grass.multimesh = multi
	grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var grass_mat := ShaderMaterial.new()
	grass_mat.shader = load("res://resources/vegetation.gdshader")
	grass_mat.set_shader_parameter("height", multi.mesh.get_aabb().end.y)
	grass_mat.set_shader_parameter("grass_variation", true)
	grass.material_override = grass_mat
	stand.add_child(grass)
	camera.fov = 70.0
	camera.look_at_from_position(Vector3(0, 1.7, -5), Vector3(0, 0.3, 1.2))
	await _shot("grass")
	quit()

func _clear() -> void:
	for child in stand.get_children():
		stand.remove_child(child)
		child.queue_free()

func _shot(name: String) -> void:
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var err := root.get_texture().get_image().save_png(OUT.path_join(name + ".png"))
	if err != OK:
		printerr("Не удалось записать витрину: ", err)
