extends PanelContainer

signal closed
signal sound_requested(kind: StringName)

const Progress := preload("res://scripts/game/shop_progress.gd")
const Style := preload("res://scripts/ui/hud_style.gd")
const PREVIEW_DIR := "res://resources/shop/"
const CANVAS := Color("#101820")
const SURFACE := Color("#1c2932")
const LINE := Color("#51616b")
const ACCENT := Color("#e9c78c")
## По категориям (Progress.Category): кнопка, подпись над названием
const CATEGORY_TITLES := ["Расцветки", "Шины", "Грипсы", "Педали", "Шлемы"]
const DETAIL_TITLES := ["РАСЦВЕТКА  /  ВЕЛОСИПЕД И РАЙДЕР", "ШИНЫ  /  ПАРА", "ГРИПСЫ  /  ПАРА", "ПЕДАЛИ  /  ПАРА", "ШЛЕМ  /  РАЙДЕР"]
## 27.11: слова для комплекта, пары (шины, грипсы, педали) и шлема — в одном месте, а не тернарниками по коду
const WORDS := {
	scheme = {worn = "Надето", worn_caps = "НАДЕТО", wear = "Надеть", new = "НОВЫЙ КОМПЛЕКТ",
		after = "После покупки комплект сразу наденется.", done = "Комплект надет на велосипед и райдера.",
		bought = "«%s» куплен и надет.", confirm = "Купить и надеть · %s"},
	pair = {worn = "Установлены", worn_caps = "УСТАНОВЛЕНЫ", wear = "Установить", new = "НОВАЯ ПАРА",
		after = "Пара установится сразу после покупки.", done = "Пара установлена.",
		bought = "Пара «%s» куплена и установлена.", confirm = "Купить и установить · %s"},
	helmet = {worn = "Надет", worn_caps = "НАДЕТ", wear = "Надеть", new = "НОВЫЙ ШЛЕМ",
		after = "Шлем наденется сразу после покупки.", done = "Шлем надет на райдера.",
		bought = "Шлем «%s» куплен и надет.", confirm = "Купить и надеть · %s"},
}
const HELMET_NOTE := "Цвет шлема задаёт расцветка."
const SPECIAL_TITLE := "РАСЦВЕТКА  /  ОСОБАЯ СЕРИЯ" # расцветки с особой отделкой (BikePalette.FINISHES)

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
var _category_buttons: Array[Button] = []
var _owned_filter: Button
var _detail_category: Label
var _description: Label
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
var _preview_missing: Label
var _stage_content: Control
var _fitting: SubViewportContainer
var _fitting_button: Button
var _fitting_reset: Button
var _fitting_apply: Button
var _fitting_zoom: Button
var _fitting_items: Array = []
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
var _card_missing := {}
var _card_status := {}
var _portrait_queue: Array[String] = []
var _full_portraits := {}
var _loaded_category := -1
var _portrait_job_id := ""
var _portrait_job_path := ""
var _portrait_generation := 0
var _portrait_job_generation := 0


