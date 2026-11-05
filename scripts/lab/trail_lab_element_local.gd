extends RefCounted
## Cheap proposal model on the already baked bare tread. Never builds a WorldData/Heightfield.
## Its sampled estimates guide selection; the production full-surface audit decides acceptance.
const S := preload("res://scripts/trails/trail_standards.gd")
const V := preload("res://scripts/lab/trail_lab_validation.gd")
const A := preload("res://scripts/lab/trail_lab_surface_audit.gd")
const T := TrailElement.Profile

static func is_structure(route: TrailDefinition, e: TrailElement) -> bool:
	if e.profile == T.NORTHSHORE: return true
	if e.profile != T.GAP: return false
	for span in route.open_spans:
		if span.y >= e.station - e.length * 0.5 and span.x <= e.station + e.length * 0.5: return true
	return false

static func adapt(original: TrailElement, route: TrailDefinition, base: Dictionary, input) -> Array[TrailElement]:
	var e := original.duplicate(true) as TrailElement
	# A crossing owns its supports, clearance and open span. Ordinary feature fitting
	# must not resize it independently of that geometry or replace it with ground relief.
	if is_structure(route, e): return [e] as Array[TrailElement]
	var from := e.station - e.length * 0.5
	var level := V._level(route, e.station)
	var speeds: PackedFloat32Array = base.ride.scenarios.normal.speeds
	var v := speeds[clampi(floori(from), 0, speeds.size() - 1)]
	var ground := func(p: Vector2) -> float: return (base._heights as Heightfield).ground_at(p.x, p.y)
	var kinds := {T.TABLETOP: "table", T.GAP: "gap", T.DROP: "drop", T.ROLLER: "roller", T.PUMP: "pump"}
	if kinds.has(e.profile):
		var sized := S.spec(kinds[e.profile], snappedf(v, 0.5), level, S.grade_of(route, ground, from, from + e.length), false)
		if not sized.is_empty():
			e.length = sized.length; e.height = sized.height
			e.station = from + e.length * 0.5
			e.count = int(sized.get("count", e.count)); e.gap = float(sized.get("gap", e.gap))
	# Section boundaries are compositional preferences. Fit the actual free extent instead.
	var available := route.route_length() - from
	for placed in route.elements:
		var start := placed.station - placed.length * 0.5
		if start > from: available = minf(available, start - from)
	if e.profile != T.GAP and e.length > available and available >= RoadRefinement.STEP * 4:
		var ratio := available / e.length
		e.length = available
		e.height *= ratio * ratio # retain crest curvature as the footprint shrinks
		e.station = from + e.length * 0.5
		if e.profile in [T.PUMP, T.WAVES]:
			e.count = maxi(1, mini(e.count, floori(e.length / (RoadRefinement.STEP * (8 if e.profile == T.WAVES else 4)))))
	# Fit available earthwork headroom before trying any candidate. Negative profiles use cut headroom.
	if not input.earthwork_limits.get("unlimited", false) and not TrailElement.places_objects(e.profile):
		var fraction := 1.0
		for s in range(floori(from), ceili(from + e.length) + 1):
			var p := route.point_at(s)
			var side := route.tangent_at(s).orthogonal()
			for lane in range(-ceili(route.width * 0.5 + 2), ceili(route.width * 0.5 + 2) + 1):
				var displacement := e.displacement(s, lane, route.width * 0.5)
				if absf(displacement) < 0.001: continue
				var at := p + side * lane
				var residual: float = ground.call(at) - input.natural_ground(at)
				var headroom: float = float(input.earthwork_limits.max_fill) - residual if displacement > 0 else float(input.earthwork_limits.max_cut) + residual
				fraction = minf(fraction, maxf(0, headroom) / absf(displacement))
		e.height *= fraction
	var result: Array[TrailElement] = [e]
	for scale: float in [0.7, 0.45, 0.25]:
		var smaller := e.duplicate(true) as TrailElement
		smaller.height *= scale
		result.append(smaller)
	if e.profile in [T.TABLETOP, T.DROP, T.WAVES, T.PUMP]:
		var roller := e.duplicate(true) as TrailElement
		roller.profile = T.ROLLER; roller.height = minf(e.height, 0.3); roller.count = 1
		result.append(roller)
	return result

