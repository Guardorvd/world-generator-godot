extends PanelContainer
## «Путешествие»: экспедиционный дневник с вкладкой «Путь» (сводка поездки, мини-схема маршрута, категории мест
## и текущие дела) и вкладкой «Альбом» (фильтр-лента, карточки фотоохоты и лайтбокс крупного просмотра).
## Оформление — HudStyle; данные собирает Hud.journey_data(), панель не хранит состояние мира.

signal closed

const HudStyle = preload("res://scripts/ui/hud_style.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const MUTED := HudStyle.MUTED
const CARD := Vector2(204, 168)
const THUMB := Vector2(190, 86)
const COLUMNS := 5
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
var _cache := {}        # путь снимка -> уменьшенная ImageTexture | null
var _large_cache := {}  # путь снимка -> крупная ImageTexture для лайтбокса | null
var _close: Button
var _lightbox: Control
var _lightbox_return_focus: Control


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_KEEP_SIZE)
	offset_left = 48
	offset_right = -48
	offset_top = 24
	offset_bottom = -24
	theme = HudStyle.theme()
	add_theme_stylebox_override("panel", HudStyle.sheet(Vector2.ZERO))
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 22 if edge in ["left", "right"] else 18)
	add_child(margin)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 12)
	margin.add_child(_box)
	hide()


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
	for child: Node in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	_path_page = null
	_album_page = null
	_album_scroll = null
	_album_content = null
	_album_filter = -1
	_album_data = {}
	_lightbox_return_focus = null
	_cache.clear()
	_large_cache.clear()
	hide()


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


## data: {seed, close_hint, foot, bike, time, alt, photos, quests, places, pages, groups,
## active_quest, series, thanks, helped, track}
func open(data: Dictionary, album_tab := false) -> void:
	clear()
	_build_header(data)
	_path_page = VBoxContainer.new()
	_path_page.add_theme_constant_override("separation", 10)
	_path_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_child(_path_page)
	_fill_path(data)
	_album_page = VBoxContainer.new()
	_album_page.add_theme_constant_override("separation", 10)
	_album_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_child(_album_page)
	_fill_album(data)
	show()
	_select(album_tab)
	_close.grab_focus()


func _build_header(data: Dictionary) -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head.custom_minimum_size.y = 48
	_box.add_child(head)
	var badge := PanelContainer.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 8, Vector2(8, 8), false))
	badge.add_child(UiIcons.rect(UiIcons.QUESTS.tour, 20, HudStyle.MINT))
	head.add_child(badge)
	var title_box := HBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_box.add_theme_constant_override("separation", 10)
	head.add_child(title_box)
	var title := _label("ПУТЕШЕСТВИЕ", 24, title_box, HudStyle.CREAM)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var seed_text := str(data.get("seed", ""))
	if not seed_text.is_empty():
		var seed_label := _label("· Мир «%s»" % seed_text, 16, title_box, MUTED)
		seed_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		seed_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		seed_label.clip_text = true
		seed_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var pages: Array = data.get("pages", [])
	var done_pages := pages.filter(func(p: Dictionary) -> bool: return not p.shot.is_empty()).size()
	var seg_box := PanelContainer.new()
	seg_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	seg_box.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 10, Vector2(4, 4), false))
	head.add_child(seg_box)
	var seg_row := HBoxContainer.new()
	seg_row.add_theme_constant_override("separation", 4)
	seg_box.add_child(seg_row)
	var group := ButtonGroup.new()
	_tab_path = _tab("Путь", UiIcons.QUESTS.tour, 114, group, seg_row)
	var album_caption := "Альбом  %d/%d" % [done_pages, pages.size()] if not pages.is_empty() else "Альбом"
	_tab_album = _tab(album_caption, UiIcons.QUESTS.photo, 152, group, seg_row)
	_tab_path.pressed.connect(func() -> void: _select(false))
	_tab_album.pressed.connect(func() -> void: _select(true))
	var close_hint := str(data.get("close_hint", "J / Esc"))
	if not close_hint.is_empty():
		head.add_child(HudStyle.chip(close_hint))
	_close = Button.new()
	_close.text = "✕ Закрыть"
	_close.custom_minimum_size = Vector2(124, 44)
	_close.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_close.pressed.connect(func() -> void: closed.emit())
	head.add_child(_close)


func _tab(text: String, icon_tex: Texture2D, min_w: float, group: ButtonGroup, parent: Container) -> Button:
	var button := Button.new()
	button.text = text
	button.icon = icon_tex
	button.toggle_mode = true
	button.button_group = group
	button.theme_type_variation = &"SegmentButton"
	button.custom_minimum_size = Vector2(min_w, 44)
	parent.add_child(button)
	return button


