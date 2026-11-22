extends RefCounted
## Историческая реализация для независимой сверки портов C# на стенде.

const SHORTCUT := 1.25
const RELIEF_CHOICE := 0.02 # другой проход отличается высотой примерно на 5 м (единицы w.h)


## Клетки сети (участки путей людей) и расстояние до них
static func _net_cells(w: WorldData) -> PackedByteArray:
	var net := PackedByteArray()
	net.resize(w.N)
	var owner := w.generation.road_owner
	for i in w.N:
		if owner[i] >= 0: net[i] = 1
	return net


static func _net_near(w: WorldData) -> PackedFloat32Array:
	return Grid.distance_field(w.W, w.H, _net_cells(w))


## Путь дважды касается одного участка сети (пересекает или примыкает) ближе StageTrails.REJOIN_GAP клеток друг от друга:
## повторное пересечение, Z-образный заход на дорогу и обратно. Касания на концах пути (узлы) не считаются.
static func _rejoins(w: WorldData, p: PackedInt32Array) -> bool:
	var owner := w.generation.road_owner
	var n := p.size()
	var first := 0
	while first < n and owner[p[first]] >= 0: first += 1
	var last := n - 1
	while last >= 0 and owner[p[last]] >= 0: last -= 1
	var seen := {}
	var previous := -1
	for k in range(first, last + 1):
		var o := owner[p[k]]
		if o >= 0 and o != previous:
			if seen.has(o) and k - int(seen[o]) < StageTrails.REJOIN_GAP: return true
		# выход с участка записывается при любой смене участка, в том числе без свободной клетки между участками
		if o != previous and previous >= 0: seen[previous] = k
		previous = o
	return false


## Годится ли новый путь как дополнение сети: не вдоль неё и без повторных пересечений
static func _adds_network(w: WorldData, p: PackedInt32Array, near: PackedFloat32Array) -> bool:
	var side := StageTrails._parallel_stats(w, p, near, _net_cells(w))
	return side.x <= StageTrails.PARALLEL_SHARE and side.y <= StageTrails.PARALLEL_RUN and not _rejoins(w, p)


## Более низкий перевал или другой уровень долины/склона дают осмысленный выбор направления.
static func _different_relief(w: WorldData, a: PackedInt32Array, b: PackedInt32Array) -> bool:
	var top_a := -INF
	var top_b := -INF
	var mean_a := 0.0
	var mean_b := 0.0
	for i in a:
		top_a = maxf(top_a, w.h[i])
		mean_a += w.h[i]
	for i in b:
		top_b = maxf(top_b, w.h[i])
		mean_b += w.h[i]
	return top_a < top_b - RELIEF_CHOICE or absf(mean_a / a.size() - mean_b / b.size()) > RELIEF_CHOICE


## Не дублировать маршрут, уже проходящий по другой части сети.
static func _new_ground(w: WorldData, p: PackedInt32Array) -> bool:
	var fresh := 0
	for i in p:
		if w.path_mask[i] < 2:
			fresh += 1
	return fresh > p.size() * 0.5


## Расстояние (клеток) до моря или озера; не дальше 1,5 — то же, что _at_mouth (вода в восьми соседях или сама клетка)
static func _water_dist(w: WorldData) -> PackedFloat32Array:
	var water := PackedByteArray()
	water.resize(w.N)
	for i: int in w.N:
		if w.ocean[i] != 0 or w.lake[i] != 0: water[i] = 1
	return Grid.distance_field(w.W, w.H, water)


## Ближайшая к клетке s клетка морского или озёрного берега от StageTrails.SHORE_MIN до StageTrails.SHORE_MAX клеток,
## не в коридоре near прежних путей; -1, если такой нет
static func _shore(w: WorldData, s: int, near: PackedByteArray, water_d: PackedFloat32Array) -> int:
	var W := w.W
	var sx := s % W
	var sy := s / W
	var best := -1
	var bd := INF
	for y in range(maxi(0, sy - StageTrails.SHORE_MAX), mini(w.H, sy + StageTrails.SHORE_MAX + 1)):
		for x in range(maxi(0, sx - StageTrails.SHORE_MAX), mini(W, sx + StageTrails.SHORE_MAX + 1)):
			var i := y * W + x
			var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
			if d < StageTrails.SHORE_MIN * StageTrails.SHORE_MIN or d >= bd or near[i] != 0 or w.cost[i] == INF or water_d[i] > 1.5:
				continue
			bd = d
			best = i
	return best


