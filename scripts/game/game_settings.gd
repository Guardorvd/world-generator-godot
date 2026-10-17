class_name GameSettings
extends RefCounted
## Настройки игрока: чувствительность мыши, инверсия, угол обзора, покачивание камеры, полный экран,
## размер мира в меню. Хранятся в user://settings.cfg (ConfigFile) и живут между запусками.

const PATH := "user://settings.cfg"
const SIZES := [256, 512, 768]   # допустимые размеры мира, как в меню

const DEFAULT_MOUSE := 1.0
const DEFAULT_INVERT_Y := false
const DEFAULT_FOV := 70.0
const DEFAULT_HEAD_BOB := true
const DEFAULT_FULLSCREEN := false

static var mouse := DEFAULT_MOUSE        # множитель GameConfig.MOUSE
static var invert_y := DEFAULT_INVERT_Y
static var fov := DEFAULT_FOV            # угол обзора по вертикали, градусы
static var head_bob := DEFAULT_HEAD_BOB  # покачивание камеры при ходьбе
static var fullscreen := DEFAULT_FULLSCREEN
static var world_size := 512
static var last_seed := ""               # зерно последнего запущенного мира, в меню подставляется при открытии


static func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	mouse = clampf(cfg.get_value("input", "mouse", mouse), 0.2, 3.0)
	invert_y = cfg.get_value("input", "invert_y", invert_y)
	fov = clampf(cfg.get_value("view", "fov", fov), 55.0, 100.0)
	head_bob = cfg.get_value("view", "head_bob", head_bob)
	fullscreen = cfg.get_value("view", "fullscreen", fullscreen)
	# файл мог быть испорчен вручную: неизвестный размер мира заменяем на средний
	world_size = int(cfg.get_value("world", "size", world_size))
	if not SIZES.has(world_size):
		world_size = 512
	last_seed = str(cfg.get_value("world", "seed", "")).strip_edges().left(32)


## Возвращает настройки игрока к значениям по умолчанию; размер мира и последнее зерно не трогает
static func reset_defaults() -> void:
	mouse = DEFAULT_MOUSE
	invert_y = DEFAULT_INVERT_Y
	fov = DEFAULT_FOV
	head_bob = DEFAULT_HEAD_BOB
	fullscreen = DEFAULT_FULLSCREEN


static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse", mouse)
	cfg.set_value("input", "invert_y", invert_y)
	cfg.set_value("view", "fov", fov)
	cfg.set_value("view", "head_bob", head_bob)
	cfg.set_value("view", "fullscreen", fullscreen)
	cfg.set_value("world", "size", world_size)
	cfg.set_value("world", "seed", last_seed)
	cfg.save(PATH)


## Полноэкранный режим или окно
static func apply_window() -> void:
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)
