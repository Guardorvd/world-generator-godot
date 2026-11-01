extends RefCounted
const TrailStandards := preload("res://scripts/trails/trail_standards.gd")
## Trail Lab, генератор трассы, v2 (01.11). По любой земле (Callable) в квадрате size × size м прокладывает одну
## линию сверху вниз и ставит на неё элементы составителем с расчётными стандартами (TrailComposer + TrailStandards).
## v2 по заездам 01.11 (v1: 2/3 поворотов R ≈ 10 м на 13–17 м/с, вылеты наружу, падение с откоса, похожие линии):
##  1. Старт и цель — по сиду: старт среди верхней пятой части поля, цель — среди нижней трети не ближе половины поля;
##     линию тянет к цели с силой pull, извилистость и её период — тоже по сиду. Разные сиды на одной местности —
##     разные трассы (свои старт, цель и рисунок).
##  2. Ходок знает скорость: на каждом шаге — скорость «как едут» (уклон, педали до крейсерской стиля, без торможения
##     заранее), и поворот за шаг не круче радиуса v² / a (a — перегрузка уровня стиля с запасом). Тугой разворот —
##     только когда упёрлись; там скорость сбрасывается до разворотной (седок тормозит), а составитель ставит вираж.
##  3. Под местность: целевой уклон стиля смягчается на пологой земле и не круче на крутой; поперечный склон и обрыв с
##     наружной стороны поворота дороги (откос > CLIFF на 5 м) — в цену шага.
##  4. Линия сглаживается (Чайкин) и выбирается через 2 м. Элементы — составитель со стандартами; повороты, которые на
##     скорости седока не пройти, получают вираж (TrailComposer._berm_turns). Итог — в stats.
## Детерминирован по (земля, seed, стиль). Позже: окно настоящего мира, несколько линий, примыкание к дорогам.

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
}
const ORDER := ["flow", "downhill", "enduro", "tech"]

static var seed := 1
static var style := "flow"
static var stats := {}
static var speeds := PackedFloat32Array() ## профиль скорости «как едут», по которому ставились элементы


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
	var shape := {pull = rng.randf_range(0.15, 0.6), wander = float(st.wander) * rng.randf_range(0.6, 1.5),
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
	for k in 10:
		tries += 1
		var s0: Vector3 = upper[rng.randi() % upper.size()]
		var start := Vector2(s0.x, s0.y)
		var g0: Vector3 = lower[rng.randi() % lower.size()]
		for j in 6:
			if Vector2(g0.x, g0.y).distance_to(start) >= size * 0.45: break
			g0 = lower[rng.randi() % lower.size()]
		var target := Vector2(g0.x, g0.y)
		var line := _walk(ground, inside, start, target, float(st.length), grade, shape, st, rng, lower)
		# лучшая попытка — по длине и спуску вместе (v2: v1 брала самую длинную, и линия могла уйти по горизонтали)
		var score := _score(line, ground, float(st.length), grade)
		if score > best_score:
			best_score = score
			pts = line
			goal = target
		if best_score > 1.5: break
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
	if not d.validate().is_empty():
		# виражи составителя не прошли проверку определения — без них (элементы составителя проверены сами)
		d.elements.assign(d.elements.filter(func(e: TrailElement) -> bool: return e.profile != TrailElement.Profile.BERM))
	var length := d.route_length()
	var drop := float(ground.call(line[0])) - float(ground.call(line[-1]))
	speeds = composed.get("speeds", PackedFloat32Array())
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
		elements = d.elements.size(), refused = composed.get("refused", {}), berms = composed.get("berms", 0), speed_top = snappedf(top, 0.1),
		speed_mean = snappedf(mean, 0.1), radius_median = snappedf(float(radii[radii.size() / 2]) if not radii.is_empty() else 0.0, 0.1),
		start = line[0], goal = goal, target_grade = snappedf(grade * 100.0, 0.1), pull = snappedf(shape.pull, 0.01),
		ms = (Time.get_ticks_usec() - started) / 1000.0, title = st.title, tries = tries}
	return [d]

## Строка для подписи: стиль, сид, длина, перепад, элементы.
static func label() -> String:
	if stats.is_empty(): return ""
	if stats.has("reason"): return str(stats.reason)
	return "%s · сид %d · %.0f м, %+.0f м (%.1f %%) · элементов %d (виражей %d) · скорость до %.0f м/с" % [stats.title, seed, stats.length, -stats.drop, -stats.grade, stats.elements, stats.berms, stats.speed_top]


## Оценка линии: доля нужной длины (до 1) плюс доля ожидаемого спуска (до 1); подъём в итоге — минус.
static func _score(line: PackedVector2Array, ground: Callable, length: float, grade: float) -> float:
	if line.size() < 2: return -INF
	var run := line.size() * STEP
	var drop := float(ground.call(line[0])) - float(ground.call(line[-1]))
	# спуск — относительно ожидаемого на всю длину стиля: короткая крутая линия не выигрывает у полной
	return minf(run / length, 1.0) + clampf(drop / maxf(1.0, length * -grade), -1.0, 1.0)

static func _walk(ground: Callable, inside: Callable, start: Vector2, goal: Vector2, length: float, grade: float, shape: Dictionary, st: Dictionary, rng: RandomNumberGenerator, lower: Array = []) -> PackedVector2Array:
	var pts := PackedVector2Array([start])
	var p := start
	var a := (goal - start).angle()
	var s := 0.0
	var ph: Vector2 = shape.phase
	var period: Vector2 = shape.period
	var wander: float = shape.wander
	var cruise: float = st.cruise
	var accel: float = TrailStandards.LAT_MAX * float(st.lat) + 1.5 # наклон полотна трассы добавляет немного
	var v := 3.0
	var bend := 0.0
	var stuck := 0
	var grid := {}
	_mark(grid, start, 0)
	while s < length:
		if p.distance_to(goal) < GOAL_REACH:
			# у цели линия кончается; рано (крутой стиль быстро сходит вниз) — новая цель, самая дальняя из низких
			if s >= length * 0.6 or lower.is_empty(): break
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
