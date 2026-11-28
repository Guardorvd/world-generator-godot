extends SceneTree
## 7.5: behavior and contact checks, independent of rendering frequency.
var fails := 0
var bike: BikeView
var state: BikeRide
const DT := 1.0 / 60.0
var body_mesh: MeshInstance3D
var skin_samples: Array[Dictionary] = []

class PreviewWorld extends WorldData:
	var path := 0

	func accessible(_x: float, _z: float, _margin := 0.0) -> bool:
		return true
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = path}

class PreviewGround extends Heightfield:
	var grade := Vector2.ZERO
	var reference := Vector2.ZERO
	func _init(data: WorldData) -> void:
		super()
		world = data
	func ground_at(x: float, z: float, _raw := false) -> float:
		return grade.dot(Vector2(x, z) - reference)
	func surface_at(x: float, z: float, _feet := -INF) -> float:
		return ground_at(x, z)
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true

class PreviewProfileGround extends PreviewGround:
	var profile: Callable
	func ground_at(x: float, z: float, _raw := false) -> float:
		return float(profile.call(-z)) if profile.is_valid() else super.ground_at(x, z, _raw)

class RoughTurnGround extends PreviewGround:
	func ground_at(x: float, z: float, _raw := false) -> float:
		return super.ground_at(x, z) + 0.026 * sin(z * 3.8) + 0.014 * sin(z * 8.1 + x * 2.5)

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
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
	_speed_before = state.speed
	bike.snap(state)
	bike.draw(1)

var _speed_before := 0.0

## Вид читает сигналы, которые считает BikeRide.step (усилие, реализованная тяга, уклон земли, ускорение
## за такт); здесь состояние задано вручную, поэтому они выводятся из него так же, как в физике.
func advance(throttle := 0.0, boost := false, dt := DT) -> void:
	state.feel_acceleration = (state.speed - _speed_before) / dt
	_speed_before = state.speed
	state.grade_now = state.tilt
	state.rider_lean = state.lean
	state._step_effort(maxf(throttle, 0.0) if not state.airborne else 0.0, dt)
	var cfg := state.config if state.config != null else BikePhysicsConfig.current()
	state.drive_force = cfg.pedal_accel * cfg.start_push_mult * state.effort * 0.5
	var braking := maxf(0.0, -state.feel_acceleration) if throttle < 0.0 else 0.0
	if throttle < 0.0:
		state.brake_applied = braking
		state.brake_pressure = clampf(braking / maxf(cfg.brake_decel, 1.0), 0.0, 1.0)
	state.brake_force = Vector2(braking * 0.6, braking * 0.4)
	bike.tick(state, dt, throttle, boost)
	bike.draw(1)
	state.land_impact = 0

func _check_model() -> void:
	body_mesh = bike.rider.skeleton.get_node("Body") as MeshInstance3D
	check(bike.rider.get_meta("model_version", 0) == 9 and body_mesh != null, "Ninth model version uses one native skinned body")
	if body_mesh == null:
		return
	var sk := bike.rider.skeleton
	check(body_mesh.get_node(body_mesh.skeleton) == sk and body_mesh.skin.get_bind_count() == 22, "Skin uses the existing 22-bone skeleton")
	for i in body_mesh.skin.get_bind_count():
		check(body_mesh.skin.get_bind_bone(i) == i and (sk.get_bone_global_rest(i) * body_mesh.skin.get_bind_pose(i)).is_equal_approx(Transform3D.IDENTITY), "Skin inverse bind matches bone rest")
	check(body_mesh.extra_cull_margin >= BikeCrash.GROUND_R + 1.0, "Skin culling margin covers the ragdoll contact region")
	var triangles := 0
	var valid := true
	for surface in body_mesh.mesh.get_surface_count():
		var data := body_mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = data[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = data[Mesh.ARRAY_WEIGHTS]
		var indices: PackedInt32Array = data[Mesh.ARRAY_INDEX]
		var normals: PackedVector3Array = data[Mesh.ARRAY_NORMAL]
		triangles += indices.size() / 3
		for i in range(0, indices.size(), 3):
			var normal := (vertices[indices[i + 1]] - vertices[indices[i]]).cross(vertices[indices[i + 2]] - vertices[indices[i]])
			valid = valid and normal.dot(normals[indices[i]]) < 0.0
		valid = valid and bones.size() == vertices.size() * 4 and weights.size() == vertices.size() * 4
		for i in vertices.size():
			var total := 0.0
			for j in 4:
				var at := i * 4 + j
				valid = valid and bones[at] >= 0 and bones[at] < 22 and is_finite(weights[at]) and weights[at] >= 0
				total += weights[at]
			valid = valid and vertices[i].is_finite() and absf(total - 1.0) < 0.0001
		for i in range(0, vertices.size(), maxi(1, vertices.size() / 20)):
			skin_samples.append({position = vertices[i], bones = bones.slice(i * 4, i * 4 + 4), weights = weights.slice(i * 4, i * 4 + 4)})
	check(valid, "Skin weights, bone indices and outward triangle winding are valid")
	# 17.11 (v9): одна поверхность с общим материалом велосипеда и седока; ткань, кожа, скорлупа шлема, стекло и обувь
	# различаются видом поверхности в вершинах (UV.y), цвет — местом палитры (UV.x)
	check(triangles < 7500 and body_mesh.mesh.get_surface_count() == 1, "Model stays within 7500 triangles in one surface (one draw call)")
	var mat := body_mesh.material_override as ShaderMaterial
	var kinds := {}
	var slots := {}
	for uv: Vector2 in body_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]:
		slots[roundi(uv.x)] = true
		kinds[roundi(uv.y)] = true
	check(mat != null and mat.shader == preload("res://resources/bike_rider.gdshader") and kinds.size() >= 6 and slots.size() >= 8, "Shared material distinguishes fabric, skin, helmet shell, lens and shoes")
	print("Cyclist v9 geometry: ", triangles, " triangles, ", body_mesh.mesh.get_surface_count(), " surfaces, ", kinds.size(), " surface kinds")


func check_skin_pose() -> void:
	# Проверяем и геометрию после skinning, а не только положение костей.
	if body_mesh != null:
		var palette: Array[Transform3D] = []
		for i in 22:
			palette.append(bike.rider.skeleton.get_bone_global_pose(i) * body_mesh.skin.get_bind_pose(i))
		var valid := true
		for sample in skin_samples:
			var posed := Vector3.ZERO
			for j in 4:
				posed += (palette[sample.bones[j]] * sample.position) * sample.weights[j]
			valid = valid and posed.is_finite() and posed.distance_to(bone("Hips")) < 2.0
		check(valid, "Deformed mesh remains finite and within the rider envelope")


func contacts() -> void:
	check_skin_pose()
	if bike._fork_lowers.size() >= 2:
		var axle := Vector3.ZERO
		for i in 2:
			axle += bike._fork_lowers[i].global_transform * Vector3(-0.055 if i == 0 else 0.055, 0.34, -0.53) * 0.5
		check(axle.distance_to(bike.front_wheel.global_position) < 0.001, "Fork axle remains aligned during steering and suspension travel")
	var neck_length := bone("Head").distance_to(bone("Neck"))
	check(neck_length > 0.14 and neck_length < 0.18, "Neck remains connected without stretching in every pose")
	for side in ["L", "R"]:
		var pedal: Node3D = bike.pedal_l if side == "L" else bike.pedal_r
		var sk := bike.rider.skeleton
		var foot_pose := sk.get_bone_global_pose(sk.find_bone("Foot" + side))
		check((foot_pose * CyclistRig.PEDAL_CONTACT_LOCAL).distance_to(bike.to_local(pedal.global_position)) < 0.001, "Foot contact")
		var platform := bike.global_basis.inverse() * pedal.global_basis
		check(absf(platform.z.y - foot_pose.basis.z.y) < 0.002, "Pedal platform follows heel pitch about the spindle")
		var grip := bike._steering.position + bike._steering.basis * (BikeView.GRIP * Vector3(-1.0 if side == "L" else 1.0, 1, 1) - BikeView.STEERING_PIVOT)
		check(bone("Hand" + side).distance_to(grip) < 0.001, "Hand contact")
		var upper_arm := sk.get_bone_global_pose(sk.find_bone("UpperArm" + side)).basis
		var forearm := sk.get_bone_global_pose(sk.find_bone("Forearm" + side)).basis
		var upper_leg := sk.get_bone_global_pose(sk.find_bone("UpperLeg" + side)).basis
		var lower_leg := sk.get_bone_global_pose(sk.find_bone("LowerLeg" + side)).basis
		check(upper_arm.x.dot(forearm.x) > 0.999 and upper_leg.x.dot(lower_leg.x) > 0.999, "Elbow and knee hinges remain twist-free")
		for pair in [["UpperArm", "Forearm", 0.31], ["Forearm", "Hand", 0.31], ["UpperLeg", "LowerLeg", 0.43], ["LowerLeg", "Foot", 0.43]]:
			check(absf(bone(pair[0] + side).distance_to(bone(pair[1] + side)) - pair[2]) < 0.001, "Limb reach: " + pair[0])

