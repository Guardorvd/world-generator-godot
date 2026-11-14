extends SceneTree
## Интеграционный и геометрический тест парковых гирлянд:
## детерминированность, габарит над дорогой и настилами NORTHSHORE,
## обход построек/ворот/мостов/воды/чужих стволов и чистый lifecycle без утечек.

class ElevatedDeckHeightfield extends Heightfield:
	var deck_y := 2.4

	func _init(y: float) -> void:
		deck_y = y

	func _cell_list(_x: float, _z: float) -> Variant:
		return null

	func ground_at(_x: float, _z: float, _raw: bool = false) -> float:
		return 0.0

	func surface_at(_x: float, _z: float, _feet: float) -> float:
		return deck_y

	func depth_at(_x: float, _z: float, _feet: float = -INF) -> float:
		return 0.0


var _failed := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		_failed += 1
		push_error("FAIL: " + msg)
		print("FAIL: " + msg)


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	call_deferred("_run")


func _run() -> void:
	# 1. Детерминизм и реальный мир (256 клеток).
	var world := WorldGenerator.generate("garland-seed-alpha", 256)
	var heights := Heightfield.new(world)
	var home: Variant = PlayerState.home(world)
	var clear_spots: Array[Vector2] = []
	if home != null:
		clear_spots.append(Vector2(home.x * GameConfig.TILE, home.y * GameConfig.TILE))

	var ox_before := world.obj_x.duplicate()
	var clusters_a := TreeGarlandsLayout.find_base_clusters(world, heights, clear_spots)
	var clusters_b := TreeGarlandsLayout.find_base_clusters(world, heights, clear_spots)
	check(clusters_a.size() == clusters_b.size(), "Одинаковое число кластеров при повторном поиске")
	for i in clusters_a.size():
		check(clusters_a[i].id == clusters_b[i].id, "Совпадают ID кластеров")
		check(clusters_a[i].center.distance_to(clusters_b[i].center) < 1e-4, "Совпадают центры кластеров")
		for j in range(i + 1, clusters_a.size()):
			var ca: Vector2 = clusters_a[i].center
			var cb: Vector2 = clusters_a[j].center
			var sep := ca.distance_to(cb)
			check(sep >= TreeGarlandsLayout.MIN_CLUSTER_SPACING - 0.5, "Разнос кластеров >= %.1f м (got %.1f)" % [TreeGarlandsLayout.MIN_CLUSTER_SPACING, sep])

	# Подбираем сид с гарантированным числом кластеров (>= 1), если 256-карта выдала 0.
	if clusters_a.is_empty():
		for try_seed: String in ["selftest", "park-trail-12", "northern-road-9"]:
			var w2 := WorldGenerator.generate(try_seed, 256)
			var h2 := Heightfield.new(w2)
			var cs2: Array[Vector2] = []
			var hm2: Variant = PlayerState.home(w2)
			if hm2 != null:
				cs2.append(Vector2(hm2.x * GameConfig.TILE, hm2.y * GameConfig.TILE))
			var f2 := TreeGarlandsLayout.find_base_clusters(w2, h2, cs2)
			if not f2.is_empty():
				world = w2
				heights = h2
				clear_spots = cs2
				clusters_a = f2
				ox_before = world.obj_x.duplicate()
				break
	check(clusters_a.size() >= 1, "В тестовых мирах найден хотя бы 1 базовый кластер гирлянд")

	# 2. Геометрическая проверка кластеров и их буферов на реальном мире.
	var huts: Array[Vector3] = []
	for s: SettlementData in world.settlements:
		huts.append(Vector3(s.x * GameConfig.TILE, s.y * GameConfig.TILE, 30.0))
	var gates := TreeGarlandsLayout._gate_positions(heights)
	var snap := {
		world = world,
		heights = preload("res://scripts/game/navigation_snapshot.gd").capture(heights, false),
		outer_veg = {},
		huts = huts,
		gates = gates,
	}
	var built_any := false
	for desc: Dictionary in clusters_a:
		for cs: Vector2 in clear_spots:
			check(desc.center.distance_to(cs) >= TreeGarlandsLayout.CLEAR_START_R - 0.5, "Кластер не накрывает точку старта")
		var res := TreeGarlandsLayout.build_cluster(desc, snap)
		if not res.get("valid", false):
			continue
		built_any = true
		check(res.bulb_count >= TreeGarlandsLayout.MIN_BULBS and res.bulb_count <= TreeGarlandsLayout.MAX_BULBS,
			"Ламп %d в пределах %d..%d" % [res.bulb_count, TreeGarlandsLayout.MIN_BULBS, TreeGarlandsLayout.MAX_BULBS])
		var res2 := TreeGarlandsLayout.build_cluster(desc, snap)
		check(res.bulb_xfs.size() == res2.bulb_xfs.size(), "Детерминированное число ламп в кластере")
		for bi in res.bulb_xfs.size():
			var xf: Transform3D = res.bulb_xfs[bi]
			var bpos: Vector3 = res.origin + xf.origin
			check(heights._cell_list(bpos.x, bpos.z) == null, "Лампа не висит над мостом/туннелем")
			check(heights.depth_at(bpos.x, bpos.z) <= 0.0, "Лампа не висит над водой")
			var g := heights.ground_at(bpos.x, bpos.z)
			var surf := maxf(g, heights.surface_at(bpos.x, bpos.z, g + 2.5))
			var bottom_y := bpos.y - TreeGarlandsLayout.BULB_DROP
			check(bottom_y >= surf + TreeGarlandsLayout.MIN_CLEARANCE - 0.25,
				"Запас высоты лампы >= 3.45 м (got %.2f)" % (bottom_y - surf))

	check(built_any, "Хотя бы один реальный кластер успешно собран")
	check(world.obj_x == ox_before, "StageVegetation/WorldData не изменяется при поиске и сборке гирлянд")

	# 3. Асинхронная потоковая загрузка + живой переключатель + отмена в полёте без утечек.
	var layer := TreeGarlandsLayer.new()
	root.add_child(layer)
	layer.setup(world, heights, clear_spots, huts)
	if not clusters_a.is_empty():
		var c0: Vector2 = clusters_a[0].center
		var p3 := Vector3(c0.x, heights.ground_at(c0.x, c0.y) + 1.5, c0.y)
		layer.update(p3, p3, Vector3.ZERO, false, 1.0, 2, 2, 0.1)
		layer.flush_pending()
		check(layer.loaded_count() >= 1, "Асинхронная сборка монтирует ближайший кластер")
		for entry: Dictionary in layer.loaded_entries().values():
			check(not entry.bulbs.multimesh.use_colors, "MultiMesh ламп должен иметь use_colors=false (Compatibility safe)")
			check(not entry.halos.multimesh.use_colors, "MultiMesh ореолов должен иметь use_colors=false (Compatibility safe)")
		layer.set_enabled(false)
		check(layer.loaded_count() == 0 and layer.active_light_count() == 0, "Выключение сразу выгружает геометрию и огни")
		layer.set_enabled(true)
		# Старт фоновой задачи и мгновенный finish() без flush_pending (стресс отмены потока).
		layer.update(p3, p3, Vector3.ZERO, false, 1.0, 2, 2, 0.1)
	layer.finish()
	check(layer.loaded_count() == 0 and layer.cluster_count() == 0, "finish() полностью очищает состояние")

	# 4. Проверка настила NORTHSHORE (автоподъём над elevated surface + отбраковка низких деревьев) и блокаторов.
	var deck_h := ElevatedDeckHeightfield.new(2.2)
	var line_pts := PackedVector2Array()
	var line_widths := PackedFloat32Array()
	var tree_list: Array = []
	for i in 12:
		var z := -30.0 + float(i) * 5.5
		line_pts.append(Vector2(0.0, z))
		line_widths.append(1.8)
		var side := -4.4 if i % 2 == 0 else 4.4
		tree_list.append({x = side, z = z, kind = Biomes.T_PINE, v = i % 3, s = 1.45, ground = 0.0})

	var deck_desc := {
		id = 101,
		center = Vector2.ZERO,
		route_pts = line_pts,
		route_widths = line_widths,
		archetype = TreeGarlandsLayout.Archetype.ALLEY_ZIGZAG,
		seed = 101,
		priority = 1.0,
		is_outer = false,
		bbox = Rect2(Vector2(-100.0, -100.0), Vector2(200.0, 200.0)),
	}
	var deck_res := TreeGarlandsLayout.build_cluster(deck_desc, {heights = deck_h, trees_override = tree_list})
	check(deck_res.get("valid", false), "Высокие деревья над настилом NORTHSHORE собираются со смещением вверх")
	var deck_origin: Vector3 = deck_res.get("origin", Vector3.ZERO)
	for xf: Transform3D in deck_res.get("bulb_xfs", []):
		var by := deck_origin.y + xf.origin.y - TreeGarlandsLayout.BULB_DROP
		check(by >= 2.2 + TreeGarlandsLayout.MIN_CLEARANCE - 0.15,
			"Лампа над настилом NORTHSHORE 2.2м >= %.2f (got %.2f)" % [2.2 + TreeGarlandsLayout.MIN_CLEARANCE, by])
	var ok_deck := layer.setup_override(tree_list, line_pts, line_widths, deck_h, Vector2.ZERO, TreeGarlandsLayout.Archetype.ALLEY_ZIGZAG, 101)
	check(ok_deck and layer.loaded_count() == 1, "Слой монтирует кластер над настилом NORTHSHORE")

	# Слишком высокий настил (6.5м), не оставляющий габарита под кроной, обязан отброситься.
	var too_high := ElevatedDeckHeightfield.new(6.5)
	var reject_high := layer.setup_override(tree_list, line_pts, line_widths, too_high, Vector2.ZERO, TreeGarlandsLayout.Archetype.ALLEY_ZIGZAG, 102)
	check(not reject_high, "Низкий просвет над высоким настилом должен безопасно отбраковываться")

	# Постройка посередине аллеи и ворота должны отсеивать перекрытые пролёты.
	var blocked := layer.setup_override(tree_list, line_pts, line_widths, ElevatedDeckHeightfield.new(0.0), Vector2.ZERO,
		TreeGarlandsLayout.Archetype.ALLEY_ZIGZAG, 103, [Vector3(0.0, 0.0, 12.0)], [Vector2(0.0, 15.0)])
	var clear_count := 0
	var full_layer := TreeGarlandsLayer.new()
	root.add_child(full_layer)
	full_layer.setup_override(tree_list, line_pts, line_widths, ElevatedDeckHeightfield.new(0.0), Vector2.ZERO, TreeGarlandsLayout.Archetype.ALLEY_ZIGZAG, 103)
	clear_count = full_layer.total_bulb_count()
	check(not blocked or layer.total_bulb_count() < clear_count, "Дом и ворота должны блокировать задетые пролёты")

	# 5. Настройка tree_garlands: сохранение, защита от повреждённого значения, сброс.
	var cfg_path := "user://garlands_settings_test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg_path))
	var gs := GameSettings.new()
	gs.settings_path = cfg_path
	check(gs.tree_garlands, "По умолчанию tree_garlands включена")
	gs.tree_garlands = false
	check(gs.save_settings() == OK, "Сохранение tree_garlands в конфиг")
	var gs2 := GameSettings.new()
	gs2.settings_path = cfg_path
	gs2.load_settings()
	check(not gs2.tree_garlands, "Выключенный переключатель tree_garlands читается из конфига")
	var bad_cfg := ConfigFile.new()
	bad_cfg.load(cfg_path)
	bad_cfg.set_value("view", "tree_garlands", "not_a_bool")
	bad_cfg.save(cfg_path)
	var gs3 := GameSettings.new()
	gs3.settings_path = cfg_path
	gs3.load_settings()
	check(gs3.tree_garlands, "Повреждённый тип в tree_garlands откатывается к значению по умолчанию")
	gs2.reset_defaults()
	check(gs2.tree_garlands, "Сброс настроек возвращает tree_garlands=true")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg_path))

	full_layer.finish()
	full_layer.queue_free()
	layer.finish()
	layer.queue_free()
	await process_frame
	print("garlands_test OK")
	quit(0 if _failed == 0 else 1)
