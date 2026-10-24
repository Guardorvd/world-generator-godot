extends RefCounted
## 11.0: выбираем место отдельным RNG, затем ближайшую готовую дорогу/тропу.
## Используем уже проложенную линию, без нового поиска маршрутов и проверок коридора.
const SPEED := 3.0


static func choose(w: WorldData, h: Heightfield, rng: RandomNumberGenerator) -> Dictionary:
	var kinds: Array = WorldData.PLACE_KINDS.duplicate()
	_shuffle(kinds, rng)
	for kind: String in kinds:
		var places: Array = w.get(kind + "s").duplicate()
		_shuffle(places, rng)
		for src: Variant in places:
			var center := Vector2(src.sx, src.sy) if kind == "lake" else Vector2(src.x, src.y)
			center *= GameConfig.TILE
			if not w.accessible(center.x / GameConfig.TILE, center.y / GameConfig.TILE):
				continue
			var best := INF
			var route: Array = []
			var index := 0
			for trail: Dictionary in w.trails:
				if trail.kind == "animal":
					continue
				for i in range(1, trail.pts.size() - 1):
					var p := Vector2(trail.pts[i].x, trail.pts[i].y) * GameConfig.TILE
					var distance := p.distance_squared_to(center)
					if distance < best and w.accessible(p.x / GameConfig.TILE, p.y / GameConfig.TILE, 2.0):
						best = distance
						route = trail.pts
						index = i
			# Старт действительно рядом с выбранным местом, а не на другом конце карты.
			if route.is_empty() or best > 160.0 * 160.0:
				continue
			var direction := 1 if index < route.size() / 2 else -1
			var points: Array[Vector2] = []
			var length := 0.0
			var cursor := index
			while cursor >= 0 and cursor < route.size():
				var point := Vector2(route[cursor].x, route[cursor].y) * GameConfig.TILE
				if not points.is_empty():
					length += point.distance_to(points[-1])
				points.append(point)
				if length >= 26.0:
					break
				cursor += direction
			if points.size() < 2:
				continue
			var forward := points[1] - points[0]
			var at := Vector3(points[0].x, h.surface_at(points[0].x, points[0].y, INF), points[0].y)
			return {position = at, heading = atan2(-forward.x, -forward.y), points = points,
				place = w.place(WorldData.place_id(kind, src.x, src.y)), cinematic = length >= 18.0}
	return {}


static func _shuffle(items: Array, rng: RandomNumberGenerator) -> void:
	for i in range(items.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var item: Variant = items[i]
		items[i] = items[j]
		items[j] = item
