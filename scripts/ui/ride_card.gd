extends Button
## Карточка общей ленты: одинаково работает в меню и в узком доке карты.

const RideLog = preload("res://scripts/game/ride_log.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const Config = preload("res://resources/ride_journal.tres")
const Feed = preload("res://scripts/game/ride_feed.gd")
const Presentation = preload("res://scripts/ui/ride_presentation.gd")
var _preview: TextureRect
var _cover: TextureRect
var _missing: Label
var preview_path := ""
var preview_revision := -1
var _failed_previews := {}
var _feed_box: VBoxContainer
var _feed_preview_box: PanelContainer
var _feed_metrics: GridContainer
var _compact_preview_box: PanelContainer
## 28.11: PNG превью (320×200, ~3 мс) декодируется в рабочем потоке, а не в кадре открытия планшета; готовые текстуры
## общие для карточек меню и планшета и живут в маленьком кэше по пути и версии файла.
const PREVIEW_CACHE_LIMIT := 24
static var _preview_cache := {} # путь -> [версия, текстура]
static var _preview_order: Array[String] = []
var _decode_task := -1
var _decode_result := {}
var _decode_path := ""
var _decode_revision := -2
var _decode_show := true


func setup(entry: Dictionary, feed, wide := false, failed_previews := {}) -> void:
	_failed_previews = failed_previews
	preview_path = feed.thumb_path(str(entry.id))
	if wide:
		_setup_feed_card(entry)
		return
	toggle_mode = true
	clip_contents = true
	custom_minimum_size.y = Config.card_wide_height if wide else Config.card_height
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	theme_type_variation = &"CardButton"
	tooltip_text = "Пешая прогулка" if bool(entry.get("walk", false)) else "Поездка на велосипеде"
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = Config.card_padding
	row.offset_top = Config.card_padding
	row.offset_right = -Config.card_padding
	row.offset_bottom = -Config.card_padding
	row.add_theme_constant_override("separation", Config.card_padding)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	var preview_box := PanelContainer.new()
	_compact_preview_box = preview_box
	var thumb_size: Vector2 = Config.card_wide_thumb_size if wide else Config.card_thumb_size
	var text_size: int = Config.card_wide_text_font if wide else Config.card_text_font
	preview_box.custom_minimum_size = thumb_size
	preview_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	preview_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_box.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.PAPER, HudStyle.BORDER, 4, Vector2.ZERO, false))
	row.add_child(preview_box)
	var preview := TextureRect.new()
	_preview = preview
	preview.custom_minimum_size = thumb_size
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_box.add_child(preview)
	update_preview(preview_path)
	var missing := Label.new()
	_missing = missing
	missing.text = "Нет карты"
	missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	missing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	missing.add_theme_font_size_override("font_size", text_size)
	missing.add_theme_color_override("font_color", HudStyle.SURFACE)
	missing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_child(missing)
	missing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	missing.visible = preview.texture == null
	update_preview_status()
	var lines := VBoxContainer.new()
	lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lines.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lines.add_theme_constant_override("separation", 3)
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lines)
	var date := Label.new()
	var full_date := RideLog.journal_date_text(float(entry.start)) if entry.has("start") else "Дата неизвестна"
	date.text = full_date.get_slice(", ", 0)
	date.add_theme_font_size_override("font_size", Config.card_wide_title_font if wide else Config.card_title_font)
	date.add_theme_color_override("font_color", HudStyle.CREAM)
	date.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	date.clip_text = true
	date.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(date)
	var tid := str(entry.get("template_id", ""))
	var type_config := WorldTemplate.config(tid) if WorldTemplate.exists(tid) else null
	var type_title: String = type_config.title if type_config != null else "Неизвестный тип мира"
	var world := Label.new()
	world.text = Presentation.world_name(entry)
	world.add_theme_font_size_override("font_size", text_size)
	world.add_theme_color_override("font_color", HudStyle.MUTED)
	world.clip_text = true
	world.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	world.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(world)
	var kind_row := HBoxContainer.new()
	kind_row.add_theme_constant_override("separation", 4)
	kind_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(kind_row)
	if bool(entry.get("walk", false)):
		var foot := FootIcon.new()
		foot.custom_minimum_size = Vector2.ONE * Config.card_icon_size
		foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		kind_row.add_child(foot)
	if type_config != null and type_config.icon != null:
		var icon := TextureRect.new()
		icon.texture = type_config.icon
		icon.custom_minimum_size = Vector2.ONE * Config.card_icon_size
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		kind_row.add_child(icon)
	var kind := Label.new()
	kind.text = ("Пешком · " if bool(entry.get("walk", false)) else "") + type_title
	kind.add_theme_font_size_override("font_size", text_size)
	kind.add_theme_color_override("font_color", HudStyle.AMBER if bool(entry.get("walk", false)) else HudStyle.MUTED)
	kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind.clip_text = true
	kind.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	kind.mouse_filter = Control.MOUSE_FILTER_IGNORE
	kind_row.add_child(kind)
	var stats := Label.new()
	var distance_key := "foot" if bool(entry.get("walk", false)) else "bike"
	var distance_text := Util.distance_text(float(entry[distance_key])) if entry.has(distance_key) else "—"
	var duration_text := RideLog.duration_text(float(entry.time)) if entry.has("time") else "—"
	stats.text = "%s · %s" % [distance_text, duration_text]
	stats.add_theme_font_size_override("font_size", text_size)
	stats.add_theme_color_override("font_color", HudStyle.CREAM)
	stats.clip_text = true
	stats.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(stats)
	var extra := Label.new()
	var falls := str(int(entry.falls)) if entry.has("falls") else "—"
	extra.text = "Падения · %s" % falls
	extra.add_theme_font_size_override("font_size", text_size)
	extra.add_theme_color_override("font_color", HudStyle.MUTED)
	extra.clip_text = true
	extra.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	extra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(extra)
	accessibility_name = "%s, %s, %s, %s, %s, падения: %s" % ["Пешая прогулка" if bool(entry.get("walk", false)) else "Поездка", full_date, world.text, type_title, stats.text, falls]
	tooltip_text = "%s · %s · %s" % [world.text, type_title, full_date]
	resized.connect(_fit_compact_card)
	_fit_compact_card.call_deferred()


