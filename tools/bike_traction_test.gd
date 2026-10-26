extends "res://tools/cyclist_animation_test.gd"
## Один запуск: численные манёвры, регрессии IK и последовательный визуальный просмотр.
## godot --path . --script res://tools/bike_traction_test.gd -- --ride-capture
const Handling = preload("res://tools/bike_handling_test.gd")
const Water = preload("res://tools/bike_water_test.gd")
var test_world := Handling.TestWorld.new()
var test_ground := Handling.TestGround.new(test_world)
var player := PlayerState.new()

func _init() -> void:
	batch.call_deferred()

func make_bike(pace := 12.0) -> BikeRide:
	var b := BikeRide.new()
	b.y = test_ground.ground_at(0, 0)
	b.speed = pace
	b.riding = true
	return b

func step_ride(b: BikeRide, throttle: float, turn := 0.0, dt := DT) -> void:
	b.step(player, throttle, turn, false, false, dt, test_world, test_ground)

func stopping(surface: int, hz: int, turn := 0.0) -> Dictionary:
	test_world.surface = surface
	var b := make_bike()
	var distance := 0.0
	var peak_slip := 0.0
	var time := 0.0
	for i in hz * 6:
		var before := Vector2(b.x, b.z)
		step_ride(b, -1.0, turn, 1.0 / hz)
		distance += before.distance_to(Vector2(b.x, b.z))
		peak_slip = maxf(peak_slip, absf(b.slip))
		time += 1.0 / hz
		if b.speed <= 0.05:
			break
	return {distance = distance, time = time, slip = peak_slip, bike = b}

