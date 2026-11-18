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
	# 18.11.2026: модель вышки теперь около 4,5 м в поперечнике (TowerLayout) и 16,5 м высотой; half и flat не тронуты —
	# от них зависят расстановка мест, дороги и растительность вокруг. Твёрдого ящика вышки в физике больше нет.
	tower = {half = Vector2(1.3, 1.3), flat = 1.4, height = 16.5},
	obelisk = {half = Vector2(0.75, 0.75), flat = 1.2, height = 5.5},
	ruin = {half = Vector2(1.7, 1.7), flat = 3.0, height = 2.4},
	keep = {half = Vector2(1.6, 1.6), flat = 2.4, height = 5.0},
	stone = {half = Vector2(0.35, 0.25), flat = 3.0, height = 2.0},
	bench = {half = Vector2(0.95, 0.3), flat = 1.6, height = 0.9},
	pier = {half = Vector2(0.8, 0.8), flat = 3.0, height = 0.5},
}
## Постройки мест без твёрдого ящика: на вышку поднимаются, на лавку садятся, по причалу идут (настилы — Heightfield.add_site_decks)
const NOT_SOLID := ["tower", "bench", "pier"]

static func is_solid(kind: String) -> bool:
	return kind not in NOT_SOLID


## Порядок моделей по категориям библиотеки (для линейки осмотра и отчётов).
const MODEL_ORDER := [
	"house", "house_wing", "house_steep",
	"house_timber", "cabin_long", "cabin_porch",
	"chalet", "chalet_terrace", "chalet_stone",
	"tall", "tall_mansard", "tall_hall",
	"barn", "barn_loft", "shed", "hay",
	"fountain", "well_canopy", "market_stall", "boat_shed", "woodpile_rack",
]

