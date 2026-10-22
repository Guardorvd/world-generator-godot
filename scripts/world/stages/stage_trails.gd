class_name StageTrails
extends RefCounted
## Этап 7. Естественные тропы и дороги: поиск пути A* по стоимости местности.
## Пишет: w.cost (стоимость прохода), w.path_mask (1 — звериная тропа, 2 — тропа людей, 3 — дорога),
## w.trails [{kind: "animal" | "trail" | "mountain" | "road", pts}], w.bridges, w.tunnels;
## убирает дома поселений, которые оказались на мосту или в туннеле.
##
## Дороги связывают все поселения (остовное дерево), поэтому ищутся по стоимости, в которой вода
## проходима, но дорога (BRIDGE_COST за клетку): так поселения на разных берегах тоже связаны.
## Где дорога или тропа между поселениями пересекает воду, ставится мост,
## где переваливает через крутой хребет — туннель. Тропа переходит узкую речку вброд, без моста;
## сухие впадины дорога проходит по рельефу, без декоративных мостов.
## Туннели и обходы горы чередуются: после туннеля следующий хребет путь по возможности обходит
## понизу (_detour), после обхода — снова туннель. Высоты здесь в единицах w.h (1 = 260 м).
## Путь, который пересекает воду или хребет там же, где уже построен мост или туннель (концы рядом,
## _same), проходит по нему: к его входу и от выхода — короткими путями по суше.
## Дополнительные тропы сокращают обход по сети или предлагают другой проход по рельефу;
## ответвления ведут к берегам и вершинам, без заданного количества связей (_second_ways).

const PROGRESS := 0.55
const LABEL := "Прокладка звериных троп"

const BRIDGE_COST := 30.0   # стоимость клетки воды для дороги: дорога обходит воду, если обход не слишком длинный
const RISE := 0.1           # хребет выше этого (около 26 м) над входами — туннель
const RISE_LEN := 30        # самый длинный туннель, клеток
const SPAN := 60            # мост или туннель охватывает не больше стольких клеток пути
const GRADE := 0.0018       # наибольший уклон моста и туннеля на клетку (около 12 %)
const BRIDGE_LANDING_GAP := 0.25 # въезд проверяется по всей ширине настила, м
const TUNNEL_R := 2.3       # клетки ближе этого к оси туннеля — его выемка (без деревьев)
const BRIDGE_R := 0.8       # клетки ближе этого к оси моста — дорога
const HUT_CLEAR := 1.5      # дом ближе этого к оси моста или туннеля убирается, клеток
const FORD_LEN := 2         # тропа переходит вброд реку не шире стольких клеток пути
const FORD_SLOPE := 0.3     # на более крутом перепаде русла глубина между клетками ненадёжна для брода
const DETOUR := 4.5         # обход горы не длиннее стольких прямых расстояний между входами туннеля
const ALT_LEN := 2.0        # второй путь не длиннее стольких первых
const BRANCH_LEN := 3.0     # тропа к берегу не длиннее стольких прямых расстояний
const SHORTCUT := 1.25      # новая связь сокращает существующий обход хотя бы на пятую часть
const RELIEF_CHOICE := 0.02 # другой проход отличается высотой примерно на 5 м (единицы w.h)
const SHORE_MIN := 15       # береговой ориентир не ближе стольких клеток от поселения
const SHORE_MAX := 45       # и не дальше стольких
const AVOID_R := 3          # коридор вокруг прежнего пути, клеток: второй путь его избегает
const AVOID_MUL := 8.0      # во столько раз дороже клетки коридора
const AVOID_SHARE := 0.4    # второй путь идёт по коридору не больше чем такой долей клеток
const REUSE_R := 5.0        # путь идёт по уже построенному мосту или туннелю, если оба его конца не дальше стольких клеток
const KEY_R := 1.5          # и проходит не дальше стольких клеток от того, что пересекает путь (_key_cell)
## Три характера езды без отдельных режимов: дорога, извилистый обход, техническая горная тропа.
const WIDTHS := {animal = 0.32, mountain = 0.42, trail = 0.55, road = 0.9}
const ROAD_CLIMB := 32.0
const TRAIL_CLIMB := 12.0
const MOUNTAIN_CLIMB := 4.0
const HEIGHT_SCALE := 65.0  # 260 м высоты / 4 м на клетку; единицы высоты и шага A* одинаковы
## Основная сеть сначала ищет удобный проход; у дополнительных и горных троп свои пределы.
## В пределах своего класса крутизна дополнительно оплачивается штрафом climb.
const ROAD_GRADE := 0.22 # удобный проход основной сети
const ROAD_LIMIT := 0.28 # короткий запасной подъём; дальше нужен обход
const TRAIL_GRADE := 0.4
const MOUNTAIN_GRADE := 0.55
const BENCH_CROSS := 0.65 # полка не должна превращаться в стену у поворота или берега


