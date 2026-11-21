extends Resource
## Мягкие штрафы A* и формирование линии. Пределы прохода воды, уклонов и поворота задаёт StageTrails.

const KINDS := ["road", "trail", "mountain"]

@export_group("Поиск по видам пути")
@export var climb_costs: Dictionary
@export var turn_costs: Dictionary
@export var bend_costs: Dictionary

@export_group("Стоимость клеток")
## Цена клетки воды в поиске дороги с сооружениями.
@export var bridge_cost := 0.0
## Множитель стоимости рядом с существующим полотном.
@export var side_cost := 0.0
## Множитель стоимости прежнего коридора при поиске второго пути.
@export var avoid_cost := 0.0
@export var animal_reuse := 0.0
@export var human_reuse := 0.0

## Числа поля характера только для --roads-v2. Радиусы указаны в клетках.
@export var character_field := {
	relief_sigma = 3.0, relief_wide_sigma = 9.0,
	meander_sigma = 20.0, meander_rms = 1.0, meander_flat = 0.035, meander_slope = 0.12,
	meander_amp_road = 0.28, meander_amp = 0.35, meander_amp_mountain = 0.32, meander_amp_ride = 0.35,
	ridge_tpi = 4.0, ridge_mul = 1.36, break_tpi = 2.5, break_mul = 0.88,
	eco_radius = 4, eco_low = 0.16, eco_high = 0.84, eco_mul = 0.86,
	shore_band = 4.0, shore_mul = 1.65, mul_min = 0.7, mul_max = 1.8,
	shape_radius = 18, shape_portal = 24, shape_min = 16,
	shore_run_band = 3.75, shore_run_m = 48.0, short_turnback_m = 120.0,
}

@export_group("Линия по видам пути")
## Допуск срезания лесенки сетки в клетках.
@export var straighten: Dictionary
## Множитель допуска на локальный бугор при пробе хорды или дуги.
@export var line_relax: Dictionary


func valid() -> bool:
	for table: Dictionary in [climb_costs, turn_costs, bend_costs, straighten, line_relax]:
		if not valid_kind_values(table, KINDS):
			return false
	return (is_finite(bridge_cost) and bridge_cost >= 1.0 and is_finite(side_cost) and side_cost >= 1.0
		and is_finite(avoid_cost) and avoid_cost >= 1.0 and animal_reuse > 0.0 and animal_reuse <= 1.0
		and human_reuse > 0.0 and human_reuse <= 1.0)


func cache_values() -> Array:
	var values := [bridge_cost, side_cost, avoid_cost, animal_reuse, human_reuse]
	for kind: String in KINDS:
		values.append_array([float(climb_costs[kind]), float(turn_costs[kind]), float(bend_costs[kind]),
			float(straighten[kind]), float(line_relax[kind])])
	return values


static func valid_kind_values(table: Dictionary, kinds: Array) -> bool:
	if table.size() != kinds.size():
		return false
	for kind: String in kinds:
		var value: Variant = table.get(kind)
		if not (value is float or value is int) or not is_finite(float(value)) or value < 0.0:
			return false
	return true
