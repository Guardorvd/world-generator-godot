extends SceneTree
## Проверка вкладок планшета без загрузки игрового мира и пользовательских сохранений.

var failures := 0

func _check(condition: bool, message: String) -> void:
	print(("PASS " if condition else "FAIL ") + message)
	if not condition:
		failures += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	root.size = Vector2i(1280, 720)
	_run.call_deferred()

func _run() -> void:
	var panel = preload("res://scripts/ui/journal_panel.gd").new()
	root.add_child(panel)
	panel.data_provider = func() -> Dictionary:
		return {seed = "test", template_id = WorldTemplate.DEFAULT_ID}
	panel.open_tab(panel.Tab.PATH, "test")
	await process_frame
	await process_frame
	_check(panel._path_center.is_visible_in_tree() and not panel._map_page.visible, "лента отдельно от карты")
	_check(panel._feed_view._wide_cards, "в игре используются полные карточки ленты")
	_check(panel._path_page.size.x > 600 and absf(panel._path_page.get_global_rect().get_center().x - 640.0) < 2.0, "лента находится по центру")
	var folder := "user://journal_layout_test/" + str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(folder)
	var fixture = preload("res://scripts/game/ride_feed.gd").new(folder)
	var entry := {id = "ride", version = fixture.VERSION, start = 1795600000, time = 1000, bike = 4200,
		seed = "test", template_id = WorldTemplate.DEFAULT_ID, walk = false,
		track = [[[0.0, 0.0], [100.0, 100.0]]]}
	_check(fixture.upsert(entry) == OK, "тестовая запись сохранена в отдельную папку")
	panel._feed_view.feed = fixture
	panel._feed_view.refresh()
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute("res://.godot/ui-redesign")
		root.get_texture().get_image().save_png("res://.godot/ui-redesign/journal.png")
	var feed = panel._feed_view
	feed._choose(fixture.entries[0])
	await process_frame
	var map_buttons: Array = feed._dialog.find_children("*", "Button", true, false).filter(func(node: Node) -> bool: return (node as Button).text == "Показать на карте мира")
	_check(map_buttons.size() == 1 and not (map_buttons[0] as Button).disabled, "подробности предлагают открыть маршрут")
	if not map_buttons.is_empty():
		(map_buttons[0] as Button).pressed.emit()
	await process_frame
	_check(panel.active_tab == panel.Tab.MAP and panel._map_page.visible and not panel._path_center.visible, "маршрут открывает вкладку карты")
	_check(panel.map_view._ride_frame.has_area(), "маршрут передан карте")
	panel._select(panel.Tab.PATH)
	await process_frame
	_check(panel._feed_view == feed and panel._path_center.visible and not panel._map_page.visible, "возврат сохраняет экземпляр ленты")
	panel._select_feed_ride({})
	_check(panel.active_tab == panel.Tab.PATH, "сброс выбранной записи не открывает карту")
	var small_view := SubViewport.new()
	small_view.size = Vector2i(400, 720)
	root.add_child(small_view)
	var small_panel = preload("res://scripts/ui/journal_panel.gd").new()
	small_view.add_child(small_panel)
	small_panel.data_provider = func() -> Dictionary: return {seed = "test", template_id = WorldTemplate.DEFAULT_ID}
	small_panel.open_tab(small_panel.Tab.PATH, "test")
	small_panel.enable_shop(preload("res://scripts/game/shop_progress.gd").new())
	await process_frame
	await process_frame
	_check(small_panel._tab_shop.get_global_rect().end.x <= 400 and small_panel._tab_path.text == "Поездки", "вкладки помещаются на узком экране")
	small_view.queue_free()
	panel.queue_free()
	await process_frame
	quit(1 if failures else 0)
