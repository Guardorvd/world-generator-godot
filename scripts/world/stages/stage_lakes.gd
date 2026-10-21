class_name StageLakes
extends RefCounted
## Этап 9 (с 2.9). Названия крупных озёр — природные места для карты, целей и быстрого перемещения.
## Идёт последним: озёра уже готовы. Растительность использует свой rng,
## поэтому изменения леса не сдвигают выбор названий озёр.
## Пишет: w.lakes [{x, y — середина (дальше всего от берега), i, level — уровень воды, name, cells,
## sx, sy — клетка берега}],
## w.lake_id — номер озера с названием для каждой клетки или -1.

const MIN_CELLS := 150  # озеро меньше этого (клеток) не получает названия: названия — редкость
const MAX_LAKES := 5    # больше названий на одной карте не бывает
## Доли стороны карты по x и y: ближе к поселению, вершине или другому озеру название не ставится, иначе
## подписи на большой карте ложатся друг на друга (подпись широкая и низкая)
const CLEAR := Vector2(1.0 / 10.0, 1.0 / 60.0)


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var lake := w.lake
	# озёра — связные по четырём соседям куски клеток lake
	var comp := PackedInt32Array()
	comp.resize(w.N)
	comp.fill(-1)
	var groups: Array[PackedInt32Array] = []
	var s := lake.find(1)
	while s >= 0:
		if comp[s] >= 0:
			s = lake.find(1, s + 1)
			continue
		var cells := PackedInt32Array([s])
		comp[s] = groups.size()
		var head := 0
		var g := groups.size()
		while head < cells.size():
			var c := cells[head]
			head += 1
			var x := c % W
			# четыре соседа без вызовов других классов: озёр в большом мире до сотни тысяч клеток
			for n: int in [c - 1 if x > 0 else -1, c + 1 if x < W - 1 else -1, c - W, c + W]:
				if n >= 0 and n < w.N and lake[n] != 0 and comp[n] < 0:
					comp[n] = g
					cells.append(n)
		groups.append(cells)
		s = lake.find(1, s + 1)
	var big: Array = []
	for g in groups.size():
		if groups[g].size() >= MIN_CELLS:
			big.append([groups[g].size(), g])
	big.sort_custom(StageLandmarks._by_score_desc)
	var want := clampi(roundi(3.0 * w.scale), 1, MAX_LAKES)
	var lake_id := PackedInt32Array()
	lake_id.resize(w.N)
	lake_id.fill(-1)
	var ocean := w.ocean
	var river := w.river
	var dist := PackedInt32Array()
	dist.resize(w.N)
	dist.fill(-1)
	var lakes: Array = []
	var taken := PackedVector2Array()   # середины мест с подписями на карте
	for s2 in w.settlements:
		taken.append(Vector2(s2.x, s2.y))
	for pk in w.peaks:
		taken.append(Vector2(pk.x, pk.y))
	var clear := CLEAR * w.W
	for b: Array in big:
		if lakes.size() >= want:
			break
		var cells: PackedInt32Array = groups[b[1]]
		var n := lakes.size()
		# расстояние от берега внутрь озера: середина — самая далёкая клетка
		var queue := PackedInt32Array()
		for c in cells:
			var x := c % W
			var g := comp[c]
			if x == 0 or x == W - 1 or c < W or c >= w.N - W or comp[c - 1] != g or comp[c + 1] != g or comp[c - W] != g or comp[c + W] != g:
				dist[c] = 0
				queue.append(c)
		var head := 0
		var mid := queue[0]
		while head < queue.size():
			var c := queue[head]
			head += 1
			if dist[c] > dist[mid]:
				mid = c
			for nn: int in [c - 1, c + 1, c - W, c + W]:
				if nn >= 0 and nn < w.N and comp[nn] == comp[c] and dist[nn] < 0:
					dist[nn] = dist[c] + 1
					queue.append(nn)
		var mx := (mid % W) + 0.5
		var my := (mid / W) + 0.5
		var crowded := false
		for t in taken:
			if absf(t.x - mx) < clear.x and absf(t.y - my) < clear.y:
				crowded = true
				break
		if crowded:
			continue
		taken.append(Vector2(mx, my))
		for c in cells:
			lake_id[c] = n
		# берег, куда встаёт игрок при быстром перемещении: ближайшая к середине сухая клетка у воды,
		# не у вытекающей реки (иначе под ногами поток вниз по склону)
		var shore := Vector2(mx, my)
		var sd := INF
		for c in queue:
			if dist[c] > 0:
				break   # в очереди сначала идут все клетки у берега
			var x := c % W
			for nn: int in [c - 1 if x > 0 else -1, c + 1 if x < W - 1 else -1, c - W, c + W]:
				if nn < 0 or nn >= w.N or lake[nn] != 0 or ocean[nn] != 0 or river[nn] != 0:
					continue
				var d := Vector2((nn % W) + 0.5 - mx, (nn / W) + 0.5 - my).length_squared()
				if d < sd and not _river_near(w, nn % W, nn / W):
					sd = d
					shore = Vector2((nn % W) + 0.5, (nn / W) + 0.5)
		lakes.append({x = mx, y = my, i = n, level = w.filled[mid], name = w.make_name(Names.LAKE), cells = cells.size(), sx = shore.x, sy = shore.y})
	w.lakes = lakes
	w.lake_id = lake_id


## Есть ли река в квадрате 5 × 5 клеток вокруг (x, y)
static func _river_near(w: WorldData, x: int, y: int) -> bool:
	for dy in range(maxi(0, y - 2), mini(w.H, y + 3)):
		for dx in range(maxi(0, x - 2), mini(w.W, x + 3)):
			if w.river[dy * w.W + dx] != 0:
				return true
	return false
