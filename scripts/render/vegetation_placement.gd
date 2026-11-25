extends RefCounted
## Общие проверки размещения. Только CPU, используется фоновой задачей растительности.

const TILE := GameConfig.TILE
const TRUNK_FLARE := 1.3 # просвет травы и подлеска у ствола: радиус ствола с расширением комля
const Plants := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
var world: WorldData
var heights: Heightfield
var regions := {} # immutable detail-worker snapshot, never OuterLand's live chunks
var outer_canopy: Image
var canopy_rect := Rect2i()
var occupied: Array[AABB] = [] # несколько крупных деталей в ближнем круге (только через occupy и clear_occupied)
var _occ_cells := {} # Vector2i(клетка мира) -> PackedInt32Array номеров в occupied: травинка смотрит 1–4 клетки, а не весь список
var _cells := {} # Vector2i(клетка) -> [x, z, радиус, объект, ...], см. prepare
var _max_r := 0.0
var _place_cells := {}
var _clear_rect := Rect2i()
var _clear_ground := PackedByteArray()


func _init(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h


func ground_at(x: float, z: float) -> float:
	if x >= 0 and z >= 0 and x < world.W * TILE and z < world.H * TILE: return heights.placement_ground_at(x, z)
	return RegionStream.snapshot_ground(world, heights, regions, x, z)


func cover_at(x: float, z: float) -> float:
	var p := Vector2i(floori(x / TILE), floori(z / TILE))
	if outer_canopy != null and canopy_rect.has_point(p):
		return outer_canopy.get_pixel(p.x - canopy_rect.position.x, p.y - canopy_rect.position.y).r
	return 0.0


func region_clear(x: float, z: float) -> bool:
	var cell := Vector2i(floori(x / TILE), floori(z / TILE))
	var key := Vector2i(floori(float(cell.x) / WorldData.REGION_SIZE), floori(float(cell.y) / WorldData.REGION_SIZE))
	var region: Dictionary = regions.get(key, {})
	if not region.has("fields"): return false
	var rect: Rect2i = region.rect
	if not rect.has_point(cell): return false
	var f: Dictionary = region.fields
	var k := (cell.y - rect.position.y) * rect.size.x + cell.x - rect.position.x
	if f.ocean[k] != 0 or f.river[k] != 0 or f.lake[k] != 0 or (f.has("village") and f.village[k] != 0): return false
	var refined := OuterLand.refined_at(regions, x, z)
	if not refined.is_empty(): return refined.weight <= 0.08
	if not f.has("dist_path"): return f.path[k] == 0
	# Tree clearance includes a wide maintained verge on roads. Low vegetation
	# keeps a smaller reserve while the conservative distance still protects tread.
	var reserve := 1.75 if f.path[k] == 3 else 0.15
	return Grid.clearance_at(f.dist_path, rect.position.x, rect.position.y, rect.size.x, x / TILE, z / TILE, TILE) >= -reserve


## Сначала валежник/камни, затем кусты/молодняк, затем мягкая подстилка и растения.
static func priority(kind: int) -> int:
	if Floor.base_kind(kind - Floor.FIRST) in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STONES, Floor.STUMP, Floor.BOULDER]:
		return 0
	if kind in [Plants.BUSH, Plants.SAPLING, Plants.PINE, Plants.YOUNG, Plants.YOUNG_PINE, Plants.HAZEL, Plants.HAZEL_TALL, Plants.ALPINE_SHRUB, Plants.ALPINE_SHRUB_CREEPING,
			Plants.SALAL, Plants.SALAL_TALL, Plants.DEVILS_CLUB, Plants.DEVILS_CLUB_TALL, Plants.BERRY_SHRUB_TALL]:
		return 1
	return 2


func clear_occupied() -> void:
	occupied.clear()
	_occ_cells.clear()


## Занять место крупной деталью (валежник, камни, кусты): по ней проверяются следующие детали и трава
func occupy(box: AABB) -> void:
	var k := occupied.size()
	occupied.append(box)
	for cz in range(floori(box.position.z / TILE), floori(box.end.z / TILE) + 1):
		for cx in range(floori(box.position.x / TILE), floori(box.end.x / TILE) + 1):
			var key := Vector2i(cx, cz)
			var list: PackedInt32Array = _occ_cells.get(key, PackedInt32Array())
			list.append(k)
			_occ_cells[key] = list


