extends RefCounted
## Trail Lab, генератор трассы (01.11, первая версия — простая, будет часто меняться). По любой земле (Callable) в
## квадрате size × size м прокладывает одну линию сверху вниз и ставит на неё элементы составителем с расчётными
## стандартами (TrailComposer + TrailStandards): размер каждого элемента — под скорость седока в этом месте.
## 1. Старт — самая высокая точка внутри поля (с отступом MARGIN), финиш не задан: линия идёт, пока не кончится длина
##    или место.
## 2. Ходок (как у велопарка BikePark._walk, проще): шаг STEP м, веер направлений не круче радиуса MIN_RADIUS; цена —
##    отличие уклона от целевого уклона стиля, поперечный склон, отклонение от плавной «волны» изгибов, близость края и
##    своей же линии (взгляд вперёд LOOK). Упёрся — поворачивает в одну сторону: так выходят развороты-серпантины.
## 3. Линия сглаживается (Чайкин) и выбирается через 2 м; TrailDefinition как у готовых трасс лаборатории.
## 4. Элементы — TrailComposer с профилем стиля и standards = true; итог — в stats (длина, перепад, уклон, элементы,
##    отказы стандартов). Детерминирован по (земля, seed, стиль).
## Позже: тот же построитель на области настоящего мира (TrailLabTerrain → окно мира игры), выбор нескольких линий.

const MARGIN := 28.0
const STEP := 4.0
const MIN_RADIUS := 9.0
const LOOK := 20.0
const SEP := 14.0        # своя линия не ближе этого (кроме последних OWN_SKIP м)
const OWN_SKIP := 40.0
## Стили: целевой уклон (спуск — отрицательный), длина, ширина, профиль составителя, извилистость.
const STYLES := {
	flow = {title = "Flow", grade = -0.07, length = 1100.0, width = 4.5, profile = "flow", wander = 0.06},
	downhill = {title = "Даунхилл", grade = -0.14, length = 1000.0, width = 4.0, profile = "mountain", wander = 0.05},
	enduro = {title = "Эндуро", grade = -0.10, length = 1300.0, width = 3.5, profile = "mixed", wander = 0.08},
	tech = {title = "Техничная", grade = -0.09, length = 900.0, width = 3.5, profile = "technical", wander = 0.09},
}
const ORDER := ["flow", "downhill", "enduro", "tech"]

static var seed := 1
static var style := "flow"
static var stats := {}


## Трасса по земле ground на поле size × size м. Пусто — линия не проложилась (stats.reason).
static func build(ground: Callable, size: float, seed_value: int, style_name: String) -> Array[TrailDefinition]:
	var started := Time.get_ticks_usec()
	seed = seed_value
	style = style_name if STYLES.has(style_name) else "flow"
	var st: Dictionary = STYLES[style]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("trail_lab_builder|%d|%s" % [seed, style])
	stats = {}
	var inside := func(p: Vector2) -> bool: return p.x > MARGIN and p.y > MARGIN and p.x < size - MARGIN and p.y < size - MARGIN
	# старт — самая высокая из точек сетки через 16 м (с небольшим разбросом по сиду среди лучших)
	var tops: Array[Vector3] = []
	var at := MARGIN + 8.0
	while at < size - MARGIN:
		var bt := MARGIN + 8.0
		while bt < size - MARGIN:
			tops.append(Vector3(at, bt, float(ground.call(Vector2(at, bt)))))
			bt += 16.0
		at += 16.0
	tops.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.z > b.z)
	# направление — к низине: средняя точка самых низких клеток
	var low := Vector2.ZERO
	for k in mini(20, tops.size()): low += Vector2(tops[tops.size() - 1 - k].x, tops[tops.size() - 1 - k].y)
	low /= float(mini(20, tops.size()))
	# несколько стартов среди высоких точек (первый — по сиду) и два направления; самая длинная линия
	var pts := PackedVector2Array()
	var first := rng.randi() % mini(6, tops.size())
	var tries := 0
	for k in mini(5, tops.size()):
		var pick := tops[(first + k) % mini(12, tops.size())]
		var start := Vector2(pick.x, pick.y)
		for turn: float in [0.0, 0.6, -0.6]:
			tries += 1
			var line := _walk(ground, inside, start, (low - start).angle() + turn, float(st.length), float(st.grade), float(st.wander), rng)
			if line.size() > pts.size(): pts = line
			if pts.size() * STEP >= float(st.length) * 0.8: break
		if pts.size() * STEP >= float(st.length) * 0.8: break
	stats.tries = tries
	if pts.size() < 40:
		stats = {reason = "линия не проложилась: места хватило на %.0f м" % (pts.size() * STEP)}
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
	var profile: Dictionary = (TrailComposer.PROFILES[st.profile] as Dictionary).duplicate(true)
	profile.standards = true
	var composed := TrailComposer.compose(d, profile, seed * 7919 + 13, ground)
	d.elements.assign(composed.elements)
	d.sections.assign(composed.sections)
	var length := d.route_length()
	var drop := float(ground.call(line[0])) - float(ground.call(line[-1]))
	var speeds: PackedFloat32Array = composed.get("speeds", PackedFloat32Array())
	var top := 0.0
	var mean := 0.0
	for v in speeds:
		top = maxf(top, v)
		mean += v
	if not speeds.is_empty(): mean /= speeds.size()
	stats = {length = snappedf(length, 1.0), drop = snappedf(drop, 0.1), grade = snappedf(-drop / maxf(length, 1.0) * 100.0, 0.1),
		elements = d.elements.size(), refused = composed.get("refused", {}), speed_top = snappedf(top, 0.1), speed_mean = snappedf(mean, 0.1),
		ms = (Time.get_ticks_usec() - started) / 1000.0, title = st.title, tries = stats.get("tries", 1)}
	return [d]

