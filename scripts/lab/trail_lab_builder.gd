extends RefCounted
const TrailStandards := preload("res://scripts/trails/trail_standards.gd")
const Validation := preload("res://scripts/lab/trail_lab_validation.gd")
## Trail Lab, генератор трассы, v3 (01.11). По любой земле (Callable) в квадрате size × size м прокладывает одну
## линию сверху вниз и ставит на неё элементы составителем с расчётными стандартами (TrailComposer + TrailStandards).
## v2 (по заездам 01.11): ходок знает скорость (радиус не туже v²/a), старт и цель по сиду, виражи на быстрых поворотах.
## v3 — многоуровневость и «земляные» элементы, которые меняют землю (carve — врезки TrailLabTerrain.apply_cuts):
##  1. Петля над собой: в середине линии — прямая через точку X, круг R LOOP_R на 270° и снова через X поперёк; верхний
##     проход — мосток (норшор-мост) или гэп над нижним, нижний ныряет в выемку LOOP_CUT м под ним (как на полигоне).
##     Сторона петли — та, где выход ведёт вниз по склону; нет места — петли нет.
##  2. Овражки: на прямых, где позволяет скорость, поперёк трассы врезается небольшой овражек (глубина RAVINE_DEPTH), и
##     через него — гэп по стандарту (разрыв под скорость седока) или, если гэп здесь не по уровню или скорости, мосток.
##     Под пролётом полотно не насыпается (TrailDefinition.open_spans): внизу остаётся сам овражек, а не дорога.
##  3. Прыжков больше: у составителя вдвое чаще участки «прыжки», чуть плотнее элементы.
## Детерминирован по (земля, seed, стиль).

const MARGIN := 28.0
const STEP := 4.0
const MIN_RADIUS := 9.0  # туже — только разворот, когда упёрлись
const HAIRPIN := 6.0     # радиус такого разворота, м
const LOOK := 20.0
const SEP := 14.0        # своя линия не ближе этого (кроме последних OWN_SKIP м)
const OWN_SKIP := 40.0
const CLIFF := 0.5       # круче (м на м) наружный откос поворота — штраф
const GOAL_REACH := 20.0 # ближе к цели — финиш, м
const CLIMB_MAX := 0.08  # круче подъём на шаге — почти запрет (на стенке уступа седок встаёт)
## Стили: целевой уклон (спуск — отрицательный), длина, ширина, профиль составителя, извилистость, крейсерская
## скорость и доля перегрузки в поворотах (под неё — радиус линии).
const STYLES := {
	flow = {title = "Flow", grade = -0.07, length = 1100.0, width = 4.5, profile = "flow", wander = 0.06, cruise = 13.0, lat = 0.6},
	downhill = {title = "Даунхилл", grade = -0.14, length = 800.0, width = 4.0, profile = "mountain", wander = 0.05, cruise = 14.0, lat = 0.7},
	enduro = {title = "Эндуро", grade = -0.10, length = 1300.0, width = 3.5, profile = "mixed", wander = 0.08, cruise = 12.0, lat = 0.6},
	tech = {title = "Техничная", grade = -0.09, length = 900.0, width = 3.5, profile = "technical", wander = 0.09, cruise = 10.0, lat = 0.55},
	# v4: пологое место — байк-парк: змейка параллельных прямых с разворотами на 180°, элементы подряд
	park = {title = "Байк-парк", grade = -0.02, length = 900.0, width = 4.0, profile = "flow", wander = 0.0, cruise = 13.0, lat = 0.7},
}
const ORDER := ["flow", "downhill", "enduro", "tech", "park"]
## Байк-парк: прямые (длина, м), их число, шаг между ними (м; разворот — полукруг радиуса шага/2).
const PARK_LANE := Vector2(90.0, 130.0) # длиннее — к середине прямой разгон до скорости столов (от 12 м/с)
const PARK_LANES := Vector2i(4, 7)
const PARK_STEP := 17.0
## Канавы вдоль трассы (v4): параллельный канал у края полотна — плохо подрулил, свалился.
const DITCH_OFFSET := 2.0    # от края полотна до оси канавы, м
const DITCH_DEPTH := 1.0
const DITCH_LENGTH := Vector2(20.0, 40.0)
const DITCH_CHANCE := 0.45   # доля прямых, у которых есть канава (у байк-парка — вдвое чаще)
## v3: петля над собой и овражки.
const LOOP_R := 16.0         # радиус петли, м (вираж на круге ставит составитель)
const LOOP_LEAD := 16.0      # прямая до X и от X до начала круга, м (равна радиусу: круг на 270° выводит на X)
const LOOP_CUT := 2.4        # выемка нижнего прохода под X, м (с мостком 1,2 м — просвет около 3,6 м)
const LOOP_DECK := 1.2
const LOOP_RELIEF := 5.0     # перепад земли под петлёй не больше, м
const RAVINE_SMOOTH := 1.2   # земля у овражка не дальше от прямой, м
const GRADE_LIMIT_MAX := 0.32 # целевой уклон выравнивания сгенерированной трассы не круче
const RAVINE_DEPTH := 1.8    # глубина овражка, м
const RAVINE_SPAN := 12.0    # овражек тянется в стороны от оси, м
const RAVINE_EVERY := 150.0  # в среднем один овражек на столько метров (v4: было 220)
const RAVINE_GAP := 90.0     # и не ближе друг к другу
const RAVINE_STRAIGHT := 35.0 # овражек — где ось на ±16 м не туже этого радиуса
const WANDER_V3 := 0.6       # v3: извилистость меньше — больше прямых под прыжки

