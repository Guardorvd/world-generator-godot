extends SceneTree
## Изолированная проверка ленты, без окна и генерации мира.

const Feed = preload("res://scripts/game/ride_feed.gd")
const Config = preload("res://resources/ride_journal.tres")
const RideLog = preload("res://scripts/game/ride_log.gd")
const Journal = preload("res://scripts/game/map_journal.gd")
const Explore = preload("res://scripts/game/exploration.gd")
const Thumb = preload("res://scripts/ui/ride_thumb.gd")
const Writer = preload("res://scripts/game/ride_feed_writer.gd")
const Presentation = preload("res://scripts/ui/ride_presentation.gd")
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	var folder := "user://ride_feed_test/" + str(Time.get_ticks_usec())
	var config = Config.duplicate()
	var feed = Feed.new(folder, config)
	check(feed.load_feed() == OK and feed.entries.is_empty(), "пустая лента")
	check(not Feed.accepts({time = 59.0, bike = 100.0, foot = 99.0}), "короткая сессия исключена")
	check(Feed.accepts({time = 60.0}) and Feed.accepts({bike = 200.0}), "пороги времени и пути")
	check(Feed.accepts({time = 0.0, session_time = 60.0}), "полное время сессии учитывает паузы")
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
	check(reload.load_feed() == ERR_FILE_CORRUPT and FileAccess.get_file_as_string(folder.path_join("feed.json")) == "{broken", "повреждённый журнал не подменяется пустым")
	check(reload.upsert(first) == ERR_UNAUTHORIZED and FileAccess.get_file_as_string(folder.path_join("feed.json")) == "{broken", "повреждённый файл защищён от записи")
	check(Feed.new(folder).load_feed() == ERR_FILE_CORRUPT, "ошибка сохраняется при повторном открытии")
	check(Feed.new(folder).upsert(first) == ERR_FILE_CORRUPT and FileAccess.get_file_as_string(folder.path_join("feed.json")) == "{broken", "новый объект не перезаписывает файл без предварительного чтения")
	file = FileAccess.open(folder.path_join("feed.json"), FileAccess.WRITE)
	var invalid_entry := '{"version":2,"entries":[{"id":"incomplete"}],"deleted":[]}'
	file.store_string(invalid_entry)
	file.close()
	check(reload.load_feed() == ERR_FILE_CORRUPT and reload.upsert(first) == ERR_UNAUTHORIZED and FileAccess.get_file_as_string(folder.path_join("feed.json")) == invalid_entry, "повреждённая запись не исчезает при последующем сохранении")
	file = FileAccess.open(folder.path_join("feed.json"), FileAccess.WRITE)
	var newer := '{"version":999,"entries":[],"deleted":[]}'
	file.store_string(newer)
	file.close()
	check(reload.load_feed() == ERR_FILE_UNRECOGNIZED and reload.upsert(first) == ERR_UNAUTHORIZED and FileAccess.get_file_as_string(folder.path_join("feed.json")) == newer, "новый формат не перезаписывается")
	for future in ['{"version":999,"new_layout":true}', '{"version":2,"entries":[{"id":"future","version":2,"start":1}],"deleted":[]}']:
		file = FileAccess.open(folder.path_join("feed.json"), FileAccess.WRITE)
		file.store_string(future)
		file.close()
		check(reload.load_feed() == ERR_FILE_UNRECOGNIZED and FileAccess.get_file_as_string(folder.path_join("feed.json")) == future, "будущий формат или запись сохранены и распознаны")
	for damaged in ['{"version":2.5,"entries":[],"deleted":[]}', '{"version":2,"entries":[{"id":"same","version":1,"start":1},{"id":"same","version":1,"start":2}],"deleted":[]}']:
		file = FileAccess.open(folder.path_join("feed.json"), FileAccess.WRITE)
		file.store_string(damaged)
		file.close()
		check(reload.load_feed() == ERR_FILE_CORRUPT and reload.upsert(first) == ERR_UNAUTHORIZED and FileAccess.get_file_as_string(folder.path_join("feed.json")) == damaged, "дробная версия и повтор id не приводят к потере исходного файла")
	_stats()
	_presentation()
	_thumbs(folder)
	_writer(folder.path_join("writer"))
	_busy_writer(folder.path_join("busy"))
	_migration(folder.path_join("migration"))
	_walk_setting(folder.path_join("settings.cfg"))
	var args := OS.get_cmdline_user_args()
	var before := args.find("--before")
	if before >= 0 and before + 1 < args.size():
		_compare_before(folder, args[before + 1])
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


