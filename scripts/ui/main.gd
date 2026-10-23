extends Node
## Приложение: меню, экраны, загрузка мира, пауза, выход. Копия js/ui/app.js и js/ui/menu-background.js.
## Экраны собраны в сцене scenes/main.tscn (оформление — resources/ui_theme.tres), здесь только поведение.
## Мир загружается в отдельном потоке (WorldLoader), чтобы экран загрузки обновлялся.
## Экран настроек открывается из меню и из паузы и возвращает туда же; настройки — GameSettings.
## С 10.0 под полем зерна — список миров: недавние, избранные (звёздочка) и рекомендованные автором
## (RecommendedSeeds). Миры недавних и избранных хранятся готовыми в кэше (WorldCache), остальные удаляются.
## С 10.2 меню в две колонки: список миров с картами-миниатюрами и выбранный мир с картой и состоянием.

const WORDS := ["Север", "Туман", "Янтарь", "Ветер", "Кедр", "Заря", "Омут", "Пустошь", "Гроза", "Сокол", "Иней", "Полынь", "Руда", "Ключ"]
const GameScene := preload("res://scenes/game_world.tscn")
const Saves := preload("res://scripts/game/save_game.gd")
const DisplayOptions := preload("res://scripts/ui/display_options.gd")

var game: GameWorld
var busy := false
var gen_thread: Thread
var bg_thread: Thread
var bg_time := 0.0
var _load_started_ms := 0
var _load_elapsed := -1
var _load_label := ""
var _settings_from := "menu"   # куда вернуться из настроек
var _seed_tab := "recent"      # вкладка списка миров: recent, favorites, recommended
var _previews := {}            # зерно -> превью карты из кэша (ImageTexture) или null
var _pending_save := {}
var _save_elapsed := 0.0
var _save_status: Label
var _load_manual: Button
var _saved_discoveries := 0
var _progress_enabled := false # инструменты не записывают пользовательский прогресс
var display_options: DisplayOptions

@onready var hud: Hud = %Hud
@onready var bg: TextureRect = %MenuBackground
@onready var seed_edit: LineEdit = %SeedEdit
@onready var bar: ProgressBar = %Progress
@onready var load_step: Label = %Step
@onready var screens := {back = %Back, menu = %Menu, loading = %Loading, pause = %Pause, settings = %Settings}


static func random_seed() -> String:
	return "%s-%d" % [WORDS[randi() % WORDS.size()], randi_range(1000, 9999)]


func _ready() -> void:
	GameSettings.load_settings()
	GameSettings.apply_window()
	GameSettings.apply_volume()
	# в поле — зерно последнего мира (если было), иначе случайное
	seed_edit.text = GameSettings.last_seed if not GameSettings.last_seed.is_empty() else random_seed()
	%Version.text = "Версия " + str(ProjectSettings.get_setting("application/config/version", "?"))
	# кэш миров — только у самой игры: инструменты проверки ставят эту сцену не главной и генерируют честно
	_progress_enabled = get_tree().current_scene == self
	WorldCache.enabled = _progress_enabled
	get_tree().auto_accept_quit = false
	_setup_save_controls()
	display_options = DisplayOptions.new()
	display_options.setup(self)
	if WorldCache.enabled:
		WorldCache.keep_only(GameSettings.keep_seeds())
	var tabs := ButtonGroup.new()
	for tab: String in ["recent", "favorites", "recommended", "saved"]:
		var b: Button = _tab_button(tab)
		b.button_group = tabs
		b.pressed.connect(_show_seed_tab.bind(tab))
	_show_seed_tab("saved" if not Saves.seeds().is_empty() else ("recent" if not GameSettings.recent_seeds.is_empty() else "recommended"))
	%LoadPreview.texture = null
	_show("menu")
	bg_thread = Thread.new()
	bg_thread.start(_menu_background_job.bind("menu-%d" % randi_range(0, 999999)))


