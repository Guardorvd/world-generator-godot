extends Button
## Компактная карточка одной записи общей ленты.

const Feed = preload("res://scripts/game/ride_feed.gd")
const RideLog = preload("res://scripts/game/ride_log.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const Config = preload("res://resources/ride_journal.tres")


func setup(entry: Dictionary, feed) -> void:
	custom_minimum_size.y = Config.card_height
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = Config.card_padding
	row.offset_top = Config.card_padding
	row.offset_right = -Config.card_padding
	row.offset_bottom = -Config.card_padding
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	var preview := TextureRect.new()
	preview.custom_minimum_size = Config.card_thumb_size
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var path: String = feed.thumb_path(str(entry.id))
	if FileAccess.file_exists(path):
		var image := Image.load_from_file(path)
		if image != null and not image.is_empty():
			preview.texture = ImageTexture.create_from_image(image)
	row.add_child(preview)
	var lines := VBoxContainer.new()
	lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lines)
	var title := Label.new()
	title.text = ("👣  " if bool(entry.get("walk", false)) else "") + RideLog.date_text(float(entry.get("start", 0.0)))
	title.add_theme_font_size_override("font_size", Config.card_title_font)
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(title)
	var subtitle := Label.new()
	var tid := str(entry.get("template_id", ""))
	var type_config := WorldTemplate.config(tid) if WorldTemplate.exists(tid) else null
	var type_title: String = type_config.title if type_config != null else tid
	var type_row := HBoxContainer.new()
	type_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(type_row)
	if type_config != null and type_config.icon != null:
		var type_icon := TextureRect.new()
		type_icon.texture = type_config.icon
		type_icon.custom_minimum_size = Vector2.ONE * Config.card_icon_size
		type_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		type_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		type_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		type_row.add_child(type_icon)
	subtitle.text = "%s · %s" % [entry.get("world_title", ""), type_title]
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subtitle.clip_text = true
	subtitle.add_theme_font_size_override("font_size", Config.card_text_font)
	subtitle.add_theme_color_override("font_color", HudStyle.MUTED)
	subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	type_row.add_child(subtitle)
	var stats := Label.new()
	var ascent := "%d м" % roundi(float(entry.climb)) if entry.has("climb") else "—"
	var falls := str(int(entry.falls)) if entry.has("falls") else "—"
	stats.text = "%s · %s\n↑ %s · падений %s" % [Util.distance_text(float(entry.get("bike", 0.0))), RideLog.duration_text(float(entry.get("time", 0.0))), ascent, falls]
	stats.add_theme_font_size_override("font_size", Config.card_text_font)
	stats.clip_text = true
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(stats)
