extends SceneTree
## Независимость случайности, готовые долины/водосборы и общие речные рёбра соседних областей.
## -- --gdscript проверяет ту же природную географию без C#.
const SelfTest := preload("res://tools/selftest.gd")
var fails := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		fails += 1
		printerr(message)


func noise_compatibility() -> void:
	for seed_text in ["Север-1234", "Туман-4821", "abc", "Ущелье"]:
		var seed_num := WGRandom.hash_string(seed_text)
		var legacy := WGRandom.new(seed_num)
		var expected := {}
		for name: String in WorldGenerator.NOISE_SLOTS:
			expected[name] = Simplex.new(legacy).perm
		var names := WorldGenerator.NOISE_SLOTS.keys()
		names.reverse()
		for name: String in names:
			var unrelated := Simplex.new(WorldGenerator.noise_rng(seed_num, "additional_noise"))
			check(unrelated.perm.size() == 512, "Новый шум не создан")
			check(Simplex.new(WorldGenerator.noise_rng(seed_num, name)).perm == expected[name],
				"Перестановка %s/%s изменилась от создания нового шума или порядка" % [seed_text, name])


static func geo_fingerprint(w: WorldData) -> Dictionary:
	var fp := {}
	for name in ["h", "filled", "elev", "acc", "slope", "temp", "moist", "dist_ocean", "dist_water"]:
		fp[name] = SelfTest.fnv(w.get(name).to_byte_array())
	for name in ["ocean", "lake", "river", "biome", "river_area"]:
		fp[name] = SelfTest.fnv(w.get(name))
	fp.river_geometry = SelfTest.fnv(var_to_bytes(w.rivers))
	fp.river_exits = SelfTest.fnv(var_to_bytes(w.river_exits))
	return fp


func overlap(a: Dictionary, b: Dictionary) -> void:
	var shared: Rect2i = a.rect.intersection(b.rect)
	for name: String in WorldRegion.FIELDS:
		var mismatches := 0
		for y in range(shared.position.y, shared.end.y):
			for x in range(shared.position.x, shared.end.x):
				var ai: int = (y - a.rect.position.y) * a.stride + x - a.rect.position.x
				var bi: int = (y - b.rect.position.y) * b.stride + x - b.rect.position.x
				if a[name][ai] != b[name][bi]:
					mismatches += 1
		check(mismatches == 0, "На границе областей расходится поле " + name)


func synthetic_routes() -> void:
	var w := WorldData.new()
	w.W = 48
	w.H = 48
	w.N = w.W * w.H
	w.seed_num = 426
	w.rng = WGRandom.new(42)
	for name in ["ocean", "lake", "river", "path_mask", "biome"]:
		var f := PackedByteArray()
		f.resize(w.N)
		if name == "biome": f.fill(Biomes.GRASS)
		w.set(name, f)
	for name in ["h", "cost", "dist_water", "slope"]:
		var f := PackedFloat32Array()
		f.resize(w.N)
		f.fill(100.0 if name == "dist_water" else (0.0 if name == "slope" else 1.0))
		w.set(name, f)
	var paths: Array[PackedInt32Array] = []
	for y in [8, 18]:
		var path := PackedInt32Array()
		for x in range(3, 43): path.append(y * w.W + x)
		paths.append(path)
	StageTrails._add_trail(w, paths[0], "animal")
	var first: Array = w.trails[-1].pts.duplicate(true)
	for i in 500: w.rng.next_float()
	StageTrails._add_trail(w, paths[1], "animal")
	StageTrails._add_trail(w, paths[0], "animal")
	check(w.trails[-1].pts == first, "Отдельная тропа зависит от соседней или общего RNG")
	w.trails = []
	for path in paths: StageTrails._add_trail(w, path, "road")
	var crossing := PackedInt32Array()
	for y in range(3, 43): crossing.append(y * w.W + 18)
	StageTrails._add_trail(w, crossing, "road")
	RoadSurface.run(w)
	var surface := w.road_surface.duplicate()
	var original := w.trails.duplicate(true)
	w.trails.reverse()
	RoadSurface.run(w)
	check(w.road_surface == surface, "Покрытие на пересечении зависит от порядка дорог")
	for i in original.size():
		check(original[i].surf == w.trails[original.size() - i - 1].surf, "Покрытие линии зависит от номера в списке")