func _select(album: bool) -> void:
	_tab_path.set_pressed_no_signal(not album)
	_tab_album.set_pressed_no_signal(album)
	_path_page.visible = not album
	_album_page.visible = album


## Вкладка «Путь»: 2-колоночный экспедиционный дашборд
func _fill_path(data: Dictionary) -> void:
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 16)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_path_page.add_child(cols)

	# --- Левая колонка: Сводка экспедиции и мини-схема маршрута ---
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 10)
	cols.add_child(left)
	_label("СВОДКА ЭКСПЕДИЦИИ", 13, left, HudStyle.MINT)

	var bike_m := float(data.get("bike", 0.0))
	var foot_m := float(data.get("foot", 0.0))
	var total_m := bike_m + foot_m
	var bike_share := bike_m / total_m if total_m > 0.0 else 0.0
	var foot_share := foot_m / total_m if total_m > 0.0 else 0.0

	var travel_row := HBoxContainer.new()
	travel_row.add_theme_constant_override("separation", 10)
	left.add_child(travel_row)
	_travel_card(travel_row, UiIcons.bike(), Util.distance_text(bike_m), "На велосипеде", bike_share, HudStyle.MINT)
	_travel_card(travel_row, UiIcons.foot(), Util.distance_text(foot_m), "Пешком", foot_share, HudStyle.AMBER)

	var seconds := int(data.get("time", 0.0))
	var time_str := "%d:%02d:%02d" % [seconds / 3600, seconds / 60 % 60, seconds % 60]
	var kpi_row := HBoxContainer.new()
	kpi_row.add_theme_constant_override("separation", 8)
	left.add_child(kpi_row)
	_kpi_tile(kpi_row, UiIcons.clock(), time_str, "В пути")
	_kpi_tile(kpi_row, UiIcons.PEAK, "%d м" % roundi(data.get("alt", 0.0)), "Высшая точка")
	_kpi_tile(kpi_row, UiIcons.CHECK, str(data.get("quests", 0)), "Заданий")
	_kpi_tile(kpi_row, UiIcons.QUESTS.photo, str(data.get("photos", 0)), "Снимков")

	var route_card := _panel_box(left, Vector2(16, 12), true)
	var route_head := HBoxContainer.new()
	route_head.add_theme_constant_override("separation", 8)
	route_card.add_child(route_head)
	var r_title := _label("МАРШРУТ ЭКСПЕДИЦИИ", 13, route_head, HudStyle.MINT)
	r_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label("Всего · %s" % Util.distance_text(total_m), 13, route_head, MUTED)
	var preview := RoutePreview.new()
	preview.track = data.get("track", {})
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview.custom_minimum_size.y = 140
	route_card.add_child(preview)

	# --- Правая колонка: Открыто в мире и Текущие дела ---
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	cols.add_child(right)

	var places: Array = data.get("places", [])
	var found_sum := 0
	var total_sum := 0
	for entry: Array in places:
		found_sum += int(entry[1])
		total_sum += int(entry[2])
	var world_ratio := float(found_sum) / maxi(1, total_sum)
	var world_card := _panel_box(right, Vector2(18, 14), true)
	var world_head := HBoxContainer.new()
	world_head.add_theme_constant_override("separation", 8)
	world_card.add_child(world_head)
	var w_title := _label("ОТКРЫТО В МИРЕ", 13, world_head, HudStyle.MINT)
	w_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label("%d%% (%d из %d)" % [roundi(world_ratio * 100.0), found_sum, total_sum], 15, world_head, HudStyle.CREAM)
	world_card.add_child(HudStyle.bar(world_ratio, 6.0, HudStyle.MINT))

	var places_scroll := ScrollContainer.new()
	places_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	places_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	world_card.add_child(places_scroll)
	var places_list := VBoxContainer.new()
	places_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	places_list.add_theme_constant_override("separation", 8)
	places_scroll.add_child(places_list)
	for entry: Array in places:
		_place_row(places_list, str(entry[0]), int(entry[1]), int(entry[2]))

	var tasks_card := _panel_box(right, Vector2(18, 14))
	_label("ТЕКУЩИЕ ДЕЛА И БЛАГОДАРНОСТИ", 13, tasks_card, HudStyle.MINT)
	_fill_tasks_card(tasks_card, data)