func run(finish := true) -> void:
	bike = load("res://scenes/bike.tscn").instantiate()
	root.add_child(bike)
	if "--turn-probe" in OS.get_cmdline_user_args():
		check_turn_transitions("--assert" in OS.get_cmdline_user_args())
		bike.free()
		quit(1 if fails else 0)
		return
	if "--small-steer-probe" in OS.get_cmdline_user_args():
		check_small_steering("--assert" in OS.get_cmdline_user_args())
		bike.free()
		quit(1 if fails else 0)
		return
	_check_model()
	reset()
	state.speed = 7.5
	advance(0.65)
	var grip := bone("HandL")
	var right := bone("HandR")
	bike.watch_requested = true
	for i in 26:
		state.crank += 4.0 * DT
		advance(0.65)
	check(bone("HandL").y > grip.y + 0.07 and bone("HandR").is_equal_approx(right), "Watch raises only the left hand")
	var watch_skeleton := bike.rider.skeleton
	var head := watch_skeleton.get_bone_global_pose(watch_skeleton.find_bone("Head"))
	var hand := watch_skeleton.get_bone_global_pose(watch_skeleton.find_bone("HandL"))
	var eye := head * Vector3(0.0, 0.045, -0.07)
	var screen := hand * Vector3(0.0, 0.033, 0.036)
	var glance := eye.direction_to(screen)
	check((-head.basis.z).dot(glance) > 0.75 and hand.basis.y.dot(-glance) > 0.35, "Rider looks down at the wrist screen")
	bike.watch_requested = false
	advance(0.65)
	check(bike._cur[BikeView.S_WATCH] > 0.0 and bike._cur[BikeView.S_WATCH] < 1.0, "Release lowers the hand without snapping")
	for i in 20:
		advance(0.65)
	check(bike._cur[BikeView.S_WATCH] == 0.0, "Release returns the left hand to the grip")
	bike.watch_requested = true
	for i in 26:
		advance(0.65)
	check(bike._cur[BikeView.S_WATCH] > 0.9, "Watch pose is active before snapping to a new position")
	bike.watch_requested = false
	state.x += 10.0
	bike.snap(state)
	bike.draw(1.0)
	check(bike._cur[BikeView.S_WATCH] == 0.0 and bone("HandL").distance_to(bike._rider_pose.left_grip) < 0.001,
		"Snapping clears the watch pose and puts the hand back on the grip")
	bike.watch_requested = true
	for unsafe in ["speed", "air", "turn", "brake"]:
		state.speed = 2.0
		state.airborne = false
		state.steer = 0.0
		state.brake_pressure = 0.0
		bike.snap(state)
		for i in 25:
			advance()
		check(bike._cur[BikeView.S_WATCH] > 0.5, "Watch pose is active before " + unsafe)
		state.speed = 12.0 if unsafe == "speed" else 2.0
		state.airborne = unsafe == "air"
		state.steer = 0.6 if unsafe == "turn" else 0.0
		state.brake_pressure = 0.8 if unsafe == "brake" else 0.0
		for i in ceili(BikeView.WATCH_BRACE / DT) + 1:
			advance()
		check(bike._cur[BikeView.S_WATCH] == 0.0, "Watch yields promptly to " + unsafe)
	bike.watch_requested = false
	reset()
	# draw до первого tick безопасен, а интерполяция не выходит за границы тактов.
	var initial := bike.transform
	bike.draw(1)
	check(bike.transform == initial, "Draw before state is a no-op")
	reset()
	bike.set_lamp(true)
	check(bike.lamp_on(), "Lamp enabled")
	check(bike.lamp.get_node("Beam").visible and bike.lamp.get_node("LensHalo").visible, "Lamp beam and lens halo enabled")
	bike.set_lamp(false)
	check(not bike.lamp_on(), "Lamp disabled")
	check(not bike.lamp.get_node("Beam").visible and not bike.lamp.get_node("LensHalo").visible, "Lamp beam and lens halo disabled")
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
	state.speed = 0.0
	state.brake_pressure = 1.0
	state.load_f = 0.98
	for i in 30:
		advance()
	check(bike._cur[BikeView.S_BRAKE] > 0.95 and absf(bike._cur[BikeView.S_STAND]) < 0.02
		and is_zero_approx(bike._cur[BikeView.S_BRAKE_POSE]), "Holding a brake lever without tyre force does not brace the body")
	reset()
	state.speed = 14.0
	state.brake_risk = 0.8
	for i in 30:
		advance()
	check(bike._cur[BikeView.S_STAND] < -0.6 and bike._cur[BikeView.S_SHIFT] > 0.02,
		"An actual tip-over warning still produces a braced stance")
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
	# 12.3: на крутом подъёме под нагрузкой — стоя, на быстром спуске без педалей — «атака», на ровном — сидя.
	reset()
	state.tilt = 0.25
	state.speed = 4
	for i in 90:
		state.crank += 6 * DT
		advance(1)
		contacts()
	check(bike._cur[BikeView.S_STAND] > 0.6 and bone("Hips").y > 1.0 and bone("Hips").z < 0.14, "Steep climb under load: out of the saddle and over the crank")
	reset()
	state.tilt = -0.25
	state.speed = 10
	for i in 90:
		advance()
		contacts()
	check(bike._cur[BikeView.S_STAND] < -0.5 and bone("Hips").y > 0.98 and bone("Hips").z > 0.20, "Fast descent: hips off and behind the saddle")
	reset()
	var foot_pitch_min := INF
	var foot_pitch_max := -INF
	var ankle_z_min := INF
	var ankle_z_max := -INF
	var knee_top_x := 0.0
	var knee_power_x := 0.0
	for i in 120:
		state.crank = TAU * float(i % 60) / 60.0
		advance(1)
		if i >= 60:
			var sk_step := bike.rider.skeleton
			var foot_l := sk_step.get_bone_global_pose(sk_step.find_bone("FootL"))
			var pedal_l_local := bike.to_local(bike.pedal_l.global_position)
			foot_pitch_min = minf(foot_pitch_min, foot_l.basis.get_euler().x)
			foot_pitch_max = maxf(foot_pitch_max, foot_l.basis.get_euler().x)
			ankle_z_min = minf(ankle_z_min, foot_l.origin.z - pedal_l_local.z)
			ankle_z_max = maxf(ankle_z_max, foot_l.origin.z - pedal_l_local.z)
			if i % 60 == 0:
				knee_top_x = absf(bone("LowerLegL").x)
			elif i % 60 == 15:
				knee_power_x = absf(bone("LowerLegL").x)
	check(absf(bike._cur[BikeView.S_STAND]) < 0.05 and bone("Hips").y > 1.005, "Flat pedalling stays seated on the saddle")
	check(foot_pitch_max - foot_pitch_min > 0.12 and ankle_z_max - ankle_z_min > 0.006, "Ankle flexes and pivots around the pedal contact point")
	check(knee_power_x < knee_top_x - 0.008, "Knee tracks closer to frame during downward power stroke")
	reset()
	state.steer = 1
	state._sustained_steer = 1.0
	state.yaw_rate = -0.65
	state.lean = -0.28
	for i in 40:
		advance()
	check(bone("Head").x > 0.025, "Balance into turn")
	check(bike.rider.skeleton.get_bone_global_pose(5).basis.get_euler().y < -0.15, "Look into turn")
	var sk_turn := bike.rider.skeleton
	var head_world_up := (bike.global_basis * sk_turn.get_bone_global_pose(sk_turn.find_bone("Head")).basis).y
	check(bone("Chest").x > bone("Hips").x + 0.015 and absf(head_world_up.x) < absf(bike.global_basis.y.x) * 0.55, "Turn separates bike lean and upper-body posture")
	var foot_l_turn := sk_turn.get_bone_global_pose(sk_turn.find_bone("FootL"))
	var foot_r_turn := sk_turn.get_bone_global_pose(sk_turn.find_bone("FootR"))
	check(bone("FootL").y < bone("FootR").y - 0.10 and foot_l_turn.basis.get_euler().x > foot_r_turn.basis.get_euler().x + 0.08 and absf(bone("LowerLegL").x) < absf(bone("LowerLegR").x) - 0.015, "Outer leg drops heel, lowers pedal and presses knee toward frame in turn")
	var head_before := sk_turn.get_bone_global_pose(sk_turn.find_bone("Head")).basis
	var turn_pose := bike._rider_pose
	turn_pose.look = 0.35
	bike.rider.pose(turn_pose)
	check(not sk_turn.get_bone_global_pose(sk_turn.find_bone("Head")).basis.is_equal_approx(head_before)
		and sk_turn.get_bone_global_pose(sk_turn.find_bone("FootL")).is_equal_approx(foot_l_turn)
		and sk_turn.get_bone_global_pose(sk_turn.find_bone("FootR")).is_equal_approx(foot_r_turn),
		"Changing gaze at fixed turn support moves the head without redistributing pedal support")
	reset()
	state.steer = 1.0
	state._sustained_steer = 1.0
	state.yaw_rate = -1.2
	state.slip = 0.18
	for i in 20:
		advance()
	check(bike._cur[BikeView.S_LOOK] < -0.12, "Gaze anticipates direction of motion from yaw rate and slip")
	# Пять читаемых фаз прыжка: подготовка → отрыв → полёт → приземление → восстановление.
	reset()
	state.hop_preparing = true
	for i in 12:
		advance()
	var prep_head_y := bone("Head").y
	var prep_crouch := bike._cur[BikeView.S_CROUCH]
	check(prep_head_y < neutral.y - 0.015 and prep_crouch > 0.025, "Jump phase 1 (preparation): preload compression before takeoff")
	state.hop_preparing = false
	state.hop_used = true
	state.airborne = true
	state.vy = 4.0
	for i in 3:
		advance()
	var takeoff_head_y := bone("Head").y
	var takeoff_crouch := bike._cur[BikeView.S_CROUCH]
	for i in 27:
		state.vy = move_toward(state.vy, -2.0, 6.0 * DT)
		advance()
	var flight_head_y := bone("Head").y
	check(takeoff_crouch < prep_crouch and takeoff_head_y > flight_head_y + 0.012, "Jump phase 2 (takeoff): body extends upward before settling into flight tuck")
	check(flight_head_y < neutral.y - 0.03, "Airborne tuck")
	state.airborne = false
	state.vy = 0.0
	state.land_impact = 9
	for i in 5:
		advance()
	var land_head_y := bone("Head").y
	check(land_head_y < neutral.y - 0.025 and land_head_y < flight_head_y, "Landing absorption")
	for i in 20:
		advance()
	var recovery_head_y := bone("Head").y
	check(recovery_head_y > land_head_y + 0.02 and recovery_head_y <= neutral.y + 0.008,
		"The rider rises out of landing compression without a second extension")
	for i in 100:
		advance()
	check(bone("Head").distance_to(neutral) < 0.004, "Landing settles within resting breath amplitude")
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
	# Дыхание и покой проверяются в прежней неподвижной посадке: стоянка с ногой на земле — отдельно ниже.
	bike.idle_life = false
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
	var rest_breath_span := breath_max - breath_min
	reset()
	bike.set_pack(true)
	state.tilt = 0.18
	for i in 120:
		state.crank += 6.0 * DT
		advance(1.0, true)
	var loaded_pack_swing := absf(bike._cur[BikeView.S_PACK_PITCH]) + absf(bike._cur[BikeView.S_PACK_ROLL])
	state.speed = 0.0
	state.tilt = 0.0
	var fatigued_min := INF
	var fatigued_max := -INF
	for i in 120:
		advance(0.0)
		fatigued_min = minf(fatigued_min, bone("Neck").y)
		fatigued_max = maxf(fatigued_max, bone("Neck").y)
	check(fatigued_max - fatigued_min > rest_breath_span * 1.25, "Breathing deepens and accelerates after heavy exertion")
	check(loaded_pack_swing > 0.015 and absf(bike._cur[BikeView.S_PACK_PITCH]) + absf(bike._cur[BikeView.S_PACK_ROLL]) < 0.001, "Equipment responds to load and settles without constant oscillation")
	bike.set_pack(false)
	state.speed = 6.0
	state.wheel_impact = Vector2(1.5, 0.0)
	advance()
	state.clear_tick_events()
	check(bike._pack_swing == Vector2.ZERO and bike._pack_velocity == Vector2.ZERO,
		"Hidden equipment does not accumulate impact motion")
	bike.set_pack(true)
	bike.draw(0.5)
	check(bike._pack_bag.rotation.is_zero_approx(), "Equipping a hidden pack starts without residual swing")
	bike.set_pack(false)
	reset()
	state.squash_fv = 2
	state.squash_rv = -1
	for i in 30:
		advance()
	check(bike._cur[BikeView.S_CROUCH] > 0.018, "Moving suspension is absorbed by body and elbows")
	check(absf(bike._cur[BikeView.S_SHIFT]) < 0.001 and absf(bike._cur[BikeView.S_HEAD_NOD]) < 0.001,
		"Suspension travel alone does not pull the rider fore-aft or nod the head")
	contacts()
	state.speed = 0
	for i in 120:
		advance()
	check(bike._cur[BikeView.S_CROUCH] < 0.00001, "No artificial road vibration when stopped")
	bike.idle_life = true
	state.speed = 6
	state.airborne = true
	for i in 90:
		advance()
	check(bike._cur[BikeView.S_CROUCH] > 0.04 and bike._cur[BikeView.S_CROUCH] < 0.075, "Airborne pose stays compact without suspension vibration")
	contacts()
	reset()
	state.tilt = 0.4
	bike.snap(state)
	bike.draw(1)
	var sk := bike.rider.skeleton
	var head_world := bike.global_basis * sk.get_bone_global_pose(sk.find_bone("Head")).basis
	check(absf(head_world.get_euler().x) < 0.2, "Head stabilizes against the slope")
	check(absf((sk.get_bone_global_pose(sk.find_bone("Neck")).basis.get_euler().x)) > 0.05, "Neck shares torso/head bend on climbs")
	# 10.6+: взгляд начинает поворот раньше плеч; усилие не переключается мгновенно.
	reset()
	var turn_world := PreviewWorld.new()
	var turn_ground := PreviewGround.new(turn_world)
	var turning_player := PlayerState.new()
	state.mount(turning_player)
	var gaze_started := false
	for i in 90:
		state.speed = 12.0
		state.step(turning_player, 0.0, 1.0, false, false, DT, turn_world, turn_ground)
		bike.tick(state)
		if not gaze_started and bike._cur[BikeView.S_LOOK] < -0.01:
			gaze_started = true
			check(absf(bike._cur[BikeView.S_BODY_LOOK]) < 0.01 and is_zero_approx(bike._cur[BikeView.S_TURN_SUPPORT]),
				"The gaze leads the shoulders and outside foot in a sustained turn")
		state.clear_tick_events()
	check(gaze_started, "Sustained steering engages gaze")
	check(bike._cur[BikeView.S_LOOK] < bike._cur[BikeView.S_BODY_LOOK] - 0.05
		and bike._cur[BikeView.S_BODY_LOOK] < -0.1 and bike._cur[BikeView.S_TURN_SUPPORT] > 0.4,
		"Shoulders and outside foot follow the steady turn while gaze leads")
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
	# Выраженный удар о кромку всё ещё даёт разный перенос на каждой оси.
	var impact_shift: Array[float] = []
	for front in [true, false]:
		reset()
		state.wheel_impact = Vector2(1.5, 0.0) if front else Vector2(0.0, 1.5)
		for i in 10:
			advance()
			state.clear_tick_events()
		impact_shift.append(bike._cur[BikeView.S_SHIFT])
		contacts()
	check(impact_shift[0] > 0.006 and impact_shift[1] < -0.003, "Front and rear edge impacts shift weight in opposite directions")
	# Последовательная реакция на удар (руки/ноги → корпус → голова) без резинового раскачивания.
	reset()
	state.wheel_impact = Vector2(1.5, 0.0)
	var limb_peak_tick := -1
	var torso_peak_tick := -1
	var head_peak_tick := -1
	var max_limb := 0.0
	var max_torso := 0.0
	var max_head := 0.0
	var head_reversals := 0
	var prev_head_nod := 0.0
	for i in 45:
		advance()
		state.wheel_impact = Vector2.ZERO
		if bike._cur[BikeView.S_FRONT_LOAD] > max_limb:
			max_limb = bike._cur[BikeView.S_FRONT_LOAD]
			limb_peak_tick = i
		if bike._cur[BikeView.S_CROUCH] > max_torso:
			max_torso = bike._cur[BikeView.S_CROUCH]
			torso_peak_tick = i
		var nod := -bike._cur[BikeView.S_HEAD_NOD]
		if nod > max_head:
			max_head = nod
			head_peak_tick = i
		if i > 1 and nod * prev_head_nod < -0.00001:
			head_reversals += 1
		prev_head_nod = nod
	check(limb_peak_tick >= 0 and limb_peak_tick < torso_peak_tick and torso_peak_tick < head_peak_tick, "Sequential front impact response: arms -> torso -> head")
	check(head_reversals == 0, "Critically damped impact response has no rubbery oscillation")
	# Приоритет торможения подавляет раскачку педалирования при одновременных сигналах.
	reset()
	state.crank = PI * 0.5
	for i in 30:
		advance(1.0)
	var pedal_sway := absf(bike._cur[BikeView.S_SWAY])
	for i in 20:
		state.speed = maxf(1.0, state.speed - 6.0 * DT)
		advance(-1.0)
	var braking_sway := absf(bike._cur[BikeView.S_SWAY])
	check(braking_sway < pedal_sway * 0.35,
		"Braking priority suppresses pedalling sway (%.4f from %.4f)" % [braking_sway, pedal_sway])
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
	# 11.11: стоянка — нога на земле, вторая на педали, руки на руле; тяга возвращает ногу на педаль.
	reset()
	state.speed = 0
	for i in 150:
		advance()
	var sk_stop := bike.rider.skeleton
	var down_foot := sk_stop.get_bone_global_pose(sk_stop.find_bone("FootL"))
	var sole := down_foot * CyclistRig.PEDAL_CONTACT_LOCAL
	check(bike._cur[BikeView.S_STOP] < -0.95 and absf(sole.y - 0.27 * tan(BikeView.STOP_LEAN)) < 0.03 and sole.x < -0.2, "Stopped rider puts the left foot on the ground")
	check(bike.rotation.z > 0.05 and bone("Hips").z < 0.1 and bone("Hips").y < 0.97, "Stopped rider stands over the frame and leans the bike to the foot")
	var foot_r_stop := sk_stop.get_bone_global_pose(sk_stop.find_bone("FootR"))
	check((foot_r_stop * CyclistRig.PEDAL_CONTACT_LOCAL).distance_to(bike.to_local(bike.pedal_r.global_position)) < 0.001 and bike.to_local(bike.pedal_r.global_position).z < -0.08, "Other foot waits on the forward pedal")
	for side in ["L", "R"]:
		check(absf(bone("UpperLeg" + side).distance_to(bone("LowerLeg" + side)) - 0.43) < 0.001 and absf(bone("LowerLeg" + side).distance_to(bone("Foot" + side)) - 0.43) < 0.001, "Stop pose keeps leg lengths")
		check(absf(bone("UpperArm" + side).distance_to(bone("Forearm" + side)) - 0.31) < 0.001 and absf(bone("Forearm" + side).distance_to(bone("Hand" + side)) - 0.31) < 0.001, "Stop pose keeps arm lengths")
	check_skin_pose()
	for i in 45:
		state.speed = minf(state.speed + 4.0 * DT, 4.0)
		state.crank += 4.0 * DT
		advance(1)
	check(absf(bike._cur[BikeView.S_STOP]) < 0.02 and absf(bike.rotation.z) < 0.01, "Pedalling off returns the foot to the pedal")
	contacts()
	# 11.11: на накате педали встают ровно; взгляд по сторонам появляется в покое и уходит в повороте.
	reset()
	state.crank = 0.3
	var gaze_max := 0.0
	for i in 480:
		advance()
		gaze_max = maxf(gaze_max, absf(bike._cur[BikeView.S_GAZE_YAW]))
	check(absf(bike.to_local(bike.pedal_l.global_position).y - bike.to_local(bike.pedal_r.global_position).y) < 0.02, "Coasting levels the pedals")
	check(gaze_max > 0.05, "Calm rider glances around")
	contacts()
	state.steer = 1
	state.lean = -0.2
	for i in 40:
		advance()
	check(absf(bike._cur[BikeView.S_GAZE_YAW]) < 0.02, "Turning brings the gaze back to the road")
	state.riding = false
	advance()
	check(not bike.rider.visible, "Dismount hides rig")
	check_obstacle_transitions()
	check_drive_transitions()
	check_body_input()
	check_secondary_motion()
	check_balance_reactions()
	check_small_steering(true)
	check_turn_transitions(true)
	check_real_ride_stability()
	await check_ragdoll_skin()
	var invalid: CyclistRig = load("res://scenes/cyclist.tscn").instantiate()
	root.add_child(invalid)
	invalid.skeleton.set_bone_name(invalid.skeleton.find_bone("HandL"), "MissingHand")
	var before := invalid.skeleton.get_bone_pose(0)
	invalid.pose(CyclistRig.PoseInput.new())
	check(not invalid._rig_valid, "Incomplete skeleton rejected")
	check(invalid.skeleton.get_bone_pose(0) == before, "Invalid rig does not write partial pose")
	invalid.free()
	print("Cyclist animation: ", fails, " failures; breathing, effort, suspension, reactions, 360 extreme poses, timing and reset")
	if "--capture" in OS.get_cmdline_user_args():
		await capture()
	bike.free()
	if finish:
		quit(1 if fails else 0)