func _init() -> void:
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	noise_compatibility()
	synthetic_routes()
	var started := Time.get_ticks_msec()
	var w := WorldGenerator.geography("Север-1234")
	if OS.get_cmdline_user_args().has("--links-only"):
		var edges := {}
		for y in 3:
			for x in 3:
				for edge: Dictionary in w.read_region(Vector2i(x, y)).links:
					var source: int = edge.from.y * w.W + edge.from.x
					check(w.river[source] != 0 or w.lake[source] != 0, "Сухой подход к истоку выдан как река")
					check(edge.width > 0.0 and edge.next_width > 0.0 and edge.e + 1e-6 >= edge.next_e, "Недопустимый профиль перехода")
					if edges.has(edge.id):
						check(edges[edge.id].data == edge, "Соседи не согласны о речном переходе")
						edges[edge.id].count += 1
					else:
						edges[edge.id] = {data = edge, count = 1}
		for id: Vector4i in edges:
			check(edges[id].count == 2, "Река не продолжена в соседнюю область")
		check(not edges.is_empty(), "Не проверено ни одного перехода")
		print("region_links_test: %s; речных переходов %d" % ["OK" if fails == 0 else "ошибок %d" % fails, edges.size()])
		quit(1 if fails > 0 else 0)
		return
	var before := geo_fingerprint(w)
	var reference: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/selftest_reference.json"))["Север-1234@256"]
	for name: String in before:
		check(int(reference[name]) == before[name], "Природная география 8.5 непреднамеренно изменилась: " + name)
	var bad_basins := 0
	for i in w.N:
		var root := w.watershed[i]
		if root < 0 or root >= w.N or w.down[root] >= 0 or (w.down[i] >= 0 and root != w.watershed[w.down[i]]):
			bad_basins += 1
	check(bad_basins == 0, "Водосборы разорваны: %d клеток" % bad_basins)
	var snapshots := {}
	var links := {}
	for y in 3:
		for x in 3:
			var key := Vector2i(x, y)
			var region := w.read_region(key)
			snapshots[key] = SelfTest.fnv(var_to_bytes(region))
			for link: Dictionary in region.links:
				if links.has(link.id):
					check(links[link.id].data == link, "Области не согласны о ширине, высоте или стоке реки")
					links[link.id].count += 1
				else:
					links[link.id] = {data = link, count = 1}
				check(link.acc <= link.receiving_acc + 0.001 and link.e + 1e-6 >= link.next_e,
					"Переход реки через границу теряет сток или поднимает воду")
	check(not links.is_empty(), "Не проверено ни одного пересечения реки с границей области")
	for id: Vector4i in links:
		check(links[id].count == 2, "Речное ребро не возвращено обоим соседям")
	for y in range(2, -1, -1):
		for x in range(2, -1, -1):
			var key := Vector2i(x, y)
			check(SelfTest.fnv(var_to_bytes(w.read_region(key))) == snapshots[key], "География зависит от порядка чтения областей")
	for y in 3:
		for x in 3:
			var a := w.read_region(Vector2i(x, y))
			if x < 2: overlap(a, w.read_region(Vector2i(x + 1, y)))
			if y < 2: overlap(a, w.read_region(Vector2i(x, y + 1)))
	var region := w.read_region(Vector2i(1, 1))
	var rect: Rect2i = region.rect
	var terrain := OuterLand.compute(w, rect.position.x, rect.position.y, rect.size.x, rect.size.y)
	check(terrain.h == region.h and terrain.dw == region.dist_water and terrain.river == region.river_area,
		"Семплер области потерял готовые долины, русла или близость воды")
	region.h[0] = 99.0
	if not region.rivers.is_empty(): region.rivers[0][0].x = 999999.0
	check(geo_fingerprint(w) == before, "Читатель области изменил общую географию")
	StageLandmarks.run(w)
	var places := w.settlements.duplicate(true)
	var peaks := w.peaks.duplicate(true)
	for i in 3000: w.rng.next_float()
	for i in 100: w.make_name(Names.PEAK, "unrelated", i, -i)
	StageLandmarks.run(w)
	check(w.settlements == places and w.peaks == peaks, "Имена или общий RNG сдвинули поселения/дома/вершины")
	check(geo_fingerprint(w) == before, "Объекты или порядок чтения перестроили природную географию")
	w.clear_noise_fields()
	print("region_geography_test: %s; речных переходов %d; %d мс" % ["OK" if fails == 0 else "ошибок %d" % fails,
		links.size(), Time.get_ticks_msec() - started])
	quit(1 if fails > 0 else 0)
