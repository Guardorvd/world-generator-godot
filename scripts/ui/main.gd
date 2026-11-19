extends Node
## Приложение: меню, экраны, загрузка мира, пауза и выход.
## Экраны собраны в сцене scenes/main.tscn (оформление — resources/ui_theme.tres), здесь только поведение.
## Мир загружается в отдельном потоке (WorldLoader), чтобы экран загрузки обновлялся.
## Экран настроек открывается из меню и из паузы и возвращает туда же; настройки — GameSettings.
## С 10.0 под полем зерна — список миров: недавние, избранные (звёздочка) и рекомендованные автором
## (RecommendedSeeds). Миры недавних и избранных хранятся готовыми в кэше (WorldCache), остальные удаляются.
## С 12.5 оформление только из темы (вариации кнопок и надписей), пиктограммы — UiIcons. Пауза: продолжить,
## быстрое сохранение, настройки, компактное управление; уход в меню и выход — с подтверждением.
## Настройки: вкладки в сцене, управление и звук применяются сразу, сброс — с подтверждением.

const WORDS := ["Север", "Туман", "Янтарь", "Ветер", "Кедр", "Заря", "Омут", "Пустошь", "Гроза", "Сокол", "Иней", "Полынь", "Руда", "Ключ"]
# Сцены игры и Лаборатории не входят в загрузку меню (их скрипты компилируются ~2,6 с до первого кадра):
# они грузятся при входе — игра под экраном загрузки мира. Фоновая загрузка (load_threaded_request) пробовалась
# и однажды зависла навсегда, поэтому только обычный load в главном потоке.
const GAME_SCENE := "res://scenes/game_world.tscn"
const TRAIL_LAB_SCENE := "res://scenes/trail_lab.tscn"
const GAME_SCRIPT := "res://scripts/render/game_world.gd"
const Saves := preload("res://scripts/game/save_game.gd")
const DisplayOptions := preload("res://scripts/ui/display_options.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const Carousel := preload("res://scripts/ui/world_carousel.gd")
const Backdrop := preload("res://scripts/ui/menu_backdrop.gd")
const UiAudio := preload("res://scripts/ui/ui_audio.gd")
const UiStack := preload("res://scripts/ui/ui_stack.gd")


class CancelFlag extends RefCounted:
	var _mutex := Mutex.new()
	var _cancelled := false

	func cancel() -> void:
		_mutex.lock()
		_cancelled = true
		_mutex.unlock()

	func is_cancelled() -> bool:
		_mutex.lock()
		var v := _cancelled
		_mutex.unlock()
		return v
const LIVE_WARM_START_DELAY := 0.18
# Заставка запуска: цвет совпадает с application/boot_splash/bg_color, меню проявляется уже с живым фоном.
const STARTUP_COVER_COLOR := Color(0.043, 0.051, 0.059)
const STARTUP_COVER_LIMIT := 6.0
const STARTUP_REVEAL := 0.45
const WIND := "res://resources/sounds/wind.wav"
const BIRDS := ["res://resources/sounds/bird_1.wav", "res://resources/sounds/bird_2.wav", "res://resources/sounds/bird_3.wav"]

var game: Node # GameWorld; без типа, чтобы меню не тянуло скрипты игры при запуске
var trail_lab: Node
var busy := false
var gen_thread: Thread
var _load_started_ms := 0
var _load_elapsed := -1
var _load_label := ""
var _settings_from := "menu"   # куда вернуться из настроек
var _seed_tab := "recent"      # вкладка списка миров: recent, favorites, recommended
var _previews := {}            # зерно -> превью карты из кэша (ImageTexture) или null
var _world_cards := {}         # зерно -> состояние, проверенное при обновлении списка
var _saved_seeds: Array = []
var _carousel_seeds: Array[String] = []
var _selected_seed := ""
var _card_reads := 0
var _cards_ready := false
var _has_active_saves := false
var _pending_save := {}
var _save_elapsed := 0.0
var _auto_save_task := -1
var _auto_save_result := {}
var _save_status: Label
var _load_manual: Button
var _saved_discoveries := 0
var _progress_enabled := false # инструменты не записывают пользовательский прогресс
var display_options: DisplayOptions
var _confirm: ConfirmationDialog   # открытое подтверждение (выход, меню, загрузка)
var _save_due := -1       # когда записать изменённые настройки (мс), -1 — нечего
var _backdrop: Backdrop
var _backdrop_epoch := 0
var _backdrop_mode := ""
var _backdrop_fade: Tween
var _poster: Texture2D
var _frozen_fallback: Texture2D
var _startup_cover: ColorRect
var _menu_wind: AudioStreamPlayer
var _menu_bird: AudioStreamPlayer
var _bird_wait := 0.0
var _parallax := Vector2.ZERO
var _parallax_tween: Tween
var _menu_rng := RandomNumberGenerator.new()
var _ui_audio: UiAudio
var _ui_stack: UiStack
var _active_screen := ""
var _pause_settings_btn: Button
var _confirm_return_focus: Control
var _hud_fade: Tween
var _progress_target := 0.0
var _load_step_tween: Tween
var _load_cancel_flag: CancelFlag
var _load_cancel_requested := false
var _load_quit_requested := false
var _favorites_notice_tween: Tween
var _fov_dragging := false
var _volume_dragging := false
var _volume_tick_ms := 0

@onready var hud: Hud = %Hud
@onready var bg: TextureRect = %MenuBackground
@onready var seed_edit: LineEdit = %SeedEdit
@onready var bar: ProgressBar = %Progress
@onready var load_step: Label = %Step
@onready var screens := {back = %Back, menu = %Menu, new_world = %NewWorld, all_worlds = %AllWorlds,
	loading = %Loading, pause = %Pause, settings = %Settings}


static func random_seed() -> String:
	return "%s-%d" % [WORDS[randi() % WORDS.size()], randi_range(1000, 9999)]


## Быстрый режим трасс (--quick-trails, только разработка): пометка в заголовке окна и поверх всего экрана,
## чтобы снимок не приняли за полный мир
func _mark_quick_trails() -> void:
	DisplayServer.window_set_title("%s — %s" % [ProjectSettings.get_setting("application/config/name", ""), QuickTrails.LABEL])
	var layer := CanvasLayer.new()
	layer.layer = 128
	var label := Label.new()
	label.text = QuickTrails.LABEL.to_upper() + " (сеть трасс только в середине мира)"
	label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.25))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	label.add_theme_constant_override("outline_size", 6)
	label.add_theme_font_size_override("font_size", 18)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 6)
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	layer.add_child(label)
	add_child(layer)


func _ready() -> void:
	if "--menu-timing" in OS.get_cmdline_user_args():
		print("MENU_READY_MS=", Time.get_ticks_msec())
	if OS.get_cmdline_user_args().has("--resource-report"):
		GameContext.scope.resource_profile = load("res://scripts/core/resource_profile.gd").new() # load: профиль тянет скрипт игры
	GameContext.scope.settings.load_settings()
	GameContext.scope.settings.apply_window()
	GameContext.scope.settings.apply_volume()
	seed_edit.text = random_seed()
	_poster = bg.texture
	%Version.text = str(ProjectSettings.get_setting("application/config/version", "?"))
	# кэш миров — только у самой игры: инструменты проверки ставят эту сцену не главной и генерируют честно
	_progress_enabled = get_tree().current_scene == self
	GameContext.scope.cache.enabled = _progress_enabled
	get_tree().auto_accept_quit = false
	_setup_save_controls()
	# 14.4+: бесконечная генерация, с предупреждением, пока она не доделана.
	# В стабильной версии пункт скрыт (в main.tscn), а ранее сохранённое «включено» сбрасывается.
	if not %Infinite.visible:
		GameContext.scope.settings.infinite_world = false
	%Infinite.set_pressed_no_signal(GameContext.scope.settings.infinite_world)
	%InfiniteWarning.visible = GameContext.scope.settings.infinite_world and %Infinite.visible
	%Infinite.toggled.connect(func(on: bool) -> void:
		GameContext.scope.settings.infinite_world = on
		%InfiniteWarning.visible = on
		GameContext.scope.settings.save_settings())
	display_options = DisplayOptions.new()
	display_options.setup(self)
	if QuickTrails.active():
		_mark_quick_trails()
	var tabs := ButtonGroup.new()
	for tab: String in ["recent", "favorites", "recommended", "saved"]:
		var b: Button = _tab_button(tab)
		b.button_group = tabs
		b.pressed.connect(_show_seed_tab.bind(tab))
	var carousel: Carousel = %Carousel
	carousel.setup(%Start, [%OpenNew, %OpenWorlds, %MenuSettings, %MenuExit], %TrailLab)
	carousel.world_selected.connect(func(seed_text: String) -> void: _select_world(seed_text))
	carousel.play_requested.connect(_on_start)
	carousel.stepped.connect(func(dir: int) -> void: _play_ui(&"carousel_step", 1.04 if dir > 0 else 0.96))
	for item: Dictionary in RecommendedSeeds.SEEDS:
		var button := Button.new()
		button.text = item.seed
		button.tooltip_text = item.get("note", "")
		button.theme_type_variation = &"ListRow"
		button.pressed.connect(_suggested_seed.bind(item.seed))
		%Suggestions.add_child(button)
	_sync_author_suggestions()
	_refresh_world_cards()
	_seed_tab = "saved" if not _saved_seeds.is_empty() else ("recent" if not GameContext.scope.settings.recent_seeds.is_empty() else "recommended")
	%LoadPreview.texture = null
	_ui_audio = UiAudio.new()
	add_child(_ui_audio)
	_ui_stack = UiStack.new()
	add_child(_ui_stack)
	_pause_settings_btn = get_node_or_null("UI/Root/Pause/Panel/Box/Settings") as Button
	_ui_stack.setup(self, {menu = %Menu, new_world = %NewWorld, all_worlds = %AllWorlds,
		loading = %Loading, pause = %Pause, settings = %Settings}, get_node_or_null("%Dimmer") as ColorRect, _ui_audio)
	for launch_btn: Button in [%Start, %PlaySelected, %CreateWorld]:
		launch_btn.set_meta(&"ui_sound_custom", true)
	%FovSlider.drag_started.connect(func() -> void:
		_fov_dragging = true
		_set_preview_peek(true))
	%FovSlider.drag_ended.connect(func(_changed: bool) -> void:
		_fov_dragging = false
		_set_preview_peek(false))
	%VolumeSlider.drag_started.connect(func() -> void: _volume_dragging = true)
	%VolumeSlider.drag_ended.connect(func(_changed: bool) -> void:
		_volume_dragging = false
		_play_ui(&"volume_tick"))
	for subtree: Node in [%Menu, %AllWorlds, %NewWorld, %Loading, %Pause, %Settings]:
		_ui_audio.bind_tree(subtree)
	get_viewport().size_changed.connect(_fit_menu)
	if _progress_enabled and DisplayServer.get_name() != "headless" and "--static-menu" not in OS.get_cmdline_user_args():
		_cover_startup()
	_show("menu", {instant = true})
	if _progress_enabled and "--menu-timing" in OS.get_cmdline_user_args():
		_report_first_menu_frame()


