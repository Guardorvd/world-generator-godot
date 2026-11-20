extends SceneTree
## 18.11.2026: быстрая проверка данных путешествия без мира и окна: трек поездок (MapJournal), счётчики, открытие мест сверху,
## классификация снимков для альбома и сохранение (Exploration). Секунды, лимит 30 с.
##   godot --headless --path . --script res://tools/explore_check.gd

const Journal := preload("res://scripts/game/map_journal.gd")
const RideLog := preload("res://scripts/game/ride_log.gd")
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	_track()
	_stats_and_reveal()
	_album()
	_save()
	_rides()
	print("ИТОГО: %s" % ("всё прошло" if failures == 0 else "%d провалов" % failures))
	quit(1 if failures else 0)


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


## Один шаг движения за dt секунд со скоростью speed (м/с) вдоль направления dir
func _walk(j: Journal, at: Vector2, dir: Vector2, speed: float, seconds: float) -> Vector2:
	var dt := 1.0 / 60.0
	for k in int(seconds / dt):
		at += dir * speed * dt
		j.record(at, dt)
	return at


func _track() -> void:
	# прямая: сотни метров — несколько опорных точек, длина верная
	var j := Journal.new()
	var at := _walk(j, Vector2(5000, -3000), Vector2(1, 0), 1.4, 360.0)
	j.end_trip()
	var points := 0
	for leg: Dictionary in j.legs:
		points += leg.points.size()
	check(j.legs.size() == 1 and points < 40 and absf(j.distance - 504.0) < 3.0, "прямая 504 м пешком: %d опорных точек, путь %.0f м" % [points, j.distance])
	# зигзаг: поворот сохраняется
	j = Journal.new()
	at = Vector2(0, 0)
	for k in 6:
		at = _walk(j, at, Vector2(1, 0).rotated(0.9 if k % 2 == 0 else -0.9), 5.0, 8.0)
	j.end_trip()
	check(j.legs.size() == 1 and j.legs[0].points.size() >= 7, "зигзаг не выпрямляется: %d точек" % j.legs[0].points.size())
	# перенос больше 30 м за такт рвёт трек: перемычки нет
	j = Journal.new()
	at = _walk(j, Vector2(0, 0), Vector2(1, 0), 6.0, 10.0)
	j.record(at + Vector2(4000, 4000), 1.0 / 60.0)
	_walk(j, at + Vector2(4000, 4000), Vector2(0, 1), 6.0, 10.0)
	j.end_trip()
	var bridged := false
	for leg: Dictionary in j.legs:
		for k in range(1, leg.points.size()):
			bridged = bridged or leg.points[k].distance_to(leg.points[k - 1]) > 200.0
	check(j.legs.size() == 2 and not bridged, "перенос: два отрезка, перемычки нет (%d)" % j.legs.size())
	# сохранение и загрузка
	var state := j.save_state()
	check(Journal.valid(state), "состояние трека проходит проверку")
	var copy := Journal.new()
	copy.restore(state)
	check(copy.legs.size() == j.legs.size() and copy.distance == j.distance and copy.current.is_empty(), "загрузка возвращает те же отрезки")
	# после загрузки новое движение начинает новый отрезок, а не тянется от старой точки
	_walk(copy, Vector2(-9000, 9000), Vector2(1, 0), 4.0, 5.0)
	copy.end_trip()
	check(copy.legs.size() == j.legs.size() + 1, "после загрузки — новый отрезок")
	# пеший и велосипедный путь считаются раздельно, перенос не считается, старое сохранение читается
	j = Journal.new()
	at = _walk(j, Vector2(0, 0), Vector2(1, 0), 1.0, 60.0)
	j.record(at + Vector2(900, 0), 1.0 / 60.0)
	at += Vector2(900, 0)
	var dt := 1.0 / 60.0
	for k in 600:
		at += Vector2(0.2, 0)
		j.record(at, dt, true)
	check(absf(j.foot - 60.0) < 0.5 and absf(j.bike - 120.0) < 0.5 and absf(j.distance - 180.0) < 1.0, "пешком %.1f м, на велосипеде %.1f м, перенос не считается" % [j.foot, j.bike])
	var split := Journal.new()
	split.restore(j.save_state())
	check(split.foot == j.foot and split.bike == j.bike, "раздельный путь сохраняется")
	var old_state := j.save_state()
	old_state.erase("foot")
	old_state.erase("bike")
	old_state.distance = 321.0
	var old := Journal.new()
	check(Journal.valid(old_state), "сохранение со старым полем distance проходит проверку")
	old.restore(old_state)
	check(old.bike == 321.0 and old.foot == 0.0, "старый путь (трек был только на велосипеде) попадает в велосипедный")
	# предел: старые отрезки отбрасываются, число точек ограничено
	var big := Journal.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var p := Vector2.ZERO
	for k in 40000:
		p += Vector2.from_angle(rng.randf() * TAU) * 6.0
		big.record(p, Journal.SAMPLE_TIME)
	big.end_trip()
	var total := 0
	for leg: Dictionary in big.legs:
		total += leg.points.size()
	check(big.legs.size() <= Journal.MAX_LEGS and total <= Journal.MAX_LEGS * Journal.POINTS_PER_LEG, "предел: %d отрезков, %d точек" % [big.legs.size(), total])
	check(Journal.valid(big.save_state()), "и предельный трек сохраняется")


