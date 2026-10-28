extends SceneTree
const Fixture = preload("res://tools/trail_lab_fixture.gd")
var failures := 0
var checks := 0
func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	print("formation: ", "PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func run() -> void:
	if "--capture" in OS.get_cmdline_user_args():
		await capture()
		quit(1 if failures else 0)
		return
	for shape in range(1, 6):
		for kind in ["road", "trail", "mountain"]:
			var routes := Fixture.course(shape, kind)
			var d := routes[0]
			check(d.validate().is_empty(), "%s %s valid" % [d.title, kind])
			var prepared := Fixture.prepare(routes, false)
			check(prepared.errors.is_empty(), "course prepares")
			if not prepared.errors.is_empty(): continue
			var h: Heightfield = prepared.heights
			var base := h.hv.duplicate()
			var water := h.water_level.duplicate()
			var before := PackedFloat32Array()
			for i in 40:
				var p := d.point_at(d.route_length() * (i + 0.5) / 40.0)
				before.append(h.ground_at(p.x, p.y))
			var started := Time.get_ticks_msec()
			check(TrailBuilder.bake_elements(h, routes).is_empty(), "formation bakes")
			print("formation: bake_ms=", Time.get_ticks_msec() - started)
			var change := 0.0
			for i in 40:
				var p := d.point_at(d.route_length() * (i + 0.5) / 40.0)
				change = maxf(change, absf(h.ground_at(p.x, p.y) - before[i]))
			check(change > 0.005 and change <= 2.001, "bounded real cut/fill %.3f" % change)
			var stat: Dictionary = h.road_refinement.trail_shaping.get(d.id, {})
			var limit := d.shape().grade_limit
			check(not stat.is_empty() and stat.cut_m3 + stat.fill_m3 > 0.0, "shaping reports cut/fill volumes")
			check(stat.grade_designed <= maxf(limit * 1.2, stat.grade_natural * 0.9) and stat.max_cut <= d.shape().max_cut + 0.001 and stat.max_fill <= d.shape().max_fill + 0.001, "%s grade %.0f%%→%.0f%% within limit" % [kind, stat.grade_natural * 100, stat.grade_designed * 100])
			check(h.hv == base and h.water_level == water, "coarse geography and water unchanged")
			check(h.road_refinement.patches.size() < (h.world.W - 1) * (h.world.H - 1) / 2, "sparse local detail")
			var arrays := TerrainBuilder.build_arrays(h.world, h)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var ids: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var error := 0.0
			for i in range(0, ids.size(), 3):
				var center := (v[ids[i]] + v[ids[i+1]] + v[ids[i+2]]) / 3.0
				error = maxf(error, absf(center.y - h.ground_at(center.x, center.z)))
			check(error < 0.0001, "mesh matches wheel and ragdoll support")
			if kind == "mountain":
				check(ride_course(h, d), "production bike rides curved course")
			if d.closed:
				check(d.point_at(-0.1).distance_to(d.point_at(d.route_length() - 0.1)) < 0.001, "closed station wraps")
				check(d.tangent_at(0).dot(d.tangent_at(d.route_length())) > 0.999, "closed frame continuous")
	# A signed offset makes both excavation and embankment, with strength respecting route kinds.
	var magnitudes := {}
	for kind in ["road", "trail", "mountain"]:
		var d := TrailDefinition.new()
		d.kind = kind
		d.width = 6
		d.earthwork = 1
		d.points = PackedVector2Array([Vector2(40, 220), Vector2(40, 40)])
		for offset in [-1.0, 1.0]:
			d.elevation_offset = offset
			var routes: Array[TrailDefinition] = [d]
			var h := Fixture.build(routes, false)
			var before := h.ground_at(40, 120)
			TrailBuilder.bake_elements(h, routes)
			var delta := h.ground_at(40, 120) - before
			check(delta * offset > 0.01, "signed earthwork %s %.1f" % [kind, offset])
			magnitudes[kind] = absf(delta)
	check(magnitudes.road > magnitudes.mountain and magnitudes.mountain > magnitudes.trail, "road / bike / natural intervention hierarchy")
	# Banking must raise the outside, regardless of clockwise/counterclockwise direction.
	for reverse in [false, true]:
		var routes := Fixture.course(3)
		var d := routes[0]
		if reverse: d.points.reverse()
		var h := Fixture.build(routes, false)
		var station := d.route_length() * 0.27
		var center := d.point_at(station)
		var tangent := d.tangent_at(station)
		var left := Vector2(-tangent.y, tangent.x)
		var outside := center - left * signf(d.curvature_at(station)) * 1.5
		var inside := center + left * signf(d.curvature_at(station)) * 1.5
		var cross_before := h.ground_at(outside.x, outside.y) - h.ground_at(inside.x, inside.y)
		TrailBuilder.bake_elements(h, routes)
		var cross_after := h.ground_at(outside.x, outside.y) - h.ground_at(inside.x, inside.y)
		check(cross_after > cross_before + 0.05, "bank raises outside for both route directions")
	# Element library: every profile is finite, bounded, zero outside its footprint; composer is deterministic and valid.
	for profile in TrailElement.Profile.values():
		var e := TrailElementLibrary.make(profile, 50.0, 18.0, 0.6, 1.0, 3, 0.35)
		var peak := 0.0
		var finite := true
		for i in range(-10, 111):
			for k in range(-6, 7):
				var v := e.displacement(41.0 + i * 0.2, k * 0.5, 3.0)
				finite = finite and is_finite(v)
				peak = maxf(peak, absf(v))
		check(finite and peak > 0.12 and peak <= 0.61 and e.displacement(40.9, 0.0, 3.0) == 0.0 and e.displacement(59.1, 0.0, 3.0) == 0.0, "library profile %s bounded and compact" % TrailElementLibrary.title(profile))
	var flow := Fixture.course(6)[0]
	var again := TrailElementLibrary.compose(flow, 4242, 0.5)
	check(flow.validate().is_empty() and flow.elements.size() >= 5 and again.size() == flow.elements.size() and again[2].station == flow.elements[2].station, "composer yields a valid deterministic flow line (%d elements)" % flow.elements.size())
	var flow_world := Fixture.prepare([flow])
	check(flow_world.errors.is_empty(), "flow line prepares and bakes")
	if flow_world.errors.is_empty():
		check(ride_course(flow_world.heights, flow), "bike rides the generated flow line")
		# Dip and roller must load the suspension; surface reads must stay finite.
		var h: Heightfield = flow_world.heights
		var bike := BikeRide.new()
		var player := PlayerState.new()
		var control := BikeController.new()
		var start := flow.elements[0]
		var at := flow.point_at(maxf(0.0, start.station - start.length * 0.5 - 12.0))
		bike.x = at.x
		bike.z = at.y
		bike.y = h.surface_at(bike.x, bike.z, -INF)
		bike.heading = flow.heading_at(0.0)
		bike.mount(player)
		bike.speed = 10.0
		var peak_g := 0.0
		var finite_state := true
		for i in 420:
			var before := Vector2(bike.x, bike.z)
			var target := flow.point_at(flow.nearest(before).x + 5.0) - before
			var steer := clampf(-wrapf(atan2(-target.x, -target.y) - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
			control.ride(1.0 / 60, player, bike, h.world, h, 0.5, steer, false, false, false)
			peak_g = maxf(peak_g, absf(bike.vertical_g))
			finite_state = finite_state and is_finite(bike.y) and is_finite(bike.squash_f) and is_finite(bike.bank_slope)
			if bike.crashed: break
		check(finite_state and peak_g > 0.05, "profile load reaches the suspension model (peak %.2f g)" % peak_g)
	print("formation: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)

func capture() -> void:
	root.size = Vector2i(1280, 720)
	var lab := preload("res://scenes/trail_lab.tscn").instantiate()
	root.add_child(lab)
	lab.set_physics_process(false)
	var out := "res://tools/control/runs/trail_formation"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	for shape in [2, 3, 4, 5]:
		check(lab.rebuild(Fixture.course(shape)), "UI builds curved course")
		lab.overview = true
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out + "/course_%d.png" % shape)
	lab.editor.show()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(lab.editor.get_global_rect()), "course editor fits viewport")
	root.get_texture().get_image().save_png(out + "/editor.png")
	lab.shutdown()
	lab.queue_free()
	await process_frame

func ride_course(h: Heightfield, d: TrailDefinition) -> bool:
	var player := PlayerState.new()
	var bike := BikeRide.new()
	var control := BikeController.new()
	bike.x = d.points[0].x
	bike.z = d.points[0].y
	bike.y = h.surface_at(bike.x, bike.z, -INF)
	bike.heading = d.heading_at(0.0)
	bike.mount(player)
	bike.speed = 5.0
	var distance := 0.0
	for i in 720:
		var before := Vector2(bike.x, bike.z)
		var local := d.nearest(before)
		var target := d.point_at(local.x + 5.0) - before
		var heading := atan2(-target.x, -target.y)
		var steer := clampf(-wrapf(heading - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		control.ride(1.0 / 60, player, bike, h.world, h, 0.6 if bike.speed < 5 else 0.0, steer, false, false, false)
		distance += before.distance_to(Vector2(bike.x, bike.z))
		if bike.crashed or not is_finite(bike.y): return false
	return distance > 35 and d.nearest(Vector2(bike.x, bike.z)).z < d.width
