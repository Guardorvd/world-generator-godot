class_name OuterLand
extends RefCounted
## Местность за краем стартовой области (с 1.9.5): тот же шум, что у StageRelief, с теми же постоянными уровнями
## моря, поэтому на границе карты нет ступеньки. Считается кусками по C × C клеток вокруг игрока (OuterTerrain).
## С 8.4 здесь и климат по тем же правилам, что у StageClimate (осадки, близость моря, свет склона, почвенная
## влага), и лес, камни и тростник тем же кодом, что в стартовой области (StageVegetation.place_chunk).
## Всё зависит только от места: клетка — в общих координатах мира, случайные числа — хеш (сид, клетка, слой),
## а соседей кусок не спрашивает: всё, что нужно рядом (море в SEA_REACH клетках, соседи для крутизны), он
## считает сам в полосе вокруг себя. Поэтому одна и та же местность получается в любом порядке загрузки.
## Океан открытой местности определяется уровнем моря. В готовом плане и закреплённых областях
## используются их маски воды, в том числе при расчёте расстояний для соседних клеток.
## compute — чистая функция, её считают фоновые задачи; в chunks и veg куски кладёт и убирает главный поток.
## Кольцо клеток вокруг карты считается сразу и потом не меняется: его читает и поток растительности
## (Heightfield.ground_at у самого края карты), а chunks — только главный поток.
## Сам мир здесь не хранится, только его размер: мир держит OuterLand (WorldData.outer), и обратная ссылка
## замкнула бы их друг на друга, тогда мир не освобождался бы после выхода в меню (до 2.0 так и было).

const C := 64              # сторона куска в клетках
## Насколько далеко клетка видит море (осадки, берег, влага). Дальше море не учитывается ни здесь, ни в
## полосе вокруг куска; поправка на близость моря сведена к нулю на этом расстоянии (см. compute)
const SEA_REACH := StageHydrology.COAST_REACH
const PAD := SEA_REACH + 2 # полоса вокруг прямоугольника: море и ещё две клетки на свет склона

var W := 0                 # размер карты в клетках
var H := 0
## Vector2i(номер куска по x, по y) -> поля compute по (C + 3)² клеткам с углом (x0 - 1, y0 - 1),
## где x0, y0 — первая клетка куска: с запасом на соседей для меша и нормалей
var chunks := {}
## Vector2i(чанк растительности, WorldData.CHUNK_SIZE клеток) -> объекты из vegetation с высотой земли ground;
## кладёт VegetationLayer, читают препятствия (ForestObstacles)
var veg := {}
var _ring: Array[Dictionary] = []   # над картой, под ней, слева, справа
## 13.9: закреплённые соседние области (журнал RegionPreparation.commit). Их клетки окончательны:
## compute берёт их поля вместо сырого шума, height/water/info — сначала из них. Журнал заменяется
## целиком в главном потоке (set_ledger); опубликованные словари и вложенные данные больше не меняются.
## Замок защищает публикацию ссылки; _load_fields/_evict копируют словари перед записью.
const SETTLEMENT_REACH := 32.0 # м: радиус отбора поселений для проверки стен
var _settlement_cells := {}
var settlements: Array = []:
	set(value):
		if is_same(settlements, value):
			return
		settlements = value
		_settlement_cells = index_collision_places(value)
var _ledger := {}
var _lock := Mutex.new()


func _init(w: WorldData = null) -> void:
	if w == null: return
	W = w.W
	H = w.H
	_ring = [compute(w, -1, -1, w.W + 2, 1), compute(w, -1, w.H, w.W + 2, 1),
		compute(w, -1, 0, 1, w.H), compute(w, w.W, 0, 1, w.H)]


