extends SceneTree
## Изолированный вид воды на дистанциях 25/120/400 м. --shader <прошлый файл> --tag before
## Низкое солнце и точечный свет выявляют круглые блики без генерации мира.

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(960, 540)
	var tag := "after"
	var material := WaterBuilder._material()
	var reference := false
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--shader":
			reference = true
			var shader := Shader.new()
			shader.code = FileAccess.get_file_as_string(args[i + 1])
			material.shader = shader
		elif args[i] == "--tag":
			tag = args[i + 1]
	var water := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(4000, 4000)
	water.mesh = plane
	water.material_override = material
	root.add_child(water)
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.position.y = -3.0
	var bed := StandardMaterial3D.new()
	bed.albedo_color = Color("6a6952")
	bed.roughness = 1.0
	ground.material_override = bed
	root.add_child(ground)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("819aab")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("b9cbd3")
	environment.environment.ambient_light_energy = 0.6
	environment.environment.glow_enabled = true
	environment.environment.glow_intensity = 0.35
	environment.environment.glow_bloom = 0.04
	root.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees.x = -25.0
	sun.light_energy = 2.0
	root.add_child(sun)
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(6, 4, 0)
	lamp.omni_range = 30
	lamp.light_energy = 6
	lamp.light_color = Color("ffae66")
	root.add_child(lamp)
	var camera := Camera3D.new()
	camera.far = 6000
	root.add_child(camera)
	for distance: float in [25.0, 120.0, 400.0]:
		camera.position = Vector3(0, distance * sin(deg_to_rad(25)), -distance * cos(deg_to_rad(25)))
		camera.look_at(Vector3.ZERO)
		for frame in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := "res://tools/control/runs/water_glint_%s_%d.png" % [tag, int(distance)]
		var image := root.get_texture().get_image()
		var error := image.save_png(path)
		if error != OK:
			push_error("Не записан " + path)
			quit(1)
			return
		print(path)
		if distance == 400.0 and not reference:
			# Несколько фаз ряби: на дальней воде не должно оставаться ярких ореолов.
			for phase in 3:
				var bright := 0
				for y in range(image.get_height() / 4, image.get_height(), 4):
					for x in range(0, image.get_width(), 4):
						var color := image.get_pixel(x, y)
						if minf(color.r, minf(color.g, color.b)) > 0.8:
							bright += 1
				if bright > 2:
					push_error("Ореолы вдали: %d ярких точек выборки" % bright)
					quit(1)
					return
				for frame in 12:
					await process_frame
				await RenderingServer.frame_post_draw
				image = root.get_texture().get_image()
			print("Дальняя вода: ореолов нет в трёх фазах ряби")
	quit()
