class_name TowerModels
extends RefCounted
## Модель дозорной вышки StageSites на общем атласе поселений: три уровня детализации.
## Размеры, марши и площадки — из TowerLayout, того же, по чему считаются настилы под ногами
## (Heightfield.add_tower_stairs). Точка опоры — центр пола (0, 0, 0), стойки уходят ниже на склон.

const TIMBER := SettlementModels.CELL_TIMBER
const DARK := SettlementModels.CELL_DARK_WOOD
const STONE := SettlementModels.CELL_STONE
const ROOF := SettlementModels.CELL_ROOF
const FLAG := SettlementModels.CELL_FLOWER_A
const SINK := 1.8       # на сколько стойки уходят под землю у нижнего угла, м
const ROOF_POSTS := 3.0 # высота стоек крыши над площадкой, м
const ROOF_RISE := 1.9


static func build(st: SurfaceTool, level: int) -> void:
	_frame(st, level)
	_deck(st, level)
	_roof(st, level)
	for f: Dictionary in TowerLayout.flights():
		_flight(st, f, level)
	var k := 0
	for p: Dictionary in TowerLayout.platforms():
		if k < 5:
			_landing(st, p, k, level)
		k += 1
	if level <= 1:
		for edge: Dictionary in TowerLayout.rails():
			_rail(st, edge.a, edge.b, edge.y, level)


static func _box(st: SurfaceTool, size: Vector3, center: Vector3, basis: Basis, cell: int) -> void:
	SettlementModels._box(st, size, center, basis, cell)


## Брус от a до b сечением thick × thick (по ширине w, если задана)
static func _beam(st: SurfaceTool, a: Vector3, b: Vector3, thick: float, cell: int, wide := 0.0) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.001:
		return
	var up := Vector3.UP if absf(d.normalized().y) < 0.98 else Vector3.RIGHT
	var basis := Basis.looking_at(d / length, up)
	_box(st, Vector3(wide if wide > 0.0 else thick, thick, length), (a + b) * 0.5, basis, cell)


static func _frame(st: SurfaceTool, level: int) -> void:
	var f := TowerLayout.FRAME_HALF
	var top := TowerLayout.DECK_Y
	var h := top - 0.2 + SINK
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_box(st, Vector3(0.32, h, 0.32), Vector3(sx * f, -SINK + h * 0.5, sz * f), Basis.IDENTITY, TIMBER)
			if level == 0:
				_box(st, Vector3(0.7, 0.8, 0.7), Vector3(sx * f, -0.1, sz * f), Basis.IDENTITY, STONE)
	if level > 1:
		return
	var rings: Array[float] = [4.0, 8.0, top - 0.55]
	for y: float in rings:
		for s: float in [-1.0, 1.0]:
			_box(st, Vector3(2.0 * f, 0.16, 0.16), Vector3(0, y, s * f), Basis.IDENTITY, DARK)
			_box(st, Vector3(0.16, 0.16, 2.0 * f), Vector3(s * f, y, 0), Basis.IDENTITY, DARK)
	# крестовые связи между поясами на всех четырёх гранях
	var levels: Array[float] = [0.0, 4.0, 8.0, top - 0.55]
	for bay in 3:
		var y0 := levels[bay]
		var y1 := levels[bay + 1]
		for s: float in [-1.0, 1.0]:
			_beam(st, Vector3(-f, y0, s * f), Vector3(f, y1, s * f), 0.12, DARK)
			_beam(st, Vector3(s * f, y0, -f), Vector3(s * f, y1, f), 0.12, DARK)
			if level == 0:
				_beam(st, Vector3(f, y0, s * f), Vector3(-f, y1, s * f), 0.12, DARK)
				_beam(st, Vector3(s * f, y0, f), Vector3(s * f, y1, -f), 0.12, DARK)


static func _deck(st: SurfaceTool, level: int) -> void:
	var top := TowerLayout.DECK_Y
	var d := TowerLayout.DECK_HALF
	_box(st, Vector3(2.0 * d + 0.1, 0.2, 2.0 * d + 0.1), Vector3(0, top - 0.1, 0), Basis.IDENTITY, TIMBER)
	if level == 0:
		for x: float in [-1.5, 0.0, 1.5]:
			_box(st, Vector3(0.14, 0.24, 2.0 * d), Vector3(x, top - 0.32, 0), Basis.IDENTITY, DARK)
	var tc := TowerLayout.TOP_CENTER
	var th := TowerLayout.TOP_HALF
	if level <= 1: # снизу площадка у входа держится на двух подкосах от каркаса
		for sx: float in [-1.0, 1.0]:
			_beam(st, Vector3(sx * (th.x - 0.15), top - 1.7, TowerLayout.FRAME_HALF), Vector3(sx * (th.x - 0.15), top - 0.14, tc.y + th.y - 0.2), 0.14, DARK)


