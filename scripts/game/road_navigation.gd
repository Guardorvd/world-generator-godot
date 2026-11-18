extends RefCounted
## Сеть готовых дорог + ограниченные подходы по известной проходимой местности.
## Поиск по длине в метрах; без генерации дорог, мира или полного navmesh.
const Topology := preload("res://scripts/world/road_topology.gd")
const LOCAL_VISITS := 1800
const CELL := 2.0
const OFFROAD_COST := 1.5
var cancelled := false # Cooperative cancellation of superseded background searches.
var points := {}
var links := {}
var levels := {}
var searches := 0
var road_route: Array[Dictionary] = [] # directed intervals of physical sections
var road_first := 0
var road_last := -1
var complete := false
var status := ""
var _world: WorldData
var _heights: Heightfield
var _cells := {}
var _node_keys := {}
var _edges := {}
var _components := {}

func build(w: WorldData, h: Heightfield = null) -> void:
	_world = w
	_heights = h
	points.clear()
	links.clear()
	levels.clear()
	_cells.clear()
	_node_keys.clear()
	_edges.clear()
	_components.clear()
	var graph := Topology.compile(w, func() -> bool: return cancelled)
	if graph.is_empty(): return
	var structures := {}
	if h != null:
		for span: Dictionary in h.structures:
			var a := Vector2(span.ax, span.az) / GameConfig.TILE
			var b := Vector2(span.bx, span.bz) / GameConfig.TILE
			structures[Topology.passage_id(a, b, span.tunnel, w.world_origin)] = span
	for id in graph.nodes.size():
		if cancelled: return
		var node: Dictionary = graph.nodes[id]
		var at: Vector2 = node.at * GameConfig.TILE
		var y := 0.0
		if h != null:
			if node.passage.is_empty():
				y = h.ground_at(at.x, at.y)
			elif structures.has(node.passage):
				var span: Dictionary = structures[node.passage]
				y = h.level(span, (at.x - span.ax) * span.ux + (at.y - span.az) * span.uz)
			else:
				continue
		if not is_finite(y): continue
		points[id] = at
		levels[id] = y
		_node_keys[id] = node.id
		links[id] = []
		var cell := Vector2i(node.at.floor())
		if not _cells.has(cell): _cells[cell] = []
		_cells[cell].append(id)
	for edge: Dictionary in graph.edges:
		if cancelled: return
		var a: int = edge.from
		var b: int = edge.to
		var key := _edge_key(a, b)
		if _edges.has(key) or not points.has(a) or not points.has(b):
			continue
		var end := _edge_level(points[a], points[b], levels[a])
		if not is_finite(end) or absf(end - float(levels[b])) > 0.5:
			continue
		_edges[key] = edge
		links[a].append(b)
		links[b].append(a)
	for id: int in points:
		if _components.has(id): continue
		var queue: Array[int] = [id]
		_components[id] = id
		var cursor := 0
		while cursor < queue.size():
			if cancelled: return
			var current := queue[cursor]
			cursor += 1
			for next: int in links[current]:
				if not _components.has(next):
					_components[next] = id
					queue.append(next)

