extends PanelContainer
## Полевой планшет. Карта и путь делят один вид атласа, альбом открывает уже сохранённые снимки.

signal closed
signal goal_requested(place: Dictionary)
signal cover_requested(key: String, path: String)
signal controls_created(root: Node)
signal feed_opening

const HudStyle = preload("res://scripts/ui/hud_style.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const ShopPanel := preload("res://scripts/ui/shop_panel.gd")
const MUTED := HudStyle.MUTED
const CARD := Vector2(248, 206)
const THUMB := Vector2(230, 126)
const INK := Color(0.045, 0.065, 0.10, 0.80)
const SURFACE := Color(0.09, 0.14, 0.19, 0.88)
const LINE := Color(0.55, 0.64, 0.69, 0.34)
const ACCENT := Color("#d2bd88")
const THUMB_CACHE_LIMIT := 384
const LARGE_CACHE_LIMIT := 4
const CARDS_PER_FRAME := 2
const Atlas := preload("res://scripts/ui/world_map_view.gd")
enum Tab { MAP, PATH, ALBUM, SHOP }
var active_tab := Tab.MAP
var map_view: Atlas
var data_provider := Callable()
var quest_provider := Callable()
var goal_provider := Callable()
var _data := {}
var _load_photos := {}
var _photo_waiters := {}
var _photo_thread: Thread
var _photo_job := ""
var _photo_generation := 0
var _photo_job_generation := 0
var _card_jobs: Array = []
var _personal_grid: GridContainer
var _focus_card_index := -1
var _cards_loading: Label
var _map_page: VBoxContainer
var _map_row: BoxContainer
var _dock: PanelContainer
var _map_frame: PanelContainer
var _right_dock: PanelContainer
var _narrow_docks: HBoxContainer
var _map_footer: HFlowContainer
var _map_key: VBoxContainer
var _map_info_toggle: Button
var _details: BoxContainer
var _dock_divider: HSeparator
var _place_title: Label
var _place_detail: Label
var _place_goal: Button
var _place_photo: Button
var _inspected_place := {}
var _checklist: VBoxContainer
var _quest_style: StyleBoxFlat
var _shown_quest := {}
var _map_hint: Label
var _track_layer: Button
var _photo_layer: Button
var _tab_map: Button
var _map_shortcut := ""
var _path_shortcut := ""
var _seed: Label
var _goal_badge: Label # 20.11: цель покупки в шапке дневника на всех вкладках: «Цель: Ледник · 35 / 50»
var _shop_profile: ShopPanel.Progress
var _feed_view
const SHORT_GROUPS := ["Биомы", "Места", "Вершины и озёра", "Ночь", "Обелиски"]

var _box: VBoxContainer
var _path_center: HBoxContainer
var _path_page: VBoxContainer
var _album_page: VBoxContainer
var _album_scroll: ScrollContainer
var _album_content: VBoxContainer
var _album_filter := -1
var _album_personal := false
var _personal_visible := 24
var _album_modes: Array[Button] = []
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
var _tab_tween: Tween
var _animated_page: Control


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = preload("res://resources/ui_theme.tres")
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
	get_viewport().size_changed.connect(_reflow)
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
	_finish_tab_transition()
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
	_album_personal = false
	_personal_visible = 24
	_album_modes.clear()
	_album_data = {}
	_data = {}
	_inspected_place = {}
	for child: Node in _path_page.get_children():
		_path_page.remove_child(child)
		child.queue_free()
	_shown_quest = {}
	_feed_view = null
	map_view.show_ride([], Rect2())
	_lightbox_return_focus = null
	_cache.clear()
	_large_cache.clear()
	_load_photos.clear()
	_photo_waiters.clear()
	_card_jobs.clear()
	_personal_grid = null
	_focus_card_index = -1
	_cards_loading = null
	_photo_generation += 1
	map_view.set_photo_pins(false, {})
	_fill_checklist({})
	set_process(_photo_thread != null)


func _exit_tree() -> void:
	if _photo_thread != null:
		_photo_thread.wait_to_finish()
		_photo_thread = null


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
	_map_shortcut = map_key
	_path_shortcut = path_key
	_update_tab_labels(get_viewport_rect().size.x < 650.0)
	_map_hint.text = hint


func _update_tab_labels(compact: bool) -> void:
	_tab_map.text = "Карта" if compact or _map_shortcut.is_empty() else "Карта [%s]" % _map_shortcut
	_tab_path.text = "Поездки" if compact or _path_shortcut.is_empty() else "Поездки [%s]" % _path_shortcut
	_tab_map.tooltip_text = "Карта [%s]" % _map_shortcut if not _map_shortcut.is_empty() else "Карта"
	_tab_path.tooltip_text = "Поездки [%s]" % _path_shortcut if not _path_shortcut.is_empty() else "Поездки"


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
	_goal_badge = _label("", 13, head, HudStyle.AMBER)
	_goal_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_goal_badge.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_goal_badge.hide()
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
	_tab_path = _tab("Поездки", group, tabs, Tab.PATH)
	_tab_album = _tab("Альбом", group, tabs, Tab.ALBUM)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(spacer)
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
	var hover := HudStyle.panel(Color(0.20, 0.26, 0.31, 0.8), Color.TRANSPARENT, 8, Vector2(18, 8), false)
	var selected := HudStyle.panel(Color(0.23, 0.28, 0.32, 0.9), ACCENT, 8, Vector2(18, 8), false)
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
	_map_frame = PanelContainer.new()
	_map_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_frame.add_theme_stylebox_override("panel", HudStyle.panel(SURFACE, LINE, 12, Vector2(8, 8), false))
	_map_row.add_child(_map_frame)
	_map_frame.add_child(map_view)
	map_view.place_selected.connect(refresh_inspector)
	map_view.places_changed.connect(_rebuild_map_key)
	map_view.photo_thumbnail_requested.connect(_queue_photo)

	_dock = PanelContainer.new()
	_dock.add_theme_stylebox_override("panel", HudStyle.panel(SURFACE, LINE, 12, Vector2(18, 18), false))
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
	_place_goal = Button.new()
	_place_goal.custom_minimum_size.y = 40
	_place_goal.pressed.connect(func() -> void:
		if not _inspected_place.is_empty():
			map_view.selected_place = _inspected_place
			goal_requested.emit(_inspected_place))
	inspector.add_child(_place_goal)
	_place_photo = Button.new()
	_place_photo.text = "Открыть снимок"
	_place_photo.custom_minimum_size.y = 40
	_place_photo.pressed.connect(_open_place_photo)
	inspector.add_child(_place_photo)
	_right_dock = PanelContainer.new()
	_right_dock.add_theme_stylebox_override("panel", HudStyle.panel(SURFACE, LINE, 12, Vector2(14, 14), false))
	_map_row.add_child(_right_dock)
	var right_scroll := ScrollContainer.new()
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_scroll.follow_focus = true
	_right_dock.add_child(right_scroll)
	var right_content := VBoxContainer.new()
	right_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_content.add_theme_constant_override("separation", 12)
	right_scroll.add_child(right_content)
	var quest_card := PanelContainer.new()
	_quest_style = HudStyle.panel(Color(0.15, 0.20, 0.24, 0.96), ACCENT, 10, Vector2(12, 12), false)
	_quest_style.border_width_left = 3
	quest_card.add_theme_stylebox_override("panel", _quest_style)
	right_content.add_child(quest_card)
	var objective := VBoxContainer.new()
	objective.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quest_card.add_child(objective)
	_label("ТЕКУЩЕЕ ЗАДАНИЕ", 12, objective, ACCENT)
	_checklist = VBoxContainer.new()
	_checklist.add_theme_constant_override("separation", 4)
	objective.add_child(_checklist)
	right_content.add_child(HSeparator.new())
	_label("ОБОЗНАЧЕНИЯ", 12, right_content, ACCENT)
	_map_key = VBoxContainer.new()
	_map_key.add_theme_constant_override("separation", 5)
	right_content.add_child(_map_key)
	_rebuild_map_key()
	_narrow_docks = HBoxContainer.new()
	_narrow_docks.add_theme_constant_override("separation", 8)
	_narrow_docks.hide()
	_map_row.add_child(_narrow_docks)
	_path_page = VBoxContainer.new()
	_path_page.add_theme_constant_override("separation", 4)
	_path_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_path_center = HBoxContainer.new()
	_path_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_child(_path_center)
	var left_space := Control.new()
	left_space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_center.add_child(left_space)
	_path_center.add_child(_path_page)
	var right_space := Control.new()
	right_space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_center.add_child(right_space)

	var footer := HFlowContainer.new()
	_map_footer = footer
	footer.add_theme_constant_override("h_separation", 8)
	footer.add_theme_constant_override("v_separation", 6)
	_map_page.add_child(footer)
	_map_hint = _label("", 13, footer, MUTED)
	_map_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_map_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_map_info_toggle = Button.new()
	_map_info_toggle.text = "Легенда и задание"
	_map_info_toggle.tooltip_text = "Показать обозначения карты и текущее задание"
	_map_info_toggle.toggle_mode = true
	_map_info_toggle.custom_minimum_size.y = 40
	_map_info_toggle.toggled.connect(func(on: bool) -> void:
		_right_dock.visible = on and active_tab == Tab.MAP
		_update_narrow_docks())
	footer.add_child(_map_info_toggle)
	var zoom_out := Button.new()
	zoom_out.text = "−"
	zoom_out.tooltip_text = "Отдалить карту"
	zoom_out.custom_minimum_size = Vector2(40, 40)
	zoom_out.pressed.connect(func() -> void: map_view._zoom_at(map_view.size * 0.5, 0.8))
	footer.add_child(zoom_out)
	var zoom_in := Button.new()
	zoom_in.text = "+"
	zoom_in.tooltip_text = "Приблизить карту"
	zoom_in.custom_minimum_size = Vector2(40, 40)
	zoom_in.pressed.connect(func() -> void: map_view._zoom_at(map_view.size * 0.5, 1.25))
	footer.add_child(zoom_in)
	_track_layer = Button.new()
	_track_layer.text = "Путь"
	_track_layer.tooltip_text = "Показать пройденный путь"
	_track_layer.toggle_mode = true
	_track_layer.button_pressed = true
	_track_layer.toggled.connect(func(on: bool) -> void: map_view.set_travel_track(on))
	footer.add_child(_track_layer)
	_photo_layer = Button.new()
	_photo_layer.text = "Снимки"
	_photo_layer.tooltip_text = "Показать снимки на карте"
	_photo_layer.toggle_mode = true
	_photo_layer.button_pressed = true
	_photo_layer.toggled.connect(func(on: bool) -> void: map_view.set_photo_pins(on, _cache))
	footer.add_child(_photo_layer)
	var center := Button.new()
	center.text = "К себе"
	center.icon = UiIcons.map_icon("goal")
	center.custom_minimum_size.y = 40
	center.pressed.connect(func() -> void:
		map_view.center_on_player())
	footer.add_child(center)


## Легенда перестраивается только при изменении известных мест, не при панорамировании.
func _rebuild_map_key() -> void:
	if _map_key == null:
		return
	for child: Node in _map_key.get_children():
		_map_key.remove_child(child)
		child.queue_free()
	for item in [["━", "Мой путь", Color("#a596ff")], ["━", "Дорога", Color("#d6bc8a")],
			["━", "Тропа", Color("#b59d72")], ["━", "Велотрасса", Color("#90bd8d")],
			["▲", "Игрок", Color("#75b7ff")], ["★", "Цель", HudStyle.AMBER],
			["●", "Велосипед", Color("#75b7ff")], ["◎", "Шаг задания", HudStyle.AMBER],
			["○", "Узнано", HudStyle.CREAM], ["✓", "Посещено", HudStyle.MINT],
			["▣", "Есть снимок", Color("#c4a5e5")]]:
		var line := HBoxContainer.new()
		_map_key.add_child(line)
		var mark := _label(item[0], 15, line, item[2])
		mark.custom_minimum_size.x = 24
		_label(item[1], 13, line, HudStyle.CREAM)
	var names := {settlement = "Поселение", peak = "Вершина", lake = "Озеро", site = "Место",
		tower = "Вышка", obelisk = "Обелиск", ruin = "Руины", stones = "Каменный круг",
		shelter = "Приют", house = "Дом", farm = "Хутор", fishing = "Рыбацкий дом", bench = "Лавка"}
	var seen := {}
	for place: Dictionary in map_view.places:
		var icon := UiIcons.map_place_icon(place)
		if not names.has(icon): icon = "site"
		if seen.has(icon): continue
		seen[icon] = true
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		_map_key.add_child(line)
		var badge := PanelContainer.new()
		badge.custom_minimum_size = Vector2(22, 22)
		badge.add_theme_stylebox_override("panel", HudStyle.panel(Atlas.pin_color(str(place.get("kind", "site")), icon), Color("#f2e7cd"), 12, Vector2(3, 3), false))
		line.add_child(badge)
		badge.add_child(UiIcons.rect(UiIcons.map_icon(icon), 14))
		_label(names[icon], 13, line, HudStyle.CREAM)


func _reflow() -> void:
	var available_width := get_viewport_rect().size.x
	var narrow := available_width < 800.0
	var compact_tabs := available_width < 650.0
	_update_tab_labels(compact_tabs)
	_map_info_toggle.text = "Обозначения" if compact_tabs else "Легенда и задание"
	for button: Button in [_tab_map, _tab_path, _tab_album, _tab_shop]:
		button.custom_minimum_size.x = 68 if compact_tabs else 110
		button.add_theme_font_size_override("font_size", 13 if compact_tabs else 16)
		for state: String in ["normal", "hover", "pressed", "hover_pressed"]:
			var style := button.get_theme_stylebox(state) as StyleBoxFlat
			if style != null:
				style.content_margin_left = 8 if compact_tabs else 18
				style.content_margin_right = 8 if compact_tabs else 18
	_path_page.custom_minimum_size.x = minf(720.0, maxf(0.0, available_width - 64.0))
	_map_row.vertical = narrow
	_details.vertical = true
	_seed.visible = not narrow
	if narrow and _dock.get_parent() != _narrow_docks:
		_dock.reparent(_narrow_docks)
		_right_dock.reparent(_narrow_docks)
	elif not narrow and _dock.get_parent() != _map_row:
		_dock.reparent(_map_row)
		_right_dock.reparent(_map_row)
	_narrow_docks.visible = narrow and (_dock.visible or _right_dock.visible)
	_dock.custom_minimum_size = Vector2(0, 112) if narrow else Vector2(190, 0)
	_right_dock.custom_minimum_size = Vector2(0, 112) if narrow else Vector2(190, 0)
	_dock.size_flags_horizontal = Control.SIZE_EXPAND_FILL if narrow else Control.SIZE_FILL
	_right_dock.size_flags_horizontal = Control.SIZE_EXPAND_FILL if narrow else Control.SIZE_FILL
	if narrow:
		_map_row.move_child(_map_frame, 0)
		_map_row.move_child(_narrow_docks, 1)
	else:
		_map_row.move_child(_dock, 0)
		_map_row.move_child(_map_frame, 1)
	_dock.size_flags_vertical = Control.SIZE_FILL if narrow else Control.SIZE_EXPAND_FILL
	_right_dock.size_flags_vertical = Control.SIZE_FILL if narrow else Control.SIZE_EXPAND_FILL


func enable_shop(profile: ShopPanel.Progress) -> void:
	shop_panel.set_profile(profile)
	_tab_shop.show()
	if _shop_profile != profile:
		if _shop_profile != null:
			_shop_profile.changed.disconnect(_refresh_goal_badge)
		_shop_profile = profile
		profile.changed.connect(_refresh_goal_badge)
	_refresh_goal_badge()


func _refresh_goal_badge() -> void:
	var id := _shop_profile.purchase_goal if _shop_profile != null and _shop_profile.load_error == OK else ""
	_goal_badge.visible = id != ""
	if id == "":
		return
	var price: int = ShopPanel.Progress.PRICES[id]
	var have := mini(_shop_profile.balance, price)
	_goal_badge.text = "Цель: %s · %d / %d" % [ShopPanel.Progress.item_name(id), have, price]
	_goal_badge.add_theme_color_override("font_color", HudStyle.MINT if have >= price else HudStyle.AMBER)
	_goal_badge.tooltip_text = "Можно купить в магазине" if have >= price else "Не хватает %d очк." % (price - have)


func _select(tab: Tab) -> void:
	if tab == Tab.SHOP and shop_panel.visible:
		return
	var changed := tab != active_tab
	_finish_tab_transition()
	close_lightbox()
	var focus := get_viewport().gui_get_focus_owner()
	var move_focus := focus != null and (
		(_album_page.is_ancestor_of(focus) and tab != Tab.ALBUM)
		or (_path_page.is_ancestor_of(focus) and tab != Tab.PATH)
		or (_details.is_ancestor_of(focus) and tab != Tab.MAP)
		or (shop_panel.is_ancestor_of(focus) and tab != Tab.SHOP))
	active_tab = tab
	_tab_map.set_pressed_no_signal(tab == Tab.MAP)
	_tab_path.set_pressed_no_signal(tab == Tab.PATH)
	_tab_album.set_pressed_no_signal(tab == Tab.ALBUM)
	_tab_shop.set_pressed_no_signal(tab == Tab.SHOP)
	_map_page.visible = tab == Tab.MAP
	map_view.visible = _map_page.visible
	_path_center.visible = tab == Tab.PATH
	_details.visible = tab == Tab.MAP
	_right_dock.visible = tab == Tab.MAP and _map_info_toggle.button_pressed
	_album_page.visible = tab == Tab.ALBUM
	shop_panel.visible = tab == Tab.SHOP
	if tab in [Tab.PATH, Tab.ALBUM] and _data.is_empty() and data_provider.is_valid():
		_data = data_provider.call()
	if tab == Tab.PATH and _path_page.get_child_count() == 0:
		feed_opening.emit()
		_fill_path(_data)
	if tab == Tab.ALBUM and _album_scroll == null:
		_fill_album(_data)
	if tab == Tab.ALBUM and not _card_jobs.is_empty():
		set_process(true)
	map_view.set_photo_pins(_photo_layer.button_pressed, _cache)
	if tab != Tab.PATH:
		map_view.show_ride([], Rect2())
	map_view.set_field_sheet(tab == Tab.MAP)
	if tab == Tab.SHOP:
		shop_panel.open()
	if changed:
		_animate_tab([_map_page, _path_center, _album_page, shop_panel][tab])
	refresh_inspector(map_view.selected_place)
	refresh_quest()
	if move_focus:
		var tab_button: Button = [_tab_map, _tab_path, _tab_album, _tab_shop][tab]
		tab_button.grab_focus()


func _finish_tab_transition() -> void:
	if _tab_tween != null and _tab_tween.is_valid():
		_tab_tween.kill()
	if is_instance_valid(_animated_page):
		_animated_page.modulate.a = 1.0
		_animated_page.scale = Vector2.ONE
	_animated_page = null


func _animate_tab(page: Control) -> void:
	if DisplayServer.get_name() == "headless" or GameContext.scope.settings.reduce_ui_motion:
		return
	_animated_page = page
	page.pivot_offset = page.size * 0.5
	page.modulate.a = 0.60
	page.scale = Vector2.ONE * 0.985
	_tab_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tab_tween.tween_property(page, "modulate:a", 1.0, 0.20)
	_tab_tween.tween_property(page, "scale", Vector2.ONE, 0.20)


func refresh_inspector(place: Dictionary) -> void:
	if not _map_page.is_visible_in_tree():
		return
	if place.is_empty():
		place = _inspected_place if not _inspected_place.is_empty() else map_view.selected_place
	_inspected_place = place
	_dock.visible = active_tab == Tab.MAP and not place.is_empty()
	_update_narrow_docks()
	var title := str(place.get("name", ""))
	var detail := "Наведитесь на метку или выберите её." if place.is_empty() else ""
	if not place.is_empty():
		var status := PackedStringArray()
		var icon := UiIcons.map_place_icon(place)
		var kind: String = {peak = "Вершина", lake = "Озеро", site = "Место", settlement = "Поселение",
			farm = "Хутор", house = "Дом", ruin = "Руины", tower = "Вышка", stones = "Каменный круг",
			shelter = "Приют", obelisk = "Обелиск", fishing = "Рыбацкий дом", bench = "Лавка"}.get(icon, "Место")
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
	_place_goal.visible = not place.is_empty()
	var goal: Dictionary = goal_provider.call() if goal_provider.is_valid() else {}
	_place_goal.text = "Снять цель" if not place.is_empty() and place.get("key") == goal.get("key") else "Сделать целью"
	_place_photo.visible = not str(place.get("map_photo", "")).is_empty()


func _update_narrow_docks() -> void:
	if is_instance_valid(_narrow_docks):
		_narrow_docks.visible = get_viewport_rect().size.x < 800.0 and (_dock.visible or _right_dock.visible)


## Обновить карточку после изменения набора известных мест.
func refresh_inspected_place() -> void:
	var id := str(_inspected_place.get("key", ""))
	_inspected_place = {}
	for place: Dictionary in map_view.places:
		if str(place.get("key", "")) == id:
			_inspected_place = place
			break
	refresh_inspector(map_view.selected_place)


func _open_place_photo() -> void:
	if _inspected_place.is_empty():
		return
	var page := {key = "place:" + str(_inspected_place.get("key", "")), group = 1,
		title = str(_inspected_place.get("name", "Место")), place_name = str(_inspected_place.get("name", "")),
		shot = {path = str(_inspected_place.get("map_photo", "")), place = str(_inspected_place.get("key", "")), date = ""}}
	var pages: Array[Dictionary] = [page]
	_open_lightbox(page, pages, _place_photo)


func refresh_quest() -> void:
	if not _map_page.is_visible_in_tree() or not quest_provider.is_valid():
		return
	var data: Dictionary = quest_provider.call()
	if data != _shown_quest or _checklist.get_child_count() == 0:
		if data != _shown_quest and not data.is_empty():
			_map_info_toggle.button_pressed = true
		_shown_quest = data
		_fill_checklist(data)


func _fill_checklist(data: Dictionary) -> void:
	for child: Node in _checklist.get_children():
		_checklist.remove_child(child)
		child.queue_free()
	_quest_style.border_color = data.get("color", ACCENT)
	if data.is_empty():
		_label("Активного задания нет", 14, _checklist, MUTED)
		return
	var title := _label(data.title, 16, _checklist, HudStyle.CREAM)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if int(data.get("reward", 0)) > 0:
		_label("Награда · %d очк." % int(data.reward), 12, _checklist, data.get("color", ACCENT))
	for i in data.steps.size():
		var marker := "✓" if i < data.index else ("▸" if i == data.index else "○")
		var color := HudStyle.MINT if i <= data.index else MUTED
		var line := _label("%s  %s" % [marker, data.steps[i]], 14, _checklist, color)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


## Общая лента и прежний итог для открытого мира.
func _fill_path(data: Dictionary) -> void:
	_feed_view = preload("res://scripts/ui/ride_feed_view.gd").new()
	_feed_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_path_page.add_child(_feed_view)
	_feed_view.ride_selected.connect(_select_feed_ride)
	_feed_view.controls_created.connect(func(root: Node) -> void: controls_created.emit(root))
	_feed_view.setup(GameContext.scope.settings, str(data.get("seed", "")), str(data.get("template_id", "")), true)
	var summary_button := Button.new()
	summary_button.text = "Итоги путешествия"
	summary_button.toggle_mode = true
	_path_page.add_child(summary_button)
	var summary_scroll := ScrollContainer.new()
	summary_scroll.custom_minimum_size.y = 120
	summary_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	summary_scroll.hide()
	_path_page.add_child(summary_scroll)
	var summary := VBoxContainer.new()
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary_scroll.add_child(summary)
	summary_button.toggled.connect(func(on: bool) -> void: summary_scroll.visible = on)
	_label("ИТОГО ЗА ПУТЕШЕСТВИЕ", 12, summary, ACCENT)
	_label("Велосипед · %s   Пешком · %s" % [Util.distance_text(data.get("bike", 0.0)), Util.distance_text(data.get("foot", 0.0))],
		13, summary, HudStyle.CREAM).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label("В пути · %s   Высшая точка · %d м" % [_duration(data.get("time", 0.0)), roundi(data.get("alt", 0.0))], 13, summary, MUTED)
	_label("Снимков · %d   Заданий · %d" % [data.get("photos", 0), data.get("quests", 0)], 13, summary, MUTED)
	for entry: Array in data.get("places", []):
		_label("%s · %d / %d" % entry, 13, summary, MUTED)
	var series: Dictionary = data.get("series", {})
	if int(series.get("total", 0)) > 0 or series.get("finished", false):
		var line := "Летопись обелисков · завершена" if series.finished else "Летопись обелисков · %d / %d" % [series.done, series.total]
		_label(line, 13, summary, HudStyle.MINT).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for line: Variant in data.get("thanks", []):
		_label(str(line), 13, summary, HudStyle.AMBER).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if data.get("thanks", []).is_empty():
		for name: Variant in data.get("helped", []):
			_label(str(name), 13, summary, MUTED).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls_created.emit(_path_page)


func _select_feed_ride(entry: Dictionary, frame := true) -> void:
	if not entry.is_empty():
		_select(Tab.MAP)
	var legs: Array = []
	for source: Array in entry.get("track", []):
		var points := PackedVector2Array()
		for coordinates: Array in source:
			if coordinates.size() == 2:
				points.append(Vector2(float(coordinates[0]), float(coordinates[1])))
		if points.size() > 1:
			legs.append(points)
	var bounds := preload("res://scripts/game/ride_log.gd").bounds({legs = legs})
	map_view.show_ride(legs, bounds, frame, entry.get("fall_marks", []))

func _show_place_on_map(id: String) -> void:
	_select(Tab.MAP)
	if map_view.focus_place(id):
		refresh_inspector(map_view.selected_place)


static func _duration(seconds: float) -> String:
	var s := int(seconds)
	return "%d:%02d:%02d" % [s / 3600, s / 60 % 60, s % 60]


func _queue_photo(path: String) -> void:
	_queue_image(path, false)


## Decode and resize off the render thread. Only ImageTexture creation touches the UI thread.
static func _decode_photo(path: String, width: int) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	if image.get_width() > width:
		image.resize(width, maxi(1, roundi(float(width) * image.get_height() / image.get_width())), Image.INTERPOLATE_BILINEAR)
	return image


func _queue_image(path: String, large: bool) -> void:
	if path.is_empty():
		return
	var cache: Dictionary = _large_cache if large else _cache
	if cache.has(path):
		return
	var key := ("L:" if large else "S:") + path
	if key != _photo_job or _photo_job_generation != _photo_generation:
		_load_photos[key] = true
	set_process(true)


func _request_image(path: String, large: bool, view: TextureRect, status: Label) -> void:
	var cache: Dictionary = _large_cache if large else _cache
	if cache.has(path):
		view.texture = cache[path]
		status.visible = view.texture == null
		status.text = "Файл снимка недоступен"
		return
	var key := ("L:" if large else "S:") + path
	if path.is_empty():
		status.text = "Файл снимка недоступен"
		return
	if not _photo_waiters.has(key):
		_photo_waiters[key] = []
	_photo_waiters[key].append([weakref(view), weakref(status)])
	_queue_image(path, large)


func _process(_dt: float) -> void:
	var card_count := mini(CARDS_PER_FRAME, _card_jobs.size()) if active_tab == Tab.ALBUM and is_visible_in_tree() else 0
	for i in card_count:
		var job: Array = _card_jobs.pop_front()
		var grid := (job[0] as WeakRef).get_ref() as GridContainer
		if not is_instance_valid(grid) or grid.is_queued_for_deletion():
			continue
		var opened: Array[Dictionary] = job[2]
		var card := _card(job[1], opened)
		grid.add_child(card)
		controls_created.emit(card)
		if grid == _personal_grid and grid.get_child_count() - 1 == _focus_card_index:
			if card is Button:
				card.grab_focus()
			_focus_card_index = -1
	if _card_jobs.is_empty() and is_instance_valid(_cards_loading):
		_cards_loading.hide()
	if _photo_thread != null and not _photo_thread.is_alive():
		var image: Image = _photo_thread.wait_to_finish()
		_photo_thread = null
		var key := _photo_job
		_photo_job = ""
		if _photo_job_generation == _photo_generation:
			_complete_photo(key, image)
	if _photo_thread == null and not _load_photos.is_empty():
		_photo_job = _load_photos.keys()[0]
		for pending: String in _load_photos:
			if pending.begins_with("L:"):
				_photo_job = pending
				break
		_load_photos.erase(_photo_job)
		_photo_job_generation = _photo_generation
		_photo_thread = Thread.new()
		var width := 800 if _photo_job.begins_with("L:") else 256
		if _photo_thread.start(_decode_photo.bind(_photo_job.substr(2), width)) != OK:
			_photo_thread = null
			_complete_photo(_photo_job, null)
			_photo_job = ""
	if _photo_thread == null and _load_photos.is_empty() and (_card_jobs.is_empty() or active_tab != Tab.ALBUM or not is_visible_in_tree()):
		set_process(false)


func _complete_photo(key: String, image: Image) -> void:
	var path := key.substr(2)
	var large := key.begins_with("L:")
	var cache: Dictionary = _large_cache if large else _cache
	var limit := LARGE_CACHE_LIMIT if large else THUMB_CACHE_LIMIT
	var texture: ImageTexture = ImageTexture.create_from_image(image) if image != null else null
	if cache.size() >= limit and not cache.has(path):
		cache.erase(cache.keys()[0])
	cache[path] = texture
	for waiter: Array in _photo_waiters.get(key, []):
		var view := (waiter[0] as WeakRef).get_ref() as TextureRect
		var status := (waiter[1] as WeakRef).get_ref() as Label
		if is_instance_valid(view) and is_instance_valid(status):
			view.texture = texture
			status.visible = texture == null
			status.text = "Файл снимка недоступен"
	_photo_waiters.erase(key)
	if not large:
		map_view.refresh_overlay()


func _fill_album(data: Dictionary) -> void:
	_album_data = data
	var pages: Array = data.get("pages", [])
	var groups: Array = data.get("groups", [])
	var nav_bar := HFlowContainer.new()
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 8)
	_album_page.add_child(modes)
	var mode_group := ButtonGroup.new()
	for mode in [false, true]:
		var button := Button.new()
		button.text = "Мои снимки" if mode else "Коллекция"
		button.toggle_mode = true
		button.button_group = mode_group
		button.button_pressed = mode == _album_personal
		button.custom_minimum_size.y = 40
		button.pressed.connect(func() -> void:
			_album_personal = mode
			for i in _album_modes.size():
				_album_modes[i].set_pressed_no_signal(i == (1 if mode else 0))
			_personal_visible = 24
			nav_bar.visible = not mode
			_rebuild_album_grid()
			if _album_scroll != null:
				_album_scroll.scroll_vertical = 0)
		modes.add_child(button)
		_album_modes.append(button)
	nav_bar.add_theme_constant_override("separation", 8)
	nav_bar.visible = not _album_personal
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
	controls_created.emit(_album_page)


