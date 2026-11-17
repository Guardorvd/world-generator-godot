extends SceneTree
## Вид модели велосипеда и седока без мира и без физики: один лист bike_model_sheet.png (3×2) —
## сбоку, три четверти спереди, игровая камера сзади, стоянка с ногой на земле, перёд сбоку крупно,
## перёд с повёрнутым рулём и сжатой вилкой. Свет игры (tools/bike_stand.gd, --hour, --flat). Нужно окно, секунды.
## Печатает цену модели (отрисовки, тени, треугольники, материалы) и время расчёта позы на кадр;
## --measure — ещё время отрисовки кадра с моделью и без (игровая камера, ~10 с);
## --schemes — лист расцветок bike_schemes.png (BikeView.set_scheme, BikePalette.SCHEMES).
## Режим отрисовки — как у игры (Forward+); Compatibility — ключом движка --rendering-method gl_compatibility.
##   godot --path . --script res://tools/bike_model_look.gd -- [--out <папка>] [--tag <суффикс>] [--hour 10.5] [--measure]
const Stand := preload("res://tools/bike_stand.gd")
const DT := 1.0 / 60.0
var out := ""
var tag := ""
var bike: BikeView
var state: BikeRide
var camera: Camera3D


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	out = Stand.arg("--out", "res://tools/control/runs")
	tag = Stand.arg("--tag", "")
	root.size = Vector2i(960, 600)
	Stand.setup(root)
	bike = load("res://scenes/bike.tscn").instantiate()
	root.add_child(bike)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.make_current()
	look.call_deferred()


func ride(ticks: int, speed: float, throttle: float, crank_rate: float, steer := 0.0, fork := 0.0) -> void:
	state = BikeRide.new()
	state.riding = true
	state.speed = speed
	state.steer = steer
	state.squash_f = fork
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


## Время такта вида и кадра позы (tick + draw) на GDScript, мкс.
func pose_cost() -> float:
	ride(10, 6.0, 1.0, 5.0)
	var t0 := Time.get_ticks_usec()
	for i in 600:
		state.crank += 5.0 * DT
		state.wheel += 6.0 / 0.34 * DT
		state._step_effort(1.0, DT)
		bike.tick(state, DT, 1.0, false)
		bike.draw(1.0)
	return float(Time.get_ticks_usec() - t0) / 600.0


func look() -> void:
	print("Bike model cost: ", Stand.cost(bike), " pose %.0f us/frame" % pose_cost())
	var frames: Array[Image] = []
	ride(40, 6.0, 1.0, 5.0)
	frames.append(await shot(Vector3(2.3, 0.95, 0.0), Vector3(0, 0.75, 0.0), 42.0))
	frames.append(await shot(Vector3(0.8, 1.3, -1.25), Vector3(0, 0.95, -0.3), 42.0))
	frames.append(await shot(Vector3(0.0, 2.25, 2.85), Vector3(0.0, 1.15, -0.25), 68.0))
	ride(150, 0.0, 0.0, 0.0)
	frames.append(await shot(Vector3(-1.7, 1.2, -1.7), Vector3(0, 0.75, 0.0), 42.0))
	ride(40, 6.0, 1.0, 5.0)
	frames.append(await shot(Vector3(1.25, 0.8, -0.42), Vector3(0, 0.7, -0.42), 42.0))
	ride(40, 6.0, 0.0, 0.0, 0.6, 0.08)
	frames.append(await shot(Vector3(-0.75, 1.15, -1.45), Vector3(0, 0.72, -0.4), 42.0))
	var size := frames[0].get_size()
	var sheet := Image.create(size.x * 3, size.y * 2, false, frames[0].get_format())
	for i in frames.size():
		sheet.blit_rect(frames[i], Rect2i(Vector2i.ZERO, size), Vector2i((i % 3) * size.x, (i / 3) * size.y))
	var path := out.path_join("bike_model_sheet" + tag + ".png")
	sheet.save_png(path)
	print("Bike model look: ", path)
	if OS.get_cmdline_user_args().has("--schemes"):
		# расцветки (BikePalette.SCHEMES): сбоку и три четверти спереди, по столбцу на расцветку
		var shots: Array[Image] = []
		var names: Array = preload("res://scripts/render/bike_palette.gd").SCHEMES.keys()
		for row in 2:
			for scheme: String in names:
				bike.set_scheme(scheme)
				ride(40, 6.0, 1.0, 5.0)
				shots.append(await shot(Vector3(2.3, 0.95, 0.0), Vector3(0, 0.75, 0.0), 42.0) if row == 0 else await shot(Vector3(-1.5, 1.6, 1.9), Vector3(0, 0.95, 0.0), 42.0))
		var schemes := Image.create(size.x * names.size(), size.y * 2, false, shots[0].get_format())
		for i in shots.size():
			schemes.blit_rect(shots[i], Rect2i(Vector2i.ZERO, size), Vector2i((i % names.size()) * size.x, (i / names.size()) * size.y))
		schemes.save_png(out.path_join("bike_schemes" + tag + ".png"))
		print("Bike schemes: ", out.path_join("bike_schemes" + tag + ".png"))
		bike.set_scheme("ember")
	if OS.get_cmdline_user_args().has("--measure"):
		ride(40, 6.0, 1.0, 5.0)
		camera.fov = 68.0
		camera.position = Vector3(0.0, 2.25, 2.85)
		camera.look_at(Vector3(0.0, 1.15, -0.25))
		print("Bike model frame: ", await Stand.measure(self, bike))
	quit(0)
