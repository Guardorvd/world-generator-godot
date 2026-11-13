extends SceneTree
## Изолированный стенд визуального стиля (VisualStyle: цветокоррекция, планы, мягкие света, зерно) на сохранённом мире
## без генерации: фикстура tools/control/runs/road_relief/<сид>.fixture.bin, рельеф, ближний и дальний лес, вода, DayCycle.
## Состояния: полдень на лугу, утренний лес, закат, ночь, пасмурно, туман, горы, вода, дорога. Варианты на каждое:
## off (всё выключено), grade / depth / highlights / grain (по одному) и all. Печатает показатели кадров (STYLE_STAT),
## сохраняет снимки <состояние>_<вариант>.png, лист before/after docs-вида style_sheet.png и листы по состояниям.
## Нужно окно (Compatibility на этом ПК). Запуск (лимит 600 с):
##   godot --path . --script res://tools/style_look.gd -- [--seed Север-1234] [--out <папка>] [--states a,b] [--variants off,all]
##     [--tonemap] — только сравнение тонмапперов на светлых состояниях (лист tonemap_sheet.png, показатели срезов)
##     [--checks] — LUT без поправки, неподвижность зерна, ход камеры (кадры off/all)
## Параметры тонмаппера для подбора: --agx-white, --agx-contrast, --agx-exposure.

const Dev := preload("res://tools/control/control.gd")
const Snapshot := preload("res://scripts/game/surface_snapshot.gd")
const Far := preload("res://scripts/render/distant_forest.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const TILE := GameConfig.TILE
const VARIANTS := ["off", "grade", "depth", "highlights", "grain", "all"]
const STATES := {
	noon_meadow = {view = "meadow", hour = 12.3, cover = 0.22},
	morning_forest = {view = "forest", hour = 7.3, cover = 0.3},
	sunset = {view = "valley", hour = 17.4, cover = 0.35},
	night = {view = "forest", hour = 0.9, cover = 0.3},
	overcast = {view = "meadow", hour = 13.0, cover = 0.82},
	mist = {view = "valley", hour = 6.4, cover = 0.4},
	mountains = {view = "peak", hour = 15.0, cover = 0.25},
	water = {view = "water", hour = 12.6, cover = 0.25},
	road = {view = "road", hour = 10.8, cover = 0.25},
}
const SHEET_ORDER := ["noon_meadow", "morning_forest", "sunset", "night", "overcast", "mist", "mountains", "water"]

var args := OS.get_cmdline_user_args()
var out := ""
var camera: Camera3D
var cycle: DayCycle
var env: Environment
var vegetation: VegetationLayer
var world: WorldData
var heights: Heightfield
var sun: DirectionalLight3D
var views := {}
var images := {}
var stats := {}
var fails := 0
var _placed := ""


func _check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 600)
	out = Dev.arg("out", "res://.godot/style_look")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	root.size = Vector2i(1280, 720)
	_run.call_deferred()


func _run() -> void:
	var started := Time.get_ticks_msec()
	_build_world(Dev.arg("seed", "Север-1234"))
	print("STYLE_BUILD ms=", Time.get_ticks_msec() - started, " objects=", world.obj_count, " renderer=", RenderingServer.get_current_rendering_method())
	var state_names: Array = STATES.keys()
	if Dev.arg("states", "") != "":
		state_names = Dev.arg("states", "").split(",")
	var variants: Array = VARIANTS
	if Dev.arg("variants", "") != "":
		variants = Dev.arg("variants", "").split(",")
	if "--tonemap" in args:
		await _tonemap_sheet()
	elif "--checks" in args:
		await _checks()
	else:
		for state: String in state_names:
			for variant: String in variants:
				await _shot(state, variant)
			_state_sheet(state, variants)
		if variants.has("off") and variants.has("all"):
			_before_after_sheet(state_names)
		FileAccess.open(ProjectSettings.globalize_path(out).path_join("style_stats.json"), FileAccess.WRITE).store_string(JSON.stringify(stats, "\t"))
	print("STYLE_LOOK failures=", fails, " total_ms=", Time.get_ticks_msec() - started)
	quit(1 if fails else 0)


# ---------- мир ----------

