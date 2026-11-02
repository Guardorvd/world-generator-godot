extends RefCounted
## Trail Lab: adaptive regions, cheap route probes and corridor-based deduplication.
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const STRIDE := 32
const SAMPLE := 8
const SHAPES := [Vector2i(64, 96), Vector2i(96, 64), Vector2i(96, 128), Vector2i(128, 96), Vector2i(128, 128)]
const PROBE_STEP := 4 # world cells, 16 m
const CORRIDOR_CELL := 4 # world cells; only a corridor is reserved, never the whole rectangle
const OVERLAP := 0.45
const WATER_MAX := 0.25
var world_size := 0
var world_seed := 0
var world_h := PackedFloat32Array()
var world_wet := PackedByteArray()
var generation_input: Resource
var dry_cache := {}
var segment_cache := {}

func _init(snapshot := {}) -> void:
	world_size = snapshot.get("size", 0)
	world_seed = snapshot.get("seed", 0)
	world_h = snapshot.get("heights", PackedFloat32Array()).duplicate()
	world_wet = snapshot.get("water", PackedByteArray()).duplicate()
	if snapshot.get("input") != null:
		generation_input = preload("res://scripts/lab/trail_lab_game_input.gd").indexed_copy(snapshot.input)

var sites: Array[Dictionary] = []
var stats := {}

func find(seed_value: int) -> Array[Dictionary]:
	var started := Time.get_ticks_usec()
	dry_cache.clear()
	segment_cache.clear()
	sites = []
	var n := world_size
	stats = {looked = 0, fit = 0, probed = 0, confirmed = 0, duplicates = 0, refused = {}}
	if n <= 0 or world_h.size() != n * n or world_wet.size() != n * n:
		stats.reason = "мир не создан или повреждён"
		return sites
	var candidates: Array[Dictionary] = []
	for shape: Vector2i in SHAPES:
		for z in range(0, n - shape.y + 1, STRIDE):
			for x in range(0, n - shape.x + 1, STRIDE):
				stats.looked += 1
				var c := measure(Rect2i(Vector2i(x, z), shape))
				if not c.reason.is_empty():
					_refuse(c.reason)
					continue
				c.score += float(posmod(hash([seed_value, x, z, shape]), 1000)) * 0.00001
				c.trail_seed = posmod(hash([seed_value, x, z, shape, "line"]), 99999) + 1
				candidates.append(c)
	stats.fit = candidates.size()
	stats.measure_ms = (Time.get_ticks_usec() - started) / 1000.0
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score > b.score)
	# Share probe effort across scales; large windows must not consume the whole search budget.
	var groups := {}
	var longest := 0
	for c in candidates:
		var shape: Vector2i = c.region.size
		if not groups.has(shape): groups[shape] = []
		groups[shape].append(c)
		longest = maxi(longest, groups[shape].size())
	candidates = []
	for rank in longest:
		for shape: Vector2i in SHAPES:
			if groups.has(shape) and rank < groups[shape].size(): candidates.append(groups[shape][rank])
	# Work budget scales with the map, not the number of accepted sites. No target site count.
	var budget := maxi(64, n * n / (STRIDE * STRIDE))
	var occupied := {}
	var probe_us := 0
	var dedup_us := 0
	for c in candidates:
		if stats.probed >= budget: break
		stats.probed += 1
		var stage := Time.get_ticks_usec()
		var trial := probe(c.region)
		probe_us += Time.get_ticks_usec() - stage
		if trial.is_empty():
			_refuse("пробная прокладка не связала участок")
			continue
		stats.confirmed += 1
		stage = Time.get_ticks_usec()
		var cells := corridor(trial.points)
		var nearby := {}
		for key in cells:
			for index: int in occupied.get(key, []): nearby[index] = true
		var duplicate := false
		for index: int in nearby:
			if overlap(cells, sites[index].corridor) >= OVERLAP:
				duplicate = true
				break
		if duplicate:
			dedup_us += Time.get_ticks_usec() - stage
			stats.duplicates += 1
			continue
		var styles := capabilities(c, trial)
		if styles.is_empty():
			_refuse("нет подходящего стиля по пробной линии")
			continue
		c.merge({probe = trial, corridor = cells, styles = styles, style = styles[0], n = sites.size() + 1,
			settings = {difficulty = 0.5, modification = 0.5, mandatory_gaps = false, park_layout = "auto"}})
		var canvas := Vector2i(clampi(c.region.get_center().x - Terrain.CELLS / 2, 0, maxi(0, n - Terrain.CELLS)), clampi(c.region.get_center().y - Terrain.CELLS / 2, 0, maxi(0, n - Terrain.CELLS)))
		c.origin = canvas
		c.bounds = Rect2(Vector2(c.region.position - canvas) * GameConfig.TILE, Vector2(c.region.size) * GameConfig.TILE)
		var index := sites.size()
		sites.append(c)
		for key in cells:
			if not occupied.has(key): occupied[key] = []
			occupied[key].append(index)
		dedup_us += Time.get_ticks_usec() - stage
	stats.sites = sites.size()
	stats.budget = budget
	stats.budget_exhausted = stats.probed < candidates.size() and stats.probed >= budget
	stats.ms = (Time.get_ticks_usec() - started) / 1000.0
	stats.probe_ms = probe_us / 1000.0
	stats.dedup_ms = dedup_us / 1000.0
	stats.dry_cache_cells = dry_cache.size()
	stats.segment_cache_edges = segment_cache.size()
	if sites.is_empty(): stats.reason = "подтверждённых мест не найдено: %s" % stats.refused
	return sites

