extends SceneTree
## Изолированная проверка настоящих материалов: крона принимает тени и затеняет землю.
const Fixture := preload("res://tools/vegetation_test.gd")
var fails := 0
var out := "res://.godot/tree_lighting"

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	if not ok:
		fails += 1

func shot(name: String) -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image()
	check(result.save_png(out.path_join(name + ".png")) == OK, "Снимок " + name)
	return result

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Нужен оконный рендерер")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(960, 640)
	var w := Fixture.fixture(0)
	var h := Heightfield.new(w, false)
	var veg := VegetationLayer.new()
	root.add_child(veg)
	veg.setup(w, h, Models.tree_defs(), Models.grass_mesh())
	var built := veg._build_entries({x = PackedFloat64Array([0, 2]), y = PackedFloat64Array([0, 0]),
		k = PackedInt32Array([Biomes.T_OAK, Biomes.T_BIRCH]), v = PackedInt32Array([0, 0]),
		s = PackedFloat64Array([1, 1]), ground = PackedFloat32Array([0.1, 0.1])})
	built.chunk = Vector2i.ZERO
	veg._apply_chunk(built)
	for entry: Dictionary in veg._defs.values():
		for part in ["trunk", "crown"]:
			for mat: ShaderMaterial in entry.get(part + "_mats", []):
				mat.set_shader_parameter("sway", 0.0)
				mat.set_shader_parameter("flutter", 0.0)
	RenderingServer.global_shader_parameter_set("veg_center", Vector2.ZERO)
	RenderingServer.global_shader_parameter_set("cloud_shadow", Vector4.ZERO)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b3c4d2")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.45
	root.add_child(env)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(140, 140)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("999999")
	ground.material_override = mat
	root.add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.2
	sun.directional_shadow_max_distance = 100
	root.add_child(sun)
	var occluder := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(140, 0.2, 140)
	occluder.mesh = box
	occluder.position.y = 12
	occluder.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	root.add_child(occluder)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	camera.look_at_from_position(Vector3(13, 7, -20), Vector3(4, 3, 0))
	for angle in [50, 12]:
		sun.rotation_degrees = Vector3(-angle, -25, 0)
		sun.shadow_enabled = false
		occluder.hide()
		var unshadowed := await shot("sun_%d_no_shadows" % angle)
		sun.shadow_enabled = true
		var own := await shot("sun_%d_trees" % angle)
		occluder.show()
		var shaded := await shot("sun_%d_occluded" % angle)
		var received := 0
		var cast := 0
		for y in range(0, own.get_height(), 2):
			for x in range(0, own.get_width(), 2):
				var lit := own.get_pixel(x, y)
				if lit.g > lit.r * 1.12 and lit.g > lit.b * 1.12 and lit.g - shaded.get_pixel(x, y).g > 0.025:
					received += 1
				if y > own.get_height() / 2 and absf(lit.r - lit.g) < 0.04 and unshadowed.get_pixel(x, y).r - lit.r > 0.025:
					cast += 1
		check(received > 40, "Кроны принимают тень при солнце %d°: %d пикселей" % [angle, received])
		check(cast > 40, "Деревья отбрасывают тень при солнце %d°: %d пикселей" % [angle, cast])
	veg.free()
	print("tree_lighting_test: %d ошибок" % fails)
	quit(1 if fails else 0)
