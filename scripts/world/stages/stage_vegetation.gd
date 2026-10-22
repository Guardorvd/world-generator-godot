class_name StageVegetation
extends RefCounted
## Этап 8. Растительность и камни. Объекты раскладываются по чанкам, чтобы 3D-сцена быстро брала ближайшие.
## 6.3: массивы, поляны, молодняк и старый лес; соседство и отступы учитывают размер крон.
## Вид, густота и размер также зависят от природных условий 6.2; валуны лежат россыпями.
## Пишет: w.obj_* (объекты: x, y, k — вид из Biomes.T_*, v — вариант, s — масштаб), w.chunks (номера объектов
## по чанкам), w.CS (сторона чанка в клетках), CW, CH (чанков по ширине и высоте), obj_count.

const PROGRESS := 0.76
const LABEL := "Леса, кустарники и камни"
const VILLAGE_R := 7.0 # полуширина квадрата вокруг поселения, клеток
# С 2.8 растительность следует характеру местности (высота, крутизна, вода), а не только биому
const HIGH_LO := 0.12    # с этой высоты в лесах прибавляется хвойных
const HIGH_HI := 0.26    # выше — почти одни хвойные
const LINE_LO := 0.2     # граница леса: с этой высоты деревья редеют и мельчают
const LINE_HI := 0.4     # а здесь их остаётся треть
const STEEP := 0.6       # крутизна, с которой деревьев меньше, а камней больше
const SHORE := 3.0       # клеток до воды: прибрежные рощи, оазисы, тростник


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var N := w.N
	# Лес не расходует общий поток: его густота больше не меняет имена озёр.
	var rng := WGRandom.new(w.seed_num ^ 0x63f07e57)
	var biome := w.biome
	var river := w.river_cells()
	var slope := w.slope
	var temp := w.temp
	var dist_water := w.dist_water
	var elev := w.elev
	var moist := w.moist
	var forest := w.noise_field("forest")
	var stony := w.noise_field("cost") # тот же шум, что и у стоимости троп: россыпи валунов пятнами
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
	var store := ObjStore.new(w)
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
			var e := elev[i]
			var sl := slope[i]
			var dw := dist_water[i]
			var light := StageClimate.natural_conditions(w, x, y).x
			# Один медленный шум задаёт возраст участка и плавную смену сообщества.
			var age := _ss(-0.45, 0.45, w.noise.forest.fbm(x / 78.0 + 91.0, y / 78.0 - 47.0, 2)) # = age_at, без лишнего вызова
			# smoothstep развёрнут на месте
			var interior := 0.0 # насколько клетка в глубине леса (0 — опушка или поле)
			if dens > 0.3:
				var t := clampf((f + 0.35) / (0.15 + 0.35), 0.0, 1.0)
				interior = t * t * (3.0 - 2.0 * t)
				dens *= interior * _ss(-0.45, -0.12, stony[i]) * lerpf(1.35, 0.75, age)
			else:
				var t := clampf((f - 0.1) / (0.5 - 0.1), 0.0, 1.0)
				dens *= 0.3 + 1.8 * (t * t * (3.0 - 2.0 * t)) # рощи в открытой местности
				# у воды в сухих и открытых краях — прибрежные рощи и оазисы
				if dw < SHORE and _dry_open(bi) and temp[i] > 0.24:
					dens += 0.22 * (1.0 - dw / SHORE)
			# Влажные защищённые места поддерживают лес, сухие склоны разрежают его.
			if bi == Biomes.FOREST or bi == Biomes.TAIGA or bi == Biomes.JUNGLE or bi == Biomes.GRASS:
				dens *= (0.55 + 0.65 * _ss(0.2, 0.75, moist[i])) * (1.08 - 0.16 * light)
			if bi == Biomes.BEACH and temp[i] < 0.6:
				dens = 0.0
			# граница леса в горах и редкие деревья на кручах
			# вызов функции на каждую клетку заметен по времени: большинство клеток ниже границы леса
			var line := 0.0 if e <= LINE_LO else _ss(LINE_LO, LINE_HI, e)
			if line > 0.0 and bi != Biomes.SNOW and bi != Biomes.ROCK and bi != Biomes.PEAK:
				dens *= 1.0 - 0.65 * line
			if sl > STEEP:
				dens /= 1.0 + (sl - STEEP) * 1.5
			if dist_path[i] < 1.2:
				continue
			if dist_path[i] < 2.5:
				dens *= 0.35
			if village[i] != 0:
				dens *= 0.08
			var kinds: Array = b_kinds[bi]
			# Числа rng на объект: проверка, x, y, вид, вариант, масштаб
			for k in 2:
				if rng.next_float() < dens * 0.6:
					var px := x + 0.1 + rng.next_float() * 0.8
					var py := y + 0.15 + rng.next_float() * 0.8
					var community_moist := clampf(moist[i] + (age - 0.5) * 0.22, 0.0, 1.0)
					var kind := _kind(bi, kinds, rng.next_float(), e, community_moist, sl, dw, temp[i], light, interior)
					var v := floori(rng.next_float() * 3)
					var sc := tree_scale(age, interior, line, moist[i], rng.next_float()) if Biomes.is_tree(kind) else 0.8 + rng.next_float() * 0.45
					store.add(px, py, kind, v, sc)
			# камни: на кручах и россыпями там, где местность неровная
			var rocky := 0.06 if sl > 0.7 else 0.0
			if sl > 0.25 and stony[i] > 0.3:
				rocky += 0.05 * clampf((stony[i] - 0.3) * 4.0, 0.0, 1.0) * clampf(sl, 0.0, 1.0)
			if rocky > 0.0 and rng.next_float() < rocky:
				var px := x + rng.next_float()
				var py := y + rng.next_float()
				var v := floori(rng.next_float() * 3)
				store.add(px, py, Biomes.T_ROCK, v, 0.7 + rng.next_float() * 0.6)
			if dw < 1.6 and _reedy(bi) and sl < 0.5 and temp[i] > 0.24 and moist[i] > 0.48 and rng.next_float() < 0.12:
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


