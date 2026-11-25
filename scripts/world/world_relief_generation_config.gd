extends Resource
## Рельеф Типа 2, который меняет высоты 4 м при генерации (план docs/RELIEF_FINE_GEOMETRY_2.md): общая маска и эрозия.
## Маска нужна и эрозии (генерация), и полю 2 м (загрузка): одно место для её чисел, в C# — ReliefMask.
## Входит в ключи кэша поверхности и растительности, пока эрозия включена (WorldTemplate.surface_cache_suffix):
## без эрозии маска на высоты 4 м не влияет, и правка её чисел мир не пересоздаёт.
const MountainDetail := preload("res://scripts/world/mountain_detail.gd")

## Порядок совпадает с ReliefMask.Parameter.
enum {
	RM_ROAD_GUARD_M, RM_ROAD_FADE_M, RM_WATER_CLEARANCE_M, RM_WATER_FADE_M, RM_PLACE_FADE_M,
	RM_ROCK_FROM, RM_ROCK_TO, RM_STEEP_FROM, RM_STEEP_TO, RM_EDGE_GUARD_M, RM_EDGE_FADE_M, RM_COUNT,
}

## Порядок совпадает с TerrainErosion.Parameter (FineRelief.Erosion.cs).
enum {
	RE_ITERATIONS, RE_TRANSITION_GRADE, RE_MAX_CHANGE_M, RE_INCISION_RATE, RE_REFERENCE_AREA_M2,
	RE_AREA_EXPONENT, RE_REPOSE_GRADE, RE_CREEP_RATE, RE_DIFFUSION, RE_CAPACITY_M3, RE_DEPOSITION_RATE, RE_EDGE_INFLOW_M,
	RE_MIN_WIDTH_M, RE_WET_LOW, RE_WET_HIGH, RE_CHANNEL_AREA_M2, RE_ROUGHNESS_M, RE_ROUGHNESS_WAVELENGTH_M, RE_GRID_FACTOR, RE_COUNT,
}

## Эрозия — последний шаг поверхности Типа 2 (ReliefErosion.run в Heightfield.finish_paths, TerrainErosion в C#).
## Сток только вырезает форму земли: видимой воды, кроме реки, не появляется.
@export var erosion_enabled := false

@export_group("Эрозия: время и пределы")
## Шаг сетки эрозии в шагах GameConfig.TILE (блоки N × N узлов 4 м, высота — среднее). 2 — сетка 8 м: сток ведёт
## форма склона, а не мелкий шум генератора, расчёт вчетверо дешевле; изменение возвращается на 4 м билинейно.
@export var grid_factor := 1
## Число итераций. Больше — глубже и длиннее лощины, дольше генерация (время растёт линейно).
@export var iterations := 0
## Уклон перехода от защищённых зон (дороги, вода, места, край плана), м/м: изменение высоты в узле не больше
## расстояния до зоны × этот уклон. Так лощина мельчает к дороге и не оставляет пьедесталов и стенок.
@export var transition_grade := 0.0
## Наибольшая глубина формы, м: эрозия снимает или насыпает не больше. Лощины в плане 1–5 м; так отроги
## и склоны не «тают», а меняется только сеть стока.
@export var max_change_m := 0.0

@export_group("Эрозия: врезание")
## Доля перепада до нижнего соседа, снимаемая за итерацию потоком с водосбором reference_area_m2 (неявная схема).
@export var incision_rate := 0.0
## Опорный водосбор, м²: на нём врезание равно incision_rate; меньший водосбор режет слабее по степени area_exponent.
@export var reference_area_m2 := 0.0
## Водосбор головы лощины, м²: выше по склону поток не врезается (там склон ведут диффузия и сползание).
@export var channel_area_m2 := 0.0
## Показатель степени водосбора в законе мощности потока (m), обычно 0,4–0,6.
@export var area_exponent := 0.5
## Наименьшая ширина лощины на половине глубины, м; узкое — дело поля 2 м. Не меньше нескольких шагов сетки 4 м.
@export var min_width_m := 0.0
## Шероховатость поверхности стока, м (±): только направляет сток, высоты не меняет. Из неё на гладком склоне
## рождается сеть лощин вместо равномерного сноса.
@export var roughness_m := 0.0
## Шаг шероховатости, м: примерно расстояние между соседними головами лощин.
@export var roughness_wavelength_m := 0.0
## Условный приток с края плана: длина водосбора за краем, м. Без него верх стен у края остаётся без лощин.
@export var edge_inflow_m := 0.0