## Поля клеток прямоугольника cw × ch с углом (x0, y0): h — высота в единицах WorldData.h (ниже 0 — море,
## в метры её переводит Heightfield.outer_meters), biome, temp, moist, elev, slope, dist — клеток до моря
## (вне SEA_REACH — 1e9), dw — до любой воды, light — освещение склона. Климат — правила StageClimate.
## При одном снимке готовых областей значение клетки не зависит от того, в каком
## прямоугольнике её считали: всё, что ей нужно, лежит в полосе PAD вокруг
static func compute(w: WorldData, x0: int, y0: int, cw: int, ch: int, snapshot: Variant = null, climate_inputs := false) -> Dictionary:
	var ledger: Dictionary = snapshot if snapshot is Dictionary else (w.outer.get_ledger() if w.outer != null else {})
	var pw := cw + 2 * PAD
	var ph := ch + 2 * PAD
	var raw := StageRelief.raw_rect(w, x0 - PAD, y0 - PAD, pw, ph, false)
	var micro := Parallel.fbm_rect(w.noise.micro, x0 - PAD, y0 - PAD, pw, ph, 9.0, 2)
	var hn := PackedFloat32Array()
	hn.resize(pw * ph)
	var sea_src := PackedByteArray()
	sea_src.resize(pw * ph)
	# StageRelief.normalize и add_micro развёрнуты на месте: куски считаются в потоках (см. Parallel)
	var sea := StageRelief.SEA_RAW
	var top := StageRelief.TOP_RAW
	var bottom := StageRelief.BOTTOM_RAW
	for k in pw * ph:
		var v := raw[k]
		var hh := minf(pow((v - sea) / (top - sea), 1.25), 1.4) if v >= sea else (v - sea) / (sea - bottom)
		hn[k] = maxf(1e-4, hh + micro[k] * 0.006 * minf(1.0, hh * 40.0)) if hh > 0.0 else hh
		sea_src[k] = 1 if hn[k] < 0.0 else 0
	var water_src := sea_src.duplicate()
	var halo := Rect2i(x0 - PAD, y0 - PAD, pw, ph)
	if w.ocean.size() == w.N and w.lake.size() == w.N and w.N > 0:
		_water_sources(halo, Rect2i(0, 0, w.W, w.H), w.ocean, w.lake, w.river_cells(), sea_src, water_src)
	for entry: Dictionary in ledger.get("regions", {}).values():
		if entry.has("fields"):
			var f: Dictionary = entry.fields
			_water_sources(halo, entry.rect, f.ocean, f.lake, f.river, sea_src, water_src)
	var dist := Grid.distance_field(pw, ph, sea_src)
	var wet_dist := dist if sea_src == water_src else Grid.distance_field(pw, ph, water_src)
	var p: Array = WorldData.NOISE_FIELDS.temp
	var temp_n := Parallel.fbm_rect(w.noise.temp, x0, y0, cw, ch, p[0], p[1])
	p = WorldData.NOISE_FIELDS.moist
	var moist_n := Parallel.fbm_rect(w.noise.moist, x0, y0, cw, ch, p[0], p[1])
	var n := cw * ch
	var out := {h = PackedFloat32Array(), biome = PackedByteArray(), temp = PackedFloat32Array(),
		moist = PackedFloat32Array(), elev = PackedFloat32Array(), slope = PackedFloat32Array(),
		dist = PackedFloat32Array(), dw = PackedFloat32Array(), light = PackedFloat32Array()}
	if climate_inputs:
		out.rain = PackedFloat32Array()
		out.temp_base = PackedFloat32Array()
	for key in out:
		out[key].resize(n)
	# Rainfall uses the actual ocean field; climate never invents freshwater.
	for j in ch:
		var lat := StageClimate.latitude(w, y0 + j)
		for i in cw:
			var c := (j + PAD) * pw + i + PAD
			var hh := hn[c]
			var o := j * cw + i
			var e := maxf(0.0, hh)
			var gx := maxf(0.0, hn[c + 1]) - maxf(0.0, hn[c - 1])
			var gy := maxf(0.0, hn[c + pw]) - maxf(0.0, hn[c - pw])
			var slope := sqrt(gx * gx + gy * gy) * 0.5 * 60.0
			# StageClimate.natural_conditions по высотам суши, развёрнута на месте
			var lgx := gx * 30.0
			var lgy := gy * 30.0
			var light := clampf(0.5 - 0.5 * lgy / sqrt(1.0 + lgx * lgx + lgy * lgy), 0.0, 1.0)
			var around := (maxf(0.0, hn[c - 2]) + maxf(0.0, hn[c + 2]) + maxf(0.0, hn[c - 2 * pw]) + maxf(0.0, hn[c + 2 * pw])) * 0.25
			var hollow := clampf((around - e) * 18.0, -0.16, 0.16)
			# Outside the coastal halo there is no known nearby water. Preserve
			# the no-source sentinel, rather than pretending water is 32 cells away.
			var d := dist[c] if dist[c] <= SEA_REACH else 1e9
			var dw := wet_dist[c] if wet_dist[c] <= SEA_REACH else 1e9
			# осадки — как в StageHydrology, поправка на близость моря гаснет к SEA_REACH
			var rain := StageHydrology.rainfall(moist_n[o], dist[c])
			var temp_base := 0.43 + lat * 0.32 + temp_n[o] * 0.18
			var t := clampf(temp_base - e * 0.6, 0.0, 1.0)
			var m := clampf(rain + 0.22 * exp(-dw / 4.0), 0.0, 1.0)
			var b: int
			if hh < 0.0:
				b = Biomes.DEEP if hh < -0.35 else (Biomes.OCEAN if hh < -0.07 else Biomes.SHALLOW)
			else:
				t = clampf(t + (light - 0.5) * 0.08, 0.0, 1.0)
				m = StageClimate.soil_moisture(rain, dw, slope, t, Vector2(light, hollow))
				b = StageClimate.land_biome(e, t, m, slope, d, dw)
			out.h[o] = hh
			out.biome[o] = b
			out.temp[o] = t
			out.moist[o] = m
			out.elev[o] = e
			out.slope[o] = slope
			out.dist[o] = d
			out.dw[o] = dw
			out.light[o] = light
			if climate_inputs:
				out.rain[o] = rain
				out.temp_base[o] = temp_base
	_overlay(w, Rect2i(x0, y0, cw, ch), out)
	_overlay_regions(ledger, Rect2i(x0, y0, cw, ch), out)
	if not climate_inputs:
		out.rock = preload("res://scripts/world/mountain_surface.gd").field(out.elev, out.slope, out.moist)
	return out


