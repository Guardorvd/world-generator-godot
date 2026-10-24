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
const MassiveForest := preload("res://scripts/world/massive_forest.gd")
const LAYER := 1         # слой растительности в WGRandom.hash_cell (с 8.4)
# 9.1: лесистость местности — медленный шум лесного Simplex (крупнейшая волна около 1,7 км, мельчайшая ~200 м)
# плюс доля лесов всего мира по сиду. Зависит только от клетки, поэтому массивы идут через границы областей.
const WOOD_SCALE := 420.0
const WOOD_OCT := 4
const WOOD_OX := -133.0
const WOOD_OY := 271.0
const SPREAD := 0.55     # насколько густо массив заходит из леса на соседние луга
# 9.2: строение массива. Древостой (около 220 м): густые и редкие участки, хвойные или лиственные пятна.
# Поляны (около 80 м): открытые места в глубине леса с мягкой опушкой.
const STAND_SCALE := 56.0
const STAND_OX := 17.0
const STAND_OY := -83.0
const GLADE_SCALE := 20.0
const GLADE_OX := -61.0
const GLADE_OY := 39.0


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	w.CS = WorldData.CHUNK_SIZE
	w.CW = ceili(float(W) / w.CS)
	w.CH = ceili(float(H) / w.CS)
	var f := fields(w)
	# С 8.4 каждый чанк раскладывается сам по себе (см. place_chunk), тем же кодом, что и чанки за краем карты.
	# С 12.2 ряды чанков считаются на всех ядрах (Parallel.bands), каждый в свой список; списки склеиваются
	# по порядку рядов, поэтому номера объектов те же, что при обходе подряд.
	var CS := w.CS
	var CW := w.CW
	var seed_num := w.seed_num
	var job := func(c0: int, c1: int) -> ObjStore:
		var st := ObjStore.new(w)
		for cy in range(c0, c1):
			for cx in CW:
				var x0 := cx * CS
				var y0 := cy * CS
				place_chunk(seed_num, x0, y0, mini(W, x0 + CS), mini(H, y0 + CS), f, 0, 0, W, w, st)
		# Объекты в чанке — с севера на юг (при равных y — в порядке добавления, как стабильная сортировка JS)
		var oy := st.y
		for c in range(c0 * CW, c1 * CW):
			st.chunk_lists[c].sort_custom(func(a: int, b: int) -> bool: return oy[a] < oy[b] if oy[a] != oy[b] else a < b)
		return st
	var rows := Parallel.bands(w.CH, job, 1)
	var chunks: Array[PackedInt32Array] = []
	chunks.resize(CW * w.CH)
	var ox := PackedFloat64Array()
	var oy := PackedFloat64Array()
	var ok := PackedInt32Array()
	var ov := PackedInt32Array()
	var os := PackedFloat64Array()
	for cy in rows.size():
		var st: ObjStore = rows[cy]
		var base := ox.size()
		for c in range(cy * CW, (cy + 1) * CW):
			var list := PackedInt32Array(st.chunk_lists[c])
			for j in list.size():
				list[j] += base
			chunks[c] = list
		ox.append_array(st.x)
		oy.append_array(st.y)
		ok.append_array(st.k)
		ov.append_array(st.v)
		os.append_array(st.s)
	w.obj_x = ox
	w.obj_y = oy
	w.obj_k = ok
	w.obj_v = ov
	w.obj_s = os
	w.chunks = chunks
	w.obj_count = ox.size()


