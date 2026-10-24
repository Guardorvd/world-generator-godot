class_name OuterLand
extends RefCounted
## Местность за краем стартовой области (с 1.9.5): тот же шум, что у StageRelief, с теми же постоянными уровнями
## моря, поэтому на границе карты нет ступеньки. Считается кусками по C × C клеток вокруг игрока (OuterTerrain).
## С 8.4 здесь и климат по тем же правилам, что у StageClimate (осадки, близость моря, свет склона, почвенная
## влага), и лес, камни и тростник тем же кодом, что в стартовой области (StageVegetation.place_chunk).
## Всё зависит только от места: клетка — в общих координатах мира, случайные числа — хеш (сид, клетка, слой),
## а соседей кусок не спрашивает: всё, что нужно рядом (море в SEA_REACH клетках, соседи для крутизны), он
## считает сам в полосе вокруг себя. Поэтому одна и та же местность получается в любом порядке загрузки.
## За внешним краем плана рек и озёр нет. Клетки внутри плана compute с 8.6 берёт из общей готовой
## географии (_overlay): с долинами, руслами и расстоянием до всей воды, а не сырой шум.
## compute — чистая функция, её считают фоновые задачи; в chunks и veg куски кладёт и убирает главный поток.
## Кольцо клеток вокруг карты считается сразу и потом не меняется: его читает и поток растительности
## (Heightfield.ground_at у самого края карты), а chunks — только главный поток.
## Сам мир здесь не хранится, только его размер: мир держит OuterLand (WorldData.outer), и обратная ссылка
## замкнула бы их друг на друга, тогда мир не освобождался бы после выхода в меню (до 2.0 так и было).

const C := 64              # сторона куска в клетках
## Насколько далеко клетка видит море (осадки, берег, влага). Дальше море не учитывается ни здесь, ни в
## полосе вокруг куска; поправка на близость моря сведена к нулю на этом расстоянии (см. compute)
const SEA_REACH := 32
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
var settlements: Array = []        # поселения закреплённых областей (мировые клетки), для столкновений
var _ledger := {}
var _lock := Mutex.new()


func _init(w: WorldData) -> void:
	W = w.W
	H = w.H
	_ring = [compute(w, -1, -1, w.W + 2, 1), compute(w, -1, w.H, w.W + 2, 1),
		compute(w, -1, 0, 1, w.H), compute(w, w.W, 0, 1, w.H)]


## Поля клеток прямоугольника cw × ch с углом (x0, y0): h — высота в единицах WorldData.h (ниже 0 — море,
## в метры её переводит Heightfield.outer_meters), biome, temp, moist, elev, slope, dist — клеток до моря
## (не больше SEA_REACH), light — освещение склона. Климат — правила StageClimate; вместо рек и озёр только
## море, поэтому dist — и близость воды, и близость океана. Значение клетки не зависит от того, в каком
## прямоугольнике её считали: всё, что ей нужно, лежит в полосе PAD вокруг
static func compute(w: WorldData, x0: int, y0: int, cw: int, ch: int) -> Dictionary:
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
	var dist := Grid.distance_field(pw, ph, sea_src)
	var p: Array = WorldData.NOISE_FIELDS.temp
	var temp_n := Parallel.fbm_rect(w.noise.temp, x0, y0, cw, ch, p[0], p[1])
	p = WorldData.NOISE_FIELDS.moist
	var moist_n := Parallel.fbm_rect(w.noise.moist, x0, y0, cw, ch, p[0], p[1])
	var n := cw * ch
	var out := {h = PackedFloat32Array(), biome = PackedByteArray(), temp = PackedFloat32Array(),
		moist = PackedFloat32Array(), elev = PackedFloat32Array(), slope = PackedFloat32Array(),
		dist = PackedFloat32Array(), light = PackedFloat32Array()}
	for key in out:
		out[key].resize(n)
	var far := exp(-SEA_REACH / 30.0)
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
			var d := minf(dist[c], SEA_REACH)
			# осадки — как в StageHydrology, поправка на близость моря гаснет к SEA_REACH
			var rain := clampf(0.36 + 0.85 * moist_n[o] + 0.18 * (exp(-d / 30.0) - far) / (1.0 - far), 0.02, 1.0)
			var t := clampf(0.16 + lat * 0.86 + temp_n[o] * 0.18 - e * 0.6, 0.0, 1.0)
			var m := clampf(rain + 0.22 * exp(-d / 4.0), 0.0, 1.0)
			var b: int
			if hh < 0.0:
				b = Biomes.DEEP if hh < -0.35 else (Biomes.OCEAN if hh < -0.07 else Biomes.SHALLOW)
			else:
				t = clampf(t + (light - 0.5) * 0.08, 0.0, 1.0)
				m = StageClimate.soil_moisture(rain, d, slope, t, Vector2(light, hollow))
				b = StageClimate.land_biome(e, t, m, slope, d)
			out.h[o] = hh
			out.biome[o] = b
			out.temp[o] = t
			out.moist[o] = m
			out.elev[o] = e
			out.slope[o] = slope
			out.dist[o] = d
			out.light[o] = light
	_overlay(w, Rect2i(x0, y0, cw, ch), out)
	if w.outer != null:
		_overlay_regions(w.outer.get_ledger(), Rect2i(x0, y0, cw, ch), out)
	return out


