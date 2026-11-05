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
	flow = {title = "Поток", elements = {T.ROLLER: 3, T.WAVES: 2, T.ROLLOVER: 2, T.DIP: 1, T.PUMP: 1}, std_elements = {T.ROLLER: 2, T.TABLETOP: 2, T.PUMP: 2, T.WAVES: 1, T.DROP: 1}, turns = [T.BERM], gap = 1.0, slope = 1.0, ease = 1.0},
	# std_elements — веса с расчётными стандартами (гэп ставится только по стандарту: без него размер не согласован со скоростью)
	jump = {title = "Прыжки", elements = {T.TABLETOP: 3, T.ROLLER: 2, T.DROP: 1}, std_elements = {T.TABLETOP: 4, T.ROLLER: 1, T.DROP: 2, T.GAP: 2}, turns = [T.BERM], gap = 1.3, slope = 0.6, ease = 1.0},
	# std_elements техники и леса — ещё мост-настил (норшор): библиотека его знает, а составитель по стандартам не ставил
	tech = {title = "Техника", elements = {T.ROCK_GARDEN: 3, T.ROOTS: 2, T.SLALOM: 2, T.NARROW: 1, T.LOG: 1, T.ROUGH: 1}, std_elements = {T.ROCK_GARDEN: 3, T.ROOTS: 2, T.SLALOM: 2, T.NARROW: 1, T.LOG: 1, T.ROUGH: 1, T.NORTHSHORE: 1}, turns = [T.BERM, T.OFF_CAMBER], gap = 0.8, slope = 0.0, ease = 1.0},
	forest = {title = "Лес", elements = {T.ROOTS: 3, T.RUTS: 2, T.ROUGH: 2, T.LOG: 1, T.NARROW: 1, T.ROLLER: 1, T.DIP: 1}, std_elements = {T.ROOTS: 3, T.RUTS: 2, T.ROUGH: 2, T.LOG: 1, T.NARROW: 1, T.ROLLER: 1, T.DIP: 1, T.NORTHSHORE: 1}, turns = [], gap = 0.9, slope = 0.0, ease = 0.9},
	rest = {title = "Отдых", elements = {T.RIPPLES: 1, T.DIP: 1, T.ROLLOVER: 1}, turns = [], gap = 2.2, slope = -1.0, ease = 0.5, calm = true},
	# Накат: участок без элементов — полотно и вид; ставится по лесистости и неровности (поляна, гладкий холм), не больше трети маршрута.
	cruise = {title = "Накат", elements = {}, turns = [], gap = 1.0, slope = 0.0, ease = 0.4, calm = true, free = true},
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
		std = {heights = heights, level = mid, adaptive = profile.get("adaptive", false), caps = {}, speeds = TrailStandards.profile_from(d, heights, mid, {}, false), speeds_boost = TrailStandards.profile_from(d, heights, mid, {}, false, true), ground = ground, last_end = 0.0, placed = 0, refused = {}}
		# Ритм (подготовленные трассы): связки по таблице FOLLOW и интервал между элементами во времени, а не в метрах;
		# carry — доля скорости профиля после прошлых элементов (памп разгоняет, вираж и роллер чуть тормозят), streak —
		# сколько элементов подряд без передышки.
		std.rhythm = profile.get("rhythm", false)
		std.carry = 1.0
		std.streak = 0
		std.phrase = [] # оставшиеся виды текущей фразы (PHRASES), по порядку
	# Горные характеры (`profile.terrain`): рельеф вдоль линии по природной земле (`profile.natural`) — уступы, неровность,
	# боковой уклон, шпильки; настроение участка и элементы подбираются под них (см. _terrain_scan)
	var terrain := {}
	if profile.get("terrain", false) and not std.is_empty():
		terrain = _terrain_scan(d, profile.get("natural", ground), profile.get("cover", Callable()))
	var ledge_at := 0 # следующий по линии уступ из terrain.ledges
	var cruised := 0.0 # сколько метров уже отдано накату
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
		# A leg of a longer route (`profile.arc` — its share of the whole): the route has one plan, not one per leg.
		var share: Vector2 = profile.get("arc", Vector2(0.0, 1.0))
		var whole := share != Vector2(0.0, 1.0)
		var last_section := whole and share.y >= 0.999 and end >= total - RUN_OUT - 0.01
		var feat := _section_features(terrain, cursor, end)
		if not feat.is_empty(): feat.cruised = cruised / maxf(cursor, 1.0)
		if not std.is_empty(): std.feat = feat
		var next := _pick_mood(profile.moods, mood, hard, _grade(d, ground, cursor, end), rng, lerpf(share.x, share.y, (cursor + end) * 0.5 / total) if whole else -1.0, last_section, feat)
		if mood != "" and next != mood: cursor += TRANSITION
		if MOODS[next].get("free", false): cruised += end - cursor
		mood = next
		var m: Dictionary = MOODS[mood]
		# Difficulty arc: warm-up, peak near three quarters of the route (or where the terrain peaks), a softer finish.
		var t := (cursor + end) * 0.5 / total
		var arc := smoothstep(0.0, 0.3, t) * (1.0 - 0.45 * smoothstep(0.8, 1.0, t))
		if whole:
			var peak: float = profile.get("peak", 0.75)
			t = lerpf(share.x, share.y, t)
			arc = smoothstep(0.0, peak, t) * (1.0 - 0.45 * smoothstep(peak, 1.0, t))
		var difficulty := lerpf(band.x, band.y, arc) * float(m.ease)
		hard = difficulty > (band.x + band.y) * 0.5 and not m.get("calm", false)
		sections.append({from = cursor, to = end, mood = mood, difficulty = snappedf(difficulty, 0.01)})
		var last := -1
		# фраза переходит в соседний участок flow/прыжков (граница участков условна); перед отдыхом и техникой — сбрасывается
		if std.get("rhythm", false) and not PHRASES.has(mood): std.phrase.clear()
		while cursor < end and not m.get("free", false):
			# Фраза: на flow и прыжках элементы идут связкой (разгон → прыжки → накат), а не по одному
			if std.get("rhythm", false) and std.phrase.is_empty() and PHRASES.has(mood):
				std.phrase = _pick_phrase(mood, difficulty, rng)
			# Природный уступ впереди: дроп встаёт на него (там земля уже падает), а не на случайное место
			std.erase("force")
			std.erase("ledge")
			if not terrain.is_empty():
				var ledges: Array = terrain.ledges
				while ledge_at < ledges.size() and float(ledges[ledge_at]) < cursor + 4.0: ledge_at += 1
				if ledge_at < ledges.size() and float(ledges[ledge_at]) < minf(cursor + LEDGE_REACH, end + OVERRUN) and not m.get("calm", false) and mood != "rest":
					# два дропа подряд — однообразие: после дропа каждый второй уступ остаётся природным
					if not (last == T.DROP and rng.randf() < 0.5):
						std.force = T.DROP
						std.ledge = float(ledges[ledge_at])
					ledge_at += 1
			var e := _element(d, m, cursor, end, difficulty, last, rng, std)
			if std.get("rhythm", false):
				# Ритм: не подошёл элемент — на том же месте пробуется малый универсальный (FALLBACK), а не сдвиг на 4 м,
				# иначе удар приходится на случайное место и такт сбивается
				var fit := _admit(e, cursor, placed_object, fits)
				if not fit:
					std.fallback = true
					e = _element(d, m, cursor, end, difficulty, last, rng, std)
					std.fallback = false
					fit = _admit(e, cursor, placed_object, fits)
				if not fit:
					std.phrase.clear() # место не подошло — фраза сорвана, следующая начнётся заново
					cursor += 4.0
					continue
			else:
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
			if std.get("rhythm", false):
				# вираж в повороте фразу не двигает; любой другой элемент (в том числе запасной) закрывает её очередной шаг
				if not std.phrase.is_empty() and e.profile not in [T.BERM, T.S_BERM, T.OFF_CAMBER]: std.phrase.pop_front()
				cursor = finish + _beat(e, finish, m, difficulty, density, std, rng)
			else:
				cursor = finish + rng.randf_range(7.0, 18.0) * float(m.gap) * (1.0 + float(feat.get("rough", 0.0))) / maxf(density, 0.2) # где рельеф сам неровный, подготовленные элементы реже
				# следующий уступ не пропускается ради случайного интервала: курсор встаёт перед ним (дроп начнётся у уступа)
				if not terrain.is_empty() and ledge_at < terrain.ledges.size():
					var next_ledge: float = terrain.ledges[ledge_at]
					if cursor > next_ledge - 12.0 and next_ledge - APPROACH - 4.0 > finish + 4.0 and next_ledge < end + OVERRUN: cursor = next_ledge - APPROACH - 4.0
		cursor = maxf(cursor, end)
	if not std.is_empty(): _berm_turns(d, elements, std)
	var result := {elements = elements, sections = sections}
	if not std.is_empty():
		result.speeds = std.speeds
		result.refused = std.refused
		result.berms = std.get("berms", 0)
	return result

