extends PanelContainer

signal closed
signal sound_requested(kind: StringName)

const Progress := preload("res://scripts/game/shop_progress.gd")
const Style := preload("res://scripts/ui/hud_style.gd")
const PREVIEW_DIR := "res://resources/shop/"
const CANVAS := Color("#101e1c")
const SURFACE := Color("#192c29")
const LINE := Color("#38534b")
const ACCENT := Color("#ace5cd")

var show_back := false
var _profile: Progress
var _selection := Progress.DEFAULT_SCHEME
var _balance: Label
var _collection: Label
var _goal_card: PanelContainer
var _goal_title: Label
var _goal_status: Label
var _goal_bar: ProgressBar
var _name: Label
var _status: Label
var _price_caption: Label
var _price_bar: ProgressBar
var _price_card: PanelContainer
var _preview_tween: Tween
var _preview: TextureRect
var _action: Button
var _goal_action: Button
var _actions: BoxContainer
var _review_actions: BoxContainer
var _cancel_buy: Button
var _confirm_buy: Button
var _purchase_id := ""
var _note: Label
var _layout: BoxContainer
var _row_grid: GridContainer
var _rows := {}
var _previews := {}


func _ready() -> void:
	theme = Style.theme()
	var background := StyleBoxFlat.new()
	background.bg_color = CANVAS
	background.set_content_margin_all(20)
	add_theme_stylebox_override("panel", background)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	column.add_child(header)
	var heading := VBoxContainer.new()
	heading.size_flags_horizontal = SIZE_EXPAND_FILL
	heading.add_theme_constant_override("separation", 2)
	header.add_child(heading)
	_label(heading, "МАГАЗИН", 25, Style.CREAM)
	_label(heading, "Персонализация", 15, Style.MUTED)
	var wallet := PanelContainer.new()
	wallet.size_flags_vertical = SIZE_SHRINK_CENTER
	wallet.add_theme_stylebox_override("panel", _flat_box(Color("#1d3530"), LINE, 8, Vector2(14, 9)))
	header.add_child(wallet)
	_balance = _label(wallet, "Очки", 17, Style.MINT)
	_balance.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if show_back:
		var back := Button.new()
		back.text = "Назад"
		back.custom_minimum_size = Vector2(100, 44)
		back.pressed.connect(func() -> void:
			if not dismiss_purchase():
				closed.emit())
		header.add_child(back)
	# A separate section strip leaves room for additional shop categories as they are implemented.
	var sections := HBoxContainer.new()
	sections.add_theme_constant_override("separation", 14)
	column.add_child(sections)
	var section_label := _label(sections, "РАЗДЕЛ", 13, Style.MUTED)
	section_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var active_section := PanelContainer.new()
	active_section.add_theme_stylebox_override("panel", _flat_box(Color("#29443b"), ACCENT, 5, Vector2(12, 5)))
	sections.add_child(active_section)
	_label(active_section, "Расцветки", 15, Style.CREAM)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	column.add_child(scroll)
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = SIZE_EXPAND_FILL
	for edge: String in ["left", "top", "right", "bottom"]:
		inset.add_theme_constant_override("margin_" + edge, 3)
	scroll.add_child(inset)
	_layout = BoxContainer.new()
	_layout.size_flags_horizontal = SIZE_EXPAND_FILL
	_layout.add_theme_constant_override("separation", 28)
	inset.add_child(_layout)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = SIZE_EXPAND_FILL
	list.size_flags_stretch_ratio = 0.85
	list.add_theme_constant_override("separation", 10)
	_layout.add_child(list)
	_collection = _label(list, "Коллекция", 15, Style.MUTED)
	_row_grid = GridContainer.new()
	_row_grid.columns = 1
	_row_grid.add_theme_constant_override("h_separation", 8)
	_row_grid.add_theme_constant_override("v_separation", 8)
	list.add_child(_row_grid)
	var group := ButtonGroup.new()
	for id: String in Progress.PRICES:
		var row := Button.new()
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.custom_minimum_size = Vector2(0, 64)
		row.size_flags_horizontal = SIZE_EXPAND_FILL
		row.theme_type_variation = &"CardButton"
		row.add_theme_stylebox_override("normal", _row_style(Color.TRANSPARENT, Color.TRANSPARENT))
		row.add_theme_stylebox_override("hover", _row_style(Color("#1e3530"), LINE))
		row.add_theme_stylebox_override("pressed", _row_style(Color("#29453c"), ACCENT))
		row.add_theme_stylebox_override("hover_pressed", _row_style(Color("#315147"), ACCENT))
		row.add_theme_font_size_override("font_size", 17)
		row.expand_icon = true
		row.add_theme_constant_override("icon_max_width", 64)
		row.add_theme_constant_override("h_separation", 10)
		row.toggle_mode = true
		row.button_group = group
		row.pressed.connect(_select.bind(id))
		row.focus_entered.connect(_select.bind(id))
		_rows[id] = row
		_row_grid.add_child(row)
	_build_goal_card(list)
	var display := PanelContainer.new()
	display.size_flags_horizontal = SIZE_EXPAND_FILL
	display.size_flags_vertical = SIZE_SHRINK_BEGIN
	display.size_flags_stretch_ratio = 2.0
	display.add_theme_stylebox_override("panel", _flat_box(SURFACE, Color.TRANSPARENT, 10, Vector2(20, 16)))
	_layout.add_child(display)
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 8)
	display.add_child(detail)
	var detail_header := HBoxContainer.new()
	detail_header.add_theme_constant_override("separation", 12)
	detail.add_child(detail_header)
	_name = _label(detail_header, "", 28, Style.CREAM)
	_name.size_flags_horizontal = SIZE_EXPAND_FILL
	_status = _label(detail_header, "", 14, Style.MINT)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.mouse_filter = MOUSE_FILTER_IGNORE
	detail.add_child(_preview)
	_price_card = PanelContainer.new()
	_price_card.add_theme_stylebox_override("panel", _flat_box(Color("#203832"), Color.TRANSPARENT, 6, Vector2(12, 9)))
	detail.add_child(_price_card)
	var price_content := VBoxContainer.new()
	price_content.add_theme_constant_override("separation", 6)
	_price_card.add_child(price_content)
	_price_caption = _label(price_content, "", 16, Style.CREAM)
	_price_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_price_bar = Style.bar(0.0, 6.0)
	price_content.add_child(_price_bar)
	_actions = BoxContainer.new()
	_actions.add_theme_constant_override("separation", 8)
	detail.add_child(_actions)
	_action = Button.new()
	_action.custom_minimum_size = Vector2(0, 46)
	_action.size_flags_horizontal = SIZE_EXPAND_FILL
	_action.theme_type_variation = &"CardButton"
	_style_primary(_action)
	_action.pressed.connect(_activate)
	_actions.add_child(_action)
	_goal_action = Button.new()
	_goal_action.custom_minimum_size = Vector2(0, 46)
	_goal_action.pressed.connect(_toggle_goal)
	_actions.add_child(_goal_action)
	_build_purchase_review(detail)
	_note = _label(detail, "", 16, Style.MUTED)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	set_process_input(false)
	resized.connect(_reflow)
	visibility_changed.connect(_visibility_changed)
	_reflow()
	_refresh()