func _build_world(seed_text: String) -> void:
	var path := "res://tools/control/runs/road_relief/%s.fixture.bin" % seed_text
	var saved: Dictionary = FileAccess.open(path, FileAccess.READ).get_var()
	world = WorldCache.new()._restore(saved.world, true)
	world.available_rect = Rect2i()
	heights = Snapshot.restore(world, saved.base, "base")
	saved = {}
	if world.obj_count == 0:
		StageVegetation.run(world)
	var scene := Node3D.new()
	root.add_child(scene)
	var terrain := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, TerrainBuilder.build_arrays(world, heights))
	terrain.mesh = mesh
	terrain.material_override = TerrainBuilder.new().material(MapBaker.bake(world, 2, true), Floor.surface_image(world))
	scene.add_child(terrain)
	for node: Node in WaterBuilder.build(world, WaterBuilder.prepare(world, heights)):
		scene.add_child(node)
	var env_node := WorldEnvironment.new()
	var template: Node = load("res://scenes/game_world.tscn").instantiate()
	env = template.get_node("WorldEnvironment").environment.duplicate()
	template.free()
	env_node.environment = env
	scene.add_child(env_node)
	sun = DirectionalLight3D.new()
	scene.add_child(sun)
	cycle = DayCycle.new(env, sun)
	cycle.world_seed = world.seed_num
	cycle.terrain_mats = [terrain.material_override]
	preload("res://scripts/render/lighting_quality.gd").apply(env, sun, 1, true)
	vegetation = VegetationLayer.new()
	scene.add_child(vegetation)
	vegetation.settings = GameSettings.new()
	vegetation.settings.flora = 1
	vegetation.setup(world, heights, Models.tree_defs(), Models.grass_mesh(), Floor.surface_image(world))
	var crowns := Node3D.new()
	scene.add_child(crowns)
	Far.active = true
	for y in ceili(float(world.H) / PlanTerrain.CELLS):
		for x in ceili(float(world.W) / PlanTerrain.CELLS):
			Far.attach(crowns, Far.plan(world, heights, Vector2i(x, y)))
	RenderingServer.global_shader_parameter_set("distant_vegetation", Vector4(vegetation.tree_r, vegetation.tree_r * 0.2, 1400, 1.0))
	camera = Camera3D.new()
	camera.far = 9000.0
	camera.fov = 70.0
	scene.add_child(camera)
	camera.make_current()
	var grain := StyleGrain.new()
	camera.add_child(grain)
	var lut_start := Time.get_ticks_usec()
	VisualStyle._build_lut(0.5)
	var lut_mid := Time.get_ticks_usec()
	VisualStyle._build_lut(0.7)
	print("STYLE_LUT first_ms=", (lut_mid - lut_start) / 1000.0, " next_ms=", (Time.get_ticks_usec() - lut_mid) / 1000.0, " size=", VisualStyle.LUT_SIZE)
	VisualStyle.bind(env)
	_pick_views()


