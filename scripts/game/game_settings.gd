class_name GameSettings
extends RefCounted
## Настройки игрока: чувствительность мыши, инверсия, угол обзора, покачивание камеры, полный экран,
## тени и затенение (с 2.6), громкость (с 2.7), длина суток и час начала игры (с 7.8; с 10.1 час случайный, пока игрок
## не выбрал его сам),
## дальность прорисовки растительности (с 9.8+), последнее зерно, последние и избранные зёрна (с 10.0). Хранятся в user://settings.cfg (ConfigFile) и живут между запусками.
## С 9.0 размера мира нет (мир один), старый ключ world/size в файле просто не читается.

const PATH := "user://settings.cfg"
var settings_path := PATH # тесты могут использовать отдельный файл, не профиль игрока
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
const DEFAULT_TRAIL_CLUTTER := true # корни, брёвна, ветки и камни на тропах (RoadObstacles)
const DEFAULT_TREE_GARLANDS := true # редкие парковые гирлянды на деревьях
const DEFAULT_FULLSCREEN := false
const DEFAULT_SHADOWS := true
const DEFAULT_LIGHTING := 1
const LIGHTING_LEVELS := ["Низкое", "Среднее", "Высокое"]
const DEFAULT_FOG_QUALITY := DEFAULT_LIGHTING
const FOG_OFF := 3
const FOG_QUALITY_LEVELS := ["Низкий", "Средний", "Высокий", "Выключен"]
## 16.11: облака неба — купол (низкие), облегчённые по пикселям (средние), прежние (высокие); LightingQuality.apply_clouds
const CLOUD_QUALITY_LEVELS := ["Низкие", "Средние", "Высокие"]
const DEFAULT_CLOUD_QUALITY := 1
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
## 16.0: качество растительности. Природная раскладка одна и та же; меняется доля мелких растений
## (трава, цветы, куртины, кусты подлеска — не валежник и не деревья), их размер (меньше — крупнее,
## чтобы земля не пустела), граница упрощённых форм, поредение листьев вдали и тени подроста.
## География, деревья, столкновения и препятствия на тропах от неё не зависят. Читает VegetationLayer.
const FLORA_LEVELS := [
	{title = "низкое", density = 0.45, grass = 0.55, grow = 1.25, far_form = 12.0,
		woody_form = 1.6, woody_detail_full = 35.0, detail = 0.6, reach = 0.6, shadows = false},
	{title = "среднее", density = 0.65, grass = 0.72, grow = 1.14, far_form = 16.0,
		woody_form = 1.6, woody_detail_full = 35.0, detail = 0.75, reach = 0.8, shadows = true},
	{title = "высокое", density = 1.0, grass = 1.0, grow = 1.0, far_form = 24.0,
		open_form_range = Vector2(27.0, 48.0), open_group_range = Vector2(64.0, 82.0),
		woody_form = 2.2, woody_detail_full = 46.2, detail = 1.0, reach = 1.0, shadows = true},
]
const DEFAULT_FLORA := 2
# 11.11.2026: частицы окружения (AmbientParticles): название и множитель плотности
const PARTICLE_LEVELS := [
	{title = "выключены", density = 0.0},
	{title = "мало", density = 0.4},
	{title = "обычно", density = 0.75},
	{title = "много", density = 1.0},
]
const DEFAULT_PARTICLES := 2
# 14.11.2026: дернина — плотный ковёр мелкой травы у игрока (GroundCarpet): густота и дальность отдельно.
# Густота — доля занятых мест (0 — слой выключен), дальность — где ковёр растворяется, м.
const CARPET_DENSITY := [
	{title = "выключена", scale = 0.0},
	{title = "редкая", scale = 0.45},
	{title = "средняя", scale = 0.7},
	{title = "густая", scale = 1.0},
]
const DEFAULT_CARPET_DENSITY := 3
const CARPET_RANGE := [
	{title = "близко", meters = 10.0},
	{title = "средне", meters = 15.0},
	{title = "далеко", meters = 22.0},
	{title = "очень далеко", meters = 32.0},
	{title = "экстра", meters = 22.0, directional = true},
]
const DEFAULT_CARPET_RANGE := 4
# 17.11.2026: дерновины средних дистанций (VegetationLayer._open_sod) — множитель их доли; 0 — слоя нет
const MID_GRASS := [
	{title = "выключена", scale = 0.0},
	{title = "редкая", scale = 0.55},
	{title = "обычная", scale = 1.0},
	{title = "густая", scale = 1.35},
]
const DEFAULT_MID_GRASS := 2
# 15.11.2026: детализация дорог — объём полотна (глубина и тени колей и ям, мелкий камень, россыпь у кромок) и дальность,
# на которой он виден. quality идёт в шейдер рельефа (общий параметр road_quality.x), stones — доля россыпи камней,
# range — множитель дальности мелкой детали (road_quality.y).
const ROAD_QUALITY := [
	{title = "простое", quality = 0.0, stones = 0.0},
	{title = "среднее", quality = 0.5, stones = 0.5},
	{title = "высокое", quality = 1.0, stones = 1.0},
]
const DEFAULT_ROAD_QUALITY := 2
const ROAD_RANGE := [
	{title = "близко", scale = 0.6},
	{title = "средне", scale = 1.0},
	{title = "далеко", scale = 1.6},
]
const DEFAULT_ROAD_RANGE := 1

