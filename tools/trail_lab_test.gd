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
	var out := "res://tools/control/runs/trail_lab"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	report.mesh_error_m = max_error
	var lab := preload("res://scenes/trail_lab.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(lab)
	lab.set_physics_process(false)
	await check_lab_session(lab)
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
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out + "/overview.png")
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
	lab._unhandled_key_input(detail_key)
	check(not lab.diagnostics.visible, "F3 hides ride diagnostics")
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
