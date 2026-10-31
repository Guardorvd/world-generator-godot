extends RefCounted
## Трасса 18 Trail Lab (30.10): «Большой спуск» — длинный маршрут байк-парка на своей горе 512 × 512 м, от открытого
## гребня через лес к долине, около 3,5 км. Устроена как главный полигон (scripts/lab/trail_lab_polygon.gd): опорные
## точки со скруглениями, извилины длинных прямых, элементы по участкам вручную, природная земля на пересечениях.
## Пять глав, у каждой свой характер, переходы между ними — виражом или ровной площадкой:
##   1. Гребень — открытый луг на вершине: разгон, столы по нарастающей, памп, первый дроп, высокая шпилька.
##   2. Опушка — ритм: памп, двойной стол, норшор-«нитка», каменный траверс, дроп перед шпилькой.
##   3. Ущелье — прыжок через ущелье вниз по склону и, позже, проезд по его дну прямо под местом прыжка: каменистый
##      спуск, камни, памп по впадинам русла, колеи, бревно, узкая линия.
##   4. Терраса — деревянный мост над выемкой, петля из трёх виражей и нижний проход под этим мостом.
##   5. Долина — быстрый финал: деревянный кикер, большой дроп, линия из трёх столов, S-вираж, каменная плита,
##      ступенька вниз и финишный стол.

const Polygon = preload("res://scripts/lab/trail_lab_polygon.gd")
const CELLS := Polygon.CELLS
const SIZE := Polygon.SIZE

## Опорные точки: x, z (м) и радиус скругления (м). Гора падает к малым z.
const WAYPOINTS := [
	# 0–3 · гребень: разгон по вершине, к 4–5 — шпилька вправо
	Vector3(36, 500, 0), Vector3(150, 492, 60), Vector3(270, 486, 50), Vector3(380, 478, 40),
	Vector3(468, 470, 22), Vector3(474, 436, 22),
	# 6–8 · опушка на запад, 9–10 · шпилька влево
	Vector3(372, 432, 50), Vector3(262, 428, 45), Vector3(150, 424, 40), Vector3(52, 418, 20), Vector3(48, 388, 20),
	# 11–12 · виражи на заход к ущелью; 12→13 — прыжок через ущелье вниз по склону
	Vector3(150, 384, 30), Vector3(232, 392, 16),
	# 13 · приземление и вираж влево, 14 · контур, 15–16 · шпилька в верховье ущелья
	Vector3(244, 300, 18), Vector3(345, 292, 50), Vector3(440, 292, 16), Vector3(458, 326, 16),
	# 17–19 · дно ущелья (17→18 — под местом прыжка), 20 · выход из ущелья
	Vector3(372, 344, 60), Vector3(176, 350, 50), Vector3(112, 334, 30), Vector3(92, 286, 25),
	# 21–22 · на террасу, 22→23 — мост; 23–25 · петля на трёх виражах; 25→26 — в выемку под мост и с террасы
	Vector3(162, 258, 50), Vector3(250, 254, 40), Vector3(346, 250, 18), Vector3(352, 284, 18), Vector3(276, 288, 16),
	# 26–28 · долина: кикер, шпилька; 28→29 · дроп и столы, 29→30 · S-вираж, 31–32 · шпилька, 32→34 · финиш
	Vector3(272, 200, 22), Vector3(440, 186, 24), Vector3(466, 146, 20), Vector3(332, 134, 40), Vector3(186, 126, 45),
	Vector3(60, 110, 20), Vector3(70, 62, 20), Vector3(250, 50, 45), Vector3(446, 34, 0),
]

## Терраса под петлёй с мостом и выемка нижнего прохода (как у полигона).
const TERRACE := Rect2(236, 238, 136, 62)
const TERRACE_FADE := 22.0
const CUT_DEPTH := 2.6
const CUT_FULL := 8.0
const CUT_FADE := 22.0
## Ущелье: русло по оси трассы между опорными точками, дно с уклоном FLOOR_GRADE от верховья.
const RAVINE_FROM := 16
const RAVINE_TO := 20
const FLOOR_GRADE := 0.012
const FLOOR_HALF := 3.0
const WALL := 1.1
const DEPTH_MAX := 100.0
## Выше этой линии (z, м) — открытый гребень: лес редкий, видно долину.
const MEADOW := 445.0
static var _cache := {}

