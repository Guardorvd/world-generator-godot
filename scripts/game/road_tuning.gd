class_name RoadTuning
extends Resource
## Файл параметров дорог (с 16.11.2026, docs/ROADS_CSHARP.md): числа полотна RoadBed и форм коридора RoadRefinement
## в одном месте, resources/road_tuning.tres. Алгоритм — в C# (FastGrid.RoadBedRefine, RoadFitNetwork), числа — здесь;
## меняются в инспекторе без правки кода и без dotnet build. Хеш значений входит в ключ кэша поверхности
## (WorldCache.artifact_key), поэтому после правки готовая поверхность мира пересобирается сама.
## Пределы и зазоры, на которые опираются другие системы (REACH, PIN, SHORE, WATER_GAP, BENCH_LIMIT), остаются в коде.

const PATH := "res://resources/road_tuning.tres"

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


## Все три вида и таблицы по восьми покрытиям на месте.
func valid() -> bool:
	return road != null and trail != null and mountain != null and surface_gain.size() == 8 \
		and character.size() == 24 and level_surface.size() == 8


## Вид пути по имени (road, trail, mountain) или null.
func kind(name: String) -> RoadKindTuning:
	match name:
		"road": return road
		"trail": return trail
		"mountain": return mountain
	return null


## Короткий хеш всех значений для ключа кэша: меняется при любой правке чисел, а не формата файла.
func digest() -> String:
	var values := []
	for k: RoadKindTuning in [road, trail, mountain]:
		values.append(k.bed_params())
		values.append(k.corridor())
		values.append(k.level)
	values.append_array([surface_gain, character, level_surface, level_r, rhythm_span, corridor_fade, corridor_gap, land_gap, prepared_scale])
	return var_to_bytes(values).hex_encode().sha256_text().left(12)