func details_clear(box: AABB) -> bool:
	# с 6.9 по клеткам: раньше каждая из ~12 000 травинок перебирала все занятые места
	for cz in range(floori(box.position.z / TILE), floori(box.end.z / TILE) + 1):
		for cx in range(floori(box.position.x / TILE), floori(box.end.x / TILE) + 1):
			var list: Variant = _occ_cells.get(Vector2i(cx, cz))
			if list == null:
				continue
			for k: int in list:
				if occupied[k].intersects(box):
					return false
	return true


## На переломах склона плоская деталь иначе висит в воздухе или проваливается.
func terrain_fits(xf: Transform3D, box: AABB, tolerance := 0.18) -> bool:
	for j in 3:
		for i in 3:
			var point := xf * Vector3(lerpf(box.position.x, box.end.x, i * 0.5), 0.0, lerpf(box.position.z, box.end.z, j * 0.5))
			if absf(point.y + 0.015 - ground_at(point.x, point.z)) > tolerance:
				return false
	return true


## Long trail debris follows the chord of its contact points. The local tangent
## at the midpoint is unreliable on a rut, at a shoulder or on a grade break.
func seat_road_span(xf: Transform3D, span: Vector2, sink: float, tolerance: float, settle: float) -> Transform3D:
	var left := span.x
	var right := span.y
	var a := xf * Vector3(left, 0.0, 0.0)
	var b := xf * Vector3(right, 0.0, 0.0)
	var ya := ground_at(a.x, a.z)
	var yb := ground_at(b.x, b.z)
	xf.basis.x.y = (yb - ya) / (right - left)
	xf.origin.y = ya - left * xf.basis.x.y - 0.015 - sink
	var low := INF
	var high := -INF
	for j in 7:
		var p := xf * Vector3(lerpf(left, right, j / 6.0), 0.0, 0.0)
		var inside := p.x >= 0 and p.z >= 0 and p.x < world.W * TILE and p.z < world.H * TILE
		if (heights.depth_at(p.x, p.z) > 0.0 if inside else not region_dry(p.x, p.z)) or heights._cell_list(p.x, p.z) != null:
			return Transform3D()
		var error := ground_at(p.x, p.z) - p.y
		low = minf(low, error)
		high = maxf(high, error)
	# Logs can rest on raised ground. Roots should hug it closely enough for
	# their two small arches to emerge and their tips to stay in the soil.
	if high - low > tolerance * xf.basis.y.y:
		return Transform3D()
	xf.origin.y += lerpf(low, high, settle) - 0.015 - sink
	return xf


## Сажает лесной валежник по 7-точечной хорде на неровном рельефе, избегая воды и самой колеи.
func seat_forest_log(xf: Transform3D, span: Vector2, sink: float, tolerance := 0.44, settle := 0.65) -> Transform3D:
	var left := span.x
	var right := span.y
	var a := xf * Vector3(left, 0.0, 0.0)
	var b := xf * Vector3(right, 0.0, 0.0)
	var ya := ground_at(a.x, a.z)
	var yb := ground_at(b.x, b.z)
	xf.basis.x.y = (yb - ya) / maxf(0.05, right - left)
	xf.origin.y = ya - left * xf.basis.x.y - 0.015 - sink
	var low := INF
	var high := -INF
	var refinement := heights.road_refinement
	for j in 7:
		var p := xf * Vector3(lerpf(left, right, j / 6.0), 0.0, 0.0)
		var inside := p.x >= 0 and p.z >= 0 and p.x < world.W * TILE and p.z < world.H * TILE
		if (heights.depth_at(p.x, p.z) > 0.0 if inside else not region_dry(p.x, p.z)) or heights._cell_list(p.x, p.z) != null:
			return Transform3D()
		if inside and refinement != null and refinement.weight_at(p.x, p.z, world.W) > 0.25:
			return Transform3D()
		var error := ground_at(p.x, p.z) - p.y
		low = minf(low, error)
		high = maxf(high, error)
	if high - low > tolerance * xf.basis.y.y:
		return Transform3D()
	xf.origin.y += lerpf(low, high, settle) - 0.015 - sink
	return xf


