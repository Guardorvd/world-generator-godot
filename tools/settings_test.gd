extends SceneTree
## Проверка повреждённых настроек без чтения и изменения пользовательского файла.

var fails := 0


func _check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok:
		fails += 1


func _initialize() -> void:
	GameSettings.reset_defaults()
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse", "ошибка")
	cfg.set_value("input", "invert_y", [])
	cfg.set_value("view", "fov", NAN)
	cfg.set_value("view", "head_bob", "false")
	cfg.set_value("view", "fullscreen", 1)
	cfg.set_value("view", "shadows", false)
	cfg.set_value("sound", "volume", INF)
	cfg.set_value("world", "size", {})
	cfg.set_value("world", "seed", "  Север-1234  ")
	GameSettings._apply_config(cfg)
	_check(GameSettings.mouse == GameSettings.DEFAULT_MOUSE and GameSettings.fov == GameSettings.DEFAULT_FOV
		and GameSettings.volume == GameSettings.DEFAULT_VOLUME, "строки, NaN и бесконечность заменяются безопасными значениями")
	_check(not GameSettings.invert_y and GameSettings.head_bob and not GameSettings.fullscreen,
		"переключатели принимают только логические значения")
	_check(not GameSettings.shadows and GameSettings.last_seed == "Север-1234",
		"исправные поля читаются даже при повреждении соседних")
	cfg.set_value("input", "mouse", 100)
	cfg.set_value("view", "fov", 1.0)
	cfg.set_value("sound", "volume", -2.0)
	GameSettings._apply_config(cfg)
	_check(GameSettings.mouse == GameSettings.MAX_MOUSE and GameSettings.fov == GameSettings.MIN_FOV
		and GameSettings.volume == 0.0, "числа ограничены диапазонами, старый ключ размера мира не мешает")
	print("Настройки: ошибок %d" % fails)
	quit(0 if fails == 0 else 1)
