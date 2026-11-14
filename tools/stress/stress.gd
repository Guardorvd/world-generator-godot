extends SceneTree
## Стресс-тест производительности: один запуск, короткие замеры по 1,5–4 с, отчёт JSON + Markdown и сравнение с базой.
## Нужно окно. Графику и игру не меняет: всё через готовые настройки и видимость узлов, после замера возвращается.
##   godot --path . --script res://tools/stress/stress.gd -- [ключи]
## Группы (--groups base,forest,world | all; по умолчанию base,forest — без мира, около минуты):
##   base   — пустая сцена: пол движка, точка отсчёта.
##   forest — изолированный лес 1 км без генерации (как tools/forest_scene_perf.gd): на месте, езда 16 м/с, полёт 60 м/с,
##            резкие переносы, поочерёдное отключение (тени, тени дальних уровней LOD, трава и подлесок, половинное
##            разрешение), вид с высоты 60 м. С ключом --dense ещё лес вдвое гуще по заявке (+15 с; правило отступов
##            крон оставляет от удвоения около +25 % деревьев, поэтому по умолчанию не меряется).
##   world  — настоящая игра на одном мире (--world, по умолчанию Север-1234). Мир берётся из своего кэша
##            tools/control/runs/stress/world_cache; генерация — только в первый раз. Кэш и сохранения игрока не трогаются,
##            настройки — по умолчанию, а не из профиля. Четыре вида, поочерёдное отключение систем в лесу, рассвет
##            и ночь, езда по дороге, быстрый пролёт, переносы, игра без паузы, память после выгрузки мира.
## Ключи: --only <часть имени,…> — только эти замеры; --out <папка> (по умолчанию tools/control/runs/stress);
##   --save-base — записать этот прогон как базу (base.json); без ключа прогон сравнивается с base.json, если она есть;
##   --compare <база.json> <новый.json> — только сравнить два отчёта (окно не нужно, ничего не меряется).
## Итог: stress.json (все числа), stress.md (выводы и таблицы), строка STRESS_RESULT в консоли. Код 1 — прогон не завершён.
## Отчёт пишется после каждого замера: при зависании остаётся всё снятое. Лимит: 150 с без мира, 420 с с миром.

const Dev := preload("res://tools/control/control.gd")
const Report := preload("res://tools/stress/stress_report.gd")
const Fixture := preload("res://tools/vegetation_test.gd")
const Lighting := preload("res://scripts/render/lighting_quality.gd")
const WARM := 0.5        # с: прогрев перед замером (шейдеры, догрузка), не считается
const HOLD := 2.0        # с: замер на месте
const MOVE := 4.0        # с: замер в движении
const TOGGLE := 1.5      # с: замер одного отключения
const GROUND := 25.8     # высота земли лесной фикстуры, м
const SADDLE := 1.6      # глаза седока над землёй, м
const DONORS := ["res://tools/control/runs/network_game_cache", "user://world_cache"]

var args := OS.get_cmdline_user_args()
var out := ""
var only: PackedStringArray
var report := {tool = "stress", format = 1, cases = [], ablation = {}, memory = {}, failed = [], groups = []}
var started := 0
var clock := 0.0
var beat := 0            # когда шёл последний кадр прогона: если он встал на ошибке скрипта, _process закрывает отчёт
var closed := false
var case_end := 0        # когда кончился прошлый замер: время подготовки между замерами идёт в setup_s
# лес
var veg: VegetationLayer
var camera: Camera3D
var hide_details := false
var eye := SADDLE         # высота камеры над землёй в лесу, м
var far_shadows := {}     # узел дальнего уровня LOD -> его прежняя настройка тени
var spike_cause: Callable # что сказать о длинном кадре: самая дорогая группа подгрузки и фаза растительности
# мир
var main: Node
var game: GameWorld
var hour := 12.0
var road: PackedVector3Array = []
var road_len: PackedFloat32Array = []


func _initialize() -> void:
	var groups := _groups()
	preload("res://tools/watchdog.gd").arm(self, 30.0 if "--compare" in args else (420.0 if "world" in groups else 150.0))
	_run.call_deferred(groups)


func _groups() -> Array:
	var g := Dev.arg("groups", "base,forest")
	return ["base", "forest", "world"] if g == "all" else Array(g.split(",", false))