func _is_screen(screen: String) -> bool:
	return _ui_stack.is_open(screen) if _ui_stack != null else _active_screen == screen


func _play_ui(kind: StringName, pitch := 1.0) -> void:
	if _ui_audio != null:
		_ui_audio.play(kind, pitch)


func _grab_focus_quiet(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		return
	if _ui_audio != null:
		_ui_audio.suppress_focus_sound = true
	control.grab_focus()
	if _ui_audio != null:
		_ui_audio.suppress_focus_sound = false


func _restore_focus(target: Control) -> void:
	if is_instance_valid(target) and target.is_inside_tree() and target.is_visible_in_tree():
		_grab_focus_quiet(target)
		_grab_focus_quiet.call_deferred(target)


func _opener_focus(fallback: Control) -> Control:
	var owner := get_viewport().gui_get_focus_owner()
	if is_instance_valid(owner) and owner.is_visible_in_tree():
		var cur_node: Control = screens.get(_active_screen)
		if cur_node == null or cur_node.is_ancestor_of(owner):
			return owner
	return fallback


func _sync_backdrop_visibility(screen := _active_screen) -> void:
	if screens.has("back") and screens.back != null:
		screens.back.visible = screen in ["menu", "new_world", "all_worlds", "loading"] or (screen == "settings" and game == null)
	if screen != "menu" and _startup_cover != null:
		_lift_startup_cover()
	if _progress_enabled:
		var mode := "frozen" if screen == "loading" else ("live" if screens.has("back") and screens.back.visible else "")
		_set_backdrop_mode(mode)


func _focus_screen_default(screen: String) -> void:
	# фокус на главной кнопке экрана: можно пользоваться клавиатурой (стрелки, Enter)
	match screen:
		"menu":
			_fit_menu()
			_grab_focus_quiet(%Start)
		"new_world":
			_grab_focus_quiet(%CreateWorld)
		"all_worlds":
			_update_selection()
			var play: Button = %PlaySelected
			var target: Control = _tab_button(_seed_tab) if play.disabled else play
			_grab_focus_quiet(target)
		"pause":
			_fill_controls()
			_grab_focus_quiet(%Resume)
		"settings":
			_grab_focus_quiet(%Done)


func _show(screen: String, opts := {}) -> void:
	_active_screen = screen
	if _ui_stack != null:
		_ui_stack.cancel_dissolve(screens.back, screens.loading)
		_ui_stack.replace(screen, opts)
	else:
		for s: String in screens:
			if s != "back" and screens[s] != null:
				screens[s].visible = s == screen
	_sync_backdrop_visibility(screen)
	_focus_screen_default(screen)


func _input(event: InputEvent) -> void:
	if _is_screen("settings") and game == null:
		GameContext.scope.controls.note(event)
	if _confirm != null or event.is_echo():
		return
	if _is_screen("settings") and (display_options == null or not display_options.pending()):
		var pad := event as InputEventJoypadButton
		if pad != null and pad.pressed and display_options != null:
			if pad.button_index == JOY_BUTTON_LEFT_SHOULDER:
				display_options.step_tab(-1)
				get_viewport().set_input_as_handled()
				return
			if pad.button_index == JOY_BUTTON_RIGHT_SHOULDER:
				display_options.step_tab(1)
				get_viewport().set_input_as_handled()
				return
	if not _is_screen("menu"):
		return
	var direction := int(event.is_action_pressed("ui_right", true)) - int(event.is_action_pressed("ui_left", true))
	if direction != 0 and (%Carousel as Carousel).move_focused(direction):
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo() or trail_lab != null:
		return
	var button := event as InputEventJoypadButton
	var pad_back := (button != null and button.pressed and button.button_index == JOY_BUTTON_B) or event.is_action_pressed("back")
	if not (pad_back or event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")):
		return
	if _confirm != null:
		_cancel_confirm()
		get_viewport().set_input_as_handled()
		return
	if busy and _is_screen("loading"):
		_cancel_loading(false)
		get_viewport().set_input_as_handled()
		return
	if _is_screen("settings"):
		if display_options != null and display_options.close_open_popup():
			get_viewport().set_input_as_handled()
			return
		if display_options != null and display_options.pending():
			display_options.revert()
			get_viewport().set_input_as_handled()
			return
		_close_settings()
		get_viewport().set_input_as_handled()
		return
	if _is_screen("pause") and game != null and game.paused:
		_resume()
		get_viewport().set_input_as_handled()
		return
	if game == null and (_is_screen("new_world") or _is_screen("all_worlds")):
		_return_to_menu_screen()
		get_viewport().set_input_as_handled()


func _open_new_world() -> void:
	var opener := _opener_focus(%OpenNew)
	seed_edit.text = random_seed()
	if _ui_stack != null and _is_screen("menu"):
		_active_screen = "new_world"
		_ui_stack.push("new_world", {
			dimmer = 0.35,
			enter_duration = 0.20,
			exit_duration = 0.14,
			dimmer_duration = 0.18,
			return_focus = opener,
			sound = &"panel_open",
		})
		_sync_backdrop_visibility("new_world")
		_focus_screen_default("new_world")
		return
	_show("new_world")


func _sync_author_suggestions() -> void:
	var show_suggestions := not GameContext.scope.settings.hide_recommended_worlds and not RecommendedSeeds.SEEDS.is_empty()
	%Author.visible = show_suggestions
	%Suggestions.visible = show_suggestions


func _open_all_worlds() -> void:
	var opener := _opener_focus(%OpenWorlds)
	var state: Dictionary = _world_cards.get(_selected_seed, {})
	if state.get("corrupt", false):
		_seed_tab = _tab_with_seed(_selected_seed)
	_show_seed_tab(_seed_tab)
	if _ui_stack != null and _is_screen("menu"):
		_active_screen = "all_worlds"
		_ui_stack.push("all_worlds", {
			dimmer = 0.35,
			enter_duration = 0.20,
			exit_duration = 0.14,
			dimmer_duration = 0.18,
			return_focus = opener,
			sound = &"panel_open",
		})
		_sync_backdrop_visibility("all_worlds")
		_focus_screen_default("all_worlds")
		return
	_show("all_worlds")


func _return_to_menu_screen() -> void:
	if _ui_stack != null and (_ui_stack.is_open("new_world") or _ui_stack.is_open("all_worlds")):
		var popped := _ui_stack.pop({sound = &"panel_close", exit_duration = 0.14, reveal_duration = 0.16, dimmer_duration = 0.14})
		_active_screen = popped.active
		_sync_backdrop_visibility(_active_screen)
		if _active_screen == "menu":
			_fit_menu()
		var target: Control = popped.return_focus if is_instance_valid(popped.return_focus) and (popped.return_focus as Control).is_visible_in_tree() else %Start
		_grab_focus_quiet(target)
		return
	_show("menu")


func _set_backdrop_mode(mode: String) -> void:
	if mode == _backdrop_mode:
		return
	_backdrop_mode = mode
	_backdrop_epoch += 1
	if _backdrop_fade != null and _backdrop_fade.is_valid():
		_backdrop_fade.kill()
	if _parallax_tween != null and _parallax_tween.is_valid():
		_parallax_tween.kill()
		_parallax_tween = null
	var frame := _poster
	var prev_parallax := _parallax
	if _backdrop != null:
		var live: TextureRect = %LiveBackdrop
		var presented := live.visible
		live.hide()
		live.texture = null
		if mode == "frozen" and presented:
			var image := _backdrop.freeze()
			if image != null and not image.is_empty():
				frame = ImageTexture.create_from_image(image)
		else:
			_backdrop.stop()
		_backdrop.queue_free()
		_backdrop = null
	if mode == "frozen" and _frozen_fallback != null:
		frame = _frozen_fallback
	_frozen_fallback = null
	if not mode.is_empty():
		bg.texture = frame
	_parallax = Vector2.ZERO
	if mode == "frozen" and DisplayServer.get_name() != "headless" and is_processing():
		_set_bg_parallax(prev_parallax)
		_parallax_tween = create_tween()
		_parallax_tween.tween_method(_set_bg_parallax, prev_parallax, Vector2.ZERO, 0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		_set_bg_parallax(Vector2.ZERO)
	if mode == "live":
		_start_menu_backdrop(_backdrop_epoch)
	else:
		_set_menu_audio(false)


func _set_bg_parallax(offset: Vector2) -> void:
	bg.offset_left = offset.x - 4.0
	bg.offset_right = offset.x + 4.0
	bg.offset_top = offset.y - 4.0
	bg.offset_bottom = offset.y + 4.0


func _start_menu_backdrop(epoch: int) -> void:
	if DisplayServer.get_name() == "headless" or "--static-menu" in OS.get_cmdline_user_args():
		return
	# Два кадра дают вывести афишу и дождаться отложенного освобождения игрового окружения.
	var hidden := _startup_cover != null
	# При запуске под заставкой ждать нечего: игрового окружения ещё не было, сцену никто не видит.
	if not hidden:
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().create_timer(LIVE_WARM_START_DELAY).timeout
	if not is_inside_tree() or epoch != _backdrop_epoch:
		return
	_set_menu_audio(true)
	var backdrop := Backdrop.new()
	add_child(backdrop)
	var quality := Backdrop.recommended_quality()
	if not backdrop.start(_backdrop_size(), GameContext.scope.settings, quality, false, true, hidden):
		backdrop.queue_free()
		_lift_startup_cover()
		return
	_backdrop = backdrop
	backdrop.prepared.connect(_reveal_menu_backdrop.bind(epoch))
	backdrop.failed.connect(func(reason: String) -> void:
		print("MENU_BACKDROP: ", reason)
		_use_menu_poster())
	backdrop.performance_fallback.connect(_use_menu_poster)


func _reveal_menu_backdrop(epoch: int) -> void:
	if epoch != _backdrop_epoch or _backdrop == null:
		return
	var live: TextureRect = %LiveBackdrop
	live.texture = _backdrop.viewport().get_texture()
	live.show()
	if _startup_cover != null:
		# Первый показ: меню и живая сцена проявляются вместе, без афиши.
		live.modulate.a = 1.0
		_lift_startup_cover()
		return
	live.modulate.a = 0.0
	_backdrop_fade = create_tween()
	_backdrop_fade.tween_property(live, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)


func _use_menu_poster() -> void:
	_lift_startup_cover()
	if _backdrop == null:
		return
	var live: TextureRect = %LiveBackdrop
	if _backdrop_fade != null and _backdrop_fade.is_valid():
		_backdrop_fade.kill()
	live.hide()
	live.texture = null
	var image := _backdrop.freeze()
	if image != null and not image.is_empty():
		_frozen_fallback = ImageTexture.create_from_image(image)
		bg.texture = _frozen_fallback
	_backdrop.queue_free()
	_backdrop = null


## Продолжение заставки движка, пока собирается живой фон (~2 с). Ввод в меню закрыт до проявления.
## Если сборка затянулась, через STARTUP_COVER_LIMIT меню открывается с афишей, как раньше.
func _cover_startup() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 120
	_startup_cover = ColorRect.new()
	_startup_cover.color = STARTUP_COVER_COLOR
	_startup_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(_startup_cover)
	_startup_cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layer)
	get_viewport().gui_disable_input = true
	get_tree().create_timer(STARTUP_COVER_LIMIT).timeout.connect(_lift_startup_cover)


func _lift_startup_cover() -> void:
	if _startup_cover == null:
		return
	var cover := _startup_cover
	_startup_cover = null
	get_viewport().gui_disable_input = false
	if _backdrop != null:
		_backdrop.end_rush()
	if "--menu-timing" in OS.get_cmdline_user_args():
		print("MENU_REVEAL_MS=", Time.get_ticks_msec(), " live=", %LiveBackdrop.visible)
	var fade := create_tween()
	fade.tween_property(cover, "color:a", 0.0, STARTUP_REVEAL).set_trans(Tween.TRANS_SINE)
	fade.tween_callback(cover.get_parent().queue_free)


func _backdrop_size() -> Vector2i:
	return get_window().size.clamp(Vector2i(2, 2), Vector2i(2560, 1440))


func _set_menu_audio(enabled: bool) -> void:
	if not enabled:
		if _menu_wind != null:
			_menu_wind.stop()
			_menu_bird.stop()
		return
	if DisplayServer.get_name() == "headless" or AudioServer.get_driver_name() == "Dummy":
		return
	if _menu_wind == null:
		_menu_wind = AudioStreamPlayer.new()
		var source: AudioStreamWAV = load(WIND)
		var loop: AudioStreamWAV = source.duplicate()
		loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
		loop.loop_end = roundi(loop.get_length() * loop.mix_rate)
		_menu_wind.stream = loop
		_menu_wind.volume_db = -30.0
		add_child(_menu_wind)
		_menu_bird = AudioStreamPlayer.new()
		_menu_bird.volume_db = -28.0
		add_child(_menu_bird)
	_menu_wind.play()
	_bird_wait = 7.0


func _animate_menu(delta: float) -> void:
	var pointer := get_viewport().get_mouse_position()
	var extent := get_viewport().get_visible_rect().size
	var target := ((pointer / extent.max(Vector2.ONE)) * 2.0 - Vector2.ONE).clamp(-Vector2.ONE, Vector2.ONE) * 3.0
	_parallax = _parallax.lerp(target, 1.0 - exp(-delta * 2.0))
	for texture: TextureRect in [bg, %LiveBackdrop]:
		texture.offset_left = _parallax.x - 4.0
		texture.offset_right = _parallax.x + 4.0
		texture.offset_top = _parallax.y - 4.0
		texture.offset_bottom = _parallax.y + 4.0
	if _menu_wind != null and _menu_wind.playing:
		_bird_wait -= delta
		if _bird_wait <= 0.0:
			_menu_bird.stream = load(BIRDS[_menu_rng.randi_range(0, BIRDS.size() - 1)])
			_menu_bird.play()
			_bird_wait = _menu_rng.randf_range(12.0, 24.0)


func _report_first_menu_frame() -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	print("MENU_FIRST_FRAME_MS=", Time.get_ticks_msec())


# ---------- Настройки ----------

func _open_settings() -> void:
	_settings_from = "pause" if _is_screen("pause") else "menu"
	var opener := _opener_focus(_pause_settings_btn if _settings_from == "pause" else %MenuSettings)
	_sync_settings_controls()
	if _ui_stack != null and _is_screen(_settings_from):
		_active_screen = "settings"
		_ui_stack.push("settings", {
			dimmer = 0.55 if _settings_from == "pause" else 0.35,
			enter_duration = 0.18 if _settings_from == "pause" else 0.20,
			exit_duration = 0.14,
			dimmer_duration = 0.18,
			return_focus = opener,
			sound = &"panel_open",
		})
		_sync_backdrop_visibility("settings")
		_focus_screen_default("settings")
		return
	_show("settings")


func _close_settings() -> void:
	if display_options != null:
		display_options.revert()
	_fov_dragging = false
	_volume_dragging = false
	_save_due = -1
	GameContext.scope.settings.save_settings()
	if _ui_stack != null and _ui_stack.is_open("settings") and _ui_stack.depth() > 1:
		var popped := _ui_stack.pop({sound = &"panel_close", exit_duration = 0.14, reveal_duration = 0.18, dimmer_duration = 0.14})
		_active_screen = popped.active
		_sync_backdrop_visibility(_active_screen)
		var fallback: Control = _pause_settings_btn if _active_screen == "pause" else %MenuSettings
		var target: Control = popped.return_focus if is_instance_valid(popped.return_focus) and (popped.return_focus as Control).is_visible_in_tree() else fallback
		_grab_focus_quiet(target)
		return
	_show(_settings_from)


func _set_preview_peek(active: bool) -> void:
	if _ui_stack != null and _is_screen("settings"):
		_ui_stack.set_dimmer_peek(active, 0.25 if game != null else 0.15)


func _pulse_preview_peek(hold_seconds := 0.75) -> void:
	if _ui_stack != null and _is_screen("settings"):
		_ui_stack.pulse_dimmer_peek(hold_seconds, 0.25 if game != null else 0.15)


## Управление, звук и графика применяются сразу; на диск — чуть позже, чтобы не писать файл на каждый шаг ползунка
func _settings_changed(category: StringName = &"graphics") -> void:
	_save_due = Time.get_ticks_msec() + 400
	if game == null:
		return
	if game.has_method("apply_live_settings"):
		game.apply_live_settings(category)
	elif game.get("garlands") != null:
		game.garlands.set_enabled(GameContext.scope.settings.tree_garlands)


func _flush_settings() -> void:
	if _save_due >= 0 and Time.get_ticks_msec() >= _save_due:
		_save_due = -1
		GameContext.scope.settings.save_settings()


## Ставит ползунки и флажки в соответствие с GameSettings; без сигналов, чтобы не сохранять лишнее
func _sync_settings_controls() -> void:
	%MouseSlider.set_value_no_signal(GameContext.scope.settings.mouse)
	%FovSlider.set_value_no_signal(GameContext.scope.settings.fov)
	%InvertY.set_pressed_no_signal(GameContext.scope.settings.invert_y)
	%HeadBob.set_pressed_no_signal(GameContext.scope.settings.head_bob)
	%TrailClutter.set_pressed_no_signal(GameContext.scope.settings.trail_clutter)
	%VolumeSlider.set_value_no_signal(GameContext.scope.settings.volume)
	%DaySlider.set_value_no_signal(GameContext.scope.settings.day_minutes)
	%StartHourSlider.set_value_no_signal(GameContext.scope.settings.start_hour)
	%RandomHour.set_pressed_no_signal(not GameContext.scope.settings.start_hour_set)
	if display_options != null:
		display_options.sync()
	_show_values()


## Сброс — только после подтверждения
func _on_reset_settings() -> void:
	_ask("Сбросить настройки?", "Управление, звук, время и графика вернутся к исходным. Режим экрана будет только выбран: он включится после «Применить».",
		"Сбросить", true, _do_reset_settings, %Reset)


func _do_reset_settings() -> void:
	var display_state := GameContext.scope.settings.display_state()
	GameContext.scope.settings.reset_defaults()
	# видеорежим меняется только через «Применить» и подтверждение; графика — сразу
	var defaults := GameContext.scope.settings.display_state()
	GameContext.scope.settings.fullscreen = display_state.fullscreen
	GameContext.scope.settings.resolution = display_state.resolution
	GameContext.scope.settings.apply_volume()
	GameContext.scope.settings.save_settings()
	_save_due = -1
	_sync_settings_controls()
	if display_options != null:
		display_options._resize()
		display_options.stage_mode(defaults)
	_settings_changed(&"all")


func _show_values() -> void:
	%MouseValue.text = "%.2f×" % GameContext.scope.settings.mouse
	%FovValue.text = "%d°" % roundi(GameContext.scope.settings.fov)
	%VolumeValue.text = "%d %%" % roundi(GameContext.scope.settings.volume * 100.0)
	%DayValue.text = "%d мин" % roundi(GameContext.scope.settings.day_minutes) if GameContext.scope.settings.day_minutes > 0.0 else "время стоит"
	%StartHourValue.text = DayCycle.clock(GameContext.scope.settings.start_hour) if GameContext.scope.settings.start_hour_set else "случайный"


func _on_mouse_changed(v: float) -> void:
	GameContext.scope.settings.mouse = v
	_settings_changed(&"input")
	_show_values()


func _on_fov_changed(v: float) -> void:
	GameContext.scope.settings.fov = v
	_settings_changed(&"fov")
	_show_values()
	if not _fov_dragging:
		_pulse_preview_peek()


func _on_volume_changed(v: float) -> void:
	GameContext.scope.settings.volume = v
	GameContext.scope.settings.apply_volume()
	_settings_changed(&"audio")
	_show_values()
	var now := Time.get_ticks_msec()
	if not _volume_dragging or now - _volume_tick_ms >= 110:
		_volume_tick_ms = now
		_play_ui(&"volume_tick")


func _on_day_changed(v: float) -> void:
	GameContext.scope.settings.day_minutes = v
	_settings_changed(&"time")
	_show_values()


func _on_start_hour_changed(v: float) -> void:
	GameContext.scope.settings.start_hour = v
	GameContext.scope.settings.start_hour_set = true
	%RandomHour.set_pressed_no_signal(false)
	_settings_changed(&"time")
	_show_values()


func _on_random_hour_toggled(on: bool) -> void:
	GameContext.scope.settings.start_hour_set = not on
	_settings_changed(&"time")
	_show_values()


func _on_invert_toggled(on: bool) -> void:
	GameContext.scope.settings.invert_y = on
	_settings_changed(&"input")


func _on_head_bob_toggled(on: bool) -> void:
	GameContext.scope.settings.head_bob = on
	_settings_changed(&"input")


func _on_trail_clutter_toggled(on: bool) -> void:
	GameContext.scope.settings.trail_clutter = on
	_settings_changed(&"input")


func _on_seed_submitted(_text: String) -> void:
	_on_create_world()


func _on_dice_pressed() -> void:
	seed_edit.text = random_seed()
	_choose_typed()


# ---------- Список миров ----------
# С 10.2 меню в две колонки: слева список миров с картой-миниатюрой и состоянием, справа выбранный мир —
# карта крупно, зерно, звёздочка, что будет при запуске (из сохранённого или заново) и «Начать игру».

func _tab_button(tab: String) -> Button:
	return {recent = %Recent, favorites = %Favorites, recommended = %Recommended, saved = %Saved}[tab]


## Превью карты мира из кэша (null — мир ещё не запускали)
func _preview_tex(seed_text: String) -> Texture2D:
	if not _previews.has(seed_text):
		_card_reads += 1
		var img := GameContext.scope.cache.preview(seed_text, not QuickTrails.active()) if GameContext.scope.cache.enabled else null
		_previews[seed_text] = ImageTexture.create_from_image(img) if img != null else null
	return _previews[seed_text]


## На карточке храним метаданные, без состояния игрока и заданий целиком.
func _read_world_card(seed_text: String) -> Dictionary:
	_card_reads += 1
	var manual := Saves.read_slot(seed_text, "manual")
	var latest := _latest_save(seed_text, manual)
	var data: Dictionary = latest.data
	var corrupt := data.is_empty() and _has_save(seed_text)
	var cache := GameContext.scope.cache
	var ready := cache.enabled and (cache.has(seed_text) or (not QuickTrails.active() and cache.has_bundled(seed_text)))
	var summary := "Откроется быстро." if ready else "Мир создастся при запуске, около минуты."
	var saved_at := -1
	if not data.is_empty():
		saved_at = int(data.saved_at)
		summary = "Открыто мест: %d · Заданий: %d\nСохранено: %s" % [data.visited.size(), data.quest.done, _local_time_text(saved_at)]
	elif corrupt:
		summary = "Сохранение не читается. Мир можно создать заново."
	return {seed = seed_text, saved = not data.is_empty(), saved_at = saved_at,
		corrupt = corrupt, manual = not manual.data.is_empty(), ready = ready, summary = summary}


func _refresh_world_cards(deleted := "", previous_index := 0) -> void:
	_cards_ready = true
	_world_cards.clear()
	_saved_seeds = Saves.seeds()
	_has_active_saves = not Saves.active_files().is_empty()
	var settings := GameContext.scope.settings
	var known: Array = _saved_seeds + settings.recent_seeds + settings.favorite_seeds
	if not settings.hide_recommended_worlds:
		for item: Dictionary in RecommendedSeeds.SEEDS:
			known.append(item.seed)
	for seed_text: String in known:
		if not _world_cards.has(seed_text):
			_world_cards[seed_text] = _read_world_card(seed_text)
		if _world_cards[seed_text].corrupt and seed_text not in _saved_seeds:
			_saved_seeds.append(seed_text)
	_saved_seeds.sort_custom(func(a: String, b: String) -> bool:
		return _world_cards[a].saved_at > _world_cards[b].saved_at)
	_carousel_seeds.clear()
	for seed_text: String in _saved_seeds + settings.recent_seeds + settings.favorite_seeds + known:
		if seed_text != deleted and seed_text not in _carousel_seeds:
			_carousel_seeds.append(seed_text)
		if _carousel_seeds.size() == Carousel.MAX_WORLDS:
			break
	if deleted == _selected_seed and not deleted.is_empty():
		_selected_seed = _carousel_seeds[mini(previous_index, _carousel_seeds.size() - 1)] if not _carousel_seeds.is_empty() else ""
	elif _selected_seed.is_empty() and not _carousel_seeds.is_empty():
		_selected_seed = _carousel_seeds[0]
	elif not _world_cards.has(_selected_seed):
		_selected_seed = _carousel_seeds[0] if not _carousel_seeds.is_empty() else ""
	if not _selected_seed.is_empty() and _selected_seed not in _carousel_seeds:
		if _carousel_seeds.size() == Carousel.MAX_WORLDS:
			_carousel_seeds.pop_back()
		_carousel_seeds.append(_selected_seed)
	if not _is_screen("new_world"):
		seed_edit.text = _selected_seed
	_update_carousel()
	_update_selection()


func _update_carousel() -> void:
	var entries: Array[Dictionary] = []
	for seed_text: String in _carousel_seeds:
		var entry: Dictionary = _world_cards[seed_text].duplicate()
		entry.texture = _preview_tex(seed_text)
		entries.append(entry)
	(%Carousel as Carousel).set_entries(entries, _selected_seed)


func _tab_with_seed(seed_text: String) -> String:
	if seed_text in _saved_seeds:
		return "saved"
	if seed_text in GameContext.scope.settings.recent_seeds:
		return "recent"
	if seed_text in GameContext.scope.settings.favorite_seeds:
		return "favorites"
	return "recommended"


func _show_seed_tab(tab: String) -> void:
	_seed_tab = tab
	# выбранная вкладка — золотой подписью (TabButton в теме)
	for name: String in ["recent", "favorites", "recommended", "saved"]:
		_tab_button(name).set_pressed_no_signal(name == tab)
	var list: VBoxContainer = %SeedList
	var focus_owner := get_viewport().gui_get_focus_owner()
	var restore_seed := ""
	var restore_star := false
	var restore_index := -1
	if is_instance_valid(focus_owner) and list.is_ancestor_of(focus_owner):
		for i in list.get_child_count():
			var c := list.get_child(i)
			if c == focus_owner or c.is_ancestor_of(focus_owner):
				restore_seed = str(c.get_meta("seed")) if c.has_meta("seed") else ""
				restore_star = c.has_meta("star_button") and focus_owner == c.get_meta("star_button")
				restore_index = i
				break
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()
	var rows: Array = []
	match tab:
		"saved":
			if not _cards_ready:
				_refresh_world_cards()
			rows = _saved_seeds.map(func(s: String) -> Dictionary:
				return {seed = s, note = "Ошибка сохранения" if _world_cards[s].corrupt else "Прогресс"})
		"recent":
			rows = GameContext.scope.settings.recent_seeds.map(func(s: String) -> Dictionary: return {seed = s, note = ""})
		"favorites":
			rows = GameContext.scope.settings.favorite_seeds.map(func(s: String) -> Dictionary: return {seed = s, note = ""})
		"recommended":
			if GameContext.scope.settings.hide_recommended_worlds:
				var restore := Button.new()
				restore.text = "Показать миры от автора"
				restore.pressed.connect(_restore_author_worlds)
				if _ui_audio != null:
					_ui_audio.bind_control(restore)
				list.add_child(restore)
			else:
				rows = RecommendedSeeds.SEEDS
	if rows.is_empty() and list.get_child_count() == 0:
		var hint := Label.new()
		hint.text = {recent = "Здесь появятся последние миры", favorites = "Отметьте мир звёздочкой, и он останется здесь",
			recommended = "Автор пока ничего не рекомендовал", saved = "Сохранения появятся после начала игры"}[tab]
		hint.theme_type_variation = &"CaptionLabel"
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(hint)
	for r: Dictionary in rows:
		list.add_child(_seed_row(str(r.seed), str(r.get("note", ""))))
	_update_selection()
	_link_seed_rows(tab)
	if _is_screen("all_worlds") or %AllWorlds.visible:
		if restore_index >= 0:
			var target := _find_seed_row_focus(restore_seed, restore_index, restore_star)
			_grab_focus_quiet(target if target != null else _tab_button(tab))
		elif get_viewport().gui_get_focus_owner() == null:
			_grab_focus_quiet(_tab_button(tab))


func _link_seed_rows(tab: String) -> void:
	var row_nodes: Array[Dictionary] = []
	for child in %SeedList.get_children():
		if not (child.has_meta("select_button") and child.has_meta("star_button")):
			continue
		var sel := child.get_meta("select_button") as Button
		var st := child.get_meta("star_button") as Button
		if sel != null and st != null:
			row_nodes.append({select = sel, star = st})
	if row_nodes.is_empty():
		return
	var active_tab := _tab_button(tab)
	var side_target: Control = %Star if not %Star.disabled else %PlaySelected
	for i in row_nodes.size():
		var sel: Button = row_nodes[i].select
		var st: Button = row_nodes[i].star
		sel.focus_neighbor_right = sel.get_path_to(st)
		st.focus_neighbor_left = st.get_path_to(sel)
		st.focus_neighbor_right = st.get_path_to(side_target)
		sel.focus_neighbor_top = sel.get_path_to(row_nodes[i - 1].select if i > 0 else active_tab)
		st.focus_neighbor_top = st.get_path_to(row_nodes[i - 1].star if i > 0 else active_tab)
		sel.focus_neighbor_bottom = sel.get_path_to(row_nodes[i + 1].select if i + 1 < row_nodes.size() else %Storage)
		st.focus_neighbor_bottom = st.get_path_to(row_nodes[i + 1].star if i + 1 < row_nodes.size() else %Storage)


func _find_seed_row_focus(seed_text: String, fallback_idx: int, prefer_star: bool) -> Control:
	var rows := []
	for child in %SeedList.get_children():
		if child.has_meta("select_button"):
			rows.append(child)
	if rows.is_empty():
		return null
	var chosen: Node = null
	for child in rows:
		if child.has_meta("seed") and str(child.get_meta("seed")) == seed_text:
			chosen = child
			break
	if chosen == null:
		chosen = rows[mini(fallback_idx, rows.size() - 1)]
	var meta_key := "star_button" if prefer_star else "select_button"
	return chosen.get_meta(meta_key) as Control if chosen.has_meta(meta_key) else null


## Строка списка: соседние кнопки выбора мира и звёздочки в горизонтальном контейнере (без кнопки внутри кнопки)
func _seed_row(seed_text: String, note: String) -> PanelContainer:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	row.custom_minimum_size = Vector2(0, 60)
	row.set_meta("seed", seed_text)
	var outer := HBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	row.add_child(outer)
	var select_btn := Button.new()
	select_btn.toggle_mode = true
	select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	select_btn.custom_minimum_size = Vector2(0, 60)
	select_btn.set_meta("seed", seed_text)
	select_btn.theme_type_variation = &"ListRow"   # выбранный мир — золотая рамка
	select_btn.tooltip_text = seed_text if note.is_empty() else "%s — %s" % [seed_text, note]
	select_btn.pressed.connect(_pick_seed.bind(seed_text))
	select_btn.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.double_click and e.button_index == MOUSE_BUTTON_LEFT:
			select_btn.accept_event()
			_pick_seed(seed_text)
			_on_start())
	outer.add_child(select_btn)
	var box := HBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 10)
	select_btn.add_child(box)
	var tex := _preview_tex(seed_text)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(48, 48)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.texture = tex
	if tex == null:
		# мир ещё не запускали: вместо карты — тёмный квадрат с вопросом
		var empty := ColorRect.new()
		empty.color = Color(1, 1, 1, 0.06)
		empty.set_anchors_preset(Control.PRESET_FULL_RECT)
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var q := Label.new()
		q.text = "?"
		q.set_anchors_preset(Control.PRESET_FULL_RECT)
		q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		q.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		q.theme_type_variation = &"CaptionLabel"
		empty.add_child(q)
		thumb.add_child(empty)
	box.add_child(thumb)
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_theme_constant_override("separation", 0)
	var name_label := Label.new()
	name_label.text = seed_text
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_font_size_override("font_size", 15)
	texts.add_child(name_label)
	var ready: bool = _world_cards.get(seed_text, {}).get("ready", false)
	var sub := ("быстрый запуск" if note.is_empty() else note + " · быстрый запуск") if ready else note
	if not sub.is_empty():
		var sub_label := Label.new()
		sub_label.text = sub
		sub_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		sub_label.theme_type_variation = &"SectionLabel" if ready else &"CaptionLabel"
		sub_label.add_theme_font_size_override("font_size", 12)
		texts.add_child(sub_label)
	box.add_child(texts)
	var fav := seed_text in GameContext.scope.settings.favorite_seeds
	var star := Button.new()
	star.theme_type_variation = &"IconButton"
	star.icon = UiIcons.star(fav)
	star.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	star.custom_minimum_size = Vector2(44, 44)
	star.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var full := not fav and GameContext.scope.settings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX
	star.modulate = Color(0.62, 0.64, 0.68, 0.65) if full else Color.WHITE
	if full:
		star.set_meta(&"ui_sound_custom", true)
	star.tooltip_text = _star_tip(fav, full)
	star.pressed.connect(_on_star.bind(seed_text, star))
	outer.add_child(star)
	row.set_meta("select_button", select_btn)
	row.set_meta("star_button", star)
	if _ui_audio != null:
		_ui_audio.bind_control(select_btn)
		_ui_audio.bind_control(star)
	return row


