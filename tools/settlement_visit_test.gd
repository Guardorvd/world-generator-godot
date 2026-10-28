extends SceneTree
## Полная игровая сцена: E у костра, маршруты, велосипед, карта и пауза.
var fails := 0

func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	fails += int(not ok)

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	_run.call_deferred()

func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main.start_game("Север-1234", 256)
	var start := Time.get_ticks_msec()
	while main.game == null or main.game.player == null:
		if Time.get_ticks_msec() - start > 240000:
			push_error("Игра не загрузилась за 4 минуты")
			quit(1)
			return
		await process_frame
	var game: GameWorld = main.game
	game.set_paused(false)
	# с 11.0 игра начинается проездом на велосипеде: доску читают пешком
	if game.opening_active():
		game._finish_opening()
	if game.bike.riding:
		game.bike.speed = 0.0
		game.bike.airborne = false
		game.toggle_bike()
	var settlement := PlayerState.home(game.world)
	print("HOUSES ", game.world.settlements.map(func(s: Dictionary) -> int: return s.huts.size()))
	check(game.world.settlements.size() <= 4, "малый мир не превышает прежний максимум поселений")
	check(InputMap.has_action("interact"), "действие E зарегистрировано")
	# с 10.1 E действует на то, на что смотрит игрок: встать в 3 м перед доской и посмотреть на неё
	var board := SettlementsBuilder.board_foot(settlement, game.heights) + Vector3(0, 1.35, 0)
	game.player.x = board.x - 2.0
	game.player.z = board.z + 2.0
	game.player.feet = game.heights.ground_at(game.player.x, game.player.z)
	game._snap()
	var look := board - Vector3(game.player.x, game.player.feet + GameConfig.EYE, game.player.z)
	game.yaw = atan2(-look.x, -look.z)
	game.pitch = atan2(look.y, Vector2(look.x, look.z).length())
	game._update_camera(1.0, 0.0)
	check(game._aim().get("kind", "") == "board", "взгляд на доску выбирает её для E")
	var event := InputEventAction.new()
	event.action = "interact"
	event.pressed = true
	game._unhandled_input(event)
	check(game._settlement_open() and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "E у костра открывает доску и освобождает мышь")
	var old_pos := Vector2(game.player.x, game.player.z)
	Input.action_press("move_forward")
	game._physics_process(1.0 / 60.0)
	Input.action_release("move_forward")
	check(old_pos == Vector2(game.player.x, game.player.z), "во время выбора маршрута игрок не движется")
	await process_frame
	await process_frame
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() != "headless" and not args.is_empty():
		root.get_texture().get_image().save_png(args[0].path_join("settlement_panel.png"))
	var routes: Array = game.hud.places().filter(func(p: Dictionary) -> bool: return p.kind == "settlement" and settlement.connections.has(p.src.i))
	check(not routes.is_empty(), "у поселения есть подтверждённый выход по дороге")
	if not routes.is_empty():
		var chosen: Dictionary = routes[0]
		for node: Node in game.hud.settlement_panel._box.find_children("*", "Button", true, false):
			if node is Button and node.text.begins_with(chosen.name):
				node.pressed.emit()
				break
		check(game.hud.goal.get("key") == chosen.key and not game._settlement_open(), "кнопка маршрута ставит цель на компасе и закрывает доску")
	# 11.9: задание доставки — сумка у доски, E по ней, сумка за спиной, без быстрого перемещения
	game._open_settlement(settlement)
	var take: Array = game.hud.settlement_panel.find_children("*", "Button", true, false).filter(
		func(b: Button) -> bool: return b.tooltip_text == "Взять задание: доставка")
	check(take.size() == 1, "на доске есть задание доставки")
	if take.size() == 1:
		take[0].pressed.emit()
		check(game.quests.active.get("kind") == "delivery" and game._bag != null and game._bag.visible and not game._settlement_open(), "доставка взята, сумка у доски")
		var bag: Vector3 = game._bag.position
		game.player.x = bag.x + 1.5
		game.player.z = bag.z + 1.5
		game.player.feet = game.heights.ground_at(game.player.x, game.player.z)
		game._snap()
		var to_bag := bag - Vector3(game.player.x, game.player.feet + GameConfig.EYE, game.player.z)
		game.yaw = atan2(-to_bag.x, -to_bag.z)
		game.pitch = atan2(to_bag.y, Vector2(to_bag.x, to_bag.z).length())
		game._update_camera(1.0, 0.0)
		check(game._aim().get("kind", "") == "cargo", "взгляд на сумку выбирает её для E")
		if DisplayServer.get_name() != "headless" and not args.is_empty():
			await process_frame
			await process_frame
			root.get_texture().get_image().save_png(args[0].path_join("quest_bag.png"))
		game._unhandled_input(event)
		check(game.quests.cargo and not game._bag.visible and game.hud.goal.get("key") == game.quests.active.target.key, "E надевает сумку, цель — поселение доставки")
		var before := Vector2(game.player.x, game.player.z)
		game.travel_to(game.quests.active.target)
		check(before == Vector2(game.player.x, game.player.z), "с сумкой быстрое перемещение недоступно")
		if DisplayServer.get_name() != "headless" and not args.is_empty():
			game.hud.update_tracker()
			await process_frame
			await process_frame
			root.get_texture().get_image().save_png(args[0].path_join("quest_in_game.png"))
	game.bike.x += 150.0
	game._open_settlement(settlement)
	game.hud.settlement_panel.bike_requested.emit()
	check(game.bike.distance_to(game.player) < 3.0 and not game.bike.riding, "оставленный велосипед возвращается рядом с игроком")
	game._open_settlement(settlement)
	game._unhandled_input(event)
	check(not game._settlement_open(), "повторное E закрывает доску")
	game._open_settlement(settlement)
	game.toggle_map()
	check(game.show_map and not game._settlement_open(), "карта закрывает доску без двух перекрывающихся экранов")
	game.toggle_map()
	game._open_settlement(settlement)
	game.set_paused(true)
	check(not game._settlement_open() and game.paused, "пауза закрывает доску и сохраняет свободный курсор")
	if DisplayServer.get_name() != "headless" and not args.is_empty():
		var center := Vector3(settlement.x * GameConfig.TILE, game.heights.ground_at(settlement.x * GameConfig.TILE, settlement.y * GameConfig.TILE), settlement.y * GameConfig.TILE)
		game.camera.look_at_from_position(center + Vector3(16, 11, 18), center, Vector3.UP)
		await process_frame
		await process_frame
		root.get_texture().get_image().save_png(args[0].path_join("settlement_overview.png"))
	game.set_paused(false)
	game._open_settlement(settlement)
	game.hud.clear_world()
	check(not game.hud.settlement_panel.visible, "выход из мира очищает доску маршрутов")
	main.queue_free()
	await process_frame
	quit(1 if fails else 0)
