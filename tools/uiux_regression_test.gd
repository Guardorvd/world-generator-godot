extends SceneTree
## Регрессия контекстных подсказок, закрепления сводки и защиты цели на карте.

var failures := 0

func check(ok: bool, message: String) -> void:
	print(("OK " if ok else "FAIL ") + message)
	if not ok:
		failures += 1

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var hud: Hud = main.get_node("%Hud")
	main.get_node("%Menu").hide()
	hud.show()
	var world := WorldData.new()
	world.W = 64
	world.H = 64
	world.N = 4096
	var map := Image.create(8, 8, false, Image.FORMAT_RGB8)
	hud.set_world(world, map)
	await process_frame
	hud.set_hints([], [["F", "Сесть"]])
	check(hud.prompt.visible and hud.get_node("Crosshair").visible and not hud.summary_visible(), "контекстная подсказка видна без сводки")
	hud.set_hints([], [])
	check(not hud.prompt.visible and not hud.get_node("Crosshair").visible, "пустая подсказка скрыта")
	hud.set_summary_blocked(true)
	hud.set_hints([], [["F", "Поставить"]], true)
	check(hud.prompt.visible, "срочная подсказка установки велосипеда видна при блокировке сводки")
	hud.set_photo_mode(true)
	check(not hud.prompt.visible, "подсказка скрывается в режиме фото")
	hud.set_photo_mode(false)
	hud.set_summary_blocked(false)
	Input.action_press("show_hud")
	await process_frame
	await process_frame
	Input.action_release("show_hud")
	await process_frame
	check(hud.summary_visible(), "сводка остаётся после отпускания")
	Input.action_press("show_hud")
	await process_frame
	await process_frame
	Input.action_release("show_hud")
	await process_frame
	check(not hud.summary_visible(), "повторное нажатие скрывает сводку")
	hud.set_goal(Hud.marker_goal(Vector2(3, 4)))
	hud.set_map_visible(true)
	await process_frame
	var at := hud.big_map.size * 0.5
	_map_click(hud.big_map, at, false)
	check(hud.goal.x == 3 and hud.goal.y == 4, "обычный клик по пустой карте сохраняет цель")
	_map_click(hud.big_map, at, true)
	check(hud.goal.kind == "marker" and hud.goal.x != 3, "Ctrl-клик ставит свободную метку")
	var close_count := [0]
	hud.map_close_requested.connect(func() -> void: close_count[0] += 1)
	(hud.big_map.get_child(0) as Button).pressed.emit()
	check(close_count[0] == 1, "кнопка закрытия карты отправляет запрос")
	main.queue_free()
	await process_frame
	print("UIUX failures: ", failures)
	quit(1 if failures else 0)

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
