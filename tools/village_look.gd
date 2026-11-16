extends SceneTree
## Изолированная сцена «деревня» (без генерации мира):
## - линейка всех моделей библиотеки с фигурой 1,8 м;
## - 6 видов поселений (центр, обычная, лесная, предгорная, приморская, удалённая) днём и ночью;
## - сравнение «было» (use_legacy = true) и «стало» (каталог .glb, 3 LOD, общий атлас, MultiMesh деталей)
##   в одном запуске по числу вызовов отрисовки, треугольников и переключению уровней (40 / 120 / 350 / 1500 м).
##   godot --path . --script res://tools/village_look.gd [-- --out <папка>]

const Catalog := preload("res://scripts/render/asset_catalog.gd")
const DEFAULT_OUT := "res://.godot/village_look"

var out_dir := ""
var camera: Camera3D
var sun: DirectionalLight3D
var env: WorldEnvironment
var day: DayCycle
var fire_light: OmniLight3D
var windows_mat: StandardMaterial3D
var ground_node: MeshInstance3D
var water_node: MeshInstance3D
var forest_props: Node3D
var active_buildings: Node3D
var fails := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	call_deferred("run")


func _check(ok: bool, msg: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", msg)
	else:
		print("OK: ", msg)


func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Для сцены «деревня» нужен графический рендерер (без --headless)")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	var oi := args.find("--out")
	out_dir = ProjectSettings.globalize_path(args[oi + 1] if oi >= 0 and oi + 1 < args.size() else DEFAULT_OUT)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var gdignore := out_dir.path_join(".gdignore")
	if not FileAccess.file_exists(gdignore):
		FileAccess.open(gdignore, FileAccess.WRITE)

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))

	env = WorldEnvironment.new()
	var base_env: Environment = load("res://resources/game_environment.tres")
	env.environment = base_env.duplicate()
	root.add_child(env)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 260.0
	root.add_child(sun)

	day = DayCycle.new(env.environment, sun)
	day.cloud_cover_override = 0.20

	fire_light = OmniLight3D.new()
	fire_light.light_color = Color8(0xff, 0xa8, 0x55)
	fire_light.omni_range = 18.0
	fire_light.light_energy = 1.8
	fire_light.visible = false
	root.add_child(fire_light)

	camera = Camera3D.new()
	camera.fov = 55.0
	camera.far = 2500.0
	root.add_child(camera)
	camera.current = true

	var w := _build_fixture_world()
	var heights := Heightfield.new(w, false)
	StageLandmarks.lay_out(w)
	for s: SettlementData in w.settlements:
		print("Поселение %-22s role=%-9s huts=%d homes=%d" % [s.name, s.role, s.huts.size(), StageLandmarks.homes_of(s)])
		_check(StageLandmarks.homes_of(s) >= 2, "у поселения %s есть жилые дома" % s.name)
	_append_lineup_settlement(w)
	_append_bench50_settlement(w)
	_append_sites_fixture(w)

	ground_node = MeshInstance3D.new()
	ground_node.mesh = _build_ground_mesh(w, heights)
	var gmat := StandardMaterial3D.new()
	gmat.vertex_color_use_as_albedo = true
	gmat.roughness = 0.96
	ground_node.material_override = gmat
	root.add_child(ground_node)

	water_node = MeshInstance3D.new()
	var wplane := PlaneMesh.new()
	wplane.size = Vector2(260.0, 116.0)
	water_node.mesh = wplane
	water_node.position = Vector3(384.0, 25.0, 460.0)
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.16, 0.36, 0.48, 0.92)
	wmat.roughness = 0.18
	water_node.material_override = wmat
	root.add_child(water_node)

	forest_props = _build_forest_ring(heights, Vector3(640.0, 0.0, 128.0))
	root.add_child(forest_props)

	var report := {catalog_models = {}, legacy = {}, current = {}, lod = {}}
	var catalog := Catalog.get_catalog()
	for id: String in catalog.settlements:
		var entry: Dictionary = catalog.settlements[id]
		var counts: Array[int] = []
		for m: Mesh in entry.lods:
			counts.append(SettlementModels._mesh_tris(m))
		report.catalog_models[id] = {size = entry.size, half = [entry.half.x, entry.half.y], tris = counts}
		print("Каталог %-14s size=%-8s half=(%.1f, %.1f) tris=%s" % [id, entry.size, entry.half.x, entry.half.y, str(counts)])

	# 1. «Было» (старые процедурные дома) тем же запуском
	SettlementsBuilder.use_legacy = true
	active_buildings = Node3D.new()
	root.add_child(active_buildings)
	var built_legacy := SettlementsBuilder.build(active_buildings, w, heights)
	windows_mat = built_legacy.windows
	await _set_time(12.5, Vector3(128.0, 25.2, 128.0))
	_aim(Vector3(128.0 + 34.0, 25.2 + 18.0, 128.0 + 42.0), Vector3(128.0, 25.2 + 2.0, 128.0))
	await _shot("legacy_center_day")
	await _set_time(23.0, Vector3(128.0, 25.2, 128.0))
	await _shot("legacy_center_night")
	await _set_time(12.5, Vector3(896.0, 25.2, 128.0))
	_aim(Vector3(896.0, 25.2 + 9.0, 128.0 + 44.0), Vector3(896.0, 25.2 + 2.2, 128.0))
	await _shot("legacy_lineup")
	report.legacy = await _measure_square(Vector2i(4, 0), Vector3(1152.0, 25.2 + 4.0, 128.0 - 40.0), Vector3(1152.0, 25.2 + 2.0, 128.0))
	print("БЫЛО (квадрат 50 домов всех видов, 40 м): draw_calls=%d main=%d tris=%d" % [report.legacy.draw_calls, report.legacy.main_draw_calls, report.legacy.tris])
	active_buildings.queue_free()
	await process_frame

	# 2. «Стало» (каталог .glb, 3 LOD, общий атлас, MultiMesh деталей)
	SettlementsBuilder.use_legacy = false
	active_buildings = Node3D.new()
	root.add_child(active_buildings)
	var built_new := SettlementsBuilder.build(active_buildings, w, heights)
	windows_mat = built_new.windows

	# Линейка всех 21 моделей в 2 ряда (12 жилых сзади z=120, 9 хозпостроек и характерных спереди z=142)
	await _set_time(12.5, Vector3(896.0, 25.2, 100.0))
	_add_lineup_labels(active_buildings)
	_aim(Vector3(896.0, 25.2 + 9.5, 128.0 + 46.0), Vector3(896.0, 25.2 + 2.2, 130.0))
	await _shot("models_lineup")
	# Крупные планы по группам моделей (с зазора между рядами, без перекрытия передним рядом)
	_aim(Vector3(878.0, 25.2 + 3.4, 135.5), Vector3(878.0, 25.2 + 1.8, 120.0))
	await _shot("lineup_small_forest")
	_aim(Vector3(914.0, 25.2 + 4.5, 136.5), Vector3(914.0, 25.2 + 2.6, 120.0))
	await _shot("lineup_chalet_tall")
	_aim(Vector3(896.0, 25.2 + 3.8, 142.0 + 18.0), Vector3(896.0, 25.2 + 1.4, 142.0))
	await _shot("lineup_out_landmarks")

	# Снимки 6 видов поселений днём и ночью
	var shots := [
		["center", Vector3(128.0, 25.2, 128.0), Vector3(34.0, 18.0, 42.0), true],
		["ordinary", Vector3(384.0, 25.2, 128.0), Vector3(30.0, 15.0, 36.0), false],
		["forest", Vector3(640.0, 25.2, 128.0), Vector3(22.0, 9.5, 25.0), true],
		["foothill", Vector3(128.0, 25.2, 384.0), Vector3(30.0, 13.0, 36.0), false],
		["coastal", Vector3(384.0, 25.2, 384.0), Vector3(28.0, 14.0, 38.0), false],
		["remote", Vector3(640.0, 25.2, 384.0), Vector3(22.0, 11.0, 26.0), true],
		["sites", Vector3(896.0, 25.2, 384.0), Vector3(14.0, 9.5, 25.0), true],
	]
	for spec: Array in shots:
		var kind: String = spec[0]
		var target: Vector3 = spec[1]
		var offset: Vector3 = spec[2]
		await _set_time(12.5, target)
		_aim(target + offset, target + Vector3(0, 2.0, 0))
		await _shot(kind + "_day")
		if spec[3]:
			await _set_time(23.0, target)
			await _shot(kind + "_night")

	# Обзорная точка, охватывающая площадь поселений
	await _set_time(12.5, Vector3(384.0, 25.2, 256.0))
	_aim(Vector3(384.0, 210.0, 620.0), Vector3(384.0, 25.0, 230.0))
	await _shot("overview_day")

	# Проверка переходов LOD и вызовов отрисовки на квадрате (4, 0) с 50 постройками всех 21 видов
	await _set_time(12.5, Vector3(1152.0, 25.2, 128.0))
	for dist: float in [40.0, 120.0, 350.0, 1500.0]:
		var m := await _measure_square(Vector2i(4, 0), Vector3(1152.0, 25.2 + clampf(dist * 0.14, 5.0, 65.0), 128.0 - dist), Vector3(1152.0, 25.2 + 2.0, 128.0))
		report.lod[str(int(dist))] = m
		print("СТАЛО (квадрат 50 домов, %4d м): draw_calls=%d main=%d tris=%d" % [int(dist), m.draw_calls, m.main_draw_calls, m.tris])
		if dist < 1000.0:
			await _shot("lod_%dm" % int(dist))

	report.current = report.lod["40"]
	var square_nodes := _count_building_nodes(active_buildings, Vector2i(4, 0))
	_check(square_nodes.lod_meshes == 3, "у квадрата 256 м 3 уровня LOD (найдено %d)" % square_nodes.lod_meshes)
	_check(square_nodes.multimeshes >= 1 and square_nodes.all_use_colors, "мелкие детали в MultiMesh с use_colors=true")
	_check(report.lod["40"].main_draw_calls <= report.legacy.main_draw_calls, "основных вызовов на 40 м стало (%d) не больше, чем было (%d)" % [report.lod["40"].main_draw_calls, report.legacy.main_draw_calls])
	_check(report.lod["120"].main_draw_calls == 1, "на 120 м (LOD1) ровно 1 основной вызов отрисовки зданий (получено %d, с тенями %d)" % [report.lod["120"].main_draw_calls, report.lod["120"].draw_calls])
	_check(report.lod["350"].main_draw_calls == 1, "на 350 м (LOD2) ровно 1 вызов отрисовки зданий (получено %d, с тенями %d)" % [report.lod["350"].main_draw_calls, report.lod["350"].draw_calls])
	_check(report.lod["1500"].draw_calls == 0, "за 1400 м (1500 м) квадрат отсечён (вызовов %d)" % report.lod["1500"].draw_calls)
	_check(report.lod["40"].tris > report.lod["120"].tris and report.lod["120"].tris > report.lod["350"].tris,
		"треугольники убывают по уровням (%d -> %d -> %d)" % [report.lod["40"].tris, report.lod["120"].tris, report.lod["350"].tris])

	FileAccess.open(out_dir.path_join("village_stats.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("Снимки и статистика: ", out_dir)
	quit(1 if fails > 0 else 0)


func _set_time(hour: float, fire_pos: Vector3) -> void:
	day.apply(hour, 10.0)
	var night := clampf(1.0 - day.sunlight, 0.0, 1.0)
	SettlementsBuilder.set_night(windows_mat, night)
	fire_light.visible = night > 0.05
	fire_light.position = fire_pos + Vector3(0, 1.5, 0)
	await process_frame


func _aim(pos: Vector3, target: Vector3) -> void:
	camera.look_at_from_position(pos, target)


func _shot(name: String) -> void:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var err := root.get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	if err != OK:
		printerr("Не удалось сохранить %s: %s" % [name, error_string(err)])
		fails += 1


func _measure_square(square: Vector2i, cam_pos: Vector3, cam_target: Vector3) -> Dictionary:
	var vis := _isolate_square(square, true)
	ground_node.visible = false
	water_node.visible = false
	forest_props.visible = false
	_aim(cam_pos, cam_target)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var vp := root.get_viewport_rid()
	var dc := RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var prims := RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var prev_shadows := sun.shadow_enabled
	sun.shadow_enabled = false
	for i in 2:
		await process_frame
	await RenderingServer.frame_post_draw
	var main_dc := RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	sun.shadow_enabled = prev_shadows
	ground_node.visible = true
	water_node.visible = true
	forest_props.visible = true
	_isolate_square(square, false)
	return {draw_calls = dc, main_draw_calls = main_dc, tris = prims, nodes = vis}


## Прячет все узлы кроме Buildings_<square> для точного замера вызовов и треугольников одного квадрата 256 м.
func _isolate_square(square: Vector2i, isolate: bool) -> Array[String]:
	var tag := "_%d_%d" % [square.x, square.y]
	var kept: Array[String] = []
	for child in active_buildings.get_children():
		if child.name == "Buildings":
			for sub in child.get_children():
				var match_sq: bool = sub.name.begins_with("Buildings" + tag + "_") or sub.name.begins_with("Buildings_Detail" + tag + "_") or sub.name.ends_with("Buildings" + tag)
				sub.visible = match_sq if isolate else true
				if match_sq:
					kept.append(sub.name)
		else:
			child.visible = not isolate
	return kept


func _count_building_nodes(node_root: Node3D, square: Vector2i) -> Dictionary:
	var tag := "_%d_%d" % [square.x, square.y]
	var lod_meshes := 0
	var multimeshes := 0
	var all_use_colors := true
	var batch_node := node_root.get_node_or_null("Buildings")
	if batch_node != null:
		for sub in batch_node.get_children():
			if not (sub.name.begins_with("Buildings" + tag + "_") or sub.name.begins_with("Buildings_Detail" + tag + "_")):
				continue
			if sub is MeshInstance3D and sub.name.contains("_LOD"):
				lod_meshes += 1
			elif sub is MultiMeshInstance3D:
				multimeshes += 1
				all_use_colors = all_use_colors and sub.multimesh.use_colors
	return {lod_meshes = lod_meshes, multimeshes = multimeshes, all_use_colors = all_use_colors}


func _build_fixture_world() -> WorldData:
	var w := WorldData.new()
	w.W = 320
	w.H = 192
	w.N = w.W * w.H
	w.seed_text = "village-look"
	w.seed_num = 20261116
	w.CS = WorldData.CHUNK_SIZE
	w.CW = w.W / w.CS
	w.CH = w.H / w.CS
	for key in ["h", "filled", "elev", "temp", "moist", "slope", "dist_water", "dist_ocean"]:
		var a := PackedFloat32Array()
		a.resize(w.N)
		a.fill(25.2 / GameConfig.HS if key in ["h", "filled"] else (0.12 if key == "elev" else (25.0 if key in ["dist_water", "dist_ocean"] else 0.0)))
		w.set(key, a)
	for key in ["biome", "ocean", "lake", "river", "path_mask"]:
		var a := PackedByteArray()
		a.resize(w.N)
		if key == "biome":
			a.fill(Biomes.GRASS)
		w.set(key, a)

	# Холм для предгорной деревни (квадрат 0,1: x=0..64, y=64..128) с плавными краями
	for y in range(64, 128):
		for x in range(0, 64):
			var idx := y * w.W + x
			var tx := clampf(1.0 - absf(x - 32.0) / 30.0, 0.0, 1.0)
			var ty := sin(clampf((y - 66.0) / 60.0, 0.0, 1.0) * TAU) * -0.5
			var h_m := 25.2 + ty * 8.0 * smoothstep(0.0, 0.5, tx)
			w.h[idx] = h_m / GameConfig.HS
			w.filled[idx] = w.h[idx]
			w.elev[idx] = 0.25
			w.slope[idx] = 0.16
			w.biome[idx] = Biomes.TUNDRA

	# Лес для лесной деревни (квадрат 2,0: x=128..192, y=0..64)
	for y in range(0, 64):
		for x in range(128, 192):
			w.biome[y * w.W + x] = Biomes.FOREST

	# Берег моря для приморской деревни (квадрат 1,1: x=64..128, y=64..128)
	for y in range(64, 128):
		for x in range(64, 128):
			var idx := y * w.W + x
			w.dist_water[idx] = maxf(0.0, 103.0 - y)
			w.dist_ocean[idx] = w.dist_water[idx]
			if y >= 103:
				w.h[idx] = 24.4 / GameConfig.HS
				w.filled[idx] = w.h[idx]
				w.ocean[idx] = 1
				w.biome[idx] = Biomes.BEACH

	var specs := [
		["Центр (Село Большое)", "center", "торговый посёлок", true, 9, 32.0, 32.0, 0],
		["Обычная (Полевая)", "ordinary", "земледельческая деревня", false, 5, 96.0, 32.0, 1],
		["Лесная (Сосновка)", "forest", "лесная деревня", false, 5, 160.0, 32.0, 2],
		["Предгорная (Утесы)", "foothill", "предгорная деревня", false, 5, 32.0, 96.0, 3],
		["Приморская (Бухта)", "ordinary", "приморская деревня", false, 5, 96.0, 96.0, 0],
		["Удалённая (Заимка)", "remote", "лесная заимка", false, 3, 160.0, 96.0, 2],
	]
	for sp: Array in specs:
		var sx := int(sp[5])
		var sy := int(sp[6])
		var s := SettlementData.new(sp[5], sp[6], sy * w.W + sx, sp[0])
		s.role = sp[1]
		s.character = sp[2]
		s.town = sp[3]
		s.homes = sp[4]
		s.style = sp[7]
		w.settlements.append(s)
		# Перекрёсток дорог/троп в поселении для естественной раскладки улиц
		for d in range(-10, 11):
			var rx := clampi(sx + d, 1, w.W - 2)
			var ry := clampi(sy + d, 1, w.H - 2)
			w.path_mask[sy * w.W + rx] = 3
			if s.role != "remote":
				w.path_mask[ry * w.W + sx] = 2 if s.role in ["forest", "foothill"] else 3
	return w


func _lineup_slots() -> Array[Dictionary]:
	var ids: Array = SettlementSets.MODEL_ORDER
	var rows := [
		{list = ids.slice(0, 12), z = 120.0, gap = 5.4},
		{list = ids.slice(12), z = 142.0, gap = 5.6},
	]
	var out: Array[Dictionary] = []
	for row: Dictionary in rows:
		var list: Array = row.list
		var width := float(list.size() - 1) * float(row.gap)
		var x0 := 896.0 - width * 0.5
		for k in list.size():
			out.append({id = str(list[k]), x = x0 + k * float(row.gap), z = float(row.z), idx = out.size()})
	return out


func _append_lineup_settlement(w: WorldData) -> void:
	# Квадрат (3, 0): центр костра вынесен назад (896, 100) м, линейка из 21 модели лицом к +Z в два ряда
	var lineup := SettlementData.new(224.0, 25.0, 25 * w.W + 224, "Линейка моделей")
	lineup.style = 0
	for sl: Dictionary in _lineup_slots():
		lineup.huts.append(HutData.new(float(sl.x) / GameConfig.TILE, float(sl.z) / GameConfig.TILE, int(sl.idx) % 4, sl.id, 0.0))
	w.settlements.append(lineup)


func _append_bench50_settlement(w: WorldData) -> void:
	# Квадрат (4, 0): центр (1152, 128) м -> 50 разных построек всех 21 видов на одном квадрате 256×256 м
	var bench := SettlementData.new(288.0, 32.0, 32 * w.W + 288, "Замер 50 домов")
	bench.style = 1
	var ids: Array = SettlementSets.MODEL_ORDER
	for k in 50:
		var row := k / 10
		var col := k % 10
		var id: String = str(ids[k % ids.size()])
		var px := 1152.0 - 45.0 + col * 10.0
		var pz := 128.0 - 20.0 + row * 10.0
		var yaw := (k % 4) * (PI * 0.5)
		bench.huts.append(HutData.new(px / GameConfig.TILE, pz / GameConfig.TILE, k % 4, id, yaw))
	w.settlements.append(bench)


func _append_sites_fixture(w: WorldData) -> void:
	# Квадрат (3, 1): центр (896, 384) м -> памятники и туры на общем атласе (tower, shelter, obelisk, ruin+keep, stones, peak)
	var cx := 224.0
	var cy := 96.0
	var items := [
		["tower", 2, "Дозорная вышка", cx - 3.6, cy - 1.5, [["tower", 0.0, 0.0, 0]]],
		["shelter", 2, "Горный приют", cx - 0.8, cy - 1.6, [["shelter", 0.0, 0.0, 0]]],
		["obelisk", 2, "Стела", cx + 1.8, cy - 1.8, [["obelisk", 0.0, 0.0, 0]]],
		["ruin", 3, "Руины замка", cx + 4.4, cy + 0.8, [["ruin", 0.0, 0.0, 0], ["keep", -1.4, -0.6, 1]]],
		["stones", 2, "Каменный круг", cx - 2.2, cy + 1.8, [
			["stone", 1.2, 0.0, 0], ["stone", 0.4, 1.1, 1], ["stone", -0.8, 0.9, 2],
			["stone", -1.1, -0.5, 3], ["stone", 0.1, -1.2, 1],
		]],
	]
	for sp: Array in items:
		var sx: float = sp[3]
		var sy: float = sp[4]
		var huts: Array[HutData] = []
		for p: Array in sp[5]:
			huts.append(HutData.new(sx + float(p[1]), sy + float(p[2]), int(p[3]), str(p[0]), 0.15))
		w.sites.append(SiteData.new(sx, sy, int(sy) * w.W + int(sx), str(sp[0]), int(sp[1]), str(sp[2]), 2.0, huts))
	w.peaks.append({x = cx + 0.8, y = cy + 2.0, i = int(cy + 2.0) * w.W + int(cx + 0.8), elev = 0.65, name = "Пик Каменный"})


func _add_lineup_labels(parent: Node3D) -> void:
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color("d8572a")
	var cap := CapsuleMesh.new()
	cap.radius = 0.25
	cap.height = 1.8
	for sl: Dictionary in _lineup_slots():
		var id: String = sl.id
		var half := SettlementSets.half_of(id)
		var fig := MeshInstance3D.new()
		fig.mesh = cap
		fig.position = Vector3(float(sl.x) + half.x + 0.65, 25.2 + 0.9, float(sl.z) + 1.4)
		fig.material_override = rm
		parent.add_child(fig)
		var lbl := Label3D.new()
		lbl.text = "%s\n(%.1f×%.1f)" % [id, half.x * 2.0, half.y * 2.0]
		lbl.pixel_size = 0.011
		lbl.font_size = 38
		lbl.outline_size = 9
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.position = Vector3(float(sl.x), 25.2 + SettlementSets.height_of(id) + 2.2, float(sl.z))
		parent.add_child(lbl)


func _build_ground_mesh(w: WorldData, heights: Heightfield) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := 2
	for y in range(0, w.H - step, step):
		for x in range(0, w.W - step, step):
			var p00 := _gvert(w, heights, x, y)
			var p10 := _gvert(w, heights, x + step, y)
			var p01 := _gvert(w, heights, x, y + step)
			var p11 := _gvert(w, heights, x + step, y + step)
			for tri: Array in [[p00, p10, p11], [p00, p11, p01]]:
				var nrm: Vector3 = ((tri[1].p - tri[0].p) as Vector3).cross(tri[2].p - tri[0].p).normalized()
				if nrm.y < 0.0:
					nrm = -nrm
				for v: Dictionary in tri:
					st.set_color(v.c)
					st.set_normal(nrm)
					st.add_vertex(v.p)
	st.index()
	return st.commit()


func _gvert(w: WorldData, heights: Heightfield, x: int, y: int) -> Dictionary:
	var wx := (x + 0.5) * GameConfig.TILE
	var wz := (y + 0.5) * GameConfig.TILE
	var idx := y * w.W + x
	var wy := heights.ground_at(wx, wz)
	var col := Color(0.40, 0.50, 0.28)
	if w.biome[idx] == Biomes.FOREST:
		col = Color(0.28, 0.40, 0.22)
	elif w.biome[idx] == Biomes.TUNDRA:
		col = Color(0.46, 0.48, 0.36)
	elif w.biome[idx] == Biomes.BEACH:
		col = Color(0.76, 0.70, 0.52)
	if w.path_mask[idx] >= 2:
		col = Color(0.55, 0.48, 0.37) if w.path_mask[idx] == 3 else Color(0.48, 0.43, 0.33)
	return {p = Vector3(wx, wy, wz), c = col}


func _build_forest_ring(heights: Heightfield, center: Vector3) -> Node3D:
	var grp := Node3D.new()
	var catalog := Catalog.get_catalog()
	var def: Dictionary = catalog.trees.get(Biomes.T_PINE, {})
	if def.is_empty():
		return grp
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = def.get("bark", Color(0.35, 0.24, 0.16))
	trunk_mat.albedo_texture = def.get("trunk_texture")
	trunk_mat.vertex_color_use_as_albedo = def.get("colored_bark", false)
	var crown_mat := StandardMaterial3D.new()
	crown_mat.albedo_color = def.leaves[0] if def.has("leaves") else Color(0.2, 0.38, 0.18)
	crown_mat.albedo_texture = def.get("crown_texture")
	crown_mat.vertex_color_use_as_albedo = true
	crown_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	crown_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	for k in 18:
		var a := TAU * k / 18.0 + 0.12 * (k % 3)
		if cos(a) > 0.20 and sin(a) > 0.20:
			continue # просвет со стороны камеры
		var r := 29.0 + (k % 4) * 4.5
		var tx := center.x + cos(a) * r
		var tz := center.z + sin(a) * r
		var ty := heights.ground_at(tx, tz)
		for part: String in ["trunk", "crown"]:
			if not def.has(part):
				continue
			var mi := MeshInstance3D.new()
			mi.mesh = def[part]
			mi.position = Vector3(tx, ty, tz)
			mi.scale = Vector3.ONE * (0.85 + 0.12 * (k % 3))
			mi.material_override = trunk_mat if part == "trunk" else crown_mat
			grp.add_child(mi)
	return grp
