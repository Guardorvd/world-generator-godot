extends RefCounted
## Общие проверки размещения. Только CPU, используется фоновой задачей растительности.

const TILE := GameConfig.TILE
const Plants := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
var world: WorldData
var heights: Heightfield
var use_dry_cache := true
var _base_ground := false
var _safe_cells := {}
var regions := {} # immutable snapshot supplied by the vegetation worker
var occupied: Array[AABB] = [] # несколько крупных деталей в ближнем круге (только через occupy и clear_occupied)
var _occ_cells := {} # Vector2i(клетка мира) -> PackedInt32Array номеров в occupied: травинка смотрит 1–4 клетки, а не весь список
var _cells := {} # Vector2i(клетка) -> [x, z, радиус, объект, ...], см. prepare
var _max_r := 0.0


func _init(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h
	_base_ground = h.get_script() != null and h.get_script().resource_path == "res://scripts/game/heightfield.gd"


## Сначала валежник/камни, затем кусты/молодняк, затем мягкая подстилка и растения.
static func priority(kind: int) -> int:
	if kind - Floor.FIRST in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STONES, Floor.STUMP, Floor.BOULDER]:
		return 0
	if kind in [Plants.BUSH, Plants.SAPLING, Plants.PINE, Plants.YOUNG, Plants.YOUNG_PINE] or Plants.is_shrub(kind):
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
func terrain_fits(xf: Transform3D, box: AABB) -> bool:
	for j in 3:
		for i in 3:
			var point := xf * Vector3(lerpf(box.position.x, box.end.x, i * 0.5), 0.0, lerpf(box.position.z, box.end.z, j * 0.5))
			if absf(point.y + 0.015 - ground_at(point.x, point.z)) > 0.18:
				return false
	return true


## Проверяем весь след у воды, дорог и домов; шаг не больше метра.
func ground_clear(x: float, z: float, radius: float) -> bool:
	if StageVegetation.near_hut(world.settlements, x / TILE, z / TILE, radius / TILE + 0.3) \
			or StageVegetation.near_hut(world.sites, x / TILE, z / TILE, radius / TILE + 0.3):
		return false
	if use_dry_cache and _base_ground and _safe_footprint(x, z, radius): return true
	var steps := ceili(radius * 2.0)
	var rc := world.river_cells() # коридор ленты реки, как у генератора растительности
	for j in steps + 1:
		for i in steps + 1:
			var px := x + lerpf(-radius, radius, float(i) / maxi(1, steps))
			var pz := z + lerpf(-radius, radius, float(j) / maxi(1, steps))
			var cx := floori(px / TILE)
			var cy := floori(pz / TILE)
			if cx < 0 or cy < 0 or cx >= world.W or cy >= world.H:
				var at := region_cell(cx, cy)
				if at.is_empty(): return false
				var f: Dictionary = at[0]
				var q: int = at[1]
				if f.path[q] > 0 or f.river[q] != 0 or f.lake[q] != 0 or f.h[q] <= 0.0:
					return false
				if f.has("village") and f.village[q] != 0: return false
				if not surface_known(px, pz): return false
				if f.has("water_level") and f.water_level[q] * GameConfig.HS > ground_at(px, pz): return false
				continue
			var k := cy * world.W + cx
			if world.path_mask[k] > 0 or rc[k] != 0:
				return false
			if heights.road_refinement != null and heights.road_refinement.weight_at(px, pz, world.W) > 0.08:
				return false
			# Озеро/море могут покрывать край соседней сухой клетки: важна глубина в точке.
			if heights.depth_at(px, pz) > 0.0:
				return false
	return true


## Exact fast acceptance, not a sampled approximation: all ground vertices are dry,
## no water triangles/lake corners or road-refinement patch can influence these cells.
## Ambiguous cells and Heightfield subclasses keep the existing point-by-point checks.
func _safe_footprint(x: float, z: float, radius: float) -> bool:
	for j in range(floori((z - radius) / TILE), floori((z + radius) / TILE) + 1):
		for i in range(floori((x - radius) / TILE), floori((x + radius) / TILE) + 1):
			if i < 0 or j < 0 or i >= world.W or j >= world.H:
				var key := Vector2i(i, j)
				if not _safe_cells.has(key): _safe_cells[key] = _safe_region_cell(i, j)
				if not _safe_cells[key]: return false
				continue
			if i < 1 or j < 1 or i >= world.W - 1 or j >= world.H - 1: return false
			var cell := j * world.W + i
			if not _safe_cells.has(cell): _safe_cells[cell] = _safe_cell(i, j, cell)
			if not _safe_cells[cell]: return false
	return true