func check_obstacle_transitions() -> void:
	for side: float in [-1.0, 0.0, 1.0]:
		reset()
		state.wheel_impact = Vector2(1.0, 0.0)
		state.fork_side_impulse = side
		advance()
		state.clear_tick_events()
		for i in 3:
			advance()
		var steer := bike._cur[BikeView.S_STEER]
		check(is_zero_approx(steer) if side == 0.0 else steer * side > 0.04, "Only an oblique front strike deflects the bar toward the physical impulse")
		contacts()
	reset()
	for i in 48:
		state.wheel_impact = Vector2(0.8, 0.0) if i % 12 == 0 else (Vector2(0.0, 0.8) if i % 12 == 6 else Vector2.ZERO)
		advance()
	var rough_stand := bike._cur[BikeView.S_STAND]
	state.clear_tick_events()
	for i in 120:
		advance()
	check(rough_stand < -0.18 and absf(bike._cur[BikeView.S_STAND]) < 0.03, "Repeated axle contacts lift the rider off the saddle and level trail releases the stance")
	reset()
	state.lift_f = 0.1
	state.squash_fv = 2.0
	for i in 30:
		advance()
	check(bike._cur[BikeView.S_FRONT_LOAD] < 0.01 and absf(bike._cur[BikeView.S_CROUCH]) < 0.001, "An unsupported fork stroke does not mimic a ground strike")
	reset()
	state.bottom_out = state.config.bottom_out_speed + 2.2
	advance()
	var peak_front := bike._cur[BikeView.S_FRONT_LOAD]
	state.clear_tick_events()
	advance()
	peak_front = maxf(peak_front, bike._cur[BikeView.S_FRONT_LOAD])
	check(peak_front > 0.65 and bike._cur[BikeView.S_REAR_LOAD] < 0.1, "Fork bottom-out reaches the arms quickly without one-frame snap")
	reset()
	state.airborne = true
	state.air_time = 0.4
	state.clearance_closing_speed = 3.0
	state.air_clearance = 2.0
	for i in 48:
		advance()
	var tucked := bone("Hips").y
	state.air_clearance = 0.14
	for i in 12:
		advance()
	check(bone("Hips").y > tucked + 0.006, "Rider extends before touchdown only as the support gets close")
	for pitch: float in [-0.32, 0.32]:
		reset()
		state.land_impact = 7.0
		state.landing_info = {pitch_error = pitch}
		advance()
		var load_difference := bike._cur[BikeView.S_FRONT_LOAD] - bike._cur[BikeView.S_REAR_LOAD]
		check(load_difference * -signf(pitch) > 0.20, "Landing pitch relative to the surface selects the leading limbs")
		contacts()
	var landing_crouch := 0.0
	for bottoming_fork: bool in [false, true]:
		reset()
		state.land_impact = 9.0
		if bottoming_fork:
			state.bottom_out = state.config.bottom_out_speed + 2.2
			state.squash_fv = 3.0
		advance()
		var tick1_front := bike._cur[BikeView.S_FRONT_LOAD]
		state.clear_tick_events()
		state.squash_fv = 0.0
		advance()
		if bottoming_fork:
			check(maxf(tick1_front, bike._cur[BikeView.S_FRONT_LOAD]) > 0.65, "Landing bottom-out still reaches the arms quickly")
		for i in 9:
			advance()
		if bottoming_fork:
			check(absf(bike._cur[BikeView.S_CROUCH] - landing_crouch) < 0.001, "Fork bottom-out does not crouch the rider twice for one landing")
		else:
			landing_crouch = bike._cur[BikeView.S_CROUCH]
	reset()