## Одни и те же места от запуска к запуску: данные мира, а не случайность
func _pick_views() -> void:
	var best := 0
	for i in world.chunks.size():
		if world.chunks[i].size() > world.chunks[best].size():
			best = i
	var forest := Vector3((best % world.CW + 0.5) * world.CS * TILE, 0.0, (best / world.CW + 0.5) * world.CS * TILE)
	forest.y = heights.ground_at(forest.x, forest.z)
	views.forest = {pos = forest + Vector3(0.0, 1.9, 0.0), target = forest + Vector3(-30.0, 3.0, -55.0)}
	var meadow := forest + Vector3(60.0, 0.0, 40.0)
	meadow.y = heights.ground_at(meadow.x, meadow.z)
	views.meadow = {pos = meadow + Vector3(0.0, 2.2, 0.0), target = meadow + Vector3(-40.0, 14.0, -120.0)}
	if world.peaks.size() > 0:
		var top: Dictionary = world.peaks[0]
		for p in world.peaks:
			if p.elev > top.elev:
				top = p
		var t := Dev._at(heights, top.x, top.y, 0.0)
		views.peak = {pos = Dev._look_from(heights, t, 700.0, 30.0, -40.0), target = t + Vector3(0, 40, 0)}
	# Вода: в сохранённых мирах нет лент рек, но есть озёра и море (уровень воды по клеткам). Берётся клетка с глубиной
	# не меньше 0,6 м, ближайшая к центру карты; камера над водой смотрит на берег, а с высоты — вдоль долины к центру.
	var centre := Vector2(world.W, world.H) * 0.5
	var water_cell := Vector2i(-1, -1)
	var water_best := INF
	for y in range(8, world.H - 8, 3):
		for x in range(8, world.W - 8, 3):
			var level := heights.water_level[y * world.W + x]
			if is_finite(level) and level - heights.ground_at((x + 0.5) * TILE, (y + 0.5) * TILE) > 0.6:
				var d := Vector2(x, y).distance_to(centre)
				if d < water_best:
					water_best = d
					water_cell = Vector2i(x, y)
	if water_cell.x >= 0:
		var wx := (water_cell.x + 0.5) * TILE
		var wz := (water_cell.y + 0.5) * TILE
		var level := heights.water_level[water_cell.y * world.W + water_cell.x]
		var toward := (Vector3(centre.x * TILE, 0.0, centre.y * TILE) - Vector3(wx, 0.0, wz)).normalized()
		if toward.length() < 0.5:
			toward = Vector3.FORWARD
		views.water = {pos = Vector3(wx, level + 2.4, wz) - toward * 18.0, target = Vector3(wx, level + 0.4, wz) + toward * 40.0}
		var vantage := Vector3(wx, heights.ground_at(wx, wz) + 70.0, wz) - toward * 160.0
		views.valley = {pos = vantage, target = Vector3(wx, level + 4.0, wz) + toward * 260.0}
		print("STYLE_VIEW вода в клетке ", water_cell, " уровень ", level)
	var roads: Array = []
	for t in world.trails:
		if t.kind == "road":
			roads.append(t.pts)
	var road: Array = Dev._longest(roads)
	if road.size() > 2:
		var m := road.size() / 2
		var k := Dev._along(road, m, 26.0)
		views.road = {pos = Dev._at(heights, road[m].x, road[m].y, 1.9), target = Dev._at(heights, road[k].x, road[k].y, 0.8)}
	for key: String in ["valley", "peak", "water", "road"]:
		if not views.has(key):
			views[key] = views.forest
			print("STYLE_VIEW нет вида ", key, ": взят лес")


# ---------- съёмка ----------

func _set_variant(variant: String) -> void:
	var on := {}
	var amount := VisualStyle.DEFAULT_AMOUNT.duplicate()
	for id: String in VisualStyle.EFFECTS:
		on[id] = variant == "all" or variant == id
	if Dev.arg("amount", "") != "" and variant != "off":
		for id: String in VisualStyle.EFFECTS:
			amount[id] = float(Dev.arg("amount", "0.6"))
	VisualStyle.configure(on, amount)


func _place(state: String) -> void:
	var s: Dictionary = STATES[state]
	var v: Dictionary = views[s.view]
	camera.look_at_from_position(v.pos, v.target)
	cycle.cloud_cover_override = s.cover
	cycle.apply(s.hour, 40.0)
	vegetation.update(v.pos.x, v.pos.z, true)


func _grab(frames := 8) -> Image:
	for i in frames:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _shot(state: String, variant: String) -> Image:
	# Кадр на Intel HD 4600 ~0,5 с: камера и растительность ставятся один раз на состояние, дальше меняются только настройки стиля
	if _placed != state:
		_place(state)
		await _grab(6)
		_placed = state
	_set_variant(variant)
	var s: Dictionary = STATES[state]
	cycle.apply(s.hour, 40.0) # DayCycle читает exposure_scale() и saturation_scale() уже новых настроек
	var img := await _grab(3)
	images[state + "/" + variant] = img
	img.save_png(ProjectSettings.globalize_path(out).path_join("%s_%s.png" % [state, variant]))
	var row := _measure(img)
	stats[state + "/" + variant] = row
	print("STYLE_STAT ", state, " ", variant, " ", JSON.stringify(row))
	return img