static func run(w: WorldData, step: Callable) -> void:
	var started_us := Time.get_ticks_usec()
	_build_cost(w)
	w.path_mask = PackedByteArray()
	w.path_mask.resize(w.N)
	w.trails = []
	var surface := Heightfield.new(w, false)
	var heights := PackedFloat32Array()
	heights.resize(w.N)
	for i in w.N:
		# По воде ищется мост, поэтому учитывается уровень воды, а не морское дно.
		heights[i] = (0.0 if w.ocean[i] != 0 else (w.filled[i] * HEIGHT_SCALE if w.lake[i] != 0 else surface.hv[i] / GameConfig.TILE))
	var finder := Pathfinder.new(w.W, w.H, heights)
	_animal_trails(w, finder)
	_route_surface(finder, surface, WIDTHS.road)
	step.call(0.66, "Прокладка троп между поселениями")
	_settlement_trails(w, finder, surface, step)
	_route_surface(finder, surface, WIDTHS.mountain)
	step.call(0.74, "Прокладка горных троп")
	_mountain_trails(w, finder, surface)
	if Pathfinder.profile_searches:
		w.generation_profile.merge(finder.search_stats())
		w.generation_profile.stage_ms = (Time.get_ticks_usec() - started_us) / 1000.0


## Поиск видит тот же прорезанный рельеф, что и полотно. Ширина в клетках, высоты / TILE.
static func _route_surface(finder: Pathfinder, surface: Heightfield, width: float) -> void:
	finder.max_cross_grade = BENCH_CROSS
	var ground := surface.hv.duplicate()
	var water := surface.water_level.duplicate()
	var wet := PackedByteArray()
	wet.resize(surface.world.N)
	for i in surface.world.N:
		ground[i] /= GameConfig.TILE
		# Запас между выборками: край сухой дороги не должен становиться бродом.
		water[i] = (maxf(0.0, water[i]) - 0.1) / GameConfig.TILE
		wet[i] = 1 if _wet(surface.world, i) else 0
	finder.set_corridor(ground, water, wet, width * 0.5)


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
	var river := w.river_cells()
	for y: int in H:
		for x: int in W:
			var i := y * W + x
			if w.ocean[i] != 0 or w.lake[i] != 0 or river[i] != 0 and (_at_mouth(w, x, y) or w.slope[i] > FORD_SLOPE):
				cost[i] = INF
				continue
			var bc: float = Biomes.LIST[w.biome[i]].get("cost", 2.0)
			cost[i] = bc + w.slope[i] * 7.0 + (cost_n[i] * 0.5 + 0.5) * 0.9 + (12.0 if river[i] != 0 else 0.0)
	w.cost = cost


## Записать найденный путь как тропу
## (road_cost — стоимость для дорог, она дешевеет вместе с w.cost; on_axis — клетки на осях мостов и туннелей:
## там и на соседних с ними клетках пути точки линии не смещаются случайно, чтобы дорога входила
## на настил и в портал ровно, а не через перила; у воды линия тоже не смещается, чтобы не уйти в неё).
## path_mask (скорость, деревья) отмечается по нарисованной линии (Grid.stamp_path), а дешевле становятся клетки пути
static func _add_trail(w: WorldData, path: PackedInt32Array, kind: String, road_cost: PackedFloat32Array = PackedFloat32Array(),
		on_axis: PackedByteArray = PackedByteArray(), surface: Heightfield = null) -> void:
	path = _explicit(w, path, on_axis)
	var W := w.W
	var H := w.H
	var jitter_seed := WGRandom.derive(w.seed_num, "trail.jitter." + kind)
	var rng := WGRandom.new(0)
	var width: float = WIDTHS[kind]
	var jitter := 0.1 if kind == "road" else (0.35 if kind == "mountain" else 0.5)
	var pts: Array = []
	var last := path.size() - 1
	var spans: Array = w.bridges + w.tunnels
	for k: int in path.size():
		var i := path[k]
		rng.reset(WGRandom.hash_cell(jitter_seed, i % W, i / W, 0))
		var px := (i % W) + 0.5 + (rng.next_float() - 0.5) * jitter
		var py := (i / W) + 0.5 + (rng.next_float() - 0.5) * jitter
		if kind != "animal":
			# Случайное смещение поперёк склона меняет реальный уклон выбранного прохода.
			px = (i % W) + 0.5
			py = (i / W) + 0.5
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
			# соседние клетки дешевеют, но не дорожают: уже дешёвый путь (0,3) не поднимается до 0,5 (с 6.9)
			if cost[n] != INF:
				cost[n] = minf(cost[n], maxf(0.5, cost[n] * 0.9))
			if both and road_cost[n] != INF:
				road_cost[n] = minf(road_cost[n], maxf(0.5, road_cost[n] * 0.9))
	w.cost = cost
	_protect_structures(w, road_cost)
	var line := _road_line(w, pts, on_axis, surface, kind) if kind != "animal" and surface != null else Grid.chaikin(pts, 3)
	Grid.stamp_path(w.path_mask, w.W, w.H, line, mark, width * 0.5 - Grid.PATH_IN)
	w.trails.append({kind = kind, pts = line})


