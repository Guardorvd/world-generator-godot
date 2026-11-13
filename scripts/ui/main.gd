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
const GameScene := preload("res://scenes/game_world.tscn")
const TrailLabScene := preload("res://scenes/trail_lab.tscn")
const Saves := preload("res://scripts/game/save_game.gd")
const DisplayOptions := preload("res://scripts/ui/display_options.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const Carousel := preload("res://scripts/ui/world_carousel.gd")
const Backdrop := preload("res://scripts/ui/menu_backdrop.gd")
const LIVE_WARM_START_DELAY := 0.18

var game: GameWorld
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
var _pending_save := {}
var _save_elapsed := 0.0
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
	if OS.get_cmdline_user_args().has("--resource-report"):
		GameContext.scope.resource_profile = preload("res://scripts/core/resource_profile.gd").new()
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
	carousel.new_world_requested.connect(_open_new_world)
	for item: Dictionary in RecommendedSeeds.SEEDS:
		var button := Button.new()
		button.text = item.seed
		button.tooltip_text = item.get("note", "")
		button.theme_type_variation = &"ListRow"
		button.pressed.connect(_suggested_seed.bind(item.seed))
		%Suggestions.add_child(button)
	_refresh_world_cards()
	_seed_tab = "saved" if not _saved_seeds.is_empty() else ("recent" if not GameContext.scope.settings.recent_seeds.is_empty() else "recommended")
	%LoadPreview.texture = null
	get_viewport().size_changed.connect(_fit_menu)
	_show("menu")
	if _progress_enabled and "--menu-timing" in OS.get_cmdline_user_args():
		_report_first_menu_frame()


func _show(screen: String) -> void:
	for s: String in screens:
		if s != "back":
			screens[s].visible = s == screen
	screens.back.visible = screen in ["menu", "new_world", "all_worlds", "loading"] or (screen == "settings" and game == null)
	if _progress_enabled:
		var mode := "frozen" if screen == "loading" else ("live" if screens.back.visible else "")
		_set_backdrop_mode(mode)
	# фокус на главной кнопке экрана: можно пользоваться клавиатурой (стрелки, Enter)
	match screen:
		"menu":
			_fit_menu()
			%Start.grab_focus()
		"new_world":
			%CreateWorld.grab_focus()
		"all_worlds":
			_update_selection()
			var play: Button = %PlaySelected
			var target: Control = _tab_button(_seed_tab) if play.disabled else play
			target.grab_focus()
		"pause":
			%Resume.grab_focus()
		"settings":
			%Done.grab_focus()


func _input(event: InputEvent) -> void:
	if _confirm != null or not %Menu.is_visible_in_tree():
		return
	var direction := int(event.is_action_pressed("ui_right", true)) - int(event.is_action_pressed("ui_left", true))
	if direction != 0 and (%Carousel as Carousel).move_focused(direction):
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventJoypadButton
	var pad_back := button != null and button.pressed and button.button_index == JOY_BUTTON_B
	if game != null or not (pad_back or event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")):
		return
	if %Settings.visible:
		_close_settings()
		get_viewport().set_input_as_handled()
	elif %NewWorld.visible or %AllWorlds.visible:
		_return_to_menu_screen()
		get_viewport().set_input_as_handled()


func _open_new_world() -> void:
	seed_edit.text = random_seed()
	_show("new_world")


func _open_all_worlds() -> void:
	var state: Dictionary = _world_cards.get(_selected_seed, {})
	if state.get("corrupt", false):
		_seed_tab = _tab_with_seed(_selected_seed)
	_show_seed_tab(_seed_tab)
	_show("all_worlds")


func _return_to_menu_screen() -> void:
	_show("menu")


func _set_backdrop_mode(mode: String) -> void:
	if mode == _backdrop_mode:
		return
	_backdrop_mode = mode
	_backdrop_epoch += 1
	if _backdrop_fade != null and _backdrop_fade.is_valid():
		_backdrop_fade.kill()
	var frame := _poster
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
	bg.texture = frame
	if mode == "live":
		_start_menu_backdrop(_backdrop_epoch)


func _start_menu_backdrop(epoch: int) -> void:
	if DisplayServer.get_name() == "headless" or "--static-menu" in OS.get_cmdline_user_args():
		return
	# Два кадра дают вывести афишу и дождаться отложенного освобождения игрового окружения.
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(LIVE_WARM_START_DELAY).timeout
	if not is_inside_tree() or epoch != _backdrop_epoch:
		return
	var backdrop := Backdrop.new()
	add_child(backdrop)
	var quality := Backdrop.recommended_quality()
	if not backdrop.start(_backdrop_size(), GameContext.scope.settings, quality, false, true):
		backdrop.queue_free()
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
	live.modulate.a = 0.0
	live.show()
	_backdrop_fade = create_tween()
	_backdrop_fade.tween_property(live, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)


func _use_menu_poster() -> void:
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


func _backdrop_size() -> Vector2i:
	return get_window().size.clamp(Vector2i(2, 2), Vector2i(2560, 1440))


func _report_first_menu_frame() -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	print("MENU_FIRST_FRAME_MS=", Time.get_ticks_msec())


# ---------- Настройки ----------

func _open_settings() -> void:
	_settings_from = "pause" if screens.pause.visible else "menu"
	_sync_settings_controls()
	_show("settings")


func _close_settings() -> void:
	if display_options != null:
		display_options.revert()
	_save_due = -1
	GameContext.scope.settings.save_settings()
	_show(_settings_from)


## Управление, звук и графика применяются сразу; на диск — чуть позже, чтобы не писать файл на каждый шаг ползунка
func _settings_changed() -> void:
	_save_due = Time.get_ticks_msec() + 400


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
		"Сбросить", true, _do_reset_settings)


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


func _show_values() -> void:
	%MouseValue.text = "%.2f×" % GameContext.scope.settings.mouse
	%FovValue.text = "%d°" % roundi(GameContext.scope.settings.fov)
	%VolumeValue.text = "%d %%" % roundi(GameContext.scope.settings.volume * 100.0)
	%DayValue.text = "%d мин" % roundi(GameContext.scope.settings.day_minutes) if GameContext.scope.settings.day_minutes > 0.0 else "время стоит"
	%StartHourValue.text = DayCycle.clock(GameContext.scope.settings.start_hour) if GameContext.scope.settings.start_hour_set else "случайный"


func _on_mouse_changed(v: float) -> void:
	GameContext.scope.settings.mouse = v
	_settings_changed()
	_show_values()


func _on_fov_changed(v: float) -> void:
	GameContext.scope.settings.fov = v
	_settings_changed()
	_show_values()


func _on_volume_changed(v: float) -> void:
	GameContext.scope.settings.volume = v
	GameContext.scope.settings.apply_volume()
	_settings_changed()
	_show_values()


func _on_day_changed(v: float) -> void:
	GameContext.scope.settings.day_minutes = v
	_settings_changed()
	_show_values()


func _on_start_hour_changed(v: float) -> void:
	GameContext.scope.settings.start_hour = v
	GameContext.scope.settings.start_hour_set = true
	%RandomHour.set_pressed_no_signal(false)
	_settings_changed()
	_show_values()


func _on_random_hour_toggled(on: bool) -> void:
	GameContext.scope.settings.start_hour_set = not on
	_settings_changed()
	_show_values()


func _on_invert_toggled(on: bool) -> void:
	GameContext.scope.settings.invert_y = on
	_settings_changed()


func _on_head_bob_toggled(on: bool) -> void:
	GameContext.scope.settings.head_bob = on
	_settings_changed()


func _on_trail_clutter_toggled(on: bool) -> void:
	GameContext.scope.settings.trail_clutter = on
	_settings_changed()


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
	var settings := GameContext.scope.settings
	var known: Array = _saved_seeds + settings.recent_seeds + settings.favorite_seeds
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
	if not %NewWorld.visible:
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
			rows = RecommendedSeeds.SEEDS
	if rows.is_empty():
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


## Строка списка: миниатюра карты, зерно, подпись и состояние, звёздочка. Щелчок — выбрать мир, двойной — играть
func _seed_row(seed_text: String, note: String) -> Button:
	var row := Button.new()
	row.toggle_mode = true
	row.custom_minimum_size = Vector2(0, 60)
	row.set_meta("seed", seed_text)
	row.theme_type_variation = &"ListRow"   # выбранный мир — золотая рамка
	row.tooltip_text = seed_text if note.is_empty() else "%s — %s" % [seed_text, note]
	row.pressed.connect(_pick_seed.bind(seed_text))
	row.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.double_click and e.button_index == MOUSE_BUTTON_LEFT:
			row.accept_event()
			_pick_seed(seed_text)
			_on_start())
	var box := HBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 10)
	row.add_child(box)
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
	star.custom_minimum_size = Vector2(40, 40)
	star.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	star.focus_mode = Control.FOCUS_NONE
	var full := not fav and GameContext.scope.settings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX
	star.disabled = full
	star.tooltip_text = _star_tip(fav, full)
	star.pressed.connect(_on_star.bind(seed_text))
	box.add_child(star)
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
	if not %NewWorld.visible:
		_pick_seed(seed_edit.text.strip_edges())


