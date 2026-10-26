extends "res://tools/cyclist_animation_test.gd"
## Один запуск: численные манёвры, регрессии IK и последовательный визуальный просмотр.
## godot --path . --script res://tools/bike_traction_test.gd -- --ride-capture
const Handling = preload("res://tools/bike_handling_test.gd")
var test_world := Handling.TestWorld.new()
var test_ground := Handling.TestGround.new(test_world)
var player := PlayerState.new()
var motion_frames: Array[PackedByteArray] = []

class LandingGround extends Heightfield:
	var gradient := Vector2.ZERO
	func surface_at(px: float, pz: float, _feet := -INF) -> float:
		return ground_at(px, pz)
	func ground_at(px: float, pz: float, _raw := false) -> float:
		return 100.0 + gradient.dot(Vector2(px, pz))
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0

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
	landing_checks()
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
	var velocity := b.horizontal_velocity()
	b._crash(-3.0)
	check(Vector2(b.crash_velocity.x, b.crash_velocity.z).distance_to(velocity) < 0.00001, "Crash inherits lateral inertia")
	b.reset_motion()
	check(b.horizontal_velocity() == Vector2.ZERO and b.brake_pressure == 0 and b.slip == 0, "Reset clears transient traction state")
	# Сохраняем существующие проверки скиннинга, контактов, крайних поз и восстановления.
	await super.run(false)
	await riding_preview()
	print("Bike traction batch: ", fails, " failures")
	quit(1 if fails else 0)

func landing_checks() -> void:
	var ground := LandingGround.new()
	ground.gradient = Vector2(0, -0.3)
	var results: Array[BikeRide] = []
	for sideways in [false, true]:
		var b := make_bike(8.0)
		b.vy = -6.0
		b.airborne = true
		if sideways:
			b.heading = PI / 2.0
			b.speed = -1.5
			b.lateral_speed = 8.0
		else:
			b.lateral_speed = 1.5
		b._land(100.0, ground)
		results.append(b)
	check(absf(results[0].land_impact - results[1].land_impact) < 0.0001, "Same landing trajectory has same impact facing straight or sideways")
	check(results[0].horizontal_velocity().distance_to(results[1].horizontal_velocity()) < 0.0001, "Landing loss preserves trajectory across heading decomposition")
	check(results[0].horizontal_velocity().length() < Vector2(1.5, -8).length(), "Hard landing reduces the complete horizontal velocity")
	var normal := Vector3(0, 1, 0.3).normalized()
	var horizontal := results[0].horizontal_velocity()
	check(absf(Vector3(horizontal.x, results[0].vy, horizontal.y).dot(normal)) < 0.0001, "Grounded velocity follows the surface tangent after landing")
	ground.gradient = Vector2(0.4, 0)
	var cross := make_bike(0.0)
	cross.lateral_speed = 6
	cross.vy = -5
	cross._land(100, ground)
	var parallel := make_bike(6.0)
	parallel.vy = -5
	parallel._land(100, ground)
	check(cross.land_impact > parallel.land_impact + 1.5, "Cross-slope lateral approach contributes to landing impact")
	var crash := make_bike(4.0)
	crash.lateral_speed = 2
	crash.vy = -20
	var before := crash.horizontal_velocity()
	crash._land(100, ground)
	check(crash.crashed and crash.horizontal_velocity() == Vector2.ZERO, "Fatal landing clears every horizontal component")
	check(Vector2(crash.crash_velocity.x, crash.crash_velocity.z).distance_to(before) < 0.0001, "Fatal landing passes the full incoming velocity to ragdoll")
	print("Landing straight/side: ", results[0].land_impact, " / ", results[1].land_impact)

