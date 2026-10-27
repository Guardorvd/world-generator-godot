extends PanelContainer
## Lab-only controls. Emits proposed values; the composition root commits a successful rebuild.
signal route_selected(index: int)
signal element_selected(index: int)
signal apply_requested(values: Dictionary)
signal launch_requested
signal reload_requested
var route_choice := OptionButton.new()
var element_choice := OptionButton.new()
var surface_choice := OptionButton.new()
var profile_choice := OptionButton.new()
var numbers := {}
var scroll := ScrollContainer.new()
var _updating := false

func _ready() -> void:
	custom_minimum_size.x = 350
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]: margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	margin.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var title := Label.new()
	title.text = "НАСТРОЙКА ТРАССЫ · F2"
	title.add_theme_font_size_override("font_size", 16)
	box.add_child(title)
	box.add_child(route_choice)
	box.add_child(element_choice)
	for name in ["Авто по местности", "Гравий", "Грунт", "Укатанная земля", "Камень", "Песок", "Лес", "Трава"]:
		surface_choice.add_item(name)
	box.add_child(surface_choice)
	for name in ["Роллер", "Стол", "Поворот"]: profile_choice.add_item(name)
	box.add_child(profile_choice)
	for choice in [route_choice, element_choice, surface_choice, profile_choice]:
		choice.add_theme_font_size_override("font_size", 15)
		choice.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	for spec: Array in [["width", "Ширина, м", 2.0, 20.0, 0.25], ["station", "От начала, м", 0.0, 1000.0, 0.5],
		["length", "Длина элемента, м", 4.0, 100.0, 0.5], ["height", "Высота, м", 0.0, 2.0, 0.05],
		["bank", "Сторона поворота", -1.0, 1.0, 0.1], ["speed", "Скорость заезда, км/ч", 0.0, 72.0, 1.0]]:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = spec[1]
		label.add_theme_font_size_override("font_size", 14)
		label.clip_text = true
		label.custom_minimum_size.x = 140
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var number := SpinBox.new()
		number.min_value = spec[2]
		number.max_value = spec[3]
		number.step = spec[4]
		number.get_line_edit().add_theme_font_size_override("font_size", 14)
		row.add_child(number)
		numbers[spec[0]] = number
		box.add_child(row)
	numbers.speed.value = 36.0
	var apply := Button.new()
	apply.text = "Применить и проверить"
	apply.pressed.connect(func() -> void:
		var values := {surface = surface_choice.selected, profile = profile_choice.selected}
		for key: String in numbers: values[key] = numbers[key].value
		apply_requested.emit(values))
	box.add_child(apply)
	var launch := Button.new()
	launch.text = "Заезд перед элементом · G"
	launch.pressed.connect(func() -> void: launch_requested.emit())
	box.add_child(launch)
	var reload_button := Button.new()
	reload_button.text = "Перечитать .tres · F5"
	reload_button.pressed.connect(func() -> void: reload_requested.emit())
	box.add_child(reload_button)
	for button in [apply, launch, reload_button]:
		button.add_theme_font_size_override("font_size", 14)
	var note := Label.new()
	note.text = "Изменения действуют в этом запуске.\nF5 возвращает данные из файлов."
	note.add_theme_font_size_override("font_size", 13)
	box.add_child(note)
	route_choice.item_selected.connect(func(index: int) -> void:
		if not _updating: route_selected.emit(index))
	element_choice.item_selected.connect(func(index: int) -> void:
		if not _updating: element_selected.emit(index))

func present(routes: Array[TrailDefinition], lane: int, element: int) -> void:
	_updating = true
	route_choice.clear()
	for d in routes: route_choice.add_item(d.title)
	route_choice.select(lane)
	var d := routes[lane]
	element_choice.clear()
	for i in d.elements.size(): element_choice.add_item("Элемент %d · %.1f м" % [i + 1, d.elements[i].station])
	var has_element := not d.elements.is_empty()
	element_choice.disabled = not has_element
	profile_choice.disabled = not has_element
	numbers.width.value = d.width
	surface_choice.select(d.surface)
	for key in ["station", "length", "height", "bank"]: numbers[key].editable = has_element
	if has_element:
		element_choice.select(element)
		var e := d.elements[element]
		profile_choice.select(e.profile)
		for key in ["station", "length", "height", "bank"]: numbers[key].value = e.get(key)
	_updating = false
