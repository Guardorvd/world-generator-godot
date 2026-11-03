extends RefCounted
const Base := preload("res://scripts/lab/trail_lab_base_surface.gd")
const V := preload("res://scripts/lab/trail_lab_validation.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")

static func evaluate(input: GI, route: TrailDefinition, base: Heightfield = null) -> Dictionary:
	var built := Base.bake(input, route)
	if not built.errors.is_empty(): return {accepted = false, errors = Array(built.errors), earthworks = {}, ride = {}, bake_ms = built.ms}
	var h: Heightfield = built.heights
	TrailTechnical.build(h, [route] as Array[TrailDefinition])
	var earthworks := Base.audit(input, h, route, base)
	var ride := V.measure(h, route, func(p: Vector2) -> bool: return not input.blocked(p))
	for scenario: Dictionary in ride.scenarios.values():
		scenario.feature_entry_speeds = {}
		for i in route.elements.size():
			var e := route.elements[i]
			scenario.feature_entry_speeds[i] = scenario.speeds[clampi(floori(e.station - e.length * 0.5), 0, scenario.speeds.size() - 1)]
	return {accepted = earthworks.accepted and ride.accepted, earthworks = earthworks, ride = ride, bake_ms = built.ms, _heights = h}

static func without_runtime(result: Dictionary) -> Dictionary:
	var copy := result.duplicate(true)
	copy.erase("_heights")
	# Every violation sample and every recomputed feature window/flight remain in the report.
	# Repeated full-route speed arrays in hundreds of counterfactuals add no diagnostic information.
	for scenario: Dictionary in copy.get("ride", {}).get("scenarios", {}).values(): scenario.erase("speeds")
	return copy

static func element_record(e: TrailElement) -> Dictionary:
	var result := {profile = TrailElement.Profile.keys()[e.profile]}
	for key in TrailElement.KEYS: result[key] = e.get(key)
	return result

static func ride_comparison(base: Dictionary, full: Dictionary) -> Array:
	var result := []
	for issue: Dictionary in full.get("issues", []):
		var inherited := []
		var added := []
		var max_added := 0.0
		for sample: Dictionary in issue.get("samples", [{station = issue.station, metrics = {}}]):
			var prior := -1.0
			for old: Dictionary in base.get("issues", []):
				if old.scenario != issue.scenario or old.reason != issue.reason: continue
				for point: Dictionary in old.get("samples", [{station = old.station, metrics = {}}]):
					if absf(float(point.station) - float(sample.station)) <= 1.0: prior = maxf(prior, float(point.get("metrics", {}).get("deviation", 0)))
			if prior < 0: added.append(sample.station)
			else: inherited.append(sample.station)
			max_added = maxf(max_added, float(sample.get("metrics", {}).get("deviation", 0)) - maxf(0, prior))
		result.append({scenario = issue.scenario, element = issue.element, reason = issue.reason, assessment = issue.assessment,
			inherited_stations = inherited, new_stations = added, max_added_deviation = max_added, max_deviation = issue.get("max_deviation", 0)})
	return result

## Counterfactual attribution on identical geometry, masks, source, difficulty sections and initial speed.
## Remove-one detects contribution; only-one separates individual defects from interactions.
static func diagnose(input: GI, route: TrailDefinition) -> Dictionary:
	var bare := route.duplicate(true) as TrailDefinition
	bare.elements.clear()
	var base := evaluate(input, bare)
	if not base.has("_heights"): return {base = without_runtime(base), error = "base bake failed"}
	var full := evaluate(input, route, base._heights)
	var report := {base = without_runtime(base), full = without_runtime(full), elements = [],
		ride_comparison = ride_comparison(base.ride, full.ride), attribution = [], pairs = [], pair_budget = 12, pair_budget_exhausted = false,
		difficulty_policy = "same sections for base and all counterfactuals"}
	for i in route.elements.size():
		var e := route.elements[i]
		report.elements.append(element_record(e))
		var removed := route.duplicate(true) as TrailDefinition
		removed.elements.remove_at(i)
		var minus := evaluate(input, removed, base._heights)
		var alone := bare.duplicate(true) as TrailDefinition
		alone.elements.append(e.duplicate(true) as TrailElement)
		var only := evaluate(input, alone, base._heights)
		report.attribution.append({element = i, without = without_runtime(minus), alone = without_runtime(only),
			removed_bad_vertices = int(full.earthworks.get("bad_vertices", 0)) - int(minus.earthworks.get("bad_vertices", 0)),
			alone_ride_comparison = ride_comparison(base.ride, only.ride), without_ride_comparison = ride_comparison(base.ride, minus.ride)})
	for i in route.elements.size():
		for j in range(i + 1, route.elements.size()):
			var a := route.elements[i]; var b := route.elements[j]
			if absf(a.station - b.station) > (a.length + b.length) * 0.5 + 30: continue
			if report.pairs.size() >= report.pair_budget: report.pair_budget_exhausted = true; continue
			var pair := bare.duplicate(true) as TrailDefinition
			pair.elements.assign([a.duplicate(true) as TrailElement, b.duplicate(true) as TrailElement])
			var measured := evaluate(input, pair, base._heights)
			var alone_sum: int = report.attribution[i].alone.earthworks.get("bad_vertices", 0) + report.attribution[j].alone.earthworks.get("bad_vertices", 0)
			report.pairs.append({elements = [i, j], evaluation = without_runtime(measured),
				earthwork_interaction = int(measured.earthworks.get("bad_vertices", 0)) > alone_sum,
				ride_vs_first = ride_comparison(report.attribution[i].alone.ride, measured.ride), ride_vs_second = ride_comparison(report.attribution[j].alone.ride, measured.ride)})
	return report
