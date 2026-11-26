extends SceneTree
## Isolated final-surface fixture. Rides use the game's bike controller, heightfield and tread.
const Snapshot := preload("res://scripts/game/surface_snapshot.gd")
const TILE := GameConfig.TILE
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 65)
	_run.call_deferred()


func _run() -> void:
	if "--saved" in OS.get_cmdline_user_args():
		_saved_worlds()
		quit(1 if failures else 0)
		return
	for seed: int in [44, 79, 102]:
		var axis := Vector2.RIGHT.rotated(0.48 if seed == 79 else 0.0)
		var w := _world(seed, axis)
		var original := w.trails.duplicate(true)
		var h := Heightfield.new(w)
		var r := h.road_refinement
		_check(not r.gaps.is_empty(), "Dry forest trail has no gap, seed %d" % seed)
		if r.gaps.is_empty():
			continue
		_check(w.trails == original, "Final-surface work changed the road graph")
		var again := Heightfield.new(w)
		_check(r.gaps == again.road_refinement.gaps and r.patches == again.road_refinement.patches, "Same seed changed the gaps")
		var saved := Snapshot.capture(h, "final")
		var restored := Snapshot.restore(w, bytes_to_var(var_to_bytes(saved)), "final")
		_check(restored != null and restored.road_refinement.gaps == r.gaps and restored.road_refinement.patches == r.patches,
			"Surface snapshot did not preserve heights and clearance")
		if restored != null:
			restored.native_ride = true
		var base := Heightfield.new(w, false)
		RoadBed.refine(base)
		base.road_refinement = RoadRefinement.build(base)
		for gap: Dictionary in r.gaps:
			var center: Vector2 = gap.area.get_center()
			var floor_delta := _height(h, center) - _height(base, center)
			_check(floor_delta < -0.45, "Gap floor has no real cut (%0.2f m)" % floor_delta)
			var floor_contact := h.path_contact(center.x, center.y)
			_check(floor_contact.surface == RoadSurface.NONE and floor_contact.weight < 0.13, "Old tread survives in the gap")
			var bypass: Array = gap.bypass.pts
			var p: Dictionary = bypass[bypass.size() / 2]
			var middle := Vector2(p.x, p.y) * TILE
			var detour := h.path_contact(middle.x, middle.y)
			_check(detour.surface == RoadSurface.FOREST and detour.weight > 0.50 and absf(_height(h, middle) - _height(base, middle)) < 0.2,
				"Detour must carry forest tread around the dry cut")
			_check(_height(h, center - 2.0 * axis) - _height(h, center) > 0.85
				and _height(h, center + 2.0 * axis) - _height(h, center) > 0.85, "Gap needs two raised banks")
			_check(_height(h, center + axis * 18.0) == _height(base, center + axis * 18.0), "Changed the far approach")
			for sign: float in [-1.0, 1.0]:
				_check(_ride_bypass(h, bypass, sign), "Bypass failed in direction %d" % sign)
				_check(_walk_through(h, center, axis * sign), "Could not descend into and walk out of the gap")
				var successes := 0
				for speed in [9.0, 11.0, 12.0, 13.0, 14.0]:
					if _ride(restored if restored != null else h, center, axis * sign, speed):
						successes += 1
				_check(successes >= 2, "Seed %d direction %d: fewer than two reliable jump speeds" % [seed, sign])
		_mesh_matches(h)
	var wet := _world(44, Vector2.RIGHT)
	wet.dist_water.fill(0.0)
	_check(Heightfield.new(wet).road_refinement.gaps.is_empty(), "A wet corridor accepted a gap")
	var junction := _world(44, Vector2.RIGHT, true)
	var crossed := Heightfield.new(junction)
	for gap: Dictionary in crossed.road_refinement.gaps:
		_check(not gap.area.grow(4.0).has_point(Vector2(130, 130)), "Gap reached a junction")
	print("Road gap checks: %d failures" % failures)
	quit(1 if failures else 0)