func batch() -> void:
	var packed := stopping(RoadSurface.PACKED, 60)
	var sand := stopping(RoadSurface.SAND, 60)
	print("STOP 12m/s: packed %.3fm %.3fs; sand %.3fm %.3fs" % [packed.distance, packed.time, sand.distance, sand.time])
	check(sand.distance > packed.distance * 1.12, "Loose surface measurably lengthens stopping distance")
	check(packed.time > 1.1 and packed.time < 2.0, "Full brake stops quickly without an instant speed cut")
	var slow := stopping(RoadSurface.SAND, 30, 1.0)
	var fast := stopping(RoadSurface.SAND, 120, 1.0)
	print("30/120Hz brake+turn: distance %.3f/%.3f; time %.3f/%.3f; heading %.3f/%.3f" % [slow.distance, fast.distance, slow.time, fast.time, slow.bike.heading, fast.bike.heading])
	check(absf(slow.distance - fast.distance) < 0.12 and absf(slow.bike.heading - fast.bike.heading) < 0.035, "30/120Hz stopping trajectory remains close")
	test_world.surface = RoadSurface.PACKED
	var b := make_bike(16.0)
	var gentle := make_bike(16.0)
	var max_slip := 0.0
	var gentle_slip := 0.0
	for i in 45:
		step_ride(b, -1.0, 1.0)
		step_ride(gentle, 0.0, 0.22)
		max_slip = maxf(max_slip, absf(b.slip))
		gentle_slip = maxf(gentle_slip, absf(gentle.slip))
		check(not b.crashed and b.horizontal_velocity().length() < 16.01, "Combined brake/corner stays upright without gaining energy")
	print("SLIP hard brake %.2fdeg; gentle %.2fdeg" % [rad_to_deg(max_slip), rad_to_deg(gentle_slip)])
	check(max_slip > deg_to_rad(2.0) and max_slip < deg_to_rad(15.0), "Hard brake in turn gives small readable slip")
	check(gentle_slip < deg_to_rad(3.5), "Ordinary corner stays planted")
	for i in 90:
		step_ride(b, 0.0)
	check(absf(b.lateral_speed) < 0.04 and absf(b.slip) < 0.01, "Released steering/brake smoothly recovers grip")
	b = make_bike(16.0)
	max_slip = 0.0
	for i in 180:
		step_ride(b, 0.6, 1.0)
		max_slip = maxf(max_slip, absf(b.slip))
	print("SUSTAINED full steering: %.2fdeg slip, %.2fm/s" % [rad_to_deg(max_slip), b.speed])
	check(max_slip < deg_to_rad(15.0) and b.speed > 6.0, "Sustained full steering remains controllable")
	b = make_bike(0.0)
	for i in 30:
		step_ride(b, 0.0, 1.0)
	check(b.heading == 0.0 and b.lean == 0.0, "Automatic balance holds a stationary bike upright")
	b = make_bike(-1.5)
	for i in 30:
		step_ride(b, -1.0, 1.0)
	check(b.heading > 0.1 and b.speed < 0.0, "Low speed steering and reverse remain responsive")
	b = make_bike(0.0)
	for i in 30:
		step_ride(b, 1.0)
	check(b.speed > 2.5 and b.speed < 3.5, "Existing responsive pedal start is preserved")
	b = make_bike(11.0)
	for i in 120:
		step_ride(b, 0.0)
	check(b.speed > 8.6 and b.speed < 10.0, "Existing coasting momentum is preserved")
	b = make_bike(8.0)
	b.step(player, 0, 0, false, true, DT, test_world, test_ground)
	check(b.airborne and b.vy > 3.0, "Hop responds immediately with internal substeps")
	var apex := b.y
	for i in 90:
		step_ride(b, 0.0)
		apex = maxf(apex, b.y)
	check(not b.airborne and not b.crashed and apex > 100.4 and apex < 100.7, "Hop lands safely with unchanged useful height")
	# Нажатие на ходу не копит ожидание заднего хода; удержание начинается с остановки.
	for grade_value in [-0.4, 0.4]:
		test_ground.profile = func(d: float) -> float: return d * grade_value
		var stop := stopping(RoadSurface.PACKED, 60)
		b = stop.bike
		var at := Vector2(b.x, b.z)
		for i in 12:
			step_ride(b, -1.0)
		check(b.speed == 0.0 and at.distance_to(Vector2(b.x, b.z)) < 0.002, "Brake holds slope before deliberate reverse")
		for i in 60:
			step_ride(b, -1.0)
		check(b.speed < -1.0, "Continued hold starts controlled reverse on either slope")
		b = make_bike(0.0)
		at = Vector2(b.x, b.z)
		for i in 120:
			step_ride(b, -0.4)
		check(b.speed == 0.0 and at.distance_to(Vector2(b.x, b.z)) < 0.002, "Partial brake holds slope without reverse")
	test_ground.profile = func(_d: float) -> float: return 0.0
	b = make_bike()
	step_ride(b, -1.0)
	var first_force := b.brake_deceleration
	for i in 20:
		step_ride(b, -1.0)
	check(first_force > 0.0 and first_force < b.brake_deceleration * 0.3, "Brake pressure rises progressively")
	check(b.front_load > 0.65 and b.squash_f > b.squash_r + 0.03, "Actual braking transfers load and compresses fork")
	for i in 90:
		step_ride(b, 0.0)
	check(b.brake_deceleration < 0.01 and absf(b.front_load - 0.5) < 0.01, "Brake load settles after release")
	b = make_bike()
	b.airborne = true
	b.y += 20.0
	var initial := b.horizontal_velocity().normalized()
	for i in 30:
		step_ride(b, -1.0, 1.0)
	check(absf(b.heading) > 0.03 and initial.dot(b.horizontal_velocity().normalized()) > 0.9999, "Airborne frame turns without rotating flight velocity")
	b.lateral_speed = 0.8
	b._water_drift = Vector2(0.3, -0.1)
	var velocity := b.horizontal_velocity()
	b._crash(-3.0)
	check(Vector2(b.crash_velocity.x, b.crash_velocity.z).distance_to(velocity) < 0.00001, "Crash inherits lateral inertia and current together")
	b.reset_motion()
	check(b.horizontal_velocity() == Vector2.ZERO and b.brake_pressure == 0 and b.slip == 0, "Reset clears transient traction state")
	# Тот же брод и его границы, без генерации мира.
	var water_ground := Water.TestGround.new()
	var water_world := Water.TestWorld.new()
	var water_bike := BikeRide.new()
	water_bike.speed = 3
	for i in 60:
		water_bike.step(player, 0, 0, false, false, DT, water_world, water_ground)
	check(water_bike.x > 0.05, "Current still moves bike laterally")
	water_ground.wall = true
	water_bike.reset_motion()
	water_bike.x = 0
	water_bike.z = 0
	for i in 60:
		water_bike.step(player, 0, 0, false, false, DT, water_world, water_ground)
	check(water_bike.x <= 0.15, "Water drift still respects collisions")
	water_ground.wall = false
	var flow_results: Array[Vector3] = []
	for hz in [30, 120]:
		water_bike = BikeRide.new()
		water_bike.speed = 3
		for i in hz:
			water_bike.step(player, 0, 0, false, false, 1.0 / hz, water_world, water_ground)
		flow_results.append(Vector3(water_bike.x, water_bike.speed, water_bike.z))
	check(flow_results[0].distance_to(flow_results[1]) < 0.02, "Current and traction agree at 30/120Hz")
	# Сохраняем существующие проверки скиннинга, контактов, крайних поз и восстановления.
	await super.run(false)
	await riding_preview()
	print("Bike traction batch: ", fails, " failures")
	quit(1 if fails else 0)

