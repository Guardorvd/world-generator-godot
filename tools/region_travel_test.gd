extends SceneTree
## 13.9+: непрерывное путешествие через соседние области в игровой сцене, одна генерация «Север-1234»@256.
## Игрок идёт на восток через пять областей, ждёт на границе неготовых, возвращается назад; затем
## сохранение, новая игровая сцена из сохранения (без повторной генерации) и продолжение пути.
## Проверяются швы высот на границах, выгрузка и чтение полей с диска, узлы областей, память и задержки.
##   godot --headless --path . --script res://tools/region_travel_test.gd
const Saves := preload("res://scripts/game/save_game.gd")
const TILE := GameConfig.TILE
const STEP := 6.0            # м за кадр
const TIMEOUT_MS := 900000
var fails := 0
var main: Node
var loaded: WorldLoader
var game: GameWorld
var frame_max := 0.0
var slow_frames := 0
var waited := 0
var _last := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	# Ошибка в сопрограмме иначе оставит процесс ждать вечно.
	create_timer(TIMEOUT_MS / 1000.0 + 120.0).timeout.connect(func() -> void:
		printerr("region_travel_test: превышено время")
		quit(2))
	call_deferred("run")


func run() -> void:
	var started := Time.get_ticks_msec()
	var dir := "user://region_travel_test"
	_remove(dir)
	RegionStream.root = dir.path_join("regions")
	Saves.dir = dir.path_join("saves")
	GameContext.scope.cache.enabled = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	# 14.4+: соседние области — только с бесконечной генерацией; меню уже прочитало настройки игрока
	GameContext.scope.settings.infinite_world = true
	loaded = WorldLoader.load_world("Север-1234", 256)
	_start({})
	var size := WorldData.REGION_SIZE
	var plan_w := game.world.W
	var z := (game.world.H / 2 + 0.5) * TILE
	var home := (plan_w - size / 2) * TILE
	var first := ceili(float(plan_w) / size) # первая область к востоку от плана
	var far := ((first + 4) * size + 100) * TILE # середина пятой области
	print("План %d × %d, путь от x = %.0f до %.0f м" % [plan_w, game.world.H, home, far])
	var near_key := Vector2i(first, floori(z / TILE / size))
	var middle := (first + 1) * size * TILE
	var ok := await _travel(home, middle, z)
	var stream := game.regions
	# Поля первой области запоминаются, пока она рядом: дальше они уйдут на диск.
	var near_hash := hash(stream.ledger.regions[near_key].fields.h) if ok else 0
	check(ok and await _travel(middle, far, z), "путь на восток через пять областей пройден")
	var counts := stream.counts()
	var mem_far := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	print("Вдали: областей %d, с полями %d, показано %d; %s; память %.0f МБ" % [counts.regions, counts.fields, counts.shown, stream.stats, mem_far])
	check(counts.regions >= 5 and stream.stats.evicted > 0 and counts.fields < counts.regions,
		"далёкие области выгружены: поля только у ближних")
	check(counts.shown < counts.regions and stream.stats.hidden > 0, "узлы далёких областей убраны")
	_seams(stream)
	# 13.9+final: места областей на карте, их доски, задания и цели переживают сохранение.
	var towns: Array = game.world.region_places().list
	print("Поселений в областях: %d, направлений: %d" % [towns.size(), game.world.region_places().routes.size()])
	var quest_title := ""
	var goal_key := ""
	if not towns.is_empty():
		var town: Dictionary = towns[0]
		goal_key = town.id
		check(main.hud.all_places().any(func(p: Dictionary) -> bool: return p.key == town.id) and not game.world.place(town.id).is_empty(),
			"поселение области в списке мест и в индексе мира")
		main.hud.set_goal(main.hud.all_places().filter(func(p: Dictionary) -> bool: return p.key == town.id)[0])
		var offers: Array = game._offers(town.src)
		check(not offers.is_empty(), "доска поселения области предлагает задания")
		if not offers.is_empty():
			game.quests.accept(offers[0])
			quest_title = offers[0].title
	var map: Hud.BigMap = main.hud.big_map
	map.size = Vector2(1280, 720)
	var before_k: float = map._frame()[2]
	var cursor := Vector2(900, 300)
	var cell: Vector2 = (cursor - map._frame()[0]) / before_k
	map._zoom_at(cursor, 1.25)
	var f: Array = map._frame()
	check(f[2] > before_k and ((cursor - f[0]) / float(f[2])).distance_to(cell) < 0.01, "колесо приближает карту вокруг курсора")
	map.reset_view()
	# Взятое задание само ставит свою цель: проверяется та, что была при сохранении.
	goal_key = main.hud.goal.get("key", "")
	print("Цель при сохранении: ", goal_key)
	# Сохранение вдали и новая игровая сцена из него.
	var saved := game.save_state()
	check(Saves.write_slot(saved) == OK, "сохранение вдали от плана записано")
	var at := Vector3(game.player.x, game.player.feet, game.player.z)
	var regions_before: int = counts.regions
	var here := Vector2i(floori(at.x / TILE / WorldData.REGION_SIZE), floori(at.z / TILE / WorldData.REGION_SIZE))
	var here_hash := hash(stream.ledger.regions[here].fields.h)
	game.queue_free()
	await process_frame
	main.hud.clear_world()
	_start(Saves.read_slot(saved.seed).data)
	for k in 20:
		await process_frame
	stream = game.regions
	check(Vector2(game.player.x - at.x, game.player.z - at.z).length() < 0.1, "после загрузки игрок там же, в соседней области")
	check(stream.counts().regions >= regions_before and stream.ledger.regions.has(here)
		and stream.ledger.regions[here].has("fields") and hash(stream.ledger.regions[here].fields.h) == here_hash,
		"закреплённые области восстановлены с диска, не перестроены")
	check(absf(game.heights.ground_at(at.x, at.z) - at.y) < 2.0 or game.heights.depth_at(at.x, at.z) > 0.0,
		"земля под игроком после загрузки та же")
	if not goal_key.is_empty():
		check(main.hud.goal.get("key") == goal_key, "цель в соседней области восстановлена")
	if not quest_title.is_empty():
		check(game.quests.active.title == quest_title, "задание из поселения области восстановлено")
	# Назад к плану: поля ближних областей читаются с диска, узлы строятся снова.
	check(await _travel(game.player.x, home, z), "обратный путь к стартовому плану пройден")
	var back: Dictionary = stream.ledger.regions[near_key]
	check(back.has("fields") and hash(back.fields.h) == near_hash and stream.stats.loaded > 0,
		"при возвращении поля области прочитаны с диска без изменений")
	check(stream.counts().shown > 0, "узлы ближних областей снова показаны")
	var mem_home := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	print("Дома: %s; память %.0f МБ (вдали было %.0f)" % [stream.counts(), mem_home, mem_far])
	check(mem_home < mem_far + 150.0, "память не растёт без предела при возвращении")
	print("Кадр: наибольший %.0f мс, дольше 100 мс — %d; ожидание на границах — %d кадров" % [frame_max, slow_frames, waited])
	check(frame_max < 1500.0, "нет длинных остановок кадра")
	print("Время: %.0f с" % ((Time.get_ticks_msec() - started) / 1000.0))
	game.queue_free()
	await process_frame
	_remove(dir)
	print("region_travel_test: %d failures" % fails)
	quit(1 if fails else 0)


