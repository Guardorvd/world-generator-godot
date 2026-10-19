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
## мост через овраг, под которым озеро или море, не ставится: дорога огибает воду по берегу.
## Туннели и обходы горы чередуются: после туннеля следующий хребет путь по возможности обходит
## понизу (_detour), после обхода — снова туннель. Высоты здесь в единицах w.h (1 = 260 м).
## Путь, который пересекает воду или хребет там же, где уже построен мост или туннель (концы рядом,
## _same), проходит по нему: к его входу и от выхода — короткими путями по суше.
## Из поселения-тупика (с одной связью) идёт ответвление к ближайшему соседу другой стороной, по суше,
## а у части дорог есть второй путь в обход первого (_second_ways).

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
const PORTAL_LEN := 3.0     # у входа туннеля, ближе стольких клеток, прежний путь не пересекает выемку
const BRIDGE_R := 0.8       # клетки ближе этого к оси моста — дорога
const HUT_CLEAR := 1.5      # дом ближе этого к оси моста или туннеля убирается, клеток
const FORD_LEN := 2         # тропа переходит вброд реку не шире стольких клеток пути
const FORD_SLOPE := 0.3     # на более крутом перепаде русла глубина между клетками ненадёжна для брода
const DETOUR := 4.5         # обход горы не длиннее стольких прямых расстояний между входами туннеля
const ALT_EVERY := 3        # второй путь у каждой третьей дороги остовного дерева (от самой длинной)
const ALT_LEN := 2.0        # второй путь не длиннее стольких первых
const DEAD_LEN := 3.0       # ответвление из тупика не длиннее стольких прямых расстояний до соседа
const DEAD_TRIES := 3       # ответвление ищется к стольким ближайшим соседям по очереди
const SHORE_MIN := 15       # если соседи по суше недоступны — тропа к берегу моря не ближе стольких клеток
const SHORE_MAX := 45       # и не дальше стольких
const AVOID_R := 3          # коридор вокруг прежнего пути, клеток: второй путь его избегает
const AVOID_MUL := 8.0      # во столько раз дороже клетки коридора
const AVOID_SHARE := 0.4    # второй путь идёт по коридору не больше чем такой долей клеток
const LINE_IN := 0.1        # клетки под лентой (ширина w, как в MapBaker) глубже этого от её края — тоже дорога (path_mask), клеток
const LINE_STEP := 0.25     # шаг, с которым линия проверяется по клеткам (_mark_line), клеток
const REUSE_R := 5.0        # путь идёт по уже построенному мосту или туннелю, если оба его конца не дальше стольких клеток
const KEY_R := 1.5          # и проходит не дальше стольких клеток от того, что пересекает путь (_key_cell)
## Три характера езды без отдельных режимов: дорога, извилистый обход, техническая горная тропа.
const ROAD_CLIMB := 32.0
const TRAIL_CLIMB := 12.0
const MOUNTAIN_CLIMB := 4.0
const HEIGHT_SCALE := 65.0  # 260 м высоты / 4 м на клетку; единицы высоты и шага A* одинаковы


static func run(w: WorldData, step: Callable) -> void:
	_build_cost(w)
	w.path_mask = PackedByteArray()
	w.path_mask.resize(w.N)
	w.trails = []
	var heights := PackedFloat32Array()
	heights.resize(w.N)
	for i in w.N:
		# По воде ищется мост, поэтому учитывается уровень воды, а не морское дно.
		heights[i] = (0.0 if w.ocean[i] != 0 else (w.filled[i] if w.lake[i] != 0 else w.h[i])) * HEIGHT_SCALE
	var finder := Pathfinder.new(w.W, w.H, heights)
	_animal_trails(w, finder)
	step.call(0.66, "Прокладка троп между поселениями")
	_settlement_trails(w, finder)
	_mountain_trails(w, finder)


