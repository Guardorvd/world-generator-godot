class_name StageTrails
extends RefCounted
## Этап 7. Естественные тропы и дороги: поиск пути A* по стоимости местности.
## Пишет: w.cost (стоимость прохода), w.path_mask (1 — звериная тропа, 2 — тропа людей, 3 — дорога),
## w.trails [{kind: "animal" | "trail" | "mountain" | "road", pts}], w.bridges, w.tunnels;
## убирает дома поселений, которые оказались на мосту или в туннеле.
##
## Дороги связывают все поселения (остовное дерево), поэтому ищутся по стоимости, в которой вода
## проходима, но дорога (BRIDGE_COST за клетку): так поселения на разных берегах тоже связаны.
## Где дорога или тропа между поселениями пересекает реку, озеро или овраг, ставится мост,
## где переваливает через крутой хребет — туннель. Тропа переходит узкую речку вброд, без моста;
## мост через овраг, под которым озеро или море, не ставится: дорога огибает воду по берегу. Высоты здесь в единицах w.h (1 = 260 м).

const PROGRESS := 0.55
const LABEL := "Прокладка звериных троп"

const BRIDGE_COST := 30.0   # стоимость клетки воды для дороги: дорога обходит воду, если обход не слишком длинный
const DIP := 0.03           # овраг глубже этого (около 8 м) под краями — мост
const DIP_LEN := 20         # самый длинный мост через овраг, клеток
const RISE := 0.1           # хребет выше этого (около 26 м) над входами — туннель
const RISE_LEN := 30        # самый длинный туннель, клеток
const SPAN := 60            # мост или туннель охватывает не больше стольких клеток пути
const GRADE := 0.0018       # наибольший уклон моста и туннеля на клетку (около 12 %)
const TUNNEL_R := 2.3       # клетки ближе этого к оси туннеля — его выемка (без деревьев)
const BRIDGE_R := 0.8       # клетки ближе этого к оси моста — дорога
const HUT_CLEAR := 1.5      # дом ближе этого к оси моста или туннеля убирается, клеток
const FORD_LEN := 2         # тропа переходит вброд реку не шире стольких клеток пути


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
	var cost_n := w.noise_field("cost")
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
## (road_cost — стоимость для дорог, она дешевеет вместе с w.cost)
static func _add_trail(w: WorldData, path: PackedInt32Array, kind: String, road_cost: PackedFloat32Array = PackedFloat32Array()) -> void:
	var W := w.W
	var H := w.H
	var rng := w.rng
	var width := 0.32 if kind == "animal" else (0.42 if kind == "mountain" else (0.9 if kind == "road" else 0.55))
	var pts: Array = []
	for i in path:
		var px := (i % W) + 0.5 + (rng.next_float() - 0.5) * 0.5
		var py := (i / W) + 0.5 + (rng.next_float() - 0.5) * 0.5
		pts.append({x = px, y = py, w = width})
	var cost := w.cost
	var mask := w.path_mask
	var mark := 1 if kind == "animal" else (3 if kind == "road" else 2)
	var cheaper := 0.6 if kind == "animal" else 0.35
	var both := road_cost.size() > 0
	for i in path:
		if mask[i] < mark:
			mask[i] = mark
		# протоптанная тропа дешевле: следующие маршруты сливаются с ней
		cost[i] = maxf(0.3, cost[i] * cheaper)
		if both:
			road_cost[i] = maxf(0.3, road_cost[i] * cheaper)
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
			if both:
				road_cost[n] = maxf(0.5, road_cost[n] * 0.9)
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


## Пути людей: остовное дерево между поселениями (дороги, через воду — по мостам)
## и несколько дополнительных связей (тропы, только по суше)
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
	w.bridges = []
	w.tunnels = []
	var road_cost := w.cost.duplicate()
	var ocean := w.ocean
	var lake := w.lake
	for i in w.N:
		if ocean[i] != 0 or lake[i] != 0:
			road_cost[i] = BRIDGE_COST
	for e in edges:
		# первые n - 1 связей — остовное дерево
		var road: bool = e[3] < n - 1
		var p := finder.find_path(st[e[0]].i, st[e[1]].i, road_cost if road else PackedFloat32Array())
		if p.size() > 0:
			_add_trail(w, _structures(w, p, road), "road" if road else "trail", road_cost)
	_clear_huts(w)


