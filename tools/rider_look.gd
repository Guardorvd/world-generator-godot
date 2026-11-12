extends SceneTree
## Вид седока без мира и без физики: листы 4×2 (модель) и 5×2 (позы).
##   rider_model_sheet.png — модель крупно: сбоку, спереди три четверти, сзади, голова, кисти на руле, стопа на педали,
##     спереди в лоб, игровая камера;
##   rider_anim_sheet.png — позы: езда сидя, подъём стоя, спуск («атака»), поворот, торможение, приземление,
##     стоянка (нога на земле), долгая стоянка (отдых: рука на бедре) спереди и сзади, встряхивание кисти в спокойной езде.
## Нужно окно, секунды. «Было» — тем же запуском на прежнем коде с --tag _old.
##   godot --path . --script res://tools/rider_look.gd -- [--out <папка>] [--tag <суффикс>]
const DT := 1.0 / 60.0
var out := ""
var tag := ""
var bike: BikeView
var state: BikeRide
var camera: Camera3D
var _speed_before := 0.0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var args := OS.get_cmdline_user_args()
	var at := args.find("--out")
	out = args[at + 1] if at >= 0 and at + 1 < args.size() else "res://tools/control/runs"
	at = args.find("--tag")
	tag = args[at + 1] if at >= 0 and at + 1 < args.size() else ""
	root.size = Vector2i(800, 600)
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


func reset(speed := 6.0) -> void:
	state = BikeRide.new()
	state.riding = true
	state.speed = speed
	state.crank = 0.9
	_speed_before = speed
	bike.snap(state)


## Сигналы вида выводятся из состояния так же, как в cyclist_animation_test.
func advance(ticks: int, throttle := 0.0, crank_rate := 0.0, boost := false) -> void:
	for i in ticks:
		state.crank += crank_rate * DT
		state.wheel += state.speed / 0.34 * DT
		state.feel_acceleration = (state.speed - _speed_before) / DT
		_speed_before = state.speed
		state.grade_now = state.tilt
		state._step_effort(maxf(throttle, 0.0) if not state.airborne else 0.0, DT)
		state.drive_force = GameConfig.BIKE_ACCEL * 1.75 * state.effort * 0.5
		bike.tick(state, DT, throttle, boost)
		state.land_impact = 0
	bike.draw(1.0)


func shot(from: Vector3, to: Vector3, fov := 36.0) -> Image:
	camera.fov = fov
	camera.position = from
	camera.look_at(to)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func save(frames: Array[Image], file: String, cols := 4) -> void:
	var size := frames[0].get_size()
	var sheet := Image.create(size.x * cols, size.y * 2, false, frames[0].get_format())
	for i in frames.size():
		sheet.blit_rect(frames[i], Rect2i(Vector2i.ZERO, size), Vector2i((i % cols) * size.x, (i / cols) * size.y))
	var path := out.path_join(file + tag + ".png")
	sheet.save_png(path)
	print("Rider look: ", path)


func look() -> void:
	var model: Array[Image] = []
	reset()
	advance(40, 1.0, 5.0)
	model.append(await shot(Vector3(2.6, 1.15, -0.05), Vector3(0, 1.05, -0.05)))
	model.append(await shot(Vector3(1.5, 1.45, -1.9), Vector3(0, 1.1, -0.1)))
	model.append(await shot(Vector3(-1.3, 1.55, 2.0), Vector3(0, 1.15, -0.05)))
	model.append(await shot(Vector3(0.75, 1.62, -0.85), Vector3(0, 1.56, -0.2), 30.0))
	model.append(await shot(Vector3(0.5, 1.25, -0.95), Vector3(0.12, 1.0, -0.4), 30.0))
	model.append(await shot(Vector3(0.9, 0.45, -0.25), Vector3(0.14, 0.4, 0.0), 34.0))
	model.append(await shot(Vector3(0.0, 1.3, -2.6), Vector3(0, 1.1, 0.0)))
	model.append(await shot(Vector3(0.0, 2.25, 2.85), Vector3(0.0, 1.15, -0.25), 68.0))
	save(model, "rider_model_sheet")
	var anim: Array[Image] = []
	var side := Vector3(2.7, 1.2, -0.05)
	var mid := Vector3(0, 1.05, -0.05)
	reset()
	advance(60, 1.0, 5.0)
	anim.append(await shot(side, mid))
	reset(4.0)
	state.tilt = 0.25
	advance(90, 1.0, 6.0, true)
	anim.append(await shot(side + Vector3(0, 0.3, 0), mid + Vector3(0, 0.2, 0)))
	reset(10.0)
	state.tilt = -0.25
	advance(90)
	anim.append(await shot(side, mid))
	reset(8.0)
	state.steer = 0.5
	state.lean = -0.3
	advance(60)
	anim.append(await shot(Vector3(0.6, 1.3, -2.7), Vector3(0, 1.0, 0.0)))
	reset(8.0)
	for i in 25:
		state.speed -= 5.0 * DT
		state.brake_applied = GameConfig.BIKE_BRAKE
		advance(1, -1.0)
	anim.append(await shot(side, mid))
	reset(8.0)
	state.airborne = true
	state.vy = -3.0
	advance(30)
	state.airborne = false
	state.vy = 0.0
	state.land_impact = 9.0
	advance(4)
	anim.append(await shot(side, mid))
	reset(0.0)
	advance(100)
	anim.append(await shot(Vector3(-1.9, 1.3, -1.9), Vector3(0, 0.95, 0.0)))
	advance(500)
	anim.append(await shot(Vector3(1.9, 1.3, -1.9), Vector3(0, 0.95, 0.0)))
	anim.append(await shot(Vector3(-1.2, 1.7, 2.2), Vector3(0, 1.1, -0.1)))
	reset()
	advance(872)
	anim.append(await shot(Vector3(1.6, 1.5, -2.0), Vector3(0, 1.1, -0.05)))
	save(anim, "rider_anim_sheet", 5)
	quit(0)
