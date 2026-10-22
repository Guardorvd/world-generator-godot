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
	# 8.2: характеры леса
	var bright := Understory.character(0.2, 0.0, 0.4, 0.9, 0.8)
	var gloomy := Understory.character(0.95, 0.9, 0.4, 0.3, 0.9)
	var thicket := Understory.character(0.6, 0.2, 0.5, 0.6, 0.02)
	var ferny := Understory.character(0.7, 0.0, 0.95, 0.3, 0.6)
	for pair: Array in [[bright, Understory.LIGHT, "светлый"], [gloomy, Understory.DARK, "тёмный"], [thicket, Understory.THICKET, "чаща"], [ferny, Understory.FERNY, "папоротниковый"]]:
		var ch: PackedFloat32Array = pair[0]
		var best := 0
		for c in 4:
			if ch[c] > ch[best]:
				best = c
		check(best == pair[1], "Характер леса должен определяться условиями: " + pair[2] + " " + str(ch))
	var w_bright := Understory.weights(Biomes.FOREST, 0.4, 0.8, 0.2, bright)
	var w_dark := Understory.weights(Biomes.FOREST, 0.4, 0.2, 0.95, gloomy)
	var w_thick := Understory.weights(Biomes.FOREST, 0.5, 0.4, 0.6, thicket)
	check(w_bright[Understory.FLOWERS] > w_dark[Understory.FLOWERS] and w_bright[Understory.HIGH_GRASS] > w_dark[Understory.HIGH_GRASS], "В светлом лесу должны быть цветы и высокая трава")
	check(w_dark[Understory.MOSS] / w_dark[Understory.GRASS] > w_bright[Understory.MOSS] / w_bright[Understory.GRASS], "В тёмном лесу мох должен вытеснять траву")
	check(w_thick[Understory.BUSH] > w_dark[Understory.BUSH] * 3.0 and w_thick[Understory.YOUNG] > 0.0, "В чаще должны преобладать кусты и подрост")
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
			var offset := n * VegetationLayer.STRIDE
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