func _star_tip(fav: bool, full: bool) -> String:
	if fav:
		return "Убрать из избранного"
	if full:
		return "Избранное заполнено (%d)" % GameSettings.FAVORITES_MAX
	return "В избранное: мир останется в списке и кэше"


func _pick_seed(seed_text: String) -> void:
	if not _world_cards.has(seed_text) and not seed_text.is_empty():
		_world_cards[seed_text] = _read_world_card(seed_text)
	_select_world(seed_text)


func _choose_typed() -> void:
	if not _is_screen("new_world"):
		_pick_seed(seed_edit.text.strip_edges())


func _on_seed_changed(_text: String) -> void:
	_choose_typed()


func _suggested_seed(seed_text: String) -> void:
	seed_edit.text = seed_text
	%CreateWorld.grab_focus()


func _select_world(seed_text: String) -> void:
	_selected_seed = seed_text
	if not _is_screen("new_world"):
		seed_edit.text = seed_text
	if not seed_text.is_empty() and seed_text not in _carousel_seeds:
		if _carousel_seeds.size() == Carousel.MAX_WORLDS:
			_carousel_seeds.pop_back()
		_carousel_seeds.push_front(seed_text)
		_update_carousel()
	else:
		(%Carousel as Carousel).show_world(seed_text, true)
	_update_selection()