static func _water_sources(halo: Rect2i, rect: Rect2i, ocean: PackedByteArray, lake: PackedByteArray,
		river: PackedByteArray, sea_src: PackedByteArray, water_src: PackedByteArray) -> void:
	var overlap := halo.intersection(rect)
	var has_river := river.size() == rect.get_area()
	for y in range(overlap.position.y, overlap.end.y):
		for x in range(overlap.position.x, overlap.end.x):
			var dst := (y - halo.position.y) * halo.size.x + x - halo.position.x
			var src := (y - rect.position.y) * rect.size.x + x - rect.position.x
			sea_src[dst] = ocean[src]
			water_src[dst] = int(ocean[src] != 0 or lake[src] != 0 or (has_river and river[src] != 0))


func set_ledger(ledger: Dictionary) -> void:
	_lock.lock()
	_ledger = ledger
	_lock.unlock()
	settlements = ledger.get("settlements", [])


func collision_settlements(x: float, z: float) -> Array:
	return _settlement_cells.get(collision_cell(x, z), [])


static func collision_cell(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / SETTLEMENT_REACH), floori(z / SETTLEMENT_REACH))


static func index_collision_places(places: Array) -> Dictionary:
	var cells := {}
	for place in places:
		var x: float = place.x * GameConfig.TILE
		var z: float = place.y * GameConfig.TILE
		var lo := collision_cell(x - SETTLEMENT_REACH, z - SETTLEMENT_REACH)
		var hi := collision_cell(x + SETTLEMENT_REACH, z + SETTLEMENT_REACH)
		for cz in range(lo.y, hi.y + 1):
			for cx in range(lo.x, hi.x + 1):
				var key := Vector2i(cx, cz)
				if not cells.has(key): cells[key] = []
				cells[key].append(place)
	return cells


func get_ledger() -> Dictionary:
	_lock.lock()
	var ledger := _ledger
	_lock.unlock()
	return ledger