## Скругляем только безопасные углы. У сооружений сохраняем точный вход на ось;
## на суше проверяем высоты игрового меша и воду по середине и краям будущей ленты.
static func _road_line(w: WorldData, pts: Array, on_axis: PackedByteArray, surface: Heightfield, kind := "road") -> Array:
	var grade := MOUNTAIN_GRADE if kind == "mountain" else (TRAIL_GRADE if kind == "trail" else ROAD_LIMIT)
	var cross_grade := MOUNTAIN_GRADE if kind == "mountain" else BENCH_CROSS
	for iteration in 3:
		var out: Array = [pts[0]]
		for k in range(1, pts.size() - 1):
			var a: Dictionary = pts[k - 1]
			var b: Dictionary = pts[k]
			var c: Dictionary = pts[k + 1]
			var fixed := false
			for p: Dictionary in [a, b, c]:
				var i := clampi(int(p.y), 0, w.H - 1) * w.W + clampi(int(p.x), 0, w.W - 1)
				fixed = fixed or not on_axis.is_empty() and on_axis[i] != 0
			var q := {x = lerpf(b.x, a.x, 0.25), y = lerpf(b.y, a.y, 0.25), w = b.w}
			var r := {x = lerpf(b.x, c.x, 0.25), y = lerpf(b.y, c.y, 0.25), w = b.w}
			if not fixed and _road_segment(surface, out[-1], q, grade, cross_grade) and _road_segment(surface, q, r, grade, cross_grade) and _road_segment(surface, r, c, grade, cross_grade):
				out.append(q)
				out.append(r)
			else:
				out.append(b)
		out.append(pts[-1])
		pts = out
	return pts


static func _road_segment(surface: Heightfield, a: Dictionary, b: Dictionary, max_grade := ROAD_LIMIT, max_cross := BENCH_CROSS) -> bool:
	var dx: float = b.x - a.x
	var dy: float = b.y - a.y
	var length := Grid.hypot(dx, dy)
	if length < 0.00001:
		return true
	var steps := maxi(1, ceili(length / 0.1))
	var nx := -dy / length * float(a.w) * 0.5
	var ny := dx / length * float(a.w) * 0.5
	for side in [-1.0, 0.0, 1.0]:
		var previous := 0.0
		for k in steps + 1:
			var t := float(k) / steps
			var x: float = (a.x + dx * t + nx * side) * GameConfig.TILE
			var z: float = (a.y + dy * t + ny * side) * GameConfig.TILE
			var h := surface.ground_at(x, z)
			if surface.depth_at(x, z) > 0.3 or k > 0 and absf(h - previous) > max_grade * length * GameConfig.TILE / steps + 0.00001:
				return false
			previous = h
	# Поперёк стены ось может быть горизонтальной. Не срезаем туда безопасный поворот.
	for k in steps + 1:
		var t := float(k) / steps
		var x: float = (a.x + dx * t) * GameConfig.TILE
		var z: float = (a.y + dy * t) * GameConfig.TILE
		var across := absf(surface.ground_at(x + nx * GameConfig.TILE, z + ny * GameConfig.TILE) - surface.ground_at(x - nx * GameConfig.TILE, z - ny * GameConfig.TILE))
		if across > max_cross * float(a.w) * GameConfig.TILE + 0.00001:
			return false
	return true


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
	var rng := WGRandom.at(w.seed_num, "trail.animal.sources")
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
		var R := 40
		var fast: Object = finder.fast()
		if fast != null:
			best = fast.FindNearestWater(cost, dist_water, W, H, sx, sy, R)
		else:
			var bd := INF
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


## Сеть растёт только через уже построенные безопасные дороги. Недоступный кандидат
## не требует связи любой ценой: не больше трёх соседей и 2*N раскрытий A* суммарно.
## Так последний остров или закрытый склон не запускает квадратичный перебор всех пар.
const SETTLEMENT_NEIGHBORS := 3
const BRIDGE_RETRIES := 2