## Земля: склон 24 % к малым z с вершинным куполом, отрогом и волнами холмов; терраса, ущелье и выемка под мостом.
static func ground(at: Vector2) -> float:
	var base := _base(at)
	var ravine := _ravine()
	var near := ravine.axis.nearest(at, 30.0) as Vector3
	if is_finite(near.z):
		var floor_level: float = ravine.top - FLOOR_GRADE * near.x
		# глубже DEPTH_MAX дно идёт по склону, а не по уровню верховья: ущелье не превращается в каньон
		var depth := clampf(base - floor_level, 0.0, DEPTH_MAX)
		base -= depth * (1.0 - smoothstep(FLOOR_HALF, FLOOR_HALF + depth * WALL + 1.0, near.z))
	var cut: Dictionary = _cut()
	var lane := (cut.axis as TrailDefinition).nearest(at, 12.0)
	if is_finite(lane.z):
		var depth: float = CUT_DEPTH * (1.0 - smoothstep(CUT_FULL, CUT_FULL + CUT_FADE, absf(lane.x - cut.under)))
		base -= depth * (1.0 - smoothstep(FLOOR_HALF, FLOOR_HALF + depth * 0.7 + 0.5, lane.z))
	return base

static func _base(at: Vector2) -> float:
	var slope := _slope(at) - _landing_step(at)
	var outside := Vector2(maxf(maxf(TERRACE.position.x - at.x, at.x - TERRACE.end.x), 0.0),
		maxf(maxf(TERRACE.position.y - at.y, at.y - TERRACE.end.y), 0.0)).length()
	var level := _slope(Vector2(TERRACE.position.x + 15.0, TERRACE.position.y + 14.0))
	return lerpf(level, slope, smoothstep(0.0, TERRACE_FADE, outside))

## Ровная полка разгона перед ущельем: на склоне 24 % передняя половина роллера только выравнивала бы спуск и не
## подбрасывала; с полки кикер даёт настоящий взлёт, а дальний край ущелья ниже — прыжок со ступенькой вниз.
const RUNWAY := Rect2(210, 354, 48, 44)
const RUNWAY_FADE := 16.0
static func _shelf(at: Vector2, rect: Rect2, fade: float, ground_y: float) -> float:
	var outside := Vector2(maxf(maxf(rect.position.x - at.x, at.x - rect.end.x), 0.0),
		maxf(maxf(rect.position.y - at.y, at.y - rect.end.y), 0.0)).length()
	return lerpf(_slope(rect.get_center()), ground_y, smoothstep(0.0, fade, outside))

## Ступень за ущельем: дальний (нижний) край у места прыжка ниже природного склона на LANDING_STEP — с кикера
## перелёт приходит на спуск, а не в стенку. Без неё на 16 м/с не хватало около метра высоты.
const LANDING_STEP := 2.2
static func _landing_step(at: Vector2) -> float:
	var hit: Variant = Geometry2D.segment_intersects_segment(Vector2(WAYPOINTS[12].x, WAYPOINTS[12].y), Vector2(WAYPOINTS[13].x, WAYPOINTS[13].y),
		Vector2(WAYPOINTS[17].x, WAYPOINTS[17].y), Vector2(WAYPOINTS[18].x, WAYPOINTS[18].y))
	if hit == null: return 0.0
	var c: Vector2 = hit
	return LANDING_STEP * (1.0 - smoothstep(30.0, 60.0, at.distance_to(c))) * smoothstep(3.0, 9.0, c.y - at.y)

## Гора: ровный склон, купол вершины у старта, восточный отрог над долиной и мелкие холмы.
static func _slope(at: Vector2) -> float:
	var dome := 6.0 * exp(-((at - Vector2(120, 500)) / Vector2(160, 70)).length_squared())
	var spur := 4.0 * exp(-pow((at.x - 430.0) / 70.0, 2.0)) * smoothstep(90.0, 220.0, at.y) * (1.0 - smoothstep(260.0, 330.0, at.y))
	var hills := 1.8 * sin(at.x / 57.0) * sin(at.y / 67.0) + 0.8 * sin((at.x - at.y) / 31.0)
	return 10.0 + at.y * 0.2 + dome + spur + hills

