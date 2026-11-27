extends SceneTree
## Вид седока без мира и без физики: лист модели 4×2 и лист поз в пяти колонках.
##   rider_model_sheet.png — модель крупно: сбоку, спереди три четверти, сзади, голова, кисти на руле, стопа на педали,
##     спереди в лоб, игровая камера;
##   rider_anim_sheet.png — позы: езда сидя, подъём стоя, спуск («атака»), поворот, торможение, приземление,
##     стоянка с ногой на земле, отдых на долгой стоянке, рывок стоя и вход в поворот.
## Нужно окно, секунды. «Было» — тем же запуском на прежнем коде с --tag _old. Свет — tools/bike_stand.gd.
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
	preload("res://tools/bike_stand.gd").setup(root) # свет игры; --flat — прежний плоский стенд, --hour — час
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
		state.wheel += state.speed / BikeRide.WHEEL_R * DT
		state.feel_acceleration = (state.speed - _speed_before) / DT
		_speed_before = state.speed
		state.grade_now = state.tilt
		state._step_effort(maxf(throttle, 0.0) if not state.airborne else 0.0, DT)
		var cfg := BikePhysicsConfig.current()
		state.drive_force = cfg.pedal_accel * cfg.pedal_push_mult * state.effort * 0.5
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
	var sheet := Image.create(size.x * cols, size.y * ceili(float(frames.size()) / cols), false, frames[0].get_format())
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
	state.brake_force = Vector2(3.0, 2.0)
	for i in 25:
		state.speed -= 5.0 * DT
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
	reset(7.5)
	bike.watch_requested = true
	advance(26, 0.65, 4.0)
	save([await shot(Vector3(-2.0, 1.65, -1.65), Vector3(0.0, 1.05, -0.12))], "rider_watch", 1)
	bike.watch_requested = false
	# 20.11: пассивное поглощение гребня без зажатого пампа — слева обычная езда накатом, справа гребень
	var absorb: Array[Image] = []
	reset(11.0)
	advance(40)
	absorb.append(await shot(side, mid))
	reset(11.0)
	advance(20)
	state._pump_absorb_v = state.config.pump_absorb_v * state.config.pump_passive
	advance(12)
	absorb.append(await shot(side, mid))
	state._pump_absorb_v = 0.0
	save(absorb, "rider_absorb", 2)
	# 12.11: рывок на Shift на скорости (стоя, велосипед раскачивается) и резкий доворот руля
	reset(12.0)
	state.surge = 1.0
	advance(50, 1.0, 9.0, true)
	anim.append(await shot(Vector3(1.6, 1.3, -2.3), mid + Vector3(0, 0.15, 0)))
	state.surge = -1.0
	reset(10.0)
	advance(30)
	for i in 8:
		state.steer = minf(1.0, state.steer + 5.0 * DT)
		state.lean = -state.steer * 0.25
		advance(1)
	anim.append(await shot(Vector3(0.6, 1.3, -2.7), Vector3(0, 1.0, 0.0)))
	save(anim, "rider_anim_sheet", 5)
	var balance: Array[Image] = []
	var ground := root.get_node("Ground") as MeshInstance3D
	var rear := Vector3(0.65, 1.65, 3.3)
	var frame_center := Vector3(0, 0.82, 0)
	reset(0.0)
	state._stance_driven = true
	state.stance = BikeRide.Stance.TRACKSTAND
	advance(35)
	balance.append(await shot(rear, frame_center, 44.0))
	state.stance = BikeRide.Stance.FOOT_DOWN
	state.foot_side = 1.0
	state.bank_slope = 0.30
	ground.rotation.z = atan(state.bank_slope)
	state.foot_support = state.foot_probe(state.foot_side)
	state.foot_support.y += state.bank_slope * state.foot_support.x
	advance(55)
	balance.append(await shot(rear, frame_center, 44.0))
	reset(6.0)
	state.bank_slope = 0.4
	ground.rotation.z = atan(state.bank_slope)
	state.lateral_speed = -0.8
	state.instability = 0.85
	advance(25)
	balance.append(await shot(rear, frame_center, 44.0))
	reset(10.0)
	state.tilt = -0.24
	ground.rotation = Vector3(state.tilt, 0, 0)
	state.brakes.pressure = 1.0
	state.brake_force = Vector2(6.0, 2.0)
	state.brakes.risk = 0.65
	state.brakes.lift = 0.16
	advance(35)
	balance.append(await shot(Vector3(3.1, 1.2, 0.0), frame_center, 44.0))
	save(balance, "rider_balance", 4)
	ground.rotation = Vector3.ZERO
	reset(4.0)
	advance(75)
	var restart: Array[Image] = []
	var pedal_camera := Vector3(1.70, 0.52, 0.12)
	var spindle := Vector3(0, 0.38, 0)
	for elapsed in [0, 4, 4, 8]:
		advance(elapsed, 1.0, 4.0)
		restart.append(await shot(pedal_camera, spindle, 34.0))
	save(restart, "rider_pedal_restart", 4)
	quit(0)