## Приземляет вертикальные вывороты и замшелые валуны на склон по нижней точке опоры без парящих корней.
func seat_embedded_solid(xf: Transform3D, box: AABB, sink: float, max_drop_ratio := 0.58) -> Transform3D:
	var min_y := INF
	var max_y := -INF
	var corners: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(box.position.x, 0.0, box.position.z),
		Vector3(box.end.x, 0.0, box.position.z),
		Vector3(box.position.x, 0.0, box.end.z),
		Vector3(box.end.x, 0.0, box.end.z),
	]
	for local_p: Vector3 in corners:
		var p := xf * local_p
		var inside := p.x >= 0 and p.z >= 0 and p.x < world.W * TILE and p.z < world.H * TILE
		if (heights.depth_at(p.x, p.z) > 0.0 if inside else not region_dry(p.x, p.z)):
			return Transform3D()
		var gy := ground_at(p.x, p.z)
		min_y = minf(min_y, gy)
		max_y = maxf(max_y, gy)
	if max_y - min_y > maxf(0.32, box.size.y * xf.basis.y.y * max_drop_ratio):
		return Transform3D()
	xf.origin.y = min_y - 0.04 - sink
	return xf


func region_dry(x: float, z: float) -> bool:
	var cell := Vector2i(floori(x / TILE), floori(z / TILE))
	var key := Vector2i(floori(float(cell.x) / WorldData.REGION_SIZE), floori(float(cell.y) / WorldData.REGION_SIZE))
	var region: Dictionary = regions.get(key, {})
	if not region.has("fields") or not region.rect.has_point(cell): return false
	var rect: Rect2i = region.rect
	var k := (cell.y - rect.position.y) * rect.size.x + cell.x - rect.position.x
	var f: Dictionary = region.fields
	return f.ocean[k] == 0 and f.river[k] == 0 and f.lake[k] == 0 and (not f.has("village") or f.village[k] == 0)


## Проверяем весь след у воды, дорог и домов; шаг не больше метра.
func ground_clear(x: float, z: float, radius: float, root_collar := false, verge_limit := 0.08) -> bool:
	if root_collar and heights.road_refinement != null and heights.road_refinement.weight_at(x, z, world.W) > 0.35:
		return false
	if root_collar and heights.road_refinement == null:
		var cx := floori(x / TILE)
		var cy := floori(z / TILE)
		if cx >= 0 and cy >= 0 and cx < world.W and cy < world.H and world.path_mask[cy * world.W + cx] != 0: return false
	var hut_radius := radius / TILE + 0.3
	if not _place_cells.is_empty() and (StageVegetation.VILLAGE_R + hut_radius) * TILE <= OuterLand.SETTLEMENT_REACH:
		if StageVegetation.near_hut(_place_cells.get(OuterLand.collision_cell(x, z), []), x / TILE, z / TILE, hut_radius):
			return false
	elif StageVegetation.near_hut(world.settlements, x / TILE, z / TILE, hut_radius) \
			or StageVegetation.near_hut(world.sites, x / TILE, z / TILE, hut_radius):
		return false
	var lo := Vector2i(floori((x - radius) / TILE), floori((z - radius) / TILE))
	var hi := Vector2i(floori((x + radius) / TILE), floori((z + radius) / TILE))
	var footprint := Rect2i(lo, hi - lo + Vector2i.ONE)
	if not root_collar and _clear_rect.has_area() and _clear_rect.encloses(footprint) and _clear_footprint(footprint):
		return true
	var steps := ceili(radius * 2.0)
	var width := world.W
	var height := world.H
	var paths := world.path_mask
	var refinement := heights.road_refinement
	var rc := world.river_cells() # коридор ленты реки, как у генератора растительности
	for j in steps + 1:
		for i in steps + 1:
			var px := x + lerpf(-radius, radius, float(i) / maxi(1, steps))
			var pz := z + lerpf(-radius, radius, float(j) / maxi(1, steps))
			var cx := floori(px / TILE)
			var cy := floori(pz / TILE)
			if cx < 0 or cy < 0 or cx >= width or cy >= height:
				if not (region_dry(px, pz) if root_collar else region_clear(px, pz)): return false
				continue
			var k := cy * width + cx
			# 15.0: у дорог и троп — их настоящее полотно (weight_at ниже), а не клетка 4 м; звериная тропа без полотна — клеткой
			if (not root_collar and (paths[k] == 1 or (paths[k] > 1 and refinement == null))) or rc[k] != 0:
				return false
			if not root_collar and refinement != null and refinement.weight_at(px, pz, width) > verge_limit:
				return false
			if root_collar and heights._cell_list(px, pz) != null:
				return false
			# Озеро/море могут покрывать край соседней сухой клетки: важна глубина в точке.
			if heights.depth_at(px, pz) > 0.0:
				return false
	return true


func _clear_footprint(rect: Rect2i) -> bool:
	var size := _clear_rect.size.x
	for y in range(rect.position.y - _clear_rect.position.y, rect.end.y - _clear_rect.position.y):
		var row := y * size - _clear_rect.position.x
		for x in range(rect.position.x, rect.end.x):
			if _clear_ground[row + x] == 0:
				return false
	return true


