extends SceneTree
## Isolated check of the automatic choice of a trail place (TrailPicker over TrailRouter) on the saved site:
## only the site file, no world or generation, no coordinates given.
##   godot --headless --path . --script res://tools/trail_pick_test.gd
##   godot --path . --script res://tools/trail_pick_test.gd -- --capture   (overview of the chosen trail)
## Cases: a trail found and built with its real length and descent; repeatability; impossible requirements refused;
## the whole-operation budgets hold (also under a tight budget); Trail Lab's button, the time from the press to the
## ready scene, a refusal keeps the previous trail; one ride of the chosen trail with the production controller.
## Report: tools/control/runs/trail_pick/metrics.json. About 30 s headless on the second PC.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const OUT := "res://tools/control/runs/trail_pick"
var failures := 0
var checks := 0
var report := {}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("trail_pick: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

## Budgets are for the whole operation, never per pair.
func within_budget(name: String, p: TrailPicker) -> void:
	var q := p.request
	check(p.stats.pairs_searched <= q.pairs and p.stats.builds <= q.builds and p.stats.expansions <= q.budget and p.stats.repairs <= q.repairs,
		"%s: whole-operation budgets hold — pairs %d/%d, full builds %d/%d, expansions %d/%d, repairs %d/%d" % [name,
		p.stats.pairs_searched, q.pairs, p.stats.builds, q.builds, p.stats.expansions, q.budget, p.stats.repairs, q.repairs])

func numbers(p: TrailPicker) -> Dictionary:
	var out := {accepted = p.accepted, reason = p.reason, start = str(p.start), finish = str(p.finish), stats = p.stats.duplicate(),
		rejected = p.rejected.duplicate(), tried = []}
	for t: Dictionary in p.tried:
		out.tried.append({start = str(t.start), finish = str(t.finish), score = t.score, outcome = t.outcome, reason = t.reason, expansions = t.expansions, builds = t.builds})
	if p.accepted:
		var r := p.router
		out.route = {length = r.stats.length, drop = r.stats.drop, peak_grade = r.stats.peak_grade, cut_m3 = r.stats.cut_m3,
			fill_m3 = r.stats.fill_m3, min_radius = r.stats.min_radius, searches = r.stats.searches, build_ms = r.stats.build_ms}
	return out

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var site := Fixture.site()
	check(site != null, "saved site opens: %s" % Fixture.site_error)
	if site == null:
		quit(1)
		return
	var file_hash := FileAccess.get_sha256(Fixture.SITE)
	# 1. One trail, chosen and built without coordinates.
	var picked := TrailPicker.find(site)
	report.found = numbers(picked)
	print(picked.summary())
	check(picked.accepted, "a trail is chosen and built automatically: %s" % (picked.reason if not picked.accepted else "(%.0f, %.0f) → (%.0f, %.0f)" % [picked.start.x, picked.start.y, picked.finish.x, picked.finish.y]))
	within_budget("found", picked)
	if picked.accepted:
		var r := picked.router
		var length := r.definition.route_length()
		var drop: float = r.survey.support[0] - r.survey.support[-1]
		check(length >= picked.request.length_min and length <= picked.request.length_max,
			"real length on the finished surface %.0f m within %.0f–%.0f m" % [length, picked.request.length_min, picked.request.length_max])
		check(drop >= picked.request.min_drop and r.survey.support[0] > r.survey.support[-1],
			"real descent %.1f m ≥ %.1f m: the start is above the finish" % [drop, picked.request.min_drop])
		var states := PackedStringArray()
		for c: Dictionary in r.checks: states.append(c.state)
		check(r.accepted and r.survey.level() == "within" and r.definition.elements.is_empty(),
			"every checked requirement met on the finished surface (%s), no elements" % ", ".join(states))
	# 2. Repeatability; the site suitability data are reused, not prepared again.
	var again := TrailPicker.find(site)
	check(picked.accepted and again.accepted and again.start == picked.start and again.finish == picked.finish
		and again.router.definition.points == picked.router.definition.points and again.stats.expansions == picked.stats.expansions
		and again.stats.builds == picked.stats.builds, "same request → same start, finish, line, expansions and builds")
	check(again.stats.prepare_reused and again.stats.prepare_ms < 5.0, "site suitability data reused: %.1f ms now, %.0f ms when prepared" % [again.stats.prepare_ms, again.stats.prepare_cost_ms])
	report.again_ms = again.stats.total_ms
	# 3. Impossible requirements: an honest refusal, nothing relaxed.
	var steep := TrailPicker.find(site, {min_drop = 40.0})
	report.impossible = numbers(steep)
	check(not steep.accepted and steep.reason.contains("отсев") and steep.stats.builds == 0, "descent of 40 m on this site refused: %s" % steep.reason)
	within_budget("impossible", steep)
	# 4. A tight whole-operation budget is respected (found or refused, never more).
	var tight := TrailPicker.find(site, {budget = 1500, builds = 1, repairs = 1})
	report.tight = numbers(tight)
	within_budget("tight", tight)
	check(tight.accepted or not tight.reason.is_empty(), "tight budget gives a result or a stated reason: %s" % (tight.reason if not tight.accepted else "found"))
	# 5. Trail Lab: the button, time from the press to the scene, a refusal keeps the trail, one ride.
	var lab := preload("res://scenes/trail_lab.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(lab)
	lab.set_physics_process(false)
	await process_frame
	var values := {}
	for key: String in lab.editor.numbers:
		if key.begins_with("route_"): values[key] = lab.editor.numbers[key].value
	var t0 := Time.get_ticks_usec()
	lab.editor.find_requested.emit(values)
	var outside_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var timings: Dictionary = lab.build_timings
	check(lab.ground_kind == "site" and lab.routes[0].id == "site_route" and lab.pick_result.accepted
		and lab.routes[0].points == picked.router.definition.points
		and is_equal_approx(lab.editor.numbers.route_start_x.value, picked.start.x), "Trail Lab's «Найти трассу» builds the same trail and fills in its start and finish")
	check(timings.total_ms >= timings.builder_ms and timings.builder_ms >= lab.pick_result.stats.total_ms and timings.total_ms <= outside_ms + 1.0,
		"time from the press to the ready scene %.0f ms (measured outside %.0f ms) = builder %.0f + scene %.0f; data reused: %s" % [
		timings.total_ms, outside_ms, timings.builder_ms, timings.total_ms - timings.builder_ms, lab.pick_result.stats.prepare_reused])
	report.lab = {total_ms = timings.total_ms, builder_ms = timings.builder_ms, outside_ms = outside_ms, picker_ms = lab.pick_result.stats.total_ms}
	var kept: Heightfield = lab.heights
	var refused := values.duplicate()
	refused.route_drop = 40.0
	lab.editor.find_requested.emit(refused)
	check(lab.heights == kept and lab.routes[0].points == picked.router.definition.points and lab.editor.line_report.text.contains("Трасса не найдена"),
		"an impossible request keeps the previous trail; the panel says why")
	var d: TrailDefinition = lab.routes[0]
	lab.reset_ride(0.0, 4.0)
	var worst_off := 0.0
	var ticks := 0
	var top := 0.0
	while ticks < 60 * 60:
		var here := Vector2(lab.bike.x, lab.bike.z)
		var near := d.nearest(here)
		worst_off = maxf(worst_off, near.z)
		if near.x > d.route_length() - 3.0: break
		var target := d.point_at(near.x + 6.0) - here
		var steer := clampf(-wrapf(atan2(-target.x, -target.y) - lab.bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		lab.step_simulation(1.0 / 60.0, 0.6, steer, false, false)
		top = maxf(top, absf(lab.bike.speed))
		ticks += 1
		if lab.crash.active(): break
	var ridden := d.nearest(Vector2(lab.bike.x, lab.bike.z)).x
	report.ride = {station = ridden, length = d.route_length(), seconds = ticks / 60.0, off_axis = worst_off, crashed = lab.crash.active(), top_speed = top}
	check(ridden > d.route_length() - 4.0 and not lab.crash.active(), "one automatic ride downhill: %.0f of %.0f m in %.1f s, off axis up to %.2f m, top %.1f m/s, crash: %s (not a safety guarantee)" % [
		ridden, d.route_length(), ticks / 60.0, worst_off, top, lab.crash.active()])
	if "--capture" in OS.get_cmdline_user_args():
		lab.set_overview(true)
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT + "/auto.png")
	check(FileAccess.get_sha256(Fixture.SITE) == file_hash, "site file unchanged")
	lab.queue_free()
	await process_frame
	report.failures = failures
	report.checks = checks
	FileAccess.open(OUT + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("trail_pick: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)