## — Ритм подготовленной трассы —
## Как следующий элемент подходит к прошлому: множитель веса (последний вид → следующий). Столы идут линией, за приземлением —
## накат, памп и волны разгоняют перед столом, дроп и гэп закрываются роллером или пампом; повтор того же вида реже.
const FOLLOW := {
	T.TABLETOP: {T.TABLETOP: 1.6, T.PUMP: 1.5, T.ROLLER: 1.3, T.WAVES: 1.2, T.DROP: 0.5, T.GAP: 0.6},
	T.GAP: {T.ROLLER: 1.6, T.PUMP: 1.6, T.WAVES: 1.3, T.TABLETOP: 0.4, T.DROP: 0.4, T.GAP: 0.1},
	T.DROP: {T.ROLLER: 1.5, T.PUMP: 1.5, T.WAVES: 1.2, T.TABLETOP: 1.0, T.DROP: 0.3, T.GAP: 0.5},
	T.PUMP: {T.TABLETOP: 1.8, T.DROP: 1.3, T.GAP: 1.3, T.ROLLER: 1.0, T.PUMP: 0.5, T.WAVES: 0.5},
	T.WAVES: {T.TABLETOP: 1.8, T.DROP: 1.3, T.GAP: 1.3, T.ROLLER: 1.0, T.PUMP: 0.6, T.WAVES: 0.4},
	T.ROLLER: {T.TABLETOP: 1.5, T.PUMP: 1.5, T.WAVES: 1.2, T.DROP: 1.2, T.ROLLER: 0.7},
	T.BERM: {T.TABLETOP: 1.4, T.ROLLER: 1.3, T.PUMP: 1.3, T.GAP: 1.2},
	T.S_BERM: {T.TABLETOP: 1.4, T.ROLLER: 1.3, T.PUMP: 1.3},
}
## Что элемент делает со скоростью седока на выходе (доля скорости профиля): памп разгоняет, роллер, вираж и рябь тормозят.
const CARRY := {T.PUMP: 1.06, T.WAVES: 1.03, T.ROLLER: 0.98, T.ROLLOVER: 0.98, T.DIP: 0.99, T.BERM: 0.97, T.S_BERM: 0.96, T.RIPPLES: 0.97, T.OFF_CAMBER: 0.96}
## Между элементами — столько секунд свободной трассы (на скорости выхода): после прыжка больше, у сложной трассы короче.
const BEAT_JUMP := Vector2(1.3, 0.85)
const BEAT_FLOW := Vector2(1.0, 0.6)
## Столько фраз подряд без передышки (лёгкая трасса, сложная); потом свободная трасса не короче BREATH секунд.
const STREAK := Vector2i(3, 2)
## Время пути между элементами внутри фразы, с: после прыжка (лёгкая, сложная трасса) и после малого элемента.
const LINK_JUMP := Vector2(1.1, 0.75)
const LINK_FLOW := 0.5

