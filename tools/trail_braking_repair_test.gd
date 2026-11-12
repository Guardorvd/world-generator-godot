extends SceneTree
const P := preload("res://scripts/lab/trail_lab_project.gd")
const Repair := preload("res://scripts/lab/trail_lab_braking_repair.gd")
const F := preload("res://scripts/lab/trail_lab_fixture.gd")
const V := preload("res://scripts/lab/trail_lab_validation.gd")
const Probe := preload("res://scripts/lab/trail_lab_ride_probe.gd")
const CACHE := "res://.godot/trail_element_cases_2026_11_03/"
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 1800)
	run.call_deferred()
func run() -> void:
	var output := {cases = [], accepted_routes = 0, processed_refusals = 0}
	var failed := false
	DirAccess.make_dir_recursive_absolute(CACHE)
	for name: String in ["7_30", "111_0"]:
		var p := ResourceLoader.load("res://resources/trails/lab/braking_case_" + name + ".tres", "", ResourceLoader.CACHE_MODE_IGNORE) as P
		var fingerprint := p.source.fingerprint()
		var original := p.routes[0].duplicate(true) as TrailDefinition
		var before := var_to_bytes_with_objects(p.routes[0]).hex_encode().sha256_text()
		var repair := Repair.solve(p.source, p.routes[0], p.settings)
		var record := {name = name, seed = p.seed, source_hash = fingerprint, source_unchanged = p.source.fingerprint() == fingerprint, repair = repair, rides = []}
		print("REPAIR ", name, " accepted=", repair.accepted, " selected=", repair.get("selected", "none"), " trials=", repair.trials.size())
		if repair.accepted:
			var ready := F.prepare(p.copy_routes(), true, "generated", p.source)
			record.final_errors = Array(ready.errors)
			if ready.heights != null:
				var h: Heightfield = ready.heights
				var tech := TrailTechnical.build(h, p.routes)
				h.obstacles.set_trail(tech.collide, tech.bumps)
				var checked := V.measure(h, p.routes[0])
				var sections_passed := true
				for zone: Vector2 in repair.intervals:
					var from := p.routes[0].nearest(original.point_at(zone.x + 5)).x
					var to := p.routes[0].nearest(original.point_at(zone.y + 8)).x
					var section := Probe.run(h, p.routes[0], {from = from, to = to, speed = 6.0, policy = "careful_section"})
					sections_passed = sections_passed and section.completed
					record.rides.append(section)
					print("REPAIRED SECTION ", name, " ", section.status, " ", from, "-", to)
				record.safety_bikeride = sections_passed
				for policy: String in ["model_profile", "careful"]:
					var spec := {from = 0.0, speed = 0.0, policy = policy}
					if policy == "model_profile": spec.profile = checked.scenarios.normal.speeds
					var ride := Probe.run(h, p.routes[0], spec)
					record.rides.append(ride)
					if policy == "careful": record.safety_bikeride = record.safety_bikeride and ride.completed
					else: record.fast_profile_bikeride = ride.completed
					print("REPAIRED WHOLE ", name, " ", policy, " ", ride.status, " s=", ride.station)
			p.accepted = ready.errors.is_empty() and record.get("safety_bikeride", false)
			record.accepted_route = p.accepted
			if p.accepted: output.accepted_routes += 1
			else: failed = true
			p.report.braking_repair = repair
			ResourceSaver.save(p, CACHE + "braking_" + name + ".tres")
		else:
			record.accepted_route = false
			record.unchanged_on_refusal = before == var_to_bytes_with_objects(p.routes[0]).hex_encode().sha256_text()
			output.processed_refusals += 1
			if not record.unchanged_on_refusal: failed = true
		if name == "7_30" and not record.accepted_route: failed = true
		output.cases.append(record)
		var file := FileAccess.open("res://docs/data/trail_braking_repair_2026_11_03.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(output, "  "))
	quit(1 if failed else 0)
