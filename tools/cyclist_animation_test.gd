extends SceneTree
## 7.5: behavior and contact checks, independent of rendering frequency.
var fails := 0
var bike: BikeView
var state: BikeRide
const DT := 1.0 / 60.0

func _init() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		push_error(label)
		fails += 1

func bone(bone_name: String) -> Vector3:
	var sk: Skeleton3D = bike.rider.skeleton
	return sk.get_bone_global_pose(sk.find_bone(bone_name)).origin

func reset() -> void:
	state = BikeRide.new()
	state.riding = true
	state.speed = 6
	bike.snap(state)
	bike.draw(1)

func advance(throttle := 0.0, boost := false, dt := DT) -> void:
	bike.tick(state, dt, throttle, boost)
	bike.draw(1)
	state.land_impact = 0

func contacts() -> void:
	for side in ["L", "R"]:
		var pedal: Node3D = bike.pedal_l if side == "L" else bike.pedal_r
		check(bone("Foot" + side).distance_to(bike.to_local(pedal.global_position) + Vector3(0, 0.055, 0.025)) < 0.001, "Foot contact")
		var grip := bike._steering.position + bike._steering.basis * Vector3(-0.24 if side == "L" else 0.24, 0.22, -0.015)
		check(bone("Hand" + side).distance_to(grip) < 0.001, "Hand contact")
		for pair in [["UpperArm", "Forearm", 0.31], ["Forearm", "Hand", 0.31], ["UpperLeg", "LowerLeg", 0.43], ["LowerLeg", "Foot", 0.43]]:
			check(absf(bone(pair[0] + side).distance_to(bone(pair[1] + side)) - pair[2]) < 0.001, "Limb reach: " + pair[0])

func run() -> void:
	bike = load("res://scenes/bike.tscn").instantiate()
	root.add_child(bike)
	reset()
	var neutral := bone("Head")
	# Pedalling adds a small vertical response; coasting lets it settle completely.
	for i in 60:
		state.crank += 4 * DT
		advance(1)
	check(bike._cur[BikeView.S_CROUCH] > 0.001, "Pedalling adds subtle body bob")
	contacts()
	for i in 120:
		advance()
	check(bike._cur[BikeView.S_CROUCH] < 0.00001, "Coasting settles pedal bob")
	reset()
	for i in 30:
		state.speed += 4 * DT
		state.crank += 4 * DT
		advance(1)
	check(bone("Head").z < neutral.z - 0.015, "Acceleration leans forward")
	reset()
	for i in 30:
		state.speed -= 4 * DT
		advance(-1)
	check(bone("Head").z > neutral.z + 0.025, "Braking shifts weight back")
	reset()
	state.tilt = 0.4
	for i in 40:
		advance()
	check(bone("Head").z < neutral.z - 0.025, "Climb shifts weight forward")
	reset()
	state.tilt = -0.4
	for i in 40:
		advance()
	check(bone("Head").z > neutral.z + 0.025, "Descent shifts weight back")
	reset()
	state.steer = 1
	state.lean = -0.28
	for i in 40:
		advance()
	check(bone("Head").x > 0.025, "Balance into turn")
	check(bike.rider.skeleton.get_bone_global_pose(5).basis.get_euler().y < -0.15, "Look into turn")
	reset()
	state.airborne = true
	for i in 30:
		advance()
	check(bone("Head").y < neutral.y - 0.03, "Airborne tuck")
	state.airborne = false
	state.land_impact = 9
	for i in 5:
		advance()
	check(bone("Head").y < neutral.y - 0.025, "Landing absorption")
	for i in 120:
		advance()
	check(bone("Head").distance_to(neutral) < 0.001, "Landing settles")
	# Extreme combined inputs through a full pedal revolution, including angle wrap.
	for sign_value in [-1.0, 1.0]:
		reset()
		state.steer = sign_value
		state.lean = -sign_value * 0.28
		state.tilt = sign_value * 0.5
		state.squash = 0.16
		for i in 180:
			state.airborne = i >= 60 and i < 110
			state.land_impact = 10 if i == 110 else 0
			state.crank = fmod(state.crank + 6 * DT, TAU)
			state.speed = 12 + sin(i * DT) * 3
			advance(sign_value, true)
			contacts()
	# No time integration in draw: repeated rendering cannot alter a pose.
	var held := bone("Head")
	for i in 120:
		bike.draw(1)
	check(bone("Head").is_equal_approx(held), "Render rate independence")
	var results: Array[Vector3] = []
	for hz in [30, 60, 120]:
		reset()
		for i in hz:
			state.speed += 3.0 / hz
			advance(1, false, 1.0 / hz)
		results.append(bone("Head"))
	check(results[0].distance_to(results[2]) < 0.001, "Physics rate independence")
	state.land_impact = 10
	advance()
	bike.snap(state)
	bike.draw(1)
	check(bike._landing == 0, "Snap clears transient motion")
	state.riding = false
	advance()
	check(not bike.rider.visible, "Dismount hides rig")
	print("Cyclist animation: ", fails, " failures; reactions, 360 extreme poses, timing and reset")
	if "--capture" in OS.get_cmdline_user_args():
		await capture()
	bike.free()
	quit(1 if fails else 0)

func capture() -> void:
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(2.8, 1.9, -2.8)
	camera.look_at(Vector3(0, 0.9, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.4
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.rotation_degrees = Vector3(-40, -30, 0)
	var environment := WorldEnvironment.new()
	root.add_child(environment)
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("a6bbc5")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.6
	for mode in ["brake", "turn", "jump"]:
		reset()
		state.crank = 1.2
		state.steer = 1.0 if mode == "turn" else 0.0
		state.lean = -0.28 if mode == "turn" else 0.0
		state.airborne = mode == "jump"
		state.tilt = 0.3 if mode == "jump" else 0.0
		for i in 30:
			if mode == "brake":
				state.speed -= 4 * DT
			advance(-1.0 if mode == "brake" else 0.0)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tools/control/runs/cyclist_75_" + mode + ".png")