static func check(input, route: TrailDefinition, e: TrailElement, base: Dictionary) -> Dictionary:
	var report := {accepted = false, element = A.element_record(e), model = "local bare-tread estimate", reasons = [], scenarios = {}}
	var from := e.station - e.length * 0.5
	var to := e.station + e.length * 0.5
	if from < 0 or to > route.route_length() or e.height < 0.01:
		report.reasons.append("нет места или запаса высоты"); return report
	var h: Heightfield = base._heights
	# Includes overlapping elements and shoulders. No whole-route grid traversal per candidate.
	for s in range(floori(from), ceili(to) + 1):
		var p := route.point_at(s)
		var side := route.tangent_at(s).orthogonal()
		for lane in range(-ceili(route.width * 0.5 + 3), ceili(route.width * 0.5 + 3) + 1):
			var offset := 0.0
			for other in route.elements: offset += other.displacement(s, lane, route.width * 0.5)
			if absf(offset) < 0.001: continue
			var at := p + side * lane
			var delta: float = h.ground_at(at.x, at.y) + clampf(offset, -TrailBuilder.ELEMENT_CAP, TrailBuilder.ELEMENT_CAP) - input.natural_ground(at)
			if input.blocked(at) or (not input.earthwork_limits.get("unlimited", false) and (delta > float(input.earthwork_limits.max_fill) + 0.05 or delta < -float(input.earthwork_limits.max_cut) - 0.05)):
				report.reasons.append("местный предел земляных работ/защищённая область"); return report
	var p0 := route.point_at(from); var p1 := route.point_at(to)
	var grade := (h.ground_at(p1.x, p1.y) - h.ground_at(p0.x, p0.y)) / e.length
	var level := V._level(route, e.station)
	var w := S.window(e, route, grade, level)
	var jump := e.profile in [T.TABLETOP, T.GAP, T.DROP]
	var origin := maxi(0, floori(from) - 2)
	var end := mini(ceili(route.route_length()), ceili(float(w.get("land_to", to)) + 12))
	var y := PackedFloat32Array()
	if jump:
		for s in range(origin, end + 1):
			var p := route.point_at(s)
			var offset := 0.0
			for other in route.elements: offset += other.displacement(s, 0, route.width * 0.5)
			y.append(h.ground_at(p.x, p.y) + clampf(offset, -TrailBuilder.ELEMENT_CAP, TrailBuilder.ELEMENT_CAP))
	for scenario: String in base.ride.scenarios:
		var speeds: PackedFloat32Array = base.ride.scenarios[scenario].speeds
		var v := speeds[clampi(floori(from), 0, speeds.size() - 1)]
		var available_from := 0.0
		for other in route.elements:
			var other_end := other.station + other.length * 0.5
			if other_end > from or other == e: continue
			if other.profile in [T.TABLETOP, T.GAP, T.DROP] or TrailElement.places_objects(other.profile):
				var other_jump := other.profile in [T.TABLETOP, T.GAP, T.DROP]
				var other_start := route.point_at(other.station - other.length * 0.5)
				var other_finish := route.point_at(other_end)
				var other_grade := (h.ground_at(other_finish.x, other_finish.y) - h.ground_at(other_start.x, other_start.y)) / other.length
				var window := S.window(other, route, other_grade, V._level(route, other.station))
				var prior_speed := speeds[clampi(floori(other.station - other.length * 0.5), 0, speeds.size() - 1)]
				available_from = maxf(available_from, maxf(other_end, float(window.get("land_to", other_end))) + S.recovery_distance(prior_speed, other_jump))
		var incoming := v
		if w.has("speed_hi") and v > float(w.speed_hi):
			var start := route.point_at(available_from)
			var distance := maxf(0, from - available_from)
			var braking_grade := (h.ground_at(p0.x, p0.y) - h.ground_at(start.x, start.y)) / maxf(1, distance)
			var braking := maxf(0.1, S.BRAKE + S.G * braking_grade)
			var required := (v * v - float(w.speed_hi) * float(w.speed_hi)) / (2 * braking)
			if required <= distance: v = float(w.speed_hi)
		var record := {incoming_speed = incoming, entry_speed = v, window = w}
		report.scenarios[scenario] = record
		if w.has("speed_hi") and v > float(w.speed_hi) + 0.5: report.reasons.append("скорость выше окна")
		if not jump: continue
		var flight := V.fly_surface(y, from - origin, v, end - origin)
		record.flight = flight
		var rollable := V._rollable_table(route, e)
		var rolls_off := V._rolls_off(route, e)
		if w.has("speed_lo") and v < float(w.speed_lo) - 0.5 and not rollable: report.reasons.append("скорость ниже окна")
		if flight.get("unresolved", false): report.reasons.append("место приземления не подтверждено")
		var land := float(flight.land) + origin if flight.flew else float(w.get("land_to", to))
		if not flight.flew and not rolls_off: report.reasons.append("нет отрыва")
		if flight.flew and (land > float(w.land_to) + 0.5 or (land < float(w.land_from) - 0.5 and not rolls_off) or float(flight.impact) > float(S.LEVELS[level].impact)): report.reasons.append("приземление вне допустимой зоны/удара")
		var recovery := maxf(land, float(w.get("land_to", to))) + S.recovery_distance(v, true)
		var approach := S.tightest(route, maxf(0, from - S.HUB - v * float(BikeRide.LOOK[-1])), float(w.get("lip", from)))
		var landing := S.tightest(route, float(w.get("land_from", from)), minf(route.route_length(), recovery))
		if recovery > route.route_length() or minf(approach, landing) < v * v / (S.LAT_MAX * float(S.LEVELS[level].lat)): report.reasons.append("нет места для подхода, приземления и восстановления на этой скорости")
	report.accepted = report.reasons.is_empty()
	return report

## Address only violations attributed to an element or intersecting its influence/recovery interval.
static func affected(route: TrailDefinition, evaluation: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for i in route.elements.size():
		var e := route.elements[i]
		var lo := e.station - e.length * 0.5 - 8
		var hi := e.station + e.length * 0.5 + 20
		var hit := false
		for interval: Dictionary in evaluation.get("earthworks", {}).get("intervals", []):
			if interval.get("new_vertices", 0) > 0 and interval.to >= lo and interval.from <= hi: hit = true
		for issue: Dictionary in evaluation.get("ride", {}).get("issues", []):
			if issue.assessment != "safety": continue
			if int(issue.element) == i: hit = true
			elif int(issue.element) < 0 and issue.get("to", issue.station) >= lo and issue.station <= hi: hit = true
		if hit: result.append(i)
	result.reverse()
	return result
