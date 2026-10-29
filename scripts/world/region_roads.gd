extends RefCounted
## 13.6: дороги и мосты общей группы подготовленных областей, без публикации в сцену.
## Группа не больше 4 областей. Разрывы и места, требующие сооружений, возвращаются явно.
## 13.8: узлы сети — поселения группы, выходы закреплённых дорог (ledger.exits) и старая сеть плана.
## К дорогам плана ведут подходы по его сухой земле не глубже APPROACH; закреплённые области
## не меняются, их дороги продолжаются от выходов. На свободных сторонах остаются новые выходы.
const Places := preload("res://scripts/world/region_settlements.gd")
const RegionalGround := preload("res://scripts/world/region_road_heightfield.gd")
const Known := preload("res://scripts/world/region_known.gd")
const MAX_CELLS := 4 * 260 * 260
const APPROACH := 64 # клеток: глубина подхода к старой дороге внутри стартового плана
const EXIT_MARGIN := 12 # выход не ставится у угла области
const PLAN := "plan" # метка сети, связанной со старыми дорогами плана
const SIDES := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
## P2 аудита 29.10, замер на стенде соседей (две области 256, два запуска с обратным порядком политик):
## когда связи удаются с первой попытки, фоновый запасной поиск (prefetch) делает столько же раскрытий,
## сколько основной, и ни разу не нужен (83 579 + 83 579 против 83 579). У реки без моста он нужен 4 раза,
## но всего раскрытий 630 тыс. против 537 тыс. у ленивого. Время в обоих случаях в пределах разброса:
## второй прогон пары медленнее первого при любой политике (5,95/7,09 с и 5,69/6,23 с). Области готовятся
## в фоне во время игры, поэтому важнее процессор: запасной поиск здесь ленивый. Стартовый план (загрузка
## на переднем плане) не меняется. Пути и остаток запаса одинаковы (стенд сравнивает побайтно).
static var eager_fallback := false