static var seed := 1
static var style := "flow"
static var stats := {}
static var speeds := PackedFloat32Array() ## профиль скорости «как едут», по которому ставились элементы
static var cuts: Array = []                ## врезки последней трассы (TrailLabTerrain.apply_cuts)


## Трасса по земле ground на поле size × size м. Пусто — линия не проложилась (stats.reason).
## avoid(Vector2) -> bool — необязательно: куда линии нельзя (вода окна мира); carve(Array) — необязательно: применить
## врезки к земле (после неё ground уже врезанная); без carve овражков и петли нет.
static func build(ground: Callable, size: float, seed_value: int, style_name: String, avoid := Callable(), carve := Callable()) -> Array[TrailDefinition]:
	var started := Time.get_ticks_usec()
	seed = seed_value
	style = style_name if STYLES.has(style_name) else "flow"
	var st: Dictionary = STYLES[style]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("trail_lab_builder|%d|%s" % [seed, style])
	stats = {}
	speeds = PackedFloat32Array()
	cuts = []
	var inside := func(p: Vector2) -> bool:
		return p.x > MARGIN and p.y > MARGIN and p.x < size - MARGIN and p.y < size - MARGIN and not (avoid.is_valid() and avoid.call(p))
	var walk_inside := func(p: Vector2) -> bool:
		var half: float = st.width * 0.5
		for offset in [Vector2.ZERO, Vector2(half, 0), Vector2(-half, 0), Vector2(0, half), Vector2(0, -half)]:
			if not inside.call(p + offset): return false
		return true
	var cells: Array[Vector3] = []
	var at := MARGIN + 8.0
	while at < size - MARGIN:
		var bt := MARGIN + 8.0
		while bt < size - MARGIN:
			cells.append(Vector3(at, bt, float(ground.call(Vector2(at, bt)))))
			bt += 16.0
		at += 16.0
	cells.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.z > b.z)
	var lo_h := cells[-1].z
	var hi_h := cells[0].z
	# характер местности: средний уклон поля — по нему целевой уклон (на пологой земле мягче, на крутой не круче стиля)
	var field_grade := (hi_h - lo_h) / (size * 0.7)
	var grade := clampf(float(st.grade), -maxf(0.03, field_grade * 0.9), -0.025)
	# рисунок линии — по сиду
	var shape := {pull = rng.randf_range(0.15, 0.6), wander = float(st.wander) * rng.randf_range(0.6, 1.5) * (WANDER_V3 if carve.is_valid() else 1.0),
		period = Vector2(rng.randf_range(30.0, 70.0), rng.randf_range(12.0, 26.0)), phase = Vector2(rng.randf() * TAU, rng.randf() * TAU)}
	var upper := cells.slice(0, maxi(1, cells.size() / 5))
	var lower := cells.slice(cells.size() * 2 / 3)
	# своя четверть поля для старта по сиду (среди верхних 40 %): иначе спуски сходятся в одну ложбину
	var quarter := rng.randi() % 4
	var mine := cells.slice(0, maxi(1, cells.size() * 2 / 5)).filter(func(c: Vector3) -> bool:
		return int(c.x > size * 0.5) + 2 * int(c.y > size * 0.5) == quarter)
	if mine.size() >= 3: upper.assign(mine)
	shape.quarter = quarter
	var pts := PackedVector2Array()
	var goal := Vector2.ZERO
	var best_score := -INF
	var tries := 0
	if style == "park":
		pts = _park_points(ground, walk_inside, size, rng)
		best_score = INF
	for k in (0 if style == "park" else 10):
		tries += 1
		var s0: Vector3 = upper[rng.randi() % upper.size()]
		var start := Vector2(s0.x, s0.y)
		var g0: Vector3 = lower[rng.randi() % lower.size()]
		for j in 6:
			if Vector2(g0.x, g0.y).distance_to(start) >= size * 0.45: break
			g0 = lower[rng.randi() % lower.size()]
		var target := Vector2(g0.x, g0.y)
		var line := _walk_with_loop(ground, walk_inside, start, target, float(st.length), grade, shape, st, rng, lower, carve.is_valid())
		# лучшая попытка — по длине и спуску вместе (v2: v1 брала самую длинную, и линия могла уйти по горизонтали)
		var score := _score(line, ground, float(st.length), grade)
		if score > best_score:
			best_score = score
			pts = line
			goal = target
		if best_score > 1.5: break
	var walk_ms := (Time.get_ticks_usec() - started) / 1000.0
	if pts.size() < 40:
		stats = {accepted = false, reason = "линия не проложилась: места хватило на %.0f м" % (pts.size() * STEP)}
		return []
	var line := _resample(_smooth(_smooth(pts)), 2.0)
	var d := TrailDefinition.new()
	d.id = "generated_%s_%d" % [style, seed]
	d.title = "%s · сид %d" % [st.title, seed]
	d.kind = "mountain"
	d.width = st.width
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	d.points = line
	var footprint_errors := Validation.footprint(d, inside)
	if not footprint_errors.is_empty():
		stats = {accepted = false, reason = "; ".join(footprint_errors)}
		return []
	# v3: целевой уклон выравнивания — по самой крутой части самой линии (не ниже пресета): иначе после крутого спуска
	# полотно держит 16 % и уходит в насыпь до 10 м — под пролётом и в узле петли это яма, а не овражек
	var shaping := TrailShaping.preset(d.kind)
	shaping.grade_limit = clampf(_steepest(d, ground) * 1.1, shaping.grade_limit, GRADE_LIMIT_MAX)
	d.shaping = shaping
	var profile: Dictionary = (TrailComposer.PROFILES[st.profile] as Dictionary).duplicate(true)
	profile.standards = true
	# v3: прыжковые участки вдвое чаще, элементы чуть плотнее
	var moods: Dictionary = profile.moods
	moods.jump = float(moods.get("jump", 0.0)) * 2.0 + 2.0
	profile.density = minf(1.0, float(profile.density) + 0.2) # v4: было +0,1
	if style == "park":
		# байк-парк: только прыжки и поток, короткие участки, элементы почти подряд
		profile.moods = {jump = 5.0, flow = 4.0}
		profile.density = 1.0
		profile.section = Vector2(40.0, 70.0)
	var band: Vector2 = profile.difficulty
	var level := clampi(int((band.x + band.y) * 0.5 * 4.0), 0, 3)
	# v3: петля и овражки — элементы, пролёты и врезки; составитель ставит своё вокруг них
	var features := {elements = [] as Array[TrailElement], spans = PackedVector3Array(), cuts = [], reserved = [] as Array[Vector2], loop = false, ravines = 0, gaps = 0, decks = 0, ditches = 0}
	var stage := Time.get_ticks_usec()
	if carve.is_valid():
		_plan_loop(d, ground, level, features)
		_plan_ravines(d, ground, level, features, rng)
		_plan_ditches(d, features, rng, DITCH_CHANCE * (2.0 if style == "park" else 1.0))
		cuts = features.cuts
		carve.call(cuts)
	d.open_spans = features.spans
	var reserved: Array[Vector2] = features.reserved
	var free := func(e: TrailElement) -> bool:
		for r in reserved:
			if e.station + e.length * 0.5 > r.x - 6.0 and e.station - e.length * 0.5 < r.y + 6.0: return false
		return true
	var features_ms := (Time.get_ticks_usec() - stage) / 1000.0
	stage = Time.get_ticks_usec()
	var composed := TrailComposer.compose(d, profile, seed * 7919 + 13, ground, free)
	var compose_ms := (Time.get_ticks_usec() - stage) / 1000.0
	var own: Array[TrailElement] = []
	own.assign((composed.elements as Array).filter(func(e: TrailElement) -> bool: return free.call(e))) # и виражи составителя
	var all: Array[TrailElement] = own.duplicate()
	all.append_array(features.elements)
	all.sort_custom(func(x: TrailElement, y: TrailElement) -> bool: return x.station < y.station)
	d.elements.assign(all)
	d.sections.assign(composed.sections)
	var errors := d.validate()
	if not errors.is_empty():
		stats = {reason = "определение трассы: " + "; ".join(errors), accepted = false}
		cuts = []
		if carve.is_valid(): carve.call(cuts)
		return []
	var length := d.route_length()
	var drop := float(ground.call(line[0])) - float(ground.call(line[-1]))
	speeds = TrailStandards.profile_from(d, TrailStandards.line_heights(d, ground), level, {}, false)
	var top := 0.0
	var mean := 0.0
	for v in speeds:
		top = maxf(top, v)
		mean += v
	if not speeds.is_empty(): mean /= speeds.size()
	var radii := []
	var s := 2.0
	while s < length - 2.0:
		var k := absf(d.curvature_at(s))
		if k > 1.0 / 40.0: radii.append(1.0 / k)
		s += 2.0
	radii.sort()
	stats = {length = snappedf(length, 1.0), drop = snappedf(drop, 0.1), grade = snappedf(-drop / maxf(length, 1.0) * 100.0, 0.1),
		accepted = false, definition_valid = true, elements = d.elements.size(), refused = composed.get("refused", {}), berms = d.elements.filter(func(e: TrailElement) -> bool: return e.profile in [TrailElement.Profile.BERM, TrailElement.Profile.S_BERM]).size(), speed_top = snappedf(top, 0.1),
		speed_mean = snappedf(mean, 0.1), radius_median = snappedf(float(radii[radii.size() / 2]) if not radii.is_empty() else 0.0, 0.1),
		start = line[0], goal = goal, target_grade = snappedf(grade * 100.0, 0.1), pull = snappedf(shape.pull, 0.01),
		ms = (Time.get_ticks_usec() - started) / 1000.0, title = st.title, tries = tries,
		walk_ms = snappedf(walk_ms, 1.0), features_ms = snappedf(features_ms, 1.0), compose_ms = snappedf(compose_ms, 1.0),
		loop = features.loop, ravines = d.open_spans.size(), ditches = features.ditches,
		gaps = d.elements.filter(func(e: TrailElement) -> bool: return e.profile == TrailElement.Profile.GAP).size(),
		decks = d.elements.filter(func(e: TrailElement) -> bool: return e.profile == TrailElement.Profile.NORTHSHORE).size(),
		jumps = d.elements.filter(func(e: TrailElement) -> bool: return e.profile in [TrailElement.Profile.TABLETOP, TrailElement.Profile.GAP, TrailElement.Profile.DROP]).size()}
	return [d]

