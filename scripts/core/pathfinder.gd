class_name Pathfinder
extends RefCounted
## Поиск пути A* по сетке со стоимостью прохода клеток (8 направлений). Основа — js/core/pathfinding.js;
## с 2.3 диагональный шаг не срезает углы (см. find_path), оценка остатка пути — H_COST.
## Стоимость прохода передаётся в каждый поиск, поэтому её можно менять между вызовами
## (так протоптанные тропы становятся дешевле). INF — непроходимо. Знает только размер сетки, не мир.
## Куча из MinHeap развёрнута прямо в цикле поиска: в GDScript вызовы методов дороги, а алгоритм тот же.
## В сборке Godot .NET поиск ведёт FastGrid.FindPath (FastGrid.Path.cs): тот же алгоритм на C#, в десятки раз быстрее;
## с 9.9 он ещё помнит последние поиски и умеет заранее искать запасной путь в фоне (prefetch) — пути те же.

## Оценка остатка пути A* — восьмисвязное расстояние до цели, умноженное на H_COST. Самая дешёвая клетка
## (протоптанная тропа, StageTrails._add_trail) стоит 0.3, так что оценка у троп бывает выше настоящей
## стоимости и путь может выйти чуть дороже самого дешёвого. Замер 2.3 (5 миров, ~380 поисков): так вышло
## у 4 путей, дороже не больше чем на 0,1 %; с честной оценкой 0.3 пути те же, а поиск дорог на четверть дольше
const H_COST := 0.6
## Начальная ёмкость кучи (элементов); растёт вдвое по необходимости
const HEAP_START_CAP := 1 << 16
## Дополнительные счётчики только для tools/bench.gd; в игре выключены.
static var profile_searches := false
var _search_us := 0

var W := 0
var H := 0
## Высоты в тех же единицах, что шаг сетки. Пустой массив отключает учёт подъёмов.
var _heights_version := 0
var _links_version := 0
var _cost_version := 0
var heights := PackedFloat32Array():
	set(value):
		heights = value
		_heights_version += 1
## Разрешённые шаги по готовому настилу/полу: биты восьми направлений Grid.DX/DY.
var links := PackedByteArray():
	set(value):
		links = value
		_links_version += 1
var use_corridor := true # проверять ширину прохода
var max_cross_grade := INF # предел земляных работ поперёк прохода
## Общий остаток раскрытий для нескольких поисков: -1 без ограничения, 0 — отказаться.
## Позволяет проверять кандидат поселения без полного перебора карты по каждому соседу.
var search_budget := -1
## Реальная ширина прохода: кэш продольного уклона и поперечного крена шагов.
var _ground := PackedFloat32Array()
var _water := PackedFloat32Array()
var _wet := PackedByteArray()
var _half := 0.0
var _corridor := PackedFloat32Array()
var _cross := PackedFloat32Array()
## Рабочие массивы поиска. seen и done содержат номер поиска (gen), а не флаг, поэтому между поисками их не чистят.
var g := PackedFloat32Array()
var from := PackedInt32Array()
var seen := PackedInt32Array()
var done := PackedInt32Array()
var heap_ids := PackedInt32Array()
var heap_keys := PackedFloat64Array()
var gen := 0
var _fast: Object = null


func _init(width: int, height: int, terrain: PackedFloat32Array = PackedFloat32Array()) -> void:
	W = width
	H = height
	heights = terrain
	_fast = Grid.fast_grid()
	if _fast != null:
		_fast.Setup(W, H)
		_fast.ProfileSearches = profile_searches
		return
	g.resize(W * H)
	from.resize(W * H)
	seen.resize(W * H)
	done.resize(W * H)
	heap_ids.resize(HEAP_START_CAP)
	heap_keys.resize(HEAP_START_CAP)


func fast() -> Object:
	return _fast


## Новый неизменяемый снимок стоимости. После мутации/замены массива нужен новый номер.
## Номер действует только в этом Pathfinder; -1 в find_path безопасно отключает повторное использование.
func next_cost_version() -> int:
	_cost_version += 1
	return _cost_version


## Поэлементные правки heights/links обходят setters: вызывать перед пакетом таких правок.
func terrain_changed() -> void:
	_heights_version += 1
	_links_version += 1


func _search_versions(cost_version: int) -> void:
	_fast.CostVersion = cost_version
	_fast.HeightsVersion = _heights_version
	_fast.LinksVersion = _links_version


## Высоты в клетках, как heights. Кэш ленивый: считаются только просмотренные A* шаги.
## Вода под будущим мостом остаётся доступной; сухой шаг не может задеть её краем.
## water — минимальная высота сухого прохода (уровень воды минус разрешённая глубина).
func set_corridor(ground: PackedFloat32Array, water: PackedFloat32Array, wet: PackedByteArray, half: float) -> void:
	if _fast != null:
		_fast.SetCorridor(ground, water, wet, half)
		return
	_ground = ground
	_water = water
	_wet = wet
	_half = half
	_corridor.resize(W * H * 8)
	_corridor.fill(-1.0)
	_cross.resize(W * H * 8)