var mouse := DEFAULT_MOUSE        # множитель GameConfig.MOUSE
var invert_y := DEFAULT_INVERT_Y
var fov := DEFAULT_FOV            # угол обзора по вертикали, градусы
var head_bob := DEFAULT_HEAD_BOB  # покачивание и удары камеры пешком и на велосипеде
var trail_clutter := DEFAULT_TRAIL_CLUTTER  # препятствия на тропах и дорогах; выключено — полотно чистое
var fullscreen := DEFAULT_FULLSCREEN
var resolution := DisplayConfig.BASE
var render_scale := 1.0
var adaptive_resolution := false # 20.11.2026: «Авто» в разрешении 3D — при нагрузке до 80 % (AdaptiveResolution); по умолчанию выключено: при 1080p даёт лишь −0,8…1,9 мс, а FSR подчёркивает дизеринг крон
var msaa := 2 # прежнее MSAA 4x
var vsync := true
var draw := DEFAULT_DRAW        # номер в DRAW_LEVELS
var flora := DEFAULT_FLORA      # номер в FLORA_LEVELS
var particles := DEFAULT_PARTICLES # номер в PARTICLE_LEVELS
var carpet_density := DEFAULT_CARPET_DENSITY # номер в CARPET_DENSITY
var carpet_range := DEFAULT_CARPET_RANGE     # номер в CARPET_RANGE
var mid_grass := DEFAULT_MID_GRASS           # номер в MID_GRASS
var road_quality := DEFAULT_ROAD_QUALITY     # номер в ROAD_QUALITY
var road_range := DEFAULT_ROAD_RANGE         # номер в ROAD_RANGE
var shadows := DEFAULT_SHADOWS # только тени направленного света
var tree_garlands := DEFAULT_TREE_GARLANDS # парковые гирлянды вдоль отдельных дорог и полян
var lighting := DEFAULT_LIGHTING
var fog_quality := DEFAULT_FOG_QUALITY
var cloud_quality := DEFAULT_CLOUD_QUALITY
## 13.11: визуальный стиль (VisualStyle) — выключатель и сила 0..1 у каждого из четырёх эффектов
var style_on: Dictionary = VisualStyle.DEFAULT_ON.duplicate()
var style_amount: Dictionary = VisualStyle.DEFAULT_AMOUNT.duplicate()
var volume := DEFAULT_VOLUME     # общая громкость 0..1 (шина Master)
var day_minutes := DEFAULT_DAY_MINUTES  # минут настоящего времени на игровые сутки, 0 — время стоит
var start_hour := DEFAULT_START_HOUR    # который час в мире при входе в игру
var start_hour_set := false  # час начала выбран игроком; иначе каждый мир начинается в случайный час
var last_seed := ""               # зерно последнего запущенного мира, в меню подставляется при открытии
var recent_seeds: Array[String] = []    # последние запущенные зёрна, новое первым
var favorite_seeds: Array[String] = []  # избранные зёрна (звёздочка в меню), в порядке добавления
var hide_recommended_worlds := false # после очистки список остаётся пустым и при следующем запуске
var active_template := WorldTemplate.DEFAULT_ID
var _template_worlds := {} # template_id -> {seed, recent, favorites, hide_recommended}
## 14.4+: бесконечная генерация — соседние области за краем стартовой готовятся и по ним можно ездить.
## Выключена — мир это стартовая область, дальний рельеф виден, но выехать нельзя и области не готовятся
var infinite_world := false


