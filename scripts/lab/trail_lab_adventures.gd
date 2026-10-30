extends RefCounted
## Два самостоятельных ландшафта, ручная линия и существующие элементы. Никаких подсказок физике/автопампу.
const Polygon = preload("res://scripts/lab/trail_lab_polygon.gd")
const DH := [
	Vector3(80, 474, 0), Vector3(175, 432, 38), Vector3(315, 448, 42),
	Vector3(438, 370, 32), Vector3(342, 310, 35), Vector3(192, 329, 40),
	Vector3(76, 260, 32), Vector3(160, 182, 38), Vector3(310, 196, 42),
	Vector3(430, 127, 34), Vector3(282, 64, 46), Vector3(100, 42, 0),
]
const XC := [
	# Старт в южной седловине; северная петля забирается на высокий холм, восточная — на низкий.
	Vector3(150, 110, 0), Vector3(66, 142, 30), Vector3(82, 264, 35),
	Vector3(151, 380, 36), Vector3(260, 451, 40), Vector3(368, 403, 36),
	Vector3(310, 322, 30), Vector3(212, 273, 28), Vector3(238, 190, 32),
	Vector3(350, 234, 32), Vector3(443, 191, 35), Vector3(410, 94, 35),
	Vector3(294, 55, 45), Vector3(150, 110, 0),
]
static var _lines := {}

static func ground(at: Vector2, kind: String) -> float:
	if kind == "downhill":
		# Открытый каменистый гребень сменяется ложбиной и широким лесистым нижним склоном.
		var ridge := 9.0 * exp(-pow((at.x - 220.0) / 115.0, 2.0)) * smoothstep(230.0, 440.0, at.y)
		var hollow := 5.0 * exp(-pow((at.x - 360.0) / 90.0, 2.0) - pow((at.y - 240.0) / 110.0, 2.0))
		return 18.0 + at.y * 0.24 + ridge - hollow + 1.2 * sin(at.x / 62.0) * sin(at.y / 47.0)
	var high := 39.0 * exp(-((at - Vector2(217, 372)) / Vector2(145, 130)).length_squared())
	var low := 19.0 * exp(-((at - Vector2(375, 189)) / Vector2(95, 100)).length_squared())
	return 22.0 + high + low + 1.3 * sin(at.x / 53.0) * sin(at.y / 61.0)

static func forest(w: WorldData, routes: Array[TrailDefinition], kind: String) -> void:
	Polygon.forest(w, routes)
	if kind != "downhill": return
	var chunks := w.chunks
	for c in chunks.size():
		var kept := PackedInt32Array()
		for o in chunks[c]:
			# Верхний гребень — редколесье; нижняя половина — полноценный игровой лес.
			if w.obj_y[o] * GameConfig.TILE < 350.0 or o % 5 == 0: kept.append(o)
		chunks[c] = kept
	w.chunks = chunks

## Круговые сопряжения сохраняют прямые касательными. Между дугами остаются площадки для техники/торможения.
static func line(kind: String) -> Dictionary:
	if _lines.has(kind): return _lines[kind]
	var way: Array = DH if kind == "downhill" else XC
	var pts := PackedVector2Array([Vector2(way[0].x, way[0].y)])
	var corners := PackedFloat32Array([0.0])
	var arcs := PackedFloat32Array([0.0])
	var length := 0.0
	for i in range(1, way.size()):
		var p := Vector2(way[i].x, way[i].y)
		var u := (p - Vector2(way[i - 1].x, way[i - 1].y)).normalized()
		var turn := 0.0
		var radius := 0.0
		var a := p
		if i < way.size() - 1:
			var next := Vector2(way[i + 1].x, way[i + 1].y)
			turn = u.angle_to((next - p).normalized())
			var t := minf(way[i].z * tan(absf(turn) * 0.5), minf(pts[-1].distance_to(p) * 0.8, p.distance_to(next) * 0.45))
			radius = t / maxf(tan(absf(turn) * 0.5), 0.0001)
			a = p - u * t
		var from := pts[-1]
		var n := maxi(1, ceili(from.distance_to(a) / 2.0))
		for k in range(1, n + 1):
			var q := from.lerp(a, float(k) / n)
			length += pts[-1].distance_to(q)
			pts.append(q)
		var arc := absf(turn) * radius
		corners.append(length + arc * 0.5)
		arcs.append(arc)
		if arc < 0.01: continue
		var center := a + u.rotated(signf(turn) * PI * 0.5) * radius
		n = maxi(1, ceili(arc))
		for k in range(1, n + 1):
			var q := center + (a - center).rotated(turn * k / n)
			length += pts[-1].distance_to(q)
			pts.append(q)
	_lines[kind] = {points = pts, corners = corners, arcs = arcs}
	return _lines[kind]

