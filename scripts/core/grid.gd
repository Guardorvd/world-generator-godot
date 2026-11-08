class_name Grid
extends RefCounted
## Алгоритмы на квадратной сетке карты: соседи, поля расстояний, сглаживание ломаных.
## Клетка (x, y) хранится в плоских массивах по индексу i = y * W + x. Копия js/core/grid.js.

const PATH_IN := 0.1   # отступ внутрь края ленты при разметке клеток
const PATH_STEP := 0.25 # шаг разметки, клеток

const SQRT2 := 1.4142135623730951


## 8 соседей: сначала 4 по сторонам, затем 4 по диагоналям; DL — длина шага
const DX: Array[int] = [1, -1, 0, 0, 1, 1, -1, -1]
const DY: Array[int] = [0, 0, 1, -1, 1, -1, 1, -1]
const DL: Array[float] = [1.0, 1.0, 1.0, 1.0, SQRT2, SQRT2, SQRT2, SQRT2]

## Самые долгие циклы генерации есть и на C# (FastGrid.cs): в сборке Godot .NET они идут там.
const FAST_GRID_SCRIPT := "res://scripts/core/FastGrid.cs"

## false — всё считать на GDScript (так проверяется, что C# даёт тот же мир)
static var allow_fast := true
static var _fast_script: Script = null
static var _fast_checked := false
static var _fast_lock := Mutex.new()


## Новый объект FastGrid (C#) или null, если игра запущена не в сборке Godot .NET
## Скрипт ищется и грузится один раз (вызов идёт и из потоков кусков OuterLand), объект — новый на каждый вызов
static func fast_grid() -> Object:
	if not allow_fast:
		return null
	# Даже чтение флага — под замком: публикация Script должна быть видна всем потокам.
	_fast_lock.lock()
	if not _fast_checked:
		if ClassDB.class_exists("CSharpScript") and ResourceLoader.exists(FAST_GRID_SCRIPT):
			var script: Script = load(FAST_GRID_SCRIPT)
			if script != null and script.can_instantiate():
				if _fast_build_stale():
					# старая сборка не знает новых методов или ждёт другие массивы: генерация упадёт посреди этапа
					push_error("FastGrid (C#) собран раньше правки .cs: расчёты идут на GDScript, соберите проект (dotnet build)")
				else:
					_fast_script = script
		if _fast_script == null and ClassDB.class_exists("CSharpScript"):
			# сборка .NET, но C# не собран: всё пойдёт на GDScript во много раз медленнее — сказать об этом
			push_warning("FastGrid (C#) недоступен, расчёты идут на GDScript: соберите проект (dotnet build)")
		_fast_checked = true
	var ready_script := _fast_script
	_fast_lock.unlock()
	return ready_script.new() if ready_script != null else null


## Запуск из папки проекта: сборка C# старше исходников .cs (ветку обновили, а проект не пересобрали).
## В экспортированной игре исходников нет, проверка не нужна.
static func _fast_build_stale() -> bool:
	if OS.has_feature("template"):
		return false
	var dll := ProjectSettings.globalize_path("res://.godot/mono/temp/bin/Debug/%s.dll" % ProjectSettings.get_setting("dotnet/project/assembly_name", "WorldGeneratorGodot"))
	if not FileAccess.file_exists(dll):
		return false
	var built := FileAccess.get_modified_time(dll)
	var dir := FAST_GRID_SCRIPT.get_base_dir()
	for name in DirAccess.get_files_at(dir):
		if name.ends_with(".cs") and FileAccess.get_modified_time(dir.path_join(name)) > built:
			return true
	return false


## Крупнейшая область суши с учётом возможных коротких переправ. Вода дальше половины
## предельного пролёта от любого берега не может принадлежать допустимому мосту.
## Связность здесь намеренно щедрая: уклон и безопасность самой переправы проверяются позже.
## Расстояние Чебышёва соответствует числу восьмисвязных шагов, в которых задан max_span.
static func bridge_region(w: int, h: int, wet: PackedByteArray, max_span: int) -> PackedByteArray:
	var fast := fast_grid()
	if fast != null:
		return fast.BridgeRegion(w, h, wet, max_span)
	return bridge_region_reference(w, h, wet, max_span)