func _chosen_seed() -> String:
	return seed_edit.text.strip_edges() if _is_screen("new_world") else _selected_seed


func _update_selection() -> void:
	var seed_text := _selected_seed
	var state: Dictionary = _world_cards.get(seed_text, {})
	var corrupt: bool = state.get("corrupt", false)
	var label := "Продолжить путешествие" if state.get("saved", false) else "Начать путешествие"
	%Start.text = "Все миры" if corrupt else label
	if seed_text.is_empty():
		%Start.text = "Создать мир"
	%PlaySelected.text = label
	%PlaySelected.disabled = corrupt or seed_text.is_empty()
	for row in %SeedList.get_children():
		var row_seed := str(row.get_meta("seed")) if row.has_meta("seed") else ""
		var select_btn := row.get_meta("select_button") as Button if row.has_meta("select_button") else null
		if select_btn != null:
			select_btn.set_pressed_no_signal(not seed_text.is_empty() and row_seed == seed_text)
		elif row is Button:
			(row as Button).set_pressed_no_signal(not seed_text.is_empty() and row_seed == seed_text)
	var tex: Texture2D = _previews.get(seed_text)
	%Preview.texture = tex
	%PreviewHint.visible = tex == null
	%PreviewHint.text = "Карта мира появится после первого запуска"
	%ChoiceName.text = "Мир не выбран" if seed_text.is_empty() else "«%s»" % seed_text
	%WorldStatus.text = state.get("summary", "")
	var star: Button = %Star
	var fav := seed_text in GameContext.scope.settings.favorite_seeds
	var full := not fav and GameContext.scope.settings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX
	star.icon = UiIcons.star(fav)
	star.disabled = seed_text.is_empty()
	star.modulate = Color(0.62, 0.64, 0.68, 0.65) if (full and not seed_text.is_empty()) else Color.WHITE
	if full:
		star.set_meta(&"ui_sound_custom", true)
	elif star.has_meta(&"ui_sound_custom"):
		star.remove_meta(&"ui_sound_custom")
	star.tooltip_text = _star_tip(fav, full)
	if corrupt:
		%WorldStatus.text = "Сохранение не читается. Можно создать мир заново; старые файлы сохранятся в архиве."
	_load_manual.disabled = not state.get("manual", false)
	%RestartWorld.disabled = seed_text.is_empty()
	%DeleteWorld.disabled = seed_text.is_empty()
	var settings := GameContext.scope.settings
	%ClearAllSaves.disabled = not _has_active_saves and _world_cards.is_empty() and settings.last_seed.is_empty()


