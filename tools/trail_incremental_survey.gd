extends SceneTree
const Source := preload("res://scripts/lab/trail_lab_game_source.gd")
const Scout := preload("res://scripts/lab/trail_lab_scout_job.gd")
const Builder := preload("res://scripts/lab/trail_lab_builder.gd")
const Fixture := preload("res://tools/trail_lab_fixture.gd")
const Probe := preload("res://scripts/lab/trail_lab_ride_probe.gd")
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 600)
	run.call_deferred()
func run() -> void:
	var report := {schema = 1, search = [], construction = [], protocol = "Six preselected game snapshots; three frozen game corridors, same source/seed/settings before and after; no rerolls"}
	var reference = load("res://.godot/trail_before_direct.gd")
	if reference == null: printerr("Prepare .godot/trail_before_direct.gd from d9a6e4e"); quit(1); return
	var args := OS.get_cmdline_user_args()
	var only_case := args[args.find("--case") + 1] if "--case" in args else ""
	var after_only := "--after-only" in args
	if not only_case.is_empty() or after_only: report = JSON.parse_string(FileAccess.get_file_as_string("res://docs/data/trail_incremental_2026_11_03.json"))
	for seed_text: String in ([] if not only_case.is_empty() or after_only else ["7", "111", "ushchelye", "2026", "31415", "taiga"]):
		var cache := "res://.godot/trail_game_%s.res" % seed_text
		var input = Source.open(cache).get("input")
		if input == null:
			input = Source.generate(seed_text)
			ResourceSaver.save(input, cache)
		var terrain := Source.terrain(input)
		var job := Scout.new(terrain)
		var published := []
		var sites := job.find(terrain.seed, func(site: Dictionary) -> void: published.append(site.trail_seed))
		var record := {seed = seed_text, terrain_hash = Source.geometry_fingerprint(input), search = job.stats, proposals = sites.size(), published = published.size()}
		report.search.append(record)
		print("SEARCH ", seed_text, " first=", job.stats.first_proposal_ms, " total=", job.stats.ms, " proposals=", sites.size())
	for name: String in ["7_30", "111_0", "111_42"]:
		if not only_case.is_empty() and name != only_case: continue
		var path := "res://resources/trails/lab/game_example_111_44101.tres" if name == "111_42" else "res://resources/trails/lab/braking_case_%s.tres" % name
		var project = load(path)
		if project == null: printerr("Missing frozen project: ", path); quit(1); return
		project = project.detached()
		project.source.earthwork_limits.unlimited = true
		var pair := {case = name, source_hash = project.source.fingerprint(), before = {}, after = {}}
		if after_only:
			for existing: Dictionary in report.construction:
				if existing.case == name:
					if existing.source_hash != pair.source_hash: printerr("Changed comparison source: ", name); quit(1); return
					pair.before = existing.before
		for method: String in ["before", "after"]:
			if after_only and method == "before": continue
			var t := Time.get_ticks_usec()
			var built: Dictionary = reference.build_project(project.source, project.seed, project.style, project.settings) if method == "before" else Builder.build_project(project.source, project.seed, project.style, project.settings)
			var item := {project_ms = (Time.get_ticks_usec() - t) / 1000.0, built = not built.routes.is_empty(), accepted = false, physical = false,
				tries = built.stats.get("tries", 0), walk_ms = built.stats.get("walk_ms", 0), method = built.stats.get("primary_method", "walk_then_corridor"),
				selection_attempts = built.stats.get("selection_attempts", []), reason = built.stats.get("reason", ""), source_unchanged = project.source.fingerprint() == pair.source_hash}
			if item.built:
				Builder.publish_project(built)
				var routes: Array[TrailDefinition] = []; routes.assign(built.routes)
				var source = project.source.duplicate(true); source.apply_cuts(built.cuts)
				t = Time.get_ticks_usec()
				var ready := Fixture.prepare(routes, true, "generated", source)
				item.preparation_ms = (Time.get_ticks_usec() - t) / 1000.0
				item.errors = Array(ready.errors)
				item.accepted = ready.errors.is_empty() and ready.heights != null
				item.length = routes[0].route_length(); item.elements = routes[0].elements.size()
				if item.accepted:
					ready.heights.obstacles.set_trail(ready.technical.collide, ready.technical.bumps)
					var ride := Probe.run(ready.heights, routes[0], {from = 0.0, speed = 0.0, policy = "careful"})
					item.physical = ride.completed
					item.ride = {status = ride.status, station = ride.station, time = ride.time, max_offset = ride.max_offset}
			pair[method] = item
			print("BUILD ", name, " ", method, " ms=", item.project_ms, " accepted=", item.accepted, " physical=", item.physical, " tries=", item.tries, " attempts=", item.selection_attempts.size())
		var replaced := false
		for i in report.construction.size():
			if report.construction[i].case == name: report.construction[i] = pair; replaced = true; break
		if not replaced: report.construction.append(pair)
		var checkpoint := FileAccess.open("res://docs/data/trail_incremental_2026_11_03.json", FileAccess.WRITE)
		checkpoint.store_string(JSON.stringify(report, "  ")); checkpoint.close()
	quit()