func _panel_box(parent: Container, pad := Vector2(16, 12), expand_v := false) -> VBoxContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if expand_v:
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 10, pad, false))
	parent.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	if expand_v:
		box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_child(box)
	return box


func _travel_card(parent: Container, icon_tex: Texture2D, distance: String, caption: String, share: float, color: Color) -> void:
	var box := _panel_box(parent, Vector2(14, 12))
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	box.add_child(top)
	top.add_child(UiIcons.rect(icon_tex, 20, color))
	var val := _label(distance, 21, top, HudStyle.CREAM)
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(HudStyle.chip("%d%%" % roundi(share * 100.0), color, HudStyle.SURFACE, Color(color, 0.5)))
	_label(caption, 13, box, MUTED)
	box.add_child(HudStyle.bar(share, 6.0, color))


func _kpi_tile(parent: Container, icon_tex: Texture2D, value: String, caption: String) -> void:
	var box := _panel_box(parent, Vector2(10, 10))
	box.add_theme_constant_override("separation", 4)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	box.add_child(top)
	top.add_child(UiIcons.rect(icon_tex, 16, HudStyle.MINT))
	var val := _label(value, 17, top, HudStyle.CREAM)
	val.clip_text = true
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cap := _label(caption, 12, box, MUTED)
	cap.clip_text = true


func _place_row(parent: Container, title: String, found: int, total: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	row.add_child(UiIcons.rect(UiIcons.place_category(title), 16, HudStyle.MINT if found > 0 else Color(MUTED, 0.55)))
	var lbl := _label(title, 15, row, HudStyle.CREAM if found > 0 else MUTED)
	lbl.custom_minimum_size.x = 152
	lbl.clip_text = true
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var bar := HudStyle.bar(float(found) / maxi(1, total), 5.0, HudStyle.MINT if found > 0 else HudStyle.BORDER)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(bar)
	var count := _label("%d из %d" % [found, total], 14, row, HudStyle.MINT if found > 0 else MUTED)
	count.custom_minimum_size.x = 64
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


func _fill_tasks_card(card: VBoxContainer, data: Dictionary) -> void:
	var active: Dictionary = data.get("active_quest", {})
	if not active.is_empty():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		card.add_child(row)
		var qcolor: Color = active.get("color", HudStyle.MINT)
		row.add_child(UiIcons.rect(UiIcons.quest(str(active.get("kind", "visit"))), 16, qcolor))
		var title := _label("Активно: «%s» (%d/%d)" % [active.title, active.step_index, active.step_count], 14, row, HudStyle.CREAM)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.clip_text = true
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var step_text := str(active.get("step_text", ""))
		if not step_text.is_empty():
			var sub := _label(step_text, 13, card, MUTED)
			sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	else:
		var empty_row := HBoxContainer.new()
		empty_row.add_theme_constant_override("separation", 8)
		card.add_child(empty_row)
		empty_row.add_child(UiIcons.rect(UiIcons.QUESTS.visit, 15, Color(MUTED, 0.55)))
		_label("Активного задания нет — проверьте доску поселения", 13, empty_row, MUTED)

	var series: Dictionary = data.get("series", {})
	if int(series.get("total", 0)) > 0 or bool(series.get("finished", false)):
		var srow := HBoxContainer.new()
		srow.add_theme_constant_override("separation", 8)
		card.add_child(srow)
		srow.add_child(UiIcons.rect(UiIcons.obelisk(0), 15, HudStyle.MINT))
		var stext := "Летопись обелисков: все таблички сняты" if bool(series.get("finished", false)) else "Летопись обелисков: %d из %d снято" % [int(series.done), int(series.total)]
		_label(stext, 13, srow, HudStyle.MINT)

	var thanks: Array = data.get("thanks", [])
	for line: Variant in thanks:
		var trow := HBoxContainer.new()
		trow.add_theme_constant_override("separation", 8)
		card.add_child(trow)
		trow.add_child(UiIcons.rect(UiIcons.CHECK, 15, HudStyle.AMBER))
		var tlbl := _label(str(line), 13, trow, HudStyle.AMBER)
		tlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tlbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var helped: Array = data.get("helped", [])
	if thanks.is_empty() and not helped.is_empty():
		var hlbl := _label("Выполнено для поселений: %s" % ", ".join(PackedStringArray(helped)), 13, card, MUTED)
		hlbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


## Вкладка «Альбом»: навигационная лента с фильтр-пилюлями + сетка карточек + лайтбокс
func _fill_album(data: Dictionary) -> void:
	_album_data = data
	var pages: Array = data.get("pages", [])
	var groups: Array = data.get("groups", [])
	var nav_bar := HBoxContainer.new()
	nav_bar.add_theme_constant_override("separation", 6)
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

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav_bar.add_child(spacer)

	var ratio := float(done_all) / maxi(1, total_all)
	var prog_box := HBoxContainer.new()
	prog_box.add_theme_constant_override("separation", 8)
	prog_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	nav_bar.add_child(prog_box)
	_label("Коллекция · %d%%" % roundi(ratio * 100.0), 13, prog_box, HudStyle.MINT)
	var prog_bar := HudStyle.bar(ratio, 6.0, HudStyle.MINT, HudStyle.RECESS)
	prog_bar.custom_minimum_size = Vector2(96, 6)
	prog_box.add_child(prog_bar)

	_album_scroll = ScrollContainer.new()
	_album_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_album_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_album_scroll.follow_focus = true
	_album_page.add_child(_album_scroll)
	_album_content = VBoxContainer.new()
	_album_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_album_content.add_theme_constant_override("separation", 12)
	_album_scroll.add_child(_album_content)
	_rebuild_album_grid()


func _pill(text: String, group_index: int, group: ButtonGroup, parent: Container) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.button_group = group
	btn.theme_type_variation = &"PillButton"
	btn.custom_minimum_size.y = 34
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
		_label("%s · %d из %d" % [groups[g], done, mine.size()], 19, header, HudStyle.MINT)
		var grid := GridContainer.new()
		grid.columns = COLUMNS
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 12)
		_album_content.add_child(grid)
		for page: Dictionary in mine:
			grid.add_child(_card(page, opened_all))


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
		btn.clip_contents = true
		btn.tooltip_text = "Открыть крупно: «%s»" % page.title
		btn.pressed.connect(func() -> void: _open_lightbox(page, opened_all, btn))
		var pad := MarginContainer.new()
		pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		for edge in ["left", "right", "top", "bottom"]:
			pad.add_theme_constant_override("margin_" + edge, 7)
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(pad)
		pad.add_child(column)
		root_ctrl = btn
	else:
		var panel := PanelContainer.new()
		panel.custom_minimum_size = CARD
		panel.clip_contents = true
		panel.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.SURFACE.lerp(HudStyle.RECESS, 0.4), HudStyle.BORDER, 8, Vector2(7, 7), false))
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
		var clip_style := HudStyle.panel(HudStyle.SURFACE, HudStyle.SURFACE, 6, Vector2.ZERO, false)
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
			dbadge.add_theme_stylebox_override("panel", HudStyle.panel(Color(HudStyle.SURFACE, 0.84), Color(HudStyle.BORDER, 0.7), 4, Vector2(5, 1), false))
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
			tbadge.add_theme_stylebox_override("panel", HudStyle.panel(Color(HudStyle.SURFACE, 0.84), Color(HudStyle.MINT, 0.7), 4, Vector2(5, 1), false))
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
		plate.add_theme_stylebox_override("panel", HudStyle.panel(pbg, Color(HudStyle.BORDER, 0.45), 6, Vector2.ZERO, false))
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
	title_row.add_theme_constant_override("separation", 5)
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
	return root_ctrl


