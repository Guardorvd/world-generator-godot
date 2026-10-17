extends Node
## Приложение: меню, экраны, загрузка мира, пауза, выход. Копия js/ui/app.js и js/ui/menu-background.js.
## Мир генерируется и запекается в отдельном потоке, чтобы экран загрузки обновлялся.

const WORDS := ["Север", "Туман", "Янтарь", "Ветер", "Кедр", "Заря", "Омут", "Пустошь", "Гроза", "Сокол", "Иней", "Полынь", "Руда", "Ключ"]
const SIZES := [[256, "Малый (256 × 256)"], [512, "Средний (512 × 512)"], [768, "Большой (768 × 768)"]]

var ui: CanvasLayer
var bg: TextureRect
var hud: Hud
var screens := {}
var seed_edit: LineEdit
var size_select: OptionButton
var bar: ProgressBar
var load_step: Label

var game: GameWorld
var busy := false
var gen_thread: Thread
var bg_thread: Thread
var bg_time := 0.0


## Пикселей текстуры рельефа на клетку. В JS-версии 8 / 6 / 4, здесь меньше: в GDScript запекание
## заметно медленнее. Начиная со среднего мира текстура и карта (2 пикселя на клетку) пекутся за один проход.
static func px_for(size: int) -> int:
	return 4 if size <= 256 else 2


static func random_seed() -> String:
	return "%s-%d" % [WORDS[randi() % WORDS.size()], randi_range(1000, 9999)]


func _ready() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = UiStyle.make_theme()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(root)

	var back := ColorRect.new()
	back.color = Color.html("#0d1626")
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(back)
	screens.back = back
	bg = TextureRect.new()
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	back.add_child(bg)

	hud = Hud.new()
	hud.visible = false
	root.add_child(hud)

	screens.menu = _build_menu(root)
	screens.loading = _build_loading(root)
	screens.pause = _build_pause(root)
	_show("menu")

	bg_thread = Thread.new()
	bg_thread.start(_menu_background_job.bind("menu-%d" % randi_range(0, 999999)))


func _screen(root: Control, title: String) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var h := Label.new()
	h.text = title
	h.add_theme_font_size_override("font_size", 34)
	h.add_theme_color_override("font_color", UiStyle.ACCENT)
	h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(h)
	return box


func _button(box: Container, text: String, action: Callable, primary := false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	if primary:
		UiStyle.primary(b)
	b.pressed.connect(action)
	box.add_child(b)
	return b


func _build_menu(root: Control) -> Control:
	var box := _screen(root, "Генератор миров")
	var sub := Label.new()
	sub.text = "Прогулка от первого лица по миру, который создаётся заново: горы, реки, леса и тропы"
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", Color(0.8, 0.82, 0.85))
	box.add_child(sub)

	var l1 := Label.new()
	l1.text = "Зерно мира"
	box.add_child(l1)
	var row := HBoxContainer.new()
	seed_edit = LineEdit.new()
	seed_edit.max_length = 32
	seed_edit.text = random_seed()
	seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_edit.text_submitted.connect(func(_t: String) -> void: _on_start())
	row.add_child(seed_edit)
	var dice := Button.new()
	dice.text = "🎲"
	dice.tooltip_text = "Случайное зерно"
	dice.custom_minimum_size = Vector2(48, 0)
	dice.pressed.connect(func() -> void: seed_edit.text = random_seed())
	row.add_child(dice)
	box.add_child(row)

	var l2 := Label.new()
	l2.text = "Размер мира"
	box.add_child(l2)
	size_select = OptionButton.new()
	for s in SIZES:
		size_select.add_item(s[1], s[0])
	size_select.select(1)
	box.add_child(size_select)

	_button(box, "Начать игру", _on_start, true)
	_button(box, "Выход", _exit_game)
	var ver := Label.new()
	ver.text = "Версия " + GameConfig.VERSION
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver.add_theme_font_size_override("font_size", 13)
	ver.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	box.add_child(ver)
	return box.get_parent().get_parent()


func _build_loading(root: Control) -> Control:
	var box := _screen(root, "Создание мира…")
	bar = ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 14)
	box.add_child(bar)
	load_step = Label.new()
	load_step.text = "Подготовка"
	load_step.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(load_step)
	return box.get_parent().get_parent()


func _build_pause(root: Control) -> Control:
	var box := _screen(root, "Пауза")
	_button(box, "Продолжить", _resume, true)
	_button(box, "Новый мир", func() -> void:
		seed_edit.text = random_seed()
		_on_start())
	_button(box, "Главное меню", _back_to_menu)
	_button(box, "Выход", _exit_game)
	return box.get_parent().get_parent()


func _show(screen: String) -> void:
	for s in ["menu", "loading", "pause"]:
		screens[s].visible = s == screen
	screens.back.visible = screen == "menu" or screen == "loading"


# ---------- Фон меню: маленький мир сверху, медленно проплывающий под панелью ----------

func _menu_background_job(seed_text: String) -> void:
	var w := WorldGenerator.generate(seed_text, 192)
	var img := MapBaker.bake(w, 4, false)
	call_deferred("_on_menu_background", img)


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
	var progress := func(p: float, label: String) -> void: call_deferred("_set_progress", p, label)
	var w := WorldGenerator.generate(seed_text, size, progress)
	# Текстура рельефа без отмывки (свет считает движок) и карта с рельефом для мини-карты
	var px := px_for(size)
	var tex: Image
	var map: Image
	if px == 2:
		var both := MapBaker.bake_both(w, 2)
		tex = both[0]
		map = both[1]
	else:
		tex = MapBaker.bake(w, px, true)
		progress.call(0.92, "Рисование карты")
		map = MapBaker.bake(w, 2, false)
	progress.call(0.97, "Строительство 3D-сцены")
	var heights := Heightfield.new(w)
	call_deferred("_on_world_ready", w, heights, tex, map)


func _set_progress(p: float, label: String) -> void:
	bar.value = p
	load_step.text = label


func _on_world_ready(w: WorldData, heights: Heightfield, tex: Image, map: Image) -> void:
	gen_thread.wait_to_finish()
	game = GameWorld.new()
	game.name = "Game"
	game.pause_requested.connect(_toggle_pause)
	add_child(game)
	game.start(w, heights, tex, map, hud)
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
