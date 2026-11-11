extends SceneTree
## 11.11.2026: изолированная сцена открытых поверхностей рельефа без генерации мира. Холмистый участок 120 × 80 м
## с метровой сеткой, полосы биомов по 12 м (луг, лес без полога, степь, саванна, пустыня, пляж, тундра, снег,
## болото, скала); материал — настоящий GameContext.scope.terrain.material, без дорог и леса.
## Снимки: у земли над травой, у земли над песком и снегом, сверху — один лист surface_sheet<tag>.jpg.
##   godot --path . --script res://tools/surface_look.gd -- [--out <папка>] [--shader <файл>] [--tag <суффикс>] [--measure]
## --shader — другой код шейдера рельефа (например, `git show HEAD:resources/terrain.gdshader`) для «было».
## --measure — медиана GPU/CPU за 90 кадров на ракурс (изолированный стенд, не игровой FPS). Нужно окно.
const W := 120
const H := 80
const STRIP := 12.0
const BIOMES := [Biomes.GRASS, Biomes.FOREST, Biomes.STEPPE, Biomes.SAVANNA, Biomes.DESERT, Biomes.BEACH, Biomes.TUNDRA, Biomes.SNOW, Biomes.SWAMP, Biomes.ROCK]
const WINDOW := Vector2i(1280, 720)

var out := ""
var tag := ""
var noise := FastNoiseLite.new()
var camera: Camera3D
var measure := false


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback


func height(x: float, z: float) -> float:
	return noise.get_noise_2d(x * 0.02, z * 0.02) * 3.0 + noise.get_noise_2d(x * 0.09 + 40.0, z * 0.09) * 0.5 + maxf(0.0, z - 58.0) * 0.55


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	out = _arg("out", "res://tools/control/runs")
	tag = _arg("tag", "")
	measure = "--measure" in OS.get_cmdline_user_args()
	if measure:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	noise.seed = 77
	noise.frequency = 1.0
	noise.fractal_octaves = 3
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
	root.add_child(sun)
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var colors := PackedColorArray()
	for z in H + 1:
		for x in W + 1:
			pos.append(Vector3(x, height(x, z), z))
			nor.append(Vector3(height(x - 1.0, z) - height(x + 1.0, z), 2.0, height(x, z - 1.0) - height(x, z + 1.0)).normalized())
			uv.append(Vector2(x / float(W), z / float(H)))
			uv2.append(Vector2.ZERO)
			colors.append(Color(0, 0, 0, 0))
	var idx := PackedInt32Array()
	var n := W + 1
	for z in H:
		for x in W:
			var a := z * n + x
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Карта биомов, 2 пикселя на метр, как в игре: полосы с неровной границей
	var base := Image.create(W * 2, H * 2, false, Image.FORMAT_RGB8)
	for y in base.get_height():
		for x in base.get_width():
			var at := x * 0.5 + noise.get_noise_2d(x * 0.03 + 9.0, y * 0.03) * 3.0
			var c: Array = Biomes.LIST[BIOMES[clampi(int(at / STRIP), 0, BIOMES.size() - 1)]].color
			base.set_pixel(x, y, Color8(c[0], c[1], c[2]))
	var mat: ShaderMaterial = GameContext.scope.terrain.material(base)
	var shader_path := _arg("shader", "")
	if shader_path != "":
		var sh := Shader.new()
		sh.code = FileAccess.get_file_as_string(shader_path)
		mat.shader = sh
	mesh.surface_set_material(0, mat)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	root.add_child(node)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.far = 400.0
	root.add_child(camera)
	camera.make_current()
	look.call_deferred()


func eye(x: float, z: float, up: float) -> Vector3:
	return Vector3(x, height(x, z) + up, z)


func look() -> void:
	DisplayServer.window_set_size(WINDOW)
	var frames: Array[Image] = []
	var views := [[eye(4.0, 14.0, 1.45), eye(30.0, 30.0, 0.3)], [eye(50.0, 10.0, 1.45), eye(76.0, 28.0, 0.3)],
		[eye(88.0, 8.0, 1.45), eye(112.0, 30.0, 0.3)], [Vector3(60.0, 34.0, -18.0), Vector3(60.0, 0.0, 34.0)]]
	for view: Array in views:
		camera.position = view[0]
		camera.look_at(view[1])
		for i in 8:
			await process_frame
		if measure:
			var gpu := PackedFloat32Array()
			var cpu := PackedFloat32Array()
			for i in 90:
				await process_frame
				gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
				cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
			gpu.sort()
			cpu.sort()
			print("view ", frames.size(), ": gpu ", snappedf(gpu[45], 0.001), " ms, cpu ", snappedf(cpu[45], 0.001), " ms")
		await RenderingServer.frame_post_draw
		frames.append(root.get_texture().get_image())
	var size := frames[0].get_size()
	var sheet := Image.create(size.x * 2, size.y * 2, false, frames[0].get_format())
	for i in frames.size():
		sheet.blit_rect(frames[i], Rect2i(Vector2i.ZERO, size), Vector2i((i % 2) * size.x, (i / 2) * size.y))
	var path := out.path_join("surface_sheet" + tag + ".jpg")
	sheet.save_jpg(path, 0.9)
	print("Surface look: ", path)
	quit(0)
