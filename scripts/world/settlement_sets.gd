class_name SettlementSets
extends RefCounted
## Наборы построек и типоразмеры поселений (16.11.2026).
## Хранится рядом с settlement_roles.gd в слое world: доступен генератору, физике (столкновения, фундамент),
## отрисовке и интерфейсу без обратных зависимостей на верхние слои.
## Варианты задаются строковыми именами (MODELS), а не индексами: добавление новой модели не сдвигает старые.

## Типоразмеры в плане (полуширина по местным X/Z, м), допуск перепада под фундаментом (м) и высота стен (м).
## Точка опоры каждой модели — центр пола (0, 0, 0), дверь смотрит в +Z, конёк вдоль Z.
const SIZE_CLASSES := {
	small = {half = Vector2(1.6, 1.6), flat = 1.6, height = 2.6},
	medium = {half = Vector2(1.9, 1.9), flat = 1.5, height = 4.7},
	large = {half = Vector2(2.2, 1.9), flat = 2.0, height = 4.3},
	barn = {half = Vector2(2.0, 1.5), flat = 1.6, height = 2.8},
	shed = {half = Vector2(1.1, 0.75), flat = 1.4, height = 2.2},
	hay = {half = Vector2(0.9, 0.9), flat = 2.0, height = 2.0},
	fountain = {half = Vector2(1.0, 0.45), flat = 0.8, height = 1.5},
}

## Габариты построек вне поселений (StageSites): хранятся здесь же, чтобы единая проверка столкновений и фундамента
## не держала вторую таблицу размеров.
const SITE_SIZES := {
	shelter = {half = Vector2(1.5, 1.5), flat = 1.8, height = 2.0},
	tower = {half = Vector2(1.3, 1.3), flat = 1.4, height = 8.5},
	obelisk = {half = Vector2(0.75, 0.75), flat = 1.2, height = 5.5},
	ruin = {half = Vector2(1.7, 1.7), flat = 3.0, height = 2.4},
	keep = {half = Vector2(1.6, 1.6), flat = 2.4, height = 5.0},
	stone = {half = Vector2(0.35, 0.25), flat = 3.0, height = 2.0},
}

## Реестр построек поселений по строковым именам.
## category: "home" (жилой дом), "outbuilding" (хозпостройка), "landmark" (характерный объект).
## size: ключ из SIZE_CLASSES. glb: путь к модели в формате GLB.
const MODELS := {
	house = {
		size = "small",
		category = "home",
		glb = "res://resources/models/settlements/house.glb",
		base = "house",
		form_v = 0,
		title = "малый оштукатуренный дом",
	},
	house_timber = {
		size = "small",
		category = "home",
		glb = "res://resources/models/settlements/house_timber.glb",
		base = "house",
		form_v = 1,
		title = "малый бревенчатый сруб с навесом",
	},
	chalet = {
		size = "large",
		category = "home",
		glb = "res://resources/models/settlements/chalet.glb",
		base = "chalet",
		form_v = 0,
		title = "горное шале с балконом",
	},
	tall = {
		size = "medium",
		category = "home",
		glb = "res://resources/models/settlements/tall.glb",
		base = "tall",
		form_v = 0,
		title = "высокий двухэтажный дом",
	},
	barn = {
		size = "barn",
		category = "outbuilding",
		glb = "res://resources/models/settlements/barn.glb",
		base = "barn",
		form_v = 0,
		title = "закрытый сарай",
	},
	shed = {
		size = "shed",
		category = "outbuilding",
		glb = "res://resources/models/settlements/shed.glb",
		base = "shed",
		form_v = 0,
		title = "дровяной навес",
	},
	hay = {
		size = "hay",
		category = "outbuilding",
		glb = "res://resources/models/settlements/hay.glb",
		base = "hay",
		form_v = 0,
		title = "стог / сеновал",
	},
	fountain = {
		size = "fountain",
		category = "landmark",
		glb = "res://resources/models/settlements/fountain.glb",
		base = "fountain",
		form_v = 0,
		title = "колодец-корыто",
	},
}

