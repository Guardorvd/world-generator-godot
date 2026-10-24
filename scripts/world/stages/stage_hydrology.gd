class_name StageHydrology
extends RefCounted
## Priority flood detects lakes and supplies an acyclic flow order.
## Non-lake sinks are breached, never filled into terrain terraces.

const PROGRESS := 0.2
const LABEL := "Течение рек"
const LAKE_MIN := 30
const LAKE_DEPTH := 0.035   # ≈ 9 м
const LAKE_MAX := 1200


## Shore clearance above lake water (normalised height).
const SHORE_LIFT := 0.003


static func run(w: WorldData) -> void:
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
	var seen := PackedByteArray()
	seen.resize(N)
	var stack := PackedInt32Array()
	var cells := PackedInt32Array()
	var lake_max := LAKE_MAX * w.scale
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
		if cells.size() < LAKE_MIN or cells.size() > lake_max or deep < LAKE_DEPTH:
			for c in cells:
				lake[c] = 0
			continue
		for c in cells:
			filled[c] = lvl

	# Include the shallow fringe of retained lakes up to their actual shoreline.
	# Leaving it as dry land would force river shaping to raise submerged inflows.
	stack.clear()
	for i in N:
		if lake[i] != 0:
			stack.append(i)
	var head := 0
	while head < stack.size():
		var c := stack[head]
		head += 1
		for k in 8:
			var x: int = c % W + Grid.DX[k]
			var y: int = c / W + Grid.DY[k]
			if x < 0 or y < 0 or x >= W or y >= H:
				continue
			var n := y * W + x
			if lake[n] == 0 and ocean[n] == 0 and h[n] < filled[c] and absf(filled[n] - filled[c]) < 1e-7:
				lake[n] = 1
				stack.append(n)

	# Keep the original depression footprint for soil moisture, including shallow
	# hollows below the lake candidate threshold. Flood's numerical tilt is not a wetland.
	var wetland := PackedByteArray()
	wetland.resize(N)
	for i in N:
		if ocean[i] == 0 and lake[i] == 0 and filled[i] - h[i] > 0.0001:
			wetland[i] = 1
	_breach_depressions(w, h, wetland, lake, down)
	w.h = h
	# Rebuild ranks, catchments and accumulation on the carved terrain. Retained
	# lakes still use a virtual filled water surface; no virtual fill is copied to h.
	flood = fast.PriorityFlood(h, ocean, W, H) if fast != null else _priority_flood(w)
	filled = flood.filled
	down = flood.down
	order = flood.order
	order_n = flood.order_n
	w.wetland = wetland

	var dist_ocean := Grid.distance_field(W, H, ocean)
	# Flood даёт безопасный выход из впадин; на склонах выбираем самый крутой
	# спуск по длине ребра, а не первого соседа, обнаруженного кучей.
	# Ранг сохраняет порядок накопления и исключает циклы на плоских участках.
	var rank := PackedInt32Array()
	rank.resize(N)
	for k in order_n:
		rank[order[k]] = k
	for i in N:
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

	var acc := _accumulate(w, filled, down, order, order_n, rain, lake)

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
	# Метка основного тальвега (на пологих склонах MFD может делить сток
	# между водосборами). down идёт к меньшему рангу, метки строятся за один проход.
	var watershed := PackedInt32Array()
	watershed.resize(N)
	watershed.fill(-1)
	for k in order_n:
		var i := order[k]
		watershed[i] = i if down[i] < 0 else watershed[down[i]]
	w.watershed = watershed