func _ready() -> void:
	theme = preload("res://resources/ui_theme.tres")
	var panel_background := Color(0.045, 0.065, 0.10, 0.80) if show_back else Color.TRANSPARENT
	add_theme_stylebox_override("panel", _flat_box(panel_background, Color.TRANSPARENT, 0, Vector2(24, 18)))
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
	# 27.11: пять категорий не помещаются в узкой витрине одной строкой — переносятся на вторую
	var categories := HFlowContainer.new()
	categories.add_theme_constant_override("h_separation", 8)
	categories.add_theme_constant_override("v_separation", 8)
	column.add_child(categories)
	var category_group := ButtonGroup.new()
	for index in Progress.DEFAULT_ITEMS.size():
		var button := Button.new()
		button.text = CATEGORY_TITLES[index]
		button.custom_minimum_size.y = 36
		button.toggle_mode = true
		button.button_group = category_group
		button.add_theme_stylebox_override("normal", _flat_box(SURFACE, LINE, 4, Vector2(12, 6)))
		button.add_theme_stylebox_override("hover", _flat_box(Color("#354651"), LINE, 8, Vector2(12, 6)))
		button.add_theme_stylebox_override("pressed", _flat_box(ACCENT, ACCENT, 4, Vector2(12, 6)))
		button.add_theme_stylebox_override("hover_pressed", _flat_box(Color("#f4dab0"), ACCENT, 4, Vector2(12, 6)))
		button.add_theme_color_override("font_pressed_color", CANVAS)
		button.add_theme_color_override("font_hover_pressed_color", CANVAS)
		button.pressed.connect(_select_category.bind(index))
		categories.add_child(button)
		_category_buttons.append(button)
	_owned_filter = Button.new()
	_owned_filter.text = "Только купленное"
	_owned_filter.toggle_mode = true
	_owned_filter.tooltip_text = "Показать вещи из вашей коллекции"
	_owned_filter.toggled.connect(func(on: bool) -> void:
		if on and _profile != null and not _profile.owns(_selection):
			_select(_profile.equipped_for(_selection))
		else:
			_refresh())
	categories.add_child(_owned_filter)
	for index in _category_buttons.size() - 1:
		var left := _category_buttons[index]
		var right := _category_buttons[index + 1]
		left.focus_neighbor_right = left.get_path_to(right)
		right.focus_neighbor_left = right.get_path_to(left)
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
	var fitting_controls := HFlowContainer.new()
	fitting_controls.add_theme_constant_override("h_separation", 8)
	fitting_controls.add_theme_constant_override("v_separation", 6)
	showcase.add_child(fitting_controls)
	_fitting_button = Button.new()
	_fitting_button.text = "Примерочная"
	_fitting_button.toggle_mode = true
	_fitting_button.tooltip_text = "Примеряйте сочетания без покупки и изменения экипировки"
	_fitting_button.toggled.connect(_toggle_fitting)
	fitting_controls.add_child(_fitting_button)
	_fitting_zoom = Button.new()
	_fitting_zoom.text = "Приблизить деталь"
	_fitting_zoom.toggle_mode = true
	_fitting_zoom.hide()
	_fitting_zoom.toggled.connect(func(_on: bool) -> void: _update_fitting())
	fitting_controls.add_child(_fitting_zoom)
	_fitting_reset = Button.new()
	_fitting_reset.text = "Мой образ"
	_fitting_reset.tooltip_text = "Вернуть в примерку надетые вещи"
	_fitting_reset.hide()
	_fitting_reset.pressed.connect(_reset_fitting)
	fitting_controls.add_child(_fitting_reset)
	_fitting_apply = Button.new()
	_fitting_apply.text = "Надеть купленное"
	_fitting_apply.tooltip_text = "Применить купленные вещи из примерки; остальные останутся только в примерке."
	_fitting_apply.hide()
	_fitting_apply.pressed.connect(_apply_fitting)
	fitting_controls.add_child(_fitting_apply)
	_stage = PanelContainer.new()
	_stage.add_theme_stylebox_override("panel", _flat_box(Color(0.11, 0.16, 0.20, 0.88), Color(0.65, 0.72, 0.74, 0.28), 12, Vector2.ZERO))
	showcase.add_child(_stage)
	var stage_content := Control.new()
	_stage_content = stage_content
	stage_content.clip_contents = true
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
	_preview_missing = _label(stage_content, "Изображение недоступно", 16, Style.CREAM)
	_preview_missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_missing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preview_missing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_missing.hide()
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
		var caption := _label(side, "", 16, Style.CREAM)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_compare_labels.append(caption)
	_stage_controls = BoxContainer.new()
	_stage_controls.vertical = true
	_stage_controls.position = Vector2(16, 16)
	_stage_controls.add_theme_constant_override("separation", 6)
	stage_content.add_child(_stage_controls)
	_stage_caption = _label(_stage_controls, "РАКУРС", 14, Style.CREAM)
	var views := ButtonGroup.new()
	for index in 2:
		var view := Button.new()
		view.text = ["Сбоку", "Под углом"][index]
		view.custom_minimum_size = Vector2(112, 36)
		view.toggle_mode = true
		view.button_group = views
		view.add_theme_font_size_override("font_size", 14)
		view.add_theme_stylebox_override("normal", _flat_box(Color("#293944"), Color.TRANSPARENT, 6, Vector2(10, 5)))
		view.add_theme_stylebox_override("hover", _flat_box(Color("#415460"), Color.TRANSPARENT, 6, Vector2(10, 5)))
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
	_compare_button.add_theme_stylebox_override("normal", _flat_box(Color("#293944"), Color.TRANSPARENT, 6, Vector2(10, 5)))
	_compare_button.add_theme_stylebox_override("hover", _flat_box(Color("#415460"), Color.TRANSPARENT, 6, Vector2(10, 5)))
	_compare_button.add_theme_stylebox_override("pressed", _flat_box(Color("#e9c78c"), Color.TRANSPARENT, 3, Vector2(10, 5)))
	_compare_button.add_theme_stylebox_override("hover_pressed", _flat_box(Color("#f4dab0"), Color.TRANSPARENT, 3, Vector2(10, 5)))
	_compare_button.add_theme_color_override("font_pressed_color", Color("#172b25"))
	_compare_button.add_theme_color_override("font_hover_pressed_color", Color("#172b25"))
	_compare_button.toggled.connect(_set_compare)
	_stage_controls.add_child(_compare_button)
	var collection_header := HBoxContainer.new()
	showcase.add_child(collection_header)
	_label(collection_header, "КОЛЛЕКЦИЯ", 14, ACCENT).size_flags_horizontal = SIZE_EXPAND_FILL
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
		row.add_theme_stylebox_override("normal", _flat_box(SURFACE, Color.TRANSPARENT, 10, Vector2(6, 6)))
		row.add_theme_stylebox_override("hover", _flat_box(Color("#354651"), LINE, 10, Vector2(6, 6)))
		row.add_theme_stylebox_override("pressed", _flat_box(Color("#354651"), ACCENT, 10, Vector2(6, 6)))
		row.add_theme_stylebox_override("hover_pressed", _flat_box(Color("#42535e"), ACCENT, 10, Vector2(6, 6)))
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
		tile_bg.color = Color(0.22, 0.30, 0.34, 0.72)
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
		var missing := _label(portrait_stage, "Нет изображения", 13, Style.CREAM)
		missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		missing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		missing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_card_missing[id] = missing
		var title_row := HBoxContainer.new()
		title_row.mouse_filter = MOUSE_FILTER_IGNORE
		title_row.add_theme_constant_override("separation", 4)
		content.add_child(title_row)
		var title := _label(title_row, Progress.item_name(id), 16, Style.CREAM)
		title.size_flags_horizontal = SIZE_EXPAND_FILL
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var colors: Array
		var stock := Progress.Palette.colors()
		if Progress.category_for(id) == Progress.Category.HELMET:
			colors = [] # шлем — форма, цвет берётся из расцветки
		elif Progress.category_for(id) == Progress.Category.PEDALS:
			colors = [stock[Progress.Palette.BLACK]] if id == Progress.DEFAULT_PEDALS else Progress.Palette.pedal_colors(id)
		elif Progress.category_for(id) == Progress.Category.GRIPS:
			colors = [stock[Progress.Palette.RUBBER]] if id == Progress.DEFAULT_GRIPS else Progress.Palette.grip_colors(id)
		elif Progress.category_for(id) == Progress.Category.TIRES:
			colors = Progress.Palette.TIRE_COLORS.get(id, [stock[Progress.Palette.RUBBER], stock[Progress.Palette.SIDEWALL]])
		else:
			var scheme: Array = Progress.Palette.SCHEMES[id]
			colors = [Color(scheme[0]), Color(scheme[2])]
			if Progress.Palette.FINISHES.has(id):
				colors.append(Color(Progress.Palette.FINISHES[id].flip, 1.0)) # третий цвет — перелив особой серии
		for color: Color in colors:
			var swatch := ColorRect.new()
			swatch.color = color
			swatch.custom_minimum_size = Vector2(10, 10)
			swatch.size_flags_vertical = SIZE_SHRINK_CENTER
			swatch.mouse_filter = MOUSE_FILTER_IGNORE
			title_row.add_child(swatch)
		_card_status[id] = _label(content, "", 15, Style.MUTED)
	var display := PanelContainer.new()
	display.size_flags_horizontal = SIZE_EXPAND_FILL
	display.size_flags_stretch_ratio = 1.0
	display.size_flags_vertical = SIZE_SHRINK_BEGIN
	display.add_theme_stylebox_override("panel", _flat_box(SURFACE, LINE, 12, Vector2(22, 20)))
	_layout.add_child(display)
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 10)
	display.add_child(detail)
	_detail_category = _label(detail, "", 12, ACCENT)
	_name = _label(detail, "", 34, Style.CREAM)
	_status = _label(detail, "", 14, Style.MINT)
	_description = _label(detail, "", 16, Style.MUTED)
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(HSeparator.new())
	_price_card = PanelContainer.new()
	_price_card.add_theme_stylebox_override("panel", _flat_box(Color("#283944"), Color.TRANSPARENT, 10, Vector2(12, 12)))
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
	_sync_category()
	set_process_input(false)
	set_process(false)
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
	_review_card.add_theme_stylebox_override("panel", _flat_box(Color("#283944"), LINE, 10, Vector2(12, 12)))
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