## Поля закреплённых областей поверх сырого шума: высоты после русел, вода, пути, биом, уклон.
## water — уровень реки или озера (единицы h, иначе -INF), path — как path_mask. dist_path и
## village для растительности появляются, только если прямоугольник задевает такую область.
static func _overlay_regions(ledger: Dictionary, rect: Rect2i, out: Dictionary) -> void:
	var area := rect.get_area()
	out.water = PackedFloat32Array()
	out.water.resize(area)
	out.water.fill(-INF)
	if not out.has("path"):
		out.path = PackedByteArray()
		out.path.resize(area)
	var regions: Dictionary = ledger.get("regions", {})
	for key: Vector2i in regions:
		var r: Rect2i = regions[key].rect
		var part := r.intersection(rect)
		if not part.has_area() or not regions[key].has("fields"):
			continue
		if not out.has("dist_path"):
			out.dist_path = PackedFloat32Array()
			out.dist_path.resize(area)
			out.dist_path.fill(99.0)
		if not out.has("village"):
			out.village = PackedByteArray()
			out.village.resize(area)
		var f: Dictionary = regions[key].fields
		var has_climate := f.has("elev")
		for y in range(part.position.y, part.end.y):
			for x in range(part.position.x, part.end.x):
				var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
				var src := (y - r.position.y) * r.size.x + x - r.position.x
				var h: float = f.h[src]
				out.h[dst] = h
				out.elev[dst] = _saved_elev(f, src)
				out.biome[dst] = f.biome[src]
				out.slope[dst] = f.slope[src]
				out.dist[dst] = f.dist[src]
				out.dw[dst] = f.dw[src]
				out.river[dst] = f.river[src]
				out.path[dst] = f.path[src]
				out.dist_path[dst] = f.dist_path[src]
				out.village[dst] = f.village[src]
				if has_climate:
					out.temp[dst] = f.temp[src]
					out.moist[dst] = f.moist[src]
					out.light[dst] = f.light[src]
				if f.river[src] != 0 or f.lake[src] != 0:
					out.water[dst] = f.water_level[src]


static func _saved_elev(f: Dictionary, i: int) -> float:
	if f.has("elev"): return f.elev[i]
	if f.lake[i] != 0: return f.water_level[i]
	return maxf(0.0, f.h[i])


## Внутри общего плана брать окончательные долины, воду и климат, а не заново сырой шум.
## dw — расстояние до любой воды, river — коридор русла.
static func _overlay(w: WorldData, rect: Rect2i, out: Dictionary) -> void:
	if not out.has("dw"): out.dw = out.dist.duplicate()
	out.river = PackedByteArray()
	out.river.resize(rect.get_area())
	out.path = PackedByteArray()
	out.path.resize(rect.get_area())
	out.village = PackedByteArray()
	out.village.resize(rect.get_area())
	# Готовая география есть после StageClimate; заготовки WorldData в тестах её не имеют.
	if w.N <= 0 or w.biome.size() != w.N or w.dist_water.size() != w.N:
		return
	var overlap := rect.intersection(Rect2i(0, 0, w.W, w.H))
	var river := w.river_cells()
	var source_h: PackedFloat32Array = w.h
	var source_biome: PackedByteArray = w.biome
	var source_temp: PackedFloat32Array = w.temp
	var source_moist: PackedFloat32Array = w.moist
	var source_elev: PackedFloat32Array = w.elev
	var source_slope: PackedFloat32Array = w.slope
	var source_dist: PackedFloat32Array = w.dist_ocean
	var source_dw: PackedFloat32Array = w.dist_water
	var dest_h: PackedFloat32Array = out.h
	var dest_biome: PackedByteArray = out.biome
	var dest_temp: PackedFloat32Array = out.temp
	var dest_moist: PackedFloat32Array = out.moist
	var dest_elev: PackedFloat32Array = out.elev
	var dest_slope: PackedFloat32Array = out.slope
	var dest_dist: PackedFloat32Array = out.dist
	var dest_dw: PackedFloat32Array = out.dw
	var dest_river: PackedByteArray = out.river
	var dest_light: PackedFloat32Array = out.light
	for y in range(overlap.position.y, overlap.end.y):
		for x in range(overlap.position.x, overlap.end.x):
			var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
			var src := y * w.W + x
			dest_h[dst] = source_h[src]
			dest_biome[dst] = source_biome[src]
			dest_temp[dst] = source_temp[src]
			dest_moist[dst] = source_moist[src]
			dest_elev[dst] = source_elev[src]
			dest_slope[dst] = source_slope[src]
			dest_dist[dst] = source_dist[src]
			dest_dw[dst] = source_dw[src]
			dest_river[dst] = river[src]
			dest_light[dst] = StageClimate.natural_conditions(w, x, y).x
			if w.path_mask.size() == w.N: out.path[dst] = w.path_mask[src]
	for place: EntityRecord in w.settlements + w.sites:
		var radius: float = StageVegetation.VILLAGE_R if place is SettlementData else place.get("clear")
		var box := Rect2i(floori(place.x - radius), floori(place.y - radius), ceili(radius * 2.0) + 1, ceili(radius * 2.0) + 1).intersection(rect)
		for y in range(box.position.y, box.end.y):
			for x in range(box.position.x, box.end.x):
				out.village[(y - rect.position.y) * rect.size.x + x - rect.position.x] = 1


