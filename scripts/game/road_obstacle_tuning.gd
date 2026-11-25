extends Resource
## Частота и состав природных препятствий. Защитные зоны и коллизии задаёт RoadObstacles.

const Routing := preload("res://scripts/game/road_routing_tuning.gd")

@export_group("Частота")
## Множитель общей плотности препятствий по видам пути ("road", "trail", "mountain").
@export var kind_scale: Dictionary
## Верхний предел итоговой вероятности появления препятствия на 4-метровом участке.
@export_range(0.0, 1.0, 0.001) var probability_ceiling := 0.0

@export_group("Ветки")
## Вклад сомкнутости лесного полога (forest.r) в частоту мелких веток на тропе.
@export var branch_cover := 0.0
## Вклад близости кроны дерева в частоту веток на тропе.
@export var branch_tree := 0.0
## Множитель частоты веток на материал покрытия в порядке RoadSurface.LIST.
@export var branch_surface := PackedFloat64Array()
## Минимальный множитель плотностного ритма веток на 40-метровых отрезках.
@export var branch_rhythm_min := 0.0
## Максимальный множитель плотностного ритма веток на 40-метровых отрезках.
@export var branch_rhythm_max := 0.0

@export_group("Камни и валуны")
## Базовый вес рассыпанных камней и каменистого щебня на грунтовых покрытиях.
@export var stone_base := 0.0
## Дополнительный вес камней на каменистых/скальных участках полотна.
@export var stone_rock := 0.0
## Дополнительный вес камней в полосе открытых осыпей (forest.a).
@export var stone_scree := 0.0
## Прирост частоты камней в зависимости от продольного уклона тропы.
@export var stone_grade := 0.0
## Дополнительный шанс уложить обломки прямо на каменистом полотне (RoadSurface.ROCK).
@export var stone_on_stone := 0.0
## Дополнительный шанс мелких камней и гальки на песчаных участках (RoadSurface.SAND).
@export var stone_on_sand := 0.0
## Минимальное боковое смещение мелкого камня от оси в долях полуширины тропы.
@export var stone_lateral_min := 0.25
## Разброс бокового смещения мелкого камня от оси в долях полуширины тропы.
@export var stone_lateral_span := 0.45
## Вес краевых валунов на каменистой тропе (RoadSurface.ROCK).
@export var boulder_rock := 0.0
## Вес краевых валунов на открытых каменистых склонах и осыпях.
@export var boulder_scree := 0.0
## Минимальный отступ центра краевого валуна от оси в долях полуширины тропы.
@export var boulder_lateral_min := 0.45
## Разброс отступа центра краевого валуна в долях полуширины тропы.
@export var boulder_lateral_span := 0.25
## Минимальный заход краевого валуна поперёк полотна (при поперечном крене), м.
@export var boulder_cross_min := 0.1
## Максимальный заход краевого валуна поперёк полотна (при поперечном крене), м.
@export var boulder_cross_max := 0.5

@export_group("Брёвна")
## Вклад сомкнутости леса в вероятность поваленного бревна на тропе.
@export var log_cover := 0.0
## Вклад близких крупных стволов деревьев в вероятность поваленного бревна.
@export var log_tree := 0.0
## Доля полотна при укладке бревна на проезжую часть вместо бровки.
@export var log_on_road := 0.0
## Вероятность укладки бревна поперёк колеи (при широких тропах/низком покрытии) вместо сдвига к краю.
@export_range(0.0, 1.0, 0.01) var log_across_chance := 0.15
## Базовый отступ конца краевого бревна от половины ширины тропы, м.
@export var log_edge_offset := 0.5
## Случайное углубление конца краевого бревна внутрь полосы к центру, м.
@export var log_edge_inset := 0.6

@export_group("Корни")
## Вероятность у подходящего ствола до поправок на расстояние и тип пути.
@export_range(0.0, 1.0, 0.001) var root_chance := 0.0
## Шанс пересечь колею крупным корнем; ниже этого порога корень выходит только к бровке.
@export var root_on_road := 0.0
## Множитель появления корней по материалам покрытия в порядке RoadSurface.LIST.
@export var root_surface := PackedFloat64Array()
## Максимальный зазор от кромки полотна до ствола, с которого корни выходят на тропу, м.
@export var root_reach := 3.5
## Минимальный масштаб взрослого дерева, с которого у него формируются проездные корни.
@export var root_tree_min := 0.85
## Вероятность двойного веера корней от одного притропного дерева.
@export_range(0.0, 1.0, 0.01) var root_pair_chance := 0.45
## Вероятность тройного веера корней от одного притропного дерева.
@export_range(0.0, 1.0, 0.01) var root_triple_chance := 0.12


func valid() -> bool:
	if not Routing.valid_kind_values(kind_scale, Routing.KINDS) or branch_surface.size() != 8 or root_surface.size() != 8:
		return false
	var weights := PackedFloat64Array([branch_cover, branch_tree, branch_rhythm_min, branch_rhythm_max,
		stone_base, stone_rock, stone_scree, stone_grade, stone_on_stone, stone_on_sand,
		stone_lateral_min, stone_lateral_span, boulder_rock, boulder_scree,
		boulder_lateral_min, boulder_lateral_span, boulder_cross_min, boulder_cross_max,
		log_cover, log_tree, log_on_road, log_edge_offset, log_edge_inset,
		root_on_road, root_reach, root_tree_min])
	weights.append_array(branch_surface)
	weights.append_array(root_surface)
	for value: float in weights:
		if not is_finite(value) or value < 0.0:
			return false
	for chance: float in [probability_ceiling, root_chance, log_across_chance, root_pair_chance, root_triple_chance]:
		if not is_finite(chance) or chance < 0.0 or chance > 1.0:
			return false
	return branch_rhythm_min <= branch_rhythm_max and root_reach > 0.4 and boulder_cross_min < boulder_cross_max