static func prepare(source: WorldData, regions: Array, batch: Dictionary, ledger := {}) -> Dictionary:
	if not batch.get("ready", false) or regions.is_empty():
		return {ready = false, reason = "water_not_ready", trails = [], settlements = [], exits = []}
	var union: Rect2i = regions[0].sample_rect
	for region: Dictionary in regions: union = union.merge(region.sample_rect)
	if union.get_area() > MAX_CELLS or regions.size() > 4:
		return {ready = false, reason = "batch_too_large", trails = [], settlements = [], exits = []}
	# Полоса стартового плана, по которой можно подойти к его дорогам.
	var plan := Rect2i(0, 0, source.W, source.H) if source.N > 0 else Rect2i()
	var strip := union.grow(APPROACH).intersection(plan)
	var bounds := union.merge(strip) if strip.has_area() else union
	# Фиксированный порядок копирования и центров: порядок загрузки не меняет сеть.
	var order: Array = range(regions.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		var p: Vector2i = regions[a].rect.position
		var q: Vector2i = regions[b].rect.position
		return p.y < q.y or p.y == q.y and p.x < q.x)
	var fields := {}
	for name: String in regions[0].fields:
		var values: Variant = regions[0].fields[name].slice(0, 0) # пустой массив того же типа, без копии поля
		values.resize(bounds.get_area())
		values.fill(0)
		fields[name] = values
	if not fields.has("path"):
		fields.path = PackedByteArray()
		fields.path.resize(bounds.get_area())
	fields.water_level.fill(-INF)
	Known.apply_known(fields, bounds, source, ledger)
	var surface := {ready = true, h = fields.h.duplicate(), river = fields.river.duplicate(), water_level = fields.water_level.duplicate()}
	for i in bounds.get_area():
		# Готовая вода плана и журнала; сухая земля плана хранит в water_level свою высоту.
		if fields.ocean[i] != 0: surface.water_level[i] = 0.0
		elif fields.river[i] == 0 and fields.lake[i] == 0: surface.water_level[i] = -INF
	var covered := PackedByteArray()
	covered.resize(bounds.get_area())
	var settlements: Array = []
	for n: int in order:
		var region: Dictionary = regions[n]
		for y in range(region.sample_rect.position.y, region.sample_rect.end.y):
			for x in range(region.sample_rect.position.x, region.sample_rect.end.x):
				var dst := (y - bounds.position.y) * bounds.size.x + x - bounds.position.x
				var src: int = (y - region.sample_rect.position.y) * region.sample_rect.size.x + x - region.sample_rect.position.x
				for name: String in region.fields: fields[name][dst] = region.fields[name][src]
				for name: String in ["h", "river", "water_level"]: surface[name][dst] = batch.surfaces[n][name][src]
				if region.rect.has_point(Vector2i(x, y)): covered[dst] = 1
		settlements.append_array(batch.settlements[n].duplicate(true))
	settlements.sort_custom(func(a: SettlementData, b: SettlementData) -> bool: return a.id < b.id)
	var merged := {rect = bounds, sample_rect = bounds, fields = fields}
	var started := Time.get_ticks_usec()
	# P1 аудита 29.10: одиночная область без полосы плана — тот же домен, поля и вода, что у её поселений;
	# география берётся из пакета. Иначе (группа, подход к плану) расстояния до воды на объединении
	# другие, и она считается заново.
	var geography: Dictionary = batch.geographies[0] if regions.size() == 1 and batch.get("geographies", []).size() == 1 else {}
	var w := Places.local_world(source, merged, surface, geography)
	var profile := {geography_ms = (Time.get_ticks_usec() - started) / 1000.0, geography_reused = geography.get("rect") == bounds}
	started = Time.get_ticks_usec()
	w.path_mask = fields.path.duplicate()
	# Проходимо: свои клетки группы и сухая земля плана в полосе подхода, кроме домов и сооружений.
	var blocked := _old_places(source, bounds)
	var open := PackedByteArray()
	open.resize(w.N)
	var targets := PackedInt32Array()
	w.cost.resize(w.N)
	for i in w.N:
		var wet := w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0
		var cell := bounds.position + Vector2i(i % w.W, i / w.W)
		if covered[i] != 0 and fields.fixed[i] == 0:
			open[i] = 1
		elif plan.has_point(cell) and not wet and blocked[i] == 0:
			open[i] = 1
			if w.path_mask[i] >= 2: targets.append(i)
		w.cost[i] = INF if open[i] == 0 else (StageTrails.BRIDGE_COST if wet else Biomes.LIST[w.biome[i]].get("cost", 2.0) + w.slope[i] * 7.0)
	# Узлы: поселения, приходящие выходы закреплённых дорог, старая сеть плана.
	var nodes: Array = []
	for place: SettlementData in settlements:
		var s: SettlementData = place.duplicate(true)
		s.x -= bounds.position.x
		s.y -= bounds.position.y
		s.i = floori(s.y) * w.W + floori(s.x)
		s.huts = []
		w.settlements.append(s)
		nodes.append({id = s.id, i = s.i, net = ""})
	var edge_of := {} # локальная клетка выхода -> точка на границе области
	var incoming: Array = []
	for exit: Dictionary in ledger.get("exits", []):
		var cell := Vector2i(floori(exit.x + exit.dx * 0.5), floori(exit.y + exit.dy * 0.5))
		for region: Dictionary in regions:
			if region.rect.has_point(cell): incoming.append(exit)
	incoming.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.y < b.y or a.y == b.y and a.x < b.x)
	for exit: Dictionary in incoming:
		var cell := Vector2i(floori(exit.x + exit.dx * 0.5), floori(exit.y + exit.dy * 0.5)) - bounds.position
		var i := cell.y * w.W + cell.x
		edge_of[i] = Vector2(exit.x, exit.y) - Vector2(bounds.position)
		nodes.append({id = "exit:%d:%d" % [cell.x + bounds.position.x, cell.y + bounds.position.y], i = i, net = exit.net})
	if not targets.is_empty(): nodes.append({id = PLAN, i = -1, net = PLAN})
	var groups: Array = range(nodes.size())
	for a in nodes.size():
		for b in range(a + 1, nodes.size()):
			if nodes[a].net != "" and nodes[a].net == nodes[b].net: _join(groups, a, b)
	var ground := RegionalGround.new(w, surface.water_level)
	# tunnels = false: области не умеют сохранять и воспроизводить туннели, поэтому хребет только
	# обходится — это известно до сооружений (ревью дорожной сети 29.10, шаг 1).
	var state := {detour = false, tunnels = false, on_axis = PackedByteArray(), surface = ground, failures = {}}
	state.on_axis.resize(w.N)
	var heights := ground.hv.duplicate()
	for i in heights.size():
		# Поиск переправы оценивает воду, а не уклон спуска на дно.
		if StageTrails._wet(w, i): heights[i] = maxf(heights[i], ground.water_level[i])
		heights[i] /= GameConfig.TILE
	var finder := Pathfinder.new(w.W, w.H, heights)
	finder.eager_fallback = eager_fallback
	StageTrails._route_surface(finder, ground, StageTrails.WIDTHS.road)
	# Один суммарный бюджет на группу, включая неудачные направления.
	finder.search_budget = w.N * 4
	# Пара со старой сетью идёт к ближайшей клетке её дороги в полосе подхода.
	var pairs: Array = []
	for a in nodes.size():
		for b in range(a + 1, nodes.size()):
			if nodes[a].i < 0: continue
			var to: int = nodes[b].i if nodes[b].i >= 0 else _nearest(w, targets, nodes[a].i)
			pairs.append([_distance2(w, nodes[a].i, to), a, b, to])
	pairs.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] or a[0] == b[0] and (a[1] < b[1] or a[1] == b[1] and a[2] < b[2]))
	var edges: Array = []
	var attempts := 0
	for pair: Array in pairs:
		var a: int = pair[1]
		var b: int = pair[2]
		if _root(groups, a) == _root(groups, b): continue
		if finder.search_budget <= 0 or attempts >= maxi(1, nodes.size() * 3): break
		attempts += 1
		if not _build(w, finder, state, open, nodes[a].i, pair[3]): continue
		edges.append({from = nodes[a].id, to = nodes[b].id})
		_join(groups, a, b)
	# Выходы на свободные стороны: следующий сосед продолжит дорогу, а не начнёт заново.
	var exits: Array = []
	for n: int in order:
		var rect: Rect2i = regions[n].rect
		for d: Vector2i in SIDES:
			if finder.search_budget <= 0: break
			var beyond := Rect2i(rect.position + d * rect.size, rect.size)
			if not _free_side(beyond, regions, ledger, plan): continue
			var from := _side_node(w, nodes, bounds, rect, d)
			if from < 0: continue
			var cell := _side_cell(w, fields, open, bounds, rect, d, nodes[from].i)
			if cell < 0 or not _build(w, finder, state, open, nodes[from].i, cell): continue
			edge_of[cell] = Vector2(cell % w.W, cell / w.W) + Vector2.ONE * 0.5 + Vector2(d) * 0.5
			exits.append({cell = cell, dx = d.x, dy = d.y, node = from})
	profile.merge(finder.search_stats())
	finder.release()
	profile.roads_ms = (Time.get_ticks_usec() - started) / 1000.0
	profile.checkpoints = state.get("checkpoints", 0)
	profile.checkpoint_mb = state.get("checkpoint_bytes", 0) / 1048576.0
	profile.restores = state.get("restores", 0)
	profile.failures = state.failures
	profile.windows = state.get("windows", {})
	started = Time.get_ticks_usec()
	# Единственная расстановка домов (площадки пришли без них) — вдоль получившихся улиц.
	StageLandmarks.lay_out(w)
	profile.homes_laid = StageLandmarks.count_homes(w.settlements)
	StageTrails._clear_huts(w)
	profile.homes_kept = StageLandmarks.count_homes(w.settlements)
	profile.layout_ms = (Time.get_ticks_usec() - started) / 1000.0
	RoadSurface.run(w)
	# Сети: связанная со старыми дорогами — PLAN, иначе наименьшая метка своих узлов.
	var labels := {}
	for k in nodes.size():
		var root: int = _root(groups, k)
		var mine: String = nodes[k].net if nodes[k].net != "" else nodes[k].id
		if not labels.has(root) or mine == PLAN or labels[root] != PLAN and mine < labels[root]: labels[root] = mine
	var merged_nets := {}
	for k in nodes.size():
		var label: String = labels[_root(groups, k)]
		if nodes[k].net != "" and nodes[k].net != label: merged_nets[nodes[k].net] = label
	# 13.9: поля для растительности закреплённой области — как у плана в StageVegetation.
	var path_src := PackedByteArray()
	path_src.resize(w.N)
	for i in w.N: path_src[i] = int(w.path_mask[i] > 0)
	var village := PackedByteArray()
	village.resize(w.N)
	var reach := StageVegetation.VILLAGE_R
	for s: SettlementData in w.settlements:
		for y in range(maxi(0, ceili(s.y - reach)), mini(w.H - 1, floori(s.y + reach)) + 1):
			for x in range(maxi(0, ceili(s.x - reach)), mini(w.W - 1, floori(s.x + reach)) + 1):
				village[y * w.W + x] = 1
	# P1 аудита 29.10: дома ставятся один раз, здесь. Площадка, где после дорог и мостов не осталось
	# минимума жилых домов, не публикуется пустой деревней: она в underfilled, дороги к ней — просто дороги.
	var underfilled: Array = []
	for s: SettlementData in w.settlements:
		if StageLandmarks.homes_of(s) < Places.min_homes(s): underfilled.append(s.id)
	profile.underfilled = underfilled.size()
	edges = edges.filter(func(e: Dictionary) -> bool: return not underfilled.has(e.from) and not underfilled.has(e.to))
	var out_places: Array = []
	for k in w.settlements.size():
		var s: SettlementData = w.settlements[k]
		if underfilled.has(s.id): continue
		s.x += bounds.position.x
		s.y += bounds.position.y
		s.i = -1
		s.net = labels[_root(groups, k)]
		s.connections = []
		for edge: Dictionary in edges:
			if edge.from == s.id: s.connections.append(edge.to)
			elif edge.to == s.id: s.connections.append(edge.from)
		for hut: HutData in s.huts:
			hut.x += bounds.position.x
			hut.y += bounds.position.y
		out_places.append(s)
	for trail: Dictionary in w.trails:
		# Конец у выхода продолжается до самой границы: две области сходятся в одной точке.
		for end: int in [0, -1]:
			var p: Dictionary = trail.pts[end]
			var i := floori(p.y) * w.W + floori(p.x)
			if edge_of.has(i) and Vector2(p.x, p.y).distance_to(Vector2(i % w.W, i / w.W) + Vector2.ONE * 0.5) < 0.01:
				var tip := {x = edge_of[i].x, y = edge_of[i].y, w = p.w}
				if end == 0: trail.pts.insert(0, tip)
				else: trail.pts.append(tip)
		trail.approach = false
		for p: Dictionary in trail.pts:
			p.x += bounds.position.x
			p.y += bounds.position.y
			trail.approach = trail.approach or plan.has_point(Vector2i(floori(p.x), floori(p.y)))
	var out_exits: Array = []
	for exit: Dictionary in exits:
		var edge: Vector2 = edge_of[exit.cell] + Vector2(bounds.position)
		out_exits.append({x = edge.x, y = edge.y, dx = exit.dx, dy = exit.dy, net = labels[_root(groups, exit.node)]})
	# Подходы внутри плана: старые клетки не меняются, новые метки путей отдельно.
	var plan_paths := {}
	for i in w.N:
		var cell := bounds.position + Vector2i(i % w.W, i / w.W)
		if plan.has_point(cell) and w.path_mask[i] > fields.path[i]: plan_paths[cell] = w.path_mask[i]
	var bridges: Array = []
	for span: BridgeData in w.bridges:
		bridges.append({a = Vector2(span.a % w.W + 0.5, span.a / w.W + 0.5) + Vector2(bounds.position),
			b = Vector2(span.b % w.W + 0.5, span.b / w.W + 0.5) + Vector2(bounds.position)})
	var components := {}
	for k in nodes.size(): components[_root(groups, k)] = true
	return {ready = components.size() <= 1, reason = "" if components.size() <= 1 else "disconnected_routes",
		trails = w.trails, bridges = bridges, settlements = out_places, underfilled = underfilled, connections = edges, components = components.size(), attempts = attempts,
		exits = out_exits, merged_nets = merged_nets, plan_paths = plan_paths,
		sample_rect = bounds, path_mask = w.path_mask, road_surface = w.road_surface, biome = w.biome,
		slope = w.slope, dw = w.dist_water, dist_path = Grid.distance_field(w.W, w.H, path_src), village = village,
		profile = profile} # время и счётчики работы; при сравнении результатов не учитывать


