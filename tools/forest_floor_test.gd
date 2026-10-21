extends SceneTree
## 6.6+: фактическое сообщество, география, корни и след крупных деталей.

const Floor := preload("res://scripts/render/forest_floor.gd")
const Fixture := preload("res://tools/vegetation_test.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var dry := Floor.weights(0.8, 0.0, 0.1, 0.5, 0.2)
	var wet := Floor.weights(0.8, 1.0, 0.9, 0.2, 0.2)
	check(dry[Floor.LEAVES] > wet[Floor.LEAVES] and wet[Floor.NEEDLES] > dry[Floor.NEEDLES], "Листья и хвоя должны зависеть от деревьев")
	check(dry[Floor.LOG] > wet[Floor.LOG] and wet[Floor.MOSS_LOG] > dry[Floor.MOSS_LOG], "Влажность должна определять мох на валежнике")
	check(Floor.weights(0.8, 0.5, 0.5, 0.5, 0.8)[Floor.STONES] > dry[Floor.STONES], "Каменистость должна поддерживать россыпи")
	var w: WorldData = Fixture.fixture(1)
	w.seed_num = 667
	w.biome.fill(Biomes.FOREST)
	w.moist.fill(0.7)
	w.dist_water.fill(6.0)
	w.slope.fill(0.5)
	w.elev.fill(0.22)
	w.obj_s.fill(1.2)
	for o in w.obj_count:
		w.obj_k[o] = Biomes.T_OAK if o % 2 == 0 else Biomes.T_PINE
	for y in w.H:
		w.path_mask[y * w.W + 124] = 3
		w.river[y * w.W + 134] = 1
	w.settlements = [{x = 128.0, y = 128.0, huts = [{x = 128.0, y = 128.0}]}]
	var frozen := var_to_bytes([w.obj_x, w.obj_y, w.obj_k, w.obj_s, w.h, w.moist, w.path_mask])
	var surface := Floor.surface_image(w)
	check(surface.get_data() == Floor.surface_image(w).get_data(), "Маски почвы должны повторяться")
	var center := surface.get_pixel(127, 127)
	check(center.r > 0.0 and center.g > 0.0 and center.g < 1.0, "Маска должна видеть смешанный полог")
	check(absf(center.r - StageVegetation.canopy_at(w, 127.5, 127.5)) < 0.005, "Полог почвы должен совпадать с пологом готового леса")
	check(surface.get_pixel(134, 127).r == 0.0 and surface.get_pixel(10, 10).r == 0.0, "Вода и открытая местность не должны получать лесную почву")
	check(Floor.rockiness(w, 127 * w.W + 127) > 0.0, "География должна влиять на каменистость")
	var h := Heightfield.new(w, false)
	for k in w.N:
		h.hv[k] += (k % w.W) * 0.12
	var veg := VegetationLayer.new()
	root.add_child(veg)
	veg.setup(w, h, Models.tree_defs(), Models.grass_mesh(), surface)
	veg.update(512.0, 512.0, true)
	var counts: Array = []
	var saved: Array = []
	for kind in range(Floor.FIRST, veg.understory.size()):
		var entry: Dictionary = veg.understory[kind]
		counts.append(entry.count)
		saved.append(entry.buf.duplicate())
		check(entry.count > 0, "Смешанный лес должен содержать подстилку, корни, ветки, валежник, сухостой и камни: %d" % kind)
		for n: int in entry.count:
			var offset := n * 16
			var buf: PackedFloat32Array = entry.buf
			var pos := Vector3(buf[offset + 3], buf[offset + 7], buf[offset + 11])
			var xf := Transform3D(Basis(Vector3(buf[offset], buf[offset + 4], buf[offset + 8]), Vector3(buf[offset + 1], buf[offset + 5], buf[offset + 9]), Vector3(buf[offset + 2], buf[offset + 6], buf[offset + 10])), pos)
			check(entry.mm.custom_aabb.grow(0.01).encloses(xf * entry.mm.mesh.get_aabb()), "Границы должны включать детали на склоне")
			var bounds: AABB = xf * entry.box
			for point: Vector2 in [Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.end.x, bounds.position.z), Vector2(bounds.position.x, bounds.end.z), Vector2(bounds.end.x, bounds.end.z), Vector2(pos.x, pos.z)]:
				var k := floori(point.y / GameConfig.TILE) * w.W + floori(point.x / GameConfig.TILE)
				check(w.path_mask[k] == 0 and w.river[k] == 0, "Весь след детали должен обходить дорогу и реку")
				check(not StageVegetation.near_hut(w.settlements, point.x / GameConfig.TILE, point.y / GameConfig.TILE, 0.3), "Края детали не должны входить в дом")
			if kind == Floor.FIRST + Floor.ROOTS:
				var attached := false
				for o in w.obj_count:
					if absf(w.obj_x[o] * GameConfig.TILE - pos.x) < 0.001 and absf(w.obj_y[o] * GameConfig.TILE - pos.z) < 0.001:
						attached = true
						break
				check(attached, "Корни должны расти от настоящего ствола")
	veg.update(512.0, 512.0, true)
	for kind in range(Floor.FIRST, veg.understory.size()):
		check(saved[kind - Floor.FIRST] == veg.understory[kind].buf, "Детали должны повторяться при обновлении")
	var tree_x := w.obj_x[0] * GameConfig.TILE
	var tree_z := w.obj_y[0] * GameConfig.TILE
	check(not veg.placement.objects_clear(tree_x, tree_z, 0.0, 1.0, veg.understory[Floor.FIRST + Floor.LOG].box, 3.0), "Поваленное дерево не должно пересекать живой ствол")
	check(not veg.placement.ground_clear(124.0 * GameConfig.TILE - 1.0, 120.0 * GameConfig.TILE, 2.0), "Дорога у края бревна должна запрещать размещение")
	check(frozen == var_to_bytes([w.obj_x, w.obj_y, w.obj_k, w.obj_s, w.h, w.moist, w.path_mask]), "Оформление не должно менять мир")
	veg.queue_free()
	await process_frame
	print("forest_floor_test: %d ошибок; по формам %s" % [fails, str(counts)])
	quit(1 if fails else 0)
