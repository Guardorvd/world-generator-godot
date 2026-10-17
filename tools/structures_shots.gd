extends SceneTree
## Снимки мостов и туннелей: запускает игру, ставит велосипед перед каждым мостом и туннелем,
## проезжает по нему и снимает въезд и середину. Нужно окно (не headless). Запуск из папки проекта:
##   godot --path . --script res://tools/structures_shots.gd -- <зерно> <размер> <папка для снимков>

var main: Node
var frames := 0
var index := -1      # какое сооружение снимаем
var phase := 0       # 0 — поставить велосипед, 1 — ждать въезда, 2 — ждать середины
var waited := 0.0


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _shot(name: String) -> void:
	var args := OS.get_cmdline_user_args()
	var dir: String = args[2] if args.size() > 2 else OS.get_user_data_dir()
	var path := dir.path_join(name + ".png")
	root.get_texture().get_image().save_png(path)
	print("Снимок: ", path)


func _process(delta: float) -> bool:
	var args := OS.get_cmdline_user_args()
	frames += 1
	if frames == 30:
		main.start_game(args[0] if args.size() > 0 else "Туман-4821", int(args[1]) if args.size() > 1 else 192)
	var game: GameWorld = main.game
	if game == null or game.player == null or game.time < 0.5:
		return false
	var list := game.heights.structures
	if index < 0:
		index = 0
		print("Мостов %d, туннелей %d" % [game.world.bridges.size(), game.world.tunnels.size()])
	if index >= list.size():
		return true
	var s: Dictionary = list[index]
	var name := "%d_%s" % [index, "tunnel" if s.tunnel else "bridge"]
	var t: float = (game.player.x - s.ax) * s.ux + (game.player.z - s.az) * s.uz
	waited += delta
	if phase == 0:
		if not game.bike.riding:
			game.bike.x = game.player.x
			game.bike.z = game.player.z
			game.toggle_bike()
		var b := game.bike
		b.x = s.ax - s.ux * 14.0
		b.z = s.az - s.uz * 14.0
		b.y = game.heights.surface_at(b.x, b.z, s.ay)
		b.heading = atan2(-s.ux, -s.uz)
		b.speed = 0.0
		game.yaw = b.heading
		game.pitch = -0.15
		phase = 1
		waited = 0.0
		Input.action_press("move_forward")
	elif phase == 1 and (t > -6.0 or waited > 8.0):
		_shot(name + "_enter")
		phase = 2
	elif phase == 2 and (t > s.len * 0.5 or waited > 30.0):
		_shot(name + "_middle")
		print("%s: %.0f м, ноги %.1f м, настил или пол %.1f м" % [name, s.len, game.player.feet, game.heights.level(s, t)])
		Input.action_release("move_forward")
		index += 1
		phase = 0
	return false