func _presentation() -> void:
	var saved := {id = "partial", version = 1, start = 1.0e20, walk = "unknown", bike = "bad", falls = -1,
		profile = [1, "bad", 2], places = ["Поляна", 17], photo_paths = [null, "user://photo.png"],
		fall_marks = [{x = 1, z = 2, progress = "bad"}, {x = 3}, null],
		track = [[[0, 0], [1, 1], null, [2, 2], [3, 3]]]}
	var original := saved.duplicate(true)
	var shown: Dictionary = Presentation.make(saved)
	check(not shown.has("bike") and not shown.has("falls") and not shown.has("walk") and not shown.has("start"), "ошибочные показатели и дата не превращаются в нули")
	check(shown.profile.is_empty() and shown.places == ["Поляна"] and shown.photo_paths == ["user://photo.png"], "неполные поля безопасны для интерфейса")
	check(shown.track.size() == 2 and shown.fall_marks.size() == 1 and not shown.fall_marks[0].has("progress"), "повреждённая точка не соединяет участки и не создаёт метку профиля")
	check(saved == original, "снимок интерфейса не изменяет сохранённые данные")


func _thumbs(folder: String) -> void:
	var map := Image.create(256, 256, false, Image.FORMAT_RGB8)
	map.fill(Color(0.2, 0.4, 0.3))
	var entry := {legs = [PackedVector2Array([Vector2(100, 100), Vector2(500, 500)]), PackedVector2Array([Vector2(500, 500), Vector2(700, 800)])], leg_modes = [true, false], fall_marks = [{x = 500.0, z = 500.0}]}
	var start := Time.get_ticks_usec()
	var square: Image = Thumb.render(map, Vector2(1024, 1024), entry)
	var elapsed := Time.get_ticks_usec() - start
	var same: Image = Thumb.render(map, Vector2(1024, 1024), entry)
	check(square != null and square.get_size() == Vector2i(Config.thumb_width, Config.thumb_height) and square.get_data() == same.get_data(), "квадратная карта: размер и повторяемость превью")
	var colors := {outline = false, bike = false, foot = false, fall = false}
	for y in square.get_height():
		for x in square.get_width():
			var pixel := square.get_pixel(x, y)
			colors.outline = colors.outline or _near_color(pixel, Config.track_outline_color)
			colors.bike = colors.bike or _near_color(pixel, Config.bike_color)
			colors.foot = colors.foot or _near_color(pixel, Config.foot_color)
			colors.fall = colors.fall or _near_color(pixel, Config.fall_color)
	check(colors.outline and colors.bike and colors.foot and colors.fall, "обводка, пеший и велосипедный пути и падение видны на карте")
	var without_mark: Image = Thumb.render(map, Vector2(1024, 1024), {legs = entry.legs})
	var invalid_mark: Image = Thumb.render(map, Vector2(1024, 1024), {legs = entry.legs, fall_marks = [{}]})
	check(without_mark.get_data() == invalid_mark.get_data(), "падение без координат не рисуется в начале карты")
	var joints := PackedVector2Array([Vector2(100, 100), Vector2(220, 180), Vector2(370, 280), Vector2(500, 410)])
	var joint_entry := {legs = [joints]}
	var joint_image: Image = Thumb.render(map, Vector2(1024, 1024), joint_entry)
	var joint_frame: Rect2 = RideLog.framed_bounds(RideLog.bounds(joint_entry), float(Config.thumb_width) / Config.thumb_height)
	var solid := true
	for i in range(1, joints.size() - 1):
		var pixel: Vector2i = Thumb._pixel(joints[i], joint_frame, Vector2(Config.thumb_width, Config.thumb_height))
		solid = solid and _near_color(joint_image.get_pixelv(pixel), Config.bike_color)
	check(solid, "стыки отрезков не перекрывают светлую линию обводкой")
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


