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
var tree_garlands: CheckBox
var draw: OptionButton
var lighting: OptionButton
var fog_quality: OptionButton
var flora: OptionButton # 16.0: качество растительности
var particles: OptionButton # 11.11: частицы окружения
var style_on := {}      # 13.11: «Визуальный стиль» — CheckBox и HSlider у каждого эффекта VisualStyle.EFFECTS
var style_amount := {}
var style_value := {}
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
	tree_garlands = host.get_node("%TreeGarlands")
	draw = host.get_node("%DrawOption")
	flora = host.get_node("%FloraOption")
	lighting = host.get_node("%LightingOption")
	fog_quality = host.get_node("%FogQualityOption")
	particles = host.get_node("%ParticlesOption")
	if particles.item_count == 0:
		for level: Dictionary in GameSettings.PARTICLE_LEVELS:
			particles.add_item(level.title.capitalize())
	if lighting.item_count == 0:
		for title: String in GameSettings.LIGHTING_LEVELS:
			lighting.add_item(title)
	if fog_quality.item_count == 0:
		for title: String in GameSettings.FOG_QUALITY_LEVELS:
			fog_quality.add_item(title)
	apply_button = host.get_node("%ApplyDisplay")
	if draw.item_count == 0:
		for level: Dictionary in GameSettings.DRAW_LEVELS:
			draw.add_item(level.title.capitalize())
	if flora.item_count == 0:
		for level: Dictionary in GameSettings.FLORA_LEVELS:
			flora.add_item(level.title.capitalize())
	for id: String in VisualStyle.EFFECTS:
		var node_id: String = id.capitalize()
		style_on[id] = host.get_node("%%Style%sOn" % node_id)
		style_amount[id] = host.get_node("%%Style%sAmount" % node_id)
		style_value[id] = host.get_node("%%Style%sValue" % node_id)
		(style_on[id] as CheckBox).text = VisualStyle.TITLES[id]
		(style_on[id] as CheckBox).tooltip_text = VisualStyle.HINTS[id]
		(style_amount[id] as HSlider).tooltip_text = VisualStyle.HINTS[id]
		(style_on[id] as CheckBox).toggled.connect(func(_on: bool) -> void: _style_changed())
		(style_amount[id] as HSlider).value_changed.connect(func(_v: float) -> void: _style_changed())
	apply_button.pressed.connect(preview)
	for option: OptionButton in [mode, resolution]:
		option.item_selected.connect(func(_i: int) -> void: _update_apply())
	for option: OptionButton in [scale, aa, draw, flora, lighting, fog_quality, particles]:
		option.item_selected.connect(func(_i: int) -> void: apply_graphics())
	for box: CheckBox in [vsync, shadows, tree_garlands]:
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
	tree_garlands.set_pressed_no_signal(state.tree_garlands)
	draw.select(state.draw)
	flora.select(state.flora)
	lighting.select(state.lighting)
	fog_quality.select(state.fog_quality)
	particles.select(state.particles)
	for id: String in VisualStyle.EFFECTS:
		(style_on[id] as CheckBox).set_pressed_no_signal(state.style_on[id])
		(style_amount[id] as HSlider).set_value_no_signal(state.style_amount[id])
		(style_amount[id] as HSlider).editable = state.style_on[id]
		_show_style_value(id)
	VisualStyle.configure(state.style_on, state.style_amount)
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
		shadows = shadows.button_pressed, tree_garlands = tree_garlands.button_pressed, draw = draw.selected, flora = flora.selected, lighting = lighting.selected,
		fog_quality = fog_quality.selected, particles = particles.selected}

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
	for key: String in ["render_scale", "msaa", "vsync", "shadows", "tree_garlands", "draw", "flora", "lighting", "fog_quality", "particles"]:
		state[key] = chosen[key]
		if pending():
			_pending[key] = chosen[key]
	GameContext.scope.settings.set_display_state(state)
	_resize()
	_host._settings_changed()

## Визуальный стиль: выключатель и сила каждого эффекта сразу в GameSettings, на экран (VisualStyle) и на диск
func _style_changed() -> void:
	var state := GameContext.scope.settings.display_state()
	for id: String in VisualStyle.EFFECTS:
		state.style_on[id] = (style_on[id] as CheckBox).button_pressed
		state.style_amount[id] = (style_amount[id] as HSlider).value
		(style_amount[id] as HSlider).editable = state.style_on[id]
		_show_style_value(id)
	GameContext.scope.settings.set_display_state(state)
	VisualStyle.configure(state.style_on, state.style_amount)
	_host._settings_changed()

func _show_style_value(id: String) -> void:
	(style_value[id] as Label).text = "%d %%" % roundi((style_amount[id] as HSlider).value * 100.0) if (style_on[id] as CheckBox).button_pressed else "выкл."

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