## Показатели кадра: средняя яркость, доля срезанных светов, цвет светов, разброс яркости у земли и у горизонта
func _measure(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var sum := 0.0
	var clipped := 0
	var count := 0
	var hi_chroma := 0.0
	var hi_count := 0
	var hi_warm := 0.0
	var near := PackedFloat32Array()
	var far := PackedFloat32Array()
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			var c := img.get_pixel(x, y)
			var l := c.get_luminance()
			sum += l
			count += 1
			if maxf(c.r, maxf(c.g, c.b)) >= 0.985:
				clipped += 1
			if l > 0.7:
				hi_count += 1
				hi_chroma += maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b))
				hi_warm += c.r - c.b
			if y > h * 0.78:
				near.append(l)
			elif y > h * 0.5 and y < h * 0.62:
				far.append(l)
	return {
		luma = snappedf(sum / count, 0.0001),
		clipped = snappedf(float(clipped) / count, 0.0001),
		hi_chroma = snappedf(hi_chroma / maxf(hi_count, 1), 0.0001),
		hi_warm = snappedf(hi_warm / maxf(hi_count, 1), 0.0001),
		near_sd = snappedf(_sd(near), 0.0001),
		far_sd = snappedf(_sd(far), 0.0001),
	}


func _sd(values: PackedFloat32Array) -> float:
	if values.size() < 2:
		return 0.0
	var mean := 0.0
	for v in values:
		mean += v
	mean /= values.size()
	var acc := 0.0
	for v in values:
		acc += (v - mean) * (v - mean)
	return sqrt(acc / values.size())


# ---------- листы ----------

