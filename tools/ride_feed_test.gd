extends SceneTree
## Изолированная проверка ленты, без окна и генерации мира.

const Feed = preload("res://scripts/game/ride_feed.gd")
const Config = preload("res://resources/ride_journal.tres")
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	var folder := "user://ride_feed_test/" + str(Time.get_ticks_usec())
	var config = Config.duplicate()
	var feed = Feed.new(folder, config)
	check(feed.load_feed() == OK and feed.entries.is_empty(), "пустая лента")
	check(not Feed.accepts({time = 59.0, bike = 100.0, foot = 99.0}), "короткая сессия исключена")
	check(Feed.accepts({time = 60.0}) and Feed.accepts({bike = 200.0}), "пороги времени и пути")
	check(not Feed.accepts({time = 100.0}, true), "режим разработки исключён")
	var first := {id = "world:one:1", version = 1, start = 1, bike = 200}
	check(feed.upsert(first) == OK, "первая запись")
	first.bike = 250
	check(feed.upsert(first) == OK and feed.entries.size() == 1, "повтор обновляет запись")
	var reload = Feed.new(folder)
	check(reload.load_feed() == OK and reload.entries.size() == 1 and reload.entries[0].bike == 250, "загрузка обновлённой записи")
	var old_limit: int = config.entries_limit
	config.entries_limit = 2
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	check(image.save_png(feed.thumb_path(first.id)) == OK, "создано превью старой записи")
	check(feed.upsert({id = "second", version = 1, start = 2}) == OK, "вторая запись")
	check(feed.upsert({id = "third", version = 1, start = 3}) == OK, "третья запись")
	check(feed.entries.size() == 2 and feed.entries[0].id == "third" and not FileAccess.file_exists(feed.thumb_path(first.id)), "предел и удаление старого превью")
	config.entries_limit = old_limit
	check(feed.erase("second") == OK and feed.entries.size() == 1, "удаление записи")
	var file := FileAccess.open(folder.path_join("feed.json"), FileAccess.WRITE)
	file.store_string("{broken")
	file.close()
	check(reload.load_feed() == OK and reload.entries.is_empty() and FileAccess.file_exists(folder.path_join("feed.json.bad")), "повреждённый файл сохранён")
	check(reload.upsert(first) == OK, "запись после восстановления")
	print("ИТОГО: %s" % ("всё прошло" if failures == 0 else "%d провалов" % failures))
	quit(1 if failures else 0)


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1
