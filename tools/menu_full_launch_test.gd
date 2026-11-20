extends SceneTree
## Полный переход из меню в мир с изолированными настройками и сохранениями.
const Saves := preload("res://scripts/game/save_game.gd")
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var dir := "res://.godot/menu_full_launch_test"
	DirAccess.make_dir_recursive_absolute(dir)
	Saves.dir = dir
	GameContext.scope.settings.settings_path = dir.path_join("settings.cfg")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var started := Time.get_ticks_msec()
	main.start_game("Menu-integration-2026")
	var last_report := started
	while main.busy and Time.get_ticks_msec() - started < 180000:
		if Time.get_ticks_msec() - last_report > 15000:
			last_report = Time.get_ticks_msec()
			print("LOAD_STAGE ", main.load_step.text, " elapsed=", (last_report - started) / 1000)
		await process_frame
	var ok: bool = not main.busy and main.game != null and main.game.world != null and main.game.world.seed_text == "Menu-integration-2026"
	print("FULL_MENU_LAUNCH ", "OK" if ok else "FAIL", " elapsed_ms=", Time.get_ticks_msec() - started)
	if main.busy:
		main._cancel_loading(false)
		while main.busy:
			await process_frame
	if main.game != null: main._free_game()
	main.queue_free()
	await process_frame
	quit(0 if ok else 1)
