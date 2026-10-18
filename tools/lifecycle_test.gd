extends SceneTree
## Проверка жизненного цикла мира: несколько миров подряд через главное меню (как игрок: «Начать», немного
## игры, «В меню»). После выхода в меню прошлый мир должен освободиться целиком, а память — не расти от мира
## к миру. Запуск из папки проекта (с окном или без):
##   godot --headless --path . --script res://tools/lifecycle_test.gd -- [--size 512] [--worlds 4]

const SEEDS := ["Север-1234", "Туман-4821", "Янтарь-5150", "Ущелье", "Кедр-2024", "Иней-7777"]
const PLAY_FRAMES := 90    # кадров игры в каждом мире: растительность и рельеф за краем успевают подгрузиться
const MENU_FRAMES := 10    # кадров в меню: освобождённые узлы уходят в конце кадра

var main: Node
var size := 512
var worlds := 4
var k := 0
var phase := "menu"
var frames := 0
var refs: Array[WeakRef] = []   # прошлые миры: после выхода в меню ссылки должны опустеть
var mem: Array = []             # [статическая память МБ, объектов] в меню после каждого мира
var fails := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args.size() - 1:
		if args[a] == "--size":
			size = int(args[a + 1])
		elif args[a] == "--worlds":
			worlds = int(args[a + 1])
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("✓ " + what)
	else:
		printerr("✗ " + what)
		fails += 1


func _process(_delta: float) -> bool:
	frames += 1
	match phase:
		"menu":
			if frames < MENU_FRAMES:
				return false
			if k > 0:
				var alive := 0
				for r in refs:
					if r.get_ref() != null:
						alive += 1
				_check(alive == 0, "после выхода в меню из мира %d прошлые миры освобождены (живых: %d)" % [k, alive])
				mem.append([Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
					int(Performance.get_monitor(Performance.OBJECT_COUNT))])
				print("  в меню после мира %d: память %.0f МБ, объектов %d" % [k, mem[-1][0], mem[-1][1]])
			if k == worlds:
				_finish()
				return true
			main.start_game(SEEDS[k % SEEDS.size()], size)
			phase = "loading"
		"loading":
			if main.game == null or main.game.player == null:
				return false
			refs.append(weakref(main.game.world))
			# мир держат ровно игра и интерфейс; освобождаться он должен сам, без ручной уборки полей
			phase = "play"
			frames = 0
		"play":
			# игрок идёт вперёд: растительность перезаполняется в фоне, рельеф за краем догружается
			main.game.player.x += 2.0
			if frames >= PLAY_FRAMES:
				main._back_to_menu()
				k += 1
				phase = "menu"
				frames = 0
	return false


func _finish() -> void:
	if mem.size() >= 3:
		# первый мир прогревает кэши (модели деревьев, шейдеры); дальше память в меню не должна расти
		var grow: float = mem[-1][0] - mem[1][0]
		_check(grow < 15.0, "память в меню не растёт от мира к миру (%+.0f МБ со второго по %d-й)" % [grow, mem.size()])
	print("Итог: %s" % ("ошибок нет" if fails == 0 else "ошибок: %d" % fails))
	quit(0 if fails == 0 else 1)
