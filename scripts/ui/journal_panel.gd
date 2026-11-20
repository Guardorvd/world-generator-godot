extends PanelContainer
## Полевой планшет. Карта и путь делят один вид атласа, альбом открывает уже сохранённые снимки.

signal closed

const HudStyle = preload("res://scripts/ui/hud_style.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const ShopPanel := preload("res://scripts/ui/shop_panel.gd")
const MUTED := HudStyle.MUTED
const CARD := Vector2(248, 206)
const THUMB := Vector2(230, 126)
const INK := Color("#101e1c")
const SURFACE := Color("#1a2c29")
const LINE := Color("#455e55")
const ACCENT := Color("#d2bd88")
const Atlas := preload("res://scripts/ui/world_map_view.gd")
enum Tab { MAP, PATH, ALBUM, SHOP }
var active_tab := Tab.MAP
var map_view: Atlas
var data_provider := Callable()
var quest_provider := Callable()
var _data := {}
var _load_photos := {}
var _map_page: VBoxContainer
var _map_row: BoxContainer
var _dock: PanelContainer
var _details: BoxContainer
var _dock_divider: HSeparator
var _place_title: Label
var _place_detail: Label
var _checklist: VBoxContainer
var _shown_quest := {}
var _map_hint: Label
var _tab_map: Button
var _seed: Label
var _rides: Array = []            # заезды открытой вкладки (Hud._ride_rows)
var _ride_buttons: Array[Button] = []
var _ride_info: VBoxContainer
const SHORT_GROUPS := ["Биомы", "Места", "Вершины и озёра", "Ночь", "Обелиски"]

var _box: VBoxContainer
var _path_page: VBoxContainer
var _album_page: VBoxContainer
var _album_scroll: ScrollContainer
var _album_content: VBoxContainer
var _album_filter := -1
var _album_data := {}
var _tab_path: Button
var _tab_album: Button
var _tab_shop: Button
var shop_panel: ShopPanel
var _cache := {}        # путь снимка -> уменьшенная ImageTexture | null
var _large_cache := {}  # путь снимка -> крупная ImageTexture для лайтбокса | null
var _close: Button
var _lightbox: Control
var _lightbox_return_focus: Control


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = HudStyle.theme()
	var background := StyleBoxFlat.new()
	background.bg_color = INK
	add_theme_stylebox_override("panel", background)
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 32 if edge in ["left", "right"] else 20)
	add_child(margin)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 12)
	margin.add_child(_box)
	_build_header()
	_build_map()
	_album_page = VBoxContainer.new()
	_album_page.add_theme_constant_override("separation", 8)
	_album_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_child(_album_page)
	shop_panel = ShopPanel.new()
	shop_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	shop_panel.hide()
	_box.add_child(shop_panel)
	resized.connect(_reflow)
	_reflow()
	hide()
	set_process(false)

func _label(text: String, size: int, parent: Control, color := Color.WHITE) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	if color != Color.WHITE:
		label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func clear() -> void:
	close_lightbox()
	hide()
	map_view.hide()
	shop_panel.hide()
	for child: Node in _album_page.get_children():
		_album_page.remove_child(child)
		child.queue_free()
	_album_scroll = null
	_album_content = null
	_album_filter = -1
	_album_data = {}
	_data = {}
	for child: Node in _path_page.get_children():
		_path_page.remove_child(child)
		child.queue_free()
	_shown_quest = {}
	_rides = []
	_ride_buttons.clear()
	_ride_info = null
	map_view.show_ride([], Rect2())
	_lightbox_return_focus = null
	_cache.clear()
	_large_cache.clear()
	_load_photos.clear()
	map_view.set_photo_pins(false, {})
	_fill_checklist({})
	set_process(false)


## Закрыть лайтбокс, если он открыт. Возвращает true, если лайтбокс был закрыт
func close_lightbox() -> bool:
	if _lightbox == null:
		return false
	if is_instance_valid(_lightbox):
		if _lightbox.get_parent() == self:
			remove_child(_lightbox)
		_lightbox.queue_free()
	_lightbox = null
	if is_instance_valid(_lightbox_return_focus) and _lightbox_return_focus.is_visible_in_tree():
		_lightbox_return_focus.grab_focus()
	elif is_instance_valid(_close) and _close.is_visible_in_tree():
		_close.grab_focus()
	_lightbox_return_focus = null
	return true


func dismiss_subpanel() -> bool:
	if active_tab == Tab.SHOP:
		return shop_panel.dismiss_purchase()
	return close_lightbox()


func open(data: Dictionary, album_tab := false) -> void:
	clear()
	_data = data
	open_tab(Tab.ALBUM if album_tab else Tab.PATH, str(data.get("seed", "")))


