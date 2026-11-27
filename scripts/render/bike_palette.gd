extends RefCounted
## Палитра общего материала велосипеда и седока (resources/bike_rider.gdshader).
## Вершины хранят место (UV.x), а не цвет, поэтому расцветка меняется одним массивом без пересборки.

enum { FRAME, FRAME_ACCENT, RUBBER, ALLOY, BLACK, TAIL, JERSEY, JERSEY_PANEL, NAVY, SKIN, CREAM, HELMET, DARK, LENS, COATING, SIDEWALL, FRAME_SECONDARY }

## Вид поверхности (UV.y) — как KIND_* в шейдере
enum { PAINT, RUBBER_KIND, ALLOY_KIND, HARD, FABRIC, SKIN_KIND, SHELL, LENS_KIND, GLOW, MATTE, COATING_KIND, GRIP_KIND, PEDAL_KIND }

const SHADER := preload("res://resources/bike_rider.gdshader")
const MATERIAL_PATH := "res://resources/bike_rider_material.tres"

## Рама, графика, джерси, вставки, шорты, шлем, ноги вилки, верх рамы, манжеты и носки.
const SCHEMES := {
	"ember": ["ca542c", "ffc177", "287b79", "184a51", "233747", "ffd18e", "c8935c", "943927", "ffc88b"],
	"glacier": ["d5e9ef", "2675c8", "285caa", "122e68", "20314c", "e7fafb", "8ba6c1", "89c2e8", "b9e9f7"],
	"moss": ["52603b", "dfbd54", "ad903b", "4b512f", "313b28", "797d49", "a89152", "343d2b", "e1c768"],
	"night": ["262b42", "ff663d", "2d3452", "87374c", "201f34", "d54635", "655b79", "713244", "f88d64"],
	"lingon": ["8e233c", "ffdbcb", "f1c5c0", "a33953", "4e2536", "bb3855", "9b8594", "551d34", "ffe0cc"],
	# 27.11: светлее джерси и серебристые вилка, шлем и манжеты — раньше рама, джерси и шорты сливались в один серый
	"fog": ["7d9392", "e4ece8", "a3b8b4", "40555c", "2e3e45", "dde6e1", "c3cdcf", "56696f", "eef3ef"],
	"copper": ["b77a63", "b8d6a1", "9eb28d", "3d715b", "24443a", "a46b50", "b17851", "4b846c", "c8d7a4"],
	# 27.11: ступени чёрного разведены (джерси угольное, шорты и вставки глубже, графика и вилка графитовые) —
	# раньше форма, маска и рама сливались в одно пятно
	"obsidian": ["16191c", "5b646c", "2a2f34", "15181b", "0f1214", "1b1f23", "4a5258", "2b3136", "3d454c"],
	"heritage": ["6b4831", "e5c48c", "a98256", "5e3f2c", "503727", "e5cf9c", "b98e52", "3f2b24", "edd2a4"],
	"pulse": ["573ab1", "dcf66e", "874ddb", "35236a", "292342", "d2ed57", "866cd4", "321d70", "daef77"],
	"salt": ["e2bb76", "183c85", "e7c388", "264d97", "26355a", "3358a4", "8f9dac", "294b91", "f2d393"],
	"tide": ["126c72", "ff966f", "e18870", "9b4b48", "153f4b", "317e80", "739995", "143e57", "ffb599"],
	"ivory": ["f0e6d3", "9a7450", "f1e3cb", "b39a7e", "544337", "fff0d8", "c1a578", "d7c4a6", "f8e9cf"],
	# 27.11: особая серия — краска с переливом и искрами (FINISHES), светящаяся графика
	"aurora": ["35227a", "9cf7d4", "1b2148", "40276e", "0d1122", "35227a", "8f9fc4", "1c1f4a", "9cf7d4"],
}
const SCHEME_NAMES := {"ember": "Закат", "glacier": "Ледник", "moss": "Мох", "night": "Ночь",
	"lingon": "Брусника", "fog": "Туман", "copper": "Медь",
	"obsidian": "Обсидиан", "heritage": "Орех", "pulse": "Импульс", "salt": "Солончак", "tide": "Прилив",
	"ivory": "Молочная кость", "aurora": "Северное сияние"}

const SCHEME_DESCRIPTIONS := {
	"ember": "Терракотовая рама, тёмно-бирюзовое джерси и янтарные детали.",
	"glacier": "Ледяная рама с синим верхом и кобальтовая форма.",
	"moss": "Оливковая рама, горчичное джерси и детали цвета сухой травы.",
	"night": "Чернильный синий, бордовые вставки и яркие сигнальные акценты.",
	"lingon": "Ягодная рама, розовое джерси и бордовые шорты.",
	"fog": "Дымчатые серо-зелёные тона с холодным серебристым акцентом.",
	"copper": "Медный низ рамы, верх цвета патины и светлое шалфейное джерси.",
	"obsidian": "Тональный чёрный комплект: глянцевые рама и шлем, графитовая графика и угольное джерси на матовых шортах.",
	"heritage": "Тёмный орех, кремовые манжеты и тёплые бронзовые детали.",
	"pulse": "Фиолетовая рама и форма с неоново-лаймовой графикой.",
	"salt": "Песочный низ рамы, синий верх и форма в цветах раллийной ливреи.",
	"tide": "Глубокий цвет морской волны, коралловое джерси и графика в тон.",
	"ivory": "Молочно-кремовые рама, джерси и шлем с бронзовой графикой и кофейными вставками.",
	"aurora": "Особая серия. Чернильно-фиолетовые рама и шлем на изгибах переливаются зелёным, как сияние над тайгой; в лаке — искры металлика, мятная графика и манжеты светятся в сумерках, линзы очков — фиолетовые.",
}

