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
##   --travel-from-map — начать перенос с открытым атласом и проверить его закрытие при прибытии.
##   --fullscreen — весь экран вместо окна 1280×720; --settings <файл> — настройки игрока (копия, файл не меняется).
##   20.11: world.off_res_90/res_80 — шаги адаптивного разрешения, world.res_switch — цена смены разрешения.
## 20.11.2026: world.board — сборка щита доски у камеры (с отбором заданий), OFFERS_MS —
##   цена отбора заданий по частям; world.play_map — карта (M) открывается и закрывается в игре без паузы.
## Итог: stress.json (все числа), stress.md (выводы и таблицы), строка STRESS_RESULT в консоли. Код 1 — прогон не завершён.
## Отчёт пишется после каждого замера: при зависании остаётся всё снятое. Лимит: 150 с без мира, 540 с с миром.

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
var _chunk_seen := {}     # ChunkSource.stats на прошлом кадре (причины пиков)
var _quiet_particles := false # отключение «частицы»: _look не крутит их на CPU
var _night_lights := true # _look зовёт update_lights (костры, окна, гирлянды), как _process игры
var _process_probe: RefCounted # ProcessMetrics (C#): сборки мусора .NET между замерами; null — сборка без .NET


func _initialize() -> void:
	Heightfield.allow_native_ride = not "--no-native-ride" in args
	Heightfield.verify_native_ride = "--verify-ride" in args
	SettlementsBuilder.use_legacy = "--legacy-settlements" in args
	var groups := _groups()
	preload("res://tools/watchdog.gd").arm(self, 30.0 if "--compare" in args else (540.0 if "world" in groups else 150.0))
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
	_set_window()
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
		_unlock_frames()
		await _frames(5)
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


static func _pipeline_counts() -> Vector4i:
	return preload("res://scripts/core/frame_statistics.gd").pipeline_counts()


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
	var physics := 0.0
	var spikes: Array = []
	var peak_video := 0.0
	var began := Time.get_ticks_usec()
	var last := began
	var dt := 1.0 / 60.0
	var initial_pipelines := _pipeline_counts()
	var previous_pipelines := initial_pipelines
	var live := keep and game != null and not game.paused
	var previous_ticks: Dictionary = game.tick_us.duplicate() if live else {}
	while Time.get_ticks_usec() - began < seconds * 1000000.0:
		var w0 := Time.get_ticks_usec()
		if step.is_valid():
			step.call((w0 - began) / 1000000.0, dt)
		var worked := (Time.get_ticks_usec() - w0) / 1000.0
		_chunk_mark()
		await process_frame
		var now := Time.get_ticks_usec()
		beat = Time.get_ticks_msec()
		dt = (now - last) / 1000000.0
		clock += dt
		last = now
		if keep:
			var pipelines := _pipeline_counts()
			var compiled := pipelines - previous_pipelines
			previous_pipelines = pipelines
			ms.append(dt * 1000.0)
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
			cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp))
			if step.is_valid():
				work.append(worked)
			calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
			# TIME_PROCESS здесь не годится: скрипт прогона — сам SceneTree, монитор давал сотни и тысячи мс на кадр.
			# Работа кадра на CPU — work_ms (шаг прогона на паузе) или tick_us игры (замеры play_*).
			physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			peak_video = maxf(peak_video, Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
			# длинный кадр — с причиной: счётчики подгрузки ещё хранят этот кадр
			if dt > 0.0167 and spike_cause.is_valid() and (spikes.size() < 5 or dt * 1000.0 > spikes[-1].ms):
				var spike := {t = snappedf((now - began) / 1000000.0, 0.01), ms = snappedf(dt * 1000.0, 0.1), work_ms = snappedf(worked, 0.1),
					gpu_ms = snappedf(gpu[gpu.size() - 1], 0.1), cpu_ms = snappedf(cpu[cpu.size() - 1], 0.1),
					mesh_pipelines = compiled.x, surface_pipelines = compiled.y, draw_pipelines = compiled.z,
					canvas_pipelines = compiled.w, cause = spike_cause.call()}
				if live:
					var tick_parts := {}
					for part: String in game.tick_us:
						if part != "frames" and part != "ticks":
							tick_parts[part] = snappedf(float(game.tick_us[part] - previous_ticks.get(part, 0)) / 1000.0, 0.01)
					spike.tick_ms = tick_parts
					spike.physics_ticks = game.tick_us.get("ticks", 0) - previous_ticks.get("ticks", 0)
					if game.navigation_line != null:
						spike.navigation_us = game.navigation_line.timings_us.duplicate()
				spikes.append(spike)
				spikes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.ms > b.ms)
				if spikes.size() > 5: spikes.pop_back()
			if live:
				previous_ticks = game.tick_us.duplicate()
	if not keep:
		return {}
	var out := Report.stats(ms, gpu, cpu, work, calls, prims)
	if out.frames > 0:
		var compiled := previous_pipelines - initial_pipelines
		out.mesh_pipelines = compiled.x
		out.surface_pipelines = compiled.y
		out.draw_pipelines = compiled.z
		out.canvas_pipelines = compiled.w
		out.physics_ms = snappedf(physics / out.frames, 0.01)
		out.peak_video_mb = snappedf(peak_video / 1048576.0, 0.1)
		out.worst = spikes
	return out