func load_settings() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(settings_path)
	if err != OK:
		if FileAccess.file_exists(settings_path):
			push_warning("Настройки не прочитаны (%s), взяты значения по умолчанию: %s" % [error_string(err), settings_path])
		return
	_apply_config(cfg)


## Повреждённое отдельное поле не мешает прочитать остальные настройки.
func _apply_config(cfg: ConfigFile) -> void:
	mouse = _number(cfg, "input", "mouse", mouse, MIN_MOUSE, MAX_MOUSE)
	infinite_world = _flag(cfg, "world", "infinite", infinite_world)
	invert_y = _flag(cfg, "input", "invert_y", invert_y)
	fov = _number(cfg, "view", "fov", fov, MIN_FOV, MAX_FOV)
	head_bob = _flag(cfg, "view", "head_bob", head_bob)
	trail_clutter = _flag(cfg, "view", "trail_clutter", trail_clutter)
	fullscreen = _flag(cfg, "view", "fullscreen", fullscreen)
	var saved_resolution: Variant = cfg.get_value("display", "resolution", Vector2i.ZERO if fullscreen else resolution)
	if DisplayConfig.valid_resolution(saved_resolution):
		resolution = saved_resolution
	render_scale = _number(cfg, "display", "render_scale", render_scale, 0.5, 1.0)
	adaptive_resolution = _flag(cfg, "display", "adaptive_resolution", adaptive_resolution)
	msaa = roundi(_number(cfg, "display", "msaa", msaa, 0, 2))
	vsync = _flag(cfg, "display", "vsync", vsync)
	shadows = _flag(cfg, "view", "shadows", shadows)
	tree_garlands = _flag(cfg, "view", "tree_garlands", tree_garlands)
	lighting = roundi(_number(cfg, "view", "lighting", lighting, 0, 2))
	fog_quality = roundi(_number(cfg, "view", "fog_quality", lighting, 0, FOG_QUALITY_LEVELS.size() - 1))
	cloud_quality = roundi(_number(cfg, "view", "cloud_quality", cloud_quality, 0, CLOUD_QUALITY_LEVELS.size() - 1))
	draw = roundi(_number(cfg, "view", "draw", draw, 0, DRAW_LEVELS.size() - 1))
	flora = roundi(_number(cfg, "view", "flora", flora, 0, FLORA_LEVELS.size() - 1))
	particles = roundi(_number(cfg, "view", "particles", particles, 0, PARTICLE_LEVELS.size() - 1))
	carpet_density = roundi(_number(cfg, "view", "carpet_density", carpet_density, 0, CARPET_DENSITY.size() - 1))
	carpet_range = roundi(_number(cfg, "view", "carpet_range", carpet_range, 0, CARPET_RANGE.size() - 1))
	mid_grass = roundi(_number(cfg, "view", "mid_grass", mid_grass, 0, MID_GRASS.size() - 1))
	road_quality = roundi(_number(cfg, "view", "road_quality", road_quality, 0, ROAD_QUALITY.size() - 1))
	road_range = roundi(_number(cfg, "view", "road_range", road_range, 0, ROAD_RANGE.size() - 1))
	for id: String in VisualStyle.EFFECTS:
		style_on[id] = _flag(cfg, "style", id + "_on", style_on[id])
		style_amount[id] = _number(cfg, "style", id + "_amount", style_amount[id], 0.0, 1.0)
	volume = _number(cfg, "sound", "volume", volume, 0.0, 1.0)
	day_minutes = _number(cfg, "time", "day_minutes", day_minutes, 0.0, MAX_DAY_MINUTES)
	start_hour = _number(cfg, "time", "start_hour", start_hour, 0.0, 23.0)
	# в файлах до 10.1 флага нет: час, отличный от прежнего значения по умолчанию, игрок выбирал сам;
	# длина суток, равная прежней по умолчанию, становится новой по умолчанию
	if not cfg.has_section_key("time", "start_hour_set") and day_minutes == OLD_DAY_MINUTES:
		day_minutes = DEFAULT_DAY_MINUTES
	start_hour_set = _flag(cfg, "time", "start_hour_set", start_hour != DEFAULT_START_HOUR)
	_template_worlds.clear()
	for tid: String in WorldTemplate.ids():
		var sec := WorldTemplate.settings_section(tid)
		_template_worlds[tid] = {
			seed = str(cfg.get_value(sec, "seed", "")).strip_edges().left(MAX_SEED_LEN),
			recent = _seeds(cfg, "recent", RECENT_MAX, sec),
			favorites = _seeds(cfg, "favorites", FAVORITES_MAX, sec),
			hide_recommended = _flag(cfg, sec, "hide_recommended", false),
		}
	_load_active_template(active_template)


