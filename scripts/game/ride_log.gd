extends RefCounted
## 20.11.2026: история заездов для дневника. Заезд — одна игровая сессия: от входа в мир (новая игра или загрузка)
## до выхода. Сохранения посреди сессии заезд не делят: в файл пишутся прошлые заезды и снимок текущего, а после
## загрузки все они — прошлые, и начинается новый. Трек заезда — отрезки MapJournal, записанные после его начала;
## счётчики — разница общих счётчиков (MapJournal, Exploration, Quests.done) с их значением на старте.

const MAX_ENTRIES := 40        # хранится последних заездов
const MAX_POINTS := 6000       # точек трека на заезд в сохранении (дальше прореживается)
const MIN_TIME := 5.0          # с: заезд короче и без пути не записывается (вход и сразу выход)
const MIN_DISTANCE := 5.0      # м
const CONFIG = preload("res://resources/ride_journal.tres")

var entries: Array[Dictionary] = []  # прошлые заезды, старые первыми
var places := {}                     # id места -> true: где игрок побывал в этом заезде (PlayerState.check_discoveries)
var alt := 0.0                       # высшая точка заезда, м
var _start := {}                     # счётчики на начало заезда
var climb := 0.0
var descent := 0.0
var alt_min := INF
var alt_max := -INF
var speed_max := 0.0
var moving_time := 0.0
var bike_moving_time := 0.0
var jumps := 0
var air_max := 0.0
var falls := 0
var fall_marks: Array[Dictionary] = []
var _anchor_alt := NAN
var _speed_samples: Array[Vector2] = [] # (длительность, путь)
var _speed_duration := 0.0
var _speed_distance := 0.0
var _speed_riding := false
var _speed_mode_set := false
var _profile_samples: Array[Vector2] = [] # (путь, высота земли)
var _distance := 0.0
var _crashed := false
var _last_fall_time := -INF
var _last_fall_position := Vector2.INF


func session_start() -> float:
	return float(_start.get("at", 0.0))


## Начать заезд (после восстановления сохранения или в новой игре)
func begin(journal, explore: Exploration, quests_done: int) -> void:
	places = {}
	alt = -INF
	alt_min = INF
	alt_max = -INF
	climb = 0.0
	descent = 0.0
	speed_max = 0.0
	moving_time = 0.0
	bike_moving_time = 0.0
	jumps = 0
	air_max = 0.0
	falls = 0
	fall_marks.clear()
	_profile_samples.clear()
	_distance = 0.0
	_crashed = false
	_last_fall_time = -INF
	_last_fall_position = Vector2.INF
	break_track()
	_start = {at = Time.get_unix_time_from_system(), leg = journal.completed_legs, bike = journal.bike, foot = journal.foot,
		time = explore.play_s, photos = explore.photos, quests = quests_done}


func tick(feet: float) -> void:
	if feet > alt:
		alt = feet


## После MapJournal.record; высота земли нужна только когда тот записал точку.
func track_tick(journal, ground: float, dt: float, riding: bool) -> void:
	if journal.record_broken:
		break_track()
	if _speed_mode_set and riding != _speed_riding:
		_clear_speed()
	_speed_mode_set = true
	_speed_riding = riding
	var step: float = journal.record_step
	_distance += step
	if dt > 0.0:
		_speed_samples.append(Vector2(dt, step))
		_speed_duration += dt
		_speed_distance += step
		var window := maxf(CONFIG.speed_window, 0.001)
		while not _speed_samples.is_empty() and _speed_duration > window:
			var oldest: Vector2 = _speed_samples[0]
			var cut := minf(oldest.x, _speed_duration - window)
			var distance_cut := oldest.y * cut / oldest.x
			_speed_duration -= cut
			_speed_distance -= distance_cut
			if cut >= oldest.x - 0.000001:
				_speed_samples.pop_front()
			else:
				_speed_samples[0] = Vector2(oldest.x - cut, oldest.y - distance_cut)
		if _speed_duration >= window - 0.000001 and riding:
			speed_max = maxf(speed_max, _speed_distance / _speed_duration)
		if step / dt > CONFIG.moving_speed:
			moving_time += dt
			if riding:
				bike_moving_time += dt
	if journal.sample_recorded and is_finite(ground):
		alt_min = minf(alt_min, ground)
		alt_max = maxf(alt_max, ground)
		if not is_finite(_anchor_alt):
			_anchor_alt = ground
		var change := ground - _anchor_alt
		if absf(change) >= CONFIG.altitude_hysteresis:
			climb += maxf(change, 0.0)
			descent += maxf(-change, 0.0)
			_anchor_alt = ground
		_profile_samples.append(Vector2(_distance, ground))
		if _profile_samples.size() > maxi(2, CONFIG.profile_limit) * 2:
			_profile_samples = _resample_profile(_profile_samples, maxi(2, CONFIG.profile_limit))