func open_tab(tab: Tab, seed_text: String) -> void:
	if not visible:
		_seed.text = seed_text
		show()
	_select(tab)


func cycle_tab(direction: int) -> void:
	if _lightbox == null:
		var tabs := [Tab.MAP, Tab.PATH, Tab.ALBUM, Tab.SHOP] if _tab_shop.visible else [Tab.MAP, Tab.PATH, Tab.ALBUM]
		_select(tabs[posmod(active_tab + direction, tabs.size())])


func set_shortcuts(map_key: String, path_key: String, hint: String) -> void:
	_tab_map.text = "Карта" if map_key.is_empty() else "Карта [%s]" % map_key
	_tab_path.text = "Заезды" if path_key.is_empty() else "Заезды [%s]" % path_key
	_map_hint.text = hint


func _build_header() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	_box.add_child(head)
	var emblem := UiIcons.rect(UiIcons.JOURNAL, 25, ACCENT)
	emblem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(emblem)
	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 0)
	head.add_child(identity)
	var eyebrow := _label("ПУТЕШЕСТВИЕ  /  ПОЛЕВОЙ АТЛАС", 11, identity, ACCENT)
	eyebrow.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var title := _label("Дневник путешествия", 25, identity, HudStyle.CREAM)
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_seed = _label("", 13, head, MUTED)
	_seed.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_seed.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_close = Button.new()
	_close.icon = UiIcons.CLOSE
	_close.tooltip_text = "Закрыть"
	_close.accessibility_name = "Закрыть дневник"
	_close.custom_minimum_size = Vector2(44, 44)
	_close.pressed.connect(func() -> void: closed.emit())
	head.add_child(_close)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 4)
	_box.add_child(tabs)
	var group := ButtonGroup.new()
	_tab_map = _tab("Карта", group, tabs, Tab.MAP)
	_tab_path = _tab("Заезды", group, tabs, Tab.PATH)
	_tab_album = _tab("Альбом", group, tabs, Tab.ALBUM)
	_tab_shop = _tab("Магазин", group, tabs, Tab.SHOP)
	_tab_shop.hide()


func _tab(text: String, group: ButtonGroup, parent: Container, tab: Tab) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.custom_minimum_size = Vector2(110, 44)
	button.add_theme_font_size_override("font_size", 16)
	var normal := HudStyle.panel(Color.TRANSPARENT, Color.TRANSPARENT, 0, Vector2(18, 8), false)
	var hover := HudStyle.panel(Color("#263c37"), Color.TRANSPARENT, 0, Vector2(18, 8), false)
	var selected := HudStyle.panel(Color("#32483e"), ACCENT, 0, Vector2(18, 8), false)
	selected.set_border_width_all(0)
	selected.border_width_bottom = 3
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", selected)
	button.add_theme_stylebox_override("hover_pressed", selected)
	button.add_theme_color_override("font_pressed_color", HudStyle.CREAM)
	button.add_theme_color_override("font_hover_pressed_color", HudStyle.CREAM)
	button.pressed.connect(_select.bind(tab))
	parent.add_child(button)
	return button


func _build_map() -> void:
	_map_page = VBoxContainer.new()
	_map_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_page.add_theme_constant_override("separation", 8)
	_box.add_child(_map_page)
	_map_row = BoxContainer.new()
	_map_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_row.add_theme_constant_override("separation", 12)
	_map_page.add_child(_map_row)
	map_view = Atlas.new()
	map_view.paper = true
	map_view.tablet = true
	map_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_view.custom_minimum_size = Vector2(120, 130)
	_map_row.add_child(map_view)
	map_view.hover_changed.connect(refresh_inspector)
	map_view.photo_thumbnail_requested.connect(_queue_photo)

	_dock = PanelContainer.new()
	_dock.add_theme_stylebox_override("panel", HudStyle.panel(SURFACE, LINE, 0, Vector2(18, 18), false))
	_map_row.add_child(_dock)
	_map_row.move_child(_dock, 0)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_dock.add_child(scroll)
	var dock_content := VBoxContainer.new()
	dock_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock_content.add_theme_constant_override("separation", 8)
	scroll.add_child(dock_content)
	_details = BoxContainer.new()
	_details.add_theme_constant_override("separation", 8)
	dock_content.add_child(_details)
	var inspector := VBoxContainer.new()
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.add_child(inspector)
	_label("ОРИЕНТИР", 12, inspector, ACCENT)
	_place_title = _label("", 18, inspector, HudStyle.CREAM)
	_place_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_place_detail = _label("", 14, inspector, MUTED)
	_place_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dock_divider = HSeparator.new()
	_details.add_child(_dock_divider)
	var objective := VBoxContainer.new()
	objective.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.add_child(objective)
	_label("ТЕКУЩЕЕ ЗАДАНИЕ", 12, objective, ACCENT)
	_checklist = VBoxContainer.new()
	_checklist.add_theme_constant_override("separation", 4)
	objective.add_child(_checklist)
	_path_page = VBoxContainer.new()
	_path_page.add_theme_constant_override("separation", 4)
	dock_content.add_child(_path_page)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	_map_page.add_child(footer)
	_map_hint = _label("", 13, footer, MUTED)
	_map_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_map_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var center := Button.new()
	center.text = "К себе"
	center.icon = UiIcons.map_icon("goal")
	center.custom_minimum_size.y = 40
	center.pressed.connect(func() -> void:
		map_view.center_on_player()
		center.release_focus())
	footer.add_child(center)