func check_drive_transitions() -> void:
	reset()
	state.speed = 14.0
	state.brake_pressure = 0.8
	state.brake_applied = state.config.brake_decel * 0.8
	for i in 20:
		advance()
	var held_pose := bike._cur[BikeView.S_BRAKE_POSE]
	state.airborne = true
	state.brake_pressure -= state.config.brake_response * DT
	advance()
	check(bike._cur[BikeView.S_BRAKE] > 0.5 and bike._cur[BikeView.S_BRAKE] < 0.8
		and bike._cur[BikeView.S_BRAKE_POSE] > held_pose * 0.85 and bike._cur[BikeView.S_BRAKE_POSE] < held_pose,
		"The lever and body release their braking pose progressively on takeoff")
	reset()
	var left_pedal_rest := bike.pedal_l.position
	var right_pedal_rest := bike.pedal_r.position
	bike.pedal_l.position += Vector3(-0.022, 0.019, -0.017)
	bike.pedal_r.position += Vector3(0.015, 0.021, 0.016)
	state.crank += 0.8
	advance(1.0)
	bike.draw(0.45)
	contacts()
	bike.pedal_l.position = left_pedal_rest
	bike.pedal_r.position = right_pedal_rest
	reset()
	for i in 70:
		advance()
	var level := bike._cur[BikeView.S_CRANK]
	state.riding = false
	bike.snap(state)
	for i in 60:
		advance()
	check(absf(angle_difference(level, bike._cur[BikeView.S_CRANK])) < 0.0001, "Parked pedals hold their last ridden position")
	state.riding = true
	bike.snap(state)
	state.crank += 0.025
	advance(0.4)
	check(absf(angle_difference(level, bike._cur[BikeView.S_CRANK]) - 0.025) < 0.0001, "First power stroke carries the level pedals forward at drivetrain cadence")
	for i in 40:
		state.wheel += 0.16
		advance()
	state.lift_f = 0.12
	var front_before := bike.front_wheel.basis
	for i in 12:
		advance()
	var travel := front_before.get_rotation_quaternion().angle_to(bike.front_wheel.basis.get_rotation_quaternion())
	check(absf(travel - 12 * 0.16) < 0.015, "Lifted wheel retains spin while grounded rear wheel slows")
	check(absf(angle_difference(bike._prev[BikeView.S_WHEEL_R], bike._cur[BikeView.S_WHEEL_R])) < 0.002, "Rear tread settles at road speed")
	state.lift_f = 0.0
	advance()
	var landing_step := angle_difference(bike._prev[BikeView.S_WHEEL_F], bike._cur[BikeView.S_WHEEL_F])
	check(landing_step > 0.04 and landing_step < 0.16, "Recontact synchronizes wheel speed progressively")
	state.speed = 34.0
	state.wheel = 0.0
	bike.snap(state)
	var long_tick := 1.0 / 30.0
	var expected := state.speed * long_tick / BikeRide.WHEEL_R
	state.wheel = fmod(expected, TAU)
	advance(0.0, false, long_tick)
	bike.draw(0.5)
	check(absf(angle_difference(bike._mix[BikeView.S_WHEEL_F], expected * 0.5)) < 0.0001, "Fast wheel interpolates in the direction of travel beyond half a turn")
	reset()