## Время сохранения по часам компьютера (unix-время хранится в UTC)
static func _local_time_text(unix: int) -> String:
	var bias: int = Time.get_time_zone_from_system().get("bias", 0)
	return Time.get_datetime_string_from_unix_time(unix + bias * 60).replace("T", " ")


func _on_star_selected() -> void:
	var seed_text := _chosen_seed()
	if not seed_text.is_empty():
		_on_star(seed_text, %Star)


func _on_star(seed_text: String, source_button: Control = null) -> void:
	var settings := GameContext.scope.settings
	if not (seed_text in settings.favorite_seeds) and settings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX:
		_play_ui(&"error_deny")
		UiAudio.shake(source_button if is_instance_valid(source_button) else %Star, 4.0)
		_show_favorites_full_notice()
		return
	settings.toggle_favorite(seed_text)
	settings.save_settings()
	if GameContext.scope.cache.enabled:
		GameContext.scope.cache.keep_only(settings.keep_seeds())
	_previews.clear()
	_refresh_world_cards()
	_show_seed_tab(_seed_tab)


func _show_favorites_full_notice() -> void:
	var notice := get_node_or_null("%FavoritesNotice") as Label
	if notice == null:
		return
	if _favorites_notice_tween != null and _favorites_notice_tween.is_valid():
		_favorites_notice_tween.kill()
		_favorites_notice_tween = null
	notice.text = "Избранное заполнено (%d)" % GameSettings.FAVORITES_MAX
	notice.visible = true
	if DisplayServer.get_name() == "headless" or not is_processing():
		notice.modulate.a = 1.0
		return
	notice.modulate.a = 0.0
	_favorites_notice_tween = create_tween()
	_favorites_notice_tween.tween_property(notice, "modulate:a", 1.0, 0.12).set_trans(Tween.TRANS_SINE)
	_favorites_notice_tween.tween_interval(2.0)
	_favorites_notice_tween.tween_property(notice, "modulate:a", 0.0, 0.25).set_trans(Tween.TRANS_SINE)
	_favorites_notice_tween.tween_callback(func() -> void:
		_favorites_notice_tween = null
		notice.visible = false
		notice.modulate.a = 1.0)


func _restart_world() -> void:
	var seed_text := _chosen_seed()
	if seed_text.is_empty():
		return
	_ask("Создать мир заново?", "Мир «%s» будет сгенерирован заново, путешествие начнётся сначала. Старые сохранения будут перенесены в архив." % seed_text, "Создать заново", true, _do_restart_world.bind(seed_text), %RestartWorld)


func _do_restart_world(seed_text: String) -> void:
	var err := Saves.archive_seed(seed_text)
	if err == OK and GameContext.scope.cache.enabled:
		err = GameContext.scope.cache.remove_seed(seed_text)
	if err != OK:
		_message("Не удалось пересоздать мир", error_string(err))
		_refresh_world_cards()
		_show_seed_tab(_seed_tab)
		return
	_previews.erase(seed_text)
	GameContext.scope.settings.remember_seed(seed_text)
	GameContext.scope.settings.save_settings()
	_play_ui(&"confirm")
	start_game(seed_text, WorldGenerator.START_SIZE, "", false)


func _delete_world() -> void:
	var seed_text := _chosen_seed()
	if seed_text.is_empty():
		return
	_ask("Удалить мир?", "Мир «%s» будет удалён из недавних и избранного вместе с текущими сохранениями и готовыми данными. Рекомендованные миры останутся в списке автора." % seed_text, "Удалить", true, _do_delete_world.bind(seed_text), %DeleteWorld)


