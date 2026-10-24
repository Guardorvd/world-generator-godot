extends RefCounted
## Настройки экрана и графики. Узлы вкладок стоят в scenes/main.tscn (Экран, Графика, Управление, Звук),
## здесь только поведение.
## С 12.5+ пробно, с подтверждением за CONFIRM_SECONDS, меняется только видеорежим (режим окна и
## разрешение): после него экран может стать нечитаемым. Графика (масштаб 3D, сглаживание, синхронизация,
## тени, дальность) применяется и сохраняется сразу.
const Config := preload("res://scripts/game/display_config.gd")
const CONFIRM_SECONDS := 15
const SCALES := [0.5, 0.67, 0.75, 1.0]
var tabs: TabContainer
var mode: OptionButton
var resolution: OptionButton
var scale: OptionButton
var aa: OptionButton
var vsync: CheckBox
var shadows: CheckBox
var draw: OptionButton
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
	tabs = host.get_node("%SettingsTabs")
	mode = host.get_node("%ModeOption")
	resolution = host.get_node("%ResolutionOption")
	scale = host.get_node("%ScaleOption")
	aa = host.get_node("%AAOption")
	vsync = host.get_node("%VSync")
	shadows = host.get_node("%Shadows")
	draw = host.get_node("%DrawOption")
	apply_button = host.get_node("%ApplyDisplay")
	if draw.item_count == 0:
		for level: Dictionary in GameSettings.DRAW_LEVELS:
			draw.add_item(level.title.capitalize())
	apply_button.pressed.connect(preview)
	for option: OptionButton in [mode, resolution]:
		option.item_selected.connect(func(_i: int) -> void: _update_apply())
	for option: OptionButton in [scale, aa, draw]:
		option.item_selected.connect(func(_i: int) -> void: apply_graphics())
	for box: CheckBox in [vsync, shadows]:
		box.toggled.connect(func(_on: bool) -> void: apply_graphics())
	dialog = ConfirmationDialog.new()
	dialog.title = "Сохранить режим экрана?"
	dialog.ok_button_text = "Сохранить"
	dialog.cancel_button_text = "Вернуть прежний"
	dialog.dialog_autowrap = true
	host.add_child(dialog)
	dialog.confirmed.connect(keep)
	dialog.canceled.connect(revert)
	_window.size_changed.connect(_resize)
	sync()

## Элементы — по сохранённым настройкам (без сигналов)
func sync() -> void:
	var state := GameContext.scope.settings.display_state()
	_sync_mode(state)
	var nearest := 0
	for i in SCALES.size():
		if absf(SCALES[i] - state.render_scale) < absf(SCALES[nearest] - state.render_scale):
			nearest = i
	scale.select(nearest)
	aa.select(state.msaa)
	vsync.set_pressed_no_signal(state.vsync)
	shadows.set_pressed_no_signal(state.shadows)
	draw.select(state.draw)
	_update_apply()

## Режим окна и разрешение в списках: сохранённые или предложенные (сброс), без применения
func _sync_mode(state: Dictionary) -> void:
	mode.select(1 if state.fullscreen else 0)
	_sizes = Config.resolutions(DisplayServer.screen_get_size(_window.current_screen), state.resolution)
	resolution.clear()
	for size: Vector2i in _sizes:
		resolution.add_item("Автоматически" if size == Vector2i.ZERO else "%d × %d" % [size.x, size.y])
	resolution.select(maxi(0, _sizes.find(state.resolution)))
	_update_apply()

## Сброс: видеорежим по умолчанию только выбран в списках, включится после «Применить»
func stage_mode(state: Dictionary) -> void:
	_sync_mode(state)

func selected_state() -> Dictionary:
	return {fullscreen = mode.selected == 1, resolution = _sizes[resolution.selected],
		render_scale = SCALES[scale.selected], msaa = aa.selected, vsync = vsync.button_pressed,
		shadows = shadows.button_pressed, draw = draw.selected}

func pending() -> bool:
	return not _pending.is_empty()

## «Применить» нужна, только когда выбран другой видеорежим
func _update_apply() -> void:
	var state := GameContext.scope.settings.display_state()
	apply_button.disabled = pending() or (mode.selected == (1 if state.fullscreen else 0)
		and _sizes[resolution.selected] == state.resolution)

## Графика: сразу в GameSettings, на экран и на диск (тени и дальность игра читает из GameSettings)
func apply_graphics() -> void:
	var state := GameContext.scope.settings.display_state()
	var chosen := selected_state()
	for key: String in ["render_scale", "msaa", "vsync", "shadows", "draw"]:
		state[key] = chosen[key]
		if pending():
			_pending[key] = chosen[key]
	GameContext.scope.settings.set_display_state(state)
	_resize()
	_host._settings_changed()

## Пробный видеорежим: прежний вернётся, если не подтвердить
func preview() -> void:
	if pending():
		return
	var state := GameContext.scope.settings.display_state()
	var chosen := selected_state()
	if chosen.fullscreen == state.fullscreen and chosen.resolution == state.resolution:
		return
	_old_geometry = {mode = _window.mode, size = _window.size, position = _window.position}
	state.fullscreen = chosen.fullscreen
	state.resolution = chosen.resolution
	_pending = state
	_deadline = Time.get_ticks_msec() + CONFIRM_SECONDS * 1000
	Config.apply(_window, _pending)
	dialog.popup_centered(Vector2i(480, 180))
	_update_apply()
	tick()

func keep() -> void:
	if not pending():
		return
	var previous := GameContext.scope.settings.display_state()
	var state := previous.duplicate()
	state.fullscreen = _pending.fullscreen
	state.resolution = _pending.resolution
	GameContext.scope.settings.set_display_state(state)
	var error := GameContext.scope.settings.save_settings()
	if error != OK:
		GameContext.scope.settings.set_display_state(previous)
		revert()
		_host._message("Не удалось сохранить настройки", "Прежний режим экрана возвращён.\n" + error_string(error))
		return
	_pending = {}
	dialog.hide()
	sync()

func revert() -> void:
	if not pending():
		return
	_pending = {}
	dialog.hide()
	Config.apply(_window, GameContext.scope.settings.display_state())
	if not GameContext.scope.settings.fullscreen and DisplayServer.get_name() != "headless":
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
		dialog.dialog_text = "Изображение видно правильно?\nБез подтверждения прежний режим вернётся через %d с." % seconds

func _resize() -> void:
	Config.apply_quality(_window, _pending if pending() else GameContext.scope.settings.display_state())

func shutdown() -> void:
	revert()
	if _window.size_changed.is_connected(_resize):
		_window.size_changed.disconnect(_resize)
