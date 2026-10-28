extends SceneTree
var fails := 0
func check(ok: bool, label: String) -> void:
	if not ok:
		push_error(label)
		fails += 1
func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()
func run() -> void:
	var bike: BikeView = load("res://scenes/bike.tscn").instantiate()
	root.add_child(bike)
	var state := BikeRide.new()
	state.riding = true
	var rig: Node3D = bike.rider
	var sk: Skeleton3D = rig.skeleton
	check(sk.get_bone_count() == 22, "Full body hierarchy")
	for steer in [-1.0, 0.0, 1.0]:
		for step in 24:
			state.crank = TAU * step / 24.0
			state.steer = steer
			state.speed = 14.0
			state.squash = 0.12
			state.squash_f = 0.16
			state.squash_r = -0.08
			bike.snap(state)
			bike.draw(1)
			for side in ["L", "R"]:
				var pedal: Node3D = bike.pedal_l if side == "L" else bike.pedal_r
				var foot := sk.get_bone_global_pose(sk.find_bone("Foot" + side)).origin
				check(foot.distance_to(bike.to_local(pedal.global_position) + Vector3(0, 0.055, 0.025)) < 0.001, "Foot stays on pedal")
				var hand := sk.get_bone_global_pose(sk.find_bone("Hand" + side)).origin
				var grip := bike._steering.position + bike._steering.basis * Vector3(-0.24 if side == "L" else 0.24, 0.22, -0.015)
				check(hand.distance_to(grip) < 0.001, "Hand stays on grip")
			for i in sk.get_bone_count():
				check(sk.get_bone_global_pose(i).is_finite(), "Finite pose")
	rig.procedural_pose = false
	var before := sk.get_bone_pose(5)
	bike.draw(0)
	check(before.is_equal_approx(sk.get_bone_pose(5)), "Animation can take over")
	rig.procedural_pose = true
	state.riding = false
	bike.snap(state)
	bike.draw(1)
	check(not rig.visible, "Dismount hides rider")
	print("Cyclist rig: ", fails, " failures; 72 riding poses")
	if "--capture" in OS.get_cmdline_user_args():
		state.riding = true
		state.crank = 1.2
		state.steer = 0.3
		state.squash = 0
		state.squash_f = 0
		state.squash_r = 0
		bike.snap(state)
		bike.draw(1)
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
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tools/control/runs/cyclist_74.png")
	bike.free()
	quit(1 if fails else 0)
