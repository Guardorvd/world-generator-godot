extends Resource
## Рабочая ширина, лесной просвет и видимая кромка природного полотна.

const Routing := preload("res://scripts/game/road_routing_tuning.gd")
const KINDS := ["road", "trail", "mountain", "animal"]

@export_group("Рабочая ширина")
## Полная ширина в клетках, до поправок на рельеф и сооружения.
@export var widths: Dictionary
## Сужения в долях полной ширины по видам человеческих путей.
@export var side_cut: Dictionary
@export var rock_cut: Dictionary
@export var ford_cut: Dictionary
## Расстояние перехода к ширине примыкания, м.
@export var junction_transition := 0.0

@export_group("Лесной просвет")
## Отступ от рабочей кромки в метрах по видам пути.
@export var clearance: Dictionary

@export_group("Видимая кромка")
## Положение кромки и поправка на подстилку в долях полуширины.
@export var edge := 0.0
@export var litter := 0.0
## Извив кромки и полуширина, при которой он достигает полной силы, м.
@export var wander := 0.0
@export var full_wander_half := 0.0
## Ширина перехода как доля полуширины, затем нижний и верхний пределы в метрах.
@export var fade := 0.0
@export var min_fade := 0.0
@export var max_fade := 0.0


func valid() -> bool:
	if not Routing.valid_kind_values(widths, KINDS) or not Routing.valid_kind_values(clearance, KINDS):
		return false
	for kind: String in KINDS:
		if widths[kind] <= 0.0:
			return false
	for cut: Dictionary in [side_cut, rock_cut, ford_cut]:
		if not Routing.valid_kind_values(cut, Routing.KINDS):
			return false
		for kind: String in Routing.KINDS:
			if cut[kind] >= 1.0:
				return false
	for value: float in tread_params():
		if not is_finite(value) or value < 0.0:
			return false
	return (is_finite(junction_transition) and junction_transition > 0.0
		and full_wander_half > 0.0 and fade > 0.0 and min_fade > 0.0 and max_fade >= min_fade)


func geometry_values() -> Array:
	var values := [junction_transition]
	for kind: String in KINDS:
		values.append(float(widths[kind]))
	for kind: String in Routing.KINDS:
		values.append_array([float(side_cut[kind]), float(rock_cut[kind]), float(ford_cut[kind])])
	return values


func clearance_values() -> Array:
	var values := []
	for kind: String in KINDS:
		values.append(float(clearance[kind]))
	return values


## Порядок аргументов FastGrid.RoadStamp.
func tread_params() -> PackedFloat64Array:
	return PackedFloat64Array([edge, litter, wander, full_wander_half, fade, min_fade, max_fade])


func tread_alpha(half: float, d: float, slow: float, organic: float) -> float:
	var at := half * (edge - organic * litter) + slow * wander * minf(1.0, half / full_wander_half)
	var ramp := clampf(half * fade, min_fade, max_fade)
	return clampf(0.5 + (at - d) / ramp, 0.0, 1.0)
