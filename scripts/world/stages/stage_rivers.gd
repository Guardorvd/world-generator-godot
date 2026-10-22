class_name StageRivers
extends RefCounted
## Этап 4. Трассировка рек в ломаные: от истока до устья, слияния или озера.
## Пишет: w.h, filled — профиль рек и долины; rivers — ломаные {x, y, w, e}; river_exits.

const PROGRESS := 0.3
const LABEL := "Русла рек и озёра"
const WIDTH_ACC := 70.0  # сток, от которого считается ширина (прежний порог реки: с 2.9 реки реже, но не уже)


static func _width_of(w: WorldData, i: int) -> float:
	var variation := 0.0
	if w.noise.has("micro"):
		variation = w.noise.micro.noise((i % w.W + w.macro_x) / 26.0, (i / w.W + w.macro_y) / 26.0)
	var d := w.down[i]
	var grade := 0.0 if d < 0 else maxf(0.0, w.filled[i] - w.filled[d]) * GameConfig.HS / GameConfig.TILE
	return (0.08 + minf(1.65, sqrt(w.acc[i] / WIDTH_ACC) * 0.2)) * (1.0 + variation * 0.12) * lerpf(1.0, 0.85, smoothstep(0.05, 0.5, grade))


static func half_width(width: float) -> float:
	return width * GameConfig.TILE * 0.55 + 0.3


## e — высота воды (0 — уровень моря): вдоль стока она только убывает
static func _pt(w: WorldData, i: int) -> Dictionary:
	return {
		x = (i % w.W) + 0.5, y = (i / w.W) + 0.5, w = _width_of(w, i),
		e = 0.0 if w.ocean[i] != 0 else maxf(0.0, w.filled[i]),
	}


static func run(w: WorldData) -> void:
	_shape_valleys(w)
	var N := w.N
	var ocean := w.ocean
	var lake := w.lake
	var river := w.river
	var down := w.down
	var acc := w.acc
	var rivers: Array = []
	var has_donor := PackedByteArray()
	has_donor.resize(N)
	var lake_donor := PackedInt32Array()
	lake_donor.resize(N)
	lake_donor.fill(-1)
	for i in N:
		var d := down[i]
		if d < 0 or river[d] == 0:
			continue
		if river[i] != 0:
			has_donor[d] = mini(2, has_donor[d] + 1)
		elif lake[i] != 0 and (lake_donor[d] < 0 or acc[i] > acc[lake_donor[d]]):
			lake_donor[d] = i
	var visited := PackedByteArray()
	visited.resize(N)
	w.river_exits.clear()
	for s in N:
		# Каждое слияние — общий конец притоков и начало следующего участка.
		# Сглаживание сохраняет концы: вода и ширина на стыке совпадают.
		if river[s] == 0 or has_donor[s] == 1:
			continue
		var pts: Array = []
		if lake_donor[s] >= 0:
			var p := _pt(w, lake_donor[s])
			p.w = _width_of(w, s)
			pts.append(p)
		var c := s
		while true:
			pts.append(_pt(w, c))
			visited[c] = 1
			var d := down[c]
			if d < 0:
				var p := _pt(w, c)
				var dx := -1 if c % w.W == 0 else (1 if c % w.W == w.W - 1 else 0)
				var dy := -1 if c < w.W else (1 if c >= N - w.W else 0)
				if dx != 0 or dy != 0:
					p.x += dx * 0.5
					p.y += dy * 0.5
					pts.append(p)
					w.river_exits.append({x = p.x, y = p.y, dx = dx, dy = dy, acc = acc[c], e = p.e, w = p.w})
				break
			if ocean[d] != 0 or lake[d] != 0:
				var p := _pt(w, d)
				p.w = _width_of(w, c) * 1.3
				pts.append(p)
				break
			if river[d] == 0:
				break
			if has_donor[d] > 1 or visited[d] != 0:
				pts.append(_pt(w, d))
				break
			c = d
		if pts.size() >= 2:
			rivers.append(Grid.chaikin(pts, 2))
	w.rivers = rivers
	# Консервативный коридор ленты для дорог, домов и растительности.
	# Не меняем гидрологическую сеть: acc/down по-прежнему относятся к river.
	w.river_area = river.duplicate()
	# Берег определяется по окончательному игровому дну: тот же коридор нужен
	# дорогам, растительности и расстояниям до воды ещё до этапа климата.
	var surface := Heightfield.new(w, false, true)
	for cell: int in surface._river_cells:
		w.river_area[cell] = 1
	# Дальше рельеф, вода и реки не меняются: этот же рельеф (с уровнями воды по готовому коридору)
	# служит базой загрузчику, дорогам и планировке домов (с 9.7), а не строится каждым заново
	surface.complete_water()
	w.base_heights = surface


