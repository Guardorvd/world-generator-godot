class_name WorldTemplate
extends RefCounted
## Реестр типов мира (docs/WORLD_TEMPLATES.md): читает настройки из resources/world_types/*.tres (WorldTypeConfig).
## Чтобы добавить третий тип мира, достаточно создать новый .tres и добавить строку в _CATALOG ниже.
## Значения по умолчанию у Типа 1 ("mountain_valley") обязаны побайтно сохранять прежнюю генерацию, кэш, сохранения и настройки.

const DEFAULT_ID := "mountain_valley"
const EXPEDITION_ID := "river_expedition"

const TEMPLATE_FLAG := "--template"
const SHORT_FLAG := "--short-expedition"
const HEIGHT_FLAG := "--exp-height"

const MAX_TEXTURE_SIDE := 4096

## Каталог меню и файлов настроек: для нового типа мира достаточно добавить сюда строку и .tres-файл.
const _CATALOG := [
	{id = DEFAULT_ID, path = "res://resources/world_types/mountain_valley.tres",
		description = "Дороги, поселения и свобода выбирать маршрут среди гор.", artwork = "res://resources/menu/type_valley.jpg"},
	{id = EXPEDITION_ID, path = "res://resources/world_types/river_expedition.tres",
		description = "Длинный путь вдоль реки, через лес и предгорья.", artwork = "res://resources/menu/type_expedition.jpg"},
	{id = "future_3", title = "Будущий тип 3", available = false},
	{id = "future_4", title = "Будущий тип 4", available = false},
]

static var _cache := {}
static var _cache_lock := Mutex.new()


static func _load_all(fresh := false) -> void:
	_cache_lock.lock()
	if not _cache.is_empty():
		_cache_lock.unlock()
		return
	var mode := ResourceLoader.CACHE_MODE_IGNORE if fresh else ResourceLoader.CACHE_MODE_REUSE
	for item: Dictionary in _CATALOG:
		var path := str(item.get("path", ""))
		if path.is_empty():
			continue
		var res := ResourceLoader.load(path, "", mode)
		if res is WorldTypeConfig:
			var cfg := res as WorldTypeConfig
			_cache[str(item.id)] = cfg
		else:
			push_error("WorldTemplate: не удалось загрузить настройки типа мира " + path)
	if not _cache.has(DEFAULT_ID):
		_cache[DEFAULT_ID] = WorldTypeConfig.new()
	_cache_lock.unlock()


static func reload_templates() -> void:
	_cache_lock.lock()
	_cache.clear()
	_cache_lock.unlock()
	ValleyAxis.clear_cache()
	RoadTuning.clear_template_cache()
	_load_all(true)


static func config(id: String) -> WorldTypeConfig:
	_load_all()
	_cache_lock.lock()
	var cfg: WorldTypeConfig = _cache.get(id, _cache.get(DEFAULT_ID))
	_cache_lock.unlock()
	return cfg


static func exists(id: String) -> bool:
	_load_all()
	_cache_lock.lock()
	var ok := _cache.has(id)
	_cache_lock.unlock()
	return ok


static func normalize_id(id: String) -> String:
	return id if exists(id) else DEFAULT_ID


static func is_default(id: String) -> bool:
	return normalize_id(id) == DEFAULT_ID


static func ids() -> PackedStringArray:
	_load_all()
	var out := PackedStringArray()
	for item: Dictionary in _CATALOG:
		var tid := str(item.id)
		if exists(tid):
			out.append(tid)
	return out


static func menu_types() -> Array[Dictionary]:
	_load_all()
	var out: Array[Dictionary] = []
	for item: Dictionary in _CATALOG:
		var tid := str(item.id)
		if exists(tid):
			var cfg := config(tid)
			out.append({id = tid, title = cfg.title, available = cfg.available and cfg.id == tid,
				description = str(item.get("description", "")), artwork = str(item.get("artwork", ""))})
		else:
			out.append({id = tid, title = str(item.get("title", tid)), available = bool(item.get("available", false))})
	return out