## Смотровая точка у клетки сети s: самая высокая клетка суши в кольце StageTrails.VIEW_MIN..StageTrails.VIEW_MAX (перебор через StageTrails.VIEW_STEP),
## выше s на StageTrails.VIEW_RISE м, не в коридоре near прежних путей и не на краю кольца (там склон продолжается — это не вершина);
## -1, если такой нет
static func _overlook(w: WorldData, s: int, near: PackedByteArray) -> int:
	var sx := s % w.W
	var sy := s / w.W
	var best := -1
	var top := w.h[s] + StageTrails.VIEW_RISE / (StageTrails.HEIGHT_SCALE * GameConfig.TILE)
	var best_d := 0
	for y in range(maxi(0, sy - StageTrails.VIEW_MAX), mini(w.H, sy + StageTrails.VIEW_MAX + 1), StageTrails.VIEW_STEP):
		for x in range(maxi(0, sx - StageTrails.VIEW_MAX), mini(w.W, sx + StageTrails.VIEW_MAX + 1), StageTrails.VIEW_STEP):
			var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
			if d < StageTrails.VIEW_MIN * StageTrails.VIEW_MIN or d > StageTrails.VIEW_MAX * StageTrails.VIEW_MAX: continue
			var i := y * w.W + x
			if w.h[i] <= top or near[i] != 0 or w.cost[i] == INF or w.ocean[i] != 0 or w.lake[i] != 0: continue
			top = w.h[i]
			best = i
			best_d = d
	if best < 0 or best_d > (StageTrails.VIEW_MAX - 3) * (StageTrails.VIEW_MAX - 3):
		return -1
	return best


## 17.11.2026: петля в выезде — в круге StageTrails.EXIT_R вокруг конца пути он уже отошёл от сети (больше StageTrails.JITTER_RUN свободных
## клеток подряд), а потом снова идёт по ней дольше StageTrails.CROSS_RUN клеток: «сошёл — вернулся — снова сошёл» у поселения.
## Общий выезд по дороге и короткое пересечение другой дороги после схода — не петля. reverse — со стороны конца.
static func _exit_loop(w: WorldData, p: PackedInt32Array, reverse: bool) -> bool:
	var n := p.size()
	if n < 2: return false
	var o := p[n - 1] if reverse else p[0]
	var ox := o % w.W
	var oy := o / w.W
	var left := false
	var fresh := 0
	var touch := 0
	for k in n:
		var c := p[n - 1 - k] if reverse else p[k]
		var dx := c % w.W - ox
		var dy := c / w.W - oy
		if dx * dx + dy * dy > StageTrails.EXIT_R * StageTrails.EXIT_R: break
		if w.path_mask[c] >= 2:
			fresh = 0
			if left:
				touch += 1
				if touch > StageTrails.CROSS_RUN: return true
		else:
			touch = 0
			fresh += 1
			if fresh > StageTrails.JITTER_RUN: left = true
	return false


## Путь между поселениями без концов внутри кругов StageTrails.EXIT_R вокруг его первой и последней клетки (общие выезды)
static func _beyond_exits(w: WorldData, p: PackedInt32Array) -> PackedInt32Array:
	var n := p.size()
	if n < 2: return p
	var a := Vector2(p[0] % w.W, p[0] / w.W)
	var b := Vector2(p[-1] % w.W, p[-1] / w.W)
	var first := 0
	var last := n - 1
	while first < n - 1 and Vector2(p[first] % w.W, p[first] / w.W).distance_to(a) <= StageTrails.EXIT_R: first += 1
	while last > first and Vector2(p[last] % w.W, p[last] / w.W).distance_to(b) <= StageTrails.EXIT_R: last -= 1
	return p.slice(first, last + 1)


## Путь без начальных и конечных клеток готовой сети: та часть, которую он добавит (общий выезд не в счёт)
static func _core(w: WorldData, p: PackedInt32Array) -> PackedInt32Array:
	var first := 0
	var last := p.size() - 1
	while first < last and w.path_mask[p[first]] >= 2: first += 1
	while last > first and w.path_mask[p[last]] >= 2: last -= 1
	return p.slice(first, last + 1)


## Клетки ближе StageTrails.AVOID_R к путям avoid (квадрат вокруг каждой клетки пути)
static func _corridor(w: WorldData, avoid: Array) -> PackedByteArray:
	var W := w.W
	var near := PackedByteArray()
	near.resize(w.N)
	for path in avoid:
		for i in (path as PackedInt32Array):
			var cx := i % W
			var cy := i / W
			for y in range(maxi(0, cy - StageTrails.AVOID_R), mini(w.H, cy + StageTrails.AVOID_R + 1)):
				for x in range(maxi(0, cx - StageTrails.AVOID_R), mini(W, cx + StageTrails.AVOID_R + 1)):
					near[y * W + x] = 1
	return near