## Река у самого устья в озеро или море (с 2.9): там она глубже брода, путь обходит её выше по течению
static func _at_mouth(w: WorldData, x: int, y: int) -> bool:
	for dy in range(maxi(0, y - 1), mini(w.H, y + 2)):
		for dx in range(maxi(0, x - 1), mini(w.W, x + 2)):
			var c := dy * w.W + dx
			if w.ocean[c] != 0 or w.lake[c] != 0:
				return true
	return false


## Стоимость прохода клетки: биом, крутизна, немного шума, реки дороже (брод), устья и крутые русла непроходимы
static func _build_cost(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var cost := PackedFloat32Array()
	cost.resize(w.N)
	var cost_n := w.noise_field("cost")
	for y: int in H:
		for x: int in W:
			var i := y * W + x
			if w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0 and (_at_mouth(w, x, y) or w.slope[i] > FORD_SLOPE):
				cost[i] = INF
				continue
			var bc: float = Biomes.LIST[w.biome[i]].get("cost", 2.0)
			cost[i] = bc + w.slope[i] * 7.0 + (cost_n[i] * 0.5 + 0.5) * 0.9 + (12.0 if w.river[i] != 0 else 0.0)
	w.cost = cost


## Записать найденный путь как тропу
## (road_cost — стоимость для дорог, она дешевеет вместе с w.cost; on_axis — клетки на осях мостов и туннелей:
## там и на соседних с ними клетках пути точки линии не смещаются случайно, чтобы дорога входила
## на настил и в портал ровно, а не через перила; у воды линия тоже не смещается, чтобы не уйти в неё).
## path_mask (скорость, деревья) отмечается по нарисованной линии (_mark_line), а дешевле становятся клетки пути
static func _add_trail(w: WorldData, path: PackedInt32Array, kind: String, road_cost: PackedFloat32Array = PackedFloat32Array(),
		on_axis: PackedByteArray = PackedByteArray()) -> void:
	path = _explicit(w, path, on_axis)
	var W := w.W
	var H := w.H
	var rng := w.rng
	var width := 0.32 if kind == "animal" else (0.42 if kind == "mountain" else (0.9 if kind == "road" else 0.55))
	var jitter := 0.1 if kind == "road" else (0.35 if kind == "mountain" else 0.5)
	var pts: Array = []
	var last := path.size() - 1
	var spans: Array = w.bridges + w.tunnels
	for k: int in path.size():
		var i := path[k]
		var px := (i % W) + 0.5 + (rng.next_float() - 0.5) * jitter
		var py := (i / W) + 0.5 + (rng.next_float() - 0.5) * jitter
		if (on_axis.size() > 0 and (on_axis[i] != 0 or on_axis[path[maxi(k - 1, 0)]] != 0 or on_axis[path[mini(k + 1, last)]] != 0)) \
				or _by_water(w, i):
			px = (i % W) + 0.5
			py = (i / W) + 0.5
		if not on_axis.is_empty() and on_axis[i] != 0:
			# Центры клеток диагональной оси идут лесенкой. Лента должна лежать на прямом настиле.
			var best_dist := INF
			for span: Dictionary in spans:
				var ax: float = span.a % W + 0.5
				var ay: float = span.a / W + 0.5
				var dx: float = span.b % W - span.a % W
				var dy: float = span.b / W - span.a / W
				var t := clampf(((i % W + 0.5 - ax) * dx + (i / W + 0.5 - ay) * dy) / maxf(dx * dx + dy * dy, 1.0), 0.0, 1.0)
				var d := Grid.hypot(i % W + 0.5 - ax - dx * t, i / W + 0.5 - ay - dy * t)
				if d < best_dist:
					best_dist = d
					px = ax + dx * t
					py = ay + dy * t
		pts.append({x = px, y = py, w = width})
	var cost := w.cost
	var mask := w.path_mask
	var mark := 1 if kind == "animal" else (3 if kind == "road" else 2)
	var cheaper := 0.6 if kind == "animal" else 0.35
	var both := road_cost.size() > 0
	for i: int in path:
		if mask[i] < mark:
			mask[i] = mark
		# протоптанная тропа дешевле: следующие маршруты сливаются с ней
		cost[i] = maxf(0.3, cost[i] * cheaper)
		if both:
			road_cost[i] = maxf(0.3, road_cost[i] * cheaper)
		var cx := i % W
		var cy := i / W
		for k: int in 8:
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
	_protect_structures(w, road_cost)
	var line := Grid.chaikin(pts, 3)
	_mark_line(w, line, mark, width * 0.5 - LINE_IN)
	w.trails.append({kind = kind, pts = line})


## Следующие пути входят на сооружения с концов: боковые клетки у стен непроходимы,
## ось остаётся дешёвой. Под высокими мостами исходная стоимость прохода сохраняется.
static func _protect_structures(w: WorldData, road_cost: PackedFloat32Array) -> void:
	var cost := w.cost
	var both := not road_cost.is_empty()
	for span: Dictionary in w.tunnels + w.bridges:
		var tunnel := w.tunnels.has(span)
		var radius := TUNNEL_R if tunnel else 1.4
		var ax: float = span.a % w.W + 0.5
		var ay: float = span.a / w.W + 0.5
		var bx: float = span.b % w.W + 0.5
		var by: float = span.b / w.W + 0.5
		var dx := bx - ax
		var dy := by - ay
		var length_sq := dx * dx + dy * dy
		for y in range(maxi(0, floori(minf(ay, by) - radius)), mini(w.H, ceili(maxf(ay, by) + radius))):
			for x in range(maxi(0, floori(minf(ax, bx) - radius)), mini(w.W, ceili(maxf(ax, bx) + radius))):
				var along := (x + 0.5 - ax) * dx + (y + 0.5 - ay) * dy
				if along <= 0.0 or along >= length_sq or Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) > radius:
					continue
				var i := y * w.W + x
				# Высоты нормированы: запас 0.015 (около 4 м) учитывает арку настила.
				# Земля значительно ниже или выше моста остаётся доступной отдельно от него.
				var deck: float = w.h[span.a] + (w.h[span.b] - w.h[span.a]) * along / length_sq
				if not tunnel and absf(w.h[i] - deck) > 0.015:
					continue
				cost[i] = INF
				if both:
					road_cost[i] = INF
		for i: int in Grid.line_cells(span.a % w.W, span.a / w.W, span.b % w.W, span.b / w.W, w.W):
			cost[i] = 0.3
			if both:
				road_cost[i] = 0.3
	w.cost = cost


