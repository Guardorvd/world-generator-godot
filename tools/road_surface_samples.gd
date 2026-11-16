extends RefCounted
## Sampling shared by the corridor bench and the network report.
const TILE := GameConfig.TILE
const MID_R := 10
const EXCLUSIONS := ["", "near_water", "near_structure", "near_settlement"]
const Topology := preload("res://scripts/world/road_topology.gd")
const Placement := preload("res://scripts/render/vegetation_placement.gd")


## Станции через 1 м по линии пути: точка, полуширина
static func stations(t: Dictionary) -> Dictionary:
	var pts: Array = t.pts
	var ps := PackedVector2Array()
	var half := PackedFloat32Array()
	var along := 0.0
	var next := 0.0
	for n in range(1, pts.size()):
		var a := Vector2(pts[n - 1].x, pts[n - 1].y) * TILE
		var b := Vector2(pts[n].x, pts[n].y) * TILE
		var length := a.distance_to(b)
		if length < 0.01: continue
		while next <= along + length:
			var f := (next - along) / length
			ps.append(a.lerp(b, f))
			half.append(lerpf(float(pts[n - 1].w), float(pts[n].w), f) * TILE * 0.5)
			next += 1.0
		along += length
	return {p = ps, half = half}


static func normal(ps: PackedVector2Array, j: int) -> Vector2:
	var t := (ps[mini(ps.size() - 1, j + 2)] - ps[maxi(0, j - 2)]).normalized()
	return Vector2(-t.y, t.x)


## Маска исключений стенда. Порядок перекрытия: поселение, сооружение, вода.
static func protection(w: WorldData, h: Heightfield) -> PackedByteArray:
	var pin := PackedByteArray()
	pin.resize(w.N)
	var water_distance := w.dist_water
	var level := h.water_level
	for i in w.N:
		if (not water_distance.is_empty() and water_distance[i] < 3.0) or (not level.is_empty() and level[i] != -INF): pin[i] = 1
	for s: Dictionary in h.structures:
		var a := Vector2(s.ax, s.az)
		var b := Vector2(s.bx, s.bz)
		var steps := maxi(1, ceili(a.distance_to(b) / TILE))
		for k in steps + 1:
			var p := a.lerp(b, float(k) / steps) / TILE
			for dz in range(-4, 5):
				for dx in range(-4, 5):
					var x := floori(p.x) + dx
					var z := floori(p.y) + dz
					if x >= 0 and z >= 0 and x < w.W and z < w.H: pin[z * w.W + x] = 2
	for v: SettlementData in w.settlements:
		for dz in range(-3, 4):
			for dx in range(-3, 4):
				var x := floori(v.x) + dx
				var z := floori(v.y) + dz
				if x >= 0 and z >= 0 and x < w.W and z < w.H: pin[z * w.W + x] = 3
	return pin


static func cell(w: WorldData, p: Vector2) -> int:
	return clampi(floori(p.y / TILE), 0, w.H - 1) * w.W + clampi(floori(p.x / TILE), 0, w.W - 1)


## Отклонение от среднего по ±MID_R станций (префиксные суммы)
static func detrend(a: PackedFloat64Array) -> PackedFloat64Array:
	var n := a.size()
	var sum := PackedFloat64Array()
	sum.resize(n + 1)
	for j in n: sum[j + 1] = sum[j] + a[j]
	var outv := PackedFloat64Array()
	outv.resize(n)
	for j in n:
		var lo := maxi(0, j - MID_R)
		var hi := mini(n - 1, j + MID_R)
		outv[j] = a[j] - (sum[hi + 1] - sum[lo]) / (hi - lo + 1)
	return outv