func _reflow() -> void:
	var narrow := size.x < 800.0
	_map_row.vertical = narrow
	_details.vertical = not narrow
	_dock_divider.visible = not narrow
	_seed.visible = not narrow
	_dock.custom_minimum_size = Vector2(0, 180) if narrow else Vector2(320, 0)
	_map_row.move_child(_dock, 1 if narrow else 0)
	_dock.size_flags_vertical = Control.SIZE_FILL if narrow else Control.SIZE_EXPAND_FILL


func enable_shop(profile: ShopPanel.Progress) -> void:
	shop_panel.set_profile(profile)
	_tab_shop.show()


func _select(tab: Tab) -> void:
	if tab == Tab.SHOP and shop_panel.visible:
		return
	close_lightbox()
	active_tab = tab
	_tab_map.set_pressed_no_signal(tab == Tab.MAP)
	_tab_path.set_pressed_no_signal(tab == Tab.PATH)
	_tab_album.set_pressed_no_signal(tab == Tab.ALBUM)
	_tab_shop.set_pressed_no_signal(tab == Tab.SHOP)
	_map_page.visible = tab == Tab.MAP or tab == Tab.PATH
	map_view.visible = _map_page.visible
	_path_page.visible = tab == Tab.PATH
	_details.visible = tab == Tab.MAP
	_album_page.visible = tab == Tab.ALBUM
	shop_panel.visible = tab == Tab.SHOP
	if tab in [Tab.PATH, Tab.ALBUM] and _data.is_empty() and data_provider.is_valid():
		_data = data_provider.call()
	if tab == Tab.PATH and _path_page.get_child_count() == 0:
		_fill_path(_data)
	if tab == Tab.ALBUM and _album_scroll == null:
		_fill_album(_data)
	map_view.set_photo_pins(tab == Tab.PATH, _cache)
	if tab != Tab.PATH:
		map_view.show_ride([], Rect2())
	_load_photos.clear()
	set_process(false)
	if tab == Tab.SHOP:
		shop_panel.open()
	refresh_inspector(map_view.hover)
	refresh_quest()


func refresh_inspector(place: Dictionary) -> void:
	if not _map_page.is_visible_in_tree():
		return
	if place.is_empty():
		place = map_view.selected_place
	var title := str(place.get("name", ""))
	var detail := "Наведитесь на метку или выберите её." if place.is_empty() else ""
	if not place.is_empty():
		var status := PackedStringArray()
		var kind: String = {peak = "Вершина", lake = "Озеро", site = "Место", settlement = "Поселение"}.get(place.kind, "")
		if not kind.is_empty():
			status.append(kind)
		var flags := int(place.get("map_status", 0))
		if flags & Atlas.Status.VISITED:
			status.append("Посещено")
		elif flags & Atlas.Status.REVEALED:
			status.append("Открыто по сведениям")
		if flags & Atlas.Status.PHOTO:
			status.append("Есть снимок")
		if flags & Atlas.Status.QUEST:
			status.append("Текущий шаг задания")
		var at := Atlas.place_at(place)
		if map_view.player.is_finite():
			status.append("%s от вас" % Util.distance_text(at.distance_to(map_view.player)))
		detail = " · ".join(status)
	_place_title.text = title
	_place_title.visible = not title.is_empty()
	_place_detail.text = detail


func refresh_quest() -> void:
	if not _map_page.is_visible_in_tree() or not quest_provider.is_valid():
		return
	var data: Dictionary = quest_provider.call()
	if data != _shown_quest or _checklist.get_child_count() == 0:
		_shown_quest = data
		_fill_checklist(data)