func break_track() -> void:
	_anchor_alt = NAN
	_clear_speed()
	_speed_mode_set = false


func _clear_speed() -> void:
	_speed_samples.clear()
	_speed_duration = 0.0
	_speed_distance = 0.0


## Вызывается до очистки landing_info и сброса crashed контроллером.
func bike_events(landing: Dictionary, crashed: bool, at: Vector2, speed: float, now: float) -> void:
	var air := float(landing.get("air", 0.0))
	if air >= CONFIG.jump_air_time:
		jumps += 1
		air_max = maxf(air_max, air)
	if crashed and not _crashed:
		if now - _last_fall_time >= CONFIG.fall_merge_time or at.distance_to(_last_fall_position) >= CONFIG.fall_merge_distance:
			falls += 1
			if fall_marks.size() < CONFIG.fall_marks_limit:
				fall_marks.append({x = at.x, z = at.y, speed = absf(float(landing.get("speed", speed))), distance = _distance})
		_last_fall_time = now
		_last_fall_position = at
	_crashed = crashed


static func _resample_profile(samples: Array[Vector2], limit: int) -> Array[Vector2]:
	if samples.size() <= 1:
		return samples.duplicate()
	limit = mini(limit, samples.size())
	var out: Array[Vector2] = []
	var first := samples[0].x
	var span := samples[-1].x - first
	var j := 0
	for i in limit:
		var distance := first + span * float(i) / float(limit - 1)
		while j + 1 < samples.size() - 1 and samples[j + 1].x < distance:
			j += 1
		var a := samples[j]
		var b := samples[j + 1]
		var t := (distance - a.x) / (b.x - a.x) if b.x > a.x else 0.0
		out.append(Vector2(distance, lerpf(a.y, b.y, t)))
	return out


## Текущий заезд как запись: те же поля, что у прошлых. Пусто, если заезд не начат
func snapshot(journal, explore: Exploration, quests_done: int) -> Dictionary:
	if _start.is_empty():
		return {}
	var legs: Array = []
	var leg_modes: Array[bool] = []
	var first: int = journal.completed_legs - journal.legs.size()
	for i in journal.legs.size():
		if first + i >= int(_start.leg):
			legs.append(journal.legs[i].points)
			leg_modes.append(bool(journal.legs[i].get("riding", true)))
	if journal.current.size() > 1:
		legs.append(journal.current.duplicate())
		leg_modes.append(journal.current_riding)
	var profile := []
	for point: Vector2 in _resample_profile(_profile_samples, maxi(2, CONFIG.profile_limit)):
		profile.append(point.y)
	var marks := fall_marks.duplicate(true)
	for mark: Dictionary in marks:
		mark.progress = float(mark.distance) / _distance if _distance > 0.0 else 0.0
		mark.erase("distance")
	var bike_distance: float = maxf(0.0, journal.bike - float(_start.bike))
	return {start = float(_start.at), end = Time.get_unix_time_from_system(),
		time = maxf(0.0, explore.play_s - float(_start.time)),
		bike = bike_distance, foot = maxf(0.0, journal.foot - float(_start.foot)),
		climb = climb, descent = descent, alt_min = alt_min if is_finite(alt_min) else 0.0,
		alt_max = alt_max if is_finite(alt_max) else 0.0, speed_max = speed_max,
		speed_avg = bike_distance / bike_moving_time if bike_moving_time > 0.0 else 0.0,
		moving_time = moving_time, jumps = jumps, air_max = air_max, falls = falls,
		fall_marks = marks, profile = profile,
		alt = alt if is_finite(alt) else 0.0, photos = maxi(0, explore.photos - int(_start.photos)),
		quests = maxi(0, quests_done - int(_start.quests)), places = places.keys(), legs = legs, leg_modes = leg_modes}


## Стоит ли заезд записи: был путь или время
static func meaningful(entry: Dictionary) -> bool:
	return float(entry.get("time", 0.0)) >= MIN_TIME or float(entry.get("bike", 0.0)) + float(entry.get("foot", 0.0)) >= MIN_DISTANCE


