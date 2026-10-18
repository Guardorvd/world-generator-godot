extends SceneTree
## Дымовая проверка: открывает главную сцену, запускает игру с заданным зерном и размером,
## снимает точку появления, едет на велосипеде и прыгает, немного идёт вперёд, открывает карту, паузу и настройки и сохраняет снимки экрана. Запуск из папки проекта:
##   godot --path . --script res://tools/smoke_test.gd -- <зерно> <размер> <папка для снимков>

const ShotUtil := preload("res://tools/shot_util.gd")

var main: Node
var frames := 0
var started := 0
var ready_at := 0
var shots := {}
var failed := false
var done := false


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


## Сохраняет снимок; ошибка записи даёт код выхода 1
func _shot(name: String) -> void:
	var args := OS.get_cmdline_user_args()
	if not ShotUtil.save_png(root, args[2] if args.size() > 2 else OS.get_user_data_dir(), name):
		failed = true


## Завершает проверку с кодом 0 (всё прошло) или 1
func _finish() -> bool:
	done = true
	if failed:
		printerr("Дымовая проверка не прошла")
	else:
		print("Дымовая проверка прошла")
	quit(1 if failed else 0)
	return false


func _process(_delta: float) -> bool:
	if done:
		return false
	var args := OS.get_cmdline_user_args()
	frames += 1
	if frames == 400:
		_shot("menu")
		started = Time.get_ticks_msec()
		main.start_game(args[0] if args.size() > 0 else "Север-1234", int(args[1]) if args.size() > 1 else 256)
	if frames == 410:
		_shot("loading")
	var game: GameWorld = main.game
	if game == null or game.player == null:
		if started > 0 and Time.get_ticks_msec() - started > ShotUtil.LOAD_TIMEOUT_MS:
			printerr("Мир не загрузился за %d с" % (ShotUtil.LOAD_TIMEOUT_MS / 1000))
			failed = true
			return _finish()
		return false
	if ready_at == 0:
		ready_at = Time.get_ticks_msec()
		print("Мир готов за %d мс" % (ready_at - started))
	if game.time < 0.5:
		return false
	if not shots.has("spawn"):
		shots.spawn = true
		_shot("spawn")
		game.toggle_bike()
	Input.action_press("move_forward")
	if game.time > 2.0 and not shots.has("hop"):
		shots.hop = true
		Input.action_press("jump")
	elif game.time > 2.1:
		Input.action_release("jump")
	if game.bike.airborne and game.bike.air_time > 0.15 and not shots.has("bike_air"):
		shots.bike_air = true
		_shot("bike_air")
		print("В воздухе: ", game.bike.y - game.heights.ground_at(game.bike.x, game.bike.z), " м над землёй")
	if game.time > 3.0 and not shots.has("bike") and not game.bike.airborne:
		shots.bike = true
		_shot("bike")
		print("Велосипед: ", game.bike.x, ", ", game.bike.z, ", скорость ", game.bike.speed)
		game.toggle_bike()
	if game.time > 5.0 and not shots.has("walk"):
		shots.walk = true
		_shot("walk")
		print("Игрок: ", game.player.x, ", ", game.player.z, ", высота ", game.player.feet)
		Input.action_release("move_forward")
		game.toggle_map()
	elif game.time > 5.3 and not shots.has("map"):
		shots.map = true
		_shot("map")
		game.toggle_map()
		main._toggle_pause()
	elif shots.has("map") and not shots.has("pause"):
		shots.pause = true
		_shot("pause")
		main._open_settings()
	elif shots.has("pause") and not shots.has("settings"):
		shots.settings = true
		_shot("settings")
		return _finish()
	return false