## Фразы — осмысленные связки: разгон (памп, волны) → прыжки → накат/приземление. Сложность рождается из связки
## (серия столов, дроп-перепад, гэп после разгона), а не из случайного препятствия. `level` — сложность, под которую
## фраза подходит; `kinds` — виды по порядку. Не подошёл элемент — вместо него малый запасной, фраза идёт дальше.
const PHRASES := {
	flow = [
		{level = 0.15, kinds = [T.ROLLER, T.ROLLER, T.PUMP]},
		{level = 0.3, kinds = [T.PUMP, T.TABLETOP, T.ROLLER]},
		{level = 0.4, kinds = [T.WAVES, T.TABLETOP]},
		{level = 0.55, kinds = [T.PUMP, T.TABLETOP, T.TABLETOP, T.ROLLER]},
		{level = 0.65, kinds = [T.ROLLER, T.DROP, T.PUMP]},
		{level = 0.8, kinds = [T.WAVES, T.TABLETOP, T.TABLETOP, T.DROP, T.ROLLER]},
	],
	jump = [
		{level = 0.3, kinds = [T.PUMP, T.TABLETOP, T.TABLETOP]},
		{level = 0.5, kinds = [T.PUMP, T.TABLETOP, T.DROP, T.ROLLER]},
		{level = 0.7, kinds = [T.PUMP, T.TABLETOP, T.TABLETOP, T.TABLETOP]},
		{level = 0.8, kinds = [T.WAVES, T.TABLETOP, T.GAP, T.ROLLER]},
		{level = 0.9, kinds = [T.PUMP, T.TABLETOP, T.TABLETOP, T.GAP, T.ROLLER]},
	],
}

## Фраза настроения под сложность участка: чем ближе level, тем вероятнее.
static func _pick_phrase(mood: String, difficulty: float, rng: RandomNumberGenerator) -> Array:
	var list: Array = PHRASES[mood]
	var weights := []
	var sum := 0.0
	for p: Dictionary in list:
		var w := exp(-absf(difficulty - float(p.level)) * 5.0)
		weights.append(w)
		sum += w
	var roll := rng.randf() * sum
	for i in list.size():
		roll -= weights[i]
		if roll <= 0.0: return (list[i].kinds as Array).duplicate()
	return (list[-1].kinds as Array).duplicate()
const BREATH := 2.0

## Малые элементы, которые встают почти на любой линии: запасной выбор, когда выбранный не подошёл.
const FALLBACK := {T.ROLLER: 3, T.PUMP: 2, T.WAVES: 1}

## Элемент e годится в cursor: он есть, не вплотную к прошлому элементу с объектами, и его принимает проверка места.
static func _admit(e: TrailElement, cursor: float, placed_object: float, fits: Callable) -> bool:
	if e == null: return false
	if TrailElement.places_objects(e.profile) and cursor < placed_object + 5.0: return false
	return not fits.is_valid() or fits.call(e)