static func _edge_key(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


## A cell is a spatial index only. It can contain several unconnected nodes.
func component_at(cell: Vector2i, preferred := -1) -> int:
	for id: int in _cells.get(cell, []):
		var component: int = _components.get(id, -1)
		if preferred < 0 or preferred == component:
			return component
	return -1


## Компонента ближайшей к точке вершины сети (метры) или -1, если сети нет.
func component_near(at: Vector2) -> int:
	var id := nearest(at)
	return int(_components.get(id, -1)) if id >= 0 else -1


func component_cells(comp: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cell: Vector2i in _cells:
		if component_at(cell, comp) == comp:
			out.append(cell)
	return out


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
	road_route.clear()
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
		var distance := from.distance_squared_to(points[id])
		var old: int = entries.get(component, -1)
		if old < 0 or distance < from.distance_squared_to(points[old]) or (distance == from.distance_squared_to(points[old])
				and absf(feet - float(levels[id])) < absf(feet - float(levels[old]))):
			entries[component] = id
	var starts: Array = entries.values()
	starts.sort_custom(func(a: int, b: int) -> bool: return from.distance_squared_to(points[a]) < from.distance_squared_to(points[b]))
	var previous := {}
	var cost := {}
	var approaches := {}
	var heap: Array[Vector2] = []
	for id: int in starts.slice(0, 6):
		if cancelled: return PackedVector2Array()
		var approach := _connector(from, points[id], feet)
		if approach.is_empty(): continue
		if _heights != null and absf(_end_level(approach, feet) - float(levels[id])) > 0.5: continue
		cost[id] = _length(approach) * OFFROAD_COST
		previous[id] = -1
		approaches[id] = approach
		_push(heap, id, cost[id])
	# The graph is finite. Do not stop at a fixed node count when additional areas are prepared.
	while not cancelled and not heap.is_empty():
		var item := _pop(heap)
		var id := int(item.y)
		if item.x > float(cost[id]) + 0.001: continue
		for next: int in links[id]:
			var distance: float = cost[id] + points[id].distance_to(points[next])
			if not cost.has(next) or distance < float(cost[next]):
				cost[next] = distance
				previous[next] = id
				_push(heap, next, distance)
	if cancelled: return PackedVector2Array()
	var tails: Array = cost.keys()
	tails.sort_custom(func(a: int, b: int) -> bool:
		return points[a].distance_to(to) + float(cost[a]) * 0.05 < points[b].distance_to(to) + float(cost[b]) * 0.05)
	var best := -1
	var best_cost := _length(direct) * OFFROAD_COST if not direct.is_empty() else INF
	var finish := PackedVector2Array()
	for id: int in tails.slice(0, 8):
		if cancelled: return PackedVector2Array()
		if float(cost[id]) + points[id].distance_to(to) * OFFROAD_COST >= best_cost:
			continue
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
		chain.append(id)
		id = previous[id]
	chain.reverse()
	var out: PackedVector2Array = approaches[chain[0]]
	road_first = out.size() - 1
	for n in range(1, chain.size()):
		out.append(points[chain[n]])
		_append_interval(chain[n - 1], chain[n])
	road_last = out.size() - 1
	out.append_array(finish.slice(1))
	complete = true
	status = ""
	return out

## Keep stations as well as IDs so a route can traverse part of a section in either direction.
func _append_interval(a: int, b: int) -> void:
	var edge: Dictionary = _edges[_edge_key(a, b)]
	var forward: bool = edge.from == a
	var start: float = edge.from_m if forward else edge.to_m
	var end: float = edge.to_m if forward else edge.from_m
	if not road_route.is_empty():
		var last: Dictionary = road_route[-1]
		if last.section == edge.section and absf(float(last.to_m) - start) < 0.001:
			last.to_m = end
			last.to_node = _node_keys[b]
			return
	road_route.append({section = edge.section, from_node = _node_keys[a], to_node = _node_keys[b], from_m = start, to_m = end})


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
	var length := a.distance_to(b)
	var steps := maxi(1, ceili(length / 0.5))
	var max_rise := maxf(0.35, length / steps)
	var last := feet
	for i in range(0, steps + 1):
		if cancelled: return INF
		var at := a.lerp(b, float(i) / steps)
		if not _heights.known(at.x, at.y) or not _world.accessible(at.x / GameConfig.TILE, at.y / GameConfig.TILE): return INF
		var y := _heights.surface_at(at.x, at.y, last + 0.1)
		if not is_finite(y) or absf(y - last) > max_rise: return INF
		if not _passable(at, y) or not BikeRecovery.headroom(_heights, at.x, at.y, y): return INF
		last = y
	return last

## 18.11.2026: связь графа дорог при сборке — только непрерывность уровня с шагом EDGE_STEP (мост, туннель, обрыв,
## неизвестная или закрытая земля). Проходимость самого полотна обеспечивает генерация дорог; полная проверка _segment
## по 0,5 м со столкновениями на каждом метре всей сети делала первый расчёт маршрута долгим (секунды на мир 768).
## Видимую часть пути NavigationLine всё равно проверяет полностью.
const EDGE_STEP := 2.0
func _edge_level(a: Vector2, b: Vector2, feet: float) -> float:
	if _heights == null: return 0.0
	var length := a.distance_to(b)
	var steps := maxi(1, ceili(length / EDGE_STEP))
	var max_rise := maxf(0.35, length / steps)
	var last := feet
	for i in range(0, steps + 1):
		if cancelled: return INF
		var at := a.lerp(b, float(i) / steps)
		if not _heights.known(at.x, at.y) or not _world.accessible(at.x / GameConfig.TILE, at.y / GameConfig.TILE): return INF
		var y := _heights.surface_at(at.x, at.y, last + 0.1)
		if not is_finite(y) or absf(y - last) > max_rise: return INF
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
	while not cancelled and not heap.is_empty() and visits < LOCAL_VISITS:
		var item := _pop(heap)
		var id := int(item.y)
		var at := a + Vector2(positions[id]) * CELL
		if item.x > float(costs[id]) + at.distance_to(b) + 0.001: continue
		visits += 1
		if at.distance_to(b) < CELL * 1.5 and _segment(at, b, elevations[id]) < INF:
			var path := PackedVector2Array([b])
			while id != -1:
				path.append(a + Vector2(positions[id]) * CELL)
				id = previous[id]
			path.reverse()
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

## Reuse the shared settlement/site collision index and the live world's native queries.
func _passable(at: Vector2, feet: float) -> bool:
	return PlayerState.is_passable(_world, _heights, at.x, at.y, feet, 0.25, true) and _heights.depth_at(at.x, at.y, feet) < GameConfig.FORD_DEPTH
