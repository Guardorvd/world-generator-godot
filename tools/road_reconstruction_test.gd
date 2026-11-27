extends "res://tools/road_corridor_probe.gd"
## Paired generation, measurements on the actual tread, and the corridor stand's BikeController ride.
## godot --path . --script res://tools/road_reconstruction_test.gd -- --seed Север-1234 [--template river_expedition]

const Rides := preload("res://scripts/world/road_rides.gd")
const Topology := preload("res://scripts/world/road_topology.gd")
const Records := preload("res://scripts/world/road_records.gd")

var seed_text: String
var template: String


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	seed_text = _arg("seed", "Север-1234")
	template = _arg("template", WorldTemplate.DEFAULT_ID)
	out = _arg("out", "res://.godot/road_reconstruction").path_join(template)
	shots = DisplayServer.get_name() != "headless" and not "--no-shots" in OS.get_cmdline_user_args()
	ride_metres = 75
	DirAccess.make_dir_recursive_absolute(out)
	run.call_deferred()


func run() -> void:
	var after_first := "--after-first" in OS.get_cmdline_user_args()
	var first := _generate(after_first)
	var second := _generate(not after_first)
	var previous := second if after_first else first
	var rebuilt := first if after_first else second
	if previous.is_empty() or rebuilt.is_empty():
		printerr("RECONSTRUCTION: could not generate both surfaces")
		quit(1)
		return
	var same_network: bool = previous.ends == rebuilt.ends and previous.junctions == rebuilt.junctions
	var same_water: bool = previous.h.water_level == rebuilt.h.water_level
	var same_structures: bool = previous.h.structures == rebuilt.h.structures
	var scope := _scope(previous, rebuilt)
	var paired := _compare_defects(previous, rebuilt)
	var report := {
		seed = seed_text, template = template, same_network = same_network, same_water = same_water, same_structures = same_structures,
		before = previous.report, after = rebuilt.report, new_stations = paired.new_stations, new_locations = paired.new_locations,
		resampled_stations = paired.resampled_stations, scope = scope, sections = [],
	}
	if shots: _scene()
	var seen := {}
	for s: Dictionary in paired.examples:
		var key: String = "%s:%d" % [s.id, s.before.station / 60]
		if seen.has(key): continue
		seen[key] = true
		s.before.kind = s.label
		s.after.kind = s.label
		s.ride_before = _ride(previous.w, previous.h, s.before)
		s.ride_after = _ride(rebuilt.w, rebuilt.h, s.after)
		s.profile_before = _profile(previous.h, s.before)
		s.profile_after = _profile(rebuilt.h, s.after)
		if shots:
			var destination := out
			base_dir = ""
			await _capture(previous, destination.path_join("before"), s.before)
			base_dir = out
			await _capture(rebuilt, destination.path_join("after"), s.after)
			out = destination
		report.sections.append(s)
	var file := FileAccess.open(out.path_join("report.json"), FileAccess.WRITE)
	if file == null:
		printerr("RECONSTRUCTION: report file unavailable")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	print("RECONSTRUCTION ", JSON.stringify({before = previous.report, after = rebuilt.report, same_network = same_network,
		same_water = same_water, same_structures = same_structures, new_stations = paired.new_stations,
		resampled_stations = paired.resampled_stations, scope = scope, samples = report.sections.size()}))
	print("RECONSTRUCTION REPORT ", out)
	var strict := "--strict" in OS.get_cmdline_user_args()
	quit(0 if same_network and same_water and same_structures and scope.ok and (not strict or paired.new_locations.is_empty()) else 1)


