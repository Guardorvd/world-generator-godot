class_name TrailComposer
extends RefCounted
const TrailStandards := preload("res://scripts/trails/trail_standards.gd")
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
	# std_elements — веса с расчётными стандартами (гэп ставится только по стандарту: без него размер не согласован со скоростью)
	jump = {title = "Прыжки", elements = {T.TABLETOP: 3, T.ROLLER: 2, T.DROP: 1}, std_elements = {T.TABLETOP: 4, T.ROLLER: 1, T.DROP: 2, T.GAP: 2}, turns = [T.BERM], gap = 1.3, slope = 0.6, ease = 1.0},
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
## `profile.standards` (01.11): элементы по расчётным стандартам TrailStandards — размер каждого под скорость седока
## в этом месте (профиль скорости по земле и поворотам) и уровень участка; техника — только где скорость не выше
## стандарта уровня или перед ней есть место затормозить. Без ключа — прежние размеры TrailElementLibrary.RANGE
## (так ставит, например, велопарк мира: его трассы запекаются в мир, и мир не меняется).
static func compose(d: TrailDefinition, profile: Dictionary, seed_value: int, ground := Callable(), fits := Callable()) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var std := {}
	if profile.get("standards", false):
		var band0: Vector2 = profile.difficulty
		var mid := clampi(int((band0.x + band0.y) * 0.5 * 4.0), 0, 3)
		var heights := TrailStandards.line_heights(d, ground)
		std = {heights = heights, level = mid, caps = {}, speeds = TrailStandards.profile_from(d, heights, mid, {}, false), ground = ground, last_end = 0.0, placed = 0, refused = {}}
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
			var e := _element(d, m, cursor, end, difficulty, last, rng, std)
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
			if not std.is_empty():
				std.last_end = finish
				std.placed += 1
			if TrailElement.places_objects(e.profile): placed_object = finish
			cursor = finish + rng.randf_range(7.0, 18.0) * float(m.gap) / maxf(density, 0.2)
		cursor = maxf(cursor, end)
	if not std.is_empty(): _berm_turns(d, elements, std)
	var result := {elements = elements, sections = sections}
	if not std.is_empty():
		result.speeds = std.speeds
		result.refused = std.refused
		result.berms = std.get("berms", 0)
	return result

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
static func _element(d: TrailDefinition, m: Dictionary, cursor: float, end: float, difficulty: float, last: int, rng: RandomNumberGenerator, std := {}) -> TrailElement:
	var turn := _turn_at(d, cursor, 14.0)
	var kind: int
	# поворот — туже R 83 м; под стандартами — туже R 33 м: пологая дуга сгенерированной линии годится под прыжок
	if absf(turn) > (0.012 if std.is_empty() else TURN_STD):
		var turns: Array = m.turns
		if turns.is_empty(): return null
		kind = turns[rng.randi() % turns.size()]
	else:
		var weights: Dictionary = m.elements if std.is_empty() else m.get("std_elements", m.elements)
		kind = _weighted(weights, rng)
		if kind == last: kind = _weighted(weights, rng)
		if kind == T.TABLETOP or kind == T.DROP: cursor += APPROACH
	var size := TrailElementLibrary.sized(kind, difficulty * rng.randf_range(0.7, 1.0))
	var count := 1
	var length := size.x
	var gap := -1.0
	if kind == T.WAVES or kind == T.PUMP:
		count = rng.randi_range(3, 5)
		length *= count
	if not std.is_empty():
		var sized := _standard(d, kind, cursor, end, difficulty, std, count, size)
		if sized.is_empty(): return null
		kind = sized.profile
		size = Vector2(sized.length, sized.height)
		length = sized.length
		count = int(sized.get("count", count))
		gap = float(sized.get("gap", -1.0))
	if cursor + length > end:
		if not std.is_empty() and kind in [T.TABLETOP, T.GAP, T.DROP]: _refuse(std, "прыжок: не помещается в участок")
		return null
	var bends := kind == T.BERM or kind == T.OFF_CAMBER
	# Straight features stay straight over their whole length; long ones shrink to a roller first.
	# стандарты: стол, гэп и дроп — и на пологой дуге (R ≥ 1/JUMP_BEND: боковая перегрузка на их скорости в пределах)
	var straight := JUMP_BEND if not std.is_empty() and kind in [T.TABLETOP, T.GAP, T.DROP] else 0.025
	if not bends and not TrailElement.places_objects(kind) and _sharpest(d, cursor, length) > straight:
		if not std.is_empty() and kind in [T.TABLETOP, T.GAP, T.DROP]: _refuse(std, "прыжок: дуга туже R 25 м")
		if length <= 12.0: return null
		kind = T.ROLLER
		size = TrailElementLibrary.sized(kind, difficulty * rng.randf_range(0.7, 1.0))
		if not std.is_empty():
			var roller := _standard(d, T.ROLLER, cursor, end, difficulty, std, 1, size)
			if roller.is_empty(): return null
			size = Vector2(roller.length, roller.height)
		length = size.x
		count = 1
		gap = -1.0
		if _sharpest(d, cursor, length) > 0.025: return null
	var e := TrailElementLibrary.make(kind, cursor + length * 0.5, length, size.y, signf(turn) if bends else 1.0, count, rng.randf_range(0.28, 0.45))
	e.seed = rng.randi() % 10000
	e.density = rng.randf_range(0.35, 0.7)
	e.lines = rng.randi_range(1, 3) if difficulty < 0.7 else 2
	e.gap = lerpf(2.0, 1.2, difficulty) if gap < 0.0 else gap
	if kind == T.LOG:
		e.count = rng.randi_range(1, 3)
		e.gap = clampf(e.gap, 1.0, d.width * 0.5 - 0.3)
	if kind == T.SLALOM: e.count = rng.randi_range(3, 5)
	if kind == T.NARROW: e.gap = clampf(e.gap, 1.0, d.width - 0.6)
	return e

