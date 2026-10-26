extends RefCounted
## Сеть готовых дорог + ограниченные подходы по известной проходимой местности.
## Поиск по длине в метрах; без генерации дорог, мира или полного navmesh.
const MAX_VISITS := 20000
const LOCAL_VISITS := 1800
const CELL := 2.0
const OFFROAD_COST := 1.5
var points := {}
var links := {}
var levels := {}
var searches := 0
var road_first := 0
var road_last := -1
var complete := false
var status := ""
var _world: WorldData
var _heights: Heightfield
var _cells := {}
var _components := {}

func build(w: WorldData, h: Heightfield = null) -> void:
	_world = w
	_heights = h
	points.clear()
	links.clear()
	levels.clear()
	_cells.clear()
	_components.clear()
	var trails := w.trails.duplicate()
	if w.outer != null:
		trails.append_array(w.outer.get_ledger().get("trails", []))
	for trail: Dictionary in trails:
		if trail.get("kind", "animal") == "animal": continue
		var previous := -1
		var level := INF
		for p: Dictionary in trail.pts:
			var at := Vector2(p.x, p.y) * GameConfig.TILE
			if not at.is_finite():
				previous = -1
				continue
			level = h.surface_at(at.x, at.y, level) if h != null else 0.0
			# Координаты клетки независимы от ширины плана; высота различает мост и проход под ним.
			var key := Vector3i(floori(p.x), floori(p.y), roundi(level / 0.8))
			if not _cells.has(key):
				var id := points.size()
				_cells[key] = id
				points[id] = at
				levels[id] = level
				links[id] = []
			var id: int = _cells[key]
			if previous != -1 and previous != id and _segment(points[previous], at, levels[previous]) < INF:
				if not links[previous].has(id): links[previous].append(id)
				if not links[id].has(previous): links[id].append(previous)
			previous = id
	for id: int in points:
		if _components.has(id): continue
		var queue: Array[int] = [id]
		_components[id] = id
		var cursor := 0
		while cursor < queue.size():
			var current := queue[cursor]
			cursor += 1
			for next: int in links[current]:
				if not _components.has(next):
					_components[next] = id
					queue.append(next)

func nearest(at: Vector2) -> int:
	var best := -1
	var distance := INF
	for id: int in points:
		var d: float = at.distance_squared_to(points[id])
		if d < distance:
			best = id
			distance = d
	return best

func route_to(from: Vector2, to: Vector2, feet := INF) -> PackedVector2Array:
	searches += 1
	road_first = 0
	road_last = -1
	complete = false
	status = "Проход к цели не найден"
	if not from.is_finite() or not to.is_finite(): return PackedVector2Array()
	if _heights != null:
		feet = _heights.surface_at(from.x, from.y, feet)
	var direct := _connector(from, to, feet)
	if points.is_empty() or from.distance_to(to) < 12.0:
		complete = not direct.is_empty()
		status = "" if complete else status
		return direct
	# Один ближайший вход на каждую компоненту: ближайшая тупиковая дорога не запирает поиск.
	var entries := {}
	for id: int in points:
		var component: int = _components[id]
		if not entries.has(component) or from.distance_squared_to(points[id]) < from.distance_squared_to(points[entries[component]]):
			entries[component] = id
	var starts: Array = entries.values()
	starts.sort_custom(func(a: int, b: int) -> bool: return from.distance_squared_to(points[a]) < from.distance_squared_to(points[b]))
	var previous := {}
	var cost := {}
	var approaches := {}
	var heap: Array[Vector2] = []
	for id: int in starts.slice(0, 6):
		var approach := _connector(from, points[id], feet)
		if approach.is_empty(): continue
		if _heights != null and absf(_end_level(approach, feet) - float(levels[id])) > 0.5: continue
		cost[id] = _length(approach) * OFFROAD_COST
		previous[id] = -1
		approaches[id] = approach
		_push(heap, id, cost[id])
	var visits := 0
	while not heap.is_empty() and visits < MAX_VISITS:
		var item := _pop(heap)
		var id := int(item.y)
		if item.x > float(cost[id]) + 0.001: continue
		visits += 1
		for next: int in links[id]:
			var distance: float = cost[id] + points[id].distance_to(points[next])
			if not cost.has(next) or distance < float(cost[next]):
				cost[next] = distance
				previous[next] = id
				_push(heap, next, distance)
	var tails: Array = cost.keys()
	tails.sort_custom(func(a: int, b: int) -> bool:
		return points[a].distance_to(to) + float(cost[a]) * 0.05 < points[b].distance_to(to) + float(cost[b]) * 0.05)
	var best := -1
	var best_cost := _length(direct) * OFFROAD_COST if not direct.is_empty() else INF
	var finish := PackedVector2Array()
	for id: int in tails.slice(0, 8):
		var end := _connector(points[id], to, levels[id])
		if end.is_empty(): continue
		var distance: float = cost[id] + _length(end) * OFFROAD_COST
		if distance < best_cost:
			best = id
			best_cost = distance
			finish = end
	if best == -1:
		complete = not direct.is_empty()
		status = "" if complete else status
		return direct
	var chain: Array[int] = []
	var id := best
	while id != -1:
		chain.push_front(id)
		id = previous[id]
	var out: PackedVector2Array = approaches[chain[0]]
	road_first = out.size() - 1
	for n in range(1, chain.size()): out.append(points[chain[n]])
	road_last = out.size() - 1
	out.append_array(finish.slice(1))
	complete = true
	status = ""
	return out