func _do_delete_world(seed_text: String) -> void:
	var previous_index := maxi(0, _carousel_seeds.find(seed_text))
	var err := Saves.delete_seed(seed_text)
	if err == OK and GameContext.scope.cache.enabled:
		err = GameContext.scope.cache.remove_seed(seed_text)
	if err != OK:
		_message("Не удалось удалить мир", error_string(err))
		_refresh_world_cards()
		_show_seed_tab(_seed_tab)
		return
	GameContext.scope.settings.recent_seeds.erase(seed_text)
	GameContext.scope.settings.favorite_seeds.erase(seed_text)
	if GameContext.scope.settings.last_seed == seed_text:
		GameContext.scope.settings.last_seed = ""
	GameContext.scope.settings.save_settings()
	_previews.erase(seed_text)
	_refresh_world_cards(seed_text, previous_index)
	_show_seed_tab(_seed_tab)


## Хранилище миров: сколько готовых миров и места; очистка не трогает сохранения прогресса
func _open_storage() -> void:
	var u := GameContext.scope.cache.usage() if GameContext.scope.cache.enabled else {worlds = 0, bytes = 0}
	var body := "Готовых миров нет." if u.worlds == 0 else "Готовых миров: %d, занято %d МБ." % [u.worlds, roundi(u.bytes / 1048576.0)]
	body += "\nНедавние и избранные миры хранятся готовыми и открываются быстрее. Если очистить, они создадутся заново при запуске; сохранения прогресса и задания останутся."
	_ask("Хранилище миров", body, "Очистить", true, _on_clear_cache, %Storage)
	_confirm.get_ok_button().disabled = u.worlds == 0
	_confirm.cancel_button_text = "Закрыть"


func _on_clear_cache() -> void:
	GameContext.scope.cache.keep_only([])
	_previews.clear()
	_refresh_world_cards()
	_show_seed_tab(_seed_tab)


func _clear_all_saves() -> void:
	if busy or game != null or not _is_screen("all_worlds") or %ClearAllSaves.disabled:
		return
	_ask("Очистить все сохранения?", "Автоматические, ручные и резервные сохранения будут перенесены в архив. Все миры исчезнут из меню, а списки недавних и избранных очистятся.",
		"Очистить", true, _do_clear_all_saves, %ClearAllSaves)


func _do_clear_all_saves() -> void:
	if busy or game != null:
		return
	var settings := GameContext.scope.settings
	var last := settings.last_seed
	var recent := settings.recent_seeds.duplicate()
	var favorites := settings.favorite_seeds.duplicate()
	var hidden := settings.hide_recommended_worlds
	settings.last_seed = ""
	settings.recent_seeds = []
	settings.favorite_seeds = []
	settings.hide_recommended_worlds = true
	var err := settings.save_settings()
	if err == OK:
		err = Saves.archive_all()
		if err != OK:
			_message("Не удалось перенести все сохранения", error_string(err))
	else:
		_message("Не удалось очистить список миров", error_string(err))
	if err != OK:
		settings.last_seed = last
		settings.recent_seeds = recent
		settings.favorite_seeds = favorites
		settings.hide_recommended_worlds = hidden
		var restore_error := settings.save_settings()
		if restore_error != OK:
			push_warning("Не удалось восстановить списки миров на диске: " + error_string(restore_error))
		_refresh_world_cards()
		_show_seed_tab(_seed_tab)
		return
	_previews.clear()
	_selected_seed = ""
	_sync_author_suggestions()
	_refresh_world_cards()
	_show_seed_tab("saved")
	_show("menu")


func _restore_author_worlds() -> void:
	var settings := GameContext.scope.settings
	settings.hide_recommended_worlds = false
	var err := settings.save_settings()
	if err != OK:
		settings.hide_recommended_worlds = true
		_message("Не удалось показать рекомендации", error_string(err))
		return
	_sync_author_suggestions()
	_refresh_world_cards()
	_show_seed_tab("recommended")
	_grab_focus_quiet(%Recommended)


func _fit_menu() -> void:
	var vs := get_viewport().get_visible_rect().size
	var worlds: Control = %AllWorlds.get_node("Panel")
	worlds.custom_minimum_size = Vector2(clampf(vs.x * 0.75, 920.0, 1220.0), clampf(vs.y * 0.80, 550.0, 700.0))
	if _backdrop != null:
		_backdrop.resize(_backdrop_size())


func _process(delta: float) -> void:
	if _ui_stack != null:
		_ui_stack.tick()
	if display_options != null:
		display_options.tick()
	if _is_screen("settings"):
		_update_control_hint()
	_flush_settings()
	if _backdrop_mode == "live" and get_window().mode != Window.MODE_MINIMIZED:
		_animate_menu(delta)
	if _auto_save_task != -1 and WorkerThreadPool.is_task_completed(_auto_save_task):
		_finish_auto_save()
	if _progress_enabled and game != null and not busy and not game.paused and not game.travel_active():
		_save_elapsed += delta
		if _auto_save_task == -1 and (_save_elapsed >= 60.0 or hud.map_place_count() != _saved_discoveries):
			_queue_auto_save()
	if busy:
		bar.value = lerpf(bar.value, _progress_target, Util.damp(8.0, delta))
		var seconds := (Time.get_ticks_msec() - _load_started_ms) / 1000
		if seconds != _load_elapsed and (_load_step_tween == null or not _load_step_tween.is_valid()):
			_load_elapsed = seconds
			load_step.text = "%s\nПрошло: %d:%02d" % [_load_label, seconds / 60, seconds % 60]


# ---------- Старт игры ----------

## Лаборатория — отдельная сцена, без запуска/сохранения выбранного мира.
func _open_trail_lab() -> void:
	if busy or game != null or trail_lab != null or not _is_screen("menu"):
		return
	trail_lab = (load(TRAIL_LAB_SCENE) as PackedScene).instantiate()
	trail_lab.exit_requested.connect(_close_trail_lab)
	hud.visible = false
	_show("", {instant = true})
	add_child(trail_lab)


func _close_trail_lab() -> void:
	if trail_lab == null:
		return
	trail_lab.shutdown()
	trail_lab.queue_free()
	trail_lab = null
	_show("menu", {instant = true})


func _on_start() -> void:
	# второй запуск во время загрузки не нужен: мир уже строится
	if busy:
		return
	if _is_screen("new_world"):
		_on_create_world()
		return
	if _selected_seed.is_empty():
		_open_new_world()
		return
	_launch_seed(_selected_seed)


func _on_create_world() -> void:
	if not busy:
		_launch_seed(seed_edit.text.strip_edges())


func _launch_seed(seed_text: String) -> void:
	if seed_text.is_empty():
		seed_text = random_seed()
		seed_edit.text = seed_text   # случайное зерно видно в поле, его можно повторить
	var latest := _latest_save(seed_text)
	if latest.data.is_empty() and _has_save(seed_text):
		_world_cards[seed_text] = _read_world_card(seed_text)
		if seed_text not in _saved_seeds:
			_saved_seeds.append(seed_text)
		_pick_seed(seed_text)
		_update_carousel()
		_open_all_worlds()
		_grab_focus_quiet(%RestartWorld)
		return
	_pick_seed(seed_text)
	GameContext.scope.settings.remember_seed(seed_text)
	GameContext.scope.settings.save_settings()
	_play_ui(&"confirm")
	var launch_btn: Button = %CreateWorld if _is_screen("new_world") else (%PlaySelected if _is_screen("all_worlds") else %Start)
	UiAudio.pulse_confirm(launch_btn)
	start_game(seed_text, WorldGenerator.START_SIZE, latest.slot)


## С 9.0 мир один: план 768 × 768 генерируется всегда целиком, size — только окно, открытое на старте.
## С 9.8 по умолчанию открыт весь план; меньшее окно ставят инструменты проверки (WorldData.open_around).
func start_game(seed_text: String, size: int = WorldGenerator.START_SIZE, slot := "", allow_bundled := true) -> void:
	if busy:
		return
	# каталог моделей устарел или не найден: мир не запускаем (в релизной сборке assert отключён)
	var catalog_error: String = preload("res://scripts/render/asset_catalog.gd").check()
	if not catalog_error.is_empty():
		_message("Каталог моделей не подготовлен", catalog_error)
		return
	if not _save_current():
		return
	_pending_save = {}
	if not slot.is_empty():
		var result := Saves.read_slot(seed_text, slot)
		if result.data.is_empty():
			_message("Ошибка загрузки", result.error)
			return
		_pending_save = result.data
		if result.backup:
			_message("Резервная копия", "Основное сохранение повреждено. Загружается предыдущая исправная копия.")
	busy = true
	_progress_target = 0.0
	_load_cancel_requested = false
	_load_quit_requested = false
	_load_cancel_flag = CancelFlag.new()
	_load_started_ms = Time.get_ticks_msec()
	_free_game()
	hud.visible = false
	_load_label = ""
	_set_progress(0.0, "Подготовка")
	var cancel_btn := get_node_or_null("%CancelLoad") as Button
	if cancel_btn != null:
		cancel_btn.visible = true
		cancel_btn.disabled = false
		cancel_btn.text = "Отменить"
	%LoadPreview.texture = _preview_tex(seed_text)
	%LoadPreview.visible = %LoadPreview.texture != null
	%LoadPlaceholder.visible = not %LoadPreview.visible
	%LoadPlaceholder.text = seed_text
	%Title.text = "Мир «%s»" % seed_text
	%Title.tooltip_text = %Title.text
	_show("loading", {enter_duration = 0.18, exit_duration = 0.14})
	gen_thread = Thread.new()
	var start_at := Vector2(_pending_save.player.x, _pending_save.player.z) if not _pending_save.is_empty() else Vector2.INF
	gen_thread.start(_generate_job.bind(seed_text, size, start_at, allow_bundled, Time.get_ticks_usec(), _load_cancel_flag))


func _generate_job(seed_text: String, size: int, start_at: Vector2, allow_bundled: bool, dispatched_us: int, cancel_flag: CancelFlag) -> void:
	var entered_us := Time.get_ticks_usec()
	var cache := GameContext.scope.cache
	if cache.enabled and not cancel_flag.is_cancelled():
		cache.keep_only(GameContext.scope.settings.keep_seeds())
		if allow_bundled and not QuickTrails.active() and size == WorldGenerator.START_SIZE and not cancel_flag.is_cancelled():
			cache.install_bundled(WorldCache.BUNDLED, seed_text)
	if cancel_flag.is_cancelled():
		var aborted := WorldLoader.new()
		aborted.cancelled = true
		_on_world_ready.call_deferred(aborted, cancel_flag)
		return
	var before_loader_us := Time.get_ticks_usec()
	var loaded := WorldLoader.load_world(seed_text, size, func(p: float, label: String) -> void:
		_set_progress.call_deferred(p, label), null, start_at, cancel_flag.is_cancelled)
	if loaded == null:
		# ошибка скрипта оборвала загрузку: вернуть меню, а не держать экран загрузки вечно
		_on_world_failed.call_deferred(cancel_flag)
		return
	var ready_us := Time.get_ticks_usec()
	loaded.timings.thread_dispatch_ms = (entered_us - dispatched_us) / 1000.0
	loaded.timings.before_loader_ms = (before_loader_us - entered_us) / 1000.0
	loaded.timings.loader_call_ms = (ready_us - before_loader_us) / 1000.0
	loaded.timings.ready_queued_us = ready_us
	_on_world_ready.call_deferred(loaded, cancel_flag)