static func _settlement_trails(w: WorldData, finder: Pathfinder, surface: Heightfield, step: Callable = Callable()) -> void:
	var started := Time.get_ticks_msec()
	var st := w.settlements
	var n := st.size()
	w.bridges = []
	w.tunnels = []
	var road_cost := w.cost.duplicate()
	var state := {detour = w.seed_num % 2 == 1, on_axis = PackedByteArray(), surface = surface}
	state.on_axis.resize(w.N)
	finder.links.resize(w.N)
	for i in w.N:
		if _wet(w, i) and w.cost[i] == INF:
			road_cost[i] = BRIDGE_COST
	var joined := PackedByteArray()
	joined.resize(n)
	var tries := PackedInt32Array()
	tries.resize(n)
	var budgets := PackedInt32Array()
	budgets.resize(n)
	budgets.fill(w.N * 2)
	var tried := {}
	var paths: Array = []
	var connected := 0
	if n > 0:
		joined[0] = 1
		connected = 1
	while connected < n:
		var best: Array = []
		for b in n:
			if joined[b] != 0 or tries[b] >= SETTLEMENT_NEIGHBORS or budgets[b] == 0:
				continue
			for a in n:
				if joined[a] == 0 or tried.has(_key(a, b)):
					continue
				var distance := Grid.hypot(st[a].x - st[b].x, st[a].y - st[b].y)
				if best.is_empty() or distance < best[2]:
					best = [a, b, distance]
		if best.is_empty():
			break
		var a: int = best[0]
		var b: int = best[1]
		tried[_key(a, b)] = true
		tries[b] += 1
		if step.is_valid():
			step.call(0.66 + 0.03 * (connected - 1) / maxi(1, n - 1), "Дороги между поселениями: %d/%d · проверка места %d/%d" % [connected - 1, maxi(0, n - 1), tries[b], SETTLEMENT_NEIGHBORS])
		finder.search_budget = budgets[b]
		var q := _connect_settlement(w, finder, road_cost, st[a].i, st[b].i, state)
		budgets[b] = finder.search_budget
		finder.search_budget = -1
		if q.is_empty():
			continue
		surface.build_structures()
		_add_trail(w, q, "road", road_cost, state.on_axis, surface)
		paths.append([a, b, q, true, best[2]])
		joined[b] = 1
		connected += 1
	# Только подтверждённые поселения попадают на карту, в растительность и постройки.
	var keep: Array = []
	var remap := {}
	for a in n:
		if joined[a] != 0:
			remap[a] = keep.size()
			keep.append(st[a])
	for e: Array in paths:
		e[0] = remap[e[0]]
		e[1] = remap[e[1]]
	w.settlements = keep
	w.generation_profile.settlement_candidates = n
	w.generation_profile.settlement_attempts = tried.size()
	w.generation_profile.settlement_rejected = n - keep.size()
	var expanded := 0
	for budget in budgets:
		expanded += w.N * 2 - budget
	w.generation_profile.settlement_expanded = expanded
	w.generation_profile.main_roads_ms = Time.get_ticks_msec() - started
	finder.use_corridor = true
	_route_surface(finder, surface, WIDTHS.trail)
	# Необязательные петли тоже не могут бесконечно перебирать непригодный берег.
	finder.search_budget = w.N * maxi(1, keep.size())
	_second_ways(w, finder, paths, road_cost, state, step)
	finder.search_budget = -1
	for s: Dictionary in w.settlements:
		s.connections = []
	for e: Array in paths:
		var a: Dictionary = w.settlements[e[0]]
		var b: Dictionary = w.settlements[e[1]]
		if not a.connections.has(b.i): a.connections.append(b.i)
		if not b.connections.has(a.i): b.connections.append(a.i)
	_clear_huts(w)


static func _connect_settlement(w: WorldData, finder: Pathfinder, cost: PackedFloat32Array,
		a: int, b: int, state: Dictionary) -> PackedInt32Array:
	var attempts: Array = []
	for limit: float in [ROAD_GRADE, ROAD_LIMIT]:
		var p := _road_path(finder, cost, a, b, true, limit)
		if p.is_empty():
			continue
		var q := _try_road_structures(w, p, finder, cost, state, attempts)
		if not q.is_empty():
			finder.use_corridor = true
			return q
	finder.use_corridor = true
	return PackedInt32Array()


## После неудачи _structures полностью восстанавливает состояние. Запасной поиск может
## вернуть ту же ось в том же режиме: повторная проверка мостов и объездов ничего не изменит.
## Разные режимы ширины проверяются отдельно: они влияют на поиск объездов внутри _structures.
static func _try_road_structures(w: WorldData, path: PackedInt32Array, finder: Pathfinder,
		cost: PackedFloat32Array, state: Dictionary, attempts: Array) -> PackedInt32Array:
	for previous: Array in attempts:
		if previous[1] == finder.use_corridor and previous[0] == path:
			return PackedInt32Array()
	attempts.append([path, finder.use_corridor])
	return _structures(w, path, true, finder, cost, state)


