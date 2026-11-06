extends RefCounted
## Shared trail character and feature placement contracts.
const S := preload("res://scripts/trails/trail_standards.gd")
const T := TrailElement.Profile
const CHARACTER := {
	flow = {moods = {flow = 6, rest = 2, jump = 1}, density = 0.65},
	downhill = {moods = {tech = 3, jump = 2, forest = 1, rest = 1}, density = 0.65},
	enduro = {moods = {forest = 4, tech = 2, rest = 2, flow = 1, cruise = 2}, density = 0.5},
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
	p.adaptive = true
	# Подготовленные трассы (парк, flow) — ритмичный заезд: связки и интервал во времени (TrailComposer.FOLLOW, _beat).
	p.rhythm = style == "park" or style == "flow"
	# Горные характеры читают природный рельеф (уступы, неровность, боковой уклон, шпильки): TrailComposer._terrain_scan
	p.terrain = style in ["downhill", "enduro", "tech"]
	# Construction amount biases proposals continuously; only explicit zero disables earthworks.
	p.density *= lerpf(0.65, 1.0, modification)
	return p

## Характер одной трассы (темп, извилистость, насыщенность, смещение сложности, чуткость к рельефу, наклон фраз) по сиду: две трассы
## одного типа едут по-разному, но состав настроений и размеры элементов остаются своими у типа. Границы узкие — тип узнаётся.
static func persona(seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("persona|%d" % seed_value)
	var p := {seed = rng.randi(), tempo = rng.randf_range(0.88, 1.14), wander = rng.randf_range(0.7, 1.45), density = rng.randf_range(0.75, 1.3),
		shift = rng.randf_range(-0.1, 0.1), gain = rng.randf_range(0.6, 1.6), tilt = rng.randf_range(-0.2, 0.2)}
	var words := PackedStringArray()
	words.append("быстрая" if p.tempo > 1.06 else ("неспешная" if p.tempo < 0.94 else "ровная"))
	if p.density > 1.12: words.append("насыщенная")
	elif p.density < 0.88: words.append("просторная")
	if p.wander > 1.2: words.append("извилистая")
	elif p.wander < 0.85: words.append("прямая")
	if p.gain > 1.3: words.append("по рельефу")
	p.name = ", ".join(words)
	return p

static func gap_allowed(_style: String, _difficulty: float, modification: float, requested: bool) -> bool:
	# Opt-in is a rider choice. Style and difficulty select sizes, not permission to build.
	return requested and modification > 0.0

## Reserve acceleration, landing and recovery BEFORE accepting a feature, including the next turn.
static func fits(d: TrailDefinition, e: TrailElement, ground: Callable, state: Dictionary, allow_gaps: bool, modification: float) -> bool:
	var from := e.station - e.length * 0.5
	var to := e.station + e.length * 0.5
	var jump := e.profile in [T.TABLETOP, T.GAP, T.DROP]
	# Speed already includes acceleration on the approach. A second fixed run-up quota
	# would refuse a small feature even when its actual entry speed is sufficient.
	var approach := 0.0
	var reason := ""
	if modification <= 0.001 and not TrailElement.places_objects(e.profile): reason = "земляные элементы выключены"
	elif e.profile == T.GAP and not allow_gaps: reason = "обязательный гэп не разрешён настройками"
	elif from - approach < float(state.get("recovery", 0.0)): reason = "нет места для разгона после предыдущего элемента"
	var recovery := float(state.get("recovery", 0.0))
	if reason.is_empty() and (jump or TrailElement.places_objects(e.profile)):
		if not state.has("speeds"):
			state.speeds = S.profile_from(d, S.line_heights(d, ground), 2, {}, false)
		var speeds: PackedFloat32Array = state.speeds
		var v := speeds[clampi(floori(from), 0, speeds.size() - 1)]
		var grade := S.grade_of(d, ground, from, to)
		var w := S.window(e, d, grade, 2)
		v = minf(v, float(w.get("speed_hi", v)))
		recovery = maxf(to, float(w.get("land_to", to))) + S.recovery_distance(v, jump)
		# Curvature is checked at the actual flight/turn speed, not against a fixed radius.
		if recovery > d.route_length(): reason = "нет выката после связки"
	if not reason.is_empty():
		state.refused[reason] = int(state.refused.get(reason, 0)) + 1
		return false
	state.recovery = recovery
	state.chains.append({from = maxf(0.0, from - approach), element_from = from, element_to = to, recovery_to = recovery, profile = e.profile})
	return true

static func describe(d: TrailDefinition, ground: Callable) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var speeds := S.profile_from(d, S.line_heights(d, ground), 2, {}, false)
	for e in d.elements:
		var from := e.station - e.length * 0.5
		var to := e.station + e.length * 0.5
		var jump := e.profile in [T.TABLETOP, T.GAP, T.DROP]
		var w := S.window(e, d, S.grade_of(d, ground, from, to), 2) if jump else {}
		var v := speeds[clampi(floori(from), 0, speeds.size() - 1)]
		var recovery := maxf(to, float(w.get("land_to", to))) + (S.recovery_distance(v, jump) if jump or TrailElement.places_objects(e.profile) else 0.0)
		var turn := recovery
		while turn < d.route_length() and absf(d.curvature_at(turn)) < 1.0 / 40.0: turn += 2.0
		result.append({from = from, element_from = from, element_to = to,
			recovery_to = recovery, turn_after = minf(turn, d.route_length()), profile = e.profile})
	return result
