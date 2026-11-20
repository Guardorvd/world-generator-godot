class_name Exploration
extends RefCounted
## Путешествие: открытые издалека места, счётчики пути и страницы альбома. Данные без узлов сцены.
## Хозяин — Hud (рядом с visited и журналом поездок MapJournal; на новом мире заменяется новым). Сохранение — необязательное
## поле "explore" (формат сохранения прежний, старые файлы читаются). Трек поездок хранит MapJournal (поле "atlas").
##
## Открытые места: малые места (сооружения, озёра, вершины) видны на картах и подписаны в мире, когда игрок их посетил,
## взял по ним задание или увидел сверху: с верхней площадки вышки и с вершины открываются все такие места в радиусе
## TOWER_RADIUS / PEAK_RADIUS, которые видны из точки (линия прямой видимости — GameWorld._occluded). Одна вышка и одна
## вершина открывают места один раз (scanned).
##
## Альбом: страницы заполняются сами при каждом снимке (PhotoCamera.photo_taken). Страница хранит первый снимок и дату.

const TOWER_RADIUS := 700.0   # м
const PEAK_RADIUS := 1500.0   # м
const NIGHT_MIN := 0.55       # 1 - sunlight не меньше: достаточно темно для ночных явлений
const EVENT_MIN := 0.3        # сила явления (DayCycle.events), с которой его видно
const UP_MIN := 0.12          # взгляд камеры выше горизонта не меньше чем на столько (y единичного вектора)
const MAX_ALBUM := 128
const MAX_PLACE_PHOTOS := 256
const MAX_PERSONAL_PHOTOS := 256
## 18.11.2026: место в рамке закрывает страницу альбома, только если снято вблизи — м от камеры до края места
## (PhotoCamera shot.dist). Приближение фотоаппарата расстояние не меняет: с соседнего холма через ×4 не засчитывается
const ALBUM_REACH := {settlement = 150.0, site = 60.0, peak = 300.0, lake = 150.0}

static var _pages: Array[Dictionary] = []
const GROUPS := ["Биомы", "Места", "Вершины и озёра", "Ночные явления", "Летопись обелисков"]

var revealed := {}   # id места -> true: открыто сверху
var scanned := {}    # id вышки или вершины -> true: с неё уже смотрели
var play_s := 0.0
var max_alt := 0.0   # высшая точка, м (как высота в сводке)
var photos := 0
var album := {}      # ключ страницы -> {path, date, place}
var place_photos := {} # id места -> последний сохранённый снимок вблизи
var personal_photos: Array[Dictionary] = [] # недавние снимки, старые первыми


## Название вида места с большой буквы («Дозорная вышка»)
static func site_title(type: String) -> String:
	var title: String = StageSites.TYPES[type].title
	return title.left(1).to_upper() + title.substr(1)


## Все страницы альбома по группам: [{key, group, title, hint}]; список собирается один раз
static func pages() -> Array[Dictionary]:
	if not _pages.is_empty():
		return _pages
	var out: Array[Dictionary] = []
	for i in Biomes.LIST.size():
		var biome: Dictionary = Biomes.LIST[i]
		if biome.get("water", false):
			continue
		out.append({key = "biome:%d" % i, group = 0, title = biome.name, hint = "Снимите местность: «%s»" % biome.name})
	out.append({key = "settlement", group = 1, title = "Поселение", hint = "Снимите вблизи (< %d м)" % int(ALBUM_REACH.settlement)})
	for type: String in StageSites.TYPES:
		out.append({key = "site:" + type, group = 1, title = site_title(type), hint = "Снимите вблизи (< %d м): %s" % [int(ALBUM_REACH.site), StageSites.TYPES[type].title]})
	out.append({key = "peak", group = 2, title = "Вершина", hint = "Снимите вершину (< %d м)" % int(ALBUM_REACH.peak)})
	out.append({key = "lake", group = 2, title = "Озеро", hint = "Снимите у берега (< %d м)" % int(ALBUM_REACH.lake)})
	out.append({key = "night:aurora", group = 3, title = "Полярное сияние", hint = "Ночью, камера выше горизонта"})
	out.append({key = "night:comet", group = 3, title = "Комета", hint = "Ночью, камера выше горизонта"})
	out.append({key = "night:meteor", group = 3, title = "Звездопад", hint = "Ночью, камера выше горизонта"})
	_pages = out
	return out