## Реестр построек поселений по строковым именам.
## category: "home" (жилой дом), "outbuilding" (хозпостройка), "landmark" (характерный объект).
## size: ключ из SIZE_CLASSES. glb: путь к модели в формате GLB.
const MODELS := {
	# --- Небольшие жилые дома (3) ---
	house = {
		size = "small",
		category = "home",
		glb = "res://resources/models/settlements/house.glb",
		base = "house",
		form_v = 0,
		title = "малый оштукатуренный дом",
	},
	house_wing = {
		size = "small",
		category = "home",
		glb = "res://resources/models/settlements/house_wing.glb",
		base = "house",
		form_v = 1,
		height = 3.2,
		title = "малый дом с боковой пристройкой",
	},
	house_steep = {
		size = "small",
		category = "home",
		glb = "res://resources/models/settlements/house_steep.glb",
		base = "house",
		form_v = 2,
		height = 3.9,
		title = "дом с крутой кровлей и люкарной",
	},
	# --- Лесные дома / срубы (3) ---
	house_timber = {
		size = "small",
		category = "home",
		glb = "res://resources/models/settlements/house_timber.glb",
		base = "house",
		form_v = 1,
		title = "компактный сруб с дровяным навесом",
	},
	cabin_long = {
		size = "small",
		category = "home",
		glb = "res://resources/models/settlements/cabin_long.glb",
		base = "house",
		form_v = 2,
		height = 3.0,
		title = "вытянутый сруб с крытой галереей",
	},
	cabin_porch = {
		size = "small",
		category = "home",
		glb = "res://resources/models/settlements/cabin_porch.glb",
		base = "house",
		form_v = 3,
		height = 3.7,
		title = "высокий таёжный сруб на подклете с крыльцом",
	},
	# --- Горные шале (3) ---
	chalet = {
		size = "large",
		category = "home",
		glb = "res://resources/models/settlements/chalet.glb",
		base = "chalet",
		form_v = 0,
		title = "горное шале с передним балконом",
	},
	chalet_terrace = {
		size = "large",
		category = "home",
		glb = "res://resources/models/settlements/chalet_terrace.glb",
		base = "chalet",
		form_v = 1,
		height = 4.6,
		title = "альпийское шале с боковой террасой и лестницей",
	},
	chalet_stone = {
		size = "large",
		category = "home",
		glb = "res://resources/models/settlements/chalet_stone.glb",
		base = "chalet",
		form_v = 2,
		height = 4.9,
		title = "каменно-деревянное шале с контрфорсами",
	},
	# --- Крупные жилые и общественные дома (3) ---
	tall = {
		size = "medium",
		category = "home",
		glb = "res://resources/models/settlements/tall.glb",
		base = "tall",
		form_v = 0,
		title = "высокий двухэтажный дом",
	},
	tall_mansard = {
		size = "medium",
		category = "home",
		glb = "res://resources/models/settlements/tall_mansard.glb",
		base = "tall",
		form_v = 1,
		height = 5.4,
		title = "крупный дом с ломаной мансардной крышей",
	},
	tall_hall = {
		size = "large",
		category = "home",
		glb = "res://resources/models/settlements/tall_hall.glb",
		base = "tall",
		form_v = 2,
		height = 7.4,
		title = "общественный дом центра с башенкой-звонницей",
	},
	# --- Сараи и хозяйственные строения (4) ---
	barn = {
		size = "barn",
		category = "outbuilding",
		glb = "res://resources/models/settlements/barn.glb",
		base = "barn",
		form_v = 0,
		title = "закрытый хозяйственный сарай",
	},
	barn_loft = {
		size = "barn",
		category = "outbuilding",
		glb = "res://resources/models/settlements/barn_loft.glb",
		base = "barn",
		form_v = 1,
		height = 3.5,
		title = "сарай-сеновал с клювом и боковым навесом",
	},
	shed = {
		size = "shed",
		category = "outbuilding",
		glb = "res://resources/models/settlements/shed.glb",
		base = "shed",
		form_v = 0,
		title = "открытый дровяной навес",
	},
	hay = {
		size = "hay",
		category = "outbuilding",
		glb = "res://resources/models/settlements/hay.glb",
		base = "hay",
		form_v = 0,
		title = "стог сена на поддоне",
	},
	# --- Характерные объекты (5) ---
	fountain = {
		size = "fountain",
		category = "landmark",
		glb = "res://resources/models/settlements/fountain.glb",
		base = "fountain",
		form_v = 0,
		title = "каменный колодец-корыто",
	},
	well_canopy = {
		size = "hay",
		category = "landmark",
		glb = "res://resources/models/settlements/well_canopy.glb",
		base = "fountain",
		form_v = 1,
		height = 2.6,
		title = "деревянный колодец под шатром с воротом",
	},
	market_stall = {
		size = "shed",
		category = "landmark",
		glb = "res://resources/models/settlements/market_stall.glb",
		base = "shed",
		form_v = 1,
		height = 2.5,
		title = "торговый навес с прилавком и товарами",
	},
	boat_shed = {
		size = "barn",
		category = "landmark",
		glb = "res://resources/models/settlements/boat_shed.glb",
		base = "barn",
		form_v = 2,
		height = 2.9,
		title = "прибрежный лодочный навес с сетями",
	},
	woodpile_rack = {
		size = "shed",
		category = "landmark",
		glb = "res://resources/models/settlements/woodpile_rack.glb",
		base = "shed",
		form_v = 2,
		height = 1.9,
		title = "крытая поленница с козлами и колодой",
	},
}

