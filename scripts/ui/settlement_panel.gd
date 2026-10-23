extends PanelContainer
## Небольшая доска у костра: с 11.9 две вкладки — задания поселения (Quests) и маршруты (цели путешествия),
## внизу возврат велосипеда. Вкладки, а не одна длинная доска: на экране 720 px всё помещается без прокрутки.

signal closed
signal destination_selected(place: Dictionary)
signal bike_requested
signal quest_accepted(quest: Dictionary)
signal quest_abandoned

const Quests = preload("res://scripts/game/quests.gd")
const GOLD := Color(1.0, 0.82, 0.32)
const MUTED := Color(1, 1, 1, 0.62)
const PAGE_W := 456.0  # ширина строк доски: 500 без полей
const CARD_W := 430.0  # и внутри карточки задания

var _box: VBoxContainer
var _tab := 0  # 0 — задания, 1 — маршруты; помнится между досками


func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(500, 0)
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 22 if edge in ["left", "right"] else 18)
	add_child(margin)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 10)
	margin.add_child(_box)
	hide()


## wrap — ширина переноса строк (px); без неё строка в одну линию. Ширина задаётся явно: перенос без неё
## считает высоту по нулевой ширине, и доска вытягивается за экран
func _label(text: String, size := 16, parent: Container = null, color := Color.WHITE, wrap := 0.0) -> Label:
	if parent == null:
		parent = _box
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	if color != Color.WHITE:
		label.add_theme_color_override("font_color", color)
	if wrap > 0.0:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size.x = wrap
	parent.add_child(label)
	return label


func _button(text: String, action: Callable, parent: Container = null) -> Button:
	if parent == null:
		parent = _box
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 38
	button.pressed.connect(action)
	parent.add_child(button)
	return button


## Убрать строки и кнопки: кнопки держат места (и записи поселений) прошлого мира
func clear() -> void:
	for child: Node in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	hide()


## places — открытые места (Hud.places); направления по дорогам берутся из индекса мира,
## поэтому видны и соседи за краем открытых земель. quests — задания игры, offers — что предлагает эта доска
func open(settlement: Dictionary, world: WorldData, places: Array, bicycle_near: bool, quests: Quests = null, offers: Array = []) -> void:
	clear()
	_label(settlement.name, 25)
	# с 9.5 в huts есть и сараи с колодцем: считаются только жилые дома
	var homes: int = settlement.huts.filter(func(u: Dictionary) -> bool: return u.get("t", "house") in SettlementsBuilder.HOMES).size()
	_label("%s · домов: %d" % [settlement.get("character", "деревня"), homes], 16, _box, MUTED)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	_box.add_child(tabs)
	var group := ButtonGroup.new()
	var pages: Array[VBoxContainer] = []
	for i in 2:
		var tab := Button.new()
		tab.text = ["Задания", "Маршруты"][i]
		tab.toggle_mode = true
		tab.button_group = group
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.custom_minimum_size.y = 34
		tab.add_theme_color_override("font_pressed_color", GOLD)
		tab.add_theme_color_override("font_hover_pressed_color", GOLD)
		tabs.add_child(tab)
		var page := VBoxContainer.new()
		page.add_theme_constant_override("separation", 8)
		page.custom_minimum_size.y = 330
		_box.add_child(page)
		pages.append(page)
		tab.toggled.connect(func(on: bool) -> void:
			page.visible = on
			if on and visible:
				_tab = i
				_fit())
	_quests_page(pages[0], settlement, quests, offers)
	_routes_page(pages[1], settlement, world, places)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_box.add_child(row)
	var bicycle := _button("Велосипед уже рядом" if bicycle_near else "Вернуть велосипед", func() -> void: bike_requested.emit(), row)
	bicycle.disabled = bicycle_near
	var close := _button("Продолжить путь · Esc", func() -> void: closed.emit(), row)
	for b: Button in [bicycle, close]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in 2:
		pages[i].visible = i == _tab
	(tabs.get_child(_tab) as Button).button_pressed = true
	show()
	_fit()
	close.grab_focus()


## После заполнения или смены вкладки контейнер считает высоту по содержимому, доска — посередине экрана
func _fit() -> void:
	reset_size()
	position = (get_parent_control().size - size) * 0.5


