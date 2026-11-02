extends SceneTree
## Fixed sample. Explicit generation success, separate from correct handling of a rejection.
const Source := preload("res://scripts/lab/trail_lab_game_source.gd")
const Job := preload("res://scripts/lab/trail_lab_world_job.gd")
const Sites := preload("res://scripts/lab/trail_lab_sites.gd")
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const F := preload("res://tools/trail_lab_fixture.gd")
var failed := false

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 1800)
	run.call_deferred()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var seeds := ["7", "111", "ushchelye"]
	if "--seed" in args: seeds = [args[args.find("--seed") + 1]]
	var limit := 4
	if "--sites" in args: limit = int(args[args.find("--sites") + 1])
	var output := {schema = 3, seeds = seeds, site_limit = limit, worlds = [], policy = "strict game water; max cut/fill 2 m", sample = "equally spaced indices in deterministic scout order; one default project per site; no rerolls"}
	for seed_text: String in seeds:
		var cache := "res://.godot/trail_game_%s.res" % seed_text
		var input
		var source_started := Time.get_ticks_usec()
		var cached := FileAccess.file_exists(cache)
		if FileAccess.file_exists(cache): input = Source.open(cache).get("input")
		if input == null:
			cached = false
			input = Source.generate(seed_text)
			ResourceSaver.save(input, cache)
		var source_open_ms := (Time.get_ticks_usec() - source_started) / 1000.0
		var t := Time.get_ticks_usec()
		var terrain := Source.terrain(input)
		var scout := preload("res://scripts/lab/trail_lab_scout_job.gd").new(terrain)
		var sites := scout.find(terrain.seed)
		Sites.publish_world({request_id = 0, terrain = terrain, sites = sites, scout = scout.stats, timings = {}}, 0)
		var world := {seed = seed_text, source_hash = terrain.input.fingerprint(), source_ms = input.provenance.get("source_ms", 0),
			source_cached = cached, source_open_ms = source_open_ms,
			game_stages_ms = input.provenance.get("stages_ms", {}), terrain = describe(input),
			search = scout.stats, search_ms = (Time.get_ticks_usec() - t) / 1000.0, candidates_found = sites.size(),
			projects_built = 0, trails_accepted = 0, handled_rejections = 0, unexplained_failures = 0, refusal_categories = {}, refusals = {}, attempts = []}
		# Spread across the ranked list rather than testing only the easiest first entries.
		for k in mini(limit, sites.size()):
			var i := k * sites.size() / mini(limit, sites.size())
			t = Time.get_ticks_usec()
			var built := Sites.select(i)
			var attempt := {index = i, project_ms = (Time.get_ticks_usec() - t) / 1000.0, built = built, accepted = false}
			attempt.line_score = Sites._built[i].stats.get("line_score", {})
			attempt.walk_reasons = Sites._built[i].stats.get("walk_reasons", {})
			attempt.completion = Sites._built[i].stats.get("completion", {})
			attempt.fragments = Sites._built[i].stats.get("fragments", [])
			attempt.finish_refused = Sites._built[i].stats.get("finish_refused", [])
			attempt.completed_candidates = Sites._built[i].stats.get("completed_candidates", 0)
			attempt.base_surface = Sites._built[i].stats.get("base_surface", {})
			attempt.finish_plan = Sites._built[i].stats.get("finish_plan", {})
			attempt.composition_started = Sites._built[i].stats.get("composition_started", false)
			if built:
				world.projects_built += 1
				# Recheck the no-element route through the final fixture, with the published site ID.
				# This detects divergence between the preflight and the actual scene construction.
				if attempt.base_surface.get("accepted", false) and Sites.project().cuts.is_empty():
					var bare := Sites.routes()
					for d in bare: d.elements.clear(); d.sections.clear()
					var replay := F._prepare_once(bare, true, "generated", Sites.project().source)
					if replay.errors.is_empty():
						attempt.base_replay = preload("res://scripts/lab/trail_lab_base_surface.gd").audit(Sites.project().source, replay.heights, bare[0])
						if not attempt.base_replay.accepted: failed = true
					else: attempt.base_replay = {accepted = false, errors = Array(replay.errors)}; failed = true
				var prepared := F.prepare(Sites.routes(), true, "generated")
				attempt.preparation = prepared.timings
				attempt.accepted = prepared.errors.is_empty() and prepared.heights != null
				attempt.reasons = Array(prepared.errors)
			else: attempt.reasons = [Sites._built[i].stats.get("reason", "")]
			if attempt.accepted:
				world.trails_accepted += 1
				attempt.length = Sites.routes()[0].route_length()
				attempt.elements = Sites.routes()[0].elements.size()
			else:
				var explained := false
				var categories := {}
				for reason: String in attempt.reasons:
					if reason.is_empty(): continue
					explained = true
					world.refusals[reason] = int(world.refusals.get(reason, 0)) + 1
					categories[category(reason)] = true
				for key in categories: world.refusal_categories[key] = int(world.refusal_categories.get(key, 0)) + 1
				if explained: world.handled_rejections += 1
				else: world.unexplained_failures += 1; failed = true
			world.attempts.append(attempt)
			print("ATTEMPT ", seed_text, " index=", i, " built=", built, " accepted=", attempt.accepted, " fragments=", attempt.fragments.size(), " base=", attempt.base_surface.get("accepted", "not_run"), " reasons=", attempt.reasons)
		world.fragment_lines = 0; world.finish_refusals = 0; world.complete_line_candidates = 0
		world.base_checked = 0; world.base_passed = 0; world.base_repaired = 0
		for attempt in world.attempts:
			world.fragment_lines += attempt.fragments.size()
			world.finish_refusals += attempt.finish_refused.size()
			world.complete_line_candidates += attempt.completed_candidates
			if not attempt.base_surface.is_empty():
				world.base_checked += 1
				if attempt.base_surface.accepted:
					world.base_passed += 1
					world.base_repaired += int(not attempt.base_surface.repairs.is_empty())
		output.worlds.append(world)
		print("WORLD ", seed_text, " candidates=", sites.size(), " built=", world.projects_built, " accepted=", world.trails_accepted, " rejections=", world.handled_rejections)
	var path := "res://docs/data/trail_route_earthworks_2026_11_02.json"
	if "--output" in args: path = args[args.find("--output") + 1]
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(output, "  "))
	quit(1 if failed else 0)

func category(reason: String) -> String:
	if reason.begins_with("базовое полотно"): return "base_surface_or_repair"
	if reason.contains("нет законченного") or reason.contains("финиш"): return "route_completion_or_finish"
	if reason.contains("линия не проложилась"): return "line_geometry_or_footprint"
	if reason.contains("предел выемки/насыпи") or reason.contains("max_fill"): return "earthwork_limit"
	if reason.contains("земляные работы затронули"): return "protected_earthworks"
	if reason.contains("повторяет трассу"): return "final_duplicate"
	if reason.contains("пересекает трассу"): return "final_crossing"
	return "ride_or_surface_validation"

func describe(input) -> Dictionary:
	var low := INF
	var high := -INF
	var water := 0
	var rivers := 0
	var forbidden := 0
	for i in input.heights.size():
		low = minf(low, input.heights[i]); high = maxf(high, input.heights[i])
		water += int(input.water[i] != 0)
		rivers += int(input.rivers[i] != 0)
		forbidden += int(input.forbidden[i] != 0)
	return {min_height = low, max_height = high, water_cells = water, river_cells = rivers, forbidden_cells = forbidden, existing_paths = input.existing_paths.size()}