## Дома, которые стоят на мосту, в туннеле или вплотную к ним, убираются: иначе в них упрётся дорога
static func _clear_huts(w: WorldData) -> void:
	var W := w.W
	var spans: Array = w.bridges + w.tunnels
	for st in w.settlements:
		var keep: Array = []
		for u in st.huts:
			var free := true
			for sp in spans:
				if Grid.segment_dist(u.x, u.y, sp.a % W + 0.5, sp.a / W + 0.5, sp.b % W + 0.5, sp.b / W + 0.5) < HUT_CLEAR:
					free = false
					break
			if free:
				keep.append(u)
		st.huts = keep


## Мокрая клетка: море, озеро или река
static func _wet(w: WorldData, i: int) -> bool:
	return w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0


## Мосты и туннели на пути между поселениями: заносит их в w.bridges и w.tunnels и возвращает путь,
## в котором участки под ними заменены прямыми. Мост — через воду (от берега до берега) или через овраг
## глубже DIP; туннель — сквозь хребет выше RISE. У обоих уклон не круче GRADE.
## Тропа (road = false) переходит реку не шире FORD_LEN вброд.
static func _structures(w: WorldData, p: PackedInt32Array, road: bool) -> PackedInt32Array:
	var W := w.W
	var n := p.size()
	# высоты, мокрые клетки и координаты вдоль пути в плоских массивах: в цикле так быстрее
	var hp := PackedFloat32Array()
	var wet := PackedByteArray()
	var xs := PackedInt32Array()
	var ys := PackedInt32Array()
	hp.resize(n)
	wet.resize(n)
	xs.resize(n)
	ys.resize(n)
	for k in n:
		var c := p[k]
		hp[k] = w.h[c]
		wet[k] = 1 if _wet(w, c) else 0
		xs[k] = c % W
		ys[k] = c / W
	# наибольшая и наименьшая высота на SPAN клеток пути вперёд: где до хребта или оврага далеко,
	# конец моста или туннеля не ищется
	var ahead_max := _window(hp, SPAN, true)
	var ahead_min := _window(hp, SPAN, false)
	var out := PackedInt32Array([p[0]])
	var i := 0
	while i < n - 1:
		var j := -1
		var kind := "bridge"
		if wet[i + 1] != 0:
			j = i + 1
			while j < n and wet[j] != 0:
				j += 1
			if j >= n or not road and j - i - 1 <= FORD_LEN and _river_only(w, p, i + 1, j):
				j = -1
		elif hp[i + 1] > hp[i] and ahead_max[i] >= hp[i] + RISE or hp[i + 1] < hp[i] and ahead_min[i] <= hp[i] - DIP:
			var up := hp[i + 1] > hp[i]
			j = _span_end(hp, wet, xs, ys, i, up)
			# вход как можно ближе к хребту или оврагу
			while j > 0 and i + 1 < j - 2 and _span_end(hp, wet, xs, ys, i + 1, up) == j:
				out.append(p[i + 1])
				i += 1
			if up:
				kind = "tunnel"
				# под горным озером и наперерез другому туннелю туннель не прокладывается
				if j > 0 and not _built(w, w.tunnels, p[i], p[j]):
					if _near_tunnel(w, p[i], p[j]):
						j = -1
					else:
						for c in Grid.line_cells(xs[i], ys[i], xs[j], ys[j], W):
							if _wet(w, c):
								j = -1
								break
			elif j > 0:
				# над озером или заливом мост через овраг не ставится: путь идёт по берегу
				for c in Grid.line_cells(xs[i], ys[i], xs[j], ys[j], W):
					if w.ocean[c] != 0 or w.lake[c] != 0:
						j = -1
						break
		if j < 0:
			out.append(p[i + 1])
			i += 1
			continue
		var a := p[i]
		var b := p[j]
		var list: Array = w.tunnels if kind == "tunnel" else w.bridges
		# дорога, слившаяся с прежней, проходит по уже построенному
		if not _built(w, list, a, b):
			list.append({a = a, b = b})
			_mark_cut(w, a, b, TUNNEL_R if kind == "tunnel" else BRIDGE_R)
		var line := Grid.line_cells(xs[i], ys[i], xs[j], ys[j], W)
		for k in range(1, line.size()):
			out.append(line[k])
		i = j
	return out


## Только река (не море и не озеро) в клетках пути p[from..to)
static func _river_only(w: WorldData, p: PackedInt32Array, from: int, to: int) -> bool:
	for k in range(from, to):
		if w.ocean[p[k]] != 0 or w.lake[p[k]] != 0:
			return false
	return true


