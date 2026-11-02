extends RefCounted
## Lab-only profiles and placement contracts. Shared game composer and its presets stay unchanged.
const S := preload("res://scripts/trails/trail_standards.gd")
const T := TrailElement.Profile
const CHARACTER := {
	flow = {moods = {flow = 6, rest = 2, jump = 1}, density = 0.65},
	downhill = {moods = {tech = 3, jump = 2, forest = 1, rest = 1}, density = 0.65},
	enduro = {moods = {forest = 4, tech = 2, rest = 2, flow = 1}, density = 0.5},
	tech = {moods = {tech = 5, forest = 2, rest = 2}, density = 0.6},
	park = {moods = {flow = 4, jump = 3, rest = 1}, density = 0.8},
}

static func profile_for(style: String, difficulty: float, modification: float) -> Dictionary:
	var p: Dictionary = TrailComposer.PROFILES.flow.duplicate(true)
	var c: Dictionary = CHARACTER[style]
	p.moods = c.moods.duplicate()
	p.density = c.density
	p.section = Vector2(60, 100) if style == "park" else Vector2(70, 130)
	p.difficulty = Vector2(maxf(0.0, difficulty - 0.12), minf(0.99, difficulty + 0.12))
	p.standards = true
	if modification < 0.3:
		p.moods = {forest = 3, rest = 2} if style in ["enduro", "tech", "downhill"] else {calm = 4, rest = 2}
		p.density *= 0.65
	return p

static func gap_allowed(style: String, difficulty: float, modification: float, requested: bool) -> bool:
	return requested and difficulty >= 0.7 and modification >= 0.65 and style in ["flow", "downhill", "park"]

## Reserve acceleration, landing and recovery BEFORE accepting a feature, including the next turn.
static func fits(d: TrailDefinition, e: TrailElement, ground: Callable, state: Dictionary, allow_gaps: bool, modification: float) -> bool:
	var from := e.station - e.length * 0.5
	var to := e.station + e.length * 0.5
	var jump := e.profile in [T.TABLETOP, T.GAP, T.DROP]
	var approach := maxf(8.0, e.height * 5.0) if jump else (6.0 if TrailElement.places_objects(e.profile) else 3.0)
	var reason := ""
	if modification <= 0.001 and not TrailElement.places_objects(e.profile): reason = "земляные элементы выключены"
	elif e.profile == T.GAP and not allow_gaps: reason = "обязательный гэп не разрешён настройками"
	elif modification < 0.3 and jump: reason = "для прыжка недостаточно земляных работ"
	elif modification < 0.3 and not TrailElement.places_objects(e.profile) and e.height > 0.1 + modification * 0.5: reason = "элемент требует слишком большого изменения рельефа"
	elif from - approach < float(state.get("recovery", 0.0)): reason = "нет места для разгона после предыдущего элемента"
	var recovery := to + 5.0
	if reason.is_empty() and jump:
		var grade := S.grade_of(d, ground, from, to)
		var w := S.window(e, d, grade, 2)
		recovery = maxf(to, float(w.get("land_to", to))) + maxf(8.0, float(w.get("speed_ideal", 10.0)) * 0.8)
		if S.tightest(d, from - approach, recovery) < 40.0: reason = "нет связки разгон → приземление → восстановление до поворота"
		elif recovery > d.route_length() - 8.0: reason = "нет выката после связки"
	if not reason.is_empty():
		state.refused[reason] = int(state.refused.get(reason, 0)) + 1
		return false
	state.recovery = recovery
	state.chains.append({from = maxf(0.0, from - approach), element_from = from, element_to = to, recovery_to = recovery, profile = e.profile})
	return true

static func describe(d: TrailDefinition, ground: Callable) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for e in d.elements:
		var from := e.station - e.length * 0.5
		var to := e.station + e.length * 0.5
		var jump := e.profile in [T.TABLETOP, T.GAP, T.DROP]
		var w := S.window(e, d, S.grade_of(d, ground, from, to), 2) if jump else {}
		var recovery := maxf(to, float(w.get("land_to", to))) + (maxf(8.0, float(w.get("speed_ideal", 10.0)) * 0.8) if jump else 5.0)
		var turn := recovery
		while turn < d.route_length() and absf(d.curvature_at(turn)) < 1.0 / 40.0: turn += 2.0
		result.append({from = maxf(0.0, from - (maxf(8.0, e.height * 5.0) if jump else 6.0)), element_from = from, element_to = to,
			recovery_to = recovery, turn_after = minf(turn, d.route_length()), profile = e.profile})
	return result
