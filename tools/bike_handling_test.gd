extends SceneTree
## 5.2: контролируемые профили рельефа и манёвры через полный BikeRide.step.

class TestWorld extends WorldData:
	var surface := RoadSurface.PACKED
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = surface}

class TestGround extends Heightfield:
	var profile: Callable = func(_d: float) -> float: return 0.0
	func _init(w: WorldData) -> void:
		super(w, false)
	func ground_at(_x: float, z: float, _raw := false) -> float:
		return 100.0 + float(profile.call(-z))
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true

const DT := 1.0 / 60.0
var fails := 0
var w := TestWorld.new()
var ground := TestGround.new(w)
var p := PlayerState.new()

func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok:
		fails += 1

func bike(pace := 8.0) -> BikeRide:
	var b := BikeRide.new()
	b.y = ground.ground_at(0.0, 0.0)
	b.speed = pace
	b.riding = true
	return b

func tick(b: BikeRide, turn := 0.0, hop := false, throttle := 0.0, dt := DT) -> void:
	b.step(p, throttle, turn, false, hop, dt, w, ground)

## Сколько раз велосипед оторвался от земли за ticks тактов под педалями на нынешнем профиле
func takeoffs(pace: float, ticks: int) -> int:
	var b := bike(pace)
	var count := 0
	var was := false
	for i in ticks:
		tick(b, 0.0, false, 1.0)
		count += int(b.airborne and not was)
		was = b.airborne
	return count

func corner(pace: float, surface: int, hz := 60) -> BikeRide:
	w.surface = surface
	var b := bike(pace)
	for i in hz:
		tick(b, 1.0, false, 0.0, 1.0 / hz)
	return b