func _start(saved: Dictionary) -> void:
	game = load("res://scenes/game_world.tscn").instantiate()
	main.add_child(game)
	game.start(loaded, main.hud, saved)
	if game.opening_active():
		game._finish_opening()
	_last = Time.get_ticks_usec()


## Идти вдоль z от x0 к x1 шагами STEP; за край готовой земли — только когда область закреплена.
func _travel(x0: float, x1: float, z: float) -> bool:
	var x := x0
	_last = Time.get_ticks_usec() # загрузка сцены — не задержка пути
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while absf(x1 - x) > 0.01:
		if Time.get_ticks_msec() > deadline:
			return false
		var next := move_toward(x, x1, STEP)
		if game.world.accessible(next / TILE, z / TILE) and game.heights.known(next, z):
			x = next
		else:
			waited += 1
		game.bike.speed = 0.0
		game.player.x = x
		game.player.z = z
		game.player.feet = game.heights.surface_at(x, z, INF)
		if game.bike.riding:
			game.bike.x = x
			game.bike.z = z
			game.bike.y = game.player.feet
		await process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - _last) / 1000.0
		_last = now
		frame_max = maxf(frame_max, ms)
		slow_frames += int(ms > 100.0)
	return true


## Швы: перепад земли через границу области не больше, чем рядом с ней внутри области
func _seams(stream: RegionStream) -> void:
	var worst := 0.0
	var inside := 0.0
	var h := game.heights
	var plan := Rect2i(0, 0, game.world.W, game.world.H)
	for key: Vector2i in stream.ledger.regions:
		# Шов между двумя областями с полями в памяти или между областью и планом.
		var west: Variant = stream.ledger.regions.get(key + Vector2i.LEFT)
		var west_known: bool = plan.has_point((key + Vector2i.LEFT) * WorldData.REGION_SIZE) or west != null and west.has("fields")
		if not stream.ledger.regions[key].has("fields") or not west_known:
			continue
		var rect := Rect2i(key * WorldData.REGION_SIZE, Vector2i.ONE * WorldData.REGION_SIZE)
		var bx := rect.position.x * TILE
		for k in range(4, rect.size.y - 4, 4):
			var z := (rect.position.y + k + 0.5) * TILE
			if h.depth_at(bx - TILE, z) > 0.0 or h.depth_at(bx + TILE, z) > 0.0:
				continue
			worst = maxf(worst, absf(h.ground_at(bx - TILE * 0.5, z) - h.ground_at(bx + TILE * 0.5, z)))
			inside = maxf(inside, absf(h.ground_at(bx + TILE * 1.5, z) - h.ground_at(bx + TILE * 2.5, z)))
	print("Швы: наибольший перепад через границу %.2f м, рядом внутри %.2f м" % [worst, inside])
	check(worst <= maxf(1.0, inside * 2.0), "на границах областей нет ступенек")


func _remove(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for sub: String in DirAccess.get_directories_at(path):
		_remove(path.path_join(sub))
	for file: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