## Строка для подписи: стиль, сид, длина, перепад, элементы.
static func label() -> String:
	if stats.is_empty(): return ""
	if stats.has("reason"): return str(stats.reason)
	var extra := PackedStringArray()
	if stats.get("loop", false): extra.append("петля над собой")
	if int(stats.get("ravines", 0)) > 0: extra.append("овражков %d" % stats.ravines)
	if int(stats.get("ditches", 0)) > 0: extra.append("канав %d" % stats.ditches)
	return "%s · сид %d · %.0f м, %+.0f м (%.1f %%) · элементов %d (прыжков %d, виражей %d)%s · до %.0f м/с · %s" % [stats.title, seed, stats.length, -stats.drop, -stats.grade,
		stats.elements, stats.get("jumps", 0), stats.berms, (" · " + ", ".join(extra)) if not extra.is_empty() else "", stats.speed_top,
		"полотно проверено" if stats.get("accepted", false) else "проверка полотна ожидается"]


## Оценка линии: доля нужной длины (до 1) плюс доля ожидаемого спуска (до 1); подъём в итоге — минус.
static func _score(line: PackedVector2Array, ground: Callable, length: float, grade: float) -> float:
	if line.size() < 2: return -INF
	var run := line.size() * STEP
	var drop := float(ground.call(line[0])) - float(ground.call(line[-1]))
	# спуск — относительно ожидаемого на всю длину стиля: короткая крутая линия не выигрывает у полной
	return minf(run / length, 1.0) + clampf(drop / maxf(1.0, length * -grade), -1.0, 1.0)

