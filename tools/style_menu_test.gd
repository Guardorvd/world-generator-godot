extends SceneTree
## Меню «Визуальный стиль» (Настройки → Графика) без генерации мира: элементы читают GameSettings, выключатель и ползунок
## меняют GameSettings и VisualStyle сразу, при выключении ползунок гаснет, сброс возвращает значения по умолчанию,
## файл настроек пишется (отдельный файл теста). Снимок группы — style_menu.png (нужно окно). Лимит 60 с.
##   godot --path . --script res://tools/style_menu_test.gd
const Options = preload("res://scripts/ui/display_options.gd")
const Main = preload("res://scripts/ui/main.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	if not ok:
		fails += 1


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	call_deferred("run")


func settle() -> void:
	for i in 4:
		await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw


func run() -> void:
	var settings := GameContext.scope.settings
	settings.settings_path = "res://.godot/style_menu_test/settings.cfg"
	DirAccess.make_dir_recursive_absolute("res://.godot/style_menu_test")
	settings.reset_defaults()
	root.size = Vector2i(1280, 720)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.set_script(null)
	root.add_child(main)
	main.set_script(Main)
	main.set_process(false)
	main.hud = main.get_node("%Hud")
	main.seed_edit = main.get_node("%SeedEdit")
	main.screens = {back = main.get_node("%Back"), menu = main.get_node("%Menu"), loading = main.get_node("%Loading"),
		pause = main.get_node("%Pause"), settings = main.get_node("%Settings")}
	main._setup_save_controls()
	var options := Options.new()
	options.setup(main)
	main.display_options = options
	main._sync_settings_controls()
	main._show("settings")
	options.tabs.current_tab = 1
	await settle()
	for id: String in VisualStyle.EFFECTS:
		check((options.style_on[id] as CheckBox).button_pressed == settings.style_on[id], "флажок «%s» читает настройки" % VisualStyle.TITLES[id])
		check(is_equal_approx((options.style_amount[id] as HSlider).value, settings.style_amount[id]), "ползунок «%s» читает настройки" % VisualStyle.TITLES[id])
	# ползунок: сразу в GameSettings и VisualStyle
	(options.style_amount.depth as HSlider).value = 0.3
	check(is_equal_approx(settings.style_amount.depth, 0.3) and is_equal_approx(VisualStyle.strength("depth"), 0.3), "ползунок «Планы» меняет настройки и стиль сразу")
	check((options.style_value.depth as Label).text == "30 %", "значение «Планы» показано (%s)" % (options.style_value.depth as Label).text)
	# выключатель: сила 0, ползунок недоступен, значение «выкл.»
	(options.style_on.grain as CheckBox).button_pressed = false
	check(not settings.style_on.grain and VisualStyle.strength("grain") == 0.0, "выключатель «Зерно» гасит эффект")
	check(not (options.style_amount.grain as HSlider).editable and (options.style_value.grain as Label).text == "выкл.", "при выключении ползунок недоступен")
	# запись на диск (через _settings_changed → таймер), затем чтение заново
	main._save_due = 0
	main._flush_settings()
	settings.reset_defaults()
	settings.load_settings()
	check(not settings.style_on.grain and is_equal_approx(settings.style_amount.depth, 0.3), "настройки стиля сохранились и читаются заново")
	# фото группы: прокрутить страницу вниз
	options.sync()
	var page: ScrollContainer = options.tabs.get_child(1)
	await settle()
	page.scroll_vertical = int(page.get_v_scroll_bar().max_value)
	await settle()
	if DisplayServer.get_name() != "headless":
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.godot/style_menu_test/style_menu.png"))
	# сброс
	main._do_reset_settings()
	check(settings.style_on == VisualStyle.DEFAULT_ON and settings.style_amount == VisualStyle.DEFAULT_AMOUNT, "сброс возвращает настройки стиля")
	var all_back := true
	for id: String in VisualStyle.EFFECTS:
		all_back = all_back and (options.style_on[id] as CheckBox).button_pressed and is_equal_approx((options.style_amount[id] as HSlider).value, VisualStyle.DEFAULT_AMOUNT[id])
		all_back = all_back and is_equal_approx(VisualStyle.strength(id), VisualStyle.DEFAULT_AMOUNT[id])
	check(all_back, "после сброса элементы и стиль показывают значения по умолчанию")
	DirAccess.remove_absolute(settings.settings_path)
	main.queue_free()
	await process_frame
	print("STYLE_MENU failures: ", fails)
	quit(1 if fails else 0)