func riding_preview() -> void:
	bike = load("res://scenes/bike.tscn").instantiate()
	root.add_child(bike)
	body_mesh = bike.rider.skeleton.get_node("Body")
	bike.set_pack(true)
	var camera := Camera3D.new()
	root.add_child(camera)
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
	var title := Label.new()
	title.position = Vector2(24, 20)
	title.add_theme_font_size_override("font_size", 24)
	root.add_child(title)
	var capture_enabled := "--ride-capture" in OS.get_cmdline_user_args()
	for mode in ["pedal", "climb", "coast", "brake", "rough", "jump"]:
		title.text = "BIKE / " + mode.to_upper()
		test_ground.profile = func(d: float) -> float:
			if mode == "climb": return d * 0.28
			if mode == "rough": return 0.09 * exp(-pow((d - 4.0) / 0.5, 2))
			return 0.0
		floor_mesh.rotation.x = atan(0.28) if mode == "climb" else 0.0
		state = make_bike(2.5 if mode == "climb" else (6.0 if mode == "pedal" else 14.0))
		if mode in ["rough", "jump"]: state.speed = 8.0
		bike.snap(state)
		var head_start := Vector3.ZERO
		var max_pose_step := 0.0
		var previous_head := Vector3.ZERO
		var landed := false
		var fork_scale: Vector3 = bike._fork_lowers[0].get_node("Slider").scale
		for i in 180:
			var throttle := 1.0 if mode in ["pedal", "climb"] else (-1.0 if mode == "brake" and i < 60 else 0.0)
			state.step(player, throttle, 0.0, false, mode == "jump" and i == 15, DT, test_world, test_ground)
			landed = landed or state.land_impact > 0.0
			bike.tick(state, DT, throttle)
			bike.draw(1.0)
			contacts()
			if i == 0: head_start = bone("Head")
			if i > 0: max_pose_step = maxf(max_pose_step, previous_head.distance_to(bone("Head")))
			previous_head = bone("Head")
			check(bike._fork_lowers[0].get_node("Slider").scale == fork_scale, "Fork sliders translate without stretching")
			if mode == "brake" and i == 29:
				check(bone("Head").z > head_start.z + 0.025, "Brake compensation remains readable")
			if mode == "climb" and i == 90:
				check(bike._effort > 0.7 and bike._stand > 0.5, "Slow heavy climb reads as effort even with low cadence")
			state.land_impact = 0.0
			if capture_enabled and i % 4 == 0:
				var snapshot: bool = i == 28 or (mode == "jump" and i in [44, 76, 124])
				await capture_pair(camera, mode, i, snapshot)
		check(max_pose_step < 0.055, "No large pose discontinuities through " + mode)
		print("Preview ", mode, ": max head step ", max_pose_step)
		if mode == "jump": check(landed and not state.airborne, "Jump shows takeoff, absorption and recovery")
		if mode == "coast": check(bike._effort < 0.001 and absf(bike._cur[BikeView.S_SWAY]) < 0.001, "Coasting settles shoulder effort")
	if capture_enabled:
		write_motion_avi("res://tools/control/runs/bike_motion.avi", 1280, 360, 15)
	bike.free()

func capture_pair(camera: Camera3D, mode: String, frame: int, snapshot: bool) -> void:
	var images: Array[Image] = []
	for side_view in [false, true]:
		if side_view:
			camera.position = bike.position + Basis(Vector3.UP, state.heading) * Vector3(2.6, 1.65, -0.5)
			camera.look_at(bike.position + Vector3(0, 0.95, 0))
		else:
			# Та же дистанция, высота цели, наклон и FOV, что у игровой камеры.
			var target := Vector3(state.x, state.y + 1.4 - bike.view_squash() * 0.25, state.z)
			camera.position = target + Basis(Vector3.UP, state.heading) * Vector3(0, sin(0.3) * GameConfig.BIKE_CAM, cos(0.3) * GameConfig.BIKE_CAM)
			camera.look_at(target)
		camera.fov = 70 + GameConfig.BIKE_FOV * clampf((absf(state.speed) - 2.0) / (GameConfig.BIKE_SPEED - 2.0), 0, 1.3)
		await process_frame
		await RenderingServer.frame_post_draw
		var picture := root.get_texture().get_image()
		if snapshot:
			picture.save_png("res://tools/control/runs/model_" + mode + "_%03d" % frame + ("_side" if side_view else "_game") + ".png")
		picture.resize(640, 360, Image.INTERPOLATE_LANCZOS)
		picture.convert(Image.FORMAT_RGB8)
		images.append(picture)
	var pair := Image.create(1280, 360, false, Image.FORMAT_RGB8)
	pair.blit_rect(images[0], Rect2i(0, 0, 640, 360), Vector2i.ZERO)
	pair.blit_rect(images[1], Rect2i(0, 0, 640, 360), Vector2i(640, 0))
	motion_frames.append(pair.save_jpg_to_buffer(0.85))