## Ходок. heading — начальный курс (NAN — на цель); prior — уже проложенные точки (своя линия до петли: от них тоже
## держится SEP); s0 и v0 — пройденное и скорость на старте. Возвращает точки от start.
## Линия с петлёй (v3): ходок до LOOP_AT доли длины, петля, если ей хватает места, и ходок дальше от её выхода.
const LOOP_AT := Vector2(0.2, 0.45)
const LOOP_TRIES := 6
const LOOP_RETRY := 40.0
static func _walk_with_loop(ground: Callable, inside: Callable, start: Vector2, goal: Vector2, length: float, grade: float, shape: Dictionary, st: Dictionary,
		rng: RandomNumberGenerator, lower: Array, loop: bool) -> PackedVector2Array:
	if not loop: return _walk(ground, inside, start, goal, length, grade, shape, st, rng, lower)
	var first := length * rng.randf_range(LOOP_AT.x, LOOP_AT.y)
	var a := _walk(ground, inside, start, goal, first, grade, shape, st, rng, [])
	if a.size() < 8: return a
	var heading := (a[-1] - a[-2]).angle()
	var m := _loop_points(ground, inside, a, heading)
	# не помещается — ещё LOOP_RETRY м и снова (до LOOP_TRIES раз, пока не дошли до 3/4 длины)
	var tries := 1
	while m.is_empty() and tries < LOOP_TRIES and a.size() * STEP < length * 0.75:
		tries += 1
		var more := _walk(ground, inside, a[-1], goal, a.size() * STEP + LOOP_RETRY, grade, shape, st, rng, lower, heading, a.slice(0, a.size() - 1), a.size() * STEP, 10.0)
		if more.size() < 3: break
		a.append_array(more.slice(1))
		heading = (a[-1] - a[-2]).angle()
		m = _loop_points(ground, inside, a, heading)
	if m.is_empty():
		var tail := _walk(ground, inside, a[-1], goal, length, grade, shape, st, rng, lower, heading, a.slice(0, a.size() - 1), a.size() * STEP, 10.0)
		a.append_array(tail.slice(1))
		return a
	var done := a.duplicate()
	done.append_array(m.points)
	var rest := _walk(ground, inside, done[-1], goal, length, grade, shape, st, rng, lower, m.exit, done.slice(0, done.size() - 1), done.size() * STEP * 0.9, 9.0)
	done.append_array(rest.slice(1))
	return done

