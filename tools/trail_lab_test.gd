extends SceneTree
## One isolated suite: authoring, real surfaces/mesh, protection and actual BikeController rides.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
var failures := 0
var report := {}
var checks := 0

class BrokenElement extends TrailElement:
	func displacement(_along: float, _across: float, _half_width: float) -> float:
		return NAN

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("trail_lab: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func ride(h: Heightfield, d: TrailDefinition, hz: int, braking := false) -> Dictionary:
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.x = d.points[0].x
	b.z = d.points[0].y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(0.0)
	b.mount(p)
	b.speed = 12.0
	var control := BikeController.new()
	var air := 0
	var peak_suspension := 0.0
	var distance := 0.0
	var max_turn := 0.0
	for tick in hz * (4 if braking else 10):
		var before := Vector2(b.x, b.z)
		var nearest := d.nearest(before)
		var target := d.point_at(nearest.x + 6.0)
		var delta := target - before
		var desired := atan2(-delta.x, -delta.y)
		var steer := 0.0 if braking else clampf(-wrapf(desired - b.heading, -PI, PI) * 2.0, -1.0, 1.0)
		max_turn = maxf(max_turn, absf(b.heading))
		control.ride(1.0 / hz, p, b, h.world, h, -1.0 if braking else 0.7, steer, false, false, false)
		distance += before.distance_to(Vector2(b.x, b.z))
		air += int(b.airborne)
		peak_suspension = maxf(peak_suspension, maxf(absf(b.squash_f), absf(b.squash_r)))
		if b.crashed or (braking and b.speed <= 0.05): break
	return {distance = distance, air_ticks = air, suspension = peak_suspension, crashed = b.crashed, speed = b.speed, max_turn = max_turn}

func run() -> void:
	if "--ui-only" in OS.get_cmdline_user_args():
		var lab := preload("res://scenes/trail_lab.tscn").instantiate()
		root.size = Vector2i(1280, 720)
		root.add_child(lab)
		lab.set_physics_process(false)
		await capture_lab(lab, "res://tools/control/runs/trail_lab")
		lab.queue_free()
		await process_frame
		quit(1 if failures else 0)
		return
	var routes := Fixture.definitions()
	var h := Fixture.build(routes, false)
	var w := h.world
	var assigned := var_to_bytes(w.trails)
	var surface_map := w.road_surface.duplicate()
	RoadSurface.run(w)
	check(assigned == var_to_bytes(w.trails) and surface_map == w.road_surface, "authored surfaces survive the normal generation surface stage")
	var before_routes := var_to_bytes(w.trails)
	var before_mask := w.path_mask.duplicate()
	check(not TrailBuilder.append_routes(w, routes).is_empty() and before_routes == var_to_bytes(w.trails) and before_mask == w.path_mask, "duplicate ids rejected without world mutation")
	var bad := routes[0].duplicate(true) as TrailDefinition
	bad.points[0] = Vector2(NAN, 0)
	check(not bad.validate().is_empty(), "non-finite authoring rejected")
	var baseline := h.ground_at(40, 142)
	TrailBuilder.bake_elements(h, routes)
	var baked := var_to_bytes(h.road_refinement.patches)
	check(not TrailBuilder.bake_elements(h, routes).is_empty() and baked == var_to_bytes(h.road_refinement.patches), "repeated bake returns an error without accumulating terrain")
	check(h.ground_at(40, 142) > baseline + 0.45, "roller is baked into actual wheel support")
	var arrays := TerrainBuilder.build_arrays(w, h)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var max_error := 0.0
	for i in range(0, indices.size(), 3):
		var center := (vertices[indices[i]] + vertices[indices[i + 1]] + vertices[indices[i + 2]]) / 3.0
		max_error = maxf(max_error, absf(h.ground_at(center.x, center.z) - center.y))
	check(max_error < 0.0001, "all mesh triangle centres agree with Heightfield: %.7fm" % max_error)
	for i in routes.size():
		var d := routes[i]
		var contact := RideSurface.sample(w, h, d.points[0].x, 200)
		check(contact.surface == d.surface and contact.weight > 0.9, "shared contact resolves " + d.title)
		var result := ride(h, d, 60)
		report[d.id] = result
		check(result.distance > 60.0 and is_finite(result.speed) and not result.crashed, "real bike traverses safely " + d.title)
		check(result.suspension > 0.002, "production suspension responds on " + d.title)
	var slow := ride(h, routes[0], 30)
	check(report.lab_2.max_turn > 0.1, "real steering follows the banked corner")
	var fast := ride(h, routes[0], 120)
	check(absf(slow.distance - fast.distance) < 0.3 and slow.crashed == fast.crashed, "30/120Hz roller ride agrees")
	check(fast.air_ticks > 0, "roller produces real airborne riding")
	var dirt := ride(h, routes[0], 60, true)
	var sand := ride(h, routes[3], 60, true)
	check(sand.distance > dirt.distance * 1.05, "shared sand traction lengthens braking distance")
	# Water cells must keep their original geometry, even when an authored feature crosses them.
	var protected := Fixture.build(routes, false)
	var cell := floori(142 / GameConfig.TILE) * w.W + floori(40 / GameConfig.TILE)
	protected.water_level[cell] = 100.0
	var wet_y := protected.ground_at(40, 142)
	TrailBuilder.bake_elements(protected, routes)
	check(absf(protected.ground_at(40, 142) - wet_y) < 0.0001, "water cell blocks earthwork")
	var structure_h := Fixture.build(routes, false)
	structure_h.structures.append({ax = 35.0, az = 142.0, bx = 45.0, bz = 142.0})
	var pinned_y := structure_h.ground_at(40, 142)
	TrailBuilder.bake_elements(structure_h, routes)
	check(absf(structure_h.ground_at(40, 142) - pinned_y) < 0.0001, "structure pin protects approach geometry")
	var crossing := TrailDefinition.new()
	crossing.id = "road_connection"
	crossing.kind = "road"
	crossing.width = 6.0
	crossing.surface = RoadSurface.PACKED
	crossing.points = PackedVector2Array([Vector2(20, 142), Vector2(70, 142)])
	var joined := routes.duplicate()
	joined.append(crossing)
	var crossing_h := Fixture.build(joined, false)
	var road_levels := PackedFloat32Array()
	for z in range(140, 145): road_levels.append(crossing_h.ground_at(40, z))
	TrailBuilder.bake_elements(crossing_h, joined)
	var road_error := 0.0
	for z in range(140, 145): road_error = maxf(road_error, absf(crossing_h.ground_at(40, z) - road_levels[z - 140]))
	check(road_error < 0.0001, "crossing road footprint stays fixed even when trail is nearer")
	var repeat := Fixture.build(routes)
	check(var_to_bytes(repeat.road_refinement.patches) == var_to_bytes(h.road_refinement.patches), "deterministic rebuild with no accumulated earthworks")
	check_rejected_bakes(routes)
	check_bike_park()
	check_composer()
	check_survey()
	var out := "res://tools/control/runs/trail_lab"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	report.mesh_error_m = max_error
	var lab := preload("res://scenes/trail_lab.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(lab)
	lab.set_physics_process(false)
	await check_lab_session(lab)
	# Готовые трассы: каждая строится в лаборатории (одна на экране), прежняя остаётся при отказе
	var built := PackedStringArray()
	var started := Time.get_ticks_usec()
	for i in TrailLabCatalog.LIST.size():
		var ok: bool = lab.select_preset(i)
		var length := 0.0
		for d: TrailDefinition in lab.routes: length += d.route_length()
		built.append("%d: %.0f м, элементов %d" % [i + 1, length, lab.routes[0].elements.size()])
		check(ok and lab.preset == i and not lab.routes.is_empty(), "preset %d «%s» builds in the lab" % [i + 1, TrailLabCatalog.LIST[i].title])
	print("Готовые трассы (%.1f с): %s" % [(Time.get_ticks_usec() - started) / 1e6, " · ".join(built)])
	lab.select_preset(0)
	if "--capture" in OS.get_cmdline_user_args():
		await capture_lab(lab, out)
	lab.queue_free()
	await process_frame
	report.failures = failures
	report.checks = checks
	var file := FileAccess.open(out + "/metrics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("trail_lab: ", failures, " failures / ", checks, " checks; ", report)
	quit(1 if failures else 0)

func capture_lab(lab: Node, out: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	lab.overview = true
	# A strict requirement, only for this shot: the overview shows the problem intervals of the finished surface.
	lab.set_grade_requirement(0.08)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out + "/overview.png")
	lab.set_grade_requirement(0.2)
	lab.overview = false
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out + "/rider.png")
	lab.editor.show()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(root.size))
	check(viewport_rect.encloses(lab.editor.get_global_rect()), "editor fits the 1280x720 viewport")
	check(viewport_rect.encloses(lab.preset_panel.get_global_rect()), "preset tiles fit the 1280x720 viewport")
	var visible_inputs := true
	for number: SpinBox in lab.editor.numbers.values():
		visible_inputs = visible_inputs and number.get_global_rect().end.x <= viewport_rect.end.x
	check(visible_inputs, "parameter fields are not clipped horizontally")
	root.get_texture().get_image().save_png(out + "/editor.png")

func check_rejected_bakes(routes: Array[TrailDefinition]) -> void:
	var fresh := Fixture.build(routes, false)
	var original := var_to_bytes(fresh.road_refinement.patches)
	var changed: Array[TrailDefinition] = []
	for d in routes: changed.append(d.duplicate(true) as TrailDefinition)
	changed[0].width += 1.0
	check(not TrailBuilder.bake_elements(fresh, changed).is_empty() and original == var_to_bytes(fresh.road_refinement.patches), "stale geometry cannot bake into old surface patches")
	changed[0].width = routes[0].width
	changed[0].elements[0] = BrokenElement.new()
	check(not TrailBuilder.bake_elements(fresh, changed).is_empty() and original == var_to_bytes(fresh.road_refinement.patches) and not fresh.road_refinement.trail_elements_baked, "invalid extension leaves all patches and bake lifecycle unchanged")
	check(TrailBuilder.bake_elements(fresh, routes).is_empty(), "valid bake succeeds after a rejected edit")
	var unprepared := Heightfield.new(fresh.world, false)
	check(not TrailBuilder.bake_elements(unprepared, routes).is_empty(), "missing refinement is a recoverable error")

## "Байк-парк": pump rollers, drop, table, northshore, off-camber turn. Relief by shape, deck by real support, all by a ride.
func check_bike_park() -> void:
	var park := Fixture.course(8)
	var d := park[0]
	var prepared := Fixture.prepare(park)
	check(d.validate().is_empty() and prepared.errors.is_empty(), "bike park course is valid and bakes")
	var h: Heightfield = prepared.heights
	TrailTechnical.build(h, park)
	check_deck_survey(h, d, park)
	var drop := d.elements[1]
	var lip := drop.station - drop.length * 0.5 + drop.length * TrailElement.DROP_LIP
	check(drop.displacement(lip - 0.2, 0.0, 2.5) > drop.height * 0.95 and absf(drop.displacement(lip + TrailElement.DROP_EDGE + 0.2, 0.0, 2.5)) < 0.01, "drop has a flat lip and lands on the natural ground")
	var shore := d.elements[3]
	var mid := d.point_at(shore.station)
	var side := Vector2(d.tangent_at(shore.station).y, -d.tangent_at(shore.station).x) * 2.0
	check(h.surface_at(mid.x, mid.y, 100.0) - h.ground_at(mid.x, mid.y) > shore.height - 0.1 and h.surface_at(mid.x + side.x, mid.y + side.y, 100.0) - h.ground_at(mid.x + side.x, mid.y + side.y) < 0.001, "northshore deck carries the bike above the ground and ends at its sides")
	var camber := d.elements[4]
	var apex := d.point_at(camber.station)
	var lateral := Vector2(d.tangent_at(camber.station).y, -d.tangent_at(camber.station).x) * camber.bank * 1.5
	check(h.ground_at(apex.x - lateral.x, apex.y - lateral.y) - h.ground_at(apex.x + lateral.x, apex.y + lateral.y) > 0.3, "off-camber lowers the outside of the turn")
	var bike := BikeRide.new()
	var player := PlayerState.new()
	var control := BikeController.new()
	bike.x = d.points[0].x
	bike.z = d.points[0].y
	bike.y = h.surface_at(bike.x, bike.z, -INF)
	bike.heading = d.heading_at(0.0)
	bike.mount(player)
	bike.speed = 6.9
	var station := 0.0
	var peak_above := 0.0
	for i in 60 * 60:
		var here := Vector2(bike.x, bike.z)
		station = d.nearest(here).x
		var delta := d.point_at(station + 5.0) - here
		var steer := clampf(-wrapf(atan2(-delta.x, -delta.y) - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		control.ride(1.0 / 60, player, bike, h.world, h, 0.6 if bike.speed < 6.9 else 0.0, steer, false, false, false)
		peak_above = maxf(peak_above, bike.y - h.ground_at(bike.x, bike.z))
		if bike.crashed or station > d.route_length() - 8.0: break
	check(not bike.crashed and station > d.route_length() - 8.0, "bike rides the whole bike park course")
	check(peak_above > shore.height * 0.8, "bike rode up onto the northshore deck")

func check_lab_session(lab: Node) -> void:
	var detail_key := InputEventKey.new()
	detail_key.keycode = KEY_F3
	detail_key.pressed = true
	lab._unhandled_key_input(detail_key)
	check(lab.diagnostics.visible, "F3 reveals ride diagnostics")
	check(lab.markers.visible and lab.survey_markers.visible, "F3 reveals track annotations")
	lab._unhandled_key_input(detail_key)
	check(not lab.diagnostics.visible, "F3 hides ride diagnostics")
	check(not lab.markers.visible and not lab.survey_markers.visible, "normal riding hides survey paint and element labels")
	lab.details_control.pressed.emit()
	check(lab.diagnostics.visible and lab.diagnostics_visible, "HUD button reveals diagnostics")
	lab.details_control.pressed.emit()
	lab.camera_control.pressed.emit()
	check(lab.overview and "сверху" in lab.camera_control.tooltip_text, "HUD camera button updates its current state")
	lab.camera_control.pressed.emit()
	lab.editor.show()
	var section: Dictionary = lab.editor.sections["Параметры элемента"]
	check(not section.content.visible, "editor groups start collapsed")
	section.button.button_pressed = true
	check(section.content.visible, "editor section expands on toggle")
	section.button.button_pressed = false
	lab.editor.close_requested.emit()
	check(not lab.editor.visible, "editor close button closes settings")
	lab.editor.show()
	lab.set_overview(true)
	lab.editor.camera_button.pressed.emit()
	check(not lab.overview and "обычная" in lab.editor.camera_button.text, "editor camera button switches to rider view")
	var camera_key := InputEventKey.new()
	camera_key.keycode = KEY_V
	camera_key.pressed = true
	lab._unhandled_key_input(camera_key)
	check(lab.overview and "сверху" in lab.editor.camera_button.text, "V switches camera while editor is open")
	lab.launch_element()
	check(not lab.overview and not lab.editor.visible, "launch returns to rider view")
	var source: TrailDefinition = Fixture.definitions()[0]
	var source_height := source.elements[0].height
	var before_y: float = lab.heights.ground_at(40, 142)
	var values := {width = 6.0, surface = RoadSurface.DIRT, profile = 0, station = 78.0, length = 10.0, height = 1.6, bank = 1.0}
	check(lab.apply_edit(values) and lab.heights.ground_at(40, 142) > before_y + 0.25, "lab applies edits to the real terrain without restart")
	check(source.elements[0].height == source_height, "live edits do not mutate the shared source resource")
	var current: Heightfield = lab.heights
	var current_mesh: Mesh = lab.terrain.mesh
	values.length = 1.0
	check(not lab.apply_edit(values) and lab.heights == current and lab.terrain.mesh == current_mesh, "invalid edit preserves the playable world and mesh")
	check(lab.reload_sources() and lab.routes[0].elements[0].height == source_height, "F5 restores file resources after live edits")
	var east := TrailDefinition.new()
	east.id = "east"
	east.points = PackedVector2Array([Vector2(40, 220), Vector2(220, 220)])
	var east_routes: Array[TrailDefinition] = [east]
	check(lab.rebuild(east_routes) and absf(lab.bike.heading + PI * 0.5) < 0.001, "custom route spawn follows its own heading")
	for i in 60: lab.step_simulation(1.0 / 60, 1.0, 0.0, false, false)
	check(lab.bike.x > 42.0 and absf(lab.bike.z - 220.0) < 0.01, "custom eastbound route really rides east")
	lab.controller.toggle_mount(lab.player, lab.bike, lab.heights.world, lab.heights)
	lab.controller.stamina.value = 0.25
	for i in 60: lab.step_simulation(1.0 / 60, 0.0, 0.0, false, false)
	check(not lab.bike.riding and lab.controller.stamina.value > 0.3, "walking restores stamina as in GameWorld")
	lab.reset_ride()
	lab.bike.land_impact = 7.0
	lab.bike.bottom_out = 2.0
	lab.step_simulation(1.0 / 60, 0.0, 0.0, false, false)
	check(lab.bike.land_impact == 0.0 and lab.bike.bottom_out == 0.0 and lab.last_land_impact == 7.0, "landing events are consumed once and retained only as telemetry")
	check_lab_survey(lab)
	lab.reload_sources()
	lab.reset_ride(30.0, 9.0)
	for i in 420: lab.step_simulation(1.0 / 60, 0.7, 0.0, false, false)
	check(lab.metrics.distance > 5.0 and lab.metrics.top_speed > 5.0 and lab.metrics.element >= 0 and lab.metrics.time > 6.5, "ride metrics collect speed, distance and the crossed element")
	check("Элемент" in lab.metrics.report(lab.routes[lab.lane]), "metrics report is readable")
	var cam_to: Vector4 = lab._cam_to
	lab.step_simulation(1.0 / 60, 0.7, 0.0, false, false)
	check(lab._cam_from == cam_to, "camera interpolates between consecutive physics ticks")
	lab.reload_sources()
	lab.reset_ride(78.0)
	lab.bike.y += 10.0
	lab.bike.airborne = true
	lab.bike.vy = -2.0
	var phases := {}
	print("trail_lab: checking actual fall / ragdoll / recovery on the authored roller")
	for i in 600:
		await physics_frame
		lab.step_simulation(1.0 / 60, 0.0, 0.0, false, false)
		phases[lab.crash.phase] = true
		if phases.has(BikeCrash.Phase.RAGDOLL) and not lab.crash.active(): break
	check(phases.has(BikeCrash.Phase.BALANCE) and phases.has(BikeCrash.Phase.RAGDOLL) and phases.has(BikeCrash.Phase.RECOVER) and not lab.crash.active() and not lab.bike.riding, "real fall completes ragdoll and returns to walking")
	lab.reset_ride()
	await process_frame
	check(not lab.crash.active() and lab.bike.riding and lab.view.rider.is_inside_tree(), "reset after a fall restores the real rider and bike")
	await check_recorder(lab)

## Запись сессии: до «Сохранить» в проект ничего не попадает; после — csv, события, заголовок и сводка; пишется во временную папку
func check_recorder(lab: Node) -> void:
	var folder := "res://tools/control/runs/ride_log_test"
	var absolute := ProjectSettings.globalize_path(folder)
	wipe(absolute)
	lab.recorder.enabled = true
	lab.recorder.root = folder + "/project"
	lab.recorder.temp_root = folder + "/temp"
	lab.reset_ride(30.0, 0.0)
	for i in 60:
		lab.bike.speed = 0.0 # на уклоне велосипед сам покатился бы: ждём стоя
		lab.step_simulation(1.0 / 60, 0.0, 0.0, false, false)
	check(not lab.recorder.has_data() and not FileAccess.file_exists(folder + "/temp/unsaved.csv"), "recorder writes nothing while nothing has happened")
	# первая поездка: газ и руль, падение с высоты; вторая (R): ещё немного езды
	for i in 90: lab.step_simulation(1.0 / 60, 1.0, 0.4 if i > 30 else 0.0, false, false)
	check(lab.recorder.has_data() and FileAccess.file_exists(folder + "/temp/unsaved.csv"), "recorder starts on the first activity, into the temporary files")
	lab.bike.y += 12.0
	lab.bike.airborne = true
	lab.bike.vy = -4.0
	for i in 600:
		await physics_frame
		lab.step_simulation(1.0 / 60, 0.0, 0.0, false, false)
		if lab.crash.active(): break
	for i in 30: lab.step_simulation(1.0 / 60, 0.0, 0.0, false, false)
	lab.reset_ride(60.0, 4.0)
	for i in 60: lab.step_simulation(1.0 / 60, 1.0, -0.3, false, false)
	check(not DirAccess.dir_exists_absolute(absolute + "/project"), "nothing reaches the project before «Save»")
	var base: String = lab.recorder.save(lab)
	check(base != "" and FileAccess.file_exists(base + ".csv") and FileAccess.file_exists(base + ".events.txt") and FileAccess.file_exists(base + ".header.json") and FileAccess.file_exists(base + ".summary.txt"), "«Save» writes csv, events, header and summary into the project")
	check(not lab.recorder.has_data() and lab.recorder.save(lab) == "", "after «Save» the session is empty: a second press has nothing to save")
	var csv := FileAccess.get_file_as_string(base + ".csv").split("\n", false)
	var head := csv[0].split(",")
	var header: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(base + ".header.json"))
	check(csv.size() > 150 and head.size() > 100 and csv[1].split(",").size() == head.size() and csv[csv.size() - 1].split(",").size() == head.size(), "every csv row has one value per column (%d rows, %d columns)" % [csv.size() - 1, head.size()])
	check(header.columns.size() == head.size() and header.bike_constants.has("SUB_HZ") and header.route.elements.size() > 0 and header.code.has("commit") and header.rides.size() == 2, "header lists the columns, physics constants, route elements, code version and both rides")
	var events := FileAccess.get_file_as_string(base + ".events.txt")
	check("ПАДЕНИЕ" in events and "отрыв" in events and "НОВАЯ ПОЕЗДКА" in events and "СОХРАНЕНО" in events, "events name the take-off, the fall, the new ride and the save")
	var summary := FileAccess.get_file_as_string(base + ".summary.txt")
	check("Ввод (время удержания" in summary and "падений 1" in summary and "поездка 2" in summary and "F3 на конец заезда" in summary, "summary states the input, the falls, the rides and the F3 report")
	# 31.10: разбор по участкам — ожидания в заголовке, итоги в сводке, колонки участка и линии в CSV
	check(header.has("features") and (header.features as Array).size() > 0 and (header.features[0] as Dictionary).has("from") and "Участки трассы" in summary,
		"header lists the expected features (%d), summary has the feature table" % (header.features as Array).size() if header.has("features") else 0)
	check(head.has("feature") and head.has("line_off") and head.has("route_r") and head.has("path_r"), "csv carries the feature, line offset and both radii")
	var ride_col := head.find("ride")
	var station_col := head.find("station")
	var row := csv[100].split(",")
	check(ride_col >= 0 and int(csv[csv.size() - 1].split(",")[ride_col]) == 2 and float(row[station_col]) > 29.0, "rows carry the ride number and the station along the route")
	lab.step_simulation(1.0 / 60, 1.0, 0.0, false, false)
	check(lab.recorder.has_data(), "a new session starts right after «Save»")
	lab.recorder.close()
	lab.recorder.enabled = DisplayServer.get_name() != "headless"
	lab.recorder.root = lab.Recorder.ROOT
	lab.recorder.temp_root = lab.Recorder.TEMP
	if "--keep-ride-log" not in OS.get_cmdline_user_args(): wipe(absolute) # образец записи: -- --keep-ride-log

## Удалить папку со всем содержимым (временные записи теста)
func wipe(absolute: String) -> void:
	if not DirAccess.dir_exists_absolute(absolute): return
	# со скрытыми (.gdignore записи): иначе папка остаётся, и следующий запуск видит «записано до сохранения»
	var dir := DirAccess.open(absolute)
	dir.include_hidden = true
	for name in dir.get_files(): DirAccess.remove_absolute(absolute.path_join(name))
	for name in DirAccess.get_directories_at(absolute): wipe(absolute.path_join(name))
	DirAccess.remove_absolute(absolute)

## TrailComposer: every profile yields a valid, deterministic, sectioned route; world-relief grounds prepare.
func check_composer() -> void:
	var start := Time.get_ticks_usec()
	var counts := {}
	for style: String in TrailComposer.PROFILES:
		var d: TrailDefinition = Fixture.course(9, "mountain", style)[0]
		var again: TrailDefinition = Fixture.course(9, "mountain", style)[0]
		counts[style] = [d.elements.size(), d.sections.size()]
		check(d.validate().is_empty() and d.elements.size() >= 3 and d.sections.size() >= 3 and again.elements.size() == d.elements.size() and again.elements[1].station == d.elements[1].station, "profile %s composes a valid deterministic route (%d elements, %d sections) %s" % [style, d.elements.size(), d.sections.size(), ", ".join(d.validate())])
	report.composer_ms = (Time.get_ticks_usec() - start) / 1000.0 / 12.0
	report.composer_counts = counts
	for ground: String in ["hills", "mountain"]:
		var cells := Fixture.relief(ground)
		var top := 0.0
		for v in cells: top = maxf(top, v)
		# The leisure profile places no objects: the ride tests the ground and the earthwork, not the line choice.
		var course := Fixture.course(9, "mountain", "leisure", ground)
		var prepared := Fixture.prepare(course, true, ground)
		var fall := Fixture.ground(course[0].points[0], ground) - Fixture.ground(course[0].points[-1], ground)
		check(prepared.errors.is_empty() and fall > (Fixture.GROUND_DROP[ground] as Vector2).x * 0.5, "%s ground from world relief (range %.1f m, route falls %.1f m) prepares a composed route %s" % [ground, top, fall, ", ".join(prepared.errors)])
		if not prepared.errors.is_empty(): continue
		var h: Heightfield = prepared.heights
		var shaping: Dictionary = h.road_refinement.trail_shaping.get(course[0].id, {})
		var end := ride_route(h, course[0], 15.0 / 3.6)
		report["relief_" + ground] = {range = snappedf(top, 0.1), fall = snappedf(fall, 0.1), grade_natural = snappedf(shaping.get("grade_natural", 0.0), 0.01), grade_designed = snappedf(shaping.get("grade_designed", 0.0), 0.01), ridden_to = snappedf(end, 0.1)}
		check(end > course[0].route_length() - 8.0, "bike rides the whole composed route on %s ground (to %.0f of %.0f m)" % [ground, end, course[0].route_length()])

## Lab diagnostics: stage times of a real rebuild, the surface report, a new requirement without a rebuild,
## the same terrain as a build without the lab, and a composed course that times its composition.
func check_lab_survey(lab: Node) -> void:
	check(lab.reload_sources(), "lab rebuilds its own courses")
	var t: Dictionary = lab.build_timings
	var stages := ["setup_ms", "surface_ms", "earthworks_ms", "technical_ms", "survey_ms", "mesh_ms", "apply_ms", "total_ms"]
	var timed := true
	for key: String in stages: timed = timed and t.get(key, -1.0) >= 0.0
	check(timed and t.compose_ms < 0.0 and "композиция —" in lab._build_report() and t.total_ms >= t.surface_ms + t.mesh_ms, "build stages are timed, composition shown as not run: " + lab._build_report().replace("\n", " "))
	report.build_timings = t.duplicate()
	var text: String = lab._survey_report()
	check(lab.surveys.size() == lab.routes.size() and "Готовая поверхность" in text and "Не проверяется" in text, "lab shows the finished surface of every course")
	var current: Heightfield = lab.heights
	lab.set_grade_requirement(0.01)
	var survey: TrailSurvey = lab.surveys[lab.routes[lab.lane].id]
	check(lab.heights == current and survey.level() == "exceeded" and lab.survey_markers.get_child_count() > 0 and "превышений" in lab._survey_report(), "a stricter requirement marks intervals in the overview without rebuilding")
	lab.set_grade_requirement(0.2)
	check(var_to_bytes(lab.heights.road_refinement.patches) == var_to_bytes(Fixture.build(Fixture.definitions()).road_refinement.patches), "the lab with its diagnostics builds the same terrain as the plain build")
	lab.editor.course_selected.emit(9, "mountain", "mixed", "flat")
	check(lab.build_timings.compose_ms >= 0.0 and lab.surveys.has(lab.routes[0].id), "composed course times its composition (%.1f ms) and is surveyed" % lab.build_timings.compose_ms)
	report.build_timings_route = lab.build_timings.duplicate()
	report.route_survey = lab._survey_report()

## TrailSurvey on a straight line over the lab's course ground (grade up to about 16 % along z) and the same line
## with a roller: requirement, intervals, and the finished profile against the design profile of TrailShaping.
func check_survey() -> void:
	var line := TrailDefinition.new()
	line.id = "course_line" # "course_" ids get the lab's bumpy course ground
	line.width = 4.0
	line.surface = RoadSurface.DIRT
	line.points = PackedVector2Array([Vector2(113, 230), Vector2(113, 30)])
	var lines: Array[TrailDefinition] = [line]
	var h: Heightfield = Fixture.prepare(lines).heights
	var gentle := TrailSurvey.measure(h, line, 0.3)
	var steep := TrailSurvey.measure(h, line, 0.08)
	check(gentle.level() == "within" and gentle.peak_grade > 0.05 and gentle.unmeasured.is_empty() and gentle.errors.is_empty(), "simple route stays within its grade requirement (peak %.0f%%)" % (gentle.peak_grade * 100.0))
	check(steep.level() == "exceeded" and steep.exceeded.size() >= 2 and steep.exceeded.size() * 20 < steep.stations.size(), "steeper than required: %d distance intervals, not a warning per sample" % steep.exceeded.size())
	var bare := TrailSurvey.measure(h, line)
	check(bare.level() == "no_requirement" and bare.exceeded.is_empty() and bare.peak_grade == gentle.peak_grade, "without a requirement the grade is only reported")
	var shaped := line.duplicate(true) as TrailDefinition
	shaped.earthwork = 1.0
	shaped.elements.append(TrailElementLibrary.make(TrailElement.Profile.ROLLER, 100.0, 10.0, 1.5))
	var shaped_routes: Array[TrailDefinition] = [shaped]
	var built: Heightfield = Fixture.prepare(shaped_routes).heights
	var design: Dictionary = built.road_refinement.trail_shaping.get(shaped.id, {})
	var finished := TrailSurvey.measure(built, shaped, design.get("grade_designed", 0.0) + 0.03)
	var linked := false
	for run: Dictionary in finished.exceeded: linked = linked or 0 in (run.elements as Array)
	check(not design.is_empty() and finished.peak_grade > design.grade_designed + 0.1 and linked and finished.peak_grade_track < finished.peak_grade, "finished profile with a roller differs from the design profile (%.0f%% vs designed %.0f%%) and the excess is tied to the element" % [finished.peak_grade * 100.0, design.get("grade_designed", 0.0) * 100.0])
	# A short roller (4 m) is a kink the 4 m grade averages out; the local grade keeps it.
	var kinked := line.duplicate(true) as TrailDefinition
	kinked.elements.append(TrailElementLibrary.make(TrailElement.Profile.ROLLER, 100.0, 4.0, 0.5))
	var kinked_routes: Array[TrailDefinition] = [kinked]
	var kinked_h: Heightfield = Fixture.prepare(kinked_routes).heights
	var kink := TrailSurvey.measure(kinked_h, kinked)
	# Rise of both grades over the plain line at the same place: the ground's own slope is taken out.
	var rise := Vector2() # x — local, y — 4 m
	var plain_base := 0.0
	for j in kink.stations.size():
		if absf(kink.stations[j] - 100.0) > 2.0: continue
		rise.x = maxf(rise.x, absf(kink.grade_local[j]) - absf(gentle.grade_local[j]))
		rise.y = maxf(rise.y, absf(kink.grade[j]) - absf(gentle.grade[j]))
		plain_base = maxf(plain_base, absf(gentle.grade[j]))
	# A requirement the local kink breaks, but its 4 m average does not.
	var judged := TrailSurvey.measure(kinked_h, kinked, plain_base + rise.x * 0.75)
	var flagged := false
	for run: Dictionary in judged.exceeded: flagged = flagged or 0 in (run.elements as Array)
	check(rise.x > 0.1 and rise.x > rise.y * 1.5 and not flagged, "short kink adds %.0f%% to the local grade but %.0f%% to the 4 m grade; a 4 m requirement of %.0f%% does not flag it" % [rise.x * 100.0, rise.y * 100.0, (plain_base + rise.x * 0.75) * 100.0])
	check_ring_seam()
	report.survey = {line_peak = snappedf(gentle.peak_grade, 0.001), line_intervals_at_8 = steep.exceeded.size(), roller_peak = snappedf(finished.peak_grade, 0.001), roller_track_peak = snappedf(finished.peak_grade_track, 0.001), designed = snappedf(design.get("grade_designed", 0.0), 0.001), survey_ms = snappedf(finished.survey_ms, 0.01)}

## The ring course measured from its own start and from a start moved by 37 points: on the same heightfield the
## profile is the same at the same places, the 4 m window wraps through the seam, nothing at the seam is unmeasured.
func check_ring_seam() -> void:
	var ring: Array[TrailDefinition] = Fixture.course(3)
	var d := ring[0]
	var h: Heightfield = Fixture.prepare(ring).heights
	var moved := d.duplicate(true) as TrailDefinition
	var pts := PackedVector2Array()
	for i in d.points.size() - 1: pts.append(d.points[(i + 37) % (d.points.size() - 1)])
	pts.append(pts[0])
	moved.points = pts
	var a := TrailSurvey.measure(h, d, 0.1)
	var b := TrailSurvey.measure(h, moved, 0.1)
	var shift := d.route_length() - moved.nearest(d.points[0]).x # station in `a` of the moved start
	var worst := 0.0
	for j in b.stations.size():
		var at := fposmod(b.stations[j] + shift, a.length)
		var i := clampi(roundi(at / (a.length / (a.stations.size() - 1))), 0, a.stations.size() - 1)
		worst = maxf(worst, absf(a.grade[i] - b.grade[j]))
	check(a.closed and a.unmeasured.is_empty() and b.unmeasured.is_empty() and is_finite(a.grade[0]) and absf(a.grade[0] - a.grade[-1]) < 0.001 and worst < 0.02 and absf(a.peak_grade - b.peak_grade) < 0.01, "ring profile is the same from a moved start (worst %.3f, %d / %d intervals), the 4 m window wraps the seam" % [worst, a.exceeded.size(), b.exceeded.size()])

## Northshore: the survey keeps to the deck (continuous support, as the bike), marks its abrupt end as unmeasured
## and changes nothing it reads.
func check_deck_survey(h: Heightfield, d: TrailDefinition, park: Array[TrailDefinition]) -> void:
	var before := [var_to_bytes(h.road_refinement.patches), var_to_bytes(h.hv), var_to_bytes(h.structures)]
	var survey := TrailSurvey.measure(h, d)
	var again := TrailSurvey.measure(h, d)
	var shore := d.elements[3]
	var deck_samples := 0
	var on_deck := true
	for j in survey.stations.size():
		if absf(survey.stations[j] - shore.station) > 2.0: continue
		var p := d.point_at(survey.stations[j])
		deck_samples += 1
		on_deck = on_deck and survey.layers[j] == TrailSurvey.Layer.DECK and absf(survey.support[j] - h.surface_at(p.x, p.y, 100.0)) < 0.001 and survey.support[j] - h.ground_at(p.x, p.y) > shore.height - 0.1
	var edge := false
	for run: Dictionary in survey.unmeasured: edge = edge or (run.reason == "кромка настила" and 3 in (run.elements as Array))
	check(deck_samples > 4 and on_deck and edge and survey.deck_length > shore.length * 0.8 and survey.errors.is_empty(), "northshore measured on its deck (%.0f m), its end marked unmeasured, not as a grade" % survey.deck_length)
	# The deck end leaves a gap in the profile: the check is incomplete, with or without excesses found elsewhere.
	var lenient := TrailSurvey.measure(h, d, 5.0)
	check(lenient.level() == "incomplete" and not lenient.complete() and lenient.exceeded.is_empty() and "НЕПОЛНАЯ" in lenient.summary(), "incomplete profile without excesses is not reported as within the requirement")
	var strict := TrailSurvey.measure(h, d, 0.05)
	check(strict.level() == "exceeded" and not strict.complete() and not strict.exceeded.is_empty() and "НЕПОЛНАЯ" in strict.summary(), "incomplete profile keeps its excesses (%d) and still says it is incomplete" % strict.exceeded.size())
	var fresh := Fixture.prepare(park)
	TrailTechnical.build(fresh.heights, park)
	check(before == [var_to_bytes(h.road_refinement.patches), var_to_bytes(h.hv), var_to_bytes(h.structures)] and survey.support == again.support and var_to_bytes((fresh.heights as Heightfield).road_refinement.patches) == before[0], "survey changes neither the terrain, the decks nor the build result")

## Centre-line ride holding `target` m/s (pedal below, brake above 1.1×); returns the last station reached.
func ride_route(h: Heightfield, d: TrailDefinition, target: float) -> float:
	var b := BikeRide.new()
	var p := PlayerState.new()
	var control := BikeController.new()
	b.x = d.points[0].x
	b.z = d.points[0].y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(0.0)
	b.mount(p)
	b.speed = target
	var station := 0.0
	for i in 60 * 150:
		station = d.nearest(Vector2(b.x, b.z)).x
		if b.crashed or station > d.route_length() - 8.0: break
		var ahead := d.point_at(station + maxf(4.0, b.speed * 0.55)) - Vector2(b.x, b.z)
		var steer := clampf(-wrapf(atan2(-ahead.x, -ahead.y) - b.heading, -PI, PI) * 2.0, -1.0, 1.0)
		control.ride(1.0 / 60, p, b, h.world, h, 1.0 if b.speed < target else (-0.6 if b.speed > target * 1.1 else 0.0), steer, false, false, false)
	return station if not b.crashed else -station