func update_preview(path: String) -> void:
	if Feed.thumb_is_preparing(path):
		update_preview_status()
		return
	if not FileAccess.file_exists(path):
		return
	var revision := Feed.thumb_revision(path)
	if int(_failed_previews.get(path, -2)) == revision:
		return
	var cached: Variant = _preview_cache.get(path)
	if cached != null and int(cached[0]) == revision:
		_show_preview(cached[1], revision)
		return
	_decode_show = true
	if _decode_task != -1 and _decode_path == path and _decode_revision == revision:
		return
	_finish_decode(false)
	var result := {}
	_decode_result = result
	_decode_path = path
	_decode_revision = revision
	_decode_task = WorkerThreadPool.add_task(func() -> void: result.image = Image.load_from_file(path), false, "Превью заезда")
	set_process(true)


func _process(_delta: float) -> void:
	if _decode_task == -1:
		set_process(false)
	elif WorkerThreadPool.is_task_completed(_decode_task):
		_finish_decode(true)


func _finish_decode(apply: bool) -> void:
	if _decode_task == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_decode_task)
	_decode_task = -1
	set_process(false)
	var image: Variant = _decode_result.get("image")
	_decode_result = {}
	if not apply:
		return
	var path := _decode_path
	var revision := _decode_revision
	if image == null or not image is Image or (image as Image).is_empty():
		_failed_previews[path] = revision
		return
	_failed_previews.erase(path)
	var texture := ImageTexture.create_from_image(image)
	_preview_cache[path] = [revision, texture]
	_preview_order.erase(path)
	_preview_order.append(path)
	while _preview_order.size() > PREVIEW_CACHE_LIMIT:
		_preview_cache.erase(_preview_order.pop_front())
	if revision != Feed.thumb_revision(path):
		update_preview(path) # пока шло чтение, файл заменили
	elif _decode_show:
		_show_preview(texture, revision)


func _show_preview(texture: Texture2D, revision: int) -> void:
	_preview.texture = texture
	preview_revision = revision
	if is_instance_valid(_missing):
		_missing.hide()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _decode_task != -1:
		WorkerThreadPool.wait_for_task_completion(_decode_task)


func update_preview_status() -> void:
	if is_instance_valid(_missing) and _preview.texture == null and not (is_instance_valid(_cover) and _cover.visible):
		_missing.text = ("Подготавливаем карту…" if _feed_box != null else "Готовится…") if Feed.thumb_is_preparing(preview_path) else ("Карта поездки недоступна" if _feed_box != null else "Нет карты")
		_missing.show()


func unload_preview() -> void:
	_decode_show = false # идущее чтение только пополнит кэш
	if is_instance_valid(_preview):
		_preview.texture = null
		if is_instance_valid(_missing):
			_missing.show()


func _fit_compact_card() -> void:
	if not is_instance_valid(_compact_preview_box) or size.x <= 0.0:
		return
	var thumb_size: Vector2 = Vector2(58, 37) if size.x < 260.0 else Config.card_thumb_size
	_compact_preview_box.custom_minimum_size = thumb_size
	_preview.custom_minimum_size = thumb_size


