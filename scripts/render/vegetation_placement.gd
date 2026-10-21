extends RefCounted
## Общие проверки размещения. Только CPU, используется фоновой задачей растительности.

const TILE := GameConfig.TILE
const Plants := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
var world: WorldData
var heights: Heightfield
var occupied: Array[AABB] = [] # несколько крупных деталей в ближнем круге


func _init(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h


## Сначала валежник/камни, затем кусты/молодняк, затем мягкая подстилка и растения.
static func priority(kind: int) -> int:
	if kind - Floor.FIRST in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STONES]:
		return 0
	if kind in [Plants.BUSH, Plants.SAPLING, Plants.PINE]:
		return 1
	return 2


func details_clear(box: AABB) -> bool:
	for obstacle in occupied:
		if obstacle.intersects(box):
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
	if StageVegetation.near_hut(world.settlements, x / TILE, z / TILE, radius / TILE + 0.3):
		return false
	var steps := ceili(radius * 2.0)
	for j in steps + 1:
		for i in steps + 1:
			var px := x + lerpf(-radius, radius, float(i) / maxi(1, steps))
			var pz := z + lerpf(-radius, radius, float(j) / maxi(1, steps))
			var cx := floori(px / TILE)
			var cy := floori(pz / TILE)
			if cx < 0 or cy < 0 or cx >= world.W or cy >= world.H:
				return false
			var k := cy * world.W + cx
			if world.path_mask[k] > 0 or world.river[k] != 0:
				return false
			if heights.road_refinement != null and heights.road_refinement.weight_at(px, pz, world.W) > 0.08:
				return false
			# Озеро/море могут покрывать край соседней сухой клетки: важна глубина в точке.
			if heights.depth_at(px, pz) > 0.0:
				return false
	return true


func objects_clear(x: float, z: float, rot: float, scale: float, box: AABB, radius: float, owner: int = -1) -> bool:
	var footprint := Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z))
	# Запас покрывает самый большой валун и ствол за краем соседнего чанка.
	var reach := radius + 4.0
	var side := world.CS * TILE
	for cy in range(maxi(0, floori((z - reach) / side)), mini(world.CH, ceili((z + reach) / side))):
		for cx in range(maxi(0, floori((x - reach) / side)), mini(world.CW, ceili((x + reach) / side))):
			for o in world.chunks[cy * world.CW + cx]:
				if o == owner:
					continue
				var kind := world.obj_k[o]
				if not Biomes.is_tree(kind) and kind not in [Biomes.T_ROCK, Biomes.T_BUSH, Biomes.T_DEAD, Biomes.T_CACTUS]:
					continue
				var r := 0.3 * world.obj_s[o]
				if kind == Biomes.T_ROCK or kind == Biomes.T_BUSH:
					r = Biomes.CROWN_RADIUS[kind] * TILE * world.obj_s[o] * (1.2 if kind == Biomes.T_ROCK else 1.0)
				var dx := world.obj_x[o] * TILE - x
				var dz := world.obj_y[o] * TILE - z
				var local := Vector2(cos(rot) * dx - sin(rot) * dz, sin(rot) * dx + cos(rot) * dz) / scale
				if footprint.grow(r / scale).has_point(local):
					return false
	return true
