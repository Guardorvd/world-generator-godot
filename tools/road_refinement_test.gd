extends SceneTree
## Проверяет поверхность 4.4: совпадение треугольников меша с опорой, стыки, локальность,
## воспроизводимость, защиту сооружений и езду по уточнённой дороге. Без окна.

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		if fails < 15:
			printerr(what)


## Загрузчик готовит базовый меш до путей; прямое построение получает уже готовый мир.
## Оба входа должны дать одинаковые высоты, сооружения и окончательный меш.
func _loading() -> void:
	var loaded := WorldLoader.load_world("abc", 128)
	# Внешнее продолжение появляется после подготовки дорог; сравниваем одинаковые входные данные.
	loaded.world.outer = null
	var direct := Heightfield.new(loaded.world)
	check(loaded.heights.hv == direct.hv, "загрузчик и Heightfield расходятся по базовому полотну")
	check(loaded.heights.structures == direct.structures, "загрузчик и Heightfield расходятся по сооружениям")
	check(loaded.heights.road_refinement.patches == direct.road_refinement.patches,
		"загрузчик и Heightfield расходятся по метровой поверхности")
	var rebuilt := TerrainBuilder.build_arrays(loaded.world, direct)
	check(loaded.terrain_arrays == rebuilt, "загрузчик и прямая сборка дают разные меши")


func _init() -> void:
	_ride()
	if OS.get_cmdline_user_args().has("--ride-only"):
		quit(1 if fails else 0)
		return
	_loading()
	for seed_text: String in ["Север-1234", "Туман-4821", "Ущелье"]:
		var w := WorldGenerator.generate(seed_text, 256)
		var h := Heightfield.new(w)
		var r := h.road_refinement
		var t0 := Time.get_ticks_msec()
		var arrays := TerrainBuilder.build_arrays(w, h)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var error := 0.0
		# Проверяется весь меш, в том числе исходная сетка и места стыков.
		for n in range(0, indices.size(), 3):
			var a := vertices[indices[n]]
			var b := vertices[indices[n + 1]]
			var c := vertices[indices[n + 2]]
			var p := a * 0.23 + b * 0.31 + c * 0.46
			error = maxf(error, absf(h.ground_at(p.x, p.z) - p.y))
		check(error < 0.001, "%s: опора расходится с мешем: %f м" % [seed_text, error])
		var boundary := 0.0
		var joins := 0.0
		var biggest := 0.0
		var protected_error := 0.0
		for key: int in r.patches:
			var cx := key % w.W
			var cz := key / w.W
			var patch: Dictionary = r.patches[key]
			for z in RoadRefinement.STRIDE:
				for x in RoadRefinement.STRIDE:
					var px := (cx + 0.5) * GameConfig.TILE + x * RoadRefinement.STEP
					var pz := (cz + 0.5) * GameConfig.TILE + z * RoadRefinement.STEP
					var value: float = patch.h[z * RoadRefinement.STRIDE + x]
					var diff := absf(value - h.base_ground_at(px, pz))
					var cell := floori(pz / GameConfig.TILE) * w.W + floori(px / GameConfig.TILE)
					if h.water_level[cell] != -INF:
						check(diff < 0.001, "изменена вода")
					elif value < h.base_ground_at(px, pz):
						check(value >= minf(h.base_ground_at(px, pz), RoadBed._wet_near(h, cell) + RoadBed.WATER_GAP) - 0.001, "срез сухого берега затопил полотно")
					biggest = maxf(biggest, diff)
					var on_boundary := (x == 0 and not r.patches.has(key - 1)) or (x == RoadRefinement.DIV and not r.patches.has(key + 1)) or (z == 0 and not r.patches.has(key - w.W)) or (z == RoadRefinement.DIV and not r.patches.has(key + w.W))
					if on_boundary:
						boundary = maxf(boundary, diff)
					if x == RoadRefinement.DIV and r.patches.has(key + 1):
						joins = maxf(joins, absf(value - r.patches[key + 1].h[z * RoadRefinement.STRIDE]))
					if z == RoadRefinement.DIV and r.patches.has(key + w.W):
						joins = maxf(joins, absf(value - r.patches[key + w.W].h[x]))
					for s: Dictionary in h.structures:
						if Grid.segment_dist(px, pz, s.ax, s.az, s.bx, s.bz) < RoadBed.PIN:
							protected_error = maxf(protected_error, diff)
		check(boundary < 0.001 and joins < 0.001, "%s: разрыв сетки: %f / %f" % [seed_text, boundary, joins])
		check(biggest <= RoadRefinement.BENCH_LIMIT + 0.001, "%s: превышен предел уточнения: %f" % [seed_text, biggest])
		check(protected_error < 0.001, "%s: сдвинут подход сооружения" % seed_text)
		check(r.patches.size() < w.N * 0.25, "%s: уточнение захватывает слишком много мира" % seed_text)
		# Оба способа загрузки должны давать одну и ту же поверхность.
		var loaded := WorldLoader.load_world(seed_text, 256)
		check(loaded.heights.road_refinement.patches.size() == r.patches.size(), "разные наборы патчей")
		for key: int in r.patches:
			check(r.patches[key].h == loaded.heights.road_refinement.patches[key].h, "невоспроизводимые высоты")
		print("%s: %.1f %% квадратов, +%d вершин, меш/опора %.6f м, стык %.6f м; проверка %d мс" % [seed_text,
			100.0 * r.patches.size() / w.N, vertices.size() - w.N, error, maxf(boundary, joins), Time.get_ticks_msec() - t0])
	print("Road Refinement 4.4: нарушений %d" % fails)
	quit(1 if fails else 0)


func _ride() -> void:
	# Контрольная грунтовка на ровном лугу: новое полотно должно физически ощущаться,
	# но мелкая неровность не должна отправлять велосипед в полёт без прыжка.
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = w.W * w.H
	w.seed_num = 44
	for name: String in ["h", "filled", "elev", "slope", "temp", "moist", "dist_water"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		values.fill(20.0 if name == "dist_water" else (0.1 if name == "h" else 0.0))
		w.set(name, values)
	for name: String in ["ocean", "lake", "river", "biome", "path_mask", "road_surface"]:
		var values := PackedByteArray()
		values.resize(w.N)
		values.fill(Biomes.GRASS if name == "biome" else 0)
		w.set(name, values)
	var points: Array = []
	var surfaces := PackedByteArray()
	for x in range(8, 57):
		points.append({x = float(x), y = 32.5, w = 0.9})
		surfaces.append(RoadSurface.DIRT)
	w.trails = [{kind = "road", pts = points, surf = surfaces}]
	var h := Heightfield.new(w)
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.x = 50.0
	b.z = 130.0
	b.y = h.ground_at(b.x, b.z)
	b.heading = -PI * 0.5
	b.mount(p)
	var low := b.y
	var high := b.y
	var air_ticks := 0
	for k in 300:
		b.step(p, 1.0, 0.0, true, false, 1.0 / 60.0, w, h)
		low = minf(low, b.y)
		high = maxf(high, b.y)
		air_ticks += 1 if b.airborne else 0
		check(is_finite(b.y) and absf(b.y - b._contact(b.x, b.z, h)) < 0.002, "база колёс расходится с грунтом")
	check(high - low > 0.005 and high - low < 0.15, "грунтовка не даёт разумной локальной неровности")
	check(air_ticks == 0 and b.x > 85.0, "мелкий грунт мешает езде или вызывает ложные взлёты")
	print("Контрольная грунтовка: неровность %.1f см, ложных взлётов %d, путь %.1f м" % [(high - low) * 100.0, air_ticks, b.x - 50.0])
