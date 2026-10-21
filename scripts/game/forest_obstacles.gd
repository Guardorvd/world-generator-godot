class_name ForestObstacles
extends RefCounted
## С 7.7: крупные стволы, валуны и валежник рядом с игроком как препятствия для ходьбы и езды.
## Без узлов и физики движка: круги (стволы, валуны, сухостой) и капсулы (лежащие брёвна) в сетке
## по 2 м, только в радиусе REACH вокруг игрока; пересобирается при отходе на REBUILD или когда
## VegetationLayer разложил новый валежник. Кусты, трава, молодняк и мелкие камни проходимы.
## Низкое препятствие (бревно, небольшой валун) можно перепрыгнуть: оно не мешает, если ноги выше его верха.

const TILE := GameConfig.TILE
const CELL := 2.0       # сторона клетки сетки, м
const REACH := 24.0     # препятствия собираются в этом радиусе от игрока, м
const REBUILD := 6.0    # отошли дальше этого от места сборки — пересобрать, м
const MIN_SCALE := 0.6  # деревья мельче (молодняк) проходимы
const SNUG := 0.85      # круг ствола чуть уже видимого: задевание кроной и корой не держит
const STRIDE := 7       # ax, az, bx, bz, радиус, основание, верх
## радиус ствола у комля при масштабе 1, м (как в ForestModels и Models)
const TRUNK := {
	Biomes.T_BIRCH: 0.14, Biomes.T_PINE: 0.23, Biomes.T_SNOWPINE: 0.23, Biomes.T_OAK: 0.32,
	Biomes.T_JUNGLE: 0.32, Biomes.T_ACACIA: 0.3, Biomes.T_PALM: 0.25, Biomes.T_DEAD: 0.34, Biomes.T_CACTUS: 0.3,
}
const ROCK_R := 1.15    # валун: сфера 1,1 м, сплюснутая до 1,43 × 0,83 × 1,1, при масштабе 1
const ROCK_TOP := 1.07

var world: WorldData
var heights: Heightfield
var data := PackedFloat32Array()  # препятствия подряд по STRIDE
var _grid := {}                   # Vector2i(клетка) -> PackedInt32Array номеров (начало записи в data)
var _center := Vector2.INF
var _version := -1


func _init(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h


## Каждый такт: пересобрать, если игрок отошёл или подлесок обновился. details — валежник из
## VegetationLayer.obstacles (тот же формат), version — его счётчик обновлений.
func update(px: float, pz: float, details: PackedFloat32Array, version: int, force := false) -> void:
	if not force and version == _version and Vector2(px, pz).distance_to(_center) < REBUILD:
		return
	_center = Vector2(px, pz)
	_version = version
	data.clear()
	_grid.clear()
	_add_objects(px, pz)
	for n in range(0, details.size(), STRIDE):
		if Vector2(details[n], details[n + 1]).distance_to(_center) < REACH:
			_add(details[n], details[n + 1], details[n + 2], details[n + 3], details[n + 4], details[n + 5], details[n + 6])


## Деревья, валуны, сухие деревья и кактусы мира — те же, что рисует VegetationLayer
func _add_objects(px: float, pz: float) -> void:
	var side := world.CS * TILE
	for cy in range(maxi(0, floori((pz - REACH) / side)), mini(world.CH, floori((pz + REACH) / side) + 1)):
		for cx in range(maxi(0, floori((px - REACH) / side)), mini(world.CW, floori((px + REACH) / side) + 1)):
			for o in world.chunks[cy * world.CW + cx]:
				var kind := world.obj_k[o]
				var s := world.obj_s[o]
				if kind != Biomes.T_ROCK and (not TRUNK.has(kind) or s < MIN_SCALE):
					continue
				var x := world.obj_x[o] * TILE
				var z := world.obj_y[o] * TILE
				if absf(x - px) > REACH or absf(z - pz) > REACH:
					continue
				# на дорогах и в воде дерево не рисуется — не мешает и здесь
				if world.path_mask[floori(world.obj_y[o]) * world.W + floori(world.obj_x[o])] >= 2:
					continue
				var base := heights.ground_at(x, z)
				if kind == Biomes.T_ROCK:
					s *= 1.2
					_add(x, z, x, z, ROCK_R * s, base, base - 0.1 + ROCK_TOP * s)
				elif heights.depth_at(x, z) <= VegetationLayer.WATER_MARGIN:
					_add(x, z, x, z, TRUNK[kind] * s * SNUG, base, INF)


## Отрезок a–b толщиной r (у круга a = b), от основания base до верха top
func _add(ax: float, az: float, bx: float, bz: float, r: float, base: float, top: float) -> void:
	var at := data.size()
	data.append_array([ax, az, bx, bz, r, base, top])
	for cy in range(floori((minf(az, bz) - r) / CELL), floori((maxf(az, bz) + r) / CELL) + 1):
		for cx in range(floori((minf(ax, bx) - r) / CELL), floori((maxf(ax, bx) + r) / CELL) + 1):
			var key := Vector2i(cx, cy)
			var list: PackedInt32Array = _grid.get(key, PackedInt32Array())
			list.append(at)
			_grid[key] = list


## Задевает ли тело радиуса r в (x, z) с ногами на высоте feet какое-нибудь препятствие
func hits(x: float, z: float, feet: float, r: float) -> bool:
	return _nearest(x, z, feet, r) >= 0


## Нормаль от препятствия, которое задевает тело (наружу, длина 1), или ноль, если не задевает.
## По ней тело скользит вдоль ствола и бревна, а велосипед понимает, ударился ли в лоб.
func normal(x: float, z: float, feet: float, r: float) -> Vector2:
	var at := _nearest(x, z, feet, r)
	if at < 0:
		return Vector2.ZERO
	var c := _closest(at, x, z)
	var d := Vector2(x, z) - c
	if d.length_squared() < 1e-8:
		return Vector2.ZERO
	return d.normalized()


## Номер самого глубоко задетого препятствия или -1
func _nearest(x: float, z: float, feet: float, r: float) -> int:
	if data.is_empty():
		return -1
	var best := -1
	var depth := 0.0
	for cy in range(floori((z - r) / CELL), floori((z + r) / CELL) + 1):
		for cx in range(floori((x - r) / CELL), floori((x + r) / CELL) + 1):
			var list: Variant = _grid.get(Vector2i(cx, cy))
			if list == null:
				continue
			for at: int in list:
				if feet >= data[at + 6]:
					continue
				var reach := data[at + 4] + r
				var gap := reach - Vector2(x, z).distance_to(_closest(at, x, z))
				if gap > depth:
					depth = gap
					best = at
	return best


## Ближайшая к (x, z) точка оси препятствия
func _closest(at: int, x: float, z: float) -> Vector2:
	var a := Vector2(data[at], data[at + 1])
	var ab := Vector2(data[at + 2], data[at + 3]) - a
	var ln := ab.length_squared()
	if ln < 1e-8:
		return a
	return a + ab * clampf((Vector2(x, z) - a).dot(ab) / ln, 0.0, 1.0)