## Штатный поиск, мосты и проверка ленты; непригодная связь откатывается целиком.
## Причина каждого отказа — в state.failures (StageTrails._count_failure).
static func _build(w: WorldData, finder: Pathfinder, state: Dictionary, open: PackedByteArray, a: int, b: int) -> bool:
	if a < 0 or b < 0 or a == b or w.cost[a] == INF or w.cost[b] == INF:
		state.failure = "endpoint"
		StageTrails._count_failure(state.failures, state)
		return false
	var checkpoint := StageTrails._make_checkpoint(w, finder, state)
	var ctx := {checkpoint = checkpoint, initial_detour = state.detour, initial_links_empty = finder.links.is_empty()}
	var path := StageTrails._connect_settlement(w, finder, w.cost, a, b, state)
	if path.size() < 2:
		StageTrails._count_failure(state.failures, state)
		return false
	# Защита: state.tunnels = false не даёт поиску строить туннели (они обходятся или связь отвергается раньше).
	if not w.tunnels.is_empty():
		push_error("RegionRoads: туннель при запрете туннелей")
		StageTrails._restore_structures(w, finder, state, ctx)
		state.failure = "tunnel"
		StageTrails._count_failure(state.failures, state)
		return false
	var old_cost := w.cost.duplicate()
	StageTrails._add_trail(w, path, "road", PackedFloat32Array(), state.on_axis, state.surface)
	if not ready_corridor(w, w.trails[-1].pts, open):
		w.trails.pop_back()
		w.cost = old_cost
		StageTrails._restore_structures(w, finder, state, ctx)
		state.failure = "corridor"
		StageTrails._count_failure(state.failures, state)
		return false
	return true


