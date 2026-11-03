extends RefCounted
## Address inherited braking errors by changing only the offending turn/approach geometry.
const A := preload("res://scripts/lab/trail_lab_surface_audit.gd")
const Contract := preload("res://scripts/lab/trail_lab_route_contract.gd")
const Fit := preload("res://scripts/lab/trail_lab_element_fit.gd")
const V := preload("res://scripts/lab/trail_lab_validation.gd")
const MAX_WARP := 8.0
const WINDOWS := [8.0, 14.0, 22.0, 30.0]
# Designed grade is a shaping choice, not a relaxed acceptance threshold. Every variant still
# passes the unchanged final speed model, full slope footprint and source cut/fill limits.
const PROFILES := [Vector2.ZERO, Vector2(0.4, 0.6), Vector2(0.5, 0.7), Vector2(0.5, 1.0)]

static func intervals(ride: Dictionary) -> Array[Vector2]:
	var stations := {}
	for issue: Dictionary in ride.get("issues", []):
		if issue.assessment != "safety" or not issue.reason.contains("торможения"): continue
		for sample in issue.samples: stations[roundi(sample.station)] = true
	var keys := stations.keys(); keys.sort()
	var result: Array[Vector2] = []
	for key: int in keys:
		if result.is_empty() or key > result[-1].y + 16: result.append(Vector2(maxf(0, key - 20), key + 12))
		else: result[-1].y = key + 12
	return result

static func reshape(d: TrailDefinition, zones: Array[Vector2], variant: Vector2) -> PackedVector2Array:
	var result := PackedVector2Array()
	var count := maxi(1, ceili(d.route_length() / 2))
	for i in count + 1:
		var s := d.route_length() * i / count
		var p := d.point_at(s)
		var average := Vector2.ZERO
		for j in range(-3, 4): average += d.point_at(clampf(s + variant.x * j / 3.0, 0, d.route_length()))
		average /= 7
		var outward := d.tangent_at(s).orthogonal() * signf(d.curvature_at(s)) * variant.y
		var weight := 0.0
		for zone in zones: weight = maxf(weight, smoothstep(zone.x - 16, zone.x, s) * (1 - smoothstep(zone.y, zone.y + 16, s)))
		weight *= smoothstep(0, 20, minf(s, d.route_length() - s))
		result.append(p + ((average - p) + outward).limit_length(MAX_WARP) * weight)
	return result

static func remap_sections(original: TrailDefinition, candidate: TrailDefinition) -> void:
	candidate.sections.clear()
	for section: Dictionary in original.sections:
		var copy := section.duplicate(true)
		copy.from = candidate.nearest(original.point_at(section.from)).x
		copy.to = candidate.nearest(original.point_at(section.to)).x
		if copy.to < copy.from: copy.to = copy.from
		candidate.sections.append(copy)

static func solve(input, route: TrailDefinition, settings: Dictionary) -> Dictionary:
	var original := route.duplicate(true) as TrailDefinition
	var bare := route.duplicate(true) as TrailDefinition
	bare.elements.clear()
	var initial := A.evaluate(input, bare)
	var report := {accepted = false, initial = A.without_runtime(initial), trials = [], max_warp_m = MAX_WARP, source_hash = input.fingerprint(), cause = "base"}
	if initial.accepted:
		report.accepted = true; report.changed = false; return report
	var zones := intervals(initial.ride)
	report.intervals = zones
	if zones.is_empty(): report.reason = "у базы нет адресуемого нарушения торможения"; return report
	var bounds: Rect2 = settings.get("bounds", Rect2(Vector2(28, 28), Vector2(input.size) * input.cell_size - Vector2.ONE * 56))
	var allowed := func(p: Vector2) -> bool: return bounds.grow(-4).has_point(p) and not input.blocked(p)
	var hint: PackedVector2Array = settings.get("route_hint", original.points)
	var check := func(candidate: TrailDefinition) -> PackedStringArray:
		var errors := V.footprint(candidate, allowed)
		for p in candidate.points:
			if original.nearest(p).z > MAX_WARP + 0.05: errors.append("превышен бюджет изменения геометрии"); break
		var completed := Contract.measure(candidate.points, hint, original.points[-1], "corridor_fit", input.ground, allowed, candidate.width)
		for reason: String in completed.reasons: errors.append(reason)
		return errors
	var candidates := []
	for window: float in WINDOWS:
		for profile: Vector2 in PROFILES: candidates.append({window = window, profile = profile})
	for variant: Dictionary in candidates:
		var candidate := bare.duplicate(true) as TrailDefinition
		candidate.points = reshape(original, zones, Vector2(variant.window, 0))
		if variant.profile != Vector2.ZERO:
			var shape := TrailShaping.preset("bike")
			shape.grade_limit = variant.profile.x; shape.strength = variant.profile.y
			shape.level_window = 3; shape.side_follow = 0.7; shape.batter = 1
			candidate.shaping = shape
		remap_sections(original, candidate)
		var errors: PackedStringArray = check.call(candidate)
		if not errors.is_empty(): report.trials.append({variant = variant, errors = Array(errors)}); continue
		var evaluated := A.evaluate(input, candidate)
		report.trials.append({variant = variant, evaluated = A.without_runtime(evaluated)})
		if not evaluated.accepted: continue
		for element in original.elements: candidate.elements.append(element.duplicate(true))
		for i in candidate.elements.size():
			var at := original.point_at(original.elements[i].station)
			candidate.elements[i].station = candidate.nearest(at).x
			if candidate.elements[i].profile == TrailElement.Profile.BERM:
				var k := candidate.curvature_at(candidate.elements[i].station)
				if absf(k) > 0.005: candidate.elements[i].bank = signf(k)
		var elements := Fit.fit(input, candidate, settings)
		report.trials[-1].element_fit = elements
		if not elements.accepted: continue
		route.points = candidate.points
		route.shaping = candidate.shaping
		route.sections = candidate.sections
		route.elements = candidate.elements
		report.changed = true
		report.selected = variant
		report.base = A.without_runtime(evaluated)
		report.elements = elements
		report.accepted = true
		return report
	report.reason = "нет безопасной геометрии в ограниченном бюджете"
	return report
