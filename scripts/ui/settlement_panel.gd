extends PanelContainer
## Небольшая доска у костра: с 11.9 две вкладки — задания поселения (Quests) и маршруты (цели путешествия),
## внизу возврат велосипеда. Вкладки, а не одна длинная доска: на экране 720 px всё помещается без прокрутки.

signal closed
signal destination_selected(place: Dictionary)
signal bike_requested
signal quest_accepted(quest: QuestData)
signal quest_abandoned

const Quests = preload("res://scripts/game/quests.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
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
func open(settlement: Variant, world: WorldData, places: Array, bicycle_near: bool, quests: Quests = null, offers: Array = []) -> void:
	clear()
	# название и сведения одной строкой: высота доски уходит на задания
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	_box.add_child(head)
	_label(settlement.name, 25, head)
	# с 9.5 в huts есть и сараи с колодцем: считаются только жилые дома
	var homes: int = settlement.huts.filter(func(u: Variant) -> bool: return EntityCodec.value(u, "t", "house") in SettlementsBuilder.HOMES).size()
	var info := _label("%s · домов: %d" % [EntityCodec.value(settlement, "character", "деревня"), homes], 15, head, MUTED)
	info.size_flags_vertical = Control.SIZE_SHRINK_END
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	_box.add_child(tabs)
	var group := ButtonGroup.new()
	var pages: Array[VBoxContainer] = []
	for i in 2:
		var tab := Button.new()
		tab.text = ["Задания", "Маршруты"][i]
		if i == 0 and quests != null:
			# на вкладке видно, есть ли что взять, ещё до перехода на неё
			tab.text = "Задания · идёт" if not quests.active.is_empty() else ("Задания · %d" % offers.size() if not offers.is_empty() else "Задания")
		tab.toggle_mode = true
		tab.button_group = group
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.custom_minimum_size.y = 36
		tab.theme_type_variation = &"TabButton"
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
func _quests_page(page: VBoxContainer, settlement: Variant, quests: Quests, offers: Array) -> void:
	if quests == null:
		_label("Заданий нет.", 15, page, MUTED)
		return
	var busy := not quests.active.is_empty()
	if busy:
		var q := quests.active
		var kind: Dictionary = Quests.KINDS[q.kind]
		var card := _card(page, kind.color, true)
		_label("Текущее задание · %s" % kind.title, 13, card, kind.color)
		_titled(q, 18, card, CARD_W)
		# шаги: пройденный — галочка, текущий — стрелка цвета задания, впереди — без знака
		for i in q.steps.size():
			var step := HBoxContainer.new()
			card.add_child(step)
			var mark: Texture2D = UiIcons.CHECK if i < q.step else (UiIcons.PLAY if i == q.step else null)
			step.add_child(UiIcons.rect(mark, 14, MUTED if i < q.step else kind.color))
			_label(quests.step_text(q.steps[i]), 14, step, Color.WHITE if i == q.step else MUTED, CARD_W - 22)
		# отказ — в два нажатия: случайный щелчок не теряет сумку и пройденные шаги
		var drop := _button("Отказаться от задания", func() -> void: pass, card)
		drop.theme_type_variation = &"DangerButton"
		drop.pressed.connect(func() -> void:
			if drop.text == "Точно отказаться? Нажмите ещё раз":
				quest_abandoned.emit()
			else:
				drop.text = "Точно отказаться? Нажмите ещё раз")
	if offers.is_empty():
		_label("Сейчас доске нечего предложить.", 15, page, MUTED)
		return
	var center := Vector2(settlement.x, settlement.y)
	if busy:
		offers = offers.filter(func(q: QuestData) -> bool: return q.id != quests.active.id)
		if offers.is_empty():
			return
		# одно задание за раз: остальные — строкой, взять можно после текущего
		_label("Ещё здесь: %s — после текущего" % ", ".join(PackedStringArray(offers.map(func(q: QuestData) -> String: return q.title))), 13, page, MUTED, PAGE_W)
		return
	var here := WorldData.place_id("settlement", settlement.x, settlement.y)
	var thanks: int = quests.by_giver.get(here, 0)
	_label("Задания поселения «%s»%s" % [settlement.name, " · выполнено для него: %d" % thanks if thanks > 0 else ""], 14, page, MUTED)
	for q: QuestData in offers:
		var card := _card(page, Quests.KINDS[q.kind].color, false)
		var head := HBoxContainer.new()
		card.add_child(head)
		var kind: Dictionary = Quests.KINDS[q.kind]
		var title := _titled(q, 16, head)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.clip_text = true
		var take := _button("Взять", func() -> void: quest_accepted.emit(q), head)
		take.custom_minimum_size = Vector2(96, 30)
		take.tooltip_text = "Взять задание: %s" % kind.title.to_lower()
		var length := Hud._fmt_dist(center.distance_to(Vector2(q.target.x, q.target.y)) * GameConfig.TILE)
		_label("%s · %s · шагов: %d" % [kind.title, length, q.steps.size()], 13, card, kind.color)
		_label(q.text, 13, card, MUTED, CARD_W)


## Название задания с пиктограммой вида (UiIcons.QUESTS) цвета вида; wrap — как у _label.
## В строке (head) растягивается сама надпись: её и возвращает
func _titled(q: QuestData, size: int, parent: Container, wrap := 0.0) -> Label:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)
	row.add_child(UiIcons.rect(UiIcons.quest(q.kind), size + 2, Quests.KINDS[q.kind].color))
	return _label(q.title, size, row, Color.WHITE, wrap - size - 10 if wrap > 0.0 else 0.0)


## Карточка задания: полоска слева — цвет вида (Quests.KINDS), у текущего ярче и с подложкой
func _card(parent: Container, color: Color, current: bool) -> VBoxContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color, 0.1) if current else Color(1, 1, 1, 0.05)
	style.border_color = Color(color, 0.9 if current else 0.55)
	style.border_width_left = 3
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	style.content_margin_left = 10
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)
	return box


func _routes_page(page: VBoxContainer, settlement: Variant, world: WorldData, places: Array) -> void:
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
