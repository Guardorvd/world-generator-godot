extends RefCounted
## Поселения после согласованной воды. Исходный WorldData не меняется.
## Один лучший участок в мировом квадрате поиска; расстояния гарантированы даже без загрузки соседа.
## 14.4: квадрат 128 клеток (было 160) делит область (256) ровно на четыре, а окно поиска ±24 (было ±12)
## всегда целиком внутри неё: раньше в область попадал один-два центра, и у большинства областей
## не было ни поселений, ни дорог между ними. Плотность теперь близка к стартовому плану.
const CELL := 128
const SEARCH := 24
const MARGIN := 8 # весь дом и хозяйственный пояс остаются в своей области


static func prepare(source: WorldData, region: Dictionary, surface: Dictionary) -> Dictionary:
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
	for gy in range(floori(float(rect.position.y) / CELL), ceili(float(rect.end.y) / CELL)):
		for gx in range(floori(float(rect.position.x) / CELL), ceili(float(rect.end.x) / CELL)):
			var center := Vector2i(gx * CELL + CELL / 2, gy * CELL + CELL / 2)
			var search := Rect2i(center - Vector2i.ONE * SEARCH, Vector2i.ONE * (SEARCH * 2 + 1))
			# Не выбирать из усечённого окна: это давало бы другой центр у границы.
			if not inside.encloses(search): continue
			var candidates: Array = []
			for y in range(search.position.y, search.end.y, 2):
				for x in range(search.position.x, search.end.x, 2):
					var i := (y - origin.y) * w.W + x - origin.x
					var bd: Dictionary = Biomes.LIST[w.biome[i]]
					if region.fields.fixed[i] != 0 or wet[i] != 0 or not bd.has("habit") or w.slope[i] > 0.6: continue
					var access := StageLandmarks._site_access(w, i, wet)
					if access < 0.35: continue
					var density := density_at(source.seed_num, x, y)
					var spacing := 96.0 * lerpf(1.35, 0.7, density)
					var close := false
					for old: SettlementData in source.settlements:
						if Vector2(x + 0.5, y + 0.5).distance_to(Vector2(old.x, old.y)) < (spacing + EntityCodec.value(old, "spacing", 129.6)) * 0.5:
							close = true
							break
					if close: continue
					var dw := w.dist_water[i]
					var score: float = bd.habit + WGRandom.hash2(x, y, seed) * 0.2 - w.slope[i] * 0.6
					score += access * 0.45 + density * 0.35
					if dw >= 1.5 and dw <= 6.0: score += 0.6
					elif dw > 16.0: score -= minf(0.6, (dw - 16.0) / 40.0)
					if dw < 1.5: score -= 0.4
					candidates.append([score, i, access, density, spacing])
			if candidates.is_empty(): continue
			candidates.sort_custom(StageLandmarks._by_score_desc)
			var c: Array = candidates[0]
			var i: int = c[1]
			var x: int = i % w.W + origin.x
			var y: int = i / w.W + origin.y
			var importance := clampf(float(w.biome[i] == Biomes.GRASS) * 0.15 + c[2] * 0.5 + c[3] * 0.3
				+ (0.12 if w.dist_water[i] < 6.0 else 0.0), 0.0, 1.0)
			var rng := WGRandom.at(source.seed_num, "settlement.huts", x, y)
			var town := importance >= 0.8 # постоянный порог вместо ранга по ещё неизвестному миру
			w.settlements.append(SettlementData.from_dict({x = x - origin.x + 0.5, y = y - origin.y + 0.5, i = i,
				spacing = c[4], importance = importance, town = town,
				homes = (8 if town else 4) + roundi(importance * 3.0) + floori(rng.next_float() * 3),
				style = floori(rng.next_float() * 4), character = StageLandmarks._character(w, i, town),
				name = source.make_name(Names.SETTLEMENT, "settlement", x, y), huts = []}))
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
	return {ready = true, reason = "", settlements = out, profile = profile}


## Те же пятна плотности, что у стартового плана (StageLandmarks.patches верна и к западу/северу от нуля).
static func density_at(seed_num: int, x: int, y: int) -> float:
	return StageLandmarks.patches(x, y, 96.0, WGRandom.derive(seed_num, "settlement.density"))


## Адаптер к существующим правилам домов: координаты в нём локальные, география — готовая.
static func local_world(source: WorldData, region: Dictionary, surface: Dictionary) -> WorldData:
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
	w.biome = region.fields.biome.duplicate()
	StageGeography.run(w) # новые уклоны и расстояния до воды после земляных работ
	for i in w.N:
		# Готовые клетки ореола сохраняют биом стартового плана.
		if w.ocean[i] == 0 and w.lake[i] == 0 and region.fields.fixed[i] == 0:
			w.biome[i] = StageClimate.land_biome(w.elev[i], region.fields.temp[i], region.fields.moist[i], w.slope[i], w.dist_ocean[i])
	return w