func _saved_worlds() -> void:
	for seed_text: String in ["Север-1234", "Туман-4821", "Ущелье"]:
		var file := FileAccess.open("res://tools/control/runs/road_relief/%s.fixture.bin" % seed_text, FileAccess.READ)
		_check(file != null, "Missing saved road fixture for %s" % seed_text)
		if file == null:
			continue
		var saved: Dictionary = file.get_var()
		var w := WorldCache.new()._restore(saved.world, true)
		var h := Snapshot.restore(w, saved.base, "base") if w != null else null
		_check(h != null, "Invalid saved road fixture for %s" % seed_text)
		if h == null:
			continue
		w.trail_plan = {state = "none"}
		w.available_rect = Rect2i()
		h.finish_paths()
		h.native_ride = true
		var gaps := h.road_refinement.gaps
		print("%s: %d gaps (%0.2f ms)" % [seed_text, gaps.size(), h.path_timings.get("gaps_ms", 0.0)])
		_check(gaps.size() >= 2 and gaps.size() <= 4, "Unexpected placement count on %s" % seed_text)
		var lines := w.trails.duplicate()
		for gap: Dictionary in gaps:
			lines.append(gap.bypass)
		var clearance := StageVegetation.path_clearance(w.W, w.H, lines, w.tunnels)
		for gap: Dictionary in gaps:
			var bypass: Array = gap.bypass.pts
			var middle: Dictionary = bypass[bypass.size() / 2]
			_check(Grid.clearance_at(clearance, 0, 0, w.W, middle.x, middle.y, TILE) < 0.0,
				"Vegetation clearance missed the bypass on %s" % seed_text)
			var from: Dictionary = bypass.front()
			var to: Dictionary = bypass.back()
			var axis := Vector2(to.x - from.x, to.y - from.y).normalized()
			var center: Vector2 = gap.area.get_center()
			for sign: float in [-1.0, 1.0]:
				_check(_ride_bypass(h, bypass, sign), "Saved-world bypass failed for %s at %s" % [seed_text, center])
				var landed := false
				for speed: float in [12.0, 13.0, 14.0, 15.0]:
					landed = _ride(h, center, axis * sign, speed) or landed
				_check(landed, "Saved-world jump failed for %s at %s" % [seed_text, center])
	print("Saved-world gap checks: %d failures" % failures)