## Наибольшее (big) или наименьшее значение v[i..i+span] для каждого i (очередь с монотонными значениями)
static func _window(v: PackedFloat32Array, span: int, big: bool) -> PackedFloat32Array:
	var n := v.size()
	var out := PackedFloat32Array()
	out.resize(n)
	var q := PackedInt32Array()
	q.resize(n)
	var head := 0
	var tail := 0
	for i in range(n - 1, -1, -1):
		while tail > head and (v[q[tail - 1]] <= v[i] if big else v[q[tail - 1]] >= v[i]):
			tail -= 1
		q[tail] = i
		tail += 1
		while q[head] > i + span:
			head += 1
		out[i] = v[q[head]]
	return out


## Есть ли уже мост или туннель, вдоль которого идёт отрезок a–b (оба конца не дальше трёх клеток от него)
static func _built(w: WorldData, list: Array, a: int, b: int) -> bool:
	var W := w.W
	for s in list:
		var sx: float = s.a % W
		var sy: float = s.a / W
		var ex: float = s.b % W
		var ey: float = s.b / W
		if Grid.segment_dist(a % W, a / W, sx, sy, ex, ey) <= 3.0 and Grid.segment_dist(b % W, b / W, sx, sy, ex, ey) <= 3.0:
			return true
	return false


## Проходит ли отрезок a–b ближе 2 * TUNNEL_R + 1 клеток к уже прорезанному туннелю
static func _near_tunnel(w: WorldData, a: int, b: int) -> bool:
	var W := w.W
	var ax: float = a % W
	var ay: float = a / W
	var bx: float = b % W
	var by: float = b / W
	for t in w.tunnels:
		var cx: float = t.a % W
		var cy: float = t.a / W
		var dx: float = t.b % W
		var dy: float = t.b / W
		# отрезки пересекаются, если концы каждого лежат по разные стороны от другого
		var s1 := (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
		var s2 := (bx - ax) * (dy - ay) - (by - ay) * (dx - ax)
		var s3 := (dx - cx) * (ay - cy) - (dy - cy) * (ax - cx)
		var s4 := (dx - cx) * (by - cy) - (dy - cy) * (bx - cx)
		if s1 * s2 < 0.0 and s3 * s4 < 0.0:
			return true
		var d := minf(minf(Grid.segment_dist(ax, ay, cx, cy, dx, dy), Grid.segment_dist(bx, by, cx, cy, dx, dy)),
			minf(Grid.segment_dist(cx, cy, ax, ay, bx, by), Grid.segment_dist(dx, dy, ax, ay, bx, by)))
		if d < TUNNEL_R * 2.0 + 1.0:
			return true
	return false


## Конец моста через овраг (up = false) или туннеля (up = true), который начинается в p[i]:
## первая клетка, после которой путь уже перевалил через хребет или овраг, или -1
static func _span_end(hp: PackedFloat32Array, wet: PackedByteArray, xs: PackedInt32Array, ys: PackedInt32Array, i: int, up: bool) -> int:
	var ha := hp[i]
	var ax := xs[i]
	var ay := ys[i]
	var lim := RISE_LEN if up else DIP_LEN
	var lim2 := lim * lim
	var top := -INF
	var bottom := INF
	for j in range(i + 1, mini(hp.size(), i + SPAN + 1)):
		if wet[j] != 0:
			return -1
		var hb := hp[j]
		var dx := xs[j] - ax
		var dy := ys[j] - ay
		var d2 := dx * dx + dy * dy
		if d2 > lim2:
			return -1
		if j >= i + 3 and (hb - ha) * (hb - ha) <= GRADE * GRADE * d2:
			if up and top - maxf(ha, hb) >= RISE:
				return j
			if not up and minf(ha, hb) - bottom >= DIP:
				return j
		top = maxf(top, hb)
		bottom = minf(bottom, hb)
	return -1


## Клетки у оси моста или туннеля (ближе r) — дорога: по ней идут быстро, деревья в выемке туннеля не растут
static func _mark_cut(w: WorldData, a: int, b: int, r: float) -> void:
	var W := w.W
	var mask := w.path_mask
	var ax := a % W + 0.5
	var ay := a / W + 0.5
	var bx := b % W + 0.5
	var by := b / W + 0.5
	for y in range(maxi(0, floori(minf(ay, by) - r)), mini(w.H, ceili(maxf(ay, by) + r))):
		for x in range(maxi(0, floori(minf(ax, bx) - r)), mini(W, ceili(maxf(ax, bx) + r))):
			if Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) <= r:
				mask[y * W + x] = 3
	w.path_mask = mask


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