## Поля стартовой области для place_chunk (stride W, угол 0, 0)
static func fields(w: WorldData) -> Dictionary:
	var W := w.W
	var H := w.H
	var N := w.N
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
	for s: SettlementData in w.settlements:
		for y in range(maxi(0, ceili(s.y - VILLAGE_R)), mini(H - 1, floori(s.y + VILLAGE_R)) + 1):
			for x in range(maxi(0, ceili(s.x - VILLAGE_R)), mini(W - 1, floori(s.x + VILLAGE_R)) + 1):
				village[y * W + x] = 1
	# Поляны у хуторов, домов и вышек (с 9.3); руины остаются в лесу
	for s: SiteData in w.sites:
		var r: float = s.clear
		for y in range(maxi(0, ceili(s.y - r)), mini(H - 1, floori(s.y + r)) + 1):
			for x in range(maxi(0, ceili(s.x - r)), mini(W - 1, floori(s.x + r)) + 1):
				if Grid.hypot(x + 0.5 - s.x, y + 0.5 - s.y) < r:
					village[y * W + x] = 1
	# С 12.2 освещённость склона и возраст леса — готовыми полями, как за краем карты (OuterLand):
	# чанки идут в нескольких потоках, а общий шум и вызовы чужого класса на каждой клетке их тормозят
	var light_job := func(y0: int, y1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((y1 - y0) * W)
		for y in range(y0, y1):
			for x in W:
				# = StageClimate.natural_conditions(w, x, y).x, развёрнут
				var gx := (elev[y * W + mini(W - 1, x + 1)] - elev[y * W + maxi(0, x - 1)]) * 30.0
				var gy := (elev[mini(H - 1, y + 1) * W + x] - elev[maxi(0, y - 1) * W + x]) * 30.0
				out[(y - y0) * W + x] = Vector2(clampf(0.5 - 0.5 * gy / sqrt(1.0 + gx * gx + gy * gy), 0.0, 1.0), 0.0).x
		return out
	var light := PackedFloat32Array()
	for part: PackedFloat32Array in Parallel.bands(H, light_job):
		light.append_array(part)
	var age_n := Parallel.fbm_rect(w.noise.forest, 0, 0, W, H, 78.0, 2, 91.0, -47.0) # как в age_at
	return {biome = biome, river = river, forest = forest, stony = stony, elev = elev, slope = slope,
		dw = dist_water, temp = temp, moist = moist, dist_path = dist_path, village = village,
		light = light, age_n = age_n}.merged(structure_rect(w, 0, 0, W, H))


## Поля строения леса прямоугольника клеток, одни и те же внутри плана и за его краем: wood — лесистость (9.1),
## massive — единый ограниченный реликтовый массив (15.4), с теми же глобальными координатами.
## stand — густой или редкий древостой и его состав (9.2), glade — поляны (9.2). Все — сдвиги одного лесного Simplex
static func structure_rect(w: WorldData, x0: int, y0: int, cw: int, ch: int) -> Dictionary:
	var n: Simplex = w.noise.forest
	return {wood = Parallel.fbm_rect(n, x0, y0, cw, ch, WOOD_SCALE, WOOD_OCT, WOOD_OX, WOOD_OY),
		stand = Parallel.fbm_rect(n, x0, y0, cw, ch, STAND_SCALE, 2, STAND_OX, STAND_OY),
		glade = Parallel.fbm_rect(n, x0, y0, cw, ch, GLADE_SCALE, 2, GLADE_OX, GLADE_OY)}.merged(MassiveForest.fields(w, x0, y0, cw, ch))


## Доля лесов мира по сиду (9.1), -0.36..0.36: одни миры лесистые, другие открытые. Без квот — только сдвиг
## порога, поэтому массивы по-прежнему разного размера.
static func world_cover(seed_num: int) -> float:
	return 0.36 * (WGRandom.new(WGRandom.derive(seed_num, "forest.cover")).next_float() * 2.0 - 1.0)


## Растительность клеток [x0, x1) × [y0, y1) одного чанка (с 8.4). Клетка (x, y) — в общих координатах мира
## (стартовая область от 0 до W, за её краем дальше и в минус), её поля в f лежат по номеру
## (y - oy) * stride + (x - ox). Числа rng у каждой клетки свои: WGRandom.hash_cell(seed, x, y, LAYER), а
## отступы между объектами проверяются только внутри чанка, поэтому чанк не зависит ни от соседей, ни от
## порядка, в котором считаются чанки. f: biome, forest, stony, elev, slope, dw, temp, moist и необязательные
## river, dist_path, village (стартовая область), light, age_n, wood, stand, glade (без них они считаются по w).
## Просеки и лесные дороги вписываются через dist_path: у пути лес редеет, на полотне его нет.
## massive, massive_scenario — необязательная маска реликтового массива из structure_rect (15.4).
## w — стартовая область (тропы и дома) или null за её краем.
static func place_chunk(seed_num: int, x0: int, y0: int, x1: int, y1: int, f: Dictionary, ox: int, oy: int, stride: int,
		w: WorldData, store: ObjStore) -> void:
	var biome: PackedByteArray = f.biome
	var forest: PackedFloat64Array = f.forest
	var stony: PackedFloat64Array = f.stony
	var elev: PackedFloat32Array = f.elev
	var slope: PackedFloat32Array = f.slope
	var dist_water: PackedFloat32Array = f.dw
	var temp: PackedFloat32Array = f.temp
	var moist: PackedFloat32Array = f.moist
	var river: PackedByteArray = f.get("river", PackedByteArray())
	var dist_path: PackedFloat32Array = f.get("dist_path", PackedFloat32Array())
	var village: PackedByteArray = f.get("village", PackedByteArray())
	var light_f: PackedFloat32Array = f.get("light", PackedFloat32Array())
	var age_n: PackedFloat64Array = f.get("age_n", PackedFloat64Array())
	var wood: PackedFloat64Array = f.get("wood", PackedFloat64Array())
	var has_wood := not wood.is_empty()
	var stand_f: PackedFloat64Array = f.get("stand", PackedFloat64Array())
	var glade_f: PackedFloat64Array = f.get("glade", PackedFloat64Array())
	var has_stand := not stand_f.is_empty()
	var massive_f: PackedFloat32Array = f.get("massive", PackedFloat32Array())
	var massive_scenario: int = f.get("massive_scenario", 0)
	var cover_bias := world_cover(seed_num)
	var has_river := not river.is_empty()
	var has_path := not dist_path.is_empty()
	var has_village := not village.is_empty()
	var has_light := not light_f.is_empty()
	var has_age := not age_n.is_empty()
	var b_water: PackedByteArray = _TABLES.water
	var b_trees: PackedFloat64Array = _TABLES.trees
	# Своя копия списков видов: чанки считаются в нескольких потоках (12.2), а общий массив на каждой
	# клетке менял бы один и тот же счётчик ссылок из всех потоков
	var b_kinds: Array = _TABLES.kinds.duplicate(true)
	var b_tree: PackedByteArray = _TABLES.tree
	var rng := WGRandom.new(0)
	var mask := WGRandom.MASK
	store.begin_chunk(x0, y0, x1, y1)
	for y in range(y0, y1):
		for x in range(x0, x1):
			var i := (y - oy) * stride + x - ox
			var bi := biome[i]
			if b_water[bi] != 0 or (has_river and river[i] != 0):
				continue
			# = WGRandom.hash_cell(seed_num, x, y, LAYER), развёрнут: вызов на каждую клетку заметен по времени
			var hc := ((x * 73856093 + y * 19349663 + LAYER * 83492791) ^ seed_num) & mask
			hc = (((hc >> 16) ^ hc) * 0x45d9f3b) & mask
			hc = (((hc >> 16) ^ hc) * 0x45d9f3b) & mask
			rng.reset((hc >> 16) ^ hc)
			var dens := b_trees[bi]
			var fv := forest[i]
			var e := elev[i]
			var sl := slope[i]
			var dw := dist_water[i]
			var light: float = light_f[i] if has_light else StageClimate.natural_conditions(w, x, y).x
			# Один медленный шум задаёт возраст участка и плавную смену сообщества.
			var age_raw: float = age_n[i] if has_age else w.noise.forest.fbm(x / 78.0 + 91.0, y / 78.0 - 47.0, 2)
			var age := _ss(-0.45, 0.45, age_raw) # = age_at, без лишнего вызова
			# smoothstep развёрнут на месте
			var interior := 0.0 # насколько клетка в глубине леса (0 — опушка или поле)
			# 9.1: лесистость — крупный шум и доля лесов мира, мелкий лесной шум только рвёт опушки
			var wv: float = wood[i] if has_wood else w.noise.forest.fbm(x / WOOD_SCALE + WOOD_OX, y / WOOD_SCALE + WOOD_OY, WOOD_OCT)
			var cover := wv * 1.15 + cover_bias + fv * 0.4
			var stand := 0.5 # 9.2: 0 — редкий светлый древостой, 1 — сомкнутый
			if dens > 0.3:
				var t := clampf((cover + 0.3) / (0.12 + 0.3), 0.0, 1.0)
				interior = t * t * (3.0 - 2.0 * t)
				var sv: float = stand_f[i] if has_stand else w.noise.forest.fbm(x / STAND_SCALE + STAND_OX, y / STAND_SCALE + STAND_OY, 2)
				var gv: float = glade_f[i] if has_stand else w.noise.forest.fbm(x / GLADE_SCALE + GLADE_OX, y / GLADE_SCALE + GLADE_OY, 2)
				stand = _ss(-0.4, 0.4, sv)
				# поляны только в глубине массива: на опушке и так светло
				var glade := _ss(0.3, 0.45, gv) * interior
				dens *= interior * _ss(-0.45, -0.12, stony[i]) * lerpf(1.35, 0.75, age) * lerpf(0.55, 1.3, stand) * (1.0 - 0.92 * glade)
				interior *= 1.0 - 0.6 * glade # у края поляны — опушечные виды
			else:
				var t := clampf((fv - 0.1) / (0.5 - 0.1), 0.0, 1.0)
				dens *= 0.3 + 1.8 * (t * t * (3.0 - 2.0 * t)) # рощи в открытой местности
				# там, где лесистость высокая, массив продолжается и на влажных лугах
				if bi == Biomes.GRASS:
					var spread := _ss(0.2, 0.55, cover) * _ss(0.3, 0.42, moist[i])
					if spread > 0.0:
						interior = spread
						dens = maxf(dens, SPREAD * spread)
				# у воды в сухих и открытых краях — прибрежные рощи и оазисы
				if dw < SHORE and _dry_open(bi) and temp[i] > 0.24:
					dens += 0.22 * (1.0 - dw / SHORE)
			# Relict core fills small clearings, ages the stand and extends into suitable meadows.
			# Apply before the existing terrain/path/village reductions and ObjStore exclusions.
			var massive := 0.0
			if not massive_f.is_empty() and massive_f[i] > 0.0:
				massive = massive_f[i] * MassiveForest.suitability(massive_scenario, bi, e, sl, moist[i], temp[i])
				age = maxf(age, MassiveForest.OLD_AGE * massive)
				interior = maxf(interior, massive)
				stand = maxf(stand, 0.85 * massive)
				dens = maxf(dens, MassiveForest.DENSITY * massive)
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
			if has_path:
				if dist_path[i] < 1.2:
					continue
				if dist_path[i] < 2.5:
					dens *= 0.35
			if has_village and village[i] != 0:
				dens *= 0.08
			var kinds: Array = b_kinds[bi]
			# Числа rng на объект: проверка, x, y, вид, вариант, масштаб
			for k in 2:
				if rng.next_float() < dens * 0.6:
					var px := x + 0.1 + rng.next_float() * 0.8
					var py := y + 0.15 + rng.next_float() * 0.8
					# сомкнутые участки — влажнее и лиственнее, редкие — светлые сосняки (9.2)
					var community_moist := clampf(moist[i] + (age - 0.5) * 0.22 + (stand - 0.5) * 0.3, 0.0, 1.0)
					var kind_roll := rng.next_float()
					var dominance := MassiveForest.DOMINANCE * massive
					# Remap the remaining interval, retaining genuinely mixed companion species.
					var community_roll := (kind_roll - dominance) / (1.0 - dominance) if dominance > 0.0 and kind_roll >= dominance else kind_roll
					var kind := _kind(bi, kinds, community_roll, e, community_moist, sl, dw, temp[i], light, interior)
					if kind_roll < dominance:
						kind = Biomes.T_PINE if massive_scenario == MassiveForest.PINE else Biomes.T_OAK
					if massive > 0.0 and kind in [Biomes.T_OAK, Biomes.T_PINE] and (not has_village or village[i] == 0):
						var relic := smoothstep(0.25, 0.85, massive) * smoothstep(0.55, 0.9, age)
						if WGRandom.hash2(x * 2 + k, y, seed_num ^ 15501) < relic:
							kind = Biomes.T_RELICT_PINE if kind == Biomes.T_PINE else Biomes.T_RELICT_OAK
					var v := floori(rng.next_float() * 3)
					var sc := tree_scale(age, interior, line, moist[i], rng.next_float()) if b_tree[kind] != 0 else 0.8 + rng.next_float() * 0.45
					store.add(px, py, kind, v, sc)
			# камни: на кручах и россыпями там, где местность неровная
			# 10.4: на кручах валуны тоже пятнами (россыпи), а не ровной сыпью по всему склону;
			# размеры разные: много мелких, редкие крупные
			var rocky := 0.06 * (0.12 + 0.88 * _ss(-0.1, 0.45, stony[i])) if sl > 0.7 else 0.0
			if sl > 0.25 and stony[i] > 0.3:
				rocky += 0.05 * clampf((stony[i] - 0.3) * 4.0, 0.0, 1.0) * clampf(sl, 0.0, 1.0)
			if rocky > 0.0 and rng.next_float() < rocky:
				var px := x + rng.next_float()
				var py := y + rng.next_float()
				var v := floori(rng.next_float() * 3)
				var size := rng.next_float()
				store.add(px, py, Biomes.T_ROCK, v, 0.5 + size * size * 1.1)
			if dw < 1.6 and _reedy(bi) and sl < 0.5 and temp[i] > 0.24 and moist[i] > 0.48 and rng.next_float() < 0.12:
				var px := x + rng.next_float()
				var py := y + rng.next_float()
				var v := floori(rng.next_float() * 3)
				store.add(px, py, Biomes.T_REED, v, 0.8 + rng.next_float() * 0.3)


## Свойства биомов в плоских таблицах: в цикле по всем клеткам словари читать дорого
static var _TABLES := _make_tables()


static func _make_tables() -> Dictionary:
	var t := {water = PackedByteArray(), trees = PackedFloat64Array(), kinds = [], tree = PackedByteArray(), max_crown = 0.0}
	for kind in Biomes.CROWN_RADIUS.size():
		t.tree.append(1 if Biomes.is_tree(kind) else 0)
		t.max_crown = maxf(t.max_crown, Biomes.CROWN_RADIUS[kind])
	for bd: Dictionary in Biomes.LIST:
		t.water.append(1 if bd.get("water", false) else 0)
		t.trees.append(bd.get("trees", 0.0))
		t.kinds.append(bd.get("kinds", []))
	return t


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
	var reach: float = _TABLES.max_crown * tree_scale(1.0, 1.0, 0.0, 1.0, 1.0) + 0.5
	for cy in range(maxi(0, floori((py - reach) / w.CS)), mini(w.CH - 1, floori((py + reach) / w.CS)) + 1):
		for cx in range(maxi(0, floori((px - reach) / w.CS)), mini(w.CW - 1, floori((px + reach) / w.CS)) + 1):
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
	for s: EntityRecord in settlements:
		if absf(s.x - ox) > VILLAGE_R + radius or absf(s.y - oy) > VILLAGE_R + radius:
			continue
		for u: HutData in s.huts:
			if absf(u.x - ox) < 0.75 + radius and absf(u.y - oy) < 0.75 + radius:
				return true
	return false


## Список объектов растительности: столбцы чисел и номера объектов по чанкам.
## Отступы между объектами — только внутри текущего чанка (begin_chunk), см. place_chunk.
## Без мира (за краем карты) — один общий список, без проверок троп и домов.
class ObjStore:
	var x := PackedFloat64Array()
	var y := PackedFloat64Array()
	var k := PackedInt32Array()
	var v := PackedInt32Array()
	var s := PackedFloat64Array()
	var chunk_lists: Array = []
	var w: WorldData
	# Поля мира копируются в хранилище: с 12.2 хранилищ несколько, по одному на поток, а частое чтение
	# свойств общего объекта из многих потоков упирается в общие счётчики ссылок
	var _huts := PackedFloat64Array() # x, y поселения или места и x, y дома — по четыре числа на дом
	var _crown := PackedFloat64Array(Biomes.CROWN_RADIUS)
	var _largest_radius := 0.0
	var _path_mask := PackedByteArray()
	var _W := 0
	var _H := 0
	# Временный индекс соседей чанка: головы списков по клеткам и ссылки по объектам.
	# В готовом WorldData остаются только прежние obj_* и chunks.
	var heads := PackedInt32Array()
	var next := PackedInt32Array()
	var _list: Array = []
	var _x0 := 0
	var _y0 := 0
	var _x1 := 0
	var _y1 := 0

	func _init(world: WorldData) -> void:
		w = world
		if w != null:
			for list: Array in [w.settlements, w.sites]:
				for st: EntityRecord in list:
					for u: HutData in st.huts:
						_huts.append_array([st.x, st.y, u.x, u.y])
			_path_mask = w.path_mask
			_W = w.W
			_H = w.H
			for c: int in w.CW * w.CH:
				chunk_lists.append([])
		else:
			chunk_lists.append(_list)

	func begin_chunk(x0: int, y0: int, x1: int, y1: int) -> void:
		_largest_radius = 0.0
		_x0 = x0
		_y0 = y0
		_x1 = x1
		_y1 = y1
		heads.resize((x1 - x0) * (y1 - y0))
		heads.fill(-1)
		if w != null:
			_list = chunk_lists[floori(float(y0) / w.CS) * w.CW + floori(float(x0) / w.CS)]

	func add(ox: float, oy: float, kind: int, variant: int, sc: float) -> void:
		var radius: float = _crown[kind] * sc
		var clearance := Biomes.ground_radius(kind) * sc
		var cx := floori(ox)
		var cy := floori(oy)
		# Independent chunks must not place giant root bases into an unqueried neighbour.
		# Only the ground footprint stays inside; the high canopy freely crosses chunk borders.
		if Biomes.is_relict(kind) and minf(minf(ox - _x0, _x1 - ox), minf(oy - _y0, _y1 - oy)) < clearance + 0.25:
			return
		if w != null:
			# = near_hut по поселениям и местам, по плоскому списку домов
			for n in range(0, _huts.size(), 4):
				if absf(_huts[n] - ox) <= VILLAGE_R + clearance and absf(_huts[n + 1] - oy) <= VILLAGE_R + clearance 						and absf(_huts[n + 2] - ox) < 0.75 + clearance and absf(_huts[n + 3] - oy) < 0.75 + clearance:
					return
			# Ground clearance protects paths; the high relict canopy may arch above them.
			var reach := ceili(clearance + 1.0)
			for yy in range(maxi(0, cy - reach), mini(_H, cy + reach + 1)):
				for xx in range(maxi(0, cx - reach), mini(_W, cx + reach + 1)):
					if _path_mask[yy * _W + xx] == 0:
						continue
					var dx := maxf(maxf(xx - ox, ox - xx - 1.0), 0.0)
					var dy := maxf(maxf(yy - oy, oy - yy - 1.0), 0.0)
					if dx * dx + dy * dy < (clearance + 0.25) ** 2:
						return
		# Кроны могут частично перекрываться, но стволы и крупные объекты не слипаются.
		# Query reach follows actual crowns already inserted in this chunk, including giants.
		var search := ceili(0.18 + 0.55 * (radius + _largest_radius))
		var cw := _x1 - _x0
		for yy in range(maxi(_y0, cy - search), mini(_y1, cy + search + 1)):
			for xx in range(maxi(_x0, cx - search), mini(_x1, cx + search + 1)):
				var o := heads[(yy - _y0) * cw + xx - _x0]
				while o != -1:
					var gap: float = 0.18 + 0.55 * (radius + _crown[k[o]] * s[o])
					if Vector2(ox - x[o], oy - y[o]).length_squared() < gap * gap:
						return
					o = next[o]
		var cell := (cy - _y0) * cw + cx - _x0
		next.append(heads[cell])
		heads[cell] = x.size()
		_list.append(x.size())
		x.append(ox)
		y.append(oy)
		k.append(kind)
		v.append(variant)
		s.append(sc)
		_largest_radius = maxf(_largest_radius, radius)