## Особая отделка расцветки (шейдер bike_rider: finish_*): перелив краски рамы и шлема к цвету flip под скользящим
## углом (alpha — сила, flip_power — резкость), искры металлика в лаке (flake — доля, flake_scale — на метр),
## свечение графики и светлых деталей формы (glow). У расцветок без записи — FINISH_NONE, обычная краска.
const FINISHES := {
	"aurora": {flip = Color("1fe89a", 0.9), flip_power = 2.0, flake = 1.0, flake_scale = 260.0, glow = 0.45},
}
const FINISH_NONE := {flip = Color(0, 0, 0, 0), flip_power = 1.0, flake = 0.0, flake_scale = 1.0, glow = 0.0}

const SIDEWALLS := {
	"glacier": "859aa5", "moss": "8b794b", "night": "444351", "lingon": "8b6767",
	"fog": "8e9a97", "copper": "8c7557", "heritage": "ab8c61",
	"pulse": "57526e", "salt": "b39263", "tide": "526a6b", "obsidian": "2a2e31", "aurora": "3b3768",
}
const STOCK_SIDEWALL := "8a6a4a"

## Общие места палитры, которые расцветка заменяет целиком (тональный чёрный: резина, металл, обувь, линзы)
const SLOT_OVERRIDES := {
	"obsidian": {RUBBER: "141618", ALLOY: "4b5156", BLACK: "1b1e20", DARK: "101214", LENS: "1d2226"},
	"aurora": {ALLOY: "aab6d0", LENS: "6b4fd0"},
}

const STOCK_TIRES := "tires_stock"
const TIRE_NAMES := {STOCK_TIRES: "Штатные", "tires_rose": "Розовые", "tires_sage": "Шалфей",
	"tires_blue": "Лазурь", "tires_sand": "Песочные", "tires_ivory": "Молочная кость"}
const STOCK_GRIPS := "grips_stock"
const GRIP_NAMES := {STOCK_GRIPS: "Штатные", "grips_rose": "Розовые", "grips_sage": "Шалфей",
	"grips_blue": "Лазурь", "grips_sand": "Песочные", "grips_ivory": "Молочная кость"}
const STOCK_PEDALS := "pedals_stock"
const PEDAL_NAMES := {STOCK_PEDALS: "Штатные", "pedals_rose": "Розовые", "pedals_sage": "Шалфей",
	"pedals_blue": "Лазурь", "pedals_sand": "Песочные", "pedals_ivory": "Молочная кость"}
# Протектор и боковина. Протектор темнее, чтобы сохранить читаемость шашек.
const TIRE_COLORS := {
	"tires_rose": [Color("#a94b69"), Color("#ec95b2")],
	"tires_sage": [Color("#4e6c53"), Color("#9bbf8e")],
	"tires_blue": [Color("#3b608a"), Color("#84b7e1")],
	"tires_sand": [Color("#8d6e49"), Color("#dac097")],
	"tires_ivory": [Color("#c5b499"), Color("#f4e6cb")],
}


static func colors(scheme := "ember") -> PackedColorArray:
	var s: Array = SCHEMES.get(scheme, SCHEMES.ember)
	var c := PackedColorArray()
	c.resize(FRAME_SECONDARY + 1)
	c[FRAME] = Color(s[0])
	c[FRAME_ACCENT] = Color(s[1])
	c[RUBBER] = Color("20272b")
	c[ALLOY] = Color("adb8b7")
	c[BLACK] = Color("2c363d")
	c[TAIL] = Color("d8322a")
	c[JERSEY] = Color(s[2])
	c[JERSEY_PANEL] = Color(s[3])
	c[NAVY] = Color(s[4])
	c[SKIN] = Color("dba47d")
	c[CREAM] = Color(s[8])
	c[HELMET] = Color(s[5])
	c[DARK] = Color("17252e")
	c[LENS] = Color("315363")
	c[COATING] = Color(s[6])
	c[SIDEWALL] = Color(SIDEWALLS.get(scheme, STOCK_SIDEWALL))
	c[FRAME_SECONDARY] = Color(s[7])
	var overrides: Dictionary = SLOT_OVERRIDES.get(scheme, {})
	for slot: int in overrides:
		c[slot] = Color(overrides[slot])
	return c


static func grip_colors(id: String) -> Array:
	return TIRE_COLORS.get("tires_" + id.trim_prefix("grips_"), [Color.TRANSPARENT, Color.TRANSPARENT])


static func pedal_colors(id: String) -> Array:
	return TIRE_COLORS.get("tires_" + id.trim_prefix("pedals_"), [Color.TRANSPARENT, Color.TRANSPARENT])


## Материал из файла (общий для сборщиков) или новый, с палитрой по умолчанию.
static func material() -> ShaderMaterial:
	if ResourceLoader.exists(MATERIAL_PATH):
		return load(MATERIAL_PATH) as ShaderMaterial
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("palette", colors())
	return m


## Сборщик пишет материал в файл один раз, чтобы велосипед и седок ссылались на один ресурс.
static func save_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("palette", colors())
	ResourceSaver.save(m, MATERIAL_PATH)
	return ResourceLoader.load(MATERIAL_PATH, "", ResourceLoader.CACHE_MODE_REPLACE) as ShaderMaterial


## Перья и цепь (CylinderMesh): тот же шейдер с постоянным местом и видом.
static func fixed_material(base: ShaderMaterial, slot: int, kind: int) -> ShaderMaterial:
	var m := base.duplicate() as ShaderMaterial
	m.set_shader_parameter("fixed_slot", float(slot))
	m.set_shader_parameter("fixed_kind", float(kind))
	return m
