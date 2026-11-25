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
var _list: Container
var _cards := {}
var _group := ButtonGroup.new()
var _wide_cards := false
var _selected := {}
var _detail_button: Button
var _dialog: AcceptDialog
var _pending_paths: Array[String] = []
var _pending_entries: Array[Dictionary] = []
var _pending_elapsed := 0.0
var _pending_poll := 0.0


func setup(game_settings, seed := "", template_id := "") -> void:
	theme = HudStyle.theme()
	settings = game_settings
	world_seed = seed
	world_template = template_id
	_only_world = not seed.is_empty()
	_wide_cards = world_seed.is_empty() and get_viewport_rect().size.x >= 800.0
	add_theme_constant_override("separation", Config.feed_spacing)
	var title := Label.new()
	title.text = "Журнал заездов" if world_seed.is_empty() else "ЖУРНАЛ ЗАЕЗДОВ"
	title.add_theme_font_size_override("font_size", Config.feed_wide_title_font if world_seed.is_empty() else Config.feed_title_font)
	add_child(title)
	if world_seed.is_empty():
		var subtitle := Label.new()
		subtitle.text = "Поездки и прогулки из всех миров"
		HudStyle.label(subtitle, 14, HudStyle.MUTED)
		add_child(subtitle)
	if not world_seed.is_empty():
		var filter := OptionButton.new()
		filter.add_item("Этот мир")
		filter.add_item("Все миры")
		filter.select(0)
		filter.item_selected.connect(func(index: int) -> void:
			_only_world = index == 0
			refresh())
		add_child(filter)
	var walks := CheckButton.new()
	walks.text = "Пешие прогулки"
	if world_seed.is_empty():
		walks.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
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
	if world_seed.is_empty():
		var grid := GridContainer.new()
		grid.add_theme_constant_override("h_separation", Config.feed_spacing)
		grid.add_theme_constant_override("v_separation", Config.feed_spacing)
		_list = grid
		resized.connect(_reflow_list)
	else:
		_list = VBoxContainer.new()
		_list.add_theme_constant_override("separation", Config.feed_spacing)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	_reflow_list()
	_detail_button = Button.new()
	_detail_button.text = "Подробнее о поездке"
	_detail_button.disabled = true
	_detail_button.visible = not world_seed.is_empty()
	_detail_button.pressed.connect(func() -> void: _show_detail(_selected))
	add_child(_detail_button)
	refresh()


func same_world(entry: Dictionary) -> bool:
	return not world_seed.is_empty() and str(entry.get("seed", "")) == world_seed and str(entry.get("template_id", "")) == world_template


func _reflow_list() -> void:
	if _list is GridContainer:
		_list.columns = 2 if size.x >= 720.0 else 1
		if size.x > 0.0:
			var wide := size.x >= 480.0
			if wide != _wide_cards:
				_wide_cards = wide
				if _detail_button != null and _list.get_child_count() > 0:
					refresh.call_deferred()


func refresh() -> void:
	var err: Error = feed.load_feed()
	_pending_paths.clear()
	_pending_entries.clear()
	_pending_elapsed = 0.0
	_pending_poll = 0.0
	set_process(false)
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_cards.clear()
	if err != OK:
		var error := Label.new()
		error.text = "Не удалось прочитать журнал"
		_list.add_child(error)
		return
	var selected_id := str(_selected.get("id", ""))
	var selected_visible := false
	for entry: Dictionary in feed.entries:
		if (_only_world and not same_world(entry)) or (bool(entry.get("walk", false)) and not settings.show_walks):
			continue
		_pending_entries.append(entry)
		if str(entry.id) == selected_id:
			_selected = entry
			selected_visible = true
	if _pending_entries.is_empty():
		var empty := Label.new()
		empty.text = "Заездов пока нет" if feed.entries.is_empty() else "Нет записей по этому фильтру"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", HudStyle.MUTED)
		_list.add_child(empty)
	if not selected_id.is_empty() and not selected_visible:
		_selected = {}
		_detail_button.disabled = true
		ride_selected.emit({})
	_append_cards()
	set_process(not _pending_entries.is_empty() or not _pending_paths.is_empty())
	controls_created.emit(self)


