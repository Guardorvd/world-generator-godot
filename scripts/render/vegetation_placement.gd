extends RefCounted
## Общие проверки размещения. Только CPU, используется фоновой задачей растительности.

const TILE := GameConfig.TILE
const Plants := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
var world: WorldData
var heights: Heightfield
var occupied: Array[AABB] = [] # несколько крупных деталей в ближнем круге (только через occupy и clear_occupied)
var _occ_cells := {} # Vector2i(клетка мира) -> PackedInt32Array номеров в occupied: травинка смотрит 1–4 клетки, а не весь список
var _cells := {} # Vector2i(клетка) -> [x, z, радиус, объект, ...], см. prepare
var _max_r := 0.0


func _init(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h


## Сначала валежник/камни, затем кусты/молодняк, затем мягкая подстилка и растения.
static func priority(kind: int) -> int:
	if kind - Floor.FIRST in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STONES]:
		return 0
	if kind in [Plants.BUSH, Plants.SAPLING, Plants.PINE, Plants.YOUNG, Plants.YOUNG_PINE]:
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
			if absf(point.y + 0.015 - heights.ground_at(point.x, point.z)) > 0.18:
				return false
	return true


## Проверяем весь след у воды, дорог и домов; шаг не больше метра.
func ground_clear(x: float, z: float, radius: float) -> bool:
	if StageVegetation.near_hut(world.settlements, x / TILE, z / TILE, radius / TILE + 0.3) \
			or StageVegetation.near_hut(world.sites, x / TILE, z / TILE, radius / TILE + 0.3):
		return false
	var steps := ceili(radius * 2.0)
	var rc := world.river_cells() # коридор ленты реки, как у генератора растительности
	for j in steps + 1:
		for i in steps + 1:
			var px := x + lerpf(-radius, radius, float(i) / maxi(1, steps))
			var pz := z + lerpf(-radius, radius, float(j) / maxi(1, steps))
			var cx := floori(px / TILE)
			var cy := floori(pz / TILE)
			if cx < 0 or cy < 0 or cx >= world.W or cy >= world.H:
				return false
			var k := cy * world.W + cx
			if world.path_mask[k] > 0 or rc[k] != 0:
				return false
			if heights.road_refinement != null and heights.road_refinement.weight_at(px, pz, world.W) > 0.08:
				return false
			# Озеро/море могут покрывать край соседней сухой клетки: важна глубина в точке.
			if heights.depth_at(px, pz) > 0.0:
				return false
	return true


## Один раз на обновление: стволы, валуны и кусты вокруг игрока раскладываются по клеткам мира,
## чтобы проверка детали или травинки смотрела несколько соседних клеток, а не целые чанки.
func prepare(px: float, pz: float, radius: float) -> void:
	_cells.clear()
	_max_r = 0.0
	var side := world.CS * TILE
	for cy in range(maxi(0, floori((pz - radius) / side)), mini(world.CH, ceili((pz + radius) / side))):
		for cx in range(maxi(0, floori((px - radius) / side)), mini(world.CW, ceili((px + radius) / side))):
			for o in world.chunks[cy * world.CW + cx]:
				var kind := world.obj_k[o]
				if not Biomes.is_tree(kind) and kind not in [Biomes.T_ROCK, Biomes.T_BUSH, Biomes.T_DEAD, Biomes.T_CACTUS]:
					continue
				var r := 0.3 * world.obj_s[o]
				if kind == Biomes.T_ROCK or kind == Biomes.T_BUSH:
					r = Biomes.CROWN_RADIUS[kind] * TILE * world.obj_s[o] * (1.2 if kind == Biomes.T_ROCK else 1.0)
				_max_r = maxf(_max_r, r)
				var cell := Vector2i(floori(world.obj_x[o]), floori(world.obj_y[o]))
				if not _cells.has(cell):
					_cells[cell] = []
				_cells[cell].append_array([world.obj_x[o] * TILE, world.obj_y[o] * TILE, r, o])


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