## Лес, камни и тростник чанка растительности key (WorldData.CHUNK_SIZE клеток, в общих координатах; для
## фоновой задачи). Тот же код, что у стартовой области, без троп и домов. Кроме объектов (x, y в клетках, k, v, s)
## возвращает высоты h, воду и маску путей с запасом RockScatter.FIELD_HALO: опора и источник осыпи
static func vegetation(w: WorldData, key: Vector2i, surface: Heightfield = null) -> Dictionary:
	var cs := WorldData.CHUNK_SIZE
	var x0 := key.x * cs
	var y0 := key.y * cs
	# The same uphill sources as the full plan; a two-cell snapshot truncated 8..24 m talus.
	var pad := maxi(2, RockScatter.FIELD_HALO)
	var side := cs + pad * 2
	var f := compute(w, x0 - pad, y0 - pad, side, side)
	var p: Array = WorldData.NOISE_FIELDS.forest
	f.forest = Parallel.fbm_rect(w.noise.forest, x0 - pad, y0 - pad, side, side, p[0], p[1])
	p = WorldData.NOISE_FIELDS.cost
	f.stony = Parallel.fbm_rect(w.noise.cost, x0 - pad, y0 - pad, side, side, p[0], p[1])
	f.age_n = Parallel.fbm_rect(w.noise.forest, x0 - pad, y0 - pad, side, side, 78.0, 2, 91.0, -47.0) # как в age_at
	f.merge(StageVegetation.structure_rect(w, x0 - pad, y0 - pad, side, side))
	var candidates := RockMassif.sites(w.seed_num, x0, y0, x0 + cs, y0 + cs, f, x0 - pad, y0 - pad, side, f.path)
	var snapshot := {h = f.h, water = f.water, path = f.path, x0 = x0 - pad, y0 = y0 - pad, side = side,
		plan_path = w.path_mask, plan_water = surface.water_level if surface != null else PackedFloat32Array(),
		world_origin = Vector2(w.world_origin) * GameConfig.TILE}
	var plan_hv := surface.hv if surface != null else PackedFloat32Array()
	f.massifs = RockMassif.seated_snapshot(candidates, snapshot, plan_hv, w.W if surface != null else 0, w.H if surface != null else 0)
	# dw уже содержит расстояние до всей воды общего плана, а снаружи — до моря.
	if not f.has("dw"):
		f.dw = f.dist
	var store := StageVegetation.ObjStore.new(null)
	StageVegetation.place_chunk(w.seed_num, x0, y0, x0 + cs, y0 + cs, f, x0 - pad, y0 - pad, side, null, store)
	return {x = store.x, y = store.y, k = store.k, v = store.v, s = store.s, h = f.h, water = f.get("water", PackedFloat32Array()), path = f.get("path", PackedByteArray()), x0 = x0 - pad, y0 = y0 - pad, side = side}