static func _portrait_paths(id: String) -> PackedStringArray:
	return [PREVIEW_DIR + id + "_side.png", PREVIEW_DIR + id + "_angle.png", PREVIEW_DIR + id + ".jpg"]


## При запуске из терминала новые PNG могут ещё не иметь локального .ctex.
## В экспорте исходников нет: там всегда используется обычная загрузка ресурсов.
static func _portrait_import_missing(path: String) -> bool:
	if not OS.has_feature("editor") or not FileAccess.file_exists(path):
		return false
	var metadata := ConfigFile.new()
	if not FileAccess.file_exists(path + ".import") or metadata.load(path + ".import") != OK:
		return true
	var imported: String = metadata.get_value("remap", "path", "")
	return imported.is_empty() or not FileAccess.file_exists(imported)


## Из фоновой загрузки, иначе обычной; до импорта — исходное изображение.
static func _texture(path: String) -> Texture2D:
	if _portrait_import_missing(path):
		var image := Image.new()
		var bytes := FileAccess.get_file_as_bytes(path)
		var result := image.load_png_from_buffer(bytes) if path.ends_with(".png") else image.load_jpg_from_buffer(bytes)
		return ImageTexture.create_from_image(image) if result == OK else null
	var status := ResourceLoader.load_threaded_get_status(path)
	if status in [ResourceLoader.THREAD_LOAD_IN_PROGRESS, ResourceLoader.THREAD_LOAD_LOADED]:
		return ResourceLoader.load_threaded_get(path) as Texture2D
	return load(path) as Texture2D if ResourceLoader.exists(path) else null