func _length(path: PackedVector2Array) -> float:
	var distance := 0.0
	for i in range(1, path.size()): distance += path[i - 1].distance_to(path[i])
	return distance

func _end_level(path: PackedVector2Array, feet: float) -> float:
	for i in range(1, path.size()): feet = _segment(path[i - 1], path[i], feet)
	return feet

## Возвращает высоту конца или INF при стене/воде/обрыве/неизвестной территории.
func _segment(a: Vector2, b: Vector2, feet: float) -> float:
	if _heights == null: return 0.0
	var steps := maxi(1, ceili(a.distance_to(b) / 0.5))
	var last := feet
	for i in range(0, steps + 1):
		var at := a.lerp(b, float(i) / steps)
		if not _heights.known(at.x, at.y) or not _world.accessible(at.x / GameConfig.TILE, at.y / GameConfig.TILE): return INF
		var y := _heights.surface_at(at.x, at.y, last + 0.1)
		if not is_finite(y) or absf(y - last) > maxf(0.35, a.distance_to(b) / steps * 1.0): return INF
		if not PlayerState.is_passable(_world, _heights, at.x, at.y, y, 0.25) or not BikeRecovery.headroom(_heights, at.x, at.y, y): return INF
		last = y
	return last

func _connector(a: Vector2, b: Vector2, feet: float) -> PackedVector2Array:
	if _segment(a, b, feet) < INF: return PackedVector2Array([a, b])
	# Локальный обход: сетка 2 м, каждый переход дополнительно проверяется с шагом 0,5 м.
	if _heights == null or a.distance_to(b) > 160.0: return PackedVector2Array()
	var start := Vector2i.ZERO
	var offsets: Array[Vector2i] = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1), Vector2i(1,1), Vector2i(-1,1), Vector2i(1,-1), Vector2i(-1,-1)]
	var positions: Array[Vector2i] = [start]
	var ids := {start: 0}
	var costs := {0: 0.0}
	var previous := {0: -1}
	var elevations := {0: feet}
	var heap: Array[Vector2] = []
	_push(heap, 0, a.distance_to(b))
	var visits := 0
	while not heap.is_empty() and visits < LOCAL_VISITS:
		var item := _pop(heap)
		var id := int(item.y)
		var at := a + Vector2(positions[id]) * CELL
		if item.x > float(costs[id]) + at.distance_to(b) + 0.001: continue
		visits += 1
		if at.distance_to(b) < CELL * 1.5 and _segment(at, b, elevations[id]) < INF:
			var path := PackedVector2Array([b])
			while id != -1:
				path.insert(0, a + Vector2(positions[id]) * CELL)
				id = previous[id]
			return path
		for offset in offsets:
			var cell := positions[id] + offset
			var next_at := a + Vector2(cell) * CELL
			if next_at.distance_to(a) + next_at.distance_to(b) > a.distance_to(b) + 64.0: continue
			var y := _segment(at, next_at, elevations[id])
			if y == INF: continue
			if not ids.has(cell):
				ids[cell] = positions.size()
				positions.append(cell)
			var next: int = ids[cell]
			var distance: float = costs[id] + at.distance_to(next_at)
			if not costs.has(next) or distance < float(costs[next]):
				costs[next] = distance
				previous[next] = id
				elevations[next] = y
				_push(heap, next, distance + next_at.distance_to(b))
	return PackedVector2Array()

func _push(heap: Array[Vector2], id: int, cost: float) -> void:
	heap.append(Vector2(cost, id))
	var index := heap.size() - 1
	while index > 0:
		var parent := (index - 1) >> 1
		if heap[parent].x <= cost: break
		heap[index] = heap[parent]
		index = parent
	heap[index] = Vector2(cost, id)

func _pop(heap: Array[Vector2]) -> Vector2:
	var out := heap[0]
	var last := heap.pop_back() as Vector2
	if heap.is_empty(): return out
	var index := 0
	while index * 2 + 1 < heap.size():
		var child := index * 2 + 1
		if child + 1 < heap.size() and heap[child + 1].x < heap[child].x: child += 1
		if heap[child].x >= last.x: break
		heap[index] = heap[child]
		index = child
	heap[index] = last
	return out