## Отметить в path_mask значением mark клетки, по которым проходит нарисованная линия pts: средняя линия
## и края ленты (half — полуширина ленты, в клетках). Так игра считает дорогой то, что видно дорогой:
## по ней быстрее, на ней не растут деревья
static func _mark_line(w: WorldData, pts: Array, mark: int, half: float) -> void:
	var W := w.W
	var H := w.H
	var mask := w.path_mask
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
		var m := ceili(seg_len / LINE_STEP)
		for s: int in range(1, m + 1):
			var f := float(s) / m
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
				_mark_cell(mask, W, H, x1 if floori(cy) == y0 else x0, y0 if floori(cy) == y0 else y1, mark)
			_mark_cell(mask, W, H, x0, y0, mark)
			_mark_cell(mask, W, H, x1, y1, mark)
			if sides:
				_mark_cell(mask, W, H, floori(x + nx), floori(y + ny), mark)
				_mark_cell(mask, W, H, floori(x - nx), floori(y - ny), mark)
			px = x
			py = y
	w.path_mask = mask


static func _mark_cell(mask: PackedByteArray, W: int, H: int, x: int, y: int, mark: int) -> void:
	if x >= 0 and y >= 0 and x < W and y < H and mask[y * W + x] < mark:
		mask[y * W + x] = mark