func check_body_input() -> void:
	var world := PreviewWorld.new()
	var ground := PreviewGround.new(world)
	for back: bool in [true, false]:
		reset()
		var player := PlayerState.new()
		state.mount(player)
		state.speed = 8.0
		bike.snap(state)
		for i in 60:
			state.step(player, 0.0, 0.0, false, false, DT, world, ground)
			bike.tick(state)
			state.clear_tick_events()
		for i in 12:
			state.body_back = back
			state.body_forward = not back
			state.step(player, 0.0, 0.0, false, false, DT, world, ground)
			bike.tick(state)
			bike.draw(1.0)
			state.clear_tick_events()
			contacts()
			if i == 2:
				var shift := bike._cur[BikeView.S_SHIFT]
				check(shift * state.body_x > 0.0 and absf(shift) > 0.12 * absf(state.body_x),
					"Manual weight shift follows Q/E during the first three physics ticks")
		state.body_back = false
		state.body_forward = false
		# Airborne Q (nose-up) / E (nose-down) arcade balance pitches the whole bike cleanly
		state.step(player, 0.0, 0.0, false, true, DT, world, ground)
		for i in 12:
			state.body_back = back
			state.body_forward = not back
			state.step(player, 0.0, 0.0, false, false, DT, world, ground)
			bike.tick(state)
			state.clear_tick_events()
		check((state.tilt > 0.25) if back else (state.tilt < -0.25),
			"Airborne Q pitches nose up and E pitches nose down (tilt=%.2f)" % state.tilt)


func check_secondary_motion() -> void:
	reset()
	for i in 16 * 60:
		advance()
		if i >= 14 * 60 and i % 10 == 0:
			contacts()
	reset()
	state.brake_pressure = 0.9
	state.use_f = 1.0
	for i in 12:
		advance()
	check(is_zero_approx(bike._cur[BikeView.S_SHUDDER]), "Lateral tyre load alone does not shake the brake lever")
	state.brake_skid = 0.8
	advance()
	var lever_start := bike._levers[0].basis
	var lever_moves := false
	var steering_is_stable := true
	for i in 12:
		advance()
		lever_moves = lever_moves or not bike._levers[0].basis.is_equal_approx(lever_start)
		steering_is_stable = steering_is_stable and bike._steering.basis.is_equal_approx(Basis.IDENTITY)
		contacts()
	check(lever_moves and steering_is_stable, "Brake shudder reaches the levers without rotating the grips")