func _run(groups: Array) -> void:
	var k := args.find("--compare")
	if k >= 0:
		var base: Variant = Dev.load_json(Dev.abs_dir(args[k + 1])) if k + 2 < args.size() else null
		var now: Variant = Dev.load_json(Dev.abs_dir(args[k + 2])) if k + 2 < args.size() else null
		if base == null or now == null:
			printerr("Нужны два отчёта: --compare <база.json> <новый.json>")
			quit(1)
			return
		var c := Report.compare(base, now)
		print(c.text)
		for w: String in c.warnings:
			print("⚠ ", w)
		quit(0)
		return
	started = Time.get_ticks_msec()
	out = Dev.abs_dir(Dev.arg("out", "res://tools/control/runs/stress"))
	DirAccess.make_dir_recursive_absolute(out)
	if not FileAccess.file_exists(out.path_join(".gdignore")):
		FileAccess.open(out.path_join(".gdignore"), FileAccess.WRITE)
	only = Dev.arg("only", "").split(",", false)
	# одинаковые условия: окно 1280×720, без вертикальной синхронизации и ограничения кадров
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Dev.WINDOW_SIZE)
	_unlock_frames()
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var git := []
	OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "rev-parse", "--short", "HEAD"], git)
	var dirty := []
	OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "status", "--porcelain", "--untracked-files=no"], dirty)
	report.version = Dev.version()
	report.commit = (git[0] as String).strip_edges() if git.size() > 0 else "?"
	report.dirty = dirty.size() > 0 and not (dirty[0] as String).strip_edges().is_empty()
	report.date = Time.get_datetime_string_from_system(false, true)
	report.groups = groups
	report.args = " ".join(args)
	report.machine = {gpu = RenderingServer.get_video_adapter_name(), cpu = OS.get_processor_name(), threads = OS.get_processor_count(),
		os = OS.get_name(), renderer = RenderingServer.get_current_rendering_method(), window = "%d×%d" % [Dev.WINDOW_SIZE.x, Dev.WINDOW_SIZE.y],
		debug = OS.is_debug_build(), dotnet = Grid.fast_grid() != null}
	await _frames(5)
	_memory("start", "Начало")
	if "base" in groups:
		await _group_base()
	if "forest" in groups:
		await _group_forest()
	if "world" in groups:
		await _group_world()
	if "base" in groups and report.cases.size() > 1:
		# та же пустая сцена в конце: если числа разошлись, машина была занята чем-то ещё
		spike_cause = Callable()
		var scene := _stage(false)
		await _case("base.calib_end", "Пустая сцена в конце (шум машины)", HOLD)
		scene.queue_free()
	_memory("end", "Конец прогона")
	_finish()


## Ошибка скрипта обрывает прогон молча, и процесс ждал бы сторожевой таймер: через 20 с без кадров прогона
## отчёт закрывается с тем, что снято, и кодом 1.
func _process(_delta: float) -> bool:
	if beat > 0 and not closed and Time.get_ticks_msec() - beat > 20000:
		report.failed.append("прогон оборвался после замера %s: ошибка скрипта, см. вывод" % (report.cases[-1].name if not report.cases.is_empty() else "—"))
		_finish()
	return false


func _finish() -> void:
	closed = true
	report.duration_s = snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.1)
	report.findings = Report.findings(report)
	var comparison := {}
	var base: Variant = Dev.load_json(out.path_join("base.json"))
	if base is Dictionary and not "--save-base" in args:
		comparison = Report.compare(base, report)
		report.comparison = {base_commit = base.get("commit", "?"), rows = comparison.rows, warnings = comparison.warnings}
	Dev.save_json(out.path_join("stress.json"), report)
	if "--save-base" in args:
		Dev.save_json(out.path_join("base.json"), report)
	FileAccess.open(out.path_join("stress.md"), FileAccess.WRITE).store_string(Report.markdown(report, comparison))
	print("\nВыводы:")
	for f: String in report.findings:
		print("  • ", f)
	for w: String in comparison.get("warnings", []):
		print("  ⚠ ", w)
	if not comparison.is_empty() and comparison.warnings.is_empty():
		print("  Против базы (%s) хуже шума ничего нет." % report.comparison.base_commit)
	print("STRESS_RESULT ", JSON.stringify({ok = report.failed.is_empty(), cases = report.cases.size(), seconds = report.duration_s,
		regressions = comparison.get("warnings", []).size(), failed = report.failed, json = out.path_join("stress.json"), md = out.path_join("stress.md")}))
	if GameContext.scope.cache.enabled:
		GameContext.scope.cache.wait_writes()
	quit(0 if report.failed.is_empty() else 1)


# ---------- общее ----------

func _unlock_frames() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0


func _frames(n: int) -> void:
	for i in n:
		beat = Time.get_ticks_msec()
		await process_frame


func _wanted(name: String) -> bool:
	if only.is_empty():
		return true
	for part in only:
		if name.contains(part):
			return true
	return false


