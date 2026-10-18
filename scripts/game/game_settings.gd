class_name GameSettings
extends RefCounted
## Настройки игрока: чувствительность мыши, инверсия, угол обзора, покачивание камеры, полный экран,
## тени и затенение (с 2.6), громкость (с 2.7),
## размер мира в меню. Хранятся в user://settings.cfg (ConfigFile) и живут между запусками.

const PATH := "user://settings.cfg"
const SIZES := [256, 512, 768]   # допустимые размеры мира, как в меню
const DEFAULT_WORLD_SIZE := 512
const MIN_MOUSE := 0.2           # пределы чувствительности и угла обзора, как у ползунков в меню
const MAX_MOUSE := 3.0
const MIN_FOV := 55.0
const MAX_FOV := 100.0
const MAX_SEED_LEN := 32         # длина зерна, как у поля ввода в меню

const DEFAULT_MOUSE := 1.0
const DEFAULT_INVERT_Y := false
const DEFAULT_FOV := 70.0
const DEFAULT_HEAD_BOB := true
const DEFAULT_FULLSCREEN := false
const DEFAULT_SHADOWS := true
const DEFAULT_VOLUME := 0.8

static var mouse := DEFAULT_MOUSE        # множитель GameConfig.MOUSE
static var invert_y := DEFAULT_INVERT_Y
static var fov := DEFAULT_FOV            # угол обзора по вертикали, градусы
static var head_bob := DEFAULT_HEAD_BOB  # покачивание камеры при ходьбе
static var fullscreen := DEFAULT_FULLSCREEN
static var shadows := DEFAULT_SHADOWS  # тени солнца и затенение в углах (SSAO): около 2 мс кадра на GTX 1650 SUPER
static var volume := DEFAULT_VOLUME     # общая громкость 0..1 (шина Master)
static var world_size := DEFAULT_WORLD_SIZE
static var last_seed := ""               # зерно последнего запущенного мира, в меню подставляется при открытии


static func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	mouse = clampf(cfg.get_value("input", "mouse", mouse), MIN_MOUSE, MAX_MOUSE)
	invert_y = cfg.get_value("input", "invert_y", invert_y)
	fov = clampf(cfg.get_value("view", "fov", fov), MIN_FOV, MAX_FOV)
	head_bob = cfg.get_value("view", "head_bob", head_bob)
	fullscreen = cfg.get_value("view", "fullscreen", fullscreen)
	shadows = cfg.get_value("view", "shadows", shadows)
	volume = clampf(cfg.get_value("sound", "volume", volume), 0.0, 1.0)
	# файл мог быть испорчен вручную: неизвестный размер мира заменяем на средний
	world_size = int(cfg.get_value("world", "size", world_size))
	if not SIZES.has(world_size):
		world_size = DEFAULT_WORLD_SIZE
	last_seed = str(cfg.get_value("world", "seed", "")).strip_edges().left(MAX_SEED_LEN)


## Возвращает настройки игрока к значениям по умолчанию; размер мира и последнее зерно не трогает
static func reset_defaults() -> void:
	mouse = DEFAULT_MOUSE
	invert_y = DEFAULT_INVERT_Y
	fov = DEFAULT_FOV
	head_bob = DEFAULT_HEAD_BOB
	fullscreen = DEFAULT_FULLSCREEN
	shadows = DEFAULT_SHADOWS
	volume = DEFAULT_VOLUME


static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse", mouse)
	cfg.set_value("input", "invert_y", invert_y)
	cfg.set_value("view", "fov", fov)
	cfg.set_value("view", "head_bob", head_bob)
	cfg.set_value("view", "fullscreen", fullscreen)
	cfg.set_value("view", "shadows", shadows)
	cfg.set_value("sound", "volume", volume)
	cfg.set_value("world", "size", world_size)
	cfg.set_value("world", "seed", last_seed)
	cfg.save(PATH)


## Полноэкранный режим или окно
static func apply_window() -> void:
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)


## Общая громкость: шина Master, на нуле звук выключен совсем
static func apply_volume() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.001)))
	AudioServer.set_bus_mute(0, volume <= 0.0)
