extends RefCounted
## Настройки экрана применяются пробно; на диск идут только после подтверждения.
const Config := preload("res://scripts/game/display_config.gd")
const CONFIRM_SECONDS := 15
const SCALES := [0.5, 0.67, 0.75, 1.0]
var tabs: TabContainer
var mode: OptionButton
var resolution: OptionButton
var scale: OptionButton
var aa: OptionButton
var vsync: CheckBox
var apply_button: Button
var dialog: ConfirmationDialog
var _host: Node
var _window: Window
var _sizes: Array[Vector2i] = []
var _pending := {}
var _old_geometry := {}
var _deadline := 0

func setup(host: Node) -> void:
	_host = host
	_window = host.get_tree().root
	var box: VBoxContainer = host.get_node("%Done").get_parent()
	var original := box.get_children()
	box.get_parent().custom_minimum_size = Vector2(620, 0)
	tabs = TabContainer.new()
	tabs.custom_minimum_size = Vector2(560, 390)
	box.add_child(tabs)
	box.move_child(tabs, 1)
	var pages := {}
	for title: String in ["Экран", "Графика", "Управление", "Звук и время"]:
		var scroll := ScrollContainer.new()
		scroll.name = title
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.follow_focus = true
		tabs.add_child(scroll)
		var page := VBoxContainer.new()
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.add_theme_constant_override("separation", 8)
		scroll.add_child(page)
		pages[title] = page
	mode = _option(pages["Экран"], "Режим экрана", ["В окне", "Полный экран"])
	resolution = _option(pages["Экран"], "Разрешение", [])
	scale = _option(pages["Графика"], "Масштаб 3D", ["50% — быстрее", "67%", "75%", "100% — чётче"])
	aa = _option(pages["Графика"], "Сглаживание", ["Выключено", "MSAA 2×", "MSAA 4×"])
	vsync = CheckBox.new()
	vsync.text = "Вертикальная синхронизация"
	pages["Графика"].add_child(vsync)
	var hint := Label.new()
	hint.text = "В окне разрешение задаёт размер окна. На полном экране — предел детализации 3D с сохранением пропорций. Интерфейс остаётся чётким.\n\nПосле выбора нажмите «Применить». Изменения нужно подтвердить за 15 секунд. Иначе вернутся прежние настройки."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.theme_type_variation = &"HintLabel"
	pages["Экран"].add_child(hint)
	for node: Node in original:
		if node.name in ["Title", "Reset", "Done"]:
			continue
		if node.name == "Fullscreen":
			node.hide() # старый узел оставлен для совместимости сцен и инструментов
			continue
		var page_name := "Управление" if node.name in ["MouseRow", "MouseSlider", "InvertY", "FovRow", "FovSlider", "HeadBob"] else "Звук и время"
		if node.name in ["Shadows", "DrawRow"]:
			page_name = "Графика"
		node.reparent(pages[page_name])
	var quality_hint := Label.new()
	quality_hint.text = "Для слабой видеокарты: масштаб 3D 67–75%, сглаживание выключено или 2×, минимальная дальность, тени выключены."
	quality_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quality_hint.theme_type_variation = &"HintLabel"
	pages["Графика"].add_child(quality_hint)
	apply_button = Button.new()
	apply_button.text = "Применить экран и графику"
	apply_button.theme_type_variation = &"PrimaryButton"
	apply_button.custom_minimum_size.y = 40
	box.add_child(apply_button)
	box.move_child(apply_button, tabs.get_index() + 1)
	host.get_node("%Done").text = "Назад"
	host.get_node("%Done").theme_type_variation = &""
	apply_button.pressed.connect(preview)
	dialog = ConfirmationDialog.new()
	dialog.title = "Сохранить настройки экрана?"
	dialog.ok_button_text = "Сохранить"
	dialog.cancel_button_text = "Вернуть прежние"
	dialog.dialog_autowrap = true
	host.add_child(dialog)
	dialog.confirmed.connect(keep)
	dialog.canceled.connect(revert)
	_window.size_changed.connect(_resize)
	sync()