func _on_world_failed(cancel_flag: CancelFlag = null) -> void:
	if gen_thread != null and gen_thread.is_started():
		gen_thread.wait_to_finish()
	busy = false
	var want_quit := _load_quit_requested
	var was_cancelled := _load_cancel_requested or (cancel_flag != null and cancel_flag.is_cancelled())
	_load_cancel_requested = false
	_load_quit_requested = false
	_load_cancel_flag = null
	if want_quit:
		_exit_game()
		return
	_show("menu")
	if not was_cancelled:
		_message("Мир не подготовлен", "Генерация прервалась с ошибкой. Подробности в журнале godot.log.")


func _on_cancel_load_pressed() -> void:
	_cancel_loading(false)


func _cancel_loading(quit_after: bool) -> void:
	if not busy:
		return
	if quit_after:
		_load_quit_requested = true
	else:
		_load_cancel_requested = true
	if _load_cancel_flag != null:
		_load_cancel_flag.cancel()
	var cancel_btn := get_node_or_null("%CancelLoad") as Button
	if cancel_btn != null:
		cancel_btn.disabled = true
		cancel_btn.text = "Ожидание остановки потока…"
	_set_progress(_progress_target, "Завершение загрузки перед выходом…\nОжидание остановки потока" if _load_quit_requested else "Отмена загрузки…\nОжидание завершения текущего этапа")
	_play_ui(&"panel_close")


func _set_progress(p: float, label: String) -> void:
	_progress_target = clampf(p, 0.0, 1.0)
	if not busy or p <= 0.0:
		bar.value = _progress_target
	var changed := label != _load_label
	_load_label = label
	_load_elapsed = -1
	if not changed:
		return
	if _load_step_tween != null and _load_step_tween.is_valid():
		_load_step_tween.kill()
		_load_step_tween = null
	if not busy or not %Loading.visible or DisplayServer.get_name() == "headless" or not is_processing():
		load_step.modulate.a = 1.0
		load_step.text = label
		return
	_load_step_tween = create_tween()
	_load_step_tween.tween_property(load_step, "modulate:a", 0.0, 0.06).set_trans(Tween.TRANS_SINE)
	_load_step_tween.tween_callback(func() -> void:
		var sec := (Time.get_ticks_msec() - _load_started_ms) / 1000
		_load_elapsed = sec
		load_step.text = "%s\nПрошло: %d:%02d" % [_load_label, sec / 60, sec % 60])
	_load_step_tween.tween_property(load_step, "modulate:a", 1.0, 0.06).set_trans(Tween.TRANS_SINE)
	_load_step_tween.tween_callback(func() -> void:
		_load_step_tween = null)


func _on_world_ready(loaded: WorldLoader, cancel_flag: CancelFlag = null) -> void:
	loaded.timings.ready_queue_ms = (Time.get_ticks_usec() - int(loaded.timings.get("ready_queued_us", Time.get_ticks_usec()))) / 1000.0
	loaded.timings.erase("ready_queued_us")
	if gen_thread != null and gen_thread.is_started():
		gen_thread.wait_to_finish()
	if loaded.cancelled or _load_cancel_requested or _load_quit_requested or (cancel_flag != null and cancel_flag.is_cancelled()):
		busy = false
		var want_quit := _load_quit_requested
		_load_cancel_requested = false
		_load_quit_requested = false
		_load_cancel_flag = null
		if want_quit:
			_exit_game()
		else:
			_show("menu", {sound = &"panel_close"})
		return
	if not loaded.error.is_empty():
		busy = false
		_load_cancel_flag = null
		_show("menu")
		_message("Мир не подготовлен", loaded.error)
		return
	if not _pending_save.is_empty() and not load(GAME_SCRIPT).can_restore(_pending_save, loaded.world):
		busy = false
		_load_cancel_flag = null
		_show("menu")
		_message("Мир изменился", "Места этого мира изменились после обновления. Сохранение оставлено без изменений. Нажмите «Создать заново», чтобы пересоздать этот мир и начать новое путешествие.")
		return
	# GameWorld.start идёт в главном потоке: подпись должна успеть показаться до него
	_set_progress(0.97, "Окружение вокруг игрока")
	var phase_started := Time.get_ticks_usec()
	await get_tree().process_frame
	if _load_cancel_requested or _load_quit_requested or (cancel_flag != null and cancel_flag.is_cancelled()):
		busy = false
		var want_quit := _load_quit_requested
		_load_cancel_requested = false
		_load_quit_requested = false
		_load_cancel_flag = null
		if want_quit:
			_exit_game()
		else:
			_show("menu", {sound = &"panel_close"})
		return
	loaded.timings.ready_frame_wait_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	phase_started = Time.get_ticks_usec()
	game = (load(GAME_SCENE) as PackedScene).instantiate()
	game.pause_requested.connect(_toggle_pause)
	add_child(game)
	loaded.timings.game_scene_create_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	phase_started = Time.get_ticks_usec()
	game.start(loaded, hud, _pending_save)
	if not loaded.error.is_empty():
		_free_game()
		hud.visible = false
		busy = false
		_load_cancel_flag = null
		_show("menu")
		_message("Мир не подготовлен", loaded.error)
		return
	loaded.timings.game_start_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	_set_progress(1.0, "Готово")
	var cancel_btn := get_node_or_null("%CancelLoad") as Button
	if cancel_btn != null:
		cancel_btn.visible = false
	# 15.1: первые кадры мира собирают шейдеры и буферы (стресс-тест: кадры 47–67 мс и прогрев до 260 мс у точки
	# появления) — пусть это идёт под заставкой загрузки, а не на глазах игрока. Инструменты (main не главная сцена)
	# берут мир сразу, как раньше.
	phase_started = Time.get_ticks_usec()
	for i in 30 if _progress_enabled else 0:
		await get_tree().process_frame
		if game == null or _load_cancel_requested or _load_quit_requested or Time.get_ticks_usec() - phase_started > 400000:
			break
	loaded.timings.first_frames_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	if _load_cancel_requested or _load_quit_requested or (cancel_flag != null and cancel_flag.is_cancelled()):
		_free_game()
		hud.visible = false
		busy = false
		var want_quit := _load_quit_requested
		_load_cancel_requested = false
		_load_quit_requested = false
		_load_cancel_flag = null
		if want_quit:
			_exit_game()
		else:
			_show("menu", {sound = &"panel_close"})
		return
	if game == null:
		busy = false
		_load_cancel_flag = null
		return
	_save_elapsed = 0.0
	_saved_discoveries = hud.map_place_count()
	game.quests.changed.connect(func() -> void: _save_elapsed = 60.0)
	phase_started = Time.get_ticks_usec()
	if _pending_save.is_empty():
		_save_current()
	loaded.timings.initial_save_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	busy = false
	_load_cancel_flag = null
	_load_cancel_requested = false
	_load_quit_requested = false
	hud.set_map_visible(false)
	var show_hud: bool = not game.opening_active()
	if _ui_stack != null and _progress_enabled and DisplayServer.get_name() != "headless":
		_fade_hud(show_hud, 0.22)
		_active_screen = ""
		_ui_stack.dissolve_to_world(%Back, %Loading, 0.28)
		_set_backdrop_mode("")
	else:
		_fade_hud(show_hud, 0.0)
		_show("", {instant = true})
	loaded.timings.published_us = Time.get_ticks_usec()


func _cancel_hud_fade() -> void:
	if _hud_fade != null and _hud_fade.is_valid():
		_hud_fade.kill()
	_hud_fade = null
	if hud != null:
		hud.modulate.a = 1.0
		hud.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED


