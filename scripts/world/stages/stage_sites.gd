class_name StageSites
extends RefCounted
## Этап 7.5 (с 9.3). Интересные места вне поселений: дозорные вышки, обелиски, руины, одинокие дома, хутора,
## горные приюты, каменные круги. Ставятся после путей: вышке нужен холм над дорогой, хутору — поле у дороги,
## приюту — горная тропа. Один общий отбор кандидатов с оценкой по типу, без отдельной системы на каждый тип.
## Пишет: w.sites [{x, y, i, type, rank (1..3 — значимость), name, clear — поляна, клеток,
## huts: [{x, y, v, t — вид постройки, a — поворот}]}]. Постройки названы huts, как у поселений:
## растительность и столкновения обходят их тем же кодом. Адрес места — WorldData.place_id("site", x, y).

const PROGRESS := 0.76
const LABEL := "Старые места и хутора"

const STEP := 4             # шаг сетки кандидатов, клеток
const NEAR_VILLAGE := 13.0  # ближе к костру поселения (клеток) — его окрестности, не отдельное место
const SPACE := 14.0         # между любыми двумя местами, клеток
const DENSITY_CELL := 128.0 # размер областей, где тип встречается чаще или реже, клеток
const RING := [Vector2i(10, 0), Vector2i(7, 7), Vector2i(0, 10), Vector2i(-7, 7),
	Vector2i(-10, 0), Vector2i(-7, -7), Vector2i(0, -10), Vector2i(7, -7)]
const SETTLEMENT_REACH := 70.0 # дальше от поселения оценки уже не зависят от расстояния
const OPEN := [Biomes.GRASS, Biomes.STEPPE, Biomes.SAVANNA, Biomes.TUNDRA]
const FARM_BIOMES := [Biomes.GRASS, Biomes.STEPPE, Biomes.SAVANNA]
const RUIN_FOREST := [Biomes.FOREST, Biomes.TAIGA]
## Порядок размещения и столбцов FastGrid.SiteCandidates.
const CANDIDATE_TYPES := ["ruin", "tower", "stones", "shelter", "obelisk", "farm", "house"]

## Сколько мест каждого типа на мир размером 512 (w.scale = 1); сид умножает на 0,5..1,5.
## Порядок — от значимых к мелким: значимые первыми выбирают лучшие места.
const TYPES := {
	ruin = {base = 3.0, space = 50.0, clear = 0.0, title = "руины"},
	tower = {base = 2.0, space = 70.0, clear = 2.0, title = "дозорная вышка"},
	stones = {base = 0.9, space = 120.0, clear = 4.0, title = "каменный круг"},
	shelter = {base = 1.2, space = 50.0, clear = 2.0, title = "горный приют"},
	obelisk = {base = 1.4, space = 80.0, clear = 1.5, title = "обелиск"},
	farm = {base = 4.0, space = 22.0, clear = 5.0, title = "хутор"},
	house = {base = 3.5, space = 30.0, clear = 3.0, title = "одинокий дом"},
	# 18.11.2026: ставятся отдельно (_place_fishing, _place_benches), а не по общей сетке кандидатов: base 0
	fishing = {base = 0.0, space = 40.0, clear = 2.0, title = "рыбацкий домик"},
	bench = {base = 0.0, space = 16.0, clear = 1.0, title = "смотровая лавка"},
}
const FISHING_CHANCE := 0.4    # доля озёр с рыбацким домиком (но хотя бы один на мир, если есть подходящее озеро)
const FISHING_MIN_CELLS := 60  # озёра меньше (клеток воды) не считаются
const BENCH_CHANCE := 0.5      # доля вершин с лавкой
const BENCH_RINGS := [6, 8, 10, 12, 14]  # клеток от вершины: 24–56 м ниже по склону
const BENCH_SKIP := [Biomes.SNOW, Biomes.PEAK] # на снегу и на ледниках лавок нет
## Допуски перепада земли под постройками и памятниками (SettlementSets.flat_of).