func _on_seed_changed(_text: String) -> void:
	_choose_typed()


func _suggested_seed(seed_text: String) -> void:
	seed_edit.text = seed_text
	%CreateWorld.grab_focus()


func _select_world(seed_text: String) -> void:
	_selected_seed = seed_text
	if not %NewWorld.visible:
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
	return seed_edit.text.strip_edges() if %NewWorld.visible else _selected_seed


func _update_selection() -> void:
	var seed_text := _selected_seed
	var state: Dictionary = _world_cards.get(seed_text, {})
	var corrupt: bool = state.get("corrupt", false)
	var label := "Продолжить путешествие" if state.get("saved", false) else "Начать путешествие"
	%Start.text = "Все миры" if corrupt else label
	%PlaySelected.text = label
	%PlaySelected.disabled = corrupt or seed_text.is_empty()
	for row in %SeedList.get_children():
		if row is Button:
			(row as Button).set_pressed_no_signal(not seed_text.is_empty() and row.get_meta("seed", "") == seed_text)
	var tex: Texture2D = _previews.get(seed_text)
	%Preview.texture = tex
	%PreviewHint.visible = tex == null
	%PreviewHint.text = "Карта мира появится после первого запуска"
	%ChoiceName.text = "Случайный мир" if seed_text.is_empty() else "«%s»" % seed_text
	%WorldStatus.text = state.get("summary", "")
	var star: Button = %Star
	var fav := seed_text in GameContext.scope.settings.favorite_seeds
	var full := not fav and GameContext.scope.settings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX
	star.icon = UiIcons.star(fav)
	star.disabled = seed_text.is_empty() or full
	star.tooltip_text = _star_tip(fav, full)
	if corrupt:
		%WorldStatus.text = "Сохранение не читается. Можно создать мир заново; старые файлы сохранятся в архиве."
	_load_manual.disabled = not state.get("manual", false)
	%RestartWorld.disabled = seed_text.is_empty()
	%DeleteWorld.disabled = seed_text.is_empty()