func _sheet(keys: Array, columns: int, cell: Vector2i, file: String) -> void:
	var rows := ceili(float(keys.size()) / columns)
	var sheet := Image.create(cell.x * columns, cell.y * rows, false, Image.FORMAT_RGB8)
	for i in keys.size():
		var img: Image = images.get(keys[i])
		if img == null:
			continue
		var small: Image = img.duplicate()
		small.convert(Image.FORMAT_RGB8)
		small.resize(cell.x, cell.y, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(small, Rect2i(Vector2i.ZERO, cell), Vector2i((i % columns) * cell.x, (i / columns) * cell.y))
	_check(sheet.save_png(ProjectSettings.globalize_path(out).path_join(file)) == OK, "лист " + file)


func _state_sheet(state: String, variants: Array) -> void:
	var keys := []
	for v in variants:
		keys.append(state + "/" + v)
	_sheet(keys, 3, Vector2i(640, 360), "sheet_%s.png" % state)


## Лист для docs/images: слева «было» (всё выключено), справа «стало» (всё включено), по паре на состояние
func _before_after_sheet(state_names: Array) -> void:
	var keys := []
	for state: String in SHEET_ORDER:
		if state in state_names:
			keys.append(state + "/off")
			keys.append(state + "/all")
	_sheet(keys, 4, Vector2i(480, 270), "style_sheet.png")


# ---------- тонмапперы ----------

func _tonemap_sheet() -> void:
	var cases := [
		{name = "aces", mode = 3, white = 6.0, exposure = 1.0},
		{name = "agx", mode = 4, white = float(Dev.arg("agx-white", "16.29")), contrast = float(Dev.arg("agx-contrast", "1.0")), exposure = float(Dev.arg("agx-exposure", "1.0"))},
		{name = "filmic", mode = 2, white = 6.0, exposure = float(Dev.arg("filmic-exposure", "1.0"))},
	]
	var keys := []
	var sat := float(Dev.arg("agx-sat", "1.0"))
	VisualStyle.configure({grade = false, depth = false, highlights = false, grain = false}, VisualStyle.DEFAULT_AMOUNT)
	for state: String in ["noon_meadow", "sunset", "mountains", "water"]:
		for case: Dictionary in cases:
			_place(state)
			env.tonemap_mode = case.mode
			env.tonemap_white = case.white
			if case.has("contrast"):
				env.tonemap_agx_white = case.white
				env.tonemap_agx_contrast = case.contrast
			env.tonemap_exposure *= case.exposure
			if case.name != "aces":
				env.adjustment_saturation *= sat
			var img := await _grab()
			var key := "%s/%s" % [state, case.name]
			images[key] = img
			img.save_png(ProjectSettings.globalize_path(out).path_join("tm_%s_%s.png" % [state, case.name]))
			var row := _measure(img)
			print("STYLE_TM ", key, " ", JSON.stringify(row))
			keys.append(key)
	_sheet(keys, 3, Vector2i(640, 360), "tonemap_sheet.png")


# ---------- проверки ----------

func _checks() -> void:
	# Кадры для сравнения без анимации (ветер, облака): небо над лугом при неподвижном времени
	var sky_view := {pos = views.meadow.pos + Vector3(0, 30, 0), target = views.meadow.pos + Vector3(0, 90, -40)}
	camera.look_at_from_position(sky_view.pos, sky_view.target)
	cycle.cloud_cover_override = 0.3
	cycle.apply(13.0, 40.0)
	# 1. Тождественный LUT не должен менять кадр: сравнение с кадром без LUT
	VisualStyle.configure({grade = false, depth = false, highlights = false, grain = false}, VisualStyle.DEFAULT_AMOUNT)
	var plain := await _grab()
	env.adjustment_color_correction = VisualStyle._build_lut(0.0)
	var identity := await _grab()
	var diff := _diff(plain, identity)
	print("STYLE_CHECK identity_lut mean=", diff.mean, " max=", diff.max)
	_check(diff.mean <= 0.004, "тождественный LUT не меняет кадр (в среднем %.4f)" % diff.mean)
	# 2. Выключение возвращает кадр: вариант all → off даёт тот же кадр, что и «чистый»
	_set_variant("all")
	await _grab()
	_set_variant("off")
	var again := await _grab()
	var back := _diff(plain, again)
	print("STYLE_CHECK off_restores mean=", back.mean, " max=", back.max)
	_check(back.max <= 0.012, "после выключения кадр прежний (max %.4f)" % back.max)
	_check(env.adjustment_color_correction == null and env.tonemap_mode == VisualStyle.TONEMAP_ACES, "выключено: LUT снят, тонмаппер ACES")
	# 3. Зерно неподвижно: два кадра подряд с зерном (небо без анимации) совпадают, без зерна отличаются на амплитуду зерна
	VisualStyle.configure({grade = false, depth = false, highlights = false, grain = false}, VisualStyle.DEFAULT_AMOUNT)
	var no_grain := await _grab()
	VisualStyle.configure({grade = false, depth = false, highlights = false, grain = true}, {grain = 1.0})
	var grain_a := await _grab()
	var grain_b := await _grab()
	var still := _diff(grain_a, grain_b)
	var amp := _diff(no_grain, grain_a)
	print("STYLE_CHECK grain_still mean=", still.mean, " max=", still.max, " amplitude mean=", amp.mean, " max=", amp.max)
	_check(still.max <= 0.004, "зерно не меняется во времени (max %.4f)" % still.max)
	_check(amp.max > 0.004 and amp.max < 0.05, "зерно едва заметно (макс. отклонение %.4f)" % amp.max)
	# 4. Ход камеры: время кадра off и all. Варианты чередуются каждый кадр (дрейф видеокарты поровну в обоих), камера идёт медленно
	# (5 см на кадр): раскладка растительности не перестраивается. Кадр считается после реальной отрисовки, без ограничения частоты.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var frames := {off = PackedFloat32Array(), all = PackedFloat32Array()}
	var last := Time.get_ticks_usec()
	var v: Dictionary = views.forest
	for i in 100:
		var variant := "off" if i % 2 == 0 else "all"
		_set_variant(variant)
		camera.look_at_from_position(v.pos + Vector3(0, 0, -0.05 * i), v.target + Vector3(0, 0, -0.05 * i))
		cycle.apply(7.3, 40.0)
		vegetation.update(camera.position.x, camera.position.z, false)
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		if i >= 8:
			frames[variant].append((now - last) / 1000.0)
		last = now
	var timing := {}
	for variant: String in frames:
		var times: PackedFloat32Array = frames[variant]
		times.sort()
		timing[variant] = {median_ms = snappedf(times[times.size() / 2], 0.1), p90_ms = snappedf(times[int(times.size() * 0.9)], 0.1), frames = times.size()}
	print("STYLE_CHECK motion ", JSON.stringify(timing))
	FileAccess.open(ProjectSettings.globalize_path(out).path_join("style_checks.json"), FileAccess.WRITE).store_string(JSON.stringify(timing, "\t"))


func _diff(a: Image, b: Image) -> Dictionary:
	var total := 0.0
	var worst := 0.0
	var n := 0
	for y in range(0, a.get_height(), 3):
		for x in range(0, a.get_width(), 3):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b)))
			total += d
			worst = maxf(worst, d)
			n += 1
	return {mean = snappedf(total / n, 0.00001), max = snappedf(worst, 0.00001)}
