extends RefCounted
## Главный полигон Trail Lab (30.10): длинная flow-трасса на своей местности 512 × 512 м — склон с холмами и оврагом.
## Линия задана опорными точками со скруглениями (радиус у каждой точки), элементы расставлены по участкам вручную:
## у каждого участка своя задача (разгон, ритм, прыжок, памп на ровном, техника в овраге, финальный flow).
## Трасса двухуровневая: в начале она перепрыгивает овраг вниз по склону, а позже идёт по дну этого же оврага
## и проезжает под местом прыжка. Земля на пересечении остаётся природной (TrailDefinition.junction_weight),
## поэтому над нижним проездом — настоящий разрыв: перелёт с кикера на склон приземления.

## Сторона полигона в клетках мира (по 4 м) и метрах.
const CELLS := 128
const SIZE := CELLS * 4.0

## Опорные точки: x, z (м) и радиус скругления (м). Склон падает к малым z.
const WAYPOINTS := [
	# 0–4 · разгон по верхней полке: широкая S-связка, роллеры и первый стол
	Vector3(60, 494, 0), Vector3(150, 486, 60), Vector3(250, 476, 45), Vector3(340, 470, 40),
	# 4–5 · шпилька вправо на виражах
	Vector3(445, 460, 22), Vector3(452, 424, 22),
	# 6–7 · ритм: памп, двойной стол, роллеры
	Vector3(360, 418, 50), Vector3(255, 414, 45),
	# 8–9 · шпилька влево, 10–11 · виражи на заход к оврагу
	Vector3(150, 408, 20), Vector3(146, 378, 20), Vector3(215, 374, 18), Vector3(258, 372, 16),
	# 12 · приземление за оврагом и вираж влево; 13 · контур по склону (памп, контруклон)
	Vector3(262, 300, 18), Vector3(335, 292, 50),
	# 14–15 · шпилька влево в верховье оврага
	Vector3(430, 290, 16), Vector3(452, 318, 16),
	# 16–18 · дно оврага (под местом прыжка), 19 · выход из оврага
	Vector3(380, 328, 60), Vector3(180, 332, 50), Vector3(122, 314, 30), Vector3(100, 266, 25),
	# 20–22 · нижний flow: роллеры, стол, норшор, виражи
	Vector3(150, 238, 60), Vector3(280, 230, 50), Vector3(405, 214, 22),
	# 23–25 · финальная шпилька, дропы и спринт к финишу
	Vector3(428, 165, 24), Vector3(340, 120, 34), Vector3(410, 62, 0),
]

## Овраг: русло идёт по оси трассы между этими опорными точками (дно — по уклону FLOOR_GRADE от верховья).
const RAVINE_FROM := 15
const RAVINE_TO := 19
const FLOOR_GRADE := 0.012
const FLOOR_HALF := 3.0   # половина ширины дна, м
const WALL := 1.1          # заложение стенок: метров по горизонтали на метр глубины
static var _cache := {}

## Земля полигона: склон 20 % к малым z, пологие холмы и врезанный овраг.
static func ground(at: Vector2) -> float:
	var base := _base(at)
	var ravine := _ravine()
	var near := ravine.axis.nearest(at, 30.0) as Vector3
	if not is_finite(near.z): return base
	var floor_level: float = ravine.top - FLOOR_GRADE * near.x
	var depth := maxf(0.0, base - floor_level)
	if depth <= 0.0: return base
	var shape := 1.0 - smoothstep(FLOOR_HALF, FLOOR_HALF + depth * WALL + 1.0, near.z)
	return base - depth * shape

static func _base(at: Vector2) -> float:
	var hills := 1.6 * sin(at.x / 53.0) * sin(at.y / 71.0) + 0.7 * sin((at.x + at.y) / 29.0)
	return 12.0 + at.y * 0.2 + hills