## Время сохранения по часам компьютера (unix-время хранится в UTC)
static func _local_time_text(unix: int) -> String:
	var bias: int = Time.get_time_zone_from_system().get("bias", 0)
	return Time.get_datetime_string_from_unix_time(unix + bias * 60).replace("T", " ")


func _on_star_selected() -> void:
	var seed_text := _chosen_seed()
	if not seed_text.is_empty():
		_on_star(seed_text)


func _on_star(seed_text: String) -> void:
	GameContext.scope.settings.toggle_favorite(seed_text)
	GameContext.scope.settings.save_settings()
	if GameContext.scope.cache.enabled:
		GameContext.scope.cache.keep_only(GameContext.scope.settings.keep_seeds())
	_previews.clear()
	_refresh_world_cards()
	_show_seed_tab(_seed_tab)


func _restart_world() -> void:
	var seed_text := _chosen_seed()
	if seed_text.is_empty():
		return
	_ask("Создать мир заново?", "Мир «%s» будет сгенерирован заново, путешествие начнётся сначала. Старые сохранения будут перенесены в архив." % seed_text, "Создать заново", true, _do_restart_world.bind(seed_text))


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
	start_game(seed_text, WorldGenerator.START_SIZE, "", false)


func _delete_world() -> void:
	var seed_text := _chosen_seed()
	if seed_text.is_empty():
		return
	_ask("Удалить мир?", "Мир «%s» будет удалён из недавних и избранного вместе с текущими сохранениями и готовыми данными. Рекомендованные миры останутся в списке автора." % seed_text, "Удалить", true, _do_delete_world.bind(seed_text))


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
	_ask("Хранилище миров", body, "Очистить", true, _on_clear_cache)
	_confirm.get_ok_button().disabled = u.worlds == 0
	_confirm.cancel_button_text = "Закрыть"


