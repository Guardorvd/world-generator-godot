extends Node
## Приложение: меню, экраны, загрузка мира, пауза, выход. Копия js/ui/app.js и js/ui/menu-background.js.
## Экраны собраны в сцене scenes/main.tscn (оформление — resources/ui_theme.tres), здесь только поведение.
## Мир загружается в отдельном потоке (WorldLoader), чтобы экран загрузки обновлялся.

const WORDS := ["Север", "Туман", "Янтарь", "Ветер", "Кедр", "Заря", "Омут", "Пустошь", "Гроза", "Сокол", "Иней", "Полынь", "Руда", "Ключ"]
const SIZES := [[256, "Малый (256 × 256)"], [512, "Средний (512 × 512)"], [768, "Большой (768 × 768)"]]
const GameScene := preload("res://scenes/game_world.tscn")

var game: GameWorld
var busy := false
var gen_thread: Thread
var bg_thread: Thread
var bg_time := 0.0

@onready var hud: Hud = %Hud
@onready var bg: TextureRect = %MenuBackground
@onready var seed_edit: LineEdit = %SeedEdit
@onready var size_select: OptionButton = %SizeSelect
@onready var bar: ProgressBar = %Progress
@onready var load_step: Label = %Step
@onready var screens := {back = %Back, menu = %Menu, loading = %Loading, pause = %Pause}


static func random_seed() -> String:
	return "%s-%d" % [WORDS[randi() % WORDS.size()], randi_range(1000, 9999)]


func _ready() -> void:
	seed_edit.text = random_seed()
	for s in SIZES:
		size_select.add_item(s[1], s[0])
	size_select.select(1)
	%Version.text = "Версия " + ProjectSettings.get_setting("application/config/version")
	_show("menu")
	bg_thread = Thread.new()
	bg_thread.start(_menu_background_job.bind("menu-%d" % randi_range(0, 999999)))


func _show(screen: String) -> void:
	for s in ["menu", "loading", "pause"]:
		screens[s].visible = s == screen
	screens.back.visible = screen == "menu" or screen == "loading"


func _on_seed_submitted(_text: String) -> void:
	_on_start()


func _on_dice_pressed() -> void:
	seed_edit.text = random_seed()


func _on_new_world() -> void:
	seed_edit.text = random_seed()
	_on_start()


# ---------- Фон меню: маленький мир сверху, медленно проплывающий под панелью ----------

func _menu_background_job(seed_text: String) -> void:
	var w := WorldGenerator.generate(seed_text, 192)
	var img := MapBaker.bake(w, 4, false)
	_on_menu_background.call_deferred(img)


func _on_menu_background(img: Image) -> void:
	bg_thread.wait_to_finish()
	bg.texture = ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
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
	var seed_text := seed_edit.text.strip_edges()
	if seed_text.is_empty():
		seed_text = random_seed()
	start_game(seed_text, size_select.get_selected_id())


func start_game(seed_text: String, size: int) -> void:
	if busy:
		return
	busy = true
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
	if game.paused:
		_resume()
	else:
		game.set_paused(true)
		_show("pause")


func _resume() -> void:
	_show("")
	game.set_paused(false)


func _free_game() -> void:
	if game != null:
		game.queue_free()
		game = null
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
