extends SceneTree
## Замер подготовки данных мира по этапам (WorldLoader.load_world).
## Создание GPU-ресурсов в GameWorld.start сюда не входит; полную загрузку измеряет control/perf.gd.
## Заливка текстуры, рельеф и вода считаются параллельно с этапами после климата, поэтому их времени
## в списке нет: оно прячется за тропами и растительностью. В конце — таблица по этапам с долей от общего времени.
## Запуск из папки проекта:
##   godot --headless --path . --script res://tools/bench.gd -- <зерно> <размер>
## По умолчанию Север-1234, 256 (малый мир из меню). Также --seed, --size, --gdscript, --out <файл.json>.

const Dev := preload("res://tools/control/control.gd")

var _t := 0
var _label := ""
## [подпись этапа, мс]
var _rows: Array = []


func _mark(label: String) -> void:
	# Счётчик внутри одного этапа обновляет экран, но не дробит таблицу на каждую дорогу.
	label = label.get_slice(": ", 0)
	if label == _label:
		return
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
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	Pathfinder.profile_searches = true
	var args := OS.get_cmdline_user_args()
	var positional := args.size() > 0 and not args[0].begins_with("--")
	var seed_text := Dev.arg("seed", args[0] if positional else "Север-1234")
	var size_text := Dev.arg("size", args[1] if positional and args.size() > 1 else "256")
	if not size_text.is_valid_int() or int(size_text) < 2:
		printerr("--size: требуется целое число не меньше 2")
		quit(1)
		return
	var size := int(size_text)
	print("%s@%d" % [seed_text, size])
	var t0 := Time.get_ticks_msec()
	_t = t0
	var loaded := WorldLoader.load_world(seed_text, size, func(_p: float, label: String) -> void: _mark(label))
	_mark("")
	var total := Time.get_ticks_msec() - t0
	_print_table(total)
	print("Всего %d мс" % total)
	print("CPU-подготовка (prepare_* перекрываются с generate): ", JSON.stringify(loaded.timings))
	print("Дорожный рельеф: ", JSON.stringify(loaded.heights.path_timings))
	print("Поиск маршрутов: ", JSON.stringify(loaded.world.generation_profile))
	print("Меш: %d вершин, %d треугольников; дорожных патчей: %d" % [
		loaded.terrain_arrays[Mesh.ARRAY_VERTEX].size(), loaded.terrain_arrays[Mesh.ARRAY_INDEX].size() / 3,
		loaded.heights.road_refinement.patches.size()])
	var path := Dev.arg("out")
	if path != "":
		Dev.save_json(Dev.abs_dir(path), {
			version = Dev.version(), seed = seed_text, size = size,
			backend = "fast" if Grid.fast_grid() != null else "gdscript",
			total_ms = total, stages = _rows, timings = loaded.timings,
			path_timings = loaded.heights.path_timings, searches = loaded.world.generation_profile,
		})
	quit()