func _open_lightbox(page: Dictionary, opened_all: Array[Dictionary], return_to: Control = null, focus_target := "close") -> void:
	if _lightbox != null:
		if is_instance_valid(_lightbox):
			if _lightbox.get_parent() == self:
				remove_child(_lightbox)
			_lightbox.queue_free()
		_lightbox = null
	_lightbox_return_focus = return_to
	var idx := 0
	for i in opened_all.size():
		if opened_all[i].key == page.key:
			idx = i
			break

	var backdrop := PanelContainer.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.03, 0.07, 0.06, 0.88)
	bg_style.set_corner_radius_all(12)
	bg_style.set_content_margin_all(24)
	backdrop.add_theme_stylebox_override("panel", bg_style)
	backdrop.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			close_lightbox())
	_lightbox = backdrop
	add_child(backdrop)

	var modal := PanelContainer.new()
	modal.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	modal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	modal.custom_minimum_size = Vector2(820, 0)
	modal.add_theme_stylebox_override("panel", HudStyle.sheet(Vector2(20, 16)))
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.add_child(modal)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	modal.add_child(vbox)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	vbox.add_child(head)
	head.add_child(UiIcons.rect(UiIcons.album_icon(int(page.group), str(page.key), int(page.get("form", 0))), 20, HudStyle.MINT))
	var title := _label(str(page.title), 22, head, HudStyle.CREAM)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var groups: Array = _album_data.get("groups", [])
	var gidx := int(page.get("group", 0))
	if gidx >= 0 and gidx < groups.size():
		head.add_child(HudStyle.chip(str(groups[gidx]), HudStyle.MINT))
	var close_btn := Button.new()
	close_btn.text = "✕ Закрыть"
	close_btn.custom_minimum_size = Vector2(124, 44)
	close_btn.pressed.connect(func() -> void: close_lightbox())
	head.add_child(close_btn)

	var lore_text := str(page.get("text", ""))
	var img_size := Vector2(560, 315) if not lore_text.is_empty() else Vector2(720, 405)
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
		lore_box.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 8, Vector2(14, 10), false))
		vbox.add_child(lore_box)
		var lore_lbl := _label(lore_text, 16, lore_box, HudStyle.CREAM)
		lore_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lore_lbl.custom_minimum_size.x = 750

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
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


