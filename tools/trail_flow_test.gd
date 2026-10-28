extends SceneTree
## Isolated check of elements on an automatically found line (TrailFlow over TrailComposer) on the saved site:
## only the site file, no world or generation, no coordinates or stations given.
##   godot --headless --path . --script res://tools/trail_flow_test.gd
##   godot --path . --script res://tools/trail_flow_test.gd -- --capture   (overview and a view of the first element)
## Cases: at least one element placed on the found line and the result judged anew; repeatability by seed; no
## accumulated earthworks; the base definition and its build unchanged; a line without room keeps the base with a
## reason; Trail Lab's flow mode; one full automatic ride of the final trail.
## Report: tools/control/runs/trail_flow/metrics.json. About 30 s headless on the second PC.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const OUT := "res://tools/control/runs/trail_flow"
var failures := 0
var checks := 0
var report := {}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("trail_flow: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

## Everything of the base line that the elements must not touch: definition, report and its build.
func base_bytes(r: TrailRouter) -> PackedByteArray:
	var d := r.definition
	return var_to_bytes([d.points, d.elements.size(), d.width, d.auto_bank, d.earthwork, d.shaping.grade_limit, d.shaping.max_cut,
		d.shaping.max_fill, r.request, r.survey.support, r.survey.peak_grade, r.prepared.heights.road_refinement.patches, r.prepared.heights.hv])

func elements_of(d: TrailDefinition) -> Array:
	var out := []
	for e in d.elements: out.append([e.profile, e.station, e.length, e.height, e.bank])
	return out

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var site := Fixture.site()
	check(site != null, "saved site opens: %s" % Fixture.site_error)
	if site == null:
		quit(1)
		return
	var file_hash := FileAccess.get_sha256(Fixture.SITE)
	# 1. The base line: found automatically, no coordinates.
	var picked := TrailPicker.find(site)
	check(picked.accepted, "base line found automatically: %.0f m" % picked.router.stats.get("length", 0.0) if picked.accepted else picked.reason)
	if not picked.accepted:
		quit(1)
		return
	var line := picked.router
	var before := base_bytes(line)
	# 2. Elements on it, judged anew on the final surface.
	var flow := TrailFlow.dress(site, line, 1)
	print(flow.summary())
	var kinds := PackedStringArray()
	for e in flow.definition.elements: kinds.append(TrailElementLibrary.title(e.profile))
	report.flow = {accepted = flow.accepted, variant = flow.variant, message = flow.message, elements = elements_of(flow.definition),
		refusals = flow.refusals, stats = flow.stats, removed = flow.removed,
		peak_grade = flow.survey.peak_grade, peak_grade_track = flow.survey.peak_grade_track, peak_local = flow.survey.peak_local,
		peak_cross = flow.survey.peak_cross, checks = flow.checks}
	check(flow.accepted and flow.definition.elements.size() >= 1, "elements placed automatically and the result passed its own checks: %d (%s), variant %s" % [flow.definition.elements.size(), ", ".join(kinds), flow.variant])
	var allowed := true
	for e in flow.definition.elements: allowed = allowed and e.profile in TrailFlow.ALLOWED and e.height <= 0.5
	check(allowed, "only small rollers, dips and berms (height ≤ 0.5 m)")
	var states := PackedStringArray()
	for c: Dictionary in flow.checks: states.append("%s: %s" % [c.name, c.state])
	check(flow.checks.size() == 5 and flow.survey.level() == "within" and flow.survey.complete(), "final surface checked anew: %s" % "; ".join(states))
	check(flow.stats.builds <= TrailFlow.BUILDS, "extra full builds after the base: %d (limit %d), composition %.1f ms, builds %.0f ms" % [flow.stats.builds, TrailFlow.BUILDS, flow.stats.compose_ms, flow.stats.build_ms])
	# 3. Repeatability by seed and no accumulated earthworks: a second dressing is built on a fresh site copy again.
	var again := TrailFlow.dress(site, line, 1)
	var h1: Heightfield = flow.prepared.heights
	var h2: Heightfield = again.prepared.heights
	check(elements_of(again.definition) == elements_of(flow.definition) and var_to_bytes(h1.road_refinement.patches) == var_to_bytes(h2.road_refinement.patches)
		and var_to_bytes(h1.road_refinement.trail_shaping) == var_to_bytes(h2.road_refinement.trail_shaping),
		"same seed → same elements and the same surface; earthworks do not accumulate (cut %.0f / fill %.0f m³ both times)" % [
		h1.road_refinement.trail_shaping[flow.definition.id].cut_m3, h1.road_refinement.trail_shaping[flow.definition.id].fill_m3])
	var other := TrailFlow.dress(site, line, 2)
	report.seed_2 = elements_of(other.definition)
	check(base_bytes(line) == before and line.definition.elements.is_empty() and flow.definition != line.definition,
		"base definition, its report and its build unchanged by the composition")
	# 4. A line with no room for elements keeps the base line and says why.
	# The short line runs between two points of the found line (its start and its point at 32 m): ground known passable.
	var short_line := TrailRouter.build(site, {start = line.definition.points[0], finish = line.definition.point_at(32.0)})
	var empty: TrailFlow = TrailFlow.dress(site, short_line, 1) if short_line.accepted else null
	if empty != null:
		print(empty.summary())
		report.no_room = {length = short_line.stats.length, message = empty.message, builds = empty.stats.builds}
	check(empty != null and not empty.accepted and empty.variant == "базовая линия" and empty.definition == short_line.definition
		and empty.stats.builds == 0 and empty.message.contains("нет места"), "a short line (%.0f m) gets no elements and keeps its base: %s" % [
		short_line.stats.get("length", 0.0), empty.message if empty != null else short_line.reason])
	# A longer but bendy, steep line: the composer proposes, the real profile refuses, and says why.
	var bendy := TrailRouter.build(site, {start = Vector2(126, 222), finish = Vector2(78, 270)})
	var refused: TrailFlow = TrailFlow.dress(site, bendy, 1) if bendy.accepted else null
	if refused != null: report.refused = {length = bendy.stats.length, message = refused.message, refusals = refused.refusals}
	check(refused != null and not refused.accepted and refused.stats.builds == 0 and not refused.refusals.is_empty(),
		"a bendy steep line keeps its base; refusals are explained: %s" % (refused.message if refused != null else bendy.reason))
	# 5. Trail Lab: the flow mode of «Найти трассу», then one full automatic ride of the final trail.
	var lab := preload("res://scenes/trail_lab.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(lab)
	lab.set_physics_process(false)
	await process_frame
	var values := {}
	for key: String in lab.editor.numbers:
		if key.begins_with("route_"): values[key] = lab.editor.numbers[key].value
	values.route_flow = 1
	values.route_seed = 1
	var t0 := Time.get_ticks_usec()
	lab.editor.find_requested.emit(values)
	var outside_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var d: TrailDefinition = lab.routes[0]
	report.lab = {total_ms = lab.build_timings.total_ms, builder_ms = lab.build_timings.builder_ms, outside_ms = outside_ms,
		picker_ms = lab.pick_result.stats.total_ms, flow_ms = lab.flow_result.stats.total_ms, compose_ms = lab.flow_result.stats.compose_ms,
		flow_build_ms = lab.flow_result.stats.build_ms}
	check(lab.flow_result != null and lab.flow_result.accepted and elements_of(d) == elements_of(flow.definition) and lab.editor.element_choice.item_count == d.elements.size(),
		"Trail Lab builds the same trail with elements; the element editor lists them; from the press to the scene %.0f ms (picker %.0f, composition %.1f, extra builds %.0f)" % [
		lab.build_timings.total_ms, lab.pick_result.stats.total_ms, lab.flow_result.stats.compose_ms, lab.flow_result.stats.build_ms])
	lab.reset_ride(0.0, 4.0)
	var worst_off := 0.0
	var ticks := 0
	var top := 0.0
	var air := 0.0
	var on_element := {}
	while ticks < 60 * 60:
		var here := Vector2(lab.bike.x, lab.bike.z)
		var near := d.nearest(here)
		worst_off = maxf(worst_off, near.z)
		if near.x > d.route_length() - 3.0: break
		for e in d.elements:
			if absf(near.x - e.station) < e.length * 0.5: on_element[TrailElementLibrary.title(e.profile)] = maxf(on_element.get(TrailElementLibrary.title(e.profile), 0.0), absf(lab.bike.speed))
		var target := d.point_at(near.x + 6.0) - here
		var steer := clampf(-wrapf(atan2(-target.x, -target.y) - lab.bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		lab.step_simulation(1.0 / 60.0, 0.6, steer, false, false)
		top = maxf(top, absf(lab.bike.speed))
		if lab.bike.airborne: air += 1.0 / 60.0
		ticks += 1
		if lab.crash.active(): break
	var ridden := d.nearest(Vector2(lab.bike.x, lab.bike.z)).x
	report.ride = {station = ridden, length = d.route_length(), seconds = ticks / 60.0, off_axis = worst_off, crashed = lab.crash.active(), top_speed = top, air_s = air, on_elements = on_element}
	check(ridden > d.route_length() - 4.0 and not lab.crash.active(), "one full automatic ride of the final trail: %.0f of %.0f m in %.1f s, off axis up to %.2f m, top %.1f m/s, in the air %.2f s, on elements %s, crash: %s (not a safety guarantee)" % [
		ridden, d.route_length(), ticks / 60.0, worst_off, top, air, on_element, lab.crash.active()])
	if "--capture" in OS.get_cmdline_user_args():
		lab.set_overview(true)
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT + "/overview.png")
		lab.set_overview(false)
		lab.reset_ride(maxf(0.0, d.elements[0].station - 14.0))
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT + "/element.png")
	check(FileAccess.get_sha256(Fixture.SITE) == file_hash, "site file unchanged")
	lab.queue_free()
	await process_frame
	report.failures = failures
	report.checks = checks
	FileAccess.open(OUT + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("trail_flow: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)
