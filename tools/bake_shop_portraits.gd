extends SceneTree
## Запекает честные изображения игровой модели для витрины без постоянного 3D-рендера.
const DT := 1.0 / 60.0
const Progress := preload("res://scripts/game/shop_progress.gd")
var bike: BikeView
var camera: Camera3D

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	root.size = Vector2i(960, 560)
	root.transparent_bg = true
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("d8e5d9")
	env.ambient_light_energy = 0.8
	world.environment = env
	root.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48, -38, 0)
	light.light_energy = 1.0
	root.add_child(light)
	bike = load("res://scenes/bike.tscn").instantiate()
	root.add_child(bike)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.1
	root.add_child(camera)
	camera.make_current()
	_bake.call_deferred()

func _bake() -> void:
	var state := BikeRide.new()
	state.riding = true
	state.speed = 6.0
	state.crank = 0.9
	bike.idle_life = false
	bike.snap(state)
	for i in 40:
		state.crank += 5.0 * DT
		state.wheel += state.speed / 0.34 * DT
		state._step_effort(1.0, DT)
		var cfg := BikePhysicsConfig.current()
		state.drive_force = cfg.pedal_accel * cfg.start_push_mult * state.effort * 0.5
		bike.tick(state, DT, 1.0, false)
	bike.draw(1.0)
	var skeleton := bike.rider.skeleton
	var head := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("Head")).origin
	var args := OS.get_cmdline_user_args()
	var only := args.find("--only")
	for id: String in Progress.PRICES:
		if only >= 0 and (only + 1 >= args.size() or args[only + 1] != id):
			continue
		var category := Progress.category_for(id)
		var tires := category == Progress.Category.TIRES
		var grips := category == Progress.Category.GRIPS
		var pedals := category == Progress.Category.PEDALS
		var helmet := category == Progress.Category.HELMET
		var accessory := category != Progress.Category.SCHEME
		if ("--tires" in args and not tires) or ("--grips" in args and not grips) or ("--helmets" in args and not helmet):
			continue
		# 20.11: готовые портреты не переснимаются (новая расцветка — только свои два файла); всё заново — -- --all
		if FileAccess.file_exists("res://resources/shop/%s_side.png" % id) and not "--all" in args:
			continue
		bike.set_scheme(Progress.DEFAULT_SCHEME if accessory else id)
		bike.set_tires(id if tires else Progress.DEFAULT_TIRES)
		bike.set_grips(id if grips else Progress.DEFAULT_GRIPS)
		bike.set_pedals(id if pedals else Progress.DEFAULT_PEDALS)
		bike.set_helmet(id if helmet else Progress.DEFAULT_HELMET)
		bike.rider.visible = not accessory or helmet
		camera.size = [2.1, 1.45, 0.52, 0.48, 0.5][category]
		var target := Vector3(0, 0.56 if tires else 0.9, 0)
		if helmet:
			# 27.11: голова крупно; второй ракурс — сзади сбоку, как шлем виден из игровой камеры
			target = head + Vector3(0, 0.05, 0)
		elif grips:
			target = Vector3(0, 0.97, -0.405)
		elif pedals:
			target = Vector3(0, 0.30, 0)
			# Обе платформы на одной высоте и разнесены вдоль рамы.
			bike.crank.rotation.x = PI * 0.5
			bike.pedal_l.rotation.x = -PI * 0.5
			bike.pedal_r.rotation.x = -PI * 0.5
		for view in 2:
			if helmet:
				camera.position = target + (Vector3(3.0, 0.3, 0.0) if view == 0 else Vector3(-2.0, 1.1, 2.2))
			elif grips:
				camera.position = Vector3(0, 1.85, -2.1) if view == 0 else Vector3(1.2, 1.65, -1.8)
			elif pedals:
				camera.position = Vector3(1.6, 0.68, 0.15) if view == 0 else Vector3(1.4, 1.28, -0.50)
			else:
				camera.position = Vector3(3.2, 1.35, 0.0) if view == 0 else Vector3(-2.8, 1.8, -2.7)
			camera.look_at(target)
			await process_frame
			await process_frame
			await RenderingServer.frame_post_draw
			var path := "res://resources/shop/%s_%s.png" % [id, "side" if view == 0 else "angle"]
			var result := root.get_texture().get_image().save_png(path)
			if result != OK:
				printerr("ERROR: Cannot save ", path)
				quit(1)
				return
			print("Baked ", path)
	quit()
