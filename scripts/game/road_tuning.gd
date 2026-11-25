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
const DEFAULT_STONE_SLOPE := 0.19

@export_group("Профили")
## Правила маршрутизации A* и геометрии линии (RoadRoutingTuning).
@export var routing: Routing
## Просветы просеки и маски кромки по видам пути (RoadSectionTuning).
@export var section: Section
## Частота и расстановка камней, веток, брёвен и корней (RoadObstacleTuning).
@export var obstacles: Obstacles
## Профиль полотна и коридора для широкой дороги (road).
@export var road: RoadKindTuning
## Профиль полотна и коридора для лесной тропы (trail).
@export var trail: RoadKindTuning
## Профиль полотна и коридора для горной тропы (mountain).
@export var mountain: RoadKindTuning

@export_group("По покрытию (порядок RoadSurface.LIST: нет, гравий, грунтовка, укатанная, камень, песок, лес, луг)")
## Выраженность форм коридора
@export var surface_gain := PackedFloat64Array()
## Характер форм: по три множителя на покрытие — длинная волна (roll), бугор (bump), перекос (wobble)
@export var character := PackedFloat64Array()
## Доля выравнивания спокойных участков
@export var level_surface := PackedFloat64Array()
## Средний уклон на отрезке 16 м, при котором грунтовая тропа переходит в каменистую (RoadSurface.ROCK).
@export_range(0.0, 0.4) var stone_slope := DEFAULT_STONE_SLOPE

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
static var _by_path := {}
static var _lock := Mutex.new()


## Параметры игры (resources/road_tuning.tres), загружаются один раз; вызов идёт и из потоков.
static func current() -> RoadTuning:
	_lock.lock()
	var cached := _current
	_lock.unlock()
	if cached != null:
		return cached
	var loaded := load(PATH) as RoadTuning
	if loaded == null or not loaded.valid():
		push_error("RoadTuning: %s не загружен или неполон — дороги не строятся с ним" % PATH)
	_lock.lock()
	if _current == null:
		_current = loaded
	var t := _current
	_lock.unlock()
	return t


## Настройки дорог для типа мира (потокобезопасно, без удержания мьютекса на загрузке .tres).
static func for_template(template_id: String) -> RoadTuning:
	if template_id.is_empty() or WorldTemplate.is_default(template_id):
		return current()
	var path := WorldTemplate.road_tuning_path(template_id)
	if path.is_empty() or path == PATH:
		return current()
	_lock.lock()
	var cached: RoadTuning = _by_path.get(path)
	_lock.unlock()
	if cached != null:
		return cached
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as RoadTuning
	if loaded == null or not loaded.valid():
		push_error("RoadTuning: %s не загружен или неполон — используется %s" % [path, PATH])
		return current()
	_lock.lock()
	if not _by_path.has(path):
		_by_path[path] = loaded
	var t: RoadTuning = _by_path[path]
	_lock.unlock()
	return t


## Настройки дорог по WorldData (при null или отсутствии template_id — общий RoadTuning.current()).
static func for_world(w: Variant) -> RoadTuning:
	if w != null and w is Object:
		var tid: Variant = w.get("template_id")
		if tid is String:
			return for_template(tid)
	return current()


## Сбрасывает кэш профилей шаблонов при WorldTemplate.reload_templates() (настройки Типа 1 _current не трогаются).
static func clear_template_cache() -> void:
	_lock.lock()
	_by_path.clear()
	_lock.unlock()


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


func surface_cache_suffix() -> String:
	return "" if stone_slope == DEFAULT_STONE_SLOPE else "|surface=" + _digest_values([stone_slope])


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
