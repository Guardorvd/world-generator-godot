extends SceneTree
## Isolated check of the line builder (TrailRouter) on the saved site: only the site file, no world or generation.
##   godot --headless --path . --script res://tools/trail_route_test.gd
##   godot --path . --script res://tools/trail_route_test.gd -- --capture   (overview of the found lines)
## Contract (step 2, new principle): the builder lays the route and the ground is prepared for it. Grade, radius and
## earthwork depth are reported against their targets, never a reason to refuse; refusals are corridor (water, bridges,
## paths, zone edge), separation, input and budget only.
## Cases: a route found over the natural land and built; a pair whose straight line is unusable and which the builder
## detours; a line over a ridge whose earthworks are deeper than the old 1.2 m / 1.0 m — prepared by the shared surface
## builder, continuous at the edge of the widened zone, ridden; refusals (separated by water/road,
## exhausted budget, start in water); repeatability; Trail Lab: the button path, a refusal keeps the previous route, one
## automatic ride of the built line with the production controller.
## Report: tools/control/runs/trail_route/metrics.json. About 30 s headless on the second PC.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const OUT := "res://tools/control/runs/trail_route"
## Pairs in site metres, picked once by eye from the site's map; the builder gets nothing but these points.
const NATURAL := [Vector2(126, 222), Vector2(78, 270)]  # west hillside: straight line up to 34 % at 4 m
const DETOUR := [Vector2(126, 246), Vector2(78, 174)]   # straight line crosses a stream and a 32 % bank
const SEPARATED := [Vector2(146, 266), Vector2(254, 282)] # across the river and the road
const RIDGE := [Vector2(108.5, 84.5), Vector2(172.5, 84.5)] # 64 m straight over a ridge 5 m above the chord
const OLD_CUT := 1.2  # earthwork limits of the previous contract (TrailRouter.DEFAULTS max_cut / max_fill)
const OLD_FILL := 1.0
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

## The accepted line is honest: every correctness check ran and passed, no elements, the corridor and work zone hold;
## grade, radius and earthworks are reported (info), not judged against limits.
func accepted_line(name: String, r: TrailRouter) -> void:
	var states := PackedStringArray()
	for c: Dictionary in r.checks: states.append("%s: %s" % [c.name, c.state])
	check(r.found and r.accepted and r.checks.size() == 5, "%s: line found over the land, ground prepared, every correctness check passed (%s)" % [name, "; ".join(states) if r.reason.is_empty() else r.reason])
	if not r.accepted: return
	check(r.definition.elements.is_empty() and r.definition.kind == "mountain" and r.survey.complete(),
		"%s: plain TrailDefinition without elements; finished-surface survey complete: peak %.1f%% (target %.0f%%), radius from %.1f m (wanted %.0f m)" % [
		name, r.survey.peak_grade * 100.0, r.request.grade * 100.0, r.stats.min_radius, r.request.min_radius])
	var bad := 0
	for p in r.definition.points: bad += int(r.blocked(p) != TrailRouter.Block.FREE)
	check(bad == 0 and _site.inside_errors([r.definition] as Array[TrailDefinition]).is_empty(), "%s: smoothed corridor clear of water, bridges, paths and the zone edge at all %d points" % [name, r.definition.points.size()])
	var gap := edge_gap(r.prepared.heights)
	check(gap <= _edge_before + 0.001, "%s: no wall at the edge of the prepared zone — boundary vertices next to untouched cells off the old triangles by %.4f m (site before the trail %.4f m)" % [name, gap, _edge_before])


## Largest difference between a boundary vertex of a metre patch (next to a cell without a patch) and the coarse
## triangles the neighbouring cell is drawn and walked on: a wall or a gap at the edge of the prepared zone shows here.
func edge_gap(h: Heightfield) -> float:
	var r := h.road_refinement
	var W := h.world.W
	var worst := 0.0
	for key: int in r.patches:
		var hs: PackedFloat32Array = r.patches[key].h
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				var open := (x == 0 and not r.patches.has(key - 1)) or (x == RoadRefinement.DIV and not r.patches.has(key + 1)) \
					or (z == 0 and not r.patches.has(key - W)) or (z == RoadRefinement.DIV and not r.patches.has(key + W))
				if not open: continue
				var at := Vector2((key % W) * RoadRefinement.DIV + x, (key / W) * RoadRefinement.DIV + z) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
				worst = maxf(worst, absf(hs[z * RoadRefinement.STRIDE + x] - h.base_ground_at(at.x, at.y)))
	return worst