func _build_goal_card(parent: Control) -> void:
	_goal_card = PanelContainer.new()
	_goal_card.add_theme_stylebox_override("panel", _flat_box(SURFACE, Color.TRANSPARENT, 6, Vector2(12, 10)))
	_goal_card.hide()
	parent.add_child(_goal_card)
	var contents := VBoxContainer.new()
	contents.add_theme_constant_override("separation", 7)
	_goal_card.add_child(contents)
	_goal_title = _label(contents, "", 16, Style.AMBER)
	_goal_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_goal_bar = ProgressBar.new()
	_goal_bar.show_percentage = false
	_goal_bar.custom_minimum_size.y = 8.0
	_goal_bar.add_theme_stylebox_override("background", Style.panel(Style.RECESS, Style.RECESS, 4, Vector2.ZERO, false))
	_goal_bar.add_theme_stylebox_override("fill", Style.panel(Style.MINT, Style.MINT, 4, Vector2.ZERO, false))
	contents.add_child(_goal_bar)
	_goal_status = _label(contents, "", 16, Style.MUTED)
	_goal_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _build_purchase_review(parent: Control) -> void:
	_review_actions = BoxContainer.new()
	_review_actions.add_theme_constant_override("separation", 8)
	_review_actions.hide()
	parent.add_child(_review_actions)
	_cancel_buy = Button.new()
	_cancel_buy.text = "Отмена"
	_cancel_buy.custom_minimum_size.y = 46
	_cancel_buy.pressed.connect(dismiss_purchase)
	_review_actions.add_child(_cancel_buy)
	_confirm_buy = Button.new()
	_confirm_buy.text = "Подтвердить покупку"
	_confirm_buy.custom_minimum_size.y = 46
	_confirm_buy.size_flags_horizontal = SIZE_EXPAND_FILL
	_confirm_buy.theme_type_variation = &"CardButton"
	_style_primary(_confirm_buy)
	_confirm_buy.set_meta(&"ui_sound_custom", true)
	_confirm_buy.pressed.connect(_buy_reviewed)
	_review_actions.add_child(_confirm_buy)


