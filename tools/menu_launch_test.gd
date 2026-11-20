extends SceneTree
const Saves := preload("res://scripts/game/save_game.gd")
var failures := 0
func check(condition: bool, message: String) -> void:
	print(("OK " if condition else "FAIL ") + message)
	failures += int(not condition)
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var dir := "res://.godot/menu_launch_test"
	DirAccess.make_dir_recursive_absolute(dir)
	Saves.dir = dir
	GameContext.scope.settings.settings_path = dir.path_join("settings.cfg")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main._ui_stack.force_animate_in_headless = true
	main._selected_seed = ""
	var carousel = main.get_node("%Carousel")
	var empty: Array[Dictionary] = []
	carousel.set_entries(empty, "")
	carousel._quick_seed.text = "preview-launch-test"
	carousel._create_first.pressed.emit()
	check(main.busy and main._is_screen("loading") and main._selected_seed == "preview-launch-test", "первый мир запускается прямо из карточки")
	check(main._ui_audio.last_sound == &"confirm", "запуск проигрывает подтверждение")
	if main.busy:
		var loading: Control = main.get_node("%Loading")
		var tween: Tween = main._ui_stack._screen_tweens.get("loading")
		check(tween != null and loading.offset_top > 0.0, "карточка загрузки начинает подъём")
		if tween != null:
			tween.custom_step(0.2)
			check(is_zero_approx(loading.offset_top) and is_equal_approx(loading.modulate.a, 1.0), "карточка загрузки доходит до позиции")
		main._cancel_loading(false)
		var deadline := Time.get_ticks_msec() + 30000
		while main.busy and Time.get_ticks_msec() < deadline:
			await process_frame
		check(not main.busy and main._is_screen("menu"), "отмена загрузки возвращает меню")
	main.queue_free()
	await process_frame
	print("Menu launch failures: ", failures)
	quit(1 if failures else 0)