func _pill(text: String, group_index: int, group: ButtonGroup, parent: Container) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.button_group = group
	btn.theme_type_variation = &"PillButton"
	btn.add_theme_stylebox_override("normal", HudStyle.panel(SURFACE, LINE, 8, Vector2(14, 8), false))
	btn.add_theme_stylebox_override("hover", HudStyle.panel(Color("#354651"), ACCENT, 8, Vector2(14, 8), false))
	btn.add_theme_stylebox_override("pressed", HudStyle.panel(Color("#42535e"), ACCENT, 8, Vector2(14, 8), false))
	btn.add_theme_stylebox_override("hover_pressed", HudStyle.panel(Color("#4c5e69"), ACCENT, 8, Vector2(14, 8), false))
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
	_card_jobs.clear()
	_personal_grid = null
	_focus_card_index = -1
	for child: Node in _album_content.get_children():
		_album_content.remove_child(child)
		child.queue_free()
	_cards_loading = _label("Подготавливаем страницы…", 13, _album_content, MUTED)
	if _album_personal:
		var personal_pages: Array[Dictionary] = []
		var personal: Array = _album_data.get("personal_photos", [])
		for i in range(personal.size() - 1, -1, -1):
			personal_pages.append(_personal_page(personal[i]))
		_label("МОИ СНИМКИ  /  %d" % personal_pages.size(), 20, _album_content, HudStyle.CREAM)
		_label("В дневнике хранятся последние 256 снимков.", 13, _album_content, MUTED)
		if personal_pages.is_empty():
			_label("Здесь появятся новые фотографии. Снимки из прежних сохранений остаются в коллекции.", 14, _album_content, MUTED).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		else:
			var personal_grid := GridContainer.new()
			_personal_grid = personal_grid
			personal_grid.columns = _album_columns()
			personal_grid.add_theme_constant_override("h_separation", 12)
			personal_grid.add_theme_constant_override("v_separation", 12)
			_album_content.add_child(personal_grid)
			for i in mini(_personal_visible, personal_pages.size()):
				_card_jobs.append([weakref(personal_grid), personal_pages[i], personal_pages])
			if personal_pages.size() > _personal_visible:
				var more := Button.new()
				more.text = "Показать ещё снимки"
				more.pressed.connect(_show_more_photos)
				_album_content.add_child(more)
		_cards_loading.visible = not _card_jobs.is_empty()
		if not _card_jobs.is_empty():
			set_process(true)
		controls_created.emit(_album_content)
		return
	var pages: Array = _album_data.get("pages", [])
	var groups: Array = _album_data.get("groups", [])
	if pages.is_empty():
		var empty := PanelContainer.new()
		empty.custom_minimum_size.y = 190
		empty.add_theme_stylebox_override("panel", HudStyle.panel(SURFACE, LINE, 12, Vector2(24, 24), false))
		_album_content.add_child(empty)
		var center := CenterContainer.new()
		empty.add_child(center)
		var message := VBoxContainer.new()
		message.add_theme_constant_override("separation", 8)
		center.add_child(message)
		var eyebrow := _label("ВАШИ ВОСПОМИНАНИЯ", 12, message, ACCENT)
		eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var heading := _label("Здесь появится ваш альбом", 21, message, HudStyle.CREAM)
		heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var description := _label("Снимайте интересные места во время путешествия.", 14, message, MUTED)
		description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_cards_loading.hide()
		controls_created.emit(_album_content)
		return
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
			_card_jobs.append([weakref(grid), page, opened_all])
	_cards_loading.visible = not _card_jobs.is_empty()
	if not _card_jobs.is_empty():
		set_process(true)
	controls_created.emit(_album_content)


