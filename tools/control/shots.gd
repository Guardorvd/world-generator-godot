extends SceneTree
## Сравнительные снимки: для каждого мира из tools/control/seeds.json (views) загружает игру и снимает
## одни и те же виды (точка появления, высочайшая вершина, долина реки, дорога, поселение — см. Dev.views),
## сохраняет карту мира и сводку мира (stats_<мир>.json: поселения, дороги, мосты, хеши). Нужно окно (не headless).
## Запуск из папки проекта (папка по умолчанию — tools/control/runs/<версия>):
##   godot --path . --script res://tools/control/shots.gd -- [--out <папка>]

const Dev := preload("res://tools/control/control.gd")
const SETTLE_FRAMES := 12   # кадров после переноса камеры до снимка

var main: Node
var out := ""
var worlds: Array = []
var index := -1         # какой мир снимаем
var views: Array = []
var view := -1
var wait := 0
var started := 0
var failed := false
var done := false


func _initialize() -> void:
	out = Dev.out_dir()
	worlds = Dev.seeds().views
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _save(img: Image, name: String, jpg: bool) -> void:
	var path := out.path_join(name + (".jpg" if jpg else ".png"))
	var err := img.save_jpg(path, 0.9) if jpg else img.save_png(path)
	if err != OK:
		printerr("Не удалось сохранить %s (ошибка %d)" % [path, err])
		failed = true
		return
	print("Снимок: ", path)


func _finish() -> bool:
	done = true
	if failed:
		printerr("Съёмка не полная")
	else:
		print("Снимки в ", out)
	quit(1 if failed else 0)
	return false


func _next_world() -> void:
	index += 1
	if index >= worlds.size():
		_finish()
		return
	var w: Array = worlds[index]
	print("Мир %s@%d" % [w[0], w[1]])
	started = Time.get_ticks_msec()
	view = -1
	main.start_game(w[0], int(w[1]))


## Ставит камеру на вид и заполняет растительность вокруг неё, как вокруг игрока
func _place(game: GameWorld, v: Dictionary) -> void:
	game.camera.fov = 70.0
	game.camera.look_at_from_position(v.pos, v.target, Vector3.UP)
	game.vegetation.update(v.pos.x, v.pos.z, true)
	# рельеф за краем карты вокруг камеры — сразу целиком, чтобы снимок не зависел от того, что успело подгрузиться
	if game.world.outer != null:
		game.outer.preload_around(v.pos.x, v.pos.z)
	for l: Label3D in game.labels:
		var d := Vector2(l.position.x - v.pos.x, l.position.z - v.pos.z).length()
		l.visible = d > 25.0 and d < 900.0


func _process(_delta: float) -> bool:
	if done:
		return false
	if index < 0:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Dev.WINDOW_SIZE)
		_next_world()
		return false
	var game: GameWorld = main.game
	if game == null or game.player == null:
		if Time.get_ticks_msec() - started > Dev.LOAD_TIMEOUT_MS:
			printerr("Мир не загрузился за %d с" % (Dev.LOAD_TIMEOUT_MS / 1000))
			failed = true
			return _finish()
		return false
	var w: Array = worlds[index]
	var id := Dev.world_id(w[0], int(w[1]))
	if view < 0:
		# игра стоит: камера и растительность только наши, интерфейс скрыт
		game.paused = true
		main.hud.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Dev.save_json(out.path_join("stats_%s.json" % id), Dev.world_stats(game.world))
		_save(main.hud.map_tex.get_image(), "%s_map" % id, false)
		views = Dev.views(game)
		view = 0
		wait = 0
		_place(game, views[0])
		return false
	wait += 1
	if wait < SETTLE_FRAMES:
		return false
	var v: Dictionary = views[view]
	_save(root.get_texture().get_image(), "%s_%s" % [id, v.name], true)
	view += 1
	wait = 0
	if view < views.size():
		_place(game, views[view])
	else:
		_next_world()
	return false
