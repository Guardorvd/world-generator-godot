class_name GameSettings
extends RefCounted
## Настройки игрока: чувствительность мыши, инверсия, угол обзора, покачивание камеры, полный экран,
## размер мира в меню. Хранятся в user://settings.cfg (ConfigFile) и живут между запусками.

const PATH := "user://settings.cfg"

static var mouse := 1.0        # множитель GameConfig.MOUSE
static var invert_y := false
static var fov := 70.0         # угол обзора по вертикали, градусы
static var head_bob := true    # покачивание камеры при ходьбе
static var fullscreen := false
static var world_size := 512


static func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	mouse = clampf(cfg.get_value("input", "mouse", mouse), 0.2, 3.0)
	invert_y = cfg.get_value("input", "invert_y", invert_y)
	fov = clampf(cfg.get_value("view", "fov", fov), 55.0, 100.0)
	head_bob = cfg.get_value("view", "head_bob", head_bob)
	fullscreen = cfg.get_value("view", "fullscreen", fullscreen)
	world_size = cfg.get_value("world", "size", world_size)


static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse", mouse)
	cfg.set_value("input", "invert_y", invert_y)
	cfg.set_value("view", "fov", fov)
	cfg.set_value("view", "head_bob", head_bob)
	cfg.set_value("view", "fullscreen", fullscreen)
	cfg.set_value("world", "size", world_size)
	cfg.save(PATH)


## Полноэкранный режим или окно
static func apply_window() -> void:
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)
