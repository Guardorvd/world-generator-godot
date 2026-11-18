extends SceneTree
## 18.11.2026: быстрая проверка данных путешествия без мира и окна: трек поездок (MapJournal), счётчики, открытие мест сверху,
## классификация снимков для альбома и сохранение (Exploration). Секунды, лимит 30 с.
##   godot --headless --path . --script res://tools/explore_check.gd

const Journal := preload("res://scripts/game/map_journal.gd")
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	_track()
	_stats_and_reveal()
	_album()
	_save()
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
	var at := Vector2(100, 100)
	for k in 600:
		at += Vector2(0.1, 0)
		e.tick(1.0 / 60.0, at, false, 50.0 + k * 0.01)
	e.tick(1.0 / 60.0, at + Vector2(500, 0), false, 60.0) # перенос
	at += Vector2(500, 0)
	for k in 600:
		at += Vector2(0.2, 0)
		e.tick(1.0 / 60.0, at, true, 55.0)
	check(absf(e.foot_m - 60.0) < 0.5 and absf(e.bike_m - 120.0) < 0.5, "пешком %.1f м, на велосипеде %.1f м, перенос не считается" % [e.foot_m, e.bike_m])
	check(absf(e.play_s - 20.0) < 0.1 and absf(e.max_alt - 60.0) < 0.1, "время %.1f с, высшая точка %.1f м" % [e.play_s, e.max_alt])
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
	var pages := Exploration.pages()
	var keys_seen := {}
	for page: Dictionary in pages:
		keys_seen[page.key] = true
	check(keys_seen.size() == pages.size() and keys_seen.has("site:tower") and keys_seen.has("night:comet") and pages.size() >= 24, "страниц %d, ключи не повторяются" % pages.size())


func _save() -> void:
	var e := Exploration.new()
	e.revealed["site:1:1"] = true
	e.scanned["site:9:9"] = true
	e.foot_m = 1234.5
	e.bike_m = 99.0
	e.play_s = 77.0
	e.max_alt = 410.0
	e.add_photo({path = "user://photo.jpg", place = "peak:4:4"}, PackedStringArray(["peak"]), "2026-11-18 12:00:00")
	var state := e.save_state()
	check(Exploration.valid_save(state), "состояние проходит проверку")
	var copy := Exploration.new()
	copy.restore(state)
	check(copy.revealed == e.revealed and copy.scanned == e.scanned and copy.album == e.album and copy.foot_m == e.foot_m and copy.photos == 1, "сохранение и загрузка без потерь")
	check(Exploration.valid_save(var_to_bytes_and_back(state)), "и через байты сохранения")
	var bad := state.duplicate(true)
	bad.foot = -1.0
	check(not Exploration.valid_save(bad), "отрицательный путь отвергается")
	bad = state.duplicate(true)
	bad.album["x"] = {path = 1, date = "", place = ""}
	check(not Exploration.valid_save(bad), "битая страница отвергается")
	check(not Exploration.valid_save({}) and not Exploration.valid_save("x"), "пустое и чужое отвергаются")


func var_to_bytes_and_back(state: Dictionary) -> Variant:
	return bytes_to_var(var_to_bytes(state))