## Веса видов после `last`: FOLLOW в степени 0,5 + сложность (на лёгкой трассе связки мягче, на сложной — выраженнее).
static func _follow(weights: Dictionary, last: int, difficulty: float) -> Dictionary:
	if not FOLLOW.has(last): return weights
	var out := {}
	for kind: int in weights: out[kind] = float(weights[kind]) * pow(float(FOLLOW[last].get(kind, 1.0)), 0.5 + difficulty)
	return out

## Свободная трасса после элемента e (метры) по скорости на выходе; обновляет carry и streak.
static func _beat(e: TrailElement, finish: float, m: Dictionary, difficulty: float, density: float, std: Dictionary, rng: RandomNumberGenerator) -> float:
	var speeds: PackedFloat32Array = std.speeds
	var carry := clampf(float(std.carry) * float(CARRY.get(e.profile, 1.0)), 0.8, 1.15)
	var v := float(speeds[clampi(int(finish), 0, speeds.size() - 1)]) * carry
	var jump := e.profile in [T.TABLETOP, T.GAP, T.DROP]
	var beat := BEAT_JUMP if jump else BEAT_FLOW
	var seconds: float
	if not std.phrase.is_empty():
		# внутри фразы такт ровный (без разброса): столы одной серии стоят через одинаковое время пути
		seconds = lerpf(LINK_JUMP.x, LINK_JUMP.y, clampf(difficulty, 0.0, 1.0)) if jump else LINK_FLOW
	else:
		seconds = lerpf(beat.x, beat.y, clampf(difficulty, 0.0, 1.0)) * float(m.gap) * rng.randf_range(0.85, 1.15) / clampf(density / 0.7, 0.7, 1.3)
		# конец фразы: считаются фразы, а не элементы; после серии фраз — передышка
		std.streak = int(std.streak) + 1
		if m.get("calm", false): std.streak = 0
		if int(std.streak) >= int(lerpf(STREAK.x, STREAK.y, clampf(difficulty, 0.0, 1.0))):
			seconds = maxf(seconds, BREATH)
			std.streak = 0
	var clear := clampf(v * seconds, 6.0, 40.0)
	std.carry = lerpf(carry, 1.0, clampf(clear / 60.0, 0.0, 1.0))
	return clear

## — Рельеф горных характеров —
## Уступ: земля падает не меньше LEDGE_DROP (и втрое быстрее среднего спуска линии) на LEDGE_SPAN м линии; уступы реже LEDGE_EVERY м.
const LEDGE_DROP := 0.7
const LEDGE_SPAN := 6.0
const LEDGE_EVERY := 25.0
## Дроп ставится на уступ, который не дальше этого впереди курсора, м.
const LEDGE_REACH := 30.0
## Неровность (вторая разность высот на шаге 2 м) и боковой уклон участка меряются относительно всей линии: участок со средним
## признаком даёт 0,5, вдвое богаче среднего — 1. Нижние пороги нормы (м, м/м) — на гладкой земле слабый шум не считается рельефом.
const ROUGH_MIN := 0.03
const SIDE_MIN := 0.05
const SHARP_R := 25.0

## Рельеф вдоль линии по природной земле: высоты, боковой уклон (по ±3 м поперёк), крутые повороты (R < SHARP_R, станциями
## через 2 м) и станции уступов. Шаг 2 м; пусто — линия короче 12 м.
static func _terrain_scan(d: TrailDefinition, natural: Callable, cover := Callable()) -> Dictionary:
	var n := int(d.route_length() / 2.0) + 1
	if n < 6: return {}
	var h := PackedFloat32Array()
	var side := PackedFloat32Array()
	var sharp := PackedFloat32Array()
	h.resize(n)
	side.resize(n)
	sharp.resize(n)
	for i in n:
		var s := i * 2.0
		var p := d.point_at(s)
		var t := d.tangent_at(s)
		var o := Vector2(-t.y, t.x) * 3.0
		h[i] = float(natural.call(p))
		side[i] = absf(float(natural.call(p + o)) - float(natural.call(p - o))) / 6.0
		sharp[i] = 1.0 if absf(d.curvature_at(s)) >= 1.0 / SHARP_R else 0.0
	# лесистость и поляна (StageVegetation.cover_at) через 8 м; без неё wood = -1 (неизвестно)
	var wood := PackedFloat32Array()
	var glade := PackedFloat32Array()
	if cover.is_valid():
		wood.resize(n / 4 + 1)
		glade.resize(n / 4 + 1)
		for k in wood.size():
			var c: Vector2 = cover.call(d.point_at(minf(k * 8.0, d.route_length())))
			wood[k] = c.x
			glade[k] = c.y
	var span := int(LEDGE_SPAN / 2.0)
	var need := maxf(LEDGE_DROP, (h[0] - h[n - 1]) / float(n - 1) * LEDGE_SPAN * 0.5 * 2.5)
	var ledges := []
	var i := 0
	while i < n - span:
		if h[i] - h[i + span] >= need:
			var best := i
			var best_drop := h[i] - h[i + span]
			for j in range(i + 1, mini(n - span, i + 6)):
				if h[j] - h[j + span] > best_drop:
					best_drop = h[j] - h[j + span]
					best = j
			ledges.append((best + span * 0.5) * 2.0)
			i = best + int(LEDGE_EVERY / 2.0)
		else:
			i += 1
	var rough_sum := 0.0
	for k in range(1, n - 1): rough_sum += absf(h[k - 1] - 2.0 * h[k] + h[k + 1])
	var side_sum := 0.0
	for k in n: side_sum += side[k]
	return {h = h, side = side, sharp = sharp, ledges = ledges, wood = wood, glade = glade,
		rough_norm = maxf(ROUGH_MIN, 2.0 * rough_sum / float(n - 2)), side_norm = maxf(SIDE_MIN, 2.0 * side_sum / float(n))}

