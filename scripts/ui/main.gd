extends Node
## Приложение: меню, экраны, загрузка мира, пауза, выход. Копия js/ui/app.js и js/ui/menu-background.js.
## Экраны собраны в сцене scenes/main.tscn (оформление — resources/ui_theme.tres), здесь только поведение.
## Мир загружается в отдельном потоке (WorldLoader), чтобы экран загрузки обновлялся.
## Экран настроек открывается из меню и из паузы и возвращает туда же; настройки — GameSettings.
## С 10.0 под полем зерна — список миров: недавние, избранные (звёздочка) и рекомендованные автором
## (RecommendedSeeds). Миры недавних и избранных хранятся готовыми в кэше (WorldCache), остальные удаляются.
## С 10.2 меню в две колонки: список миров с картами-миниатюрами и выбранный мир с картой и состоянием.
## С 12.5 оформление только из темы (вариации кнопок и надписей), пиктограммы — UiIcons. Пауза: продолжить,
## быстрое сохранение, настройки, компактное управление; уход в меню и выход — с подтверждением.
## С 12.5+ в меню выбранный мир (из списка) и новый мир по зерну (поле ввода) — разные источники: щелчок по
## строке не трогает поле, ввод в поле снимает выбор строки. Кэш — в «Хранилище миров», не на первом плане.
## Настройки: вкладки в сцене, управление и звук применяются сразу, сброс — с подтверждением.