func open() -> void:
	_purchase_id = ""
	_compare_mode = false
	_owned_filter.set_pressed_no_signal(false)
	if _fitting_button.button_pressed:
		_fitting_button.button_pressed = false
	var reward_result := 0
	if _profile != null:
		_selection = _profile.purchase_goal if _profile.purchase_goal != "" else _profile.equipped
		reward_result = _profile.retry_rewards()
	_activate_portrait_category(Progress.category_for(_selection))
	_refresh()
	if reward_result < 0 and _profile.load_error == OK:
		_note.text = "Не удалось записать очки за задания. Откройте магазин ещё раз, чтобы повторить."
	_category_buttons[Progress.category_for(_selection)].grab_focus()
	_scroll.set_deferred("scroll_vertical", 0)


## Карточки готовятся постепенно; второй ракурс загружается только для выбранного товара.
func _activate_portrait_category(category: int) -> void:
	if _loaded_category == category:
		_load_portrait(_selection, true)
		_portrait_queue.erase(_selection)
		set_process(not _portrait_queue.is_empty() or not _portrait_job_path.is_empty())
		return
	_clear_portraits()
	_loaded_category = category
	for id: String in Progress.PRICES:
		if Progress.category_for(id) == category:
			_portrait_queue.append(id)
			_card_missing[id].text = "Подготавливаем…"
			_card_missing[id].show()
	_load_portrait(_selection, true)
	_portrait_queue.erase(_selection)
	if _profile != null:
		var equipped: String = _profile.equipped_in(category)
		_load_portrait(equipped, true)
		_portrait_queue.erase(equipped)
	set_process(not _portrait_queue.is_empty() or not _portrait_job_path.is_empty())


func _load_portrait(id: String, full := false) -> void:
	if not _rows.has(id):
		return
	if id == _portrait_job_id:
		_portrait_job_generation = _portrait_generation
		return
	var paths := _portrait_paths(id)
	if not _portraits.has(id):
		var side := _texture(paths[0])
		_store_portrait_side(id, side)
	if full and not _full_portraits.has(id):
		_portraits[id][1] = _texture(paths[1])
		_full_portraits[id] = true


func _store_portrait_side(id: String, side: Texture2D) -> void:
	var fallback := _texture(_portrait_paths(id)[2]) if side == null else null
	_previews[id] = fallback
	_portraits[id] = [side, null]
	_card_images[id].texture = _portrait_crop(side if side != null else fallback, Progress.category_for(id) != Progress.Category.SCHEME)
	_card_missing[id].text = "Нет изображения"
	_card_missing[id].visible = _card_images[id].texture == null


