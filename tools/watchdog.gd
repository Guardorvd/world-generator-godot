extends RefCounted
## Сторожевой таймер для всех тестов и проверок (tools/*.gd, tools/control/*.gd). Первая строка входа скрипта:
##   preload("res://tools/watchdog.gd").arm(self, <секунды>)
## Таймер в своём потоке, поэтому срабатывает и когда главный поток завис в генерации, ожидании или отрисовке:
## печатает причину и завершает процесс с кодом 1. Лимит — реальное время теста с запасом. Зависание —
## ошибка теста или кода: искать причину, не перезапускать и не поднимать лимит, чтобы «прошло».

static var _thread: Thread
static var _deadline := 0
static var _limit := 0.0
static var _what := ""
static var _done := false


## Повторный вызов (скрипт-наследник) только заменяет лимит.
static func arm(tree: SceneTree, seconds: float) -> void:
	_limit = seconds
	_deadline = Time.get_ticks_msec() + int(seconds * 1000.0)
	var script: Script = tree.get_script()
	_what = (script.resource_path.get_file() if script != null else "скрипт")
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_what += " -- " + " ".join(args)
	if _thread != null:
		return
	tree.root.tree_exiting.connect(_stop)
	_thread = Thread.new()
	_thread.start(_watch)


static func _watch() -> void:
	while not _done:
		if Time.get_ticks_msec() > _deadline:
			printerr("\nТАЙМАУТ: %s не завершился за %d с, процесс остановлен (код 1). Не перезапускать: это зависание, нужна причина." % [_what, int(_limit)])
			var pid := OS.get_process_id()
			if OS.get_name() == "Windows":
				OS.execute("taskkill", ["/F", "/PID", str(pid)])
			OS.kill(pid)
			return
		OS.delay_msec(200)


static func _stop() -> void:
	_done = true
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
