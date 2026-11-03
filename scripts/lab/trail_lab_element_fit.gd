extends RefCounted
## Lab-only proposal fitting. Every variant gets a fresh FINAL surface and complete ride check.
const A := preload("res://scripts/lab/trail_lab_surface_audit.gd")
const C := preload("res://scripts/lab/trail_lab_composition.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const T := TrailElement.Profile
const MAX_VARIANTS := 7
const MAX_BAKES := 72

static func risk(ride: Dictionary) -> float:
	var result := float(ride.get("errors", []).size())
	for issue: Dictionary in ride.get("issues", []):
		if issue.assessment != "safety": continue
		result += 1.0 + float(issue.get("max_deviation", 0)) * 10 + issue.get("samples", []).size() * 0.1
	return result

static func variants(e: TrailElement) -> Array[TrailElement]:
	var result: Array[TrailElement] = [e.duplicate(true) as TrailElement]
	for shift: float in [-6.0, 6.0]:
		var moved := e.duplicate(true) as TrailElement
		moved.station += shift
		result.append(moved)
	for scale: float in [0.7, 0.45, 0.25]:
		var smaller := e.duplicate(true) as TrailElement
		smaller.height *= scale
		smaller.length = maxf(4, e.length * (1.15 if e.profile in [T.BERM, T.S_BERM, T.TABLETOP, T.DROP] else 1.0))
		result.append(smaller)
	var alternate := e.duplicate(true) as TrailElement
	if e.profile in [T.TABLETOP, T.DROP, T.WAVES, T.PUMP]:
		alternate.profile = T.ROLLER
		alternate.height = minf(e.height, 0.3)
		alternate.count = 1
	elif e.profile in [T.ROCK_GARDEN, T.LOG, T.SLALOM]:
		alternate.profile = T.ROOTS; alternate.height = minf(e.height, 0.12); alternate.density = minf(e.density, 0.3)
	else:
		alternate.height *= 0.15
		alternate.length = minf(40, e.length * 1.3)
	result.append(alternate)
	return result

static func sequence_errors(route: TrailDefinition, ground: Callable, settings: Dictionary) -> Array:
	var errors := []
	var state := {recovery = 0.0, chains = [], refused = {}}
	for e in route.elements:
		# Contiguous turn support can overlap; real cross-section and turn safety decide, not a jump recovery quota.
		if e.profile in [T.BERM, T.S_BERM]: continue
		if not C.fits(route, e, ground, state, settings.get("mandatory_gaps", false), float(settings.get("modification", 0.5))): errors.append(state.refused.duplicate(true))
	return errors

static func support_check(route: TrailDefinition, e: TrailElement, evaluation: Dictionary) -> Dictionary:
	var from := maxf(0, e.station - e.length * 0.5 - 16)
	var to := minf(route.route_length(), e.station + e.length * 0.5 + 16)
	var issues := []
	for issue: Dictionary in evaluation.get("ride", {}).get("issues", []):
		if issue.assessment != "safety": continue
		for sample: Dictionary in issue.get("samples", []):
			if sample.station >= from and sample.station <= to: issues.append({scenario = issue.scenario, station = sample.station, reason = issue.reason, deviation = sample.metrics.get("deviation", 0)})
	return {checked_without_element = true, from = from, to = to, safe_without = issues.is_empty(), issues = issues}

static func fit(input: GI, route: TrailDefinition, settings := {}) -> Dictionary:
	var proposals: Array[TrailElement] = []
	for e in route.elements: proposals.append(e.duplicate(true) as TrailElement)
	var bare := route.duplicate(true) as TrailDefinition
	bare.elements.clear()
	var base := A.evaluate(input, bare)
	var report := {accepted = false, base = A.without_runtime(base), decisions = [], bake_count = 1, budget = MAX_BAKES,
		max_variants = MAX_VARIANTS, proposed = proposals.size(), kept = 0, declined = 0, unresolved_support = []}
	if not base.has("_heights"):
		report.reason = "база не собралась"; return report
	var current := base
	var working := bare.duplicate(true) as TrailDefinition
	var ground := func(p: Vector2) -> float: return (base._heights as Heightfield).ground_at(p.x, p.y)
	# Turn support goes first, including every auto-berm; optional features use the resulting surface.
	var order := []
	for i in proposals.size():
		if proposals[i].profile in [T.BERM, T.S_BERM, T.NORTHSHORE]: order.append(i)
	for i in proposals.size():
		if i not in order: order.append(i)
	for index: int in order:
		var e := proposals[index]
		var decision := {proposal = index, original = A.element_record(e), trials = [], accepted = false}
		var best_route: TrailDefinition
		var best_evaluation := {}
		var best_risk := INF
		var trials := variants(e)
		for variant in trials:
			if report.bake_count >= MAX_BAKES - 1: break
			var candidate := working.duplicate(true) as TrailDefinition
			candidate.elements.append(variant)
			candidate.elements.sort_custom(func(a: TrailElement, b: TrailElement) -> bool: return a.station < b.station)
			var definition_errors := candidate.validate()
			var spacing := sequence_errors(candidate, ground, settings)
			if not definition_errors.is_empty() or not spacing.is_empty():
				decision.trials.append({element = A.element_record(variant), accepted = false, definition_errors = Array(definition_errors), sequence_errors = spacing})
				continue
			var evaluated := A.evaluate(input, candidate, base._heights)
			report.bake_count += 1
			var score := risk(evaluated.get("ride", {}))
			var comparison := A.ride_comparison(current.get("ride", {}), evaluated.get("ride", {}))
			var worsened := false
			for issue: Dictionary in comparison:
				if issue.assessment == "safety" and (not issue.new_stations.is_empty() or issue.max_added_deviation > 0.001): worsened = true
			var corrective := e.profile in [T.BERM, T.S_BERM] and score < risk(current.ride) - 0.01
			for issue: Dictionary in evaluated.get("ride", {}).get("issues", []):
				if issue.assessment == "safety" and issue.reason != "не хватает торможения перед поворотом/элементом": corrective = false
			var legal: bool = evaluated.get("earthworks", {}).get("accepted", false) and (evaluated.get("ride", {}).get("accepted", false) or (not worsened and score <= risk(current.ride) + 0.001) or corrective)
			decision.trials.append({element = A.element_record(variant), eligible = legal, accepted = evaluated.get("accepted", false), earthworks = evaluated.get("earthworks", {}),
				ride = A.without_runtime(evaluated).get("ride", {}), ride_comparison = comparison, risk = score})
			if legal and score < best_risk:
				best_risk = score; best_route = candidate; best_evaluation = evaluated
			if legal and evaluated.ride.accepted: break
		if best_route != null:
			working = best_route
			current = best_evaluation
			decision.accepted = true
			decision.selected = decision.trials.filter(func(trial: Dictionary) -> bool: return trial.get("eligible", false) and trial.get("risk", INF) == best_risk)[0].element
			report.kept += 1
		else:
			report.declined += 1
			decision.reason = "нет допустимого варианта в ограниченном бюджете"
			if e.profile in [T.BERM, T.S_BERM, T.NORTHSHORE]:
				decision.support = support_check(working, e, current)
				if not decision.support.safe_without: report.unresolved_support.append({proposal = index, support = decision.support})
		report.decisions.append(decision)
	# A full final bake/ride check remains mandatory after all combinations and all refusals.
	route.elements.assign(working.elements)
	var final := A.evaluate(input, route, base._heights)
	report.bake_count += 1
	report.final = A.without_runtime(final)
	report.accepted = final.accepted
	var unresolved := []
	for entry: Dictionary in report.unresolved_support:
		var checked := support_check(route, proposals[entry.proposal], final)
		if not checked.safe_without: unresolved.append({proposal = entry.proposal, support = checked})
	report.unresolved_support = unresolved
	if not report.accepted: report.reason = "итоговая поверхность или проезд не прошли проверку"
	return report