## Строка для подписи: стиль, сид, длина, перепад, элементы.
static func label() -> String:
	if stats.is_empty(): return ""
	if stats.has("reason"): return str(stats.reason)
	return "%s · сид %d · %.0f м, −%.0f м (%.1f %%) · элементов %d · скорость до %.0f м/с" % [stats.title, seed, stats.length, stats.drop, absf(stats.grade), stats.elements, stats.speed_top]


static func _walk(ground: Callable, inside: Callable, start: Vector2, heading: float, length: float, grade: float, wander: float, rng: RandomNumberGenerator) -> PackedVector2Array:
	var pts := PackedVector2Array([start])
	var p := start
	var a := heading
	var s := 0.0
	var ph := Vector2(rng.randf() * TAU, rng.randf() * TAU)
	var max_turn := STEP / MIN_RADIUS
	var bend := 0.0
	var stuck := 0
	var grid := {}
	_mark(grid, start, 0)
	while s < length:
		var want := (wander * sin(s / 47.0 + ph.x) + wander * 0.6 * sin(s / 19.0 + ph.y)) * STEP
		var best := INF
		var best_o := 0.0
		for k in 13:
			var o := -max_turn + max_turn * k / 6.0
			var dir := Vector2.from_angle(a + o)
			var next := p + dir * STEP
			if not inside.call(next) or _near_own(grid, pts.size(), next): continue
			var g := (float(ground.call(next)) - float(ground.call(p))) / STEP
			var side := Vector2(-dir.y, dir.x)
			var cross := absf(float(ground.call(next + side * 2.0)) - float(ground.call(next - side * 2.0))) / 4.0
			# уклон к цели стиля (подъём — дорого), поперечный склон, плавность и «волна» изгибов
			var cost := absf(g - grade) * 30.0 + maxf(0.0, g) * 60.0 + maxf(0.0, cross - 0.25) * 8.0 + absf(o - want) * 1.5
			for j in range(1, 5):
				var ahead := p + dir * (STEP + LOOK * j / 4.0)
				if not inside.call(ahead) or _near_own(grid, pts.size(), ahead):
					cost += 30.0 / j - (1.0 if signf(o) == signf(bend) else 0.0)
					break
			if cost < best:
				best = cost
				best_o = o
		if best == INF:
			# упёрлись: тугой разворот на месте (до полукруга), потом сдаёмся
			stuck += 1
			if stuck > 8: break
			a += max_turn * 1.5 * (1.0 if bend >= 0.0 else -1.0)
			continue
		stuck = 0
		a += best_o
		bend = best_o
		p += Vector2.from_angle(a) * STEP
		s += STEP
		pts.append(p)
		_mark(grid, p, pts.size() - 1)
	return pts

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