## Один замер: прогрев, замер, запись в отчёт. Пустой словарь — замер не выбран ключом --only.
func _case(name: String, title: String, seconds: float, step := Callable(), extra := {}, always := false) -> Dictionary:
	if not always and not _wanted(name):
		return {}
	var pm0 := _dotnet()
	var warm := await _sample(WARM, step, true)
	var setup_s := snappedf((Time.get_ticks_msec() - (case_end if case_end > 0 else started)) / 1000.0, 0.1)
	var c := await _sample(seconds, step, true)
	case_end = Time.get_ticks_msec()
	c.setup_s = setup_s
	c.cold_max_ms = warm.ms.max if warm.get("frames", 0) > 0 else 0.0 # худший кадр прогрева: шейдеры и первая догрузка
	c.cold_mesh_pipelines = warm.get("mesh_pipelines", 0)
	c.cold_surface_pipelines = warm.get("surface_pipelines", 0)
	c.cold_draw_pipelines = warm.get("draw_pipelines", 0)
	c.cold_canvas_pipelines = warm.get("canvas_pipelines", 0)
	c.cold_worst = warm.get("worst", [])
	c.name = name
	c.title = title
	c.group = name.get_slice(".", 0)
	c.seconds = seconds
	c.video_mb = snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1)
	c.nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var pm1 := _dotnet()
	if not pm0.is_empty() and not pm1.is_empty():
		# прогрев + замер: сборки мусора .NET (C#-расчёты подгрузки) и их паузы
		c.dotnet = {gc0 = int(pm1.gc0) - int(pm0.gc0), gc1 = int(pm1.gc1) - int(pm0.gc1), gc2 = int(pm1.gc2) - int(pm0.gc2),
			alloc_mb = snappedf((float(pm1.managed_allocated_bytes) - float(pm0.managed_allocated_bytes)) / 1048576.0, 0.1),
			pause_ms = snappedf(float(pm1.get("gc_pause_ms", 0.0)) - float(pm0.get("gc_pause_ms", 0.0)), 0.01),
			heap_mb = snappedf(float(pm1.managed_heap_bytes) / 1048576.0, 0.1)}
	c.merge(extra)
	report.cases.append(c)
	print("%-24s %6.0f FPS  1%% %5.0f  p99 %6.1f мс  худший %6.1f мс  GPU %5.1f мс  вызовов %5d  %s" % [name, c.fps, c.low1_fps, c.ms.p99,
		c.ms.max, c.gpu_ms, c.draw_calls, c.bound])
	Dev.save_json(out.path_join("stress.json"), report)
	return c


## Счётчики процесса из C# (ProcessMetrics); пусто, если .NET нет
func _dotnet() -> Dictionary:
	if _process_probe == null and ClassDB.class_exists("CSharpScript"):
		var script: Variant = load("res://scripts/core/ProcessMetrics.cs")
		if script is Script and (script as Script).can_instantiate():
			_process_probe = script.new()
	return _process_probe.Capture() if _process_probe != null else {}


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
				# 16.11: тени ближних крон (уровень 0, их собственный меш с вырезами) — сколько вообще можно выиграть
				["crown0_shadow", "тени ближних крон", _near_crown_shadows.bind(veg, false), _near_crown_shadows.bind(veg, true)],
				["details", "трава и подлесок", _details.bind(false), _details.bind(true)],
				["half_res", "половина разрешения", func() -> void: root.scaling_3d_scale = 0.5, func() -> void: root.scaling_3d_scale = 1.0],
			] + _shadow_parts(sun, veg, func() -> void: Lighting.apply_shadows(sun, 1)), still, veg)
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


## Снимок вида для сравнения картинки до и после правки (view_<имя>.png в папке отчёта, ключ --shots).
## 15.11: --shot-atlas <размер> — ещё снимок того же кадра с другим атласом теней (view_<имя>_atlas<размер>.png).
func _shot(name: String, relight: Callable) -> void:
	if not "--shots" in args:
		return
	root.get_texture().get_image().save_png(out.path_join("view_%s.png" % name))
	var atlas := int(Dev.arg("shot-atlas", "0"))
	if atlas > 0:
		RenderingServer.directional_shadow_atlas_set_size(atlas, true)
		await _frames(4)
		root.get_texture().get_image().save_png(out.path_join("view_%s_atlas%d.png" % [name, atlas]))
		relight.call()
		await _frames(4)


## 15.11: части теней солнца для поочерёдного отключения; restore возвращает каскады уровня качества
func _shadow_parts(sun: DirectionalLight3D, under: Node, restore: Callable) -> Array:
	var bits := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/16_bits", true))
	var filter := int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 2))
	return [
		["shadow_150", "дальность теней 190 → 150 м", func() -> void: sun.directional_shadow_max_distance = 150.0, restore],
		["shadow_cascades2", "4 каскада → 2 той же дальности", func() -> void: sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, restore],
		["shadow_blend", "смешивание каскадов", func() -> void: sun.directional_shadow_blend_splits = false, restore],
		# среднее качество с 15.11 — атлас 2048 (lighting_quality.gd); вдвое меньше — сколько ещё стоит разрешение
		["shadow_atlas_half", "атлас теней 2048 → 1024", func() -> void: RenderingServer.directional_shadow_atlas_set_size(1024, bits), restore],
		["shadow_filter", "мягкий фильтр теней (жёсткие)", func() -> void: RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD),
			func() -> void: RenderingServer.directional_soft_shadow_filter_set_quality(filter)],
		["shadow_double", "двусторонние тени (односторонние)", _double_sided.bind(under, false), _double_sided.bind(under, true)],
	]


var _near_crowns := {}
## Тени ближних крон (узлы кроны уровня 0 с двусторонней тенью)
func _near_crown_shadows(under: Node, on: bool) -> void:
	if on:
		for node: Variant in _near_crowns:
			if is_instance_valid(node):
				node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		_near_crowns.clear()
		return
	for node: Node in under.find_children("*", "MultiMeshInstance3D", true, false):
		var g := node as GeometryInstance3D
		if g.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED and int(g.get_meta("level", -1)) == 0:
			_near_crowns[g] = true
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