func _generate(enabled: bool) -> Dictionary:
	StageTrails.local_reconstruction = enabled
	var started := Time.get_ticks_usec()
	var w := WorldGenerator.generate(seed_text, WorldGenerator.START_SIZE, Callable(), Callable(), Callable(), template,
		"--short-expedition" in OS.get_cmdline_user_args())
	var ms := (Time.get_ticks_usec() - started) / 1000.0
	if w == null or w.generation.trail_surface == null or not Rides.validation_error(w).is_empty(): return {}
	if not Records.validation_error(w.trails, "road reconstruction stand", Records.Phase.SURFACED).is_empty(): return {}
	var h: Heightfield = w.generation.trail_surface
	var mask := Samples.protection(w, h)
	var gaps := h.road_refinement.gaps
	var route_stats := {}
	var ends := {}
	var totals := {}
	var tuning := RoadTuning.for_world(w).routing
	for route in w.trails.size():
		var t: Dictionary = w.trails[route]
		if not RoadBed.KINDS.has(t.kind) or t.has("trail_id") or not t.has("road_id"): continue
		ends[t.road_id] = [Vector2(t.pts[0].x, t.pts[0].y), Vector2(t.pts[-1].x, t.pts[-1].y), t.kind]
		var stations: PackedVector2Array = Samples.stations(t).p
		if stations.size() < 24: continue
		var axis := PackedVector2Array()
		var distance := PackedFloat64Array()
		for node: Dictionary in t.pts:
			var pos := Vector2(node.x, node.y) * TILE
			distance.append(0.0 if axis.is_empty() else distance[-1] + pos.distance_to(axis[-1]))
			axis.append(pos)
		var y := PackedFloat64Array()
		for p: Vector2 in stations: y.append(h.ground_at(p.x, p.y))
		var grade: float = {"road": StageTrails.ROAD_LIMIT, "trail": StageTrails.TRAIL_GRADE, "mountain": StageTrails.MOUNTAIN_GRADE}[t.kind]
		grade = tuning.line_limits(grade, StageTrails.BENCH_CROSS).grade
		var grade_break: float = {"road": 0.15, "trail": 0.22, "mountain": 0.30}[t.kind]
		var kink := float(tuning.line_shape.kink_laplacian_angle) + (10.0 if t.kind == "mountain" else 0.0)
		var signs := PackedByteArray()
		signs.resize(stations.size())
		var totals_kind: Dictionary = totals.get_or_add(t.kind, {kink = 0, grade = 0, grade_break = 0})
		for i in range(12, stations.size() - 12):
			if mask[Samples.cell(w, stations[i])] != 0: continue
			if gaps.any(func(gap: Dictionary) -> bool: return (gap.area as Rect2).grow(6.0).has_point(stations[i])): continue
			var before := stations[i] - stations[i - 4]
			var after := stations[i + 4] - stations[i]
			var rise := (y[i + 6] - y[i - 6]) / 12.0
			if absf(rad_to_deg(before.angle_to(after))) > kink:
				signs[i] |= 1
				totals_kind.kink += 1
			if rise > grade or rise < -grade * tuning.downhill_ratio():
				signs[i] |= 2
				totals_kind.grade += 1
			if absf(y[i - 4] - 2.0 * y[i] + y[i + 4]) > 4.0 * grade_break:
				signs[i] |= 4
				totals_kind.grade_break += 1
		route_stats[t.road_id] = {route = route, kind = t.kind, p = stations, axis = axis, distance = distance, defects = signs, y = y,
			grade = grade, downhill = tuning.downhill_ratio(), grade_break = grade_break}
	var result := {w = w, h = h, routes = route_stats, ends = ends, junctions = _junctions(w), report = {world_ms = ms, defects = totals,
		stages = w.generation_profile.get("stages_ms", {}), axis = w.generation_profile.get("road_corner_reconstruction", {}),
		surface = h.path_timings}}
	print("RECONSTRUCTION ", template, " enabled=", enabled, " world_ms=", ms, " defects=", totals)
	return result


func _scope(previous: Dictionary, rebuilt: Dictionary) -> Dictionary:
	var total := 0.0
	for t: Dictionary in previous.w.trails:
		if RoadBed.KINDS.has(t.kind) and not t.has("trail_id"):
			total += Topology.length_m(t.pts)
	var approved := 0.0
	var intervals := 0
	var outside := 0
	for id: String in rebuilt.routes:
		var row: Dictionary = rebuilt.routes[id]
		var t: Dictionary = rebuilt.w.trails[row.route]
		var spans: PackedFloat64Array = t.get("reconstruction_ranges_m", PackedFloat64Array())
		for k in range(0, spans.size(), 2):
			approved += spans[k + 1] - spans[k]
			intervals += 1
		if previous.routes.has(id) and not _axis_outside_matches(previous.routes[id], row, spans):
			outside += 1
	return {ok = outside == 0, total_m = total, approved_m = approved, intervals = intervals,
		approved_pct = approved / maxf(total, 1.0) * 100.0, axes_changed_outside = outside}


func _axis_outside_matches(before: Dictionary, after: Dictionary, spans: PackedFloat64Array) -> bool:
	var a: PackedVector2Array = before.axis
	var b: PackedVector2Array = after.axis
	if spans.is_empty(): return a == b
	var distances: PackedFloat64Array = after.distance
	var old := 0
	var current := 0
	for i in range(0, spans.size(), 2):
		var first := distances.bsearch(spans[i] - 0.001)
		var last := distances.bsearch(spans[i + 1] - 0.001)
		if first >= b.size() or last >= b.size(): return false
		var old_first := a.find(b[first], old)
		var old_last := a.find(b[last], maxi(old_first, 0))
		if old_first < 0 or old_last < 0 or a.slice(old, old_first + 1) != b.slice(current, first + 1): return false
		old = old_last
		current = last
	return a.slice(old) == b.slice(current)