func _fill_checklist(data: Dictionary) -> void:
	for child: Node in _checklist.get_children():
		_checklist.remove_child(child)
		child.queue_free()
	if data.is_empty():
		_label("Активного задания нет", 14, _checklist, MUTED)
		return
	var title := _label(data.title, 16, _checklist, HudStyle.CREAM)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for i in data.steps.size():
		var marker := "✓" if i < data.index else ("▸" if i == data.index else "○")
		var color := HudStyle.MINT if i <= data.index else MUTED
		var line := _label("%s  %s" % [marker, data.steps[i]], 14, _checklist, color)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


## 20.11.2026: вкладка «Заезды» — история игровых сессий (RideLog): список, у выбранного трек на карте, счётчики
## и места; ниже — итог за всю игру (прежняя сводка пути)
func _fill_path(data: Dictionary) -> void:
	_rides = data.get("rides", [])
	_ride_buttons.clear()
	_label("ИСТОРИЯ МАРШРУТОВ", 12, _path_page, ACCENT)
	_label("Ваши заезды", 22, _path_page, HudStyle.CREAM)
	_label("Выберите заезд, чтобы увидеть его на карте", 13, _path_page, MUTED).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _rides.is_empty():
		_label("Заездов пока нет", 14, _path_page, MUTED)
	var group := ButtonGroup.new()
	for i in _rides.size():
		var ride: Dictionary = _rides[i]
		var button := Button.new()
		button.toggle_mode = true
		button.button_group = group
		button.text = "%s
%s" % [ride.title, ride.summary]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size.y = 64
		button.add_theme_font_size_override("font_size", 15)
		button.add_theme_stylebox_override("normal", HudStyle.panel(Color("#213631"), LINE, 0, Vector2(12, 8), false))
		button.add_theme_stylebox_override("hover", HudStyle.panel(Color("#314a40"), ACCENT, 0, Vector2(12, 8), false))
		button.add_theme_stylebox_override("pressed", HudStyle.panel(Color("#435b49"), ACCENT, 0, Vector2(12, 8), false))
		button.add_theme_stylebox_override("hover_pressed", HudStyle.panel(Color("#4b6350"), ACCENT, 0, Vector2(12, 8), false))
		button.tooltip_text = "Показать заезд на карте"
		button.pressed.connect(_select_ride.bind(i))
		_path_page.add_child(button)
		_ride_buttons.append(button)
	_ride_info = VBoxContainer.new()
	_ride_info.add_theme_constant_override("separation", 4)
	_path_page.add_child(_ride_info)

	_path_page.add_child(HSeparator.new())
	_label("ИТОГО ЗА ПУТЕШЕСТВИЕ", 12, _path_page, ACCENT)
	_label("Велосипед · %s   Пешком · %s" % [Util.distance_text(data.get("bike", 0.0)), Util.distance_text(data.get("foot", 0.0))],
		13, _path_page, HudStyle.CREAM).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label("В пути · %s   Высшая точка · %d м" % [_duration(data.get("time", 0.0)), roundi(data.get("alt", 0.0))], 13, _path_page, MUTED)
	_label("Снимков · %d   Заданий · %d" % [data.get("photos", 0), data.get("quests", 0)], 13, _path_page, MUTED)
	for entry: Array in data.get("places", []):
		_label("%s · %d / %d" % entry, 13, _path_page, MUTED)
	var series: Dictionary = data.get("series", {})
	if int(series.get("total", 0)) > 0 or series.get("finished", false):
		var line := "Летопись обелисков · завершена" if series.finished else "Летопись обелисков · %d / %d" % [series.done, series.total]
		_label(line, 13, _path_page, HudStyle.MINT).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for line: Variant in data.get("thanks", []):
		_label(str(line), 13, _path_page, HudStyle.AMBER).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if data.get("thanks", []).is_empty():
		for name: Variant in data.get("helped", []):
			_label(str(name), 13, _path_page, MUTED).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if not _rides.is_empty():
		_ride_buttons[0].set_pressed_no_signal(true)
		_select_ride.call_deferred(0) # карта уже разложена: вид подгоняется под трек заезда


