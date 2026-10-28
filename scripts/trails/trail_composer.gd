class_name TrailComposer
extends RefCounted
## One composer for every kind of bike line. A route is cut into sections; each section gets a mood
## (flow, jumps, technical, forest, rest) and a difficulty, then is filled with library elements.
## Trail profiles are data only: mood weights, a difficulty band, density and section length.
## Deterministic in (route, profile, seed, ground); one pass over the route length, no search.

const T := TrailElement.Profile
## Section moods. `elements` — weights of straight features; `turns` — what goes into a turn (empty: leave it);
## `gap` scales the spacing; `slope` > 0 prefers descents, < 0 climbs; `ease` scales the difficulty;
## `calm` — the section lets the rider recover after a hard one.
const MOODS := {
	flow = {title = "Поток", elements = {T.ROLLER: 3, T.WAVES: 2, T.ROLLOVER: 2, T.DIP: 1, T.PUMP: 1}, turns = [T.BERM], gap = 1.0, slope = 1.0, ease = 1.0},
	jump = {title = "Прыжки", elements = {T.TABLETOP: 3, T.ROLLER: 2, T.DROP: 1}, turns = [T.BERM], gap = 1.3, slope = 0.6, ease = 1.0},
	tech = {title = "Техника", elements = {T.ROCK_GARDEN: 3, T.ROOTS: 2, T.SLALOM: 2, T.NARROW: 1, T.LOG: 1, T.ROUGH: 1}, turns = [T.BERM, T.OFF_CAMBER], gap = 0.8, slope = 0.0, ease = 1.0},
	forest = {title = "Лес", elements = {T.ROOTS: 3, T.RUTS: 2, T.ROUGH: 2, T.LOG: 1, T.NARROW: 1, T.ROLLER: 1, T.DIP: 1}, turns = [], gap = 0.9, slope = 0.0, ease = 0.9},
	rest = {title = "Отдых", elements = {T.RIPPLES: 1, T.DIP: 1, T.ROLLOVER: 1}, turns = [], gap = 2.2, slope = -1.0, ease = 0.5, calm = true},
	# First elements on a line found over real terrain: only small earthworks, wide spacing.
	calm = {title = "Спокойный поток", elements = {T.ROLLER: 2, T.DIP: 1}, turns = [T.BERM], gap = 1.6, slope = 0.0, ease = 1.0, calm = true},
}
## Trail profiles. `difficulty` — band over the route arc; `section` — section length range, m;
## `route` — settings the lab applies to the definition (width, auto_bank).
const PROFILES := {
	flow = {title = "Плавная скоростная", difficulty = Vector2(0.35, 0.75), density = 0.75, section = Vector2(80, 130), moods = {flow = 4, jump = 2, rest = 1}, route = {width = 5.0, auto_bank = 1.0}},
	technical = {title = "Техническая", difficulty = Vector2(0.4, 0.85), density = 0.8, section = Vector2(60, 100), moods = {tech = 4, forest = 1, flow = 1, rest = 1}, route = {width = 4.0, auto_bank = 0.6}},
	forest = {title = "Лесная", difficulty = Vector2(0.3, 0.65), density = 0.6, section = Vector2(60, 110), moods = {forest = 4, flow = 1, rest = 2}, route = {width = 4.0, auto_bank = 0.5}},
	mountain = {title = "Горная", difficulty = Vector2(0.45, 0.9), density = 0.65, section = Vector2(70, 120), moods = {tech = 3, jump = 1, flow = 1, rest = 1}, route = {width = 4.0, auto_bank = 0.2}},
	leisure = {title = "Прогулочная", difficulty = Vector2(0.1, 0.3), density = 0.35, section = Vector2(100, 160), moods = {rest = 3, flow = 1}, route = {width = 4.0, auto_bank = 0.5}},
	mixed = {title = "Смешанная", difficulty = Vector2(0.3, 0.8), density = 0.65, section = Vector2(60, 110), moods = {flow = 2, jump = 1, tech = 2, forest = 2, rest = 1}, route = {width = 5.0, auto_bank = 0.6}},
	calm_flow = {title = "Спокойный flow", difficulty = Vector2(0.0, 0.2), density = 0.5, section = Vector2(60, 120), moods = {calm = 1}, route = {width = 3.0, auto_bank = 1.0}},
}
const LEAD_IN := 22.0
const RUN_OUT := 18.0
## Free ground between two sections of different mood, m: the change of pace reads as a transition.
const TRANSITION := 10.0
## Extra straight run before a jump or a drop, m.
const APPROACH := 8.0