func check_balance_reactions() -> void:
	reset()
	state.speed = 0.0
	state.stance_driven = true
	state.stance = BikeRide.Stance.TRACKSTAND
	for i in 40:
		advance()
	check(bike._cur[BikeView.S_TRACK] > 0.9 and is_zero_approx(bike._cur[BikeView.S_STOP]), "Trackstand balances with both feet on pedals")
	check(bike._steering.basis.is_equal_approx(Basis.IDENTITY) and is_zero_approx(bike.rotation.z)
		and is_zero_approx(bike._cur[BikeView.S_SIDE]), "A settled trackstand does not invent steering, roll or side sway")
	contacts()
	state.stance = BikeRide.Stance.FOOT_DOWN
	state.foot_side = 1.0
	state.bank_slope = 0.31
	state.heading = 0.68
	state.tilt = 0.18
	state.x = 12.0
	state.z = -7.0
	state.set_config(state.config.duplicate() as BikePhysicsConfig)
	state.config.stop_foot_offset = 0.33
	var heights := PreviewGround.new(PreviewWorld.new())
	heights.reference = Vector2(state.x, state.z)
	var grade_world := Basis(Vector3.UP, state.heading) * Vector3(state.bank_slope, 0.0, -state.tilt)
	heights.grade = Vector2(grade_world.x, grade_world.z)
	state._stop_timer = state.config.stop_settle_time
	state._update_stance(DT, state.tilt, heights)
	var expected := Vector3(state.x, state.y, state.z) + Basis(Vector3.UP, state.heading) * Vector3(0.33, 0.0, -0.06)
	expected.y = heights.ground_at(expected.x, expected.z)
	check(state.foot_support.distance_to(expected) < 0.0001, "Stop samples the configured lateral and forward foot offsets")
	for i in 90:
		advance()
	var sk := bike.rider.skeleton
	var sole := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("FootR")) * CyclistRig.PEDAL_CONTACT_LOCAL
	check(sole.distance_to(state.foot_support) < 0.003, "Uphill sole meets the sampled world-space point with a custom foot offset")
	var sole_up := (sk.global_basis * sk.get_bone_global_pose(sk.find_bone("FootR")).basis).y
	var surface_up := Basis(Vector3.UP, state.heading) * Vector3(-state.bank_slope, 1, state.grade_now).normalized()
	check(sole_up.dot(surface_up) > 0.999, "Planted shoe lies on the side slope at an oblique heading")
	state.foot_side = -1.0
	state.bank_slope = -0.10
	state._update_stance(DT, state.tilt, heights)
	advance()
	var departing := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("FootR")) * CyclistRig.PEDAL_CONTACT_LOCAL
	var held_support := sk.global_transform * bike._rider_pose.ground_point
	check(held_support.distance_to(expected) < 0.003 and departing.distance_to(sole) < 0.05,
		"Changing sides retracts gradually from the old three-dimensional support")
	for i in 120:
		advance()
	check(bike._cur[BikeView.S_STOP] < -0.95, "Opposite foot takes support after retraction")
	reset()
	state.speed = -1.2
	for i in 45:
		advance()
	var rollback := bone("Hips")
	var rollback_crank := bike.crank.rotation.x
	state.reversing = true
	for i in 45:
		advance()
	check(bike._cur[BikeView.S_LOOK] > 0.5 and bone("Hips").z > rollback.z + 0.01, "Intentional reverse looks back, rollback braces forward")
	check(absf(angle_difference(rollback_crank, bike.crank.rotation.x)) > 0.2, "Rider follows cranks during deliberate reverse")
	for side: float in [-1.0, 1.0]:
		reset()
		state.lateral_speed = side
		state.instability = 1.0
		state.brake_skid = 1.0
		state.use_r = 1.0
		for i in 40:
			state.wheel += 0.12
			advance()
		var foot := "FootR" if side > 0.0 else "FootL"
		check(side * bone(foot).x > 0.24 and side * bone("Chest").x < -0.035, "Catch leg opens toward slip and trunk counterbalances")
		check(absf(angle_difference(bike._prev[BikeView.S_WHEEL_R], bike._cur[BikeView.S_WHEEL_R])) < 0.01 and absf(angle_difference(bike._prev[BikeView.S_WHEEL_F], bike._cur[BikeView.S_WHEEL_F])) > 0.1, "Saturated rear wheel slows independently")


func small_steer_trace(pace: float, ground: Heightfield, input: String, verify_contacts := false) -> Array[Vector4]:
	reset()
	bike.idle_life = false
	var player := PlayerState.new()
	var controls := Controls.new()
	controls.joypad = input == "stick"
	state.y = ground.ground_at(0.0, 0.0)
	state.mount(player)
	state.speed = pace
	bike.snap(state)
	var samples: Array[Vector4] = []
	for tick in 120:
		var raw := 0.0
		if input == "tap":
			raw = 1.0 if tick >= 14 and tick < 20 else (-1.0 if tick >= 62 and tick < 68 else 0.0)
		elif input == "stick":
			raw = 0.35 if tick >= 14 and tick < 47 else (-0.35 if tick >= 62 and tick < 96 else 0.0)
		state.speed = pace
		state.step(player, 0.0, controls.bike_steer(raw, DT, pace), false, false, DT, ground.world, ground)
		bike.tick(state)
		bike.draw(1.0)
		if verify_contacts and tick in [19, 46, 67, 95]:
			contacts()
		var pose := bike._rider_pose
		samples.append(Vector4(bike._cur[BikeView.S_STEER] * state.config.max_steer_angle,
			bike.rotation.z, bone("Chest").x, pose.look))
		state.clear_tick_events()
	bike.idle_life = true
	return samples


func check_small_steering(assert_limits: bool) -> void:
	check_flat_steer_tap(assert_limits)
	var ground := RoughTurnGround.new(PreviewWorld.new())
	ground.grade = Vector2(0.14, 0.05)
	for pace: float in [7.0, 12.0, 20.0]:
		var straight := small_steer_trace(pace, ground, "straight")
		for input: String in ["tap", "stick"]:
			var turned := small_steer_trace(pace, ground, input, assert_limits)
			var peak := Vector4.ZERO
			for i in turned.size():
				var change := (turned[i] - straight[i]).abs()
				peak = Vector4(maxf(peak.x, change.x), maxf(peak.y, change.y), maxf(peak.z, change.z), maxf(peak.w, change.w))
			print("CORRECTION %s %.0f m/s | bar %.2f deg | roll %.2f deg | chest %.1f mm | gaze %.2f deg" % [
				input, pace, rad_to_deg(peak.x), rad_to_deg(peak.y), peak.z * 1000.0, rad_to_deg(peak.w)])
			if assert_limits:
				check(not state.crashed and peak.x > 0.006 and peak.y < 0.017 and peak.z < 0.006 and peak.w < 0.035,
					"%s at %.0f m/s on rough ground steers the front without a body throw" % [input, pace])
	reset()
	state.lateral_speed = 1.0
	state.instability = 1.0
	for i in 40:
		advance()
	var rider_catch := bike._cur[BikeView.S_BALANCE]
	var frame_roll := bike._cur[BikeView.S_ROLL]
	var bar_turn := bike._cur[BikeView.S_STEER]
	print("CATCH balance %.3f | roll %.2f deg | bar %.2f deg" % [rider_catch, rad_to_deg(frame_roll), rad_to_deg(bar_turn * state.config.max_steer_angle)])
	if assert_limits:
		check(rider_catch > 0.5 and is_zero_approx(frame_roll) and is_zero_approx(bar_turn),
			"The rider's balance recovery cannot turn the frame or the front wheel")
	reset()
	var chest := bone("Chest")
	state.fork_side_impulse = 0.85
	advance()
	state.fork_side_impulse = 0.0
	var kick_bar := 0.0
	var chest_motion := 0.0
	for i in 18:
		advance()
		kick_bar = maxf(kick_bar, absf(bike._cur[BikeView.S_STEER]))
		chest_motion = maxf(chest_motion, absf(bone("Chest").x - chest.x))
	print("FORK bar %.2f deg | chest %.1f mm" % [rad_to_deg(kick_bar * state.config.max_steer_angle), chest_motion * 1000.0])
	if assert_limits:
		check(kick_bar > 0.025 and chest_motion < 0.005 and is_zero_approx(bike.rotation.z),
			"An oblique light fork impulse moves the fork and hands without rolling the frame or throwing the torso")
		contacts()
	check_turn_pose_blend(ground, assert_limits)


## Сравниваем соседние кадры из игровой камеры, включая движение рамы и таза.
func check_flat_steer_tap(assert_limits: bool) -> void:
	var road := PreviewWorld.new()
	road.path = 3 # гравий
	var ground := PreviewGround.new(road)
	var camera := Camera3D.new()
	root.add_child(camera)
	var viewport_height := maxf(1.0, camera.get_viewport().get_visible_rect().size.y)
	for throttle: float in [0.0, 1.0]:
		var straight := flat_steer_trace(ground, camera, throttle, 0.0)
		for direction: float in [-1.0, 1.0]:
			var turn := flat_steer_trace(ground, camera, throttle, direction)
			var body_step := 0.0
			var max_roll := 0.0
			for i in range(1, turn.size()):
				for joint in 3:
					var step: Vector2 = turn[i].body[joint] - turn[i - 1].body[joint]
					var straight_step: Vector2 = straight[i].body[joint] - straight[i - 1].body[joint]
					body_step = maxf(body_step, (step - straight_step).length() / viewport_height)
				max_roll = maxf(max_roll, absf(turn[i].roll - straight[i].roll))
			print("FLAT TAP throttle %.0f side %+.0f | body step %.2f px at 540p | roll %.2f deg" % [
				throttle, direction, body_step * 540.0, rad_to_deg(max_roll)])
			if assert_limits:
				check(direction * turn[3].steer > 0.005 and direction * turn.back().heading < -0.03,
					"A short turn moves the handlebar and changes course")
				check(body_step < 0.003 and max_roll < 0.012,
					"A 233 ms tap on flat gravel does not throw the rider in the follow camera")
	camera.free()
	reset()


