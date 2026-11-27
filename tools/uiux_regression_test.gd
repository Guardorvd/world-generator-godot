extends SceneTree
## Регрессия HUD при удержании и защиты цели на большой карте.

var failures := 0

func check(ok: bool, message: String) -> void:
	print(("OK " if ok else "FAIL ") + message)
	if not ok:
		failures += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 15)
	_run.call_deferred()

func _run() -> void:
	var test_dir := "res://.godot/uiux_regression_test"
	DirAccess.make_dir_recursive_absolute(test_dir)
	GameContext.scope.settings.settings_path = test_dir.path_join("settings.cfg")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var pause_controls := main.get_node("%PauseControlsToggle") as Button
	var pause_box := main.get_node("%Pause/Panel/Box")
	check(not pause_box.get_node("ControlsBox").visible, "список управления в паузе сначала скрыт")
	pause_controls.button_pressed = true
	check(pause_box.get_node("ControlsBox").visible and not pause_box.get_node("SavePanel").visible and pause_controls.text == "Назад к паузе", "управление открывается отдельным состоянием паузы")
	pause_controls.button_pressed = false
	check(not pause_box.get_node("ControlsBox").visible and pause_box.get_node("SavePanel").visible, "из управления можно вернуться к действиям паузы")
	var hud: Hud = main.get_node("%Hud")
	# Магазин не участвует в сценарии: не начинать фоновую загрузку портретов перед завершением теста.
	hud.journal_panel._tab_shop.hide()
	main.get_node("%Menu").hide()
	hud.show()
	var world := WorldData.new()
	world.W = 64
	world.H = 64
	world.N = 4096
	var map := Image.create(8, 8, false, Image.FORMAT_RGB8)
	hud.set_world(world, map)
	await process_frame
	check(not hud.summary_requested() and not hud.minimap.visible and not hud._ride.visible, "игровой HUD скрыт при старте")
	hud.set_hints([], [["F", "Сесть"]])
	check(not hud.prompt.visible and not hud.get_node("Crosshair").visible, "подсказка при наведении скрыта")
	await _hold_hud(true)
	await create_timer(Hud.SUMMARY_FADE + 0.04).timeout
	check(hud.summary_requested() and hud.minimap.visible and hud._ride.visible and not hud.compass.visible and not hud.hint.visible,
		"удержание открывает компактную сводку без компаса и подсказок")
	await _hold_hud(false)
	check(not hud.summary_requested(), "отпускание завершает режим просмотра")
	await create_timer(Hud.SUMMARY_HIDE + 0.04).timeout
	check(not hud.minimap.visible and not hud._ride.visible, "после отпускания сводка погасла")
	hud.toast("Тестовая подсказка")
	check(hud._toast_left == 0.0, "в обычном режиме подсказка не появляется как уведомление")
	hud.toast("Открыта деревня", &"discovery")
	check(hud._toast_left > 0.0, "уведомление об открытии места остаётся")
	hud._toast_left = 0.0
	hud.toast("Задание выполнено", &"quest")
	await process_frame
	await process_frame
	check(hud.toast_label.text == "Задание выполнено" and hud.get_node("Toast").visible, "завершение задания видно без удержания сводки")
	hud._toast_left = 0.0
	hud.toast("Груз повреждён", &"warning")
	await process_frame
	await process_frame
	check(hud.toast_label.text == "Груз повреждён" and hud.get_node("Toast").visible, "предупреждение видно без удержания сводки")
	hud.set_hints([], [])
	check(not hud.prompt.visible and not hud.get_node("Crosshair").visible, "пустая подсказка скрыта")
	hud.set_summary_blocked(true)
	hud.set_hints([], [["F", "Поставить"]], true)
	check(hud.prompt.visible, "срочная подсказка установки велосипеда видна при блокировке сводки")
	hud.set_photo_mode(true)
	check(not hud.prompt.visible, "подсказка скрывается в режиме фото")
	hud.set_photo_mode(false)
	hud.set_summary_blocked(false)
	await _hold_hud(true)
	hud.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(not hud.summary_requested() and not hud.minimap.visible, "потеря фокуса сбрасывает удержание")
	await _hold_hud(false)
	hud.set_goal(Hud.marker_goal(Vector2(3, 4)))
	hud.set_map_visible(true)
	await process_frame
	await _hold_hud(true)
	check(not hud.summary_requested() and hud.big_map.visible, "удержание Tab не перехватывает открытую большую карту")
	await _hold_hud(false)
	var at := hud.big_map.size * 0.5
	_map_click(hud.big_map, at, false)
	check(hud.goal.x == 3 and hud.goal.y == 4, "обычный клик по пустой карте сохраняет цель")
	_map_click(hud.big_map, at, true)
	check(hud.goal.kind == "marker" and hud.goal.x != 3, "Ctrl-клик ставит свободную метку")
	var close_count := [0]
	hud.map_close_requested.connect(func() -> void: close_count[0] += 1)
	hud.journal_panel._close.pressed.emit()
	check(close_count[0] == 1, "кнопка закрытия карты отправляет запрос")
	var game: GameWorld = preload("res://scenes/game_world.tscn").instantiate()
	root.add_child(game)
	game.hud = hud
	game._captured_at = 0
	game._finish_travel("Прибытие", true)
	check(game._captured_at > 0, "после переноса с доски возвращается управление взглядом")
	game.free()
	hud.ask_travel({name = "Пункт", x = 4.0, y = 4.0})
	hud.clear_world()
	check(hud._travel_dialog == null, "выход из мира закрывает подтверждение переноса")
	main.queue_free()
	await process_frame
	print("UIUX failures: ", failures)
	quit(1 if failures else 0)

func _hold_hud(pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = &"show_hud"
	event.pressed = pressed
	Input.parse_input_event(event)
	await process_frame

func _map_click(map: Control, at: Vector2, ctrl: bool) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = at
	press.ctrl_pressed = ctrl
	press.pressed = true
	map._gui_input(press)
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	map._gui_input(release)