## Исходный обход: запасной путь без .NET и эталон проверки пакетного метода.
static func bridge_region_reference(w: int, h: int, wet: PackedByteArray, max_span: int) -> PackedByteArray:
	var n := w * h
	var result := PackedByteArray()
	result.resize(n)
	if n == 0:
		return result
	var distance := PackedInt32Array()
	distance.resize(n)
	var reach := maxi(0, max_span / 2)
	for i in n:
		distance[i] = reach + 1 if wet[i] != 0 else 0
	for y in h:
		for x in w:
			var i := y * w + x
			if x > 0: distance[i] = mini(distance[i], distance[i - 1] + 1)
			if y > 0:
				distance[i] = mini(distance[i], distance[i - w] + 1)
				if x > 0: distance[i] = mini(distance[i], distance[i - w - 1] + 1)
				if x + 1 < w: distance[i] = mini(distance[i], distance[i - w + 1] + 1)
	for y in range(h - 1, -1, -1):
		for x in range(w - 1, -1, -1):
			var i := y * w + x
			if x + 1 < w: distance[i] = mini(distance[i], distance[i + 1] + 1)
			if y + 1 < h:
				distance[i] = mini(distance[i], distance[i + w] + 1)
				if x > 0: distance[i] = mini(distance[i], distance[i + w - 1] + 1)
				if x + 1 < w: distance[i] = mini(distance[i], distance[i + w + 1] + 1)
	var regions := PackedInt32Array()
	regions.resize(n)
	var queue := PackedInt32Array()
	queue.resize(n)
	var region := 0
	var largest := 0
	var largest_land := 0
	for start in n:
		if regions[start] != 0 or distance[start] > reach:
			continue
		region += 1
		regions[start] = region
		queue[0] = start
		var head := 0
		var tail := 1
		var land := 0
		while head < tail:
			var c := queue[head]
			head += 1
			if wet[c] == 0: land += 1
			var x := c % w
			var y := c / w
			for dy in range(maxi(0, y - 1), mini(h, y + 2)):
				for dx in range(maxi(0, x - 1), mini(w, x + 2)):
					var next := dy * w + dx
					if regions[next] == 0 and distance[next] <= reach:
						regions[next] = region
						queue[tail] = next
						tail += 1
		if land > largest_land:
			largest_land = land
			largest = region
	if largest != 0:
		for i in n:
			result[i] = 1 if regions[i] == largest else 0
	return result


## Лежит ли клетка i на краю карты w × h
@warning_ignore("integer_division")
static func on_edge(i: int, w: int, h: int) -> bool:
	var x := i % w
	var y := i / w
	return x == 0 or y == 0 or x == w - 1 or y == h - 1


## Просвет у путей (15.0): у каждой клетки — расстояние (м) от её центра до кромки полотна ближайшего пути минус запас
## его вида; дальше cap — cap. Пути — столбцами: CSR starts по точкам, px/py/pw — x, y и ширина точек в клетках,
## tile — метров в клетке, margin — запас пути, м (дорога — обочина, тропа — проход руля, звериная тропа — почти ничего). Считается только
## у линий (полоса cap), а не по всей карте. Растительность и камни ставят ствол или камень, если просвет в их точке
## не меньше их радиуса: деревья подходят к кромке тропы, кроны над ней не запрещены. Тот же расчёт, что у
## FastGrid.PathClearance (double, хранение во float).
## При смене ширины берётся максимальная полуширина отрезка: консервативная огибающая полотна,
## сохраняющая нижнюю оценку clearance_at и покрывающая среднюю ширину метрового меша.
static func path_clearance(w: int, h: int, starts: PackedInt32Array, px: PackedFloat64Array, py: PackedFloat64Array,
		pw: PackedFloat64Array, margin: PackedFloat64Array, tile: float, cap: float) -> PackedFloat32Array:
	var fast := fast_grid()
	if fast != null:
		return fast.PathClearance(w, h, starts, px, py, pw, margin, tile, cap)
	var out := PackedFloat32Array()
	out.resize(w * h)
	out.fill(cap)
	for r in margin.size():
		for n in range(starts[r] + 1, starts[r + 1]):
			var ax := px[n - 1]
			var ay := py[n - 1]
			var dx := px[n] - ax
			var dy := py[n] - ay
			var l2 := dx * dx + dy * dy
			var wa := pw[n - 1] * tile * 0.5
			var wb := pw[n] * tile * 0.5
			# Постоянная огибающая покрывает и среднюю полуширину отрезка RoadRefinement.
			# Переменная ширина в проекции на ось не даёт 1-липшицево поле, нужное clearance_at.
			var half := maxf(wa, wb)
			var reach := (maxf(wa, wb) + margin[r] + cap) / tile
			for y in range(maxi(0, floori(minf(ay, ay + dy) - reach)), mini(h, floori(maxf(ay, ay + dy) + reach) + 1)):
				for x in range(maxi(0, floori(minf(ax, ax + dx) - reach)), mini(w, floori(maxf(ax, ax + dx) + reach) + 1)):
					var t := 0.0 if l2 == 0.0 else clampf(((x + 0.5 - ax) * dx + (y + 0.5 - ay) * dy) / l2, 0.0, 1.0)
					var ox := x + 0.5 - ax - dx * t
					var oy := y + 0.5 - ay - dy * t
					var value := sqrt(ox * ox + oy * oy) * tile - half - margin[r]
					var i := y * w + x
					if value < out[i]:
						out[i] = value
	return out