## Ось русла — участок линии трассы по дну; верх русла — земля в его начале.
static func _ravine() -> Dictionary:
	if _cache.has("ravine"): return _cache.ravine
	var line := _line()
	var stations: PackedFloat32Array = line.corners
	var d := TrailDefinition.new()
	d.id = "ravine"
	var pts := PackedVector2Array()
	var full := TrailDefinition.new()
	full.points = line.points
	var s: float = stations[RAVINE_FROM]
	while s <= stations[RAVINE_TO]:
		pts.append(full.point_at(s))
		s += 2.0
	d.points = pts
	_cache.ravine = {axis = d, top = _base(pts[0])}
	return _cache.ravine

## Скруглённая линия по опорным точкам: точки через ~1 м на дугах и 2 м на прямых, станции середин дуг (corners)
## и длины дуг (arcs) по номерам опорных точек.
static func _line() -> Dictionary:
	if _cache.has("line"): return _cache.line
	var pts: Array[Vector2] = []
	var corners := PackedFloat32Array()
	var arcs := PackedFloat32Array()
	corners.resize(WAYPOINTS.size())
	arcs.resize(WAYPOINTS.size())
	var marks := PackedInt32Array() # номер точки линии у середины дуги каждой опорной точки
	marks.resize(WAYPOINTS.size())
	pts.append(Vector2(WAYPOINTS[0].x, WAYPOINTS[0].y))
	var calm := _calm_point()
	for i in range(1, WAYPOINTS.size()):
		var p := Vector2(WAYPOINTS[i].x, WAYPOINTS[i].y)
		if i == WAYPOINTS.size() - 1:
			_straight(pts, p, MEANDER.get(i - 1, 0.0), calm)
			marks[i] = pts.size() - 1
			break
		var prev := Vector2(WAYPOINTS[i - 1].x, WAYPOINTS[i - 1].y)
		var next := Vector2(WAYPOINTS[i + 1].x, WAYPOINTS[i + 1].y)
		var u := (p - prev).normalized()
		var v := (next - p).normalized()
		var turn := u.angle_to(v)
		var t := float(WAYPOINTS[i].z) * tan(absf(turn) * 0.5)
		t = minf(t, minf(pts[-1].distance_to(p), p.distance_to(next) * 0.5))
		var r := t / maxf(tan(absf(turn) * 0.5), 0.0001)
		var a := p - u * t
		_straight(pts, a, MEANDER.get(i - 1, 0.0), calm)
		var center := a + u.rotated(signf(turn) * PI * 0.5) * r
		var arc := absf(turn) * r
		var n := maxi(1, ceili(arc))
		marks[i] = pts.size() - 1 + n / 2
		arcs[i] = arc
		for k in range(1, n + 1):
			pts.append(center + (a - center).rotated(turn * k / n))
	var along := 0.0
	for k in pts.size():
		if k > 0: along += pts[k - 1].distance_to(pts[k])
		for i in marks.size():
			if marks[i] == k: corners[i] = along
	_cache.line = {points = PackedVector2Array(pts), corners = corners, arcs = arcs}
	return _cache.line

## Извилины длинных прямых: амплитуда, м, по номеру опорной точки, с которой начинается прямая. Волна около 70 м,
## на концах прямой смещение и его наклон нулевые — дуги опорных точек не ломаются. Без извилин: разгон к оврагу (11)
## и спуск после него, у нижнего проезда под местом прыжка (calm) прямая тоже остаётся прямой.
const MEANDER := {0: 4.0, 1: 4.0, 2: 3.5, 3: 4.0, 6: 4.5, 12: 3.0, 13: 4.0, 16: 4.0, 19: 3.0, 20: 5.0, 21: 4.5, 24: 3.5}
const WAVE := 70.0
const CALM := 22.0

