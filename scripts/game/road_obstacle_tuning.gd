extends Resource
## Частота и состав природных препятствий. Защитные зоны и коллизии задаёт RoadObstacles.

const Routing := preload("res://scripts/game/road_routing_tuning.gd")

@export_group("Частота")
@export var kind_scale: Dictionary
@export_range(0.0, 1.0, 0.001) var probability_ceiling := 0.0

@export_group("Ветки")
@export var branch_cover := 0.0
@export var branch_tree := 0.0
## Множитель на материал в порядке RoadSurface.LIST.
@export var branch_surface := PackedFloat64Array()
@export var branch_rhythm_min := 0.0
@export var branch_rhythm_max := 0.0

@export_group("Камни и валуны")
@export var stone_base := 0.0
@export var stone_rock := 0.0
@export var stone_scree := 0.0
@export var stone_grade := 0.0
@export var stone_on_stone := 0.0
@export var stone_on_sand := 0.0
@export var boulder_rock := 0.0
@export var boulder_scree := 0.0

@export_group("Брёвна")
@export var log_cover := 0.0
@export var log_tree := 0.0
@export var log_on_road := 0.0

@export_group("Корни")
## Вероятность у подходящего ствола до поправок на расстояние и тип пути.
@export_range(0.0, 1.0, 0.001) var root_chance := 0.0
@export var root_on_road := 0.0
@export var root_surface := PackedFloat64Array()


func valid() -> bool:
	if not Routing.valid_kind_values(kind_scale, Routing.KINDS) or branch_surface.size() != 8 or root_surface.size() != 8:
		return false
	var weights := PackedFloat64Array([branch_cover, branch_tree, branch_rhythm_min, branch_rhythm_max,
		stone_base, stone_rock, stone_scree, stone_grade, stone_on_stone, stone_on_sand, boulder_rock, boulder_scree,
		log_cover, log_tree, log_on_road, root_on_road])
	weights.append_array(branch_surface)
	weights.append_array(root_surface)
	for value: float in weights:
		if not is_finite(value) or value < 0.0:
			return false
	return (probability_ceiling >= 0.0 and probability_ceiling <= 1.0 and root_chance >= 0.0 and root_chance <= 1.0
		and branch_rhythm_min <= branch_rhythm_max)
