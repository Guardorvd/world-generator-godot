extends RefCounted
## Главный полигон Trail Lab (30.10): длинная flow-трасса на своей местности 512 × 512 м — лесистый склон с холмами,
## оврагом и полкой. Линия задана опорными точками со скруглениями (радиус у каждой точки), элементы расставлены по
## участкам вручную: у каждого участка своя задача (разгон, ритм, прыжок, памп на ровном, техника в овраге, петля,
## финальный flow). Трасса трёхъярусная в двух местах: сначала она перепрыгивает овраг вниз по склону, а позже идёт
## по дну этого же оврага под местом прыжка; на полке она проходит по деревянному мосту, делает петлю и ныряет
## в выемку под этот мост. Земля на пересечениях остаётся природной (TrailDefinition.junction_weight): над нижним
## проездом — настоящий разрыв или настил.
## Финальная версия выверена по заездам автопилота трёх манер (scripts/lab/trail_autopilot.gd): невысокие роллеры,
## волны и рябь первой версии ничего не давали ни на какой скорости — их места заняли столы, памп-секции, дропы и
## дерево (норшор-«нитка», мост, деревянный кикер).

## Сторона полигона в клетках мира (по 4 м) и метрах.
const CELLS := 128
const SIZE := CELLS * 4.0

## Опорные точки: x, z (м) и радиус скругления (м). Склон падает к малым z.
const WAYPOINTS := [
	# 0–4 · разгон по верхней полке: линия столов, памп-дублы, первый дроп
	Vector3(60, 494, 0), Vector3(150, 486, 60), Vector3(250, 476, 45), Vector3(340, 470, 40),
	# 4–5 · шпилька вправо на высоких виражах
	Vector3(445, 460, 22), Vector3(452, 424, 22),
	# 6–7 · ритм: памп, двойной стол, ступенька вниз, корни
	Vector3(360, 418, 50), Vector3(255, 414, 45),
	# 8–9 · шпилька влево, норшор-«нитка», 10–11 · виражи на заход к оврагу
	Vector3(150, 408, 20), Vector3(146, 378, 20), Vector3(215, 374, 18), Vector3(258, 372, 16),
	# 12 · приземление за оврагом и вираж влево; 13 · контур по склону (памп, контруклон, стол)
	Vector3(262, 300, 18), Vector3(335, 292, 50),
	# 14–15 · шпилька влево в верховье оврага
	Vector3(430, 290, 16), Vector3(452, 318, 16),
	# 16–18 · дно оврага (под местом прыжка), 19 · выход из оврага
	Vector3(380, 328, 60), Vector3(180, 332, 50), Vector3(122, 314, 30), Vector3(100, 266, 25),
	# 20–21 · на полку, мост; 22–24 · петля на трёх виражах влево; к 25 — в выемку под мост и спуск с полки
	Vector3(165, 240, 50), Vector3(250, 236, 40), Vector3(345, 232, 18), Vector3(352, 268, 18), Vector3(275, 272, 16),
	# 25–28 · финал: стол и памп, деревянный кикер, ступенька, финишный стол
	Vector3(272, 188, 22), Vector3(420, 165, 24), Vector3(345, 115, 34), Vector3(410, 62, 0),
]

## Полка (терраса) под петлёй с мостом: прямоугольник x, z, ширина, глубина (м) и полоса перехода к склону (м).
const TERRACE := Rect2(235, 222, 135, 63)
const TERRACE_FADE := 22.0
## Выемка нижнего прохода под мостом: глубина у моста, полудлина участка полной глубины и сход на нет (м).
const CUT_DEPTH := 2.6
const CUT_FULL := 8.0
const CUT_FADE := 22.0

## Овраг: русло идёт по оси трассы между этими опорными точками (дно — по уклону FLOOR_GRADE от верховья).
const RAVINE_FROM := 15
const RAVINE_TO := 19
const FLOOR_GRADE := 0.012
const FLOOR_HALF := 3.0   # половина ширины дна, м
const WALL := 1.1          # заложение стенок: метров по горизонтали на метр глубины
static var _cache := {}