static func page_title(key: String) -> String:
	for page: Dictionary in pages():
		if page.key == key:
			return page.title
	return key


## Время в игре и высшая точка (alt — высота ног). Пройденный путь по видам хранит MapJournal: он уже снимает положение игрока
func tick(dt: float, alt: float) -> void:
	play_s += dt
	if is_finite(alt):
		max_alt = maxf(max_alt, alt)


## Места kind site, lake, peak из places (элементы Hud.all_places: {key, kind, x, y — клетки}) в радиусе radius м от eye,
## ещё не открытые (is_known(id) -> false) и видимые из eye: ground(x, z) -> высота земли, occluded(from, to) -> закрыто ли.
## Возвращает id новых открытий и записывает их в revealed.
func reveal_from(places: Array, eye: Vector3, radius: float, tile: float, is_known: Callable, ground: Callable, occluded: Callable) -> PackedStringArray:
	var found := PackedStringArray()
	var limit := radius * radius
	for place: Dictionary in places:
		if not place.kind in ["site", "lake", "peak"]:
			continue
		var id: String = place.key
		if revealed.has(id) or is_known.call(id):
			continue
		var x: float = place.x * tile
		var z: float = place.y * tile
		var dx := x - eye.x
		var dz := z - eye.z
		if dx * dx + dz * dz > limit:
			continue
		var top := Vector3(x, float(ground.call(x, z)) + 4.0, z)
		if occluded.is_valid() and occluded.call(eye, top):
			continue
		revealed[id] = true
		found.append(id)
	return found


## Страницы, которые закрывает снимок. place — запись Hud.all_places() места в рамке или пусто; biome — номер биома
## под камерой (или -1); sky — {dark: 1 - sunlight, up: y взгляда, aurora, comet, meteor: сила явлений ночи}
static func classify(place: Dictionary, biome: int, sky: Dictionary, plaque := "") -> PackedStringArray:
	var keys := PackedStringArray()
	if biome >= 0 and biome < Biomes.LIST.size() and not Biomes.LIST[biome].get("water", false):
		keys.append("biome:%d" % biome)
	if not place.is_empty():
		match place.kind:
			"settlement":
				keys.append("settlement")
			"peak", "lake":
				keys.append(place.kind)
			"site":
				var src: Variant = place.get("src")
				if src != null and StageSites.TYPES.has(src.type):
					keys.append("site:" + src.type)
	if plaque != "":
		keys.append("plaque:" + plaque) # страница обелиска: табличка снята вблизи; страницы собирает Hud.journey_data по обелискам мира
	if float(sky.get("dark", 0.0)) >= NIGHT_MIN and float(sky.get("up", -1.0)) >= UP_MIN:
		for event: String in ["aurora", "comet", "meteor"]:
			if float(sky.get(event, 0.0)) >= EVENT_MIN:
				keys.append("night:" + event)
	return keys


## Не дальше скольких метров место kind засчитывается в альбом
static func album_reach(kind: String) -> float:
	return ALBUM_REACH.get(kind, 60.0)