## Просвет в точке (x, y) в клетках поля field с началом (ox, oy) и шириной stride, м. Нижняя оценка по четырём
## соседним центрам клеток: расстояние меняется не быстрее самого смещения, поэтому значение в центре минус путь
## до точки не больше настоящего (билинейная интерполяция у самой оси завышала бы его и пускала ствол на полотно).
static func clearance_at(field: PackedFloat32Array, ox: int, oy: int, stride: int, x: float, y: float, tile := 4.0) -> float:
	var rows := field.size() / stride
	var i0 := clampi(floori(x - 0.5) - ox, 0, stride - 2)
	var j0 := clampi(floori(y - 0.5) - oy, 0, rows - 2)
	var best := -INF
	for j in range(j0, j0 + 2):
		for i in range(i0, i0 + 2):
			var dx := x - (ox + i + 0.5)
			var dy := y - (oy + j + 0.5)
			best = maxf(best, field[j * stride + i] - sqrt(dx * dx + dy * dy) * tile)
	return best


## Дистанционное преобразование (фаска 1 / √2): расстояние в клетках до ближайшей клетки, где source[i] != 0
## В сборке .NET считается на C# (FastGrid.DistanceField), результат тот же
static func distance_field(w: int, h: int, source: PackedByteArray) -> PackedFloat32Array:
	var fast := fast_grid()
	if fast != null:
		return fast.DistanceField(w, h, source)
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


## Сглаживание ломаной (алгоритм Чайкина). Точки {x, y, w[, e]}: w и e интерполируются вместе с координатами.
## Поле e должно быть либо у всех точек, либо ни у одной (проверяется только у первой точки отрезка)
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


## Клетки под осью и краями ленты; диагональ включает клетку у общего угла.
## Без values повышает маску до mark; с values пишет значение ближайшего конца сегмента.
## Один обход для маски пути и его покрытия. half — полуширина в клетках.
static func stamp_path(mask: PackedByteArray, W: int, H: int, pts: Array, mark: int, half: float,
		values: PackedByteArray = PackedByteArray()) -> void:
	if pts.size() < 2:
		return
	var overwrite := not values.is_empty()
	# у узкой линии (звериная тропа) края ленты почти там же, где середина
	var sides := half > 0.1
	var last: Dictionary = pts[0]
	var px: float = last.x
	var py: float = last.y
	for k: int in range(1, pts.size()):
		var b: Dictionary = pts[k]
		var ax: float = last.x
		var ay: float = last.y
		var dx: float = b.x - ax
		var dy: float = b.y - ay
		last = b
		var seg_len := sqrt(dx * dx + dy * dy)
		if seg_len == 0.0:
			continue
		var nx := -dy / seg_len * half
		var ny := dx / seg_len * half
		var m := ceili(seg_len / PATH_STEP)
		for s: int in range(1, m + 1):
			var f := float(s) / m
			var value := mark if not overwrite else int(values[k - 1] if f < 0.5 else values[k])
			var x := ax + dx * f
			var y := ay + dy * f
			# середина: клетка точки и, если линия ушла от прошлой точки в соседнюю по диагонали клетку,
			# та из двух клеток у общего угла, через которую она прошла
			var x0 := floori(px)
			var y0 := floori(py)
			var x1 := floori(x)
			var y1 := floori(y)
			if x0 != x1 and y0 != y1:
				var bx := maxi(x0, x1)
				var cy := py + (bx - px) * (y - py) / (x - px)
				_mark_cell(mask, W, H, x1 if floori(cy) == y0 else x0, y0 if floori(cy) == y0 else y1, value, overwrite)
			_mark_cell(mask, W, H, x0, y0, value, overwrite)
			_mark_cell(mask, W, H, x1, y1, value, overwrite)
			if sides:
				_mark_cell(mask, W, H, floori(x + nx), floori(y + ny), value, overwrite)
				_mark_cell(mask, W, H, floori(x - nx), floori(y - ny), value, overwrite)
			px = x
			py = y


static func _mark_cell(mask: PackedByteArray, W: int, H: int, x: int, y: int, value: int, overwrite: bool) -> void:
	if x >= 0 and y >= 0 and x < W and y < H and (overwrite or mask[y * W + x] < value):
		mask[y * W + x] = value