## Земля полигона: склон 20 % к малым z, пологие холмы, полка, врезанный овраг и выемка под мостом.
static func ground(at: Vector2) -> float:
	var base := _base(at)
	var ravine := _ravine()
	var near := ravine.axis.nearest(at, 30.0) as Vector3
	if is_finite(near.z):
		var floor_level: float = ravine.top - FLOOR_GRADE * near.x
		var depth := maxf(0.0, base - floor_level)
		base -= depth * (1.0 - smoothstep(FLOOR_HALF, FLOOR_HALF + depth * WALL + 1.0, near.z))
	var cut: Dictionary = _cut()
	var lane := (cut.axis as TrailDefinition).nearest(at, 12.0)
	if is_finite(lane.z):
		var depth: float = CUT_DEPTH * (1.0 - smoothstep(CUT_FULL, CUT_FULL + CUT_FADE, absf(lane.x - cut.under)))
		base -= depth * (1.0 - smoothstep(FLOOR_HALF, FLOOR_HALF + depth * 0.7 + 0.5, lane.z))
	return base

## Лес полигона тем же этапом, что в игре (StageVegetation): деревья, кусты и камни по чанкам мира, сюда же смотрят
## столкновения (ForestObstacles) и рисование (VegetationLayer). Вызывать до TrailBuilder.append_routes: просека
## у игровых дорог (без деревьев на 5 м и редкий лес до 10 м) сделала бы из трассы поляну. Здесь лес подходит
## к самому краю: из чанков убирается только то, что ближе CLEAR к краю полотна. Смешанный влажный лес; высота для
## состава и границы леса — как у предгорья (в лаборатории высоты условные, иначе вышли бы почти одни сосны).
## Сид леса подобран по густоте (tools/control/runs/polygon/forest_seeds.gd): у сида лаборатории лес занимал
## половину полигона с редкими деревьями, у FOREST_SEED — около 70 % и вдвое гуще.
const FOREST_SEED := 2024
## Свободная полоса от края полотна до ствола, куста или камня, м: шире выступа виража (TrailElement.BERM_BACK).
const CLEAR := 2.5
static func forest(w: WorldData, routes: Array[TrailDefinition]) -> void:
	var seed_num := w.seed_num
	w.seed_num = FOREST_SEED
	for name: String in WorldGenerator.NOISE_SLOTS:
		if not w.noise.has(name): w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	# свойства WorldData отдают копии массивов: заполнять копию и присваивать целиком
	var biome := w.biome
	biome.fill(Biomes.FOREST)
	w.biome = biome
	var field := PackedFloat32Array()
	field.resize(w.N)
	field.fill(0.75)
	w.moist = field
	field.fill(0.5)
	w.temp = field
	var elev := w.elev
	field.fill(0.08)
	w.elev = field
	StageVegetation.run(w)
	w.elev = elev
	w.seed_num = seed_num
	var chunks := w.chunks
	for c in chunks.size():
		var kept := PackedInt32Array()
		for o in chunks[c]:
			var at := Vector2(w.obj_x[o], w.obj_y[o]) * GameConfig.TILE
			var free := true
			for d in routes:
				if is_finite(d.nearest(at, d.width * 0.5 + CLEAR).z): free = false
			if free: kept.append(o)
		chunks[c] = kept
	w.chunks = chunks

## Склон с холмами и полкой: внутри TERRACE земля ровная (на уровне въезда), к краю полоса TERRACE_FADE сводит её
## со склоном — выше полки получается выемка в склон, ниже — насыпной откос.
static func _base(at: Vector2) -> float:
	var slope := _slope(at)
	var outside := Vector2(maxf(maxf(TERRACE.position.x - at.x, at.x - TERRACE.end.x), 0.0),
		maxf(maxf(TERRACE.position.y - at.y, at.y - TERRACE.end.y), 0.0)).length()
	var level := _slope(Vector2(TERRACE.position.x + 15.0, TERRACE.position.y + 14.0))
	return lerpf(level, slope, smoothstep(0.0, TERRACE_FADE, outside))

static func _slope(at: Vector2) -> float:
	var hills := 1.6 * sin(at.x / 53.0) * sin(at.y / 71.0) + 0.7 * sin((at.x + at.y) / 29.0)
	return 12.0 + at.y * 0.2 + hills