func set_ledger(ledger: Dictionary) -> void:
	_lock.lock()
	_ledger = ledger
	_lock.unlock()
	settlements = ledger.get("settlements", [])


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
	out.path = PackedByteArray()
	out.path.resize(area)
	var regions: Dictionary = ledger.get("regions", {})
	for key: Vector2i in regions:
		var r: Rect2i = regions[key].rect
		var part := r.intersection(rect)
		if not part.has_area() or not regions[key].has("fields"):
			continue
		if not out.has("village"):
			out.dist_path = PackedFloat32Array()
			out.dist_path.resize(area)
			out.dist_path.fill(99.0)
			out.village = PackedByteArray()
			out.village.resize(area)
		var f: Dictionary = regions[key].fields
		for y in range(part.position.y, part.end.y):
			for x in range(part.position.x, part.end.x):
				var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
				var src := (y - r.position.y) * r.size.x + x - r.position.x
				var h: float = f.h[src]
				out.h[dst] = h
				out.elev[dst] = maxf(0.0, h)
				out.biome[dst] = f.biome[src]
				out.slope[dst] = f.slope[src]
				out.dist[dst] = f.dist[src]
				out.dw[dst] = f.dw[src]
				out.river[dst] = f.river[src]
				out.path[dst] = f.path[src]
				out.dist_path[dst] = f.dist_path[src]
				out.village[dst] = f.village[src]
				if f.river[src] != 0 or f.lake[src] != 0:
					out.water[dst] = f.water_level[src]


## Внутри общего плана брать окончательные долины, воду и климат, а не заново сырой шум.
## dw — расстояние до любой воды, river — коридор русла; снаружи плана только море.
static func _overlay(w: WorldData, rect: Rect2i, out: Dictionary) -> void:
	out.dw = out.dist.duplicate()
	out.river = PackedByteArray()
	out.river.resize(rect.get_area())
	# Готовая география есть после StageClimate; заготовки WorldData в тестах её не имеют.
	if w.N <= 0 or w.biome.size() != w.N or w.dist_water.size() != w.N:
		return
	var overlap := rect.intersection(Rect2i(0, 0, w.W, w.H))
	var river := w.river_cells()
	for y in range(overlap.position.y, overlap.end.y):
		for x in range(overlap.position.x, overlap.end.x):
			var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
			var src := y * w.W + x
			for name: String in ["h", "biome", "temp", "moist", "elev", "slope"]:
				out[name][dst] = w.get(name)[src]
			out.dist[dst] = w.dist_ocean[src]
			out.dw[dst] = w.dist_water[src]
			out.river[dst] = river[src]
			out.light[dst] = StageClimate.natural_conditions(w, x, y).x


## Лес, камни и тростник чанка растительности key (WorldData.CHUNK_SIZE клеток, в общих координатах; для
## фоновой задачи). Тот же код, что у стартовой области, без троп и домов. Кроме объектов (x, y в клетках, k, v, s)
## возвращает высоты h клеток от (x0 - 1, y0 - 1) со стороной side: по ним считается земля под объектами
static func vegetation(w: WorldData, key: Vector2i) -> Dictionary:
	var cs := WorldData.CHUNK_SIZE
	var x0 := key.x * cs
	var y0 := key.y * cs
	var side := cs + 2
	var f := compute(w, x0 - 1, y0 - 1, side, side)
	var p: Array = WorldData.NOISE_FIELDS.forest
	f.forest = Parallel.fbm_rect(w.noise.forest, x0 - 1, y0 - 1, side, side, p[0], p[1])
	p = WorldData.NOISE_FIELDS.cost
	f.stony = Parallel.fbm_rect(w.noise.cost, x0 - 1, y0 - 1, side, side, p[0], p[1])
	f.age_n = Parallel.fbm_rect(w.noise.forest, x0 - 1, y0 - 1, side, side, 78.0, 2, 91.0, -47.0) # как в age_at
	f.merge(StageVegetation.structure_rect(w, x0 - 1, y0 - 1, side, side))
	# dw уже содержит расстояние до всей воды общего плана, а снаружи — до моря.
	if not f.has("dw"):
		f.dw = f.dist
	var store := StageVegetation.ObjStore.new(null)
	StageVegetation.place_chunk(w.seed_num, x0, y0, x0 + cs, y0 + cs, f, x0 - 1, y0 - 1, side, null, store)
	return {x = store.x, y = store.y, k = store.k, v = store.v, s = store.s, h = f.h, x0 = x0 - 1, y0 = y0 - 1, side = side}


## Поля куска key (для фоновой задачи)
static func compute_chunk(w: WorldData, key: Vector2i) -> Dictionary:
	return compute(w, key.x * C - 1, key.y * C - 1, C + 3, C + 3)


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


## Сведения о клетке за краем карты в том же виде, что WorldData.tile_info, или {}, если куска нет
func info(i: int, j: int) -> Dictionary:
	var at := _locate(i, j)
	var known := _region_at(i, j)
	if at.is_empty() and known.is_empty():
		return {}
	if not known.is_empty():
		# Закреплённая клетка: свои биом, вода и путь; климат — из куска, если он уже есть.
		var g: Dictionary = known[0]
		var q: int = known[1]
		return {i = -1, biome = g.biome[q], river = g.river[q] != 0, path = g.path[q], surface = 0,
			elev = maxf(0.0, g.h[q]), temp = at[0].temp[at[1]] if not at.is_empty() else 0.5,
			moist = at[0].moist[at[1]] if not at.is_empty() else 0.5, slope = g.slope[q]}
	var f: Dictionary = at[0]
	var k: int = at[1]
	return {i = -1, biome = f.biome[k], river = false, path = 0, surface = 0,
		elev = f.elev[k], temp = f.temp[k], moist = f.moist[k], slope = f.slope[k]}
