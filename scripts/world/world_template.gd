class_name WorldTemplate
extends RefCounted
## Неизменяемый справочник типов мира (docs/WORLD_TEMPLATES.md).
## Значения по умолчанию у Типа 1 ("mountain_valley") обязаны побайтно сохранять прежнюю генерацию,
## кэш, сохранения и настройки истории игрока.

const DEFAULT_ID := "mountain_valley"
const EXPEDITION_ID := "river_expedition"

const TEMPLATE_FLAG := "--template"
const SHORT_FLAG := "--short-expedition"
const HEIGHT_FLAG := "--exp-height"

const MAX_TEXTURE_SIDE := 4096

const _TEMPLATES := {
	mountain_valley = {
		id = DEFAULT_ID,
		title = "Горная долина",
		available = true,
		plan_width = 768,
		plan_heights = [768],
		dev_height = 768,
		full_plan_territory = false,
		allow_infinite_regions = true,
		pick_start = true,
		lat_mode = "fixed",
		lat_base = 0.5,
		lat_center = 383.5,
		lat_cells = 3072.0,
		valley_relief = false,
		valley_river = false,
		single_road = false,
		routing_overrides = {},
	},
	river_expedition = {
		id = EXPEDITION_ID,
		title = "Речная экспедиция",
		available = true,
		plan_width = 256,
		plan_heights = [2560, 3072, 3584],
		dev_height = 768,
		full_plan_territory = true,
		allow_infinite_regions = false,
		pick_start = false,
		lat_mode = "span",
		lat_start = 0.28,
		lat_end = 0.46,
		valley_relief = true,
		valley_river = true,
		single_road = true,
		routing_overrides = {
			shore_mul = 1.0,
			meander_amp_road = 0.36,
		},
	},
}

const _MENU_ORDER := [
	{id = DEFAULT_ID, title = "Горная долина", available = true},
	{id = EXPEDITION_ID, title = "Речная экспедиция", available = true},
	{id = "future_3", title = "Будущий тип 3", available = false},
	{id = "future_4", title = "Будущий тип 4", available = false},
]


static func exists(id: String) -> bool:
	return _TEMPLATES.has(id)


static func normalize_id(id: String) -> String:
	return id if _TEMPLATES.has(id) else DEFAULT_ID


static func get_template(id: String) -> Dictionary:
	return _TEMPLATES.get(id, _TEMPLATES[DEFAULT_ID])


static func is_default(id: String) -> bool:
	return normalize_id(id) == DEFAULT_ID


static func is_expedition(id: String) -> bool:
	return normalize_id(id) == EXPEDITION_ID


static func menu_types() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item: Dictionary in _MENU_ORDER:
		out.append(item.duplicate())
	return out


static func ids() -> PackedStringArray:
	return PackedStringArray([DEFAULT_ID, EXPEDITION_ID])


static func full_plan_territory(id: String) -> bool:
	return bool(get_template(id).full_plan_territory)


static func allow_infinite_regions(id: String) -> bool:
	return bool(get_template(id).allow_infinite_regions)


static func pick_start(id: String) -> bool:
	return bool(get_template(id).pick_start)


static func has_valley_relief(id: String) -> bool:
	return bool(get_template(id).valley_relief)


static func has_valley_river(id: String) -> bool:
	return bool(get_template(id).valley_river)


static func has_single_road(id: String) -> bool:
	return bool(get_template(id).single_road)


static func routing_overrides(id: String) -> Dictionary:
	return get_template(id).routing_overrides


static func expedition_site_counts(id: String, plan_height: int) -> Dictionary:
	if not has_single_road(id):
		return {}
	var full := plan_height >= 1500
	return {
		fishing = 1,
		tower = 2 if full else 1,
		shelter = 1,
		bench = 3 if full else 2,
		opposite_farm = 1,
	}


static func routing_overrides_suffix(id: String) -> String:
	var ov: Dictionary = routing_overrides(id)
	if ov.is_empty():
		return ""
	var keys := ov.keys()
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%s" % [str(k), str(ov[k])])
	return "|tpl_route=" + ",".join(parts).sha256_text().left(12)


## Размер плана (W, H) в клетках по сиду и типу. Длина кратна 64 и строго <= 4096 (потолок GPU-текстур).
static func plan_size(id: String, seed_num: int, short_dev := false, explicit_height := 0) -> Vector2i:
	var t := get_template(id)
	var width: int = int(t.plan_width)
	if is_default(id):
		return Vector2i(width, int(t.plan_heights[0]))
	var h := 0
	if explicit_height > 0:
		h = explicit_height
	elif short_dev or cmdline_short():
		h = int(t.dev_height)
	else:
		var cli_h := cmdline_height()
		if cli_h > 0:
			h = cli_h
		else:
			var heights: Array = t.plan_heights
			var pick := WGRandom.at(seed_num, "template.length")
			h = int(heights[floori(pick.next_float() * heights.size()) % heights.size()])
	h = clampi((h / 64) * 64, 256, MAX_TEXTURE_SIDE)
	return Vector2i(width, h)


static func valid_plan_size(id: String, width: int, height: int) -> bool:
	var t := get_template(id)
	if is_default(id):
		return width == int(t.plan_width) and height == int(t.plan_heights[0])
	return width == int(t.plan_width) and height >= 256 and height <= MAX_TEXTURE_SIDE and height % 64 == 0


## Параметры линейной широты Vector3(lat_base, lat_center, lat_cells) для формулы:
##   lat = lat_base + (y - lat_center) / lat_cells
## Едина для StageClimate.latitude, FastGrid.ClimateFields и OuterLand.compute.
static func latitude_params(id: String, plan_height: int) -> Vector3:
	var t := get_template(id)
	if t.lat_mode == "fixed":
		return Vector3(float(t.lat_base), float(t.lat_center), float(t.lat_cells))
	var span := maxf(1e-4, float(t.lat_end) - float(t.lat_start))
	var cells := maxf(1.0, float(plan_height - 1)) / span
	return Vector3(float(t.lat_start), 0.0, cells)


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