var _double := {}
func _double_sided(under: Node, on: bool) -> void:
	if on:
		for node: Variant in _double:
			if is_instance_valid(node):
				node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		_double.clear()
		return
	for node: Node in under.find_children("*", "GeometryInstance3D", true, false):
		var g := node as GeometryInstance3D
		if g.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED:
			_double[g] = true
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


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
	var text := "%s %.1f мс; %s" % [stats.group_names[k], last[k] / 1000.0, _phase_cause(game.vegetation)]
	if game.chunk_source != null:
		var cs: Dictionary = game.chunk_source.stats
		var up: float = cs.upload_ms - _chunk_seen.get("upload_ms", cs.upload_ms)
		var reads: int = cs.reads - int(_chunk_seen.get("reads", cs.reads))
		if up > 0.05 or reads > 0:
			text += "; рельеф с диска: передано %.1f мс, чтений %d" % [up, reads]
	return text + "; камера %d, %d" % [at.x, at.z]


## Счётчики ChunkSource на прошлом кадре: причина пика — их прирост за кадр
func _chunk_mark() -> void:
	if game != null and game.chunk_source != null:
		_chunk_seen = {upload_ms = game.chunk_source.stats.upload_ms, reads = game.chunk_source.stats.reads}


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
	if Heightfield.verify_native_ride:
		_ride_sweep(hf)


## 15.11, --verify-ride: сверка RideGround (C#) с GDScript не только на пути езды — по всему плану, у каждого
## моста и туннеля (над настилом, под ним, на перилах), у лент рек и озёр, с разными высотами ног
func _ride_sweep(hf: Heightfield) -> void:
	var before := Heightfield.native_ride_checks
	var w := game.world
	var rng := RandomNumberGenerator.new()
	rng.seed = 1511
	var size := Vector2(w.W, w.H) * GameConfig.TILE
	var probe := func(x: float, z: float, feet: float) -> void:
		hf.ground_at(x, z)
		hf.surface_at(x, z, feet)
		hf.depth_at(x, z, feet)
		hf.depth_at(x, z)
		hf.immersion_at(x, z, feet)
		# этап 2: проверка габарита с телом пешехода и велосипеда, со всеми режимами
		for r: float in [0.0, PlayerState.BODY_R, BikeRide.BODY_R]:
			PlayerState.is_passable(w, hf, x, z, feet, r)
			PlayerState.is_passable(w, hf, x, z, feet, r, false, ForestObstacles.CLIMB_MAX, true)
			PlayerState.is_passable(w, hf, x, z, feet, r, true, 0.0)
	# постройки поселений и мест: точки вокруг каждой
	for list: Array in [w.civil.settlements, w.civil.sites]:
		for s in list:
			for u in s.huts:
				for k in 12:
					var x: float = u.x * GameConfig.TILE + rng.randf_range(-5.0, 5.0)
					var z: float = u.y * GameConfig.TILE + rng.randf_range(-5.0, 5.0)
					probe.call(x, z, hf.ground_at(x, z) + rng.randf_range(-0.5, 1.0))
	for i in 40000:
		var x := rng.randf() * size.x
		var z := rng.randf() * size.y
		probe.call(x, z, hf.ground_at(x, z) + rng.randf_range(-1.0, 2.0))
	for s: Dictionary in hf.structures:
		for k in 60:
			var t := rng.randf_range(-2.0, s.len + 2.0)
			var side := rng.randf_range(-s.half - 2.0, s.half + 2.0)
			var x: float = s.ax + s.ux * t + s.uz * side
			var z: float = s.az + s.uz * t - s.ux * side
			var deck := hf.level(s, clampf(t, 0.0, s.len))
			for feet: float in [deck - 2.0, deck - 0.79, deck - 0.81, deck, deck + 1.0, INF, -INF]:
				probe.call(x, z, feet)
	for cell: int in hf._river_cells:
		for k in 4:
			var x := (cell % w.W + rng.randf()) * GameConfig.TILE
			var z := (cell / w.W + rng.randf()) * GameConfig.TILE
			probe.call(x, z, hf.ground_at(x, z) + rng.randf_range(-1.5, 1.5))
	var lake := w.lake
	for i in lake.size():
		if lake[i] != 0 and rng.randf() < 0.05:
			var x := (i % w.W + rng.randf()) * GameConfig.TILE
			var z := (i / w.W + rng.randf()) * GameConfig.TILE
			probe.call(x, z, hf.ground_at(x, z) + rng.randf_range(-1.5, 1.5))
	print("RIDE_SWEEP checks %d, structures %d, river cells %d, mismatches %d %s" % [Heightfield.native_ride_checks - before,
		hf.structures.size(), hf._river_cells.size(), Heightfield.native_ride_mismatches.size(), Heightfield.native_ride_mismatches])


