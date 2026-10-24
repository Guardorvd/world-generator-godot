class_name Biomes
extends RefCounted
## Справочники: биомы и виды объектов (деревья, кусты, камни). Копия js/data/biomes.js.
## Все свойства биома собраны в одной записи: чтобы добавить биом, достаточно дописать его сюда,
## в правила выбора биома (scripts/world/stages/stage_climate.gd) и, при желании, в цвета карты.

# Биомы (индекс в LIST)
const DEEP := 0
const OCEAN := 1
const SHALLOW := 2
const LAKE := 3
const BEACH := 4
const DESERT := 5
const SAVANNA := 6
const STEPPE := 7
const GRASS := 8
const FOREST := 9
const JUNGLE := 10
const SWAMP := 11
const TAIGA := 12
const TUNDRA := 13
const SNOW := 14
const ROCK := 15
const PEAK := 16
const STONESHORE := 17

# Виды объектов растительности
const T_OAK := 0
const T_PINE := 1
const T_PALM := 2
const T_JUNGLE := 3
const T_BUSH := 4
const T_CACTUS := 5
const T_ROCK := 6
const T_SNOWPINE := 7
const T_BIRCH := 8
const T_DEAD := 9
const T_REED := 10
const T_ACACIA := 11
const T_RELICT_OAK := 12
const T_RELICT_PINE := 13

# Приблизительный радиус кроны/объекта в клетках (клетка 4 м), по Models.
# Общий для размещения и оценки полога; масштаб экземпляра применяется отдельно.
const CROWN_RADIUS := [0.70, 0.475, 0.65, 0.95, 0.325, 0.20, 0.43, 0.475, 0.35, 0.20, 0.125, 0.80, 2.65, 2.5]
# Поля записи биома (индекс в массиве = номер биома):
#   name       — название для интерфейса
#   color      — цвет на карте и в текстуре рельефа, [r, g, b]
#   water      — водный биом (по нему нельзя идти, там не растут деревья)
#   speed      — множитель скорости игрока
#   cost       — стоимость прохода при прокладке троп (по умолчанию 2)
#   trees      — плотность растительности, kinds — какие объекты растут
#   habit      — привлекательность для поселений (нет поля — поселений не бывает)
#   animals    — отсюда начинаются звериные тропы к водопою
#   flowers / pebbles — микродетали на карте: цветы или галька
#   grass      — трава у ног в 3D: dens — пучков на клетку, tint — цвет [r, g, b] в долях единицы (поля записи, а не отдельные ключи)
const LIST: Array[Dictionary] = [
	{name = "Глубокий океан", color = [18, 44, 92], water = true, speed = 0.0},
	{name = "Океан", color = [28, 70, 128], water = true, speed = 0.0},
	{name = "Мелководье", color = [52, 116, 168], water = true, speed = 0.45},
	{name = "Озеро", color = [48, 104, 156], water = true, speed = 0.0},
	{name = "Пляж", color = [222, 206, 152], speed = 0.9, cost = 1.2, trees = 0.03, kinds = [T_PALM],
		habit = 0.5, grass = {dens = 0.8, tint = [0.6, 0.62, 0.35]}},
	{name = "Пустыня", color = [224, 192, 124], speed = 0.8, cost = 1.6, trees = 0.025, kinds = [T_CACTUS, T_CACTUS, T_ROCK, T_BUSH],
		habit = 0.15, pebbles = true},
	{name = "Саванна", color = [190, 178, 94], speed = 1.0, cost = 1.1, trees = 0.07, kinds = [T_ACACIA, T_ACACIA, T_BUSH],
		habit = 0.6, animals = true, flowers = true, grass = {dens = 7.0, tint = [0.72, 0.68, 0.33]}},
	{name = "Степь", color = [170, 168, 100], speed = 1.0, cost = 1.0, trees = 0.025, kinds = [T_BUSH, T_BUSH, T_ROCK],
		habit = 0.7, animals = true, flowers = true, grass = {dens = 6.0, tint = [0.62, 0.64, 0.36]}},
	{name = "Луга", color = [112, 164, 72], speed = 1.0, cost = 1.0, trees = 0.06, kinds = [T_OAK, T_BIRCH, T_BUSH, T_BUSH],
		habit = 1.0, animals = true, flowers = true, grass = {dens = 9.0, tint = [0.42, 0.66, 0.27]}},
	{name = "Лиственный лес", color = [72, 128, 58], speed = 0.75, cost = 2.2, trees = 0.8, kinds = [T_OAK, T_OAK, T_BIRCH, T_BUSH, T_PINE],
		habit = 0.7, animals = true, flowers = true, grass = {dens = 5.0, tint = [0.3, 0.52, 0.22]}},
	{name = "Джунгли", color = [42, 112, 52], speed = 0.6, cost = 3.0, trees = 1.0, kinds = [T_JUNGLE, T_JUNGLE, T_JUNGLE, T_PALM, T_BUSH],
		habit = 0.3, animals = true, grass = {dens = 7.0, tint = [0.2, 0.48, 0.2]}},
	{name = "Болото", color = [82, 100, 62], speed = 0.5, cost = 4.0, trees = 0.35, kinds = [T_REED, T_REED, T_DEAD, T_BUSH],
		grass = {dens = 7.0, tint = [0.36, 0.44, 0.24]}},
	{name = "Тайга", color = [60, 96, 70], speed = 0.75, cost = 2.2, trees = 0.75, kinds = [T_PINE, T_PINE, T_PINE, T_BIRCH],
		habit = 0.5, animals = true, grass = {dens = 4.0, tint = [0.3, 0.44, 0.28]}},
	{name = "Тундра", color = [142, 150, 122], speed = 0.85, cost = 1.4, trees = 0.04, kinds = [T_BUSH, T_ROCK],
		habit = 0.25, animals = true, pebbles = true, grass = {dens = 3.0, tint = [0.55, 0.58, 0.45]}},
	{name = "Снега", color = [232, 238, 244], speed = 0.6, cost = 2.5, trees = 0.05, kinds = [T_SNOWPINE, T_SNOWPINE, T_ROCK]},
	{name = "Скалы", color = [124, 116, 108], speed = 0.55, cost = 3.5, trees = 0.06, kinds = [T_ROCK, T_ROCK, T_PINE],
		pebbles = true},
	{name = "Заснеженные вершины", color = [244, 247, 252], speed = 0.4, cost = 6.0, trees = 0.02, kinds = [T_ROCK],
		pebbles = true},
	{name = "Каменистый берег", color = [140, 136, 126], speed = 0.8, cost = 1.6, trees = 0.06, kinds = [T_ROCK],
		habit = 0.3, pebbles = true},
]


static func is_tree(kind: int) -> bool:
	return kind == T_OAK or kind == T_PINE or kind == T_PALM or kind == T_JUNGLE or kind == T_SNOWPINE or kind == T_BIRCH or kind == T_ACACIA or is_relict(kind)


static func is_relict(kind: int) -> bool:
	return kind == T_RELICT_OAK or kind == T_RELICT_PINE


static func is_conifer(kind: int) -> bool:
	return kind == T_PINE or kind == T_SNOWPINE or kind == T_RELICT_PINE


## Ground clearance differs from the high canopy: paths may pass under the vault.
static func ground_radius(kind: int) -> float:
	if kind == T_RELICT_OAK: return 0.55
	if kind == T_RELICT_PINE: return 0.5
	return CROWN_RADIUS[kind]


static func base_tree(kind: int) -> int:
	if kind == T_RELICT_OAK: return T_OAK
	if kind == T_RELICT_PINE: return T_PINE
	return kind
