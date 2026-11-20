extends SceneTree

var failures := 0

func check(condition: bool, message: String) -> void:
	print(("OK " if condition else "FAIL ") + message)
	if not condition: failures += 1

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var carousel = main.get_node("%Carousel")
	var artwork: Control = carousel.get_node("Card/Slide/Frame/Artwork")
	var map: TextureRect = artwork.get_node("Art/Map")
	check(carousel.get_parent() == main.get_node("%Menu"), "карта расположена отдельно от навигации")
	var art: Control = artwork.get_node("Art")
	check(absf(art.size.x - art.size.y) < 1.0, "окно карты квадратное")
	check(map.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "карта не обрезается")
	var old_size := root.size
	for viewport_size: Vector2i in [Vector2i(1280, 720), Vector2i(800, 600), Vector2i(640, 360)]:
		root.size = viewport_size
		main._fit_menu()
		await process_frame
		var panel: Control = main.get_node("%Menu/Panel")
		var lab: Control = main.get_node("%TrailLab")
		var card_rect: Rect2 = carousel.get_global_rect()
		var panel_rect := panel.get_global_rect()
		var lab_rect := lab.get_global_rect()
		check(carousel.visible and is_equal_approx(card_rect.position.x, lab_rect.position.x)
			and is_equal_approx(card_rect.position.y, 28.0) and is_equal_approx(lab_rect.end.y, root.get_visible_rect().size.y - 28.0),
			"отступы карты и лаборатории при %s" % viewport_size)
		check(card_rect.end.y <= panel_rect.position.y + 0.1 and panel_rect.end.y <= lab_rect.position.y + 0.1,
			"карта, меню и лаборатория не перекрываются при %s" % viewport_size)
	root.size = old_size
	main._fit_menu()
	await process_frame
	check(carousel.get_node_or_null("Strip") == null, "лента миниатюр отсутствует")
	var many: Array[Dictionary] = []
	for i in 12: many.append({seed = "Тест-%d" % i, texture = null})
	carousel.set_entries(many, "Тест-0")
	check(carousel._count.text == "1 / 12", "счётчик не ограничен восемью мирами")
	var entries: Array[Dictionary] = [{seed = "Один", texture = null, favorite = false}, {seed = "Два", texture = null, favorite = true}]
	main._world_cards["Один"] = {seed = "Один", summary = "", ready = false}
	main._world_cards["Два"] = {seed = "Два", summary = "", ready = false}
	main._carousel_seeds.assign(["Один", "Два"])
	carousel.set_entries(entries, "Один")
	carousel.move(1)
	check(carousel.selected_index() == 1 and carousel._count.text == "2 / 2", "стрелка выбирает мир и обновляет счётчик")
	var received := [""]
	carousel.favorite_requested.disconnect(main._on_star)
	carousel.favorite_requested.connect(func(seed: String, _source: Control) -> void: received[0] = seed)
	carousel._favorite.pressed.emit()
	check(received[0] == "Два", "звёздочка передаёт выбранный мир")
	carousel._set_mode(1)
	check(carousel._placeholder.visible and not carousel._hint.text.is_empty(), "непостроенная карта имеет заглушку")
	carousel.play_requested.disconnect(main._on_start)
	var played := [false]
	carousel.play_requested.connect(func() -> void: played[0] = true)
	var enter := InputEventAction.new()
	enter.action = "ui_accept"
	enter.pressed = true
	carousel._card_input(enter)
	check(played[0], "Enter на карте запрашивает запуск")
	played[0] = false
	var double_click := InputEventMouseButton.new()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.double_click = true
	carousel._card_input(double_click)
	check(played[0], "двойной щелчок по карте запрашивает запуск")
	played[0] = false
	carousel._placeholder.gui_input.emit(double_click)
	check(played[0], "двойной щелчок по заглушке тоже запускает выбранный мир")
	main._open_all_worlds()
	check(main._is_screen("world_hub") and main.get_node("%SeedEdit").is_visible_in_tree(), "создание доступно в общем экране миров")
	check(main.get_node("%SeedEdit").has_focus(), "поле создания получает фокус")
	main._return_to_menu_screen()
	check(main._is_screen("menu") and main.get_node("%OpenWorlds").has_focus(), "возврат из экрана миров ведёт в меню")
	main.queue_free()
	await process_frame
	print("Menu showcase failures: ", failures)
	quit(1 if failures else 0)