func _fade_hud(show_hud: bool, duration: float) -> void:
	_cancel_hud_fade()
	if hud == null:
		return
	if duration <= 0.0 or DisplayServer.get_name() == "headless" or not is_processing():
		hud.visible = show_hud
		hud.modulate.a = 1.0
		hud.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED
		return
	if show_hud:
		hud.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED
		if not hud.visible:
			hud.modulate.a = 0.0
			hud.visible = true
		_hud_fade = create_tween()
		_hud_fade.tween_property(hud, "modulate:a", 1.0, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_hud_fade.tween_callback(func() -> void: _hud_fade = null)
	else:
		if not hud.visible:
			return
		hud.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_DISABLED
		_hud_fade = create_tween()
		_hud_fade.tween_property(hud, "modulate:a", 0.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_hud_fade.tween_callback(func() -> void:
			_hud_fade = null
			if hud != null:
				hud.visible = false
				hud.modulate.a = 1.0
				hud.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED)


func _toggle_pause() -> void:
	if game == null:
		return
	if _is_screen("settings"):
		if display_options != null and display_options.close_open_popup():
			return
		if display_options != null and display_options.pending():
			display_options.revert()
			return
		_close_settings()
	elif game.paused:
		_resume()
	else:
		game.set_paused(true)
		_save_current()
		_fade_hud(false, 0.18)   # подсказки и сообщения не лезут поверх панели паузы
		%PauseWorld.text = "Мир «%s»" % game.world.seed_text
		if _ui_stack != null:
			_active_screen = "pause"
			_ui_stack.push("pause", {
				dimmer = 0.55,
				enter_duration = 0.20,
				exit_duration = 0.14,
				dimmer_duration = 0.18,
				sound = &"panel_open",
			})
			_sync_backdrop_visibility("pause")
			_focus_screen_default("pause")
		else:
			_show("pause")


func _resume() -> void:
	_close_confirm()
	if _ui_stack != null and _ui_stack.is_open("pause"):
		_active_screen = ""
		_ui_stack.pop({sound = &"panel_close", exit_duration = 0.14, dimmer_duration = 0.14})
		_sync_backdrop_visibility("")
	else:
		_show("")
	_fade_hud(not game.opening_active(), 0.14)
	game.set_paused(false)
	# щелчок по кнопке «Продолжить» не должен сразу считаться щелчком по миру
	get_viewport().gui_release_focus()


## Мир живёт, пока на него ссылаются игра и интерфейс: обе ссылки снимаются здесь, а внутри мира ссылок
## наверх нет (рельеф за краем знает только размер карты), поэтому он освобождается сам целиком.
## Проверка: tools/lifecycle_test.gd
func _free_game() -> void:
	_cancel_hud_fade()
	if GameContext.scope.resource_profile != null: GameContext.scope.resource_profile.save()
	if game != null:
		game.queue_free()
		game = null
	hud.clear_world()
	TrailRouter.release()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Уход из мира — только с подтверждением: случайное нажатие не закрывает мир (его загрузка — до минуты)
func _confirm_to_menu() -> void:
	_ask("Выйти в главное меню?", "Прогресс сохранится. Мир закроется, снова его загружать придётся с экрана загрузки.",
		"В меню", false, _back_to_menu, get_node_or_null("%ToMenu") as Control)


func _confirm_exit() -> void:
	if game == null:
		_exit_game()
		return
	_ask("Выйти из игры?", "Прогресс сохранится, игра закроется.", "Выйти", true, _exit_game, get_node_or_null("%Exit") as Control)


## Подтверждение; фокус на «Остаться», чтобы Enter по привычке ничего не закрыл
func _ask(title: String, body: String, ok_text: String, danger: bool, action: Callable, return_focus: Control = null) -> void:
	_close_confirm()
	_confirm_return_focus = return_focus
	var dialog := ConfirmationDialog.new()
	_confirm = dialog
	dialog.title = title
	dialog.dialog_text = body
	dialog.dialog_autowrap = true
	dialog.ok_button_text = ok_text
	dialog.cancel_button_text = "Остаться"
	if danger:
		dialog.get_ok_button().theme_type_variation = &"DangerButton"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		_confirm_return_focus = null
		_close_confirm()
		action.call())
	dialog.canceled.connect(_cancel_confirm)
	dialog.window_input.connect(func(ev: InputEvent) -> void:
		if ev.is_echo():
			return
		var pad := ev as InputEventJoypadButton
		if (pad != null and pad.pressed and pad.button_index == JOY_BUTTON_B) or ev.is_action_pressed("back"):
			dialog.set_input_as_handled()
			_cancel_confirm())
	dialog.popup_centered(Vector2i(440, 0))
	_grab_focus_quiet(dialog.get_cancel_button())


func _cancel_confirm() -> void:
	var target := _confirm_return_focus
	_confirm_return_focus = null
	_close_confirm()
	_restore_focus(target)


func _close_confirm() -> void:
	_confirm_return_focus = null
	if _confirm != null:
		_confirm.hide()   # скрыть сразу: до удаления окно ещё держит модальность
		_confirm.queue_free()
		_confirm = null


func _back_to_menu() -> void:
	if not _save_current():
		return
	_cancel_hud_fade()
	_free_game()
	hud.visible = false
	_previews.clear()   # после игры у мира появилось или обновилось превью
	_refresh_world_cards()
	_show("menu")


func _exit_game() -> void:
	if display_options != null:
		display_options.revert()
	if busy:
		_cancel_loading(true)
		return
	if not _save_current():
		return
	if _save_due >= 0:
		# настройка изменена меньше чем 400 мс назад: на диск ещё не записана
		_save_due = -1
		GameContext.scope.settings.save_settings()
	_set_backdrop_mode("")
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_exit_game()


func _latest_save(seed_text: String, manual := {}) -> Dictionary:
	var auto := Saves.read_slot(seed_text)
	if manual.is_empty():
		manual = Saves.read_slot(seed_text, "manual")
	var use_manual: bool = not manual.data.is_empty() and (auto.data.is_empty() or manual.data.saved_at > auto.data.saved_at)
	var result: Dictionary = manual if use_manual else auto
	result.slot = ("manual" if use_manual else "auto") if not result.data.is_empty() else ""
	return result


func _has_save(seed_text: String) -> bool:
	for slot: String in ["auto", "manual"]:
		var path := Saves.path_for(seed_text, slot)
		if FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak"):
			return true
	return false


func _save_current(slot := "auto") -> bool:
	if game == null or game.quests == null or not _progress_enabled:
		return true
	# Перед выходом или сменой мира новая запись должна идти после фоновой записи того же слота.
	_finish_auto_save(false)
	var err := Saves.write_slot(game.save_state(), slot)
	if err == OK:
		_saved_discoveries = hud.map_place_count()
	return _report_save(err, slot)


func _queue_auto_save() -> void:
	var state: Dictionary = game.save_state()
	var result := {discoveries = hud.map_place_count(), error = ERR_BUSY}
	_auto_save_result = result
	_save_elapsed = 0.0
	_auto_save_task = WorkerThreadPool.add_task(func() -> void:
		result.error = Saves.write_slot(state), false, "Автосохранение")


func _finish_auto_save(report := true) -> void:
	if _auto_save_task == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_auto_save_task)
	_auto_save_task = -1
	var err: Error = _auto_save_result.error
	if err == OK:
		_saved_discoveries = _auto_save_result.discoveries
	_auto_save_result = {}
	if report:
		_report_save(err, "auto")


func _report_save(err: Error, slot: String) -> bool:
	_save_status.text = ("Ручное сохранение записано" if slot == "manual" else "Автосохранение записано") if err == OK else "Ошибка сохранения: " + error_string(err)
	if err != OK:
		_message("Не удалось сохранить", "Прогресс остаётся в текущей игре. Освободите место и повторите сохранение.\n" + error_string(err))
	return err == OK


func _message(title: String, body: String) -> void:
	if game != null and not game.paused and not busy:
		game.set_paused(true)
		hud.visible = false
		_show("pause")
	var dialog := AcceptDialog.new()
	dialog.title = title
	dialog.dialog_text = body
	dialog.dialog_autowrap = true
	add_child(dialog)
	dialog.popup_centered(Vector2i(520, 180))
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)


func _confirm_load(seed_text: String, slot: String) -> void:
	var opener: Control = _load_manual if _is_screen("all_worlds") else (get_node_or_null("%QuickLoad") as Control)
	_ask("Загрузить сохранение?", "Текущий прогресс будет записан в автосохранение.\nЗатем загрузится ручное сохранение этого мира.",
		"Загрузить", false, start_game.bind(seed_text, WorldGenerator.START_SIZE, slot), opener)


## Кнопки сохранения стоят в сцене (меню — «Загрузить ручное», пауза — быстрое сохранение и загрузка),
## здесь только поведение и подсказки управления паузы
func _setup_save_controls() -> void:
	%RestartWorld.pressed.connect(_restart_world)
	%DeleteWorld.pressed.connect(_delete_world)
	_load_manual = %LoadManual
	_load_manual.pressed.connect(func() -> void: _confirm_load(_chosen_seed(), "manual"))
	_save_status = %SaveStatus
	%QuickSave.pressed.connect(func() -> void: _save_current("manual"))
	# «Путешествие» из паузы: пауза снимается, экран открывается поверх игры (закрыть — J, Esc или кнопка)
	%Journey.pressed.connect(func() -> void:
		if game == null:
			return
		_resume()
		game.open_journal())
	%QuickLoad.pressed.connect(func() -> void:
		if Saves.read_slot(game.world.seed_text, "manual").data.is_empty():
			_message("Загрузка", "Ручного сохранения пока нет. Нажмите «Сохранить».")
		else:
			_confirm_load(game.world.seed_text, "manual"))
	_fill_controls()


## Подсказки управления в паузе: клавиша — действие, по две пары в строке.
## Подписи берутся из раскладки (Controls.label): клавиатура или геймпад, как играют сейчас; перестраиваются при открытии паузы.
func _control_rows() -> Array:
	var c: Controls = GameContext.scope.controls
	var pad := c.joypad
	var rows: Array = [
		["Правый стик" if pad else "Мышь", "осмотреться"], ["Левый стик" if pad else "WASD", "идти"],
		[c.label(&"run"), "бег, рывок на велосипеде"], [c.label(&"jump"), "прыжок"],
	]
	if not pad:
		rows.append([c.label(&"bike_pump"), "памп на велосипеде (держать)"])
		rows.append(["%s → %s" % [c.label(&"bike_back"), c.label(&"bike_forward")], "баннихоп"])
	rows.append([c.label(&"interact"), "взаимодействовать, сесть / слезть"])
	rows.append([c.label(&"flashlight"), "фонарик"])
	rows.append([c.label(&"recover_bike"), "выбрать место для велосипеда"])
	rows.append([c.label(&"toggle_map"), "карта"])
	rows.append([c.label(&"journal"), "путешествие: путь и альбом"])
	rows.append([c.label(&"photo") if pad else "ПКМ", "фотоаппарат"])
	if not pad:
		rows.append([c.label(&"time_skip"), "время суток (+Shift — назад)"])
	rows.append([c.label(&"show_hud"), "сводка (показать / скрыть)"])
	rows.append([c.label(&"pause"), "пауза"])
	return rows


func _update_control_hint() -> void:
	var controls := GameContext.scope.controls
	var caption := "%s — взаимодействовать · %s — показать или скрыть сводку" % [
		controls.label(&"interact"), controls.label(&"show_hud"),
	]
	if %ActionBindings.text != caption:
		%ActionBindings.text = caption


func _fill_controls() -> void:
	var grid: GridContainer = %Controls
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	var rows := _control_rows()
	if rows.size() % 2 == 1:
		rows.append(["", ""])
	for pair: Array in rows:
		var key := Label.new()
		if not pair[0].is_empty():   # пустая пара — выравнивание последней строки, без рамки клавиши
			key.theme_type_variation = &"KeyLabel"
		key.text = pair[0]
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key.custom_minimum_size.x = 64
		grid.add_child(key)
		var what := Label.new()
		what.theme_type_variation = &"HintLabel"
		what.text = pair[1]
		what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(what)


func _exit_tree() -> void:
	_backdrop_epoch += 1
	_cancel_hud_fade()
	for tw: Tween in [_load_step_tween, _favorites_notice_tween, _parallax_tween]:
		if tw != null and tw.is_valid():
			tw.kill()
	_load_step_tween = null
	_favorites_notice_tween = null
	_parallax_tween = null
	if _load_cancel_flag != null:
		_load_cancel_flag.cancel()
	_finish_auto_save(false)
	if display_options != null:
		display_options.shutdown()
	if gen_thread != null and gen_thread.is_started():
		gen_thread.wait_to_finish()
	GameContext.scope.cache.wait_writes()   # мир дописывается в кэш в фоне; оборванная запись осталась бы только .tmp