## Новая связь полезна, если сокращает реальный обход по сети. Второй проход нужен,
## если идёт по другому уровню рельефа. Оба ищутся по суше, без обязательного числа петель.
static func _second_ways(w: WorldData, finder: Pathfinder, paths: Array, road_cost: PackedFloat32Array, state: Dictionary, step: Callable = Callable()) -> void:
	var st := w.settlements
	var n := st.size()
	var have := {}
	for e in paths:
		have[_key(e[0], e[1])] = true
	var pairs: Array = []
	for a in n:
		for b in range(a + 1, n):
			var d := Grid.hypot(st[a].x - st[b].x, st[a].y - st[b].y)
			if have.has(_key(a, b)) or d >= w.W * 0.45:
				continue
			# Соседи по пространству: внутри круга с диаметром a–b нет другого поселения.
			var neighbor := true
			for s in st:
				if (s.x - st[a].x) * (s.x - st[b].x) + (s.y - st[a].y) * (s.y - st[b].y) < 0.0:
					neighbor = false
					break
			if neighbor:
				pairs.append([a, b, d])
	pairs.sort_custom(func(p: Array, q: Array) -> bool: return p[2] < q[2] if p[2] != q[2] else _key(p[0], p[1]) < _key(q[0], q[1]))
	var network := _network_cost(w)
	for index in pairs.size():
		var e: Array = pairs[index]
		if step.is_valid():
			step.call(0.69 + 0.015 * index / maxi(1, pairs.size()), "Дополнительные тропы: %d/%d" % [index + 1, pairs.size()])
		var a: int = st[e[0]].i
		var b: int = st[e[1]].i
		var old := finder.find_path(network, a, b)
		var old_len := _length(w, old)
		if old.is_empty() or old_len <= e[2] * SHORTCUT:
			continue
		var corr := _corridor(w, [old])
		var p := _land_path(finder, _avoiding(w, corr), a, b, TRAIL_CLIMB)
		if p.is_empty() or _length(w, p) * SHORTCUT >= old_len or _share(p, corr) > AVOID_SHARE or not _new_ground(w, p):
			continue
		var q := _structures(w, p, false, finder, w.cost, state)
		if q.is_empty():
			continue
		_add_trail(w, q, "trail", road_cost, state.on_axis, state.get("surface"))
		paths.append([e[0], e[1], q, false, e[2]])
		network = _network_cost(w)
	# Проверяем каждую основную связь; плоская копия соседней дороги сама по себе не повод для петли.
	var primary_paths := paths.duplicate()
	for index in primary_paths.size():
		var e: Array = primary_paths[index]
		if not e[3]:
			continue
		if step.is_valid():
			step.call(0.705 + 0.015 * index / maxi(1, primary_paths.size()), "Обходные тропы: %d/%d" % [index + 1, primary_paths.size()])
		var corr := _corridor(w, [e[2]])
		var p := _land_path(finder, _avoiding(w, corr), st[e[0]].i, st[e[1]].i, TRAIL_CLIMB)
		if p.is_empty() or _length(w, p) > _length(w, e[2]) * ALT_LEN or _share(p, corr) > AVOID_SHARE \
				or not _new_ground(w, p) or not _different_relief(w, p, e[2]):
			continue
		var q := _structures(w, p, false, finder, w.cost, state)
		if q.is_empty():
			continue
		_add_trail(w, q, "trail", road_cost, state.on_axis, state.get("surface"))
		paths.append([e[0], e[1], q, false, e[4]])
	# Берег — самостоятельная цель исследования, даже у поселения с несколькими дорогами.
	var all_paths: Array = []
	for e in paths:
		all_paths.append(e[2])
	for index in st.size():
		var s: Dictionary = st[index]
		if step.is_valid():
			step.call(0.72 + 0.02 * index / maxi(1, st.size()), "Тропы к берегам: %d/%d" % [index + 1, st.size()])
		var corr := _corridor(w, all_paths)
		var t := _shore(w, s.i, corr)
		if t >= 0:
			var p := _land_path(finder, _avoiding(w, corr), s.i, t, TRAIL_CLIMB)
			var d := Grid.hypot(t % w.W - s.x, t / w.W - s.y)
			if not p.is_empty() and _length(w, p) <= d * BRANCH_LEN and _share(p, corr) <= AVOID_SHARE:
				var q := _structures(w, p, false, finder, w.cost, state)
				if q.is_empty():
					continue
				_add_trail(w, q, "trail", road_cost, state.on_axis, state.get("surface"))
				all_paths.append(q)


## Сеть уже нарисованных путей людей: реальный обход учитывает развилки вне поселений.
static func _network_cost(w: WorldData) -> PackedFloat32Array:
	var cost := PackedFloat32Array()
	cost.resize(w.N)
	for i in w.N:
		cost[i] = 1.0 if w.path_mask[i] >= 2 else INF
	return cost


## У троп свой предел: короткий технический подъём конкурирует с длинным обходом по цене A*.
static func _land_path(finder: Pathfinder, cost: PackedFloat32Array, a: int, b: int, climb: float, limit: float = TRAIL_GRADE) -> PackedInt32Array:
	return finder.find_path(cost, a, b, climb, limit)


## Земляные работы могут исправить край полотна; продольный обрыв ими не исправить.
## Вода доступна для сооружений; на суше полная ширина проверяется во всех попытках.
static func _road_path(finder: Pathfinder, cost: PackedFloat32Array, a: int, b: int, wide := true, limit := ROAD_GRADE) -> PackedInt32Array:
	finder.use_corridor = wide
	return finder.find_path(cost, a, b, ROAD_CLIMB, limit)


static func _length(w: WorldData, p: PackedInt32Array) -> float:
	var length := 0.0
	for k in range(1, p.size()):
		length += Grid.hypot(p[k] % w.W - p[k - 1] % w.W, p[k] / w.W - p[k - 1] / w.W)
	return length


## Не дублировать маршрут, уже проходящий по другой части сети.
static func _new_ground(w: WorldData, p: PackedInt32Array) -> bool:
	var fresh := 0
	for i in p:
		if w.path_mask[i] < 2:
			fresh += 1
	return fresh > p.size() * 0.5


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


## Ближайшая к клетке s клетка морского или озёрного берега от SHORE_MIN до SHORE_MAX клеток,
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
			if d < SHORE_MIN * SHORE_MIN or d >= bd or near[i] != 0 or w.cost[i] == INF or not _at_mouth(w, x, y):
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
			# Полоса дороги должна оставаться свободной и внутри деревни, не только на мостах.
			for dz: float in [-0.55, 0.0, 0.55]:
				for dx: float in [-0.55, 0.0, 0.55]:
					var x := clampi(floori(u.x + dx), 0, w.W - 1)
					var y := clampi(floori(u.y + dz), 0, w.H - 1)
					if w.path_mask[y * W + x] >= 2:
						free = false
			for sp in spans:
				if Grid.segment_dist(u.x, u.y, sp.a % W + 0.5, sp.a / W + 0.5, sp.b % W + 0.5, sp.b / W + 0.5) < HUT_CLEAR:
					free = false
					break
			if free:
				keep.append(u)
		st.huts = keep


