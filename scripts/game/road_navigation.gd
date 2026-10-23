extends RefCounted
## Компактная сеть только существующих путей людей. Один узел на клетку дороги;
## связи берутся из готовых линий, а не из соседства клеток рельефа.
const MAX_VISITS := 20000
var points := {} # клетка -> точка на оси дороги в метрах
var links := {}  # клетка -> соседние клетки той же линии
var searches := 0


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


## Один BFS по небольшой дорожной сети, с пределом работы. Не прокладывает новые дороги.
func route(start: int, finish: int) -> PackedVector2Array:
	searches += 1
	if not points.has(start) or not points.has(finish):
		return PackedVector2Array()
	var previous := {start: -1}
	var queue: Array[int] = [start]
	var cursor := 0
	while cursor < queue.size() and cursor < MAX_VISITS and not previous.has(finish):
		var id := queue[cursor]
		cursor += 1
		for next: int in links[id]:
			if previous.has(next):
				continue
			previous[next] = id
			queue.append(next)
	var out := PackedVector2Array()
	if not previous.has(finish):
		return out
	var id := finish
	while id != -1:
		out.append(points[id])
		id = previous[id]
	out.reverse()
	return out