## Выбранный заезд: трек на карте, вид на него, счётчики и места
func _select_ride(index: int) -> void:
	if index >= _rides.size() or _ride_info == null or active_tab != Tab.PATH:
		return
	var ride: Dictionary = _rides[index]
	for i in _ride_buttons.size():
		_ride_buttons[i].set_pressed_no_signal(i == index)
	for child: Node in _ride_info.get_children():
		_ride_info.remove_child(child)
		child.queue_free()
	_label("ВЫБРАННЫЙ ЗАЕЗД", 12, _ride_info, ACCENT)
	_label(ride.title + (" · идёт сейчас" if ride.current else ""), 17, _ride_info, HudStyle.CREAM)
	var metrics := GridContainer.new()
	metrics.columns = 2
	metrics.add_theme_constant_override("h_separation", 8)
	metrics.add_theme_constant_override("v_separation", 6)
	_ride_info.add_child(metrics)
	_metric(metrics, "ВЕЛОСИПЕД", Util.distance_text(ride.bike))
	_metric(metrics, "ПЕШКОМ", Util.distance_text(ride.foot))
	_metric(metrics, "В ПУТИ", _duration(ride.time))
	_metric(metrics, "ВЫСШАЯ ТОЧКА", "%d м" % roundi(ride.alt))
	_label("Снимков · %d   Заданий · %d" % [ride.photos, ride.quests], 14, _ride_info, MUTED)
	var places: Array = ride.places
	var where := "Места: " + ", ".join(PackedStringArray(places)) if not places.is_empty() else "Места: —"
	_label(where, 13, _ride_info, MUTED).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if ride.legs.is_empty():
		_label("Трека нет: стояли на месте", 13, _ride_info, MUTED)
	map_view.show_ride(ride.legs, ride.bounds)


func _metric(parent: GridContainer, caption: String, value: String) -> void:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 0)
	parent.add_child(box)
	_label(caption, 11, box, MUTED)
	_label(value, 17, box, HudStyle.CREAM)


static func _duration(seconds: float) -> String:
	var s := int(seconds)
	return "%d:%02d:%02d" % [s / 3600, s / 60 % 60, s % 60]


func _queue_photo(path: String) -> void:
	_load_photos[path] = true
	set_process(true)


func _process(_dt: float) -> void:
	if not _load_photos.is_empty():
		var path: String = _load_photos.keys()[0]
		_load_photos.erase(path)
		_thumbnail(path)
		map_view.refresh_overlay()
	if _load_photos.is_empty():
		set_process(false)


func _fill_album(data: Dictionary) -> void:
	_album_data = data
	var pages: Array = data.get("pages", [])
	var groups: Array = data.get("groups", [])
	var nav_bar := HFlowContainer.new()
	nav_bar.add_theme_constant_override("separation", 8)
	_album_page.add_child(nav_bar)

	var total_all := pages.size()
	var done_all := pages.filter(func(p: Dictionary) -> bool: return not p.shot.is_empty()).size()
	var pill_group := ButtonGroup.new()
	var all_pill := _pill("Все %d/%d" % [done_all, total_all], -1, pill_group, nav_bar)
	all_pill.set_pressed_no_signal(true)

	for g in groups.size():
		var mine := pages.filter(func(p: Dictionary) -> bool: return p.group == g)
		if mine.is_empty():
			continue
		var done := mine.filter(func(p: Dictionary) -> bool: return not p.shot.is_empty()).size()
		var short_name: String = SHORT_GROUPS[g] if g < SHORT_GROUPS.size() else str(groups[g])
		_pill("%s %d/%d" % [short_name, done, mine.size()], g, pill_group, nav_bar)


	_album_scroll = ScrollContainer.new()
	_album_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_album_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_album_scroll.follow_focus = true
	_album_page.add_child(_album_scroll)
	_album_content = VBoxContainer.new()
	_album_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_album_content.add_theme_constant_override("separation", 12)
	_album_scroll.add_child(_album_content)
	_album_scroll.resized.connect(_resize_album_grid)
	_rebuild_album_grid()


func _pill(text: String, group_index: int, group: ButtonGroup, parent: Container) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.button_group = group
	btn.theme_type_variation = &"PillButton"
	btn.add_theme_stylebox_override("normal", HudStyle.panel(SURFACE, LINE, 0, Vector2(14, 8), false))
	btn.add_theme_stylebox_override("hover", HudStyle.panel(Color("#30463b"), ACCENT, 0, Vector2(14, 8), false))
	btn.add_theme_stylebox_override("pressed", HudStyle.panel(Color("#435b49"), ACCENT, 0, Vector2(14, 8), false))
	btn.add_theme_stylebox_override("hover_pressed", HudStyle.panel(Color("#4b6350"), ACCENT, 0, Vector2(14, 8), false))
	btn.custom_minimum_size.y = 44
	btn.pressed.connect(func() -> void:
		_album_filter = group_index
		_rebuild_album_grid()
		if _album_scroll != null:
			_album_scroll.scroll_vertical = 0)
	parent.add_child(btn)
	return btn


