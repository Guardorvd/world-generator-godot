class_name StageHydrology
extends RefCounted
## Этап 3. Гидрология: заполнение впадин (priority flood), направления стока, озёра, осадки, накопление стока.
## Пишет: w.filled, down, order, order_n, lake, dist_ocean, rain, acc, river; засыпает мелкие впадины в w.h.

const PROGRESS := 0.2
const LABEL := "Течение рек"
## Озеро меньше стольких клеток засыпается, как мелкая впадина (с 1.9.9): на пологих равнинах такие ямы
## глубиной в пару метров выглядели квадратными прудами с отвесными стенками
const LAKE_MIN := 30
## С 2.9 озёр меньше: мелкое (глубже LAKE_DEPTH нигде нет) засыпается, как и маленькое, а слишком большое
## (больше LAKE_MAX клеток на мир 512, это бывшие морские котловины внутри суши) становится сухой низиной
## с уклоном к стоку и мелкими неровностями (_drain), иначе по ровному дну реки шли бы прямыми линиями
const LAKE_DEPTH := 0.035   # ≈ 9 м
const LAKE_MAX := 1200


const DRAIN_TILT := 0.0003  # подъём сухой низины на клетку от стока (≈ 8 см)
## Берег озера не ниже уровня воды плюс SHORE_LIFT (≈ 0,8 м, с 3.0): засыпанные мелководья вокруг озера лежали
## ровно на уровне воды, и вода расползалась по берегу рваными треугольниками
const SHORE_LIFT := 0.003


## again — второй проход после того, как большие котловины стали низинами
static func run(w: WorldData, again := false) -> void:
	var W := w.W
	var H := w.H
	var N := w.N
	var h := w.h
	var ocean := w.ocean
	var fast := Grid.fast_grid()
	var flood: Dictionary = fast.PriorityFlood(h, ocean, W, H) if fast != null else _priority_flood(w)
	var filled: PackedFloat32Array = flood.filled
	var down: PackedInt32Array = flood.down
	var order: PackedInt32Array = flood.order
	var order_n: int = flood.order_n

	var lake := PackedByteArray()
	lake.resize(N)
	for i in N:
		if ocean[i] == 0 and filled[i] - h[i] > 0.008:
			lake[i] = 1
	# Мелкие впадины (не озёра) засыпаны наносами: рельеф вдоль стока не поднимается,
	# и реки не уходят под землю на порогах
	for i in N:
		if ocean[i] == 0 and lake[i] == 0:
			h[i] = filled[i]
	# Одно озеро — один уровень воды (уровень порога стока), без ступенек на поверхности; совсем маленькие
	# озёра засыпаются
	var seen := PackedByteArray()
	seen.resize(N)
	var stack := PackedInt32Array()
	var cells := PackedInt32Array()
	var lake_max := LAKE_MAX * w.scale
	var drained := false
	for s in N:
		if lake[s] == 0 or seen[s] != 0:
			continue
		seen[s] = 1
		stack.append(s)
		cells.clear()
		var lvl := INF
		var deep := 0.0
		while stack.size() > 0:
			var c := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			cells.append(c)
			if filled[c] < lvl:
				lvl = filled[c]
			deep = maxf(deep, filled[c] - h[c])
			var cx := c % W
			var cy := c / W
			for k in 8:
				var nx: int = cx + Grid.DX[k]
				var ny: int = cy + Grid.DY[k]
				if nx < 0 or ny < 0 or nx >= W or ny >= H:
					continue
				var n := ny * W + nx
				if lake[n] != 0 and seen[n] == 0:
					seen[n] = 1
					stack.append(n)
		if cells.size() > lake_max and deep >= LAKE_DEPTH and not again:
			_drain(w, cells, down, lvl)
			drained = true
			continue
		if cells.size() < LAKE_MIN or cells.size() > lake_max or deep < LAKE_DEPTH:
			for c in cells:
				lake[c] = 0
				h[c] = filled[c]
			continue
		for c in cells:
			filled[c] = lvl

	if drained:
		# у низин новый рельеф: впадины и сток считаются заново
		run(w, true)
		return

	var dist_ocean := Grid.distance_field(W, H, ocean)
	# Flood даёт безопасный выход из впадин; на склонах выбираем самый крутой
	# спуск по длине ребра, а не первого соседа, обнаруженного кучей.
	# Ранг сохраняет порядок накопления и исключает циклы на плоских участках.
	if fast != null:
		# Тот же выбор на C# (FastGrid.SteepestDown): восемь соседей на клетку в GDScript — основная часть этапа.
		down = fast.SteepestDown(filled, ocean, lake, down, order, order_n, W, H)
	var rank := PackedInt32Array()
	if fast == null:
		rank.resize(N)
		for k in order_n:
			rank[order[k]] = k
	for i in (N if fast == null else 0):
		if ocean[i] != 0 or lake[i] != 0 or down[i] < 0:
			continue
		var best := 0.0
		var x := i % W
		var y := i / W
		for k in 8:
			var nx: int = x + Grid.DX[k]
			var ny: int = y + Grid.DY[k]
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var n := ny * W + nx
			var drop := (filled[i] - filled[n]) / Grid.DL[k]
			if rank[n] < rank[i] and drop > best:
				best = drop
				down[i] = n

	# Предварительная влажность (осадки): шум + близость к морю
	var moist_n := w.noise_field("moist")
	var rain := PackedFloat32Array()
	rain.resize(N)
	for i in N:
		rain[i] = clampf(0.36 + 0.85 * moist_n[i] + 0.18 * exp(-dist_ocean[i] / 30.0), 0.02, 1.0)

	# Накопление стока сверху вниз по порядку заполнения
	var acc := PackedFloat32Array()
	acc.resize(N)
	for k in range(order_n - 1, -1, -1):
		var i := order[k]
		if ocean[i] != 0:
			continue
		# Часть осадков впитывается; небольшой базовый сток поддерживает ручьи
		# умеренного климата. Единицы и пороги не зависят от размера окна мира.
		acc[i] += maxf(0.04, rain[i] - 0.12)
		var d := down[i]
		if d >= 0:
			acc[d] += acc[i]

	var river := PackedByteArray()
	river.resize(N)
	for i in N:
		if ocean[i] == 0 and lake[i] == 0 and acc[i] >= WorldData.STREAM_ACC:
			river[i] = 1

	# С 3.1 берег поднимается после определения рек: русла у входа и выхода озера остаются
	# на высоте стока. Иначе береговая прибавка делала в реке порог против течения
	for i in N:
		if lake[i] == 0 or ocean[i] != 0:
			continue
		var cx := i % W
		var cy := i / W
		for k in 8:
			var nx: int = cx + Grid.DX[k]
			var ny: int = cy + Grid.DY[k]
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			# с 6.9 край карты не поднимается: он должен совпадать с рельефом за краем (OuterLand)
			if nx == 0 or ny == 0 or nx == W - 1 or ny == H - 1:
				continue
			var n := ny * W + nx
			if lake[n] == 0 and ocean[n] == 0 and river[n] == 0 and h[n] < filled[i] + SHORE_LIFT:
				h[n] = filled[i] + SHORE_LIFT
				filled[n] = maxf(filled[n], h[n])

	w.h = h
	w.filled = filled
	w.down = down
	w.order = order
	w.order_n = order_n
	w.lake = lake
	w.dist_ocean = dist_ocean
	w.rain = rain
	w.acc = acc
	w.river = river
	# Выход каждого водосбора один на весь план. down уже идёт к меньшему рангу,
	# поэтому его метку можно переиспользовать одним проходом без нового поиска.
	var watershed := PackedInt32Array()
	watershed.resize(N)
	watershed.fill(-1)
	for k in order_n:
		var i := order[k]
		watershed[i] = i if down[i] < 0 else watershed[down[i]]
	w.watershed = watershed