func _memory(key: String, title: String) -> void:
	var pm := Dev.process_memory()
	report.memory[key] = {title = title, rss_mb = snappedf(pm.rss / 1048576.0, 0.1), peak_rss_mb = snappedf(pm.peak / 1048576.0, 0.1),
		video_mb = snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		static_mb = snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		objects = int(Performance.get_monitor(Performance.OBJECT_COUNT)), nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))}


## Кадры в течение seconds; step(t, dt) — что делать в каждом кадре (камера, подгрузка), его время идёт в work_ms.
func _sample(seconds: float, step: Callable, keep: bool) -> Dictionary:
	var vp := root.get_viewport_rid()
	beat = Time.get_ticks_msec() # долгая синхронная подготовка перед замером — не остановка
	var ms := PackedFloat32Array()
	var gpu := PackedFloat32Array()
	var cpu := PackedFloat32Array()
	var work := PackedFloat32Array()
	var calls := 0.0
	var prims := 0.0
	var logic := 0.0
	var physics := 0.0
	var spikes: Array = []
	var began := Time.get_ticks_usec()
	var last := began
	var dt := 1.0 / 60.0
	while Time.get_ticks_usec() - began < seconds * 1000000.0:
		var w0 := Time.get_ticks_usec()
		if step.is_valid():
			step.call((w0 - began) / 1000000.0, dt)
		var worked := (Time.get_ticks_usec() - w0) / 1000.0
		await process_frame
		var now := Time.get_ticks_usec()
		beat = Time.get_ticks_msec()
		dt = (now - last) / 1000000.0
		clock += dt
		last = now
		if keep:
			ms.append(dt * 1000.0)
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
			cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp))
			if step.is_valid():
				work.append(worked)
			calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
			logic += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			# длинный кадр — с причиной: счётчики подгрузки ещё хранят этот кадр
			if dt > 0.0167 and spike_cause.is_valid() and spikes.size() < 64:
				spikes.append({t = snappedf((now - began) / 1000000.0, 0.01), ms = snappedf(dt * 1000.0, 0.1), work_ms = snappedf(worked, 0.1), cause = spike_cause.call()})
	if not keep:
		return {}
	var out := Report.stats(ms, gpu, cpu, work, calls, prims)
	if out.frames > 0:
		out.process_ms = snappedf(logic / out.frames, 0.01)
		out.physics_ms = snappedf(physics / out.frames, 0.01)
		spikes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.ms > b.ms)
		out.worst = spikes.slice(0, 5)
	return out


## Один замер: прогрев, замер, запись в отчёт. Пустой словарь — замер не выбран ключом --only.
func _case(name: String, title: String, seconds: float, step := Callable(), extra := {}, always := false) -> Dictionary:
	if not always and not _wanted(name):
		return {}
	var warm := await _sample(WARM, step, true)
	var setup_s := snappedf((Time.get_ticks_msec() - (case_end if case_end > 0 else started)) / 1000.0, 0.1)
	var c := await _sample(seconds, step, true)
	case_end = Time.get_ticks_msec()
	c.setup_s = setup_s
	c.cold_max_ms = warm.ms.max if warm.get("frames", 0) > 0 else 0.0 # худший кадр прогрева: шейдеры и первая догрузка
	c.name = name
	c.title = title
	c.group = name.get_slice(".", 0)
	c.seconds = seconds
	c.video_mb = snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1)
	c.nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	c.merge(extra)
	report.cases.append(c)
	print("%-24s %6.0f FPS  1%% %5.0f  p99 %6.1f мс  худший %6.1f мс  GPU %5.1f мс  вызовов %5d  %s" % [name, c.fps, c.low1_fps, c.ms.p99,
		c.ms.max, c.gpu_ms, c.draw_calls, c.bound])
	Dev.save_json(out.path_join("stress.json"), report)
	return c


## Ждёт, пока растительность догрузит раскладку (от least до most секунд): замер на месте не должен захватить
## догрузку. Возвращает, сколько ждал; most — значит, не дождался.
func _settle(layer: VegetationLayer, step: Callable, least := 0.2, most := 2.0) -> float:
	var t0 := Time.get_ticks_msec()
	await _sample(least, step, false)
	while not layer.placement_ready() and Time.get_ticks_msec() - t0 < most * 1000.0:
		await _sample(0.1, step, false)
	return snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)