static func run(w: WorldData) -> void:
	if WorldTemplate.has_single_road(w.template_id):
		_run_expedition(w)
		return
	var W := w.W
	var river := w.river_cells()
	var selection := _select_candidates(w, river)
	var dist_path: PackedFloat32Array = selection.distance
	var candidates: Array = selection.candidates
	var sites: Array = []
	var names := {}
	for s: SettlementData in w.settlements:
		names[s.name] = true
	for t in CANDIDATE_TYPES.size():
		var type: String = CANDIDATE_TYPES[t]
		var rng := WGRandom.new(WGRandom.derive(w.seed_num, "site.count." + type))
		var want := roundi(TYPES[type].base * w.scale * (0.5 + rng.next_float()))
		var placed := 0
		for i: int in candidates[t]:
			if placed >= want:
				break
			var x := (i % W) + 0.5
			var y := (i / W) + 0.5
			if _crowded(sites, type, x, y):
				continue
			var site := _build(w, river, type, x, y, i, names)
			if site.is_empty():
				continue
			sites.append(site)
			placed += 1
	_place_fishing(w, river, dist_path, sites, names)
	_place_benches(w, river, dist_path, sites, names)
	w.sites = sites


## Тип 2 («Речная экспедиция»): редкие точки интереса (число задаётся типом, не площадью) и
## гарантированный рыбацкий домик с причалом на берегу широкой реки у финишной базы (через FishingLayout).
static func _run_expedition(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var river := w.river_cells()
	var axis := ValleyAxis.for_world(w)
	var cfg := axis.cfg
	var counts := cfg.site_counts(H)
	var human := PackedByteArray()
	human.resize(w.N)
	for i in w.N:
		human[i] = int(w.path_mask[i] >= 2)
	var dist_path := Grid.distance_field(W, H, human)
	var sites: Array = []
	var names := {}
	for s: SettlementData in w.settlements:
		names[s.name] = true

	# 1. Рыбацкий домик с причалом у финишной базы — прямо на берегу широкой реки.
	if int(counts.get("fishing", 0)) > 0 and w.settlements.size() >= 2:
		_place_expedition_fishing(w, river, axis, w.settlements[1], sites, names)

	var y_start := int(w.settlements[0].y) if not w.settlements.is_empty() else 54
	var y_finish := int(w.settlements[1].y) if w.settlements.size() >= 2 else H - 94
	var span := maxi(120, y_finish - y_start)
	var seed_hash := WGRandom.derive(w.seed_num, "site.expedition")

	# 2. Дозорные вышки на заметных отрогах у дороги.
	var want_towers := int(counts.get("tower", 0))
	for t in want_towers:
		var band_y0 := y_start + roundi(float(span) * (0.20 + 0.36 * float(t)))
		var band_y1 := y_start + roundi(float(span) * (0.48 + 0.34 * float(t)))
		_place_expedition_point(w, river, axis, dist_path, sites, names, "tower", band_y0, band_y1,
			3.0, 18.0, 0.42, true, seed_hash + t * 97)

	# 3. Горный/лесной приют у дороги в средней части маршрута.
	if int(counts.get("shelter", 0)) > 0:
		_place_expedition_point(w, river, axis, dist_path, sites, names, "shelter",
			y_start + roundi(float(span) * 0.35), y_start + roundi(float(span) * 0.68),
			2.2, 9.5, 0.30, false, seed_hash + 313)

	# 4. Смотровые лавки у дороги лицом к реке.
	var want_benches := int(counts.get("bench", 0))
	for b in want_benches:
		var frac0 := 0.14 + float(b) * (0.72 / float(maxi(1, want_benches)))
		var frac1 := minf(0.90, frac0 + 0.65 / float(maxi(1, want_benches)))
		_place_expedition_bench(w, river, axis, dist_path, sites, names,
			y_start + roundi(float(span) * frac0), y_start + roundi(float(span) * frac1), seed_hash + 521 + b * 41)

	# 5. Одинокий хутор на противоположном берегу реки (точка масштаба, без дороги).
	if int(counts.get("opposite_farm", 0)) > 0:
		_place_opposite_farm(w, river, axis, sites, names,
			y_start + roundi(float(span) * 0.28), y_start + roundi(float(span) * 0.72), seed_hash + 809)

	w.sites = sites


static func _place_expedition_fishing(w: WorldData, river: PackedByteArray, axis: ValleyAxis,
		finish: SettlementData, sites: Array, names: Dictionary) -> void:
	var W := w.W
	var H := w.H
	var cfg := axis.cfg
	var surface := Heightfield.base_of(w)
	var fy := roundi(finish.y)
	var y0 := clampi(fy - cfg.fishing_search_back, 16, H - 24)
	var y1 := clampi(fy + cfg.fishing_search_fwd, y0, H - 16)
	var best := {}
	for y in range(y0, y1 + 1):
		var ax := axis.axis_x_at(float(y))
		var rhw := axis.river_hw_at(y)
		# Направление к ближайшей точке русла (перпендикулярно оси реки даже на финишном повороте).
		var tangent := Vector2(axis.axis_x_at(float(mini(H - 1, y + 2))) - axis.axis_x_at(float(maxi(0, y - 2))), 4.0).normalized()
		var to_river := Vector2(-tangent.y, tangent.x)
		if to_river.x * float(axis.road_side) > 0.0:
			to_river = -to_river
		var facing := atan2(to_river.x, to_river.y)
		# Ставим домик у кромки берега: сухой фундамент + причал FishingLayout достаёт реку (depth > 0.3 м).
		for off_step in range(11, 44, 2):
			var off := float(off_step) * 0.1
			var x := clampi(roundi(ax + (rhw + off) * float(axis.road_side)), 4, W - 5)
			var j := y * W + x
			if w.ocean[j] != 0 or w.lake[j] != 0 or river[j] != 0 or w.path_mask[j] != 0:
				continue
			var cx := float(x) + 0.5
			var cy := float(y) + 0.5
			var d_fin := Grid.hypot(cx - finish.x, cy - finish.y)
			if d_fin < cfg.fishing_min_dist or d_fin > cfg.fishing_max_dist:
				continue
			if not _fits(w, river, "house_timber", cx, cy):
				continue
			var origin := Vector3(cx * GameConfig.TILE, surface.ground_at(cx * GameConfig.TILE, cy * GameConfig.TILE), cy * GameConfig.TILE)
			var m := FishingLayout.measure(surface, origin, facing)
			var tip := origin + Basis(Vector3.UP, facing) * Vector3(0.0, 0.0, FishingLayout.START + m.len)
			# Настоящий причал в реку: конец настила над водой > 0.3 м (не сухая заглушка).
			if surface.depth_at(tip.x, tip.z) <= 0.3 or m.len < 4.5:
				continue
			var score := -w.slope[j] * 4.5 - absf(m.dy) * 2.2 - absf(d_fin - 18.0) * 0.06 - absf(m.len - 11.0) * 0.04
			if best.is_empty() or score > float(best.score):
				best = {score = score, x = cx, y = cy, i = j, facing = facing}
	if not best.is_empty():
		var site := _build(w, river, "fishing", float(best.x), float(best.y), int(best.i), names, float(best.facing))
		if not site.is_empty():
			sites.append(site)


static func _place_expedition_point(w: WorldData, river: PackedByteArray, axis: ValleyAxis, dist_path: PackedFloat32Array,
		sites: Array, names: Dictionary, type: String, y0: int, y1: int, dp_min: float, dp_max: float,
		max_slope: float, prefer_prom: bool, seed_hash: int) -> void:
	var W := w.W
	var H := w.H
	var best := {}
	var ya := clampi(y0, 18, H - 18)
	var yb := clampi(y1, ya, H - 18)
	for y in range(ya, yb + 1, 3):
		var ax := axis.axis_x_at(float(y))
		var rhw := axis.river_hw_at(y)
		var x_a := clampi(roundi(ax + (rhw + 4.0) * float(axis.road_side)), 6, W - 7)
		var x_b := clampi(roundi(ax + 78.0 * float(axis.road_side)), 6, W - 7)
		for x in range(mini(x_a, x_b), maxi(x_a, x_b) + 1, 3):
			var j := y * W + x
			if w.ocean[j] != 0 or w.lake[j] != 0 or river[j] != 0 or w.path_mask[j] != 0:
				continue
			var dp := dist_path[j]
			if dp < dp_min or dp > dp_max or w.slope[j] > max_slope:
				continue
			if _settlement_dist(w.settlements, x, y) < 22.0:
				continue
			var cx := float(x) + 0.5
			var cy := float(y) + 0.5
			if _crowded(sites, type, cx, cy) or not _fits(w, river, type, cx, cy):
				continue
			var prom := _prominence(w.elev, W, H, x, y)
			var score := (prom * 22.0 if prefer_prom else -w.slope[j] * 4.0) - dp * 0.05 + WGRandom.hash2(x, y, seed_hash) * 0.35
			if best.is_empty() or score > float(best.score):
				best = {score = score, x = cx, y = cy, i = j}
	if not best.is_empty():
		var site := _build(w, river, type, float(best.x), float(best.y), int(best.i), names)
		if not site.is_empty():
			sites.append(site)


static func _place_expedition_bench(w: WorldData, river: PackedByteArray, axis: ValleyAxis, dist_path: PackedFloat32Array,
		sites: Array, names: Dictionary, y0: int, y1: int, seed_hash: int) -> void:
	var W := w.W
	var H := w.H
	var best := {}
	var ya := clampi(y0, 18, H - 18)
	var yb := clampi(y1, ya, H - 18)
	for y in range(ya, yb + 1, 3):
		var ax := axis.axis_x_at(float(y))
		var rhw := axis.river_hw_at(y)
		var x_a := clampi(roundi(ax + (rhw + 3.0) * float(axis.road_side)), 6, W - 7)
		var x_b := clampi(roundi(ax + 72.0 * float(axis.road_side)), 6, W - 7)
		for x in range(mini(x_a, x_b), maxi(x_a, x_b) + 1, 3):
			var j := y * W + x
			if w.ocean[j] != 0 or w.lake[j] != 0 or river[j] != 0 or w.path_mask[j] != 0:
				continue
			var dp := dist_path[j]
			if dp < 1.8 or dp > 6.5 or w.slope[j] > 0.32 or w.biome[j] in BENCH_SKIP:
				continue
			if _settlement_dist(w.settlements, x, y) < 18.0:
				continue
			var cx := float(x) + 0.5
			var cy := float(y) + 0.5
			if _crowded(sites, "bench", cx, cy) or not _fits(w, river, "bench", cx, cy):
				continue
			var prom := _prominence(w.elev, W, H, x, y)
			var sd := (cx - ax) * float(axis.road_side)
			var view_bonus := 0.5 if sd < rhw + 14.0 else maxf(0.0, prom * 14.0)
			var score := view_bonus - w.slope[j] * 3.0 + WGRandom.hash2(x, y, seed_hash) * 0.3
			if best.is_empty() or score > float(best.score):
				best = {score = score, x = cx, y = cy, i = j, facing = atan2(ax - cx, 0.0)}
	if not best.is_empty():
		var site := _build(w, river, "bench", float(best.x), float(best.y), int(best.i), names, float(best.facing))
		if not site.is_empty():
			sites.append(site)


static func _place_opposite_farm(w: WorldData, river: PackedByteArray, axis: ValleyAxis,
		sites: Array, names: Dictionary, y0: int, y1: int, seed_hash: int) -> void:
	var W := w.W
	var H := w.H
	var opp := -axis.road_side
	var best := {}
	var ya := clampi(y0, 24, H - 24)
	var yb := clampi(y1, ya, H - 24)
	for y in range(ya, yb + 1, 3):
		var ax := axis.axis_x_at(float(y))
		var rhw := axis.river_hw_at(y)
		var x_a := clampi(roundi(ax + (rhw + 3.5) * float(opp)), 6, W - 7)
		var x_b := clampi(roundi(ax + 19.0 * float(opp)), 6, W - 7)
		for x in range(mini(x_a, x_b), maxi(x_a, x_b) + 1, 2):
			var j := y * W + x
			if w.ocean[j] != 0 or w.lake[j] != 0 or river[j] != 0 or w.slope[j] > 0.24:
				continue
			var cx := float(x) + 0.5
			var cy := float(y) + 0.5
			if _crowded(sites, "farm", cx, cy) or not _fits(w, river, "house_timber", cx, cy):
				continue
			var sd_opp := (cx - ax) * float(opp)
			var score := -w.slope[j] * 5.0 - absf(sd_opp - (rhw + 7.0)) * 0.08 + WGRandom.hash2(x, y, seed_hash) * 0.35
			if best.is_empty() or score > float(best.score):
				best = {score = score, x = cx, y = cy, i = j, facing = atan2(ax - cx, 0.0)}
	if not best.is_empty():
		var site := _build(w, river, "farm", float(best.x), float(best.y), int(best.i), names, float(best.facing))
		if not site.is_empty():
			sites.append(site)


static func _select_candidates(w: WorldData, river: PackedByteArray) -> Dictionary:
	var pick_seed := WGRandom.derive(w.seed_num, "site.candidate")
	var density_seeds := PackedInt64Array()
	for type: String in CANDIDATE_TYPES:
		density_seeds.append(WGRandom.derive(w.seed_num, "site.density." + type))
	var fast := Grid.fast_grid()
	if fast == null:
		return _select_script(w, river, pick_seed, density_seeds)
	var habit := PackedFloat64Array()
	var flags := PackedByteArray()
	for bi in Biomes.LIST.size():
		habit.append(float(Biomes.LIST[bi].get("habit", 0.0)))
		flags.append(int(bi in OPEN) | (int(bi in FARM_BIOMES) << 1) | (int(bi in RUIN_FOREST) << 2))
	var settlements := PackedFloat64Array()
	for s: SettlementData in w.settlements:
		settlements.append(s.x)
		settlements.append(s.y)
	return fast.SiteCandidates(w.W, w.H, STEP, w.path_mask, w.ocean, w.lake, river, w.elev, w.slope, w.biome,
		habit, flags, settlements, NEAR_VILLAGE, SETTLEMENT_REACH, pick_seed, density_seeds, DENSITY_CELL)


static func _select_script(w: WorldData, river: PackedByteArray, pick_seed: int, density_seeds: PackedInt64Array) -> Dictionary:
	var W := w.W
	var H := w.H
	var paths := w.path_mask
	var ocean := w.ocean
	var lake := w.lake
	var elev := w.elev
	var slope := w.slope
	var biome := w.biome
	var human := PackedByteArray()
	human.resize(w.N)
	for i in w.N:
		human[i] = int(paths[i] >= 2)
	var dist_path := Grid.distance_field(W, H, human)
	var cand := []
	for t in CANDIDATE_TYPES.size():
		cand.append([])
	for y in range(8, H - 8, STEP):
		var nearby: Array[SettlementData] = []
		for s: SettlementData in w.settlements:
			if absf(s.y - y) <= SETTLEMENT_REACH:
				nearby.append(s)
		for x in range(8, W - 8, STEP):
			var i := y * W + x
			if ocean[i] != 0 or lake[i] != 0 or river[i] != 0 or paths[i] != 0:
				continue
			var settle := _settlement_dist(nearby, x, y)
			if settle < NEAR_VILLAGE:
				continue
			var f := {e = elev[i], sl = slope[i], dp = dist_path[i], settle = settle, bi = biome[i],
				habit = float(Biomes.LIST[biome[i]].get("habit", 0.0)), prom = _prominence(elev, W, H, x, y),
				r = WGRandom.hash2(x, y, pick_seed)}
			for t in CANDIDATE_TYPES.size():
				var s := _score(CANDIDATE_TYPES[t], f)
				if s == -INF:
					continue
				# Области, где тип часто встречается, и области почти без него: места не размазаны ровно.
				var d := StageLandmarks.patches(x, y, DENSITY_CELL, density_seeds[t])
				if d < 0.22:
					continue
				# Vector2 сортируется встроенным сравнением, без вызова функции на каждую пару (клетка < 2^24).
				cand[t].append(Vector2(s + (d - 0.5) * 1.2, -i))
	var ranked := []
	for list: Array in cand:
		list.sort()
		var cells := PackedInt32Array()
		cells.resize(list.size())
		for k in range(list.size() - 1, -1, -1):
			cells[list.size() - 1 - k] = -int(list[k].y)
		ranked.append(cells)
	return {distance = dist_path, candidates = ranked}


## Оценка клетки для типа места или -INF, если тип здесь не стоит
static func _score(type: String, f: Dictionary) -> float:
	match type:
		"tower":
			# Холм с видом на дорогу или тропу.
			if f.prom < 0.02 or f.dp > 24.0 or f.sl > 0.5 or f.e > 0.62:
				return -INF
			return f.prom * 25.0 + (1.0 - f.dp / 24.0) * 0.6 + f.r * 0.3
		"obelisk":
			# У пути, чаще на открытом месте или на перевале.
			if f.dp < 1.5 or f.dp > 4.0 or f.sl > 0.35 or f.settle < 30.0:
				return -INF
			return f.e * 0.8 + (0.3 if f.bi in OPEN else 0.0) + f.r * 0.8
		"ruin":
			# Брошенное место: в стороне от нынешних дорог, часто на возвышенности.
			if f.habit <= 0.0 and f.bi not in RUIN_FOREST:
				return -INF
			if f.sl > 0.6 or f.settle < 30.0:
				return -INF
			return f.prom * 15.0 + f.r * 0.8 + (0.4 if f.settle > 45.0 else 0.0) + (0.3 if f.dp > 8.0 else 0.0)
		"house":
			if f.habit < 0.2 or f.dp < 2.0 or f.dp > 8.0 or f.sl > 0.35 or f.settle < 20.0:
				return -INF
			return f.habit + f.r * 0.6 + (0.3 if f.settle > 40.0 else 0.0)
		"farm":
			# Поле у дороги в дне пути от поселения.
			if f.bi not in FARM_BIOMES or f.sl > 0.25:
				return -INF
			if f.dp < 2.0 or f.dp > 10.0 or f.settle > SETTLEMENT_REACH:
				return -INF
			return f.habit + (1.0 - absf(f.settle - 30.0) / 40.0) * 0.5 + f.r * 0.4
		"shelter":
			# Высоко в горах у тропы, далеко от жилья.
			if f.e < 0.45 or f.sl > 0.55 or f.dp > 10.0 or f.settle < 40.0:
				return -INF
			return f.e + (1.0 - f.dp / 10.0) * 0.3 + f.r * 0.3
		"stones":
			if f.bi not in OPEN or f.prom < 0.008 or f.dp < 6.0 or f.settle < 35.0 or f.sl > 0.4:
				return -INF
			return f.prom * 20.0 + f.r * 0.5
	return -INF


static func _crowded(sites: Array, type: String, x: float, y: float) -> bool:
	var space: float = TYPES[type].space
	for s: SiteData in sites:
		var d := Grid.hypot(s.x - x, s.y - y)
		if d < SPACE or s.type == type and d < space:
			return true
	return false


## Место со значимостью, названием и постройками; пусто, если главная постройка не встала
## facing — поворот постройки (вид «вперёд», +z модели) вместо случайного: рыбацкий домик лицом к воде, лавка лицом от вершины
static func _build(w: WorldData, river: PackedByteArray, type: String, x: float, y: float, i: int, names: Dictionary, facing := NAN) -> SiteData:
	var rng := WGRandom.at(w.seed_num, "site." + type, floori(x), floori(y))
	var prom := _prominence(w.elev, w.W, w.H, floori(x), floori(y))
	var rank := 2
	var parts: Array = [] # [вид, смещение в клетках] до поворота; первая — главная
	match type:
		"tower":
			rank = 3 if prom > 0.04 else 2
			parts = [["tower", Vector2.ZERO]]
		"obelisk":
			rank = 3 if w.elev[i] > 0.45 else 2
			parts = [["obelisk", Vector2.ZERO]]
		"stones":
			rank = 3 if prom > 0.02 else 2
			var n := 7 + floori(rng.next_float() * 3)
			for k in n:
				var a := TAU * k / n
				parts.append(["stone", Vector2(cos(a), sin(a)) * 1.25])
		"shelter":
			parts = [["shelter", Vector2.ZERO]]
		"fishing":
			rank = 1
			# домик и причал в одной точке: причал (модель и настил) уходит от двери в воду, длину считает FishingLayout по рельефу
			parts = [["house_timber", Vector2.ZERO], ["pier", Vector2.ZERO]]
		"bench":
			rank = 1
			parts = [["bench", Vector2.ZERO]]
		"house":
			rank = 1
			var home_id := SettlementSets.pick_site_home(w.biome[i], w.elev[i], w.slope[i], rng.next_float())
			parts = [[home_id, Vector2.ZERO]]
			if rng.next_float() < 0.65:
				var aux := "woodpile_rack" if w.biome[i] in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE] else ("well_canopy" if rng.next_float() < 0.45 else "shed")
				parts.append([aux, Vector2(1.55, -0.45)])
		"farm":
			rank = 2 if Biomes.LIST[w.biome[i]].get("habit", 0.0) > 0.8 and rng.next_float() < 0.4 else 1
			var home_id := SettlementSets.pick_site_home(w.biome[i], w.elev[i], w.slope[i], rng.next_float())
			var barn1 := SettlementSets.pick_site_barn(w.biome[i], rng.next_float())
			parts = [[home_id, Vector2.ZERO], [barn1, Vector2(1.9, 0.2)], ["hay", Vector2(0.4, 1.8)]]
			if rank == 2:
				parts += [["barn_loft", Vector2(-0.3, -1.9)], ["well_canopy" if rng.next_float() < 0.5 else "hay", Vector2(1.6, 1.7)]]
		"ruin":
			# Крепость — редкая: только на заметном холме
			rank = 3 if prom > 0.045 and rng.next_float() < 0.5 else (2 if rng.next_float() < 0.5 else 1)
			var rooms := [Vector2.ZERO, Vector2(1.1, 0.3), Vector2(-0.5, 1.2), Vector2(0.7, -1.2), Vector2(1.9, 1.2)]
			for k in [1, 3, 5][rank - 1]:
				parts.append(["ruin", rooms[k]])
			if rank == 3:
				parts.append(["keep", Vector2(-1.4, -0.6)])
	var turn := rng.next_float() * TAU if is_nan(facing) else facing
	var huts: Array[HutData] = []
	for k in parts.size():
		var off: Vector2 = parts[k][1].rotated(turn)
		var hx := x + off.x
		var hy := y + off.y
		if parts[k][0] == "pier" or _fits(w, river, parts[k][0], hx, hy):
			var variant := floori(rng.next_float() * 4)
			var jitter := (rng.next_float() - 0.5) * 0.3
			huts.append(HutData.new(hx, hy, variant, parts[k][0], turn + (jitter if is_nan(facing) else 0.0)))
		elif k == 0:
			return SiteData.new()
	# Круг, от которого осталась пара камней, не читается как круг
	if type == "stones" and huts.size() < 5:
		return SiteData.new()
	# Названия в мире не повторяются: при совпадении берётся следующий вариант того же места.
	var name := ""
	for k in 6:
		name = _name(w, type, rank, floori(x) + k * 7919, floori(y))
		if not names.has(name):
			break
	names[name] = true
	return SiteData.new(x, y, i, type, rank, name, TYPES[type].clear, huts)