func _append_cards() -> void:
	var count := mini(maxi(1, Config.feed_cards_per_frame), _pending_entries.size())
	for i in count:
		var entry: Dictionary = _pending_entries.pop_front()
		var card := Card.new()
		_list.add_child(card)
		card.setup(entry, feed, _wide_cards)
		if not str(entry.get("thumb", "")).is_empty():
			var thumb_path: String = feed.thumb_path(str(entry.id))
			if not FileAccess.file_exists(thumb_path):
				_pending_paths.append(thumb_path)
		card.button_group = _group
		_cards[str(entry.id)] = card
		if str(entry.id) == str(_selected.get("id", "")):
			card.set_pressed_no_signal(true)
		card.pressed.connect(_choose.bind(entry))
		controls_created.emit(card)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	if not _pending_entries.is_empty():
		_append_cards()
	_pending_elapsed += delta
	_pending_poll += delta
	if _pending_elapsed >= Config.pending_preview_timeout:
		_pending_paths.clear()
	if _pending_entries.is_empty() and _pending_paths.is_empty():
		set_process(false)
		return
	if _pending_poll < Config.pending_preview_interval:
		return
	_pending_poll = 0.0
	for path: String in _pending_paths.duplicate():
		if FileAccess.file_exists(path):
			for id: String in _cards:
				if feed.thumb_path(id) == path:
					_cards[id].update_preview(path)
			_pending_paths.erase(path)


func _choose(entry: Dictionary) -> void:
	_selected = entry
	if _cards.has(str(entry.id)):
		_cards[str(entry.id)].set_pressed_no_signal(true)
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
	_dialog.title = "Итог заезда"
	_dialog.theme = HudStyle.theme()
	_dialog.add_theme_stylebox_override("panel", HudStyle.sheet(Vector2(20, 16)))
	_dialog.add_theme_stylebox_override("embedded_border", _window_border())
	_dialog.add_theme_color_override("title_color", HudStyle.CREAM)
	var available := Vector2i(get_viewport().get_visible_rect().size) - Vector2i(32, 32)
	_dialog.min_size = Config.detail_min_size.min(available)
	add_child(_dialog)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Config.detail_scroll_size.min(Vector2(available - Vector2i(32, 80)))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dialog.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", Config.feed_spacing)
	scroll.add_child(box)
	var title := Label.new()
	title.text = ("ПЕШАЯ ПРОГУЛКА · " if bool(entry.get("walk", false)) else "ПОЕЗДКА · ") + RideLog.date_text(float(entry.get("start", 0.0)))
	HudStyle.label(title, 18, HudStyle.CREAM)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)
	var world := Label.new()
	var tid := str(entry.get("template_id", ""))
	var type_title: String = WorldTemplate.config(tid).title if WorldTemplate.exists(tid) else tid
	world.text = "%s · %s" % [entry.get("world_title", ""), type_title]
	HudStyle.label(world, 14, HudStyle.MUTED)
	world.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(world)
	var preview_path: String = feed.thumb_path(str(entry.id))
	var preview_box := PanelContainer.new()
	preview_box.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.PAPER, HudStyle.BORDER, 6, Vector2(4, 4), false))
	box.add_child(preview_box)
	var preview := TextureRect.new()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = Vector2(0, Config.detail_preview_height)
	preview_box.add_child(preview)
	if FileAccess.file_exists(preview_path):
		var image := Image.load_from_file(preview_path)
		if image != null and not image.is_empty():
			preview.texture = ImageTexture.create_from_image(image)
	if preview.texture == null:
		var missing := Label.new()
		missing.text = "Карта поездки недоступна"
		missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		missing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		HudStyle.label(missing, 14, HudStyle.SURFACE)
		preview.add_child(missing)
		missing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var profile_title := Label.new()
	profile_title.text = "ПРОФИЛЬ ВЫСОТЫ"
	HudStyle.label(profile_title, 12, HudStyle.AMBER)
	box.add_child(profile_title)
	var profile := Profile.new()
	profile.values = entry.get("profile", [])
	profile.marks = entry.get("fall_marks", [])
	profile.custom_minimum_size.y = Config.detail_profile_height
	box.add_child(profile)
	if profile.values.size() >= 2:
		var limits := Label.new()
		limits.text = "мин. %d м    ·    макс. %d м" % [roundi(float(profile.values.min())), roundi(float(profile.values.max()))]
		HudStyle.label(limits, 12, HudStyle.MUTED)
		box.add_child(limits)
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
	grid.add_theme_constant_override("v_separation", Config.feed_spacing)
	box.add_child(grid)
	for item: Array in labels:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 1)
		grid.add_child(cell)
		var caption := Label.new()
		caption.text = str(item[0])
		HudStyle.label(caption, 12, HudStyle.MUTED)
		caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cell.add_child(caption)
		var value := Label.new()
		value.text = str(item[1])
		HudStyle.label(value, 16, HudStyle.CREAM)
		value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cell.add_child(value)
	var places := Label.new()
	places.text = "Места: " + (", ".join(entry.get("places", [])) if not entry.get("places", []).is_empty() else "—")
	places.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(places)
	var paths: Array[String] = []
	for path: String in entry.get("photo_paths", []):
		if FileAccess.file_exists(path):
			paths.append(path)
	if not paths.is_empty():
		var photos_title := Label.new()
		photos_title.text = "СНИМКИ · %d" % paths.size()
		HudStyle.label(photos_title, 12, HudStyle.AMBER)
		box.add_child(photos_title)
		var photos := GridContainer.new()
		photos.columns = 3 if available.x >= 600 else 2
		photos.add_theme_constant_override("h_separation", Config.feed_spacing)
		photos.add_theme_constant_override("v_separation", Config.feed_spacing)
		box.add_child(photos)
		var more := Button.new()
		more.text = "Показать ещё снимки"
		box.add_child(more)
		var state := {next = 0}
		more.pressed.connect(func() -> void: _append_photos(photos, paths, state, more))
		_append_photos(photos, paths, state, more)
	var remove := Button.new()
	remove.text = "Удалить запись"
	remove.theme_type_variation = &"DangerButton"
	box.add_child(remove)
	remove.pressed.connect(func() -> void:
		var confirm := ConfirmationDialog.new()
		confirm.title = "Удалить запись?"
		confirm.dialog_text = "Запись и её превью будут удалены."
		_dialog.add_child(confirm)
		controls_created.emit(confirm)
		confirm.confirmed.connect(func() -> void:
			if feed.load_feed() == OK and feed.erase(str(entry.id)) == OK:
				_selected = {}
				_detail_button.disabled = true
				ride_selected.emit({})
				_dialog.hide()
				refresh())
		confirm.popup_centered())
	controls_created.emit(_dialog)
	_dialog.popup_centered(Config.detail_window_size.min(available))