## Поочерёдное отключение: toggles — [имя, название, выключить, вернуть]. Выигрыш — к замеру base по медиане кадра.
func _ablate(key: String, title: String, prefix: String, base: Dictionary, toggles: Array, step: Callable, layer: VegetationLayer) -> void:
	if base.is_empty():
		return
	var items: Array = []
	for t: Array in toggles:
		if not _wanted(prefix + t[0]):
			continue
		var t0 := Time.get_ticks_usec()
		t[2].call()
		var apply_ms := snappedf((Time.get_ticks_usec() - t0) / 1000.0, 0.1) # задержка самой смены настройки
		await _settle(layer, step)
		var c := await _case(prefix + t[0], "%s: без «%s»" % [title, t[1]], TOGGLE, step)
		t[3].call()
		await _settle(layer, step)
		items.append({name = t[0], title = t[1], frame_ms = c.ms.p50, gain_ms = snappedf(base.ms.p50 - c.ms.p50, 0.01),
			gpu_gain_ms = snappedf(base.gpu_ms - c.gpu_ms, 0.01), fps = c.fps, apply_ms = apply_ms})
	if not items.is_empty():
		report.ablation[key] = {title = title, base = base.name, base_ms = base.ms.p50, base_gpu_ms = base.gpu_ms, items = items}


# ---------- пустая сцена ----------

func _group_base() -> void:
	var scene := _stage(false)
	await _case("base.empty", "Пустая сцена", HOLD)
	scene.queue_free()
	await _frames(2)


## Земля, солнце, небо одним цветом и камера — как в forest_scene_perf
func _stage(shadows: bool) -> Node3D:
	var scene := Node3D.new()
	root.add_child(scene)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1024, 1024)
	ground.mesh = plane
	ground.position = Vector3(512, GROUND, 512)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.45, 0.2)
	ground.material_override = mat
	scene.add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.shadow_enabled = shadows
	Lighting.apply_shadows(sun, 1) # 15.1: каскады теней как в игре (среднее качество), а не по умолчанию движка
	scene.add_child(sun)
	var sky := WorldEnvironment.new()
	sky.environment = Environment.new()
	sky.environment.background_mode = Environment.BG_COLOR
	sky.environment.background_color = Color(0.5, 0.65, 0.85)
	sky.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	sky.environment.ambient_light_color = Color.WHITE
	sky.environment.ambient_light_energy = 0.5
	scene.add_child(sky)
	camera = Camera3D.new()
	camera.far = 500
	scene.add_child(camera)
	camera.current = true
	camera.look_at_from_position(Vector3(512, GROUND + SADDLE, 340), Vector3(512, GROUND + 1.0, 420), Vector3.UP)
	return scene


# ---------- изолированный лес ----------

func _group_forest() -> void:
	var scene := _stage(true)
	var sun: DirectionalLight3D = scene.get_node("Sun")
	spike_cause = func() -> String: return _phase_cause(veg)
	var still := func(_t: float, dt: float) -> void: _forest_at(340.0, dt)
	var ride := func(t: float, dt: float) -> void: _forest_at(340.0 + t * 16.0, dt)
	for density: float in [1.0, 2.0]:
		if density == 2.0 and (not "--dense" in args or not _wanted("forest.dense")):
			continue
		var t0 := Time.get_ticks_msec()
		var world := _forest(density)
		veg = VegetationLayer.new()
		scene.add_child(veg)
		veg.setup(world, Heightfield.new(world, false), Models.tree_defs(), Models.grass_mesh())
		veg.update(512.0, 340.0, true)
		var extra := {objects = world.obj_count, build_ms = Time.get_ticks_msec() - t0}
		await _settle(veg, still)
		if density == 1.0:
			var base := await _case("forest.still", "Лес: на месте", HOLD, still, extra)
			# Отключения — сразу после базы, до движения: после переносов тот же вид рисуется иначе
			# (15.0: +17 % вызовов), и сравнение с базой до переносов врало.
			await _ablate("forest", "Лес", "forest.off_", base, [
				["shadows", "тени", func() -> void: sun.shadow_enabled = false, func() -> void: sun.shadow_enabled = true],
				["shadows_far", "тени дальних уровней LOD", _far_shadows.bind(false), _far_shadows.bind(true)],
				["details", "трава и подлесок", _details.bind(false), _details.bind(true)],
				["half_res", "половина разрешения", func() -> void: root.scaling_3d_scale = 0.5, func() -> void: root.scaling_3d_scale = 1.0],
			], still, veg)
			await _case("forest.ride", "Лес: езда 16 м/с", MOVE, ride)
			await _case("forest.fast", "Лес: полёт 60 м/с", MOVE, func(t: float, dt: float) -> void: _forest_at(340.0 + t * 60.0, dt))
			await _case("forest.jump", "Лес: перенос на 300 м раз в секунду", MOVE, func(t: float, dt: float) -> void: _forest_at([220.0, 520.0, 800.0, 380.0][int(t) % 4], dt))
			await _settle(veg, still) # вернуться к исходному месту и дождаться раскладки
			# Тот же вид, что база: вызовы и треугольники должны совпасть с «на месте»
			await _case("forest.back", "Лес: на месте после переездов", HOLD, still)
			eye = 60.0 # вид с возвышенности: в кадре весь лес до дальности прорисовки
			await _settle(veg, still)
			await _case("forest.high", "Лес: с высоты 60 м", HOLD, still)
			eye = SADDLE
		else:
			await _settle(veg, still)
			await _case("forest.dense_still", "Лес вдвое гуще: на месте", HOLD, still, extra)
			await _case("forest.dense_ride", "Лес вдвое гуще: езда 16 м/с", MOVE, ride)
		veg.queue_free()
		veg = null
		await _frames(3)
	scene.queue_free()
	await _frames(3)