## Sheet flow on gentle slopes converges continuously into a single thalweg.
## Only strictly descending, lower-rank neighbours receive MFD flow: the flood
## tree handles flats/lakes, preserving an acyclic order and all rainfall mass.
static func _accumulate(w: WorldData, filled: PackedFloat32Array, down: PackedInt32Array,
		order: PackedInt32Array, order_n: int, rain: PackedFloat32Array, lake: PackedByteArray) -> PackedFloat32Array:
	var W := w.W
	var H := w.H
	var N := w.N
	var ocean := w.ocean
	var acc := PackedFloat32Array()
	acc.resize(N)
	var rank := PackedInt32Array()
	rank.resize(N)
	for k in order_n:
		rank[order[k]] = k
	var weights := PackedFloat64Array()
	weights.resize(8)
	for index in range(order_n - 1, -1, -1):
		var i := order[index]
		if ocean[i] != 0:
			continue
		acc[i] += maxf(0.04, rain[i] - 0.12)
		var d := down[i]
		if d < 0:
			continue
		var diffuse := 1.0 - smoothstep(WorldData.STREAM_ACC * 0.4, WorldData.STREAM_ACC, acc[i])
		if lake[i] != 0 or diffuse <= 0.0:
			acc[d] += acc[i]
			continue
		var x := i % W
		var y := i / W
		var total := 0.0
		var steepest := 0.0
		for k in 8:
			weights[k] = 0.0
			var nx: int = x + Grid.DX[k]
			var ny: int = y + Grid.DY[k]
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var n := ny * W + nx
			var slope := (filled[i] - filled[n]) / Grid.DL[k]
			if rank[n] >= rank[i] or slope <= 0.0:
				continue
			steepest = maxf(steepest, slope * GameConfig.HS / GameConfig.TILE)
			weights[k] = pow(slope, 1.1)
			total += weights[k]
		diffuse *= 1.0 - smoothstep(0.03, 0.15, steepest)
		if total <= 0.0 or diffuse <= 0.0:
			acc[d] += acc[i]
			continue
		acc[d] += acc[i] * (1.0 - diffuse)
		for k in 8:
			if weights[k] > 0.0:
				var n: int = (y + Grid.DY[k]) * W + x + Grid.DX[k]
				acc[n] += acc[i] * diffuse * weights[k] / total
	return acc


## Least excavation cost (depth * edge length), with a small distance penalty
## favouring a nearby lower slope when excavation costs match. Dijkstra explores
## only visited cells; no N-sized scratch buffers per sink. Process low pits first
## so later channels can drain into earlier breaches. Retained lake beds are protected.
const BREACH_DROP := 0.0001
const BREACH_DISTANCE_COST := 0.0001

static func _breach_depressions(w: WorldData, h: PackedFloat32Array,
		wetland: PackedByteArray, lake: PackedByteArray, down: PackedInt32Array) -> void:
	var pits := MinHeap.new(64)
	for i in w.N:
		if wetland[i] == 0 or down[i] < 0 or h[down[i]] <= h[i]:
			continue
		var low := true
		for k in 8:
			var x: int = i % w.W + Grid.DX[k]
			var y: int = i / w.W + Grid.DY[k]
			if x >= 0 and y >= 0 and x < w.W and y < w.H and h[y * w.W + x] < h[i]:
				low = false
		if low:
			pits.push(i, h[i])
	while pits.n > 0:
		_breach_from(w, h, lake, pits.pop())


static func _breach_from(w: WorldData, h: PackedFloat32Array, lake: PackedByteArray, pit: int) -> void:
	var level := h[pit] - BREACH_DROP
	var costs := {pit: 0.0}
	var parent := {pit: -1}
	var closed := {}
	var heap := MinHeap.new(64)
	heap.push(pit, 0.0)
	var outlet := -1
	while heap.n > 0:
		var c := heap.pop()
		if closed.has(c):
			continue
		closed[c] = true
		if c != pit and (h[c] <= level or Grid.on_edge(c, w.W, w.H)):
			outlet = c
			break
		for k in 8:
			var x: int = c % w.W + Grid.DX[k]
			var y: int = c / w.W + Grid.DY[k]
			if x < 0 or y < 0 or x >= w.W or y >= w.H:
				continue
			var n := y * w.W + x
			if closed.has(n) or lake[n] != 0:
				continue
			var cost: float = costs[c] + (maxf(0.0, h[n] - level) + BREACH_DISTANCE_COST) * Grid.DL[k]
			if cost < float(costs.get(n, INF)):
				costs[n] = cost
				parent[n] = c
				heap.push(n, cost)
	if outlet < 0:
		return
	var path := PackedInt32Array()
	var c := outlet
	while c != pit:
		path.append(c)
		c = parent[c]
	# A tiny continuous fall opens the outlet without raising or flattening the
	# surrounding bowl. Only the single-cell channel is excavated.
	for k in path.size():
		var target := lerpf(h[pit], level, float(path.size() - k) / path.size())
		h[path[k]] = minf(h[path[k]], target)


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
			filled[n] = maxf(h[n], fc)
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
