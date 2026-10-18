class_name StageVegetation
extends RefCounted
## Этап 8. Растительность и камни. Объекты раскладываются по чанкам, чтобы 3D-сцена быстро брала ближайшие.
## Пишет: w.obj_* (объекты: x, y, k — вид из Biomes.T_*, v — вариант, s — масштаб), w.chunks (номера объектов
## по чанкам), w.CS (сторона чанка в клетках), CW, CH (чанков по ширине и высоте), obj_count.

const PROGRESS := 0.76
const LABEL := "Леса, кустарники и камни"
const VILLAGE_R := 7.0 # полуширина квадрата вокруг поселения, клеток


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var N := w.N
	var rng := w.rng
	var biome := w.biome
	var river := w.river
	var slope := w.slope
	var temp := w.temp
	var dist_water := w.dist_water
	var forest := w.noise_field("forest")
	var path_src := PackedByteArray()
	path_src.resize(N)
	for i in N:
		path_src[i] = 1 if w.path_mask[i] > 0 else 0
	var dist_path := Grid.distance_field(W, H, path_src)
	# Окрестности поселений (квадрат ±7 клеток) и клетки под домами
	var village := PackedByteArray()
	village.resize(N)
	for s: Dictionary in w.settlements:
		for y in range(maxi(0, ceili(s.y - VILLAGE_R)), mini(H - 1, floori(s.y + VILLAGE_R)) + 1):
			for x in range(maxi(0, ceili(s.x - VILLAGE_R)), mini(W - 1, floori(s.x + VILLAGE_R)) + 1):
				village[y * W + x] = 1
	w.CS = WorldData.CHUNK_SIZE
	w.CW = ceili(float(W) / w.CS)
	w.CH = ceili(float(H) / w.CS)
	var store := ObjStore.new(w, village)
	# Свойства биомов в плоских таблицах: в цикле по всем клеткам словари читать дорого
	var b_water := PackedByteArray()
	var b_trees := PackedFloat64Array()
	var b_kinds: Array = []
	for bd: Dictionary in Biomes.LIST:
		b_water.append(1 if bd.get("water", false) else 0)
		b_trees.append(bd.get("trees", 0.0))
		b_kinds.append(bd.get("kinds", []))

	for y in H:
		for x in W:
			var i := y * W + x
			var bi := biome[i]
			if b_water[bi] != 0 or river[i] != 0:
				continue
			var dens := b_trees[bi]
			var f := forest[i]
			# smoothstep развёрнут на месте
			if dens > 0.3:
				var t := clampf((f + 0.35) / (0.15 + 0.35), 0.0, 1.0)
				dens *= t * t * (3.0 - 2.0 * t) # поляны в лесу
			else:
				var t := clampf((f - 0.1) / (0.5 - 0.1), 0.0, 1.0)
				dens *= 0.3 + 1.8 * (t * t * (3.0 - 2.0 * t)) # рощи в открытой местности
			if bi == Biomes.BEACH and temp[i] < 0.6:
				dens = 0.0
			if dist_path[i] < 1.2:
				continue
			if dist_path[i] < 2.5:
				dens *= 0.35
			if village[i] != 0:
				dens *= 0.08
			var kinds: Array = b_kinds[bi]
			# Порядок вызовов rng тот же, что в JS: x, y, вид, вариант, масштаб
			for k in 2:
				if rng.next_float() < dens * 0.6:
					var px := x + 0.1 + rng.next_float() * 0.8
					var py := y + 0.15 + rng.next_float() * 0.8
					var kind: int = kinds[floori(rng.next_float() * kinds.size())]
					var v := floori(rng.next_float() * 3)
					store.add(px, py, kind, v, 0.8 + rng.next_float() * 0.45)
			if slope[i] > 0.7 and rng.next_float() < 0.06:
				var px := x + rng.next_float()
				var py := y + rng.next_float()
				var v := floori(rng.next_float() * 3)
				store.add(px, py, Biomes.T_ROCK, v, 0.7 + rng.next_float() * 0.6)
			if dist_water[i] < 1.6 and (bi == Biomes.GRASS or bi == Biomes.FOREST or bi == Biomes.SWAMP) and rng.next_float() < 0.12:
				var px := x + rng.next_float()
				var py := y + rng.next_float()
				var v := floori(rng.next_float() * 3)
				store.add(px, py, Biomes.T_REED, v, 0.8 + rng.next_float() * 0.3)

	# Объекты в чанке — с севера на юг (при равных y — в порядке добавления, как стабильная сортировка JS)
	var oy := store.y
	var chunks: Array[PackedInt32Array] = []
	for list: Array in store.chunk_lists:
		list.sort_custom(func(a: int, b: int) -> bool: return oy[a] < oy[b] if oy[a] != oy[b] else a < b)
		chunks.append(PackedInt32Array(list))
	w.obj_x = store.x
	w.obj_y = store.y
	w.obj_k = store.k
	w.obj_v = store.v
	w.obj_s = store.s
	w.chunks = chunks
	w.obj_count = store.x.size()


static func near_hut(settlements: Array, ox: float, oy: float) -> bool:
	for s: Dictionary in settlements:
		if absf(s.x - ox) > VILLAGE_R or absf(s.y - oy) > VILLAGE_R:
			continue
		for u: Dictionary in s.huts:
			if absf(u.x - ox) < 0.75 and absf(u.y - oy) < 0.75:
				return true
	return false


## Список объектов растительности: столбцы чисел и номера объектов по чанкам
class ObjStore:
	var x := PackedFloat64Array()
	var y := PackedFloat64Array()
	var k := PackedInt32Array()
	var v := PackedInt32Array()
	var s := PackedFloat64Array()
	var chunk_lists: Array = []
	var w: WorldData
	var village: PackedByteArray

	func _init(world: WorldData, village_mask: PackedByteArray) -> void:
		w = world
		village = village_mask
		for c: int in w.CW * w.CH:
			chunk_lists.append([])

	func add(ox: float, oy: float, kind: int, variant: int, sc: float) -> void:
		if village[floori(oy) * w.W + floori(ox)] != 0 and StageVegetation.near_hut(w.settlements, ox, oy):
			return
		chunk_lists[floori(oy / w.CS) * w.CW + floori(ox / w.CS)].append(x.size())
		x.append(ox)
		y.append(oy)
		k.append(kind)
		v.append(variant)
		s.append(sc)
