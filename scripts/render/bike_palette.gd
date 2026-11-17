extends RefCounted
## Палитра общего материала велосипеда и седока (resources/bike_rider.gdshader): 16 мест.
## Вершины хранят место (UV.x), а не цвет, поэтому расцветка меняется одним массивом без пересборки.

enum { FRAME, FRAME_ACCENT, RUBBER, ALLOY, BLACK, TAIL, JERSEY, JERSEY_PANEL, NAVY, SKIN, CREAM, HELMET, DARK, LENS, COATING, SIDEWALL }

## Вид поверхности (UV.y) — как KIND_* в шейдере
enum { PAINT, RUBBER_KIND, ALLOY_KIND, HARD, FABRIC, SKIN_KIND, SHELL, LENS_KIND, GLOW, MATTE, COATING_KIND }

const SHADER := preload("res://resources/bike_rider.gdshader")
const MATERIAL_PATH := "res://resources/bike_rider_material.tres"

## Расцветки: рама, акцент рамы, джерси, вставки джерси, тёмная ткань (шорты), шлем, ноги вилки.
## Остальные места (резина, металл, кожа, стекло) общие.
const SCHEMES := {
	"ember": ["c95c32", "e9d6a5", "299a9a", "206c73", "243747", "f2e8d0", "c2a25a"],
	"glacier": ["e8ecef", "2f7fb8", "2f7fb8", "1d4f78", "23303a", "e8ecef", "23272b"],
	"moss": ["55704a", "d9c27a", "c98a3a", "8a5a2a", "2f3a2c", "d9d2bf", "c2a25a"],
	"night": ["2b3036", "e0562c", "e0562c", "2b3036", "1c2126", "2b3036", "c9ced2"],
}
const SCHEME_NAMES := {"ember": "Закат", "glacier": "Ледник", "moss": "Мох", "night": "Ночь"}


static func colors(scheme := "ember") -> PackedColorArray:
	var s: Array = SCHEMES.get(scheme, SCHEMES.ember)
	var c := PackedColorArray()
	c.resize(16)
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
	c[CREAM] = Color("f0e5cc")
	c[HELMET] = Color(s[5])
	c[DARK] = Color("17252e")
	c[LENS] = Color("315363")
	c[COATING] = Color(s[6])
	c[SIDEWALL] = Color("8a6a4a")
	return c


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
