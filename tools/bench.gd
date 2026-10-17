extends SceneTree
## Замер скорости загрузки мира по этапам (WorldLoader.load_world, как при старте игры).
## Заливка текстуры, рельеф и вода считаются параллельно с этапами после климата, поэтому их времени
## в списке нет: оно прячется за тропами и растительностью. Запуск из папки проекта:
##   godot --headless --path . --script res://tools/bench.gd -- <зерно> <размер>

var _t := 0
var _label := ""


func _mark(label: String) -> void:
	var now := Time.get_ticks_msec()
	if _label != "":
		print("  %-28s %6d мс" % [_label, now - _t])
	_t = now
	_label = label


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var seed_text: String = args[0] if args.size() > 0 else "Север-1234"
	var size: int = int(args[1]) if args.size() > 1 else 512
	print("%s@%d" % [seed_text, size])
	var t0 := Time.get_ticks_msec()
	var loaded := WorldLoader.load_world(seed_text, size, func(_p: float, label: String) -> void: _mark(label))
	_mark("")
	print("Всего %d мс" % (Time.get_ticks_msec() - t0))
	# узлы воды не в дереве сцены: освободить вручную, иначе Godot жалуется на утечки при выходе
	for node in loaded.water:
		node.free()
	quit()
