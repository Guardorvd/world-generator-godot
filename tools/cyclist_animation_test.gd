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
	# draw до первого tick безопасен, а интерполяция не выходит за границы тактов.
	var initial := bike.transform
	bike.draw(1)
	check(bike.transform == initial, "Draw before state is a no-op")
	reset()
	bike.set_lamp(true)
	check(bike.lamp_on(), "Lamp enabled")
	check(bike.lamp.get_node("Beam").visible and bike.lamp.get_node("Flood").visible, "Both lamp beams enabled")
	bike.set_lamp(false)
	check(not bike.lamp_on(), "Lamp disabled")
	check(not bike.lamp.get_node("Beam").visible and not bike.lamp.get_node("Flood").visible, "Both lamp beams disabled")
	state.x += 2.0
	bike.tick(state)
	bike.draw(-1)
	check(is_equal_approx(bike.position.x, 0.0), "Interpolation lower bound")
	bike.draw(2)
	check(is_equal_approx(bike.position.x, 2.0), "Interpolation upper bound")
	# Вырожденный IK сохраняет длины двух звеньев и конечные координаты.
	for target in [Vector3.ZERO, Vector3.DOWN * 0.4]:
		var joint := bike.rider._joint(Vector3.ZERO, target, 0.43, Vector3.DOWN)
		check(joint.is_finite() and is_equal_approx(joint.length(), 0.43), "Degenerate IK has a finite joint and valid first limb")
		check(absf(joint.distance_to(target) - 0.43) < 0.001, "Degenerate IK has valid second limb")
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
	# 10.6: плечи работают в такт усилию и затихают на накате.
	var shoulder_ranges: Array[float] = []
	for boosting in [false, true]:
		reset()
		var shoulder_min := INF
		var shoulder_max := -INF
		for i in 120:
			state.crank += TAU / 60.0
			advance(1, boosting)
			var shoulder := bone("UpperArmL").z - bone("UpperArmR").z
			shoulder_min = minf(shoulder_min, shoulder)
			shoulder_max = maxf(shoulder_max, shoulder)
			contacts()
		shoulder_ranges.append(shoulder_max - shoulder_min)
	check(shoulder_ranges[0] > 0.025, "Pedalling alternates shoulders")
	check(shoulder_ranges[1] > shoulder_ranges[0] * 1.15, "Boost visibly increases body effort")
	for i in 120:
		advance()
	check(absf(bike._cur[BikeView.S_SWAY]) < 0.00001, "Coasting settles shoulder effort")
	reset()
	state.speed = 0
	var breath_min := INF
	var breath_max := -INF
	for i in 180:
		advance()
		breath_min = minf(breath_min, bone("Neck").y)
		breath_max = maxf(breath_max, bone("Neck").y)
		contacts()
	check(breath_max - breath_min > 0.003, "Resting rider breathes subtly")
	reset()
	state.squash_fv = 2
	state.squash_rv = -1
	for i in 30:
		advance()
	check(bike._cur[BikeView.S_CROUCH] > 0.018, "Moving suspension is absorbed by body and elbows")
	contacts()
	state.speed = 0
	for i in 120:
		advance()
	check(bike._cur[BikeView.S_CROUCH] < 0.00001, "No artificial road vibration when stopped")
	state.speed = 6
	state.airborne = true
	for i in 90:
		advance()
	check(absf(bike._cur[BikeView.S_CROUCH] - 0.035) < 0.0001, "Airborne pose ignores suspension vibration")
	contacts()
	reset()
	state.tilt = 0.4
	bike.snap(state)
	bike.draw(1)
	var sk := bike.rider.skeleton
	var head_world := bike.global_basis * sk.get_bone_global_pose(sk.find_bone("Head")).basis
	check(absf(head_world.get_euler().x) < 0.2, "Head stabilizes against the slope")
	# 10.6+: взгляд начинает поворот раньше плеч; усилие не переключается мгновенно.
	reset()
	state.steer = 1
	advance()
	check(absf(bike._cur[BikeView.S_LOOK]) > absf(bike._cur[BikeView.S_BODY_LOOK]) * 2.0, "Head leads shoulders into a turn")
	for i in 90:
		advance()
	check(absf(bike._cur[BikeView.S_LOOK] - bike._cur[BikeView.S_BODY_LOOK]) < 0.001, "Shoulders catch up to a steady turn")
	reset()
	state.crank += 4 * DT
	advance(1)
	check(bike._effort > 0 and bike._effort < 0.2, "Pedal effort eases in")
	for i in 60:
		state.crank += 4 * DT
		advance(1)
	var loaded := bike._effort
	advance()
	check(bike._effort < loaded and bike._effort > loaded * 0.8, "Releasing pedals retains a brief body follow-through")
	# Одинаковые толчки разными колёсами дают противоположный перенос веса.
	var road_positions: Array[float] = []
	for front in [true, false]:
		reset()
		state.squash_fv = 2.0 if front else 0.0
		state.squash_rv = 0.0 if front else 2.0
		for i in 30:
			advance()
		road_positions.append(bone("Head").z)
		contacts()
	check(road_positions[0] > neutral.z + 0.005 and road_positions[1] < neutral.z - 0.005, "Front and rear bumps shift weight in opposite directions")
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
			state.squash_fv = sin(i * DT * 12.0) * 2.0
			state.squash_rv = cos(i * DT * 9.0) * 1.5
			advance(sign_value, true)
			contacts()
	# No time integration in draw: repeated rendering cannot alter a pose.
	var held := bone("Head")
	var held_pose := bike.rider.capture_pose()
	for i in 120:
		bike.draw(1)
	check(bone("Head").is_equal_approx(held), "Render rate independence")
	check(bike.rider.capture_pose() == held_pose, "Rendering does not advance breathing or shoulder movement")
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
	check(bike._cur[BikeView.S_SWAY] == 0 and bike._cur[BikeView.S_BREATH] == 0 and bike._breath_phase == 0 and bike._effort == 0, "Snap clears effort and breathing phase")
	state.riding = false
	advance()
	check(not bike.rider.visible, "Dismount hides rig")
	var invalid: CyclistRig = load("res://scenes/cyclist.tscn").instantiate()
	root.add_child(invalid)
	invalid.skeleton.set_bone_name(invalid.skeleton.find_bone("HandL"), "MissingHand")
	var before := invalid.skeleton.get_bone_pose(0)
	invalid.pose(0, 0, Vector3.ZERO, Vector3.ZERO)
	check(not invalid._rig_valid, "Incomplete skeleton rejected")
	check(invalid.skeleton.get_bone_pose(0) == before, "Invalid rig does not write partial pose")
	invalid.free()
	print("Cyclist animation: ", fails, " failures; breathing, effort, suspension, reactions, 360 extreme poses, timing and reset")
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
	for mode in ["pedal", "rough"]:
		reset()
		state.crank = 0.4
		state.speed = 12
		state.steer = 0.45 if mode == "rough" else 0.0
		state.lean = -0.2 if mode == "rough" else 0.0
		state.squash = 0.08 if mode == "rough" else 0.0
		state.squash_f = 0.12 if mode == "rough" else 0.0
		state.squash_fv = 2.0 if mode == "rough" else 0.0
		state.squash_rv = -1.0 if mode == "rough" else 0.0
		for i in 30:
			state.crank += 4.0 * DT
			advance(1.0, true)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tools/control/runs/cyclist_106plus_" + mode + ".png")