func _refuse(reason: String) -> void:
	stats.refused[reason] = int(stats.refused.get(reason, 0)) + 1

func measure(region: Rect2i) -> Dictionary:
	var n := world_size
	var low := INF
	var high := -INF
	var water := 0
	var count := 0
	var steep := 0
	var gentle := 0
	var sum := 0.0
	for z in range(region.position.y + SAMPLE, region.end.y - SAMPLE, SAMPLE):
		for x in range(region.position.x + SAMPLE, region.end.x - SAMPLE, SAMPLE):
			var i := z * n + x
			count += 1
			if world_wet[i] != 0:
				water += 1
				continue
			var h := world_h[i]
			low = minf(low, h)
			high = maxf(high, h)
			var g := Vector2(world_h[i + SAMPLE] - h, world_h[i + SAMPLE * n] - h).length() / (SAMPLE * GameConfig.TILE)
			sum += g
			steep += int(g > 0.7)
			gentle += int(g < 0.10)
	var dry := maxi(1, count - water)
	var r := {region = region, reason = "", fall = high - low, slope = sum / dry, gentle = float(gentle) / dry, water = float(water) / maxi(1, count)}
	if count < 10 or r.water > WATER_MAX: r.reason = "вода"
	elif float(steep) / dry > 0.3: r.reason = "кручи"
	elif not is_finite(r.fall): r.reason = "нет сухого рельефа"
	r.score = 1.0 + minf(r.fall / 100.0, 1.0) + r.gentle * 0.3 - r.water * 3.0 - float(steep) / dry * 2.0
	return r