## 15.11, --verify-ride, этап 2: стволы, валуны и валежник — препятствия собираются вокруг каждого вида
## (как вокруг игрока), сверка is_passable у каждого препятствия; затем препятствия возвращаются к игроку
func _ride_sweep_obstacles(views: Dictionary) -> void:
	var hf := game.heights
	var w := game.world
	if hf.obstacles == null:
		return
	var before := Heightfield.native_ride_checks
	var rng := RandomNumberGenerator.new()
	rng.seed = 1512
	var count := 0
	for name: String in ["forest", "valley", "peak", "village", "spawn"]:
		if not views.has(name):
			continue
		var v: Dictionary = views[name]
		_place(v)
		await _frames(2)
		hf.obstacles.update(v.pos.x, v.pos.z, game.vegetation.obstacles, game.vegetation.obstacles_version, true)
		var data := hf.obstacles.data
		count += data.size() / ForestObstacles.STRIDE
		for at in range(0, data.size(), ForestObstacles.STRIDE):
			for k in 16:
				var t := rng.randf()
				var x := lerpf(data[at], data[at + 2], t) + rng.randf_range(-data[at + 4] - 1.5, data[at + 4] + 1.5)
				var z := lerpf(data[at + 1], data[at + 3], t) + rng.randf_range(-data[at + 4] - 1.5, data[at + 4] + 1.5)
				var top := minf(data[at + 6], data[at + 5] + 3.0)
				var feet := rng.randf_range(data[at + 5] - 0.5, top + 0.5)
				for r: float in [0.0, PlayerState.BODY_R, BikeRide.BODY_R]:
					for climb: float in [0.0, ForestObstacles.CLIMB_MAX]:
						PlayerState.is_passable(w, hf, x, z, feet, r, false, climb)
						PlayerState.is_passable(w, hf, x, z, feet, r, true, climb)
	hf.obstacles.update(game.player.x, game.player.z, game.vegetation.obstacles, game.vegetation.obstacles_version, true)
	print("RIDE_OBSTACLES checks %d, obstacles %d, mismatches %d %s" % [Heightfield.native_ride_checks - before, count,
		Heightfield.native_ride_mismatches.size(), Heightfield.native_ride_mismatches])


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
	# настройки — по умолчанию и в своём файле: профиль игрока не читается и не пишется.
	# --settings <файл>: настройки игрока (копируются рядом с отчётом, сам файл не меняется)
	settings.settings_path = out.path_join("settings.cfg")
	var player_settings := Dev.arg("settings", "")
	if player_settings != "":
		var copy := out.path_join("settings_player.cfg")
		if DirAccess.copy_absolute(ProjectSettings.globalize_path(player_settings), copy) == OK:
			settings.settings_path = copy
			settings.load_settings()
		else:
			report.failed.append("настройки %s не прочитаны" % player_settings)
	preload("res://scripts/game/opening_route.gd").fixed_seed = 1
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main.startup_render_frames = main.LOAD_WARMUP_FRAMES
	await _frames(3)
	_set_window()
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
	if Heightfield.verify_native_ride:
		await _ride_sweep_obstacles(views)
	spike_cause = _stream_cause

	# виды на месте: камера ставится с полной догрузкой окружения, как в check.gd (без неё числа гуляют:
	# штатная догрузка после переноса идёт дольше 3 с). Лес — последним: в нём же меряются отключения.
	var heavy := {}
	var heavy_view := {}
	var sun: DirectionalLight3D = game.get_node("Sun")
	var env: Environment = game.get_node("WorldEnvironment").environment
	var relight := func() -> void: game._apply_lighting_and_fog()
	for name: String in ["spawn", "village", "valley", "peak", "forest"]:
		var base_for_toggles := name == "forest" and (_wanted("world.off_") or _wanted("world.hour_") or _wanted("world.forest_"))
		var extras := _wanted("world.%s_" % name)
		if not views.has(name) or not (_wanted("world.view_" + name) or base_for_toggles or extras):
			continue
		heavy_view = views[name]
		_place(heavy_view)
		heavy = await _case("world.view_" + name, "Мир: " + heavy_view.title, HOLD, _look.bind(heavy_view), {}, base_for_toggles or extras)
		await _shot(name, relight)
		if "--veg-tris" in args:
			_veg_tris(game.vegetation, name)
		var at := _look.bind(heavy_view)
		var cut := func(nodes: Array) -> Array: return [_show.bind(nodes, false), _show.bind(nodes, true)]
		var buildings: Array = [game.get_node("Settlements"), game.get_node("Structures")]
		if name == "village":
			# 15.1: в лесу постройки и вода почти не в кадре — их цена меряется там, где они видны
			await _ablate("village", "Мир, вид «%s»" % heavy_view.title, "world.village_off_", heavy, [
				["buildings", "поселения и сооружения"] + cut.call(buildings),
				["water", "вода"] + cut.call([game.get_node("Water")]),
				["garlands", "гирлянды", _garlands.bind(false), _garlands.bind(true)],
			], at, game.vegetation)
			hour = 23.0
			await _case("world.village_night", "Мир: %s ночью (костры, окна, гирлянды)" % heavy_view.title, HOLD, at)
			hour = 12.0
		elif name == "valley":
			await _ablate("valley", "Мир, вид «%s»" % heavy_view.title, "world.valley_off_", heavy, [
				["water", "вода"] + cut.call([game.get_node("Water")]),
				["particles", "частицы и местный туман", _particles.bind(false), _particles.bind(true)],
			], at, game.vegetation)
			# Пасмурный рассвет у воды с местным туманом.
			hour = 6.5
			game.day.cloud_cover_override = 1.0
			await _case("world.valley_mist", "Мир: %s, пасмурный рассвет" % heavy_view.title, HOLD, at)
			game.day.cloud_cover_override = -1.0
			hour = 12.0

	# что сколько стоит — в лесу (последний снятый вид), сразу после его замера
	if not heavy.is_empty():
		var step := _look.bind(heavy_view)
		var far: Array = get_nodes_in_group("distant_forest")
		var msaa := root.msaa_3d
		var low_fog := func() -> void:
			env.volumetric_fog_enabled = false
			game.local_mist.set_quality(0, env)
		var low_light := func() -> void:
			Lighting.apply(env, sun, 0, settings.shadows, 0)
			game.local_mist.set_quality(0, env)
		var low := func() -> void:
			Lighting.apply(env, sun, 0, false, 0)
			game.local_mist.set_quality(0, env)
			VisualStyle.configure({grade = false, depth = false, highlights = false, grain = false}, {})
			_veg_level(game.vegetation, 0, 0)
			_particles(false)
			_garlands(false)
			root.msaa_3d = Viewport.MSAA_DISABLED
		var high := func() -> void:
			relight.call()
			_veg_level(game.vegetation, settings.draw, settings.flora)
			_particles(true)
			_garlands(true)
			root.msaa_3d = msaa
		await _ablate("world", "Мир, вид «%s»" % heavy_view.title, "world.off_", heavy, [
			["shadows", "тени солнца", func() -> void: sun.shadow_enabled = false, relight],
			["lighting", "освещение и туман выше низкого", low_light, relight],
			# 15.1: «освещение» по частям — какая из них дорогая
			["cascades", "каскады теней как на низком (2 каскада, 110 м)", func() -> void: Lighting.apply_shadows(sun, 0), relight],
			["ssao", "затенение SSAO", func() -> void: env.ssao_enabled = false, relight],
			# 16.11: качество облаков (по умолчанию средние): низкие — купол облаков, высокие — прежние по пикселям
			["clouds_low", "облака низкие (купол) вместо средних", func() -> void: Lighting.apply_clouds(env, 0),
				func() -> void: Lighting.apply_clouds(env, settings.cloud_quality)],
			["clouds_high", "облака высокие (прежние) вместо средних", func() -> void: Lighting.apply_clouds(env, 2),
				func() -> void: Lighting.apply_clouds(env, settings.cloud_quality)],
			["local_fog", "местный и объёмный туман", low_fog, relight],
			["style", "визуальный стиль", func() -> void: VisualStyle.configure({grade = false, depth = false, highlights = false, grain = false}, {}), relight],
			# 15.11: цена частей теней солнца (дальность, атлас, фильтр, смешивание каскадов, двусторонние тени)
		] + _shadow_parts(sun, game, relight) + [
			["msaa", "сглаживание MSAA", func() -> void: root.msaa_3d = Viewport.MSAA_DISABLED, func() -> void: root.msaa_3d = msaa],
			# 19.11: умолчание 4x → 2x; при базе 2x строка ничего не меняет
			# 19.11: тень подлеска только ближе 70 м (shadow_far); отрицательный выигрыш — во что обходилась вся дальность
			["under_shadow_far", "тень подлеска только ближе 70 м (вся дальность теней)", _under_shadow_far.bind(game.vegetation, 0.0),
				_under_shadow_far.bind(game.vegetation, VegetationLayer.UNDERSTORY_SHADOW_FAR)],
			["msaa2", "MSAA 4x (2x вместо него)", func() -> void: root.msaa_3d = Viewport.MSAA_2X, func() -> void: root.msaa_3d = msaa],
			["half_res", "половина разрешения", func() -> void: root.scaling_3d_scale = 0.5, func() -> void: root.scaling_3d_scale = 1.0],
			# 20.11: шаги адаптивного разрешения (FSR 1) — сколько GPU снимает 90 % и 80 % стороны кадра
			["res_90", "разрешение 3D 90 % с FSR", _render_scale.bind(0.9), _render_scale.bind(1.0)],
			["res_80", "разрешение 3D 80 % с FSR", _render_scale.bind(0.8), _render_scale.bind(1.0)],
			["vegetation", "ближняя растительность", _show.bind([game.vegetation], false), _show.bind([game.vegetation], true)],
			# 19.11: ковёр травы (GroundCarpet) отдельно от остальной ближней растительности — его доля в треугольниках
			["carpet", "ковёр травы", _show_carpet.bind(game.vegetation, false), _show_carpet.bind(game.vegetation, true)],
			["far_forest", "дальний лес", _show.bind(far, false), _show.bind(far, true)],
			["terrain", "рельеф", _show.bind([game.get_node("Terrain")], false), _show.bind([game.get_node("Terrain")], true)],
			["outer", "местность за краем области", _show.bind([game.outer], false), _show.bind([game.outer], true)],
			["particles", "частицы и местный туман", _particles.bind(false), _particles.bind(true)],
			["garlands", "гирлянды", _garlands.bind(false), _garlands.bind(true)],
			["draw_min", "дальность растительности выше минимальной", func() -> void: _veg_level(game.vegetation, 0, -1), func() -> void: _veg_level(game.vegetation, settings.draw, -1)],
			["flora_low", "качество растительности выше низкого", func() -> void: _veg_level(game.vegetation, -1, 0), func() -> void: _veg_level(game.vegetation, -1, settings.flora)],
			["all_low", "все настройки выше минимума", low, high],
		], step, game.vegetation)
		# 20.11: цена самой смены разрешения (пересоздание буферов кадра) — смена 100 % ↔ 90 % раз в 0,5 с
		if _wanted("world.res_switch"):
			var switch := func(t: float, dt: float) -> void:
				step.call(t, dt)
				var reduced := int(t / 0.5) % 2 == 1
				if reduced != (root.scaling_3d_scale < 1.0):
					_render_scale(0.9 if reduced else 1.0)
			await _case("world.res_switch", "Мир: тот же вид, разрешение 3D 100 % ↔ 90 % раз в 0,5 с", MOVE, switch)
			_render_scale(1.0)
			await _settle(game.vegetation, step)
		if "--shots" in args:
			for scale: float in [0.9, 0.8]:
				_render_scale(scale)
				await _settle(game.vegetation, step)
				await _shot("forest_res_%d" % roundi(scale * 100.0), relight)
			_render_scale(1.0)
			_under_shadow_far(game.vegetation, 0.0)
			await _settle(game.vegetation, step)
			await _shot("forest_under_shadow_all", relight)
			_under_shadow_far(game.vegetation, VegetationLayer.UNDERSTORY_SHADOW_FAR)
			await _settle(game.vegetation, step)
			await _shot("forest_under_shadow_near", relight)
		for h: Array in [[6.5, "dawn", "рассвет"], [23.0, "night", "ночь"]]:
			hour = h[0]
			await _case("world.hour_" + h[1], "Мир: тот же вид, " + h[2], TOGGLE, step)
			await _shot("forest_" + h[1], relight)
		hour = 12.0
		# Высокое качество света и тумана — по умолчанию стоит среднее.
		if _wanted("world.forest_high"):
			Lighting.apply(env, sun, 2, settings.shadows, 2)
			var high_fog := func() -> void:
				env.volumetric_fog_enabled = RenderingServer.get_current_rendering_method() == "forward_plus"
				game.local_mist.set_quality(2, env)
			high_fog.call()
			await _settle(game.vegetation, step)
			var high_case := await _case("world.forest_high", "Мир: тот же вид, свет и туман «высокие»", TOGGLE, step)
			var sky_mat := env.sky.sky_material as ShaderMaterial if env.sky != null else null
			await _ablate("high", "Мир, вид «%s», свет «высокий»" % heavy_view.title, "world.high_off_", high_case, [
				["ssil", "SSIL (непрямой свет)", func() -> void: env.ssil_enabled = false, func() -> void: env.ssil_enabled = true],
				["clouds", "облака в 5 шагов (как на среднем — 2)", func() -> void: if sky_mat: sky_mat.set_shader_parameter("cumulus_steps", 2),
					func() -> void: if sky_mat: sky_mat.set_shader_parameter("cumulus_steps", 5)],
				["fog", "аналитический туман вместо объёмного", func() -> void:
					env.volumetric_fog_enabled = false
					game.local_mist.set_quality(1, env), high_fog],
			], step, game.vegetation)
			relight.call()

	# движение: подгрузка рельефа, растительности и воды штатным планировщиком
	await _settle(game.vegetation, _ride.bind(0.0), 1.0, 3.0)
	await _case("world.road_still", "Мир: начало дороги, на месте", HOLD, _ride.bind(0.0))
	await _case("world.ride", "Мир: езда по дороге %d м/с" % GameConfig.BIKE_SPEED, MOVE * 1.5, _ride.bind(GameConfig.BIKE_SPEED))
	await _case("world.fast", "Мир: пролёт по дороге %d м/с" % (GameConfig.BIKE_SPEED * 4), MOVE, _ride.bind(GameConfig.BIKE_SPEED * 4.0))
	var stops: Array = views.values()
	await _case("world.jump", "Мир: перенос в другое место раз в 1,5 с", MOVE * 1.5, func(t: float, dt: float) -> void: _look(t, dt, stops[int(t / 1.5) % stops.size()]))

	if _wanted("world.board"):
		await _board_case()

	# игра без паузы: логика, физика, HUD и звук; сначала игрок стоит, потом едет (руль и газ — нажатия действий)
	await _play("world.play_map", "Мир: карта открывается и закрывается раз в секунду", MOVE, _toggle_map)
	if game.show_map:
		game.close_tablet(false)
	await _play("world.play_idle", "Мир: игра без паузы, игрок стоит", HOLD, Callable())
	await _play("world.play_ride", "Мир: езда с физикой велосипеда", MOVE, _drive)
	# Торможение начинается после двух секунд разгона. Первый тормозной кадр попадает в основной замер.
	await _play("world.play_brake", "Мир: разгон и резкое торможение", MOVE, _brake)
	if _wanted("world.play_night"):
		game.hour = 23.0
		# сначала без фары, потом с ней: цена фары — разница двух соседних отрезков одной ночной езды
		await _play("world.play_night_dark", "Мир: ночная езда без фары", MOVE * 0.5, _drive)
		game.bike_view.set_lamp(true)
		await _play("world.play_night", "Мир: ночная езда с фарой", MOVE * 0.5, _drive)
		game.bike_view.set_lamp(false)
		game.hour = 12.0
	if _wanted("world.after_travel") and views.has("forest"):
		await _travel(views.forest)

	_memory("played", "После замеров в мире")
	main._free_game()
	game = null
	await _frames(30)
	_memory("after_free", "Мир выгружен")
	if "--cycles" in args or _wanted("world.reload"):
		await _reload(seed_text, size)
	main.queue_free()
	main = null
	await _frames(5)


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