static func titles() -> PackedStringArray:
	var result := PackedStringArray()
	for key: String in PROFILES: result.append(PROFILES[key].title)
	return result

## Elements and sections for a route. `ground(Vector2) -> float` (natural terrain, m) is optional: without it
## the route is treated as level. Sections are {from, to, mood, difficulty}.
## `fits(element) -> bool` is optional: the caller's check of a proposed element against the real line (its finished
## profile before elements); a refused element is skipped like one that does not fit the section.
static func compose(d: TrailDefinition, profile: Dictionary, seed_value: int, ground := Callable(), fits := Callable()) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var elements: Array[TrailElement] = []
	var sections: Array[Dictionary] = []
	var total := d.route_length()
	var band: Vector2 = profile.difficulty
	var density: float = profile.density
	var cursor := LEAD_IN
	var mood := ""
	var hard := false
	var placed_object := -100.0 # end of the last object-placing feature: they keep a recovery gap
	while cursor < total - RUN_OUT - 10.0:
		var span := rng.randf_range(profile.section.x, profile.section.y)
		var end := minf(cursor + span, total - RUN_OUT)
		if total - RUN_OUT - end < profile.section.x * 0.5: end = total - RUN_OUT # no stub section at the end
		var next := _pick_mood(profile.moods, mood, hard, _grade(d, ground, cursor, end), rng)
		if mood != "" and next != mood: cursor += TRANSITION
		mood = next
		var m: Dictionary = MOODS[mood]
		# Difficulty arc: warm-up, peak near three quarters of the route, a softer finish.
		var t := (cursor + end) * 0.5 / total
		var arc := smoothstep(0.0, 0.3, t) * (1.0 - 0.45 * smoothstep(0.8, 1.0, t))
		var difficulty := lerpf(band.x, band.y, arc) * float(m.ease)
		hard = difficulty > (band.x + band.y) * 0.5 and not m.get("calm", false)
		sections.append({from = cursor, to = end, mood = mood, difficulty = snappedf(difficulty, 0.01)})
		var last := -1
		while cursor < end:
			var e := _element(d, m, cursor, end, difficulty, last, rng)
			if e == null:
				cursor += 4.0
				continue
			if TrailElement.places_objects(e.profile) and cursor < placed_object + 5.0:
				cursor = placed_object + 5.0
				continue
			if fits.is_valid() and not fits.call(e):
				cursor += 4.0
				continue
			elements.append(e)
			last = e.profile
			var finish := e.station + e.length * 0.5
			if TrailElement.places_objects(e.profile): placed_object = finish
			cursor = finish + rng.randf_range(7.0, 18.0) * float(m.gap) / maxf(density, 0.2)
		cursor = maxf(cursor, end)
	return {elements = elements, sections = sections}

## Weighted mood choice: never the same mood twice in a row when there is another; a hard section
## makes a calm one likelier; the terrain grade favours moods that suit it.
static func _pick_mood(weights: Dictionary, previous: String, hard: bool, grade: float, rng: RandomNumberGenerator) -> String:
	var keys: Array = weights.keys()
	var sum := 0.0
	var scaled := []
	for key: String in keys:
		var m: Dictionary = MOODS[key]
		var w := float(weights[key])
		if key == previous and keys.size() > 1: w *= 0.15
		if hard and m.get("calm", false): w *= 3.0
		# Descent is negative grade: slope > 0 likes it, slope < 0 likes climbs. ±8 % doubles or halves.
		w *= pow(2.0, clampf(-grade / 0.08, -1.0, 1.0) * float(m.slope))
		scaled.append(w)
		sum += w
	var roll := rng.randf() * sum
	for i in keys.size():
		roll -= scaled[i]
		if roll <= 0.0: return keys[i]
	return keys[-1]