## Точки петли от конца линии a с курсом heading: LOOP_LEAD до X, LOOP_LEAD дальше, круг LOOP_R на 270° в сторону, где
## выход ниже, прямая обратно через X и ещё LOOP_LEAD. {points, exit, x} или пусто, если места нет.
static func _loop_points(ground: Callable, inside: Callable, a: PackedVector2Array, heading: float) -> Dictionary:
	var grid := {}
	for k in a.size(): _mark(grid, a[k], k)
	var p := a[-1]
	var f := Vector2.from_angle(heading)
	var x := p + f * LOOP_LEAD
	var best := {}
	var best_drop := -INF
	for side: float in [1.0, -1.0]:
		var pts := PackedVector2Array()
		for k in range(1, int(LOOP_LEAD * 2.0 / 2.0) + 1): pts.append(p + f * (2.0 * k))
		var h := heading
		var q := pts[-1]
		var arc := 1.5 * PI * LOOP_R
		var steps := int(arc / 2.0)
		for k in steps:
			h += side * 2.0 / LOOP_R
			q += Vector2.from_angle(h) * 2.0
			pts.append(q)
		# прямая обратно через X и дальше
		var back := (x - q).normalized()
		var to_x := q.distance_to(x)
		var t := 2.0
		while t < to_x + LOOP_LEAD:
			pts.append(q + back * t)
			t += 2.0
		var ok := true
		for k in pts.size():
			var c := pts[k]
			if not inside.call(c): ok = false
			# не у прежней линии (кроме её последних 40 м — оттуда петля начинается)
			elif _near_own(grid, a.size(), c): ok = false
			if not ok: break
		# петля замыкается: курс после круга смотрит на X (иначе пересечение не поперёк)
		if absf(Vector2.from_angle(h).angle_to(back)) > 0.35: ok = false
		# земля под петлёй почти ровная: тогда полотно идёт по земле, и у пересечения под мостком честный просвет
		if ok:
			var lo := INF
			var hi := -INF
			for c in pts:
				lo = minf(lo, float(ground.call(c)))
				hi = maxf(hi, float(ground.call(c)))
			if hi - lo > LOOP_RELIEF: ok = false
		if not ok: continue
		var drop := float(ground.call(x)) - float(ground.call(pts[-1]))
		if drop > best_drop:
			best_drop = drop
			best = {points = pts, exit = back.angle(), x = x}
	if best.is_empty() or best_drop < 0.3: return {}
	return best

static func _walk(ground: Callable, inside: Callable, start: Vector2, goal: Vector2, length: float, grade: float, shape: Dictionary, st: Dictionary, rng: RandomNumberGenerator, lower: Array = [],
		heading := NAN, prior := PackedVector2Array(), s0 := 0.0, v0 := 3.0) -> PackedVector2Array:
	var pts := PackedVector2Array([start])
	var p := start
	var a := (goal - start).angle() if is_nan(heading) else heading
	var s := s0
	var ph: Vector2 = shape.phase
	var period: Vector2 = shape.period
	var wander: float = shape.wander
	var cruise: float = st.cruise
	var accel: float = TrailStandards.LAT_MAX * float(st.lat) + 1.5 # наклон полотна трассы добавляет немного
	var v := v0
	var bend := 0.0
	var stuck := 0
	var grid := {}
	# прежние точки: номер по расстоянию от их конца в шагах (отрицательный) — последние OWN_SKIP м не мешают продолжению
	var back := 0.0
	for k in range(prior.size() - 1, -1, -1):
		if k < prior.size() - 1: back += prior[k].distance_to(prior[k + 1])
		_mark(grid, prior[k], -1 - int(back / STEP))
	_mark(grid, start, 0)
	while s < length:
		if p.distance_to(goal) < GOAL_REACH:
			# у цели линия кончается; рано (крутой стиль быстро сходит вниз) — новая цель, самая дальняя из низких
			if s >= length * 0.6 or lower.is_empty() or s0 > 0.0: break
			var far := goal
			for c: Vector3 in lower:
				if Vector2(c.x, c.y).distance_to(p) > far.distance_to(p): far = Vector2(c.x, c.y)
			if far.distance_to(p) < GOAL_REACH * 2.0: break
			goal = far
		# поворот за шаг — не круче радиуса, который седок держит на этой скорости
		var max_turn := STEP / maxf(MIN_RADIUS, v * v / accel)
		var want := (wander * sin(s / period.x + ph.x) + wander * 0.6 * sin(s / period.y + ph.y)) * STEP
		want += clampf(Vector2.from_angle(a).angle_to(goal - p), -1.0, 1.0) * float(shape.pull) * max_turn
		var best := INF
		var best_o := 0.0
		var best_g := 0.0
		# обычный веер; упёрлись — второй, разворотом радиуса HAIRPIN (с шагом вперёд, без излома на месте)
		var fan := max_turn if stuck == 0 else STEP / HAIRPIN
		for k in 13:
			var o := -fan + fan * k / 6.0
			var dir := Vector2.from_angle(a + o)
			var next := p + dir * STEP
			if not inside.call(next) or _near_own(grid, pts.size(), next): continue
			var here := float(ground.call(next))
			var g := (here - float(ground.call(p))) / STEP
			var side := Vector2(-dir.y, dir.x)
			var cross := absf(float(ground.call(next + side * 2.0)) - float(ground.call(next - side * 2.0))) / 4.0
			# уклон к цели стиля (подъём — дорого), поперечный склон, плавность и «волна» изгибов
			var cost := absf(g - grade) * 60.0 + maxf(0.0, g) * 80.0 + maxf(0.0, cross - 0.25) * 8.0 + absf(o - want) * 1.5
			# стенка уступа или крутой подъём — седок встанет: только если другого хода нет
			if g > CLIMB_MAX: cost += 200.0
			# обрыв снаружи поворота: вылет наружу — вниз по откосу (падение 01.11 с 30 м)
			if absf(o) > max_turn * 0.3:
				var outer := side * (-signf(o))
				var fall := (here - float(ground.call(next + outer * 5.0))) / 5.0
				cost += maxf(0.0, fall - CLIFF) * 12.0
			# взгляд вперёд — не короче тормозного пути до разворотной скорости: тупик виден заранее
			var look := maxf(LOOK, (v * v - accel * HAIRPIN) / (2.0 * TrailStandards.BRAKE))
			for j in range(1, 5):
				var ahead := p + dir * (STEP + look * j / 4.0)
				if not inside.call(ahead) or _near_own(grid, pts.size(), ahead):
					cost += 30.0 / j - (1.0 if signf(o) == signf(bend) else 0.0)
					break
			if cost < best:
				best = cost
				best_o = o
				best_g = g
		if best == INF:
			# упёрлись: следующий шаг — веером разворота; не нашлось и его — линия кончилась
			stuck += 1
			if stuck > 1: break
			continue
		if stuck > 0: v = minf(v, sqrt(accel * HAIRPIN)) # разворот: седок тормозит до разворотной скорости
		stuck = 0
		a += best_o
		bend = best_o
		# скорость «как едут»: тяжесть на уклоне, качение, воздух, педали до крейсерской
		var acc: float = -TrailStandards.G * best_g / sqrt(1.0 + best_g * best_g) - TrailStandards.ROLL - TrailStandards.DRAG * v * v
		if v < cruise: acc += TrailStandards.PEDAL * (1.0 - v / cruise)
		v = clampf(sqrt(maxf(1.0, v * v + 2.0 * acc * STEP)), 3.0, 20.0)
		p += Vector2.from_angle(a) * STEP
		s += STEP
		pts.append(p)
		_mark(grid, p, pts.size() - 1)
	return pts