## Признаки участка [from, to]: rough, side, turn — 0..1, ledges — число уступов. Пусто, если рельефа нет.
static func _section_features(terrain: Dictionary, from: float, to: float) -> Dictionary:
	if terrain.is_empty(): return {}
	var h: PackedFloat32Array = terrain.h
	var a := clampi(int(from / 2.0) + 1, 1, h.size() - 2)
	var b := clampi(int(to / 2.0), a, h.size() - 2)
	var rough := 0.0
	var side := 0.0
	var sharp := 0.0
	for i in range(a, b + 1):
		rough += absf(h[i - 1] - 2.0 * h[i] + h[i + 1])
		side += float(terrain.side[i])
		sharp += float(terrain.sharp[i])
	var count := float(b - a + 1)
	var wood := -1.0
	var glade := 0.0
	var tree_cover: PackedFloat32Array = terrain.wood
	if not tree_cover.is_empty():
		var ka := clampi(int(from / 8.0), 0, tree_cover.size() - 1)
		var kb := clampi(int(to / 8.0), ka, tree_cover.size() - 1)
		wood = 0.0
		for k in range(ka, kb + 1):
			wood += tree_cover[k]
			glade += float(terrain.glade[k])
		wood /= float(kb - ka + 1)
		glade /= float(kb - ka + 1)
	var ledges := 0
	for l: float in terrain.ledges:
		if l >= from and l <= to: ledges += 1
	return {rough = clampf(rough / count / float(terrain.rough_norm), 0.0, 1.0), side = clampf(side / count / float(terrain.side_norm), 0.0, 1.0), turn = sharp / count, ledges = ledges, wood = wood, glade = glade}

## Множитель веса настроения по рельефу участка: неровная, боковая или извилистая земля — техника, уступы — прыжки и перепады,
## гладкий склон — поток; прыжки не любят боковой уклон и шпильки.
static func _terrain_mood(key: String, feat: Dictionary) -> float:
	var rough: float = feat.rough
	var side: float = feat.side
	var turn: float = feat.turn
	var rich := rough + side
	var wood: float = feat.wood
	var weight := 1.0
	if wood >= 0.0:
		# лесистость: сомкнутый лес — лесная техника, открытые склоны — поток и накат, поляна — выдох; прыжкам нужен простор
		match key:
			"forest": weight = 0.3 + 2.2 * wood
			"flow": weight = 0.6 + 0.8 * (1.0 - wood)
			"jump": weight = 1.0 - 0.8 * wood
			"tech": weight = 1.0 - 0.3 * wood
			"rest": weight = 1.0 + 1.5 * float(feat.glade)
			"cruise": weight = (0.4 + 1.6 * (1.0 - wood) + 1.5 * float(feat.glade)) * (1.0 - 0.6 * rough)
	elif key == "cruise":
		weight = 1.0 - 0.6 * rough # без данных о лесе накат — на гладкой земле
	if key == "cruise": weight *= clampf(1.0 - float(feat.get("cruised", 0.0)) / 0.3, 0.1, 1.0) # не больше трети маршрута
	match key:
		"tech": return weight * (1.0 + 1.5 * rough + 1.0 * side + 1.5 * turn)
		"forest": return weight * (1.0 + 0.5 * rough + 0.5 * turn)
		"jump": return weight * (1.0 + 0.7 * minf(int(feat.ledges), 3)) * (1.0 - 0.6 * side) * (1.0 - 0.7 * minf(turn * 3.0, 1.0))
		"flow": return weight * (1.0 + 0.5 * (1.0 - minf(rich, 1.0)) * (1.0 - minf(turn * 3.0, 1.0)))
		"rest": return weight * (1.0 + 0.5 * maxf(rich - 1.0, 0.0)) # природный участок сам держит внимание: после него выдох
	return weight

## Веса видов в участке по рельефу: каменный сад и неровность там, где рельеф неровный; узкий проход — на боковом уклоне;
## столы и дропы — не на боковом уклоне.
static func _terrain_weights(weights: Dictionary, feat: Dictionary) -> Dictionary:
	if feat.is_empty(): return weights
	var out := {}
	for kind: int in weights:
		var w := float(weights[kind])
		match kind:
			T.ROCK_GARDEN, T.ROUGH: w *= 1.0 + 2.0 * float(feat.rough)
			T.NARROW, T.LOG: w *= 1.0 + 1.0 * float(feat.side)
			T.TABLETOP, T.DROP, T.GAP: w *= 1.0 - 0.7 * float(feat.side)
		out[kind] = w
	return out