## One element at `cursor` or null when nothing fits here (the caller moves on).
static func _element(d: TrailDefinition, m: Dictionary, cursor: float, end: float, difficulty: float, last: int, rng: RandomNumberGenerator) -> TrailElement:
	var turn := _turn_at(d, cursor, 14.0)
	var kind: int
	if absf(turn) > 0.012:
		var turns: Array = m.turns
		if turns.is_empty(): return null
		kind = turns[rng.randi() % turns.size()]
	else:
		kind = _weighted(m.elements, rng)
		if kind == last: kind = _weighted(m.elements, rng)
		if kind == T.TABLETOP or kind == T.DROP: cursor += APPROACH
	var size := TrailElementLibrary.sized(kind, difficulty * rng.randf_range(0.7, 1.0))
	var count := 1
	var length := size.x
	if kind == T.WAVES or kind == T.PUMP:
		count = rng.randi_range(3, 5)
		length *= count
	if cursor + length > end: return null
	var bends := kind == T.BERM or kind == T.OFF_CAMBER
	# Straight features stay straight over their whole length; long ones shrink to a roller first.
	if not bends and not TrailElement.places_objects(kind) and _sharpest(d, cursor, length) > 0.025:
		if length <= 12.0: return null
		kind = T.ROLLER
		size = TrailElementLibrary.sized(kind, difficulty * rng.randf_range(0.7, 1.0))
		length = size.x
		count = 1
		if _sharpest(d, cursor, length) > 0.025: return null
	var e := TrailElementLibrary.make(kind, cursor + length * 0.5, length, size.y, signf(turn) if bends else 1.0, count, rng.randf_range(0.28, 0.45))
	e.seed = rng.randi() % 10000
	e.density = rng.randf_range(0.35, 0.7)
	e.lines = rng.randi_range(1, 3) if difficulty < 0.7 else 2
	e.gap = lerpf(2.0, 1.2, difficulty)
	if kind == T.LOG:
		e.count = rng.randi_range(1, 3)
		e.gap = clampf(e.gap, 1.0, d.width * 0.5 - 0.3)
	if kind == T.SLALOM: e.count = rng.randi_range(3, 5)
	if kind == T.NARROW: e.gap = clampf(e.gap, 1.0, d.width - 0.6)
	return e

static func _weighted(weights: Dictionary, rng: RandomNumberGenerator) -> int:
	var sum := 0.0
	for key in weights: sum += float(weights[key])
	var roll := rng.randf() * sum
	for key in weights:
		roll -= float(weights[key])
		if roll <= 0.0: return key
	return weights.keys()[-1]

## Mean natural grade along the route between two stations (negative: downhill).
static func _grade(d: TrailDefinition, ground: Callable, from: float, to: float) -> float:
	if not ground.is_valid() or to - from < 1.0: return 0.0
	return (float(ground.call(d.point_at(to))) - float(ground.call(d.point_at(from)))) / (to - from)

## Strongest curvature (1/m) anywhere over `span` metres from `from`.
static func _sharpest(d: TrailDefinition, from: float, span: float) -> float:
	var peak := 0.0
	var at := from
	while at <= from + span:
		peak = maxf(peak, absf(d.curvature_at(at)))
		at += 2.0
	return peak

## Mean signed curvature over a window starting at `from`; the sign says which side is the outside.
static func _turn_at(d: TrailDefinition, from: float, window: float) -> float:
	var sum := 0.0
	for i in 5: sum += d.curvature_at(from + window * i / 4.0)
	return sum / 5.0
