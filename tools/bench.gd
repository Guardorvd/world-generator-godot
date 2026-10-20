extends SceneTree
## Замер подготовки данных мира по этапам (WorldLoader.load_world).
## Создание GPU-ресурсов в GameWorld.start сюда не входит; полную загрузку измеряет control/perf.gd.
## Заливка текстуры, рельеф и вода считаются параллельно с этапами после климата, поэтому их времени
## в списке нет: оно прячется за тропами и растительностью. В конце — таблица по этапам с долей от общего времени.
## Запуск из папки проекта:
##   godot --headless --path . --script res://tools/bench.gd -- <зерно> <размер>

var _t := 0
var _label := ""
## [подпись этапа, мс]
var _rows: Array = []


func _mark(label: String) -> void:
	var now := Time.get_ticks_msec()
	if _label != "":
		_rows.append([_label, now - _t])
	_t = now
	_label = label


func _print_table(total: int) -> void:
	print("  %-34s %8s %7s" % ["Этап", "мс", "доля"])
	var sum := 0
	for row in _rows:
		var ms: int = row[1]
		sum += ms
		var share := 100.0 * ms / maxi(1, total)
		print("  %-34s %8d %6.1f%%" % [row[0], ms, share])
	print("  %-34s %8d" % ["Сумма этапов", sum])


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var seed_text: String = args[0] if args.size() > 0 else "Север-1234"
	var size: int = int(args[1]) if args.size() > 1 else 512
	print("%s@%d" % [seed_text, size])
	var t0 := Time.get_ticks_msec()
	_t = t0
	var loaded := WorldLoader.load_world(seed_text, size, func(_p: float, label: String) -> void: _mark(label))
	_mark("")
	var total := Time.get_ticks_msec() - t0
	_print_table(total)
	print("Всего %d мс" % total)
	print("CPU-подготовка (prepare_* перекрываются с generate): ", JSON.stringify(loaded.timings))
	print("Меш: %d вершин, %d треугольников; дорожных патчей: %d" % [
		loaded.terrain_arrays[Mesh.ARRAY_VERTEX].size(), loaded.terrain_arrays[Mesh.ARRAY_INDEX].size() / 3,
		loaded.heights.road_refinement.patches.size()])
	quit()
