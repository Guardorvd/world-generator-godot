extends PanelContainer

signal closed
signal sound_requested(kind: StringName)

const Progress := preload("res://scripts/game/shop_progress.gd")
const Style := preload("res://scripts/ui/hud_style.gd")
const PREVIEW_DIR := "res://resources/shop/"
const CANVAS := Color("#101a19")
const SURFACE := Color("#1b2b29")
const LINE := Color("#405853")
const ACCENT := Color("#e9c78c")

var show_back := false
var _profile: Progress
var _selection := Progress.DEFAULT_SCHEME
var _balance: Label
var _header: HBoxContainer
var _heading_title: Label
var _heading_eyebrow: Label
var _scroll: ScrollContainer
var _back: Button
var _stage_controls: BoxContainer
var _stage_caption: Label
var _collection: Label
var _goal_card: PanelContainer
var _goal_title: Label
var _goal_status: Label
var _goal_bar: ProgressBar
var _name: Label
var _status: Label
var _price_caption: Label
var _price_value: Label
var _review_card: PanelContainer
var _review_title: Label
var _review_balance: Label
var _price_bar: ProgressBar
var _price_card: PanelContainer
var _preview_tween: Tween
var _preview: TextureRect
var _stage: PanelContainer
var _view_buttons: Array[Button] = []
var _view_index := 0
var _portraits := {}
var _compare_mode := false
var _compare_button: Button
var _compare_root: HBoxContainer
var _compare_images: Array[TextureRect] = []
var _compare_labels: Array[Label] = []
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
var _card_images := {}
var _card_status := {}


