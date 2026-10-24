extends RefCounted
## 13.6: дороги и мосты общей группы подготовленных областей, без публикации в сцену.
## Группа не больше 4 областей. Разрывы и места, требующие сооружений, возвращаются явно.
const Places := preload("res://scripts/world/region_settlements.gd")
const RegionalGround := preload("res://scripts/world/region_road_heightfield.gd")
const MAX_CELLS := 4 * 260 * 260


static func prepare(source: WorldData, regions: Array, batch: Dictionary) -> Dictionary:
	if not batch.get("ready", false) or regions.is_empty():
		return {ready = false, reason = "water_not_ready", trails = [], settlements = []}
	var bounds: Rect2i = regions[0].sample_rect
	for region: Dictionary in regions: bounds = bounds.merge(region.sample_rect)
	if bounds.get_area() > MAX_CELLS or regions.size() > 4:
		return {ready = false, reason = "batch_too_large", trails = [], settlements = []}
	# Фиксированный порядок копирования и центров: порядок загрузки не меняет сеть.
	var order: Array = range(regions.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		var p: Vector2i = regions[a].rect.position
		var q: Vector2i = regions[b].rect.position
		return p.y < q.y or p.y == q.y and p.x < q.x)
	var fields := {}
	for name: String in regions[0].fields:
		var values: Variant = regions[0].fields[name].duplicate()
		values.resize(bounds.get_area())
		values.fill(0)
		fields[name] = values
	fields.fixed.fill(1)
	var surface := {ready = true, h = fields.h.duplicate(), river = fields.river.duplicate(), water_level = fields.water_level.duplicate()}
	surface.water_level.fill(-INF)
	var covered := PackedByteArray()
	covered.resize(bounds.get_area())
	var settlements: Array = []
	for n: int in order:
		var region: Dictionary = regions[n]
		for y in range(region.sample_rect.position.y, region.sample_rect.end.y):
			for x in range(region.sample_rect.position.x, region.sample_rect.end.x):
				var dst := (y - bounds.position.y) * bounds.size.x + x - bounds.position.x
				var src: int = (y - region.sample_rect.position.y) * region.sample_rect.size.x + x - region.sample_rect.position.x
				for name: String in fields: fields[name][dst] = region.fields[name][src]
				for name: String in ["h", "river", "water_level"]: surface[name][dst] = batch.surfaces[n][name][src]
				if region.rect.has_point(Vector2i(x, y)): covered[dst] = 1
		settlements.append_array(batch.settlements[n].duplicate(true))
	settlements.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.id < b.id)
	var merged := {rect = bounds, sample_rect = bounds, fields = fields}
	var w := Places.local_world(source, merged, surface)
	w.cost.resize(w.N)
	for i in w.N:
		var wet := w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0
		w.cost[i] = INF if covered[i] == 0 or fields.fixed[i] != 0 else (StageTrails.BRIDGE_COST if wet else Biomes.LIST[w.biome[i]].get("cost", 2.0) + w.slope[i] * 7.0)
	for place: Dictionary in settlements:
		var s: Dictionary = place.duplicate(true)
		s.x -= bounds.position.x
		s.y -= bounds.position.y
		s.i = floori(s.y) * w.W + floori(s.x)
		s.huts = []
		w.settlements.append(s)
	var ground := RegionalGround.new(w, surface.water_level)
	var state := {detour = false, on_axis = PackedByteArray(), surface = ground}
	state.on_axis.resize(w.N)
	var heights := ground.hv.duplicate()
	for i in heights.size():
		# Поиск переправы оценивает воду, а не уклон спуска на дно.
		if StageTrails._wet(w, i): heights[i] = maxf(heights[i], ground.water_level[i])
		heights[i] /= GameConfig.TILE
	var finder := Pathfinder.new(w.W, w.H, heights)
	StageTrails._route_surface(finder, ground, StageTrails.WIDTHS.road)
	# Один суммарный бюджет на группу, включая неудачные направления.
	finder.search_budget = w.N * 4
	var pairs: Array = []
	for a in settlements.size():
		for b in range(a + 1, settlements.size()):
			pairs.append([Vector2(settlements[a].x, settlements[a].y).distance_squared_to(Vector2(settlements[b].x, settlements[b].y)), a, b])
	pairs.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] or a[0] == b[0] and (a[1] < b[1] or a[1] == b[1] and a[2] < b[2]))
	var groups: Array = range(settlements.size())
	var edges: Array = []
	var attempts := 0
	for pair: Array in pairs:
		var a: int = pair[1]
		var b: int = pair[2]
		if groups[a] == groups[b]: continue
		if finder.search_budget <= 0 or attempts >= maxi(1, settlements.size() * 3): break
		attempts += 1
		var checkpoint := StageTrails._make_checkpoint(w, finder, state)
		var ctx := {checkpoint = checkpoint, initial_detour = state.detour, initial_links_empty = finder.links.is_empty()}
		var path := StageTrails._connect_settlement(w, finder, w.cost, w.settlements[a].i, w.settlements[b].i, state)
		if path.size() < 2: continue
		# Туннели требуют отдельной подготовки рельефа; этот этап допускает только мосты.
		if not w.tunnels.is_empty():
			StageTrails._restore_structures(w, finder, state, ctx)
			continue
		var old_cost := w.cost.duplicate()
		StageTrails._add_trail(w, path, "road", PackedFloat32Array(), state.on_axis, ground)
		if not ready_corridor(w, w.trails[-1].pts, covered, fields.fixed):
			w.trails.pop_back()
			w.cost = old_cost
			StageTrails._restore_structures(w, finder, state, ctx)
			continue
		edges.append({from = settlements[a].id, to = settlements[b].id})
		var old: int = groups[b]
		for i in groups.size():
			if groups[i] == old: groups[i] = groups[a]
	finder.release()
	# Повторить штатную расстановку вдоль получившихся улиц; входные дома не меняются.
	StageLandmarks.lay_out(w)
	StageTrails._clear_huts(w)
	RoadSurface.run(w)
	var out_places: Array = []
	for s: Dictionary in w.settlements:
		s.x += bounds.position.x
		s.y += bounds.position.y
		s.erase("i")
		s.connections = []
		for edge: Dictionary in edges:
			if edge.from == s.id: s.connections.append(edge.to)
			elif edge.to == s.id: s.connections.append(edge.from)
		for hut: Dictionary in s.huts:
			hut.x += bounds.position.x
			hut.y += bounds.position.y
		out_places.append(s)
	for trail: Dictionary in w.trails:
		for p: Dictionary in trail.pts:
			p.x += bounds.position.x
			p.y += bounds.position.y
	var bridges: Array = []
	for span: Dictionary in w.bridges:
		bridges.append({a = Vector2(span.a % w.W + 0.5, span.a / w.W + 0.5) + Vector2(bounds.position),
			b = Vector2(span.b % w.W + 0.5, span.b / w.W + 0.5) + Vector2(bounds.position)})
	var components := {}
	for group: int in groups: components[group] = true
	return {ready = components.size() <= 1, reason = "" if components.size() <= 1 else "disconnected_routes",
		trails = w.trails, bridges = bridges, settlements = out_places, connections = edges, components = components.size(), attempts = attempts,
		sample_rect = bounds, path_mask = w.path_mask, road_surface = w.road_surface}


## Вся лента лежит в готовой области; над водой разрешён только проверенный настил.
static func ready_corridor(w: WorldData, points: Array, covered: PackedByteArray, fixed: PackedByteArray) -> bool:
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
				if covered[i] == 0 or fixed[i] != 0: return false
				if w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0:
					var on_bridge := false
					for span: Dictionary in w.bridges:
						var start := Vector2(span.a % w.W + 0.5, span.a / w.W + 0.5)
						var end := Vector2(span.b % w.W + 0.5, span.b / w.W + 0.5)
						var axis := end - start
						var t := (p - start).dot(axis) / axis.length_squared()
						if t >= 0.0 and t <= 1.0 and p.distance_to(start + axis * t) <= Heightfield.BRIDGE_HALF / GameConfig.TILE:
							on_bridge = true
							break
					if not on_bridge: return false
	return true