func _load_active_template(tid: String) -> void:
	var id := WorldTemplate.normalize_id(tid)
	active_template = id
	var bucket: Dictionary = _template_worlds.get(id, {seed = "", recent = [] as Array[String], favorites = [] as Array[String], hide_recommended = false})
	last_seed = str(bucket.get("seed", ""))
	recent_seeds = (bucket.get("recent", []) as Array[String]).duplicate()
	favorite_seeds = (bucket.get("favorites", []) as Array[String]).duplicate()
	hide_recommended_worlds = bool(bucket.get("hide_recommended", false))


func _sync_active_template() -> void:
	_template_worlds[active_template] = {
		seed = last_seed,
		recent = recent_seeds.duplicate(),
		favorites = favorite_seeds.duplicate(),
		hide_recommended = hide_recommended_worlds,
	}


func set_active_template(id: String) -> void:
	var tid := WorldTemplate.normalize_id(id)
	if tid == active_template:
		return
	_sync_active_template()
	_load_active_template(tid)


func _number(cfg: ConfigFile, section: String, key: String, fallback: float, low: float, high: float) -> float:
	var value: Variant = cfg.get_value(section, key, fallback)
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return fallback
	if not is_finite(float(value)):
		return fallback
	return clampf(float(value), low, high)


## Список зёрен из файла: только непустые строки, без повторов, не длиннее поля ввода
func _seeds(cfg: ConfigFile, key: String, limit: int, section := "world") -> Array[String]:
	var out: Array[String] = []
	var value: Variant = cfg.get_value(section, key, [])
	if not (value is Array):
		return out
	for v: Variant in value:
		var s := str(v).strip_edges().left(MAX_SEED_LEN) if v is String else ""
		if not s.is_empty() and not s in out and out.size() < limit:
			out.append(s)
	return out


## Запущенный мир: первым в последних, лишние уходят
func remember_seed(seed_text: String) -> void:
	last_seed = seed_text
	recent_seeds.erase(seed_text)
	recent_seeds.push_front(seed_text)
	recent_seeds.resize(mini(recent_seeds.size(), RECENT_MAX))
	_sync_active_template()


## Звёздочка: добавить в избранное или убрать; false — избранное уже полное
func toggle_favorite(seed_text: String) -> bool:
	if seed_text in favorite_seeds:
		favorite_seeds.erase(seed_text)
	elif favorite_seeds.size() < FAVORITES_MAX:
		favorite_seeds.append(seed_text)
	else:
		return false
	_sync_active_template()
	return true