## Мокрая клетка: море, озеро или река
static func _wet(w: WorldData, i: int) -> bool:
	return w.ocean[i] != 0 or w.lake[i] != 0 or w.river_cells()[i] != 0


## Мосты и туннели на пути между поселениями: заносит их в w.bridges и w.tunnels и возвращает путь,
## в котором участки под ними заменены прямыми. Мост — только через воду между берегами;
## туннель — сквозь хребет выше RISE. У обоих уклон не круче GRADE.
## Тропа (road = false) переходит реку не шире FORD_LEN вброд. Новый туннель через раз заменяется
## обходом горы, если он есть (state.detour — очередь обхода; cost — стоимость, по которой ищется обход).
## Клетки осей мостов и туннелей отмечаются в state.on_axis.
static func _make_checkpoint(w: WorldData, finder: Pathfinder, state: Dictionary) -> Dictionary:
	var surface: Heightfield = state.get("surface")
	return {bridges = w.bridges.duplicate(), tunnels = w.tunnels.duplicate(), mask = w.path_mask.duplicate(),
		heights = finder.heights.duplicate(), links = finder.links.duplicate(), on_axis = state.on_axis.duplicate(),
		detour = state.detour, hv = surface.hv.duplicate() if surface != null else PackedFloat32Array()}


static func _structures(w: WorldData, p: PackedInt32Array, road: bool, finder: Pathfinder, cost: PackedFloat32Array, state: Dictionary, retries: int = 0) -> PackedInt32Array:
	# Неудачная связь не оставляет за собой мосты, выемки и разрешённые шаги по их осям.
	var ctx := {checkpoint = null, initial_detour = state.detour, initial_links_empty = finder.links.is_empty()}
	var result := _build_structures(w, p, road, finder, cost, state, retries, ctx)
	if result.is_empty():
		_restore_structures(w, finder, state, ctx)
	return result


static func _restore_structures(w: WorldData, finder: Pathfinder, state: Dictionary, ctx: Dictionary) -> void:
	if ctx.checkpoint == null:
		state.detour = ctx.initial_detour
		if ctx.initial_links_empty:
			finder.links = PackedByteArray()
		return
	var checkpoint: Dictionary = ctx.checkpoint
	w.bridges = checkpoint.bridges.duplicate()
	w.tunnels = checkpoint.tunnels.duplicate()
	w.path_mask = checkpoint.mask.duplicate()
	finder.heights = checkpoint.heights.duplicate()
	finder.links = PackedByteArray() if ctx.initial_links_empty else checkpoint.links.duplicate()
	state.on_axis = checkpoint.on_axis.duplicate()
	state.detour = ctx.initial_detour
	if state.has("surface"):
		state.surface.hv = checkpoint.hv.duplicate()
		state.surface.build_structures()


static func _build_structures(w: WorldData, p: PackedInt32Array, road: bool, finder: Pathfinder, cost: PackedFloat32Array, state: Dictionary, retries: int, ctx: Dictionary) -> PackedInt32Array:
	if finder.links.is_empty():
		finder.links.resize(w.N)
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
		if state.has("surface"):
			var surface: Heightfield = state.surface
			hp[k] = (surface.water_level[c] if wet[k] != 0 and surface.water_level[c] > -INF else surface.hv[c]) / GameConfig.HS
		xs[k] = c % W
		ys[k] = c / W
	# Наибольшая высота впереди: без хребта конец туннеля не ищется.
	var ahead_max := _window(hp, SPAN, true)
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
			if j >= n or not road and j - i - 1 <= FORD_LEN and _river_only(w, p, i + 1, j, state.get("surface")):
				j = -1
			elif state.has("surface"):
				var shore := j
				# Короткая переправа между устойчивыми берегами; не вытягиваем мост
				# вдоль дороги до случайной далёкой клетки с подходящей высотой.
				var site := _bridge_site(state.surface, p, wet, i, shore, out, state.on_axis)
				j = site.y
				if site.x >= 0:
					out.resize(out.size() - (i - site.x))
					i = site.x
				if j < 0:
					# Последняя неудача уже исчерпала запас объездов: ещё один A* не используется.
					if retries >= BRIDGE_RETRIES:
						return PackedInt32Array()
					var bypass := cost.duplicate()
					for k in range(i + 1, shore):
						for y in range(maxi(0, ys[k] - 3), mini(w.H, ys[k] + 4)):
							for x in range(maxi(0, xs[k] - 3), mini(W, xs[k] + 4)):
								if _wet(w, y * W + x):
									bypass[y * W + x] = INF
					# Новый переход ищется от начала связи: фиксированный крутой берег
					# не должен заставлять объезд карабкаться вверх сразу от воды.
					var q := _road_path(finder, bypass, p[0], p[-1], finder.use_corridor) if road else _land_path(finder, bypass, p[0], p[-1], TRAIL_CLIMB)
					if not q.is_empty():
						_restore_structures(w, finder, state, ctx)
						return _structures(w, q, road, finder, bypass, state, retries + 1)
					return PackedInt32Array()
		elif hp[i + 1] > hp[i] and ahead_max[i] >= hp[i] + RISE:
			j = _span_end(hp, wet, xs, ys, i)
			while j > 0 and i + 1 < j - 2 and _span_end(hp, wet, xs, ys, i + 1) == j:
				out.append(p[i + 1])
				i += 1
			kind = "tunnel"
			if j > 0 and _same(w, w.tunnels, p[i], p[j], _key_cell(p, hp, wet, i, j)).is_empty():
				if _near_tunnel(w, p[i], p[j]) or _wet_near(w, p[i], p[j], TUNNEL_R) or _path_at_portal(w, p[i], p[j]):
					j = -1
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
			if a != ends[0] and to_a.is_empty() or ends[1] != b and from_b.is_empty() or _has_wet(w, to_a) or _has_wet(w, from_b):
				ends = []
				to_a = PackedInt32Array()
				from_b = PackedInt32Array()
		# Повторно используемый мост тоже записывает on_axis, heights и links ниже.
		if ctx.checkpoint == null:
			ctx.checkpoint = _make_checkpoint(w, finder, state)
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
			if state.has("surface"):
				state.surface.build_structures()
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
				# У диагонального настила боковые клетки могут быть водой или стеной.
				# Разрешается только фактический шаг вдоль оси, без боковых входов.
				for direction in 8:
					if line[k] % W - line[k - 1] % W == Grid.DX[direction] and line[k] / W - line[k - 1] / W == Grid.DY[direction]:
						finder.links[line[k - 1]] |= 1 << direction
					if line[k - 1] % W - line[k] % W == Grid.DX[direction] and line[k - 1] / W - line[k] / W == Grid.DY[direction]:
						finder.links[line[k]] |= 1 << direction
				out.append(line[k])
		out.append_array(from_b)
		i = j
	return _no_backtrack(out)