## Путь p, в котором каждый диагональный шаг между двумя сухими клетками, которые разделяет река (обе соседние
## по сторонам клетки мокрые), идёт через одну из этих клеток: так переход реки виден в клетках пути (мост, брод),
## а не проскакивает в угол. Готовые оси сооружений не меняются: вставка боковой клетки увела бы путь с настила.
static func _explicit(w: WorldData, p: PackedInt32Array, on_axis: PackedByteArray = PackedByteArray()) -> PackedInt32Array:
	var W := w.W
	var out := PackedInt32Array()
	for k: int in p.size():
		var b := p[k]
		if k > 0:
			var a := p[k - 1]
			var dx := b % W - a % W
			var dy := b / W - a / W
			if dx != 0 and dy != 0 and not _wet(w, a) and not _wet(w, b) \
					and not (not on_axis.is_empty() and on_axis[a] != 0 and on_axis[b] != 0):
				var c1 := a + dx
				var c2 := a + dy * W
				if _wet(w, c1) and _wet(w, c2):
					out.append(c1 if w.cost[c1] <= w.cost[c2] else c2)
		out.append(b)
	return out


## Есть ли вода (море, озеро, река) в клетке i или рядом с ней (w.dist_water считается по тем же клеткам, что _wet)
static func _by_water(w: WorldData, i: int) -> bool:
	return w.dist_water[i] < 1.5


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
		var p := finder.find_path(w.cost, s, best, TRAIL_CLIMB)
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
	for it: int in range(1, n):
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
	# detour — что пробовать на следующем хребте: обход (true) или туннель, с чего начать — по сиду;
	# on_axis — клетки на осях мостов и туннелей (_add_trail)
	var state := {detour = w.seed_num % 2 == 1, on_axis = PackedByteArray()}
	state.on_axis.resize(w.N)
	var ocean := w.ocean
	var lake := w.lake
	for i in w.N:
		if ocean[i] != 0 or lake[i] != 0 or w.river[i] != 0 and w.cost[i] == INF:
			road_cost[i] = BRIDGE_COST
	var paths: Array = []   # [a, b, путь, дорога ли, прямое расстояние] найденных связей
	for e in edges:
		# первые n - 1 связей — остовное дерево
		var road: bool = e[3] < n - 1
		var p := finder.find_path(road_cost if road else w.cost, st[e[0]].i, st[e[1]].i, ROAD_CLIMB if road else TRAIL_CLIMB)
		if p.size() > 0:
			var q := _structures(w, p, road, finder, road_cost if road else w.cost, state)
			_add_trail(w, q, "road" if road else "trail", road_cost, state.on_axis)
			paths.append([e[0], e[1], q, road, e[2]])
	_second_ways(w, finder, paths, road_cost, state)
	_clear_huts(w)