## v3: петля над собой на готовой линии — пересечение двух её участков (станции далеко друг от друга). Верхний проход —
## гэп по стандарту, если на его скорости разрыв перекрывает нижнюю трассу, иначе мосток; нижний — в выемке LOOP_CUT.
static func _plan_loop(d: TrailDefinition, ground: Callable, level: int, f: Dictionary) -> void:
	var cross := _self_crossing(d)
	if cross == Vector2.ZERO: return
	var up := cross.x
	var low := cross.y
	var v := TrailStandards.profile_from(d, TrailStandards.line_heights(d, ground), level, {}, false)
	var speed := v[clampi(int(up) - 12, 0, v.size() - 1)]
	var e: TrailElement = null
	var gap := TrailStandards.spec("gap", snappedf(speed, 0.5), level, TrailStandards.element_grade(d, ground, up - 12.0))
	if not gap.is_empty() and float(gap.gap) >= d.width + 1.5 and speed >= float(gap.get("speed_lo", 0.0)) - 0.5 and speed <= float(gap.get("speed_hi", INF)) + 0.5:
		e = TrailStandards.element(gap, 0.0)
		var start := up - (e.gap_lip() + e.gap * 0.5)
		e.station = start + e.length * 0.5
		f.gaps += 1
	else:
		e = TrailElementLibrary.make(TrailElement.Profile.NORTHSHORE, up, 24.0, LOOP_DECK, 1.0, 3, 0.75)
		e.gap = minf(3.2, d.width - 0.5) # same clearance as TrailDefinition.validate
		f.decks += 1
	f.elements.append(e)
	f.reserved.append(Vector2(e.station - e.length * 0.5, e.station + e.length * 0.5))
	f.reserved.append(Vector2(low - 14.0, low + 14.0)) # нижний проход чистый
	# выемка нижнего прохода: полная у X, на нет за 30 м
	var pts := PackedVector2Array()
	var depth := PackedFloat32Array()
	var s := maxf(0.0, low - 32.0)
	while s <= minf(d.route_length(), low + 32.0):
		pts.append(d.point_at(s))
		depth.append(LOOP_CUT * (1.0 - smoothstep(5.0, 30.0, absf(s - low))))
		s += 4.0
	f.cuts.append({points = pts, depth = depth, half = d.width * 0.5 + 0.4, wall = 0.9})
	f.loop = true

