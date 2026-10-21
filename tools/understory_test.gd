extends SceneTree
## 6.6: состав подлеска, воспроизводимость и исключение воды/дорог/домов.

const Understory := preload("res://scripts/render/understory_models.gd")
const Fixture := preload("res://tools/vegetation_test.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var wet := Understory.weights(Biomes.FOREST, 0.9, 0.2, 0.8)
	var dry := Understory.weights(Biomes.FOREST, 0.15, 0.9, 0.1)
	check(wet[Understory.FERN] > dry[Understory.FERN] and wet[Understory.MOSS] > dry[Understory.MOSS] and wet[Understory.MUSHROOM] > dry[Understory.MUSHROOM], "Влажная тень должна поддерживать папоротники, мох и грибы")
	check(dry[Understory.GRASS] > wet[Understory.GRASS] and dry[Understory.BUSH] > wet[Understory.BUSH], "Просветы должны поддерживать траву и кусты")
	var taiga := Understory.weights(Biomes.TAIGA, 0.9, 0.2, 0.8)
	check(taiga[Understory.PINE] > wet[Understory.PINE] and taiga[Understory.SAPLING] < wet[Understory.SAPLING], "Молодняк должен соответствовать характеру леса")
	var w: WorldData = Fixture.fixture(1)
	w.seed_num = 660
	w.biome.fill(Biomes.FOREST)
	w.moist.fill(0.85)
	w.dist_water.fill(8.0)
	w.settlements = [{x = 128.0, y = 128.0, huts = [{x = 128.0, y = 128.0}]}]
	for y in w.H:
		w.path_mask[y * w.W + 126] = 3
		w.river[y * w.W + 130] = 1
	var h := Heightfield.new(w, false)
	for k in w.N:
		h.hv[k] += (k % w.W) * 0.1 # пологий склон для проверки прилегания мха
	var veg := VegetationLayer.new()
	root.add_child(veg)
	veg.setup(w, h, Models.tree_defs(), Models.grass_mesh())
	veg.update(512.0, 512.0, true)
	var saved: Array = []
	var counts: Array = []
	for kind in veg.understory.size():
		var entry: Dictionary = veg.understory[kind]
		if kind < 8 and kind != Understory.PINE:
			check(entry.count > 0, "Влажный лиственный лес должен содержать все основные ярусы")
		saved.append(entry.buf.duplicate())
		counts.append(entry.count)
		check(entry.mm.visible_instance_count == entry.count, "Буферы подлеска должны передаваться на отображение")
		for n: int in entry.count:
			var offset := n * 16
			var buf: PackedFloat32Array = entry.buf
			var x := buf[offset + 3]
			var z := buf[offset + 11]
			if kind == Understory.MOSS:
				check(absf(buf[offset + 4]) + absf(buf[offset + 6]) > 0.001, "Мох должен следовать уклону почвы")
			var k := floori(z / GameConfig.TILE) * w.W + floori(x / GameConfig.TILE)
			check(w.path_mask[k] == 0 and w.river[k] == 0, "Подлесок не должен попадать на дороги и реки")
			check(not StageVegetation.near_hut(w.settlements, x / GameConfig.TILE, z / GameConfig.TILE, 0.3), "Подлесок не должен попадать в дома")
			var xf := Transform3D(Basis(Vector3(buf[offset], buf[offset + 4], buf[offset + 8]), Vector3(buf[offset + 1], buf[offset + 5], buf[offset + 9]), Vector3(buf[offset + 2], buf[offset + 6], buf[offset + 10])), Vector3(x, buf[offset + 7], z))
			check(entry.mm.custom_aabb.grow(0.01).encloses(xf * entry.mm.mesh.get_aabb()), "AABB подлеска должен включать геометрию")
	veg.update(512.0, 512.0, true)
	for kind in veg.understory.size():
		check(saved[kind] == veg.understory[kind].buf and counts[kind] == veg.understory[kind].count, "Размещение должно повторяться при обновлении")
	w.biome.fill(Biomes.TAIGA)
	veg.update(512.0, 512.0, true)
	check(veg.understory[Understory.PINE].count > 0, "В тайге должен появляться хвойный молодняк")
	w.lake.fill(1)
	w.filled.fill(0.3)
	h.water_level.fill(0.3 * GameConfig.HS)
	veg.update(512.0, 512.0, true)
	for entry: Dictionary in veg.understory:
		check(entry.count == 0, "На затопленной почве подлесок не должен расти")
	veg.update(5000.0, 5000.0, true)
	for entry: Dictionary in veg.understory:
		check(entry.mm.visible_instance_count == 0, "При переносе старый подлесок должен исчезнуть")
	veg.queue_free()
	await process_frame
	print("understory_test: %d ошибок; по формам %s" % [fails, str(counts)])
	quit(1 if fails else 0)
