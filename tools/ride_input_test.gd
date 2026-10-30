extends SceneTree
## Player input contracts: held pump, progressive steering and independent camera.
const Pump = preload("res://tools/auto_pump_test.gd")
const Friendly = preload("res://tools/bike_friendly_test.gd")
const Lab = preload("res://scripts/lab/trail_lab.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("ride_input: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func run() -> void:
	var world := Friendly.TestWorld.new()
	var ground := Pump.Ground.new(world)
	ground.profile = func(s: float) -> float: return 0.25 * (1.0 - cos(s * TAU / 6.0))
	var b := BikeRide.new()
	var player := PlayerState.new()
	b.y = 100.0
	b.mount(player)
	b.speed = 8.0
	var controls := Controls.new()
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	controls.read_bike_body(b)
	check(InputMap.event_is_action(event, "bike_pump"), "ЛКМ назначена на памп")
	check(b.pump_pressed, "ЛКМ включает памп через общий ввод")
	var active := false
	for i in 60:
		b.step(player, 0.0, 0.0, false, false, 1.0 / 60, world, ground)
		active = active or b.pump_active > 0.1
	check(active, "удержание работает на волнах")
	var release := event.duplicate() as InputEventMouseButton
	release.pressed = false
	Input.parse_input_event(release)
	Input.flush_buffered_events()
	controls.read_bike_body(b)
	var quiet := true
	for i in 30:
		b.step(player, 0.0, 0.0, false, false, 1.0 / 60, world, ground)
		quiet = quiet and b.pump_accel == 0.0 and b.pump_load == 0.0 and b._pump_reach == 0.0 and b._pump_absorb_v == 0.0 and b.pump_active == 0.0
	check(quiet, "отпущенная ЛКМ: нет сил и поглощения")
	Input.action_press("bike_pump")
	controls.read_bike_body(b, false)
	check(not b.pump_pressed, "панель блокирует памп")
	Input.action_release("bike_pump")
	for pace: float in [4.0, 16.0]:
		controls.reset()
		var first := controls.bike_steer(1.0, 1.0 / 60, pace)
		var held := first
		for i in 60: held = controls.bike_steer(1.0, 1.0 / 60, pace)
		check(first > 0.0 and first < 0.05 and held > 0.9, "мягкое начало и полный поворот при удержании на %.0f м/с" % pace)
		var reverse := controls.bike_steer(-1.0, 1.0 / 60, pace)
		check(reverse > 0.0 and held - reverse < 0.15, "перекладка не меняет знак рывком")
		for i in 60: reverse = controls.bike_steer(-1.0, 1.0 / 60, pace)
		check(reverse < -0.9, "противоположная дуга доступна")
		for i in 30: reverse = controls.bike_steer(0.0, 1.0 / 60, pace)
		check(absf(reverse) < 0.02, "отпускание возвращает руль")
	controls.reset()
	var a := 0.0
	for i in 30: a = controls.bike_steer(1.0, 1.0 / 30, 16.0)
	controls.reset()
	var c := 0.0
	for i in 120: c = controls.bike_steer(1.0, 1.0 / 120, 16.0)
	check(absf(a - c) < 0.01, "нарастание одинаково при 30/120 Гц")
	var flat := Friendly.TestGround.new(world)
	for pace: float in [8.0, 16.0]:
		var rider := BikeRide.new()
		rider.y = 100.0
		rider.mount(player)
		rider.speed = pace
		controls.reset()
		for i in 60:
			rider.step(player, 0.0, controls.bike_steer(1.0, 1.0 / 60, pace), false, false, 1.0 / 60, world, flat)
		check(absf(rider.heading) > 0.15 and not rider.crashed, "реальный поворот доступен на %.0f м/с" % pace)
	var camera := PlayerCameraController.new()
	camera.yaw = 0.7
	camera.pitch = -0.4
	b.heading = 2.0
	for i in 180: camera.follow_bike(b, 0.01, 10.0, 1.0 / 60)
	check(camera.yaw == 0.7 and camera.pitch == -0.4, "камера не доворачивает за велосипедом даже после ожидания")
	print("ride_input: %d failures" % failures)
	quit(1 if failures else 0)