## A bounded A* over terrain only. No composition, shaping, terrain mutation or physics objects.
func probe(region: Rect2i) -> Dictionary:
	var n := world_size
	var nodes := {}
	var first := region.position + Vector2i(8, 8)
	for z in range(first.y, region.end.y - 8, PROBE_STEP):
		for x in range(first.x, region.end.x - 8, PROBE_STEP):
			var p := Vector2i(x, z)
			if _dry(p): nodes[p] = world_h[z * n + x]
	if nodes.size() < 16: return {}
	var keys := nodes.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return nodes[a] > nodes[b] if nodes[a] != nodes[b] else (a.y * n + a.x < b.y * n + b.x))
	var start: Vector2i = keys[0]
	var goal: Vector2i = start
	var best := -INF
	for p: Vector2i in keys:
		var distance := Vector2(p - start).length()
		var score := distance + (float(nodes[start]) - float(nodes[p])) * 0.4
		if score > best: best = score; goal = p
	var open: Array[Vector2i] = [start]
	var cost := {start: 0.0}
	var previous := {}
	var visited := {}
	var expansions := 0
	while not open.is_empty() and expansions < 768:
		var chosen := 0
		var rank := INF
		for k in open.size():
			var p := open[k]
			var f := float(cost[p]) + Vector2(p - goal).length() * GameConfig.TILE
			if f < rank: chosen = k; rank = f
		var p := open[chosen]
		open.remove_at(chosen)
		if visited.has(p): continue
		visited[p] = true
		expansions += 1
		if p == goal:
			var path := PackedVector2Array([Vector2(goal) * GameConfig.TILE])
			while p != start:
				p = previous[p]
				path.append(Vector2(p) * GameConfig.TILE)
			path.reverse()
			var length := 0.0
			var peak := 0.0
			var straight := 0.0
			for k in range(1, path.size()):
				var span := path[k].distance_to(path[k - 1])
				length += span
				var a := Vector2i((path[k - 1] / GameConfig.TILE).round())
				var b := Vector2i((path[k] / GameConfig.TILE).round())
				peak = maxf(peak, absf(float(nodes[a]) - float(nodes[b])) / span)
				if k < 2 or absf((path[k] - path[k - 1]).angle_to(path[k - 1] - path[k - 2])) < 0.15: straight += span
			if length < 140.0: return {}
			return {points = path, length = length, drop = float(nodes[start]) - float(nodes[goal]), peak_grade = peak, straight_share = straight / length, expanded = expansions}
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0: continue
				var q := p + Vector2i(dx, dz) * PROBE_STEP
				if not nodes.has(q) or visited.has(q): continue
				var span := Vector2(q - p).length() * GameConfig.TILE
				var grade := (float(nodes[q]) - float(nodes[p])) / span
				if grade > 0.10 or grade < -0.45 or not _segment_dry(p, q): continue
				var next := float(cost[p]) + span * (1.0 + absf(grade + 0.07) * 2.0 + maxf(grade, 0.0) * 8.0)
				if next >= float(cost.get(q, INF)): continue
				cost[q] = next
				previous[q] = p
				open.append(q)
	return {}

func _dry(p: Vector2i) -> bool:
	var n := world_size
	var key := p.y * n + p.x
	if dry_cache.has(key): return dry_cache[key]
	for offset in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var q: Vector2i = p + offset
		if q.x < 0 or q.y < 0 or q.x >= n or q.y >= n or world_wet[q.y * n + q.x] != 0:
			dry_cache[key] = false
			return false
		if generation_input != null and generation_input.blocked(Vector2(q) * GameConfig.TILE):
			dry_cache[key] = false
			return false
	dry_cache[key] = true
	return true

func _segment_dry(a: Vector2i, b: Vector2i) -> bool:
	var ai := a.y * world_size + a.x
	var bi := b.y * world_size + b.x
	var key := mini(ai, bi) * world_size * world_size + maxi(ai, bi)
	if segment_cache.has(key): return segment_cache[key]
	var steps := maxi(absi(b.x - a.x), absi(b.y - a.y))
	for i in steps + 1:
		if not _dry(Vector2i(Vector2(a).lerp(Vector2(b), float(i) / maxi(1, steps)).round())):
			segment_cache[key] = false
			return false
	segment_cache[key] = true
	return true

func capabilities(c: Dictionary, trial: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var grade := float(trial.drop) / float(trial.length)
	if c.gentle >= 0.65 and trial.peak_grade < 0.16 and minf(c.region.size.x, c.region.size.y) >= 64: result.append("park")
	if grade >= 0.025 and grade <= 0.14 and trial.straight_share > 0.35: result.append("flow")
	if grade >= 0.08 and trial.peak_grade >= 0.14: result.append("downhill")
	if grade >= 0.025 and trial.peak_grade <= 0.4: result.append("enduro")
	if c.slope >= 0.08 and trial.peak_grade <= 0.4: result.append("tech")
	return result

func corridor(points: PackedVector2Array) -> Dictionary:
	var result := {}
	for k in range(1, points.size()):
		var steps := maxi(1, ceili(points[k].distance_to(points[k - 1]) / (GameConfig.TILE * CORRIDOR_CELL * 0.5)))
		for j in steps + 1:
			var p := points[k - 1].lerp(points[k], float(j) / steps) / (GameConfig.TILE * CORRIDOR_CELL)
			var key := Vector2i(p.floor())
			for dz in range(-1, 2):
				for dx in range(-1, 2): result[key + Vector2i(dx, dz)] = true
	return result

func overlap(a: Dictionary, b: Dictionary) -> float:
	var shared := 0
	for key in a:
		if b.has(key): shared += 1
	return float(shared) / maxi(1, mini(a.size(), b.size()))