## Большая котловина становится сухой низиной: дно поднимается к уровню порога, от стока (клетки, откуда
## вода уходит из котловины) вглубь растёт на DRAIN_TILT за клетку, сверху мелкие неровности
static func _drain(w: WorldData, cells: PackedInt32Array, down: PackedInt32Array, lvl: float) -> void:
	var W := w.W
	var h := w.h
	var dist := {}
	for c in cells:
		dist[c] = -1
	var queue := PackedInt32Array()
	for c in cells:
		if down[c] < 0 or not dist.has(down[c]):
			dist[c] = 0
			queue.append(c)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var x := c % W
		for n: int in [c - 1 if x > 0 else -1, c + 1 if x < W - 1 else -1, c - W, c + W]:
			if dist.get(n, 0) == -1:
				dist[n] = dist[c] + 1
				queue.append(n)
	var base := maxf(lvl, 0.002)
	var micro: Simplex = w.noise.micro
	for c in cells:
		var x := c % W
		var y := c / W
		h[c] = base + maxf(0, dist[c]) * DRAIN_TILT + (micro.noise(x / 9.0, y / 9.0) + 1.0) * 0.003


## Заполнение впадин от океана и от края карты (priority flood): с 1.9.6 за краем мир продолжается, и вода
## с суши у края стекает туда, а не ищет выход к океану через всю карту. Возвращает {filled, down, order, order_n}.
## В сборке Godot .NET вместо него работает FastGrid.PriorityFlood, результат тот же.
static func _priority_flood(w: WorldData) -> Dictionary:
	var W := w.W
	var H := w.H
	var N := w.N
	var h := w.h
	var ocean := w.ocean
	var filled := h.duplicate()
	var down := PackedInt32Array()
	down.resize(N)
	down.fill(-1)
	var order := PackedInt32Array()
	order.resize(N)
	var order_n := 0
	var closed := PackedByteArray()
	closed.resize(N)
	var heap := MinHeap.new(N + 16)
	for i in N:
		if ocean[i] != 0 or Grid.on_edge(i, W, H):
			closed[i] = 1
			heap.push(i, h[i])
	# Цикл заполнения с развёрнутой кучей (тот же алгоритм, что MinHeap, без вызовов методов)
	var ids := heap.ids
	var keys := heap.keys
	var hn := heap.n
	var DX := Grid.DX
	var DY := Grid.DY
	while hn > 0:
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
		order[order_n] = c
		order_n += 1
		var cx := c % W
		var cy := c / W
		var fc := filled[c]
		for k in 8:
			var nx: int = cx + DX[k]
			var ny: int = cy + DY[k]
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var n := ny * W + nx
			if closed[n] != 0:
				continue
			closed[n] = 1
			filled[n] = maxf(h[n], fc + 1e-5)
			down[n] = c
			var key := filled[n]
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
	return {filled = filled, down = down, order = order, order_n = order_n}