## Прямая от последней точки до p через ~2 м, с извилинами амплитуды amp.
static func _straight(pts: Array[Vector2], p: Vector2, amp: float, calm: Vector2) -> void:
	var from := pts[-1]
	var span := from.distance_to(p)
	if span < 0.01: return
	var side := (p - from).normalized().orthogonal()
	var waves := maxf(1.0, roundf(span / WAVE * 2.0))
	# на коротких прямых извилина дала бы тугой изгиб (радиус меньше 20 м): там её нет
	amp *= clampf((span - 45.0) / 45.0, 0.0, 1.0)
	var n := maxi(1, ceili(span / 2.0))
	for k in range(1, n + 1):
		var u := float(k) / n
		var at := from.lerp(p, u)
		var quiet := 1.0 - exp(-pow(at.distance_to(calm) / CALM, 2.0))
		pts.append(at + side * amp * sin(PI * waves * u) * pow(sin(PI * u), 2.0) * quiet)

## Точка, где разгон к оврагу (опоры 11–12) пересекает дно оврага (опоры 16–17).
static func _calm_point() -> Vector2:
	var w := func(i: int) -> Vector2: return Vector2(WAYPOINTS[i].x, WAYPOINTS[i].y)
	var hit: Variant = Geometry2D.segment_intersects_segment(w.call(11), w.call(12), w.call(16), w.call(17))
	return hit if hit != null else Vector2(INF, INF)

## Трасса полигона с элементами.
static func route() -> TrailDefinition:
	var line := _line()
	var d := TrailDefinition.new()
	d.id = "course_polygon"
	d.title = "Главный полигон"
	d.kind = "mountain"
	d.width = 4.5
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	d.points = line.points
	d.elements = elements(d, line.corners, line.arcs)
	return d