## Постройка на сухой ровной земле и не на пути (как дома поселений после StageTrails._clear_huts).
## Перепад — по высоте клеток: игровой рельеф для этого строить дорого, а на клетке 4 м разница мала.
static func _fits(w: WorldData, river: PackedByteArray, kind: String, hx: float, hy: float) -> bool:
	if hx < 2 or hy < 2 or hx >= w.W - 2 or hy >= w.H - 2:
		return false
	var low := INF
	var high := -INF
	for dz: float in [-0.55, 0.0, 0.55]:
		for dx: float in [-0.55, 0.0, 0.55]:
			var j := floori(hy + dz) * w.W + floori(hx + dx)
			if w.path_mask[j] != 0 or w.ocean[j] != 0 or w.lake[j] != 0 or river[j] != 0:
				return false
			low = minf(low, w.h[j])
			high = maxf(high, w.h[j])
	return (high - low) * GameConfig.HS <= SettlementSets.flat_of(kind)


## Рыбацкие домики на берегах озёр (18.11.2026): у каждого озера (связная вода w.lake от FISHING_MIN_CELLS клеток — не только
## названные) с шансом FISHING_CHANCE, но хотя бы один на мир. Домик стоит на суше в двух клетках от воды (в 3×3 клетках вокруг
## воды нет, как требует _fits), дверь и причал смотрят на воду.
static func _place_fishing(w: WorldData, river: PackedByteArray, dist_path, sites: Array, names: Dictionary) -> void:
	var W := w.W
	var lake := w.lake
	var start := lake.find(1)
	if start < 0:
		return
	var comp := PackedInt32Array()
	comp.resize(w.N)
	comp.fill(-1)
	var sizes: Array[int] = []
	var lake_cells := PackedInt32Array()
	var seed_hash := WGRandom.derive(w.seed_num, "site.fishing")
	while start >= 0:
		lake_cells.append(start)
		if comp[start] < 0:
			var group := sizes.size()
			var queue := PackedInt32Array([start])
			comp[start] = group
			var head := 0
			while head < queue.size():
				var c := queue[head]
				head += 1
				var x := c % W
				for direction in 8:
					var n: int = c + Grid.DY[direction] * W + Grid.DX[direction]
					if n >= 0 and n < w.N and absi(n % W - x) <= 1 and lake[n] != 0 and comp[n] < 0:
						comp[n] = group
						queue.append(n)
			sizes.append(queue.size())
		start = lake.find(1, start + 1)
	var best := {}   # озеро -> {score, x, y, i, facing}
	var steps: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for i in lake_cells:
		var group := comp[i]
		if sizes[group] < FISHING_MIN_CELLS:
			continue
		var x := i % W
		var y := i / W
		for step: Vector2i in steps:
			# от клетки воды двигаемся прочь от неё: первая клетка суши рядом, домик — через одну
			var near := Vector2i(x, y) + step
			if near.x < 2 or near.y < 2 or near.x >= W - 2 or near.y >= w.H - 2 or lake[near.y * W + near.x] != 0:
				continue
			var spot := Vector2i(x, y) + step * 2
			var j := spot.y * W + spot.x
			if lake[j] != 0 or w.ocean[j] != 0 or river[j] != 0:
				continue
			var cx := spot.x + 0.5
			var cy := spot.y + 0.5
			if _settlement_dist(w.settlements, spot.x, spot.y) < NEAR_VILLAGE * 0.5 or not _fits(w, river, "house_timber", cx, cy):
				continue
			# ровнее — лучше; ближе к путям — лучше (до домика дойти); остальное решает хеш
			var score := -w.slope[j] * 4.0 - minf(dist_path[j], 30.0) * 0.02 + WGRandom.hash2(spot.x, spot.y, seed_hash) * 0.5
			if not best.has(group) or score > best[group].score:
				best[group] = {score = score, x = cx, y = cy, i = j, facing = atan2(-float(step.x), -float(step.y))}
	var order := best.keys()
	order.sort()
	var chosen: Array = []
	for group: int in order:
		var rng := WGRandom.new(WGRandom.derive(w.seed_num, "site.fishing.%d" % group))
		if rng.next_float() < FISHING_CHANCE:
			chosen.append(group)
	if chosen.is_empty() and not order.is_empty():
		var largest: int = order[0] # хотя бы один: самое большое озеро с подходящим берегом
		for group: int in order:
			if sizes[group] > sizes[largest]:
				largest = group
		chosen.append(largest)
	for group: int in chosen:
		var c: Dictionary = best[group]
		if _crowded(sites, "fishing", c.x, c.y):
			continue
		var site := _build(w, river, "fishing", c.x, c.y, c.i, names, c.facing)
		if not site.is_empty():
			sites.append(site)

