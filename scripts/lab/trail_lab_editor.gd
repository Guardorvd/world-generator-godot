extends PanelContainer
## Lab-only controls. Emits proposed values; the composition root commits a successful rebuild.
signal course_selected(index: int, kind: String)
signal route_selected(index: int)
signal element_selected(index: int)
signal apply_requested(values: Dictionary)
signal launch_requested
signal reload_requested
signal camera_toggle_requested
signal close_requested
var course_choice := OptionButton.new()
var kind_choice := OptionButton.new()
var route_choice := OptionButton.new()
var element_choice := OptionButton.new()
var surface_choice := OptionButton.new()
var profile_choice := OptionButton.new()
var numbers := {}
var scroll := ScrollContainer.new()
var camera_button := Button.new()
var _updating := false

func _ready() -> void:
	custom_minimum_size.x = 350
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]: margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 8)
	margin.add_child(layout)
	var header := HBoxContainer.new()
	layout.add_child(header)
	var heading := VBoxContainer.new()
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	var title := Label.new()
	title.text = "TRAIL LAB"
	title.theme_type_variation = "TitleLabel"
	title.add_theme_font_size_override("font_size", 19)
	heading.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Конструктор трассы"
	subtitle.theme_type_variation = "HintLabel"
	heading.add_child(subtitle)
	var close_button := Button.new()
	close_button.text = "Закрыть  ×"
	close_button.tooltip_text = "Закрыть настройки · F2 / Esc"
	close_button.pressed.connect(func() -> void: close_requested.emit())
	header.add_child(close_button)
	camera_button.pressed.connect(func() -> void: camera_toggle_requested.emit())
	layout.add_child(camera_button)
	set_camera_overview(false)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)
	_add_heading(box, "01  ПОСТРОИТЬ ТРАССУ")
	for name in ["Исходные элементы", "S-повороты", "Серпантин", "Кольцо", "Спираль", "Восьмёрка"]: course_choice.add_item(name)
	_add_choice(box, "Форма", course_choice)
	for name in ["Велотрасса", "Природная тропа", "Обычная дорога"]: kind_choice.add_item(name)
	_add_choice(box, "Тип", kind_choice)
	var load_course := Button.new()
	load_course.text = "Построить выбранную форму"
	load_course.tooltip_text = "Заменить текущую площадку выбранной формой трассы"
	load_course.pressed.connect(func() -> void: course_selected.emit(course_choice.selected, ["mountain", "trail", "road"][kind_choice.selected]))
	box.add_child(load_course)
	_add_heading(box, "02  ВЫБРАТЬ И НАСТРОИТЬ")
	_add_choice(box, "Трасса", route_choice)
	_add_choice(box, "Элемент", element_choice)
	for name in ["Авто по местности", "Гравий", "Грунт", "Укатанная земля", "Камень", "Песок", "Лес", "Трава"]: surface_choice.add_item(name)
	_add_choice(box, "Покрытие", surface_choice)
	for name in ["Роллер", "Стол", "Поворот"]: profile_choice.add_item(name)
	_add_choice(box, "Профиль элемента", profile_choice)
	_add_heading(box, "ГЕОМЕТРИЯ")
	for spec: Array in [["width", "Ширина, м", 2.0, 20.0, 0.25], ["station", "От начала, м", 0.0, 1000.0, 0.5],
		["length", "Длина элемента, м", 4.0, 100.0, 0.5], ["height", "Высота, м", 0.0, 2.0, 0.05],
		["bank", "Сторона поворота", -1.0, 1.0, 0.1], ["earthwork", "Земляные работы", 0.0, 1.0, 0.05], ["elevation_offset", "Выемка / насыпь, м", -2.0, 2.0, 0.1], ["auto_bank", "Автовираж", 0.0, 1.0, 0.05], ["speed", "Скорость заезда, км/ч", 0.0, 72.0, 1.0]]:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = spec[1]
		label.add_theme_font_size_override("font_size", 14)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var number := SpinBox.new()
		number.min_value = spec[2]
		number.max_value = spec[3]
		number.step = spec[4]
		number.custom_minimum_size.x = 112
		if spec[0] == "bank": number.tooltip_text = "Отрицательное значение — одна сторона, положительное — другая"
		if spec[0] == "earthwork": number.tooltip_text = "Насколько трасса изменяет рельеф: 0 — выключено, 1 — полностью"
		if spec[0] == "auto_bank": number.tooltip_text = "Сила автоматического наклона трассы на поворотах: от 0 до 1"
		number.get_line_edit().add_theme_font_size_override("font_size", 14)
		row.add_child(number)
		numbers[spec[0]] = number
		box.add_child(row)
	numbers.speed.value = 36.0
	var reload_button := Button.new()
	reload_button.text = "Вернуть данные из файлов  ·  F5"
	reload_button.tooltip_text = "Отменить правки текущего запуска и перечитать исходные трассы"
	reload_button.pressed.connect(func() -> void: reload_requested.emit())
	box.add_child(reload_button)
	var note := Label.new()
	note.text = "Правки действуют только в текущем запуске."
	note.theme_type_variation = "HintLabel"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)
	var actions := VBoxContainer.new()
	layout.add_child(actions)
	var apply := Button.new()
	apply.text = "Применить и начать заезд"
	apply.tooltip_text = "Применить параметры и начать проверочный заезд"
	apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply.pressed.connect(func() -> void:
		var values := {surface = surface_choice.selected, profile = profile_choice.selected}
		for key: String in numbers: values[key] = numbers[key].value
		apply_requested.emit(values))
	actions.add_child(apply)
	var launch := Button.new()
	launch.text = "Заезд без применения правок  ·  G"
	launch.theme_type_variation = "PrimaryButton"
	launch.tooltip_text = "Начать заезд перед выбранным элементом без применения новых значений"
	launch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	launch.pressed.connect(func() -> void: launch_requested.emit())
	actions.add_child(launch)
	route_choice.item_selected.connect(func(index: int) -> void:
		if not _updating: route_selected.emit(index))
	element_choice.item_selected.connect(func(index: int) -> void:
		if not _updating: element_selected.emit(index))