## Клетка целиком сухая, если в четырёх пересекающих её квадах нет дорожных патчей и озёр,
## все вершины выше уровня моря, а клетку не задевает река. Остальные клетки проверяются по точкам.
func _prepare_clear_ground(px: float, pz: float, radius: float) -> void:
	var width := world.W
	var height := world.H
	var lo := Vector2i(floori((px - radius) / TILE), floori((pz - radius) / TILE))
	var hi := Vector2i(floori((px + radius) / TILE), floori((pz + radius) / TILE))
	_clear_rect = Rect2i(lo, hi - lo + Vector2i.ONE).intersection(Rect2i(1, 1, width - 2, height - 2))
	var paths := world.path_mask
	var river := world.river_cells()
	var lake := world.lake
	var ground := heights.hv
	if not _clear_rect.has_area() or paths.size() != world.N or river.size() != world.N or lake.size() != world.N or ground.size() != world.N:
		_clear_rect = Rect2i()
	_clear_ground.resize(_clear_rect.get_area())
	_clear_ground.fill(0)
	var refinement := heights.road_refinement
	var patches: Dictionary = refinement.patches if refinement != null else {}
	var ribbons := heights._river_cells
	for y in range(_clear_rect.position.y, _clear_rect.end.y):
		for x in range(_clear_rect.position.x, _clear_rect.end.x):
			var k := y * width + x
			if paths[k] == 1 or (paths[k] > 1 and refinement == null) or river[k] != 0 or ribbons.has(k):
				continue
			if patches.has(k) or patches.has(k - 1) or patches.has(k - width) or patches.has(k - width - 1):
				continue
			var dry := true
			for row in range(k - width, k + width + 1, width):
				if lake[row - 1] != 0 or lake[row] != 0 or lake[row + 1] != 0 \
						or not (ground[row - 1] >= 0.0 and ground[row] >= 0.0 and ground[row + 1] >= 0.0):
					dry = false
					break
			if dry:
				_clear_ground[(y - _clear_rect.position.y) * _clear_rect.size.x + x - _clear_rect.position.x] = 1


## Один раз на обновление: стволы, валуны и кусты вокруг игрока раскладываются по клеткам мира,
## чтобы проверка детали или травинки смотрела несколько соседних клеток, а не целые чанки.
func prepare(px: float, pz: float, radius: float) -> void:
	_cells.clear()
	_max_r = 0.0
	_place_cells = OuterLand.index_collision_places(world.settlements + world.sites)
	_prepare_clear_ground(px, pz, radius)
	var side := world.CS * TILE
	for cy in range(maxi(0, floori((pz - radius) / side)), mini(world.CH, ceili((pz + radius) / side))):
		for cx in range(maxi(0, floori((px - radius) / side)), mini(world.CW, ceili((px + radius) / side))):
			for o in world.chunks[cy * world.CW + cx]:
				var kind := world.obj_k[o]
				if not Biomes.is_tree(kind) and kind not in [Biomes.T_ROCK, Biomes.T_BUSH, Biomes.T_DEAD, Biomes.T_CACTUS]:
					continue
				var at := Vector2(world.obj_x[o], world.obj_y[o]) * TILE
				var seat := Vector4.ZERO
				if kind == Biomes.T_ROCK:
					seat = RockModels.seat(heights, at.x, at.y, world.obj_s[o] * 1.2, world.obj_v[o])
					if seat.x == INF:
						continue
				# 11.11.2026: у ствола — по его радиусу с расширением комля (раньше 0,3 на единицу масштаба)
				var r: float = StageVegetation.TRUNK.get(kind, 0.23) * TRUNK_FLARE * world.obj_s[o]
				if kind == Biomes.T_ROCK or kind == Biomes.T_BUSH:
					r = Biomes.CROWN_RADIUS[kind] * TILE * world.obj_s[o] * (1.2 if kind == Biomes.T_ROCK else 1.0)
				if kind == Biomes.T_ROCK and RockModels.is_outcrop(world.obj_v[o]):
					r = RockModels.footprint(world.obj_v[o], world.obj_s[o] * 1.2)
					# Массив: круг плотного тела, сдвинутый в склон, — трава у подножия стены остаётся.
					if RockModels.is_massif(world.obj_v[o]):
						var xf := RockModels.outcrop_transform(at.x, at.y, world.obj_s[o] * 1.2, Vector3(seat.y, seat.z, seat.w), seat.x,
							Vector2(world.world_origin) * TILE, world.obj_v[o])
						var core: Vector3 = xf * RockModels.MASSIF_SPEC[RockModels.massif_form(world.obj_v[o])].core
						at = Vector2(core.x, core.z)
				if r > 3.0:
					# Крупный массив записан во все клетки своего круга: поиск соседей у каждой травинки
					# не расширяется на его радиус (иначе по 30+ клеток на травинку у каждой горы).
					for gy in range(floori((at.y - r) / TILE), floori((at.y + r) / TILE) + 1):
						for gx in range(floori((at.x - r) / TILE), floori((at.x + r) / TILE) + 1):
							var key := Vector2i(gx, gy)
							if not _cells.has(key):
								_cells[key] = []
							_cells[key].append_array([at.x, at.y, r, o, kind, world.obj_s[o]])
					continue
				_max_r = maxf(_max_r, r)
				var cell := Vector2i(floori(at.x / TILE), floori(at.y / TILE))
				if not _cells.has(cell):
					_cells[cell] = []
				_cells[cell].append_array([at.x, at.y, r, o, kind, world.obj_s[o]])