## Ищем ближайшую пару берегов, а не первый подходящий дальний конец.
## Не меняем уже принятую ось или путь до текущего подхода.
static func _bridge_site(surface: Heightfield, p: PackedInt32Array, wet: PackedByteArray,
		start: int, shore: int, out: PackedInt32Array, on_axis: PackedByteArray) -> Vector2i:
	var best := Vector2i(-1, -1)
	var score := INF
	for back in range(4):
		var a := start - back
		if a < 0 or out.size() <= back or out[-1 - back] != p[a] or wet[a] != 0:
			break
		if back > 0 and on_axis[p[a]] != 0:
			break
		for b in range(shore, mini(p.size(), mini(shore + 7, a + SPAN))):
			if wet[b] != 0:
				continue
			var length := Grid.hypot(p[b] % surface.world.W - p[a] % surface.world.W,
				p[b] / surface.world.W - p[a] / surface.world.W)
			if length >= score or not _crosses_water(surface, p[a], p[b]) or not _bridge_clear(surface, p[a], p[b]):
				continue
			best = Vector2i(a, b)
			score = length
	return best


## Маска реки включает сухой берег; мост нужен над самой водой, а не над маской.
static func _crosses_water(surface: Heightfield, a: int, b: int) -> bool:
	var s := surface._axis(a, b, false)
	for k in range(1, ceili(s.len)):
		if surface.depth_at(s.ax + s.ux * k, s.az + s.uz * k) > 0.3:
			return true
	return false


## Тот же настил, что в игре: пологий, выше воды и земли, с доступными подходами.
static func _bridge_clear(surface: Heightfield, a: int, b: int) -> bool:
	if a == b:
		return false
	var s := surface._axis(a, b, false)
	s.ay = surface.ground_at(s.ax, s.az)
	s.by = surface.ground_at(s.bx, s.bz)
	if absf(s.by - s.ay) > GRADE * HEIGHT_SCALE * s.len:
		return false
	# Концы моста не должны попадать на узкий мыс: проверяем сушу под обоими краями
	# настила. Иначе центр касается берега, а большая часть въезда нависает над водой.
	for end in 2:
		var t: float = 0.0 if end == 0 else s.len
		var deck: float = s.ay if end == 0 else s.by
		for side in [-1.0, 0.0, 1.0]:
			var x: float = s.ax + s.ux * t - s.uz * side * s.half
			var z: float = s.az + s.uz * t + s.ux * side * s.half
			if surface.depth_at(x, z) > 0.3 or absf(surface.ground_at(x, z) - deck) > BRIDGE_LANDING_GAP:
				return false
	for k in range(-2, ceili(s.len) + 3):
		var t := clampf(float(k), -2.0, s.len + 2.0)
		var deck := surface.level(s, t)
		for side in [-1.0, 0.0, 1.0]:
			var x: float = s.ax + s.ux * t - s.uz * side * (s.half + 0.8)
			var z: float = s.az + s.uz * t + s.ux * side * (s.half + 0.8)
			var ground := surface.ground_at(x, z)
			if t > 1.0 and t < s.len - 1.0 and ground > deck + 0.3:
				return false
			var other := surface.deck_at(x, z, INF)
			if other > -INF and absf(other - deck) > 0.3 and absf(other - deck) < Heightfield.TUNNEL_HEIGHT:
				return false
			if side == 0.0 and (surface.wall_at(x, z, maxf(deck, ground), 0.5) or surface.depth_at(x, z) > 0.3 and ground + surface.depth_at(x, z) > deck - 0.1):
				return false
	return true


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


