extends RefCounted
## Trail Lab: adaptive regions, cheap route probes and corridor-based deduplication.
const CANVAS_CELLS := 128
const STRIDE := 32
const SAMPLE := 8
const SHAPES := [Vector2i(64, 96), Vector2i(96, 64), Vector2i(96, 128), Vector2i(128, 96), Vector2i(128, 128)]
const PROBE_STEP := 4 # world cells, 16 m
const CORRIDOR_CELL := 4 # world cells; only a corridor is reserved, never the whole rectangle
const OVERLAP := 0.45
var world_size := 0
var world_seed := 0
var world_h := PackedFloat32Array()
var world_wet := PackedByteArray()
var generation_input: Resource
var dry_cache := {}
var segment_cache := {}
var tread_cache := {}
var endpoint_cache := {}
const Contract := preload("res://scripts/trails/trail_route_contract.gd")
const PROBE_WIDTH := 4.5
const PAIR_BUDGET := 768

var options := {}

func _init(snapshot := {}, limits := {}) -> void:
	options = limits
	world_size = snapshot.get("size", 0)
	world_seed = snapshot.get("seed", 0)
	world_h = snapshot.get("heights", PackedFloat32Array()).duplicate()
	world_wet = snapshot.get("water", PackedByteArray()).duplicate()
	if snapshot.get("input") != null:
		generation_input = preload("res://scripts/trails/trail_indexed_input.gd").indexed_copy(snapshot.input)

var sites: Array[Dictionary] = []
var stats := {}

func find(seed_value: int, publish := Callable(), cancelled := Callable()) -> Array[Dictionary]:
	var started := Time.get_ticks_usec()
	sites = []
	stats = {looked = 0, fit = 0, probed = 0, confirmed = 0, duplicates = 0, refused = {}, first_proposal_ms = null}
	if world_size <= 0 or world_h.size() != world_size * world_size or world_wet.size() != world_h.size():
		stats.reason = "мир не создан или повреждён"
		return sites
	var atlas := preload("res://scripts/trails/trail_coarse_map.gd").new()
	atlas.prepare(world_size, _ground, world_wet, generation_input)
	stats.overview_ms = (Time.get_ticks_usec() - started) / 1000.0
	stats.overview_cells = atlas.heights.size()
	var anchors := atlas.anchors(seed_value, options.get("rideable", false))
	stats.looked = anchors.size()
	var area: Rect2i = options.get("area", Rect2i(0, 0, world_size, world_size))
	anchors = anchors.filter(func(anchor: int) -> bool: return area.has_point(Vector2i(atlas.point(anchor) / GameConfig.TILE)))
	var budget := int(options.get("probe_budget", maxi(64, world_size * world_size / (STRIDE * STRIDE))))
	var occupied := {}
	for anchor: int in anchors:
		if stats.probed >= budget or _stopped(cancelled): break
		stats.probed += 1
		var c := atlas.trace(anchor, seed_value, options.get("corridor", {}))
		if c.is_empty():
			_refuse("нет протяжённого свободного коридора")
			continue
		if not area.encloses(c.region):
			_refuse("коридор выходит за подготовленную область")
			continue
		stats.fit += 1; stats.confirmed += 1
		var cells := corridor(c.probe.points)
		var nearby := {}
		for key in cells:
			for index: int in occupied.get(key, []): nearby[index] = true
		var duplicate := false
		for index: int in nearby:
			if overlap(cells, sites[index].corridor) >= OVERLAP: duplicate = true; break
		if duplicate:
			stats.duplicates += 1
			continue
		var styles := capabilities(c, c.probe)
		c.merge({corridor = cells, styles = styles, style = styles[0], n = sites.size() + 1,
			trail_seed = posmod(hash([seed_value, anchor, c.feature]), 99999) + 1,
			settings = {difficulty = 0.5, modification = 0.5, mandatory_gaps = false, park_layout = "auto"}})
		var n := world_size
		c.origin = Vector2i(clampi(c.region.get_center().x - CANVAS_CELLS / 2, 0, maxi(0, n - CANVAS_CELLS)), clampi(c.region.get_center().y - CANVAS_CELLS / 2, 0, maxi(0, n - CANVAS_CELLS)))
		c.bounds = Rect2(Vector2(c.region.position - c.origin) * GameConfig.TILE, Vector2(c.region.size) * GameConfig.TILE)
		var index := sites.size()
		sites.append(c)
		for key in cells:
			if not occupied.has(key): occupied[key] = []
			occupied[key].append(index)
		if stats.first_proposal_ms == null: stats.first_proposal_ms = (Time.get_ticks_usec() - started) / 1000.0
		if publish.is_valid(): publish.call(c)
	stats.sites = sites.size(); stats.budget = budget
	stats.budget_exhausted = stats.probed < anchors.size() and (stats.probed >= budget or _stopped(cancelled))
	stats.ms = (Time.get_ticks_usec() - started) / 1000.0
	stats.probe_ms = stats.ms - stats.overview_ms
	stats.measure_ms = stats.overview_ms
	stats.detailed_probes = 0
	if sites.is_empty(): stats.reason = "свободных коридоров не найдено"
	return sites