## Weighted mood choice: never the same mood twice in a row when there is another; a hard section
## makes a calm one likelier; the terrain grade favours moods that suit it.
## `t` — place in a whole route (-1: none): an easy start, tech and jumps in the middle, a calm finish (`finish`: the last
## section of the route takes a calm mood when the profile has one).
static func _pick_mood(weights: Dictionary, previous: String, hard: bool, grade: float, rng: RandomNumberGenerator, t := -1.0, finish := false, feat := {}) -> String:
	var keys: Array = weights.keys()
	var sum := 0.0
	var scaled := []
	for key: String in keys:
		var m: Dictionary = MOODS[key]
		var w := float(weights[key])
		if key == previous and keys.size() > 1: w *= 0.15
		if hard and m.get("calm", false): w *= 3.0
		if t >= 0.0:
			var calm: bool = m.get("calm", false) or key == "flow"
			var intense := key == "tech" or key == "jump"
			if t < 0.15: w *= 2.0 if calm else (0.6 if intense else 1.0)
			elif t > 0.45 and t < 0.85 and intense: w *= 1.5
			if finish and m.get("calm", false): w *= 6.0
			elif t > 0.9 and m.get("calm", false): w *= 2.5
		# Descent is negative grade: slope > 0 likes it, slope < 0 likes climbs. ±8 % doubles or halves.
		w *= pow(2.0, clampf(-grade / 0.08, -1.0, 1.0) * float(m.slope))
		if not feat.is_empty(): w *= _terrain_mood(key, feat)
		scaled.append(w)
		sum += w
	var roll := rng.randf() * sum
	for i in keys.size():
		roll -= scaled[i]
		if roll <= 0.0: return keys[i]
	return keys[-1]

