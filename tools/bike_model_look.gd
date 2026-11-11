extends SceneTree
## Вид модели велосипеда и седока без мира и без физики: один лист bike_model_sheet.png (2×2) —
## сбоку, три четверти спереди, игровая камера сзади, стоянка с ногой на земле. Нужно окно, секунды.
##   godot --path . --script res://tools/bike_model_look.gd -- [--out <папка>] [--tag <суффикс>]
const DT := 1.0 / 60.0
var out := ""
var tag := ""
var bike: BikeView
var state: BikeRide
var camera: Camera3D


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var args := OS.get_cmdline_user_args()
	var at := args.find("--out")
	out = args[at + 1] if at >= 0 and at + 1 < args.size() else "res://tools/control/runs"
	at = args.find("--tag")
	tag = args[at + 1] if at >= 0 and at + 1 < args.size() else ""
	root.size = Vector2i(960, 600)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("a6bbc5")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color.WHITE
	e.ambient_light_energy = 0.6
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30, 30)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.5, 0.47, 0.4)
	ground.material_override = ground_mat
	root.add_child(ground)
	bike = load("res://scenes/bike.tscn").instantiate()
	root.add_child(bike)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.make_current()
	look.call_deferred()


func ride(ticks: int, speed: float, throttle: float, crank_rate: float) -> void:
	state = BikeRide.new()
	state.riding = true
	state.speed = speed
	state.crank = 0.9
	bike.snap(state)
	for i in ticks:
		state.crank += crank_rate * DT
		state.wheel += speed / 0.34 * DT
		state._step_effort(throttle, DT)
		state.drive_force = GameConfig.BIKE_ACCEL * 1.75 * state.effort * 0.5
		bike.tick(state, DT, throttle, false)
	bike.draw(1.0)


func shot(from: Vector3, to: Vector3, fov: float) -> Image:
	camera.fov = fov
	camera.position = from
	camera.look_at(to)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func look() -> void:
	var frames: Array[Image] = []
	ride(40, 6.0, 1.0, 5.0)
	frames.append(await shot(Vector3(2.3, 0.95, 0.0), Vector3(0, 0.75, 0.0), 42.0))
	frames.append(await shot(Vector3(0.8, 1.3, -1.25), Vector3(0, 0.95, -0.3), 42.0))
	frames.append(await shot(Vector3(0.0, 2.25, 2.85), Vector3(0.0, 1.15, -0.25), 68.0))
	ride(150, 0.0, 0.0, 0.0)
	frames.append(await shot(Vector3(-1.7, 1.2, -1.7), Vector3(0, 0.75, 0.0), 42.0))
	var size := frames[0].get_size()
	var sheet := Image.create(size.x * 2, size.y * 2, false, frames[0].get_format())
	for i in frames.size():
		sheet.blit_rect(frames[i], Rect2i(Vector2i.ZERO, size), Vector2i((i % 2) * size.x, (i / 2) * size.y))
	var path := out.path_join("bike_model_sheet" + tag + ".png")
	sheet.save_png(path)
	print("Bike model look: ", path)
	quit(0)
