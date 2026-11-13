extends SceneTree
## Карточки, навигация и размеры главного меню без генерации.

const Saves := preload("res://scripts/game/save_game.gd")
const Main := preload("res://scenes/main.tscn")
const OUT := "res://.godot/menu_ui_look"
const SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(960, 720)]

var _main: Node
var _failures := 0
var _old_saves := ""
var _test_saves := ""
var _test_seeds: Array[String] = []


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var settings := GameContext.scope.settings
	settings.settings_path = OUT.path_join("settings-%d.cfg" % OS.get_process_id())
	_old_saves = Saves.dir
	_test_saves = OUT.path_join("saves-%d" % OS.get_process_id())
	Saves.dir = _test_saves
	_main = Main.instantiate()
	root.add_child(_main)
	if not _main.has_method("_chosen_seed"):
		push_error("Не удалось загрузить скрипт главного меню.")
		quit(1)
		return
	_check(_main._chosen_seed() == RecommendedSeeds.SEEDS[0].seed, "на первом запуске выбран мир от автора")
	await _capture_state("new")
	_fixture("Долина-27", 1700000300)
	_main._refresh_world_cards()
	_main._pick_seed("Долина-27")
	_check(_main.get_node("%Start").text.begins_with("Продолжить"), "предлагает продолжить сохранённый мир")
	await _capture_state("saved")
	for i in range(1, 8):
		_fixture("Мир-%d" % i, 1700000300 + i)
	_main._refresh_world_cards()
	_main._pick_seed("Мир-7")
	_check(_main._carousel_seeds.size() == 8 and _main._carousel_seeds[0] == "Мир-7", "восемь миров по дате сохранения")
	await _capture_state("eight")
	await _navigation()
	# Битый файл без резервной копии узнаётся по зерну из недавних.
	var broken := "Сохранение-с-очень-длинным-именем"
	_test_seeds.append(broken)
	var file := FileAccess.open(Saves.path_for(broken), FileAccess.WRITE)
	file.store_string("broken")
	file.close()
	settings.recent_seeds.append(broken)
	_main._refresh_world_cards()
	_main._pick_seed(broken)
	_check(_main.get_node("%Start").text == "Все миры", "повреждённый слот ведёт к управлению мирами")
	await _capture_state("corrupt")
	_main._on_start()
	_check(_main.get_node("%AllWorlds").visible and _main.get_node("%RestartWorld").has_focus() and not _main.busy,
		"доступно восстановление через пересоздание")
	_main._return_to_menu_screen()
	_main._pick_seed("Мир-6")
	var previous_index: int = _main._carousel_seeds.find("Мир-6")
	_main._do_delete_world("Мир-6")
	var chosen: String = _main._chosen_seed()
	_check(chosen != "Мир-6" and chosen == _main._carousel_seeds[previous_index],
		"при удалении выбран сосед (%s)" % chosen)
	_main._open_new_world()
	await _capture_screen("create", "%NewWorld")
	_main._open_all_worlds()
	await _capture_screen("worlds", "%AllWorlds")
	_main.get_node("%Title").text = "Мир «Сохранение-с-очень-длинным-именем»"
	_main.get_node("%LoadPlaceholder").text = "Сохранение-с-очень-длинным-именем"
	_main.get_node("%LoadPlaceholder").show()
	_main._set_progress(0.52, "Рельеф и вода\nПрошло: 0:24")
	_main._show("loading")
	await _capture_screen("loading", "%Loading")
	_main._show("pause")
	_main.get_node("%Back").show()
	await _capture_screen("pause", "%Pause")
	_main.queue_free()
	await process_frame
	for seed_text in _test_seeds:
		Saves.delete_seed(seed_text)
	DirAccess.remove_absolute(_test_saves)
	if FileAccess.file_exists(settings.settings_path):
		DirAccess.remove_absolute(settings.settings_path)
	Saves.dir = _old_saves
	print("MENU_UI failures=", _failures)
	quit(int(_failures > 0))


func _fixture(seed_text: String, saved_at: int) -> void:
	_test_seeds.append(seed_text)
	var quests := preload("res://scripts/game/quests.gd").new()
	var data := {format = 1, seed = seed_text, signature = "menu-stand", saved_at = saved_at,
		visited = {"settlement:1": true}, goal = "", quest = quests.save_state(),
		player = {x = 0.0, z = 0.0, feet = 0.0, yaw = 0.0, pitch = 0.0, hour = 9.0},
		bike = {x = 0.0, z = 0.0, y = 0.0, heading = 0.0, riding = true}}
	_check(Saves.write_slot(data) == OK, "сохранение стенда: " + seed_text)


func _capture_state(label: String) -> void:
	await _capture_screen(label, "%Menu")


func _capture_screen(label: String, screen_path: String) -> void:
	for dimensions: Vector2i in SIZES:
		root.size = dimensions
		await process_frame
		await process_frame
		var panel: Control = _main.get_node(screen_path + "/Panel")
		_check(root.get_visible_rect().encloses(panel.get_global_rect()), "%s %s помещается" % [label, dimensions])
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var path := OUT.path_join("%s_%dx%d.png" % [label, dimensions.x, dimensions.y])
			_check(image.get_size() == dimensions and image.save_png(path) == OK, path)


func _navigation() -> void:
	var start: Button = _main.get_node("%Start")
	start.grab_focus()
	var before: int = _main._card_reads
	var selected: String = _main._chosen_seed()
	var direction := InputEventAction.new()
	direction.action = &"ui_right"
	direction.pressed = true
	root.push_input(direction)
	_check(_main._chosen_seed() != selected and start.has_focus(), "стрелка листает с главной кнопки")
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_DPAD_UP
	pad.pressed = true
	root.push_input(pad)
	_check(root.gui_get_focus_owner().theme_type_variation == &"CarouselTab", "геймпад переводит фокус к карточкам")
	var card: Button = root.gui_get_focus_owner()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	card.gui_input.emit(wheel)
	_check(_main._card_reads == before, "переключение карточек без чтения диска")
	pad.button_index = JOY_BUTTON_DPAD_DOWN
	root.push_input(pad)
	_check(start.has_focus(), "вниз возвращает к запуску")
	root.push_input(pad)
	_check(_main.get_node("%OpenNew").has_focus(), "из запуска можно перейти к пунктам меню")
	_main._open_new_world()
	_check(_main.get_node("%CreateWorld").has_focus(), "экран нового мира доступен")
	var cancel := InputEventJoypadButton.new()
	cancel.button_index = JOY_BUTTON_B
	cancel.pressed = true
	root.push_input(cancel)
	await process_frame
	_check(start.has_focus() and _main.get_node("%Menu").visible, "B возвращает в главное меню")
	_main._open_all_worlds()
	_check(_main.get_node("%AllWorlds").visible and _main.get_node("%Storage").is_visible_in_tree(), "все миры и хранилище доступны")
	_main._return_to_menu_screen()
	_main._open_settings()
	_check(_main.get_node("%Done").has_focus(), "настройки доступны")
	_main._show("menu")


func _check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	_failures += int(not ok)