## Вторые пути. Поселение-тупик (одна связь) получает тропу к ближайшему соседу, с которым не связано;
## у каждой ALT_EVERY-й дороги остовного дерева (по длине, с самой длинной) появляется вторая дорога
## между теми же поселениями. Оба ищутся только по суше и в стороне от прежнего пути (_avoiding),
## поэтому петляют по другой местности; слишком длинный или почти совпадающий с прежним путь отбрасывается.
static func _second_ways(w: WorldData, finder: Pathfinder, paths: Array, road_cost: PackedFloat32Array, state: Dictionary) -> void:
	var st := w.settlements
	var n := st.size()
	var links: Array = []   # пути у каждого поселения
	links.resize(n)
	for a in n:
		links[a] = []
	var have := {}
	for e in paths:
		links[e[0]].append(e[2])
		links[e[1]].append(e[2])
		have[_key(e[0], e[1])] = true
	var ways: Array = []   # [a, соседи по удалённости, пути, которых избегать, дорога ли, предел длины на клетку расстояния]
	for a in n:
		if links[a].size() != 1:
			continue
		var near: Array = []
		for b in n:
			var d := Grid.hypot(st[a].x - st[b].x, st[a].y - st[b].y)
			if b != a and not have.has(_key(a, b)) and d < w.W * 0.45:
				near.append([b, d])
		near.sort_custom(func(p: Array, q: Array) -> bool: return p[1] < q[1] if p[1] != q[1] else p[0] < q[0])
		ways.append([a, near.slice(0, DEAD_TRIES), links[a], false, DEAD_LEN])
	var roads: Array = []
	for e in paths:
		if e[3]:
			roads.append(e)
	roads.sort_custom(func(p: Array, q: Array) -> bool: return p[4] > q[4] if p[4] != q[4] else p[0] < q[0])
	for k in range(0, roads.size(), ALT_EVERY):
		var e: Array = roads[k]
		ways.append([e[0], [[e[1], e[4]]], [e[2]], true, e[2].size() * ALT_LEN / e[4]])
	for v in ways:
		var a: int = v[0]
		var avoid: Array = v[2]
		var road: bool = v[3]
		var corr := _corridor(w, avoid)
		var c := _avoiding(w, corr)
		var found := false
		# к первому соседу, до которого нашёлся подходящий путь
		for nb in v[1]:
			var b: int = nb[0]
			if have.has(_key(a, b)) and not road:
				continue
			var p := finder.find_path(c, st[a].i, st[b].i, TRAIL_CLIMB)
			if p.size() == 0 or p.size() > nb[1] * v[4] or _share(p, corr) > AVOID_SHARE:
				continue
			have[_key(a, b)] = true
			_add_trail(w, _structures(w, p, road, finder, w.cost, state), "road" if road else "trail", road_cost, state.on_axis)
			found = true
			break
		if found or road:
			continue
		# до соседей по суше не дойти (обычно это остров): тропа к морю на другой стороне
		var t := _shore(w, st[a].i, corr)
		if t >= 0:
			var p := finder.find_path(c, st[a].i, t, TRAIL_CLIMB)
			var d := Grid.hypot(t % w.W - st[a].x, t / w.W - st[a].y)
			if p.size() > 0 and p.size() <= d * DEAD_LEN and _share(p, corr) <= AVOID_SHARE:
				_add_trail(w, _structures(w, p, false, finder, w.cost, state), "trail", road_cost, state.on_axis)


## Ближайшая к клетке s клетка морского берега на расстоянии от SHORE_MIN до SHORE_MAX клеток,
## не в коридоре near прежних путей; -1, если такой нет
static func _shore(w: WorldData, s: int, near: PackedByteArray) -> int:
	var W := w.W
	var sx := s % W
	var sy := s / W
	var best := -1
	var bd := INF
	for y in range(maxi(0, sy - SHORE_MAX), mini(w.H, sy + SHORE_MAX + 1)):
		for x in range(maxi(0, sx - SHORE_MAX), mini(W, sx + SHORE_MAX + 1)):
			var i := y * W + x
			var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
			if d < SHORE_MIN * SHORE_MIN or d >= bd or near[i] != 0 or w.cost[i] == INF or w.dist_ocean[i] > 1.5:
				continue
			bd = d
			best = i
	return best


## Стоимость по суше (w.cost), в которой клетки коридора near (_corridor) в AVOID_MUL раз дороже
static func _avoiding(w: WorldData, near: PackedByteArray) -> PackedFloat32Array:
	var c := w.cost.duplicate()
	for i: int in w.N:
		if near[i] != 0 and c[i] != INF:
			c[i] *= AVOID_MUL
	return c


## Клетки ближе AVOID_R к путям avoid (квадрат вокруг каждой клетки пути)
static func _corridor(w: WorldData, avoid: Array) -> PackedByteArray:
	var W := w.W
	var near := PackedByteArray()
	near.resize(w.N)
	for path in avoid:
		for i in (path as PackedInt32Array):
			var cx := i % W
			var cy := i / W
			for y in range(maxi(0, cy - AVOID_R), mini(w.H, cy + AVOID_R + 1)):
				for x in range(maxi(0, cx - AVOID_R), mini(W, cx + AVOID_R + 1)):
					near[y * W + x] = 1
	return near