## Гирлянды: выключаются целиком (и их CPU), как настройкой в меню
func _garlands(on: bool) -> void:
	if game.garlands != null:
		game.garlands.set_enabled(on and GameContext.scope.settings.tree_garlands)


## Частицы и местный туман: прячутся, и _look перестаёт крутить их на CPU
func _particles(on: bool) -> void:
	_show([game.ambient, game.local_mist], on)
	_quiet_particles = not on


## Замер игры без паузы: кадр ведёт сама игра (_process и _physics_process), drive(t, dt) жмёт действия.
## В замер пишется tick_parts_ms (такт физики и кадр игры по частям) и game_cpu_ms — CPU игры на кадр.
func _play(name: String, title: String, seconds: float, drive: Callable) -> void:
	if not _wanted(name):
		return
	main.hud.visible = true
	game.paused = false
	game.tick_us.clear()
	var c := await _case(name, title, seconds, drive)
	for action: String in ["move_forward", "move_back", "move_left", "move_right"]:
		Input.action_release(action)
	var ticks := maxi(1, int(game.tick_us.get("ticks", 0)))
	var frames := maxi(1, int(game.tick_us.get("frames", 0)))
	var parts := {}
	var cpu := 0.0
	for k: String in game.tick_us:
		if k == "ticks" or k == "frames":
			continue
		var per_frame: float = game.tick_us[k] / float(frames) / 1000.0
		parts[k] = snappedf(game.tick_us[k] / float(frames if k.begins_with("frame_") else ticks) / 1000.0, 0.01)
		cpu += per_frame
	c.tick_parts_ms = parts
	if Heightfield.verify_native_ride:
		print("RIDE_VERIFY ", name, " checks ", Heightfield.native_ride_checks, " mismatches ", Heightfield.native_ride_mismatches.size(), " ", Heightfield.native_ride_mismatches)
	c.game_cpu_ms = snappedf(cpu, 0.01)
	c.physics_hz = snappedf(ticks / maxf(0.001, seconds + WARM), 1.0)
	c.bike_speed = snappedf(game.bike.speed, 0.1)
	Dev.save_json(out.path_join("stress.json"), report)
	game.paused = true
	main.hud.visible = false