static func _root(groups: Array, k: int) -> int:
	while groups[k] != k: k = groups[k]
	return k


## Меньший корень остаётся корнем: метки не зависят от порядка соединений.
static func _join(groups: Array, a: int, b: int) -> void:
	var ra := _root(groups, a)
	var rb := _root(groups, b)
	groups[maxi(ra, rb)] = mini(ra, rb)


static func _distance2(w: WorldData, a: int, b: int) -> float:
	if b < 0: return INF
	return Vector2(a % w.W - b % w.W, a / w.W - b / w.W).length_squared()


static func _nearest(w: WorldData, targets: PackedInt32Array, from: int) -> int:
	var best := -1
	var distance := INF
	for t: int in targets:
		var d := _distance2(w, from, t)
		if d < distance:
			distance = d
			best = t
	return best


## Дома, места, сооружения, деревья и камни плана: подход их обходит, а не прокладывает дорогу сквозь них.
static func _old_places(source: WorldData, bounds: Rect2i) -> PackedByteArray:
	var blocked := PackedByteArray()
	blocked.resize(bounds.get_area())
	var mark := func(x: float, y: float, r: float) -> void:
		for cy in range(floori(y - r), ceili(y + r)):
			for cx in range(floori(x - r), ceili(x + r)):
				if bounds.has_point(Vector2i(cx, cy)) and Vector2(cx + 0.5, cy + 0.5).distance_to(Vector2(x, y)) <= r:
					blocked[(cy - bounds.position.y) * bounds.size.x + cx - bounds.position.x] = 1
	for place: EntityRecord in source.settlements + source.sites:
		for hut: HutData in EntityCodec.value(place, "huts", []): mark.call(hut.x, hut.y, 1.5)
	for span: EntityRecord in source.bridges + source.tunnels:
		var a := Vector2(span.a % source.W + 0.5, span.a / source.W + 0.5)
		var b := Vector2(span.b % source.W + 0.5, span.b / source.W + 0.5)
		var steps := maxi(1, ceili(a.distance_to(b)))
		for k in steps + 1: mark.call(lerpf(a.x, b.x, float(k) / steps), lerpf(a.y, b.y, float(k) / steps), 2.0)
	# Растительность плана уже стоит: подход идёт только по свободной земле (13.9).
	var part := bounds.intersection(Rect2i(0, 0, source.W, source.H))
	if part.has_area() and source.chunks.size() == source.CW * source.CH and source.CW > 0:
		for cy in range(part.position.y / source.CS, (part.end.y - 1) / source.CS + 1):
			for cx in range(part.position.x / source.CS, (part.end.x - 1) / source.CS + 1):
				for o: int in source.chunks[cy * source.CW + cx]:
					mark.call(source.obj_x[o], source.obj_y[o], 1.0)
	return blocked


