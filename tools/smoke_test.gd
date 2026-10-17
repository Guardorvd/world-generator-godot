extends SceneTree
## Дымовая проверка: открывает главную сцену, запускает игру с заданным зерном и размером,
## снимает точку появления, едет на велосипеде, немного идёт вперёд, открывает карту и сохраняет снимки экрана. Запуск из папки проекта:
##   godot --path . --script res://tools/smoke_test.gd -- <зерно> <размер> <папка для снимков>

var main: Node
var frames := 0
var started := 0
var ready_at := 0
var shots := {}


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _shot(name: String) -> void:
	var args := OS.get_cmdline_user_args()
	var dir: String = args[2] if args.size() > 2 else OS.get_user_data_dir()
	var path := dir.path_join(name + ".png")
	root.get_texture().get_image().save_png(path)
	print("Снимок: ", path)


func _process(_delta: float) -> bool:
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
	if game.time > 3.0 and not shots.has("bike"):
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
		return true
	return false
