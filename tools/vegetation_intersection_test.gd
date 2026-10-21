extends SceneTree
## Hotfix 6.6+: края растений, берег между клетками и пересечения деталей.

const Plants := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const Fixture := preload("res://tools/vegetation_test.gd")
var fails := 0


class Ridge extends Heightfield:
	func ground_at(x: float, z: float, raw := false) -> float:
		return super.ground_at(x, z, raw) + maxf(0.0, x - 500.5) * 2.0


func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var w: WorldData = Fixture.fixture(1)
	w.biome.fill(Biomes.FOREST)
	w.obj_x = PackedFloat64Array([128.5])
	w.obj_y = PackedFloat64Array([128.5])
	w.obj_k = PackedInt32Array([Biomes.T_PINE])
	w.obj_v = PackedInt32Array([0])
	w.obj_s = PackedFloat64Array([1.0])
	w.obj_count = 1
	for c in w.chunks.size():
		w.chunks[c] = PackedInt32Array()
	w.chunks[(128 / w.CS) * w.CW + 128 / w.CS] = PackedInt32Array([0])
	var h := Heightfield.new(w, false)
	var veg := VegetationLayer.new()
	root.add_child(veg)
	veg.setup(w, h, Models.tree_defs(), Models.grass_mesh())
	# Центр на сухой свободной земле, но край папоротника заходит на дорогу.
	w.path_mask[127 * w.W + 130] = 3
	veg._put_understory(Plants.FERN, 519.9, 510.0, 0.0, 1.0)
	check(veg.understory[Plants.FERN].count == 0, "Край папоротника не должен заходить на дорогу")
	# Вода озера покрывает часть соседней клетки без её собственного water_level.
	w.lake[127 * w.W + 130] = 1
	w.filled[127 * w.W + 130] = 0.3
	check(h.water_level[127 * w.W + 129] == -INF and h.depth_at(519.0, 510.0) > 0.0, "Тест должен воспроизводить затопленный край соседней клетки")
	veg._put_understory(Plants.MOSS, 519.0, 510.0, 0.0, 0.7)
	check(veg.understory[Plants.MOSS].count == 0, "На затопленном краю берега не должен появляться мох")
	var tree_chunk := (128 / w.CS) * w.CW + 128 / w.CS
	w.obj_x[0] = 129.75
	w.obj_y[0] = 127.5
	check(veg._build_chunk(tree_chunk).entries.is_empty(), "Дерево на затопленном краю берега не должно попадать в буферы")
	w.obj_x[0] = 128.5
	w.obj_y[0] = 128.5
	veg._fill_grass(516.0, 510.0)
	for n in veg._grass_n:
		check(h.depth_at(veg.grass_buf[n * 16 + 3], veg.grass_buf[n * 16 + 11]) == 0.0, "Трава не должна появляться на затопленном краю берега")
	w.lake.fill(0)
	veg.placement.clear_occupied()
	# Молодняк не должен расти прямо из живого ствола или валуна.
	veg._put_understory(Plants.SAPLING, 514.0, 514.0, 0.0, 1.0)
	check(veg.understory[Plants.SAPLING].count == 0, "Молодняк не должен пересекать живой ствол")
	w.obj_k[0] = Biomes.T_ROCK
	veg.placement.prepare(514.0, 514.0, 16.0) # мир изменён после заполнения
	veg._put_understory(Plants.PINE, 514.0, 514.0, 0.0, 1.0)
	check(veg.understory[Plants.PINE].count == 0, "Молодняк не должен расти из валуна")
	var log_kind := Floor.FIRST + Floor.LOG
	veg._put_understory(log_kind, 514.0, 514.0, 0.0, 1.0)
	check(veg.understory[log_kind].count == 0, "Валежник не должен проходить сквозь валун")
	w.obj_k[0] = Biomes.T_BUSH
	veg.placement.prepare(514.0, 514.0, 16.0)
	veg._put_understory(Plants.PINE, 514.0, 514.0, 0.0, 1.0)
	check(veg.understory[Plants.PINE].count == 0, "Молодняк не должен пересекать существующий куст")
	veg._put_understory(log_kind, 490.0, 490.0, 0.0, 1.0)
	var logs: int = veg.understory[log_kind].count
	check(logs == 1, "В свободном месте должно помещаться бревно")
	veg._put_understory(log_kind, 490.0, 490.0, PI / 2.0, 1.0)
	check(veg.understory[log_kind].count == logs, "Два поваленных дерева не должны проходить друг сквозь друга")
	var ferns: int = veg.understory[Plants.FERN].count
	veg._put_understory(Plants.FERN, 490.0, 490.0, 0.0, 1.0)
	check(veg.understory[Plants.FERN].count == ferns, "Папоротник не должен прорастать сквозь бревно")
	# Трава тоже должна учитывать крупные детали, даже если её заполнили раньше.
	veg._grass_n = 3
	VegetationLayer._put_xform(veg.grass_buf, 0, 490.0, h.ground_at(490.0, 490.0), 490.0, 0.0, 1.0, 1.0)
	VegetationLayer._put_xform(veg.grass_buf, 16, 480.0, h.ground_at(480.0, 480.0), 480.0, 0.0, 1.0, 1.0)
	VegetationLayer._put_xform(veg.grass_buf, 32, 514.0, h.ground_at(514.0, 514.0), 514.0, 0.0, 1.0, 1.0)
	veg._filter_grass()
	check(veg._grass_n == 1 and veg.grass_buf[3] == 480.0, "Трава внутри бревна и существующего куста должна удаляться с сохранением свободной травы")
	var ridge := Ridge.new(w, false)
	veg.heights = ridge
	veg.placement.heights = ridge
	veg._put_understory(log_kind, 500.0, 490.0, 0.0, 1.0)
	check(veg.understory[log_kind].count == logs, "На переломе склона бревно не должно проваливаться в землю")
	veg.queue_free()
	await process_frame
	print("vegetation_intersection_test: %d ошибок" % fails)
	quit(1 if fails else 0)
