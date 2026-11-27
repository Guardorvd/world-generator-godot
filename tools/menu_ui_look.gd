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
	_check(_main._saved_seeds.size() == 8 and _main._saved_seeds[0] == "Мир-7", "восемь миров по дате сохранения")
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
	await _capture_screen("create", "%Menu")
	_main._cancel_new_world()
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
	_main.get_node("%PauseControlsToggle").button_pressed = true
	await _capture_screen("pause_controls", "%Pause")
	_main.get_node("%PauseControlsToggle").button_pressed = false
	await _clear_saves()
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


func _clear_saves() -> void:
	var orphan := Saves.path_for("неизвестное зерно", "manual") + ".bak"
	var temporary := Saves.path_for("прерванная запись") + ".tmp"
	for path in [orphan, temporary]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string("damaged")
		file.close()
	var unrelated := _test_saves.path_join("notes.txt")
	var notes := FileAccess.open(unrelated, FileAccess.WRITE)
	notes.store_string("keep")
	notes.close()
	var settings := GameContext.scope.settings
	settings.remember_seed("Долина-27")
	settings.toggle_favorite("Мир-7")
	_main._show("menu")
	_main._open_all_worlds()
	var button: Button = _main.get_node("%ClearAllSaves")
	_check(button.is_visible_in_tree() and not button.disabled, "очистка доступна рядом с хранилищем")
	button.pressed.emit()
	_check(_main._confirm != null and not Saves.active_files().is_empty(), "открытие диалога не меняет файлы")
	_main._confirm.canceled.emit()
	_check(FileAccess.file_exists(orphan), "отмена сохраняет слоты")
	button.pressed.emit()
	_main._confirm.confirmed.emit()
	var files := DirAccess.get_files_at(_test_saves)
	_check(Saves.active_files().is_empty() and Saves.seeds().is_empty(), "активные слоты исчезли, включая нечитаемые")
	_check(FileAccess.file_exists(unrelated) and files.size() > 1, "архивы и посторонние файлы сохранены")
	_check(_main._carousel_seeds.is_empty() and _main._chosen_seed().is_empty(), "карусель и выбор очищены")
	_check(_main.get_node("%Start").text == "Создать мир",
		"с пустым списком доступно создание, карусель скрыта")
	var reloaded := GameSettings.new()
	reloaded.settings_path = settings.settings_path
	reloaded.load_settings()
	_check(reloaded.hide_recommended_worlds and reloaded.recent_seeds.is_empty() and reloaded.favorite_seeds.is_empty() and reloaded.last_seed.is_empty(),
		"пустой список сохраняется после перезапуска")
	await _capture_state("cleared")
	_main._open_all_worlds()
	_check(_main.get_node("%AllWorlds").visible and _main.get_node("%SeedEdit").has_focus(), "пустой список открывает создание мира")
	var restore: Button = _main.get_node("%Recommended")
	restore.pressed.emit()
	_check(_main._carousel_seeds.has(RecommendedSeeds.SEEDS[0].seed), "рекомендации можно вернуть")
	var restored_settings := GameSettings.new()
	restored_settings.settings_path = settings.settings_path
	restored_settings.load_settings()
	_check(not restored_settings.hide_recommended_worlds, "выбор показывать рекомендации записан")
	for name in files:
		if name == "notes.txt" or ".save" in name and ".archive." in name:
			DirAccess.remove_absolute(_test_saves.path_join(name))


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
		var panel: Control = _main._menu_scroll if screen_path == "%Menu" else _main.get_node(screen_path + "/Panel")
		_check(root.get_visible_rect().encloses(panel.get_global_rect()), "%s %s помещается" % [label, dimensions])
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var path := OUT.path_join("%s_%dx%d.png" % [label, dimensions.x, dimensions.y])
			_check(image.get_size() == dimensions and image.save_png(path) == OK, path)


func _navigation() -> void:
	var start: Button = _main.get_node("%Start")
	start.grab_focus()
	var carousel = _main.get_node("%Carousel")
	_check(carousel._type_buttons.size() >= 2 and not carousel._mode_panel.visible,
		"на главной видны доступные типы, режимы карты скрыты")
	_check(carousel._showcase_title.text == "Горная долина", "показан доступный тип мира")
	var saved_seed: String = _main._chosen_seed()
	_main._open_type_catalog(carousel._showcase_all)
	_main._type_catalog._choose("future_3", false)
	_check(_main._is_screen("type_catalog") and carousel.selected_type_id() == WorldTemplate.DEFAULT_ID and _main._chosen_seed() == saved_seed,
		"заглушка не меняет выбранный мир")
	_main._close_type_catalog()
	carousel._select_type_from_ui(WorldTemplate.EXPEDITION_ID)
	_check(carousel.selected_type_id() == WorldTemplate.EXPEDITION_ID, "доступный тип переключается")
	carousel._select_type_from_ui(WorldTemplate.DEFAULT_ID)
	start.grab_focus()
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_DPAD_DOWN
	pad.pressed = true
	root.push_input(pad)
	_check(_main.get_node("%NewWorld").has_focus(), "из запуска можно перейти к созданию")
	_main.get_node("%NewWorld").pressed.emit()
	_check(_main._draft_seed.has_focus() and _main._is_screen("menu"), "поле нового мира доступно на главной")
	_main._draft_seed.text = "Долина-27"
	_main._on_create_world()
	_check(_main._confirm != null and not _main.busy, "существующее зерно требует явного выбора")
	_main._confirm.canceled.emit()
	await process_frame
	await process_frame
	_check(not Saves.read_slot("Долина-27").data.is_empty(), "отмена сохраняет прогресс")
	var cancel := InputEventJoypadButton.new()
	cancel.button_index = JOY_BUTTON_B
	cancel.pressed = true
	root.push_input(cancel)
	await process_frame
	_check(_main.get_node("%NewWorld").has_focus() and _main.get_node("%Menu").visible, "B возвращает фокус на создание")
	_main._open_all_worlds()
	_check(_main.get_node("%AllWorlds").visible and _main.get_node("%Storage").is_visible_in_tree(), "все миры и хранилище доступны")
	_main._return_to_menu_screen()
	_main._open_settings()
	_check(_main.get_node("%Done").has_focus(), "настройки доступны")
	_main._show("menu")


func _check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	_failures += int(not ok)
