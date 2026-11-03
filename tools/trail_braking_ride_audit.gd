extends SceneTree
const F := preload("res://tools/trail_lab_fixture.gd")
const V := preload("res://scripts/lab/trail_lab_validation.gd")
const P := preload("res://scripts/lab/trail_lab_project.gd")
const Probe := preload("res://scripts/lab/trail_lab_ride_probe.gd")
const CACHE := "res://.godot/trail_element_cases_2026_11_03/"
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 900)
	run.call_deferred()
func run() -> void:
	var output := {cases = [], motion = "BikeRide + BikeController, 60 Hz, no resets; section starts are diagnostic only"}
	for name: String in ["7_30", "111_0", "111_42"]:
		var path := "res://resources/trails/lab/game_example_111_44101.tres" if name == "111_42" else "res://resources/trails/lab/braking_case_" + name + ".tres"
		var project := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as P
		var record := {name = name, source_hash = project.source_hash, seed = project.seed, runs = []}
		for mode: String in ["base", "final"]:
			var routes := project.copy_routes()
			if mode == "base": routes[0].elements.clear()
			var ready := F._prepare_once(routes, true, "generated", project.source)
			if not ready.errors.is_empty(): push_error(str(ready.errors)); quit(1); return
			var h: Heightfield = ready.heights
			var tech := TrailTechnical.build(h, routes)
			h.obstacles.set_trail(tech.collide, tech.bumps)
			var checked := V.measure(h, routes[0])
			var profile: PackedFloat32Array = checked.scenarios.normal.speeds
			var intervals := []
			for issue: Dictionary in checked.issues:
				if issue.scenario != "normal" or not issue.reason.contains("торможения"): continue
				for sample: Dictionary in issue.samples:
					if intervals.is_empty() or sample.station > intervals[-1].y + 8: intervals.append(Vector2(sample.station, sample.station))
					else: intervals[-1].y = sample.station
			for interval: Vector2 in intervals:
				var from := maxf(0, interval.x - 24)
				var spec := {from = from, to = minf(routes[0].route_length() - 2, interval.y + 24), profile = profile, speed = profile[floori(from)], policy = "model_profile_section"}
				var ride := Probe.run(h, routes[0], spec)
				record.runs.append({mode = mode, section = interval, ride = ride})
				print("SECTION ", name, " ", mode, " ", interval, " ", ride.status, " s=", ride.station)
			for policy: String in ["model_profile", "careful"]:
				var spec := {from = 0.0, speed = 0.0, policy = policy}
				if policy == "model_profile": spec.profile = profile
				var ride := Probe.run(h, routes[0], spec)
				record.runs.append({mode = mode, ride = ride})
				print("WHOLE ", name, " ", mode, " ", policy, " ", ride.status, " s=", ride.station, "/", routes[0].route_length())
		output.cases.append(record)
	var file := FileAccess.open("res://docs/data/trail_braking_rides_2026_11_03.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(output, "  "))
	quit()