func _show(screen: String) -> void:
	for s in ["menu", "loading", "pause", "settings"]:
		screens[s].visible = s == screen
	screens.back.visible = screen == "menu" or screen == "loading" or (screen == "settings" and game == null)
	# фокус на главной кнопке экрана: можно пользоваться клавиатурой (стрелки, Enter)
	match screen:
		"menu":
			%Start.grab_focus()
		"pause":
			%Resume.grab_focus()
		"settings":
			%Done.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	# Esc (или B на геймпаде) в настройках из главного меню; в игре Esc приходит через GameWorld.pause_requested
	if (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")) and screens.settings.visible and game == null:
		_close_settings()
		get_viewport().set_input_as_handled()


# ---------- Настройки ----------

func _open_settings() -> void:
	_settings_from = "pause" if screens.pause.visible else "menu"
	_sync_settings_controls()
	_show("settings")


func _close_settings() -> void:
	if display_options != null:
		display_options.revert()
	GameSettings.save_settings()
	_show(_settings_from)


## Ставит ползунки и флажки в соответствие с GameSettings; без сигналов, чтобы не сохранять лишнее
func _sync_settings_controls() -> void:
	%MouseSlider.set_value_no_signal(GameSettings.mouse)
	%FovSlider.set_value_no_signal(GameSettings.fov)
	%InvertY.set_pressed_no_signal(GameSettings.invert_y)
	%HeadBob.set_pressed_no_signal(GameSettings.head_bob)
	%Fullscreen.set_pressed_no_signal(GameSettings.fullscreen)
	%Shadows.set_pressed_no_signal(GameSettings.shadows)
	if %DrawOption.item_count == 0:
		for level: Dictionary in GameSettings.DRAW_LEVELS:
			%DrawOption.add_item(level.title.capitalize())
	%DrawOption.select(GameSettings.draw)
	%VolumeSlider.set_value_no_signal(GameSettings.volume)
	%DaySlider.set_value_no_signal(GameSettings.day_minutes)
	%StartHourSlider.set_value_no_signal(GameSettings.start_hour)
	%RandomHour.set_pressed_no_signal(not GameSettings.start_hour_set)
	if display_options != null:
		display_options.sync()
	_show_values()


func _on_reset_settings() -> void:
	var display_state := GameSettings.display_state()
	GameSettings.reset_defaults()
	# Режим экрана меняется только через «Применить» и подтверждение.
	var defaults := GameSettings.display_state()
	GameSettings.set_display_state(display_state)
	GameSettings.apply_volume()
	GameSettings.save_settings()
	_sync_settings_controls()
	if display_options != null:
		GameSettings.set_display_state(defaults)
		display_options.sync()
		GameSettings.set_display_state(display_state)


func _show_values() -> void:
	%MouseValue.text = "%.2f×" % GameSettings.mouse
	%FovValue.text = "%d°" % roundi(GameSettings.fov)
	%VolumeValue.text = "%d %%" % roundi(GameSettings.volume * 100.0)
	%DayValue.text = "%d мин" % roundi(GameSettings.day_minutes) if GameSettings.day_minutes > 0.0 else "время стоит"
	%StartHourValue.text = DayCycle.clock(GameSettings.start_hour) if GameSettings.start_hour_set else "случайный"


func _on_mouse_changed(v: float) -> void:
	GameSettings.mouse = v
	_show_values()


func _on_fov_changed(v: float) -> void:
	GameSettings.fov = v
	_show_values()


func _on_volume_changed(v: float) -> void:
	GameSettings.volume = v
	GameSettings.apply_volume()
	_show_values()


func _on_day_changed(v: float) -> void:
	GameSettings.day_minutes = v
	_show_values()


func _on_start_hour_changed(v: float) -> void:
	GameSettings.start_hour = v
	GameSettings.start_hour_set = true
	%RandomHour.set_pressed_no_signal(false)
	_show_values()


func _on_random_hour_toggled(on: bool) -> void:
	GameSettings.start_hour_set = not on
	_show_values()


func _on_invert_toggled(on: bool) -> void:
	GameSettings.invert_y = on


func _on_head_bob_toggled(on: bool) -> void:
	GameSettings.head_bob = on


func _on_fullscreen_toggled(on: bool) -> void:
	if display_options != null:
		display_options.mode.select(1 if on else 0)
	else:
		GameSettings.fullscreen = on
		GameSettings.apply_window()


func _on_shadows_toggled(on: bool) -> void:
	if display_options == null:
		GameSettings.shadows = on


func _on_draw_selected(index: int) -> void:
	if display_options == null:
		GameSettings.draw = index


func _on_seed_submitted(_text: String) -> void:
	_on_start()


func _on_dice_pressed() -> void:
	seed_edit.text = random_seed()
	_update_selection()


# ---------- Список миров ----------
# С 10.2 меню в две колонки: слева список миров с картой-миниатюрой и состоянием, справа выбранный мир —
# карта крупно, зерно, звёздочка, что будет при запуске (из сохранённого или заново) и «Начать игру».

func _tab_button(tab: String) -> Button:
	return {recent = %Recent, favorites = %Favorites, recommended = %Recommended, saved = %Saved}[tab]


## Превью карты мира из кэша (null — мир ещё не запускали)
func _preview_tex(seed_text: String) -> Texture2D:
	if not _previews.has(seed_text):
		var img := WorldCache.preview(seed_text) if WorldCache.enabled else null
		_previews[seed_text] = ImageTexture.create_from_image(img) if img != null else null
	return _previews[seed_text]


## Состояние мира в кэше: [коротко для строки, подробно для панели]
func _world_status(seed_text: String) -> Array:
	if not WorldCache.enabled:
		return ["", ""]
	var n := WorldCache.ready_layers(seed_text)
	if n > WorldGenerator.LAYERS.size():
		return ["готов", "Кэш готов: мир загрузится быстрее. Прогресс хранится отдельно."]
	if n > 0:
		return ["частично", "Кэш обновится частично. Сохранение прогресса хранится отдельно."]
	if _preview_tex(seed_text) != null:
		return ["обновится", "Игра обновилась: мир создастся заново, это около минуты."]
	return ["новый", "Кэша нет: создание займёт около минуты. Сохранения прогресса сохраняются."]


func _show_seed_tab(tab: String) -> void:
	_seed_tab = tab
	# выбранная вкладка — золотой подписью, как заголовок; остальные приглушены
	for name: String in ["recent", "favorites", "recommended", "saved"]:
		var b := _tab_button(name)
		b.set_pressed_no_signal(name == tab)
		var color := Color(0.85, 0.72, 0.42) if name == tab else Color(1, 1, 1, 0.55)
		for key: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
			b.add_theme_color_override(key, color)
	var list: VBoxContainer = %SeedList
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()
	var rows: Array = []
	match tab:
		"saved":
			rows = Saves.seeds().map(func(s: String) -> Dictionary: return {seed = s, note = "Прогресс"})
		"recent":
			rows = GameSettings.recent_seeds.map(func(s: String) -> Dictionary: return {seed = s, note = ""})
		"favorites":
			rows = GameSettings.favorite_seeds.map(func(s: String) -> Dictionary: return {seed = s, note = ""})
		"recommended":
			rows = RecommendedSeeds.SEEDS
	if rows.is_empty():
		var hint := Label.new()
		hint.text = {recent = "Здесь появятся последние миры", favorites = "Отметьте мир звёздочкой, и он останется здесь",
			recommended = "Автор пока ничего не рекомендовал", saved = "Сохранения появятся после начала игры"}[tab]
		hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		hint.add_theme_font_size_override("font_size", 14)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(hint)
	for r: Dictionary in rows:
		list.add_child(_seed_row(str(r.seed), str(r.get("note", ""))))
	_update_selection()
	_update_cache_info()


## Строка списка: миниатюра карты, зерно, подпись и состояние, звёздочка. Щелчок — выбрать мир, двойной — играть
func _seed_row(seed_text: String, note: String) -> Button:
	var row := Button.new()
	row.toggle_mode = true
	row.custom_minimum_size = Vector2(0, 60)
	row.set_meta("seed", seed_text)
	# выбранный мир — золотая рамка
	var selected := StyleBoxFlat.new()
	selected.bg_color = Color(0.85, 0.72, 0.42, 0.16)
	selected.border_color = Color(0.85, 0.72, 0.42, 0.9)
	selected.set_border_width_all(2)
	selected.set_corner_radius_all(6)
	for key: String in ["pressed", "hover_pressed"]:
		row.add_theme_stylebox_override(key, selected)
	row.tooltip_text = seed_text if note.is_empty() else "%s — %s" % [seed_text, note]
	row.pressed.connect(_pick_seed.bind(seed_text))
	row.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.double_click and e.button_index == MOUSE_BUTTON_LEFT:
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
		q.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
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
	var status: String = _world_status(seed_text)[0]
	var sub := " · ".join(PackedStringArray([note, status]).slice(0 if not note.is_empty() else 1)) \
		if not status.is_empty() else note
	if not sub.is_empty():
		var sub_label := Label.new()
		sub_label.text = sub
		sub_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		sub_label.add_theme_font_size_override("font_size", 12)
		sub_label.add_theme_color_override("font_color", Color(0.85, 0.72, 0.42, 0.85) if status == "готов" \
			else Color(1, 1, 1, 0.5))
		texts.add_child(sub_label)
	box.add_child(texts)
	var fav := seed_text in GameSettings.favorite_seeds
	var star := Button.new()
	star.flat = true
	star.text = "★" if fav else "☆"
	star.custom_minimum_size = Vector2(36, 36)
	star.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	star.focus_mode = Control.FOCUS_NONE
	star.add_theme_font_size_override("font_size", 18)
	var full := not fav and GameSettings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX
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
	seed_edit.text = seed_text
	_update_selection()
	%Start.grab_focus()


func _on_seed_changed(_text: String) -> void:
	_update_selection()


## Выбранный мир (зерно в поле): подсветка строки, карта, звёздочка и что будет при запуске
func _update_selection() -> void:
	var seed_text := seed_edit.text.strip_edges()
	for row in %SeedList.get_children():
		if row is Button:
			(row as Button).set_pressed_no_signal(row.get_meta("seed", "") == seed_text)
	var tex := _preview_tex(seed_text) if not seed_text.is_empty() else null
	%Preview.texture = tex
	%PreviewHint.visible = tex == null
	%PreviewHint.text = "Введите зерно или выберите мир" if seed_text.is_empty() \
		else "Карта мира появится после первого запуска"
	%WorldStatus.text = _world_status(seed_text)[1] if not seed_text.is_empty() \
		else "Пустое поле — будет случайный мир."
	var star: Button = %Star
	var fav := seed_text in GameSettings.favorite_seeds
	var full := not fav and GameSettings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX
	star.text = "★" if fav else "☆"
	star.disabled = seed_text.is_empty() or full
	star.tooltip_text = _star_tip(fav, full)
	var latest := _latest_save(seed_text)
	%Start.text = "Продолжить" if not latest.data.is_empty() else "Начать путешествие"
	_load_manual.disabled = Saves.read_slot(seed_text, "manual").data.is_empty()
	if not latest.data.is_empty():
		var d: Dictionary = latest.data
		%WorldStatus.text = "Открыто мест: %d · Заданий: %d\nСохранено: %s\nКэш: %s" % [
			d.visited.size(), d.quest.done, Time.get_datetime_string_from_unix_time(int(d.saved_at)).replace("T", " ") + " UTC", _world_status(seed_text)[0]]


func _on_star_selected() -> void:
	var seed_text := seed_edit.text.strip_edges()
	if not seed_text.is_empty():
		_on_star(seed_text)


func _on_star(seed_text: String) -> void:
	GameSettings.toggle_favorite(seed_text)
	GameSettings.save_settings()
	if WorldCache.enabled:
		WorldCache.keep_only(GameSettings.keep_seeds())
	_show_seed_tab(_seed_tab)


## Сколько миров сохранено и сколько места они занимают
func _update_cache_info() -> void:
	%CacheInfo.get_parent().visible = WorldCache.enabled
	if not WorldCache.enabled:
		return
	var u := WorldCache.usage()
	%CacheInfo.text = "Кэш пуст" if u.worlds == 0 \
		else "Кэш: %d миров · %d МБ" % [u.worlds, roundi(u.bytes / 1048576.0)]
	%ClearCache.disabled = u.worlds == 0


func _on_clear_cache() -> void:
	WorldCache.keep_only([])
	_previews.clear()
	_show_seed_tab(_seed_tab)


func _on_new_world() -> void:
	seed_edit.text = random_seed()
	_on_start()


# ---------- Фон меню: маленький мир сверху, медленно проплывающий под панелью ----------

func _menu_background_job(seed_text: String) -> void:
	var w := WorldGenerator.menu_background(seed_text)
	var img := MapBaker.bake(w, 4, false)
	_on_menu_background.call_deferred(img)


func _on_menu_background(img: Image) -> void:
	bg_thread.wait_to_finish()
	bg.texture = ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	if display_options != null:
		display_options.tick()
	if game != null and not busy and not game.paused:
		_save_elapsed += delta
		if _save_elapsed >= 60.0 or hud.visited.size() != _saved_discoveries:
			_save_elapsed = 0.0
			_save_current()
	if busy:
		var seconds := (Time.get_ticks_msec() - _load_started_ms) / 1000
		if seconds != _load_elapsed:
			_load_elapsed = seconds
			load_step.text = "%s\nПрошло: %d:%02d" % [_load_label, seconds / 60, seconds % 60]
	if not screens.back.visible or bg.texture == null:
		return
	bg_time += delta * 1000.0
	var vs := get_viewport().get_visible_rect().size
	var tw := float(bg.texture.get_width())
	var s := (maxf(vs.x, vs.y) / tw) * 1.6
	var sz := Vector2(tw, bg.texture.get_height()) * s
	var a := bg_time / 40000.0
	bg.size = sz
	bg.position = Vector2((vs.x - sz.x) / 2.0 + cos(a) * (sz.x - vs.x) * 0.4, (vs.y - sz.y) / 2.0 + sin(a * 1.3) * (sz.y - vs.y) * 0.4)


# ---------- Старт игры ----------

func _on_start() -> void:
	# второй запуск во время загрузки не нужен: мир уже строится
	if busy:
		return
	var seed_text := seed_edit.text.strip_edges()
	if seed_text.is_empty():
		seed_text = random_seed()
	seed_edit.text = seed_text   # случайное зерно видно в поле, его можно повторить
	var latest := _latest_save(seed_text)
	if latest.data.is_empty() and _has_save(seed_text):
		_message("Не удалось загрузить прогресс", latest.error + " Файлы оставлены без изменений.")
		return
	GameSettings.remember_seed(seed_text)
	GameSettings.save_settings()
	# мир, выпавший из последних и не избранный, больше не хранится
	if WorldCache.enabled:
		WorldCache.keep_only(GameSettings.keep_seeds())
	start_game(seed_text, WorldGenerator.START_SIZE, latest.slot)


## С 9.0 мир один: план 768 × 768 генерируется всегда целиком, size — только окно, открытое на старте.
## С 9.8 по умолчанию открыт весь план; меньшее окно ставят инструменты проверки (WorldData.open_around).
func start_game(seed_text: String, size: int = WorldGenerator.START_SIZE, slot := "") -> void:
	if busy:
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
	gen_thread.start(_generate_job.bind(seed_text, size))


func _generate_job(seed_text: String, size: int) -> void:
	var loaded := WorldLoader.load_world(seed_text, size, func(p: float, label: String) -> void:
		_set_progress.call_deferred(p, label))
	_on_world_ready.call_deferred(loaded)


func _set_progress(p: float, label: String) -> void:
	bar.value = p
	_load_label = label
	_load_elapsed = -1
	load_step.text = label


func _on_world_ready(loaded: WorldLoader) -> void:
	gen_thread.wait_to_finish()
	if not _pending_save.is_empty() and not GameWorld.can_restore(_pending_save, loaded.world):
		busy = false
		_show("menu")
		_message("Мир изменился", "Места этого мира изменились после обновления. Сохранение оставлено без изменений. Для нового путешествия выберите другое зерно.")
		return
	# GameWorld.start идёт в главном потоке: подпись должна успеть показаться до него
	_set_progress(0.97, "Окружение вокруг игрока")
	await get_tree().process_frame
	game = GameScene.instantiate()
	game.pause_requested.connect(_toggle_pause)
	add_child(game)
	game.start(loaded, hud, _pending_save)
	_save_elapsed = 0.0
	_saved_discoveries = hud.visited.size()
	game.quests.changed.connect(func() -> void: _save_elapsed = 60.0)
	hud.visible = not game.opening_active()
	hud.set_map_visible(false)
	_show("")
	busy = false
	if _pending_save.is_empty():
		_save_current()


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
		_show("pause")


func _resume() -> void:
	_show("")
	hud.visible = not game.opening_active()
	game.set_paused(false)
	# щелчок по кнопке «Продолжить» не должен сразу считаться щелчком по миру
	get_viewport().gui_release_focus()


## Мир живёт, пока на него ссылаются игра и интерфейс: обе ссылки снимаются здесь, а внутри мира ссылок
## наверх нет (рельеф за краем знает только размер карты), поэтому он освобождается сам целиком.
## Проверка: tools/lifecycle_test.gd
func _free_game() -> void:
	if game != null:
		game.queue_free()
		game = null
	hud.clear_world()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _back_to_menu() -> void:
	if not _save_current():
		return
	_free_game()
	hud.visible = false
	_previews.clear()   # после игры у мира появилось или обновилось превью
	_show_seed_tab(_seed_tab)
	_show("menu")


func _exit_game() -> void:
	if display_options != null:
		display_options.revert()
	if busy:
		_message("Мир загружается", "Дождитесь завершения загрузки перед выходом.")
		return
	if not _save_current():
		return
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_exit_game()


func _latest_save(seed_text: String) -> Dictionary:
	var auto := Saves.read_slot(seed_text)
	var manual := Saves.read_slot(seed_text, "manual")
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
	var dialog := ConfirmationDialog.new()
	dialog.title = "Загрузить сохранение?"
	dialog.dialog_text = "Текущий прогресс будет записан в автосохранение.\nЗатем загрузится ручное сохранение этого мира."
	dialog.ok_button_text = "Загрузить"
	add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(func() -> void:
		start_game(seed_text, WorldGenerator.START_SIZE, slot)
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)


func _setup_save_controls() -> void:
	_load_manual = Button.new()
	_load_manual.text = "Загрузить ручное сохранение"
	_load_manual.custom_minimum_size.y = 36
	%Start.get_parent().add_child(_load_manual)
	_load_manual.pressed.connect(func() -> void: _confirm_load(seed_edit.text.strip_edges(), "manual"))
	var box := %Resume.get_parent()
	var row := HBoxContainer.new()
	box.add_child(row)
	box.move_child(row, %Resume.get_index() + 1)
	for action: String in ["Сохранить", "Загрузить"]:
		var button := Button.new()
		button.text = action
		button.custom_minimum_size.y = 40
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(button)
		if action == "Сохранить":
			button.pressed.connect(func() -> void: _save_current("manual"))
		else:
			button.pressed.connect(func() -> void:
				if Saves.read_slot(game.world.seed_text, "manual").data.is_empty():
					_message("Загрузка", "Ручного сохранения пока нет. Нажмите «Сохранить».")
				else:
					_confirm_load(game.world.seed_text, "manual"))
	_save_status = Label.new()
	_save_status.text = "Автосохранение: каждые 60 секунд, при паузе и выходе"
	_save_status.add_theme_font_size_override("font_size", 13)
	_save_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_save_status)
	box.move_child(_save_status, row.get_index() + 1)


func _exit_tree() -> void:
	if display_options != null:
		display_options.shutdown()
	for t in [gen_thread, bg_thread]:
		if t != null and t.is_started():
			t.wait_to_finish()
	WorldCache.wait_writes()   # мир дописывается в кэш в фоне; оборванная запись осталась бы только .tmp