func _on_clear_cache() -> void:
	GameContext.scope.cache.keep_only([])
	_previews.clear()
	_refresh_world_cards()
	_show_seed_tab(_seed_tab)


func _fit_menu() -> void:
	var vs := get_viewport().get_visible_rect().size
	var worlds: Control = %AllWorlds.get_node("Panel")
	worlds.custom_minimum_size = Vector2(clampf(vs.x * 0.75, 920.0, 1220.0), clampf(vs.y * 0.80, 550.0, 700.0))
	if _backdrop != null:
		_backdrop.resize(_backdrop_size())


func _process(delta: float) -> void:
	if display_options != null:
		display_options.tick()
	_flush_settings()
	if game != null and not busy and not game.paused and not game.travel_active():
		_save_elapsed += delta
		if _save_elapsed >= 60.0 or hud.visited.size() != _saved_discoveries:
			_save_elapsed = 0.0
			_save_current()
	if busy:
		var seconds := (Time.get_ticks_msec() - _load_started_ms) / 1000
		if seconds != _load_elapsed:
			_load_elapsed = seconds
			load_step.text = "%s\nПрошло: %d:%02d" % [_load_label, seconds / 60, seconds % 60]


# ---------- Старт игры ----------

## Лаборатория — отдельная сцена, без запуска/сохранения выбранного мира.
func _open_trail_lab() -> void:
	if busy or game != null or trail_lab != null or not screens.menu.visible:
		return
	trail_lab = TrailLabScene.instantiate()
	trail_lab.exit_requested.connect(_close_trail_lab)
	hud.visible = false
	_show("")
	add_child(trail_lab)


func _close_trail_lab() -> void:
	if trail_lab == null:
		return
	trail_lab.shutdown()
	trail_lab.queue_free()
	trail_lab = null
	_show("menu")


func _on_start() -> void:
	# второй запуск во время загрузки не нужен: мир уже строится
	if busy:
		return
	if %NewWorld.visible:
		_on_create_world()
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
		_message("Не удалось загрузить прогресс", latest.error + " Используйте «Создать заново»: старые файлы будут сохранены в архиве.")
		return
	_pick_seed(seed_text)
	GameContext.scope.settings.remember_seed(seed_text)
	GameContext.scope.settings.save_settings()
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
	_load_started_ms = Time.get_ticks_msec()
	_free_game()
	hud.visible = false
	_set_progress(0.0, "Подготовка")
	%LoadPreview.texture = _preview_tex(seed_text)
	%LoadPreview.visible = %LoadPreview.texture != null
	%Title.text = "Мир «%s»" % seed_text
	_show("loading")
	gen_thread = Thread.new()
	var start_at := Vector2(_pending_save.player.x, _pending_save.player.z) if not _pending_save.is_empty() else Vector2.INF
	gen_thread.start(_generate_job.bind(seed_text, size, start_at, allow_bundled))