## Езда: газ всё время, руль плавно вправо-влево (поворот, торможение на дуге, подъёмы по рельефу)
func _drive(t: float, _dt: float) -> void:
	Input.action_press("move_forward", 1.0)
	var turn := sin(t * 1.3) * 0.8
	if turn > 0.05:
		Input.action_release("move_left")
		Input.action_press("move_right", turn)
	elif turn < -0.05:
		Input.action_release("move_right")
		Input.action_press("move_left", -turn)
	else:
		Input.action_release("move_left")
		Input.action_release("move_right")


## 20.11: карта (M) открыта с 0,3 по 1,3 с каждых двух секунд: открытие и закрытие попадают в замер по два раза,
## первое открытие — в прогрев (cold_max_ms)
func _toggle_map(t: float, _dt: float) -> void:
	var want := fmod(t, 2.0) >= 0.3 and fmod(t, 2.0) < 1.3
	if want != game.show_map:
		game.toggle_map()


## 20.11: щит ближней доски (карта и листки в SubViewport): камера стоит в 25 м от доски, окружение догружено;
## первую секунду доска «за 60 м», затем «близко» — сборка щита (с отбором заданий) попадает в замер без подгрузки
## мира вокруг; после замера OFFERS_MS — цена отбора заданий по частям
func _board_case() -> void:
	var boards: Array = game.board_display.boards.call()
	if boards.is_empty():
		report.failed.append("в мире нет досок для замера щита")
		return
	var at: Transform3D = boards[0].at
	var v := {pos = at * Vector3(0.0, 0.4, 25.0), target = at.origin}
	_place(v)
	await _settle(game.vegetation, _look.bind(v), 1.0, 3.0)
	var bd := game.board_display
	var step := func(t: float, dt: float) -> void:
		_look(t, dt, v)
		bd._next_check_ms = 0
		bd.tick(at * Vector3(0.0, 0.0, 60.0 if t < 1.0 else 20.0))
	await _case("world.board", "Мир: щит доски строится у камеры", MOVE, step)
	var svc := game.interaction_service
	var here := svc.target(game.world.place(WorldData.place_id("settlement", boards[0].place.x, boards[0].place.y)))
	var clock_us := func(f: Callable) -> float:
		var t0 := Time.get_ticks_usec()
		f.call()
		return (Time.get_ticks_usec() - t0) / 1000.0
	var trip: Dictionary = svc.travel.call()
	var prefer := svc.quests.prefer(here, trip)
	print("OFFERS_MS all=%.1f places=%.1f travel=%.1f beacons=%.1f paint=%.1f" % [clock_us.call(func() -> void: svc.offers(boards[0].place)),
		clock_us.call(func() -> void: svc.all_places.call()), clock_us.call(func() -> void: svc.travel.call()),
		clock_us.call(func() -> void: load("res://scripts/game/beacon_sites.gd").route(game.world, game.heights, here, svc.quests.installed_beacons, prefer)),
		clock_us.call(func() -> void: load("res://scripts/game/paint_targets.gd").route(game.world, game.heights, here, svc.quests.painted_objects, prefer))])