func _stats_and_reveal() -> void:
	var e := Exploration.new()
	for k in 600:
		e.tick(1.0 / 60.0, 50.0 + k * 0.01)
	check(absf(e.play_s - 10.0) < 0.1 and absf(e.max_alt - 55.99) < 0.1, "время %.1f с, высшая точка %.1f м" % [e.play_s, e.max_alt])
	var places: Array = [
		{key = "site:1:1", kind = "site", x = 25.0, y = 0.0},   # 100 м: видно
		{key = "site:2:2", kind = "site", x = 600.0, y = 0.0},  # далеко
		{key = "lake:3:3", kind = "lake", x = 50.0, y = 0.0},   # 200 м: закрыто склоном
		{key = "peak:4:4", kind = "peak", x = 0.0, y = 25.0},   # 100 м: уже посещена
		{key = "settlement:5:5", kind = "settlement", x = 10.0, y = 0.0},  # не малое место
		{key = "site:6:6", kind = "site", x = 0.0, y = -50.0},  # 200 м: видно
	]
	var known := func(id: String) -> bool: return id == "peak:4:4"
	var ground := func(_x: float, _z: float) -> float: return 0.0
	var occluded := func(_from: Vector3, to: Vector3) -> bool: return absf(to.x - 200.0) < 1.0
	var found := e.reveal_from(places, Vector3(0, 12, 0), Exploration.TOWER_RADIUS, 4.0, known, ground, occluded)
	found.sort()
	check(found == PackedStringArray(["site:1:1", "site:6:6"]) and e.revealed.size() == 2, "с вышки открыты только видимые малые места в радиусе: %s" % [found])
	check(e.reveal_from(places, Vector3(0, 12, 0), Exploration.TOWER_RADIUS, 4.0, known, ground, occluded).is_empty(), "повторно те же места не открываются")


func _album() -> void:
	var camp := {kind = "site", src = {type = "tower"}}
	var keys := Exploration.classify(camp, Biomes.GRASS, {dark = 0.1, up = 0.5, aurora = 1.0})
	check(keys == PackedStringArray(["biome:%d" % Biomes.GRASS, "site:tower"]), "днём: страница биома и страница вышки, без сияния (%s)" % [keys])
	keys = Exploration.classify({}, Biomes.TAIGA, {dark = 0.9, up = 0.4, aurora = 0.8, comet = 0.1, meteor = 0.35})
	check(keys.has("night:aurora") and keys.has("night:meteor") and not keys.has("night:comet"), "ночью над горизонтом: сияние и звездопад, комета слабая (%s)" % [keys])
	keys = Exploration.classify({}, Biomes.TAIGA, {dark = 0.9, up = -0.1, aurora = 0.8})
	check(not keys.has("night:aurora"), "ниже горизонта сияния нет")
	keys = Exploration.classify({kind = "lake"}, Biomes.OCEAN, {})
	check(keys == PackedStringArray(["lake"]), "вода и озеро: только страница озера (%s)" % [keys])
	var e := Exploration.new()
	var first := e.add_photo({path = "user://a.jpg", place = ""}, PackedStringArray(["peak", "biome:8"]), "2026-11-18 10:00:00")
	var second := e.add_photo({path = "user://b.jpg", place = ""}, PackedStringArray(["peak", "lake"]), "2026-11-18 11:00:00")
	check(first.size() == 2 and second.size() == 1 and e.album.peak.path == "user://a.jpg" and e.photos == 2, "страница хранит первый снимок")
	check(e.personal_photos.size() == 2 and e.choose_album_photo("peak", "user://b.jpg") and e.album.peak.path == "user://b.jpg",
		"личные снимки сохраняются и подходящий кадр становится обложкой")
	check(not e.choose_album_photo("biome:8", "user://b.jpg") and e.album["biome:8"].path == "user://a.jpg",
		"неподходящий кадр не заменяет обложку")
	var pages := Exploration.pages()
	var keys_seen := {}
	for page: Dictionary in pages:
		keys_seen[page.key] = true
	check(keys_seen.size() == pages.size() and keys_seen.has("site:tower") and keys_seen.has("night:comet") and pages.size() >= 24, "страниц %d, ключи не повторяются" % pages.size())


