extends PanelContainer
## Небольшая доска маршрутов у костра: цели путешествия и возврат велосипеда.

signal closed
signal destination_selected(place: Dictionary)
signal bike_requested

var _box: VBoxContainer

func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(480, 0)
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 22)
	add_child(margin)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 10)
	margin.add_child(_box)
	hide()

func _label(text: String, size := 16) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	_box.add_child(label)

func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 38
	button.pressed.connect(action)
	_box.add_child(button)
	return button

## Убрать строки и кнопки: кнопки держат места (и записи поселений) прошлого мира
func clear() -> void:
	for child: Node in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	hide()

## places — открытые места (Hud.places); направления по дорогам берутся из индекса мира,
## поэтому видны и соседи за краем открытых земель.
func open(settlement: Dictionary, world: WorldData, places: Array, bicycle_near: bool) -> void:
	clear()
	_label(settlement.name, 25)
	_label("%s · домов: %d" % [settlement.get("character", "деревня"), settlement.huts.size()])
	_label("Доска маршрутов", 19)
	_label("Выберите цель — указатель появится на компасе и карте.", 14)
	var here := WorldData.place_id("settlement", settlement.x, settlement.y)
	var routes: Array = []
	for r: Dictionary in world.routes(here):
		routes.append(_target(world.place(r.to if r.from == here else r.from)))
	var nearby: Array = []
	for place: Dictionary in places:
		if place.kind in ["peak", "lake"]:
			nearby.append(place)
	var center := Vector2(settlement.x, settlement.y)
	var by_distance := func(a: Dictionary, b: Dictionary) -> bool:
		return center.distance_squared_to(Vector2(a.x, a.y)) < center.distance_squared_to(Vector2(b.x, b.y))
	routes.sort_custom(by_distance)
	nearby.sort_custom(by_distance)
	if not routes.is_empty():
		_label("По дорогам отсюда", 15)
	for place: Dictionary in routes.slice(0, 3):
		_destination(place, center)
	if not nearby.is_empty():
		_label("Окрестности", 15)
	for place: Dictionary in nearby.slice(0, 2):
		_destination(place, center)
	# Одна далёкая цель по сети дорог — повод для путешествия, без условий и наград.
	var far := world.far_destination(here)
	if not far.is_empty() and not routes.any(func(p: Dictionary) -> bool: return p.key == far.id):
		_label("Дальний путь", 15)
		_destination(_target(far), center)
	var bicycle := _button("Велосипед уже рядом" if bicycle_near else "Вернуть велосипед к костру", func() -> void: bike_requested.emit())
	bicycle.disabled = bicycle_near
	var close := _button("Продолжить путь · Esc", func() -> void: closed.emit())
	show()
	# После заполнения контейнер считает высоту по содержимому.
	reset_size()
	position = (get_parent_control().size - size) * 0.5
	close.grab_focus()

## Место индекса как цель HUD: ключ цели и visited — его id.
func _target(place: Dictionary) -> Dictionary:
	var out := place.duplicate()
	out.key = place.id
	return out


func _destination(place: Dictionary, center: Vector2) -> void:
	var distance := center.distance_to(Vector2(place.x, place.y)) * GameConfig.TILE
	var length := "%d м" % roundi(distance) if distance < 1000.0 else "%.1f км" % (distance / 1000.0)
	_button("%s · %s" % [place.name, length], func() -> void: destination_selected.emit(place))
