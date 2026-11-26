extends CenterContainer
## Общий каталог для главного меню и библиотеки. Данные только из WorldTemplate.
signal type_requested(id: String)
signal closed
signal unavailable_requested

var _list: VBoxContainer
var _scroll: ScrollContainer
var _selected: Button
var _focus_target: Button
var _rows: Array[Button] = []
var _notice: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = &"MenuGlass"
	panel.custom_minimum_size = Vector2(620, 540)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Выберите путешествие"
	title.theme_type_variation = &"TitleLabel"
	box.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Каждый тип предлагает свой характер мира"
	subtitle.theme_type_variation = &"MenuFootnote"
	box.add_child(subtitle)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 5)
	_scroll.add_child(_list)
	_notice = Label.new()
	_notice.text = " "
	_notice.theme_type_variation = &"MenuFootnote"
	box.add_child(_notice)
	var close_button := Button.new()
	close_button.text = "← Назад"
	close_button.custom_minimum_size.y = 44
	close_button.pressed.connect(func() -> void: closed.emit())
	box.add_child(close_button)


func populate(types: Array[Dictionary], selected_id: String, focus_id := "") -> void:
	_scroll.scroll_vertical = 0
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_rows.clear()
	_selected = null
	_focus_target = null
	_notice.text = " "
	var future_heading_added := false
	for available in [true, false]:
		for item: Dictionary in types:
			if bool(item.get("available", false)) != available:
				continue
			if not available and not future_heading_added:
				var heading := Label.new()
				heading.text = "В РАЗРАБОТКЕ"
				heading.theme_type_variation = &"SectionLabel"
				_list.add_child(heading)
				future_heading_added = true
			var id := str(item.id)
			var selected: bool = bool(available) and id == selected_id
			var button := Button.new()
			button.theme_type_variation = &"ListRow"
			button.set_meta(&"ui_sound_custom", true)
			button.custom_minimum_size.y = 60
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.add_theme_font_size_override("font_size", 16)
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			button.text = ("✓  " if selected else "    ") + str(item.title)
			var description := str(item.get("description", "")) if available else "В разработке"
			if not description.is_empty():
				button.text += "\n  " + description
			button.tooltip_text = description
			button.pressed.connect(_choose.bind(id, available))
			button.focus_entered.connect(_ensure_visible.bind(button))
			_list.add_child(button)
			_rows.append(button)
			if selected: _selected = button
			if id == focus_id: _focus_target = button


func focus_selected() -> void:
	var target: Button = _focus_target if _focus_target != null else (_selected if _selected != null else (_rows[0] if not _rows.is_empty() else null))
	if target != null:
		target.grab_focus()
		_settle_focus.call_deferred(target)


func _settle_focus(button: Button) -> void:
	await get_tree().process_frame
	if is_instance_valid(button) and visible and button.has_focus() and _scroll.is_ancestor_of(button):
		_scroll.scroll_vertical = 0
		_scroll.ensure_control_visible(button)


func _ensure_visible(button: Button) -> void:
	if is_instance_valid(button) and _scroll.is_ancestor_of(button):
		_scroll.ensure_control_visible(button)


func _choose(id: String, available: bool) -> void:
	if not available:
		_notice.text = "Этот тип путешествия пока в разработке."
		unavailable_requested.emit()
		return
	type_requested.emit(id)