static func full_plan_territory(id: String) -> bool:
	return config(id).full_plan_territory


static func allow_infinite_regions(id: String) -> bool:
	return config(id).allow_infinite_regions


static func pick_start(id: String) -> bool:
	return config(id).pick_start


static func home_is_first_settlement(id: String) -> bool:
	return config(id).home_is_first_settlement


static func show_valley_length(id: String) -> bool:
	return config(id).show_valley_length


static func has_valley_relief(id: String) -> bool:
	return config(id).valley_relief


static func has_valley_river(id: String) -> bool:
	return config(id).valley_river


static func has_single_road(id: String) -> bool:
	return config(id).single_road


static func road_tuning_path(id: String) -> String:
	return config(id).road_tuning_path


static func expedition_route_kind(id: String) -> String:
	var kind := config(id).expedition_route_kind
	return kind if not kind.is_empty() else "road"


static func allow_road_gaps(id: String) -> bool:
	return config(id).allow_road_gaps


## Суффиксы ключа кэша по .tres настроек типа (пусто для Типа 1 — его ключи не меняются).
static func geo_cache_suffix(id: String) -> String:
	var tid := normalize_id(id)
	if tid == DEFAULT_ID:
		return ""
	return "|tpl=%s|g=%s" % [tid, config(tid).geo_cache_digest()]


static func places_cache_suffix(id: String) -> String:
	var tid := normalize_id(id)
	if tid == DEFAULT_ID:
		return ""
	return "|p=" + config(tid).places_cache_digest()


## Возвращает конфиг растительности шаблона (null для Типа 1).
static func vegetation_config(id: String) -> WorldVegetationConfig:
	return config(id).vegetation


## Возвращает конфиг атмосферы, сезона и LUT шаблона (null для Типа 1).
static func atmosphere_config(id: String) -> WorldAtmosphereConfig:
	return config(id).atmosphere


## Плоский буфер VP_* для C#/GD генерации растительности (пустой для Типа 1 без конфига).
static func veg_params(id: String, plan_h := 0) -> PackedFloat64Array:
	var cfg := config(id)
	if cfg.vegetation == null:
		return PackedFloat64Array()
	var h_use := plan_h if plan_h > 0 else cfg.dev_height
	var drop := clampf(float(maxi(1, h_use - 1)) * GameConfig.TILE * cfg.river_target_grade / GameConfig.HS, cfg.river_drop_min, cfg.river_drop_max)
	return cfg.vegetation.veg_params(cfg.eco_base, cfg.river_bot_h, cfg.river_bot_h + drop)


## Суффикс слоя nature по параметрам WorldVegetationConfig (пусто для Типа 1).
static func nature_cache_suffix(id: String) -> String:
	var tid := normalize_id(id)
	if tid == DEFAULT_ID:
		return ""
	var suffix := "|expedition-vegetation-3" if tid == EXPEDITION_ID else ""
	var vdigest := config(tid).nature_cache_digest()
	if vdigest != "none":
		suffix += "|v=" + vdigest
	return suffix + config(tid).relief_generation_suffix()


## Суффикс картинок мира (подстилка леса): с эрозией влажность подстилки — после эрозии (этап 5 части 2 плана
## рельефа, Heightfield.ground_moisture); прежние картинки Типа 2 с влажностью до эрозии не годятся. Пусто для Типа 1.
static func view_cache_suffix(id: String) -> String:
	var tid := normalize_id(id)
	if tid == DEFAULT_ID or config(tid).relief_generation_suffix().is_empty():
		return ""
	return "|flow-moisture-1"


## Суффикс артефакта surface по параметрам микрорельефа тропы (пусто для Типа 1).
static func surface_cache_suffix(id: String) -> String:
	var tid := normalize_id(id)
	if tid == DEFAULT_ID:
		return ""
	return "|s=" + config(tid).surface_cache_digest()