@export_group("Эрозия: склоны и наносы")
## Угол устойчивости почвы, м/м: борта лощин сползают до него. Исходные более крутые стены генератора не трогаются.
## Не круче MountainDetail.DETAIL_STEEP_FROM — уклона, с которого склон считается крутым для езды и детали.
@export var repose_grade := 0.0
## Доля избытка над углом устойчивости, сползающая за итерацию, 0..1.
@export var creep_rate := 0.0
## Диффузия склона за итерацию (доля разницы с соседями), 0..1: скругляет бровки, верх склона выпуклый.
@export var diffusion := 0.0
## Ёмкость потока, м³ за итерацию: столько несёт поток с водосбором reference_area_m2 на уклоне 1. Избыток оседает.
@export var capacity_m3 := 0.0
## Доля избытка наносов, оседающая в клетке за итерацию, 0..1: выносы у подножий и ровные днища.
@export var deposition_rate := 0.0

@export_group("Эрозия: влажность")
## Индекс влажности ln(a / tg β) (a — водосбор на метр ширины склона, м), который считается сухим (0) и сырым (1).
@export var wet_index := Vector2(0.0, 1.0)
## Насколько влажность стока W сдвигает влажность мира для выбора леса: moist + gain × (W − 0,5).
@export var wet_moist_gain := 0.0

@export_group("Маска")
## Неподвижная полоса вокруг дорожных патчей, м.
@export var road_guard_m := 0.0
## Выход из защитной полосы дороги, м.
@export var road_fade_m := 0.0
## Минимальная высота суши над соседним уровнем воды, м.
@export var water_clearance_m := 0.0
## Переход от защищённого берега к изменяемой земле, м.
@export var water_fade_m := 0.0
## Переход от площадки или сооружения к изменяемой земле, м.
@export var place_fade_m := 0.0
## Плавное затухание по доле обнажённой породы (RockRelief.field_of), доли.
@export var rock_fade := Vector2(1.0, 1.0)
## Уклоны, при которых начинается и заканчивается затухание, м/м.
@export var slope_fade := Vector2(MountainDetail.DETAIL_STEEP_FROM, MountainDetail.DETAIL_LIMIT)
## Ширина неподвижного края плана (стык с OuterLand), м.
@export var edge_guard_m := 0.0
## Переход между неподвижным краем и изменяемой землёй, м.
@export var edge_fade_m := 0.0


func mask_params() -> PackedFloat64Array:
	return PackedFloat64Array([
		road_guard_m, road_fade_m, water_clearance_m, water_fade_m, place_fade_m,
		rock_fade.x, rock_fade.y, slope_fade.x, slope_fade.y, edge_guard_m, edge_fade_m,
	])


func erosion_params() -> PackedFloat64Array:
	return PackedFloat64Array([
		iterations, transition_grade, max_change_m, incision_rate, reference_area_m2,
		area_exponent, repose_grade, creep_rate, diffusion, capacity_m3, deposition_rate, edge_inflow_m,
		min_width_m, wet_index.x, wet_index.y, channel_area_m2,
		roughness_m, roughness_wavelength_m, grid_factor,
	])


func valid() -> bool:
	return road_guard_m >= 0.0 and water_clearance_m >= 0.0 and edge_guard_m >= 0.0


func valid_erosion() -> bool:
	return iterations > 0 and transition_grade > 0.0 and max_change_m > 0.0 \
		and incision_rate > 0.0 and reference_area_m2 > 0.0 and area_exponent > 0.0 \
		and repose_grade > 0.0 and repose_grade <= MountainDetail.DETAIL_STEEP_FROM \
		and creep_rate >= 0.0 and creep_rate <= 1.0 and diffusion >= 0.0 and diffusion <= 1.0 \
		and capacity_m3 >= 0.0 and deposition_rate >= 0.0 and deposition_rate <= 1.0 and edge_inflow_m >= 0.0 \
		and min_width_m >= 0.0 and wet_index.y > wet_index.x \
		and channel_area_m2 >= 0.0 and channel_area_m2 < reference_area_m2 \
		and roughness_m >= 0.0 and roughness_wavelength_m >= 0.0 and grid_factor >= 1


## Хеш для ключа кэша: всё, что меняет высоты 4 м. Пусто, пока эрозия выключена (высоты не меняются).
func cache_digest() -> String:
	if not erosion_enabled:
		return ""
	return var_to_str([erosion_enabled, Array(mask_params()), Array(erosion_params()), wet_moist_gain]).sha256_text().left(16)
