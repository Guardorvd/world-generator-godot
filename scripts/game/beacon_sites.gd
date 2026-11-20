extends RefCounted
const BeaconSitesScript = preload("res://scripts/game/beacon_sites.gd")
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


## 20.11.2026: площадки маяков проверяются лениво. Раньше каждая точка у дорог кольца (~350–700 на мире 768) проходила
## полную проверку (лес и скалы вокруг, пеший подход по рельефу) ещё до выбора треугольника — ~0,35 с одним кадром
## у доски. Теперь из дорог берутся только кандидаты по геометрии (кольцо, не на дороге), треугольник ищется по ним,
## а полная проверка — только у точек, которые в него попадают (_Pick.valid, с запоминанием на мир). Кандидаты для
## второй и третьей вершины берутся из сетки _Pick.buckets (ближе 100 и 45 клеток) в том же порядке по цене.
static func route(w: WorldData, heights: Heightfield, here: Dictionary, occupied: Dictionary, prefer := Callable()) -> Array[Vector2i]:
	if heights == null or w.path_mask.size() != w.N:
		return []
	for ring: Vector3 in RINGS:
		var pick := _Pick.new(w, heights)
		_gather(pick, w, Vector2(here.x, here.y), occupied, ring.x, ring.y)
		var found := _triangle(pick, Vector2(here.x, here.y), prefer, ring.z)
		if found.size() == COUNT:
			return found
	return []


## Точки выборки всех путей мира (через ROAD_SAMPLE клеток, как раньше) и их сетка — один раз на мир. Поиск у доски
## берёт только ячейки сетки в пределах кольца, а не обходит все дороги мира (~40 мс на мире 768)
const INDEX_CELL := 32.0
static var _index_world := 0
static var _roads := PackedVector2Array()
static var _sides := PackedVector2Array()
static var _index := {}       # Vector2i ячейки -> PackedInt32Array номеров точек
static var _clear := {}       # клетка -> площадка свободна от леса и скал (запоминается на мир)
static var _walk := {}        # Vector4(клетка, точка дороги) -> есть пеший подход


## Подготовить указатель путей мира заранее (GameWorld при загрузке, под заставкой)
static func warm(w: WorldData) -> void:
	if _index_world == w.get_instance_id():
		return
	_index_world = w.get_instance_id()
	_roads = PackedVector2Array()
	_sides = PackedVector2Array()
	_index = {}
	_clear = {}
	_walk = {}
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
			while next < span:
				var road := a + along * next
				next += ROAD_SAMPLE
				var bucket := Vector2i((road / INDEX_CELL).floor())
				if not _index.has(bucket):
					_index[bucket] = PackedInt32Array()
				_index[bucket].append(_roads.size())
				_roads.append(road)
				_sides.append(Vector2(-along.y, along.x))
			next -= span


## Кандидаты кольца: клетки у дорог в стороне от полотна (дёшево); для каждой — точки дороги, откуда к ней подход
static func _gather(pick: _Pick, w: WorldData, center: Vector2, occupied: Dictionary, min_radius: float, max_radius: float) -> void:
	warm(w)
	var reach := max_radius + OFFSETS[-1]
	var rejected := {}
	var first := Vector2i(((center - Vector2.ONE * reach) / INDEX_CELL).floor())
	var last := Vector2i(((center + Vector2.ONE * reach) / INDEX_CELL).floor())
	for by in range(first.y, last.y + 1):
		for bx in range(first.x, last.x + 1):
			for n: int in _index.get(Vector2i(bx, by), PackedInt32Array()):
				var road := _roads[n]
				if road.distance_to(center) > reach:
					continue
				var side := _sides[n]
				for offset: float in OFFSETS:
					for sign: float in [-1.0, 1.0]:
						var target := (road + side * offset * sign).floor()
						var cell := Vector2i(target)
						var distance := center.distance_to(target + Vector2(0.5, 0.5))
						if distance < min_radius or distance > max_radius or rejected.has(cell) or occupied.has(key(cell)):
							continue
						if not pick.roads.has(cell):
							if not _off_road(w, cell):
								rejected[cell] = true
								continue
							pick.roads[cell] = PackedVector2Array()
						pick.roads[cell].append(road)


