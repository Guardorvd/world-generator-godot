class_name RoadKindTuning
extends Resource
## Числа дорожного полотна и форм коридора одного вида пути (дорога, тропа, горная тропа) — часть RoadTuning
## (resources/road_tuning.tres, docs/ROADS_CSHARP.md). Считает их только C#: правка здесь меняет мир, её видно в
## road_look / road_relief_test без сборки; road_golden после неё расходится — эталон переснимается осознанно.
## Значения по умолчанию нулевые нарочно: редактор не пишет в .tres значение, равное умолчанию, и правка умолчания в коде
## тихо меняла бы числа в файле. Настоящие числа — только в resources/road_tuning.tres.

@export_group("Полотно (RoadBed)")
## Сколько за краем полотна ещё ровно, м
@export var flat := 0.0
## Где за краем изменение сходит на нет, м
@export var shoulder := 0.0
## Полуокно сглаживания профиля вдоль линии, м
@export var window := 0.0
## Доля местной неровности, которая остаётся
@export var bed_keep := 0.0
## Наибольший срез или подсыпка профиля, м
@export var cut := 0.0
## То же для точки рельефа сбоку от линии (поперечный уклон), м
@export var side := 0.0

@export_group("Формы коридора (docs/ROAD_RELIEF.md)")
## Пологие волны (~30 м), м
@export var roll := 0.0
## Бугры и впадины (~10 м), м
@export var bump := 0.0
## Перекос от шума у края, м
@export var tilt := 0.0
## Доля природного поперечного склона
@export var tilt_keep := 0.0
## Предел перекоса, доля полуширины
@export var tilt_max := 0.0
## Выпуклость (+) или корыто (−), м
@export var dish := 0.0
## Разброс выпуклости, м
@export var dish_var := 0.0
## Продавленные места, м
@export var hollow := 0.0
## Канава у края, м
@export var ditch := 0.0
## Вал у края, м
@export var lip := 0.0
## Предел добавленного продольного уклона
@export var grade := 0.0
## Доля выравнивания спокойных участков (умножается на долю покрытия RoadTuning.level_surface)
@export var level := 0.0
## Доля выполаживания полки на косогоре (1.0 — полная полка Типа 1, 0.0 — естественный косогор)
@export var bench_scale := 1.0
## Сила контруклона в поворотах (поперечный уклон на 1/м кривизны; 0 — без контруклона)
@export var turn_bank := 0.0


## Числа полотна для C# (FastGrid.RoadBedRefine): flat, shoulder, window, keep, cut, side.
func bed_params() -> PackedFloat64Array:
	return PackedFloat64Array([flat, shoulder, window, bed_keep, cut, side])


@export_group("Метровая сетка")
## Доля второго выравнивания оси относительно прежней подгонки RoadFitNetwork.
@export var profile_fit := 1.0
## Доля боковой подгонки метрической сетки.
@export var cross_fit := 1.0
## Доля защиты природного поперечного уклона от добавленного наклона.
@export var natural_cross := 0.0
## Высота выборочных скальных бровок и промоин, м.
@export var technical_relief := 0.0
## Максимальная местная подрезка или подсыпка опорной полосы, м. 0 — обычное полотно.
@export var support_cut := 0.0
## Доля направленного предела уклона в тесном апексе после подгонки профиля.
@export var turn_grade_scale := 1.0


## Формы коридора с ключами Roads.CorridorParams.
func corridor() -> Dictionary:
	var out := {"roll": roll, "bump": bump, "tilt": tilt, "keep": tilt_keep, "max": tilt_max, "dish": dish, "var": dish_var,
		"hollow": hollow, "ditch": ditch, "lip": lip, "grade": grade}
	if not is_equal_approx(bench_scale, 1.0):
		out["bench_scale"] = bench_scale
	if not is_zero_approx(turn_bank):
		out["turn_bank"] = turn_bank
	if profile_fit != 1.0 or cross_fit != 1.0:
		out["profile_fit"] = profile_fit
		out["cross_fit"] = cross_fit
	if natural_cross != 0.0:
		out["natural_cross"] = natural_cross
	if technical_relief > 0.0:
		out["technical_relief"] = technical_relief
	if support_cut > 0.0:
		out["support_cut"] = support_cut
		out["turn_grade_scale"] = turn_grade_scale
	return out