## Сторона свободна, если за ней нет области группы, закреплённой области и стартового плана.
static func _free_side(beyond: Rect2i, regions: Array, ledger: Dictionary, plan: Rect2i) -> bool:
	if beyond.intersects(plan): return false
	for region: Dictionary in regions:
		if region.rect.intersects(beyond): return false
	for key: Vector2i in ledger.get("regions", {}):
		if ledger.regions[key].rect.intersects(beyond): return false
	return true


## Ближайший к стороне узел этой области; старая сеть плана сюда не подходит.
static func _side_node(w: WorldData, nodes: Array, bounds: Rect2i, rect: Rect2i, d: Vector2i) -> int:
	var best := -1
	var distance := INF
	for k in nodes.size():
		var i: int = nodes[k].i
		if i < 0: continue
		var cell := bounds.position + Vector2i(i % w.W, i / w.W)
		if not rect.has_point(cell): continue
		var gap := float(rect.end.x - cell.x if d.x > 0 else (cell.x - rect.position.x if d.x < 0
			else (rect.end.y - cell.y if d.y > 0 else cell.y - rect.position.y)))
		if gap < distance:
			distance = gap
			best = k
	return best


## Клетка у границы напротив узла: сухая, своя, и за границей тоже сухая суша, не план.
static func _side_cell(w: WorldData, fields: Dictionary, open: PackedByteArray, bounds: Rect2i, rect: Rect2i, d: Vector2i, from: int) -> int:
	var along := Vector2i(absi(d.y), absi(d.x))
	var anchor := bounds.position + Vector2i(from % w.W, from / w.W)
	var low := rect.position.x if along.x != 0 else rect.position.y
	var high := (rect.end.x if along.x != 0 else rect.end.y) - 1
	var t := clampi(anchor.x if along.x != 0 else anchor.y, low + EXIT_MARGIN, high - EXIT_MARGIN)
	var side := Vector2i(rect.end.x - 1 if d.x > 0 else rect.position.x, rect.end.y - 1 if d.y > 0 else rect.position.y)
	for offset: int in [0, 6, -6, 12, -12]:
		var cell := side * Vector2i(absi(d.x), absi(d.y)) + along * (t + offset)
		var outside := cell + d
		if not bounds.has_point(outside): continue
		var i := (cell.y - bounds.position.y) * w.W + cell.x - bounds.position.x
		var j := (outside.y - bounds.position.y) * w.W + outside.x - bounds.position.x
		if open[i] == 0 or w.cost[i] == INF or StageTrails._wet(w, i): continue
		if fields.fixed[j] != 0 or fields.h[j] < 0.0 or fields.river[j] != 0 or fields.lake[j] != 0 or w.river[j] != 0: continue
		return i
	return -1


