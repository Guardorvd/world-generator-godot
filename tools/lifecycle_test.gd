extends SceneTree
## Проверка жизненного цикла мира: несколько миров подряд через главное меню (как игрок: «Начать», немного
## игры, «В меню»). После выхода в меню прошлый мир должен освободиться целиком, а память — не расти от мира
## к миру. Запуск из папки проекта (с окном или без):
##   godot --headless --path . --script res://tools/lifecycle_test.gd -- [--size 512] [--worlds 4]

const SEEDS := ["Север-1234", "Туман-4821", "Янтарь-5150", "Ущелье", "Кедр-2024", "Иней-7777"]
const PLAY_FRAMES := 90    # кадров игры в каждом мире: растительность и рельеф за краем успевают подгрузиться
const MENU_FRAMES := 10    # кадров в меню: освобождённые узлы уходят в конце кадра
const MainScene := "res://scenes/main.tscn"
const OUT := "res://.godot/menu_lifecycle"

var main: Node
var size := 512
var worlds := 4
var k := 0
var phase := "menu"
var frames := 0
var refs: Array[WeakRef] = []   # мир, рельеф и остальные владельцы данных: все ссылки должны опустеть
var mem: Array = []             # [статическая память МБ, объектов] в меню после каждого мира
var fails := 0


# По умолчанию (4 мира 512) около 10 мин, --size 256 --worlds 3 в несколько раз меньше.
func _watchdog_limit() -> float:
	var args := OS.get_cmdline_user_args()
	if "--menu-smoke" in args:
		return 540.0
	var n := worlds
	var s := size
	for a in args.size() - 1:
		if args[a] == "--size":
			s = int(args[a + 1])
		elif args[a] == "--worlds":
			n = int(args[a + 1])
	return 60.0 + n * (200.0 if s >= 512 else 90.0)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, _watchdog_limit())
	_check_base_ownership()
	var args := OS.get_cmdline_user_args()
	if "--menu-smoke" in args:
		phase = "smoke"
		_menu_smoke.call_deferred()
		return
	for a in args.size() - 1:
		if args[a] == "--size":
			size = int(args[a + 1])
		elif args[a] == "--worlds":
			worlds = int(args[a + 1])
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


## Один мир с окном. Основная сцена получает обычные права на кэш и сохранения в каталоге стенда.
func _menu_smoke() -> void:
	if DisplayServer.get_name() == "headless":
		_check(false, "для проверки живого меню требуется окно")
		_finish()
		return
	var run := OUT.path_join(str(OS.get_process_id()))
	DirAccess.make_dir_recursive_absolute(run)
	GameContext.scope.settings.settings_path = run.path_join("settings.cfg")
	GameContext.scope.cache.dir = run.path_join("world_cache")
	preload("res://scripts/game/save_game.gd").dir = run.path_join("saves")
	change_scene_to_file(MainScene)
	await scene_changed
	main = current_scene
	_check(main.get_node("%Start").has_focus() and main.bg.texture != null, "афиша и управление доступны на первом кадре")
	_check(main._backdrop == null, "сборка фона отложена")
	_check(main.get_node("%Carousel/Card/CardContent/Artwork/Art/Map").texture != null, "миниатюра мира читается из сборки")
	await _wait_for_backdrop()
	var live: TextureRect = main.get_node("%LiveBackdrop")
	_check(live.visible and main._backdrop != null, "живой фон проявился")
	if main._backdrop != null:
		print("MENU_LIVE_READY_MS=", main._backdrop.build_ms)
	await _smoke_shot("menu")
	main._on_start()
	_check(main._backdrop == null and not live.visible and not VisualStyle.is_bound(), "фон и стиль освобождены до загрузки")
	_check(main.screens.loading.visible and main.bg.texture != null, "экран загрузки показывает неподвижный кадр")
	await _smoke_shot("loading")
	if not await _wait_for_world():
		_finish()
		return
	var first_world: WeakRef = weakref(main.game.world)
	var first_game: WeakRef = weakref(main.game)
	main._toggle_pause()
	_check(main.screens.pause.visible and main.get_node("%Resume").has_focus(), "пауза открывается из игры")
	await _smoke_shot("pause")
	main._back_to_menu()
	await process_frame
	await process_frame
	_check(first_world.get_ref() == null and first_game.get_ref() == null, "после возврата узлы и данные мира освобождены")
	_check(main.screens.menu.visible and main.get_node("%Start").text.begins_with("Продолжить"), "возврат показывает сохранённый прогресс")
	# Сразу продолжаем, пока новый фон ещё собирается.
	main._on_start()
	if await _wait_for_world():
		_check(main._backdrop == null and VisualStyle.is_bound(), "повторный вход восстановил стиль игрового мира")
		main._back_to_menu()
		await process_frame
		await process_frame
	main._set_backdrop_mode("")
	_finish()