## Трава и подлесок: прячутся в каждом кадре (_forest_at), возвращаются полной раскладкой
func _details(on: bool) -> void:
	hide_details = not on
	if on:
		veg.update(512.0, 340.0, true)


func _forest_at(z: float, dt: float) -> void:
	camera.look_at_from_position(Vector3(512, GROUND + eye, z), Vector3(512, GROUND + 1.0, z + 80.0 + eye * 3.0), Vector3.UP)
	veg.update(512.0, z, false, dt)
	if hide_details:
		veg.grass.visible_instance_count = 0
		for e: Dictionary in veg.understory:
			e.mm.visible_instance_count = 0


## Тени деревьев дальних уровней LOD (уровень 1 и дальше): выключить и вернуть как было
func _far_shadows(on: bool) -> void:
	if on:
		for node: Variant in far_shadows:
			if is_instance_valid(node):
				node.cast_shadow = far_shadows[node]
		far_shadows.clear()
		return
	for key: Vector3i in veg.veg:
		for node: MultiMeshInstance3D in veg.veg[key].nodes:
			if int(node.get_meta("level", -1)) >= 1:
				far_shadows[node] = node.cast_shadow
				node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Самая дорогая фаза слоя растительности в последнем кадре
func _phase_cause(layer: VegetationLayer) -> String:
	var last: Array = layer.phase_stats.last_us
	var k := last.find(last.max())
	return "растительность/%s %.1f мс" % [layer.phase_stats.names[k], last[k] / 1000.0]


## Самая дорогая группа подгрузки в последнем кадре и фаза растительности в нём же
func _stream_cause() -> String:
	var stats: Dictionary = game.stream_coordinator.stats
	var last: Array = stats.group_last_us
	var k := last.find(last.max())
	var at := game.camera.global_position
	return "%s %.1f мс; %s; камера %d, %d" % [stats.group_names[k], last[k] / 1000.0, _phase_cause(game.vegetation), at.x, at.z]


## Цена выборок высоты (их зовёт физика велосипеда каждый подшаг): мкс на вызов по 20 тыс. вызовов у дороги
func _micro() -> void:
	var hf := game.heights
	var out := {}
	for name: String in ["ground_at", "surface_at", "depth_at", "passable"]:
		var t0 := Time.get_ticks_usec()
		for i in 20000:
			var p := road[i % road.size()]
			var x := p.x + (i % 37) * 0.7
			var z := p.z + (i % 41) * 0.7
			match name:
				"ground_at": hf.ground_at(x, z)
				"surface_at": hf.surface_at(x, z, INF)
				"depth_at": hf.depth_at(x, z, p.y)
				# проверка габарита, которую велосипед зовёт трижды на каждую примерку положения (BikeRide.fits)
				"passable": PlayerState.is_passable(game.world, hf, x, z, p.y, BikeRide.BODY_R, false, 0.0, false)
		out[name + "_us"] = snappedf((Time.get_ticks_usec() - t0) / 20000.0, 0.01)
	report.micro = out


## Дальность (draw) и качество (flora) растительности теми же вызовами, что меню настроек; -1 — не менять
func _veg_level(layer: VegetationLayer, draw: int, flora: int) -> void:
	var changed := false
	if draw >= 0:
		changed = layer.set_draw(draw) or changed
	if flora >= 0:
		changed = layer.set_flora(flora) or changed
	if changed:
		layer.update(game.camera.global_position.x, game.camera.global_position.z, true)


