class_name StageHydrology
extends RefCounted
## Этап 3. Гидрология: заполнение впадин (priority flood), направления стока, озёра, осадки, накопление стока.
## Пишет: w.filled, down, order, order_n, lake, dist_ocean, rain, acc, river; засыпает мелкие впадины в w.h.

const PROGRESS := 0.2
const LABEL := "Течение рек"


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
	# Мелкие впадины (не озёра) засыпаны наносами: рельеф вдоль стока не поднимается,
	# и реки не уходят под землю на порогах
	for i in N:
		if ocean[i] == 0 and lake[i] == 0:
			h[i] = filled[i]
	# Одно озеро — один уровень воды (уровень порога стока), без ступенек на поверхности
	var seen := PackedByteArray()
	seen.resize(N)
	var stack := PackedInt32Array()
	var cells := PackedInt32Array()
	for s in N:
		if lake[s] == 0 or seen[s] != 0:
			continue
		seen[s] = 1
		stack.append(s)
		cells.clear()
		var lvl := INF
		while stack.size() > 0:
			var c := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			cells.append(c)
			if filled[c] < lvl:
				lvl = filled[c]
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
		for c in cells:
			filled[c] = lvl

	var dist_ocean := Grid.distance_field(W, H, ocean)

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
		acc[i] += rain[i]
		var d := down[i]
		if d >= 0:
			acc[d] += acc[i]

	var river := PackedByteArray()
	river.resize(N)
	for i in N:
		if ocean[i] == 0 and lake[i] == 0 and acc[i] >= WorldData.RIVER_ACC:
			river[i] = 1

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