static func route(kind: String) -> TrailDefinition:
	var form := line(kind)
	var d := TrailDefinition.new()
	d.id = "course_" + kind
	d.title = "Хребет и папоротники" if kind == "downhill" else "Два холма"
	d.kind = "mountain" if kind == "downhill" else "trail"
	d.width = 4.8 if kind == "downhill" else 3.8
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	d.points = form.points
	# Кольцо замкнуто геометрически; старт/финиш в спокойной зоне без элементов.
	d.closed = kind == "xc"
	d.shaping = TrailShaping.preset("mountain")
	d.shaping.grade_limit = 0.23 if kind == "downhill" else 0.16
	d.shaping.level_window = 6.0
	d.shaping.side_follow = 0.15
	d.shaping.bank_max = 0.22 if kind == "downhill" else 0.12
	d.elements = elements(d, form, kind)
	return d

static func elements(d: TrailDefinition, form: Dictionary, kind: String) -> Array[TrailElement]:
	var T := TrailElement.Profile
	var list: Array[TrailElement] = []
	var c: PackedFloat32Array = form.corners
	var arcs: PackedFloat32Array = form.arcs
	var put := func(profile: int, leg: int, fraction: float, span: float, height: float, count := 3) -> TrailElement:
		var e := TrailElementLibrary.make(profile, lerpf(c[leg], c[leg + 1], fraction), span, height, 1.0, count)
		e.seed = 1600 + leg * 17 + profile
		list.append(e)
		return e
	for i in range(1, c.size() - 1):
		var span := arcs[i] + 10.0
		list.append(TrailElementLibrary.make(T.BERM, c[i], span, 0.65 if kind == "downhill" else 0.35, signf(d.curvature_at(c[i]))))
	if kind == "downhill":
		# Верх: невысокий учебный стол, разгон и длинный каменный траверс с двумя чистыми линиями.
		put.call(T.TABLETOP, 0, 0.45, 18.0, 0.65)
		put.call(T.ROCK_GARDEN, 1, 0.5, 24.0, 0.16)
		put.call(T.PUMP, 2, 0.5, 30.0, 0.4, 3)
		# Центральная чаша: длинная обратная сторона гребня, стол и ритм из трёх волн.
		var crest := put.call(T.ROLLOVER, 3, 0.5, 20.0, 0.85) as TrailElement
		crest.skew = 0.28
		put.call(T.TABLETOP, 4, 0.5, 22.0, 1.0)
		put.call(T.WAVES, 5, 0.5, 36.0, 0.4, 3)
		# Лес: корни на прямой, затем просторный пролёт и памп к выходу.
		put.call(T.ROOTS, 6, 0.5, 20.0, 0.1)
		put.call(T.TABLETOP, 7, 0.5, 24.0, 1.1)
		put.call(T.PUMP, 8, 0.5, 30.0, 0.45, 3)
		put.call(T.ROLLOVER, 9, 0.5, 22.0, 0.75)
		put.call(T.TABLETOP, 10, 0.38, 24.0, 0.9)
	else:
		# Подъём: выбор чистой линии через корни. Верхняя петля — отдых и небольшой стол на спуске.
		put.call(T.ROOTS, 1, 0.5, 16.0, 0.08)
		put.call(T.ROCK_GARDEN, 3, 0.45, 14.0, 0.1)
		put.call(T.TABLETOP, 5, 0.5, 18.0, 0.55)
		put.call(T.PUMP, 6, 0.5, 24.0, 0.3, 3)
		# Седловина: бревно можно перепрыгнуть или спокойно объехать по краю.
		var log := put.call(T.LOG, 7, 0.5, 6.0, 0.22, 1) as TrailElement
		log.gap = 1.4
		put.call(T.ROOTS, 9, 0.5, 14.0, 0.08)
		put.call(T.WAVES, 10, 0.5, 32.0, 0.25, 3)
		put.call(T.PUMP, 11, 0.5, 28.0, 0.32, 3)
		put.call(T.TABLETOP, 12, 0.5, 18.0, 0.45)
	list.sort_custom(func(a: TrailElement, b: TrailElement) -> bool: return a.station < b.station)
	return list