const WORDS := ["Север", "Туман", "Янтарь", "Ветер", "Кедр", "Заря", "Омут", "Пустошь", "Гроза", "Сокол", "Иней", "Полынь", "Руда", "Ключ"]
const GameScene := preload("res://scenes/game_world.tscn")
const TrailLabScene := preload("res://scenes/trail_lab.tscn")
const Saves := preload("res://scripts/game/save_game.gd")
const DisplayOptions := preload("res://scripts/ui/display_options.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
## Подсказки управления в паузе: клавиша — действие, по две пары в строке
const CONTROLS := [
	["Мышь", "осмотреться"], ["WASD", "идти"],
	["Shift", "бег"], ["Пробел", "прыжок"],
	["E", "действие, слезть"], ["F", "фонарик"],
	["Y", "выбрать место для велосипеда"], ["M", "карта"],
	["Tab", "сводка (зажать)"], ["Esc", "пауза"],
]

var game: GameWorld
var trail_lab: Node
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
var _confirm: ConfirmationDialog   # открытое подтверждение (выход, меню, загрузка)
var _save_due := -1       # когда записать изменённые настройки (мс), -1 — нечего

@onready var hud: Hud = %Hud
@onready var bg: TextureRect = %MenuBackground
@onready var seed_edit: LineEdit = %SeedEdit
@onready var bar: ProgressBar = %Progress
@onready var load_step: Label = %Step
@onready var screens := {back = %Back, menu = %Menu, loading = %Loading, pause = %Pause, settings = %Settings}


static func random_seed() -> String:
	return "%s-%d" % [WORDS[randi() % WORDS.size()], randi_range(1000, 9999)]


func _ready() -> void:
	GameContext.scope.settings.load_settings()
	GameContext.scope.settings.apply_window()
	GameContext.scope.settings.apply_volume()
	# в поле — зерно последнего мира (если было), иначе случайное
	seed_edit.text = GameContext.scope.settings.last_seed if not GameContext.scope.settings.last_seed.is_empty() else random_seed()
	%Version.text = "Версия " + str(ProjectSettings.get_setting("application/config/version", "?"))
	# кэш миров — только у самой игры: инструменты проверки ставят эту сцену не главной и генерируют честно
	_progress_enabled = get_tree().current_scene == self
	GameContext.scope.cache.enabled = _progress_enabled
	get_tree().auto_accept_quit = false
	_setup_save_controls()
	# 14.4+: бесконечная генерация (по умолчанию выключена), с предупреждением, пока она не доделана
	%Infinite.set_pressed_no_signal(GameContext.scope.settings.infinite_world)
	%InfiniteWarning.visible = GameContext.scope.settings.infinite_world
	%Infinite.toggled.connect(func(on: bool) -> void:
		GameContext.scope.settings.infinite_world = on
		%InfiniteWarning.visible = on
		GameContext.scope.settings.save_settings())
	display_options = DisplayOptions.new()
	display_options.setup(self)
	if GameContext.scope.cache.enabled:
		GameContext.scope.cache.install_bundled()
		GameContext.scope.cache.keep_only(GameContext.scope.settings.keep_seeds())
	var tabs := ButtonGroup.new()
	for tab: String in ["recent", "favorites", "recommended", "saved"]:
		var b: Button = _tab_button(tab)
		b.button_group = tabs
		b.pressed.connect(_show_seed_tab.bind(tab))
	_show_seed_tab("saved" if not Saves.seeds().is_empty() else ("recent" if not GameContext.scope.settings.recent_seeds.is_empty() else "recommended"))
	%LoadPreview.texture = null
	get_viewport().size_changed.connect(_fit_menu)
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
			_fit_menu()
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


func _on_seed_submitted(_text: String) -> void:
	_on_start()


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
		var img := GameContext.scope.cache.preview(seed_text) if GameContext.scope.cache.enabled else null
		_previews[seed_text] = ImageTexture.create_from_image(img) if img != null else null
	return _previews[seed_text]


## Как быстро мир откроется: [коротко для строки, подробно для панели]. Без слов о кэше: игроку важно,
## ждать ли около минуты; подробности — в «Хранилище миров»
func _world_status(seed_text: String) -> Array:
	if not GameContext.scope.cache.enabled:
		return ["", ""]
	if GameContext.scope.cache.ready_layers(seed_text) > 0:
		return ["быстрый запуск", "Мир уже создавался и откроется быстро."]
	return ["", "Мир создастся при запуске, это около минуты."]


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
			rows = Saves.seeds().map(func(s: String) -> Dictionary: return {seed = s, note = "Прогресс"})
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
	var status: String = _world_status(seed_text)[0]
	var sub := " · ".join(PackedStringArray([note, status]).slice(0 if not note.is_empty() else 1)) \
		if not status.is_empty() else note
	if not sub.is_empty():
		var sub_label := Label.new()
		sub_label.text = sub
		sub_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		sub_label.theme_type_variation = &"SectionLabel" if not status.is_empty() else &"CaptionLabel"
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


## Щелчок по строке ставит её зерно в поле: с 14.2 поле — единственный источник выбора (до этого
## мир из списка и зерно в поле были разными, и не всегда было ясно, что запустится)
func _pick_seed(seed_text: String) -> void:
	seed_edit.text = seed_text
	_update_selection()
	%Start.grab_focus()


## Ввод в поле или кубик: выбор — то, что в поле; строка списка с тем же зерном подсвечивается
func _choose_typed() -> void:
	_update_selection()


func _on_seed_changed(_text: String) -> void:
	_choose_typed()


## Что запустит главная кнопка: зерно из поля (пустое — случайный мир)
func _chosen_seed() -> String:
	return seed_edit.text.strip_edges()


## Выбранный мир: подсветка строки, карта, звёздочка, прогресс и подпись главной кнопки
func _update_selection() -> void:
	var seed_text := _chosen_seed()
	for row in %SeedList.get_children():
		if row is Button:
			(row as Button).set_pressed_no_signal(not seed_text.is_empty() and row.get_meta("seed", "") == seed_text)
	var tex := _preview_tex(seed_text) if not seed_text.is_empty() else null
	%Preview.texture = tex
	%PreviewHint.visible = tex == null
	%PreviewHint.text = "Карта мира появится после первого запуска"
	%ChoiceName.text = "Случайный мир" if seed_text.is_empty() else "«%s»" % seed_text
	%WorldStatus.text = _world_status(seed_text)[1] if not seed_text.is_empty() \
		else "Пустое поле — будет случайный мир."
	var star: Button = %Star
	var fav := seed_text in GameContext.scope.settings.favorite_seeds
	var full := not fav and GameContext.scope.settings.favorite_seeds.size() >= GameSettings.FAVORITES_MAX
	star.icon = UiIcons.star(fav)
	star.disabled = seed_text.is_empty() or full
	star.tooltip_text = _star_tip(fav, full)
	var latest := _latest_save(seed_text) if not seed_text.is_empty() else {data = {}}
	if not seed_text.is_empty() and latest.data.is_empty() and _has_save(seed_text):
		%WorldStatus.text = "Сохранение не читается. Можно создать мир заново; старые файлы сохранятся в архиве."
	%Start.text = "Продолжить путешествие" if not latest.data.is_empty() else "Начать путешествие"
	_load_manual.disabled = seed_text.is_empty() or Saves.read_slot(seed_text, "manual").data.is_empty()
	%RestartWorld.disabled = seed_text.is_empty()
	%DeleteWorld.disabled = seed_text.is_empty()
	if not latest.data.is_empty():
		var d: Dictionary = latest.data
		%WorldStatus.text = "Открыто мест: %d · Заданий: %d\nСохранено: %s" % [
			d.visited.size(), d.quest.done, Time.get_datetime_string_from_unix_time(int(d.saved_at)).replace("T", " ") + " UTC"]


func _on_star_selected() -> void:
	var seed_text := _chosen_seed()
	if not seed_text.is_empty():
		_on_star(seed_text)


func _on_star(seed_text: String) -> void:
	GameContext.scope.settings.toggle_favorite(seed_text)
	GameContext.scope.settings.save_settings()
	if GameContext.scope.cache.enabled:
		GameContext.scope.cache.keep_only(GameContext.scope.settings.keep_seeds())
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
		_show_seed_tab(_seed_tab)
		return
	_previews.erase(seed_text)
	GameContext.scope.settings.remember_seed(seed_text)
	GameContext.scope.settings.save_settings()
	start_game(seed_text)


func _delete_world() -> void:
	var seed_text := _chosen_seed()
	if seed_text.is_empty():
		return
	_ask("Удалить мир?", "Мир «%s» будет удалён из недавних и избранного вместе с текущими сохранениями и готовыми данными. Рекомендованные миры останутся в списке автора." % seed_text, "Удалить", true, _do_delete_world.bind(seed_text))


func _do_delete_world(seed_text: String) -> void:
	var err := Saves.delete_seed(seed_text)
	if err == OK and GameContext.scope.cache.enabled:
		err = GameContext.scope.cache.remove_seed(seed_text)
	if err != OK:
		_message("Не удалось удалить мир", error_string(err))
		_show_seed_tab(_seed_tab)
		return
	GameContext.scope.settings.recent_seeds.erase(seed_text)
	GameContext.scope.settings.favorite_seeds.erase(seed_text)
	if GameContext.scope.settings.last_seed == seed_text:
		GameContext.scope.settings.last_seed = ""
	GameContext.scope.settings.save_settings()
	_previews.erase(seed_text)
	seed_edit.text = ""
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
	_show_seed_tab(_seed_tab)


## Две колонки меню растут с экраном: шире на широких мониторах, выше — на 4:3 (интерфейс не меньше 1280 × 720)
func _fit_menu() -> void:
	var vs := get_viewport().get_visible_rect().size
	# Запас включает две строки статуса и предупреждение бесконечной генерации.
	var compact := vs.y < 900.0
	var side: VBoxContainer = screens.menu.get_node("Panel/Box/Columns/Side")
	side.add_theme_constant_override("separation", 4 if compact else 8)
	(side.get_node("PreviewFrame") as Control).custom_minimum_size.y = 88.0 if compact else 140.0
	side.get_node("NewWorld/NewBox/SeedHelp").visible = not compact
	(screens.menu.get_node("Panel") as Control).custom_minimum_size = Vector2(clampf(vs.x * 0.74, 920.0, 1320.0), clampf(vs.y * 0.86, 600.0, 940.0))


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
	_flush_settings()
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
	var seed_text := _chosen_seed()
	if seed_text.is_empty():
		seed_text = random_seed()
		seed_edit.text = seed_text   # случайное зерно видно в поле, его можно повторить
	var latest := _latest_save(seed_text)
	if latest.data.is_empty() and _has_save(seed_text):
		_message("Не удалось загрузить прогресс", latest.error + " Используйте «Создать заново»: старые файлы будут сохранены в архиве.")
		return
	GameContext.scope.settings.remember_seed(seed_text)
	GameContext.scope.settings.save_settings()
	# мир, выпавший из последних и не избранный, больше не хранится
	if GameContext.scope.cache.enabled:
		GameContext.scope.cache.keep_only(GameContext.scope.settings.keep_seeds())
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
	loaded.timings.ready_queued_us = Time.get_ticks_usec()
	_on_world_ready.call_deferred(loaded)


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
	if game != null:
		game.queue_free()
		game = null
	hud.clear_world()
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
	var grid: GridContainer = %Controls
	for pair: Array in CONTROLS:
		var key := Label.new()
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
	for t in [gen_thread, bg_thread]:
		if t != null and t.is_started():
			t.wait_to_finish()
	GameContext.scope.cache.wait_writes()   # мир дописывается в кэш в фоне; оборванная запись осталась бы только .tmp
