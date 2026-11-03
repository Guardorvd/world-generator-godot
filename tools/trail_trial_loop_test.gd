extends SceneTree
const Trial := preload("res://scripts/lab/trail_lab_trial.gd")
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()
func run() -> void:
	# Ordered physical gates: finish proximity and diagnostic teleports cannot produce a result.
	var d := TrailDefinition.new()
	d.points = PackedVector2Array([Vector2(40, 40), Vector2(40, 240)])
	var state := Trial.new()
	state.configure(d, {position = Vector2(40, 32)})
	state.retry(); state.begin()
	state.tick(1.0 / 60, Vector2(40, 239))
	check(state.phase == Trial.Phase.FAILED and not state.result.finished, "teleporting to finish cannot complete a run")
	state.retry(); state.begin()
	for i in range(0, 418): state.tick(0.02, Vector2(40, 32 + i * 0.5))
	check(state.phase == Trial.Phase.FINISHED and state.result.gates == state.gates.size(), "continuous start-to-finish passage gives a result")
	var best := state.best
	state.retry()
	check(state.phase == Trial.Phase.READY and state.elapsed == 0 and state.next_gate == 0 and state.best == best, "repeat resets progress and timer while keeping best")
	var lab: Node = load("res://scenes/trail_lab.tscn").instantiate()
	root.add_child(lab)
	await process_frame
	lab.set_physics_process(false)
	var examples := []
	for path: String in [lab.GAME_EXAMPLE, "res://resources/trails/lab/game_example_7_9066.tres"]:
		check(lab.open_game_example(path), "bundled real-world example opens: " + path)
		if lab.trial == null: lab.shutdown(); quit(1); return
		check(lab.trial.spawn.accepted and lab.trial.spawn.distance >= 2 and lab.bike.speed == 0 and lab.trial.phase == Trial.Phase.READY, "safe appearance is before start and stationary")
		var source_hash: String = lab.active_project.source_hash
		lab.step_simulation(1.0 / 60, 0, 0, false, false)
		check(lab.trial.phase == Trial.Phase.READY and lab.trial.elapsed == 0 and lab.bike.speed == 0, "waiting at spawn cannot start the timer or roll away")
		var results := []
		for repeat in 2:
			if repeat > 0: lab.trial_hud.retry.pressed.emit()
			var pilot := preload("res://scripts/lab/trail_autopilot.gd").new()
			pilot.style = "careful"
			pilot.reset(lab.routes[0], lab.heights, 0)
			lab.trial.assisted = true
			for tick in 14400:
				var input := pilot.drive(lab.bike, lab.routes[0])
				lab.step_simulation(1.0 / 60, input.throttle, input.turn, input.run, input.jump)
				if lab.trial.phase in [Trial.Phase.FINISHED, Trial.Phase.FAILED]: break
			check(lab.trial.phase == Trial.Phase.FINISHED, "real BikeRide full attempt %d finishes: %s" % [repeat + 1, lab.trial.result])
			check(lab.active_project.source_hash == source_hash and lab.trial.result.get("assisted", false), "repeat preserves source and assisted runs are marked")
			check(lab.trial_hud.description.text.contains("Финиш"), "finish result is visible in the game HUD")
			lab._sync_mouse()
			check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "result keeps cursor available for retry button")
			results.append(lab.trial.result.duplicate(true))
		examples.append({path = path, source_hash = source_hash, spawn = lab.trial.spawn, results = results, attempts = lab.trial.attempts})
	var file := FileAccess.open("res://docs/data/trail_trial_loop_2026_11_03.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({accepted = failures == 0, examples = examples}, "  "))
	lab.shutdown(); lab.queue_free()
	quit(1 if failures else 0)