## Самый крутой уклон земли под осью на базе 8 м, м на м.
static func _steepest(d: TrailDefinition, ground: Callable) -> float:
	var worst := 0.0
	var s := 4.0
	var length := d.route_length()
	while s < length - 4.0:
		worst = maxf(worst, absf(float(ground.call(d.point_at(s + 4.0))) - float(ground.call(d.point_at(s - 4.0)))) / 8.0)
		s += 4.0
	return worst

## v4: змейка байк-парка — PARK_LANES прямых длиной PARK_LANE вдоль горизонталей поля, через PARK_STEP, соединённых
## полукругами (разворот на 180°). Центр — по сиду во внутренней части; не помещается — меньше прямых или короче.
static func _park_points(ground: Callable, inside: Callable, size: float, rng: RandomNumberGenerator) -> PackedVector2Array:
	for attempt in 12:
		var c := Vector2(rng.randf_range(0.3, 0.7), rng.randf_range(0.3, 0.7)) * size
		var gx := float(ground.call(c + Vector2(20, 0))) - float(ground.call(c - Vector2(20, 0)))
		var gz := float(ground.call(c + Vector2(0, 20))) - float(ground.call(c - Vector2(0, 20)))
		var down := -Vector2(gx, gz).normalized() if Vector2(gx, gz).length() > 0.4 else Vector2.from_angle(rng.randf() * TAU)
		var along := down.orthogonal() # прямые — вдоль горизонтали, от прямой к прямой — вниз
		var lanes := rng.randi_range(PARK_LANES.x, PARK_LANES.y) - attempt / 4
		var lane := rng.randf_range(PARK_LANE.x, PARK_LANE.y) * (1.0 - 0.1 * (attempt % 4))
		var r := PARK_STEP * 0.5
		var start := c - along * lane * 0.5 - down * PARK_STEP * (lanes - 1) * 0.5
		var pts := PackedVector2Array([start])
		var p := start
		var dir := along
		for i in lanes:
			var n := int(lane / 2.0)
			for k in n:
				p += dir * 2.0
				pts.append(p)
			if i == lanes - 1: break
			# полукруг к следующей прямой (вниз по склону)
			var center := p + down * r
			var a0 := (p - center).angle()
			var turn := signf(dir.cross(down)) # в сторону «вниз»
			var steps := int(PI * r / 2.0)
			for k in range(1, steps + 1):
				pts.append(center + Vector2.from_angle(a0 + turn * PI * k / steps) * r)
			p = pts[-1]
			dir = -dir
		var ok := true
		for q in pts:
			if not inside.call(q):
				ok = false
				break
		if ok and pts.size() > 40: return pts
	return PackedVector2Array()

## v4: канавы вдоль прямых участков — у края полотна с одной стороны, глубина DITCH_DEPTH, на концах сходят на нет.
static func _plan_ditches(d: TrailDefinition, f: Dictionary, rng: RandomNumberGenerator, chance: float) -> void:
	var length := d.route_length()
	var s := 30.0
	while s < length - 50.0:
		var span := rng.randf_range(DITCH_LENGTH.x, DITCH_LENGTH.y)
		if TrailStandards.tightest(d, s, s + span) < 60.0 or rng.randf() > chance:
			s += 12.0
			continue
		var side := 1.0 if rng.randf() < 0.5 else -1.0
		var offset := d.width * 0.5 + DITCH_OFFSET
		var pts := PackedVector2Array()
		var depth := PackedFloat32Array()
		var t := s
		while t <= s + span:
			pts.append(d.point_at(t) + d.tangent_at(t).orthogonal() * side * offset)
			depth.append(DITCH_DEPTH * smoothstep(0.0, 6.0, t - s) * smoothstep(0.0, 6.0, s + span - t))
			t += 4.0
		f.cuts.append({points = pts, depth = depth, half = 0.5, wall = 0.8})
		f.ditches += 1
		s += span + 30.0

## Наибольшее отклонение земли под осью от прямой между концами [from, to], м.
static func _relief(d: TrailDefinition, ground: Callable, from: float, to: float) -> float:
	var a := float(ground.call(d.point_at(from)))
	var b := float(ground.call(d.point_at(to)))
	var worst := 0.0
	var s := from
	while s <= to:
		worst = maxf(worst, absf(float(ground.call(d.point_at(s))) - lerpf(a, b, (s - from) / maxf(to - from, 0.01))))
		s += 2.0
	return worst

## Станции верхнего и нижнего прохода над одним местом (пересечение линии с собой), Vector2.ZERO — нет.
static func _self_crossing(d: TrailDefinition) -> Vector2:
	var grid := {}
	var length := d.route_length()
	var s := 0.0
	while s < length:
		var key := Vector2i((d.point_at(s) / 4.0).floor())
		if not grid.has(key): grid[key] = []
		(grid[key] as Array).append(s)
		s += 1.0
	var best := Vector2.ZERO
	var best_dist := 1.6
	s = 0.0
	while s < length:
		var at := d.point_at(s)
		var key := Vector2i((at / 4.0).floor())
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				for t: float in grid.get(key + Vector2i(ox, oz), []):
					if t - s < 60.0: continue
					var dist := d.point_at(t).distance_to(at)
					if dist < best_dist:
						best_dist = dist
						best = Vector2(s, t)
		s += 1.0
	return best

