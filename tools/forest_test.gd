extends SceneTree
## Структура леса, расстояния с учётом размера и стыки с другими системами.

var fails := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		printerr(label)
		fails += 1


func fixture() -> WorldData:
	var w := WorldData.new()
	w.W = 96
	w.H = 96
	w.N = w.W * w.H
	w.rng = WGRandom.new(630)
	w.seed_num = 630
	w.noise.forest = Simplex.new(w.rng)
	w.noise.cost = Simplex.new(w.rng)
	for key in ["h", "elev", "temp", "moist", "slope", "dist_water"]:
		var a := PackedFloat32Array()
		a.resize(w.N)
		a.fill(0.08 if key == "h" or key == "elev" else (0.6 if key == "temp" or key == "moist" else (8.0 if key == "dist_water" else 0.0)))
		w.set(key, a)
	for key in ["biome", "ocean", "lake", "river", "path_mask"]:
		var a := PackedByteArray()
		a.resize(w.N)
		if key == "biome":
			a.fill(Biomes.FOREST)
		w.set(key, a)
	for y in w.H:
		w.path_mask[y * w.W + 40] = 3
		w.path_mask[y * w.W + 70] = 1
		w.river[y * w.W + 55] = 1
	w.settlements = [{x = 18.0, y = 18.0, huts = [{x = 18.0, y = 18.0}]}]
	return w


func _init() -> void:
	Grid.allow_fast = false
	var w := fixture()
	var frozen := var_to_bytes(EntityCodec.encode([w.h, w.elev, w.temp, w.moist, w.biome, w.river, w.path_mask, w.settlements]))
	var rng_before := w.rng._a
	StageVegetation.run(w)
	check(w.rng._a == rng_before, "Лес не должен расходовать rng других этапов")
	check(StageVegetation.canopy_at(w, 40.5, 48.5) < 0.3, "Просвет над дорогой не должен оставаться под сплошным пологом")
	check(frozen == var_to_bytes(EntityCodec.encode([w.h, w.elev, w.temp, w.moist, w.biome, w.river, w.path_mask, w.settlements])), "Лес не должен менять географию, климат, пути и поселения")
	var young := 0
	var old := 0
	var occupied := {}
	var species := {}
	var spacing_bad := 0
	var path_bad := 0
	var hut_bad := 0
	var chunk_count := 0
	for chunk in w.chunks:
		chunk_count += chunk.size()
	for o in w.obj_count:
		var p := Vector2(w.obj_x[o], w.obj_y[o])
		var r: float = Biomes.CROWN_RADIUS[w.obj_k[o]] * w.obj_s[o]
		occupied[Vector2i(p / 8.0)] = true
		species[w.obj_k[o]] = true
		if Biomes.is_tree(w.obj_k[o]):
			young += int(w.obj_s[o] < 0.7)
			old += int(w.obj_s[o] > 1.25)
			check(StageVegetation.canopy_at(w, p.x, p.y) > 0.99, "Полог должен учитывать фактическое дерево")
		if StageVegetation.near_hut(w.settlements, p.x, p.y, r):
			hut_bad += 1
		if w.river[floori(p.y) * w.W + floori(p.x)] != 0:
			path_bad += 1
		for path_x in [40.0, 70.0]:
			var d := maxf(maxf(path_x - p.x, p.x - path_x - 1.0), 0.0)
			if d < r + 0.25:
				path_bad += 1
		# С 8.4 отступы держатся внутри чанка (чанки раскладываются независимо), соседей через границу не сравниваем
		for other in w.chunks[floori(p.y / w.CS) * w.CW + floori(p.x / w.CS)]:
			if other >= o:
				continue
			var gap: float = 0.18 + 0.55 * (r + Biomes.CROWN_RADIUS[w.obj_k[other]] * w.obj_s[other])
			if p.distance_to(Vector2(w.obj_x[other], w.obj_y[other])) < gap - 0.00001:
				spacing_bad += 1
	check(young > 20 and old > 20, "Нужны молодняк и крупные старые деревья")
	check(species.size() >= 3 and occupied.size() > 50, "Нужны смешанные лесные массивы")
	check(spacing_bad == 0 and path_bad == 0 and hut_bad == 0, "Кроны и соседи должны учитывать размеры, пути, воду и дома")
	check(chunk_count == w.obj_count, "Каждый объект должен попасть в чанк")
	var repeat := fixture()
	StageVegetation.run(repeat)
	check(w.obj_x == repeat.obj_x and w.obj_y == repeat.obj_y and w.obj_k == repeat.obj_k and w.obj_s == repeat.obj_s and w.obj_v == repeat.obj_v and w.chunks == repeat.chunks, "Лес и чанки должны повторяться по сиду")
	print("Лес: %d ошибок; объектов %d, молодых %d, старых %d, видов %d" % [fails, w.obj_count, young, old, species.size()])
	quit(1 if fails else 0)