## One element at `cursor` or null when nothing fits here (the caller moves on).
static func _element(d: TrailDefinition, m: Dictionary, cursor: float, end: float, difficulty: float, last: int, rng: RandomNumberGenerator, std := {}) -> TrailElement:
	var adaptive: bool = std.get("adaptive", false)
	var turn := _turn_at(d, cursor, 14.0)
	var kind: int
	var s_side := 0.0
	# поворот — туже R 83 м; под стандартами — туже R 33 м: пологая дуга сгенерированной линии годится под прыжок
	if absf(turn) > (0.012 if std.is_empty() else TURN_STD):
		var turns: Array = m.turns
		if turns.is_empty(): return null
		kind = turns[rng.randi() % turns.size()]
	else:
		# S-поворот: два изгиба подряд в разные стороны (средняя кривизна на 14 м около нуля, поэтому «прямая» он не годится
		# ни под прыжок, ни под роллер); только под стандартами и там, где настроение допускает виражи
		if not std.is_empty() and T.BERM in m.turns: s_side = _s_bend(d, cursor, S_BEND_SPAN)
		if s_side != 0.0:
			kind = T.S_BERM
		else:
			var weights: Dictionary = m.elements if std.is_empty() else m.get("std_elements", m.elements)
			if std.get("fallback", false): weights = FALLBACK
			elif std.get("rhythm", false):
				var phrase: Array = std.phrase
				weights = {phrase[0]: 1.0} if not phrase.is_empty() else _follow(weights, last, difficulty)
			weights = _terrain_weights(weights, std.get("feat", {}))
			kind = _weighted(weights, rng)
			if kind == last: kind = _weighted(weights, rng)
			if int(std.get("force", -1)) >= 0: kind = std.force
			if kind == T.TABLETOP or kind == T.DROP: cursor += APPROACH
	var size := TrailElementLibrary.sized(kind, difficulty * rng.randf_range(0.7, 1.0))
	var count := 1
	var length := size.x
	var gap := -1.0
	if kind == T.WAVES or kind == T.PUMP:
		count = rng.randi_range(3, 5)
		length *= count
	if not std.is_empty():
		std.last_kind = last
		var sized := _standard(d, kind, cursor, end, difficulty, std, count, size)
		if sized.is_empty(): return null
		kind = sized.profile
		size = Vector2(sized.length, sized.height)
		length = sized.length
		count = int(sized.get("count", count))
		gap = float(sized.get("gap", -1.0))
		if int(std.get("force", -1)) >= 0:
			# на уступе — только дроп; не получился на этой скорости (стал роллером) — уступ остаётся природным
			if kind != std.force: return null
			cursor = maxf(cursor, float(std.ledge) - length * 0.5)
	# стандарты: границы участков условные — прыжок может зайти за конец участка на OVERRUN м (столы и гэпы длинные)
	if not adaptive and (cursor + length > end + (OVERRUN if not std.is_empty() else 0.0) or cursor + length > d.route_length() - RUN_OUT):
		if not std.is_empty() and kind in [T.TABLETOP, T.GAP, T.DROP]: _refuse(std, "прыжок: не помещается в участок")
		return null
	var bends := kind == T.BERM or kind == T.OFF_CAMBER or kind == T.S_BERM
	# Straight features stay straight over their whole length; long ones shrink to a roller first.
	# стандарты: стол, гэп и дроп — и на пологой дуге (R ≥ 1/JUMP_BEND: боковая перегрузка на их скорости в пределах)
	var straight := JUMP_BEND if not std.is_empty() and kind in [T.TABLETOP, T.GAP, T.DROP] else 0.025
	# прыжок на дуге — только если её проходят на скорости седока без виража (иначе вираж туда уже не встанет)
	if not adaptive and not std.is_empty() and kind in [T.TABLETOP, T.GAP, T.DROP] and _sharpest(d, cursor, length) > 0.025:
		var speeds: PackedFloat32Array = std.speeds
		var v := speeds[clampi(int(cursor), 0, speeds.size() - 1)]
		if v > TrailStandards.turn_speed(1.0 / _sharpest(d, cursor, length), 0.0, 0.8) - 0.5:
			_refuse(std, "прыжок: дуга быстрая для прыжка")
			return null
	if not adaptive and not bends and not TrailElement.places_objects(kind) and _sharpest(d, cursor, length) > straight:
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
	var e := TrailElementLibrary.make(kind, cursor + length * 0.5, length, size.y, s_side if kind == T.S_BERM else (signf(turn) if bends else 1.0), count, rng.randf_range(0.28, 0.45))
	if adaptive and cursor + length > d.route_length():
		var available := d.route_length() - cursor - 0.05 # запас: перенос линии в мировые float32 чуть меняет её длину
		if available < RoadRefinement.STEP * 4 or kind == T.GAP or kind == T.NORTHSHORE: return null
		e.height *= pow(available / e.length, 2)
		e.length = available; e.station = cursor + available * 0.5
		if kind in [T.PUMP, T.WAVES]: e.count = maxi(1, mini(e.count, floori(available / (RoadRefinement.STEP * (8 if kind == T.WAVES else 4)))))
	e.seed = rng.randi() % 10000
	e.density = rng.randf_range(0.35, 0.7)
	e.lines = rng.randi_range(1, 3) if difficulty < 0.7 else 2
	e.gap = lerpf(2.0, 1.2, difficulty) if gap < 0.0 else gap
	if kind == T.LOG:
		e.count = rng.randi_range(1, 3)
		e.gap = clampf(e.gap, 1.0, d.width * 0.5 - 0.3)
	if kind == T.SLALOM: e.count = rng.randi_range(3, 5)
	if kind == T.NARROW: e.gap = clampf(e.gap, 1.0, d.width - 0.6)
	if kind == T.NORTHSHORE:
		# настил — мост, не уступ: он выходит на землю в конце (skew > 0.5), а не обрывается; ширина настила — e.gap
		e.skew = 0.75
		e.gap = clampf(e.gap, 1.2, d.width - 0.6)
	return e