## Поля куска key (для фоновой задачи)
static func compute_chunk(w: WorldData, key: Vector2i, snapshot: Variant = null) -> Dictionary:
	return compute(w, key.x * C - 1, key.y * C - 1, C + 3, C + 3, snapshot)


## Клетка закреплённой области: [её поля, номер] или []. Эти поля окончательны и важнее кусков.
func _region_at(i: int, j: int) -> Array:
	var regions: Dictionary = get_ledger().get("regions", {})
	if regions.is_empty():
		return []
	var size := WorldData.REGION_SIZE
	var r: Variant = regions.get(Vector2i(floori(float(i) / size), floori(float(j) / size)))
	if r == null or not r.has("fields"):
		return []
	var rect: Rect2i = r.rect
	if not rect.has_point(Vector2i(i, j)): return []
	return [r.fields, (j - rect.position.y) * rect.size.x + i - rect.position.x]


## Где лежит клетка (i, j) за краем карты: [поля, номер в них] или [] — куска ещё нет
func _locate(i: int, j: int) -> Array:
	if i >= 0 and j >= 0 and i < W and j < H:
		return [] # клетка на карте: её поля в WorldData, не здесь
	if i >= -1 and j >= -1 and i <= W and j <= H:
		if j == -1:
			return [_ring[0], i + 1]
		if j == H:
			return [_ring[1], i + 1]
		if i == -1:
			return [_ring[2], j]
		return [_ring[3], j]
	var key := Vector2i(floori(float(i) / C), floori(float(j) / C))
	var f: Variant = chunks.get(key)
	if f == null:
		return []
	return [f, (j - key.y * C + 1) * (C + 3) + i - key.x * C + 1]


## Высота клетки за краем карты в единицах WorldData.h (ниже 0 — море); где кусок ещё не посчитан — уровень моря
func height(i: int, j: int) -> float:
	var known := _region_at(i, j)
	if not known.is_empty():
		return known[0].h[known[1]]
	var at := _locate(i, j)
	return at[0].h[at[1]] if not at.is_empty() else 0.0


## Речное дно может быть ниже нуля, сохраняя масштаб суши.
func ground(i: int, j: int) -> float:
	var known := _region_at(i, j)
	if not known.is_empty():
		var f: Dictionary = known[0]
		var k: int = known[1]
		return Heightfield.outer_meters(f.h[k], f.ocean[k] == 0)
	return Heightfield.outer_meters(height(i, j))


## Посчитана ли клетка за краем карты
func has(i: int, j: int) -> bool:
	return not _region_at(i, j).is_empty() or not _locate(i, j).is_empty()


## Закреплена ли клетка (её поля в памяти): по ней можно ходить (WorldData.accessible)
func committed(i: int, j: int) -> bool:
	return not _region_at(i, j).is_empty()


## Уровень реки или озера закреплённой области в клетке (единицы h) или -INF; море — по высоте
func water(i: int, j: int) -> float:
	var known := _region_at(i, j)
	if known.is_empty():
		return -INF
	var f: Dictionary = known[0]
	var k: int = known[1]
	return f.water_level[k] if f.river[k] != 0 or f.lake[k] != 0 else -INF


static func water_corner(f: Dictionary, width: int, height: int, x: int, y: int) -> float:
	var sum := 0.0
	var count := 0
	for d in 4:
		var nx := x - 1 + (d & 1)
		var ny := y - 1 + (d >> 1)
		if nx < 0 or ny < 0 or nx >= width or ny >= height: continue
		var k := ny * width + nx
		if (f.river[k] != 0 or f.lake[k] != 0) and is_finite(f.water_level[k]):
			sum += f.water_level[k]
			count += 1
	return maxf(0.0, sum / count) if count > 0 else -INF