static func _ss(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## 0 — молодой участок, 1 — старый лес. 8.2: тот же шум задаёт подлесок и характер леса.
static func age_at(w: WorldData, x: float, y: float) -> float:
	if not w.noise.has("forest"):
		return 0.5 # тестовые миры без шумов
	return _ss(-0.45, 0.45, w.noise.forest.fbm(x / 78.0 + 91.0, y / 78.0 - 47.0, 2))


## Возраст — характер участка, а не симуляция лет. Под старым пологом есть молодые деревья.
static func tree_scale(age: float, interior: float, line: float, moist: float, r: float) -> float:
	var size := lerpf(0.5, 1.6, age) * (0.85 + r * 0.3)
	if r < 0.18 * age:
		size *= 0.42
	return size * (0.82 + 0.18 * interior) * (1.0 - 0.3 * line) * (0.85 + 0.15 * moist)


## Локальный полог готового леса для травы. Только ближайшие чанки, без новой карты теней.
static func canopy_at(w: WorldData, px: float, py: float) -> float:
	var cover := 0.0
	for cy in range(maxi(0, floori((py - 2.5) / w.CS)), mini(w.CH - 1, floori((py + 2.5) / w.CS)) + 1):
		for cx in range(maxi(0, floori((px - 2.5) / w.CS)), mini(w.CW - 1, floori((px + 2.5) / w.CS)) + 1):
			for o in w.chunks[cy * w.CW + cx]:
				if not Biomes.is_tree(w.obj_k[o]):
					continue
				var r: float = Biomes.CROWN_RADIUS[w.obj_k[o]] * w.obj_s[o] + 0.5
				var d := Vector2(px - w.obj_x[o], py - w.obj_y[o]).length()
				cover += maxf(0.0, 1.0 - d / r)
	return minf(1.0, cover)


## Сухие и открытые биомы, где у воды появляются рощи
static func _dry_open(bi: int) -> bool:
	return bi == Biomes.DESERT or bi == Biomes.SAVANNA or bi == Biomes.STEPPE or bi == Biomes.TUNDRA or bi == Biomes.GRASS


## Где у самой воды растёт тростник
static func _reedy(bi: int) -> bool:
	return bi == Biomes.GRASS or bi == Biomes.FOREST or bi == Biomes.SWAMP or bi == Biomes.TAIGA or bi == Biomes.STEPPE or bi == Biomes.SAVANNA


## Вид объекта по местности. r — случайное число 0..1, e — высота, m — влажность, sl — крутизна,
## dw — клеток до воды. Без особых условий — вид из списка биома, как раньше
static func _kind(bi: int, kinds: Array, r: float, e: float, m: float, sl: float, dw: float, t: float, light: float, interior: float) -> int:
	var shore := dw < SHORE
	# Ограничение действует и на специальные сообщества ниже.
	if sl > 1.0 and r < 0.4:
		return Biomes.T_ROCK if r < 0.2 else Biomes.T_BUSH
	match bi:
		Biomes.FOREST, Biomes.GRASS:
			# Пятна лесного шума задают опушки и сообщества, условия — их состав.
			var pine := 0.1 + 0.5 * _ss(HIGH_LO, HIGH_HI, e) + 0.25 * (1.0 - m) + 0.1 * light
			var birch := 0.12 + 0.18 * m + 0.12 * (1.0 - interior)
			if bi == Biomes.GRASS and m < 0.35:
				return Biomes.T_BUSH if r < 0.75 else Biomes.T_PINE
			if r < pine:
				return Biomes.T_PINE
			if r < pine + birch:
				return Biomes.T_BIRCH
			return Biomes.T_OAK if r < 0.94 or interior > 0.75 else Biomes.T_BUSH
		Biomes.TAIGA:
			if r < (0.08 + 0.22 * m) * (1.0 - 0.5 * _ss(HIGH_LO, HIGH_HI, e)):
				return Biomes.T_BIRCH
			if e > HIGH_HI:
				return Biomes.T_PINE
		Biomes.DESERT:
			if shore:
				return Biomes.T_PALM if t > 0.65 and r < 0.7 else Biomes.T_BUSH # оазис
		Biomes.SAVANNA:
			if shore and t > 0.65 and r < 0.4:
				return Biomes.T_PALM
		Biomes.STEPPE, Biomes.TUNDRA:
			if shore and t > 0.24:
				return Biomes.T_BIRCH if r < 0.45 else Biomes.T_BUSH
		Biomes.ROCK:
			# нижние скалы ещё в соснах, верхние — голый камень
			return Biomes.T_PINE if e < 0.3 and r < 0.5 else Biomes.T_ROCK
		Biomes.JUNGLE:
			if e > HIGH_HI and r < 0.5:
				return Biomes.T_PINE
	return kinds[floori(r * kinds.size())]


static func near_hut(settlements: Array, ox: float, oy: float, radius: float = 0.0) -> bool:
	for s: Dictionary in settlements:
		if absf(s.x - ox) > VILLAGE_R + radius or absf(s.y - oy) > VILLAGE_R + radius:
			continue
		for u: Dictionary in s.huts:
			if absf(u.x - ox) < 0.75 + radius and absf(u.y - oy) < 0.75 + radius:
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
	# Временный индекс соседей: головы списков по клеткам и ссылки по объектам.
	# В готовом WorldData остаются только прежние obj_* и chunks.
	var heads := PackedInt32Array()
	var next := PackedInt32Array()

	func _init(world: WorldData) -> void:
		w = world
		heads.resize(w.N)
		heads.fill(-1)
		for c: int in w.CW * w.CH:
			chunk_lists.append([])

	func add(ox: float, oy: float, kind: int, variant: int, sc: float) -> void:
		var radius: float = Biomes.CROWN_RADIUS[kind] * sc
		if StageVegetation.near_hut(w.settlements, ox, oy, radius):
			return
		var cx := floori(ox)
		var cy := floori(oy)
		# Увеличенные кроны не заходят на полотно. Животные тропы тоже сохраняются.
		var reach := ceili(radius + 1.0)
		for yy in range(maxi(0, cy - reach), mini(w.H, cy + reach + 1)):
			for xx in range(maxi(0, cx - reach), mini(w.W, cx + reach + 1)):
				if w.path_mask[yy * w.W + xx] == 0:
					continue
				var dx := maxf(maxf(xx - ox, ox - xx - 1.0), 0.0)
				var dy := maxf(maxf(yy - oy, oy - yy - 1.0), 0.0)
				if dx * dx + dy * dy < (radius + 0.25) ** 2:
					return
		# Кроны могут частично перекрываться, но стволы и крупные объекты не слипаются.
		# Максимальный масштаб дерева < 1.85; поиск ±3 клетки покрывает любую пару.
		for yy in range(maxi(0, cy - 3), mini(w.H, cy + 4)):
			for xx in range(maxi(0, cx - 3), mini(w.W, cx + 4)):
				var o := heads[yy * w.W + xx]
				while o != -1:
					var gap: float = 0.18 + 0.55 * (radius + Biomes.CROWN_RADIUS[k[o]] * s[o])
					if Vector2(ox - x[o], oy - y[o]).length_squared() < gap * gap:
						return
					o = next[o]
		var cell := cy * w.W + cx
		next.append(heads[cell])
		heads[cell] = x.size()
		chunk_lists[floori(oy / w.CS) * w.CW + floori(ox / w.CS)].append(x.size())
		x.append(ox)
		y.append(oy)
		k.append(kind)
		v.append(variant)
		s.append(sc)
