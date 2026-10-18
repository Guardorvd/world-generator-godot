extends RefCounted
## Общее для инструментов с окном (smoke_test.gd, structures_shots.gd, control/*): подключается через preload.

const LOAD_TIMEOUT_MS := 180000   # дольше этого мир не загрузится: считаем, что игра зависла


## Сохраняет снимок окна в <dir>/<name>.png. Ошибка записи (например, нет папки) пишется в консоль, возвращает false
static func save_png(viewport: Viewport, dir: String, name: String) -> bool:
	var path := dir.path_join(name + ".png")
	var err := viewport.get_texture().get_image().save_png(path)
	if err != OK:
		printerr("Не удалось сохранить снимок %s (ошибка %d): проверьте, что папка существует" % [path, err])
		return false
	print("Снимок: ", path)
	return true