## Наборы построек по 6 видам поселений (центр, приморское, лесное, предгорное, удалённое, обычное).
## В каждом наборе: жилые варианты с весами (homes, plaza_homes для первого ряда у площади),
## вероятность и веса хозпостроек, а также 1–2 характерных объекта.
const SETS := {
	center = {
		homes = [["house", 0.35], ["house_timber", 0.15], ["chalet", 0.30], ["tall", 0.20]],
		plaza_homes = [["tall", 0.60], ["chalet", 0.25], ["house", 0.15]],
		outbuilding_chance = 0.60,
		outbuildings = [["barn", 0.45], ["shed", 0.35], ["hay", 0.20]],
		landmarks = [{id = "fountain", chance = 1.0}],
	},
	coastal = {
		homes = [["house", 0.50], ["house_timber", 0.20], ["chalet", 0.20], ["tall", 0.10]],
		plaza_homes = [["tall", 0.35], ["house", 0.45], ["chalet", 0.20]],
		outbuilding_chance = 0.40,
		outbuildings = [["shed", 0.60], ["barn", 0.25], ["hay", 0.15]],
		landmarks = [{id = "fountain", chance = 0.70}],
	},
	forest = {
		homes = [["house_timber", 0.55], ["chalet", 0.30], ["house", 0.15]],
		plaza_homes = [["chalet", 0.45], ["house_timber", 0.45], ["tall", 0.10]],
		outbuilding_chance = 0.55,
		outbuildings = [["shed", 0.55], ["barn", 0.25], ["hay", 0.20]],
		landmarks = [{id = "fountain", chance = 0.35}],
	},
	foothill = {
		homes = [["chalet", 0.55], ["house_timber", 0.25], ["house", 0.20]],
		plaza_homes = [["chalet", 0.65], ["tall", 0.20], ["house_timber", 0.15]],
		outbuilding_chance = 0.55,
		outbuildings = [["barn", 0.35], ["shed", 0.40], ["hay", 0.25]],
		landmarks = [{id = "fountain", chance = 0.65}],
	},
	remote = {
		homes = [["house_timber", 0.55], ["house", 0.30], ["chalet", 0.15]],
		plaza_homes = [["house_timber", 0.60], ["chalet", 0.25], ["house", 0.15]],
		outbuilding_chance = 0.55,
		outbuildings = [["shed", 0.60], ["hay", 0.25], ["barn", 0.15]],
		landmarks = [{id = "fountain", chance = 0.15}],
	},
	ordinary = {
		homes = [["house", 0.50], ["house_timber", 0.20], ["chalet", 0.30]],
		plaza_homes = [["house", 0.45], ["chalet", 0.35], ["tall", 0.20]],
		outbuilding_chance = 0.45,
		outbuildings = [["barn", 0.35], ["shed", 0.40], ["hay", 0.25]],
		landmarks = [{id = "fountain", chance = 0.40}],
	},
}

## Размеры, прочитанные из запечённого каталога при запуске (AssetCatalog.get_catalog()).
## Если каталог ещё не загружен (например, фоновая генерация или headless-проверка),
## используются совпадающие значения из SIZE_CLASSES, проверенные скриптом сборки.
static var catalog_meta := {}


## Обновить метаданные размеров из загруженного каталога моделей.
static func apply_catalog(settlements_dict: Dictionary) -> void:
	var next := {}
	for id: String in settlements_dict:
		var entry: Variant = settlements_dict[id]
		if entry is Dictionary and entry.has("half"):
			next[id] = {
				half = entry.half,
				flat = float(entry.get("flat", flat_of(id))),
				height = float(entry.get("height", height_of(id))),
				size = str(entry.get("size", size_class_of(id))),
			}
	catalog_meta = next


## Входит ли вариант в жилые дома (учёт населения и панели поселения).
static func is_home(id: String) -> bool:
	return MODELS.has(id) and MODELS[id].category == "home"


## Все строковые имена жилых домов.
static func home_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id: String in MODELS:
		if MODELS[id].category == "home":
			out.append(id)
	return out


