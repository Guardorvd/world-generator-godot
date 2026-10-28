extends SceneTree
## Isolated check of the line builder (TrailRouter) on the saved site: only the site file, no world or generation.
##   godot --headless --path . --script res://tools/trail_route_test.gd
##   godot --path . --script res://tools/trail_route_test.gd -- --capture   (overview of the found lines)
## Cases: a route found over the natural land and built; a pair whose straight line is unusable and which the builder
## detours; refusals (separated by water/road, exhausted budget, start in water); repeatability; Trail Lab: the button
## path, a refusal keeps the previous route, one automatic ride of the built line with the production controller.
## Report: tools/control/runs/trail_route/metrics.json. About 30 s headless on the second PC.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const OUT := "res://tools/control/runs/trail_route"
## Pairs in site metres, picked once by eye from the site's map; the builder gets nothing but these points.
const NATURAL := [Vector2(126, 222), Vector2(78, 270)]  # west hillside: straight line up to 34 % at 4 m
const DETOUR := [Vector2(126, 246), Vector2(78, 174)]   # straight line crosses a stream and a 32 % bank
const SEPARATED := [Vector2(146, 266), Vector2(254, 282)] # across the river and the road
var failures := 0
var checks := 0
var report := {}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("trail_route: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func request(pair: Array, extra := {}) -> Dictionary:
	var r := {start = pair[0], finish = pair[1]}
	r.merge(extra, true)
	return r

func numbers(r: TrailRouter) -> Dictionary:
	return {found = r.found, accepted = r.accepted, reason = r.reason, stage = r.stage,
		length = r.stats.get("length", 0.0), straight = r.straight.get("length", 0.0), straight_ok = r.straight.get("ok", false),
		straight_problems = Array(r.straight.get("problems", [])),
		drop = r.stats.get("drop", 0.0), climb = r.stats.get("climb", 0.0), descent = r.stats.get("descent", 0.0),
		peak_grade = r.stats.get("peak_grade", 0.0), cut_m3 = r.stats.get("cut_m3", 0.0), fill_m3 = r.stats.get("fill_m3", 0.0),
		min_radius = r.stats.get("min_radius", INF), expansions = r.stats.expansions, searches = r.stats.searches,
		repairs = r.stats.repairs, builds = r.stats.builds, corner_fixes = r.stats.get("corner_fixes", 0),
		search_ms = r.stats.search_ms, geometry_ms = r.stats.geometry_ms, estimate_ms = r.stats.estimate_ms,
		build_ms = r.stats.build_ms, total_ms = r.stats.total_ms, notes = Array(r.notes)}

## The accepted line is honest: every check ran and passed, no elements, the corridor and work zone hold.
func accepted_line(name: String, r: TrailRouter) -> void:
	var states := PackedStringArray()
	for c: Dictionary in r.checks: states.append("%s: %s" % [c.name, c.state])
	check(r.found and r.accepted and r.checks.size() == 4, "%s: line found over the land, built and every checked requirement met (%s)" % [name, "; ".join(states) if r.reason.is_empty() else r.reason])
	if not r.accepted: return
	check(r.definition.elements.is_empty() and r.definition.kind == "mountain" and r.survey.level() == "within" and r.survey.complete(),
		"%s: plain TrailDefinition without elements; finished-surface survey complete and within %.0f%%: peak %.1f%%" % [name, r.request.grade * 100.0, r.survey.peak_grade * 100.0])
	var bad := 0
	for p in r.definition.points: bad += int(r.blocked(p) != TrailRouter.Block.FREE)
	check(bad == 0 and _site.inside_errors([r.definition] as Array[TrailDefinition]).is_empty(), "%s: smoothed corridor clear of water, bridges, paths and the zone edge at all %d points" % [name, r.definition.points.size()])
	check(r.stats.min_radius >= r.request.min_radius - 0.01, "%s: turn radii from %.1f m (required %.0f m)" % [name, r.stats.min_radius, r.request.min_radius])

var _site: TrailSite

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_site = Fixture.site()
	check(_site != null, "saved site opens: %s" % Fixture.site_error)
	if _site == null:
		quit(1)
		return
	var file_hash := FileAccess.get_sha256(Fixture.SITE)
	var demo := _site.demo_route()
	# 1. A route over the natural land of the site.
	var natural := TrailRouter.build(_site, request(NATURAL))
	report.natural = numbers(natural)
	print(natural.summary())
	accepted_line("natural", natural)
	check(natural.definition == null or natural.definition.points[0].distance_to(demo.points[0]) > 20.0, "the demo route is neither used nor the result")
	# 2. Repeatability: the same input gives the same line, the same work and the same surface.
	var again := TrailRouter.build(_site, request(NATURAL))
	var same: bool = natural.accepted and again.accepted and natural.definition.points == again.definition.points \
		and natural.stats.expansions == again.stats.expansions and natural.stats.repairs == again.stats.repairs \
		and var_to_bytes(natural.prepared.heights.road_refinement.patches) == var_to_bytes(again.prepared.heights.road_refinement.patches)
	check(same, "same input → same line (%d points), expansions (%d), repairs and finished surface" % [natural.definition.points.size() if natural.definition else 0, natural.stats.expansions])
	# 3. The straight line between the points is unusable; the builder finds a detour.
	var detour := TrailRouter.build(_site, request(DETOUR))
	report.detour = numbers(detour)
	print(detour.summary())
	check(not detour.straight.ok, "detour: the straight line itself is unusable: %s" % "; ".join(detour.straight.problems))
	accepted_line("detour", detour)
	if detour.accepted:
		check(detour.stats.length > detour.straight.length * 1.05, "detour: the line goes round (%.0f m against %.0f m straight)" % [detour.stats.length, detour.straight.length])
	# 4. Refusals with a clear reason.
	var apart := TrailRouter.build(_site, request(SEPARATED))
	report.separated = numbers(apart)
	check(not apart.found and apart.reason.contains("разделены"), "points across the river and the road refused: %s" % apart.reason)
	var poor := TrailRouter.build(_site, request(DETOUR, {budget = 200}))
	report.budget = numbers(poor)
	check(not poor.found and poor.reason.contains("бюджет") and poor.stats.expansions <= 200, "exhausted budget refused: %s (%d expansions)" % [poor.reason, poor.stats.expansions])
	var wet := TrailRouter.build(_site, request([Vector2(110, 160), NATURAL[1]]))
	check(not wet.found and wet.stage == "входные данные" and wet.reason.contains("вода"), "start in water refused: %s" % wet.reason)
	# 5. Trail Lab: the panel's button, a refusal keeps the scene, one ride of the built line.
	var lab := preload("res://scenes/trail_lab.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(lab)
	lab.set_physics_process(false)
	await process_frame
	var values := {}
	for key: String in lab.editor.numbers:
		if key.begins_with("route_"): values[key] = lab.editor.numbers[key].value
	values.merge({route_start_x = NATURAL[0].x, route_start_z = NATURAL[0].y, route_finish_x = NATURAL[1].x, route_finish_z = NATURAL[1].y}, true)
	lab.editor.line_requested.emit(values)
	check(lab.ground_kind == "site" and lab.routes.size() == 1 and lab.routes[0].id == "site_route" and lab.line_result.accepted
		and lab.routes[0].points == natural.definition.points, "Trail Lab builds the same line from the panel's numbers: %.0f ms in all" % lab.build_timings.get("total_ms", -1.0))
	report.lab_build = lab.build_timings.duplicate()
	var kept: Heightfield = lab.heights
	var refused := values.duplicate()
	refused.merge({route_finish_x = SEPARATED[1].x, route_finish_z = SEPARATED[1].y, route_start_x = SEPARATED[0].x, route_start_z = SEPARATED[0].y}, true)
	lab.editor.line_requested.emit(refused)
	check(lab.heights == kept and lab.routes[0].points == natural.definition.points and not lab.line_result.found
		and lab.editor.line_report.text.contains("Путь найден: нет"), "a refused line keeps the previous route; the panel says why")
	# One automatic ride with the production controller (steering at a point 6 m ahead, 60 % pedalling).
	var d: TrailDefinition = lab.routes[0]
	lab.reset_ride(0.0, 5.0)
	var worst_off := 0.0
	var ticks := 0
	var top_speed := 0.0
	while ticks < 60 * 60:
		var here := Vector2(lab.bike.x, lab.bike.z)
		var near := d.nearest(here)
		worst_off = maxf(worst_off, near.z)
		if near.x > d.route_length() - 3.0: break
		var target := d.point_at(near.x + 6.0) - here
		var steer := clampf(-wrapf(atan2(-target.x, -target.y) - lab.bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		lab.step_simulation(1.0 / 60.0, 0.6, steer, false, false)
		top_speed = maxf(top_speed, absf(lab.bike.speed))
		ticks += 1
		if lab.crash.active(): break
	var ridden := d.nearest(Vector2(lab.bike.x, lab.bike.z)).x
	report.ride = {station = ridden, length = d.route_length(), seconds = ticks / 60.0, off_axis = worst_off, crashed = lab.crash.active(), top_speed = top_speed}
	check(ridden > d.route_length() - 4.0 and not lab.crash.active(), "one automatic ride: %.0f of %.0f m in %.1f s, off axis up to %.2f m, top %.1f m/s, crash: %s (not a safety guarantee)" % [
		ridden, d.route_length(), ticks / 60.0, worst_off, top_speed, lab.crash.active()])
	if "--capture" in OS.get_cmdline_user_args():
		lab.set_overview(true)
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT + "/natural.png")
		var detour_values := values.duplicate()
		detour_values.merge({route_start_x = DETOUR[0].x, route_start_z = DETOUR[0].y, route_finish_x = DETOUR[1].x, route_finish_z = DETOUR[1].y}, true)
		lab.editor.line_requested.emit(detour_values)
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT + "/detour.png")
	check(FileAccess.get_sha256(Fixture.SITE) == file_hash, "site file unchanged")
	lab.queue_free()
	await process_frame
	report.failures = failures
	report.checks = checks
	FileAccess.open(OUT + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("trail_route: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)