func _ready() -> void:
	theme = Style.theme()
	add_theme_stylebox_override("panel", _flat_box(CANVAS, Color.TRANSPARENT, 0, Vector2(24, 18)))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	add_child(column)
	_header = HBoxContainer.new()
	_header.add_theme_constant_override("separation", 16)
	column.add_child(_header)
	var heading := VBoxContainer.new()
	heading.size_flags_horizontal = SIZE_EXPAND_FILL
	heading.add_theme_constant_override("separation", 0)
	_header.add_child(heading)
	_heading_eyebrow = _label(heading, "ЭКИПИРОВКА  /  МАГАЗИН", 13, ACCENT)
	_heading_eyebrow.clip_text = true
	_heading_title = _label(heading, "Выберите свой стиль", 27, Style.CREAM)
	_heading_title.clip_text = true
	var wallet := VBoxContainer.new()
	wallet.size_flags_vertical = SIZE_SHRINK_CENTER
	wallet.add_theme_constant_override("separation", 0)
	_header.add_child(wallet)
	_label(wallet, "ВАШ БАЛАНС", 12, Style.MUTED)
	_balance = _label(wallet, "0 очков", 21, Style.CREAM)
	if show_back:
		_back = Button.new()
		_back.text = "Назад"
		_back.custom_minimum_size = Vector2(100, 44)
		_back.size_flags_vertical = SIZE_SHRINK_CENTER
		_back.pressed.connect(func() -> void:
			if not dismiss_purchase():
				closed.emit())
		_header.add_child(_back)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	column.add_child(_scroll)
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = SIZE_EXPAND_FILL
	for edge: String in ["left", "top", "right", "bottom"]:
		inset.add_theme_constant_override("margin_" + edge, 3)
	_scroll.add_child(inset)
	_layout = BoxContainer.new()
	_layout.size_flags_horizontal = SIZE_EXPAND_FILL
	_layout.add_theme_constant_override("separation", 20)
	inset.add_child(_layout)
	var showcase := VBoxContainer.new()
	showcase.size_flags_horizontal = SIZE_EXPAND_FILL
	showcase.size_flags_stretch_ratio = 1.9
	showcase.add_theme_constant_override("separation", 10)
	_layout.add_child(showcase)
	_stage = PanelContainer.new()
	_stage.add_theme_stylebox_override("panel", _flat_box(Color("#697e72"), Color.TRANSPARENT, 3, Vector2.ZERO))
	showcase.add_child(_stage)
	var stage_content := Control.new()
	stage_content.mouse_filter = MOUSE_FILTER_PASS
	_stage.add_child(stage_content)
	var backdrop := preload("res://scripts/ui/shop_stage.gd").new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage_content.add_child(backdrop)
	_preview = TextureRect.new()
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.mouse_filter = MOUSE_FILTER_IGNORE
	stage_content.add_child(_preview)
	_compare_root = HBoxContainer.new()
	_compare_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_compare_root.offset_left = 145
	_compare_root.offset_top = 18
	_compare_root.offset_right = -12
	_compare_root.offset_bottom = -14
	_compare_root.add_theme_constant_override("separation", 8)
	_compare_root.mouse_filter = MOUSE_FILTER_IGNORE
	_compare_root.hide()
	stage_content.add_child(_compare_root)
	for i in 2:
		var side := VBoxContainer.new()
		side.size_flags_horizontal = SIZE_EXPAND_FILL
		side.add_theme_constant_override("separation", 4)
		side.mouse_filter = MOUSE_FILTER_IGNORE
		_compare_root.add_child(side)
		var image := TextureRect.new()
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image.size_flags_vertical = SIZE_EXPAND_FILL
		image.mouse_filter = MOUSE_FILTER_IGNORE
		side.add_child(image)
		_compare_images.append(image)
		var caption := _label(side, "", 16, Color("#020905"))
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_compare_labels.append(caption)
	_stage_controls = BoxContainer.new()
	_stage_controls.vertical = true
	_stage_controls.position = Vector2(16, 16)
	_stage_controls.add_theme_constant_override("separation", 6)
	stage_content.add_child(_stage_controls)
	_stage_caption = _label(_stage_controls, "РАКУРС", 14, Color("#020905"))
	var views := ButtonGroup.new()
	for index in 2:
		var view := Button.new()
		view.text = ["Сбоку", "Под углом"][index]
		view.custom_minimum_size = Vector2(112, 36)
		view.toggle_mode = true
		view.button_group = views
		view.add_theme_font_size_override("font_size", 14)
		view.add_theme_stylebox_override("normal", _flat_box(Color("#536b5f"), Color.TRANSPARENT, 3, Vector2(10, 5)))
		view.add_theme_stylebox_override("hover", _flat_box(Color("#415c4f"), Color.TRANSPARENT, 3, Vector2(10, 5)))
		view.add_theme_stylebox_override("pressed", _flat_box(Color("#e9c78c"), Color.TRANSPARENT, 3, Vector2(10, 5)))
		view.add_theme_stylebox_override("hover_pressed", _flat_box(Color("#f4dab0"), Color.TRANSPARENT, 3, Vector2(10, 5)))
		view.add_theme_color_override("font_pressed_color", Color("#172b25"))
		view.add_theme_color_override("font_hover_pressed_color", Color("#172b25"))
		view.pressed.connect(_set_view.bind(index))
		_stage_controls.add_child(view)
		_view_buttons.append(view)
	_view_buttons[0].set_pressed_no_signal(true)
	_compare_button = Button.new()
	_compare_button.text = "Сравнить"
	_compare_button.custom_minimum_size = Vector2(112, 36)
	_compare_button.toggle_mode = true
	_compare_button.add_theme_font_size_override("font_size", 14)
	_compare_button.add_theme_stylebox_override("normal", _flat_box(Color("#405e50"), Color.TRANSPARENT, 3, Vector2(10, 5)))
	_compare_button.add_theme_stylebox_override("hover", _flat_box(Color("#304d40"), Color.TRANSPARENT, 3, Vector2(10, 5)))
	_compare_button.add_theme_stylebox_override("pressed", _flat_box(Color("#e9c78c"), Color.TRANSPARENT, 3, Vector2(10, 5)))
	_compare_button.add_theme_stylebox_override("hover_pressed", _flat_box(Color("#f4dab0"), Color.TRANSPARENT, 3, Vector2(10, 5)))
	_compare_button.add_theme_color_override("font_pressed_color", Color("#172b25"))
	_compare_button.add_theme_color_override("font_hover_pressed_color", Color("#172b25"))
	_compare_button.toggled.connect(_set_compare)
	_stage_controls.add_child(_compare_button)
	var collection_header := HBoxContainer.new()
	showcase.add_child(collection_header)
	_label(collection_header, "КОЛЛЕКЦИЯ РАСЦВЕТОК", 14, ACCENT).size_flags_horizontal = SIZE_EXPAND_FILL
	_collection = _label(collection_header, "", 14, Style.MUTED)
	_row_grid = GridContainer.new()
	_row_grid.columns = 4
	_row_grid.add_theme_constant_override("h_separation", 8)
	_row_grid.add_theme_constant_override("v_separation", 8)
	showcase.add_child(_row_grid)
	var group := ButtonGroup.new()
	for id: String in Progress.PRICES:
		var row := Button.new()
		row.custom_minimum_size = Vector2(0, 162)
		row.size_flags_horizontal = SIZE_EXPAND_FILL
		row.toggle_mode = true
		row.button_group = group
		row.add_theme_stylebox_override("normal", _flat_box(Color("#1b2b29"), Color.TRANSPARENT, 3, Vector2(6, 6)))
		row.add_theme_stylebox_override("hover", _flat_box(Color("#30443f"), LINE, 3, Vector2(6, 6)))
		row.add_theme_stylebox_override("pressed", _flat_box(Color("#30443f"), ACCENT, 3, Vector2(6, 6)))
		row.add_theme_stylebox_override("hover_pressed", _flat_box(Color("#394b43"), ACCENT, 3, Vector2(6, 6)))
		row.pressed.connect(_select.bind(id))
		row.focus_entered.connect(_select.bind(id))
		_rows[id] = row
		_row_grid.add_child(row)
		var content := VBoxContainer.new()
		content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		content.offset_left = 7
		content.offset_top = 7
		content.offset_right = -7
		content.offset_bottom = -7
		content.add_theme_constant_override("separation", 2)
		content.mouse_filter = MOUSE_FILTER_IGNORE
		row.add_child(content)
		var portrait_stage := Control.new()
		portrait_stage.custom_minimum_size.y = 98
		portrait_stage.size_flags_vertical = SIZE_EXPAND_FILL
		portrait_stage.mouse_filter = MOUSE_FILTER_IGNORE
		content.add_child(portrait_stage)
		var tile_bg := ColorRect.new()
		tile_bg.color = Color("#687e71")
		tile_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tile_bg.mouse_filter = MOUSE_FILTER_IGNORE
		portrait_stage.add_child(tile_bg)
		var thumb := TextureRect.new()
		thumb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.mouse_filter = MOUSE_FILTER_IGNORE
		portrait_stage.add_child(thumb)
		_card_images[id] = thumb
		var title_row := HBoxContainer.new()
		title_row.mouse_filter = MOUSE_FILTER_IGNORE
		title_row.add_theme_constant_override("separation", 4)
		content.add_child(title_row)
		var title := _label(title_row, Progress.Palette.SCHEME_NAMES[id], 16, Style.CREAM)
		title.size_flags_horizontal = SIZE_EXPAND_FILL
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var colors: Array = Progress.Palette.SCHEMES[id]
		for color_index in [0, 2]:
			var swatch := ColorRect.new()
			swatch.color = Color(colors[color_index])
			swatch.custom_minimum_size = Vector2(10, 10)
			swatch.size_flags_vertical = SIZE_SHRINK_CENTER
			swatch.mouse_filter = MOUSE_FILTER_IGNORE
			title_row.add_child(swatch)
		_card_status[id] = _label(content, "", 15, Style.MUTED)
	var display := PanelContainer.new()
	display.size_flags_horizontal = SIZE_EXPAND_FILL
	display.size_flags_stretch_ratio = 1.0
	display.size_flags_vertical = SIZE_SHRINK_BEGIN
	display.add_theme_stylebox_override("panel", _flat_box(SURFACE, Color.TRANSPARENT, 3, Vector2(22, 20)))
	_layout.add_child(display)
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 10)
	display.add_child(detail)
	_label(detail, "РАСЦВЕТКА  /  ВЕЛОСИПЕД И РАЙДЕР", 12, ACCENT)
	_name = _label(detail, "", 34, Style.CREAM)
	_status = _label(detail, "", 14, Style.MINT)
	_label(detail, "Один комплект меняет облик велосипеда и райдера.", 16, Style.MUTED).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(HSeparator.new())
	_price_card = PanelContainer.new()
	_price_card.add_theme_stylebox_override("panel", _flat_box(Color("#253a35"), Color.TRANSPARENT, 3, Vector2(12, 12)))
	detail.add_child(_price_card)
	var price_content := VBoxContainer.new()
	price_content.add_theme_constant_override("separation", 8)
	_price_card.add_child(price_content)
	var price_header := HBoxContainer.new()
	price_content.add_child(price_header)
	var price_heading := _label(price_header, "СТОИМОСТЬ", 13, Style.MUTED)
	price_heading.size_flags_horizontal = SIZE_EXPAND_FILL
	price_heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_price_value = _label(price_header, "", 22, Style.CREAM)
	_price_caption = _label(price_content, "", 15, Style.CREAM)
	_price_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_price_bar = Style.bar(0.0, 6.0, ACCENT)
	price_content.add_child(_price_bar)
	_actions = BoxContainer.new()
	_actions.vertical = true
	_actions.add_theme_constant_override("separation", 8)
	detail.add_child(_actions)
	_action = Button.new()
	_action.custom_minimum_size = Vector2(0, 48)
	_action.size_flags_horizontal = SIZE_EXPAND_FILL
	_action.add_theme_stylebox_override("focus", _focus_inside())
	_action.theme_type_variation = &"CardButton"
	_style_primary(_action)
	_action.pressed.connect(_activate)
	_actions.add_child(_action)
	_goal_action = Button.new()
	_goal_action.custom_minimum_size = Vector2(0, 44)
	_goal_action.add_theme_stylebox_override("focus", _focus_inside())
	_goal_action.pressed.connect(_toggle_goal)
	_actions.add_child(_goal_action)
	_build_purchase_review(detail)
	_note = _label(detail, "", 15, Style.MUTED)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_goal_card(detail)
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
	_review_card = PanelContainer.new()
	_review_card.add_theme_stylebox_override("panel", _flat_box(Color("#253a35"), LINE, 3, Vector2(12, 12)))
	_review_card.hide()
	parent.add_child(_review_card)
	var contents := VBoxContainer.new()
	contents.add_theme_constant_override("separation", 5)
	_review_card.add_child(contents)
	_label(contents, "ПОДТВЕРЖДЕНИЕ ПОКУПКИ", 13, ACCENT)
	_review_title = _label(contents, "", 19, Style.CREAM)
	_review_balance = _label(contents, "", 15, Style.MUTED)
	_review_balance.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_review_actions = BoxContainer.new()
	_review_actions.add_theme_constant_override("separation", 8)
	_review_actions.hide()
	parent.add_child(_review_actions)
	_cancel_buy = Button.new()
	_cancel_buy.text = "Отмена"
	_cancel_buy.custom_minimum_size.y = 46
	_cancel_buy.add_theme_stylebox_override("focus", _focus_inside())
	_cancel_buy.pressed.connect(dismiss_purchase)
	_review_actions.add_child(_cancel_buy)
	_confirm_buy = Button.new()
	_confirm_buy.text = "Подтвердить покупку"
	_confirm_buy.custom_minimum_size.y = 46
	_confirm_buy.size_flags_horizontal = SIZE_EXPAND_FILL
	_confirm_buy.add_theme_stylebox_override("focus", _focus_inside())
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
	_compare_mode = false
	var reward_result := 0
	if _profile != null:
		_selection = _profile.purchase_goal if _profile.purchase_goal != "" else _profile.equipped
		reward_result = _profile.retry_rewards()
	if _previews.is_empty():
		for id: String in _rows:
			# 20.11: у расцветок второго ряда только портреты, без отдельной картинки
			var preview := load(PREVIEW_DIR + id + ".jpg") as Texture2D if ResourceLoader.exists(PREVIEW_DIR + id + ".jpg") else null
			_previews[id] = preview
			_portraits[id] = [load(PREVIEW_DIR + id + "_side.png"), load(PREVIEW_DIR + id + "_angle.png")]
			_card_images[id].texture = _portrait_crop(_portraits[id][0] if _portraits[id][0] != null else preview)
	_refresh()
	if reward_result < 0 and _profile.load_error == OK:
		_note.text = "Не удалось записать очки за задания. Откройте магазин ещё раз, чтобы повторить."
	_rows[_selection].grab_focus()