func _option(parent: Control, title: String, values: Array) -> OptionButton:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = title
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(250, 36)
	for value: String in values:
		option.add_item(value)
	row.add_child(option)
	return option

func sync() -> void:
	var state := GameSettings.display_state()
	mode.select(1 if state.fullscreen else 0)
	_sizes = Config.resolutions(DisplayServer.screen_get_size(_window.current_screen), state.resolution)
	resolution.clear()
	for size: Vector2i in _sizes:
		resolution.add_item("Автоматически" if size == Vector2i.ZERO else "%d × %d" % [size.x, size.y])
	resolution.select(_sizes.find(state.resolution))
	var nearest := 0
	for i in SCALES.size():
		if absf(SCALES[i] - state.render_scale) < absf(SCALES[nearest] - state.render_scale):
			nearest = i
	scale.select(nearest)
	aa.select(state.msaa)
	vsync.set_pressed_no_signal(state.vsync)
	_host.get_node("%Shadows").set_pressed_no_signal(state.shadows)
	var draw_option: OptionButton = _host.get_node("%DrawOption")
	if draw_option.item_count == 0:
		for level: Dictionary in GameSettings.DRAW_LEVELS:
			draw_option.add_item(level.title.capitalize())
	draw_option.select(state.draw)

func selected_state() -> Dictionary:
	return {fullscreen = mode.selected == 1, resolution = _sizes[resolution.selected],
		render_scale = SCALES[scale.selected], msaa = aa.selected, vsync = vsync.button_pressed,
		shadows = _host.get_node("%Shadows").button_pressed, draw = _host.get_node("%DrawOption").selected}

func pending() -> bool:
	return not _pending.is_empty()

func preview() -> void:
	if pending():
		return
	var state := selected_state()
	if state == GameSettings.display_state():
		return
	_old_geometry = {mode = _window.mode, size = _window.size, position = _window.position}
	_pending = state
	_deadline = Time.get_ticks_msec() + CONFIRM_SECONDS * 1000
	Config.apply(_window, _pending)
	dialog.popup_centered(Vector2i(480, 180))
	tick()

func keep() -> void:
	if not pending():
		return
	var previous := GameSettings.display_state()
	GameSettings.set_display_state(_pending)
	var error := GameSettings.save_settings()
	if error != OK:
		GameSettings.set_display_state(previous)
		revert()
		_host._message("Не удалось сохранить настройки", "Прежние настройки экрана возвращены.\n" + error_string(error))
		return
	_pending = {}
	dialog.hide()
	sync()

func revert() -> void:
	if not pending():
		return
	_pending = {}
	dialog.hide()
	Config.apply(_window, GameSettings.display_state())
	if not GameSettings.fullscreen and DisplayServer.get_name() != "headless":
		var usable := Config.usable_rect(_window)
		_window.size = Config.fit_window(_old_geometry.size, usable.size)
		var high := usable.end - _window.size
		_window.position = Vector2i(clampi(_old_geometry.position.x, usable.position.x, high.x),
			clampi(_old_geometry.position.y, usable.position.y, high.y))
		if _old_geometry.mode == Window.MODE_MAXIMIZED:
			_window.mode = Window.MODE_MAXIMIZED
	_resize()
	sync()

func tick() -> void:
	if not pending():
		return
	var seconds := ceili((_deadline - Time.get_ticks_msec()) / 1000.0)
	if seconds <= 0:
		revert()
	else:
		dialog.dialog_text = "Изображение видно правильно?\nБез подтверждения прежние настройки вернутся через %d с." % seconds

func _resize() -> void:
	Config.apply_quality(_window, _pending if pending() else GameSettings.display_state())

func shutdown() -> void:
	revert()
	if _window.size_changed.is_connected(_resize):
		_window.size_changed.disconnect(_resize)