## Зёрна, чьи миры держит кэш: последние и избранные (у Типа 1 также миры автора)
func keep_seeds(template_id := "") -> Array[String]:
	var tid := active_template if template_id.is_empty() else WorldTemplate.normalize_id(template_id)
	_sync_active_template()
	var bucket: Dictionary = _template_worlds.get(tid, {recent = [] as Array[String], favorites = [] as Array[String]})
	var out: Array[String] = (bucket.get("recent", []) as Array[String]).duplicate()
	for s: String in bucket.get("favorites", []):
		if not s in out:
			out.append(s)
	# 14.5: миры автора готовы в проекте — их кэш не удаляется (относятся к Типу 1)
	if WorldTemplate.is_default(tid):
		for r: Dictionary in RecommendedSeeds.SEEDS:
			if not r.seed in out:
				out.append(r.seed)
	return out


func _flag(cfg: ConfigFile, section: String, key: String, fallback: bool) -> bool:
	var value: Variant = cfg.get_value(section, key, fallback)
	return value if typeof(value) == TYPE_BOOL else fallback


## Возвращает настройки игрока к значениям по умолчанию; последнее зерно не трогает
func reset_defaults() -> void:
	mouse = DEFAULT_MOUSE
	invert_y = DEFAULT_INVERT_Y
	fov = DEFAULT_FOV
	head_bob = DEFAULT_HEAD_BOB
	trail_clutter = DEFAULT_TRAIL_CLUTTER
	fullscreen = DEFAULT_FULLSCREEN
	resolution = DisplayConfig.BASE
	render_scale = 1.0
	adaptive_resolution = false
	msaa = 2
	vsync = true
	shadows = DEFAULT_SHADOWS
	tree_garlands = DEFAULT_TREE_GARLANDS
	lighting = DEFAULT_LIGHTING
	fog_quality = DEFAULT_FOG_QUALITY
	cloud_quality = DEFAULT_CLOUD_QUALITY
	draw = DEFAULT_DRAW
	flora = DEFAULT_FLORA
	particles = DEFAULT_PARTICLES
	carpet_density = DEFAULT_CARPET_DENSITY
	carpet_range = DEFAULT_CARPET_RANGE
	mid_grass = DEFAULT_MID_GRASS
	road_quality = DEFAULT_ROAD_QUALITY
	road_range = DEFAULT_ROAD_RANGE
	style_on = VisualStyle.DEFAULT_ON.duplicate()
	style_amount = VisualStyle.DEFAULT_AMOUNT.duplicate()
	volume = DEFAULT_VOLUME
	day_minutes = DEFAULT_DAY_MINUTES
	start_hour = DEFAULT_START_HOUR
	start_hour_set = false


func save_settings() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse", mouse)
	cfg.set_value("input", "invert_y", invert_y)
	cfg.set_value("view", "fov", fov)
	cfg.set_value("view", "head_bob", head_bob)
	cfg.set_value("view", "trail_clutter", trail_clutter)
	cfg.set_value("view", "fullscreen", fullscreen)
	cfg.set_value("display", "resolution", resolution)
	cfg.set_value("display", "render_scale", render_scale)
	cfg.set_value("display", "adaptive_resolution", adaptive_resolution)
	cfg.set_value("display", "msaa", msaa)
	cfg.set_value("display", "vsync", vsync)
	cfg.set_value("view", "shadows", shadows)
	cfg.set_value("view", "tree_garlands", tree_garlands)
	cfg.set_value("view", "lighting", lighting)
	cfg.set_value("view", "fog_quality", fog_quality)
	cfg.set_value("view", "cloud_quality", cloud_quality)
	cfg.set_value("view", "draw", draw)
	cfg.set_value("view", "flora", flora)
	cfg.set_value("view", "particles", particles)
	cfg.set_value("view", "carpet_density", carpet_density)
	cfg.set_value("view", "carpet_range", carpet_range)
	cfg.set_value("view", "mid_grass", mid_grass)
	cfg.set_value("view", "road_quality", road_quality)
	cfg.set_value("view", "road_range", road_range)
	for id: String in VisualStyle.EFFECTS:
		cfg.set_value("style", id + "_on", style_on[id])
		cfg.set_value("style", id + "_amount", style_amount[id])
	cfg.set_value("sound", "volume", volume)
	cfg.set_value("time", "day_minutes", day_minutes)
	cfg.set_value("time", "start_hour", start_hour)
	cfg.set_value("time", "start_hour_set", start_hour_set)
	_sync_active_template()
	for tid: String in WorldTemplate.ids():
		var sec := WorldTemplate.settings_section(tid)
		var bucket: Dictionary = _template_worlds.get(tid, {seed = "", recent = [] as Array[String], favorites = [] as Array[String], hide_recommended = false})
		cfg.set_value(sec, "seed", str(bucket.get("seed", "")))
		cfg.set_value(sec, "recent", Array(bucket.get("recent", [])))
		cfg.set_value(sec, "favorites", Array(bucket.get("favorites", [])))
		cfg.set_value(sec, "hide_recommended", bool(bucket.get("hide_recommended", false)))
	cfg.set_value("world", "infinite", infinite_world)
	var err := cfg.save(settings_path)
	if err != OK:
		push_warning("Настройки не записаны (%s): %s" % [error_string(err), settings_path])
	return err