func _save() -> void:
	var e := Exploration.new()
	e.revealed["site:1:1"] = true
	e.scanned["site:9:9"] = true
	e.play_s = 77.0
	e.max_alt = 410.0
	e.add_photo({path = "user://photo.jpg", place = "peak:4:4"}, PackedStringArray(["peak"]), "2026-11-18 12:00:00")
	var state := e.save_state()
	check(Exploration.valid_save(state), "состояние проходит проверку")
	var copy := Exploration.new()
	copy.restore(state)
	check(copy.revealed == e.revealed and copy.scanned == e.scanned and copy.album == e.album and copy.play_s == e.play_s and copy.photos == 1 and copy.personal_photos == e.personal_photos, "сохранение и загрузка без потерь")
	var legacy := state.duplicate(true)
	legacy.erase("personal_photos")
	check(Exploration.valid_save(legacy), "сохранение без личной галереи остаётся совместимым")
	check(Exploration.valid_save(var_to_bytes_and_back(state)), "и через байты сохранения")
	var bad := state.duplicate(true)
	bad.time = -1.0
	check(not Exploration.valid_save(bad), "отрицательное время отвергается")
	bad = state.duplicate(true)
	bad.album["x"] = {path = 1, date = "", place = ""}
	check(not Exploration.valid_save(bad), "битая страница отвергается")
	bad = state.duplicate(true)
	bad.personal_photos[0]["keys"] = [1]
	check(not Exploration.valid_save(bad), "битые категории личного снимка отвергаются")
	check(not Exploration.valid_save({}) and not Exploration.valid_save("x"), "пустое и чужое отвергаются")


func var_to_bytes_and_back(state: Dictionary) -> Variant:
	return bytes_to_var(var_to_bytes(state))


## 20.11.2026: история заездов — заезд от входа до выхода, сохранение посреди заезда его не делит
func _rides() -> void:
	var j := Journal.new()
	var e := Exploration.new()
	var log := RideLog.new()
	_walk(j, Vector2(100, 100), Vector2(1, 0), 6.0, 20.0)  # прошлое до заезда — не его
	j.end_trip()
	e.play_s = 100.0
	log.begin(j, e, 2)
	var at := _walk(j, Vector2(400, 400), Vector2(0, 1), 8.0, 30.0)
	e.play_s = 130.0
	e.photos = 1
	log.tick(55.0)
	log.places["peak:4:4"] = true
	var now := log.snapshot(j, e, 3)
	check(absf(now.foot - 240.0) < 15.0 and now.quests == 1 and now.photos == 1 and is_equal_approx(now.time, 30.0) and now.alt == 55.0,
		"заезд считает только своё: путь, время, снимки, задания (%.0f м)" % now.foot)
	var frame := RideLog.bounds(now)
	check(not now.legs.is_empty() and frame.position.y >= 399.0 and frame.end.x < 401.0, "трек заезда — только после его начала")
	var saved := log.save_state(j, e, 3)
	check(RideLog.valid(saved) and RideLog.valid(var_to_bytes_and_back(saved)) and saved.entries.size() == 1, "сохранение проходит проверку")
	_walk(j, at, Vector2(1, 0), 8.0, 10.0)
	saved = log.save_state(j, e, 3)
	check(saved.entries.size() == 1 and saved.entries[0].foot > now.foot, "повторное сохранение обновляет тот же заезд")
	var next := RideLog.new()
	next.restore(saved)
	next.begin(j, e, 3)
	var list := next.history(j, e, 3)
	check(list.size() == 2 and list[0].current and not list[1].get("current", false) and list[1].foot > 0.0,
		"после загрузки прошлый заезд в истории, новый — первым")
	var idle := RideLog.new()
	idle.begin(j, e, 3)
	check(idle.save_state(j, e, 3).entries.is_empty(), "вход и сразу выход — без записи")
	var long := [PackedVector2Array()]
	for i in RideLog.MAX_POINTS * 3:
		long[0].append(Vector2(i, 0))
	var thin := RideLog._thin(long)
	check(thin[0].size() <= RideLog.MAX_POINTS + 1 and thin[0][-1] == Vector2(RideLog.MAX_POINTS * 3 - 1, 0), "длинный трек прореживается, конец сохранён")
	var bad := saved.duplicate(true)
	bad.entries[0].legs = [PackedVector2Array([Vector2(INF, 0), Vector2.ZERO])]
	check(not RideLog.valid(bad) and not RideLog.valid({}) and not RideLog.valid({entries = [1]}), "битые заезды отвергаются")
	check(RideLog.date_text(0.0).length() > 5 and RideLog.duration_text(3725.0) == "1:02:05", "подписи даты и длительности")