func set_profile(profile: Progress) -> void:
	if _profile == profile:
		return
	if _profile != null:
		_profile.changed.disconnect(_refresh)
	_profile = profile
	_purchase_id = ""
	_profile.changed.connect(_refresh)
	_selection = profile.equipped
	if is_node_ready():
		_refresh()


func open() -> void:
	_purchase_id = ""
	var reward_result := 0
	if _profile != null:
		_selection = _profile.purchase_goal if _profile.purchase_goal != "" else _profile.equipped
		reward_result = _profile.retry_rewards()
	if _previews.is_empty():
		for id: String in _rows:
			var preview := load(PREVIEW_DIR + id + ".jpg") as Texture2D
			_previews[id] = preview
			_rows[id].icon = preview
	_refresh()
	if reward_result < 0 and _profile.load_error == OK:
		_note.text = "Не удалось записать очки за задания. Откройте магазин ещё раз, чтобы повторить."
	_rows[_selection].grab_focus()


func _label(parent: Control, value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _flat_box(background: Color, border: Color, radius: int, padding: Vector2) -> StyleBoxFlat:
	var box := Style.panel(background, border, radius, padding, false)
	box.set_border_width_all(0 if border.a == 0.0 else 1)
	return box


func _row_style(background: Color, accent: Color) -> StyleBoxFlat:
	var box := _flat_box(background, Color.TRANSPARENT, 6, Vector2(10, 6))
	box.border_color = accent
	box.border_width_left = 3
	return box


func _style_primary(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _flat_box(ACCENT, Color.TRANSPARENT, 6, Vector2(14, 8)))
	button.add_theme_stylebox_override("hover", _flat_box(Color("#c6f2df"), Color.TRANSPARENT, 6, Vector2(14, 8)))
	button.add_theme_stylebox_override("pressed", _flat_box(Color("#81c3a7"), Color.TRANSPARENT, 6, Vector2(14, 8)))
	for color_name: String in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
		button.add_theme_color_override(color_name, Color("#102720"))


func _reflow() -> void:
	_layout.vertical = size.x < 640.0
	_row_grid.columns = 2 if _layout.vertical and size.x >= 440.0 else 1
	_actions.vertical = size.x < 550.0
	_review_actions.vertical = _actions.vertical
	for row: Button in _rows.values():
		row.custom_minimum_size.y = 54.0 if _layout.vertical else 64.0
	_preview.custom_minimum_size.y = clampf(size.y - 405.0, 150.0, 380.0)
	_link_actions()


func _link_actions() -> void:
	var selected: Control = _rows[_selection]
	var first := _goal_action if _action.disabled and _goal_action.visible else _action
	if _review_actions.visible:
		first = _cancel_buy
	var goal_left: Control = selected if _action.disabled else _action
	for row: Button in _rows.values():
		row.focus_neighbor_right = NodePath() if _layout.vertical or first.disabled else row.get_path_to(first)
	_action.focus_neighbor_left = NodePath() if _layout.vertical else _action.get_path_to(selected)
	_action.focus_neighbor_right = _action.get_path_to(_goal_action) if _goal_action.visible and not _actions.vertical else NodePath()
	_goal_action.focus_neighbor_left = NodePath() if _layout.vertical else _goal_action.get_path_to(goal_left)
	_cancel_buy.focus_neighbor_left = NodePath() if _layout.vertical else _cancel_buy.get_path_to(selected)
	_cancel_buy.focus_neighbor_right = NodePath() if _review_actions.vertical else _cancel_buy.get_path_to(_confirm_buy)
	_cancel_buy.focus_neighbor_bottom = _cancel_buy.get_path_to(_confirm_buy) if _review_actions.vertical else NodePath()
	_confirm_buy.focus_neighbor_left = NodePath() if _review_actions.vertical else _confirm_buy.get_path_to(_cancel_buy)
	_confirm_buy.focus_neighbor_top = _confirm_buy.get_path_to(_cancel_buy) if _review_actions.vertical else NodePath()


func _select(id: String) -> void:
	if id == _selection:
		return
	_selection = id
	_purchase_id = ""
	_show_selection()


func _visibility_changed() -> void:
	if is_visible_in_tree():
		_refresh()
	else:
		_purchase_id = ""
		set_process_input(false)


func _input(event: InputEvent) -> void:
	# The second half of a double-click on Buy may land on the newly shown Confirm button.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and event.double_click and _confirm_buy.get_global_rect().has_point(event.position):
		get_viewport().set_input_as_handled()


func _refresh() -> void:
	if _profile == null or not is_visible_in_tree():
		return
	_balance.text = "Очки · %d" % _profile.balance
	var owned_count := 0
	for id: String in _rows:
		var status := "%d очк." % Progress.PRICES[id]
		if _profile.owns(id):
			owned_count += 1
			status = "Надето" if id == _profile.equipped else "Куплено"
		elif id == _profile.purchase_goal:
			status += " · Цель"
		_rows[id].text = "%s\n%s" % [Progress.Palette.SCHEME_NAMES[id], status]
		_rows[id].tooltip_text = "%s · %s" % [Progress.Palette.SCHEME_NAMES[id], status]
	_collection.text = "Расцветки · %d из %d" % [owned_count, _rows.size()]
	_refresh_goal()
	_show_selection()


func _refresh_goal() -> void:
	var id := _profile.purchase_goal
	_goal_card.visible = id != "" and _profile.load_error == OK
	if not _goal_card.visible:
		return
	var price: int = Progress.PRICES[id]
	var remaining := _profile.remaining(id)
	_goal_title.text = "Цель · " + Progress.Palette.SCHEME_NAMES[id]
	_goal_bar.max_value = price
	_goal_bar.value = price - remaining
	_goal_status.text = "%d из %d очк. · Осталось %d" % [price - remaining, price, remaining] if remaining > 0 else "Можно купить · %d очк." % price


func _show_selection() -> void:
	for id: String in _rows:
		_rows[id].set_pressed_no_signal(id == _selection)
	_name.text = Progress.Palette.SCHEME_NAMES[_selection]
	var preview: Texture2D = _previews.get(_selection)
	if _preview.texture != preview:
		_preview.texture = preview
		if preview != null and DisplayServer.get_name() != "headless":
			if _preview_tween != null and _preview_tween.is_valid():
				_preview_tween.kill()
			_preview.modulate.a = 0.72
			_preview_tween = create_tween()
			_preview_tween.tween_property(_preview, "modulate:a", 1.0, 0.16)
	_note.text = ""
	var owned := _profile.owns(_selection)
	_status.text = "НАДЕТО" if _selection == _profile.equipped else ("В КОЛЛЕКЦИИ" if owned else "НОВЫЙ КОМПЛЕКТ")
	_status.add_theme_color_override("font_color", Style.MINT if owned else Style.AMBER)
	_price_card.visible = not owned
	if not owned:
		var price: int = Progress.PRICES[_selection]
		var remaining := _profile.remaining(_selection)
		_price_caption.text = "Доступно %d из %d очк. · Не хватает %d" % [mini(_profile.balance, price), price, remaining] if remaining > 0 else "Доступно для покупки · %d очк." % price
		_price_bar.value = minf(float(_profile.balance) / float(maxi(price, 1)), 1.0)
	var reviewing := _purchase_id != ""
	set_process_input(reviewing)
	_actions.visible = not reviewing
	_review_actions.visible = reviewing
	_action.disabled = false
	var goal := _profile.purchase_goal
	_goal_action.visible = not _profile.owns(_selection)
	_goal_action.disabled = _profile.load_error != OK
	_goal_action.text = "Сделать целью"
	if goal == _selection:
		_goal_action.text = "Убрать цель"
	elif goal != "":
		_goal_action.text = "Сменить цель"
	if _selection == _profile.equipped:
		_action.text = "Надето"
		_action.disabled = true
		if _profile.needs_first_purchase() and _profile.balance == 0:
			_note.text = "Очки за расцветки можно заработать заданиями поселений."
	elif _profile.owns(_selection):
		_action.text = "Надеть"
	else:
		var price: int = Progress.PRICES[_selection]
		_action.text = "Купить за %d" % price
		var remaining := _profile.remaining(_selection)
		_action.disabled = remaining > 0
		if _action.disabled and _selection == goal:
			_note.text = "Очки дают за задания поселений."
		elif _action.disabled:
			_note.text = "Не хватает %d очк. · Выполняйте задания поселений" % remaining
		else:
			_note.text = _purchase_summary(_selection, price)
	if reviewing:
		_confirm_buy.disabled = _action.disabled or _profile.owns(_purchase_id) or _profile.load_error != OK
		if not _confirm_buy.disabled:
			var price: int = Progress.PRICES[_purchase_id]
			_note.text = "«%s» за %d очк. %s" % [_name.text, price, _purchase_summary(_purchase_id, price)]
	if _profile.load_error != OK:
		_action.disabled = true
		_status.text = "НЕТ ДАННЫХ"
		_status.add_theme_color_override("font_color", Style.RED)
		_price_card.hide()
		_note.text = "Не удалось загрузить прогресс магазина."
	_link_actions()


func _purchase_summary(id: String, price: int) -> String:
	var after := _profile.balance - price
	var summary := "После покупки останется %d очк." % after
	var goal := _profile.purchase_goal
	if goal != "" and goal != id and after < int(Progress.PRICES[goal]):
		summary += " На «%s» нужно будет ещё %d очк." % [Progress.Palette.SCHEME_NAMES[goal], int(Progress.PRICES[goal]) - after]
	return summary


func _toggle_goal() -> void:
	var id := "" if _profile.purchase_goal == _selection else _selection
	if _profile.set_purchase_goal(id) != OK:
		_note.text = "Не удалось сохранить цель. Попробуйте ещё раз."


func _activate() -> void:
	if _purchase_id != "" or _action.disabled:
		return
	if _profile.owns(_selection):
		if _profile.equip(_selection) == OK:
			_rows[_selection].grab_focus()
			_note.text = "Комплект надет на велосипед и райдера."
			Style.pulse(_status, Style.MINT)
			return
		_note.text = "Не удалось сохранить изменение. Попробуйте ещё раз."
	else:
		_purchase_id = _selection
		_show_selection()
		_cancel_buy.grab_focus()


func dismiss_purchase() -> bool:
	if _purchase_id == "":
		return false
	_purchase_id = ""
	_show_selection()
	_action.grab_focus()
	return true


func _buy_reviewed() -> void:
	if _purchase_id == "" or _confirm_buy.disabled:
		return
	var id := _purchase_id
	_purchase_id = ""
	if _profile.buy(id) == OK:
		_rows[id].grab_focus()
		_note.text = "«%s» добавлен в коллекцию. Нажмите «Надеть», чтобы применить." % _name.text
		Style.pulse(_status, Style.MINT)
		sound_requested.emit(&"confirm")
	else:
		_show_selection()
		_action.grab_focus()
		_note.text = "Покупка не сохранена. Очки сохранены на счёте."
		sound_requested.emit(&"error_deny")
