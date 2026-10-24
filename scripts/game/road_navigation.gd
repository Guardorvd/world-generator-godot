extends RefCounted
## Компактная сеть только существующих путей людей. Один узел на клетку дороги;
## связи берутся из готовых линий, а не из соседства клеток рельефа.
## 14.9: путь всегда доходит до цели. По дорогам — до ближайшей достижимой к цели точки,
## последний участок — по прямой; игрок вне дорог — сначала по прямой к ближайшему узлу.
const MAX_VISITS := 20000
var points := {} # клетка -> точка на оси дороги в метрах
var links := {}  # клетка -> соседние клетки той же линии
var searches := 0
var road_first := 0 # индекс первой дорожной точки в последнем маршруте
var road_last := -1  # индекс последней; дорожных отрезков нет при road_last <= road_first


func build(w: WorldData) -> void:
	for trail: Dictionary in w.trails:
		if trail.kind == "animal":
			continue
		var previous := -1
		for p: Dictionary in trail.pts:
			var id := floori(p.y) * w.W + floori(p.x)
			if not points.has(id):
				points[id] = Vector2(p.x, p.y) * GameConfig.TILE
				links[id] = []
			if previous != -1 and previous != id:
				if not links[previous].has(id):
					links[previous].append(id)
				if not links[id].has(previous):
					links[id].append(previous)
			previous = id


func nearest(at: Vector2) -> int:
	var best := -1
	var distance := INF
	for id: int in points:
		var d := at.distance_squared_to(points[id])
		if d < distance:
			best = id
			distance = d
	return best


## Маршрут от игрока к цели: по дорогам до ближайшей к цели достижимой точки, дальше — по прямой.
## Если дорог нет вовсе, ведёт по прямой. Один поиск в ширину, новых дорог не прокладывает.
## Границы дорожной части результата остаются в road_first и road_last.
func route_to(from: Vector2, to: Vector2) -> PackedVector2Array:
	searches += 1
	road_first = 0
	road_last = -1
	var out := PackedVector2Array([from])
	var start := nearest(from)
	if start == -1:
		out.append(to)
		return out
	var finish := nearest(to)
	var previous := {start: -1}
	var queue: Array[int] = [start]
	var cursor := 0
	var tail := start
	var closest: float = points[start].distance_squared_to(to)
	while cursor < queue.size() and cursor < MAX_VISITS:
		var node := queue[cursor]
		cursor += 1
		if node == finish:
			tail = finish
			break
		var d: float = points[node].distance_squared_to(to)
		if d < closest:
			closest = d
			tail = node
		for next: int in links[node]:
			if previous.has(next):
				continue
			previous[next] = node
			queue.append(next)
	var chain: Array[Vector2] = []
	var id := tail
	while id != -1:
		chain.append(points[id])
		id = int(previous[id])
	chain.reverse()
	out.append_array(chain)
	road_first = 1 # out[0] — место игрока, дальше цепочка дорожных точек
	road_last = chain.size()
	if out[out.size() - 1].distance_squared_to(to) > 1.0:
		out.append(to)
	return out