func _stopped(cancelled: Callable) -> bool:
	return Time.get_ticks_msec() >= int(options.get("deadline", 9223372036854775807)) or (cancelled.is_valid() and cancelled.call())

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
	if count < 10 or water == count: r.reason = "вода"
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
			if _dry(p): nodes[p] = _ground(Vector2(p) * GameConfig.TILE)
	if nodes.size() < 16: return {}
	var keys := nodes.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return nodes[a] > nodes[b] if nodes[a] != nodes[b] else (a.y * n + a.x < b.y * n + b.x))
	# Several spatially separated starts and finishes, under one expansion budget.
	var component := {}
	var component_id := 0
	for root: Vector2i in keys:
		if component.has(root): continue
		component_id += 1
		var queue: Array[Vector2i] = [root]
		component[root] = component_id
		var cursor := 0
		while cursor < queue.size():
			var p := queue[cursor]; cursor += 1
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var q := p + Vector2i(dx, dz) * PROBE_STEP
					if nodes.has(q) and not component.has(q):
						component[q] = component_id
						queue.append(q)
	var endpoint_bounds := _construction_bounds(region).grow(-PROBE_WIDTH * 0.5 - 2)
	var starts: Array[Vector2i] = []
	for p: Vector2i in keys:
		var at := Vector2(p) * GameConfig.TILE
		if not endpoint_bounds.has_point(at): continue
		var separate := true
		for q in starts:
			if Vector2(p - q).length() < 24: separate = false
		if separate: starts.append(p)
		if starts.size() >= 3: break
	var pairs := []
	for start in starts:
		var goals := keys.filter(func(p: Vector2i) -> bool: return component[p] == component[start] and endpoint_bounds.has_point(Vector2(p) * GameConfig.TILE))
		goals.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return Vector2(a - start).length() + (float(nodes[start]) - float(nodes[a])) * 0.4 > Vector2(b - start).length() + (float(nodes[start]) - float(nodes[b])) * 0.4)
		var selected: Array[Vector2i] = []
		for goal: Vector2i in goals.slice(0, 32):
			if goal == start: continue
			var tangent := Vector2(goal - start).normalized()
			if not _endpoint(start, tangent, region).suitable or not _endpoint(goal, tangent, region).suitable: continue
			var separate := true
			for q in selected:
				if Vector2(goal - q).length() < 16: separate = false
			if not separate: continue
			selected.append(goal)
			pairs.append([start, goal])
			if selected.size() >= 2: break
	var best := {}
	var used := 0
	var tested := 0
	var successes := 0
	for pair in pairs:
		if used >= PAIR_BUDGET: break
		var trial := _probe_pair(nodes, pair[0], pair[1], mini(256, PAIR_BUDGET - used))
		used += int(trial.get("expanded", 0))
		tested += 1
		if not trial.has("points"): continue
		var path: PackedVector2Array = trial.points
		trial.start_area = _endpoint(pair[0], (path[1] - path[0]).normalized(), region)
		trial.finish_area = _endpoint(pair[1], (path[-1] - path[-2]).normalized(), region)
		if not trial.start_area.suitable or not trial.finish_area.suitable: continue
		if best.is_empty() or trial.build_cost < best.build_cost: best = trial
		successes += 1
		if successes >= 2: break
	if best.is_empty(): return {}
	best.pairs_tested = tested
	best.expanded = used
	return best

func _probe_pair(nodes: Dictionary, start: Vector2i, goal: Vector2i, budget: int) -> Dictionary:
	var open: Array[Dictionary] = []
	_heap_push(open, {point = start, rank = _estimate(nodes, start, goal), serial = 0, cost = 0.0})
	var serial := 0
	var cost := {start: 0.0}
	var previous := {}
	var visited := {}
	var expansions := 0
	while not open.is_empty() and expansions < budget:
		var entry := _heap_pop(open)
		var p: Vector2i = entry.point
		if float(entry.cost) != float(cost[p]): continue
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
			return {points = path, length = length, drop = float(nodes[start]) - float(nodes[goal]), peak_grade = peak, straight_share = straight / length, expanded = expansions, build_cost = float(cost[goal]) / length}
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0: continue
				var q := p + Vector2i(dx, dz) * PROBE_STEP
				if not nodes.has(q) or visited.has(q): continue
				var span := Vector2(q - p).length() * GameConfig.TILE
				var grade := (float(nodes[q]) - float(nodes[p])) / span
				if not _segment_dry(p, q): continue
				var tread := _tread(p, q)
				if not tread.suitable: continue
				var next := float(cost[p]) + span * (1.0 + absf(grade + 0.07) * 2.0 + maxf(grade, 0.0) * 8.0 + float(tread.work) * 2.0)
				if next >= float(cost.get(q, INF)): continue
				cost[q] = next
				previous[q] = p
				serial += 1
				_heap_push(open, {point = q, rank = next + _estimate(nodes, q, goal), serial = serial, cost = next})
	return {expanded = expansions}

