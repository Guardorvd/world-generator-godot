extends SceneTree
## Visual contrast review against deliberately light and dark backgrounds.
const Journal = preload("res://scripts/ui/journal_panel.gd")
const Shop = preload("res://scripts/ui/shop_panel.gd")
const OUTPUT := "res://.godot/ui11-visual"
var failures := 0

func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		failures += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 45)
	root.size = Vector2i(1280, 720)
	_run.call_deferred()

func _shot(name: String) -> void:
	await process_frame
	await create_timer(0.2).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUTPUT.path_join(name + ".png"))

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	var background := ColorRect.new()
	background.color = Color("#e6d9a4")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(background)
	var panel := Journal.new()
	root.add_child(panel)
	panel.data_provider = func() -> Dictionary: return {seed = "Туман-4821", template_id = WorldTemplate.DEFAULT_ID, pages = [], groups = []}
	panel.enable_shop(Shop.Progress.new())
	panel.open_tab(Journal.Tab.MAP, "Туман-4821")
	await _shot("map-light")
	panel._select(Journal.Tab.PATH)
	await _shot("journal-light")
	panel._select(Journal.Tab.MAP)
	panel._select(Journal.Tab.PATH)
	_check(is_equal_approx(panel._map_page.modulate.a, 1.0), "быстрое переключение возвращает непрозрачность предыдущей вкладке")
	panel._select(Journal.Tab.ALBUM)
	await _shot("album-light")
	_check(is_equal_approx(panel._album_page.modulate.a, 1.0), "переход завершается и оставляет текст читаемым")
	panel._select(Journal.Tab.SHOP)
	while panel.shop_panel.is_processing():
		await process_frame
	await _shot("shop-light")
	panel.shop_panel._fitting_button.button_pressed = true
	await _shot("fitting-light")
	_check(panel.shop_panel._scroll.scroll_vertical == 0 and panel.shop_panel._scroll.get_global_rect().encloses(panel.shop_panel._stage.get_global_rect()), "примерочная открывается с видимой моделью")
	background.color = Color("#08161b")
	await _shot("fitting-dark")
	panel.queue_free()
	background.queue_free()
	await process_frame
	quit(1 if failures else 0)