## Reuse the existing object index, not a second index for regional details.
func prepare_outer(batches: Array, px: float, pz: float, radius: float) -> void:
	for b in range(1, batches.size()):
		var batch: Dictionary = batches[b]
		for o in batch.x.size():
			var x: float = batch.x[o] * TILE
			var z: float = batch.y[o] * TILE
			if absf(x - px) > radius or absf(z - pz) > radius: continue
			var kind: int = batch.k[o]
			if not Biomes.is_tree(kind) and kind not in [Biomes.T_ROCK, Biomes.T_BUSH, Biomes.T_DEAD, Biomes.T_CACTUS]: continue
			var r: float = (Biomes.CROWN_RADIUS[kind] * TILE if kind in [Biomes.T_ROCK, Biomes.T_BUSH] else StageVegetation.TRUNK.get(kind, 0.23) * TRUNK_FLARE) * batch.s[o]
			if kind == Biomes.T_ROCK: r *= 1.2
			if kind == Biomes.T_ROCK and batch.has("v") and RockModels.is_outcrop(batch.v[o]): r = RockModels.footprint(batch.v[o], batch.s[o] * 1.2)
			if r > 3.0:
				for gy in range(floori((z - r) / TILE), floori((z + r) / TILE) + 1):
					for gx in range(floori((x - r) / TILE), floori((x + r) / TILE) + 1):
						var key := Vector2i(gx, gy)
						if not _cells.has(key): _cells[key] = []
						_cells[key].append_array([x, z, r, -2 - (b << 20) - o, kind, batch.s[o]])
				continue
			_max_r = maxf(_max_r, r)
			var key := Vector2i(floori(x / TILE), floori(z / TILE))
			if not _cells.has(key): _cells[key] = []
			_cells[key].append_array([x, z, r, -2 - (b << 20) - o, kind, batch.s[o]])


func nature_around(mid: Vector2, radius: float) -> Array:
	var records := []
	var seen := {}
	for cy in range(floori((mid.y - radius) / TILE), floori((mid.y + radius) / TILE) + 1):
		for cx in range(floori((mid.x - radius) / TILE), floori((mid.x + radius) / TILE) + 1):
			var list: Array = _cells.get(Vector2i(cx, cy), [])
			for n in range(0, list.size(), 6):
				if seen.has(list[n + 3]): continue
				seen[list[n + 3]] = true
				for i in 6: records.append(list[n + i])
	return records


func objects_clear(x: float, z: float, rot: float, scale: float, box: AABB, radius: float, owner: int = -1) -> bool:
	var footprint := Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z))
	var reach := radius + _max_r
	var c := cos(rot)
	var s := sin(rot)
	for cy in range(floori((z - reach) / TILE), floori((z + reach) / TILE) + 1):
		for cx in range(floori((x - reach) / TILE), floori((x + reach) / TILE) + 1):
			var list: Array = _cells.get(Vector2i(cx, cy), [])
			for n in range(0, list.size(), 6):
				if list[n + 3] == owner:
					continue
				var dx: float = list[n] - x
				var dz: float = list[n + 1] - z
				var r: float = list[n + 2]
				if absf(dx) > radius + r or absf(dz) > radius + r:
					continue
				var local := Vector2(c * dx - s * dz, s * dx + c * dz) / scale
				if footprint.grow(r / scale).has_point(local):
					return false
	return true