## Смешанный лес древостоями, как в генерации (копия фикстуры tools/forest_scene_perf.gd)
func _forest(density: float) -> WorldData:
	var w: WorldData = Fixture.fixture(0)
	w.biome.fill(Biomes.FOREST)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var kinds := [Biomes.T_OAK, Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_PINE]
	var store := StageVegetation.ObjStore.new(null)
	for cy in range(0, 256, w.CS):
		for cx in range(0, 256, w.CS):
			store.begin_chunk(cx, cy, cx + w.CS, cy + w.CS)
			for y in range(maxi(cy, 8), mini(cy + w.CS, 248)):
				for x in range(maxi(cx, 8), mini(cx + w.CS, 248)):
					for k in 2:
						if rng.randf() >= 0.6 * density:
							continue
						var px := x + 0.1 + rng.randf() * 0.8
						var py := y + 0.1 + rng.randf() * 0.8
						var kind: int = kinds[rng.randi() % kinds.size()]
						var age := clampf(0.55 + 0.5 * sin(px * 0.11) * sin(py * 0.083 + 1.3), 0.0, 1.0)
						var form := StageVegetation.tree_form(age, 1.0, 0.0, 0.6, 0.0, rng.randf())
						store.add(px, py, kind, rng.randi() % 3 + 3 * int(form.y), form.x)
	for o in store.x.size():
		w.obj_x.append(store.x[o])
		w.obj_y.append(store.y[o])
		w.obj_k.append(store.k[o])
		w.obj_v.append(store.v[o])
		w.obj_s.append(store.s[o])
		w.chunks[(int(store.y[o]) / w.CS) * w.CW + int(store.x[o]) / w.CS].append(o)
	w.obj_count = w.obj_x.size()
	return w


# ---------- настоящая игра ----------