func _estimate(nodes: Dictionary, p: Vector2i, goal: Vector2i) -> float:
	var remaining := Vector2(p - goal).length() * GameConfig.TILE
	var rise := float(nodes[goal]) - float(nodes[p])
	return remaining + maxf(0, rise + remaining * 0.07) * 2 + maxf(0, rise) * 8

func _heap_less(a: Dictionary, b: Dictionary) -> bool:
	return a.rank < b.rank or (a.rank == b.rank and a.serial < b.serial)

func _heap_push(heap: Array[Dictionary], value: Dictionary) -> void:
	heap.append(value)
	var i := heap.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if not _heap_less(heap[i], heap[parent]): break
		var swap := heap[i]; heap[i] = heap[parent]; heap[parent] = swap
		i = parent

func _heap_pop(heap: Array[Dictionary]) -> Dictionary:
	var result := heap[0]
	var last: Dictionary = heap.pop_back()
	if heap.is_empty(): return result
	heap[0] = last
	var i := 0
	while i * 2 + 1 < heap.size():
		var child := i * 2 + 1
		if child + 1 < heap.size() and _heap_less(heap[child + 1], heap[child]): child += 1
		if not _heap_less(heap[child], heap[i]): break
		var swap := heap[i]; heap[i] = heap[child]; heap[child] = swap
		i = child
	return result

func _ground(p: Vector2) -> float:
	if generation_input != null: return generation_input.ground(p)
	var cell := Vector2i((p / GameConfig.TILE).round()).clamp(Vector2i.ZERO, Vector2i.ONE * (world_size - 1))
	return world_h[cell.y * world_size + cell.x]

func _construction_bounds(region: Rect2i) -> Rect2:
	return Rect2(Vector2(region.position) * GameConfig.TILE, Vector2(region.size) * GameConfig.TILE).grow(-4).intersection(Rect2(Vector2.ONE * 28, Vector2.ONE * (world_size * GameConfig.TILE - 56)))

func _endpoint(p: Vector2i, tangent: Vector2, region: Rect2i) -> Dictionary:
	# Quantised orientation is a cheap feasibility estimate; the builder checks the exact tangent.
	var direction := roundi(tangent.angle() / (PI / 8))
	var key := Vector3i(p.x, p.y, direction)
	# Clearance depends on this region; cache only the terrain/earthwork calculation globally.
	var heading := Vector2.from_angle(direction * PI / 8)
	var at := Vector2(p) * GameConfig.TILE
	var bounds := _construction_bounds(region)
	var side := heading.orthogonal() * (PROBE_WIDTH * 0.5 + 2)
	for along: float in [-6.0, 12.0]:
		if not bounds.has_point(at + heading * along - side) or not bounds.has_point(at + heading * along + side): return {suitable = false}
	if endpoint_cache.has(key): return endpoint_cache[key]
	var result := Contract.endpoint(at, heading, _ground, func(point: Vector2) -> bool:
		if generation_input != null: return not generation_input.blocked(point)
		return _dry(Vector2i((point / GameConfig.TILE).round())), PROBE_WIDTH)
	endpoint_cache[key] = result
	return result

func _tread(a: Vector2i, b: Vector2i) -> Dictionary:
	var ai := a.y * world_size + a.x
	var bi := b.y * world_size + b.x
	var key := mini(ai, bi) * world_size * world_size + maxi(ai, bi)
	if tread_cache.has(key): return tread_cache[key]
	var from := Vector2(a) * GameConfig.TILE
	var to := Vector2(b) * GameConfig.TILE
	var side := (to - from).normalized().orthogonal()
	var work := 0.0
	var suitable := true
	var steps := maxi(1, ceili(from.distance_to(to) / 8.0))
	for k in steps + 1:
		var at := from.lerp(to, float(k) / steps)
		var h := _ground(at)
		for offset: float in [-PROBE_WIDTH * 0.5 - 2.0, PROBE_WIDTH * 0.5 + 2.0]:
			var edge := at + side * offset
			if generation_input != null and generation_input.blocked(edge): suitable = false
			elif generation_input == null and not _dry(Vector2i((edge / GameConfig.TILE).round())): suitable = false
			var delta := absf(_ground(edge) - h)
			work = maxf(work, delta)
	var result := {suitable = suitable, work = work}
	tread_cache[key] = result
	return result

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
	# Terrain suggests an order, not permission to build a character. Shaping and
	# the final ride check decide whether the requested result works.
	if result.is_empty(): result.append("tech")
	for character: String in ["flow", "downhill", "enduro", "tech", "park"]:
		if character not in result: result.append(character)
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
