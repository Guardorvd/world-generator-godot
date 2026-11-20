extends SceneTree
## Изолированная проверка FPS-отчёта на маленьком мире без генерации и рендера.
const Saves := preload("res://scripts/game/save_game.gd")
const Sessions := preload("res://scripts/game/session_performance.gd")
const Main := preload("res://scripts/ui/main.gd")

var _failures := 0


class Fixture extends GameWorld:
	var state: Dictionary

	func save_state() -> Dictionary:
		return state.duplicate(true)

	func _process(_delta: float) -> void:
		pass

	func _physics_process(_delta: float) -> void:
		pass


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	_run.call_deferred()


func _run() -> void:
	var dir := "res://.godot/session_performance_test_%d" % OS.get_process_id()
	Saves.dir = dir.path_join("saves")
	Sessions.dir = dir.path_join("reports")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.set_script(null)
	root.add_child(main)
	main.set_script(Main)
	main.set_process(false)
	main.hud = main.find_child("Hud", true, false)
	main._setup_save_controls()
	main._progress_enabled = true
	var game := _fixture(main)
	main.game = game
	var start := Time.get_ticks_usec() - 2_000_000
	var session := Sessions.new(game, "gameplay", start)
	main._session_performance = session
	var now := start
	for frame: int in 65:
		now += 16_000
		session.sample(game, "gameplay", now)
	_check(game.performance_context().light == "dawn" and game.performance_context().view == "vista", "рассвет и вид с высоты")
	game.hour = 22.5
	game.player.x = 305.0
	game.player.z = 300.0
	game.world.climate.biome.data[75 * game.world.W + 76] = Biomes.FOREST
	game.tick_us.frame_stream = 20_000
	game.stream_coordinator.stats.frames += 1
	game.stream_coordinator.stats.group_last_us[0] = 18_000
	game.vegetation.phase_stats.last_us[5] = 16_000
	game.note_perf_event("discovery", "1")
	now += 120_000
	session.sample(game, "pause", now)
	# Кадр паузы не должен унаследовать работу стриминга.
	now += 180_000
	session.sample(game, "pause", now)
	_check(main._save_current("manual") and main._session_performance == session, "ручное сохранение продолжает сбор")
	game.paused = true
	game.state.format = -1
	_check(not main._save_current("auto", "menu") and main._session_performance == session, "ошибка сохранения оставляет сессию открытой")
	_check(not DirAccess.dir_exists_absolute(Sessions.dir), "до успешного выхода отчётов нет")
	game.state.format = 1
	_check(main._save_current("auto", "menu") and main._session_performance == null, "успешное сохранение завершает отчёт")
	_check(not Saves.read_slot(game.world.seed_text).data.is_empty(), "прогресс мира записан")
	_check_report()
	main.queue_free()
	await process_frame
	print("SESSION PERFORMANCE failures: ", _failures)
	quit(1 if _failures else 0)


func _fixture(parent: Node) -> Fixture:
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	game.set_script(Fixture)
	parent.add_child(game)
	game.world = WorldData.new()
	game.world.W = 128
	game.world.H = 128
	game.world.N = game.world.W * game.world.H
	game.world.seed_text = "Проверка FPS"
	game.world.climate.biome.data.resize(game.world.N)
	game.world.climate.biome.data.fill(Biomes.GRASS)
	game.world.geology.river.data.resize(game.world.N)
	game.world.geology.elev.data.resize(game.world.N)
	game.world.climate.temp.data.resize(game.world.N)
	game.world.climate.moist.data.resize(game.world.N)
	game.world.geology.slope.data.resize(game.world.N)
	game.world.settlements = [SettlementData.new(76, 76, -1, "Кедровка")]
	game.heights = Heightfield.new()
	game.heights.world = game.world
	game.heights.hv.resize(game.world.N)
	game.player = PlayerState.new()
	game.player.x = 40.0
	game.player.z = 400.0
	game.camera.position = Vector3(40.0, 38.0, 400.0)
	game.bike = BikeRide.new()
	game.day = DayCycle.new(Environment.new(), game.get_node("Sun"))
	game.hour = 4.8
	game.quests = preload("res://scripts/game/quests.gd").new()
	var fixture := game as Fixture
	fixture.state = {format = 1, seed = game.world.seed_text, signature = "fixture", saved_at = 1,
		visited = {}, goal = "", quest = game.quests.save_state(),
		player = {x = 40.0, z = 400.0, feet = 0.0, yaw = 0.0, pitch = 0.0, hour = 4.8},
		bike = {x = 40.0, z = 400.0, y = 0.0, heading = 0.0, riding = false}}
	return fixture


func _check_report() -> void:
	var files := DirAccess.get_files_at(Sessions.dir)
	_check(files.size() == 2, "записаны парные Markdown и JSON")
	var parsed: Variant
	for file: String in files:
		if file.ends_with(".json"):
			parsed = JSON.parse_string(FileAccess.get_file_as_string(Sessions.dir.path_join(file)))
	if not _check(parsed is Dictionary, "JSON читается"):
		return
	var report: Dictionary = parsed
	var s: Dictionary = report.summary
	_check(s.frames == 67 and is_equal_approx(s.fps, 67.0 / 1.34) and is_equal_approx(s.max_fps, 62.5)
		and is_equal_approx(s.min_fps, 1000.0 / 180.0), "средний и крайние FPS за всю сессию")
	if not _check(s.hitches == 2 and s.over_100_ms == 2 and report.long_frames.size() == 2 and report.timeline.size() == 3,
			"рывки и интервалы сохраняются до конца"):
		return
	var row: Dictionary = report.long_frames[0]
	_check(row.stream_ms.vegetation == 18 and row.vegetation_ms.tree_upload == 16 and row.context.settlement == "Кедровка",
		"длинный кадр связывает подгрузку и поселение")
	_check(row.context.light == "dusk" and row.context.biome == Biomes.LIST[Biomes.FOREST].name, "смена биома и закат видны в кадре")
	_check(report.long_frames[1].stream_ms.is_empty() and report.context_groups.mode.has("pause"), "на паузе не повторяются счётчики подгрузки")
	_check(report.dotnet_gc != null, "читаются счётчики GC")
	var parts := func(r: Dictionary) -> Array: return r.evidence.map(func(e: Dictionary) -> String: return e.part)
	_check("event_discovery" in parts.call(row) and report.events.any(func(e: Dictionary) -> bool: return e.kind == "discovery"),
		"событие игры (открытие места) в кадре и в событиях")
	var after: Array = report.long_frames[1].evidence.filter(func(e: Dictionary) -> bool: return e.part == "after_mode")
	_check(after.size() == 1 and after[0].from == "gameplay" and after[0].held_s > 1.0, "кадр после смены режима знает, откуда и сколько там пробыли")
	_check(s.missed_refresh == 2 and is_equal_approx(report.machine.refresh_hz, 60.0), "пропуски обновления экрана — от полутора кадров 60 Гц")


func _check(ok: bool, label: String) -> bool:
	print(("OK " if ok else "FAIL ") + label)
	_failures += int(not ok)
	return ok
