class_name StageTrails
extends RefCounted
## Этап 7. Естественные тропы: поиск пути A* по стоимости местности.
## Пишет: w.cost (стоимость прохода), w.path_mask (1 — звериная тропа, 2 — тропа людей),
## w.trails [{kind: "animal" | "trail" | "mountain", pts}].

const PROGRESS := 0.55
const LABEL := "Прокладка звериных троп"


static func run(w: WorldData, step: Callable) -> void:
	_build_cost(w)
	w.path_mask = PackedByteArray()
	w.path_mask.resize(w.N)
	w.trails = []
	var finder := Pathfinder.new(w)
	_animal_trails(w, finder)
	step.call(0.66, "Прокладка троп между поселениями")
	_settlement_trails(w, finder)
	_mountain_trails(w, finder)


## Стоимость прохода клетки: биом, крутизна, немного шума, реки дороже (брод)
static func _build_cost(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var cost := PackedFloat32Array()
	cost.resize(w.N)
	var cost_n := Parallel.fbm_field(w, w.noise.cost, 14.0, 2)
	for y in H:
		for x in W:
			var i := y * W + x
			if w.ocean[i] != 0 or w.lake[i] != 0:
				cost[i] = INF
				continue
			var bc: float = Biomes.LIST[w.biome[i]].get("cost", 2.0)
			cost[i] = bc + w.slope[i] * 7.0 + (cost_n[i] * 0.5 + 0.5) * 0.9 + (12.0 if w.river[i] != 0 else 0.0)
	w.cost = cost


## Записать найденный путь как тропу
static func _add_trail(w: WorldData, path: PackedInt32Array, kind: String) -> void:
	var W := w.W
	var H := w.H
	var rng := w.rng
	var width := 0.32 if kind == "animal" else (0.42 if kind == "mountain" else 0.55)
	var pts: Array = []
	for i in path:
		var px := (i % W) + 0.5 + (rng.next_float() - 0.5) * 0.5
		var py := (i / W) + 0.5 + (rng.next_float() - 0.5) * 0.5
		pts.append({x = px, y = py, w = width})
	var cost := w.cost
	var mask := w.path_mask
	var mark := 1 if kind == "animal" else 2
	var cheaper := 0.6 if kind == "animal" else 0.35
	for i in path:
		if mask[i] < mark:
			mask[i] = mark
		# протоптанная тропа дешевле: следующие маршруты сливаются с ней
		cost[i] = maxf(0.3, cost[i] * cheaper)
		var cx := i % W
		var cy := i / W
		for k in 8:
			var nx: int = cx + Grid.DX[k]
			var ny: int = cy + Grid.DY[k]
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var n := ny * W + nx
			if cost[n] != INF:
				cost[n] = maxf(0.5, cost[n] * 0.9)
	w.cost = cost
	w.path_mask = mask
	w.trails.append({kind = kind, pts = Grid.chaikin(pts, 3)})


## Звериные тропы: от лесов и лугов к ближайшему водопою
static func _animal_trails(w: WorldData, finder: Pathfinder) -> void:
	var W := w.W
	var H := w.H
	var rng := w.rng
	var dist_water := w.dist_water
	var count := clampi(roundi(30.0 * w.scale), 8, 70)
	var k := 0
	var tries := 0
	while k < count and tries < count * 40:
		tries += 1
		var sx := 4 + floori(rng.next_float() * (W - 8))
		var sy := 4 + floori(rng.next_float() * (H - 8))
		var s := sy * W + sx
		if not Biomes.LIST[w.biome[s]].get("animals", false) or dist_water[s] < 8.0 or dist_water[s] > 35.0:
			continue
		var cost := w.cost
		var best := -1
		var bd := INF
		var R := 40
		for y in range(maxi(0, sy - R), mini(H, sy + R)):
			for x in range(maxi(0, sx - R), mini(W, sx + R)):
				var i := y * W + x
				if cost[i] == INF or dist_water[i] > 1.5:
					continue
				var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
				if d < bd:
					bd = d
					best = i
		if best < 0:
			continue
		var p := finder.find_path(s, best)
		if p.size() > 6:
			_add_trail(w, p, "animal")
			k += 1


## Тропы людей: остовное дерево между поселениями + несколько дополнительных связей
static func _settlement_trails(w: WorldData, finder: Pathfinder) -> void:
	var W := w.W
	var st := w.settlements
	var n := st.size()
	var edges: Array = []   # [a, b, d, порядок добавления]
	var in_tree: Array[bool] = []
	in_tree.resize(n)
	in_tree.fill(false)
	if n > 0:
		in_tree[0] = true
	for it in range(1, n):
		var best: Array = []
		for a in n:
			if not in_tree[a]:
				continue
			for b in n:
				if in_tree[b]:
					continue
				var d := Grid.hypot(st[a].x - st[b].x, st[a].y - st[b].y)
				if best.is_empty() or d < best[2]:
					best = [a, b, d]
		in_tree[best[1]] = true
		best.append(edges.size())
		edges.append(best)
	var have := {}
	for e in edges:
		have[_key(e[0], e[1])] = true
	for a in n:
		var near: Array = []
		for b in n:
			if b != a:
				near.append([b, Grid.hypot(st[a].x - st[b].x, st[a].y - st[b].y)])
		near.sort_custom(func(p: Array, q: Array) -> bool: return p[1] < q[1] if p[1] != q[1] else p[0] < q[0])
		for e in near.slice(0, 2):
			var b: int = e[0]
			var d: float = e[1]
			if not have.has(_key(a, b)) and d < W * 0.45:
				have[_key(a, b)] = true
				edges.append([a, b, d, edges.size()])
	edges.sort_custom(func(p: Array, q: Array) -> bool: return p[2] < q[2] if p[2] != q[2] else p[3] < q[3])
	for e in edges:
		var p := finder.find_path(st[e[0]].i, st[e[1]].i)
		if p.size() > 0:
			_add_trail(w, p, "trail")


static func _key(a: int, b: int) -> String:
	return "%d:%d" % [a, b] if a < b else "%d:%d" % [b, a]


## Горные тропы к вершинам от ближайшего поселения
static func _mountain_trails(w: WorldData, finder: Pathfinder) -> void:
	for pk in w.peaks:
		var best = null
		var bd := INF
		for s in w.settlements:
			var d := Grid.hypot(s.x - pk.x, s.y - pk.y)
			if d < bd:
				bd = d
				best = s
		if best != null and bd < w.W * 0.4:
			var p := finder.find_path(best.i, pk.i)
			if p.size() > 0:
				_add_trail(w, p, "mountain")