## Записать снимок: страницы без снимка получают его (path, date). Возвращает названия вновь заполненных страниц.
func add_photo(shot: Dictionary, keys: PackedStringArray, date: String, ride_start := 0.0) -> PackedStringArray:
	photos += 1
	var path := str(shot.get("path", ""))
	if not path.is_empty():
		var photo_place := str(shot.get("place", ""))
		if photo_place.is_empty():
			photo_place = str(shot.get("plaque", ""))
		personal_photos.append({path = path, date = date, place = photo_place,
			keys = Array(keys), time = Time.get_unix_time_from_system(), ride_start = ride_start})
		if personal_photos.size() > MAX_PERSONAL_PHOTOS:
			personal_photos.pop_front()
	var titles := PackedStringArray()
	for key: String in keys:
		if album.has(key) or album.size() >= MAX_ALBUM:
			continue
		album[key] = {path = str(shot.get("path", "")), date = date, place = str(shot.get("place", ""))}
		titles.append(str(shot.get("name", "Табличка")) if key.begins_with("plaque:") else page_title(key))
	return titles


## Выбранный игроком снимок должен действительно подходить открытой странице.
func choose_album_photo(key: String, path: String) -> bool:
	if not album.has(key):
		return false
	for photo: Dictionary in personal_photos:
		if photo.path == path and key in photo["keys"]:
			album[key] = {path = photo.path, date = photo.date, place = photo.place}
			return true
	return false


func record_place_photo(id: String, path: String) -> void:
	if id.is_empty() or path.is_empty():
		return
	if not place_photos.has(id) and place_photos.size() >= MAX_PLACE_PHOTOS:
		place_photos.erase(place_photos.keys()[0])
	place_photos[id] = path


func save_state() -> Dictionary:
	return {revealed = revealed.duplicate(), scanned = scanned.duplicate(), time = play_s,
		alt = max_alt, photos = photos, album = album.duplicate(true), place_photos = place_photos.duplicate(),
		personal_photos = personal_photos.duplicate(true)}


func restore(state: Dictionary) -> void:
	revealed = state.get("revealed", {}).duplicate()
	scanned = state.get("scanned", {}).duplicate()
	play_s = float(state.get("time", 0.0))
	max_alt = float(state.get("alt", 0.0))
	photos = int(state.get("photos", 0))
	album = state.get("album", {}).duplicate(true)
	place_photos = state.get("place_photos", {}).duplicate()
	personal_photos.clear()
	for photo: Dictionary in state.get("personal_photos", []):
		personal_photos.append(photo.duplicate(true))


static func valid_save(state: Variant) -> bool:
	if not state is Dictionary:
		return false
	for key: String in ["revealed", "scanned", "album"]:
		if not state.get(key) is Dictionary:
			return false
	for key: String in ["time", "alt"]:
		var v: Variant = state.get(key)
		if not (v is float or v is int) or not is_finite(float(v)) or v < 0.0:
			return false
	if not state.get("photos") is int or state.photos < 0:
		return false
	for group: String in ["revealed", "scanned"]:
		for key: Variant in state[group]:
			if not key is String or state[group][key] != true:
				return false
	if state.album.size() > MAX_ALBUM:
		return false
	for key: Variant in state.album:
		var page: Variant = state.album[key]
		if not key is String or not page is Dictionary:
			return false
		for field: String in ["path", "date", "place"]:
			if not page.get(field) is String:
				return false
	var location_photos: Variant = state.get("place_photos", {})
	if not location_photos is Dictionary or location_photos.size() > MAX_PLACE_PHOTOS:
		return false
	for key: Variant in location_photos:
		if not key is String or not location_photos[key] is String:
			return false
	var personal: Variant = state.get("personal_photos", [])
	if not personal is Array or personal.size() > MAX_PERSONAL_PHOTOS:
		return false
	for photo: Variant in personal:
		if not photo is Dictionary:
			return false
		for field: String in ["path", "date", "place"]:
			if not photo.get(field) is String:
				return false
		if not photo.get("keys") is Array or not (photo.get("time") is float or photo.get("time") is int) or not is_finite(float(photo.time)):
			return false
		var ride_start: Variant = photo.get("ride_start", 0.0)
		if not (ride_start is float or ride_start is int) or not is_finite(float(ride_start)):
			return false
		for key: Variant in photo["keys"]:
			if not key is String:
				return false
	return true