## Размеры элемента kind у cursor по TrailStandards: скорость седока в этом месте, уровень по сложности участка.
## Прыжок, который на этой скорости не получается (гэп ниже красной, стол без длины), становится столом или роллером;
## техника при скорости выше стандарта уровня ставится, только если до неё есть место для торможения после прошлого
## элемента — тогда в профиль скорости добавляется предел, и дальше элементы считаются уже с торможением.
## Пусто — здесь ничего не ставить (причина в std.refused).
static func _standard(d: TrailDefinition, kind: int, cursor: float, end: float, difficulty: float, std: Dictionary, count: int, size: Vector2) -> Dictionary:
	var level := clampi(int(difficulty * 4.0), 0, 3)
	var speeds: PackedFloat32Array = std.speeds
	var v := speeds[clampi(int(cursor), 0, speeds.size() - 1)]
	var grade := TrailStandards.element_grade(d, std.ground, cursor)
	var key := {T.TABLETOP: "table", T.GAP: "gap", T.DROP: "drop", T.ROLLER: "roller", T.PUMP: "pump"}
	if key.has(kind):
		for k: String in ([key[kind]] + (["table", "roller"] if kind in [T.GAP, T.TABLETOP] else (["roller"] if kind == T.DROP else []))):
			var s := TrailStandards.spec(k, snappedf(v, 0.5), level, grade)
			# на краях модели подбор длины и окно скорости расходятся: прыжок — только если седок в его окне
			if not s.is_empty() and s.has("speed_lo") and (v < float(s.speed_lo) - 0.5 or v > float(s.get("speed_hi", INF)) + 0.5):
				var why := "прыжок: скорость вне окна"
				std.refused[why] = int(std.refused.get(why, 0)) + 1
				continue
			if not s.is_empty(): return s
		std.refused[TrailElementLibrary.title(kind)] = int(std.refused.get(TrailElementLibrary.title(kind), 0)) + 1
		return {}
	match kind:
		T.WAVES:
			var step := clampf(TrailStandards.pump_step(v, size.y), RoadRefinement.STEP * 8.5, 12.0) # волна короче 8 шагов сетки не держится
			return {profile = kind, length = snappedf(step * count, 0.1), height = size.y, count = count}
		T.BERM, T.OFF_CAMBER, T.S_BERM:
			var radius := TrailStandards.tightest(d, cursor, cursor + size.x)
			# контруклон отнимает сцепление: только где медленно, иначе обычный вираж (01.11: на 15 м/с — вылеты)
			if kind == T.OFF_CAMBER and v > OFF_CAMBER_SPEED: kind = T.BERM
			var h := TrailStandards.berm_height(v, radius, level, d.width) if is_finite(radius) else size.y
			return {profile = kind, length = size.x, height = clampf(h if is_finite(h) else 1.2, 0.3, 1.2) if kind != T.OFF_CAMBER else minf(size.y, 0.5)}
	if TrailElement.places_objects(kind) or kind in [T.ROUGH, T.RUTS]:
		var limit: float = TrailStandards.TECH_SPEED[level]
		if kind == T.LOG: limit = minf(limit, TrailStandards.LOG_SPEED)
		# 01.11: только где седок и без торможения не быстрее стандарта — заранее не тормозят (бревно на 12,6 м/с
		# после поворота уронило через руль)
		if v > limit + 0.5:
			var why := "техника: здесь быстрее %.0f м/с" % limit
			std.refused[why] = int(std.refused.get(why, 0)) + 1
			return {}
		var h := size.y
		if TrailStandards.TECH_HEIGHTS.has(kind): h = TrailStandards.tech_height(kind, level)
		return {profile = kind, length = size.x, height = h}
	return {profile = kind, length = size.x, height = size.y, count = count}

