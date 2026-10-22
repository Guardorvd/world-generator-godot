extends Node
## Приложение: меню, экраны, загрузка мира, пауза, выход. Копия js/ui/app.js и js/ui/menu-background.js.
## Экраны собраны в сцене scenes/main.tscn (оформление — resources/ui_theme.tres), здесь только поведение.
## Мир загружается в отдельном потоке (WorldLoader), чтобы экран загрузки обновлялся.
## Экран настроек открывается из меню и из паузы и возвращает туда же; настройки — GameSettings.

const WORDS := ["Север", "Туман", "Янтарь", "Ветер", "Кедр", "Заря", "Омут", "Пустошь", "Гроза", "Сокол", "Иней", "Полынь", "Руда", "Ключ"]
const SIZES := [[256, "Малая территория (256 × 256)"], [512, "Средняя территория (512 × 512)"], [768, "Большая территория (768 × 768)"]]
const GameScene := preload("res://scenes/game_world.tscn")

var game: GameWorld
var busy := false
var gen_thread: Thread
var bg_thread: Thread
var bg_time := 0.0
var _load_started_ms := 0
var _load_elapsed := -1
var _load_label := ""
var _settings_from := "menu"   # куда вернуться из настроек

@onready var hud: Hud = %Hud
@onready var bg: TextureRect = %MenuBackground
@onready var seed_edit: LineEdit = %SeedEdit
@onready var size_select: OptionButton = %SizeSelect
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
	for s in SIZES:
		size_select.add_item(s[1], s[0])
	size_select.select(maxi(0, size_select.get_item_index(GameSettings.world_size)))
	%Version.text = "Версия " + str(ProjectSettings.get_setting("application/config/version", "?"))
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
			%ExpandTerritory.disabled = game == null or game.world.available_rect.size.x >= WorldGenerator.PLAN_SIZE
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
	%VolumeSlider.set_value_no_signal(GameSettings.volume)
	%DaySlider.set_value_no_signal(GameSettings.day_minutes)
	%StartHourSlider.set_value_no_signal(GameSettings.start_hour)
	_show_values()


func _on_reset_settings() -> void:
	GameSettings.reset_defaults()
	GameSettings.apply_window()
	GameSettings.apply_volume()
	GameSettings.save_settings()
	_sync_settings_controls()


func _show_values() -> void:
	%MouseValue.text = "%.2f×" % GameSettings.mouse
	%FovValue.text = "%d°" % roundi(GameSettings.fov)
	%VolumeValue.text = "%d %%" % roundi(GameSettings.volume * 100.0)
	%DayValue.text = "%d мин" % roundi(GameSettings.day_minutes) if GameSettings.day_minutes > 0.0 else "время стоит"
	%StartHourValue.text = DayCycle.clock(GameSettings.start_hour)


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
	_show_values()


func _on_invert_toggled(on: bool) -> void:
	GameSettings.invert_y = on


func _on_head_bob_toggled(on: bool) -> void:
	GameSettings.head_bob = on


func _on_fullscreen_toggled(on: bool) -> void:
	GameSettings.fullscreen = on
	GameSettings.apply_window()


func _on_shadows_toggled(on: bool) -> void:
	GameSettings.shadows = on


func _on_seed_submitted(_text: String) -> void:
	_on_start()


func _on_dice_pressed() -> void:
	seed_edit.text = random_seed()


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
	GameSettings.world_size = size_select.get_selected_id()
	GameSettings.last_seed = seed_text
	GameSettings.save_settings()
	start_game(seed_text, GameSettings.world_size)


func start_game(seed_text: String, size: int) -> void:
	if busy:
		return
	busy = true
	_load_started_ms = Time.get_ticks_msec()
	_free_game()
	hud.visible = false
	_set_progress(0.0, "Подготовка")
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
	game = GameScene.instantiate()
	game.pause_requested.connect(_toggle_pause)
	add_child(game)
	game.start(loaded, hud)
	hud.visible = true
	hud.set_map_visible(false)
	_show("")
	busy = false


func _toggle_pause() -> void:
	if game == null:
		return
	if screens.settings.visible:
		_close_settings()
	elif game.paused:
		_resume()
	else:
		game.set_paused(true)
		hud.visible = false   # подсказки и сообщения не лезут поверх панели паузы
		_show("pause")


## Открыть следующую территорию, сохранив тот же мир, игрока, велосипед и меши.
func _expand_territory() -> void:
	if game == null:
		return
	var side := game.world.available_rect.size.x
	var next_size := 512 if side < 512 else WorldGenerator.PLAN_SIZE
	game.world.expand_territory(next_size)
	GameSettings.world_size = next_size
	size_select.select(size_select.get_item_index(next_size))
	GameSettings.save_settings()
	_resume()
	hud.toast_now("Территория расширена до %d × %d" % [next_size, next_size])


func _resume() -> void:
	_show("")
	hud.visible = true
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
	_free_game()
	hud.visible = false
	_show("menu")


func _exit_game() -> void:
	get_tree().quit()


func _exit_tree() -> void:
	for t in [gen_thread, bg_thread]:
		if t != null and t.is_started():
			t.wait_to_finish()