## Ось выемки — нижний проход петли (опоры 24–25); under — его станция под мостом (от начала оси).
static func _cut() -> Dictionary:
	if _cache.has("cut"): return _cache.cut
	var line := _line()
	var full := TrailDefinition.new()
	full.points = line.points
	var d := TrailDefinition.new()
	d.id = "cut"
	var pts := PackedVector2Array()
	var s: float = line.corners[24]
	while s <= line.corners[25]:
		pts.append(full.point_at(s))
		s += 2.0
	d.points = pts
	var bridge := _cross(full, line.corners[21], line.corners[22], d)
	_cache.cut = {axis = d, under = d.nearest(full.point_at(bridge)).x}
	return _cache.cut

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
	var calm := _calm_points()
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
## на концах прямой смещение и его наклон нулевые — дуги опорных точек не ломаются. Без извилин: разгон к оврагу (11),
## прямые моста (21) и выемки (24); у пересечений (calm) прямая тоже остаётся прямой.
const MEANDER := {0: 4.0, 1: 4.0, 2: 3.5, 3: 4.0, 6: 4.5, 12: 3.0, 13: 4.0, 16: 4.0, 19: 3.0, 20: 4.0, 25: 5.0, 27: 3.5}
const WAVE := 70.0
const CALM := 22.0

## Прямая от последней точки до p через ~2 м, с извилинами амплитуды amp; у точек calm извилина гаснет.
static func _straight(pts: Array[Vector2], p: Vector2, amp: float, calm: Array[Vector2]) -> void:
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
		var quiet := 1.0
		for point in calm: quiet *= 1.0 - exp(-pow(at.distance_to(point) / CALM, 2.0))
		pts.append(at + side * amp * sin(PI * waves * u) * pow(sin(PI * u), 2.0) * quiet)