## Лес полигона до края полотна; на гребне — редколесье (каждый пятый объект), открытый луг с видом вниз.
static func forest(w: WorldData, routes: Array[TrailDefinition]) -> void:
	Polygon.forest(w, routes)
	var chunks := w.chunks
	for c in chunks.size():
		var kept := PackedInt32Array()
		for o in chunks[c]:
			if w.obj_y[o] * GameConfig.TILE < MEADOW or o % 5 == 0: kept.append(o)
		chunks[c] = kept
	w.chunks = chunks

static func _cut() -> Dictionary:
	if _cache.has("cut"): return _cache.cut
	var line := _line()
	var full := TrailDefinition.new()
	full.points = line.points
	var d := TrailDefinition.new()
	d.id = "cut"
	var pts := PackedVector2Array()
	var s: float = line.corners[25]
	while s <= line.corners[26]:
		pts.append(full.point_at(s))
		s += 2.0
	d.points = pts
	var bridge := Polygon._cross(full, line.corners[22], line.corners[23], d)
	_cache.cut = {axis = d, under = d.nearest(full.point_at(bridge)).x}
	return _cache.cut

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

## Скруглённая линия по опорным точкам (как у полигона): станции середин дуг и длины дуг по номерам точек.
static func _line() -> Dictionary:
	if _cache.has("line"): return _cache.line
	var pts: Array[Vector2] = []
	var corners := PackedFloat32Array()
	var arcs := PackedFloat32Array()
	corners.resize(WAYPOINTS.size())
	arcs.resize(WAYPOINTS.size())
	var marks := PackedInt32Array()
	marks.resize(WAYPOINTS.size())
	pts.append(Vector2(WAYPOINTS[0].x, WAYPOINTS[0].y))
	var calm := _calm_points()
	for i in range(1, WAYPOINTS.size()):
		var p := Vector2(WAYPOINTS[i].x, WAYPOINTS[i].y)
		if i == WAYPOINTS.size() - 1:
			Polygon._straight(pts, p, MEANDER.get(i - 1, 0.0), calm)
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
		Polygon._straight(pts, a, MEANDER.get(i - 1, 0.0), calm)
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

## Извилины длинных прямых по номеру точки, с которой начинается прямая. Без извилин: разгон к ущелью (11, 12),
## мост (22), выемка (25), прямая дропа и столов (28).
## 31.10: в полтора раза сильнее (радиус около 20 м), как у полигона: прямые — flow-перекладки, гэпы на них — трансферы.
const MEANDER := {0: 6.0, 1: 6.5, 2: 6.0, 5: 6.5, 6: 6.0, 7: 6.0, 13: 6.0, 17: 5.5, 20: 4.5, 21: 5.5, 26: 6.5, 28: 5.0, 29: 6.0, 32: 6.5, 33: 6.0}

## Пересечения: прыжок (12–13) над дном ущелья (17–18), мост (22–23) над выемкой (25–26).
static func _calm_points() -> Array[Vector2]:
	var w := func(i: int) -> Vector2: return Vector2(WAYPOINTS[i].x, WAYPOINTS[i].y)
	var result: Array[Vector2] = []
	for pair: Array in [[12, 17], [22, 25]]:
		var hit: Variant = Geometry2D.segment_intersects_segment(w.call(pair[0]), w.call(pair[0] + 1), w.call(pair[1]), w.call(pair[1] + 1))
		if hit != null: result.append(hit)
	return result

static func route() -> TrailDefinition:
	var line := _line()
	var d := TrailDefinition.new()
	d.id = "course_epic"
	d.title = "Большой спуск"
	d.kind = "mountain"
	d.width = 4.5
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	d.points = line.points
	d.elements = elements(d, line.corners, line.arcs)
	return d