static func _refuse(std: Dictionary, why: String) -> void:
	std.refused[why] = int(std.refused.get(why, 0)) + 1

## Под стандартами место — поворот (вираж), если средняя кривизна туже этого (1/м, R 33 м).
const TURN_STD := 0.03
## Под стандартами прыжок ставится на дуге не туже этого (1/м, R 25 м).
const JUMP_BEND := 0.04
## Контруклон под стандартами — только медленнее этого, м/с.
const OFF_CAMBER_SPEED := 9.0
## Поворот оси туже этого радиуса проверяется на вираж, м.
const BERM_CHECK := 40.0

## Виражи в поворотах без своего элемента, которые на скорости седока («как едут») не пройти без наклона: высота —
## TrailStandards.berm_height под скорость и радиус (01.11: на сгенерированных трассах 2/3 поворотов R ≈ 10 м были без
## виража, вылеты наружу и падение с откоса). Не пересекаются с другими элементами.
static func _berm_turns(d: TrailDefinition, elements: Array[TrailElement], std: Dictionary) -> void:
	var length := d.route_length()
	var speeds: PackedFloat32Array = std.speeds
	var shape := d.shape()
	var added := 0
	var at := 4.0
	while at < length - 4.0:
		if absf(d.curvature_at(at)) < 1.0 / BERM_CHECK:
			at += 1.0
			continue
		var sign := signf(d.curvature_at(at))
		var from := at
		while at < length - 4.0 and absf(d.curvature_at(at)) >= 0.7 / BERM_CHECK and signf(d.curvature_at(at)) == sign: at += 1.0
		var radius := TrailStandards.tightest(d, from, at)
		# скорость на подходе: внутри поворота профиль уже срезан до его предела
		var v := 0.0
		for k in range(maxi(0, int(from) - 8), mini(speeds.size(), int(from) + 1)): v = maxf(v, speeds[k])
		var route_bank := minf(absf(d.curvature_at((from + at) * 0.5)) * shape.bank_gain, shape.bank_max) * d.auto_bank
		var level := int(std.level)
		if not is_finite(radius) or v <= TrailStandards.turn_speed(radius, route_bank, float(TrailStandards.LEVELS[level].lat)) + 0.5:
			at += 2.0
			continue
		# длинный поворот — вираж 30 м на самом тугом месте
		var tight := from
		for k in range(int(from), int(at) + 1):
			if absf(d.curvature_at(k)) > absf(d.curvature_at(tight)): tight = k
		var lo := maxf(2.0, from - 3.0)
		var hi := minf(length - 2.0, at + 3.0)
		if hi - lo > 34.0:
			lo = maxf(2.0, tight - 15.0)
			hi = minf(length - 2.0, tight + 15.0)
		if hi - lo < 10.0:
			at += 2.0
			continue
		# поворот принадлежит виражу: виражи составителя здесь сливаются в один, прочие элементы (кроме прыжков —
		# их в поворотах нет) уступают место; прыжок в повороте — вираж не ставится
		var merged: Array[TrailElement] = []
		var jump := false
		for e in elements:
			var e_lo := e.station - e.length * 0.5
			var e_hi := e.station + e.length * 0.5
			if e_hi < lo - 2.0 or e_lo > hi + 2.0: continue
			if e.profile in [T.TABLETOP, T.GAP, T.DROP]: jump = true
			elif e.profile == T.BERM and signf(e.bank) == sign:
				merged.append(e)
				lo = minf(lo, e_lo)
				hi = maxf(hi, e_hi)
			else:
				merged.append(e)
		if jump:
			std.refused["вираж: в повороте прыжок"] = int(std.refused.get("вираж: в повороте прыжок", 0)) + 1
		else:
			var h := TrailStandards.berm_height(v, radius, level, d.width)
			for e in merged:
				if e.profile == T.BERM: h = maxf(h, e.height)
				elements.erase(e)
			hi = minf(hi, lo + 40.0)
			elements.append(TrailElementLibrary.make(T.BERM, (lo + hi) * 0.5, hi - lo, clampf(h if is_finite(h) else 1.2, 0.4, 1.2), sign))
			added += 1
		at += 2.0
	elements.sort_custom(func(a: TrailElement, b: TrailElement) -> bool: return a.station < b.station)
	std.berms = added

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