func _rebuild_album_grid() -> void:
	if _album_content == null:
		return
	for child: Node in _album_content.get_children():
		_album_content.remove_child(child)
		child.queue_free()
	var pages: Array = _album_data.get("pages", [])
	var groups: Array = _album_data.get("groups", [])
	var opened_all: Array[Dictionary] = []
	for p: Dictionary in pages:
		if not p.shot.is_empty():
			opened_all.append(p)
	for g in groups.size():
		if _album_filter >= 0 and g != _album_filter:
			continue
		var mine: Array = pages.filter(func(p: Dictionary) -> bool: return p.group == g)
		if mine.is_empty():
			continue
		var done := mine.filter(func(p: Dictionary) -> bool: return not p.shot.is_empty()).size()
		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 8)
		_album_content.add_child(header)
		header.add_child(UiIcons.rect(UiIcons.album_icon(g, str(mine[0].get("key", ""))), 18, HudStyle.MINT))
		_label("%s  /  %d из %d" % [groups[g], done, mine.size()], 20, header, HudStyle.CREAM)
		var grid := GridContainer.new()
		grid.columns = _album_columns()
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 12)
		_album_content.add_child(grid)
		for page: Dictionary in mine:
			grid.add_child(_card(page, opened_all))


func _album_columns() -> int:
	return maxi(1, floori((_album_scroll.size.x - 8.0) / (CARD.x + 12.0)))


func _resize_album_grid() -> void:
	if _album_content == null:
		return
	for child: Node in _album_content.get_children():
		if child is GridContainer:
			child.columns = _album_columns()


func _card(page: Dictionary, opened_all: Array[Dictionary]) -> Control:
	var done: bool = not page.shot.is_empty()
	var root_ctrl: Control
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if done:
		var btn := Button.new()
		btn.custom_minimum_size = CARD
		btn.theme_type_variation = &"CardButton"
		btn.add_theme_stylebox_override("normal", HudStyle.panel(SURFACE, LINE, 0, Vector2(8, 8), false))
		btn.add_theme_stylebox_override("hover", HudStyle.panel(Color("#293e35"), ACCENT, 0, Vector2(8, 8), false))
		btn.add_theme_stylebox_override("pressed", HudStyle.panel(Color("#435b49"), ACCENT, 0, Vector2(8, 8), false))
		btn.clip_contents = true
		btn.tooltip_text = "Открыть крупно: «%s»" % page.title
		btn.pressed.connect(func() -> void: _open_lightbox(page, opened_all, btn))
		var pad := MarginContainer.new()
		pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		for edge in ["left", "right", "top", "bottom"]:
			pad.add_theme_constant_override("margin_" + edge, 8)
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(pad)
		pad.add_child(column)
		root_ctrl = btn
	else:
		var panel := PanelContainer.new()
		panel.custom_minimum_size = CARD
		panel.clip_contents = true
		panel.add_theme_stylebox_override("panel", HudStyle.panel(SURFACE, LINE, 0, Vector2(9, 9), false))
		panel.add_child(column)
		root_ctrl = panel

	var frame := Control.new()
	frame.custom_minimum_size = THUMB
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(frame)
	var texture := _thumbnail(page.shot.get("path", "")) if done else null
	if texture != null:
		var clip := Panel.new()
		clip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		clip.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
		clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var clip_style := HudStyle.panel(HudStyle.SURFACE, HudStyle.SURFACE, 0, Vector2.ZERO, false)
		clip_style.set_border_width_all(0)
		clip.add_theme_stylebox_override("panel", clip_style)
		frame.add_child(clip)
		var view := TextureRect.new()
		view.texture = texture
		view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip.add_child(view)
		var date_text := str(page.shot.get("date", "")).left(10)
		if not date_text.is_empty():
			var dbadge := PanelContainer.new()
			dbadge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dbadge.add_theme_stylebox_override("panel", HudStyle.panel(Color(HudStyle.SURFACE, 0.84), Color(HudStyle.BORDER, 0.7), 4, Vector2(4, 4), false))
			dbadge.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			dbadge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			dbadge.grow_vertical = Control.GROW_DIRECTION_BEGIN
			dbadge.offset_right = -4
			dbadge.offset_bottom = -4
			var dlbl := Label.new()
			dlbl.text = date_text
			HudStyle.label(dlbl, 10, HudStyle.CREAM)
			dbadge.add_child(dlbl)
			frame.add_child(dbadge)
		if page.get("text", "") != "":
			var tbadge := PanelContainer.new()
			tbadge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tbadge.add_theme_stylebox_override("panel", HudStyle.panel(Color(HudStyle.SURFACE, 0.84), Color(HudStyle.MINT, 0.7), 4, Vector2(4, 4), false))
			tbadge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			tbadge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			tbadge.offset_right = -4
			tbadge.offset_top = 4
			var tlbl := Label.new()
			tlbl.text = "Текст"
			HudStyle.label(tlbl, 10, HudStyle.MINT)
			tbadge.add_child(tlbl)
			frame.add_child(tbadge)
	else:
		var plate := Panel.new()
		plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var pbg := HudStyle.RECESS if not done else HudStyle.RECESS.lerp(HudStyle.AMBER, 0.18)
		plate.add_theme_stylebox_override("panel", HudStyle.panel(pbg, Color(HudStyle.BORDER, 0.45), 0, Vector2.ZERO, false))
		frame.add_child(plate)
		if not done:
			var center := CenterContainer.new()
			center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			center.mouse_filter = Control.MOUSE_FILTER_IGNORE
			center.add_child(UiIcons.rect(UiIcons.album_icon(int(page.group), str(page.key), int(page.get("form", 0))), 36, Color(MUTED, 0.25)))
			plate.add_child(center)
		else:
			var deleted := _label("снимок удалён", 12, plate, Color(HudStyle.AMBER, 0.85))
			deleted.set_anchors_preset(Control.PRESET_FULL_RECT)
			deleted.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			deleted.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			deleted.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 4)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(title_row)
	title_row.add_child(UiIcons.rect(UiIcons.album_icon(int(page.group), str(page.key), int(page.get("form", 0))), 13, HudStyle.MINT if done else Color(MUTED, 0.5)))
	var title := _label(str(page.title), 14, title_row, HudStyle.CREAM if done else MUTED)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sub_text := ""
	var sub_color := Color(MUTED, 0.72)
	if done:
		if page.get("text", "") != "":
			sub_text = str(page.text)
			sub_color = MUTED
		elif str(page.get("place_name", "")) != "":
			sub_text = str(page.place_name)
			sub_color = HudStyle.MINT
		else:
			sub_text = "Нажмите для просмотра"
			sub_color = HudStyle.MINT
	else:
		sub_text = str(page.hint)
	var note := _label(sub_text, 12, column, sub_color)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = THUMB.x
	note.max_lines_visible = 2
	note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return root_ctrl


