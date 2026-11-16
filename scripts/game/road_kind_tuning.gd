class_name RoadKindTuning
extends Resource
## Числа дорожного полотна и форм коридора одного вида пути (дорога, тропа, горная тропа) — часть RoadTuning
## (resources/road_tuning.tres, docs/ROADS_CSHARP.md). Считает их только C#: правка здесь меняет мир, её видно в
## road_look / road_relief_test без сборки; road_golden после неё расходится — эталон переснимается осознанно.

@export_group("Полотно (RoadBed)")
## Сколько за краем полотна ещё ровно, м
@export var flat := 0.6
## Где за краем изменение сходит на нет, м
@export var shoulder := 3.0
## Полуокно сглаживания профиля вдоль линии, м
@export var window := 14.0
## Доля местной неровности, которая остаётся
@export var bed_keep := 0.52
## Наибольший срез или подсыпка профиля, м
@export var cut := 1.2
## То же для точки рельефа сбоку от линии (поперечный уклон), м
@export var side := 1.6

@export_group("Формы коридора (docs/ROAD_RELIEF.md)")
## Пологие волны (~30 м), м
@export var roll := 0.6
## Бугры и впадины (~10 м), м
@export var bump := 0.26
## Перекос от шума у края, м
@export var tilt := 0.11
## Доля природного поперечного склона
@export var tilt_keep := 0.3
## Предел перекоса, доля полуширины
@export var tilt_max := 0.07
## Выпуклость (+) или корыто (−), м
@export var dish := 0.03
## Разброс выпуклости, м
@export var dish_var := 0.1
## Продавленные места, м
@export var hollow := 0.2
## Канава у края, м
@export var ditch := 0.28
## Вал у края, м
@export var lip := 0.09
## Предел добавленного продольного уклона
@export var grade := 0.1
## Доля выравнивания спокойных участков (умножается на долю покрытия RoadTuning.level_surface)
@export var level := 0.75


## Числа полотна для C# (FastGrid.RoadBedRefine): flat, shoulder, window, keep, cut, side.
func bed_params() -> PackedFloat64Array:
	return PackedFloat64Array([flat, shoulder, window, bed_keep, cut, side])


## Формы коридора с ключами Roads.CorridorParams.
func corridor() -> Dictionary:
	return {"roll": roll, "bump": bump, "tilt": tilt, "keep": tilt_keep, "max": tilt_max, "dish": dish, "var": dish_var,
		"hollow": hollow, "ditch": ditch, "lip": lip, "grade": grade}