## Станция прыжка над ущельем (для проб и автопилота).
static func crossing(d: TrailDefinition) -> float:
	var line := _line()
	return Polygon._cross(d, line.corners[12], line.corners[13], _ravine().axis)

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

	var jump := func(station: float, length: float, height: float, gap: float) -> void:
		(put.call(T.GAP, station, length, height) as TrailElement).gap = gap
	var pump := func(station: float, count: int, period: float, height: float) -> void:
		put.call(T.PUMP, station, count * period, height, count)

	# 31.10 (как у полигона, по tools/trail_air_stats.gd): линии гэпов и высоких столов вместо невысоких столов,
	# пампы с волной 10–11 м вместо 5–6 (не подбрасывают на гребне), прямые долины — линии прыжков.
	# 1 · Гребень: памп со старта, стол, линия гэп — стол — гэп, памп и большой стол, гэп и дроп до шпильки
	pump.call(c.call(0) + 30.0, 3, 10.0, 0.55)
	put.call(T.TABLETOP, c.call(0) + 70.0, 22.0, 1.5)
	berm.call(1, 0.5)
	jump.call(c.call(1) + 25.0, 18.0, 1.4, 3.5)
	put.call(T.TABLETOP, c.call(1) + 55.0, 22.0, 1.7)
	jump.call(c.call(1) + 85.0, 20.0, 1.5, 4.0)
	berm.call(2, 0.6)
	pump.call(c.call(2) + 30.0, 4, 11.0, 0.6)
	put.call(T.TABLETOP, c.call(2) + 80.0, 24.0, 1.9)
	berm.call(3, 0.6)
	jump.call(c.call(3) + 18.0, 20.0, 1.5, 4.0)
	put.call(T.DROP, c.call(3) + 38.0, 14.0, 1.2)
	berm.call(4, 1.1)
	berm.call(5, 1.3)
	# 2 · Опушка: памп возвращает скорость после шпильки, гэп и стол, норшор-«нитка», гэп, каменный траверс, дроп
	pump.call(c.call(5) + 28.0, 3, 10.0, 0.55)
	jump.call(c.call(5) + 62.0, 18.0, 1.4, 3.5)
	put.call(T.TABLETOP, c.call(5) + 86.0, 22.0, 1.6)
	berm.call(6, 0.6)
	(put.call(T.NORTHSHORE, between.call(6, 0.45), 22.0, 0.6) as TrailElement).gap = 1.2
	# здесь опушка идёт почти горизонтально: гэпу не хватало скорости (взлёт 7,5–10 м/с), стол прощает недолёт
	put.call(T.TABLETOP, c.call(6) + 85.0, 22.0, 1.6)
	berm.call(7, 0.6)
	put.call(T.ROCK_GARDEN, between.call(7, 0.35), 18.0, 0.14)
	put.call(T.DROP, between.call(7, 0.65), 12.0, 1.0)
	berm.call(8, 0.7)
	put.call(T.TABLETOP, c.call(8) + 30.0, 22.0, 1.6)
	berm.call(9, 1.0)
	berm.call(10, 1.1)
	# 3 · Ущелье: корни на выходе из шпильки, памп, два виража на заход, разгон вниз по склону к кикеру над ущельем;
	# приземление в спуск впадины (как у полигона: передняя половина роллера на краю разрыва)
	put.call(T.ROOTS, between.call(10, 0.4), 14.0, 0.1)
	pump.call(c.call(10) + 70.0, 3, 10.0, 0.55)
	berm.call(11, 0.9)
	berm.call(12, 0.9)
	var gap := crossing(d)
	put.call(T.ROLLER, gap - 5.5, 6.0, 1.0, 1)
	put.call(T.DIP, gap + 12.0, 18.0, 1.8)
	berm.call(13, 1.0)
	pump.call(c.call(13) + 32.0, 3, 11.0, 0.6)
	jump.call(c.call(13) + 70.0, 20.0, 1.5, 4.0)
	list.append(TrailElementLibrary.make(T.OFF_CAMBER, c.call(14), 20.0, 0.5, signf(d.curvature_at(c.call(14)))))
	put.call(T.TABLETOP, c.call(14) + 30.0, 22.0, 1.6)
	berm.call(15, 1.1)
	berm.call(16, 1.1)
	# сразу после шпильки, пока скорость невысокая, — каменистый спуск в верховье ущелья (две чистые линии)
	put.call(T.ROCK_GARDEN, between.call(16, 0.5), 22.0, 0.16)
	# дно ущелья: камни и памп по впадинам русла, под местом прыжка полотно чистое, колеи, бревно поперёк русла,
	# узкая линия и корни на выходе к террасе
	berm.call(17, 0.7)
	put.call(T.ROCK_GARDEN, between.call(17, 0.12), 16.0, 0.14)
	pump.call(between.call(17, 0.33), 4, 10.0, 0.55)
	put.call(T.RUTS, between.call(17, 0.86), 16.0, 0.15)
	berm.call(18, 0.8)
	put.call(T.LOG, between.call(18, 0.45), 8.0, 0.3, 1)
	berm.call(19, 0.9)
	(put.call(T.NARROW, between.call(19, 0.45), 10.0, 0.45) as TrailElement).gap = 2.0
	berm.call(20, 0.9)
	put.call(T.ROOTS, between.call(20, 0.45), 16.0, 0.1)
	berm.call(21, 0.6)
	# 4 · Терраса: памп на въезде, мост над выемкой, петля из трёх виражей влево, нижний проход под мост
	pump.call(between.call(21, 0.5), 3, 10.0, 0.55)
	var bridge := Polygon._cross(d, corners[22], corners[23], _cut().axis)
	(put.call(T.NORTHSHORE, bridge + 2.0, 26.0, 1.0) as TrailElement).gap = 2.4
	berm.call(23, 1.0)
	berm.call(24, 1.1)
	berm.call(25, 0.9)
	berm.call(26, 1.0)
	# 5 · Долина: гэп и стол, деревянный кикер; дроп и линия гэп — стол; гэп перед S-виражом, каменная плита;
	# стол и гэп до шпильки; две финишные линии — памп, гэп, стол, гэп
	jump.call(c.call(26) + 30.0, 20.0, 1.5, 4.0)
	put.call(T.TABLETOP, c.call(26) + 60.0, 22.0, 1.7)
	(put.call(T.NORTHSHORE, between.call(26, 0.62), 12.0, 1.0) as TrailElement).gap = 1.8
	berm.call(27, 1.0)
	berm.call(28, 1.1)
	put.call(T.DROP, between.call(28, 0.3), 14.0, 1.2)
	jump.call(c.call(28) + 70.0, 18.0, 1.4, 3.5)
	put.call(T.TABLETOP, c.call(28) + 100.0, 22.0, 1.7)
	berm.call(29, 0.6)
	jump.call(c.call(29) + 20.0, 20.0, 1.5, 4.0)
	put.call(T.S_BERM, between.call(29, 0.35), 30.0, 0.8)
	put.call(T.ROCK_GARDEN, between.call(29, 0.72), 16.0, 0.12)
	berm.call(30, 0.8)
	put.call(T.TABLETOP, c.call(30) + 30.0, 24.0, 1.9)
	jump.call(c.call(30) + 62.0, 18.0, 1.4, 3.5)
	berm.call(31, 1.0)
	berm.call(32, 1.0)
	pump.call(c.call(32) + 40.0, 4, 10.5, 0.6)
	jump.call(c.call(32) + 80.0, 20.0, 1.5, 4.0)
	put.call(T.TABLETOP, c.call(32) + 110.0, 22.0, 1.7)
	jump.call(c.call(32) + 145.0, 20.0, 1.5, 4.0)
	berm.call(33, 0.8)
	pump.call(c.call(33) + 40.0, 3, 11.0, 0.6)
	jump.call(c.call(33) + 85.0, 18.0, 1.4, 3.5)
	put.call(T.TABLETOP, c.call(33) + 120.0, 24.0, 1.9)
	jump.call(c.call(33) + 165.0, 20.0, 1.5, 4.0)
	list.sort_custom(func(a: TrailElement, b: TrailElement) -> bool: return a.station < b.station)
	return list
