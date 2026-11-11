extends SceneTree
## 11.11.2026: изолированная сцена частиц окружения (AmbientParticles) без мира: ровная площадка, несколько тёмных
## столбов для фона, окружение задаётся вручную (force_context). Лист 2×2 ambient_sheet.jpg: лес днём (пылинки,
## листья в воздухе и на земле), луг днём (пух), болото ночью (светлячки), снег. Печатает правила слоёв для каждого
## биома и медиану GPU/CPU на ракурс со всеми слоями и без них. Нужно окно, секунды.
##   godot --path . --script res://tools/ambient_look.gd -- [--out <папка>]

class FlatGround extends Heightfield:
	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 0.0

var ambient: AmbientParticles
var camera: Camera3D
var env: Environment
var sun: DirectionalLight3D


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()


func context(biome: int, sunlight: float) -> Dictionary:
	var entry: Dictionary = Biomes.LIST[biome]
	return {biome = biome, water = entry.get("water", false), trees = float(entry.get("trees", 0.0)), temp = 0.5, moist = 0.5,
		river = false, sun = sunlight, night = 1.0 - sunlight}


func median_ms(frames: int) -> Vector2:
	var gpu := PackedFloat32Array()
	var cpu := PackedFloat32Array()
	for i in frames:
		await process_frame
		ambient.update(1.0 / 60.0, camera.global_position, sun.light_energy)
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
	gpu.sort()
	cpu.sort()
	return Vector2(gpu[frames / 2], cpu[frames / 2])


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[args.find("--out") + 1] if args.find("--out") >= 0 else "res://tools/control/runs"
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	# правила: какие слои видны в каждом биоме днём и ночью
	for biome in Biomes.LIST.size():
		var line := ""
		for sunlight: float in [1.0, 0.0]:
			for def: Dictionary in AmbientParticles.LAYERS:
				var w := AmbientParticles._target(def.id, context(biome, sunlight))
				if w > 0.0:
					line += " %s%s %.2f" % [def.id, "" if sunlight > 0.5 else "(ночь)", w]
		print("%-16s%s" % [Biomes.LIST[biome].name, line])
	var world_env := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.glow_enabled = true
	world_env.environment = env
	root.add_child(world_env)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -30, 0)
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(120, 120)
	ground.mesh = plane
	var soil := StandardMaterial3D.new()
	ground.material_override = soil
	root.add_child(ground)
	for i in 9:
		var trunk := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.3
		cyl.bottom_radius = 0.4
		cyl.height = 14.0
		trunk.mesh = cyl
		var bark := StandardMaterial3D.new()
		bark.albedo_color = Color(0.16, 0.12, 0.09)
		trunk.material_override = bark
		trunk.position = Vector3(-12.0 + i * 3.0, 7.0, -9.0 - (i % 3) * 4.0)
		root.add_child(trunk)
	ambient = AmbientParticles.new()
	root.add_child(ambient)
	ambient.setup(null, FlatGround.new())
	camera = Camera3D.new()
	camera.fov = 70.0
	root.add_child(camera)
	camera.make_current()
	camera.look_at_from_position(Vector3(0, 1.9, 4.0), Vector3(0, 2.3, -8.0))
	var frames: Array[Image] = []
	# [биом, свет, цвет неба, цвет земли]
	for view: Array in [[Biomes.FOREST, 1.0, Color("7f9db0"), Color("46552f")], [Biomes.GRASS, 1.0, Color("86a9c4"), Color("5d8a3a")],
			[Biomes.SWAMP, 0.0, Color("0a0f1a"), Color("10160f")], [Biomes.SNOW, 1.0, Color("9fb0c0"), Color("dfe6ee")]]:
		env.background_color = view[2]
		env.ambient_light_color = Color.WHITE if view[1] > 0.5 else Color(0.25, 0.3, 0.45)
		env.ambient_light_energy = 0.6 if view[1] > 0.5 else 0.25
		sun.light_energy = view[1]
		soil.albedo_color = view[3]
		ambient.density = 0.0
		ambient.force_context(context(view[0], view[1]))
		var off: Vector2 = await median_ms(60)
		ambient.density = 1.0
		ambient.force_context(context(view[0], view[1]))
		var on: Vector2 = await median_ms(60)
		print("%s: gpu %.3f → %.3f ms, cpu %.3f → %.3f ms" % [Biomes.LIST[view[0]].name, off.x, on.x, off.y, on.y])
		await RenderingServer.frame_post_draw
		frames.append(root.get_texture().get_image())
	var size := frames[0].get_size()
	var sheet := Image.create(size.x * 2, size.y * 2, false, frames[0].get_format())
	for i in frames.size():
		sheet.blit_rect(frames[i], Rect2i(Vector2i.ZERO, size), Vector2i((i % 2) * size.x, (i / 2) * size.y))
	sheet.save_jpg(out.path_join("ambient_sheet.jpg"), 0.92)
	print("Ambient look: ", out.path_join("ambient_sheet.jpg"))
	quit(0)