## Размер плана (W, H) в клетках по сиду и типу. Длина кратна 64 и строго <= 4096 (потолок GPU-текстур).
static func plan_size(id: String, seed_num: int, short_dev := false, explicit_height := 0) -> Vector2i:
	var cfg := config(id)
	var width := cfg.plan_width
	if is_default(id):
		return Vector2i(width, cfg.plan_heights[0] if not cfg.plan_heights.is_empty() else 768)
	var h := 0
	if explicit_height > 0:
		h = explicit_height
	elif short_dev or cmdline_short():
		h = cfg.dev_height
	else:
		var cli_h := cmdline_height()
		if cli_h > 0:
			h = cli_h
		else:
			var heights := cfg.plan_heights
			var pick := WGRandom.at(seed_num, "template.length")
			h = heights[floori(pick.next_float() * heights.size()) % heights.size()] if not heights.is_empty() else cfg.dev_height
	h = clampi((h / 64) * 64, 256, MAX_TEXTURE_SIDE)
	return Vector2i(width, h)


static func valid_plan_size(id: String, width: int, height: int) -> bool:
	var cfg := config(id)
	if is_default(id):
		var h0 := cfg.plan_heights[0] if not cfg.plan_heights.is_empty() else 768
		return width == cfg.plan_width and height == h0
	return width == cfg.plan_width and height >= 256 and height <= MAX_TEXTURE_SIDE and height % 64 == 0


## Параметры линейной широты Vector3(lat_base, lat_center, lat_cells) для формулы:
##   lat = lat_base + (y - lat_center) / lat_cells
## Едина для StageClimate.latitude, FastGrid.ClimateFields и OuterLand.compute.
static func latitude_params(id: String, plan_height: int) -> Vector3:
	var cfg := config(id)
	if cfg.lat_mode == "fixed":
		return Vector3(cfg.lat_base, cfg.lat_center, cfg.lat_cells)
	var span := maxf(1e-4, cfg.lat_end - cfg.lat_start)
	var cells := maxf(1.0, float(plan_height - 1)) / span
	return Vector3(cfg.lat_start, 0.0, cells)


## Соседние папки кэша и сохранений: Тип 1 сохраняет прежние пути (включая QuickTrails),
## другие типы лежат рядом, не внутри папки Типа 1.
static func cache_dir(id: String) -> String:
	var tid := normalize_id(id)
	if tid == DEFAULT_ID:
		return QuickTrails.cache_dir()
	return "user://world_cache_" + tid


static func saves_dir(id: String) -> String:
	var tid := normalize_id(id)
	if tid == DEFAULT_ID:
		return QuickTrails.saves_dir()
	return "user://saves_" + tid


static func settings_section(id: String) -> String:
	var tid := normalize_id(id)
	return "world" if tid == DEFAULT_ID else "world_" + tid


## Ключи запуска для инструментов и отладки вне сборки для игрока (по образцу QuickTrails).
static func cmdline_template() -> String:
	if OS.has_feature("template"):
		return DEFAULT_ID
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == TEMPLATE_FLAG and i + 1 < args.size():
			return normalize_id(args[i + 1].strip_edges())
		if args[i].begins_with(TEMPLATE_FLAG + "="):
			return normalize_id(args[i].substr(TEMPLATE_FLAG.length() + 1).strip_edges())
	return DEFAULT_ID


static func cmdline_short() -> bool:
	return not OS.has_feature("template") and OS.get_cmdline_user_args().has(SHORT_FLAG)


static func cmdline_height() -> int:
	if OS.has_feature("template"):
		return 0
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == HEIGHT_FLAG and i + 1 < args.size():
			return maxi(0, int(args[i + 1]))
		if args[i].begins_with(HEIGHT_FLAG + "="):
			return maxi(0, int(args[i].substr(HEIGHT_FLAG.length() + 1)))
	return 0