func _label(parent: Control, value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.mouse_filter = MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _flat_box(background: Color, border: Color, radius: int, padding: Vector2) -> StyleBoxFlat:
	var box := Style.panel(background, border, radius, padding, false)
	box.set_border_width_all(0 if border.a == 0.0 else 1)
	return box


func _focus_inside() -> StyleBoxFlat:
	var focus := _flat_box(Color.TRANSPARENT, ACCENT, 4, Vector2.ZERO)
	focus.draw_center = false
	focus.set_border_width_all(2)
	return focus


func _style_primary(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _flat_box(ACCENT, Color.TRANSPARENT, 6, Vector2(14, 8)))
	button.add_theme_stylebox_override("hover", _flat_box(Color("#f4dab0"), Color.TRANSPARENT, 6, Vector2(14, 8)))
	button.add_theme_stylebox_override("pressed", _flat_box(Color("#c8a66f"), Color.TRANSPARENT, 6, Vector2(14, 8)))
	for color_name: String in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
		button.add_theme_color_override(color_name, Color("#102720"))


func _reflow() -> void:
	_layout.vertical = size.x < 760.0
	var compact := size.x < 520.0
	_header.add_theme_constant_override("separation", 8 if compact else 16)
	_heading_eyebrow.text = "ЭКИПИРОВКА" if compact else "ЭКИПИРОВКА  /  МАГАЗИН"
	_heading_title.text = "Магазин" if compact else "Выберите свой стиль"
	_heading_title.add_theme_font_size_override("font_size", 22 if compact else 27)
	if _back != null:
		_back.custom_minimum_size.x = 76 if compact else 100
	_stage_controls.position = Vector2(10, 12) if compact else Vector2(16, 16)
	_stage_controls.vertical = not compact
	_stage_caption.visible = not compact
	for button: Button in _view_buttons + [_compare_button]:
		button.custom_minimum_size.x = 90 if compact else 112
		button.add_theme_font_size_override("font_size", 13 if compact else 14)
	_stage_controls.size = Vector2.ZERO
	_compare_root.offset_left = 8 if compact else 145
	_compare_root.offset_top = 58 if compact else 18
	_row_grid.columns = 2 if _layout.vertical else 4
	_actions.vertical = true
	_review_actions.vertical = true
	_stage.custom_minimum_size.y = clampf(size.y - 384.0, 230.0, 400.0) if not _layout.vertical else 260.0
	if _compare_mode and _profile != null:
		_update_preview()
	_link_actions()


func _link_actions() -> void:
	var selected: Control = _rows[_selection]
	var first := _goal_action if _action.disabled and _goal_action.visible else _action
	if _review_actions.visible:
		first = _cancel_buy
	elif first.disabled:
		first = _view_buttons[1]
	var cards: Array = _rows.values()
	var columns := _row_grid.columns
	for i in cards.size():
		var row: Button = cards[i]
		row.focus_neighbor_left = row.get_path_to(cards[i - 1]) if i % columns > 0 else NodePath()
		if i % columns < columns - 1 and i + 1 < cards.size():
			row.focus_neighbor_right = row.get_path_to(cards[i + 1])
		else:
			row.focus_neighbor_right = row.get_path_to(first) if not _layout.vertical and not first.disabled else NodePath()
		if i >= columns:
			row.focus_neighbor_top = row.get_path_to(cards[i - columns])
		elif size.x < 520.0 and i % columns == 0:
			row.focus_neighbor_top = row.get_path_to(_view_buttons[0])
		else:
			row.focus_neighbor_top = row.get_path_to(_compare_button if _compare_button.visible else _view_buttons[1])
		row.focus_neighbor_bottom = row.get_path_to(cards[i + columns]) if i + columns < cards.size() else (row.get_path_to(first) if _layout.vertical and not first.disabled else NodePath())
	for button: Button in _view_buttons + [_compare_button]:
		button.focus_neighbor_left = NodePath()
		button.focus_neighbor_right = NodePath()
		button.focus_neighbor_top = NodePath()
		button.focus_neighbor_bottom = NodePath()
	if size.x < 520.0:
		_view_buttons[0].focus_neighbor_right = _view_buttons[0].get_path_to(_view_buttons[1])
		_view_buttons[1].focus_neighbor_left = _view_buttons[1].get_path_to(_view_buttons[0])
		_view_buttons[1].focus_neighbor_right = _view_buttons[1].get_path_to(_compare_button) if _compare_button.visible else NodePath()
		_compare_button.focus_neighbor_left = _compare_button.get_path_to(_view_buttons[1])
		for button: Button in _view_buttons + [_compare_button]:
			button.focus_neighbor_bottom = button.get_path_to(selected)
	else:
		_view_buttons[0].focus_neighbor_bottom = _view_buttons[0].get_path_to(_view_buttons[1])
		_view_buttons[1].focus_neighbor_top = _view_buttons[1].get_path_to(_view_buttons[0])
		_view_buttons[1].focus_neighbor_bottom = _view_buttons[1].get_path_to(_compare_button if _compare_button.visible else selected)
		_compare_button.focus_neighbor_top = _compare_button.get_path_to(_view_buttons[1])
		_compare_button.focus_neighbor_bottom = _compare_button.get_path_to(selected)
	_action.focus_neighbor_left = _action.get_path_to(selected) if not _layout.vertical else NodePath()
	_action.focus_neighbor_top = _action.get_path_to(selected) if _layout.vertical else NodePath()
	_action.focus_neighbor_bottom = _action.get_path_to(_goal_action) if _goal_action.visible else NodePath()
	_goal_action.focus_neighbor_left = _goal_action.get_path_to(selected) if not _layout.vertical else NodePath()
	_goal_action.focus_neighbor_top = _goal_action.get_path_to(_action) if not _action.disabled else _goal_action.get_path_to(selected)
	_cancel_buy.focus_neighbor_left = _cancel_buy.get_path_to(selected) if not _layout.vertical else NodePath()
	_cancel_buy.focus_neighbor_top = _cancel_buy.get_path_to(selected) if _layout.vertical else NodePath()
	_cancel_buy.focus_neighbor_bottom = _cancel_buy.get_path_to(_confirm_buy)
	_confirm_buy.focus_neighbor_top = _confirm_buy.get_path_to(_cancel_buy)


func _select(id: String) -> void:
	if id == _selection:
		return
	_selection = id
	_purchase_id = ""
	_refresh_goal()
	_show_selection()


func _set_view(index: int) -> void:
	if index == _view_index:
		return
	_view_index = index
	for i in _view_buttons.size():
		_view_buttons[i].set_pressed_no_signal(i == index)
	_update_preview()


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
	_balance.text = _points(_profile.balance) if _profile.load_error == OK else "—"
	var owned_count := 0
	for id: String in _rows:
		var status := "%d очк." % Progress.PRICES[id]
		if _profile.owns(id):
			owned_count += 1
			status = "Надето" if id == _profile.equipped else "Куплено"
		elif id == _profile.purchase_goal:
			status += " · Цель"
		if _profile.load_error != OK:
			status = "Нет данных"
		_card_status[id].text = status
		_rows[id].tooltip_text = "%s · %s" % [Progress.Palette.SCHEME_NAMES[id], status]
	_collection.text = "%d / %d открыто" % [owned_count, _rows.size()] if _profile.load_error == OK else "Нет данных"
	_refresh_goal()
	_show_selection()


func _refresh_goal() -> void:
	var id := _profile.purchase_goal
	_goal_card.visible = id != "" and id != _selection and _profile.load_error == OK
	if id == "" or _profile.load_error != OK:
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
	_compare_button.visible = _selection != _profile.equipped and _profile.load_error == OK
	if not _compare_button.visible:
		_compare_mode = false
	_compare_button.set_pressed_no_signal(_compare_mode)
	_update_preview()
	_note.text = ""
	var owned := _profile.owns(_selection)
	_status.text = "НАДЕТО" if _selection == _profile.equipped else ("В КОЛЛЕКЦИИ" if owned else "НОВЫЙ КОМПЛЕКТ")
	_status.add_theme_color_override("font_color", Style.MINT if owned else Style.AMBER)
	_price_card.visible = not owned
	if not owned:
		var price: int = Progress.PRICES[_selection]
		var remaining := _profile.remaining(_selection)
		_price_value.text = _points(price)
		_price_caption.text = "%d / %d очк. · Не хватает %d" % [mini(_profile.balance, price), price, remaining] if remaining > 0 else "Доступно для покупки"
		_price_bar.value = minf(float(_profile.balance) / float(maxi(price, 1)), 1.0)
	var reviewing := _purchase_id != ""
	set_process_input(reviewing)
	_actions.visible = not reviewing
	_review_actions.visible = reviewing
	_review_card.visible = reviewing and _profile.load_error == OK
	_price_card.visible = not owned and not reviewing
	_action.disabled = false
	var goal := _profile.purchase_goal
	_goal_action.visible = not _profile.owns(_selection) and _profile.load_error == OK
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
			_note.text = "Очки за расцветки дают задания поселений, новые страницы альбома, обзор с вышек и ремонт по пути."
	elif _profile.owns(_selection):
		_action.text = "Надеть"
	else:
		var price: int = Progress.PRICES[_selection]
		_action.text = "Купить за %d" % price
		var remaining := _profile.remaining(_selection)
		_action.disabled = remaining > 0
		if _action.disabled:
			_note.text = "Очки дают за задания, новые страницы альбома, обзор с вышек и вершин и ремонт по пути."
		else:
			_note.text = "После покупки комплект сразу наденется."
	if reviewing:
		var price: int = Progress.PRICES[_purchase_id]
		_confirm_buy.disabled = _action.disabled or _profile.owns(_purchase_id) or _profile.load_error != OK
		_review_title.text = "«%s»  ·  %s" % [Progress.Palette.SCHEME_NAMES[_purchase_id], _points(price)]
		_confirm_buy.text = "Купить и надеть · %s" % _points(price)
		if _confirm_buy.disabled:
			_review_balance.text = "Текущий баланс: %s" % _points(_profile.balance)
			_note.text = "Покупка недоступна. Отмените и проверьте комплект."
		else:
			_review_balance.text = "Баланс: %s  →  %s" % [_points(_profile.balance), _points(_profile.balance - price)]
			_note.text = "После покупки комплект сразу наденется."
			var other_goal := _profile.purchase_goal
			if other_goal != "" and other_goal != _purchase_id and _profile.balance - price < int(Progress.PRICES[other_goal]):
				_note.text += " На «%s» потребуется ещё %s." % [Progress.Palette.SCHEME_NAMES[other_goal], _points(int(Progress.PRICES[other_goal]) - (_profile.balance - price))]
	if _profile.load_error != OK:
		_action.disabled = true
		_action.text = "Недоступно"
		_status.text = "НЕТ ДАННЫХ"
		_status.add_theme_color_override("font_color", Style.RED)
		_price_card.hide()
		_note.text = "Не удалось загрузить прогресс магазина."
	_link_actions()


func _set_compare(on: bool) -> void:
	_compare_mode = on
	_update_preview()


func _portrait_crop(texture: Texture2D) -> Texture2D:
	if texture == null:
		return null
	var crop := AtlasTexture.new()
	crop.atlas = texture
	var extent := texture.get_size()
	crop.region = Rect2(extent * Vector2(0.2, 0.09), extent * Vector2(0.6, 0.86))
	return crop


func _update_preview() -> void:
	_preview.visible = not _compare_mode
	_compare_root.visible = _compare_mode
	_compare_button.text = "Закрыть" if _compare_mode else "Сравнить"
	if _compare_mode:
		var ids := [_profile.equipped, _selection]
		for i in 2:
			var variants: Array = _portraits.get(ids[i], [])
			var texture: Texture2D = variants[_view_index] if variants.size() > _view_index else _previews.get(ids[i])
			_compare_images[i].texture = _portrait_crop(texture)
			_compare_labels[i].text = ("Надето" if i == 0 else "Выбрано") + ("\n" if size.x < 520.0 else " · ") + Progress.Palette.SCHEME_NAMES[ids[i]]
	var portraits: Array = _portraits.get(_selection, [])
	var preview: Texture2D = portraits[_view_index] if portraits.size() > _view_index else _previews.get(_selection)
	if _preview.texture != preview:
		_preview.texture = preview
		if preview != null and DisplayServer.get_name() != "headless":
			if _preview_tween != null and _preview_tween.is_valid():
				_preview_tween.kill()
			_preview.modulate.a = 0.72
			_preview_tween = create_tween()
			_preview_tween.tween_property(_preview, "modulate:a", 1.0, 0.16)

func _points(value: int) -> String:
	var last_two := value % 100
	var last := value % 10
	var word := "очков"
	if last_two < 11 or last_two > 14:
		if last == 1:
			word = "очко"
		elif last >= 2 and last <= 4:
			word = "очка"
	return "%d %s" % [value, word]


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
		if _compare_mode:
			_compare_button.button_pressed = false
			_compare_button.grab_focus()
			return true
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
		# 20.11: купленный комплект сразу надевается (одно действие вместо двух); если запись не удалась — он в коллекции
		var worn := _profile.equip(id) == OK
		_rows[id].grab_focus()
		_note.text = ("«%s» куплен и надет." if worn else "«%s» добавлен в коллекцию. Нажмите «Надеть», чтобы применить.") % _name.text
		Style.pulse(_status, Style.MINT)
		sound_requested.emit(&"confirm")
	else:
		_show_selection()
		_action.grab_focus()
		_note.text = "Покупка не сохранена. Очки сохранены на счёте."
		sound_requested.emit(&"error_deny")