## Размеры элемента kind у cursor по TrailStandards: скорость седока в этом месте, уровень по сложности участка.
## Прыжок, который на этой скорости не получается (гэп ниже красной, стол без длины), становится столом или роллером;
## техника при скорости выше стандарта уровня ставится, только если до неё есть место для торможения после прошлого
## элемента — тогда в профиль скорости добавляется предел, и дальше элементы считаются уже с торможением.
## Пусто — здесь ничего не ставить (причина в std.refused).
static func _standard(d: TrailDefinition, kind: int, cursor: float, end: float, difficulty: float, std: Dictionary, count: int, size: Vector2) -> Dictionary:
	var level := clampi(int(difficulty * 4.0), 0, 3)
	var speeds: PackedFloat32Array = std.speeds
	var v := speeds[clampi(int(cursor), 0, speeds.size() - 1)] * float(std.get("carry", 1.0))
	var grade := TrailStandards.element_grade(d, std.ground, cursor)
	var key := {T.TABLETOP: "table", T.GAP: "gap", T.DROP: "drop", T.ROLLER: "roller", T.PUMP: "pump"}
	if key.has(kind):
		# не получился на этой скорости — следующий по списку: стол ниже 12 м/с не взлетает, дроп — с 5 м/с (v4: дроп
		# раньше роллера — на змейке байк-парка после разворотов столы иначе становились роллерами)
		var chain := {T.GAP: ["table", "drop", "roller"], T.TABLETOP: ["drop", "roller"], T.DROP: ["roller"]}
		for k: String in ([key[kind]] + (chain.get(kind, []) as Array)):
			# ритм: два дропа подряд не ставятся (стол на малой скорости становится дропом, но не серией дропов)
			if k == "drop" and std.get("rhythm", false) and int(std.get("last_kind", -1)) == T.DROP: continue
			# Перед прыжком седок разгоняется с Shift (проверка полотна даёт всем сценариям разбег RUN_UP): скорость входа —
			# по профилю с разгоном, а не по комфортной скорости уровня
			var vk := v
			var turn_cap := INF
			if std.get("adaptive", false) and k in ["table", "gap", "drop"]:
				var boosted: PackedFloat32Array = std.speeds_boost
				vk = maxf(v, boosted[clampi(int(cursor), 0, boosted.size() - 1)] * float(std.get("carry", 1.0)))
				# поворот на подходе или в приземлении: проверка полотна тормозит седока до скорости, которую держит этот радиус
				# (TrailValidation.jump_turn_cap), прыжок считается на неё
				turn_cap = TrailStandards.jump_turn_cap(d, cursor, cursor + JUMP_SPAN, level)
				vk = minf(vk, turn_cap)
			var s := TrailStandards.spec(k, snappedf(vk, 0.5), level, grade, not std.get("adaptive", false))
			# на краях модели подбор длины и окно скорости расходятся: прыжок — только если седок в его окне; в игре и если
			# быстрый сценарий проверки (FAST_SPEED) перелетит зону приземления
			var fast_v := minf(vk * FAST_SPEED, turn_cap) if std.get("adaptive", false) else vk
			if not s.is_empty() and s.has("speed_lo") and (vk < float(s.speed_lo) - 0.5 or vk > float(s.get("speed_hi", INF)) + 0.5 or fast_v > float(s.get("speed_hi", INF)) + 0.5):
				var why := "прыжок: скорость вне окна"
				std.refused[why] = int(std.refused.get(why, 0)) + 1
				continue
			if not s.is_empty():
				if std.get("adaptive", false) and k in ["table", "gap", "drop"] and float(s.length) > d.route_length() - cursor: continue
				return s
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
		if kind == T.NORTHSHORE: limit = minf(limit, TrailStandards.DECK_SPEED)
		if kind == T.NARROW:
			limit = minf(limit, TrailStandards.NARROW_SPEED)
			# v4: к узкому проходу — прямой подход (после виража курс сбит — удар в стенку)
			if not std.get("adaptive", false) and TrailStandards.tightest(d, cursor - 15.0, cursor + size.x) < 40.0:
				_refuse(std, "узкий проход: нет прямого подхода")
				return {}
		# 01.11: только где седок и без торможения не быстрее стандарта — заранее не тормозят (бревно на 12,6 м/с
		# после поворота уронило через руль)
		if not std.get("adaptive", false) and v > limit + 0.5:
			var why := "техника: здесь быстрее %.0f м/с" % limit
			std.refused[why] = int(std.refused.get(why, 0)) + 1
			return {}
		var h := size.y
		if TrailStandards.TECH_HEIGHTS.has(kind): h = TrailStandards.tech_height(kind, level)
		return {profile = kind, length = size.x, height = h}
	return {profile = kind, length = size.x, height = size.y, count = count}

const OVERRUN := 25.0
## Примерная длина прыжка с приземлением для оценки поворота на нём (размер известен только после стандарта), м.
const JUMP_SPAN := 24.0
## Быстрый сценарий проверки полотна (TrailValidation.SCENARIOS.fast).
const FAST_SPEED := 1.15
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
		var needs := is_finite(radius) and v > TrailStandards.turn_speed(radius, route_bank, float(TrailStandards.LEVELS[level].lat)) + 0.5
		# v4: вираж, который уже стоит в повороте, закрывает его целиком (выносило за его концом в 4 м)
		var partial := false
		for e in elements:
			if e.profile == T.BERM and e.station + e.length * 0.5 > from - 2.0 and e.station - e.length * 0.5 < at + 2.0 and \
					(e.station - e.length * 0.5 > from - 1.0 or e.station + e.length * 0.5 < at + 1.0): partial = true
		if not needs and not partial:
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
			elif needs:
				merged.append(e) # быстрый поворот принадлежит виражу
			else:
				jump = true # только продлить вираж — соседний элемент не трогаем, вираж остаётся как есть
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

## S-поворот на `span` м от `from`: кривизна заметна в обе стороны (R ≤ S_BEND_R) и знак меняется один раз. Знак первого
## изгиба (как у виража: в какую сторону первый поворот) или 0 — S-поворота здесь нет.
const S_BEND_SPAN := 20.0
const S_BEND_R := 60.0
static func _s_bend(d: TrailDefinition, from: float, span: float) -> float:
	if from + span > d.route_length(): return 0.0
	var first := 0.0
	var second := false
	var at := 0.0
	while at <= span:
		var k := d.curvature_at(from + at)
		if absf(k) >= 1.0 / S_BEND_R:
			if first == 0.0: first = signf(k)
			elif signf(k) != first: second = true
			elif second: return 0.0 # снова в первую сторону: не S, а змейка
		at += 2.0
	return first if second else 0.0

## Mean signed curvature over a window starting at `from`; the sign says which side is the outside.
static func _turn_at(d: TrailDefinition, from: float, window: float) -> float:
	var sum := 0.0
	for i in 5: sum += d.curvature_at(from + window * i / 4.0)
	return sum / 5.0