func _safe_cell(i: int, j: int, cell: int) -> bool:
	if world.path_mask[cell] > 0 or world.river_cells()[cell] != 0 or heights._river_cells.has(cell): return false
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n := (j + dy) * world.W + i + dx
			if world.lake[n] != 0 or heights.hv[n] < 0.0: return false
	if heights.road_refinement != null:
		for dy in [-1, 0]:
			for dx in [-1, 0]:
				if heights.road_refinement.patches.has((j + dy) * world.W + i + dx): return false
	return true


func _safe_region_cell(i: int, j: int) -> bool:
	var at := region_cell(i, j)
	if at.is_empty(): return false
	var f: Dictionary = at[0]
	var q: int = at[1]
	if f.path[q] != 0 or (f.has("village") and f.village[q] != 0): return false
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var neighbour := region_cell(i + dx, j + dy)
			if neighbour.is_empty(): return false
			var g: Dictionary = neighbour[0]
			var n: int = neighbour[1]
			if g.h[n] <= 0.0 or g.river[n] != 0 or g.lake[n] != 0: return false
			if g.has("water_level") and g.water_level[n] > 0.0: return false
	return true


## Один раз на обновление: стволы, валуны и кусты вокруг игрока раскладываются по клеткам мира,
## чтобы проверка детали или травинки смотрела несколько соседних клеток, а не целые чанки.
func prepare(px: float, pz: float, radius: float, outer_trees := {}) -> void:
	_cells.clear()
	_safe_cells.clear()
	_max_r = 0.0
	var side := world.CS * TILE
	for cy in range(maxi(0, floori((pz - radius) / side)), mini(world.CH, ceili((pz + radius) / side))):
		for cx in range(maxi(0, floori((px - radius) / side)), mini(world.CW, ceili((px + radius) / side))):
			for o in world.chunks[cy * world.CW + cx]:
				var kind := world.obj_k[o]
				if not Biomes.is_tree(kind) and kind not in [Biomes.T_ROCK, Biomes.T_BUSH, Biomes.T_DEAD, Biomes.T_CACTUS]:
					continue
				_index_object(world.obj_x[o], world.obj_y[o], kind, world.obj_s[o], o)
	for cy in range(floori((pz - radius) / side), floori((pz + radius) / side) + 1):
		for cx in range(floori((px - radius) / side), floori((px + radius) / side) + 1):
			var items: Dictionary = outer_trees.get(Vector2i(cx, cy), {})
			if items.is_empty(): continue
			for o in items.x.size():
				_index_object(items.x[o], items.y[o], items.k[o], items.s[o], -2)


func _index_object(x: float, y: float, kind: int, scale: float, owner: int) -> void:
	if not Biomes.is_tree(kind) and kind not in [Biomes.T_ROCK, Biomes.T_BUSH, Biomes.T_DEAD, Biomes.T_CACTUS]: return
	var radius: float = (ForestObstacles.TRUNK[kind] if Biomes.is_relict(kind) else 0.3) * scale
	if kind in [Biomes.T_ROCK, Biomes.T_BUSH]:
		radius = Biomes.CROWN_RADIUS[kind] * TILE * scale * (1.2 if kind == Biomes.T_ROCK else 1.0)
	_max_r = maxf(_max_r, radius)
	var cell := Vector2i(floori(x), floori(y))
	if not _cells.has(cell): _cells[cell] = []
	_cells[cell].append_array([x * TILE, y * TILE, radius, owner])


func region_cell(i: int, j: int) -> Array:
	var size := WorldData.REGION_SIZE
	var region: Dictionary = regions.get(Vector2i(floori(float(i) / size), floori(float(j) / size)), {})
	if not region.has("fields"): return []
	var rect: Rect2i = region.rect
	if not rect.has_point(Vector2i(i, j)): return []
	return [region.fields, (j - rect.position.y) * rect.size.x + i - rect.position.x]


func surface_known(x: float, z: float) -> bool:
	var i := floori(x / TILE - 0.5)
	var j := floori(z / TILE - 0.5)
	for dy in 2:
		for dx in 2:
			var cx := i + dx
			var cy := j + dy
			if cx >= 0 and cy >= 0 and cx < world.W and cy < world.H: continue
			if region_cell(cx, cy).is_empty(): return false
	return true


func ground_at(x: float, z: float) -> float:
	return heights.ground_at(x, z) if regions.is_empty() else RegionStream.snapshot_ground(world, heights, regions, x, z)



func objects_clear(x: float, z: float, rot: float, scale: float, box: AABB, radius: float, owner: int = -1) -> bool:
	var footprint := Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z))
	var reach := radius + _max_r
	var c := cos(rot)
	var s := sin(rot)
	for cy in range(floori((z - reach) / TILE), floori((z + reach) / TILE) + 1):
		for cx in range(floori((x - reach) / TILE), floori((x + reach) / TILE) + 1):
			var list: Array = _cells.get(Vector2i(cx, cy), [])
			for n in range(0, list.size(), 4):
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
