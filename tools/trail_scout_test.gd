extends SceneTree
## Isolated check of the automatic work-site choice inside a prepared world area (TrailScout). The area is the prepared
## data of a saved site read into memory (TrailSite.surface() and its world: the same WorldData and Heightfield after
## finish_paths that the game has), so no generation and no world cache — those are stale for the current code on this PC.
## The site is only the source of the area: TrailScout never reads .tsite, it cuts its own working sites in memory.
## No coordinates. One call finds a window, builds and checks one trail (TrailPicker → TrailRouter → TrailFlow) or reports a
## refusal. Second area: the steep mountain site (a normal "no place" / refusal). Total cost is printed per area.
##   godot --headless --path . --script res://tools/trail_scout_test.gd
## Report: tools/control/runs/trail_scout/metrics.json
const OUT := "res://tools/control/runs/trail_scout"
const AREAS := ["sever_gentle", "sever_hills", "sever_steep"]
var failures := 0
var checks := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	print("trail_scout: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1


func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var report := {areas = []}
	for name: String in AREAS:
		var path := TrailSite.DIR.path_join(name + TrailSite.EXT)
		var before := FileAccess.get_sha256(path)
		var t0 := Time.get_ticks_msec()
		var got := TrailSite.open(path)
		check(not got.has("error"), "%s opens as the prepared area: %s" % [name, got.get("error", "%d ms" % (Time.get_ticks_msec() - t0))])
		if got.has("error"): continue
		var source: TrailSite = got.site
		var h := source.surface() # готовая поверхность участка (метровая сетка, русла) и её WorldData
		var w := h.world
		print("— Область «%s»: %s клеток, пути %d, сооружения %d" % [name, source.size, source.trails.size(), source.structures.size()])
		var scout := TrailScout.find(w, h)
		print(scout.summary())
		if scout.flow != null: print(scout.flow.summary())
		var q := scout.request
		check(scout.verdict in ["found", "no_window", "refused_all", "budget"], "%s: normal result %s" % [name, scout.verdict])
		check(scout.stats.searched <= q.windows and scout.stats.pairs <= q.pairs and scout.stats.expansions <= q.budget 			and scout.stats.repairs <= q.repairs and scout.stats.builds <= q.builds + TrailFlow.BUILDS,
			"%s: one shared budget — windows %d/%d, pairs %d/%d, expansions %d/%d, repairs %d/%d, builds %d/%d, %.1f s" % [name, scout.stats.searched, q.windows,
			scout.stats.pairs, q.pairs, scout.stats.expansions, q.budget, scout.stats.repairs, q.repairs, scout.stats.builds,
			q.builds + TrailFlow.BUILDS, scout.stats.total_ms / 1000.0])
		if scout.accepted:
			var r := scout.picker.router
			check(r.accepted and r.survey.level() == "within", "%s: the trail meets every checked requirement on the finished surface" % name)
			check(scout.flow != null and (scout.flow.accepted or scout.flow.variant == "базовая линия"), "%s: elements judged anew (%s)" % [name, scout.flow.variant])
			var rect := Rect2(Vector2(scout.window.position) * GameConfig.TILE, Vector2(scout.window.size) * GameConfig.TILE)
			check(rect.has_point(scout.start) and rect.has_point(scout.finish), "%s: start and finish lie inside the chosen window" % name)
		else:
			check(not scout.reason.is_empty(), "%s: a refusal has a reason" % name)
		check(FileAccess.get_sha256(path) == before, "%s: area source file unchanged" % name)
		report.areas.append({area = name, verdict = scout.verdict, accepted = scout.accepted, reason = scout.reason, window = str(scout.window),
			start = str(scout.start), finish = str(scout.finish), stats = scout.stats, rejected = scout.rejected,
			windows = scout.windows.map(func(c: Dictionary) -> Dictionary: return {rect = str(c.rect), score = c.score, outcome = c.outcome})})
	report.failures = failures
	report.checks = checks
	FileAccess.open(OUT + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify(report, "	"))
	print("trail_scout: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)
