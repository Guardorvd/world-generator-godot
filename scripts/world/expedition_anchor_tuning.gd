extends Resource
## Геометрия проходов через отроги и отбор технических якорей.

@export_group("Геометрия отрога")
## Пары: сдвиг вдоль долины в долях полудлины отрога, отступ от реки в долях вылета отрога.
@export var entry := PackedFloat64Array()
@export var exit := PackedFloat64Array()
@export var lower_exit := PackedFloat64Array()
## Пары: сдвиг вдоль долины в долях полудлины отрога, поправка к глубине траверса в клетках.
@export var turn_approach := PackedFloat64Array()
@export var turn_apex := PackedFloat64Array()
@export var turn_return := PackedFloat64Array()
## Сдвиг по длине и доля, на которую нижний траверс ближе к реке.
@export var lower_traverse := PackedFloat64Array()
## Отступ площадки от кромки реки и от начала стены (клетки).
@export var clearances := PackedFloat64Array()
## Минимальный угол между подходом и выходом, чтобы принять обратное колено, в градусах.
@export var turn_min_deg := 0.0
## Колено должно вернуться минимум на столько рядов плана вверх по долине.
@export var backtrack_rows := 0.0

@export_group("Поиск площадки")
## Полуразмер окна поиска по x и y в клетках.
@export var search_half := Vector2i.ZERO
## Минимальный просвет до предыдущей точки той же связки, в метрах.
@export var passage_spacing_m := 0.0
## Радиусы выборки топографического индекса и оценки площадки апекса, в клетках.
@export var tpi_radius := 1
@export var apex_radius := 1
## Штраф за уклон клетки и за уклон от предыдущей точки.
@export var passage_grade_weights := PackedFloat64Array()
## Штрафы за модуль топографического индекса на траверсе и в апексе.
@export var passage_tpi_weights := PackedFloat64Array()
## Штрафы за удаление кандидата по x и y от центра окна.
@export var passage_position_weights := PackedFloat64Array()
## Штраф за крутой край площадки апекса.
@export var apex_slope_weight := 0.0

@export_group("Оценка одиночного технического якоря")
## Диапазоны нормализации уклона, топографического индекса и поперечной выпуклости.
@export var terrace_slope_band := PackedFloat64Array()
@export var terrace_tpi_band_m := PackedFloat64Array()
@export var terrace_shoulder_band_m := PackedFloat64Array()
## Веса уклона, индекса и выпуклости соответственно.
@export var terrace_terrain_weights := PackedFloat64Array()
## Штрафы за продольное смещение и за смещение поперёк долины.
@export var terrace_position_weights := PackedFloat64Array()


func has_passage_shape() -> bool:
	for pair: PackedFloat64Array in [entry, exit, lower_exit, turn_approach, turn_apex, turn_return,
			lower_traverse, clearances, passage_grade_weights, passage_tpi_weights, passage_position_weights]:
		if pair.size() != 2:
			return false
	return true


func has_terrace_shape() -> bool:
	return terrace_slope_band.size() == 2 and terrace_tpi_band_m.size() == 2 \
		and terrace_shoulder_band_m.size() == 2 and terrace_terrain_weights.size() == 3 \
		and terrace_position_weights.size() == 2


func cache_values() -> Array:
	return [entry, exit, lower_exit, turn_approach, turn_apex, turn_return, lower_traverse, clearances, turn_min_deg,
		backtrack_rows, search_half, passage_spacing_m, tpi_radius, apex_radius, passage_grade_weights,
		passage_tpi_weights, passage_position_weights, apex_slope_weight, terrace_slope_band, terrace_tpi_band_m,
		terrace_shoulder_band_m, terrace_terrain_weights, terrace_position_weights]