## Вкладка заданий: текущее задание со шагами и «Отказаться», ниже карточки предложений этой доски
func _quests_page(page: VBoxContainer, settlement: Dictionary, quests: Quests, offers: Array) -> void:
	if quests == null:
		_label("Заданий нет.", 15, page, MUTED)
		return
	var busy := not quests.active.is_empty()
	if busy:
		var q := quests.active
		var card := _card(page, true)
		_label("Текущее задание · %s" % Quests.KINDS[q.kind].title, 13, card, GOLD)
		_label(q.title, 18, card, Color.WHITE, CARD_W)
		for i in q.steps.size():
			var mark := "✓" if i < q.step else ("›" if i == q.step else "·")
			_label("%s %s" % [mark, quests.step_text(q.steps[i])], 14, card, Color.WHITE if i == q.step else MUTED, CARD_W)
		_button("Отказаться от задания", func() -> void: quest_abandoned.emit(), card)
	if offers.is_empty():
		_label("Сейчас доске нечего предложить.", 15, page, MUTED)
		return
	var center := Vector2(settlement.x, settlement.y)
	if busy:
		offers = offers.filter(func(q: Dictionary) -> bool: return q.id != quests.active.id)
		if offers.is_empty():
			return
		# одно задание за раз: остальные — строкой, взять можно после текущего
		_label("Ещё здесь: %s — после текущего" % ", ".join(PackedStringArray(offers.map(func(q: Dictionary) -> String: return q.title))), 13, page, MUTED, PAGE_W)
		return
	_label("Задания поселения «%s»" % settlement.name, 14, page, MUTED)
	for q: Dictionary in offers:
		var card := _card(page, false)
		var head := HBoxContainer.new()
		card.add_child(head)
		var kind: Dictionary = Quests.KINDS[q.kind]
		var title := _label("%s %s" % [kind.icon, q.title], 16, head)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.clip_text = true
		var take := _button("Взять", func() -> void: quest_accepted.emit(q), head)
		take.custom_minimum_size = Vector2(96, 30)
		take.tooltip_text = "Взять задание: %s" % kind.title.to_lower()
		var length := Hud._fmt_dist(center.distance_to(Vector2(q.target.x, q.target.y)) * GameConfig.TILE)
		_label("%s · %s · %s" % [kind.title, length, q.text], 13, card, MUTED, CARD_W)


func _card(parent: Container, current: bool) -> VBoxContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.05) if not current else Color(GOLD, 0.08)
	style.border_color = Color(GOLD, 0.8) if current else Color(1, 1, 1, 0.12)
	style.border_width_left = 3
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)
	return box


func _routes_page(page: VBoxContainer, settlement: Dictionary, world: WorldData, places: Array) -> void:
	_label("Выберите цель — указатель появится на компасе и карте.", 14, page, MUTED, PAGE_W)
	var here := WorldData.place_id("settlement", settlement.x, settlement.y)
	var routes: Array = []
	for r: Dictionary in world.routes(here):
		routes.append(_target(world.place(r.to if r.from == here else r.from)))
	var nearby: Array = []
	for place: Dictionary in places:
		if place.kind in ["peak", "lake"] or place.kind == "site" and place.src.rank >= 2:
			nearby.append(place)
	var center := Vector2(settlement.x, settlement.y)
	var by_distance := func(a: Dictionary, b: Dictionary) -> bool:
		return center.distance_squared_to(Vector2(a.x, a.y)) < center.distance_squared_to(Vector2(b.x, b.y))
	routes.sort_custom(by_distance)
	nearby.sort_custom(by_distance)
	if not routes.is_empty():
		_label("По дорогам отсюда", 15, page)
	for place: Dictionary in routes.slice(0, 3):
		_destination(place, center, page)
	if not nearby.is_empty():
		_label("Окрестности", 15, page)
	for place: Dictionary in nearby.slice(0, 3):
		_destination(place, center, page)
	# Одна далёкая цель по сети дорог — повод для путешествия, без условий и наград.
	var far := world.far_destination(here)
	if not far.is_empty() and not routes.any(func(p: Dictionary) -> bool: return p.key == far.id):
		_label("Дальний путь", 15, page)
		_destination(_target(far), center, page)


## Место индекса как цель HUD: ключ цели и visited — его id.
static func _target(place: Dictionary) -> Dictionary:
	var out := place.duplicate()
	out.key = place.id
	return out


func _destination(place: Dictionary, center: Vector2, page: VBoxContainer) -> void:
	var length := Hud._fmt_dist(center.distance_to(Vector2(place.x, place.y)) * GameConfig.TILE)
	_button("%s · %s" % [place.name, length], func() -> void: destination_selected.emit(place), page)
