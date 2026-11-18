class_name FishingLayout
extends RefCounted
## Причал рыбацкого домика (StageSites, вид "fishing"): настил в воду от двери домика и лодка у его края.
## Как и у TowerLayout, одна геометрия на модель (FishingModels) и на физику (Heightfield.add_site_decks): настил
## идёт по ровной отметке над водой, поэтому длина и высота считаются по рельефу и воде (measure) и одинаковы для обоих.
## Местные координаты: начало — центр домика, дверь и причал смотрят в +z; в мир переводятся поворотом Basis(UP, a).

const START := 1.9         # от центра домика до начала настила, м (до порога)
const HALF := 0.8          # полуширина настила, м
const OVER_WATER := 5.0    # сколько настила уходит в воду от кромки, м
const DECK_ABOVE := 0.4    # настил выше воды, м
const MAX_LEN := 16.0
const BOAT_SIDE := 1.5     # лодка стоит у правого борта настила, м от оси
const BOAT_BACK := 2.2     # и не у самого конца, м до конца настила


## Длина настила и отметки относительно центра домика origin (с высотой земли в y):
## {len, dy — верх настила, water — уровень воды}. Вода ищется вдоль +z до глубины больше 0,3 м.
static func measure(heights: Heightfield, origin: Vector3, yaw: float) -> Dictionary:
	var basis := Basis(Vector3.UP, yaw)
	var d := START
	while d < MAX_LEN + START:
		var p := origin + basis * Vector3(0.0, 0.0, d)
		var depth := heights.depth_at(p.x, p.z)
		if depth > 0.3:
			var water := heights.ground_at(p.x, p.z) + depth - origin.y
			return {len = minf(d - START + OVER_WATER, MAX_LEN), dy = water + DECK_ABOVE, water = water}
		d += 0.5
	return {len = 8.0, dy = -0.1, water = -0.5} # воды у домика нет: короткий настил на суше


## Настил как сооружение для Heightfield: {key, half, ax, az, ay, bx, bz, by, rails}; origin — центр домика (y — низ)
static func structure(origin: Vector3, yaw: float, key: String, m: Dictionary) -> Dictionary:
	var basis := Basis(Vector3.UP, yaw)
	var a := origin + basis * Vector3(0.0, m.dy, START)
	var b := origin + basis * Vector3(0.0, m.dy, START + m.len)
	return {key = key + ":pier", half = HALF, ax = a.x, az = a.z, ay = a.y, bx = b.x, bz = b.z, by = b.y, rails = false}