static func measure(w: WorldData, sections: Array, h: Heightfield, forest: Image) -> Dictionary:
	var pin := protection(w, h) if h != null else PackedByteArray()
	var obstacles: RoadObstacles
	if h != null and forest != null and w.CS > 0 and not w.chunks.is_empty():
		obstacles = RoadObstacles.new(w)
		var placement := Placement.new(w, h)
		var centre := Vector2(w.W, w.H) * TILE * 0.5
		placement.prepare(centre.x, centre.y, maxf(centre.x, centre.y))
		obstacles.sync_regions({}, placement)
	var measured := {}
	for index: int in sections:
		var t: Dictionary = w.trails[index]
		var group: Dictionary = measured.get_or_add(t.kind, {sections = 0, axis_m = 0.0,
			width = [], cross = [], roughness = [], excluded_sections = [], cross_excluded = {}, roughness_excluded = {},
			obstacles = {chords = 0, occupied = 0, parts = {}, rejected = {}}})
		group.sections += 1
		group.axis_m += Topology.length_m(t.pts)
		_measure_section(w, index, h, pin, group)
		if obstacles != null:
			var candidates := obstacles.measure_candidates(h, forest, index)
			group.obstacles.chords += candidates.chords
			group.obstacles.occupied += candidates.occupied
			_merge_counts(group.obstacles.parts, candidates.parts)
			_merge_counts(group.obstacles.rejected, candidates.rejected)
	for kind: String in measured:
		var group: Dictionary = measured[kind]
		var parts := 0
		for count: int in group.obstacles.parts.values(): parts += count
		group.obstacles.parts_total = parts
		group.obstacles.parts_per_km = snappedf(1000.0 * parts / group.axis_m, 0.01) if group.axis_m > 0.0 else null
		if obstacles == null: group.obstacles = null
		group.axis_m = snappedf(group.axis_m, 0.01)
		group.width_m = _stats(group.width)
		group.cross_slope_pct = _stats(group.cross)
		group.longitudinal_roughness_cm = _stats(group.roughness)
		group.erase("width")
		group.erase("cross")
		group.erase("roughness")
	return measured


static func _measure_section(w: WorldData, index: int, h: Heightfield, pin: PackedByteArray, group: Dictionary) -> void:
	var t: Dictionary = w.trails[index]
	var st := stations(t)
	var ps: PackedVector2Array = st.p
	var count := ps.size()
	var heights := PackedFloat64Array()
	var reasons := PackedStringArray()
	var excluded := {section_index = index, road_id = t.get("road_id", ""), stations = count,
		cross_slope = {}, roughness = {}}
	if count == 0: excluded.reason = "no_stations"
	var in_plan := Rect2(0.0, 0.0, w.W * TILE, w.H * TILE)
	for j in count:
		var half: float = st.half[j]
		group.width.append(half * 2.0)
		var p := ps[j]
		var reason := ""
		if h == null:
			reason = "surface_unavailable"
		elif not in_plan.has_point(p):
			reason = "outside_plan"
		else:
			reason = EXCLUSIONS[pin[cell(w, p)]]
		var height := h.ground_at(p.x, p.y) if reason.is_empty() else 0.0
		if not is_finite(height):
			reason = "non_finite_height"
			height = 0.0
		heights.append(height)
		reasons.append(reason)
		if reason.is_empty():
			var side := normal(ps, j) * half * 0.9
			if side == Vector2.ZERO:
				reason = "undefined_normal"
			elif not in_plan.has_point(p - side) or not in_plan.has_point(p + side):
				reason = "outside_plan"
			else:
				var slope := absf(h.ground_at(p.x + side.x, p.y + side.y) - h.ground_at(p.x - side.x, p.y - side.y)) / (1.8 * half)
				if is_finite(slope):
					group.cross.append(slope * 100.0)
				else:
					reason = "non_finite_height"
		if not reason.is_empty(): _count(excluded.cross_slope, reason)
	var residuals := detrend(heights)
	for j in count:
		var reason := reasons[j]
		if reason.is_empty() and (j < MID_R or j + MID_R >= count):
			reason = "incomplete_window"
		if reason.is_empty():
			for k in range(j - MID_R, j + MID_R + 1):
				if not reasons[k].is_empty():
					reason = "window_intersects_" + reasons[k]
					break
		if reason.is_empty():
			group.roughness.append(absf(residuals[j]) * 100.0)
		else:
			_count(excluded.roughness, reason)
	if count == 0 or not excluded.cross_slope.is_empty() or not excluded.roughness.is_empty():
		group.excluded_sections.append(excluded)
		_merge_counts(group.cross_excluded, excluded.cross_slope)
		_merge_counts(group.roughness_excluded, excluded.roughness)


static func _count(counts: Dictionary, key: String) -> void:
	counts[key] = int(counts.get(key, 0)) + 1


static func _merge_counts(counts: Dictionary, other: Dictionary) -> void:
	for key: String in other:
		counts[key] = int(counts.get(key, 0)) + int(other[key])


static func _stats(values: Array) -> Dictionary:
	var n := values.size()
	if n == 0: return {samples = 0}
	values.sort()
	var sum := 0.0
	var squares := 0.0
	for value: float in values:
		sum += value
		squares += value * value
	return {samples = n, min = snappedf(values[0], 0.001), mean = snappedf(sum / n, 0.001),
		p95 = snappedf(values[ceili(n * 0.95) - 1], 0.001), max = snappedf(values[-1], 0.001),
		rms = snappedf(sqrt(squares / n), 0.001)}