func _wait_for_backdrop() -> void:
	var deadline := Time.get_ticks_msec() + 80000
	while not main.get_node("%LiveBackdrop").visible and Time.get_ticks_msec() < deadline:
		await process_frame
	await create_timer(0.65).timeout


func _wait_for_world() -> bool:
	while main.busy:
		await process_frame
	var ok: bool = main.game != null and main.game.player != null
	_check(ok, "мир загружен через главное меню")
	return ok


func _smoke_shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUT.path_join(label + ".png"))


func _check(ok: bool, what: String) -> void:
	if ok:
		print("✓ " + what)
	else:
		printerr("✗ " + what)
		fails += 1


func _process(_delta: float) -> bool:
	frames += 1
	match phase:
		"menu":
			if frames < MENU_FRAMES:
				return false
			if k > 0:
				var alive := 0
				for r in refs:
					if r.get_ref() != null:
						alive += 1
				_check(alive == 0, "после мира %d освобождены все %d объектов прошлых миров (живых: %d)" % [k, refs.size(), alive])
				mem.append([Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
					int(Performance.get_monitor(Performance.OBJECT_COUNT))])
				print("  в меню после мира %d: память %.0f МБ, объектов %d" % [k, mem[-1][0], mem[-1][1]])
			if k == worlds:
				_finish()
				return true
			main.start_game(SEEDS[k % SEEDS.size()], size)
			phase = "loading"
		"loading":
			if main.game == null or main.game.player == null:
				return false
			for value: Object in [main.game, main.game.world, main.game.heights, main.game.heights.road_refinement,
					main.game.world.outer, main.game.player, main.game.bike, main.game.quests]:
				if value != null:
					refs.append(weakref(value))
			# Панель открывает кнопки с замыканиями, которые тоже должны уйти вместе с миром.
			if not main.game.world.settlements.is_empty():
				main.game.hud.settlement_panel.open(main.game.world.settlements[0], main.game.world, [], false, main.game.quests)
			main.game.tree_exited.connect(_check_hud_connections.bind(main.game))
			# мир держат ровно игра и интерфейс; освобождаться он должен сам, без ручной уборки полей
			phase = "play"
			frames = 0
		"play":
			# игрок идёт вперёд: растительность перезаполняется в фоне, рельеф за краем догружается
			main.game.player.x += 2.0
			if frames >= PLAY_FRAMES:
				main._back_to_menu()
				k += 1
				phase = "menu"
				frames = 0
	return false


func _check_base_ownership() -> void:
	# Прерванная генерация: финальная ручная очистка base_heights ещё не выполнялась.
	var w := WorldData.new()
	var h := Heightfield.new()
	h.world = w
	w.base_heights = h
	var owner: WeakRef = weakref(w)
	var cached: WeakRef = weakref(h)
	var copy := h.copy()
	w = null
	_check(owner.get_ref() != null and copy.world != null, "игровая копия рельефа владеет миром")
	copy = null
	_check(owner.get_ref() == null and h.world == null, "общий рельеф не держит прерванный мир")
	h = null
	_check(cached.get_ref() == null, "общий рельеф освобождён без ручной очистки WorldData.base_heights")


func _check_hud_connections(game: GameWorld) -> void:
	# tree_exited испускается до удаления объекта: автоматическая уборка при free ещё не помогает.
	var panel: Control = main.hud.settlement_panel
	var sources: Array[Object] = [main.hud, panel]
	var attached := 0
	for source: Object in sources:
		for description: Dictionary in source.get_signal_list():
			for connection: Dictionary in source.get_signal_connection_list(description.name):
				if connection.callable.get_object() == game:
					attached += 1
	_check(attached == 0, "обработчики GameWorld отключены от Hud и панели до удаления сцены")


func _finish() -> void:
	if mem.size() >= 3:
		# первый мир прогревает кэши (модели деревьев, шейдеры); дальше память в меню не должна расти
		var grow: float = mem[-1][0] - mem[1][0]
		_check(grow < 15.0, "память в меню не растёт от мира к миру (%+.0f МБ со второго по %d-й)" % [grow, mem.size()])
	print("Итог: %s" % ("ошибок нет" if fails == 0 else "ошибок: %d" % fails))
	quit(0 if fails == 0 else 1)
