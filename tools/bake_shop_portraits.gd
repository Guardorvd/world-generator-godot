extends SceneTree
## Запекает честные изображения игровой модели для витрины без постоянного 3D-рендера.
const DT := 1.0 / 60.0
var bike: BikeView
var camera: Camera3D

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
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
		state.drive_force = GameConfig.BIKE_ACCEL * 1.75 * state.effort * 0.5
		bike.tick(state, DT, 1.0, false)
	bike.draw(1.0)
	for id: String in preload("res://scripts/render/bike_palette.gd").SCHEMES:
		bike.set_scheme(id)
		for view in 2:
			camera.position = Vector3(3.2, 1.35, 0.0) if view == 0 else Vector3(-2.8, 1.8, -2.7)
			camera.look_at(Vector3(0, 0.9, 0))
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
