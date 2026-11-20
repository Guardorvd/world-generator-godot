extends RefCounted
## Три существующих объекта по ходу одной дороги или тропы.

const COUNT := 3
const TILE := GameConfig.TILE
const KEY_PRECISION := 1000.0 # тысячные доли клетки
const ROAD_SAMPLE := 4.0 # клетки
const NEAR_BOARD := 18.0
## 18.11.2026: метки дальше по дороге от доски (было 12–115 клеток — у самой деревни); сторона — по prefer (Quests.prefer)
## Окна по дороге [от, до] клеток: сначала дальнее (280–720 м), если там не нашлось трёх объектов — прежнее ближнее
const TRIPS := [Vector2(70.0, 180.0), Vector2(12.0, 115.0)]
const VERGE := 5.0
const MIN_GAP := 12.0


static func route(w: WorldData, heights: Heightfield, here: Dictionary, painted: Dictionary, prefer := Callable()) -> Array[Dictionary]:
	if heights == null or w.chunks.is_empty():
		return []
	for trip: Vector2 in TRIPS:
		var found := _route(w, heights, here, painted, prefer, trip.x, trip.y)
		if not found.is_empty():
			return found
	return []


static func _route(w: WorldData, heights: Heightfield, here: Dictionary, painted: Dictionary, prefer: Callable,
		MIN_TRIP: float, MAX_TRIP: float) -> Array[Dictionary]:
	var center := Vector2(here.x, here.y)
	var best: Array[Dictionary] = []
	var best_cost := INF
	var all_stations := _world_stations(w)
	for r in w.trails.size():
		var road: Dictionary = w.trails[r]
		if road.kind not in ["road", "trail", "mountain"] or road.pts.size() < 2:
			continue
		# 20.11.2026: путь, все точки которого дальше NEAR_BOARD от доски, не подходит — его точки не перебираются
		var reach: Rect2 = all_stations[r][1]
		if not reach.grow(NEAR_BOARD).has_point(center):
			continue
		var stations: PackedVector2Array = all_stations[r][0]
		var entry := 0
		var entry_gap := NEAR_BOARD
		for i in stations.size():
			var distance := stations[i].distance_to(center)
			if distance < entry_gap:
				entry = i
				entry_gap = distance
		if entry_gap == NEAR_BOARD:
			continue
		for direction: int in [1, -1]:
			var run: Array[Dictionary] = []
			var next := MIN_TRIP
			for leg in range(ceili(MIN_TRIP / ROAD_SAMPLE), floori(MAX_TRIP / ROAD_SAMPLE) + 1):
				var cell := entry + leg * direction
				if cell < 0 or cell >= stations.size():
					break
				if leg * ROAD_SAMPLE < next:
					continue
				var target := _near(w, heights, stations[cell], run, painted)
				if target.is_empty():
					continue
				run.append(target)
				next = leg * ROAD_SAMPLE + MIN_GAP
				if run.size() == COUNT:
					var cost := entry_gap + leg * ROAD_SAMPLE + (0.0 if road.kind == "road" else 16.0) 						+ (float(prefer.call(stations[cell])) * 60.0 if prefer.is_valid() else 0.0)
					if cost < best_cost:
						best = run
						best_cost = cost
					break
	return best


## 20.11.2026: точки путей мира через ROAD_SAMPLE и их рамка — один раз на мир (раньше заново при каждом открытии доски)
static var _cached_stations: Array = []
static var _cached_world := 0

static func _world_stations(w: WorldData) -> Array:
	if _cached_world != w.get_instance_id() or _cached_stations.size() != w.trails.size():
		_cached_world = w.get_instance_id()
		_cached_stations = []
		for road: Dictionary in w.trails:
			var stations := _stations(road.pts) if road.pts.size() >= 2 else PackedVector2Array()
			var frame := Rect2(stations[0], Vector2.ZERO) if not stations.is_empty() else Rect2(-1e9, -1e9, 0, 0)
			for at in stations:
				frame = frame.expand(at)
			_cached_stations.append([stations, frame])
	return _cached_stations


static func _stations(points: Array) -> PackedVector2Array:
	var stations := PackedVector2Array()
	var next := 0.0
	var a := Vector2(points[0].x, points[0].y)
	for i in range(1, points.size()):
		var b := Vector2(points[i].x, points[i].y)
		var length := a.distance_to(b)
		while next < length:
			stations.append(a.lerp(b, next / length))
			next += ROAD_SAMPLE
		next -= length
		a = b
	return stations


