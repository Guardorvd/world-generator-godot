class_name GameSettings
extends RefCounted
## Настройки игрока: чувствительность мыши, инверсия, угол обзора, покачивание камеры, полный экран,
## тени и затенение (с 2.6), громкость (с 2.7), длина суток и час начала игры (с 7.8; с 10.1 час случайный, пока игрок
## не выбрал его сам),
## дальность прорисовки растительности (с 9.8+), последнее зерно, последние и избранные зёрна (с 10.0). Хранятся в user://settings.cfg (ConfigFile) и живут между запусками.
## С 9.0 размера мира нет (мир один), старый ключ world/size в файле просто не читается.

const PATH := "user://settings.cfg"
static var settings_path := PATH # тесты могут использовать отдельный файл, не профиль игрока
const DisplayConfig := preload("res://scripts/game/display_config.gd")
const MIN_MOUSE := 0.2           # пределы чувствительности и угла обзора, как у ползунков в меню
const MAX_MOUSE := 3.0
const MIN_FOV := 55.0
const MAX_FOV := 100.0
const MAX_SEED_LEN := 32         # длина зерна, как у поля ввода в меню
const RECENT_MAX := 5            # сколько последних зёрен помнить (их миры хранятся в кэше, WorldCache; с 10.2 пять)
const FAVORITES_MAX := 12        # избранных зёрен не больше: каждое держит свой мир в кэше

const DEFAULT_MOUSE := 1.0
const DEFAULT_INVERT_Y := false
const DEFAULT_FOV := 70.0
const DEFAULT_HEAD_BOB := true
const DEFAULT_FULLSCREEN := false
const DEFAULT_SHADOWS := true
const DEFAULT_VOLUME := 0.8
const DEFAULT_DAY_MINUTES := 7.0   # с 12.9 сутки за 7 минут; 0 — время стоит
const OLD_DAY_MINUTES := 24.0      # прежнее значение по умолчанию: в файлах до 10.1 заменяется новым
const DEFAULT_START_HOUR := 9.0
const MAX_DAY_MINUTES := 120.0
## Дальность прорисовки растительности, м: деревья, трава с мелкими растениями, крупный подлесок
## (кусты, подрост, валежник, камни). Минимальная — как в 9.8+. Читает VegetationLayer.
const DRAW_LEVELS := [
	{title = "минимальная", trees = 330.0, grass = 52.0, under = 140.0},
	{title = "средняя", trees = 330.0, grass = 140.0, under = 140.0},
	{title = "высокая", trees = 450.0, grass = 300.0, under = 300.0},
]
const DEFAULT_DRAW := 2 # высокая (решение пользователя в 9.8+)

static var mouse := DEFAULT_MOUSE        # множитель GameConfig.MOUSE
static var invert_y := DEFAULT_INVERT_Y
static var fov := DEFAULT_FOV            # угол обзора по вертикали, градусы
static var head_bob := DEFAULT_HEAD_BOB  # покачивание и удары камеры пешком и на велосипеде
static var fullscreen := DEFAULT_FULLSCREEN
static var resolution := DisplayConfig.BASE
static var render_scale := 1.0
static var msaa := 2 # прежнее MSAA 4x
static var vsync := true
static var draw := DEFAULT_DRAW        # номер в DRAW_LEVELS
static var shadows := DEFAULT_SHADOWS  # тени солнца и затенение в углах (SSAO): около 2 мс кадра на GTX 1650 SUPER
static var volume := DEFAULT_VOLUME     # общая громкость 0..1 (шина Master)
static var day_minutes := DEFAULT_DAY_MINUTES  # минут настоящего времени на игровые сутки, 0 — время стоит
static var start_hour := DEFAULT_START_HOUR    # который час в мире при входе в игру
static var start_hour_set := false  # час начала выбран игроком; иначе каждый мир начинается в случайный час
static var last_seed := ""               # зерно последнего запущенного мира, в меню подставляется при открытии
static var recent_seeds: Array[String] = []    # последние запущенные зёрна, новое первым
static var favorite_seeds: Array[String] = []  # избранные зёрна (звёздочка в меню), в порядке добавления
## 14.4+: бесконечная генерация — соседние области за краем стартовой готовятся и по ним можно ездить.
## Выключена — мир это стартовая область, дальний рельеф виден, но выехать нельзя и области не готовятся
static var infinite_world := false


static func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(settings_path) != OK:
		return
	_apply_config(cfg)


