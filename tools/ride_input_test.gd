extends SceneTree
## Player input contracts: crisp steering, progressive braking, bunny-hop buffer/coyote, airborne Q/E pitch balance, and independent camera.

class FlatWorld extends WorldData:
	func _init() -> void:
		W = 64
		H = 64
		N = W * H
		river.resize(N)
		dist_water.resize(N)
		dist_water.fill(50.0)
		path_mask.resize(N)
		road_surface.resize(N)
	func tile_info(_x: float, _y: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = RoadSurface.PACKED}

class FlatGround extends Heightfield:
	func _init(w: WorldData) -> void:
		super()
		world = w
	func surface_at(_x: float, _z: float, _ref := -INF) -> float:
		return 100.0
	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 100.0
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func immersion_at(_x: float, _z: float, _feet: float) -> float:
		return 0.0
	func wall_at(_x: float, _z: float, _feet: float, _r := 0.0) -> bool:
		return false
	func known(_x: float, _z: float) -> bool:
		return true

var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("ride_input: ", "PASS " if ok else "FAIL ", label)
	if not ok:
		failures += 1

func run() -> void:
	var world := FlatWorld.new()
	var ground := FlatGround.new(world)
	var player := PlayerState.new()
	var controls := Controls.new()

	# 1. Q/E ввод баланса и блокировка панелями
	var b := BikeRide.new()
	b.x = 128.0; b.z = 128.0; b.y = 100.0; b.mount(player); b.speed = 8.0
	Input.action_press("bike_back")
	controls.read_bike_body(b, true)
	check(b.body_back and not b.body_forward, "Q включает наклон назад")
	Input.action_press("bike_forward")
	controls.read_bike_body(b, true)
	check(b.body_forward, "E доступна при нажатой Q")
	controls.read_bike_body(b, false)
	check(not b.body_back and not b.body_forward, "блокировка интерфейса снимает ввод Q/E")
	Input.action_release("bike_back")
	Input.action_release("bike_forward")

	# 2. Кривая руля: отзывчивая, монотонная, одинаковая на разных FPS
	for pace: float in [4.0, 16.0]:
		controls.reset()
		var first := controls.bike_steer(1.0, 1.0 / 60.0, pace)
		var held := first
		var monotonic := true
		for i in 30:
			var prev := held
			held = controls.bike_steer(1.0, 1.0 / 60.0, pace)
			if held < prev - 0.0001:
				monotonic = false
		check(first > 0.25 and monotonic and held > 0.99, "быстрый и плавный набор руля на %.0f м/с (%.2f)" % [pace, held])
		for i in 30:
			held = controls.bike_steer(-1.0, 1.0 / 60.0, pace)
		check(held < -0.95, "быстрая перекладка руля в другую сторону (%.2f)" % held)
		for i in 20:
			held = controls.bike_steer(0.0, 1.0 / 60.0, pace)
		check(absf(held) < 0.02, "отпускание возвращает руль в центр")

	controls.reset()
	var r30 := 0.0
	for i in 15: r30 = controls.bike_steer(1.0, 1.0 / 30.0, 12.0)
	controls.reset()
	var r120 := 0.0
	for i in 60: r120 = controls.bike_steer(1.0, 1.0 / 120.0, 12.0)
	check(absf(r30 - r120) < 0.02, "кривая руля независима от частоты 30/120 Гц")
	controls.reset_motion()
	var slalom := BikeRide.new()
	slalom.x = 128.0
	slalom.z = 128.0
	slalom.y = 100.0
	slalom.mount(player)
	slalom.speed = 20.0
	var max_switch := 0
	var peak_lat := 0.0
	for direction: float in [1.0, -1.0, 1.0, -1.0]:
		var switch_tick := 13
		for i in 12:
			var command := controls.bike_steer(direction, 1.0 / 60.0, slalom.speed)
			slalom.step(player, 0.0, command, false, false, 1.0 / 60.0, world, ground)
			if slalom.yaw_rate * direction < -0.01:
				switch_tick = mini(switch_tick, i + 1)
			peak_lat = maxf(peak_lat, absf(slalom.yaw_rate * slalom.speed))
		max_switch = maxi(max_switch, switch_tick)
	check(not slalom.crashed and max_switch <= 4 and peak_lat <= slalom.config.max_lat_accel + 0.02,
		"серия перекладок с 20 м/с: смена дуги за %d такта, пик %.2f м/с²" % [max_switch, peak_lat])

	# 3. Тормоз
	controls.reset()
	var brake_tap := controls.bike_brake(-1.0, 1.0 / 60.0)
	var brake_held := brake_tap
	for i in 30:
		brake_held = controls.bike_brake(-1.0, 1.0 / 60.0)
	check(brake_tap > -0.5 and brake_tap < -0.1 and brake_held < -0.99 and controls.bike_brake(0.7, 1.0 / 60.0) == 0.7,
		"тормоз плавно набирается с клавиатуры, газ проходит как есть")

	# 4. Буфер и coyote time для Space + удержание угла в воздухе Q/E
	var c := BikeRide.new()
	c.x = 128.0; c.z = 128.0; c.y = 100.0; c.mount(player); c.speed = 9.0
	c.airborne = true; c.air_time = 0.03; c._coyote = c.config.hop_coyote; c.y = 100.1
	c.step(player, 0.0, 0.0, false, true, 1.0 / 60.0, world, ground)
	check(c.vy > 3.0 and c.hop_used, "Space в окне coyote запускает прыжок")

	var jumper := BikeRide.new()
	jumper.x = 128.0; jumper.z = 128.0; jumper.y = 100.0; jumper.mount(player); jumper.speed = 11.0
	jumper.step(player, 0.0, 0.0, false, true, 1.0 / 60.0, world, ground)
	for i in 12:
		jumper.body_back = true
		jumper.step(player, 0.0, 0.0, false, false, 1.0 / 60.0, world, ground)
	var tilt_after_q := jumper.tilt
	jumper.body_back = false
	for i in 6:
		jumper.step(player, 0.0, 0.0, false, false, 1.0 / 60.0, world, ground)
	check(absf(jumper.tilt - tilt_after_q) < 0.08, "выбранный Q/E угол держится после отпускания клавиши")

	# 5. Камера не доворачивает за курсом велосипеда
	var camera := PlayerCameraController.new()
	camera.yaw = 0.7
	camera.pitch = -0.4
	camera.heights = ground
	camera.settings = GameSettings.new()
	var cam_node := Camera3D.new()
	root.add_child(cam_node)
	b.heading = 2.0
	b.riding = true
	for i in 60:
		camera.update(1.0, 1.0 / 60.0, player, b, cam_node, 10.0 + i / 60.0, false, false, false, false, 70.0, 0.0)
	check(camera.yaw == 0.7 and camera.pitch == -0.4, "камера не доворачивает за велосипедом")
	b.speed = 16.0
	camera.settings.head_bob = true
	camera.store_previous(player, 11.0)
	var horizon := Vector3(cos(camera.yaw), 0.0, -sin(camera.yaw))
	camera.update(0.5, 1.0 / 60.0, player, b, cam_node, 11.0, false, false, false, false, 70.0, 0.0, NAN, -0.24)
	var first_roll := horizon.signed_angle_to(cam_node.global_basis.x, cam_node.global_basis.z)
	camera.update(0.5, 1.0 / 60.0, player, b, cam_node, 11.0, false, false, false, false, 70.0, 0.0, NAN, 0.24)
	var second_roll := horizon.signed_angle_to(cam_node.global_basis.x, cam_node.global_basis.z)
	check(first_roll < -0.01 and second_roll > 0.01, "горизонт меняет крен вместе с кадром велосипеда (%.3f / %.3f рад)" % [first_roll, second_roll])
	cam_node.free()
	print("ride_input: %d failures" % failures)
	quit(1 if failures else 0)