## v3: овражки поперёк трассы на прямых: гэп по стандарту, если скорость в его окне и уровень позволяет, иначе мосток.
## Под пролётом — открытый пролёт (природная земля, то есть сам овражек).
static func _plan_ravines(d: TrailDefinition, ground: Callable, level: int, f: Dictionary, rng: RandomNumberGenerator) -> void:
	var length := d.route_length()
	var v := TrailStandards.profile_from(d, TrailStandards.line_heights(d, ground), level, {}, false)
	var want := clampi(int(length / RAVINE_EVERY), 1, 6)
	var last := -INF
	var s := 60.0 + rng.randf() * 40.0
	while s < length - 50.0 and f.ravines < want:
		var clear := s - last >= RAVINE_GAP
		for r: Vector2 in f.reserved:
			if s + 20.0 > r.x - 10.0 and s - 20.0 < r.y + 10.0: clear = false
		if not clear or TrailStandards.tightest(d, s - 16.0, s + 16.0) < RAVINE_STRAIGHT:
			s += 6.0
			continue
		# земля вдоль оси на ±16 м гладкая (почти прямая): трасса идёт по ней, без больших насыпей
		if _relief(d, ground, s - 16.0, s + 16.0) > RAVINE_SMOOTH:
			s += 6.0
			continue
		var speed := v[clampi(int(s) - 12, 0, v.size() - 1)]
		var e: TrailElement = null
		var span := Vector3.ZERO
		var floor_half := 0.8
		var gap := TrailStandards.spec("gap", snappedf(speed, 0.5), level, TrailStandards.element_grade(d, ground, s - 12.0))
		if not gap.is_empty() and speed >= float(gap.get("speed_lo", 0.0)) - 0.5 and speed <= float(gap.get("speed_hi", INF)) + 0.5:
			e = TrailStandards.element(gap, 0.0)
			var start := s - (e.gap_lip() + e.gap * 0.5)
			e.station = start + e.length * 0.5
			span = Vector3(start + e.gap_lip() + 0.3, start + e.gap_lip() + e.gap - 0.3, RAVINE_DEPTH)
			floor_half = maxf(0.5, e.gap * 0.5 - 1.2)
			f.gaps += 1
		elif speed >= 4.0:
			e = TrailElementLibrary.make(TrailElement.Profile.NORTHSHORE, s, 14.0, 0.5, 1.0, 3, 0.75)
			e.gap = minf(2.4, d.width - 0.6)
			span = Vector3(s - 2.5, s + 2.5, RAVINE_DEPTH)
			f.decks += 1
		else:
			s += 6.0
			continue
		var lo := e.station - e.length * 0.5
		var hi := e.station + e.length * 0.5
		if lo < 20.0 or hi > length - 20.0:
			s += 6.0
			continue
		f.elements.append(e)
		f.spans.append(span)
		f.reserved.append(Vector2(lo, hi))
		var at := d.point_at(s)
		var n := d.tangent_at(s).orthogonal()
		f.cuts.append({points = PackedVector2Array([at - n * RAVINE_SPAN, at, at + n * RAVINE_SPAN]),
			depth = PackedFloat32Array([RAVINE_DEPTH * 0.7, RAVINE_DEPTH, RAVINE_DEPTH * 0.7]), half = floor_half, wall = 0.8})
		f.ravines += 1
		last = s
		s += RAVINE_GAP

## Индекс точек линии по клеткам SEP: {клетка: [Vector3(x, z, номер)]}.
static func _mark(grid: Dictionary, p: Vector2, index: int) -> void:
	var key := Vector2i((p / SEP).floor())
	if not grid.has(key): grid[key] = []
	(grid[key] as Array).append(Vector3(p.x, p.y, index))

## Своя линия ближе SEP к q, кроме последних OWN_SKIP м.
static func _near_own(grid: Dictionary, count: int, q: Vector2) -> bool:
	var last := count - int(OWN_SKIP / STEP)
	var key := Vector2i((q / SEP).floor())
	for oz in range(-1, 2):
		for ox in range(-1, 2):
			for e: Vector3 in grid.get(key + Vector2i(ox, oz), []):
				if int(e.z) < last and Vector2(e.x, e.y).distance_squared_to(q) < SEP * SEP: return true
	return false

## Чайкин: углы ломаной срезаются, концы остаются на месте.
static func _smooth(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	for i in pts.size() - 1:
		out.append(pts[i].lerp(pts[i + 1], 0.25))
		out.append(pts[i].lerp(pts[i + 1], 0.75))
	out.append(pts[-1])
	return out

static func _resample(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	var carry := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var span := a.distance_to(b)
		var t := step - carry
		while t <= span:
			out.append(a.lerp(b, t / span))
			t += step
		carry = span - (t - step)
	if out[-1].distance_to(pts[-1]) > 0.5: out.append(pts[-1])
	return out