## Безопасный подход по суше к готовому сооружению (без a); пустой, если подхода нет.
static func _link(w: WorldData, finder: Pathfinder, a: int, b: int) -> PackedInt32Array:
	if a == b:
		return PackedInt32Array()
	var q := finder.find_path(w.cost, a, b, ROAD_CLIMB, ROAD_GRADE)
	if q.size() == 0 or q.size() > REUSE_R * 3.0:
		return PackedInt32Array()
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
	var q := _land_path(finder, c, a, b, TRAIL_CLIMB)
	if q.size() > d * DETOUR:
		return PackedInt32Array()
	return q


## Проходит ли прежний путь (path_mask) поперёк выемки будущего туннеля a–b (с 3.0 — у входов, с 6.9 — по всей
## длине): выемка опускает рельеф до пола, и путь упирался бы в стену у портала или в провал над туннелем
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
			if w.path_mask[y * W + x] >= 2 and minf(da, db) > 0.5 and Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) <= TUNNEL_R:
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
static func _river_only(w: WorldData, p: PackedInt32Array, from: int, to: int, surface: Heightfield = null) -> bool:
	for k in range(from, to):
		if w.ocean[p[k]] != 0 or w.lake[p[k]] != 0 or w.slope[p[k]] > FORD_SLOPE:
			return false
	if surface != null:
		for k in range(maxi(1, from), mini(p.size(), to + 1)):
			var a := Vector2(p[k - 1] % w.W + 0.5, p[k - 1] / w.W + 0.5) * GameConfig.TILE
			var b := Vector2(p[k] % w.W + 0.5, p[k] / w.W + 0.5) * GameConfig.TILE
			var steps := maxi(1, ceili(a.distance_to(b) / 0.5))
			for step in steps + 1:
				var q := a.lerp(b, float(step) / steps)
				if surface.depth_at(q.x, q.y) > GameConfig.FORD_DEPTH - 0.15:
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
		# у короткого моста оба порядка концов проходят REUSE_R: берётся тот, где концы ближе к a и b.
		# До 6.9 брался первый, путь шёл к дальнему концу через воду, и рядом строился второй такой же мост
		var best: Array = []
		var best_d := INF
		for e in [[s.a, s.b], [s.b, s.a]]:
			var ea: int = e[0]
			var eb: int = e[1]
			var da := Grid.hypot(ea % W - a % W, ea / W - a / W)
			var db := Grid.hypot(eb % W - b % W, eb / W - b / W)
			if da <= REUSE_R and db <= REUSE_R and da + db < best_d:
				best = e
				best_d = da + db
		if not best.is_empty():
			return best
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


## Конец туннеля, который начинается в p[i]:
## первая клетка, после которой путь уже перевалил через хребет, или -1
static func _span_end(hp: PackedFloat32Array, wet: PackedByteArray, xs: PackedInt32Array, ys: PackedInt32Array, i: int) -> int:
	var ha := hp[i]
	var ax := xs[i]
	var ay := ys[i]
	var lim := RISE_LEN
	var lim2 := lim * lim
	var top := -INF
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
			if top - maxf(ha, hb) >= RISE:
				return j
		top = maxf(top, hb)
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


## Горные тропы ответвляются от ближайшего доступного пути людей, а не обязательно от поселения.
static func _mountain_trails(w: WorldData, finder: Pathfinder, surface: Heightfield = null) -> void:
	var on_axis := PackedByteArray()
	on_axis.resize(w.N)
	for span: Dictionary in w.bridges + w.tunnels:
		for c: int in Grid.line_cells(span.a % w.W, span.a / w.W, span.b % w.W, span.b / w.W, w.W):
			on_axis[c] = 1
	# С 3.1 горная тропа обходит крутые участки реки: на перепаде русла такой «брод» глубже,
	# чем кажется по одной клетке. Это последний поиск путей, дороги уже проложены по мостам
	var river := w.river_cells()
	for i in w.N:
		if river[i] == 0:
			continue
		var unsafe := w.slope[i] > FORD_SLOPE
		if surface != null:
			# Узкий глубокий участок может лежать между центрами клеток.
			# Горные тропы не строят мостов: заранее закрываем такой проход.
			for dz in [-0.4, 0.0, 0.4]:
				for dx in [-0.4, 0.0, 0.4]:
					if surface.depth_at((i % w.W + 0.5 + dx) * GameConfig.TILE, (i / w.W + 0.5 + dz) * GameConfig.TILE, INF) > GameConfig.FORD_DEPTH - 0.15:
						unsafe = true
		if unsafe and on_axis[i] == 0:
			w.cost[i] = INF
	for pk in w.peaks:
		var best := -1
		var bd := INF
		if w.path_mask[pk.i] >= 2:
			continue
		for i in w.N:
			if w.path_mask[i] < 2 or w.cost[i] == INF:
				continue
			var d := Grid.hypot(i % w.W + 0.5 - pk.x, i / w.W + 0.5 - pk.y)
			if d < bd:
				bd = d
				best = i
		if best >= 0 and bd < w.W * 0.4:
			# Технический подъём остаётся крутым, но отвесная вершина не получает фиктивную тропу.
			var p := finder.find_path(w.cost, best, pk.i, MOUNTAIN_CLIMB, MOUNTAIN_GRADE)
			if p.size() > 0:
				_add_trail(w, p, "mountain", PackedFloat32Array(), on_axis, surface)
