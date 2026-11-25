extends Button
## Карточка общей ленты: одинаково работает в меню и в узком доке карты.

const RideLog = preload("res://scripts/game/ride_log.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const Config = preload("res://resources/ride_journal.tres")
var _preview: TextureRect
var _missing: Label


func setup(entry: Dictionary, feed, wide := false) -> void:
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
	var path: String = feed.thumb_path(str(entry.id))
	update_preview(path)
	if preview.texture == null:
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
	var lines := VBoxContainer.new()
	lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lines.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lines.add_theme_constant_override("separation", 3)
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lines)
	var date := Label.new()
	date.text = RideLog.date_text(float(entry.get("start", 0.0)))
	date.add_theme_font_size_override("font_size", Config.card_wide_title_font if wide else Config.card_title_font)
	date.add_theme_color_override("font_color", HudStyle.CREAM)
	date.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	date.clip_text = true
	date.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(date)
	var tid := str(entry.get("template_id", ""))
	var type_config := WorldTemplate.config(tid) if WorldTemplate.exists(tid) else null
	var type_title: String = type_config.title if type_config != null else tid
	var world := Label.new()
	world.text = str(entry.get("world_title", ""))
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
	var distance := float(entry.get("foot", 0.0)) if bool(entry.get("walk", false)) else float(entry.get("bike", 0.0))
	stats.text = "%s · %s" % [Util.distance_text(distance), RideLog.duration_text(float(entry.get("time", 0.0)))]
	stats.add_theme_font_size_override("font_size", text_size)
	stats.add_theme_color_override("font_color", HudStyle.CREAM)
	stats.clip_text = true
	stats.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(stats)
	var extra := Label.new()
	var ascent := "%d м" % roundi(float(entry.climb)) if entry.has("climb") else "—"
	var falls := str(int(entry.falls)) if entry.has("falls") else "—"
	extra.text = "↑ %s · падений %s" % [ascent, falls]
	extra.add_theme_font_size_override("font_size", text_size)
	extra.add_theme_color_override("font_color", HudStyle.MUTED)
	extra.clip_text = true
	extra.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	extra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(extra)
	accessibility_name = "%s, %s, %s, %s" % ["Пешая прогулка" if bool(entry.get("walk", false)) else "Поездка", date.text, world.text, stats.text]
	tooltip_text = "%s · %s · %s" % [world.text, type_title, date.text]


func update_preview(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return
	_preview.texture = ImageTexture.create_from_image(image)
	if is_instance_valid(_missing):
		_missing.queue_free()
		_missing = null


class FootIcon extends Control:
	func _draw() -> void:
		var scale_factor := minf(size.x, size.y) / 16.0
		draw_line(Vector2(5, 3) * scale_factor, Vector2(4, 8) * scale_factor, HudStyle.AMBER, 3.0 * scale_factor, true)
		draw_line(Vector2(11, 8) * scale_factor, Vector2(10, 13) * scale_factor, HudStyle.AMBER, 3.0 * scale_factor, true)
		draw_circle(Vector2(6, 1.5) * scale_factor, 1.2 * scale_factor, HudStyle.AMBER)
		draw_circle(Vector2(12, 6.5) * scale_factor, 1.2 * scale_factor, HudStyle.AMBER)