## Полноэкранный режим или окно
func apply_window() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		DisplayConfig.apply(tree.root, display_state())


func display_state() -> Dictionary:
	return {fullscreen = fullscreen, resolution = resolution, render_scale = render_scale, adaptive_resolution = adaptive_resolution,
		msaa = msaa, vsync = vsync, shadows = shadows, tree_garlands = tree_garlands, draw = draw, flora = flora, lighting = lighting,
		fog_quality = fog_quality, cloud_quality = cloud_quality, particles = particles, carpet_density = carpet_density, carpet_range = carpet_range,
		mid_grass = mid_grass, road_quality = road_quality, road_range = road_range,
		style_on = style_on.duplicate(), style_amount = style_amount.duplicate()}


func set_display_state(state: Dictionary) -> void:
	fullscreen = state.fullscreen
	resolution = state.resolution
	render_scale = state.render_scale
	adaptive_resolution = bool(state.get("adaptive_resolution", adaptive_resolution))
	msaa = state.msaa
	vsync = state.vsync
	shadows = state.shadows
	tree_garlands = bool(state.get("tree_garlands", tree_garlands))
	draw = state.draw
	flora = state.get("flora", flora)
	particles = clampi(state.get("particles", particles), 0, PARTICLE_LEVELS.size() - 1)
	carpet_density = clampi(state.get("carpet_density", carpet_density), 0, CARPET_DENSITY.size() - 1)
	carpet_range = clampi(state.get("carpet_range", carpet_range), 0, CARPET_RANGE.size() - 1)
	mid_grass = clampi(state.get("mid_grass", mid_grass), 0, MID_GRASS.size() - 1)
	road_quality = clampi(state.get("road_quality", road_quality), 0, ROAD_QUALITY.size() - 1)
	road_range = clampi(state.get("road_range", road_range), 0, ROAD_RANGE.size() - 1)
	lighting = clampi(state.get("lighting", lighting), 0, 2)
	fog_quality = clampi(state.get("fog_quality", fog_quality), 0, FOG_QUALITY_LEVELS.size() - 1)
	cloud_quality = clampi(state.get("cloud_quality", cloud_quality), 0, CLOUD_QUALITY_LEVELS.size() - 1)
	for id: String in VisualStyle.EFFECTS:
		style_on[id] = bool(state.get("style_on", style_on).get(id, style_on[id]))
		style_amount[id] = clampf(float(state.get("style_amount", style_amount).get(id, style_amount[id])), 0.0, 1.0)


## Час, в который начинается мир: выбранный игроком или случайный
func pick_start_hour() -> float:
	return start_hour if start_hour_set else randf() * 24.0


## Общая громкость: шина Master, на нуле звук выключен совсем
func apply_volume() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.001)))
	AudioServer.set_bus_mute(0, volume <= 0.0)


## Full in-memory reset; never touches the player profile.
func reset() -> void:
	reset_defaults()
	settings_path = PATH
	active_template = WorldTemplate.DEFAULT_ID
	_template_worlds.clear()
	last_seed = ""
	recent_seeds.clear()
	favorite_seeds.clear()
	hide_recommended_worlds = false
	infinite_world = false
