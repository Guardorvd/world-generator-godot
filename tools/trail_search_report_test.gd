extends SceneTree
## Audit the fixed-map survey, independently of its counting and acceptance code.
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize() -> void:
	var protocol: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://docs/data/trail_search_protocol_2026_11_03.json"))
	var before: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://docs/data/trail_search_baseline_2026_11_03.json"))
	var after: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://docs/data/trail_search_after_2026_11_03.json"))
	check(before.worlds.size() == protocol.seeds.size() and after.worlds.size() == protocol.seeds.size(), "every preselected seed is present before and after")
	var hashes := {}
	for world in before.worlds: hashes[world.seed] = world.terrain_hash
	var retried := false
	for report in [before, after]:
		for world in report.worlds:
			check(hashes.get(world.seed) == world.terrain_hash, "same terrain, masks and infrastructure: " + world.seed)
			var built := 0
			var accepted := 0
			var physical := 0
			var explained := true
			var budgets := true
			var count := mini(int(report.site_limit), int(world.candidates_found))
			for k in world.attempts.size():
				var a: Dictionary = world.attempts[k]
				check(a.index == k * int(world.candidates_found) / maxi(1, count), "unfiltered sample index: %s/%d" % [world.seed, k])
				built += int(a.built)
				accepted += int(a.accepted)
				if a.accepted:
					check(a.built and a.completion.complete and a.has("ride"), "accepted route is complete and physically tested: %s/%d" % [world.seed, a.index])
					physical += int(a.ride.completed)
				else: explained = explained and not a.reasons.is_empty() and not str(a.reasons[0]).is_empty()
				var attempts: Array = a.builder.get("base_attempts", [])
				budgets = budgets and attempts.size() <= 3 and a.builder.get("retained_lines", 0) <= 3
				if attempts.size() > 1 and not attempts[0].accepted: retried = true
				var fit: Dictionary = a.builder.get("element_fit", {})
				if fit.has("budget"): budgets = budgets and fit.bake_count <= fit.budget
			check(built == world.projects_built and accepted == world.trails_accepted and physical == world.physically_completed, "built, accepted and physical counters are independent: " + world.seed)
			check(explained and world.unexplained_failures == 0, "all refusals have reasons: " + world.seed)
			check(budgets, "candidate and fitting work stay within their budgets: " + world.seed)
	check(retried, "a refused first tread is followed by reserve-line attempts within the shared budget")
	quit(1 if failures else 0)
