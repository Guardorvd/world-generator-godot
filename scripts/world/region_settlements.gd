extends RefCounted
## Поселения после согласованной воды. Исходный WorldData не меняется.
## Один лучший участок в мировом квадрате поиска; расстояния гарантированы даже без загрузки соседа
## (с аудита 29.10 — рангом квадратов, см. prepare).
## 14.4: квадрат 128 клеток (было 160) делит область (256) ровно на четыре, а окно поиска ±24 (было ±12)
## всегда целиком внутри неё: раньше в область попадал один-два центра, и у большинства областей
## не было ни поселений, ни дорог между ними. Плотность теперь близка к стартовому плану.
const CELL := 128
const SEARCH := 24
const MARGIN := 8 # весь дом и хозяйственный пояс остаются в своей области


## P0 аудита 29.10: квадрат 128 при окне ±24 сам по себе не держит spacing (до 129,6) между соседними
## квадратами — центры окон сходятся до 80 клеток. Теперь у каждого квадрата мировой приоритет; квадрат
## уступает всем восьми соседям выше рангом. ledger — журнал: его поселения закреплены, как стартовые.
static func prepare(source: WorldData, region: Dictionary, surface: Dictionary, ledger := {}) -> Dictionary:
	if not surface.get("ready", false):
		return {ready = false, reason = "water_not_ready", settlements = []}
	var started := Time.get_ticks_usec()
	var w := local_world(source, region, surface)
	var profile := {geography_ms = (Time.get_ticks_usec() - started) / 1000.0}
	started = Time.get_ticks_usec()
	var rect: Rect2i = region.rect
	var origin: Vector2i = region.sample_rect.position
	var inside := rect.grow(-MARGIN)
	var wet := PackedByteArray()
	wet.resize(w.N)
	for i in w.N: wet[i] = int(w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0)
	var seed := WGRandom.derive(source.seed_num, "settlement.candidate")
	var density_seed := WGRandom.derive(source.seed_num, "settlement.density") # как density_at, один раз
	# Закреплённые места (стартовый план и журнал) не двигаются, новые держатся от них на полусумме spacing.
	var pinned: Array = []
	pinned.append_array(source.settlements)
	pinned.append_array(EntityCodec.settlements(ledger.get("settlements", [])))
	# Квадраты области — по убыванию мирового приоритета; поселения хранятся в прежнем порядке квадратов.
	var cells: Array[Vector2i] = []
	for gy in range(floori(float(rect.position.y) / CELL), ceili(float(rect.end.y) / CELL)):
		for gx in range(floori(float(rect.position.x) / CELL), ceili(float(rect.end.x) / CELL)):
			# Не выбирать из усечённого окна: это давало бы другой центр у границы.
			if inside.encloses(window(Vector2i(gx, gy))): cells.append(Vector2i(gx, gy))
	var by_priority := cells.duplicate()
	by_priority.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return outranks(source.seed_num, a, b))
	var winners := {} # квадрат -> [x, y, spacing] в мировых клетках
	var chosen := {} # квадрат -> SettlementData
	for cell: Vector2i in by_priority:
		var search := window(cell)
		# Соседи выше рангом: свои — по фактическому месту, чужой области — по всему окну с наибольшим spacing.
		# Чужая область этот квадрат учитывает так же, поэтому пара соседей разнесена при любом порядке загрузки.
		var above: Array = []
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var other := cell + Vector2i(dx, dy)
				if other == cell or not outranks(source.seed_num, other, cell): continue
				if other in cells:
					if winners.has(other): above.append(winners[other])
				elif can_settle(other):
					above.append([window(other), widest(source.seed_num, other)])
		var best: Array = []
		for y in range(search.position.y, search.end.y, 2):
			for x in range(search.position.x, search.end.x, 2):
				var i := (y - origin.y) * w.W + x - origin.x
				var bd: Dictionary = Biomes.LIST[w.biome[i]]
				if region.fields.fixed[i] != 0 or wet[i] != 0 or not bd.has("habit") or w.slope[i] > 0.6: continue
				var access := StageLandmarks._site_access(w, i, wet)
				if access < 0.35: continue
				var density := StageLandmarks.patches(x, y, 96.0, density_seed)
				var spacing := 96.0 * lerpf(1.35, 0.7, density)
				var at := Vector2(x + 0.5, y + 0.5)
				var close := false
				for old: SettlementData in pinned:
					if at.distance_to(Vector2(old.x, old.y)) < (spacing + EntityCodec.value(old, "spacing", 129.6)) * 0.5:
						close = true
						break
				for item: Array in above:
					if close: break
					if item[0] is Rect2i:
						close = distance_to_window(at, item[0]) < (spacing + item[1]) * 0.5
					else:
						close = at.distance_to(Vector2(item[0], item[1])) < (spacing + item[2]) * 0.5
				if close: continue
				var dw := w.dist_water[i]
				var score: float = bd.habit + WGRandom.hash2(x, y, seed) * 0.2 - w.slope[i] * 0.6
				score += access * 0.45 + density * 0.35
				if dw >= 1.5 and dw <= 6.0: score += 0.6
				elif dw > 16.0: score -= minf(0.6, (dw - 16.0) / 40.0)
				if dw < 1.5: score -= 0.4
				# Нужен только победитель: линейный максимум с тем же правилом равенства, что у
				# StageLandmarks._by_score_desc (при равной оценке — меньший индекс; он встречается раньше).
				if best.is_empty() or score > best[0]: best = [score, i, access, density, spacing]
		if best.is_empty(): continue
		var c: Array = best
		var i: int = c[1]
		var x: int = i % w.W + origin.x
		var y: int = i / w.W + origin.y
		winners[cell] = [x + 0.5, y + 0.5, c[4]]
		var importance := clampf(float(w.biome[i] == Biomes.GRASS) * 0.15 + c[2] * 0.5 + c[3] * 0.3
			+ (0.12 if w.dist_water[i] < 6.0 else 0.0), 0.0, 1.0)
		var rng := WGRandom.at(source.seed_num, "settlement.huts", x, y)
		var town := importance >= 0.8 # постоянный порог вместо ранга по ещё неизвестному миру
		chosen[cell] = SettlementData.from_dict({x = x - origin.x + 0.5, y = y - origin.y + 0.5, i = i,
			spacing = c[4], importance = importance, town = town,
			homes = (8 if town else 4) + roundi(importance * 3.0) + floori(rng.next_float() * 3),
			style = floori(rng.next_float() * 4), character = StageLandmarks._character(w, i, town),
			name = source.make_name(Names.SETTLEMENT, "settlement", x, y), huts = []})
	for cell: Vector2i in cells:
		if chosen.has(cell): w.settlements.append(chosen[cell])
	# Тот же подбор домов, проверки девяти точек фундамента и хозяйственные постройки.
	# Пока нет дорог, используется существующее кольцо вокруг площади.
	profile.select_ms = (Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	StageLandmarks.lay_out(w)
	profile.layout_ms = (Time.get_ticks_usec() - started) / 1000.0
	profile.places = w.settlements.size()
	profile.homes = StageLandmarks.count_homes(w.settlements)
	var out: Array = []
	for settlement: SettlementData in w.settlements:
		if settlement.huts.is_empty(): continue
		var s: SettlementData = settlement.duplicate(true)
		s.x += origin.x
		s.y += origin.y
		s.i = -1 # локальный индекс не является адресом в стартовом плане
		s.id = WorldData.place_id("settlement", s.x, s.y)
		s.region = source.region_at(Vector2i(floori(s.x), floori(s.y)))
		for hut: HutData in s.huts:
			hut.x += origin.x
			hut.y += origin.y
		out.append(s)
	profile.kept = out.size()
	return {ready = true, reason = "", settlements = out, profile = profile, geography = geography_of(w, region)}


## Окно поиска мирового квадрата cell.
static func window(cell: Vector2i) -> Rect2i:
	var center := cell * CELL + Vector2i.ONE * (CELL / 2)
	return Rect2i(center - Vector2i.ONE * SEARCH, Vector2i.ONE * (SEARCH * 2 + 1))


## Ранг квадрата зависит только от сида и адреса: порядок загрузки и состав группы его не меняют.
static func outranks(seed_num: int, a: Vector2i, b: Vector2i) -> bool:
	var seed := WGRandom.derive(seed_num, "settlement.cell")
	var pa := WGRandom.hash2(a.x, a.y, seed)
	var pb := WGRandom.hash2(b.x, b.y, seed)
	if pa != pb: return pa > pb
	return a.y < b.y or a.y == b.y and a.x < b.x


## Может ли в квадрате вообще появиться поселение: его окно целиком внутри своей области (как в prepare).
static func can_settle(cell: Vector2i) -> bool:
	var search := window(cell)
	var key := Vector2i(floori(float(search.get_center().x) / WorldData.REGION_SIZE), floori(float(search.get_center().y) / WorldData.REGION_SIZE))
	return Rect2i(key * WorldData.REGION_SIZE, Vector2i.ONE * WorldData.REGION_SIZE).grow(-MARGIN).encloses(search)


## Наибольший spacing, который может получить место в окне квадрата: по наименьшей плотности его проб.
static func widest(seed_num: int, cell: Vector2i) -> float:
	var search := window(cell)
	var seed := WGRandom.derive(seed_num, "settlement.density")
	var lowest := 1.0
	for y in range(search.position.y, search.end.y, 2):
		for x in range(search.position.x, search.end.x, 2):
			lowest = minf(lowest, StageLandmarks.patches(x, y, 96.0, seed))
	return 96.0 * lerpf(1.35, 0.7, lowest)


## Расстояние от центра клетки p до ближайшего центра проб окна.
static func distance_to_window(p: Vector2, search: Rect2i) -> float:
	var low := Vector2(search.position) + Vector2.ONE * 0.5
	var high := Vector2(search.end) - Vector2.ONE * 0.5
	return p.distance_to(p.clamp(low, high))


## Те же пятна плотности, что у стартового плана (StageLandmarks.patches верна и к западу/северу от нуля).
static func density_at(seed_num: int, x: int, y: int) -> float:
	return StageLandmarks.patches(x, y, 96.0, WGRandom.derive(seed_num, "settlement.density"))


## Производные поля того же домена (sample_rect) из той же согласованной воды. Владелец — пакет
## подготовки (finish_neighbors): поля не меняются, дороги той же области берут их вместо пересчёта.
static func geography_of(w: WorldData, region: Dictionary) -> Dictionary:
	return {rect = region.sample_rect, dist_water = w.dist_water, elev = w.elev, slope = w.slope, biome = w.biome}


## Адаптер к существующим правилам домов: координаты в нём локальные, география — готовая.
## geography — результат geography_of для ТОГО ЖЕ прямоугольника, полей и поверхности; иначе пересчёт.
static func local_world(source: WorldData, region: Dictionary, surface: Dictionary, geography := {}) -> WorldData:
	var w := WorldData.new()
	w.W = region.sample_rect.size.x
	w.H = region.sample_rect.size.y
	w.N = w.W * w.H
	w.seed_num = WGRandom.derive(source.seed_num, "region.layout.%d.%d" % [region.rect.position.x, region.rect.position.y])
	w.h = surface.h.duplicate()
	w.filled = w.h.duplicate()
	w.ocean = region.fields.ocean.duplicate()
	w.lake = region.fields.lake.duplicate()
	w.river = surface.river.duplicate()
	for i in w.N:
		w.river[i] = maxi(w.river[i], region.fields.river[i])
		if w.lake[i] != 0: w.filled[i] = region.fields.water_level[i]
		if surface.river[i] != 0: w.filled[i] = surface.water_level[i]
	w.dist_ocean = region.fields.dist.duplicate()
	w.path_mask.resize(w.N)
	if geography.get("rect") == region.sample_rect:
		# Массивы общие (копия при записи): изменения дорог не трогают поля пакета.
		w.dist_water = geography.dist_water
		w.elev = geography.elev
		w.slope = geography.slope
		w.biome = geography.biome
		return w
	w.biome = region.fields.biome.duplicate()
	StageGeography.run(w) # новые уклоны и расстояния до воды после земляных работ
	for i in w.N:
		# Готовые клетки ореола сохраняют биом стартового плана.
		if w.ocean[i] == 0 and w.lake[i] == 0 and region.fields.fixed[i] == 0:
			w.biome[i] = StageClimate.land_biome(w.elev[i], region.fields.temp[i], region.fields.moist[i], w.slope[i], w.dist_ocean[i])
	return w