## Наборы построек по 6 видам поселений (центр, приморское, лесное, предгорное, удалённое, обычное).
## В каждом наборе: жилые варианты с весами (homes, plaza_homes для первого ряда у площади),
## вероятность и веса хозпостроек, а также 1–2 характерных объекта.
const SETS := {
	center = {
		homes = [
			["house", 0.22], ["house_wing", 0.14], ["house_steep", 0.14],
			["tall", 0.16], ["tall_mansard", 0.16], ["chalet", 0.10], ["chalet_terrace", 0.08],
		],
		plaza_homes = [
			["tall", 0.28], ["tall_mansard", 0.26], ["tall_hall", 0.18],
			["chalet", 0.12], ["chalet_terrace", 0.08], ["house_steep", 0.08],
		],
		outbuilding_chance = 0.60,
		outbuildings = [["barn", 0.30], ["barn_loft", 0.25], ["shed", 0.25], ["hay", 0.20]],
		landmarks = [{id = "fountain", chance = 1.0}, {id = "market_stall", chance = 0.85}],
	},
	coastal = {
		homes = [
			["house", 0.28], ["house_wing", 0.18], ["house_timber", 0.16],
			["cabin_long", 0.14], ["house_steep", 0.12], ["tall", 0.06], ["tall_mansard", 0.06],
		],
		plaza_homes = [
			["tall_mansard", 0.22], ["tall", 0.18], ["house_wing", 0.24],
			["house", 0.22], ["chalet_terrace", 0.14],
		],
		outbuilding_chance = 0.42,
		outbuildings = [["shed", 0.48], ["barn", 0.20], ["barn_loft", 0.17], ["hay", 0.15]],
		landmarks = [{id = "boat_shed", chance = 0.85}, {id = "fountain", chance = 0.60}],
	},
	forest = {
		homes = [
			["house_timber", 0.32], ["cabin_long", 0.28], ["cabin_porch", 0.22],
			["house_steep", 0.10], ["house", 0.08],
		],
		plaza_homes = [
			["cabin_porch", 0.36], ["house_timber", 0.28], ["cabin_long", 0.22], ["house_steep", 0.14],
		],
		outbuilding_chance = 0.55,
		outbuildings = [["shed", 0.45], ["barn", 0.20], ["barn_loft", 0.15], ["hay", 0.20]],
		landmarks = [{id = "woodpile_rack", chance = 0.70}, {id = "well_canopy", chance = 0.45}],
	},
	foothill = {
		homes = [
			["chalet", 0.26], ["chalet_terrace", 0.22], ["chalet_stone", 0.22],
			["house_wing", 0.14], ["house_steep", 0.10], ["house_timber", 0.06],
		],
		plaza_homes = [
			["chalet_stone", 0.32], ["chalet", 0.28], ["chalet_terrace", 0.24], ["tall", 0.16],
		],
		outbuilding_chance = 0.55,
		outbuildings = [["barn", 0.25], ["barn_loft", 0.25], ["shed", 0.30], ["hay", 0.20]],
		landmarks = [{id = "fountain", chance = 0.65}, {id = "woodpile_rack", chance = 0.40}],
	},
	remote = {
		homes = [
			["cabin_porch", 0.30], ["cabin_long", 0.28], ["house_timber", 0.22],
			["chalet_stone", 0.12], ["house", 0.08],
		],
		plaza_homes = [
			["cabin_porch", 0.40], ["chalet_stone", 0.25], ["house_timber", 0.20], ["cabin_long", 0.15],
		],
		outbuilding_chance = 0.55,
		outbuildings = [["shed", 0.55], ["hay", 0.25], ["barn", 0.20]],
		landmarks = [{id = "woodpile_rack", chance = 0.60}],
	},
	ordinary = {
		homes = [
			["house", 0.28], ["house_wing", 0.20], ["house_steep", 0.16],
			["house_timber", 0.14], ["cabin_long", 0.12], ["tall", 0.10],
		],
		plaza_homes = [
			["house_wing", 0.25], ["house", 0.22], ["house_steep", 0.20],
			["tall_mansard", 0.18], ["chalet", 0.15],
		],
		outbuilding_chance = 0.48,
		outbuildings = [["barn", 0.25], ["barn_loft", 0.22], ["shed", 0.33], ["hay", 0.20]],
		landmarks = [{id = "well_canopy", chance = 0.55}, {id = "fountain", chance = 0.35}],
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
		return float(MODELS[id].get("height", SIZE_CLASSES[MODELS[id].size].height))
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
		return pick_weighted([["barn", 0.30], ["barn_loft", 0.25], ["hay", 0.25], ["shed", 0.20]], u)
	var spec: Dictionary = SETS.get(set_kind, SETS.ordinary)
	return pick_weighted(spec.outbuildings, u)


## Выбор жилого дома для хутора или одинокого двора вне поселения (StageSites) по биому и рельефу.
static func pick_site_home(biome: int, elev: float, slope: float, u: float) -> String:
	if elev > 0.34 or slope > 0.20:
		return pick_weighted([["chalet_stone", 0.40], ["chalet_terrace", 0.35], ["chalet", 0.25]], u)
	if biome in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE]:
		return pick_weighted([["cabin_porch", 0.40], ["cabin_long", 0.35], ["house_timber", 0.25]], u)
	return pick_weighted([["house_wing", 0.35], ["house_steep", 0.35], ["house", 0.30]], u)


## Выбор хозяйственной постройки для хутора вне поселения (StageSites) по биому.
static func pick_site_barn(biome: int, u: float) -> String:
	if biome in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE]:
		return pick_weighted([["shed", 0.45], ["barn", 0.30], ["woodpile_rack", 0.25]], u)
	return pick_weighted([["barn_loft", 0.45], ["barn", 0.35], ["shed", 0.20]], u)