func flat_steer_trace(ground: Heightfield, camera: Camera3D, throttle: float, direction: float) -> Array[Dictionary]:
	reset()
	var follow := PlayerCameraController.new()
	follow.settings = GameSettings.new()
	follow.heights = ground
	follow._cam_y = PlayerCameraController.RIDE_HEIGHT
	camera.fov = follow.settings.fov
	var player := PlayerState.new()
	var controls := Controls.new()
	state.mount(player)
	state.speed = 12.0
	bike.snap(state)
	var samples: Array[Dictionary] = []
	for i in 128:
		var time := i * DT
		var raw := direction if i >= 80 and i < 94 else 0.0
		follow.store_previous(player, time)
		state.step(player, throttle, controls.bike_steer(raw, DT, state.speed), false, false, DT, ground.world, ground)
		bike.tick(state, DT, throttle)
		bike.draw(0.5)
		follow.update(0.5, DT, player, state, camera, time, false, false, false, false, camera.fov,
			bike.view_squash(), bike.position.y, bike.view_roll())
		if i >= 79:
			var body := PackedVector2Array()
			for joint in ["Hips", "Chest", "Head"]:
				body.append(camera.unproject_position(bike.rider.skeleton.to_global(bone(joint))))
			samples.append({body = body, roll = bike.rotation.z, heading = bike.rotation.y,
				steer = bike._mix[BikeView.S_STEER] * state.config.max_steer_angle})
		state.clear_tick_events()
	return samples


func check_turn_pose_blend(ground: Heightfield, assert_limits: bool) -> void:
	reset()
	var player := PlayerState.new()
	state.mount(player)
	var peak_roll := 0.0
	var peak_support := 0.0
	var max_step := 0.0
	var last_roll := 0.0
	var last_chest := bone("Chest").x
	var max_chest_step := 0.0
	for i in 105:
		var turn := lerpf(0.32, 1.0, smoothstep(12.0, 34.0, float(i))) if i < 62 else 0.32
		state.speed = 16.0
		state.step(player, 0.0, turn, false, false, DT, ground.world, ground)
		bike.tick(state)
		var roll := bike._cur[BikeView.S_ROLL]
		peak_roll = maxf(peak_roll, absf(roll))
		peak_support = maxf(peak_support, absf(bike._cur[BikeView.S_TURN_SUPPORT]))
		max_step = maxf(max_step, absf(roll - last_roll))
		last_roll = roll
		for alpha: float in [0.25, 0.50, 0.75, 1.0]:
			bike.draw(alpha)
			var chest := bone("Chest").x
			max_chest_step = maxf(max_chest_step, absf(chest - last_chest))
			last_chest = chest
		state.clear_tick_events()
	var steady := absf(bike._cur[BikeView.S_ROLL])
	print("BLEND roll %.2f deg | support %.3f | step %.2f deg | released %.2f deg | chest step at 240 Hz %.1f mm" % [
		rad_to_deg(peak_roll), peak_support, rad_to_deg(max_step), rad_to_deg(steady), max_chest_step * 1000.0])
	if assert_limits:
		check(not state.crashed and peak_roll > 0.17 and peak_support > 0.32 and max_step < 0.062
			and steady < 0.003 and absf(bike._cur[BikeView.S_STEER]) > 0.015 and max_chest_step < 0.008,
			"A held turn grows into a body pose and releases back to hands-only steering on rough ground")
	reset()


func check_turn_transitions(assert_limits: bool) -> void:
	var world := PreviewWorld.new()
	var ground := PreviewGround.new(world)
	var player := PlayerState.new()
	for pace: float in [6.0, 12.0, 20.0, 24.0]:
		reset()
		var controls := Controls.new()
		var frame := 0.0
		var frame_step := 0.0
		var max_roll_step := 0.0
		var max_roll_jerk := 0.0
		var max_input_delay := 0
		var min_body_lead := 45
		var min_support_lead := 45
		for phase in 5:
			var direction := 1.0 if phase % 2 == 0 else -1.0
			var input_tick := -1
			var body_tick := -1
			var support_tick := -1
			var frame_tick := -1
			for i in 36:
				state.speed = pace
				var command := controls.bike_steer(direction, DT, pace)
				state.step(player, 0.0, command, false, false, DT, world, ground)
				bike.tick(state, DT)
				var roll := bike._cur[BikeView.S_ROLL]
				if input_tick < 0 and state.yaw_rate * direction < -0.01:
					input_tick = i
				if body_tick < 0 and bike._cur[BikeView.S_SIDE] * direction > 0.0001:
					body_tick = i
				if support_tick < 0 and bike._cur[BikeView.S_TURN_SUPPORT] * direction > 0.0001:
					support_tick = i
				if frame_tick < 0 and roll * direction < -0.001:
					frame_tick = i
				var roll_step := roll - frame
				max_roll_step = maxf(max_roll_step, absf(roll_step))
				max_roll_jerk = maxf(max_roll_jerk, absf(roll_step - frame_step))
				frame = roll
				frame_step = roll_step
			state.clear_tick_events()
			max_input_delay = maxi(max_input_delay, input_tick + 1 if input_tick >= 0 else 36)
			if phase > 0 and pace >= 12.0:
				min_body_lead = mini(min_body_lead, frame_tick - body_tick if body_tick >= 0 and frame_tick >= 0 else -36)
				min_support_lead = mini(min_support_lead, frame_tick - support_tick if support_tick >= 0 and frame_tick >= 0 else -36)
		if pace < 12.0:
			min_body_lead = 0
			min_support_lead = 0
		print("TURN %.0f m/s | roll step %.2f deg | step change %.2f deg | hip lead %d ticks | support lead %d ticks | yaw delay %d ticks" % [
			pace, rad_to_deg(max_roll_step), rad_to_deg(max_roll_jerk), min_body_lead, min_support_lead, max_input_delay])
		if assert_limits:
			check(not state.crashed and max_input_delay in [1, 2, 3] and rad_to_deg(max_roll_step) < 3.5,
				"Frame rolls progressively while steering responds immediately at %.0f m/s" % pace)
			if pace >= 12.0:
				check(min_body_lead >= 2 and min_support_lead >= 0,
					"The rider prepares the new lean before the frame changes sides at %.0f m/s" % pace)
	reset()


