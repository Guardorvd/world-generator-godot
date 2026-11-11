extends SceneTree
## 11.11.2026: изолированный вид коры без мира: взрослые дуб, сосна, берёза и ель у камеры на высоте седла.
## Слева на листе — без рисунка коры (bark_detail = 0, как было), справа — с ним. Лист bark_sheet.jpg.
##   godot --path . --script res://tools/bark_look.gd -- [--out <папка>]
## Нужно окно, секунды (модели строятся напрямую, ForestModels.baking).
const KINDS := [Biomes.T_OAK, Biomes.T_PINE, Biomes.T_BIRCH, Biomes.T_SNOWPINE]
var camera: Camera3D
var mats: Array[ShaderMaterial] = []
var details: Array[float] = []


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[args.find("--out") + 1] if args.find("--out") >= 0 else "res://tools/control/runs"
	ForestModels.baking = true
	RenderingServer.global_shader_parameter_set("veg_center", Vector2.ZERO)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b9ced2")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("e5e6d7")
	env.environment.ambient_light_energy = 0.7
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, -55, 0)
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	ground.mesh = plane
	var soil := StandardMaterial3D.new()
	soil.albedo_color = Color("5d6b45")
	ground.material_override = soil
	root.add_child(ground)
	var x := 0.0
	for kind: int in KINDS:
		var def: Dictionary = ForestModels.definition(kind, 0)
		var height := 0.3
		for part: String in ["trunk", "crown"]:
			if def.has(part):
				height = maxf(height, (def[part] as Mesh).get_aabb().end.y)
		for part: String in ["trunk", "crown"]:
			if not def.has(part):
				continue
			var node := MeshInstance3D.new()
			node.mesh = def[part]
			node.position.x = x
			var shader := VegetationLayer.CUTOUT_SHADER if part == "crown" else VegetationLayer.TRUNK_SHADER
			var mat := VegetationLayer._wind_mat(shader, VegetationLayer.WIND.get(kind, VegetationLayer.CALM), part == "crown")
			mat.set_shader_parameter("albedo_tex", def.get(part + "_texture"))
			mat.set_shader_parameter("albedo_color", def.leaves[0] if part == "crown" else def.bark)
			mat.set_shader_parameter("use_vertex_color", def.get("colored_bark", false))
			mat.set_shader_parameter("height", height)
			mat.set_shader_parameter("lod_level", -1)
			if part == "trunk":
				mats.append(mat)
				details.append(VegetationLayer.bark_detail(kind))
			node.material_override = mat
			root.add_child(node)
		x += 2.6
	camera = Camera3D.new()
	camera.fov = 60.0
	root.add_child(camera)
	camera.make_current()
	camera.look_at_from_position(Vector3(3.9, 1.5, 4.3), Vector3(3.9, 1.7, 0.0))
	var frames: Array[Image] = []
	for on in [false, true]:
		for i in mats.size():
			mats[i].set_shader_parameter("bark_detail", details[i] if on else 0.0)
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		frames.append(root.get_texture().get_image())
	var size := frames[0].get_size()
	var sheet := Image.create(size.x * 2, size.y, false, frames[0].get_format())
	sheet.blit_rect(frames[0], Rect2i(Vector2i.ZERO, size), Vector2i.ZERO)
	sheet.blit_rect(frames[1], Rect2i(Vector2i.ZERO, size), Vector2i(size.x, 0))
	sheet.save_jpg(out.path_join("bark_sheet.jpg"), 0.9)
	print("Bark look: ", out.path_join("bark_sheet.jpg"))
	ForestModels.baking = false
	quit(0)