func _open_lightbox(page: Dictionary, opened_all: Array[Dictionary], return_to: Control = null, focus_target := "close") -> void:
	# 19.11.2026: при листании затемнение остаётся, меняется только карточка снимка (прежде пересоздавалось всё окно)
	var flip := _lightbox != null and is_instance_valid(_lightbox) and _lightbox.get_parent() == self
	if flip:
		for old: Node in _lightbox.get_children():
			_lightbox.remove_child(old)
			old.queue_free()
	elif _lightbox != null:
		if is_instance_valid(_lightbox):
			_lightbox.queue_free()
		_lightbox = null
	_lightbox_return_focus = return_to
	var idx := 0
	for i in opened_all.size():
		if opened_all[i].key == page.key:
			idx = i
			break

	if not flip:
		var shade := PanelContainer.new()
		shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		shade.mouse_filter = Control.MOUSE_FILTER_STOP
		var bg_style := StyleBoxFlat.new()
		bg_style.bg_color = Color(0.03, 0.07, 0.06, 0.88)
		bg_style.set_corner_radius_all(12)
		bg_style.set_content_margin_all(24)
		shade.add_theme_stylebox_override("panel", bg_style)
		shade.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				close_lightbox())
		_lightbox = shade
		add_child(shade)
	var backdrop := _lightbox

	var modal := PanelContainer.new()
	modal.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	modal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var modal_width := minf(820.0, maxf(280.0, size.x - 48.0))
	modal.custom_minimum_size = Vector2(modal_width, 0)
	modal.add_theme_stylebox_override("panel", HudStyle.sheet(Vector2(20, 16)))
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.add_child(modal)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	modal.add_child(vbox)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vbox.add_child(head)
	head.add_child(UiIcons.rect(UiIcons.album_icon(int(page.group), str(page.key), int(page.get("form", 0))), 20, HudStyle.MINT))
	var title := _label(str(page.title), 22, head, HudStyle.CREAM)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var groups: Array = _album_data.get("groups", [])
	var gidx := int(page.get("group", 0))
	if gidx >= 0 and gidx < groups.size():
		head.add_child(HudStyle.chip(str(groups[gidx]), HudStyle.MINT))
	var close_btn := Button.new()
	close_btn.icon = UiIcons.CLOSE
	close_btn.text = "Закрыть"
	close_btn.custom_minimum_size = Vector2(124, 44)
	close_btn.pressed.connect(func() -> void: close_lightbox())
	head.add_child(close_btn)

	var lore_text := str(page.get("text", ""))
	var image_width := minf(560.0 if not lore_text.is_empty() else 720.0, modal_width - 40.0)
	var image_height := minf(image_width * 0.5625, maxf(100.0, size.y - (330.0 if not lore_text.is_empty() else 250.0)))
	var img_size := Vector2(image_width, image_height)
	var large_tex := _large_photo(str(page.shot.get("path", "")))
	if large_tex != null:
		var view := TextureRect.new()
		view.texture = large_tex
		view.custom_minimum_size = img_size
		view.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		vbox.add_child(view)
	else:
		var missing := PanelContainer.new()
		missing.custom_minimum_size = img_size
		missing.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		missing.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS.lerp(HudStyle.AMBER, 0.14), HudStyle.BORDER, 8, Vector2(16, 16), false))
		var mlbl := _label("Файл снимка был удалён с диска", 16, missing, HudStyle.AMBER)
		mlbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mlbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		vbox.add_child(missing)

	var meta_row := HBoxContainer.new()
	meta_row.add_theme_constant_override("separation", 12)
	vbox.add_child(meta_row)
	var meta_parts := PackedStringArray()
	var place_name := str(page.get("place_name", ""))
	if not place_name.is_empty():
		meta_parts.append("Место: «%s»" % place_name)
	var date_full := str(page.shot.get("date", ""))
	if not date_full.is_empty():
		meta_parts.append("Снято: %s" % date_full)
	var meta_lbl := _label(" · ".join(meta_parts), 13, meta_row, HudStyle.MINT)
	meta_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	if not lore_text.is_empty():
		var lore_box := PanelContainer.new()
		lore_box.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 8, Vector2(16, 12), false))
		vbox.add_child(lore_box)
		var lore_lbl := _label(lore_text, 16, lore_box, HudStyle.CREAM)
		lore_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lore_lbl.custom_minimum_size.x = maxf(200.0, modal_width - 72.0)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	vbox.add_child(footer)
	var prev_btn := Button.new()
	prev_btn.text = "‹ Предыдущий"
	prev_btn.custom_minimum_size = Vector2(148, 44)
	prev_btn.disabled = opened_all.size() <= 1
	prev_btn.pressed.connect(func() -> void:
		if opened_all.size() > 1:
			var next_i := posmod(idx - 1, opened_all.size())
			_open_lightbox(opened_all[next_i], opened_all, _lightbox_return_focus, "prev"))
	footer.add_child(prev_btn)
	var counter := _label("%d из %d" % [idx + 1, maxi(1, opened_all.size())], 14, footer, MUTED)
	counter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var next_btn := Button.new()
	next_btn.text = "Следующий ›"
	next_btn.custom_minimum_size = Vector2(148, 44)
	next_btn.disabled = opened_all.size() <= 1
	next_btn.pressed.connect(func() -> void:
		if opened_all.size() > 1:
			var next_i := posmod(idx + 1, opened_all.size())
			_open_lightbox(opened_all[next_i], opened_all, _lightbox_return_focus, "next"))
	footer.add_child(next_btn)

	# Фокус остаётся внутри лайтбокса при навигации клавиатурой/геймпадом
	close_btn.focus_neighbor_bottom = prev_btn.get_path()
	prev_btn.focus_neighbor_top = close_btn.get_path()
	next_btn.focus_neighbor_top = close_btn.get_path()
	prev_btn.focus_neighbor_right = next_btn.get_path()
	next_btn.focus_neighbor_left = prev_btn.get_path()
	if flip and DisplayServer.get_name() != "headless":
		# листание: новая карточка мягко проявляется на месте прежней
		modal.modulate.a = 0.35
		modal.create_tween().tween_property(modal, "modulate:a", 1.0, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	match focus_target:
		"prev": prev_btn.grab_focus()
		"next": next_btn.grab_focus()
		_: close_btn.grab_focus()


## Снимок целиком в игровом размере тяжёл: в карточке — уменьшенная копия, одна на путь
func _thumbnail(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _cache.has(path):
		return _cache[path]
	var texture: ImageTexture = null
	if FileAccess.file_exists(path):
		var image := Image.load_from_file(path)
		if image != null and not image.is_empty():
			var width := 320
			image.resize(width, maxi(1, roundi(float(width) * image.get_height() / image.get_width())), Image.INTERPOLATE_BILINEAR)
			texture = ImageTexture.create_from_image(image)
	_cache[path] = texture
	return texture


func _large_photo(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _large_cache.has(path):
		return _large_cache[path]
	var texture: ImageTexture = null
	if FileAccess.file_exists(path):
		var image := Image.load_from_file(path)
		if image != null and not image.is_empty():
			if image.get_width() > 800:
				var w := 800
				image.resize(w, maxi(1, roundi(float(w) * image.get_height() / image.get_width())), Image.INTERPOLATE_BILINEAR)
			texture = ImageTexture.create_from_image(image)
	_large_cache[path] = texture
	return texture