## Доля клеток пути p в коридоре near (_corridor) прежних путей; 0, если путь пуст
static func _share(p: PackedInt32Array, near: PackedByteArray) -> float:
	if p.is_empty():
		return 0.0
	var k := 0
	for i: int in p:
		if near[i] != 0:
			k += 1
	return float(k) / p.size()


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
## Тропа (road = false) переходит реку не шире FORD_LEN вброд. Новый туннель через раз заменяется
## обходом горы, если он есть (state.detour — очередь обхода; cost — стоимость, по которой ищется обход).
## Клетки осей мостов и туннелей отмечаются в state.on_axis.
static func _structures(w: WorldData, p: PackedInt32Array, road: bool, finder: Pathfinder, cost: PackedFloat32Array, state: Dictionary) -> PackedInt32Array:
	p = _explicit(w, p)
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
			# Не ставим опору на низкой отмели между двумя рукавами прямого перехода.
			while j < n and (wet[j] != 0 or j + 1 < n and wet[j + 1] != 0 and hp[j] <= hp[i] + GRADE \
					and Grid.segment_dist(xs[j], ys[j], xs[i], ys[i], xs[j + 1], ys[j + 1]) < 0.1):
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
				# под горным озером, через реку в выемке, наперерез другому туннелю и поперёк прежней дороги у входа
				# туннель не прокладывается
				if j > 0 and _same(w, w.tunnels, p[i], p[j], _key_cell(p, hp, wet, i, j)).is_empty():
					if _near_tunnel(w, p[i], p[j]) or _wet_near(w, p[i], p[j], TUNNEL_R) or _path_at_portal(w, p[i], p[j]):
						j = -1
			elif j > 0:
				# над озером или заливом мост через овраг не ставится: путь идёт по берегу. С 3.0 и там, где
				# земля по прямой между концами выше обоих концов (два оврага с бугром между ними): настил ушёл бы в бугор
				var top := maxf(hp[i], hp[j])
				for c: int in Grid.line_cells(xs[i], ys[i], xs[j], ys[j], W):
					if w.ocean[c] != 0 or w.lake[c] != 0 or w.h[c] > top:
						j = -1
						break
		if j < 0:
			out.append(p[i + 1])
			i += 1
			continue
		var a := p[i]
		var b := p[j]
		var list: Array = w.tunnels if kind == "tunnel" else w.bridges
		var ends := _same(w, list, a, b, _key_cell(p, hp, wet, i, j))
		# к входу и от выхода уже построенного — по суше: если так не дойти, строится своё
		var to_a := PackedInt32Array()
		var from_b := PackedInt32Array()
		if not ends.is_empty():
			to_a = _link(w, finder, a, ends[0])
			from_b = _link(w, finder, ends[1], b)
			if _has_wet(w, to_a) or _has_wet(w, from_b):
				ends = []
				to_a = PackedInt32Array()
				from_b = PackedInt32Array()
		if kind == "tunnel" and ends.is_empty():
			if state.detour:
				var q := _detour(w, finder, cost, a, b)
				if q.size() > 0:
					state.detour = false
					for k in range(1, q.size()):
						out.append(q[k])
					i = j
					continue
			state.detour = true
		if ends.is_empty():
			list.append({a = a, b = b})
			_mark_cut(w, a, b, TUNNEL_R if kind == "tunnel" else BRIDGE_R)
			ends = [a, b]
		# дорога, слившаяся с прежней, проходит по уже построенному
		out.append_array(to_a)
		var line := Grid.line_cells(ends[0] % W, ends[0] / W, ends[1] % W, ends[1] / W, W)
		var dx: int = ends[1] % W - ends[0] % W
		var dy: int = ends[1] / W - ends[0] / W
		var length_sq := maxf(dx * dx + dy * dy, 1.0)
		for k in line.size():
			state.on_axis[line[k]] = 1
			# Следующие пути оценивают настил/пол, а не скрытое под сооружением дно или хребет.
			var along: float = (line[k] % W - ends[0] % W) * dx + (line[k] / W - ends[0] / W) * dy
			finder.heights[line[k]] = lerpf(w.h[ends[0]], w.h[ends[1]], along / length_sq) * HEIGHT_SCALE
			if k > 0:
				out.append(line[k])
		out.append_array(from_b)
		i = j
	return _no_backtrack(out)


