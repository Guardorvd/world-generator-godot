extends PanelContainer
## Дорожная карта окрестностей и задания непосредственно под ней.

signal closed
signal travel_requested(place: Dictionary)
signal bike_requested
signal quest_accepted(quest: QuestData)
signal quest_abandoned

const Quests = preload("res://scripts/game/quests.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const Atlas = preload("res://scripts/ui/world_map_view.gd")
const MapData = preload("res://scripts/ui/local_map_data.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const MUTED := HudStyle.MUTED
const CARD_W := 270.0

var _box: VBoxContainer
var _drop_button: Button
var _drop_generation := 0
var board_map: Atlas


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
	_drop_generation += 1
	_drop_button = null
	board_map = null
	for child: Node in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	hide()


## places: первый пункт — поселение у доски, остальные — доступные пункты для переноса.
func open(settlement: Variant, world: WorldData, places: Array, bicycle_near: bool, quests: Quests = null,
		offers: Array = [], source: MapData = null) -> void:
	clear()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	_box.add_child(head)
	var title := _label(settlement.name, 30, head, HudStyle.CREAM)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var close := _button("Продолжить путь", func() -> void: closed.emit(), head)
	var destinations := places
	if destinations.is_empty():
		destinations = [{key = WorldData.place_id("settlement", settlement.x, settlement.y),
			x = settlement.x, y = settlement.y, name = settlement.name}]
	board_map = Atlas.new()
	board_map.park = true
	board_map.custom_minimum_size.y = 260
	board_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_child(board_map)
	board_map.configure_board(source if source != null else MapData.new(world), destinations)
	var can_travel := quests == null or not quests.cargo
	board_map.place_selected.connect(func(place: Dictionary) -> void:
		if can_travel and place.key != destinations[0].key:
			travel_requested.emit(place))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	_box.add_child(actions)
	if destinations.size() > 1:
		_label("Переместиться" if can_travel else "С грузом — своим ходом", 15, actions, MUTED)
	for place: Dictionary in destinations.slice(1):
		var distance := Atlas.place_at(destinations[0]).distance_to(Atlas.place_at(place))
		var transfer := _button("%s · %s" % [place.name, Util.distance_text(distance)],
			func() -> void: travel_requested.emit(place), actions)
		transfer.disabled = not can_travel
		transfer.tooltip_text = "Переместиться сюда" if can_travel else "С грузом нужно доехать своим ходом"
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	var bicycle := _button("Велосипед рядом" if bicycle_near else "Вернуть велосипед", func() -> void: bike_requested.emit(), actions)
	bicycle.disabled = bicycle_near

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 202
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_box.add_child(scroll)
	var quests_box := VBoxContainer.new()
	quests_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quests_box.add_theme_constant_override("separation", 8)
	scroll.add_child(quests_box)
	_quests_page(quests_box, settlement, quests, offers)
	show()
	close.grab_focus()


## Задания доски: текущее и предложения, ниже — «Летопись обелисков» (серия идёт параллельно и не занимает «одно задание за раз»)
func _quests_page(page: VBoxContainer, settlement: Variant, quests: Quests, offers: Array) -> void:
	if quests == null:
		_label("Заданий нет.", 15, page, MUTED)
		return
	var series_offers := offers.filter(func(q: QuestData) -> bool: return q.kind == "obelisks")
	var has_series := not series_offers.is_empty() or not quests.series.is_empty()
	_quests_main(page, settlement, quests, offers.filter(func(q: QuestData) -> bool: return q.kind != "obelisks"), has_series)
	if not quests.series.is_empty():
		_series_card(page, quests)
	elif not series_offers.is_empty():
		var q: QuestData = series_offers[0]
		var card := _card(page, Quests.KINDS[q.kind].color, false)
		var head := HBoxContainer.new()
		card.add_child(head)
		var title := _titled(q, 16, head)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var take := _button("Взять", func() -> void: quest_accepted.emit(q), head)
		take.custom_minimum_size = Vector2(96, 40)
		take.tooltip_text = "Взять задание: %s" % Quests.KINDS[q.kind].title.to_lower()
		_label("Серия · обелисков: %d · идёт параллельно с другими заданиями" % q.steps.size(), 13, card, Quests.KINDS[q.kind].color)
		_label(q.text, 13, card, MUTED, CARD_W * 2.0)


## Серия идёт: сколько табличек снято и какие остались
func _series_card(page: VBoxContainer, quests: Quests) -> void:
	var series := quests.series
	var color: Color = Quests.KINDS[series.kind].color
	var card := _card(page, color, true)
	var progress := quests.series_progress()
	_label("Серия · %s · снято %d из %d" % [Quests.KINDS[series.kind].title, progress.x, progress.y], 13, card, color)
	for i in series.steps.size():
		var row := HBoxContainer.new()
		card.add_child(row)
		row.add_child(UiIcons.rect(UiIcons.CHECK if i < series.step else null, 14, MUTED if i < series.step else color))
		_label(series.steps[i].place.name, 14, row, MUTED if i < series.step else Color.WHITE)


func _quests_main(page: VBoxContainer, settlement: Variant, quests: Quests, offers: Array, has_series: bool) -> void:
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
		_drop_button = drop
		drop.theme_type_variation = &"DangerButton"
		drop.pressed.connect(func() -> void:
			if drop.text == "Точно отказаться? Нажмите ещё раз":
				quest_abandoned.emit()
			else:
				drop.text = "Точно отказаться? Нажмите ещё раз"
				_drop_generation += 1
				_reset_drop_later(drop, _drop_generation))
	if offers.is_empty():
		if not has_series:
			_label("Сейчас доске нечего предложить.", 15, page, MUTED)
		return
	var center := Vector2(settlement.x, settlement.y)
	if busy:
		offers = offers.filter(func(q: QuestData) -> bool: return q.id != quests.active.id)
		if offers.is_empty():
			return
		# одно задание за раз: остальные — строкой, взять можно после текущего
		_label("Ещё здесь: %s — после текущего" % ", ".join(PackedStringArray(offers.map(func(q: QuestData) -> String: return q.title))), 13, page, MUTED, 600.0)
		return
	var here := WorldData.place_id("settlement", settlement.x, settlement.y)
	var thanks: int = quests.by_giver.get(here, 0)
	_label("Задания поселения «%s»%s" % [settlement.name, " · выполнено для него: %d" % thanks if thanks > 0 else ""], 14, page, MUTED)
	var cards := GridContainer.new()
	cards.columns = mini(4, offers.size())
	cards.add_theme_constant_override("h_separation", 8)
	cards.add_theme_constant_override("v_separation", 8)
	page.add_child(cards)
	for q: QuestData in offers:
		var card := _card(cards, Quests.KINDS[q.kind].color, false)
		var head := HBoxContainer.new()
		card.add_child(head)
		var kind: Dictionary = Quests.KINDS[q.kind]
		var title := _titled(q, 16, head)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.clip_text = true
		var take := _button("Взять", func() -> void: quest_accepted.emit(q), head)
		take.custom_minimum_size = Vector2(96, 40)
		take.tooltip_text = "Взять задание: %s" % kind.title.to_lower()
		var length := Util.distance_text(center.distance_to(Vector2(q.target.x, q.target.y)) * GameConfig.TILE)
		_label("%s · %s · шагов: %d" % [kind.title, length, q.steps.size()], 13, card, kind.color)
		_label(q.text, 13, card, MUTED, CARD_W)


func _reset_drop_confirmation() -> void:
	_drop_generation += 1
	if is_instance_valid(_drop_button):
		_drop_button.text = "Отказаться от задания"


func _reset_drop_later(button: Button, generation: int) -> void:
	await get_tree().create_timer(4.0).timeout
	if is_instance_valid(button) and button == _drop_button and generation == _drop_generation:
		_reset_drop_confirmation()


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
	style.bg_color = HudStyle.RECESS.lerp(color, 0.1) if current else Color(HudStyle.RECESS, 0.55)
	style.border_color = Color(color, 0.9 if current else 0.55)
	style.border_width_left = 3
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	style.content_margin_left = 10
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)
	return box