## Кандидаты маяков одного поиска: подходы, запомненные проверки, сетка для поиска соседей
class _Pick:
	const BUCKET := 25.0
	var w: WorldData
	var heights: Heightfield
	var roads := {}      # клетка -> точки дорог (клетки), откуда к ней можно подойти
	var checked := {}    # клетка -> прошла ли полную проверку
	var order: Array[Vector2i] = []  # кандидаты по цене
	var at := PackedVector2Array()   # их клетки как Vector2, тем же порядком
	var cost := PackedFloat64Array()
	var buckets := {}    # Vector2i -> PackedInt32Array номеров в order

	func _init(world: WorldData, hf: Heightfield) -> void:
		w = world
		heights = hf

	## Полная проверка площадки (лес и скалы вокруг, подход хотя бы от одной точки дороги), один раз на клетку
	func valid(cell: Vector2i) -> bool:
		if checked.has(cell):
			return checked[cell]
		var target := Vector2(cell) + Vector2(0.5, 0.5)
		var ok := false
		var clear: Variant = BeaconSitesScript._clear.get(cell)
		if clear == null:
			clear = BeaconSitesScript._clear_pad(w, target)
			BeaconSitesScript._clear[cell] = clear
		if clear:
			for road: Vector2 in roads[cell]:
				var k := Vector4(cell.x, cell.y, road.x, road.y)
				var walk: Variant = BeaconSitesScript._walk.get(k)
				if walk == null:
					walk = BeaconSitesScript._approach(w, heights, road, target)
					BeaconSitesScript._walk[k] = walk
				if walk:
					ok = true
					break
		checked[cell] = ok
		return ok

	## Номера кандидатов в круге radius вокруг p, по возрастанию (порядок цены)
	func near(p: Vector2, radius: float) -> PackedInt32Array:
		var out := PackedInt32Array()
		var first := Vector2i(((p - Vector2.ONE * radius) / BUCKET).floor())
		var last := Vector2i(((p + Vector2.ONE * radius) / BUCKET).floor())
		for y in range(first.y, last.y + 1):
			for x in range(first.x, last.x + 1):
				out.append_array(buckets.get(Vector2i(x, y), PackedInt32Array()))
		out.sort()
		return out


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
	# 20.11.2026: дальше самого большого охвата (массив скал) объект не мешает — без разбора его вида и размера
	var farthest := ((RockModels.MASSIF_REACH + 1.0) / TILE) ** 2
	for z in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			for i: int in w.chunks[z * w.CW + x]:
				var d2 := target.distance_squared_to(Vector2(w.obj_x[i], w.obj_y[i]))
				if d2 >= farthest:
					continue
				var kind := w.obj_k[i]
				var radius: float = ForestObstacles.TRUNK.get(kind, 0.0) * w.obj_s[i]
				if kind == Biomes.T_ROCK:
					radius = RockModels.MASSIF_REACH if RockModels.is_massif(w.obj_v[i]) else 3.0 * w.obj_s[i]
				if radius > 0.0 and d2 < ((radius + 1.0) / TILE) ** 2:
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
## Перебор как при полной проверке всех площадок (12 лучших для первой вершины, все годные для второй и третьей), но
## годность точки проверяется, только когда она вошла бы в лучший треугольник. Первая вершина, которая так и не
## понадобилась, не проверяется вовсе — поэтому изредка выбор отличается от прежнего (12 первых вершин берутся
## из непроверенных, а не только из годных)
static func _triangle(pick: _Pick, center: Vector2, prefer := Callable(), IDEAL := 26.0) -> Array[Vector2i]:
	var costs := {}
	for cell: Vector2i in pick.roads:
		costs[cell] = absf(center.distance_to(Vector2(cell)) - IDEAL) * 0.35 + (float(prefer.call(Vector2(cell))) * 40.0 if prefer.is_valid() else 0.0)
		pick.order.append(cell)
	pick.order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return costs[a] < costs[b] if costs[a] != costs[b] else a < b)
	for i in pick.order.size():
		var cell := pick.order[i]
		pick.at.append(Vector2(cell))
		pick.cost.append(costs[cell])
		var bucket := Vector2i((Vector2(cell) / _Pick.BUCKET).floor())
		if not pick.buckets.has(bucket):
			pick.buckets[bucket] = PackedInt32Array()
		pick.buckets[bucket].append(i)
	var best: Array[Vector2i] = []
	var best_score := INF
	var firsts := 0
	for ia in pick.order.size():
		if firsts == 12:
			break
		if pick.checked.get(pick.order[ia], true) == false:
			continue
		firsts += 1
		var a := pick.at[ia]
		var a_failed := false
		for ib in pick.near(a, 100.0):
			var edge := pick.at[ib] - a
			var side := edge.length()
			if side < 26.0 or side > 100.0:
				continue
			var base_score := absf(side - 52.0) + pick.cost[ia]
			if base_score >= best_score:
				continue
			var mid := a + edge * 0.5
			var cross := Vector2(-edge.y, edge.x) * (sqrt(3.0) * 0.5)
			var tips := pick.near(mid + cross, side * 0.45)
			tips.append_array(pick.near(mid - cross, side * 0.45))
			tips.sort()
			var previous := -1
			for ic in tips:
				if ic == previous:
					continue
				previous = ic
				var c := pick.at[ic]
				var error := minf(c.distance_to(mid + cross), c.distance_to(mid - cross))
				var score := base_score + error
				if error < side * 0.45 and score < best_score:
					if not pick.valid(pick.order[ia]):
						a_failed = true
						break
					if not pick.valid(pick.order[ib]):
						break
					if not pick.valid(pick.order[ic]):
						continue
					best = [pick.order[ia], pick.order[ib], pick.order[ic]]
					best_score = score
			if a_failed:
				break
		if a_failed:
			firsts -= 1 # непригодная первая вершина не в счёт двенадцати
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
