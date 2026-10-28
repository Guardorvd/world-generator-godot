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
var sections := {}
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
	_add_heading(box, "ТЕКУЩАЯ ТРАССА")
	_add_choice(box, "Трасса", route_choice)
	_add_choice(box, "Элемент", element_choice)
	var course_box := _add_section(box, "Построить новую трассу", false)
	for name in ["Исходные элементы", "S-повороты", "Серпантин", "Кольцо", "Спираль", "Восьмёрка", "Flow-трасса", "Технический лес", "Байк-парк"]: course_choice.add_item(name)
	_add_choice(course_box, "Форма", course_choice)
	for name in ["Велотрасса", "Природная тропа", "Обычная дорога"]: kind_choice.add_item(name)
	_add_choice(course_box, "Тип", kind_choice)
	var load_course := Button.new()
	load_course.text = "Построить"
	load_course.tooltip_text = "Заменить текущую площадку выбранной формой трассы"
	load_course.pressed.connect(func() -> void: course_selected.emit(course_choice.selected, ["mountain", "trail", "road"][kind_choice.selected]))
	course_box.add_child(load_course)
	var trail_box := _add_section(box, "Трасса и покрытие", false)
	for name in ["Авто по местности", "Гравий", "Грунт", "Укатанная земля", "Камень", "Песок", "Лес", "Трава"]: surface_choice.add_item(name)
	_add_choice(trail_box, "Покрытие", surface_choice)
	_add_number(trail_box, ["width", "Ширина, м", 2.0, 20.0, 0.25])
	var element_box := _add_section(box, "Параметры элемента", false)
	for name in TrailElementLibrary.titles(): profile_choice.add_item(name)
	_add_choice(element_box, "Профиль", profile_choice)
	for spec: Array in [["station", "От начала, м", 0.0, 1000.0, 0.5], ["length", "Длина, м", 4.0, 100.0, 0.5], ["height", "Высота, м", 0.0, 2.0, 0.05], ["bank", "Сторона поворота", -1.0, 1.0, 0.1], ["count", "Число волн / брёвен", 1.0, 12.0, 1.0], ["skew", "Положение гребня", 0.15, 0.85, 0.05], ["period", "Шаг ряби, м", 1.5, 6.0, 0.1], ["density", "Плотность", 0.05, 1.0, 0.05], ["lines", "Число линий", 1.0, 3.0, 1.0], ["gap", "Проход / настил, м", 1.0, 6.0, 0.1], ["seed", "Номер раскладки", 0.0, 9999.0, 1.0]]:
		_add_number(element_box, spec)
	var terrain_box := _add_section(box, "Рельеф и виражи", false)
	for spec: Array in [["earthwork", "Земляные работы", 0.0, 1.0, 0.05], ["elevation_offset", "Выемка / насыпь, м", -2.0, 2.0, 0.1], ["auto_bank", "Автовираж", 0.0, 1.0, 0.05], ["grade_limit", "Макс. уклон, %", 2.0, 60.0, 1.0], ["side_follow", "Следование склону", 0.0, 1.0, 0.05], ["bank_max", "Макс. вираж, %", 0.0, 60.0, 1.0], ["batter", "Откос выемок, м/м", 0.2, 4.0, 0.1]]:
		_add_number(terrain_box, spec)
	var source_box := _add_section(box, "Исходные данные", false)
	var reload_button := Button.new()
	reload_button.text = "Вернуть данные из файлов  ·  F5"
	reload_button.tooltip_text = "Отменить правки текущего запуска и перечитать исходные трассы"
	reload_button.pressed.connect(func() -> void: reload_requested.emit())
	source_box.add_child(reload_button)
	var note := Label.new()
	note.text = "Правки действуют только в текущем запуске."
	note.theme_type_variation = "HintLabel"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	source_box.add_child(note)
	_add_heading(box, "ЗАЕЗД")
	_add_number(box, ["speed", "Скорость старта, км/ч", 0.0, 72.0, 1.0])
	numbers.speed.value = 36.0
	var actions := VBoxContainer.new()
	layout.add_child(actions)
	var apply := Button.new()
	apply.text = "Применить и заезд"
	apply.tooltip_text = "Применить параметры и начать проверочный заезд"
	apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply.pressed.connect(func() -> void:
		var values := {surface = surface_choice.selected, profile = profile_choice.selected}
		for key: String in numbers: values[key] = numbers[key].value
		apply_requested.emit(values))
	actions.add_child(apply)
	var launch := Button.new()
	launch.text = "Заезд без правок  ·  G"
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

func _add_section(box: VBoxContainer, title: String, expanded: bool) -> VBoxContainer:
	var button := Button.new()
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true
	button.button_pressed = expanded
	button.text = ("▾  " if expanded else "▸  ") + title
	box.add_child(button)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 5)
	content.visible = expanded
	box.add_child(content)
	sections[title] = {"button": button, "content": content}
	button.toggled.connect(func(open: bool) -> void:
		content.visible = open
		button.text = ("▾  " if open else "▸  ") + title)
	return content

func _add_number(box: VBoxContainer, spec: Array) -> void:
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
	if spec[0] == "grade_limit": number.tooltip_text = "Самый крутой продольный уклон, до которого трасса выравнивает рельеф"
	if spec[0] == "side_follow": number.tooltip_text = "0 — ровная полка в склоне, 1 — полотно повторяет поперечный склон"
	if spec[0] == "batter": number.tooltip_text = "Крутизна откосов выемки и насыпи рядом с полотном"
	if spec[0] == "auto_bank": number.tooltip_text = "Сила автоматического наклона трассы на поворотах: от 0 до 1"
	number.get_line_edit().add_theme_font_size_override("font_size", 14)
	row.add_child(number)
	numbers[spec[0]] = number
	box.add_child(row)

func _add_choice(box: VBoxContainer, caption: String, choice: OptionButton) -> void:
	var label := Label.new()
	label.text = caption
	label.theme_type_variation = "HintLabel"
	label.add_theme_font_size_override("font_size", 13)
	box.add_child(label)
	choice.add_theme_font_size_override("font_size", 14)
	choice.fit_to_longest_item = false
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
	var shape := d.shape()
	numbers.grade_limit.value = shape.grade_limit * 100.0
	numbers.side_follow.value = shape.side_follow
	numbers.bank_max.value = shape.bank_max * 100.0
	numbers.batter.value = shape.batter
	surface_choice.select(d.surface)
	for key in TrailElement.KEYS: numbers[key].editable = has_element
	if has_element:
		element_choice.select(element)
		var e := d.elements[element]
		profile_choice.select(e.profile)
		for key in TrailElement.KEYS: numbers[key].value = e.get(key)
	_updating = false