func _append_photos(grid: GridContainer, paths: Array[String], state: Dictionary, more: Button) -> void:
	var last := mini(paths.size(), int(state.next) + maxi(1, Config.detail_photos_per_batch))
	while int(state.next) < last:
		var path := paths[int(state.next)]
		state.next += 1
		var image := Image.load_from_file(path)
		if image == null or image.is_empty():
			continue
		if image.get_width() > Config.detail_photo_width:
			image.resize(Config.detail_photo_width, maxi(1, roundi(float(image.get_height()) * Config.detail_photo_width / image.get_width())), Image.INTERPOLATE_BILINEAR)
		var button := TextureButton.new()
		button.texture_normal = ImageTexture.create_from_image(image)
		button.ignore_texture_size = true
		button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		button.custom_minimum_size = Vector2(Config.detail_photo_width / 3.0, Config.detail_photo_height)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = "Открыть снимок"
		button.accessibility_name = "Открыть снимок " + path.get_file()
		button.pressed.connect(_open_photo.bind(path))
		grid.add_child(button)
		controls_created.emit(button)
	more.visible = int(state.next) < paths.size()


func _open_photo(path: String) -> void:
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return
	var dialog := AcceptDialog.new()
	dialog.title = "Снимок поездки"
	dialog.theme = HudStyle.theme()
	dialog.add_theme_stylebox_override("panel", HudStyle.sheet())
	dialog.add_theme_stylebox_override("embedded_border", _window_border())
	dialog.add_theme_color_override("title_color", HudStyle.CREAM)
	_dialog.add_child(dialog)
	var view := TextureRect.new()
	view.texture = ImageTexture.create_from_image(image)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var available := Vector2i(get_viewport().get_visible_rect().size) - Vector2i(80, 100)
	view.custom_minimum_size = Vector2(available)
	dialog.add_child(view)
	dialog.close_requested.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)
	controls_created.emit(dialog)
	dialog.popup_centered(available)


static func _window_border() -> StyleBoxFlat:
	var border := HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 8, Vector2.ZERO, false)
	border.expand_margin_left = 16.0
	border.expand_margin_right = 16.0
	border.expand_margin_top = 40.0
	border.expand_margin_bottom = 16.0
	return border


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
