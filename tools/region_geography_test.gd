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
	preload("res://tools/watchdog.gd").arm(self, 180)
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	noise_compatibility()
	synthetic_routes()
	var started := Time.get_ticks_msec()
	var w := WorldGenerator.geography("Север-1234")
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
	# Области — адреса одного плана: русло через их границу — то же ребро стока, что внутри.
	# Проверяем целостность сети по всему плану и отдельно считаем переходы границ.
	var links := 0
	var bad_links := 0
	for i in w.N:
		var d := w.down[i]
		if d < 0 or w.river[i] == 0:
			continue
		if w.acc[i] > w.acc[d] + 0.001 or w.filled[i] + 1e-6 < w.filled[d]:
			bad_links += 1
		if w.region_at(Vector2i(i % w.W, i / w.W)) != w.region_at(Vector2i(d % w.W, d / w.W)):
			links += 1
	check(bad_links == 0, "Русло теряет сток или поднимает воду: %d рёбер" % bad_links)
	check(links > 0, "Не проверено ни одного пересечения реки с границей области")
	var rect := w.region_rect(Vector2i(1, 1)).grow(2)
	var terrain := OuterLand.compute(w, rect.position.x, rect.position.y, rect.size.x, rect.size.y)
	var lost := 0
	for y in rect.size.y:
		for x in rect.size.x:
			var k := y * rect.size.x + x
			var i := (y + rect.position.y) * w.W + x + rect.position.x
			if terrain.h[k] != w.h[i] or terrain.dw[k] != w.dist_water[i] or terrain.river[k] != w.river_area[i]:
				lost += 1
	check(lost == 0, "Семплер области потерял готовые долины, русла или близость воды")
	terrain.h[0] = 99.0
	check(geo_fingerprint(w) == before, "Семплер области изменил общую географию")
	StageLandmarks.run(w)
	var places := w.settlements.duplicate(true)
	var peaks := w.peaks.duplicate(true)
	check(w.rng == null, "Генератор снова создаёт общий RNG мира")
	for i in 100: w.make_name(Names.PEAK, "unrelated", i, -i)
	StageLandmarks.run(w)
	check(w.settlements == places and w.peaks == peaks, "Имена или общий RNG сдвинули поселения/дома/вершины")
	check(geo_fingerprint(w) == before, "Объекты или порядок чтения перестроили природную географию")
	w.clear_noise_fields()
	print("region_geography_test: %s; речных переходов %d; %d мс" % ["OK" if fails == 0 else "ошибок %d" % fails,
		links, Time.get_ticks_msec() - started])
	quit(1 if fails > 0 else 0)