func _add_heading(box: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = "SectionLabel"
	label.add_theme_font_size_override("font_size", 13)
	box.add_child(label)

func _add_choice(box: VBoxContainer, caption: String, choice: OptionButton) -> void:
	var label := Label.new()
	label.text = caption
	label.theme_type_variation = "HintLabel"
	label.add_theme_font_size_override("font_size", 13)
	box.add_child(label)
	choice.add_theme_font_size_override("font_size", 14)
	choice.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(choice)

func set_camera_overview(enabled: bool) -> void:
	camera_button.text = "Камера: обзор сверху · V" if enabled else "Камера: обычная · V"
	camera_button.tooltip_text = "Переключить между обзором трассы и видом за велосипедистом"

func present(routes: Array[TrailDefinition], lane: int, element: int) -> void:
	_updating = true
	route_choice.clear()
	for d in routes: route_choice.add_item(d.title)
	route_choice.select(lane)
	var d := routes[lane]
	element_choice.clear()
	for i in d.elements.size(): element_choice.add_item("Элемент %d · %.1f м" % [i + 1, d.elements[i].station])
	var has_element := not d.elements.is_empty()
	if not has_element: element_choice.add_item("На трассе нет элементов")
	element_choice.disabled = not has_element
	profile_choice.disabled = not has_element
	numbers.width.value = d.width
	for key in ["earthwork", "elevation_offset", "auto_bank"]: numbers[key].value = d.get(key)
	surface_choice.select(d.surface)
	for key in ["station", "length", "height", "bank"]: numbers[key].editable = has_element
	if has_element:
		element_choice.select(element)
		var e := d.elements[element]
		profile_choice.select(e.profile)
		for key in ["station", "length", "height", "bank"]: numbers[key].value = e.get(key)
	_updating = false