## Путь p без возвратов на шаг назад (A, B, A -> A): они остаются, когда вход уже построенного моста
## или туннеля лежит позади точки, где путь к нему свернул
static func _no_backtrack(p: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for c: int in p:
		var n := out.size()
		if n >= 2 and out[n - 2] == c:
			out.resize(n - 1)
		else:
			out.append(c)
	return out


## Путь по суше от клетки a до клетки b (без a); если его нет или он длиннее REUSE_R * 3 — прямая
static func _link(w: WorldData, finder: Pathfinder, a: int, b: int) -> PackedInt32Array:
	if a == b:
		return PackedInt32Array()
	var q := finder.find_path(w.cost, a, b, TRAIL_CLIMB)
	if q.size() == 0 or q.size() > REUSE_R * 3.0:
		q = Grid.line_cells(a % w.W, a / w.W, b % w.W, b / w.W, w.W)
	return q.slice(1)


## Есть ли в клетках p вода (море, озеро, река)
static func _has_wet(w: WorldData, p: PackedInt32Array) -> bool:
	for c: int in p:
		if _wet(w, c):
			return true
	return false


## Клетка, которую пересекает участок пути p[i..j] под мостом или туннелем: середина воды, дно оврага
## или верх хребта. Уже построенное подходит этому участку, только если проходит над ней (_same)
static func _key_cell(p: PackedInt32Array, hp: PackedFloat32Array, wet: PackedByteArray, i: int, j: int) -> int:
	if wet[i + 1] != 0:
		return p[(i + j) / 2]
	var up := hp[i + 1] > hp[i]
	var best := i + 1
	for k in range(i + 1, j):
		if hp[k] > hp[best] if up else hp[k] < hp[best]:
			best = k
	return p[best]


## Обход горы от a до b вместо туннеля: путь в окрестности отрезка a–b, не выше входов больше чем
## на 0.7 RISE (около 18 м), без воды и не длиннее DETOUR прямых расстояний; пустой, если такого нет
static func _detour(w: WorldData, finder: Pathfinder, cost: PackedFloat32Array, a: int, b: int) -> PackedInt32Array:
	var W := w.W
	var ax := a % W
	var ay := a / W
	var bx := b % W
	var by := b / W
	var d := Grid.hypot(bx - ax, by - ay)
	var m := ceili(d * 2.0)   # обход ищется не дальше двух длин туннеля от входов
	var top := maxf(w.h[a], w.h[b]) + RISE * 0.7
	var c := PackedFloat32Array()
	c.resize(w.N)
	c.fill(INF)
	for y in range(maxi(0, mini(ay, by) - m), mini(w.H, maxi(ay, by) + m + 1)):
		for x in range(maxi(0, mini(ax, bx) - m), mini(W, maxi(ax, bx) + m + 1)):
			var k := y * W + x
			if w.h[k] <= top and not _wet(w, k):
				c[k] = cost[k]
	var q := finder.find_path(c, a, b, TRAIL_CLIMB)
	if q.size() > d * DETOUR:
		return PackedInt32Array()
	return q


## Проходит ли прежний путь (path_mask) поперёк выемки будущего туннеля a–b у его входов (с 3.0): выемка там
## почти до пола, и путь шёл бы сквозь стену у портала
static func _path_at_portal(w: WorldData, a: int, b: int) -> bool:
	var W := w.W
	var ax := a % W + 0.5
	var ay := a / W + 0.5
	var bx := b % W + 0.5
	var by := b / W + 0.5
	for y in range(maxi(0, floori(minf(ay, by) - TUNNEL_R)), mini(w.H, ceili(maxf(ay, by) + TUNNEL_R))):
		for x in range(maxi(0, floori(minf(ax, bx) - TUNNEL_R)), mini(W, ceili(maxf(ax, bx) + TUNNEL_R))):
			var da := Grid.hypot(x + 0.5 - ax, y + 0.5 - ay)
			var db := Grid.hypot(x + 0.5 - bx, y + 0.5 - by)
			if w.path_mask[y * W + x] >= 2 and minf(da, db) > 0.5 and minf(da, db) < PORTAL_LEN 					and Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) <= TUNNEL_R:
				return true
	return false


