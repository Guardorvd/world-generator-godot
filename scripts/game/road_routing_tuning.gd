extends Resource
## Мягкие штрафы A* и формирование линии. Пределы прохода воды, уклонов и поворота задаёт StageTrails.

const KINDS := ["road", "trail", "mountain"]

@export_group("Поиск по видам пути")
@export var climb_costs: Dictionary
@export var turn_costs: Dictionary
@export var bend_costs: Dictionary

@export_group("Технический маршрут экспедиции")
## Пределы поиска на подъёме и спуске. Ноль сохраняет прежний профиль.
@export var expedition_grades := Vector2.ZERO
## Запасной поиск сухой связи. Компоненты: подъём, спуск, поперечный крен, вес кромки.
@export var expedition_connector_limits := Vector4.ZERO
## Предельный поперечный крен коридора A* и коротких дуг.
@export var expedition_cross := 0.0
## Вес продольного уклона на боковой кромке. Ось и поперечный крен имеют свои пределы.
@export var expedition_edge_grade := 1.0
## Доля штрафа за продольную крутизну на спусках.
@export var expedition_descent_weight := 1.0
## Вес крутизны клетки, стоимость скальной клетки, амплитуда шума стоимости.
@export var expedition_cell_cost := Vector3.ZERO
## Расчётная скорость тесных поворотов, м/с.
@export var expedition_turn_speed := 0.0
## Множитель цены поворота при большом продольном уклоне или поперечном крене.
@export var expedition_turn_terrain := 0.0
## Отступ от кромки реки (м), добавленная цена клетки и затухание у лагерей (м).
@export var expedition_shore_avoid := Vector3.ZERO

@export_group("Стоимость клеток")
## Цена клетки воды в поиске дороги с сооружениями.
@export var bridge_cost := 0.0
## Множитель стоимости рядом с существующим полотном.
@export var side_cost := 0.0
## Множитель стоимости прежнего коридора при поиске второго пути.
@export var avoid_cost := 0.0
@export var animal_reuse := 0.0
@export var human_reuse := 0.0

## Числа поля характера дорожной сети. Радиусы указаны в клетках.
@export var character_field: Dictionary
@export var network_rules: Dictionary

@export_group("Линия по видам пути")
@export var line_shape: Dictionary
## Круговые дуги и короткие переходы к существующим плечам оси V2.
@export var arc_bends_enabled: bool
@export var arc_radii_m: PackedFloat64Array
@export var arc_angle_deg: float
@export var arc_shoulder_m: float
@export var arc_fit_m: float
@export var arc_transitions_m: PackedFloat64Array
@export var axis_protection_m: float
@export var axis_min_radius_m: float
## Меандр по длинным прямым. Длины и амплитуды в метрах, уклоны в долях.
@export var axis_meander_enabled: bool
@export var axis_meander_min_m: float
@export var axis_meander_fit_m: float
@export var axis_meander_search_m: float
@export var axis_meander_min_shift_m: float
@export var axis_meander_slope: float
@export var axis_meander_slope_fade: float
@export var axis_meander_water_m: Vector2
@export var axis_meander_road: Dictionary
@export var axis_meander_trail: Dictionary
## Дополнительные поиски V2, чтобы проверить запасные финиши после основных.
@export var ride_search_reserve: float
## Перегоны для сухих связей между уже опубликованными осями, в метрах.
@export var inland_connector: Dictionary
## Допуск срезания лесенки сетки в клетках.
@export var straighten: Dictionary
## Множитель допуска на локальный бугор при пробе хорды или дуги.
@export var line_relax: Dictionary


func valid() -> bool:
	for table: Dictionary in [climb_costs, turn_costs, bend_costs, straighten, line_relax]:
		if not valid_kind_values(table, KINDS):
			return false
	return (not character_field.is_empty() and not network_rules.is_empty() and not line_shape.is_empty()
		and is_finite(bridge_cost) and bridge_cost >= 1.0 and is_finite(side_cost) and side_cost >= 1.0
		and is_finite(avoid_cost) and avoid_cost >= 1.0 and animal_reuse > 0.0 and animal_reuse <= 1.0
		and human_reuse > 0.0 and human_reuse <= 1.0)


func cache_values() -> Array:
	var values := [bridge_cost, side_cost, avoid_cost, animal_reuse, human_reuse]
	for kind: String in KINDS:
		values.append_array([float(climb_costs[kind]), float(turn_costs[kind]), float(bend_costs[kind]),
			float(straighten[kind]), float(line_relax[kind])])
	values.append_array([_ordered_values(character_field), _ordered_values(network_rules), _ordered_values(line_shape),
		ride_search_reserve, _ordered_values(inland_connector), arc_bends_enabled, arc_radii_m, arc_angle_deg,
		arc_shoulder_m, arc_fit_m, arc_transitions_m, axis_protection_m, axis_min_radius_m, axis_meander_enabled,
		axis_meander_min_m, axis_meander_fit_m, axis_meander_search_m, axis_meander_min_shift_m,
		axis_meander_slope, axis_meander_slope_fade, axis_meander_water_m,
		_ordered_values(axis_meander_road), _ordered_values(axis_meander_trail)])
	if expedition_grades.x > 0.0:
		values.append_array([expedition_grades, expedition_cross, expedition_edge_grade, expedition_descent_weight, expedition_cell_cost, expedition_turn_speed])
	if expedition_connector_limits.x > 0.0:
		values.append(expedition_connector_limits)
	if expedition_turn_terrain > 0.0 or expedition_shore_avoid.x > 0.0:
		values.append_array([expedition_turn_terrain, expedition_shore_avoid])
	return values


static func _ordered_values(table: Dictionary) -> Array:
	# Dictionary literals use StringName keys. Sort strings to order them by text.
	var keys := table.keys().map(func(key: Variant) -> String: return str(key))
	keys.sort()
	return keys.map(func(key: String) -> Array: return [key, table[key]])


static func valid_kind_values(table: Dictionary, kinds: Array) -> bool:
	if table.size() != kinds.size():
		return false
	for kind: String in kinds:
		var value: Variant = table.get(kind)
		if not (value is float or value is int) or not is_finite(float(value)) or value < 0.0:
			return false
	return true