static func _near(w: WorldData, heights: Heightfield, road: Vector2, picked: Array[Dictionary], painted: Dictionary) -> Dictionary:
	var from := _chunk(w, road - Vector2.ONE * VERGE).max(Vector2i.ZERO)
	var to := _chunk(w, road + Vector2.ONE * VERGE).min(Vector2i(w.CW - 1, w.CH - 1))
	var best := {}
	var best_cost := INF
	var previous_rock: bool = not picked.is_empty() and picked[-1].rock
	for z in range(from.y, to.y + 1):
		for x in range(from.x, to.x + 1):
			for i: int in w.chunks[z * w.CW + x]:
				var radius := _radius(w, i)
				if radius <= 0.0:
					continue
				var at := Vector2(w.obj_x[i], w.obj_y[i])
				var distance := at.distance_to(road)
				if distance < 1.0 or distance > VERGE or not w.accessible(at.x, at.y):
					continue
				var rock := w.obj_k[i] == Biomes.T_ROCK
				var cost := distance + (1.25 if not picked.is_empty() and rock == previous_rock else 0.0)
				if cost >= best_cost or painted.has(_key(w, i)):
					continue
				if picked.any(func(p: Dictionary) -> bool: return at.distance_squared_to(Vector2(p.x, p.y)) < 8.0 ** 2):
					continue
				var approach := _approach(w, heights, road, at, radius, i)
				if approach.is_finite():
					best = place(w, i)
					best.approach = approach
					best_cost = cost
	return best


static func _radius(w: WorldData, i: int) -> float:
	var kind := w.obj_k[i]
	var scale := w.obj_s[i]
	if kind == Biomes.T_ROCK:
		return ForestObstacles.ROCK_R * scale * 1.2 if scale >= 0.65 and not RockModels.is_outcrop(w.obj_v[i]) else 0.0
	var radius: float = ForestObstacles.TRUNK.get(kind, 0.0) * scale
	return radius if kind != Biomes.T_MUGO and radius >= 0.13 else 0.0


## Место у объекта, где можно встать. Навигация ведёт сюда, а метка — на сам объект.
static func _approach(w: WorldData, heights: Heightfield, road: Vector2, at: Vector2, radius: float, i: int) -> Vector2:
	var object_pos := at * TILE
	if ForestObstacles.on_tread(heights, object_pos.x, object_pos.y) or heights.depth_at(object_pos.x, object_pos.y) > 0.03:
		return Vector2.INF
	if w.obj_k[i] == Biomes.T_ROCK and RockModels.seat(heights, object_pos.x, object_pos.y, w.obj_s[i] * 1.2, w.obj_v[i]).x == INF:
		return Vector2.INF
	var from := road * TILE
	var to := object_pos.move_toward(from, radius + 0.65)
	var steps := maxi(1, ceili(from.distance_to(to) / 2.0))
	var last := heights.ground_at(from.x, from.y)
	for n in range(0, steps + 1):
		var point := from.lerp(to, float(n) / steps)
		var y := heights.ground_at(point.x, point.y)
		if absf(last - y) > 1.15 or heights.depth_at(point.x, point.y) > 0.03 \
				or not PlayerState.is_passable(w, heights, point.x, point.y, y, PlayerState.BODY_R):
			return Vector2.INF
		last = y
	return to if absf(last - heights.ground_at(object_pos.x, object_pos.y)) < 1.2 else Vector2.INF


static func _chunk(w: WorldData, at: Vector2) -> Vector2i:
	return Vector2i((at / w.CS).floor())


static func _key(w: WorldData, i: int) -> String:
	return "paint:%d:%d:%d" % [w.obj_k[i], roundi(w.obj_x[i] * KEY_PRECISION), roundi(w.obj_y[i] * KEY_PRECISION)]


static func address(id: String) -> PackedInt64Array:
	var fields := id.split(":", false)
	if fields.size() != 4 or fields[0] != "paint":
		return []
	var result := PackedInt64Array()
	for n in range(1, 4):
		var value := fields[n].to_int()
		if value < 0 or fields[n] != str(value):
			return []
		result.append(value)
	return result if id == "paint:%d:%d:%d" % [result[0], result[1], result[2]] else PackedInt64Array()


static func resolve(w: WorldData, id: String) -> Dictionary:
	var data := address(id)
	if w == null or w.chunks.is_empty() or data.is_empty():
		return {}
	var at := Vector2(data[1], data[2]) / KEY_PRECISION
	if not Rect2(0, 0, w.W, w.H).grow(1.0 / KEY_PRECISION).has_point(at):
		return {}
	# Округление адреса возле границы может перенести координату в соседний чанк.
	var first := _chunk(w, at - Vector2.ONE / KEY_PRECISION).max(Vector2i.ZERO)
	var last := _chunk(w, at + Vector2.ONE / KEY_PRECISION).min(Vector2i(w.CW - 1, w.CH - 1))
	for z in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			for i: int in w.chunks[z * w.CW + x]:
				if w.obj_k[i] == data[0] and _key(w, i) == id:
					return place(w, i)
	return {}


static func place(w: WorldData, i: int) -> Dictionary:
	var rock := w.obj_k[i] == Biomes.T_ROCK
	return {key = _key(w, i), kind = "paint", name = "Камень" if rock else "Дерево",
		x = w.obj_x[i], y = w.obj_y[i], object = i, rock = rock, radius = _radius(w, i)}