## Вся лента лежит на проходимых клетках; над водой разрешён только проверенный настил.
static func ready_corridor(w: WorldData, points: Array, open: PackedByteArray) -> bool:
	for k in range(1, points.size()):
		var a := Vector2(points[k - 1].x, points[k - 1].y)
		var b := Vector2(points[k].x, points[k].y)
		var normal := (b - a).normalized().orthogonal() * float(points[k].w) * 0.5
		var steps := maxi(1, ceili(a.distance_to(b) * 4.0))
		for step in range(steps + 1):
			for side: float in [-1.0, 0.0, 1.0]:
				var p := a.lerp(b, float(step) / steps) + normal * side
				var x := floori(p.x)
				var y := floori(p.y)
				if x < 0 or y < 0 or x >= w.W or y >= w.H: return false
				var i := y * w.W + x
				if open[i] == 0: return false
				if w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0:
					var on_bridge := false
					for span: BridgeData in w.bridges:
						var start := Vector2(span.a % w.W + 0.5, span.a / w.W + 0.5)
						var end := Vector2(span.b % w.W + 0.5, span.b / w.W + 0.5)
						var axis := end - start
						var t := (p - start).dot(axis) / axis.length_squared()
						if t >= 0.0 and t <= 1.0 and p.distance_to(start + axis * t) <= Heightfield.BRIDGE_HALF / GameConfig.TILE:
							on_bridge = true
							break
					if not on_bridge: return false
	return true