## Имя класса типоразмера модели ("small", "medium", "large", ...).
static func size_class_of(id: String) -> String:
	if MODELS.has(id):
		return MODELS[id].size
	return "small"


## Полуширина постройки в плане (м) для расстановки, фундамента и столкновений.
static func half_of(id: String) -> Vector2:
	if catalog_meta.has(id):
		return catalog_meta[id].half
	if MODELS.has(id):
		return SIZE_CLASSES[MODELS[id].size].half
	if SITE_SIZES.has(id):
		return SITE_SIZES[id].half
	return SIZE_CLASSES.small.half


## Допустимый перепад земли под фундаментом постройки (м).
static func flat_of(id: String) -> float:
	if catalog_meta.has(id):
		return catalog_meta[id].flat
	if MODELS.has(id):
		return SIZE_CLASSES[MODELS[id].size].flat
	if SITE_SIZES.has(id):
		return SITE_SIZES[id].flat
	return SIZE_CLASSES.small.flat


## Оценочная высота постройки (м) для упрощённых коллизий при падении с велосипеда.
static func height_of(id: String, v: int = 0) -> float:
	if id == "keep":
		return 5.0 + float(v) * 1.5
	if catalog_meta.has(id):
		return catalog_meta[id].height
	if MODELS.has(id):
		return SIZE_CLASSES[MODELS[id].size].height
	if SITE_SIZES.has(id):
		return SITE_SIZES[id].height
	return 2.0


## Вид набора для поселения s: учитывает берег, роль из settlement_roles.gd и характер места.
static func kind_of(w: WorldData, s: SettlementData) -> String:
	var ch: String = EntityCodec.value(s, "character", "")
	if ch.begins_with("примор") or ch.begins_with("рыбац"):
		return "coastal"
	if w != null and s.i >= 0 and s.i < w.dist_water.size() and w.dist_water[s.i] < 5.0 and s.role in ["center", "ordinary", ""]:
		if not w.dist_ocean.is_empty() and w.dist_ocean[s.i] < 8.0:
			return "coastal"
	if SETS.has(s.role):
		return s.role
	if ch.begins_with("лесн"):
		return "forest"
	if ch.begins_with("предгор") or ch.begins_with("горн"):
		return "foothill"
	return "center" if s.town else "ordinary"


## Взвешенный выбор строкового имени по значению u в [0, 1).
static func pick_weighted(list: Array, u: float) -> String:
	if list.is_empty():
		return "house"
	var total := 0.0
	for item: Array in list:
		total += float(item[1])
	if total <= 0.0:
		return str(list[0][0])
	var target := clampf(u, 0.0, 0.999999) * total
	var acc := 0.0
	for item: Array in list:
		acc += float(item[1])
		if target < acc:
			return str(item[0])
	return str(list[-1][0])


## Выбор жилого дома для слота на расстоянии from_plaza клеток от кромки площади.
static func pick_home(set_kind: String, town: bool, from_plaza: float, u: float) -> String:
	var spec: Dictionary = SETS.get(set_kind, SETS.ordinary)
	if (town or set_kind == "center") and from_plaza < 1.6 and spec.has("plaza_homes"):
		return pick_weighted(spec.plaza_homes, u)
	return pick_weighted(spec.homes, u)


## Вероятность хозяйственной постройки во дворе дома.
static func outbuilding_chance(set_kind: String, s: SettlementData) -> float:
	var ch: String = EntityCodec.value(s, "character", "")
	if ch.begins_with("земледель") or ch.begins_with("торгов"):
		return 0.70
	var spec: Dictionary = SETS.get(set_kind, SETS.ordinary)
	return float(spec.get("outbuilding_chance", 0.45))


## Выбор хозяйственной постройки для двора.
static func pick_outbuilding(set_kind: String, s: SettlementData, u: float) -> String:
	var ch: String = EntityCodec.value(s, "character", "")
	if ch.begins_with("земледель") or ch.begins_with("торгов"):
		return pick_weighted([["barn", 0.45], ["hay", 0.30], ["shed", 0.25]], u)
	var spec: Dictionary = SETS.get(set_kind, SETS.ordinary)
	return pick_weighted(spec.outbuildings, u)
