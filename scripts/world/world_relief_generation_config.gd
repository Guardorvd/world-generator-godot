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

## Эрозия — последний шаг поверхности Типа 2 (ReliefErosion.run в Heightfield.finish_paths). Алгоритма до этапа 3 плана нет:
## шаг пустой, высоты и кэш прежние.
@export var erosion_enabled := false

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


func valid() -> bool:
	return road_guard_m >= 0.0 and water_clearance_m >= 0.0 and edge_guard_m >= 0.0


## Хеш для ключа кэша: всё, что меняет высоты 4 м. Пусто, пока эрозия выключена (высоты не меняются).
func cache_digest() -> String:
	if not erosion_enabled:
		return ""
	return var_to_str([erosion_enabled, Array(mask_params())]).sha256_text().left(16)