func riding_preview() -> void:
	bike = load("res://scenes/bike.tscn").instantiate()
	root.add_child(bike)
	var camera := Camera3D.new()
	root.add_child(camera)
	var camera_control := preload("res://scripts/render/player_camera_controller.gd").new()
	camera_control.settings = GameSettings.new()
	camera_control.heights = test_ground
	camera_control.pitch = -0.3
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.rotation_degrees = Vector3(-40, -30, 0)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("92afc0")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.65
	root.add_child(env)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	floor_mesh.mesh = plane
	floor_mesh.position.y = 99.99
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("827b5a")
	floor_mesh.material_override = mat
	root.add_child(floor_mesh)
	for mode in ["coast", "brake", "turn_brake", "recover"]:
		state = make_bike(14.0)
		bike.snap(state)
		var head_start := Vector3.ZERO
		for i in 60:
			var braking_now: bool = mode == "brake" or mode == "turn_brake" or (mode == "recover" and i < 20)
			step_ride(state, -1.0 if braking_now else 0.0, 1.0 if mode == "turn_brake" else 0.0)
			bike.tick(state, DT, -1.0 if braking_now else 0.0)
			bike.draw(1.0)
			contacts()
			if i == 0:
				head_start = bone("Head")
			if i == 29:
				if mode == "brake":
					check(bone("Head").z > head_start.z + 0.025, "Physical braking produces visible rearward brace")
				if "--ride-capture" in OS.get_cmdline_user_args():
					camera_control.yaw = state.heading
					camera_control._cam_y = state.y + 1.4
					camera_control.store_previous(player, 5.0)
					camera_control.update(1.0, DT, player, state, camera, 5.0, false, true, false, false, 70.0, bike.view_squash())
					await process_frame
					await process_frame
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png("res://tools/control/runs/traction_" + mode + ".png")
					# Дополнительный ракурс в той же сцене: видны руки, ноги и сжатие вилки.
					camera.position = bike.position + Basis(Vector3.UP, state.heading) * Vector3(2.6, 1.65, -0.5)
					camera.look_at(bike.position + Vector3(0, 0.95, 0))
					await process_frame
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png("res://tools/control/runs/traction_" + mode + "_side.png")
		if mode == "recover":
			check(absf(bike._cur[BikeView.S_SHIFT]) < 0.015, "Rider releases brake pose smoothly")
	bike.free()
