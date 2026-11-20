extends RefCounted
## 20.11.2026: история заездов для дневника. Заезд — одна игровая сессия: от входа в мир (новая игра или загрузка)
## до выхода. Сохранения посреди сессии заезд не делят: в файл пишутся прошлые заезды и снимок текущего, а после
## загрузки все они — прошлые, и начинается новый. Трек заезда — отрезки MapJournal, записанные после его начала;
## счётчики — разница общих счётчиков (MapJournal, Exploration, Quests.done) с их значением на старте.

const MAX_ENTRIES := 40        # хранится последних заездов
const MAX_POINTS := 6000       # точек трека на заезд в сохранении (дальше прореживается)
const MIN_TIME := 5.0          # с: заезд короче и без пути не записывается (вход и сразу выход)
const MIN_DISTANCE := 5.0      # м

var entries: Array[Dictionary] = []  # прошлые заезды, старые первыми
var places := {}                     # id места -> true: где игрок побывал в этом заезде (PlayerState.check_discoveries)
var alt := 0.0                       # высшая точка заезда, м
var _start := {}                     # счётчики на начало заезда


func session_start() -> float:
	return float(_start.get("at", 0.0))


## Начать заезд (после восстановления сохранения или в новой игре)
func begin(journal, explore: Exploration, quests_done: int) -> void:
	places = {}
	alt = -INF
	_start = {at = Time.get_unix_time_from_system(), leg = journal.completed_legs, bike = journal.bike, foot = journal.foot,
		time = explore.play_s, photos = explore.photos, quests = quests_done}


func tick(feet: float) -> void:
	if feet > alt:
		alt = feet


## Текущий заезд как запись: те же поля, что у прошлых. Пусто, если заезд не начат
func snapshot(journal, explore: Exploration, quests_done: int) -> Dictionary:
	if _start.is_empty():
		return {}
	var legs: Array = []
	var first: int = journal.completed_legs - journal.legs.size()
	for i in journal.legs.size():
		if first + i >= int(_start.leg):
			legs.append(journal.legs[i].points)
	if journal.current.size() > 1:
		legs.append(journal.current.duplicate())
	return {start = float(_start.at), end = Time.get_unix_time_from_system(),
		time = maxf(0.0, explore.play_s - float(_start.time)),
		bike = maxf(0.0, journal.bike - float(_start.bike)), foot = maxf(0.0, journal.foot - float(_start.foot)),
		alt = alt if is_finite(alt) else 0.0, photos = maxi(0, explore.photos - int(_start.photos)),
		quests = maxi(0, quests_done - int(_start.quests)), places = places.keys(), legs = legs}


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