func _show_more_photos() -> void:
	var previous := _personal_visible
	_personal_visible += 24
	_rebuild_album_grid()
	_focus_card_index = previous


func _personal_page(photo: Dictionary) -> Dictionary:
	var name := str(photo.get("place_name", ""))
	return {key = "photo:" + str(photo.get("path", "")), group = 1,
		title = name if not name.is_empty() else "Снимок путешествия", hint = "",
		place_name = name, shot = photo, photo_keys = photo.get("keys", [])}


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
		btn.add_theme_stylebox_override("normal", HudStyle.panel(SURFACE, LINE, 10, Vector2(8, 8), false))
		btn.add_theme_stylebox_override("hover", HudStyle.panel(Color("#354651"), ACCENT, 10, Vector2(8, 8), false))
		btn.add_theme_stylebox_override("pressed", HudStyle.panel(Color("#42535e"), ACCENT, 10, Vector2(8, 8), false))
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
		panel.add_theme_stylebox_override("panel", HudStyle.panel(SURFACE, LINE, 10, Vector2(9, 9), false))
		panel.add_child(column)
		root_ctrl = panel

	var frame := Control.new()
	frame.custom_minimum_size = THUMB
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(frame)
	if done:
		var clip := Panel.new()
		clip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		clip.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
		clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var clip_style := HudStyle.panel(HudStyle.SURFACE, HudStyle.SURFACE, 0, Vector2.ZERO, false)
		clip_style.set_border_width_all(0)
		clip.add_theme_stylebox_override("panel", clip_style)
		frame.add_child(clip)
		var view := TextureRect.new()
		view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip.add_child(view)
		var loading := _label("Загрузка снимка…", 12, clip, MUTED)
		loading.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		loading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		loading.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_request_image(str(page.shot.get("path", "")), false, view, loading)
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
		elif str(page.key).begins_with("photo:"):
			sub_text = "Снимок из поездки" if float(page.shot.get("ride_start", 0.0)) > 0.0 else "Личный снимок"
			sub_color = HudStyle.MINT
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
	modal.add_theme_stylebox_override("panel", HudStyle.panel(SURFACE, LINE, 12, Vector2(20, 16)))
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
	var allowance := 330.0 if not lore_text.is_empty() else 250.0
	if not page.get("photo_keys", []).is_empty():
		allowance += 56.0
	var image_height := minf(image_width * 0.5625, maxf(100.0, size.y - allowance))
	var img_size := Vector2(image_width, image_height)
	var picture := Control.new()
	picture.custom_minimum_size = img_size
	picture.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(picture)
	var view := TextureRect.new()
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.add_child(view)
	var loading := _label("Загрузка снимка…", 16, picture, MUTED)
	loading.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_request_image(str(page.shot.get("path", "")), true, view, loading)

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
	var place_id := str(page.shot.get("place", ""))
	var show_place_button: Button
	if not place_id.is_empty() and map_view.places.any(func(p: Dictionary) -> bool: return str(p.get("key", "")) == place_id):
		var show_place := Button.new()
		show_place_button = show_place
		show_place.text = "На карте"
		show_place.pressed.connect(func() -> void:
			close_lightbox()
			_show_place_on_map(place_id))
		meta_row.add_child(show_place)
	var photo_keys: Array = page.get("photo_keys", [])
	var choices: Array[Dictionary] = []
	var choice_control: OptionButton
	var cover_button: Button
	for collection_page: Dictionary in _data.get("pages", []):
		if collection_page.key in photo_keys and not collection_page.shot.is_empty():
			choices.append(collection_page)
	if not choices.is_empty():
		var cover_row := HBoxContainer.new()
		vbox.add_child(cover_row)
		var choice := OptionButton.new()
		choice_control = choice
		choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for item: Dictionary in choices:
			choice.add_item(str(item.title))
		cover_row.add_child(choice)
		var cover := Button.new()
		cover_button = cover
		cover.text = "Выбрать для коллекции"
		cover.pressed.connect(func() -> void:
			cover_requested.emit(str(choices[choice.selected].key), str(page.shot.path))
			if data_provider.is_valid():
				_data = data_provider.call()
				_album_data = _data
			close_lightbox()
			_rebuild_album_grid()
			if _album_modes.size() > 1 and _album_modes[1].is_visible_in_tree():
				_album_modes[1].grab_focus())
		cover_row.add_child(cover)

	if not lore_text.is_empty():
		var lore_box := PanelContainer.new()
		lore_box.add_theme_stylebox_override("panel", HudStyle.panel(SURFACE, LINE, 8, Vector2(16, 12), false))
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
	var middle: Array[Control] = []
	if show_place_button != null:
		middle.append(show_place_button)
	if choice_control != null:
		middle.append(choice_control)
	if cover_button != null:
		middle.append(cover_button)
	if not middle.is_empty():
		close_btn.focus_neighbor_bottom = middle[0].get_path()
		for i in middle.size():
			middle[i].focus_neighbor_top = close_btn.get_path() if i == 0 else middle[i - 1].get_path()
			middle[i].focus_neighbor_bottom = prev_btn.get_path() if i == middle.size() - 1 else middle[i + 1].get_path()
		prev_btn.focus_neighbor_top = middle[-1].get_path()
		next_btn.focus_neighbor_top = middle[-1].get_path()
	controls_created.emit(modal)
	if flip and DisplayServer.get_name() != "headless":
		# листание: новая карточка мягко проявляется на месте прежней
		modal.modulate.a = 0.35
		modal.create_tween().tween_property(modal, "modulate:a", 1.0, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	match focus_target:
		"prev": prev_btn.grab_focus()
		"next": next_btn.grab_focus()
		_: close_btn.grab_focus()