## Элементы по участкам. c(k) — середина дуги у опорной точки k, between(k, f) — доля пути от точки k к следующей.
static func elements(d: TrailDefinition, corners: PackedFloat32Array, arcs: PackedFloat32Array) -> Array[TrailElement]:
	var T := TrailElement.Profile
	var list: Array[TrailElement] = []
	var c := func(k: int) -> float: return corners[k]
	var between := func(k: int, f: float) -> float: return lerpf(corners[k], corners[k + 1], f)
	var berm := func(k: int, height: float) -> void:
		var span := clampf(arcs[k] + 8.0, 12.0, 40.0)
		list.append(TrailElementLibrary.make(T.BERM, corners[k], span, height, signf(d.curvature_at(corners[k]))))
	var put := func(profile: int, station: float, length: float, height: float, count := 3, skew := 0.35) -> TrailElement:
		var e := TrailElementLibrary.make(profile, station, length, height, 1.0, count, skew)
		list.append(e)
		return e

	# — Разгон: пологие роллеры на прямой, S-связка на виражах, первый невысокий стол перед шпилькой
	put.call(T.ROLLER, between.call(0, 0.35), 12.0, 0.35)
	put.call(T.ROLLER, between.call(0, 0.65), 12.0, 0.45)
	berm.call(1, 0.5)
	put.call(T.WAVES, between.call(1, 0.5), 30.0, 0.25, 3)
	berm.call(2, 0.6)
	put.call(T.TABLETOP, between.call(2, 0.5), 16.0, 0.8)
	berm.call(3, 0.6)
	put.call(T.ROLLER, between.call(3, 0.45), 13.0, 0.5)
	# шпилька: тормозим до неё на ровном, сами виражи высокие
	berm.call(4, 1.1)
	berm.call(5, 1.1)
	# — Ритм: памп сразу после шпильки возвращает скорость, дальше двойной стол и смена уклона
	put.call(T.PUMP, between.call(5, 0.3), 22.0, 0.45, 4)
	put.call(T.TABLETOP, between.call(5, 0.62), 14.0, 0.7)
	put.call(T.TABLETOP, between.call(5, 0.82), 14.0, 0.7)
	berm.call(6, 0.6)
	put.call(T.ROLLOVER, between.call(6, 0.35), 12.0, 0.6, 3, 0.3)
	put.call(T.ROOTS, between.call(6, 0.6), 12.0, 0.1)
	berm.call(7, 0.6)
	# шпилька влево; перед ней только корни и ровное полотно
	berm.call(8, 1.1)
	berm.call(9, 1.1)
	# — Заход на овраг: два виража подряд разворачивают на спуск, затем прямой разгон по склону к кикеру
	put.call(T.RIPPLES, between.call(9, 0.5), 14.0, 0.06)
	berm.call(10, 0.9)
	berm.call(11, 0.9)
	# Прыжок через овраг. Насыпь трассы держит полотно над оврагом, а у нижнего проезда (2,25–5,25 м от его оси,
	# junction_weight) земля остаётся природной — это и есть разрыв. Кикер — передняя половина роллера: самый крутой
	# его участок приходится на край разрыва, задняя половина уходит в разрыв. Приземление — в спуск впадины за разрывом,
	# её подъём гасит удар. Автопилот на 56 км/ч (разгон по спуску к оврагу без тормоза): полёт 0,8 с, удар 4,9 м/с.
	var gap := _crossing(d)
	put.call(T.ROLLER, gap - 2.1, 13.0, 2.0)
	put.call(T.DIP, gap + 10.0, 16.0, 1.5)
	# — Приземление и контур: вираж сразу после посадки, памп на почти ровной полке, контруклон в пологой дуге
	berm.call(12, 1.0)
	put.call(T.PUMP, between.call(12, 0.55), 24.0, 0.45, 5)
	var off := TrailElementLibrary.make(T.OFF_CAMBER, c.call(13), 20.0, 0.5, signf(d.curvature_at(c.call(13))))
	list.append(off)
	put.call(T.WAVES, between.call(13, 0.55), 27.0, 0.3, 3)
	berm.call(14, 1.1)
	berm.call(15, 1.1)
	# — Овраг: после шпильки, пока скорость невысокая, — колеи, бревно поперёк русла и камни; дальше по прямой под
	# местом прыжка полотно чистое, а впадины русла дают качнуть скорость
	put.call(T.RUTS, c.call(16) - 34.0, 16.0, 0.15)
	put.call(T.LOG, c.call(16) - 12.0, 10.0, 0.22)
	put.call(T.ROCK_GARDEN, between.call(16, 0.12), 16.0, 0.12)
	put.call(T.WAVES, between.call(16, 0.72), 27.0, 0.3, 3)
	berm.call(17, 0.7)
	put.call(T.NARROW, between.call(17, 0.4), 10.0, 0.45).gap = 2.0
	berm.call(18, 0.8)
	berm.call(19, 0.9)
	# — Нижний flow: роллеры по нарастающей, большой стол, норшор на ровном месте
	put.call(T.ROLLER, between.call(19, 0.4), 12.0, 0.4)
	put.call(T.ROLLER, between.call(19, 0.75), 13.0, 0.55)
	berm.call(20, 0.6)
	put.call(T.TABLETOP, between.call(20, 0.3), 18.0, 0.9)
	var shore := put.call(T.NORTHSHORE, between.call(20, 0.65), 20.0, 0.9) as TrailElement
	shore.gap = 1.4
	berm.call(21, 0.6)
	put.call(T.WAVES, between.call(21, 0.5), 30.0, 0.3, 3)
	berm.call(22, 1.1)
	berm.call(23, 1.1)
	# — Финал: дроп с полки, S-вираж, спринт по роллерам к финишу
	put.call(T.DROP, between.call(23, 0.45), 14.0, 0.7)
	berm.call(24, 0.8)
	put.call(T.ROLLER, between.call(24, 0.35), 12.0, 0.45)
	put.call(T.TABLETOP, between.call(24, 0.62), 16.0, 0.8)
	list.sort_custom(func(a: TrailElement, b: TrailElement) -> bool: return a.station < b.station)
	return list

## Станция верхнего прохода над оврагом: ближайшая к оси русла точка участка между опорами 11 и 12.
static func _crossing(d: TrailDefinition) -> float:
	var line := _line()
	var axis: TrailDefinition = _ravine().axis
	var best := INF
	var station := 0.0
	var s: float = line.corners[11]
	while s < line.corners[12]:
		var gap := axis.nearest(d.point_at(s), 40.0).z
		if gap < best:
			best = gap
			station = s
		s += 0.5
	return station