## Пересечения опорных прямых: разгон к оврагу (11–12) с дном оврага (16–17), мост (21–22) с выемкой (24–25).
static func _calm_points() -> Array[Vector2]:
	var w := func(i: int) -> Vector2: return Vector2(WAYPOINTS[i].x, WAYPOINTS[i].y)
	var result: Array[Vector2] = []
	for pair: Array in [[11, 16], [21, 24]]:
		var hit: Variant = Geometry2D.segment_intersects_segment(w.call(pair[0]), w.call(pair[0] + 1), w.call(pair[1]), w.call(pair[1] + 1))
		if hit != null: result.append(hit)
	return result
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

	# — Разгон по верхней полке: линия из двух столов по нарастающей, памп-дублы, большой стол и первый дроп перед
	# шпилькой (между дропом и виражом 40 м — тормозить есть где)
	put.call(T.TABLETOP, between.call(0, 0.35), 14.0, 0.7)
	put.call(T.TABLETOP, between.call(0, 0.68), 16.0, 0.9)
	berm.call(1, 0.5)
	put.call(T.PUMP, between.call(1, 0.5), 18.0, 0.55, 3)
	berm.call(2, 0.6)
	put.call(T.TABLETOP, between.call(2, 0.5), 18.0, 1.1)
	berm.call(3, 0.6)
	put.call(T.DROP, between.call(3, 0.42), 12.0, 0.8)
	berm.call(4, 1.1)
	berm.call(5, 1.3)
	# — Ритм: памп после шпильки возвращает скорость, двойной стол, ступенька вниз, корни на выходе из дуги
	put.call(T.PUMP, between.call(5, 0.3), 22.0, 0.45, 4)
	put.call(T.TABLETOP, between.call(5, 0.62), 16.0, 0.9)
	put.call(T.TABLETOP, between.call(5, 0.82), 16.0, 1.0)
	berm.call(6, 0.6)
	put.call(T.ROLLOVER, between.call(6, 0.35), 14.0, 0.9, 3, 0.25)
	put.call(T.ROOTS, between.call(6, 0.62), 12.0, 0.1)
	berm.call(7, 0.6)
	# шпилька влево ниже и мягче первой; за ней — норшор-«нитка» на ровном: узкий настил с ровным сходом
	berm.call(8, 0.9)
	berm.call(9, 1.1)
	(put.call(T.NORTHSHORE, between.call(9, 0.45), 18.0, 0.6) as TrailElement).gap = 1.2
	# — Заход на овраг: два виража подряд разворачивают на спуск, затем прямой разгон по склону к кикеру
	berm.call(10, 0.9)
	berm.call(11, 0.9)
	# Прыжок через овраг. Насыпь трассы держит полотно над оврагом, а у нижнего проезда (2,25–5,25 м от его оси,
	# junction_weight) земля остаётся природной — это и есть разрыв. Кикер — передняя половина роллера: самый крутой
	# его участок приходится на край разрыва, задняя половина уходит в разрыв. Приземление — в спуск впадины за разрывом,
	# её подъём гасит удар. Любая манера автопилота разгоняется к нему до 56 км/ч: полёт 0,8 с, удар около 5 м/с.
	var gap := _cross(d, corners[11], corners[12], _ravine().axis)
	put.call(T.ROLLER, gap - 2.1, 13.0, 2.0)
	put.call(T.DIP, gap + 10.0, 16.0, 1.5)
	# — Приземление и контур: вираж сразу после посадки, памп на почти ровной полке, контруклон в пологой дуге, стол
	berm.call(12, 1.0)
	put.call(T.PUMP, between.call(12, 0.55), 24.0, 0.45, 5)
	list.append(TrailElementLibrary.make(T.OFF_CAMBER, c.call(13), 20.0, 0.5, signf(d.curvature_at(c.call(13)))))
	put.call(T.TABLETOP, between.call(13, 0.55), 18.0, 1.0)
	berm.call(14, 1.1)
	berm.call(15, 1.0)
	# — Овраг: после шпильки, пока скорость невысокая, — колеи, поваленное дерево поперёк русла (объезд у стенки
	# или прыжок) и камни; под местом прыжка полотно чистое, дальше впадины русла — памп
	put.call(T.RUTS, c.call(16) - 34.0, 16.0, 0.15)
	put.call(T.LOG, c.call(16) - 12.0, 8.0, 0.3, 1)
	put.call(T.ROCK_GARDEN, between.call(16, 0.12), 16.0, 0.14)
	put.call(T.PUMP, between.call(16, 0.72), 24.0, 0.5, 4)
	berm.call(17, 0.7)
	(put.call(T.NARROW, between.call(17, 0.4), 10.0, 0.45) as TrailElement).gap = 2.0
	berm.call(18, 0.8)
	berm.call(19, 0.9)
	# — Полка: памп на въезде, деревянный мост над выемкой, петля на трёх виражах влево; нижний проход ныряет
	# в выемку под мост (полотно чистое) и уходит с полки крутым спуском прямо в вираж. Дроп на краю полки убран:
	# на пределе седок улетал с него в вираж (удар 12 м/с при пороге падения 13).
	put.call(T.PUMP, between.call(19, 0.55), 18.0, 0.5, 3)
	var bridge := _cross(d, corners[21], corners[22], _cut().axis)
	var deck := put.call(T.NORTHSHORE, bridge + 2.0, 26.0, 1.0) as TrailElement
	deck.gap = 2.4
	berm.call(22, 1.0)
	berm.call(23, 1.1)
	berm.call(24, 0.9)
	berm.call(25, 1.0)
	# — Финал: стол и памп на прямой, деревянный кикер (норшор с обрывом), ступенька вниз и финишный стол
	put.call(T.TABLETOP, between.call(25, 0.3), 18.0, 1.1)
	put.call(T.PUMP, between.call(25, 0.66), 18.0, 0.55, 3)
	berm.call(26, 1.1)
	(put.call(T.NORTHSHORE, between.call(26, 0.42), 12.0, 1.0) as TrailElement).gap = 1.8
	berm.call(27, 0.8)
	put.call(T.ROLLOVER, between.call(27, 0.3), 14.0, 0.9, 3, 0.25)
	put.call(T.TABLETOP, between.call(27, 0.66), 18.0, 1.2)
	list.sort_custom(func(a: TrailElement, b: TrailElement) -> bool: return a.station < b.station)
	return list

## Станция участка трассы от from до to, ближайшая к оси other (место пересечения).
static func _cross(d: TrailDefinition, from: float, to: float, other: TrailDefinition) -> float:
	var best := INF
	var station := from
	var s := from
	while s < to:
		var gap := other.nearest(d.point_at(s), 40.0).z
		if gap < best:
			best = gap
			station = s
		s += 0.5
	return station

## Станция верхнего прохода над оврагом (для проб и снимков).
static func _crossing(d: TrailDefinition) -> float:
	var line := _line()
	return _cross(d, line.corners[11], line.corners[12], _ravine().axis)