## Один проход вместо эрозии. Вода в руслах опускается от устья вверх,
## затем склоны долины подрезаются к этому профилю. Исходные склоны задают
## узкую V-долину в горах и широкую пойму на равнине. Поверхность воды не ниже моря.
static func _shape_valleys(w: WorldData) -> void:
	var original := w.h.duplicate()
	for k in w.order_n:
		var i := w.order[k]
		if w.river[i] == 0:
			continue
		var x := i % w.W
		var y := i / w.W
		# На границе остаётся исходный профиль: за картой пока только сырой рельеф.
		var edge := minf(minf(x, w.W - 1 - x), minf(y, w.H - 1 - y))
		var fade := smoothstep(0.0, 8.0, edge)
		var size := clampf(sqrt(w.acc[i] / WorldData.RIVER_ACC), 0.0, 3.0)
		var d := w.down[i]
		var floor_level := 0.0 if d < 0 else maxf(0.0, w.filled[d])
		var level := maxf(floor_level, original[i] - (0.003 + 0.003 * size) * fade)
		w.filled[i] = level
		w.h[i] = level
	var W := w.W
	var H := w.H
	var h := w.h
	var filled := w.filled
	var ocean := w.ocean
	var lake := w.lake
	var river := w.river
	var acc := w.acc
	var DX := Grid.DX
	var DY := Grid.DY
	# С 6.9 подрезка долины не опускает берег озера ниже его воды плюс SHORE_LIFT
	# (у выхода реки из озера склон долины уходил под уровень озера)
	var bank := PackedFloat32Array()
	bank.resize(w.N)
	bank.fill(-INF)
	for i in w.N:
		if lake[i] == 0 or ocean[i] != 0:
			continue
		var cx := i % W
		var cy := i / W
		for k in 8:
			var nx: int = cx + DX[k]
			var ny: int = cy + DY[k]
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var n := ny * W + nx
			bank[n] = maxf(bank[n], filled[i] + StageHydrology.SHORE_LIFT)
	# Снимок высот и min делают результат независимым от порядка соседних русел.
	for i in w.N:
		if river[i] == 0:
			continue
		var x := i % W
		var y := i / W
		var relief := 0.0
		for k in 8:
			var nx: int = clampi(x + DX[k] * 2, 0, W - 1)
			var ny: int = clampi(y + DY[k] * 2, 0, H - 1)
			relief = maxf(relief, absf(original[ny * W + nx] - original[i]))
		var steep := smoothstep(0.012, 0.09, relief)
		var size := clampf(sqrt(acc[i] / WorldData.RIVER_ACC), 0.0, 3.0)
		var radius := lerpf(3.0 + size * 1.5, 1.5 + size * 0.4, steep)
		var r := ceili(radius)
		var fi := filled[i]
		for ny in range(maxi(0, y - r), mini(H, y + r + 1)):
			for nx in range(maxi(0, x - r), mini(W, x + r + 1)):
				var n := ny * W + nx
				if ocean[n] != 0 or lake[n] != 0 or river[n] != 0:
					continue
				var t := Vector2(nx - x, ny - y).length() / radius
				if t >= 1.0:
					continue
				var edge := minf(minf(nx, W - 1 - nx), minf(ny, H - 1 - ny))
				var blend := (1.0 - smoothstep(0.0, 1.0, t)) * smoothstep(0.0, 8.0, edge)
				var profile := fi + 0.002 + lerpf(0.012 * t * t, 0.09 * t, steep)
				# Ограниченный срез: горы не превращаются в глубокие щели.
				var target := maxf(profile, original[n] - lerpf(0.012, 0.035, steep))
				var cut := lerpf(original[n], minf(original[n], target), blend)
				h[n] = minf(h[n], maxf(cut, minf(original[n], bank[n])))