## Та же сетка и диагонали, что у RegionStream.water_arrays.
func water_at(x: float, z: float) -> float:
	var i := floori(x / GameConfig.TILE)
	var j := floori(z / GameConfig.TILE)
	var known := _region_at(i, j)
	if known.is_empty(): return -INF
	var f: Dictionary = known[0]
	var k: int = known[1]
	if f.river[k] == 0 and f.lake[k] == 0: return -INF
	var size := WorldData.REGION_SIZE
	var key := Vector2i(floori(float(i) / size), floori(float(j) / size))
	var rect: Rect2i = get_ledger().regions[key].rect
	var cx := i - rect.position.x
	var cy := j - rect.position.y
	var a := water_corner(f, rect.size.x, rect.size.y, cx, cy)
	var b := water_corner(f, rect.size.x, rect.size.y, cx + 1, cy)
	var c := water_corner(f, rect.size.x, rect.size.y, cx, cy + 1)
	var d := water_corner(f, rect.size.x, rect.size.y, cx + 1, cy + 1)
	var tx := x / GameConfig.TILE - i
	var tz := z / GameConfig.TILE - j
	return a + (b - a) * tx + (c - a) * tz if tx + tz <= 1.0 else d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz)


## Сведения о клетке за краем карты в том же виде, что WorldData.tile_info, или {}, если куска нет
func info(i: int, j: int) -> Dictionary:
	var at := _locate(i, j)
	var known := _region_at(i, j)
	if at.is_empty() and known.is_empty():
		return {}
	if not known.is_empty():
		# Старые блоки без климата используют поля куска, пока он загружен.
		var g: Dictionary = known[0]
		var q: int = known[1]
		var has_climate := g.has("elev")
		return {i = -1, biome = g.biome[q], river = g.river[q] != 0, path = g.path[q], surface = 0,
			elev = _saved_elev(g, q), temp = g.temp[q] if has_climate else (at[0].temp[at[1]] if not at.is_empty() else 0.5),
			moist = g.moist[q] if has_climate else (at[0].moist[at[1]] if not at.is_empty() else 0.5), slope = g.slope[q]}
	var f: Dictionary = at[0]
	var k: int = at[1]
	return {i = -1, biome = f.biome[k], river = false, path = 0, surface = 0,
		elev = f.elev[k], temp = f.temp[k], moist = f.moist[k], slope = f.slope[k]}


## Shared sparse surface for rendering, wheel/foot support and vegetation snapshots.
static func refined_patch(regions: Dictionary, cell: Vector2i) -> Dictionary:
	var key := Vector2i(floori(float(cell.x) / WorldData.REGION_SIZE), floori(float(cell.y) / WorldData.REGION_SIZE))
	return regions.get(key, {}).get("fields", {}).get("trail_patches", {}).get(cell, {})

static func refined_at(regions: Dictionary, x: float, z: float) -> Dictionary:
	var f := Vector2(x, z) / GameConfig.TILE - Vector2.ONE * 0.5
	var cell := Vector2i(f.floor())
	var patch := refined_patch(regions, cell)
	if patch.is_empty(): return {}
	var uv := (f - Vector2(cell)) * RoadRefinement.DIV
	var ix := mini(RoadRefinement.DIV - 1, floori(uv.x))
	var iz := mini(RoadRefinement.DIV - 1, floori(uv.y))
	var tx := uv.x - ix
	var tz := uv.y - iz
	var a := iz * RoadRefinement.STRIDE + ix
	var b := a + 1
	var c := a + RoadRefinement.STRIDE
	var wa := 1.0 - tx - tz
	var wb := tx
	var wc := tz
	if tx + tz > 1.0:
		a = c + 1
		wa = tx + tz - 1.0
		wb = 1.0 - tz
		wc = 1.0 - tx
	var closest := a if wa >= wb and wa >= wc else (b if wb >= wc else c)
	return {surface = patch.surface[closest], road = patch.road[closest] != 0, across = patch.uv[a].x * wa + patch.uv[b].x * wb + patch.uv[c].x * wc,
		h = patch.h[a] * wa + patch.h[b] * wb + patch.h[c] * wc,
		weight = patch.color[a].a * wa + patch.color[b].a * wb + patch.color[c].a * wc,
		normal = Vector3(-(patch.h[b] - patch.h[a]) / (1.0 if tx + tz <= 1.0 else -1.0), RoadRefinement.STEP,
			-(patch.h[c] - patch.h[a]) / (1.0 if tx + tz <= 1.0 else -1.0)).normalized()}