func _height(x: float, y: float) -> float:
	x = clampf(x, 0.0, W - 1.001)
	y = clampf(y, 0.0, H - 1.001)
	var ix := floori(x)
	var iy := floori(y)
	var tx := x - ix
	var ty := y - iy
	var a := iy * W + ix
	if tx + ty <= 1.0:
		return _ground[a] + (_ground[a + 1] - _ground[a]) * tx + (_ground[a + W] - _ground[a]) * ty
	var d := a + W + 1
	return _ground[d] + (_ground[d - 1] - _ground[d]) * (1.0 - tx) + (_ground[d - W] - _ground[d]) * (1.0 - ty)


func _measure_corridor(c: int, k: int) -> void:
	var key := c * 8 + k
	if _corridor[key] >= 0.0:
		return
	var n := c + Grid.DY[k] * W + Grid.DX[k]
	var grade := 0.0
	var cross_grade := 0.0
	# Консервативный коридор реки включает сухой берег. Пропускается только
	# настоящий водный шаг под будущим мостом, а не проверка всей дороги у реки.
	if (_wet[c] == 0 or _ground[c] >= _water[c]) and (_wet[n] == 0 or _ground[n] >= _water[n]):
		var nx := -Grid.DY[k] / Grid.DL[k] * _half
		var ny := Grid.DX[k] / Grid.DL[k] * _half
		var previous := [0.0, 0.0, 0.0]
		for j in 5:
			var left := 0.0
			var right := 0.0
			for side in 3:
				var x: float = c % W + Grid.DX[k] * j * 0.25 + nx * (side - 1)
				var y: float = c / W + Grid.DY[k] * j * 0.25 + ny * (side - 1)
				var h := _height(x, y)
				var cell := clampi(floori(y + 0.5), 0, H - 1) * W + clampi(floori(x + 0.5), 0, W - 1)
				if _water[cell] > h:
					grade = INF
				if j > 0:
					grade = maxf(grade, absf(h - previous[side]) * 4.0 / Grid.DL[k])
				previous[side] = h
				if side == 0: left = h
				if side == 2: right = h
			cross_grade = maxf(cross_grade, maxf(absf(right - previous[1]), absf(left - previous[1])) / _half)
	_corridor[key] = grade
	_cross[key] = cross_grade
	# Обратный шаг имеет тот же профиль и ширину.
	var opposite := [1, 0, 3, 2, 7, 6, 5, 4]
	_corridor[n * 8 + opposite[k]] = grade
	_cross[n * 8 + opposite[k]] = cross_grade