## Разгон 2 с, затем полный тормоз (move_back) до конца замера
func _brake(t: float, _dt: float) -> void:
	Input.action_release("move_left")
	Input.action_release("move_right")
	if t < 2.0:
		Input.action_release("move_back")
		Input.action_press("move_forward", 1.0)
	else:
		Input.action_release("move_forward")
		Input.action_press("move_back", 1.0)


## Быстрое перемещение (как с карты): сколько длится переход и какие первые кадры после него
func _travel(v: Dictionary) -> void:
	game.paused = false
	main.hud.visible = true
	var from_map := "--travel-from-map" in args
	var atlas_open_ms := 0.0
	if from_map:
		var open_tick := Time.get_ticks_usec()
		game.toggle_map()
		if not game.show_map:
			report.failed.append("атлас не открылся перед быстрым перемещением")
		# Игрок сначала видит карту, затем выбирает на ней место.
		for frame in 8:
			await process_frame
			var now := Time.get_ticks_usec()
			atlas_open_ms = maxf(atlas_open_ms, (now - open_tick) / 1000.0)
			open_tick = now
	var place := {kind = "peak", name = "стресс-тест", x = v.target.x / Dev.TILE, y = v.target.z / Dev.TILE}
	var before := Vector2(game.player.x, game.player.z)
	var t0 := Time.get_ticks_usec()
	var worst := 0.0
	var worst_phase := ""
	var last := t0
	game.travel_to(place)
	var frames := 0
	while game.travel_active() and Time.get_ticks_usec() - t0 < 20000000:
		var phase := "prepare" if game._travel_task != -1 else "publish"
		await process_frame
		beat = Time.get_ticks_msec()
		var now := Time.get_ticks_usec()
		var elapsed := (now - last) / 1000.0
		if elapsed > worst:
			worst = elapsed
			worst_phase = phase if game.travel_active() else "arrive"
		last = now
		frames += 1
	var travel_s := snappedf((Time.get_ticks_usec() - t0) / 1000000.0, 0.01)
	var moved := before.distance_to(Vector2(game.player.x, game.player.z)) > 1.0
	await _case("world.after_travel", "Мир: первые 2 с после быстрого перемещения", HOLD, Callable(),
		{travel_s = travel_s, travel_worst_ms = snappedf(worst, 0.1), travel_peak_phase = worst_phase,
		travel_frames = frames, travel_moved = moved, atlas_open_ms = snappedf(atlas_open_ms, 0.1)})
	if not moved:
		report.failed.append("быстрое перемещение не сработало (место недоступно)")
	if from_map and (game.show_map or root.disable_3d):
		report.failed.append("при прибытии атлас не закрылся или 3D не включилось")
	game.paused = true
	main.hud.visible = false