## Лавки у вершин (18.11.2026): у каждой вершины с шансом BENCH_CHANCE, ниже самой вершины (24–56 м), не на снегу и ледниках,
## на ровном месте; лицом от вершины, к долине. Ближе к тропе — лучше.
static func _place_benches(w: WorldData, river: PackedByteArray, dist_path, sites: Array, names: Dictionary) -> void:
	var W := w.W
	var seed_hash := WGRandom.derive(w.seed_num, "site.bench")
	for pk in w.peaks:
		var rng := WGRandom.new(WGRandom.derive(w.seed_num, "site.bench.%d.%d" % [floori(pk.x), floori(pk.y)]))
		if rng.next_float() >= BENCH_CHANCE:
			continue
		var top := w.elev[clampi(floori(pk.y), 0, w.H - 1) * W + clampi(floori(pk.x), 0, W - 1)]
		var best := {}
		for ring: int in BENCH_RINGS:
			for k in 16:
				var angle := TAU * k / 16.0
				var dir := Vector2(cos(angle), sin(angle))
				var cell := Vector2i((Vector2(pk.x, pk.y) + dir * ring).floor())
				if cell.x < 8 or cell.y < 8 or cell.x >= W - 8 or cell.y >= w.H - 8:
					continue
				var j := cell.y * W + cell.x
				if w.biome[j] in BENCH_SKIP or w.ocean[j] != 0 or w.lake[j] != 0 or river[j] != 0 or w.slope[j] > 0.4 or w.elev[j] >= top:
					continue
				var cx := cell.x + 0.5
				var cy := cell.y + 0.5
				if not _fits(w, river, "bench", cx, cy):
					continue
				var score := -w.slope[j] * 3.0 + (0.6 if dist_path[j] < 8.0 else 0.0) + WGRandom.hash2(cell.x, cell.y, seed_hash) * 0.4
				if best.is_empty() or score > best.score:
					best = {score = score, x = cx, y = cy, i = j, facing = atan2(dir.x, dir.y)}
		if best.is_empty() or _crowded(sites, "bench", best.x, best.y):
			continue
		var site := _build(w, river, "bench", best.x, best.y, best.i, names, best.facing)
		if not site.is_empty():
			sites.append(site)


static func _name(w: WorldData, type: String, rank: int, x: int, y: int) -> String:
	match type:
		"ruin":
			var old := w.make_name(Names.SETTLEMENT, "site.ruin", x, y)
			return ("Крепость " if rank == 3 else "Руины ") + old
		"farm":
			return "Хутор " + w.make_name(Names.SETTLEMENT, "site.farm", x, y)
	return w.make_name(Names.SITES[type], "site." + type, x, y)


## Расстояние до ближайшего поселения, клеток
static func _settlement_dist(settlements: Array, x: int, y: int) -> float:
	var best := INF
	for s: SettlementData in settlements:
		var dx := s.x - x
		var dy := s.y - y
		best = minf(best, dx * dx + dy * dy)
	return sqrt(best)


## Насколько клетка выше окрестности на расстоянии 10 клеток (единицы elev, 0,01 ≈ 2,6 м)
static func _prominence(elev: PackedFloat32Array, W: int, H: int, x: int, y: int) -> float:
	var sum := 0.0
	for offset: Vector2i in RING:
		var sx := clampi(x + offset.x, 0, W - 1)
		var sy := clampi(y + offset.y, 0, H - 1)
		sum += elev[sy * W + sx]
	return elev[y * W + x] - sum / 8.0