## Путь от клетки s до клетки t (индексы клеток) по стоимости прохода cost или пустой массив, если пути нет
@warning_ignore("integer_division")
func find_path(cost: PackedFloat32Array, s: int, t: int, climb: float = 0.0, max_grade: float = INF, cost_version: int = -1) -> PackedInt32Array:
	if search_budget == 0:
		return PackedInt32Array()
	if _fast != null:
		_search_versions(cost_version)
		_fast.SearchBudget = search_budget
		var started := Time.get_ticks_usec()
		var path: PackedInt32Array = _fast.FindPath(cost, s, t, heights, climb, max_grade, links, use_corridor, max_cross_grade)
		search_budget = _fast.SearchBudget
		if profile_searches:
			_search_us += Time.get_ticks_usec() - started
		return path
	# Локальные ссылки на поля (в цикле локальные переменные быстрее полей)
	var W := self.W
	var H := self.H
	var heights := self.heights
	var terrain := not heights.is_empty() and (climb > 0.0 or max_grade < INF)
	var g := self.g
	var from := self.from
	var seen := self.seen
	var done := self.done
	var ids := heap_ids
	var keys := heap_keys
	var DX := PackedInt32Array(Grid.DX)
	var DY := PackedInt32Array(Grid.DY)
	var DL := PackedFloat64Array(Grid.DL)
	var OFF := PackedInt32Array()
	for k in 8:
		OFF.append(DY[k] * W + DX[k])
	var W1 := W - 1
	var H1 := H - 1
	gen += 1
	var gn := gen
	var tx := t % W
	var ty := t / W
	g[s] = 0.0
	seen[s] = gn
	from[s] = -1
	ids[0] = s
	keys[0] = 0.0
	var hn := 1
	while hn > 0:
		# извлечь минимум из кучи
		var c := ids[0]
		hn -= 1
		if hn > 0:
			var id := ids[hn]
			var kk := keys[hn]
			var i := 0
			while true:
				var l := 2 * i + 1
				if l >= hn:
					break
				var r := l + 1
				if r < hn and keys[r] < keys[l]:
					l = r
				if keys[l] >= kk:
					break
				ids[i] = ids[l]
				keys[i] = keys[l]
				i = l
			ids[i] = id
			keys[i] = kk
		if c == t:
			break
		if done[c] == gn:
			continue
		if search_budget == 0:
			heap_ids = ids
			heap_keys = keys
			return PackedInt32Array()
		if search_budget > 0:
			search_budget -= 1
		done[c] = gn
		var cx := c % W
		var cy := c / W
		var gc := g[c]
		var cc := cost[c]
		# у клеток не на краю все 8 соседей внутри карты: проверка границ не нужна
		var inner := cx > 0 and cy > 0 and cx < W1 and cy < H1
		for k in 8:
			var nx := cx + DX[k]
			var ny := cy + DY[k]
			var n := c + OFF[k]
			if not inner and (nx < 0 or ny < 0 or nx >= W or ny >= H):
				continue
			var cn := cost[n]
			if cn == INF or done[n] == gn:
				continue
			var step := (cc + cn) * 0.5
			var linked := not links.is_empty() and (links[c] & (1 << k)) != 0
			# диагональный шаг проходит через угол двух соседних клеток: нельзя мимо непроходимой,
			# и он стоит не меньше, чем их пересечь (иначе путь срезает угол озера и бесплатно переходит
			# реку, текущую по диагонали)
			if k >= 4 and not linked:
				var ca := cost[c + DX[k]]
				var cb := cost[c + DY[k] * W]
				if ca == INF or cb == INF:
					continue
				step = maxf(step, (ca + cb) * 0.5)
			# Штраф за уклон вдоль шага, а не только за крутизну всей клетки:
			# по склону можно идти поперёк подъёма. Квадрат предпочитает плавный набор высоты.
			if terrain:
				var grade := absf(heights[n] - heights[c]) / DL[k]
				# Эта диагональ пересекает два треугольника меша: между равными концами
				# может быть крутая ложбина или выступ. Вторая диагональ идёт по ребру.
				if (k == 4 or k == 7) and not linked:
					var mid := (float(heights[c + DX[k]]) + heights[c + DY[k] * W]) * 0.5
					grade = maxf(absf(mid - heights[c]), absf(heights[n] - mid)) * 2.0 / DL[k]
				var cross_grade := 0.0
				if use_corridor and not _ground.is_empty() and not linked:
					_measure_corridor(c, k)
					grade = maxf(grade, _corridor[c * 8 + k])
					cross_grade = _cross[c * 8 + k]
					if grade == INF:
						continue
				if grade > max_grade or cross_grade > max_cross_grade:
					continue
				var steep := maxf(0.0, grade - 0.22)
				# Подъём и земляные работы оплачиваются отдельно: крен не скрывает крутой подъём.
				step += climb * (grade * grade + 4.0 * steep * steep + cross_grade * cross_grade)
			var ng := gc + DL[k] * step
			if seen[n] != gn or ng < g[n]:
				seen[n] = gn
				g[n] = ng
				from[n] = c
				var ax := absi(nx - tx)
				var ay := absi(ny - ty)
				# 0.414 ≈ √2 − 1 (октильная оценка). Не заменять на Grid.SQRT2 - 1: другие знаки меняют
				# тай-брейки и результат, и тогда GDScript перестаёт совпадать с FastGrid.cs
				var key: float = ng + (maxi(ax, ay) + 0.414 * mini(ax, ay)) * H_COST
				# добавить в кучу
				if hn >= ids.size():
					ids.resize(ids.size() * 2)
					keys.resize(keys.size() * 2)
				var i := hn
				hn += 1
				while i > 0:
					var p := (i - 1) >> 1
					if keys[p] <= key:
						break
					ids[i] = ids[p]
					keys[i] = keys[p]
					i = p
				ids[i] = n
				keys[i] = key
	heap_ids = ids
	heap_keys = keys
	var path := PackedInt32Array()
	if seen[t] != gn:
		return path
	var c := t
	while c != -1:
		path.append(c)
		c = from[c]
	path.reverse()
	return path


## Начать в фоне поиск find_path(cost, s, t, climb, max_grade) с нынешними heights, links, use_corridor и запасом
## не больше search_budget (с 9.9). Если следующий find_path с теми же входами будет именно таким, он возьмёт готовый
## результат; иначе фоновый поиск ни на что не влияет. На GDScript ничего не делает.
func prefetch(cost: PackedFloat32Array, s: int, t: int, climb: float = 0.0, max_grade: float = INF, cost_version: int = -1) -> void:
	if _fast != null and search_budget != 0:
		_search_versions(cost_version)
		_fast.Prefetch(cost, s, t, heights, climb, max_grade, links, use_corridor, max_cross_grade, search_budget)


func cancel_prefetch() -> void:
	if _fast != null:
		_fast.CancelPrefetch()


## Поиски закончены: C# отпускает кэш и возвращает буфер прохода в пул без принудительной сборки GC.
func release() -> void:
	if _fast != null:
		_fast.Release()


func search_stats() -> Dictionary:
	if not profile_searches or _fast == null:
		return {}
	var stats: Dictionary = _fast.SearchStats()
	stats.call_ms = _search_us / 1000.0
	return stats