func _world(seed: int, axis: Vector2, junction := false) -> WorldData:
	var w := WorldData.new()
	w.W = 66
	w.H = 66
	w.N = w.W * w.H
	w.seed_num = seed
	for name: String in ["h", "filled", "elev", "slope", "temp", "moist", "dist_water"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		values.fill(20.0 if name == "dist_water" else (0.1 if name == "h" else 0.0))
		w.set(name, values)
	for name: String in ["ocean", "lake", "river", "biome", "path_mask", "road_surface"]:
		var values := PackedByteArray()
		values.resize(w.N)
		values.fill(Biomes.FOREST if name == "biome" else 0)
		w.set(name, values)
	w.trails = [_trail(axis)]
	if junction:
		w.trails.append(_trail(axis.orthogonal(), "road"))
	return w


func _trail(axis: Vector2, kind := "trail") -> Dictionary:
	var points: Array = []
	var surfaces := PackedByteArray()
	for s in range(-96, 97, 4):
		var p := (Vector2(130.0, 130.0) + axis * s) / TILE
		points.append({x = p.x, y = p.y, w = 0.62})
		surfaces.append(RoadSurface.FOREST)
	return {kind = kind, pts = points, surf = surfaces}


func _ride(h: Heightfield, center: Vector2, axis: Vector2, speed: float) -> bool:
	var start := center - axis * 15.0
	var p := PlayerState.new()
	var bike := BikeRide.new()
	bike.x = start.x
	bike.z = start.y
	bike.y = _height(h, start)
	bike.heading = atan2(-axis.x, -axis.y)
	bike.mount(p)
	bike.speed = speed
	var control := BikeController.new()
	var takeoff := INF
	var landing := -INF
	var air_time := 0.0
	var repeat_air := 0.0
	var along := -15.0
	for tick in 300:
		var was := bike.airborne
		var throttle := clampf((speed - bike.speed) * 0.8, 0.0, 1.0) if along < -2.0 else 0.0
		control.ride(1.0 / 60.0, p, bike, h.world, h, throttle, 0.0, false, false, false)
		along = (Vector2(bike.x, bike.z) - center).dot(axis)
		if along > -3.9 and bike.airborne:
			if landing == -INF:
				takeoff = minf(takeoff, along)
				air_time += 1.0 / 60.0
			else:
				repeat_air += 1.0 / 60.0
		if was and not bike.airborne and air_time > 0.10 and landing == -INF:
			landing = along
		if along > 12.0 or bike.crashed:
			break
	var ok := not bike.crashed and takeoff < 0.0 and landing > 1.5 and landing < 11.0 and air_time > 0.20 and repeat_air < 0.17 and along > 11.0
	print("seed %d dir %+.2f/%+.2f v %.0f: %s takeoff %.2f landing %.2f air %.2f repeat %.2f end %.2f" %
		[h.world.seed_num, axis.x, axis.y, speed, "OK" if ok else "MISS", takeoff, landing, air_time, repeat_air, along])
	return ok


func _ride_bypass(h: Heightfield, line: Array, direction: float) -> bool:
	var route := TrailDefinition.new()
	var points := PackedVector2Array()
	for p: Dictionary in line:
		points.append(Vector2(p.x, p.y) * TILE)
	if direction < 0.0:
		points.reverse()
	var axis := points[0].direction_to(points[-1])
	points.insert(0, points[0] - axis * 5.0)
	points.append(points[-1] + axis * 5.0)
	route.points = points
	var player := PlayerState.new()
	var bike := BikeRide.new()
	bike.x = points[0].x
	bike.z = points[0].y
	bike.y = _height(h, points[0])
	bike.heading = route.heading_at(0.0)
	bike.mount(player)
	bike.speed = 5.0
	var control := BikeController.new()
	var traveled := 0.0
	var max_error := 0.0
	for tick in 720:
		var at := Vector2(bike.x, bike.z)
		var near := route.nearest(at)
		traveled = near.x
		max_error = maxf(max_error, absf(near.z))
		if bike.crashed or traveled > route.route_length() - 1.0:
			break
		var aim := route.point_at(traveled + 2.8) - at
		var steer := clampf(-wrapf(atan2(-aim.x, -aim.y) - bike.heading, -PI, PI) * 2.5, -1.0, 1.0)
		var throttle := clampf(0.47 + (5.0 - bike.speed) * 0.25, 0.0, 1.0)
		control.ride(1.0 / 60.0, player, bike, h.world, h, throttle, steer, false, false, false)
	return not bike.crashed and traveled > route.route_length() - 1.0 and max_error < 1.3


func _walk_through(h: Heightfield, center: Vector2, axis: Vector2) -> bool:
	var p := PlayerState.new()
	var start := center - axis * 5.0
	p.x = start.x
	p.z = start.y
	p.feet = _height(h, start)
	var yaw := atan2(-axis.x, -axis.y)
	var reached_floor := false
	for tick in 900:
		p.step(1.0, 0.0, false, false, yaw, 1.0 / 60.0, h.world, h)
		var along := (Vector2(p.x, p.z) - center).dot(axis)
		if absf(along) < 0.4 and p.feet < _height(h, center) + 0.25:
			reached_floor = true
		if along > 5.0:
			return reached_floor
	return false


func _mesh_matches(h: Heightfield) -> void:
	var arrays := TerrainBuilder.build_arrays(h.world, h)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var error := 0.0
	for i in range(0, indices.size(), 3):
		var p := vertices[indices[i]] * 0.29 + vertices[indices[i + 1]] * 0.33 + vertices[indices[i + 2]] * 0.38
		error = maxf(error, absf(p.y - h.ground_at(p.x, p.z)))
	_check(error < 0.001, "Ground and terrain triangles differ by %.6f m" % error)


func _height(h: Heightfield, at: Vector2) -> float:
	return h.ground_at(at.x, at.y)


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		printerr(message)
