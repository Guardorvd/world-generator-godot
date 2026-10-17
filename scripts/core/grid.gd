class_name Grid
extends RefCounted
## Алгоритмы на квадратной сетке карты: соседи, поля расстояний, сглаживание ломаных.
## Клетка (x, y) хранится в плоских массивах по индексу i = y * W + x. Копия js/core/grid.js.

## 8 соседей: сначала 4 по сторонам, затем 4 по диагоналям; DL — длина шага
const DX: Array[int] = [1, -1, 0, 0, 1, 1, -1, -1]
const DY: Array[int] = [0, 0, 1, -1, 1, -1, 1, -1]
const DL: Array[float] = [1.0, 1.0, 1.0, 1.0, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951]
const SQRT2 := 1.4142135623730951

## Самые долгие циклы генерации есть и на C# (FastGrid.cs): в сборке Godot .NET они идут там.
const FAST_GRID_SCRIPT := "res://scripts/core/FastGrid.cs"

## false — всё считать на GDScript (так проверяется, что C# даёт тот же мир)
static var allow_fast := true


## Новый объект FastGrid (C#) или null, если игра запущена не в сборке Godot .NET
static func fast_grid() -> Object:
	if not allow_fast or not ClassDB.class_exists("CSharpScript") or not ResourceLoader.exists(FAST_GRID_SCRIPT):
		return null
	var script: Script = load(FAST_GRID_SCRIPT)
	if script == null or not script.can_instantiate():
		return null
	return script.new()


static func smoothstep_js(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Дистанционное преобразование (фаска 1 / √2): расстояние в клетках до ближайшей клетки, где source[i] != 0
static func distance_field(w: int, h: int, source: PackedByteArray) -> PackedFloat32Array:
	var n := w * h
	var d := PackedFloat32Array()
	d.resize(n)
	for i in n:
		d[i] = 0.0 if source[i] != 0 else 1e9
	for y in h:
		for x in w:
			var i := y * w + x
			var v := d[i]
			if x > 0:
				v = minf(v, d[i - 1] + 1.0)
			if y > 0:
				v = minf(v, d[i - w] + 1.0)
				if x > 0:
					v = minf(v, d[i - w - 1] + SQRT2)
				if x < w - 1:
					v = minf(v, d[i - w + 1] + SQRT2)
			d[i] = v
	for y in range(h - 1, -1, -1):
		for x in range(w - 1, -1, -1):
			var i := y * w + x
			var v := d[i]
			if x < w - 1:
				v = minf(v, d[i + 1] + 1.0)
			if y < h - 1:
				v = minf(v, d[i + w] + 1.0)
				if x < w - 1:
					v = minf(v, d[i + w + 1] + SQRT2)
				if x > 0:
					v = minf(v, d[i + w - 1] + SQRT2)
			d[i] = v
	return d


## Сглаживание ломаной (алгоритм Чайкина). Точки {x, y, w[, e]}: w и e интерполируются вместе с координатами
static func chaikin(pts: Array, iter: int) -> Array:
	for k in iter:
		if pts.size() < 3:
			return pts
		var out: Array = [pts[0]]
		for i in pts.size() - 1:
			var a: Dictionary = pts[i]
			var b: Dictionary = pts[i + 1]
			var q := {x = a.x * 0.75 + b.x * 0.25, y = a.y * 0.75 + b.y * 0.25, w = a.w * 0.75 + b.w * 0.25}
			var r := {x = a.x * 0.25 + b.x * 0.75, y = a.y * 0.25 + b.y * 0.75, w = a.w * 0.25 + b.w * 0.75}
			if a.has("e"):
				q.e = a.e * 0.75 + b.e * 0.25
				r.e = a.e * 0.25 + b.e * 0.75
			out.append(q)
			out.append(r)
		out.append(pts[pts.size() - 1])
		pts = out
	return pts


## Длина вектора в двойной точности (Vector2 в Godot хранит float32)
static func hypot(a: float, b: float) -> float:
	return sqrt(a * a + b * b)


## Клетки отрезка от (x0, y0) до (x1, y1) по восьми соседям (Брезенхем), оба конца включены
static func line_cells(x0: int, y0: int, x1: int, y1: int, w: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		out.append(y0 * w + x0)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return out


## Расстояние от точки (px, py) до отрезка (ax, ay)–(bx, by)
static func segment_dist(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
	var vx := bx - ax
	var vy := by - ay
	var l2 := vx * vx + vy * vy
	var t := 0.0 if l2 == 0.0 else clampf(((px - ax) * vx + (py - ay) * vy) / l2, 0.0, 1.0)
	return hypot(px - ax - vx * t, py - ay - vy * t)