## Все заезды, новые первыми; текущий — первым с пометкой current
func history(journal, explore: Exploration, quests_done: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var now := snapshot(journal, explore, quests_done)
	if not now.is_empty():
		now.current = true
		out.append(now)
	for i in range(entries.size() - 1, -1, -1):
		out.append(entries[i])
	return out


func save_state(journal, explore: Exploration, quests_done: int) -> Dictionary:
	var list: Array = []
	for entry: Dictionary in entries:
		list.append(entry)
	var now := snapshot(journal, explore, quests_done)
	if not now.is_empty() and meaningful(now):
		now.legs = _thin(now.legs)
		list.append(now)
	if list.size() > MAX_ENTRIES:
		list = list.slice(list.size() - MAX_ENTRIES)
	return {entries = list}


## Из сохранения: все записанные заезды — прошлые
func restore(state: Dictionary) -> void:
	entries.clear()
	for entry: Dictionary in state.get("entries", []):
		entries.append(entry)
	_start = {}


## Трек длиннее MAX_POINTS прореживается равномерно (каждая k-я точка, концы отрезков сохраняются)
static func _thin(legs: Array) -> Array:
	var total := 0
	for points: PackedVector2Array in legs:
		total += points.size()
	if total <= MAX_POINTS:
		return legs
	var step := ceili(float(total) / MAX_POINTS)
	var out: Array = []
	for points: PackedVector2Array in legs:
		var thin := PackedVector2Array()
		for i in range(0, points.size(), step):
			thin.append(points[i])
		if thin[-1] != points[-1]:
			thin.append(points[-1])
		if thin.size() > 1:
			out.append(thin)
	return out


static func valid(state: Variant) -> bool:
	if not state is Dictionary or not state.get("entries") is Array or state.entries.size() > MAX_ENTRIES:
		return false
	for entry: Variant in state.entries:
		if not entry is Dictionary:
			return false
		for key: String in ["start", "end", "time", "bike", "foot", "alt", "photos", "quests"]:
			var v: Variant = entry.get(key)
			if not (v is float or v is int) or not is_finite(float(v)):
				return false
		if not entry.get("places") is Array or not entry.get("legs") is Array:
			return false
		for id: Variant in entry.places:
			if not id is String:
				return false
		var points_total := 0
		for points: Variant in entry.legs:
			if not points is PackedVector2Array or points.size() < 2:
				return false
			points_total += points.size()
			for point: Vector2 in points:
				if not point.is_finite():
					return false
		if points_total > MAX_POINTS * 2:
			return false
	return true


## «20 нояб., 14:05» по местному времени
static func date_text(unix: float) -> String:
	const MONTHS := ["янв.", "февр.", "марта", "апр.", "мая", "июня", "июля", "авг.", "сент.", "окт.", "нояб.", "дек."]
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(int(unix) + bias)
	return "%d %s, %02d:%02d" % [d.day, MONTHS[clampi(int(d.month) - 1, 0, 11)], d.hour, d.minute]


static func duration_text(seconds: float) -> String:
	var s := int(seconds)
	return "%d:%02d:%02d" % [s / 3600, s / 60 % 60, s % 60] if s >= 3600 else "%d:%02d" % [s / 60, s % 60]


## Рамка трека заезда (метры); пустая — трека нет
static func bounds(entry: Dictionary) -> Rect2:
	var frame := Rect2()
	var started := false
	for points: PackedVector2Array in entry.get("legs", []):
		for point in points:
			if not started:
				frame = Rect2(point, Vector2.ZERO)
				started = true
			else:
				frame = frame.expand(point)
	return frame


## Рамка в метрах с полями, дополненная до пропорций целевой области.
static func framed_bounds(frame: Rect2, aspect: float) -> Rect2:
	var margin := maxf(CONFIG.frame_min_margin, maxf(frame.size.x, frame.size.y) * CONFIG.frame_margin)
	var result := frame.grow(margin)
	var ratio := maxf(aspect, 0.001)
	if result.size.x / maxf(result.size.y, 0.001) < ratio:
		var width := result.size.y * ratio
		result.position.x -= (width - result.size.x) * 0.5
		result.size.x = width
	else:
		var height := result.size.x / ratio
		result.position.y -= (height - result.size.y) * 0.5
		result.size.y = height
	return result