func _junctions(w: WorldData) -> Dictionary:
	var graph := Topology.compile(w)
	var sections := {}
	for edge: Dictionary in graph.edges:
		(sections.get_or_add(edge.from, {}) as Dictionary)[edge.section] = true
		(sections.get_or_add(edge.to, {}) as Dictionary)[edge.section] = true
	var result := {}
	for node: int in sections:
		var members: Dictionary = sections[node]
		if members.size() > 1: result[graph.nodes[node].id] = members
	return result


func _compare_defects(previous: Dictionary, rebuilt: Dictionary) -> Dictionary:
	var samples := {}
	var new_stations := {kink = 0, grade = 0, grade_break = 0}
	var resampled := 0
	var locations := []
	for id: String in rebuilt.routes:
		if not previous.routes.has(id): continue
		var a: Dictionary = previous.routes[id]
		var b: Dictionary = rebuilt.routes[id]
		var at := 0
		for j in b.p.size():
			var point: Vector2 = b.p[j]
			var nearest := INF
			var matched := at
			for k in range(maxi(0, at - 12), mini(a.p.size(), at + 24)):
				var d := point.distance_squared_to(a.p[k])
				if d < nearest:
					nearest = d
					matched = k
			at = matched
			var seen := 0
			for k in range(maxi(0, at - 5), mini(a.p.size(), at + 6)): seen |= a.defects[k]
			var introduced: int = b.defects[j] & ~seen
			if introduced != 0 and j >= 6 and j + 6 < b.p.size() and nearest <= 0.55 * 0.55:
				var old: int = introduced & _flags_at_same_station(previous.h, a, b.p, j, at)
				introduced &= ~old
				resampled += int(old != 0)
			new_stations.kink += int(introduced & 1 != 0)
			new_stations.grade += int(introduced & 2 != 0)
			new_stations.grade_break += int(introduced & 4 != 0)
			if introduced != 0:
				locations.append({route = b.route, old_m = at, new_m = j, x = point.x, z = point.y,
					axis_move_m = sqrt(nearest), height_delta_m = b.y[j] - a.y[at], defect = introduced,
					delta_grade = absf(b.y[j - 4] - 2.0 * b.y[j] + b.y[j + 4]) / 4.0})
			if j < 32 or j + 32 >= b.p.size() or at < 32 or at + 32 >= a.p.size(): continue
			var label := "turn" if nearest > 1.0 else "profile"
			var score := sqrt(nearest) if label == "turn" else absf(b.y[j] - a.y[at])
			if score < 0.20 or b.defects[j] != 0 or seen == 0: continue
			if score <= samples.get(label, {}).get("score", 0.0): continue
			samples[label] = {id = id, label = label, kind = b.kind, score = score,
				before = {route = a.route, station = at}, after = {route = b.route, station = j}}
	return {new_stations = new_stations, new_locations = locations, resampled_stations = resampled, examples = samples.values()}


## An earlier splice shifts metre sampling on the rest of a route. When both
## axes pass through these exact chord points, measure the old surface there too.
func _flags_at_same_station(h: Heightfield, route: Dictionary, points: PackedVector2Array, station: int, old: int) -> int:
	var y := PackedFloat64Array()
	var distances: PackedFloat64Array = route.distance
	var axis: PackedVector2Array = route.axis
	for offset: int in [-6, -4, 0, 4, 6]:
		var p := points[station + offset]
		var first := maxi(1, distances.bsearch(old + offset - 2.0))
		var last := mini(axis.size() - 1, distances.bsearch(old + offset + 2.0))
		var same := false
		for k in range(first, last + 1):
			if Geometry2D.get_closest_point_to_segment(p, axis[k - 1], axis[k]).distance_squared_to(p) <= 0.02 * 0.02:
				same = true
				break
		if not same: return 0
		y.append(h.ground_at(p.x, p.y))
	var old_grade := (y[4] - y[0]) / 12.0
	var flags := 1 # The same chords hit the same unmodified part of the horizontal axis.
	if old_grade > route.grade or old_grade < -route.grade * route.downhill: flags |= 2
	if absf(y[1] - 2.0 * y[2] + y[3]) > 4.0 * route.grade_break: flags |= 4
	return flags


func _capture(version: Dictionary, destination: String, section: Dictionary) -> void:
	out = destination
	DirAccess.make_dir_recursive_absolute(out)
	var w: WorldData = version.w
	var image := MapBaker.finish(w, 1, [MapBaker.paint(w, 1, true, false)[0]], false)[0]
	terrain_material = GameContext.scope.terrain.material(image)
	await _shoot(w, version.h, seed_text, section)