## Небольшой MJPEG AVI без внешнего кодека/зависимостей. 18 с, два синхронных ракурса.
func write_motion_avi(path: String, width: int, height: int, fps: int) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	var count := motion_frames.size()
	var avih := PackedByteArray()
	avih.resize(56)
	for item in [[0, 1000000 / fps], [12, 16], [16, count], [24, 1], [32, width], [36, height]]:
		avih.encode_u32(item[0], int(item[1]))
	var stream := PackedByteArray()
	stream.resize(56)
	stream.encode_u32(0, 0x73646976) # vids
	stream.encode_u32(4, 0x47504a4d) # MJPG
	for item in [[20, 1], [24, fps], [32, count], [40, 0xffffffff]]:
		stream.encode_u32(item[0], item[1])
	stream.encode_u16(52, width)
	stream.encode_u16(54, height)
	var format_data := PackedByteArray()
	format_data.resize(40)
	for item in [[0, 40], [4, width], [8, height], [16, 0x47504a4d], [20, width * height * 3]]:
		format_data.encode_u32(item[0], item[1])
	format_data.encode_u16(12, 1)
	format_data.encode_u16(14, 24)
	var stream_list := "strl".to_ascii_buffer() + avi_chunk("strh", stream) + avi_chunk("strf", format_data)
	var header := "hdrl".to_ascii_buffer() + avi_chunk("avih", avih) + avi_chunk("LIST", stream_list)
	file.store_buffer("RIFF".to_ascii_buffer())
	file.store_32(0)
	file.store_buffer("AVI ".to_ascii_buffer())
	file.store_buffer(avi_chunk("LIST", header))
	file.store_buffer("LIST".to_ascii_buffer())
	var movie_size_at := file.get_position()
	file.store_32(0)
	file.store_buffer("movi".to_ascii_buffer())
	var movie_at := file.get_position() - 4
	var index := PackedByteArray()
	for picture in motion_frames:
		var entry := PackedByteArray()
		entry.resize(16)
		entry.encode_u32(0, 0x63643030) # 00dc
		entry.encode_u32(4, 16)
		entry.encode_u32(8, file.get_position() - movie_at)
		entry.encode_u32(12, picture.size())
		index.append_array(entry)
		file.store_buffer(avi_chunk("00dc", picture))
	var movie_end := file.get_position()
	file.store_buffer(avi_chunk("idx1", index))
	var end := file.get_position()
	file.seek(movie_size_at)
	file.store_32(movie_end - movie_size_at - 4)
	file.seek(4)
	file.store_32(end - 8)
	file.close()
	print("Motion AVI: ", count, " frames / ", fps, " fps")

func avi_chunk(id: String, bytes: PackedByteArray) -> PackedByteArray:
	var result := id.to_ascii_buffer()
	var size_bytes := PackedByteArray()
	size_bytes.resize(4)
	size_bytes.encode_u32(0, bytes.size())
	result.append_array(size_bytes)
	result.append_array(bytes)
	if bytes.size() % 2: result.append(0)
	return result