var _site: TrailSite
var _edge_before := 0.0

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_site = Fixture.site()
	check(_site != null, "saved site opens: %s" % Fixture.site_error)
	if _site == null:
		quit(1)
		return
	var file_hash := FileAccess.get_sha256(Fixture.SITE)
	_edge_before = edge_gap(_site.surface())
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
	# 3b. Earthworks deeper than the old limits: a straight line over a ridge (5 m above the chord) with a gentle target
	# grade, built by the same shared surface builder (TrailSite.prepare → TrailBuilder.bake_elements). Before, the profile
	# was clamped to 1.2 m of cut and the router refused such a line; now the ground is cut to the designed profile, the
	# zone of influence widens with the depth and new metre patches carry the side slopes out to the ground.
	var ridge := TrailDefinition.new()
	ridge.id = "site_route"
	ridge.kind = "mountain"
	ridge.width = 3.0
	ridge.surface = RoadSurface.DIRT
	ridge.earthwork = 1.0
	ridge.auto_bank = 1.0
	ridge.shaping = TrailShaping.preset("mountain")
	ridge.shaping.grade_limit = 0.06
	ridge.shaping.strength = 1.0
	ridge.shaping.end_fade = 4.0
	var line := PackedVector2Array()
	for k in 65: line.append(RIDGE[0].lerp(RIDGE[1], k / 64.0))
	ridge.points = line
	var built := _site.prepare([ridge] as Array[TrailDefinition])
	check(built.errors.is_empty(), "ridge: built by the shared surface builder: %s" % "; ".join(built.errors))
	if built.errors.is_empty():
		var hr: Heightfield = built.heights
		var sh: Dictionary = hr.road_refinement.trail_shaping.site_route
		var survey := TrailSurvey.measure(hr, ridge, 0.06)
		report.ridge = {earthworks = sh, peak_grade = survey.peak_grade, natural = sh.grade_natural, added = hr.road_refinement.build_timings.get("trail_patches_added", 0)}
		check(sh.max_cut > OLD_CUT or sh.max_fill > OLD_FILL, "ridge: earthworks over the old limits — cut %.2f m (old %.1f), fill %.2f m (old %.1f), %.0f / %.0f m³" % [
			sh.max_cut, OLD_CUT, sh.max_fill, OLD_FILL, sh.cut_m3, sh.fill_m3])
		check(survey.complete() and survey.peak_grade < sh.grade_natural * 0.6, "ridge: the ground is prepared to the profile — finished grade up to %.1f%% against %.1f%% of the natural ground (target 6%%)" % [
			survey.peak_grade * 100.0, sh.grade_natural * 100.0])
		check(sh.reach > ridge.width * 0.5 + RoadRefinement.REACH + 1.0 and hr.road_refinement.build_timings.get("trail_patches_added", 0) > 0,
			"ridge: the prepared zone widens past the old strip (%.1f m from the axis against %.1f m) with %d new metre patches" % [sh.reach,
			ridge.width * 0.5 + RoadRefinement.REACH, hr.road_refinement.build_timings.get("trail_patches_added", 0)])
		var gap := edge_gap(hr)
		check(gap <= _edge_before + 0.001, "ridge: no wall or gap at the edge of the prepared zone (boundary off the old triangles %.4f m, site before %.4f m)" % [gap, _edge_before])
		# the side slope: no vertex step between neighbouring metre vertices steeper than the side slope can make
		var steepest := 0.0
		for key: int in hr.road_refinement.patches:
			var hs: PackedFloat32Array = hr.road_refinement.patches[key].h
			for z in RoadRefinement.STRIDE:
				for x in RoadRefinement.DIV:
					steepest = maxf(steepest, absf(hs[z * RoadRefinement.STRIDE + x + 1] - hs[z * RoadRefinement.STRIDE + x]) / RoadRefinement.STEP)
		report.ridge.steepest_step = steepest
		print("ridge: steepest step between metre vertices %.2f m/m" % steepest)
		report.ridge.ride = ride_alone(hr, ridge, "ridge")
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


## One ride of a built line with the game's controller on its finished surface (no lab scene), downhill from the start.
func ride_alone(h: Heightfield, line: TrailDefinition, tag: String) -> Dictionary:
	var controller := BikeController.new()
	var player := PlayerState.new()
	var bike := BikeRide.new()
	var at := line.point_at(1.0)
	player.x = at.x
	player.z = at.y
	player.feet = h.surface_at(at.x, at.y, -INF)
	player.on_ground = true
	bike.x = player.x
	bike.z = player.z
	bike.y = player.feet
	bike.heading = line.heading_at(1.0)
	bike.mount(player)
	bike.speed = 3.0
	var ticks := 0
	var worst := 0.0
	var crashed := false
	while ticks < 60 * 60:
		var here := Vector2(bike.x, bike.z)
		var near := line.nearest(here)
		worst = maxf(worst, near.z)
		if near.x > line.route_length() - 2.0: break
		var target := line.point_at(near.x + 6.0) - here
		var steer := clampf(-wrapf(atan2(-target.x, -target.y) - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		h.obstacles.update(player.x, player.z, PackedFloat32Array(), -1)
		controller.ride(1.0 / 60.0, player, bike, h.world, h, 0.4, steer, false, false, false)
		ticks += 1
		if bike.crashed:
			crashed = true
			break
	var ridden := line.nearest(Vector2(bike.x, bike.z)).x
	check(ridden > line.route_length() - 3.0 and not crashed, tag + ": one ride over the prepared line with the game's controller: %.0f of %.0f m in %.1f s, off axis up to %.2f m, fall: %s (not a safety guarantee)" % [
		ridden, line.route_length(), ticks / 60.0, worst, crashed])
	return {station = ridden, length = line.route_length(), seconds = ticks / 60.0, off_axis = worst, crashed = crashed}