func _clear_portraits() -> void:
	_portrait_generation += 1
	set_process(not _portrait_job_path.is_empty())
	_portrait_queue.clear()
	for id: String in _portraits:
		_card_images[id].texture = null
		_card_missing[id].text = "Нет изображения"
		_card_missing[id].show()
	_portraits.clear()
	_previews.clear()
	_full_portraits.clear()
	_loaded_category = -1
	_preview.texture = null
	for image: TextureRect in _compare_images:
		image.texture = null


func _process(_delta: float) -> void:
	if not _portrait_job_path.is_empty():
		var status := ResourceLoader.load_threaded_get_status(_portrait_job_path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return
		var texture := ResourceLoader.load_threaded_get(_portrait_job_path) as Texture2D if status == ResourceLoader.THREAD_LOAD_LOADED else _texture(_portrait_job_path)
		var id := _portrait_job_id
		var current := _portrait_job_generation == _portrait_generation and is_visible_in_tree()
		_portrait_job_path = ""
		_portrait_job_id = ""
		if current and not _portraits.has(id):
			_store_portrait_side(id, texture)
			if id == _selection or (_profile != null and id == _profile.equipped_for(_selection)):
				_load_portrait(id, true)
				_update_preview()
	if not is_visible_in_tree() or _portrait_queue.is_empty():
		set_process(false)
		return
	var id: String = _portrait_queue.pop_front()
	if _portraits.has(id):
		return
	var path: String = _portrait_paths(id)[0]
	if _portrait_import_missing(path) or not ResourceLoader.exists(path):
		_load_portrait(id)
		return
	if ResourceLoader.load_threaded_request(path) == OK:
		_portrait_job_id = id
		_portrait_job_path = path
		_portrait_job_generation = _portrait_generation
	else:
		_load_portrait(id)


func _exit_tree() -> void:
	if not _portrait_job_path.is_empty():
		var status := ResourceLoader.load_threaded_get_status(_portrait_job_path)
		if status in [ResourceLoader.THREAD_LOAD_IN_PROGRESS, ResourceLoader.THREAD_LOAD_LOADED]:
			ResourceLoader.load_threaded_get(_portrait_job_path)
		_portrait_job_path = ""


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
	for button in _category_buttons:
		button.add_theme_font_size_override("font_size", 13 if compact else 16)
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
	_preview.offset_top = 58 if compact else 0
	_preview_missing.offset_top = _preview.offset_top
	if is_instance_valid(_fitting):
		_fitting.offset_top = _preview.offset_top
	_compare_root.offset_left = 8 if compact else 145
	_compare_root.offset_top = 58 if compact else 18
	_row_grid.columns = 2 if _layout.vertical else 4
	_actions.vertical = true
	_review_actions.vertical = true
	_stage.custom_minimum_size.y = clampf(size.y - 424.0, 220.0, 360.0) if not _layout.vertical else 260.0
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
	var cards: Array = _rows.values().filter(func(row: Button) -> bool: return row.visible)
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
	var category := _category_buttons[Progress.category_for(_selection)]
	_view_buttons[0].focus_neighbor_top = _view_buttons[0].get_path_to(_fitting_button)
	_fitting_button.focus_neighbor_top = _fitting_button.get_path_to(category)
	_fitting_button.focus_neighbor_bottom = _fitting_button.get_path_to(_view_buttons[0])
	_fitting_button.focus_neighbor_right = _fitting_button.get_path_to(_fitting_zoom) if _fitting_zoom.visible else NodePath()
	_fitting_zoom.focus_neighbor_left = _fitting_zoom.get_path_to(_fitting_button)
	_fitting_zoom.focus_neighbor_right = _fitting_zoom.get_path_to(_fitting_reset)
	_fitting_zoom.focus_neighbor_bottom = _fitting_zoom.get_path_to(_view_buttons[0])
	_fitting_reset.focus_neighbor_left = _fitting_reset.get_path_to(_fitting_zoom)
	_fitting_reset.focus_neighbor_right = _fitting_reset.get_path_to(_fitting_apply) if _fitting_apply.visible and not _fitting_apply.disabled else NodePath()
	_fitting_reset.focus_neighbor_bottom = _fitting_reset.get_path_to(_view_buttons[0])
	_fitting_apply.focus_neighbor_left = _fitting_apply.get_path_to(_fitting_reset)
	_fitting_apply.focus_neighbor_bottom = _fitting_apply.get_path_to(_view_buttons[0])
	for button: Button in _category_buttons:
		button.focus_neighbor_bottom = button.get_path_to(_fitting_button)
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
	_activate_portrait_category(Progress.category_for(id))
	if _fitting_button.button_pressed and _fitting_items.size() == Progress.DEFAULT_ITEMS.size():
		_fitting_items[Progress.category_for(id)] = id
		_compare_mode = false
		_compare_button.set_pressed_no_signal(false)
	_purchase_id = ""
	_refresh()


func _select_category(category: Progress.Category) -> void:
	if _profile == null:
		return
	var id: String = _fitting_items[category] if _fitting_button.button_pressed and _fitting_items.size() == Progress.DEFAULT_ITEMS.size() else _profile.equipped_in(category)
	if _owned_filter.button_pressed and not _profile.owns(id):
		id = _profile.equipped_in(category)
	_compare_mode = false
	_compare_button.set_pressed_no_signal(false)
	if id == _selection:
		_refresh()
	else:
		_select(id)
	_category_buttons[category].grab_focus()
	_scroll.set_deferred("scroll_vertical", 0)


func _sync_category() -> void:
	var category := Progress.category_for(_selection)
	for i in _category_buttons.size():
		_category_buttons[i].set_pressed_no_signal(i == category)
	for id: String in _rows:
		_rows[id].visible = Progress.category_for(id) == category and (not _owned_filter.button_pressed or _profile == null or _profile.owns(id))


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
		if _fitting_button.button_pressed:
			_fitting_button.button_pressed = false
		_clear_portraits()
		set_process_input(false)


func _input(event: InputEvent) -> void:
	# The second half of a double-click on Buy may land on the newly shown Confirm button.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and event.double_click and _confirm_buy.get_global_rect().has_point(event.position):
		get_viewport().set_input_as_handled()


func _refresh() -> void:
	if _profile == null or not is_visible_in_tree():
		return
	_sync_category()
	_balance.text = _points(_profile.balance) if _profile.load_error == OK else "—"
	var owned_count := 0
	var category_count := 0
	for id: String in _rows:
		if not _rows[id].visible:
			continue
		category_count += 1
		var status := "%d очк." % Progress.PRICES[id]
		if _profile.owns(id):
			owned_count += 1
			status = _words(id).worn if id == _profile.equipped_for(id) else "Куплено"
		elif id == _profile.purchase_goal:
			status += " · Цель"
		if _profile.load_error != OK:
			status = "Нет данных"
		_card_status[id].text = status
		_rows[id].tooltip_text = "%s · %s" % [Progress.item_name(id), status]
	_collection.text = "%d / %d открыто" % [owned_count, category_count] if _profile.load_error == OK else "Нет данных"
	_refresh_goal()
	_show_selection()


func _refresh_goal() -> void:
	var id := _profile.purchase_goal
	_goal_card.visible = id != "" and id != _selection and _profile.load_error == OK
	if id == "" or _profile.load_error != OK:
		return
	var price: int = Progress.PRICES[id]
	var remaining := _profile.remaining(id)
	_goal_title.text = "Цель · " + Progress.item_name(id)
	_goal_bar.max_value = price
	_goal_bar.value = price - remaining
	_goal_status.text = "%d из %d очк. · Осталось %d" % [price - remaining, price, remaining] if remaining > 0 else "Можно купить · %d очк." % price


func _show_selection() -> void:
	for id: String in _rows:
		_rows[id].set_pressed_no_signal(id == _selection)
	var category := Progress.category_for(_selection)
	var words := _words(_selection)
	var equipped := _selection == _profile.equipped_for(_selection)
	_view_buttons[0].text = "Спереди" if category == Progress.Category.GRIPS else "Сбоку"
	_name.text = Progress.item_name(_selection)
	_detail_category.text = SPECIAL_TITLE if Progress.Palette.FINISHES.has(_selection) else DETAIL_TITLES[category]
	match category:
		Progress.Category.HELMET:
			_description.text = Progress.Helmets.DESCRIPTIONS[_selection] + " " + HELMET_NOTE
		Progress.Category.TIRES:
			_description.text = "Цвет передней и задней шин. На витрине показан базовый велосипед."
		Progress.Category.GRIPS:
			_description.text = "Цвет обеих рукояток руля. Грипсы можно подобрать в тон шинам."
		Progress.Category.PEDALS:
			_description.text = "Цвет обеих педалей. Можно подобрать в тон шинам и грипсам."
		_:
			_description.text = Progress.Palette.SCHEME_DESCRIPTIONS[_selection]
	_compare_button.visible = (not equipped or _fitting_button.button_pressed) and _profile.load_error == OK
	if not _compare_button.visible:
		_compare_mode = false
	_compare_button.set_pressed_no_signal(_compare_mode)
	_update_preview()
	_note.text = ""
	var owned := _profile.owns(_selection)
	_status.text = words.worn_caps if equipped else ("В КОЛЛЕКЦИИ" if owned else words.new)
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
	if equipped:
		_action.text = words.worn
		_action.disabled = true
		if _profile.needs_first_purchase() and _profile.balance == 0:
			_note.text = "Очки дают за задания поселений, новые страницы альбома, обзор с вышек и ремонт по пути."
	elif _profile.owns(_selection):
		_action.text = words.wear
	else:
		var price: int = Progress.PRICES[_selection]
		_action.text = "Купить за %d" % price
		var remaining := _profile.remaining(_selection)
		_action.disabled = remaining > 0
		if _action.disabled:
			_note.text = "Очки дают за задания, новые страницы альбома, обзор с вышек и вершин и ремонт по пути."
		else:
			_note.text = words.after
	if reviewing:
		var price: int = Progress.PRICES[_purchase_id]
		_confirm_buy.disabled = _action.disabled or _profile.owns(_purchase_id) or _profile.load_error != OK
		_review_title.text = "«%s»  ·  %s" % [Progress.item_name(_purchase_id), _points(price)]
		_confirm_buy.text = words.confirm % _points(price)
		if _confirm_buy.disabled:
			_review_balance.text = "Текущий баланс: %s" % _points(_profile.balance)
			_note.text = "Покупка недоступна. Отмените и проверьте комплект."
		else:
			_review_balance.text = "Баланс: %s  →  %s" % [_points(_profile.balance), _points(_profile.balance - price)]
			_note.text = words.after
			var other_goal := _profile.purchase_goal
			if other_goal != "" and other_goal != _purchase_id and _profile.balance - price < int(Progress.PRICES[other_goal]):
				_note.text += " На «%s» потребуется ещё %s." % [Progress.item_name(other_goal), _points(int(Progress.PRICES[other_goal]) - (_profile.balance - price))]
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
	if on:
		_scroll.scroll_vertical = 0


func _portrait_crop(texture: Texture2D, accessory := false) -> Texture2D:
	if texture == null:
		return null
	var crop := AtlasTexture.new()
	crop.atlas = texture
	var extent := texture.get_size()
	var inset := 0.09 if accessory else 0.2
	crop.region = Rect2(extent * Vector2(inset, 0.09), extent * Vector2(1.0 - inset * 2.0, 0.86))
	return crop


func _update_preview() -> void:
	var fitting := _fitting_button.button_pressed
	_preview.visible = not _compare_mode and not fitting
	_compare_root.visible = _compare_mode and not fitting
	if fitting:
		_view_buttons[0].text = "Сбоку"
		_update_fitting()
	_compare_button.text = ("Вернуть примерку" if fitting else "Закрыть") if _compare_mode else "Сравнить"
	if _compare_mode and not fitting:
		var accessory := Progress.category_for(_selection) != Progress.Category.SCHEME
		var ids := [_profile.equipped_for(_selection), _selection]
		for i in 2:
			var variants: Array = _portraits.get(ids[i], [])
			var texture: Texture2D = variants[_view_index] if variants.size() > _view_index else _previews.get(ids[i])
			_compare_images[i].texture = _portrait_crop(texture, accessory)
			_compare_labels[i].text = (_words(_selection).worn if i == 0 else "Выбрано") + ("\n" if size.x < 520.0 else " · ") + Progress.item_name(ids[i])
	var portraits: Array = _portraits.get(_selection, [])
	var preview: Texture2D = portraits[_view_index] if portraits.size() > _view_index else _previews.get(_selection)
	if preview == null:
		preview = _previews.get(_selection)
	_preview_missing.text = "Подготавливаем изображение…" if not _portraits.has(_selection) else "Изображение недоступно"
	_preview_missing.visible = preview == null and not fitting and not _compare_mode
	if _preview.texture != preview:
		_preview.texture = preview
		if preview != null and DisplayServer.get_name() != "headless" and not GameContext.scope.settings.reduce_ui_motion:
			if _preview_tween != null and _preview_tween.is_valid():
				_preview_tween.kill()
			_preview.modulate.a = 0.72
			_preview_tween = create_tween()
			_preview_tween.tween_property(_preview, "modulate:a", 1.0, 0.16)


func _toggle_fitting(on: bool) -> void:
	if on and _profile == null:
		_fitting_button.set_pressed_no_signal(false)
		return
	_fitting_zoom.visible = on
	_fitting_reset.visible = on
	_fitting_apply.visible = on
	if on:
		_compare_mode = false
		_compare_button.set_pressed_no_signal(false)
		_fitting_button.grab_focus()
		_scroll.set_deferred("scroll_vertical", 0)
		_fitting_items.clear()
		for category in Progress.DEFAULT_ITEMS.size():
			_fitting_items.append(_profile.equipped_in(category))
		_fitting_items[Progress.category_for(_selection)] = _selection
		_fitting = preload("res://scripts/ui/shop_fitting.gd").new()
		_fitting.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_fitting.offset_top = _preview.offset_top
		_stage_content.add_child(_fitting)
		_stage_content.move_child(_fitting, _preview.get_index() + 1)
		_update_fitting()
	else:
		_compare_mode = false
		_compare_button.set_pressed_no_signal(false)
		if is_instance_valid(_fitting):
			_stage_content.remove_child(_fitting)
			_fitting.queue_free()
		_fitting = null
		_fitting_items.clear()
		_fitting_zoom.set_pressed_no_signal(false)
	if _profile != null and is_visible_in_tree():
		_show_selection()
	else:
		_update_preview()


func _reset_fitting() -> void:
	if _profile == null or _fitting_items.is_empty():
		return
	_compare_mode = false
	_compare_button.set_pressed_no_signal(false)
	for category in Progress.DEFAULT_ITEMS.size():
		_fitting_items[category] = _profile.equipped_in(category)
	_select(_fitting_items[Progress.category_for(_selection)])
	_update_preview()


func _update_fitting() -> void:
	if not is_instance_valid(_fitting):
		return
	var items := _fitting_items
	if _compare_mode:
		items = []
		for category in Progress.DEFAULT_ITEMS.size():
			items.append(_profile.equipped_in(category))
	_fitting.apply_items(items)
	_fitting.set_view(_view_index, _fitting_zoom.button_pressed, Progress.category_for(_selection))
	_update_fitting_apply()


func _update_fitting_apply() -> void:
	if _profile == null or _fitting_items.size() != Progress.DEFAULT_ITEMS.size():
		_fitting_apply.disabled = true
		return
	var has_changes := false
	for category in _fitting_items.size():
		var id: String = _fitting_items[category]
		if _profile.owns(id) and id != _profile.equipped_in(category):
			has_changes = true
	_fitting_apply.disabled = not has_changes or _profile.load_error != OK
	_link_actions()


func _apply_fitting() -> void:
	if _profile == null or _fitting_items.size() != Progress.DEFAULT_ITEMS.size():
		return
	var items: Array = []
	var unowned := false
	for category in _fitting_items.size():
		var id: String = _fitting_items[category]
		if _profile.owns(id):
			items.append(id)
		else:
			items.append(_profile.equipped_in(category))
			unowned = true
	var err: Error = _profile.equip_set(items)
	if err == OK:
		_note.text = "Купленные вещи надеты. Остальные остаются в примерке." if unowned else "Образ надет."
		_update_fitting_apply()
	else:
		_note.text = "Не удалось сохранить образ. Попробуйте ещё раз."

static func _words(id: String) -> Dictionary:
	match Progress.category_for(id):
		Progress.Category.SCHEME: return WORDS.scheme
		Progress.Category.HELMET: return WORDS.helmet
		_: return WORDS.pair


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
			_note.text = _words(_selection).done
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
		if _fitting_button.button_pressed:
			_fitting_button.button_pressed = false
			_fitting_button.grab_focus()
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
	if _profile.buy(id, true) == OK:
		# 20.11: купленный комплект сразу надевается — одно действие и одна запись профиля
		_rows[id].grab_focus()
		_note.text = _words(id).bought % _name.text
		Style.pulse(_status, Style.MINT)
		sound_requested.emit(&"confirm")
	else:
		_show_selection()
		_action.grab_focus()
		_note.text = "Покупка не сохранена. Очки сохранены на счёте."
		sound_requested.emit(&"error_deny")
