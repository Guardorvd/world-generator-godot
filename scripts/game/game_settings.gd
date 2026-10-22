class_name GameSettings
extends RefCounted
## Настройки игрока: чувствительность мыши, инверсия, угол обзора, покачивание камеры, полный экран,
## тени и затенение (с 2.6), громкость (с 2.7), длина суток и час начала игры (с 7.8),
## дальность прорисовки растительности (с 9.8+), последнее зерно. Хранятся в user://settings.cfg (ConfigFile) и живут между запусками.
## С 9.0 размера мира нет (мир один), старый ключ world/size в файле просто не читается.

const PATH := "user://settings.cfg"
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
const DEFAULT_DAY_MINUTES := 24.0  # сутки за 24 минуты игры; 0 — время стоит
const DEFAULT_START_HOUR := 9.0
const MAX_DAY_MINUTES := 120.0
## Дальность прорисовки растительности, м: деревья, трава с мелкими растениями, крупный подлесок
## (кусты, подрост, валежник, камни). Минимальная — как в 9.8+. Читает VegetationLayer.
const DRAW_LEVELS := [
	{title = "минимальная", trees = 330.0, grass = 52.0, under = 140.0},
	{title = "средняя", trees = 330.0, grass = 140.0, under = 140.0},
	{title = "высокая", trees = 450.0, grass = 300.0, under = 300.0},
]
const DEFAULT_DRAW := 0

static var mouse := DEFAULT_MOUSE        # множитель GameConfig.MOUSE
static var invert_y := DEFAULT_INVERT_Y
static var fov := DEFAULT_FOV            # угол обзора по вертикали, градусы
static var head_bob := DEFAULT_HEAD_BOB  # покачивание и удары камеры пешком и на велосипеде
static var fullscreen := DEFAULT_FULLSCREEN
static var draw := DEFAULT_DRAW        # номер в DRAW_LEVELS
static var shadows := DEFAULT_SHADOWS  # тени солнца и затенение в углах (SSAO): около 2 мс кадра на GTX 1650 SUPER
static var volume := DEFAULT_VOLUME     # общая громкость 0..1 (шина Master)
static var day_minutes := DEFAULT_DAY_MINUTES  # минут настоящего времени на игровые сутки, 0 — время стоит
static var start_hour := DEFAULT_START_HOUR    # который час в мире при входе в игру
static var last_seed := ""               # зерно последнего запущенного мира, в меню подставляется при открытии


static func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	_apply_config(cfg)


## Повреждённое отдельное поле не мешает прочитать остальные настройки.
static func _apply_config(cfg: ConfigFile) -> void:
	mouse = _number(cfg, "input", "mouse", mouse, MIN_MOUSE, MAX_MOUSE)
	invert_y = _flag(cfg, "input", "invert_y", invert_y)
	fov = _number(cfg, "view", "fov", fov, MIN_FOV, MAX_FOV)
	head_bob = _flag(cfg, "view", "head_bob", head_bob)
	fullscreen = _flag(cfg, "view", "fullscreen", fullscreen)
	shadows = _flag(cfg, "view", "shadows", shadows)
	draw = roundi(_number(cfg, "view", "draw", draw, 0, DRAW_LEVELS.size() - 1))
	volume = _number(cfg, "sound", "volume", volume, 0.0, 1.0)
	day_minutes = _number(cfg, "time", "day_minutes", day_minutes, 0.0, MAX_DAY_MINUTES)
	start_hour = _number(cfg, "time", "start_hour", start_hour, 0.0, 23.0)
	last_seed = str(cfg.get_value("world", "seed", "")).strip_edges().left(MAX_SEED_LEN)


static func _number(cfg: ConfigFile, section: String, key: String, fallback: float, low: float, high: float) -> float:
	var value: Variant = cfg.get_value(section, key, fallback)
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return fallback
	if not is_finite(float(value)):
		return fallback
	return clampf(float(value), low, high)


static func _flag(cfg: ConfigFile, section: String, key: String, fallback: bool) -> bool:
	var value: Variant = cfg.get_value(section, key, fallback)
	return value if typeof(value) == TYPE_BOOL else fallback


## Возвращает настройки игрока к значениям по умолчанию; последнее зерно не трогает
static func reset_defaults() -> void:
	mouse = DEFAULT_MOUSE
	invert_y = DEFAULT_INVERT_Y
	fov = DEFAULT_FOV
	head_bob = DEFAULT_HEAD_BOB
	fullscreen = DEFAULT_FULLSCREEN
	shadows = DEFAULT_SHADOWS
	draw = DEFAULT_DRAW
	volume = DEFAULT_VOLUME
	day_minutes = DEFAULT_DAY_MINUTES
	start_hour = DEFAULT_START_HOUR


static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse", mouse)
	cfg.set_value("input", "invert_y", invert_y)
	cfg.set_value("view", "fov", fov)
	cfg.set_value("view", "head_bob", head_bob)
	cfg.set_value("view", "fullscreen", fullscreen)
	cfg.set_value("view", "shadows", shadows)
	cfg.set_value("view", "draw", draw)
	cfg.set_value("sound", "volume", volume)
	cfg.set_value("time", "day_minutes", day_minutes)
	cfg.set_value("time", "start_hour", start_hour)
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
