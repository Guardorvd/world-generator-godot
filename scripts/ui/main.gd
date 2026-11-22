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
const SessionPerformance := preload("res://scripts/game/session_performance.gd")
const DisplayOptions := preload("res://scripts/ui/display_options.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const Carousel := preload("res://scripts/ui/world_carousel.gd")
const Backdrop := preload("res://scripts/ui/menu_backdrop.gd")
const UiAudio := preload("res://scripts/ui/ui_audio.gd")
const UiStack := preload("res://scripts/ui/ui_stack.gd")
const ShopPanel := preload("res://scripts/ui/shop_panel.gd")


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
const HUB_ROW_BUDGET_USEC := 5000
const LOAD_ENTER_SECONDS := 0.18
const LOAD_STEP_SECONDS := 0.12
const LOAD_DISSOLVE_SECONDS := 0.28
const LOAD_WARMUP_FRAMES := 30
# Заставка запуска: цвет совпадает с application/boot_splash/bg_color, меню проявляется уже с живым фоном.
const STARTUP_COVER_COLOR := Color(0.043, 0.051, 0.059)
const STARTUP_COVER_LIMIT := 6.0
const STARTUP_REVEAL := 0.45
const WIND := "res://resources/sounds/wind.wav"
const BIRDS := ["res://resources/sounds/bird_1.wav", "res://resources/sounds/bird_2.wav", "res://resources/sounds/bird_3.wav"]

var game: Node # GameWorld; без типа, чтобы меню не тянуло скрипты игры при запуске
var trail_lab: Node
var busy := false
var startup_render_frames := 0 # инструменты замера могут включить прогрев без записи прогресса
var gen_thread: Thread
var _load_started_ms := 0
var _load_elapsed := -1
var _settings_from := "menu"   # куда вернуться из настроек
var _seed_tab := "all"      # фильтр единого списка: all, saved, favorites
var _hub_rows := {}
var _hub_rank := {}
var _hub_build_queue: Array[String] = []
var _hub_reveal_seed := ""
var _hub_needs_sync := true
var _hub_preview_scan := false
var _hub_preview_queue: Array[String] = []
var _hub_preview_task := -1
var _hub_preview_result := {}
var _hub_preview_epoch := 0
var _previews := {}            # зерно -> превью карты из кэша (ImageTexture) или null
var _world_cards := {}         # зерно -> состояние, проверенное при обновлении списка
var _saved_seeds: Array = []
var _carousel_seeds: Array[String] = []
var _selected_seed := ""
var _card_reads := 0
var _has_active_saves := false
var _pending_save := {}
var _save_elapsed := 0.0
var _auto_save_task := -1
var _auto_save_result := {}
var _save_status: Label
var _load_manual: Button
var _saved_discoveries := 0
const AUTO_SAVE_GAP_MS := 2500  # мс между автосохранениями по открытиям мест
var _auto_save_at_ms := -AUTO_SAVE_GAP_MS
var _progress_enabled := false # инструменты не записывают пользовательский прогресс
var _session_performance: SessionPerformance
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
var _shop: ShopPanel
var _shop_progress: ShopPanel.Progress
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
@onready var load_previous_step: Label = %PreviousStep
@onready var load_elapsed: Label = %LoadElapsed
@onready var cancel_load_button: Button = %CancelLoad
@onready var screens := {back = %Back, menu = %Menu, world_hub = %AllWorlds,
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


func _cmdline_seed() -> String:
	if OS.has_feature("template"):
		return ""
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--seed" and i + 1 < args.size():
			return args[i + 1].strip_edges()
		if args[i].begins_with("--seed="):
			return args[i].substr(7).strip_edges()
	return ""


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
	_shop_progress = GameContext.scope.shop if _progress_enabled else ShopPanel.Progress.new()
	if _progress_enabled:
		_shop_progress.load_profile(QuickTrails.saves_dir().path_join("shop_progress.bin"))
	hud.journal_panel.enable_shop(_shop_progress)
	startup_render_frames = LOAD_WARMUP_FRAMES if _progress_enabled else 0
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
	for tab: String in ["all", "favorites", "saved"]:
		var b: Button = _tab_button(tab)
		b.button_group = tabs
		b.pressed.connect(_show_seed_tab.bind(tab))
	%Recommended.text = "От автора +"
	%Recommended.tooltip_text = "Вернуть миры от автора в общий список"
	%Recommended.pressed.connect(_restore_author_worlds)
	var carousel: Carousel = %Carousel
	carousel.setup(%Start, [%NewWorld, %OpenWorlds, %OpenShop, %MenuSettings, %MenuExit], %TrailLab)
	carousel.favorite_requested.connect(_on_star)
	%OpenWorlds.icon = UiIcons.ALBUM
	%OpenShop.icon = UiIcons.BAG
	%MenuSettings.icon = UiIcons.INFO
	%MenuExit.icon = UiIcons.EXIT
	for button: Button in [%OpenWorlds, %OpenShop, %MenuSettings, %MenuExit]:
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 22)
	carousel.world_selected.connect(func(seed_text: String) -> void: _select_world(seed_text))
	carousel.type_changed.connect(_update_menu_selection)
	carousel.play_requested.connect(_on_start)
	carousel.create_requested.connect(func(seed_text: String) -> void:
		if not busy and _is_screen("menu"): _launch_seed(seed_text))
	carousel.preview_ready.connect(func(seed_text: String, texture: Texture2D) -> void:
		_previews[seed_text] = texture
		_update_hub_row(seed_text))
	carousel.map_changed.connect(_update_hub_map)
	for i in 3:
		var mode_button: Button = [%HubRelief, %HubAtlas, %HubHeights][i]
		mode_button.pressed.connect(_set_hub_map_mode.bind(i))
	%HubBuildPreview.pressed.connect(carousel._request_preview)
	carousel.stepped.connect(func(dir: int) -> void: _play_ui(&"carousel_step", 1.06 if dir > 0 else 0.94))

	_refresh_world_cards()
	_seed_tab = "all"
	%LoadPreview.texture = null
	_ui_audio = UiAudio.new()
	add_child(_ui_audio)
	_ui_stack = UiStack.new()
	add_child(_ui_stack)
	var shop_screen := MarginContainer.new()
	shop_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge: String in ["left", "top", "right", "bottom"]:
		shop_screen.add_theme_constant_override("margin_" + edge, 24)
	shop_screen.hide()
	%Menu.get_parent().add_child(shop_screen)
	_shop = ShopPanel.new()
	_shop.show_back = true
	_shop.set_profile(_shop_progress)
	_shop.closed.connect(_return_to_menu_screen)
	shop_screen.add_child(_shop)
	screens.shop = shop_screen
	%OpenShop.pressed.connect(_open_shop)
	_pause_settings_btn = get_node_or_null("UI/Root/Pause/Panel/Box/Settings") as Button
	_ui_stack.setup(self, {menu = %Menu, world_hub = %AllWorlds,
		loading = %Loading, pause = %Pause, settings = %Settings, shop = shop_screen}, get_node_or_null("%Dimmer") as ColorRect, _ui_audio)
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
	_shop.sound_requested.connect(_play_ui)
	hud.journal_panel.shop_panel.sound_requested.connect(_play_ui)
	hud.journal_panel.controls_created.connect(_ui_audio.bind_tree)
	for subtree: Node in [%Menu, %AllWorlds, %Loading, %Pause, %Settings, _shop, hud.journal_panel]:
		_ui_audio.bind_tree(subtree)
	get_viewport().size_changed.connect(_fit_menu)
	(%AllWorlds.get_node("Panel") as Control).resized.connect(_fit_hub)
	(%SeedList.get_parent() as ScrollContainer).get_v_scroll_bar().value_changed.connect(func(_value: float) -> void:
		_hub_preview_scan = true)
	if _progress_enabled and DisplayServer.get_name() != "headless" and "--static-menu" not in OS.get_cmdline_user_args():
		_cover_startup()
	_show("menu", {instant = true})
	var cmd_seed := _cmdline_seed()
	if _progress_enabled and not cmd_seed.is_empty():
		_pick_seed(cmd_seed)
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
		screens.back.visible = screen in ["menu", "world_hub", "loading", "shop"] or (screen == "settings" and game == null)
	if screen != "menu" and _startup_cover != null:
		_lift_startup_cover()
	if _progress_enabled:
		var mode := "frozen" if screen == "loading" else ("live" if screens.has("back") and screens.back.visible else "")
		_set_backdrop_mode(mode)
		if _backdrop != null:
			_backdrop.process_mode = Node.PROCESS_MODE_DISABLED if screen == "shop" else Node.PROCESS_MODE_INHERIT


func _focus_screen_default(screen: String) -> void:
	# фокус на главной кнопке экрана: можно пользоваться клавиатурой (стрелки, Enter)
	match screen:
		"menu":
			_fit_menu()
			(%Carousel as Carousel)._set_mode(0)
			_grab_focus_quiet(%Start if (%Carousel as Carousel).type_available() else (%Carousel as Carousel)._next)
		"world_hub":
			_update_selection()
			_grab_focus_quiet(seed_edit)
		"loading":
			if not cancel_load_button.disabled:
				_grab_focus_quiet(cancel_load_button)
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
	if busy and not event.is_echo() and _is_back_press(event):
		_cancel_loading(false)
		get_viewport().set_input_as_handled()
		return
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
	if event.is_echo() or trail_lab != null or not _is_back_press(event):
		return
	if _confirm != null:
		_cancel_confirm()
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
	if _is_screen("shop") and _shop.dismiss_purchase():
		get_viewport().set_input_as_handled()
		return
	if game == null and (_is_screen("world_hub") or _is_screen("shop")):
		_return_to_menu_screen()
		get_viewport().set_input_as_handled()


static func _is_back_press(event: InputEvent) -> bool:
	var button := event as InputEventJoypadButton
	return (button != null and button.pressed and button.button_index == JOY_BUTTON_B) \
		or event.is_action_pressed("back") or event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")


func _open_new_world() -> void:
	if _is_screen("menu") and not (%Carousel as Carousel).type_available():
		return
	if _is_screen("menu"):
		seed_edit.text = random_seed()
		while _has_save(seed_edit.text):
			seed_edit.text = random_seed()
	_open_all_worlds(%NewWorld)
	if _is_screen("world_hub"):
		_grab_focus_quiet(seed_edit)


func _open_all_worlds(return_to: Control = null) -> void:
	if _is_screen("menu") and not (%Carousel as Carousel).type_available():
		return
	if _is_screen("world_hub"):
		if _hub_needs_sync:
			_show_seed_tab(_seed_tab)
		return
	if _hub_needs_sync:
		_show_seed_tab(_seed_tab)
	_hub_preview_scan = true
	if _ui_stack != null and _is_screen("menu"):
		_active_screen = "world_hub"
		_ui_stack.push("world_hub", {
			dimmer = 0.45, enter_duration = 0.20, enter_scale = 0.96,
			offset_y = 0.0, exit_duration = 0.14, dimmer_duration = 0.18,
			return_focus = return_to if return_to != null else %OpenWorlds, sound = &"panel_open",
		})
		_sync_backdrop_visibility("world_hub")
		_focus_screen_default("world_hub")
		return
	_show("world_hub")


func _open_shop() -> void:
	if not _is_screen("menu"):
		return
	_active_screen = "shop"
	_ui_stack.push("shop", {
		dimmer = 0.35, enter_duration = 0.20, sound = &"panel_open",
		return_focus = %OpenShop,
	})
	_sync_backdrop_visibility("shop")
	_shop.open()


func _return_to_menu_screen() -> void:
	if _ui_stack != null and (_ui_stack.is_open("world_hub") or _ui_stack.is_open("shop")):
		var popped := _ui_stack.pop({sound = &"panel_close", exit_duration = 0.14, exit_scale = 0.97, exit_offset_y = 0.0, reveal_duration = 0.16, dimmer_duration = 0.14})
		_active_screen = popped.active
		_sync_backdrop_visibility(_active_screen)
		if _active_screen == "menu":
			_fit_menu()
			(%Carousel as Carousel)._set_mode(0)
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
	if _is_screen("shop"):
		backdrop.process_mode = Node.PROCESS_MODE_DISABLED
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
	if DisplayServer.get_name() != "headless":
		var dice: Button = %Dice
		var old: Variant = dice.get_meta(&"_dice_tween") if dice.has_meta(&"_dice_tween") else null
		if old is Tween and old.is_valid(): old.kill()
		dice.pivot_offset = dice.size * 0.5
		var tw := dice.create_tween()
		dice.set_meta(&"_dice_tween", tw)
		tw.tween_property(dice, "rotation", dice.rotation + PI, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# ---------- Список миров ----------
# С 10.2 меню в две колонки: слева список миров с картой-миниатюрой и состоянием, справа выбранный мир —
# карта крупно, зерно, звёздочка, что будет при запуске (из сохранённого или заново) и «Начать игру».

func _tab_button(tab: String) -> Button:
	return {all = %Recent, recent = %Recent, favorites = %Favorites, recommended = %Recent, saved = %Saved}.get(tab, %Recent)


## Превью карты мира из кэша (null — мир ещё не запускали)
func _preview_tex(seed_text: String) -> Texture2D:
	if not _previews.has(seed_text):
		_card_reads += 1
		var img := GameContext.scope.cache.preview(seed_text, not QuickTrails.active()) if GameContext.scope.cache.enabled else null
		_previews[seed_text] = ImageTexture.create_from_image(img) if img != null else null
		if img != null:
			var carousel := get_node_or_null("%Carousel") as Carousel
			if carousel != null: carousel.promote_cached(seed_text)
	if _previews[seed_text] == null:
		var carousel := get_node_or_null("%Carousel") as Carousel
		if carousel != null:
			return carousel.generated_preview(seed_text)
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
	var map_ready := cache.enabled and (cache.ready_layers(seed_text) >= 2 or (not QuickTrails.active() and cache.has_bundled(seed_text)))
	var summary := "Откроется быстро." if ready else "Мир создастся при запуске, около минуты."
	var saved_at := -1
	if not data.is_empty():
		saved_at = int(data.saved_at)
		summary = "Открыто мест: %d · Заданий: %d\nСохранено: %s" % [data.visited.size(), data.quest.done, _local_time_text(saved_at)]
	elif corrupt:
		summary = "Сохранение не читается. Мир можно создать заново."
	return {seed = seed_text, saved = not data.is_empty(), saved_at = saved_at,
		corrupt = corrupt, manual = not manual.data.is_empty(), ready = ready, map_ready = map_ready, summary = summary,
		visited = data.visited.size() if not data.is_empty() else 0}


func _refresh_world_cards(deleted := "", previous_index := 0) -> void:
	_hub_needs_sync = true
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
	if deleted == _selected_seed and not deleted.is_empty():
		_selected_seed = _carousel_seeds[mini(previous_index, _carousel_seeds.size() - 1)] if not _carousel_seeds.is_empty() else ""
	elif _selected_seed.is_empty() and not _carousel_seeds.is_empty():
		_selected_seed = _carousel_seeds[0]
	elif not _world_cards.has(_selected_seed):
		_selected_seed = _carousel_seeds[0] if not _carousel_seeds.is_empty() else ""
	if not _selected_seed.is_empty() and _selected_seed not in _carousel_seeds:
		_carousel_seeds.append(_selected_seed)
	_update_carousel()
	_update_selection()


func _update_carousel() -> void:
	var entries: Array[Dictionary] = []
	for seed_text: String in _carousel_seeds:
		var entry: Dictionary = _world_cards[seed_text].duplicate()
		entry.texture = _preview_tex(seed_text) if seed_text == _selected_seed else _previews.get(seed_text)
		entry.favorite = seed_text in GameContext.scope.settings.favorite_seeds
		entries.append(entry)
	(%Carousel as Carousel).set_entries(entries, _selected_seed)


func _set_hub_map_mode(index: int) -> void:
	(%Carousel as Carousel)._set_mode(index)
	_update_hub_map()


func _update_hub_map() -> void:
	var carousel := get_node_or_null("%Carousel") as Carousel
	if carousel == null or not carousel.is_node_ready():
		return
	for i in 3:
		var button: Button = [%HubRelief, %HubAtlas, %HubHeights][i]
		button.set_pressed_no_signal(i == carousel._mode)
		button.disabled = _selected_seed.is_empty()
	var tex := carousel.selected_texture() if not _selected_seed.is_empty() else null
	%Preview.texture = tex
	%PreviewHint.visible = tex == null
	var working := carousel._thread != null and carousel._loading_seed == _selected_seed and not carousel._cancel_flag.is_cancelled()
	var entry: Dictionary = _world_cards.get(_selected_seed, {})
	%HubBuildPreview.visible = not _selected_seed.is_empty() and tex == null and not working and not entry.get("map_ready", false) and not carousel._derived.has(_selected_seed)
	%HubBuildPreview.disabled = carousel._thread != null
	if _selected_seed.is_empty():
		%PreviewHint.text = "\nВыберите мир"
	elif working:
		%PreviewHint.text = "\nПодготовка карты…"
	elif carousel._preview_errors.has(_selected_seed):
		%PreviewHint.text = "\nНе удалось подготовить карту"
	elif %HubBuildPreview.visible:
		%PreviewHint.text = "\nГеография без дорог и 3D"
	else:
		%PreviewHint.text = "\nКарта появится после создания мира"


func _ordered_hub_seeds() -> Array[String]:
	var settings := GameContext.scope.settings
	var ordered: Array[String] = []
	_hub_rank.clear()
	for seed_text: String in _saved_seeds + settings.favorite_seeds + settings.recent_seeds + _carousel_seeds:
		if _world_cards.has(seed_text) and not _hub_rank.has(seed_text):
			_hub_rank[seed_text] = ordered.size()
			ordered.append(seed_text)
	return ordered


func _hub_seed_matches_filter(seed_text: String) -> bool:
	return _seed_tab == "all" or (seed_text in _saved_seeds if _seed_tab == "saved" else seed_text in GameContext.scope.settings.favorite_seeds)


func _update_hub_empty() -> void:
	var has_visible := _hub_rows.values().any(func(item: Control) -> bool: return item.visible)
	var heading := "Ваши миры · подготовка…" if not _hub_build_queue.is_empty() else "Ваши миры"
	if %WorldsLabel.text != heading:
		%WorldsLabel.text = heading
	%HubEmpty.visible = not has_visible
	if not _hub_build_queue.is_empty():
		%HubEmpty.text = "Подготавливаем список миров…"
	else:
		%HubEmpty.text = "Нет избранных миров" if _seed_tab == "favorites" else ("Пока нет сохранений" if _seed_tab == "saved" else "Здесь появятся ваши миры")


func _show_seed_tab(tab: String) -> void:
	# Старые вызовы открытия рекомендаций приводят к единому списку.
	_seed_tab = tab if tab in ["all", "saved", "favorites"] else "all"
	for name: String in ["all", "favorites", "saved"]:
		_tab_button(name).set_pressed_no_signal(name == _seed_tab)
	var settings := GameContext.scope.settings
	var ordered := _ordered_hub_seeds()
	_hub_needs_sync = false
	var list: VBoxContainer = %SeedList
	var scroll := list.get_parent() as ScrollContainer
	var scroll_position := scroll.scroll_vertical
	%Recommended.visible = settings.hide_recommended_worlds
	_hub_build_queue.clear()
	# Удаляются только миры, исчезнувшие из модели; фильтры лишь скрывают строки.
	for seed_text: String in _hub_rows.keys():
		if not _hub_rank.has(seed_text):
			var removed: Control = _hub_rows[seed_text]
			list.remove_child(removed)
			removed.queue_free()
			_hub_rows.erase(seed_text)
	var existing_index := 0
	for seed_text: String in ordered:
		if not _hub_rows.has(seed_text):
			if _hub_seed_matches_filter(seed_text):
				_hub_build_queue.append(seed_text)
			continue
		var row: Control = _hub_rows[seed_text]
		if row.get_index() != existing_index:
			list.move_child(row, existing_index)
		existing_index += 1
		row.visible = _hub_seed_matches_filter(seed_text)
		_update_hub_row(seed_text)
	_update_hub_empty()
	_update_selection()
	_link_seed_rows(_seed_tab)
	_hub_preview_scan = true
	_build_hub_rows()
	# Перестановка и фильтрация не должны уводить пользователя в начало списка.
	scroll.set_deferred("scroll_vertical", scroll_position)


func _hub_insert_index(seed_text: String) -> int:
	var list: VBoxContainer = %SeedList
	var low := 0
	var high := list.get_child_count() - 1  # новая строка уже добавлена в конец
	var rank := int(_hub_rank[seed_text])
	while low < high:
		var middle := (low + high) / 2
		var other := str(list.get_child(middle).get_meta("seed"))
		if int(_hub_rank[other]) < rank:
			low = middle + 1
		else:
			high = middle
	return low


func _build_hub_rows() -> void:
	if _hub_build_queue.is_empty():
		return
	var began := Time.get_ticks_usec()
	var built := 0
	while not _hub_build_queue.is_empty() and (built == 0 or Time.get_ticks_usec() - began < HUB_ROW_BUDGET_USEC):
		var seed_text: String = _hub_build_queue.pop_front()
		if not _hub_rank.has(seed_text) or _hub_rows.has(seed_text) or not _hub_seed_matches_filter(seed_text):
			continue
		var row := _seed_row(seed_text)
		_hub_rows[seed_text] = row
		%SeedList.add_child(row)
		%SeedList.move_child(row, _hub_insert_index(seed_text))
		_update_hub_row(seed_text)
		(row.get_meta("select_button") as Button).set_pressed_no_signal(seed_text == _selected_seed)
		_relink_seed_row(row)
		var previous := _visible_seed_neighbor(row.get_index(), -1)
		var next := _visible_seed_neighbor(row.get_index(), 1)
		if previous != null: _relink_seed_row(previous)
		if next != null: _relink_seed_row(next)
		if seed_text == _hub_reveal_seed:
			_hub_reveal_seed = ""
			(%SeedList.get_parent() as ScrollContainer).ensure_control_visible.call_deferred(row)
		built += 1
	if built > 0:
		_hub_preview_scan = true
	_update_hub_empty()


func _update_hub_row(seed_text: String) -> void:
	if not _hub_rows.has(seed_text):
		return
	var row: Control = _hub_rows[seed_text]
	var settings := GameContext.scope.settings
	var fav := seed_text in settings.favorite_seeds
	var star: Button = row.get_meta("star_button")
	_update_favorite_button(star, seed_text)
	var badges: Array[String] = []
	if seed_text in _saved_seeds:
		badges.append("Ошибка сохранения" if _world_cards[seed_text].get("corrupt", false) else "Сохранение")
	if fav: badges.append("Избранное")
	if seed_text in settings.recent_seeds: badges.append("Недавний")
	if not settings.hide_recommended_worlds:
		for item: Dictionary in RecommendedSeeds.SEEDS:
			if item.seed == seed_text:
				badges.append("От автора")
				break
	var label: Label = row.get_meta("badge_label")
	label.text = " · ".join(badges)
	var thumb: TextureRect = row.get_meta("thumb")
	var texture: Texture2D = _previews.get(seed_text)
	if texture == null:
		texture = (%Carousel as Carousel).generated_preview(seed_text)
	thumb.texture = texture
	if thumb.get_child_count() > 0:
		(thumb.get_child(0) as Control).visible = texture == null


func _update_favorite_button(star: Button, seed_text: String) -> void:
	var settings := GameContext.scope.settings
	var fav := seed_text in settings.favorite_seeds
	var full := not fav and settings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX
	star.icon = UiIcons.star(fav)
	star.disabled = seed_text.is_empty()
	star.modulate = Color(0.62, 0.64, 0.68, 0.65) if full and not seed_text.is_empty() else Color.WHITE
	star.tooltip_text = _star_tip(fav, full)
	if full:
		star.set_meta(&"ui_sound_custom", true)
	elif star.has_meta(&"ui_sound_custom"):
		star.remove_meta(&"ui_sound_custom")


func _visible_seed_neighbor(index: int, direction: int) -> Control:
	var list: VBoxContainer = %SeedList
	var next := index + direction
	while next >= 0 and next < list.get_child_count():
		var row := list.get_child(next) as Control
		if row.visible and row.has_meta("select_button"):
			return row
		next += direction
	return null


func _relink_seed_row(row: Control) -> void:
	if not is_instance_valid(row) or not row.visible:
		return
	var sel: Button = row.get_meta("select_button")
	var star: Button = row.get_meta("star_button")
	var previous := _visible_seed_neighbor(row.get_index(), -1)
	var next := _visible_seed_neighbor(row.get_index(), 1)
	var top_select: Control = previous.get_meta("select_button") if previous != null else _tab_button(_seed_tab)
	var top_star: Control = previous.get_meta("star_button") if previous != null else _tab_button(_seed_tab)
	var bottom_select: Control = next.get_meta("select_button") if next != null else %Storage
	var bottom_star: Control = next.get_meta("star_button") if next != null else %Storage
	sel.focus_neighbor_right = sel.get_path_to(star)
	star.focus_neighbor_left = star.get_path_to(sel)
	star.focus_neighbor_right = star.get_path_to(%Star if not %Star.disabled else %PlaySelected)
	sel.focus_neighbor_top = sel.get_path_to(top_select)
	star.focus_neighbor_top = star.get_path_to(top_star)
	sel.focus_neighbor_bottom = sel.get_path_to(bottom_select)
	star.focus_neighbor_bottom = star.get_path_to(bottom_star)


func _update_favorite_in_hub(seed_text: String, was_full: bool) -> void:
	var settings := GameContext.scope.settings
	var ordered := _ordered_hub_seeds()
	var row: Control = _hub_rows.get(seed_text)
	if row != null:
		var scroll := %SeedList.get_parent() as ScrollContainer
		var scroll_position := scroll.scroll_vertical
		var affected: Array[Control] = [row]
		var old_previous := _visible_seed_neighbor(row.get_index(), -1)
		var old_next := _visible_seed_neighbor(row.get_index(), 1)
		if old_previous != null: affected.append(old_previous)
		if old_next != null: affected.append(old_next)
		var target := 0
		for seed: String in ordered:
			if seed == seed_text: break
			if _hub_rows.has(seed): target += 1
		if row.get_index() != target:
			%SeedList.move_child(row, target)
		row.visible = _hub_seed_matches_filter(seed_text)
		_update_hub_row(seed_text)
		var new_previous := _visible_seed_neighbor(row.get_index(), -1)
		var new_next := _visible_seed_neighbor(row.get_index(), 1)
		if new_previous != null: affected.append(new_previous)
		if new_next != null: affected.append(new_next)
		for changed: Control in affected:
			_relink_seed_row(changed)
		_hub_preview_scan = true
		scroll.set_deferred("scroll_vertical", scroll_position)
	elif _hub_rank.has(seed_text) and _hub_seed_matches_filter(seed_text):
		_hub_build_queue.erase(seed_text)
		_hub_build_queue.push_front(seed_text)
	_update_hub_empty()
	if was_full != (settings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX):
		for seed: String in _hub_rows:
			_update_favorite_button(_hub_rows[seed].get_meta("star_button"), seed)
	_update_favorite_button(%Star, _selected_seed)


func _tick_hub_previews() -> void:
	if _hub_preview_task != -1:
		if not WorkerThreadPool.is_task_completed(_hub_preview_task):
			return
		WorkerThreadPool.wait_for_task_completion(_hub_preview_task)
		_hub_preview_task = -1
		var result := _hub_preview_result
		_hub_preview_result = {}
		var completed_seed := str(result.seed)
		if int(result.epoch) == _hub_preview_epoch and not _previews.has(completed_seed):
			var img: Image = result.image
			_previews[completed_seed] = ImageTexture.create_from_image(img) if img != null else null
			if img != null:
				(%Carousel as Carousel).promote_cached(completed_seed)
			_update_hub_row(completed_seed)
			if completed_seed == _selected_seed:
				var carousel := %Carousel as Carousel
				carousel.set_preview(completed_seed, _previews[completed_seed])
				carousel.show_world(completed_seed)
	if not _is_screen("world_hub") or not GameContext.scope.cache.enabled:
		return
	var scroll := %SeedList.get_parent() as ScrollContainer
	if _hub_preview_scan:
		_hub_preview_scan = false
		_hub_preview_queue.clear()
		var viewport_rect := scroll.get_global_rect()
		for row: Control in %SeedList.get_children():
			if row.visible and row.get_global_rect().intersects(viewport_rect):
				var seed_text := str(row.get_meta("seed"))
				if not _previews.has(seed_text):
					_hub_preview_queue.append(seed_text)
	# Одно фоновое чтение за раз; прокрутка заменяет очередь видимыми строками.
	if not _hub_preview_queue.is_empty():
		var seed_text: String = _hub_preview_queue.pop_front()
		if _hub_rows.has(seed_text) and not _previews.has(seed_text):
			var reader := WorldCache.new()
			reader.dir = GameContext.scope.cache.dir
			var bundled := not QuickTrails.active()
			var result := {seed = seed_text, epoch = _hub_preview_epoch, image = null}
			_hub_preview_result = result
			_card_reads += 1
			_hub_preview_task = WorkerThreadPool.add_task(func() -> void:
				result.image = reader.preview(seed_text, bundled), false, "Миниатюра мира")


func _invalidate_world_preview(seed_text := "") -> void:
	_hub_preview_epoch += 1
	_hub_preview_queue.clear()
	_hub_preview_scan = true
	if seed_text.is_empty():
		_previews.clear()
	else:
		_previews.erase(seed_text)
	(%Carousel as Carousel).invalidate_preview(seed_text)


func _link_seed_rows(tab: String) -> void:
	var row_nodes: Array[Dictionary] = []
	for child in %SeedList.get_children():
		if not (child.visible and child.has_meta("select_button") and child.has_meta("star_button")):
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


## Строка списка: соседние кнопки выбора мира и звёздочки в горизонтальном контейнере (без кнопки внутри кнопки)
func _seed_row(seed_text: String) -> PanelContainer:
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
	select_btn.tooltip_text = seed_text
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
	# Не читаем дисковый кэш при построении каждой строки: видимые миниатюры подгружаются покадрово.
	var tex: Texture2D = _previews.get(seed_text)
	if tex == null:
		tex = (%Carousel as Carousel).generated_preview(seed_text)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(48, 48)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.texture = tex
	# Заглушка сохраняется и при последующем удалении готового превью.
	var empty := ColorRect.new()
	empty.color = Color(1, 1, 1, 0.06)
	empty.set_anchors_preset(Control.PRESET_FULL_RECT)
	empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	empty.visible = tex == null
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
	var sub_label := Label.new()
	sub_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub_label.theme_type_variation = &"CaptionLabel"
	sub_label.add_theme_font_size_override("font_size", 12)
	texts.add_child(sub_label)
	row.set_meta("badge_label", sub_label)
	row.set_meta("thumb", thumb)
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
	var typed := seed_edit.text.strip_edges()
	_hub_reveal_seed = ""
	if _world_cards.has(typed):
		if _seed_tab != "all" and (not _hub_rows.has(typed) or not (_hub_rows[typed] as Control).visible):
			_show_seed_tab("all")
		_pick_seed(typed)
		if _hub_rows.has(typed):
			var row: Control = _hub_rows[typed]
			(%SeedList.get_parent() as ScrollContainer).ensure_control_visible.call_deferred(row)
		elif typed in _hub_build_queue:
			_hub_build_queue.erase(typed)
			_hub_build_queue.push_front(typed)
			_hub_reveal_seed = typed


func _on_seed_changed(_text: String) -> void:
	_choose_typed()


func _select_world(seed_text: String) -> void:
	_hub_reveal_seed = ""
	_selected_seed = seed_text
	if not seed_text.is_empty() and seed_text not in _carousel_seeds:
		_carousel_seeds.push_front(seed_text)
		_hub_needs_sync = true
		_update_carousel()
	else:
		var texture: Texture2D
		if _is_screen("world_hub"):
			texture = _previews.get(seed_text)
			_hub_preview_scan = true
		else:
			texture = _preview_tex(seed_text)
		(%Carousel as Carousel).set_preview(seed_text, texture)
		(%Carousel as Carousel).show_world(seed_text, true)
	_update_selection()


func _chosen_seed() -> String:
	return _selected_seed


func _update_menu_selection() -> void:
	var seed_text := _selected_seed
	var state: Dictionary = _world_cards.get(seed_text, {})
	var corrupt: bool = state.get("corrupt", false)
	var label := "Продолжить путешествие" if state.get("saved", false) else "Начать путешествие"
	%Start.text = "Все миры" if corrupt else ("Продолжить «%s»" % seed_text if state.get("saved", false) else label)
	if state.get("saved", false):
		var when := _local_time_text(int(state.saved_at))
		var today := Time.get_datetime_string_from_system().get_slice("T", 0)
		var saved_label := "сегодня" if when.begins_with(today) else when.get_slice(" ", 0)
		%MenuStatus.text = "Открыто мест: %d · Сохранено %s" % [state.get("visited", 0), saved_label]
	else:
		%MenuStatus.text = str(state.get("summary", "Выберите или создайте мир")).replace("\n", " · ")
	%OpenShop.text = "Экипировка  ·  %d" % _shop_progress.balance if _shop_progress.load_error == OK else "Экипировка"
	if seed_text.is_empty():
		%Start.text = "Создать мир"
	var type_ready := (%Carousel as Carousel).type_available()
	%Start.disabled = not type_ready
	%NewWorld.disabled = not type_ready
	%OpenWorlds.disabled = not type_ready
	var type_next: Control = (%Carousel as Carousel)._next
	type_next.focus_neighbor_bottom = type_next.get_path_to(%Start if type_ready else %OpenShop)
	%OpenShop.focus_neighbor_top = %OpenShop.get_path_to(%OpenWorlds if type_ready else type_next)
	if not type_ready:
		%Start.text = "Скоро появится"
		%MenuStatus.text = "Этот тип мира пока недоступен"


func _update_selection() -> void:
	var seed_text := _selected_seed
	var state: Dictionary = _world_cards.get(seed_text, {})
	var corrupt: bool = state.get("corrupt", false)
	var label := "Продолжить путешествие" if state.get("saved", false) else "Начать путешествие"
	_update_menu_selection()
	%PlaySelected.text = label
	%PlaySelected.disabled = corrupt or seed_text.is_empty()
	for row in %SeedList.get_children():
		var row_seed := str(row.get_meta("seed")) if row.has_meta("seed") else ""
		var select_btn := row.get_meta("select_button") as Button if row.has_meta("select_button") else null
		if select_btn != null:
			select_btn.set_pressed_no_signal(not seed_text.is_empty() and row_seed == seed_text)
		elif row is Button:
			(row as Button).set_pressed_no_signal(not seed_text.is_empty() and row_seed == seed_text)
	_update_hub_map()
	%ChoiceName.text = "Мир не выбран" if seed_text.is_empty() else "«%s»" % seed_text
	%WorldStatus.text = state.get("summary", "")
	_update_favorite_button(%Star, seed_text)
	if corrupt:
		%WorldStatus.text = "Сохранение не читается. Можно создать мир заново; старые файлы сохранятся в архиве."
	_load_manual.visible = state.get("manual", false)
	_load_manual.disabled = not state.get("manual", false)
	%RestartWorld.modulate = Color(1.0, 0.48, 0.42) if corrupt else Color.WHITE
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
	var was_full := settings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX
	var previous_favorites := settings.favorite_seeds.duplicate()
	settings.toggle_favorite(seed_text)
	var err := settings.save_settings()
	if err != OK:
		settings.favorite_seeds = previous_favorites
		# Обработчик общего звука кнопки выполняется после этого обработчика.
		if is_instance_valid(source_button) and not source_button.has_meta(&"ui_sound_custom"):
			source_button.set_meta(&"ui_sound_custom", true)
			(func() -> void:
				if is_instance_valid(source_button):
					source_button.remove_meta(&"ui_sound_custom")).call_deferred()
		_play_ui(&"error_deny")
		_message("Не удалось изменить избранное", "Изменение не сохранено: %s" % error_string(err))
		return
	# Чистка дискового кэша выполняется при следующем запуске мира.
	_update_favorite_in_hub(seed_text, was_full)
	(%Carousel as Carousel).set_favorite(seed_text, seed_text in settings.favorite_seeds)
	if is_instance_valid(source_button) and not source_button.is_visible_in_tree() and _is_screen("world_hub"):
		_grab_focus_quiet(_tab_button(_seed_tab))
	if is_instance_valid(source_button) and DisplayServer.get_name() != "headless":
		var old: Variant = source_button.get_meta(&"_favorite_pulse") if source_button.has_meta(&"_favorite_pulse") else null
		if old is Tween and old.is_valid(): old.kill()
		source_button.pivot_offset = source_button.size * 0.5
		source_button.scale = Vector2.ONE * 0.8
		var tw := source_button.create_tween()
		source_button.set_meta(&"_favorite_pulse", tw)
		tw.tween_property(source_button, "scale", Vector2.ONE * 1.15, 0.10).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(source_button, "scale", Vector2.ONE, 0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _show_favorites_full_notice() -> void:
	if _is_screen("menu"):
		%MenuStatus.text = "Избранное заполнено (%d)" % GameSettings.FAVORITES_MAX
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			if is_inside_tree() and _is_screen("menu"): _update_selection())
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
	_invalidate_world_preview(seed_text)
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
	_invalidate_world_preview(seed_text)
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
	_confirm.add_button("Отчёты FPS", true, "session_reports")
	_confirm.custom_action.connect(_open_session_reports)


func _open_session_reports(_action: StringName) -> void:
	var folder := ProjectSettings.globalize_path(SessionPerformance.dir)
	var err := DirAccess.make_dir_recursive_absolute(folder)
	if err == OK:
		err = OS.shell_open(folder)
	if err != OK:
		_close_confirm()
		_message("Не удалось открыть отчёты FPS", "%s\n%s" % [folder, error_string(err)])


func _on_clear_cache() -> void:
	GameContext.scope.cache.keep_only([])
	_invalidate_world_preview()
	_refresh_world_cards()
	_show_seed_tab(_seed_tab)


func _clear_all_saves() -> void:
	if busy or game != null or not _is_screen("world_hub") or %ClearAllSaves.disabled:
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
	_invalidate_world_preview()
	_selected_seed = ""
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
	_refresh_world_cards()
	_show_seed_tab("all")
	_grab_focus_quiet(%Recent)


func _fit_menu() -> void:
	var vs := get_viewport().get_visible_rect().size
	var showcase: Control = %Carousel
	var panel: Control = %Menu.get_node("Panel")
	var lab: Control = %TrailLab
	# Вся колонка помещается между равными верхним и нижним отступами.
	var column_width := maxf(388.0, panel.get_combined_minimum_size().x)
	var panel_height := panel.get_combined_minimum_size().y
	var card_height := 200.0
	var total_height := card_height + 12.0 + panel_height + 12.0 + 44.0
	var column_scale := minf(1.0, minf(maxf(0.3, (vs.y - 56.0) / total_height), maxf(0.3, (vs.x - 96.0) / column_width)))
	showcase.visible = true
	showcase.scale = Vector2.ONE * column_scale
	showcase.offset_left = 48.0
	showcase.offset_top = 28.0
	showcase.offset_right = 48.0 + column_width
	showcase.offset_bottom = 28.0 + card_height
	panel.scale = showcase.scale
	panel.offset_left = 48.0
	panel.offset_top = vs.y - 28.0 - (44.0 + 12.0 + panel_height) * column_scale
	panel.offset_right = 48.0 + column_width
	panel.offset_bottom = panel.offset_top + panel_height
	lab.scale = showcase.scale
	lab.offset_top = -28.0 - 44.0 * column_scale
	lab.offset_bottom = lab.offset_top + 44.0
	var loading_panel: Control = %Loading.get_node("Panel")
	loading_panel.scale = showcase.scale
	loading_panel.offset_left = showcase.offset_left
	loading_panel.offset_top = showcase.offset_top
	loading_panel.offset_right = showcase.offset_right
	var worlds: Control = %AllWorlds.get_node("Panel")
	worlds.custom_minimum_size = Vector2(clampf(vs.x * 0.75, 920.0, 1220.0), clampf(vs.y * 0.80, 550.0, 700.0))
	_fit_hub.call_deferred()
	if _backdrop != null:
		_backdrop.resize(_backdrop_size())


func _fit_hub() -> void:
	var panel := %AllWorlds.get_node("Panel") as Control
	if panel.size.x <= 0.0 or panel.size.y <= 0.0:
		return
	var available := get_viewport().get_visible_rect().size - Vector2(24, 24)
	var fit := minf(1.0, minf(maxf(0.01, available.x / panel.size.x), maxf(0.01, available.y / panel.size.y)))
	UiStack.set_panel_base_scale(panel, fit)
	_hub_preview_scan = true


func _process(delta: float) -> void:
	if _is_screen("world_hub"):
		_build_hub_rows()
	_tick_hub_previews()
	if _session_performance != null:
		_session_performance.sample(game, _session_mode(), Time.get_ticks_usec())
	var main_began_us := Time.get_ticks_usec()
	if _ui_stack != null:
		_ui_stack.tick()
	if display_options != null:
		display_options.tick()
	if _is_screen("settings"):
		_update_control_hint()
	_flush_settings()
	if _backdrop_mode == "live" and not _is_screen("shop") and get_window().mode != Window.MODE_MINIMIZED:
		_animate_menu(delta)
	if _auto_save_task != -1 and WorkerThreadPool.is_task_completed(_auto_save_task):
		_finish_auto_save()
	if _progress_enabled and game != null and not busy and not game.paused and not game.travel_active():
		_save_elapsed += delta
		# 21.11.2026: открытия мест подряд (место, доска рядом) — одно сохранение раз в AUTO_SAVE_GAP_MS, а не три за 0,1 с;
		# смена задания (_save_elapsed = 60) пишется сразу
		var discovered := hud.map_place_count() != _saved_discoveries and Time.get_ticks_msec() - _auto_save_at_ms >= AUTO_SAVE_GAP_MS
		if _auto_save_task == -1 and (_save_elapsed >= 60.0 or discovered):
			_queue_auto_save()
	if busy:
		_tick_loading(delta)
	# 21.11.2026: своя работа главного цикла (меню, настройки, автосохранение) — часть «main» записи сессии
	if game != null and _session_performance != null:
		game.tick_us["main"] = game.tick_us.get("main", 0) + Time.get_ticks_usec() - main_began_us


func _session_mode() -> String:
	if DisplayServer.get_name() != "headless" and get_window().mode == Window.MODE_MINIMIZED: return "background"
	if _active_screen == "settings": return "settings"
	return game.performance_mode()


func _tick_loading(delta: float) -> void:
	var progress := lerpf(bar.value, _progress_target, Util.damp(8.0, delta))
	bar.value = _progress_target if absf(progress - _progress_target) < 0.001 else progress
	var seconds := (Time.get_ticks_msec() - _load_started_ms) / 1000
	if seconds != _load_elapsed:
		_load_elapsed = seconds
		load_elapsed.text = "Прошло %d:%02d" % [seconds / 60, seconds % 60]
	if gen_thread != null and not gen_thread.is_alive():
		var loaded := gen_thread.wait_to_finish() as WorldLoader
		gen_thread = null
		_on_world_ready(loaded)


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
	if busy or (_is_screen("menu") and not (%Carousel as Carousel).type_available()):
		return
	if _selected_seed.is_empty():
		_open_new_world()
		return
	_launch_seed(_selected_seed)


func _on_create_world() -> void:
	if busy:
		return
	var seed_text := seed_edit.text.strip_edges()
	if seed_text.is_empty():
		seed_text = random_seed()
		while _has_save(seed_text):
			seed_text = random_seed()
		seed_edit.text = seed_text
	if _has_save(seed_text):
		_ask("Мир уже существует", "У мира «%s» уже есть сохранение. Открыть его? Чтобы создать новый мир, выберите другое зерно." % seed_text,
			"Открыть мир", false, _launch_seed.bind(seed_text), seed_edit)
		return
	_launch_seed(seed_text)


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
	var launch_btn: Button = %CreateWorld if _is_screen("world_hub") and seed_edit.has_focus() else (%PlaySelected if _is_screen("world_hub") else %Start)
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
	var save_began_us := Time.get_ticks_usec()
	if not _save_current():
		return
	var save_ended_us := Time.get_ticks_usec()
	_pending_save = {}
	if not slot.is_empty():
		var result := Saves.read_slot(seed_text, slot)
		if result.data.is_empty():
			_message("Ошибка загрузки", result.error)
			return
		_pending_save = result.data
		if result.backup:
			_message("Резервная копия", "Основное сохранение повреждено. Загружается предыдущая исправная копия.")
	_finish_session("switch_world", save_began_us, save_ended_us)
	(%Carousel as Carousel).cancel_preview()
	busy = true
	_progress_target = 0.0
	bar.value = 0.0
	_load_cancel_requested = false
	_load_quit_requested = false
	_load_cancel_flag = CancelFlag.new()
	_load_started_ms = Time.get_ticks_msec()
	_load_elapsed = 0
	load_elapsed.text = "Прошло 0:00"
	_free_game()
	hud.visible = false
	_set_progress(0.0, "Подготовка", true)
	cancel_load_button.disabled = false
	var selected_map: Texture2D = (%Carousel as Carousel).selected_texture() if _is_screen("menu") and seed_text == _selected_seed else null
	%LoadPreview.texture = selected_map if selected_map != null else _preview_tex(seed_text)
	%LoadPreview.visible = %LoadPreview.texture != null
	%LoadPlaceholder.visible = not %LoadPreview.visible
	%LoadPlaceholder.text = seed_text
	%Title.text = "Мир «%s»" % seed_text
	%Title.tooltip_text = %Title.text
	_show("loading", {enter_duration = LOAD_ENTER_SECONDS})
	gen_thread = Thread.new()
	var start_at := Vector2(_pending_save.player.x, _pending_save.player.z) if not _pending_save.is_empty() else Vector2.INF
	var err := gen_thread.start(_generate_job.bind(seed_text, size, start_at, allow_bundled, Time.get_ticks_usec(), _load_cancel_flag))
	if err != OK:
		gen_thread = null
		_finish_load("Мир не подготовлен", "Не удалось запустить поток загрузки (%s)." % error_string(err))


func _generate_job(seed_text: String, size: int, start_at: Vector2, allow_bundled: bool, dispatched_us: int, cancel_flag: CancelFlag) -> WorldLoader:
	var entered_us := Time.get_ticks_usec()
	var cache := GameContext.scope.cache
	if cache.enabled and not cancel_flag.is_cancelled():
		cache.keep_only(GameContext.scope.settings.keep_seeds())
		if allow_bundled and not QuickTrails.active() and size == WorldGenerator.START_SIZE and not cancel_flag.is_cancelled():
			cache.install_bundled(WorldCache.BUNDLED, seed_text)
	if cancel_flag.is_cancelled():
		return null
	var before_loader_us := Time.get_ticks_usec()
	var loaded := WorldLoader.load_world(seed_text, size, func(p: float, label: String) -> void:
		_report_load_progress.call_deferred(p, label, cancel_flag), null, start_at, cancel_flag.is_cancelled)
	if loaded == null:
		return null
	var ready_us := Time.get_ticks_usec()
	loaded.timings.thread_dispatch_ms = (entered_us - dispatched_us) / 1000.0
	loaded.timings.before_loader_ms = (before_loader_us - entered_us) / 1000.0
	loaded.timings.loader_call_ms = (ready_us - before_loader_us) / 1000.0
	loaded.timings.ready_queued_us = ready_us
	return loaded


func _report_load_progress(p: float, label: String, cancel_flag: CancelFlag) -> void:
	if gen_thread != null and cancel_flag == _load_cancel_flag and not _load_cancel_requested:
		_set_progress(p, label)


func _finish_load(error_title := "", error_detail := "") -> void:
	if game != null:
		_free_game()
	hud.hide()
	_pending_save = {}
	if _load_quit_requested and GameContext.scope.cache.has_pending_writes():
		_set_progress(bar.value, "Сохранение кэша перед выходом…", true)
		while GameContext.scope.cache.has_pending_writes():
			await get_tree().process_frame
	busy = false
	var want_quit := _load_quit_requested
	var was_cancelled := _load_cancel_requested
	_load_cancel_requested = false
	_load_quit_requested = false
	_load_cancel_flag = null
	if want_quit:
		_exit_game()
		return
	_show("menu")
	if not was_cancelled and not error_title.is_empty():
		_message(error_title, error_detail)


func _on_cancel_load_pressed() -> void:
	_cancel_loading(false)


func _cancel_loading(quit_after: bool) -> void:
	if not busy or (_load_cancel_requested and (not quit_after or _load_quit_requested)):
		return
	var first_request := not _load_cancel_requested
	_load_cancel_requested = true
	_load_quit_requested = quit_after
	if _load_cancel_flag != null:
		_load_cancel_flag.cancel()
	cancel_load_button.disabled = true
	if not _is_screen("loading"):
		_show("loading", {instant = true})
	var label := "Выход после завершения текущего этапа…" if quit_after else "Отмена после завершения текущего этапа…"
	_set_progress(bar.value, label, true)
	if first_request:
		_play_ui(&"panel_close")


func _set_progress(p: float, label: String, instant := false) -> void:
	_progress_target = clampf(p, 0.0, 1.0)
	if label == load_step.text and not instant:
		return
	if _load_step_tween != null and _load_step_tween.is_valid():
		_load_step_tween.kill()
	_load_step_tween = null
	if instant or not %Loading.visible or not _ui_stack.should_animate():
		load_previous_step.hide()
		load_step.modulate.a = 1.0
		load_step.text = label
		return
	# При быстрой смене этапов оставляем наиболее читаемую подпись предыдущего перехода.
	if not load_previous_step.visible or load_step.modulate.a >= load_previous_step.modulate.a:
		load_previous_step.text = load_step.text
		load_previous_step.modulate.a = load_step.modulate.a
	load_previous_step.show()
	load_step.text = label
	load_step.modulate.a = 1.0 - load_previous_step.modulate.a
	_load_step_tween = create_tween()
	_load_step_tween.set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_load_step_tween.tween_property(load_previous_step, "modulate:a", 0.0, LOAD_STEP_SECONDS)
	_load_step_tween.tween_property(load_step, "modulate:a", 1.0, LOAD_STEP_SECONDS)
	_load_step_tween.chain().tween_callback(func() -> void:
		load_previous_step.hide()
		_load_step_tween = null)


func _on_world_ready(loaded: WorldLoader) -> void:
	if _load_cancel_requested or (loaded != null and loaded.cancelled):
		_finish_load()
		return
	if loaded == null:
		_finish_load("Мир не подготовлен", "Генерация прервалась с ошибкой. Подробности в журнале Godot.")
		return
	loaded.timings.ready_queue_ms = (Time.get_ticks_usec() - int(loaded.timings.get("ready_queued_us", Time.get_ticks_usec()))) / 1000.0
	loaded.timings.erase("ready_queued_us")
	if not loaded.error.is_empty():
		_finish_load("Мир не подготовлен", loaded.error)
		return
	# Даём подписи проявиться перед синхронным созданием сцены.
	_set_progress(0.97, "Окружение вокруг игрока")
	var phase_started := Time.get_ticks_usec()
	await get_tree().process_frame
	while _load_step_tween != null and not _load_cancel_requested:
		await get_tree().process_frame
	if _load_cancel_requested:
		_finish_load()
		return
	if not _pending_save.is_empty() and not load(GAME_SCRIPT).can_restore(_pending_save, loaded.world):
		_finish_load("Мир изменился", "Места этого мира изменились после обновления. Сохранение оставлено без изменений. Нажмите «Создать заново», чтобы пересоздать этот мир и начать новое путешествие.")
		return
	loaded.timings.ready_frame_wait_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	phase_started = Time.get_ticks_usec()
	game = (load(GAME_SCENE) as PackedScene).instantiate()
	game.shop_progress = _shop_progress
	game.startup_input_locked = true
	game.pause_requested.connect(_toggle_pause)
	add_child(game)
	loaded.timings.game_scene_create_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	phase_started = Time.get_ticks_usec()
	game.start(loaded, hud, _pending_save)
	if not loaded.error.is_empty():
		_finish_load("Мир не подготовлен", loaded.error)
		return
	game.set_physics_process(false)
	loaded.timings.game_start_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	# Рендер и стриминг работают под заставкой, физика ждёт начала перехода.
	_set_progress(0.99, "Прогрев 3D-сцены")
	phase_started = Time.get_ticks_usec()
	var warmup_frames := startup_render_frames if DisplayServer.get_name() != "headless" else 0
	var pipeline_probe: Node3D
	if warmup_frames > 0 and RenderingServer.get_current_rendering_method() == "forward_plus" \
			and get_window().mode != Window.MODE_MINIMIZED:
		pipeline_probe = game.prepare_render_pipelines()
	for i in warmup_frames:
		await get_tree().process_frame
		if i == 1 and is_instance_valid(pipeline_probe):
			pipeline_probe.queue_free()
			pipeline_probe = null
		if game == null or _load_cancel_requested or get_window().mode == Window.MODE_MINIMIZED:
			break
	if is_instance_valid(pipeline_probe):
		pipeline_probe.queue_free()
	loaded.timings.first_frames_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	if _load_cancel_requested or game == null:
		_finish_load()
		return
	_set_progress(1.0, "Готово")
	hud.set_map_visible(false)
	if _progress_enabled or _ui_stack.force_animate_in_headless:
		_active_screen = ""
		# Пролёт начинается вместе с проявлением мира. Для сохранений стоим до передачи управления.
		game.set_physics_process(game.opening_active())
		var dissolve := _ui_stack.dissolve_to_world(%Back, %Loading, LOAD_DISSOLVE_SECONDS)
		while dissolve != null and dissolve.is_running() and not _load_cancel_requested and game != null:
			await get_tree().process_frame
	else:
		_show("", {instant = true})
	if _load_cancel_requested or game == null:
		_finish_load()
		return
	_set_backdrop_mode("")
	_save_elapsed = 0.0
	_saved_discoveries = hud.map_place_count()
	game.quests.changed.connect(func() -> void: _save_elapsed = 60.0)
	phase_started = Time.get_ticks_usec()
	if _pending_save.is_empty():
		_save_current()
	loaded.timings.initial_save_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	_pending_save = {}
	bar.value = 1.0
	busy = false
	_load_cancel_flag = null
	game.startup_input_locked = false
	game.set_physics_process(true)
	game.sync_mouse_mode()
	_fade_hud(not game.opening_active(), 0.22 if _progress_enabled else 0.0)
	loaded.timings.published_us = Time.get_ticks_usec()
	if _progress_enabled:
		var phases := loaded.timings.duplicate()
		phases.erase("published_us")
		var loading := {duration_ms = loaded.timings.published_us / 1000.0 - _load_started_ms,
			from_cache = loaded.from_cache, phases = phases}
		_session_performance = SessionPerformance.new(game, _session_mode(), loaded.timings.published_us, loading)


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
	if game == null or busy:
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
		# 21.11.2026: сохранение при паузе — фоном, как автосохранение (было ~7,5 мс записи в кадре открытия паузы);
		# выход и смена мира дожидаются его в _save_current
		if _progress_enabled and game.quests != null:
			_finish_auto_save()
			_queue_auto_save()
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
	if not _save_current("auto", "menu"):
		return
	var played_seed := str(game.world.seed_text) if game != null and game.world != null else _selected_seed
	_cancel_hud_fade()
	_free_game()
	hud.visible = false
	if not played_seed.is_empty():
		_invalidate_world_preview(played_seed)   # изменился только что завершённый мир
	_refresh_world_cards()
	_show("menu")


func _exit_game() -> void:
	if display_options != null:
		display_options.revert()
	if busy:
		_cancel_loading(true)
		return
	if not _save_current("auto", "exit"):
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


func _save_current(slot := "auto", session_end := "") -> bool:
	if game == null or game.quests == null or not _progress_enabled:
		return true
	var began_us := Time.get_ticks_usec()
	# Перед выходом или сменой мира новая запись должна идти после фоновой записи того же слота.
	_finish_auto_save(false)
	if _shop_progress != null:
		_shop_progress.retry_rewards()
	var err := Saves.write_slot(game.save_state(), slot)
	if err == OK:
		_saved_discoveries = hud.map_place_count()
	if _session_performance != null:
		var ended_us := Time.get_ticks_usec()
		if err == OK and not session_end.is_empty():
			_finish_session(session_end, began_us, ended_us)
		else:
			_session_performance.work("world_save_" + slot, began_us, ended_us, error_string(err))
	return _report_save(err, slot)


func _finish_session(reason: String, save_began_us: int, save_ended_us: int) -> void:
	if _session_performance == null:
		return
	var report := _session_performance.finish(reason, save_began_us, save_ended_us)
	_session_performance = null
	if report.json_error != OK or report.markdown_error != OK:
		push_warning("Отчёт FPS %s: JSON %s, Markdown %s" % [
			report.path, error_string(report.json_error), error_string(report.markdown_error)])
	else:
		print("Отчёт FPS сохранён: ", ProjectSettings.globalize_path(report.path + ".md"))


func _queue_auto_save() -> void:
	var began_us := Time.get_ticks_usec()
	if _shop_progress != null:
		_shop_progress.retry_rewards()
	var state: Dictionary = game.save_state()
	# 21.11.2026: в фон уходят готовые байты, а не словари игры (часть их — общие с живыми данными, например заезды)
	var seed_text: String = state.seed
	var raw := Saves.encode(state)
	var result := {discoveries = hud.map_place_count(), error = ERR_BUSY, began_us = 0, ended_us = 0}
	_auto_save_result = result
	_save_elapsed = 0.0
	_auto_save_at_ms = Time.get_ticks_msec()
	if _session_performance != null:
		_session_performance.work("autosave_snapshot", began_us, Time.get_ticks_usec())
	_auto_save_task = WorkerThreadPool.add_task(func() -> void:
		result.began_us = Time.get_ticks_usec()
		result.error = Saves.write_bytes(seed_text, raw)
		result.ended_us = Time.get_ticks_usec(),
		false, "Автосохранение")


func _finish_auto_save(report := true) -> void:
	if _auto_save_task == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_auto_save_task)
	_auto_save_task = -1
	var err: Error = _auto_save_result.error
	if err == OK:
		_saved_discoveries = _auto_save_result.discoveries
	if _session_performance != null:
		_session_performance.work("autosave_write", _auto_save_result.began_us, _auto_save_result.ended_us, error_string(err), true)
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
	var opener: Control = _load_manual if _is_screen("world_hub") else (get_node_or_null("%QuickLoad") as Control)
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
		rows.append([c.labels(&"bike_pump"), "памп на велосипеде (держать)"])
		rows.append(["%s → %s" % [c.label(&"bike_back"), c.label(&"bike_forward")], "баннихоп"])
	rows.append([c.label(&"interact"), "взаимодействовать, сесть / слезть"])
	rows.append([c.label(&"flashlight"), "фонарик"])
	rows.append([c.label(&"recover_bike"), "выбрать место для велосипеда"])
	rows.append([c.label(&"toggle_map"), "карта"])
	rows.append([c.label(&"journal"), "путешествие: путь и альбом"])
	rows.append([c.label(&"photo") if pad else "ПКМ", "фотоаппарат"])
	if not pad:
		rows.append([c.label(&"time_skip"), "время суток (+Shift — назад)"])
	rows.append([c.label(&"show_hud"), "посмотреть сводку (держать)"])
	rows.append([c.label(&"pause"), "пауза"])
	return rows


func _update_control_hint() -> void:
	var controls := GameContext.scope.controls
	var caption := "%s — взаимодействовать · %s — сводка (держать)" % [
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
	if _hub_preview_task != -1:
		WorkerThreadPool.wait_for_task_completion(_hub_preview_task)
		_hub_preview_task = -1
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