func _group_world() -> void:
	var seed_text := Dev.arg("world", "Север-1234")
	var size := WorldGenerator.START_SIZE
	var settings := GameContext.scope.settings
	# настройки — по умолчанию и в своём файле: профиль игрока не читается и не пишется
	settings.settings_path = out.path_join("settings.cfg")
	preload("res://scripts/game/opening_route.gd").fixed_seed = 1
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(3)
	DisplayServer.window_set_size(Dev.WINDOW_SIZE)
	_unlock_frames()
	# свой кэш мира: первый раз мир генерируется (или берётся готовый из папок DONORS), дальше грузится из кэша
	var cache := GameContext.scope.cache
	cache.dir = out.path_join("world_cache")
	cache.enabled = true
	settings.recent_seeds.assign([seed_text]) # иначе keep_only сотрёт кэш этого мира перед загрузкой
	_seed_cache(cache, seed_text, size)
	var cached := cache.has(seed_text, size)
	_memory("menu", "Меню")
	print("Мир %s@%d: %s" % [seed_text, size, "из кэша" if cached else "генерация (один раз)"])
	var t0 := Time.get_ticks_msec()
	main.start_game(seed_text, size)
	while main.game == null or main.game.player == null or main.busy: # 15.1: main ещё держит заставку первые кадры
		await process_frame
		beat = Time.get_ticks_msec()
		if Time.get_ticks_msec() - t0 > 330000 or (not main.busy and main.game == null and Time.get_ticks_msec() - t0 > 3000):
			report.failed.append("мир %s не загрузился за %d с" % [seed_text, (Time.get_ticks_msec() - t0) / 1000])
			return
	game = main.game
	report.load = {seed = seed_text, size = size, cached = cached, load_s = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1), timings = game.load_timings.duplicate()}
	game.paused = true # игра стоит: камеру, сутки и подгрузку ведёт замер, как в tools/control/check.gd
	main.hud.visible = false
	if game.pause_requested.is_connected(main._toggle_pause):
		game.pause_requested.disconnect(main._toggle_pause)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if game._opening:
		game._finish_opening()
	game.camera.fov = 70.0
	_unlock_frames()
	_memory("loaded", "Мир загружен")
	var views := {}
	for v: Dictionary in Dev.views(game):
		views[v.name] = v
	_load_road(views.spawn.pos)
	_micro()
	spike_cause = _stream_cause

	# виды на месте: камера ставится с полной догрузкой окружения, как в check.gd (без неё числа гуляют:
	# штатная догрузка после переноса идёт дольше 3 с). Лес — последним: в нём же меряются отключения.
	var heavy := {}
	var heavy_view := {}
	for name: String in ["spawn", "village", "peak", "forest"]:
		var base_for_toggles := name == "forest" and (_wanted("world.off_") or _wanted("world.hour_"))
		if not views.has(name) or not (_wanted("world.view_" + name) or base_for_toggles):
			continue
		heavy_view = views[name]
		_place(heavy_view)
		heavy = await _case("world.view_" + name, "Мир: " + heavy_view.title, HOLD, _look.bind(heavy_view), {}, base_for_toggles)
		if "--shots" in args: # снимок вида для сравнения картинки до и после правки (view_<имя>.png в папке отчёта)
			root.get_texture().get_image().save_png(out.path_join("view_%s.png" % name))

	# что сколько стоит — в лесу (последний снятый вид), сразу после его замера
	if not heavy.is_empty():
		var step := _look.bind(heavy_view)
		var sun: DirectionalLight3D = game.get_node("Sun")
		var env: Environment = game.get_node("WorldEnvironment").environment
		var far: Array = get_nodes_in_group("distant_forest")
		var msaa := root.msaa_3d
		var relight := func() -> void: game._apply_lighting_and_fog()
		var low := func() -> void:
			Lighting.apply(env, sun, 0, false, 0)
			VisualStyle.configure({grade = false, depth = false, highlights = false, grain = false}, {})
			_veg_level(game.vegetation, 0, 0)
			game.ambient.visible = false
			root.msaa_3d = Viewport.MSAA_DISABLED
		var high := func() -> void:
			relight.call()
			_veg_level(game.vegetation, settings.draw, settings.flora)
			game.ambient.visible = true
			root.msaa_3d = msaa
		await _ablate("world", "Мир, вид «%s»" % heavy_view.title, "world.off_", heavy, [
			["shadows", "тени солнца", func() -> void: sun.shadow_enabled = false, relight],
			["lighting", "освещение и туман выше низкого", func() -> void: Lighting.apply(env, sun, 0, settings.shadows, 0), relight],
			# 15.1: «освещение» по частям — какая из них дорогая
			["cascades", "каскады теней как на низком (2 каскада, 110 м)", func() -> void: Lighting.apply_shadows(sun, 0), relight],
			["ssao", "затенение SSAO", func() -> void: env.ssao_enabled = false, relight],
			["vol_fog", "объёмный туман", func() -> void: env.volumetric_fog_enabled = false, relight],
			["style", "визуальный стиль", func() -> void: VisualStyle.configure({grade = false, depth = false, highlights = false, grain = false}, {}), relight],
			["msaa", "сглаживание MSAA", func() -> void: root.msaa_3d = Viewport.MSAA_DISABLED, func() -> void: root.msaa_3d = msaa],
			["half_res", "половина разрешения", func() -> void: root.scaling_3d_scale = 0.5, func() -> void: root.scaling_3d_scale = 1.0],
			["vegetation", "ближняя растительность", _show.bind([game.vegetation], false), _show.bind([game.vegetation], true)],
			["far_forest", "дальний лес", _show.bind(far, false), _show.bind(far, true)],
			["terrain", "рельеф", _show.bind([game.get_node("Terrain")], false), _show.bind([game.get_node("Terrain")], true)],
			["outer", "местность за краем области", _show.bind([game.outer, game.regions], false), _show.bind([game.outer, game.regions], true)],
			["water", "вода", _show.bind([game.get_node("Water")], false), _show.bind([game.get_node("Water")], true)],
			["buildings", "поселения и сооружения", _show.bind([game.get_node("Settlements"), game.get_node("Structures")], false),
				_show.bind([game.get_node("Settlements"), game.get_node("Structures")], true)],
			["particles", "частицы и местный туман", _show.bind([game.ambient, game.local_mist], false), _show.bind([game.ambient, game.local_mist], true)],
			["draw_min", "дальность растительности выше минимальной", func() -> void: _veg_level(game.vegetation, 0, -1), func() -> void: _veg_level(game.vegetation, settings.draw, -1)],
			["flora_low", "качество растительности выше низкого", func() -> void: _veg_level(game.vegetation, -1, 0), func() -> void: _veg_level(game.vegetation, -1, settings.flora)],
			["all_low", "все настройки выше минимума", low, high],
		], step, game.vegetation)
		for h: Array in [[6.5, "dawn", "рассвет"], [23.0, "night", "ночь"]]:
			hour = h[0]
			await _case("world.hour_" + h[1], "Мир: тот же вид, " + h[2], TOGGLE, step)
		hour = 12.0

	# движение: подгрузка рельефа, растительности и воды штатным планировщиком
	await _settle(game.vegetation, _ride.bind(0.0), 1.0, 3.0)
	await _case("world.ride", "Мир: езда по дороге %d м/с" % GameConfig.BIKE_SPEED, MOVE * 1.5, _ride.bind(GameConfig.BIKE_SPEED))
	await _case("world.fast", "Мир: пролёт по дороге %d м/с" % (GameConfig.BIKE_SPEED * 4), MOVE, _ride.bind(GameConfig.BIKE_SPEED * 4.0))
	var stops: Array = views.values()
	await _case("world.jump", "Мир: перенос в другое место раз в 1,5 с", MOVE * 1.5, func(t: float, dt: float) -> void: _look(t, dt, stops[int(t / 1.5) % stops.size()]))

	# игра без паузы: логика, физика, HUD и звук на стоящем игроке
	if _wanted("world.play_idle"):
		main.hud.visible = true
		game.paused = false
		game.tick_us.clear()
		var idle := await _case("world.play_idle", "Мир: игра без паузы, игрок стоит", HOLD)
		# такт физики и кадр игры по частям, мкс на такт / на кадр
		var parts := {}
		var ticks := maxi(1, int(game.tick_us.get("ticks", 0)))
		var frames := maxi(1, int(game.tick_us.get("frames", 0)))
		for k: String in game.tick_us:
			if k != "ticks" and k != "frames":
				parts[k] = snappedf(game.tick_us[k] / float(frames if k.begins_with("frame_") else ticks) / 1000.0, 0.01)
		idle.tick_parts_ms = parts
		print("TICK_PARTS ticks=%d frames=%d %s" % [ticks, frames, parts])
		game.paused = true
		main.hud.visible = false

	_memory("played", "После замеров в мире")
	main._free_game()
	game = null
	await _frames(30)
	_memory("after_free", "Мир выгружен")