func _near_color(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01


func _writer(folder: String) -> void:
	var writer = Writer.new(folder)
	var map := Image.create(32, 32, false, Image.FORMAT_RGB8)
	map.fill(Color.DARK_GREEN)
	var snapshot := {start = 123.0, end = 200.0, time = 77.0, bike = 250.0, foot = 0.0,
		places = ["old-id"], legs = [PackedVector2Array([Vector2(10, 10), Vector2(100, 100)])]}
	check(writer.submit(snapshot, "test", "seed", ["Место"], [], map, Vector2(128, 128), true) == OK, "запись и ожидание фонового превью")
	var feed = Feed.new(folder)
	check(feed.load_feed() == OK and feed.entries.size() == 1 and feed.entries[0].places == ["Место"], "итог содержит названия мест")
	var id: String = feed.entries[0].id
	check(FileAccess.file_exists(feed.thumb_path(id)) and feed.entries[0].track.size() == 1, "превью и координаты доступны после выхода")
	snapshot.bike = 300.0
	check(writer.submit(snapshot, "test", "seed", [], [], map, Vector2(128, 128), false) == OK, "автосохранение обновляет заезд")
	check(writer.submit(snapshot, "test", "seed", [], [], map, Vector2(128, 128), true, true) == OK, "режим разработки пропущен")
	writer.finish()
	check(feed.load_feed() == OK and feed.entries.size() == 1 and float(feed.entries[0].bike) == 300.0, "нет дубля после автосохранения")
	var second = Writer.new(folder)
	snapshot.start = 124.0
	check(second.submit(snapshot, "test", "seed", [], [], map, Vector2(128, 128)) == OK, "фоновый снимок начат")
	var removed_id := Feed.ride_id("test", "seed", 124.0)
	check(feed.load_feed() == OK and feed.erase(removed_id) == OK, "удаление во время построения")
	second.finish()
	check(not FileAccess.file_exists(feed.thumb_path(removed_id)), "удалённое превью не возвращается из потока")


func _migration(folder: String) -> void:
	var writer = Writer.new(folder)
	var map := Image.create(32, 32, false, Image.FORMAT_RGB8)
	var old := {start = 42.0, end = 50.0, time = 8.0, bike = 10.0, foot = 0.0, alt = 42.0,
		photos = 0, quests = 0, places = ["old-id"], legs = [PackedVector2Array([Vector2(4, 4), Vector2(80, 80)])]}
	var records := [{snapshot = old, names = ["Старое место"], photos = []}]
	check(writer.migrate(records, "test", "seed", map, Vector2(128, 128)) == OK, "перенос старого короткого заезда")
	writer.finish()
	var feed = Feed.new(folder)
	check(feed.load_feed() == OK and feed.entries.size() == 1 and not feed.entries[0].has("climb") and feed.entries[0].alt_max == 42.0, "старые неизвестные показатели не выдумываются")
	var id: String = feed.entries[0].id
	check(FileAccess.file_exists(feed.thumb_path(id)), "превью старого заезда")
	check(writer.migrate(records, "test", "seed", map, Vector2(128, 128)) == OK, "повторный перенос безопасен")
	writer.finish()
	check(feed.load_feed() == OK and feed.entries.size() == 1 and feed.erase(id) == OK, "повтор не создаёт дубликат")
	check(writer.migrate(records, "test", "seed", map, Vector2(128, 128)) == OK, "повторный перенос после удаления")
	writer.finish()
	check(feed.load_feed() == OK and feed.entries.is_empty(), "удалённая запись не возвращается")


func _busy_writer(folder: String) -> void:
	var writer = Writer.new(folder)
	var gate := Semaphore.new()
	writer._result = {error = OK}
	writer._task = WorkerThreadPool.add_task(func() -> void: gate.wait())
	var map := Image.create(32, 32, false, Image.FORMAT_RGB8)
	var snapshot := {start = 222.0, time = 70.0, bike = 250.0, foot = 0.0,
		legs = [PackedVector2Array([Vector2(10, 10), Vector2(90, 90)])]}
	var id := Feed.ride_id("test", "seed", 222.0)
	var err: Error = writer.submit(snapshot, "test", "seed", [], [], map, Vector2(128, 128))
	check(err == OK and not FileAccess.file_exists(writer.feed.thumb_path(id)), "превью ждёт занятого рабочего потока")
	check(Feed.thumb_is_preparing(writer.feed.thumb_path(id)), "ожидающее превью помечено как подготавливаемое")
	snapshot.start = 223.0
	var next_id := Feed.ride_id("test", "seed", 223.0)
	check(writer.submit(snapshot, "test", "seed", [], [], map, Vector2(128, 128)) == OK and not Feed.thumb_is_preparing(writer.feed.thumb_path(id)) and Feed.thumb_is_preparing(writer.feed.thumb_path(next_id)), "замена ожидающего задания снимает старое состояние")
	gate.post()
	writer.finish()
	check(FileAccess.file_exists(writer.feed.thumb_path(next_id)) and not Feed.thumb_is_preparing(writer.feed.thumb_path(next_id)), "ожидающее превью строится и снимает состояние подготовки")


func _walk_setting(path: String) -> void:
	var settings := GameSettings.new()
	settings.settings_path = path
	check(not settings.show_walks, "пешие прогулки по умолчанию скрыты")
	settings.show_walks = true
	var err := settings.save_settings()
	var restored := GameSettings.new()
	restored.settings_path = path
	restored.load_settings()
	check(err == OK and restored.show_walks, "переключатель прогулок переживает перезапуск")
	restored.reset_defaults()
	check(not restored.show_walks, "сброс настроек скрывает прогулки")


func _compare_before(folder: String, source_folder: String) -> void:
	var feed_script := GDScript.new()
	feed_script.source_code = FileAccess.get_file_as_string(source_folder.path_join("ride_feed.gd"))
	var thumb_script := GDScript.new()
	thumb_script.source_code = FileAccess.get_file_as_string(source_folder.path_join("ride_thumb.gd"))
	if feed_script.reload() != OK or thumb_script.reload() != OK:
		check(false, "версия до ревизии загружена")
		return
	var old_feed = feed_script.new(folder.path_join("before"))
	var new_feed = Feed.new(folder.path_join("after"))
	var entries := [{id = "a", version = 1, start = 1, bike = 300.0}, {id = "b", version = 1, start = 2, bike = 450.0}]
	for entry: Dictionary in entries:
		old_feed.upsert(entry)
		new_feed.upsert(entry)
	check(FileAccess.get_file_as_bytes(folder.path_join("before/feed.json")) == FileAccess.get_file_as_bytes(folder.path_join("after/feed.json")), "до и после: записи побайтно")
	var map := Image.create(128, 128, false, Image.FORMAT_RGB8)
	map.fill(Color.DARK_GREEN)
	var ride := {legs = [PackedVector2Array([Vector2(10, 20), Vector2(90, 100)])], fall_marks = [{x = 50, z = 60}]}
	var before_image: Image = thumb_script.render(map, Vector2(128, 128), ride)
	var after_image: Image = Thumb.render(map, Vector2(128, 128), ride)
	check(before_image.save_png_to_buffer() == after_image.save_png_to_buffer(), "до и после: PNG побайтно")


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1