static func _roof(st: SurfaceTool, level: int) -> void:
	var top := TowerLayout.DECK_Y
	var p := TowerLayout.DECK_HALF - 0.15
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_box(st, Vector3(0.18, ROOF_POSTS, 0.18), Vector3(sx * p, top + ROOF_POSTS * 0.5, sz * p), Basis.IDENTITY, TIMBER)
	if level <= 1:
		for s: float in [-1.0, 1.0]:
			_box(st, Vector3(2.0 * p + 0.2, 0.16, 0.16), Vector3(0, top + ROOF_POSTS - 0.1, s * p), Basis.IDENTITY, DARK)
			_box(st, Vector3(0.16, 0.16, 2.0 * p + 0.2), Vector3(s * p, top + ROOF_POSTS - 0.1, 0), Basis.IDENTITY, DARK)
	SettlementModels._cyl(st, 0.0, 3.9, ROOF_RISE, 4, Vector3(0, top + ROOF_POSTS + ROOF_RISE * 0.5, 0), Basis(Vector3.UP, PI / 4.0), ROOF)
	if level <= 1:
		var apex := top + ROOF_POSTS + ROOF_RISE
		_box(st, Vector3(0.1, 2.2, 0.1), Vector3(0, apex + 1.0, 0), Basis.IDENTITY, DARK)
		_box(st, Vector3(1.0, 0.6, 0.06), Vector3(0.5, apex + 1.7, 0), Basis.IDENTITY, FLAG)


## Один марш: ступени (верх на высоте настила физики в середине ступени), косоуры, перила
static func _flight(st: SurfaceTool, f: Dictionary, level: int) -> void:
	var a: Vector3 = f.a
	var b: Vector3 = f.b
	var d := b - a
	var run := Vector2(d.x, d.z)
	var yaw := atan2(run.x, run.y)
	var across := Vector3(cos(yaw), 0.0, -sin(yaw))
	var w := TowerLayout.STAIR_HALF
	if level == 2:
		_beam(st, a - Vector3(0, 0.07, 0), b - Vector3(0, 0.07, 0), 0.14, TIMBER, 2.0 * w)
		return
	var n: int = f.steps
	var basis := Basis(Vector3.UP, yaw)
	var depth := run.length() / n
	for i in n:
		var u := (i + 0.5) / n
		var at := a + d * u - Vector3(0, 0.035, 0)
		_box(st, Vector3(2.0 * w - 0.04, 0.07, depth + 0.04), at, basis, TIMBER)
	for s: float in [-1.0, 1.0]:
		var side := across * s * (w - 0.05)
		_beam(st, a + side - Vector3(0, 0.2, 0), b + side - Vector3(0, 0.2, 0), 0.3, DARK, 0.08)
		var rail := across * s * (w - 0.02)
		_beam(st, a + rail + Vector3(0, 0.95, 0), b + rail + Vector3(0, 0.95, 0), 0.07, DARK)
		if level == 0:
			var posts := maxi(2, ceili(d.length() / 1.2) + 1)
			for k in posts:
				var p := a + d * (float(k) / (posts - 1)) + rail
				_box(st, Vector3(0.08, 0.95, 0.08), p + Vector3(0, 0.475, 0), Basis.IDENTITY, DARK)


## Угловая площадка k (0–3) или площадка у входа на настил (4): настил, стойка на углу, связь с каркасом
static func _landing(st: SurfaceTool, p: Dictionary, k: int, level: int) -> void:
	var at: Vector2 = p.c
	var half: Vector2 = p.half
	var y: float = p.y
	_box(st, Vector3(2.0 * half.x, 0.14, 2.0 * half.y), Vector3(at.x, y - 0.07, at.y), Basis.IDENTITY, TIMBER)
	if k >= 4 or level == 2:
		return
	var out := Vector2(signf(at.x), signf(at.y))
	var post := Vector3(at.x + out.x * (half.x - 0.1), 0.0, at.y + out.y * (half.y - 0.1))
	_box(st, Vector3(0.2, y + SINK, 0.2), Vector3(post.x, -SINK + (y + SINK) * 0.5, post.z), Basis.IDENTITY, TIMBER)
	var f := TowerLayout.FRAME_HALF
	_beam(st, Vector3(out.x * f, y - 0.2, out.y * f), Vector3(at.x, y - 0.2, at.y), 0.14, DARK)


## Перила на отрезке плана a–b: верхняя и средняя жерди и стойки
static func _rail(st: SurfaceTool, a: Vector2, b: Vector2, y: float, level: int) -> void:
	var top := Vector3(0, 1.0, 0)
	_beam(st, Vector3(a.x, y, a.y) + top, Vector3(b.x, y, b.y) + top, 0.08, DARK)
	if level > 0:
		return
	_beam(st, Vector3(a.x, y, a.y) + top * 0.5, Vector3(b.x, y, b.y) + top * 0.5, 0.06, DARK)
	var length := a.distance_to(b)
	var count := maxi(1, ceili(length / 1.3))
	for k in count + 1:
		var q := a.lerp(b, float(k) / count)
		_box(st, Vector3(0.1, 1.0, 0.1), Vector3(q.x, y + 0.5, q.y), Basis.IDENTITY, DARK)
