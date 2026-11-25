extends VBoxContainer
## Одна лента для главного меню и вкладки поездок.

signal ride_selected(entry: Dictionary)
signal controls_created(root: Node)

const Feed = preload("res://scripts/game/ride_feed.gd")
const Card = preload("res://scripts/ui/ride_card.gd")
const RideLog = preload("res://scripts/game/ride_log.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const Config = preload("res://resources/ride_journal.tres")

var feed = Feed.new()
var settings
var world_seed := ""
var world_template := ""
var _only_world := false
var _list: VBoxContainer
var _selected := {}
var _detail_button: Button
var _dialog: AcceptDialog


func setup(game_settings, seed := "", template_id := "") -> void:
	settings = game_settings
	world_seed = seed
	world_template = template_id
	_only_world = not seed.is_empty()
	add_theme_constant_override("separation", Config.feed_spacing)
	var title := Label.new()
	title.text = "ЖУРНАЛ ЗАЕЗДОВ"
	title.add_theme_font_size_override("font_size", Config.feed_title_font)
	add_child(title)
	if not world_seed.is_empty():
		var filter := CheckButton.new()
		filter.text = "Только этот мир"
		filter.button_pressed = _only_world
		filter.toggled.connect(func(on: bool) -> void:
			_only_world = on
			refresh())
		add_child(filter)
	var walks := CheckButton.new()
	walks.text = "Пешие прогулки"
	walks.button_pressed = settings.show_walks
	walks.toggled.connect(func(on: bool) -> void:
		settings.show_walks = on
		settings.save_settings()
		refresh())
	add_child(walks)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = Config.feed_list_height
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	_detail_button = Button.new()
	_detail_button.text = "Подробнее о поездке"
	_detail_button.disabled = true
	_detail_button.pressed.connect(func() -> void: _show_detail(_selected))
	add_child(_detail_button)
	refresh()


func same_world(entry: Dictionary) -> bool:
	return not world_seed.is_empty() and str(entry.get("seed", "")) == world_seed and str(entry.get("template_id", "")) == world_template


func refresh() -> void:
	var err: Error = feed.load_feed()
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if err != OK:
		var error := Label.new()
		error.text = "Не удалось прочитать журнал"
		_list.add_child(error)
		return
	var count := 0
	for entry: Dictionary in feed.entries:
		if (_only_world and not same_world(entry)) or (bool(entry.get("walk", false)) and not settings.show_walks):
			continue
		var card := Card.new()
		_list.add_child(card)
		card.setup(entry, feed)
		card.pressed.connect(_choose.bind(entry))
		count += 1
	if count == 0:
		var empty := Label.new()
		empty.text = "Заездов пока нет"
		empty.add_theme_color_override("font_color", HudStyle.MUTED)
		_list.add_child(empty)
	controls_created.emit(self)


func _choose(entry: Dictionary) -> void:
	_selected = entry
	_detail_button.disabled = false
	ride_selected.emit(entry if same_world(entry) else {})
	if not same_world(entry):
		_show_detail(entry)


func _show_detail(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	if is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = AcceptDialog.new()
	_dialog.title = "Поездка · " + RideLog.date_text(float(entry.get("start", 0.0)))
	_dialog.min_size = Config.detail_min_size
	add_child(_dialog)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Config.detail_scroll_size
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dialog.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var preview_path: String = feed.thumb_path(str(entry.id))
	if FileAccess.file_exists(preview_path):
		var image := Image.load_from_file(preview_path)
		if image != null and not image.is_empty():
			var preview := TextureRect.new()
			preview.texture = ImageTexture.create_from_image(image)
			preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			preview.custom_minimum_size = Vector2(0, Config.detail_preview_height)
			box.add_child(preview)
	var profile := Profile.new()
	profile.values = entry.get("profile", [])
	profile.marks = entry.get("fall_marks", [])
	profile.custom_minimum_size.y = Config.detail_profile_height
	box.add_child(profile)
	var labels := [
		["Велосипед", Util.distance_text(float(entry.get("bike", 0.0)))],
		["Пешком", Util.distance_text(float(entry.get("foot", 0.0)))],
		["Время", RideLog.duration_text(float(entry.get("time", 0.0)))],
		["В движении", RideLog.duration_text(float(entry.moving_time)) if entry.has("moving_time") else "—"],
		["Набор / сброс", _metric(entry, "climb", " м") + " / " + _metric(entry, "descent", " м")],
		["Высота мин. / макс.", _metric(entry, "alt_min", " м") + " / " + _metric(entry, "alt_max", " м")],
		["Скорость средняя / макс.", _speed(entry, "speed_avg") + " / " + _speed(entry, "speed_max")],
		["Прыжки / полёт", _metric(entry, "jumps", "") + " / " + _metric(entry, "air_max", " с")],
		["Падения", _metric(entry, "falls", "")],
		["Снимки / задания", "%d / %d" % [int(entry.get("photos", 0)), int(entry.get("quests", 0))]],
	]
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Config.detail_grid_gap)
	box.add_child(grid)
	for item: Array in labels:
		var line := Label.new()
		line.text = "%s · %s" % item
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(line)
	var places := Label.new()
	places.text = "Места: " + (", ".join(entry.get("places", [])) if not entry.get("places", []).is_empty() else "—")
	places.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(places)
	for path: String in entry.get("photo_paths", []):
		if FileAccess.file_exists(path):
			var photo_image := Image.load_from_file(path)
			if photo_image != null and not photo_image.is_empty():
				if photo_image.get_width() > Config.detail_photo_width:
					photo_image.resize(Config.detail_photo_width, maxi(1, roundi(float(photo_image.get_height()) * Config.detail_photo_width / photo_image.get_width())), Image.INTERPOLATE_BILINEAR)
				var photo := TextureRect.new()
				photo.texture = ImageTexture.create_from_image(photo_image)
				photo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				photo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				photo.custom_minimum_size.y = Config.detail_photo_height
				box.add_child(photo)
	var remove := Button.new()
	remove.text = "Удалить запись"
	box.add_child(remove)
	remove.pressed.connect(func() -> void:
		var confirm := ConfirmationDialog.new()
		confirm.title = "Удалить запись?"
		confirm.dialog_text = "Запись и её превью будут удалены."
		_dialog.add_child(confirm)
		confirm.confirmed.connect(func() -> void:
			if feed.load_feed() == OK and feed.erase(str(entry.id)) == OK:
				_selected = {}
				_detail_button.disabled = true
				ride_selected.emit({})
				_dialog.hide()
				refresh())
		confirm.popup_centered())
	_dialog.popup_centered(Config.detail_window_size)


static func _metric(entry: Dictionary, key: String, unit: String) -> String:
	return ("%.1f" % float(entry[key])).trim_suffix(".0") + unit if entry.has(key) else "—"


static func _speed(entry: Dictionary, key: String) -> String:
	return "%.1f км/ч" % (float(entry[key]) * 3.6) if entry.has(key) else "—"


class Profile extends Control:
	var values: Array = []
	var marks: Array = []

	func _draw() -> void:
		if values.size() < 2:
			draw_string(ThemeDB.fallback_font, Vector2(8, 28), "Профиль высоты недоступен", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, HudStyle.MUTED)
			return
		var low := float(values.min())
		var high := float(values.max())
		var span := maxf(high - low, 1.0)
		var points := PackedVector2Array()
		for i in values.size():
			points.append(Vector2(float(i) / float(values.size() - 1) * size.x, size.y - (float(values[i]) - low) / span * (size.y - Config.profile_padding * 2.0) - Config.profile_padding))
		draw_polyline(points, HudStyle.MINT, Config.profile_line_width, true)
		for mark: Dictionary in marks:
			var x := clampf(float(mark.get("progress", 0.0)), 0.0, 1.0) * (values.size() - 1)
			var index := mini(floori(x), values.size() - 2)
			var p := points[index].lerp(points[index + 1], x - index)
			var radius: float = Config.profile_fall_radius
			draw_line(p + Vector2(-radius, -radius), p + Vector2(radius, radius), Config.map_fall_color, Config.profile_fall_width)
			draw_line(p + Vector2(-radius, radius), p + Vector2(radius, -radius), Config.map_fall_color, Config.profile_fall_width)