## Мини-схема пройденного маршрута (MapJournal.legs + current): тёмно-хвойный планшет с сеткой и стрелкой игрока
class RoutePreview extends Control:
	var track := {}

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true

	func _draw() -> void:
		draw_style_box(HudStyle.panel(HudStyle.SURFACE, Color(HudStyle.BORDER, 0.65), 8, Vector2.ZERO, false), Rect2(Vector2.ZERO, size))
		var grid_color := Color(HudStyle.BORDER, 0.22)
		var step := 36.0
		for x in range(int(step), int(size.x), int(step)):
			draw_line(Vector2(x, 4), Vector2(x, size.y - 4), grid_color, 1.0)
		for y in range(int(step), int(size.y), int(step)):
			draw_line(Vector2(4, y), Vector2(size.x - 4, y), grid_color, 1.0)
		HudStyle.centered(self, Vector2(size.x - 16.0, 18.0), "С", 11, Color(HudStyle.MUTED, 0.7))

		var legs: Array = track.get("legs", [])
		var current: PackedVector2Array = track.get("current", PackedVector2Array())
		var lines: Array[PackedVector2Array] = []
		for leg: Dictionary in legs:
			var pts: PackedVector2Array = leg.get("points", PackedVector2Array())
			if pts.size() > 1:
				lines.append(pts)
		if current.size() > 1:
			lines.append(current)

		if lines.is_empty():
			HudStyle.centered(self, size * 0.5 + Vector2(0, 4), "Маршрут появится в движении", 13, Color(HudStyle.MUTED, 0.65))
			return

		var bounds := Rect2(lines[0][0], Vector2.ZERO)
		for pts: PackedVector2Array in lines:
			for p: Vector2 in pts:
				bounds = bounds.expand(p)
		var player_pos: Vector2 = track.get("player", Vector2.INF)
		if player_pos.is_finite():
			bounds = bounds.expand(player_pos)

		var span := bounds.size.max(Vector2(60.0, 60.0))
		var pad := Vector2(28.0, 22.0)
		var avail := (size - pad * 2.0).max(Vector2.ONE)
		var scale_f := minf(avail.x / span.x, avail.y / span.y)
		var center_world := bounds.get_center()
		var center_screen := size * 0.5
		var to_screen := func(w: Vector2) -> Vector2:
			return center_screen + (w - center_world) * scale_f

		for pts: PackedVector2Array in lines:
			var mapped := PackedVector2Array()
			mapped.resize(pts.size())
			for i in pts.size():
				mapped[i] = to_screen.call(pts[i])
			draw_polyline(mapped, Color(HudStyle.SURFACE.lerp(HudStyle.MINT, 0.25), 0.7), 5.0, true)
			draw_polyline(mapped, HudStyle.MINT, 2.2, true)

		var start_pt: Vector2 = to_screen.call(lines[0][0])
		draw_circle(start_pt, 4.0, HudStyle.CREAM, true, -1.0, true)
		draw_circle(start_pt, 2.2, HudStyle.SURFACE, true, -1.0, true)

		if player_pos.is_finite():
			var p_screen: Vector2 = to_screen.call(player_pos)
			var yaw := float(track.get("yaw", 0.0))
			draw_circle(p_screen, 8.0, Color(HudStyle.AMBER, 0.22), true, -1.0, true)
			draw_set_transform(p_screen, -yaw)
			var tip := PackedVector2Array([Vector2(0, -7), Vector2(4.5, 5), Vector2(0, 2.5), Vector2(-4.5, 5)])
			draw_colored_polygon(tip, HudStyle.AMBER)
			draw_set_transform(Vector2.ZERO)
