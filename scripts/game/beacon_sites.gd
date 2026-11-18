extends RefCounted
## Точки задания подбираются у готовой дорожной сети при открытии доски.

const COUNT := 3
const TILE := GameConfig.TILE
## 18.11.2026: точки дальше от доски (было 26–105 клеток — маяки ставили почти у деревни); сторона — по prefer
## (Quests.prefer: не назад по своим следам и не по изъезженному), дальность первой точки — около IDEAL
## Кольца [от, до] клеток от доски: сначала дальнее (240–680 м), если там не сложился треугольник — прежнее ближнее
const RINGS := [Vector3(60.0, 170.0, 95.0), Vector3(26.0, 105.0, 26.0)] # от, до, желаемая дальность первой точки
const ROAD_SAMPLE := 8.0
const OFFSETS := [6.0, 10.0] # 24–40 м от оси пути
const REACH := 3.0 # м для установки
const NO_CELL := Vector2i(-1, -1)


static func route(w: WorldData, heights: Heightfield, here: Dictionary, occupied: Dictionary, prefer := Callable()) -> Array[Vector2i]:
	if heights == null or w.path_mask.size() != w.N:
		return []
	for ring: Vector3 in RINGS:
		var found := _route(w, heights, here, occupied, prefer, ring.x, ring.y, ring.z)
		if found.size() == COUNT:
			return found
	return []


static func _route(w: WorldData, heights: Heightfield, here: Dictionary, occupied: Dictionary, prefer: Callable,
		MIN_RADIUS: float, MAX_RADIUS: float, IDEAL: float) -> Array[Vector2i]:
	var center := Vector2(here.x, here.y)
	var candidates: Array[Vector2i] = []
	var seen := {}
	for trail: Dictionary in w.trails:
		if trail.kind not in ["road", "trail", "mountain"]:
			continue
		var points: Array = trail.pts
		var next := 0.0
		for i in range(1, points.size()):
			var a := Vector2(points[i - 1].x, points[i - 1].y)
			var b := Vector2(points[i].x, points[i].y)
			var span := a.distance_to(b)
			if span < 0.001:
				continue
			var along := (b - a) / span
			var side := Vector2(-along.y, along.x)
			while next < span:
				var road := a + along * next
				next += ROAD_SAMPLE
				if road.distance_to(center) > MAX_RADIUS + OFFSETS[-1]:
					continue
				for offset: float in OFFSETS:
					for sign: float in [-1.0, 1.0]:
						var target := (road + side * offset * sign).floor()
						var cell := Vector2i(target)
						target += Vector2(0.5, 0.5)
						var distance := center.distance_to(target)
						if cell in seen or distance < MIN_RADIUS or distance > MAX_RADIUS or occupied.has(key(cell)):
							continue
						if _off_road(w, cell) and _clear_pad(w, target) and _approach(w, heights, road, target):
							seen[cell] = true
							candidates.append(cell)
			next -= span
	return _triangle(candidates, center, prefer, IDEAL)


static func _off_road(w: WorldData, cell: Vector2i) -> bool:
	if not Rect2i(2, 2, w.W - 4, w.H - 4).has_point(cell):
		return false
	var paths := w.path_mask
	for z in range(cell.y - 2, cell.y + 3):
		for x in range(cell.x - 2, cell.x + 3):
			if paths[z * w.W + x] != 0:
				return false
	return true


## Растительность плана читается напрямую: коллизии леса подгружаются только вокруг игрока.
static func _clear_pad(w: WorldData, target: Vector2) -> bool:
	if w.chunks.is_empty():
		return true
	var range_cells := Vector2.ONE * ((RockModels.MASSIF_REACH + REACH) / TILE)
	var first := Vector2i(((target - range_cells) / w.CS).floor()).max(Vector2i.ZERO)
	var last := Vector2i(((target + range_cells) / w.CS).floor()).min(Vector2i(w.CW - 1, w.CH - 1))
	for z in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			for i: int in w.chunks[z * w.CW + x]:
				var kind := w.obj_k[i]
				var radius: float = ForestObstacles.TRUNK.get(kind, 0.0) * w.obj_s[i]
				if kind == Biomes.T_ROCK:
					radius = RockModels.MASSIF_REACH if RockModels.is_massif(w.obj_v[i]) else 3.0 * w.obj_s[i]
				if radius > 0.0 and target.distance_squared_to(Vector2(w.obj_x[i], w.obj_y[i])) < ((radius + 1.0) / TILE) ** 2:
					return false
	return true


## Короткий пеший подход по суше, с запасом для тела игрока и без резких перепадов.
static func _approach(w: WorldData, heights: Heightfield, road: Vector2, target: Vector2) -> bool:
	var from := road * TILE
	var to := target * TILE
	var count := ceili(from.distance_to(to) / 2.0)
	var run := from.distance_to(to) / count
	var previous := heights.ground_at(from.x, from.y)
	for i in range(0, count + 1):
		var point := from.lerp(to, float(i) / count)
		var y := heights.ground_at(point.x, point.y)
		if absf(y - previous) > run * 0.55 or heights.depth_at(point.x, point.y) > 0.03 \
				or not PlayerState.is_passable(w, heights, point.x, point.y, y, PlayerState.BODY_R):
			return false
		previous = y
	for offset: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var point := to + offset
		if absf(heights.ground_at(point.x, point.y) - previous) > 0.35 or heights.depth_at(point.x, point.y) > 0.03:
			return false
	return true


## Среди площадок выбираем треугольник, близкий к равностороннему. Начинаем со стороны доски.
static func _triangle(candidates: Array[Vector2i], center: Vector2, prefer := Callable(), IDEAL := 26.0) -> Array[Vector2i]:
	var start_cost := func(cell: Vector2i) -> float:
		return absf(center.distance_to(Vector2(cell)) - IDEAL) * 0.35 + (float(prefer.call(Vector2(cell))) * 40.0 if prefer.is_valid() else 0.0)
	var costs := {}
	for cell: Vector2i in candidates:
		costs[cell] = start_cost.call(cell)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return costs[a] < costs[b] if costs[a] != costs[b] else a < b)
	var best: Array[Vector2i] = []
	var best_score := INF
	for a: Vector2i in candidates.slice(0, 12):
		for b: Vector2i in candidates:
			var edge := Vector2(b - a)
			var side := edge.length()
			if side < 26.0 or side > 100.0:
				continue
			var mid := Vector2(a) + edge * 0.5
			var cross := Vector2(-edge.y, edge.x) * (sqrt(3.0) * 0.5)
			var base_score := absf(side - 52.0) + float(costs[a])
			if base_score >= best_score:
				continue
			for c: Vector2i in candidates:
				var error := minf(Vector2(c).distance_to(mid + cross), Vector2(c).distance_to(mid - cross))
				var score := base_score + error
				if error < side * 0.45 and score < best_score:
					best = [a, b, c]
					best_score = score
	return best


static func key(cell: Vector2i) -> String:
	return WorldData.place_id("beacon", cell.x, cell.y)


static func cell_of(id: String) -> Vector2i:
	var fields := id.split(":")
	if fields.size() != 3 or fields[0] != "beacon" or not fields[1].is_valid_int() or not fields[2].is_valid_int():
		return NO_CELL
	var cell := Vector2i(int(fields[1]), int(fields[2]))
	return cell if cell.x >= 0 and cell.y >= 0 and key(cell) == id else NO_CELL


static func place(cell: Vector2i, number: int) -> Dictionary:
	return {key = key(cell), kind = "beacon", name = "Маяк %d" % number, x = cell.x + 0.5, y = cell.y + 0.5}