func _generate_job(seed_text: String, size: int, start_at := Vector2.INF, allow_bundled := true) -> void:
	var cache := GameContext.scope.cache
	if cache.enabled:
		cache.keep_only(GameContext.scope.settings.keep_seeds())
		if allow_bundled and not QuickTrails.active() and size == WorldGenerator.START_SIZE:
			cache.install_bundled(WorldCache.BUNDLED, seed_text)
	var loaded := WorldLoader.load_world(seed_text, size, func(p: float, label: String) -> void:
		_set_progress.call_deferred(p, label), null, start_at)
	if loaded == null:
		# ошибка скрипта оборвала загрузку: вернуть меню, а не держать экран загрузки вечно
		_on_world_failed.call_deferred()
		return
	loaded.timings.ready_queued_us = Time.get_ticks_usec()
	_on_world_ready.call_deferred(loaded)


func _on_world_failed() -> void:
	gen_thread.wait_to_finish()
	busy = false
	_show("menu")
	_message("Мир не подготовлен", "Генерация прервалась с ошибкой. Подробности в журнале godot.log.")


func _set_progress(p: float, label: String) -> void:
	bar.value = p
	_load_label = label
	_load_elapsed = -1
	load_step.text = label


func _on_world_ready(loaded: WorldLoader) -> void:
	loaded.timings.ready_queue_ms = (Time.get_ticks_usec() - int(loaded.timings.get("ready_queued_us", Time.get_ticks_usec()))) / 1000.0
	loaded.timings.erase("ready_queued_us")
	gen_thread.wait_to_finish()
	if not loaded.error.is_empty():
		busy = false
		_show("menu")
		_message("Мир не подготовлен", loaded.error)
		return
	if not _pending_save.is_empty() and not GameWorld.can_restore(_pending_save, loaded.world):
		busy = false
		_show("menu")
		_message("Мир изменился", "Места этого мира изменились после обновления. Сохранение оставлено без изменений. Нажмите «Создать заново», чтобы пересоздать этот мир и начать новое путешествие.")
		return
	# GameWorld.start идёт в главном потоке: подпись должна успеть показаться до него
	_set_progress(0.97, "Окружение вокруг игрока")
	var phase_started := Time.get_ticks_usec()
	await get_tree().process_frame
	loaded.timings.ready_frame_wait_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	phase_started = Time.get_ticks_usec()
	game = GameScene.instantiate()
	game.pause_requested.connect(_toggle_pause)
	add_child(game)
	loaded.timings.game_scene_create_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	phase_started = Time.get_ticks_usec()
	game.start(loaded, hud, _pending_save)
	if not loaded.error.is_empty():
		_free_game()
		hud.visible = false
		busy = false
		_show("menu")
		_message("Мир не подготовлен", loaded.error)
		return
	loaded.timings.game_start_ms = (Time.get_ticks_usec() - phase_started) / 1000.0
	_save_elapsed = 0.0
	_saved_discoveries = hud.visited.size()
	game.quests.changed.connect(func() -> void: _save_elapsed = 60.0)
	hud.visible = not game.opening_active()
	hud.set_map_visible(false)
	_show("")
	busy = false
	phase_started = Time.get_ticks_usec()
	if _pending_save.is_empty():
		_save_current()
	loaded.timings.initial_save_ms = (Time.get_ticks_usec() - phase_started) / 1000.0


func _toggle_pause() -> void:
	if game == null:
		return
	if screens.settings.visible:
		if display_options != null and display_options.pending():
			display_options.revert()
			return
		_close_settings()
	elif game.paused:
		_resume()
	else:
		game.set_paused(true)
		_save_current()
		hud.visible = false   # подсказки и сообщения не лезут поверх панели паузы
		%PauseWorld.text = "Мир «%s»" % game.world.seed_text
		_fill_controls()
		_show("pause")