func _init() -> void:
	var stopped := corner(0.0, RoadSurface.PACKED)
	check(stopped.heading == 0.0 and stopped.lean == 0.0, "на месте нет поворота корпуса и завала")
	var tight := corner(5.0, RoadSurface.PACKED)
	var fast := corner(16.0, RoadSurface.PACKED)
	var loose := corner(16.0, RoadSurface.SAND)
	check(tight.heading < fast.heading and fast.heading < 0.0, "на скорости дуга шире, направление предсказуемо")
	check(absf(loose.heading) < absf(fast.heading), "песок расширяет дугу по сравнению с плотной землёй")
	check(fast.lean < -0.15 and absf(fast.lean) <= 0.28, "скоростной поворот даёт умеренный крен до 16°")
	check(fast.speed < bike(16.0).speed and fast.speed > 12.0, "резкий поворот плавно теряет часть скорости")
	w.surface = RoadSurface.PACKED
	var straight := bike(16.0)
	for i in 60:
		tick(straight)
	check(fast.speed < straight.speed, "потеря скорости в повороте больше обычного наката")
	var old_heading := fast.heading
	tick(fast, -1.0)
	check(absf(fast.heading - old_heading) < 0.03 and fast.lean < 0.0, "перекладка руля не переворачивает крен мгновенно")
	for i in 30:
		tick(fast, -1.0)
	check(fast.lean > 0.1, "контрруление уверенно перекладывает велосипед")
	for i in 60:
		tick(fast)
	check(absf(fast.lean) < 0.01 and absf(fast._yaw_rate) < 0.001, "отпущенный руль быстро стабилизирует курс")
	check(corner(-1.5, RoadSurface.PACKED).heading > 0.0, "руль предсказуемо работает задним ходом")
	var turn30 := corner(12.0, RoadSurface.PACKED, 30)
	var turn120 := corner(12.0, RoadSurface.PACKED, 120)
	check(absf(turn30.heading - turn120.heading) < 0.05, "поворот близок при 30 и 120 тактах/с")
	w.surface = RoadSurface.PACKED
	var jump := bike()
	tick(jump, 0.0, true)
	check(jump.airborne and jump.vy > 3.0, "прыжок отзывчив с первого такта")
	var vy0 := jump.vy
	tick(jump, 0.0, true)
	check(jump.vy < vy0, "повторный пробел не даёт двойного прыжка")
	var apex := jump.y
	var compression := 0.0
	for i in 90:
		tick(jump)
		apex = maxf(apex, jump.y)
		compression = maxf(compression, jump.squash)
	check(apex > 100.4 and apex < 100.7, "высота обычного прыжка контролируема")
	check(not jump.airborne and not jump.crashed and compression > 0.03, "приземление сжимает подвеску без падения (%.3f м)" % compression)
	check(absf(jump.squash) < 0.005, "подвеска успокаивается после приземления")
	var buffered := bike()
	buffered.airborne = true
	buffered.air_time = 0.4
	buffered.y += 0.06
	buffered.vy = -4.0
	tick(buffered, 0.0, true)
	tick(buffered)
	check(buffered.airborne and buffered.vy > 3.0, "нажатие перед приземлением запускает следующий прыжок")
	ground.profile = func(d: float) -> float: return -2.0 if d > 0.1 else 0.0
	var ledge := bike(2.0)
	for i in 6:
		tick(ledge)
	check(ledge.airborne, "с края падаем даже на малой скорости")
	tick(ledge, 0.0, true)
	check(ledge.vy > 3.0, "короткий запас прыжка после схода с края")
	ground.profile = func(d: float) -> float: return 0.02 * sin(d * 2.0)
	var bumps := bike(6.0)
	var flights := 0
	var travel := 0.0
	for i in 120:
		tick(bumps, 0.0, false, 1.0)
		flights += int(bumps.airborne)
		travel = maxf(travel, absf(bumps.squash))
	check(flights < 12 and travel > 0.001, "мелкие неровности отрабатывает подвеска без частых отрывов")
	ground.profile = func(d: float) -> float: return 0.3 * d if d < 4.0 else 1.2 - 0.3 * (d - 4.0)
	var crest := bike(11.0)
	var launched := false
	for i in 50:
		tick(crest, 0.0, false, 1.0)
		launched = launched or (crest.airborne and crest.vy > 0.0)
	check(launched, "с быстрого гребня отрыв с сохранением подъёмного импульса")
	# 7.0: тот же гребень медленно и пологий излом быстро проезжаются по земле
	check(takeoffs(4.0, 50) == 0, "медленно гребень проезжается без отрыва")
	ground.profile = func(d: float) -> float: return 0.12 * d if d < 6.0 else 0.72
	check(takeoffs(13.0, 60) == 0, "пологий излом на скорости не подбрасывает")
	# холмы, как сетка рельефа: изломы через 2 м, на крейсерской без ложных подлётов и рывков
	ground.profile = func(d: float) -> float:
		var k := floorf(d / 2.0)
		var a := 0.8 * sin(k * 0.45) + 0.12 * sin(k * 1.7)
		var b := 0.8 * sin((k + 1.0) * 0.45) + 0.12 * sin((k + 1.0) * 1.7)
		return lerpf(a, b, d / 2.0 - k)
	var hills := bike(11.0)
	var hill_flights := 0
	var jerk := 0.0
	var was := false
	var vy_prev := 0.0
	for i in 300:
		tick(hills, 0.0, false, 1.0)
		hill_flights += int(hills.airborne and not was)
		if i > 0 and not was and not hills.airborne:
			jerk = maxf(jerk, absf(hills.vy - vy_prev))
		was = hills.airborne
		vy_prev = hills.vy
	check(hill_flights <= 2 and jerk < 1.5, "холмы с изломами: отрывов %d, рывок по вертикали на земле %.2f м/с за такт" % [hill_flights, jerk])
	ground.profile = func(d: float) -> float: return 0.4 * d if d < 3.0 else 1.2
	check(takeoffs(10.0, 40) == 1, "трамплин на скорости — настоящий прыжок")
	ground.profile = func(_d: float) -> float: return 0.0
	var air_turn := bike(12.0)
	air_turn.airborne = true
	air_turn.y += 20.0
	for i in 20:
		tick(air_turn, 1.0)
	check(absf(air_turn.heading) < 0.15 and absf(air_turn.tilt) < 0.56, "в полёте ограничены доворот и клевок")
	var flat_land := bike(10.0)
	flat_land.vy = -8.0
	flat_land._land(100.0, ground)
	ground.profile = func(d: float) -> float: return -0.4 * d
	var slope_land := bike(10.0)
	slope_land.vy = -8.0
	slope_land._land(100.0, ground)
	check(slope_land.land_impact < flat_land.land_impact and slope_land.speed > flat_land.speed, "приземление вдоль склона мягче и лучше сохраняет скорость")
	var spring := bike()
	spring.squash_v = 20.0
	for i in 30:
		spring._step_suspension(0.1)
	check(absf(spring.squash) < 0.001 and is_finite(spring.squash_v), "подвеска устойчива при длинном такте и сильном ударе")
	quit(1 if fails else 0)
