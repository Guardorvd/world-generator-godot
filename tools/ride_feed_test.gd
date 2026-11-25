extends SceneTree
## Изолированная проверка ленты, без окна и генерации мира.

const Feed = preload("res://scripts/game/ride_feed.gd")
const Config = preload("res://resources/ride_journal.tres")
const RideLog = preload("res://scripts/game/ride_log.gd")
const Journal = preload("res://scripts/game/map_journal.gd")
const Explore = preload("res://scripts/game/exploration.gd")
const Thumb = preload("res://scripts/ui/ride_thumb.gd")
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
	_stats()
	_thumbs(folder)
	print("ИТОГО: %s" % ("всё прошло" if failures == 0 else "%d провалов" % failures))
	quit(1 if failures else 0)


func _stats() -> void:
	var journal = Journal.new()
	var explore = Explore.new()
	var ride = RideLog.new()
	ride.begin(journal, explore, 0)
	# Движение 5 м/с и рельеф с дрожью менее порога гистерезиса.
	for i in 200:
		journal.record(Vector2(i * 0.5, 0), 0.1, true)
		ride.track_tick(journal, 100.0 + (0.5 if i % 2 == 0 else -0.5), 0.1, true)
	var before: float = ride.speed_max
	journal.record(Vector2(10000, 0), 0.1, true)
	ride.track_tick(journal, 200.0, 0.1, true)
	for i in 20:
		journal.record(Vector2(10000 + i * 0.5, 0), 0.1, true)
		ride.track_tick(journal, 200.0, 0.1, true)
	check(ride.climb == 0.0 and ride.descent == 0.0, "дрожь высоты и перенос не дают набора")
	check(absf(before - 5.0) < 0.01 and ride.speed_max < 5.1, "скорость за секунду не растёт от переноса")
	ride.bike_events({air = 0.39}, false, Vector2.ZERO, 5.0, 0.0)
	ride.bike_events({air = 0.4, speed = 7.0}, true, Vector2.ZERO, 5.0, 1.0)
	ride.bike_events({}, true, Vector2.ZERO, 5.0, 1.1)
	ride.bike_events({}, false, Vector2.ZERO, 5.0, 1.2)
	ride.bike_events({}, true, Vector2(1, 0), 5.0, 2.0)
	ride.bike_events({}, false, Vector2.ZERO, 5.0, 2.1)
	ride.bike_events({}, true, Vector2(20, 0), 5.0, 3.0)
	check(ride.jumps == 1 and ride.air_max == 0.4, "учитывается прыжок от 0,4 секунды")
	check(ride.falls == 2 and ride.fall_marks.size() == 2 and ride.fall_marks[0].speed == 7.0, "фронты и склейка падений")
	var snapshot: Dictionary = ride.snapshot(journal, explore, 0)
	check(snapshot.profile.size() <= Config.profile_limit and snapshot.fall_marks[0].progress <= 1.0, "ограниченный профиль и положение падения")
	var hill = RideLog.new()
	var hill_journal = Journal.new()
	hill.begin(hill_journal, explore, 0)
	for i in 25:
		hill_journal.record(Vector2(i * 4, 0), 1.0, true)
		var elevation := float(i) if i <= 12 else float(24 - i)
		hill.track_tick(hill_journal, elevation, 1.0, true)
	check(hill.climb == 12.0 and hill.descent == 12.0 and hill.alt_min == 0.0 and hill.alt_max == 12.0, "набор, сброс и пределы высоты")


func _thumbs(folder: String) -> void:
	var map := Image.create(256, 256, false, Image.FORMAT_RGB8)
	map.fill(Color(0.2, 0.4, 0.3))
	var entry := {legs = [PackedVector2Array([Vector2(100, 100), Vector2(500, 500)]), PackedVector2Array([Vector2(500, 500), Vector2(700, 800)])], leg_modes = [true, false], fall_marks = [{x = 500.0, z = 500.0}]}
	var start := Time.get_ticks_usec()
	var square: Image = Thumb.render(map, Vector2(1024, 1024), entry)
	var elapsed := Time.get_ticks_usec() - start
	var same: Image = Thumb.render(map, Vector2(1024, 1024), entry)
	check(square != null and square.get_size() == Vector2i(Config.thumb_width, Config.thumb_height) and square.get_data() == same.get_data(), "квадратная карта: размер и повторяемость превью")
	check(square.save_png(folder.path_join("square.png")) == OK, "PNG квадратной карты")
	var elongated: Image = Thumb.render(map, Vector2(1024, 4096), entry)
	check(elongated != null and elongated.save_png(folder.path_join("elongated.png")) == OK, "PNG вытянутой карты")
	print("Превью: %.2f мс" % (float(elapsed) / 1000.0))
	var long_track := PackedVector2Array()
	for i in 6000:
		long_track.append(Vector2(20.0 + float(i) * 0.15, 500.0 + 100.0 * sin(float(i) * 0.02)))
	start = Time.get_ticks_usec()
	var long_image: Image = Thumb.render(map, Vector2(1024, 1024), {legs = [long_track]})
	print("Превью 6000 точек: %.2f мс" % (float(Time.get_ticks_usec() - start) / 1000.0))
	check(long_image != null, "превью длинного трека")


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1