func _resume() -> void:
	_close_confirm()
	_show("")
	hud.visible = not game.opening_active()
	game.set_paused(false)
	# щелчок по кнопке «Продолжить» не должен сразу считаться щелчком по миру
	get_viewport().gui_release_focus()


## Мир живёт, пока на него ссылаются игра и интерфейс: обе ссылки снимаются здесь, а внутри мира ссылок
## наверх нет (рельеф за краем знает только размер карты), поэтому он освобождается сам целиком.
## Проверка: tools/lifecycle_test.gd
func _free_game() -> void:
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
		"В меню", false, _back_to_menu)


func _confirm_exit() -> void:
	if game == null:
		_exit_game()
		return
	_ask("Выйти из игры?", "Прогресс сохранится, игра закроется.", "Выйти", true, _exit_game)


## Подтверждение; фокус на «Остаться», чтобы Enter по привычке ничего не закрыл
func _ask(title: String, body: String, ok_text: String, danger: bool, action: Callable) -> void:
	_close_confirm()
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
		_close_confirm()
		action.call())
	dialog.canceled.connect(_close_confirm)
	dialog.popup_centered(Vector2i(440, 0))
	dialog.get_cancel_button().grab_focus()


func _close_confirm() -> void:
	if _confirm != null:
		_confirm.hide()   # скрыть сразу: до удаления окно ещё держит модальность
		_confirm.queue_free()
		_confirm = null


func _back_to_menu() -> void:
	if not _save_current():
		return
	_free_game()
	hud.visible = false
	_previews.clear()   # после игры у мира появилось или обновилось превью
	_refresh_world_cards()
	_show("menu")


func _exit_game() -> void:
	if display_options != null:
		display_options.revert()
	if busy:
		_message("Мир загружается", "Дождитесь завершения загрузки перед выходом.")
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
	var err := Saves.write_slot(game.save_state(), slot)
	if err == OK:
		_saved_discoveries = hud.visited.size()
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
	_ask("Загрузить сохранение?", "Текущий прогресс будет записан в автосохранение.\nЗатем загрузится ручное сохранение этого мира.",
		"Загрузить", false, start_game.bind(seed_text, WorldGenerator.START_SIZE, slot))


## Кнопки сохранения стоят в сцене (меню — «Загрузить ручное», пауза — быстрое сохранение и загрузка),
## здесь только поведение и подсказки управления паузы
func _setup_save_controls() -> void:
	%RestartWorld.pressed.connect(_restart_world)
	%DeleteWorld.pressed.connect(_delete_world)
	_load_manual = %LoadManual
	_load_manual.pressed.connect(func() -> void: _confirm_load(_chosen_seed(), "manual"))
	_save_status = %SaveStatus
	%QuickSave.pressed.connect(func() -> void: _save_current("manual"))
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
		rows.append(["ЛКМ (держать)", "памп на велосипеде"])
		rows.append(["%s → %s" % [c.label(&"bike_back"), c.label(&"bike_forward")], "баннихоп"])
	rows.append([c.label(&"interact"), "действие, слезть"])
	rows.append([c.label(&"flashlight"), "фонарик"])
	rows.append([c.label(&"recover_bike"), "выбрать место для велосипеда"])
	rows.append([c.label(&"toggle_map"), "карта"])
	rows.append([c.label(&"photo") if pad else "ПКМ", "фотоаппарат"])
	if not pad:
		rows.append([c.label(&"time_skip"), "время суток (+Shift — назад)"])
	rows.append([c.label(&"show_hud"), "сводка (зажать)"])
	rows.append([c.label(&"pause"), "пауза"])
	return rows


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
	if display_options != null:
		display_options.shutdown()
	if gen_thread != null and gen_thread.is_started():
		gen_thread.wait_to_finish()
	GameContext.scope.cache.wait_writes()   # мир дописывается в кэш в фоне; оборванная запись осталась бы только .tmp