func check_real_ride_stability() -> void:
	var world := PreviewWorld.new()
	var player := PlayerState.new()

	# A. Real-physics steering weave across zero: finite, C1-smooth handlebar motion without spike.
	var flat := PreviewProfileGround.new(world)
	state = BikeRide.new()
	state.riding = true
	state.speed = 10.0
	state.step(player, 1.0, 0.0, false, false, DT, world, flat)
	bike.snap(state)
	bike.draw(1.0)
	var prev_steer := bike._cur[BikeView.S_STEER]
	var max_steer_step := 0.0
	var max_abs_steer := 0.0
	for i in 120:
		var turn := sin(i * 0.08)
		state.step(player, 1.0, turn, false, false, DT, world, flat)
		bike.tick(state, DT, 1.0, false)
		bike.draw(1.0)
		state.clear_tick_events()
		max_steer_step = maxf(max_steer_step, absf(bike._cur[BikeView.S_STEER] - prev_steer))
		max_abs_steer = maxf(max_abs_steer, absf(bike._cur[BikeView.S_STEER]))
		prev_steer = bike._cur[BikeView.S_STEER]
	check(max_steer_step < 0.14 and max_abs_steer <= 1.0001,
		"Real ride steering weave across zero stays smooth and clamped (step=%.3f, max=%.3f)" % [max_steer_step, max_abs_steer])

	# B. Real-physics faceted 2 m hills: no micro-detaches, continuous frame height, grounded tire alignment.
	var hills := PreviewProfileGround.new(world)
	hills.profile = func(d: float) -> float:
		var k := floorf(d / 2.0)
		var a := 0.8 * sin(k * 0.45) + 0.12 * sin(k * 1.7)
		var b := 0.8 * sin((k + 1.0) * 0.45) + 0.12 * sin((k + 1.0) * 1.7)
		return lerpf(a, b, d / 2.0 - k)
	state = BikeRide.new()
	state.riding = true
	state.speed = 11.0
	state.step(player, 1.0, 0.0, false, false, DT, world, hills)
	bike.snap(state)
	bike.draw(1.0)
	var detaches := 0
	var was_air := state.airborne
	var prev_y := bike.position.y
	var prev_dy := 0.0
	var max_dy_jerk := 0.0
	var max_wheel_err := 0.0
	for i in 240:
		state.step(player, 1.0, 0.0, false, false, DT, world, hills)
		bike.tick(state, DT, 1.0, false)
		bike.draw(1.0)
		state.clear_tick_events()
		if state.airborne and not was_air:
			detaches += 1
		var dy := bike.position.y - prev_y
		if i > 1:
			max_dy_jerk = maxf(max_dy_jerk, absf(dy - prev_dy))
		prev_dy = dy
		prev_y = bike.position.y
		was_air = state.airborne
		if not state.airborne and state.contact_f() and state.contact_r():
			var err_f := absf(bike.front_wheel.global_position.y - BikeView.WHEEL_Y - (state.y + state.ground_f))
			var err_r := absf(bike.rear_wheel.global_position.y - BikeView.WHEEL_Y - (state.y + state.ground_r))
			max_wheel_err = maxf(max_wheel_err, maxf(err_f, err_r))
	check(detaches <= 2 and max_dy_jerk < 0.10 and max_wheel_err < 0.06,
		"Real ride faceted hills stay grounded and wheel-aligned (detaches=%d, dy_jerk=%.4f, wheel_err=%.4f)" % [detaches, max_dy_jerk, max_wheel_err])

	# C. Real-physics bunny-hop takeoff and landing continuity + IK contact invariants.
	state = BikeRide.new()
	state.riding = true
	state.speed = 8.0
	state.step(player, 1.0, 0.0, false, false, DT, world, flat)
	bike.snap(state)
	bike.draw(1.0)
	var took_off := false
	var landed := false
	var takeoff_jump := 0.0
	var mid_flight_checked := false
	prev_y = bike.position.y
	for i in 90:
		var hop := (i == 10)
		state.step(player, 1.0, 0.0, false, hop, DT, world, flat)
		bike.tick(state, DT, 1.0, false)
		bike.draw(1.0)
		if state.airborne and not took_off:
			took_off = true
			takeoff_jump = absf(bike.position.y - prev_y)
		elif took_off and state.airborne and not mid_flight_checked and state.air_time > 0.12:
			mid_flight_checked = true
			contacts()
		elif took_off and not state.airborne and not landed:
			landed = true
			contacts()
		prev_y = bike.position.y
		state.clear_tick_events()
	check(took_off and landed and mid_flight_checked and takeoff_jump < 0.14,
		"Bunny-hop takeoff and landing remain continuous with valid IK contacts (jump=%.4f)" % takeoff_jump)

	# D. 240 Hz sub-frame foot-support side switch never crosses opposite S_STOP signs within one tick.
	reset()
	state.speed = 0.0
	state.stance_driven = true
	state.stance = BikeRide.Stance.FOOT_DOWN
	state.foot_side = -1.0
	state.foot_support = state.foot_probe(-1.0)
	for i in 45:
		advance()
	var left_planted := bike._cur[BikeView.S_STOP] < -0.5
	state.foot_side = 1.0
	state.foot_support = state.foot_probe(1.0)
	var sign_crossed := false
	var finite_ok := true
	var sk_foot := bike.rider.skeleton
	for i in 90:
		state.feel_acceleration = 0.0
		state.grade_now = 0.0
		bike.tick(state, DT, 0.0, false)
		if bike._prev[BikeView.S_STOP] * bike._cur[BikeView.S_STOP] < -0.0001:
			sign_crossed = true
		for alpha: float in [0.25, 0.5, 0.75, 1.0]:
			bike.draw(alpha)
			check_skin_pose()
			for side in ["L", "R"]:
				var grip := bike._steering.position + bike._steering.basis * (BikeView.GRIP * Vector3(-1.0 if side == "L" else 1.0, 1, 1) - BikeView.STEERING_PIVOT)
				if bone("Hand" + side).distance_to(grip) >= 0.002:
					finite_ok = false
				for pair in [["UpperArm", "Forearm", 0.31], ["Forearm", "Hand", 0.31], ["UpperLeg", "LowerLeg", 0.43], ["LowerLeg", "Foot", 0.43]]:
					if absf(bone(pair[0] + side).distance_to(bone(pair[1] + side)) - pair[2]) >= 0.002:
						finite_ok = false
			if not bike.position.is_finite() or not sk_foot.get_bone_global_pose(sk_foot.find_bone("FootR")).origin.is_finite():
				finite_ok = false
	check(left_planted and not sign_crossed and finite_ok and bike._cur[BikeView.S_STOP] > 0.5,
		"240 Hz foot-support side flip passes smoothly through neutral without sign crossing")
	reset()


## Короткое физическое падение в той же сцене: новая оболочка должна следовать костям после отделения от рамы.
func check_ragdoll_skin() -> void:
	reset()
	var world := PreviewWorld.new()
	var heights := PreviewGround.new(world)
	var crash := BikeCrash.new()
	root.add_child(crash)
	crash.start(bike, state, Vector3(0, -5, -6), heights)
	crash.tick(DT * 5.0, state, world, heights)
	crash.draw(0.36)
	var release := bike.rider.capture_pose()
	crash.draw(0.82)
	crash.draw(0.36)
	check(release == bike.rider.capture_pose() and release != crash._seated_pose, "Balance phase releases limbs independently of render order")
	crash.tick(BikeCrash.BALANCE, state, world, heights)
	for i in 12:
		await physics_frame
		crash.tick(DT, state, world, heights)
		check_skin_pose()
	check(bike.rider.get_parent() == crash and body_mesh.get_node(body_mesh.skeleton) == bike.rider.skeleton, "Native skin remains bound while ragdoll is detached")
	check(crash._bones.size() == BikeCrash.BODIES.size(), "Ragdoll still creates all physical bones")
	crash.abort()
	check(bike.rider.get_parent() == bike and bike.rider.procedural_pose, "Skin returns to the animated rider after abort")
	crash.free()
	reset()

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
	for mode in ["game", "pedal", "rough", "climb", "rear", "crouch", "pump_compress", "pump_extend"]:
		if mode == "game":
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			camera.fov = 68.0
			camera.position = Vector3(0.0, 2.25, 2.85)
			camera.look_at(Vector3(0.0, 1.15, -0.25))
		else:
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.position = Vector3(2.8, 1.9, -2.8) if mode == "pedal" else (Vector3(1.4, 1.8, 2.6) if mode == "rear" else Vector3(2.4, 1.8, -0.4))
			camera.look_at(Vector3(0, 0.9, 0) if mode == "pedal" else Vector3(0, 1.18, -0.04))
			camera.size = 2.4 if mode == "pedal" else 1.45
		reset()
		state.crank = 0.4
		state.speed = 18.0 if mode == "crouch" else 12.0
		state.pump_motion = 1.0 if mode == "pump_compress" else (-1.0 if mode == "pump_extend" else 0.0)
		state.steer = 0.45 if mode == "rough" else 0.0
		state.lean = -0.2 if mode == "rough" else 0.0
		state.squash = 0.08 if mode == "rough" else (0.14 if mode == "crouch" else 0.0)
		state.squash_f = 0.12 if mode == "rough" else 0.0
		state.squash_fv = 2.0 if mode == "rough" else 0.0
		state.squash_rv = -1.0 if mode == "rough" else 0.0
		if mode == "climb":
			state.tilt = 0.25
			state.speed = 4
		for i in (90 if mode == "climb" else 30):
			state.crank += 4.0 * DT
			advance(1.0, true)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tools/control/runs/cyclist_v8_" + mode + ".png")
