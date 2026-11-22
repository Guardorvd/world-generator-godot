class_name RoadTuning
extends Resource
## Параметры природных дорог (resources/road_tuning.tres).
## Зависимости кэша и пределы проходимости описаны в docs/ROAD_DATA_CONTRACT.md.

const PATH := "res://resources/road_tuning.tres"
const Routing := preload("res://scripts/game/road_routing_tuning.gd")
const Section := preload("res://scripts/game/road_section_tuning.gd")
const Obstacles := preload("res://scripts/game/road_obstacle_tuning.gd")
## Отпечатки значений до добавления зависимостей. С этими значениями старый кэш уже правильный.
const BASELINE_BED_DIGEST := "2fe77c228432"
const BASELINE_ROUTING_DIGEST := "e7cfb205deaa"
const BASELINE_WIDTH_DIGEST := "2f05a2e55136"
const BASELINE_CLEARANCE_DIGEST := "1a9220c8b0d0"
const BASELINE_TREAD_DIGEST := "8bc1a25b1f49"

@export var routing: Routing
@export var section: Section
@export var obstacles: Obstacles

## По видам пути; порядок видов в C# — road, trail, mountain (RoadBed.KINDS, RoadRefinement.CORRIDOR_KINDS)
@export var road: RoadKindTuning
@export var trail: RoadKindTuning
@export var mountain: RoadKindTuning

@export_group("По покрытию (порядок RoadSurface.LIST: нет, гравий, грунтовка, укатанная, камень, песок, лес, луг)")
## Выраженность форм коридора
@export var surface_gain := PackedFloat64Array()
## Характер форм: по три множителя на покрытие — длинная волна (roll), бугор (bump), перекос (wobble)
@export var character := PackedFloat64Array()
## Доля выравнивания спокойных участков
@export var level_surface := PackedFloat64Array()

@export_group("Общие")
## Радиус выравнивания спокойных участков, м
@export var level_r := 0
## Размах ритма участков (RoadBump.patch().x)
@export var rhythm_span := 0.0
## Формы включаются на столько метров от закреплённого места (вода, мост, развилка), м
@export var corridor_fade := 0.0
## Зазор между полотнами, достаточный для узкого сечения, м
@export var corridor_gap := 0.0
## Зазор для широких форм по обеим сторонам, м
@export var land_gap := 0.0
## Путь трассы без земляных работ (trail_id, earthwork 0): доля форм
@export var prepared_scale := 0.0

static var _current: RoadTuning
static var _lock := Mutex.new()


## Параметры игры (resources/road_tuning.tres), загружаются один раз; вызов идёт и из потоков.
static func current() -> RoadTuning:
	_lock.lock()
	if _current == null:
		_current = load(PATH) as RoadTuning
		if _current == null or not _current.valid():
			push_error("RoadTuning: %s не загружен или неполон — дороги не строятся с ним" % PATH)
	var t := _current
	_lock.unlock()
	return t


## Все группы и таблицы по восьми покрытиям на месте.
func valid() -> bool:
	return routing != null and routing.valid() and section != null and section.valid() and obstacles != null and obstacles.valid() \
		and road != null and trail != null and mountain != null and surface_gain.size() == 8 \
		and character.size() == 24 and level_surface.size() == 8


## Вид пути по имени (road, trail, mountain) или null.
func kind(name: String) -> RoadKindTuning:
	match name:
		"road": return road
		"trail": return trail
		"mountain": return mountain
	return null


## Отпечаток полотна и форм коридора. Старый ключ производной поверхности хранит его целиком.
func digest() -> String:
	var values := []
	for k: RoadKindTuning in [road, trail, mountain]:
		values.append(k.bed_params())
		values.append(k.corridor())
		values.append(k.level)
	values.append_array([surface_gain, character, level_surface, level_r, rhythm_span, corridor_fade, corridor_gap, land_gap, prepared_scale])
	return _digest_values(values)


func routing_cache_suffix() -> String:
	var key := _digest_values(routing.cache_values())
	return "" if key == BASELINE_ROUTING_DIGEST else "|routing=" + key


func bed_cache_suffix() -> String:
	var key := digest()
	return "" if key == BASELINE_BED_DIGEST else "|bed=" + key


func width_cache_suffix() -> String:
	var key := _digest_values(section.geometry_values())
	return "" if key == BASELINE_WIDTH_DIGEST else "|width=" + key


func clearance_cache_suffix() -> String:
	var key := _digest_values(section.clearance_values())
	return "" if key == BASELINE_CLEARANCE_DIGEST else "|clearance=" + key


func tread_cache_suffix() -> String:
	var key := _digest_values([section.tread_params()])
	return "" if key == BASELINE_TREAD_DIGEST else "|tread=" + key


static func _digest_values(values: Array) -> String:
	return var_to_bytes(values).hex_encode().sha256_text().left(12)