## Второй цикл «загрузка → выгрузка»: рост памяти от цикла к циклу — утечка, а не разовые кэши движка
func _reload(seed_text: String, size: int) -> void:
	var t0 := Time.get_ticks_msec()
	main.start_game(seed_text, size)
	while main.game == null or main.game.player == null or main.busy:
		await process_frame
		beat = Time.get_ticks_msec()
		if Time.get_ticks_msec() - t0 > 120000 or (not main.busy and main.game == null and Time.get_ticks_msec() - t0 > 3000):
			report.failed.append("мир %s не загрузился второй раз" % seed_text)
			return
	report.load.reload_s = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
	main.game.paused = true
	await _frames(30)
	_memory("loaded2", "Мир загружен второй раз")
	main._free_game()
	await _frames(30)
	_memory("after_free2", "Мир выгружен второй раз")


## 19.11: --veg-tris — треугольники ближней растительности по видам (экземпляры × треугольники сетки) с учётом
## дальности видимости узла; тень — узлы, попадающие в проход теней (у теневых копий — только в него)
const _UNDER_NAMES := ["FERN", "MOSS", "MUSHROOM", "HERB", "GRASS", "BUSH", "SAPLING", "PINE", "FLOWERS", "HIGH_GRASS", "YOUNG",
	"YOUNG_PINE", "MEADOW", "FORBS", "SEDGE", "STIPA", "FIREWEED", "HAZEL", "HAZEL_TALL"]
func _veg_tris(layer: VegetationLayer, view: String) -> void:
	var labels := {}
	for u: Dictionary in layer.understory:
		var b: int = u.base
		labels[u.node] = ("under_" + _UNDER_NAMES[b]) if b < _UNDER_NAMES.size() else "floor_%d" % b
	if layer.carpet != null:
		for entry: Dictionary in layer.carpet.layers:
			for part: Dictionary in entry.nodes.values():
				labels[part.node] = "carpet_" + String(entry.name)
	var cam := layer.get_viewport().get_camera_3d()
	var eye := cam.global_position
	var rows := {}
	var tri_cache := {}
	var stack: Array[Node] = [layer]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if not (n is MultiMeshInstance3D) or not n.is_visible_in_tree() or n.multimesh == null or n.multimesh.mesh == null:
			continue
		var node := n as MultiMeshInstance3D
		var mm: MultiMesh = node.multimesh
		var d := eye.distance_to(node.global_transform * mm.get_aabb().get_center())
		if node.visibility_range_end > 0.0 and d > node.visibility_range_end + node.visibility_range_end_margin:
			continue
		if d < node.visibility_range_begin:
			continue
		var count := mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
		if count <= 0:
			continue
		var mesh: Mesh = mm.mesh
		if not tri_cache.has(mesh):
			var t := 0
			for i in mesh.get_surface_count():
				var arr := mesh.surface_get_arrays(i)
				var idx: Variant = arr[Mesh.ARRAY_INDEX]
				t += (idx as PackedInt32Array).size() / 3 if idx != null and not (idx as PackedInt32Array).is_empty() else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
			tri_cache[mesh] = t
		var tris: int = tri_cache[mesh]
		var label: String = labels.get(node, "")
		if label == "":
			if node.has_meta("stream_tree"):
				label = "tree_lvl%s" % str(node.get_meta("level", "?"))
			elif mm.mesh == layer.grass.mesh if layer.grass != null else false:
				label = "grass"
			else:
				label = "other"
		var mode := "только тень" if node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY else ("с тенью" if node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF else "")
		var key := "%s %s" % [label, mode]
		var r: Array = rows.get(key, [0, 0, 0])
		r[0] += 1
		r[1] += count
		r[2] += count * tris
		rows[key] = r
	var keys := rows.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return rows[a][2] > rows[b][2])
	var total := 0
	for k: String in keys: total += rows[k][2]
	print("VEG_TRIS %s всего %d в дальности (вид: узлов, экземпляров, треугольников)" % [view, total])
	for k: String in keys.slice(0, 40):
		print("VEG_TRIS  %-34s %5d %8d %9d" % [k, rows[k][0], rows[k][1], rows[k][2]])


## Подлесок с тенью (не валежник и камни: у них base от Floor.FIRST) — тот же отбор, что в VegetationLayer
func _under_shadow_far(layer: VegetationLayer, far: float) -> void:
	for u: Dictionary in layer.understory:
		if u.base < _UNDER_NAMES.size() and u.node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			(u.node.material_override as ShaderMaterial).set_shader_parameter("shadow_far", far)


func _show_carpet(layer: VegetationLayer, on: bool) -> void:
	if layer == null or layer.carpet == null:
		return
	for entry: Dictionary in layer.carpet.layers:
		for part: Dictionary in entry.nodes.values():
			if is_instance_valid(part.node):
				part.node.visible = on


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
	var decor_deadline := game.stream_coordinator.update(v.pos)
	if not _quiet_particles:
		game.ambient.update(dt, v.pos, game.day.sunlight)
		game.local_mist.update(v.pos, dt)
	if game._ocean != null:
		game._ocean.position = Vector3(v.pos.x, 0.0, v.pos.z)
	if _night_lights:
		game.update_lights(v.pos, v.pos, clock, dt, decor_deadline) # 15.1: на паузе не было ни костров, ни окон, ни гирлянд


## Доля разрешения 3D: ниже 100 % — с повышением резкости FSR 1, как у адаптивного разрешения игры
func _render_scale(scale: float) -> void:
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if scale < 1.0 else Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = scale


## Окно замера: 1280×720 или (--fullscreen) весь экран — как у игрока в полноэкранном режиме
func _set_window() -> void:
	if "--fullscreen" in args:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Dev.WINDOW_SIZE)


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