## Есть ли вода (море, озеро, река) в клетках ближе r к отрезку между центрами клеток a и b
## (у туннеля это его выемка: вода в ней стояла бы у портала и на полу)
static func _wet_near(w: WorldData, a: int, b: int, r: float) -> bool:
	var W := w.W
	var ax := a % W + 0.5
	var ay := a / W + 0.5
	var bx := b % W + 0.5
	var by := b / W + 0.5
	for y in range(maxi(0, floori(minf(ay, by) - r)), mini(w.H, ceili(maxf(ay, by) + r))):
		for x in range(maxi(0, floori(minf(ax, bx) - r)), mini(W, ceili(maxf(ax, bx) + r))):
			if Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) <= r and _wet(w, y * W + x):
				return true
	return false


## Только река (не море и не озеро), без крутого перепада русла: возможен брод p[from..to)
static func _river_only(w: WorldData, p: PackedInt32Array, from: int, to: int) -> bool:
	for k in range(from, to):
		if w.ocean[p[k]] != 0 or w.lake[p[k]] != 0 or w.slope[p[k]] > FORD_SLOPE:
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


## Уже построенный мост или туннель из list с концами у клеток a и b (каждый не дальше REUSE_R, в любом
## порядке) и осью над клеткой key, которую пересекает путь (_key_cell): [его конец у a, его конец у b] или
## пустой массив. Сооружение, которое лишь проходит рядом (например, мост через соседнюю петлю реки),
## не годится: путь по нему пересекал бы воду или гору не там, где построено
static func _same(w: WorldData, list: Array, a: int, b: int, key: int) -> Array:
	var W := w.W
	for s: Dictionary in list:
		if Grid.segment_dist(key % W + 0.5, key / W + 0.5, s.a % W + 0.5, s.a / W + 0.5, s.b % W + 0.5, s.b / W + 0.5) > KEY_R:
			continue
		for e in [[s.a, s.b], [s.b, s.a]]:
			var ea: int = e[0]
			var eb: int = e[1]
			if Grid.hypot(ea % W - a % W, ea / W - a / W) <= REUSE_R and Grid.hypot(eb % W - b % W, eb / W - b / W) <= REUSE_R:
				return e
	return []


## Проходит ли отрезок a–b ближе 2 * TUNNEL_R + 1 клеток к уже прорезанному туннелю или пересекает его
static func _near_tunnel(w: WorldData, a: int, b: int) -> bool:
	var W := w.W
	var ax: float = a % W
	var ay: float = a / W
	var bx: float = b % W
	var by: float = b / W
	for t: Dictionary in w.tunnels:
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
				mask[y * W + x] = 3   # дорога (как road в _add_trail)
	w.path_mask = mask


static func _key(a: int, b: int) -> String:
	return "%d:%d" % [a, b] if a < b else "%d:%d" % [b, a]


## Горные тропы к вершинам от ближайшего поселения
static func _mountain_trails(w: WorldData, finder: Pathfinder) -> void:
	var on_axis := PackedByteArray()
	on_axis.resize(w.N)
	for span: Dictionary in w.bridges + w.tunnels:
		for c: int in Grid.line_cells(span.a % w.W, span.a / w.W, span.b % w.W, span.b / w.W, w.W):
			on_axis[c] = 1
	# С 3.1 горная тропа обходит крутые участки реки: на перепаде русла такой «брод» глубже,
	# чем кажется по одной клетке. Это последний поиск путей, дороги уже проложены по мостам
	for i in w.N:
		if w.river[i] != 0 and w.slope[i] > FORD_SLOPE:
			w.cost[i] = INF
	for pk in w.peaks:
		var best = null
		var bd := INF
		for s in w.settlements:
			var d := Grid.hypot(s.x - pk.x, s.y - pk.y)
			if d < bd:
				bd = d
				best = s
		if best != null and bd < w.W * 0.4:
			var p := finder.find_path(w.cost, best.i, pk.i, MOUNTAIN_CLIMB)
			if p.size() > 0:
				_add_trail(w, p, "mountain", PackedFloat32Array(), on_axis)