## Повреждённое отдельное поле не мешает прочитать остальные настройки.
static func _apply_config(cfg: ConfigFile) -> void:
	mouse = _number(cfg, "input", "mouse", mouse, MIN_MOUSE, MAX_MOUSE)
	infinite_world = _flag(cfg, "world", "infinite", infinite_world)
	invert_y = _flag(cfg, "input", "invert_y", invert_y)
	fov = _number(cfg, "view", "fov", fov, MIN_FOV, MAX_FOV)
	head_bob = _flag(cfg, "view", "head_bob", head_bob)
	fullscreen = _flag(cfg, "view", "fullscreen", fullscreen)
	var saved_resolution: Variant = cfg.get_value("display", "resolution", Vector2i.ZERO if fullscreen else resolution)
	if DisplayConfig.valid_resolution(saved_resolution):
		resolution = saved_resolution
	render_scale = _number(cfg, "display", "render_scale", render_scale, 0.5, 1.0)
	msaa = roundi(_number(cfg, "display", "msaa", msaa, 0, 2))
	vsync = _flag(cfg, "display", "vsync", vsync)
	shadows = _flag(cfg, "view", "shadows", shadows)
	draw = roundi(_number(cfg, "view", "draw", draw, 0, DRAW_LEVELS.size() - 1))
	volume = _number(cfg, "sound", "volume", volume, 0.0, 1.0)
	day_minutes = _number(cfg, "time", "day_minutes", day_minutes, 0.0, MAX_DAY_MINUTES)
	start_hour = _number(cfg, "time", "start_hour", start_hour, 0.0, 23.0)
	# в файлах до 10.1 флага нет: час, отличный от прежнего значения по умолчанию, игрок выбирал сам;
	# длина суток, равная прежней по умолчанию, становится новой по умолчанию
	if not cfg.has_section_key("time", "start_hour_set") and day_minutes == OLD_DAY_MINUTES:
		day_minutes = DEFAULT_DAY_MINUTES
	start_hour_set = _flag(cfg, "time", "start_hour_set", start_hour != DEFAULT_START_HOUR)
	last_seed = str(cfg.get_value("world", "seed", "")).strip_edges().left(MAX_SEED_LEN)
	recent_seeds = _seeds(cfg, "recent", RECENT_MAX)
	favorite_seeds = _seeds(cfg, "favorites", FAVORITES_MAX)


static func _number(cfg: ConfigFile, section: String, key: String, fallback: float, low: float, high: float) -> float:
	var value: Variant = cfg.get_value(section, key, fallback)
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return fallback
	if not is_finite(float(value)):
		return fallback
	return clampf(float(value), low, high)


## Список зёрен из файла: только непустые строки, без повторов, не длиннее поля ввода
static func _seeds(cfg: ConfigFile, key: String, limit: int) -> Array[String]:
	var out: Array[String] = []
	var value: Variant = cfg.get_value("world", key, [])
	if not (value is Array):
		return out
	for v: Variant in value:
		var s := str(v).strip_edges().left(MAX_SEED_LEN) if v is String else ""
		if not s.is_empty() and not s in out and out.size() < limit:
			out.append(s)
	return out


## Запущенный мир: первым в последних, лишние уходят
static func remember_seed(seed_text: String) -> void:
	last_seed = seed_text
	recent_seeds.erase(seed_text)
	recent_seeds.push_front(seed_text)
	recent_seeds.resize(mini(recent_seeds.size(), RECENT_MAX))


## Звёздочка: добавить в избранное или убрать; false — избранное уже полное
static func toggle_favorite(seed_text: String) -> bool:
	if seed_text in favorite_seeds:
		favorite_seeds.erase(seed_text)
	elif favorite_seeds.size() < FAVORITES_MAX:
		favorite_seeds.append(seed_text)
	else:
		return false
	return true


## Зёрна, чьи миры держит кэш: последние и избранные
static func keep_seeds() -> Array[String]:
	var out: Array[String] = recent_seeds.duplicate()
	for s in favorite_seeds:
		if not s in out:
			out.append(s)
	return out


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
	resolution = DisplayConfig.BASE
	render_scale = 1.0
	msaa = 2
	vsync = true
	shadows = DEFAULT_SHADOWS
	draw = DEFAULT_DRAW
	volume = DEFAULT_VOLUME
	day_minutes = DEFAULT_DAY_MINUTES
	start_hour = DEFAULT_START_HOUR
	start_hour_set = false


static func save_settings() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse", mouse)
	cfg.set_value("input", "invert_y", invert_y)
	cfg.set_value("view", "fov", fov)
	cfg.set_value("view", "head_bob", head_bob)
	cfg.set_value("view", "fullscreen", fullscreen)
	cfg.set_value("display", "resolution", resolution)
	cfg.set_value("display", "render_scale", render_scale)
	cfg.set_value("display", "msaa", msaa)
	cfg.set_value("display", "vsync", vsync)
	cfg.set_value("view", "shadows", shadows)
	cfg.set_value("view", "draw", draw)
	cfg.set_value("sound", "volume", volume)
	cfg.set_value("time", "day_minutes", day_minutes)
	cfg.set_value("time", "start_hour", start_hour)
	cfg.set_value("time", "start_hour_set", start_hour_set)
	cfg.set_value("world", "seed", last_seed)
	cfg.set_value("world", "recent", Array(recent_seeds))
	cfg.set_value("world", "favorites", Array(favorite_seeds))
	cfg.set_value("world", "infinite", infinite_world)
	return cfg.save(settings_path)


## Полноэкранный режим или окно
static func apply_window() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		DisplayConfig.apply(tree.root, display_state())


static func display_state() -> Dictionary:
	return {fullscreen = fullscreen, resolution = resolution, render_scale = render_scale,
		msaa = msaa, vsync = vsync, shadows = shadows, draw = draw}


static func set_display_state(state: Dictionary) -> void:
	fullscreen = state.fullscreen
	resolution = state.resolution
	render_scale = state.render_scale
	msaa = state.msaa
	vsync = state.vsync
	shadows = state.shadows
	draw = state.draw


## Час, в который начинается мир: выбранный игроком или случайный
static func pick_start_hour() -> float:
	return start_hour if start_hour_set else randf() * 24.0


## Общая громкость: шина Master, на нуле звук выключен совсем
static func apply_volume() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.001)))
	AudioServer.set_bus_mute(0, volume <= 0.0)