func _setup_feed_card(entry: Dictionary) -> void:
	toggle_mode = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip_contents = true
	var normal := HudStyle.panel(Color(0.08, 0.12, 0.16, 0.86), Color(0.65, 0.70, 0.73, 0.35), 12, Vector2.ZERO, false)
	var hover := HudStyle.panel(Color(0.14, 0.19, 0.23, 0.94), Color(0.95, 0.80, 0.50, 0.8), 12, Vector2.ZERO, false)
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", hover)
	add_theme_stylebox_override("pressed", hover)
	add_theme_stylebox_override("hover_pressed", hover)
	var focus := HudStyle.panel(Color.TRANSPARENT, HudStyle.AMBER, 10, Vector2.ZERO, false)
	focus.draw_center = false
	focus.set_border_width_all(2)
	add_theme_stylebox_override("focus", focus)
	var box := VBoxContainer.new()
	_feed_box = box
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 18
	box.offset_right = -18
	box.offset_top = 14
	box.offset_bottom = -14
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	var walking := bool(entry.get("walk", false))
	var kind := "ПЕШАЯ ПРОГУЛКА" if walking else ("ВЕЛОПОЕЗДКА" if entry.has("walk") else "ПОЕЗДКА")
	var date := RideLog.journal_date_text(float(entry.start)) if entry.has("start") else "Дата неизвестна"
	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)
	var kind_label := _add_label(header, kind, 15, HudStyle.AMBER)
	kind_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var date_label := _add_label(header, date, 14, HudStyle.MUTED)
	date_label.clip_text = false
	date_label.custom_minimum_size.x = 156.0
	date_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var tid := str(entry.get("template_id", ""))
	var type_title: String = WorldTemplate.config(tid).title if WorldTemplate.exists(tid) else "Неизвестный тип мира"
	var world := Presentation.world_name(entry)
	_add_label(box, "%s · %s" % [world, type_title], 18, HudStyle.CREAM)
	var preview_box := PanelContainer.new()
	_feed_preview_box = preview_box
	preview_box.custom_minimum_size.y = 110
	preview_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_box.add_theme_stylebox_override("panel", HudStyle.panel(Color(0.14, 0.19, 0.22, 0.9), Color(0.70, 0.74, 0.73, 0.18), 6, Vector2.ZERO, false))
	preview_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(preview_box)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.clip_contents = true
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_box.add_child(_preview)
	_cover = TextureRect.new()
	_cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cover.hide()
	_preview.add_child(_cover)
	_missing = Label.new()
	_missing.text = "Карта поездки недоступна"
	_missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_missing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	HudStyle.label(_missing, 14, HudStyle.MUTED)
	_preview.add_child(_missing)
	_missing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	update_preview_status()
	var stats := GridContainer.new()
	_feed_metrics = stats
	stats.columns = 3
	stats.add_theme_constant_override("separation", 8)
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(stats)
	var distance_key := "foot" if walking or (not entry.has("walk") and not entry.has("bike") and entry.has("foot")) else "bike"
	var distance_caption := "Пешком" if distance_key == "foot" else ("На велосипеде" if entry.has("walk") or entry.has("bike") else "Расстояние")
	var distance := Util.distance_text(float(entry[distance_key])) if entry.has(distance_key) else "—"
	var duration := RideLog.duration_text(float(entry.time)) if entry.has("time") else "—"
	var falls := str(int(entry.falls)) if entry.has("falls") else "—"
	_add_metric(stats, distance_caption, distance)
	_add_metric(stats, "Длительность", duration)
	_add_metric(stats, "Падения", falls)
	_add_label(box, "Подробнее о поездке  ›", 15, HudStyle.AMBER)
	custom_minimum_size.y = 300
	resized.connect(_fit_feed_card)
	_fit_feed_card.call_deferred()
	accessibility_name = "%s, %s, %s, %s. %s: %s, длительность: %s, падения: %s. Подробнее о поездке" % [kind, date, world, type_title, distance_caption, distance, duration, falls]
	tooltip_text = "%s · %s · %s" % [world, type_title, date]


func _fit_feed_card() -> void:
	if size.x <= 0.0 or not is_instance_valid(_feed_box):
		return
	_feed_metrics.columns = 1 if size.x < 400.0 else 3
	var map_height := clampf((size.x - 36.0) * 0.22, 80.0, minf(110.0, maxf(80.0, Config.feed_preview_max_height)))
	_feed_preview_box.custom_minimum_size = Vector2(0, map_height)
	custom_minimum_size.y = _feed_box.get_combined_minimum_size().y + 32.0


func set_cover(texture: Texture2D) -> void:
	if not is_instance_valid(_cover):
		return
	_cover.texture = texture
	_cover.visible = texture != null
	if is_instance_valid(_missing):
		_missing.visible = texture == null and _preview.texture == null


func _add_label(parent: Node, value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	HudStyle.label(label, font_size, color)
	parent.add_child(label)
	return label


func _add_metric(parent: Node, caption: String, value: String) -> void:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(column)
	_add_label(column, caption, 13, HudStyle.MUTED)
	_add_label(column, value, 18, HudStyle.CREAM)


class FootIcon extends Control:
	func _draw() -> void:
		var scale_factor := minf(size.x, size.y) / 16.0
		draw_line(Vector2(5, 3) * scale_factor, Vector2(4, 8) * scale_factor, HudStyle.AMBER, 3.0 * scale_factor, true)
		draw_line(Vector2(11, 8) * scale_factor, Vector2(10, 13) * scale_factor, HudStyle.AMBER, 3.0 * scale_factor, true)
		draw_circle(Vector2(6, 1.5) * scale_factor, 1.2 * scale_factor, HudStyle.AMBER)
		draw_circle(Vector2(12, 6.5) * scale_factor, 1.2 * scale_factor, HudStyle.AMBER)