## Готовые слои этого мира из других папок кэша, если своих ещё нет: чтение чужого кэша, запись только в свой
func _seed_cache(cache: WorldCache, seed_text: String, size: int) -> void:
	var prefix := cache._base(seed_text, size) + "."
	DirAccess.make_dir_recursive_absolute(cache.dir)
	for f in DirAccess.get_files_at(cache.dir):
		if f.begins_with(prefix):
			return
	for donor: String in DONORS:
		var dir := ProjectSettings.globalize_path(donor)
		var copied := 0
		for f in DirAccess.get_files_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray():
			if f.begins_with(prefix) and DirAccess.copy_absolute(dir.path_join(f), cache.dir.path_join(f)) == OK:
				copied += 1
		if copied > 0:
			print("Кэш мира взят из %s (%d файлов)" % [donor, copied])
			return


func _show(nodes: Array, on: bool) -> void:
	for n: Variant in nodes:
		if n != null and is_instance_valid(n):
			n.visible = on


## Камера в вид с полной догрузкой окружения (до замера)
func _place(v: Dictionary) -> void:
	game.camera.look_at_from_position(v.pos, v.target, Vector3.UP)
	game.vegetation.update(v.pos.x, v.pos.z, true)
	game.terrain_stream.update(v.pos.x, v.pos.z, true)
	if game.world.outer != null:
		game.outer.preload_around(v.pos.x, v.pos.z)


## Кадр игры на паузе: то же, что GameWorld._process делает для картинки — сутки, подгрузка, частицы, туман, море
func _look(_t: float, dt: float, v: Dictionary) -> void:
	game.camera.look_at_from_position(v.pos, v.target, Vector3.UP)
	game.hour = hour
	game.day.apply(hour, clock)
	game.stream_coordinator.update(v.pos)
	game.ambient.update(dt, v.pos, game.day.sunlight)
	game.local_mist.update(v.pos, game.day, dt, clock)
	if game._ocean != null:
		game._ocean.position = Vector3(v.pos.x, 0.0, v.pos.z)


func _ride(t: float, dt: float, speed: float) -> void:
	_look(t, dt, {pos = _road_eye(t * speed), target = _road_eye(t * speed + 15.0)})


## Самая длинная дорога мира в метрах; если дорог нет — прямая на север от точки появления
func _load_road(spawn: Vector3) -> void:
	var best: Array = []
	var best_n := 0.0
	for tr in game.world.trails:
		if tr.kind == "road" and Dev.path_length(tr.pts) > best_n:
			best_n = Dev.path_length(tr.pts)
			best = tr.pts
	if best.size() < 2:
		best = [{x = spawn.x / Dev.TILE, y = spawn.z / Dev.TILE}, {x = spawn.x / Dev.TILE, y = spawn.z / Dev.TILE - 200.0}]
	var acc := 0.0
	for k in best.size():
		var p := Vector3((best[k].x + 0.5) * Dev.TILE, 0.0, (best[k].y + 0.5) * Dev.TILE)
		if k > 0:
			acc += Vector2(p.x - road[k - 1].x, p.z - road[k - 1].z).length()
		road.append(p)
		road_len.append(acc)


## Глаза седока в s метрах от начала дороги (туда и обратно, если дорога короче): на настиле моста, над водой брода
func _road_eye(s: float) -> Vector3:
	var total := road_len[road_len.size() - 1]
	s = fmod(s, 2.0 * total)
	if s > total:
		s = 2.0 * total - s
	var k := 1
	while k < road_len.size() - 1 and road_len[k] < s:
		k += 1
	var p := road[k - 1].lerp(road[k], clampf((s - road_len[k - 1]) / maxf(0.001, road_len[k] - road_len[k - 1]), 0.0, 1.0))
	var hf := game.heights
	p.y = maxf(hf.surface_at(p.x, p.z, INF), hf.ground_at(p.x, p.z) + hf.depth_at(p.x, p.z)) + GameConfig.EYE
	return p
