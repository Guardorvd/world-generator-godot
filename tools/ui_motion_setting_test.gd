extends SceneTree
## Настройка движения сохраняется и отключает анимацию переходов стека экранов.
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	print("PASS " if condition else "FAIL ", message)
	if not condition:
		failures += 1

func _run() -> void:
	var directory := "res://.godot/ui_motion_setting_test"
	DirAccess.make_dir_recursive_absolute(directory)
	var settings := GameSettings.new()
	settings.settings_path = directory.path_join("settings.cfg")
	settings.reduce_ui_motion = true
	check(settings.save_settings() == OK, "настройка записана")
	var loaded := GameSettings.new()
	loaded.settings_path = settings.settings_path
	loaded.load_settings()
	check(loaded.reduce_ui_motion, "настройка восстанавливается после загрузки")
	loaded.reset_defaults()
	check(not loaded.reduce_ui_motion, "сброс возвращает обычные переходы")
	var previous: bool = GameContext.scope.settings.reduce_ui_motion
	var host := Node.new()
	root.add_child(host)
	var stack = preload("res://scripts/ui/ui_stack.gd").new()
	host.add_child(stack)
	stack.setup(host, {}, null, null)
	stack.force_animate_in_headless = true
	GameContext.scope.settings.reduce_ui_motion = false
	check(stack.should_animate(), "обычные переходы доступны")
	GameContext.scope.settings.reduce_ui_motion = true
	check(not stack.should_animate(), "уменьшение движения отключает переходы")
	GameContext.scope.settings.reduce_ui_motion = previous
	host.queue_free()
	await process_frame
	quit(1 if failures else 0)
