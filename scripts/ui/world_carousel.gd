extends VBoxContainer
## Отображает готовые карточки. Переключение работает только с данными в памяти.

signal world_selected(seed_text: String)
signal play_requested
signal new_world_requested

const MAX_WORLDS := 8

@onready var _card: Control = $Card
@onready var _artwork: Control = $Card/CardContent/Artwork
@onready var _map: TextureRect = $Card/CardContent/Artwork/Art/Map
@onready var _placeholder: Label = $Card/CardContent/Artwork/Art/Placeholder
@onready var _name: Label = $Card/CardContent/WorldName
@onready var _summary: Label = $Card/CardContent/Summary
@onready var _previous: Button = $Strip/Previous
@onready var _next: Button = $Strip/Next
@onready var _cards: HBoxContainer = $Strip/Cards

var _entries: Array[Dictionary] = []
var _index := -1
var _start: Button
var _actions: Array[Button] = []
var _trail_lab: Button
var _fade: Tween


func setup(start_button: Button, actions: Array[Button], trail_lab: Button) -> void:
	_start = start_button
	_actions = actions
	_trail_lab = trail_lab
	_previous.pressed.connect(move.bind(-1))
	_next.pressed.connect(move.bind(1))
	_artwork.gui_input.connect(_card_input)


func set_entries(entries: Array[Dictionary], selected: String) -> void:
	_entries = entries
	_index = -1
	for child in _cards.get_children():
		_cards.remove_child(child)
		child.queue_free()
	for i in _entries.size():
		var entry := _entries[i]
		var button := _make_button(entry.seed, entry.texture)
		button.toggle_mode = true
		button.pressed.connect(_choose.bind(i))
		button.gui_input.connect(_thumbnail_input.bind(i))
	var add := _make_button("Новый мир", null)
	add.text = "+"
	add.pressed.connect(new_world_requested.emit)
	show_world(selected)


func show_world(seed_text: String, animate := false) -> void:
	for i in _entries.size():
		if _entries[i].seed == seed_text:
			_show_index(i, animate)
			return
	_show_index(0 if not _entries.is_empty() else -1, false)


func selected_index() -> int:
	return _index


func move(direction: int) -> void:
	if not _entries.is_empty():
		_choose(posmod(_index + direction, _entries.size()))


func move_focused(direction: int) -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	if focus == _start:
		move(direction)
		return true
	if focus == _previous or focus == _next or (focus != null and focus.get_parent() == _cards):
		var buttons := _strip_buttons()
		var i := buttons.find(focus)
		if i < 0:
			return false
		var next := posmod(i + direction, buttons.size())
		var target := buttons[next]
		target.grab_focus()
		if target.get_parent() == _cards and target.get_index() < _entries.size():
			_choose(target.get_index())
		return true
	return false


func _choose(index: int) -> void:
	if index != _index:
		_show_index(index, true)
		world_selected.emit(_entries[index].seed)
	else:
		(_cards.get_child(index) as Button).set_pressed_no_signal(true)


func _show_index(index: int, animate: bool) -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()
	var changed := _index != index
	_index = index
	var entry: Dictionary = _entries[index] if index >= 0 else {}
	_map.texture = entry.get("texture")
	_placeholder.visible = _map.texture == null
	_placeholder.text = entry.get("seed", "Новый мир")
	_name.visible = _map.texture != null
	_name.text = entry.get("seed", "Случайный мир")
	_summary.text = entry.get("summary", "Мир создастся при запуске, около минуты.")
	_previous.disabled = _entries.size() < 2
	_next.disabled = _previous.disabled
	for i in _entries.size():
		(_cards.get_child(i) as Button).set_pressed_no_signal(i == index)
	_card.modulate.a = 1.0
	if animate and changed:
		_card.modulate.a = 0.66
		_fade = create_tween()
		_fade.tween_property(_card, "modulate:a", 1.0, 0.15).set_trans(Tween.TRANS_SINE)
	_link_focus()


func _make_button(label: String, texture: Texture2D) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(34, 37)
	button.theme_type_variation = &"CarouselTab"
	button.tooltip_text = label
	button.accessibility_name = label
	if texture != null:
		button.icon = texture
		button.expand_icon = true
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		button.text = label.left(1).to_upper()
	_cards.add_child(button)
	return button


func _strip_buttons() -> Array[Button]:
	var buttons: Array[Button] = []
	if not _previous.disabled:
		buttons.append(_previous)
	for child: Button in _cards.get_children():
		buttons.append(child)
	if not _next.disabled:
		buttons.append(_next)
	return buttons


func _link_focus() -> void:
	if _start == null:
		return
	var cards := _strip_buttons()
	var selected: Control = _cards.get_child(maxi(_index, 0))
	_start.focus_neighbor_top = _start.get_path_to(selected)
	_start.focus_neighbor_bottom = _start.get_path_to(_actions[0])
	for button in cards:
		button.focus_neighbor_top = button.get_path_to(button)
		button.focus_neighbor_bottom = button.get_path_to(_start)
	for i in _actions.size():
		var button := _actions[i]
		button.focus_neighbor_top = button.get_path_to(_start)
		button.focus_neighbor_bottom = button.get_path_to(_trail_lab)
		button.focus_neighbor_left = button.get_path_to(_actions[posmod(i - 1, _actions.size())])
		button.focus_neighbor_right = button.get_path_to(_actions[(i + 1) % _actions.size()])
	_trail_lab.focus_neighbor_top = _trail_lab.get_path_to(_actions[0])


func _gui_input(event: InputEvent) -> void:
	_scroll(event, self)


func _card_input(event: InputEvent) -> void:
	if not _scroll(event, _artwork) and _is_double_click(event):
		_artwork.accept_event()
		play_requested.emit()


func _thumbnail_input(event: InputEvent, index: int) -> void:
	var button: Button = _cards.get_child(index)
	if not _scroll(event, button) and _is_double_click(event):
		button.accept_event()
		_choose(index)
		play_requested.emit()


func _scroll(event: InputEvent, control: Control) -> bool:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			move(-1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
			control.accept_event()
			return true
	return false


func _is_double_click(event: InputEvent) -> bool:
	return event is InputEventMouseButton and event.pressed and event.double_click and event.button_index == MOUSE_BUTTON_LEFT
