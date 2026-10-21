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
	# 7.3+: каменистый участок на скорости расходует сцепление сверх свойств покрытия.
	w.surface = RoadSurface.STONE
	var rocks := bike(16.0)
	rocks.steer = 1.0
	rocks._yaw_rate = -2.0
	tick(rocks, 1.0)
	check(absf(rocks._yaw_rate) * rocks.speed < BikeRide.CORNER_GRIP * 0.9 * 0.98,
		"быстрый поворот по камням требует дополнительного запаса сцепления")
	var careful := bike(4.0)
	var careful_reference := bike(4.0)
	careful_reference._step_speed(0.0, false, 0.0, PlayerState.terrain_speed(w, 0.0, 0.0, ground), DT, 0.9)
	tick(careful)
	check(absf(careful.speed - careful_reference.speed) < 0.00001,
		"медленный проезд камней не получает дополнительного сопротивления")
	var quick := bike(16.0)
	var quick_reference := bike(16.0)
	quick_reference._step_speed(0.0, false, 0.0, PlayerState.terrain_speed(w, 0.0, 0.0, ground), DT, 0.9)
	tick(quick)
	check(quick.speed < quick_reference.speed - 0.001,
		"быстрый прямой проезд камней расходует часть наката")
	w.surface = RoadSurface.PACKED
	# 7.3: инерция перекладки и общий запас сцепления тормоза/поворота.
	var slow_response := bike(4.0)
	var fast_response := bike(16.0)
	slow_response.steer = 1.0
	fast_response.steer = 1.0
	slow_response._step_turn(1.0, 1.0, DT)
	fast_response._step_turn(1.0, 1.0, DT)
	check(absf(slow_response._yaw_rate) > absf(fast_response._yaw_rate), "на скорости поворот набирается более инерционно")
	fast_response.speed = 0.0
	check(fast_response._step_turn(1.0, 1.0, DT) == 0.0, "остановка гасит остаточное вращение")
	var coast_turn := bike(16.0)
	var brake_turn := bike(16.0)
	for i in 30:
		coast_turn._step_turn(1.0, 1.0, DT)
		brake_turn._step_turn(1.0, 1.0, DT, 1.0)
	check(absf(brake_turn._yaw_rate) < absf(coast_turn._yaw_rate), "тормоз оставляет меньше сцепления для резкого поворота")
	coast_turn._step_turn(1.0, 0.75, DT)
	check(absf(coast_turn._yaw_rate * coast_turn.speed) <= BikeRide.CORNER_GRIP * 0.75 + 0.01,
		"при въезде на песок накопленный поворот ограничен сцеплением")
	var packed_brake := bike(12.0)
	var sand_brake := bike(12.0)
	for i in 60:
		w.surface = RoadSurface.PACKED
		tick(packed_brake, 0.0, false, -1.0)
		w.surface = RoadSurface.SAND
		tick(sand_brake, 0.0, false, -1.0)
	check(sand_brake.speed > packed_brake.speed + 1.0 and absf(sand_brake.z) > absf(packed_brake.z),
		"на песке тормозной путь длиннее, чем на укатанной земле")
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
	var hill_travel := 0.0
	var tilt_jerk := 0.0
	var tilt_prev := 0.0
	var turn_prev := 0.0
	var geo_jerk := 0.0
	var geo_prev := 0.0
	var geo_turn := 0.0
	for i in 300:
		tick(hills, 0.0, false, 1.0)
		hill_flights += int(hills.airborne and not was)
		if i > 0 and not was and not hills.airborne:
			jerk = maxf(jerk, absf(hills.vy - vy_prev))
		if i > 30:
			hill_travel = maxf(hill_travel, maxf(absf(hills.squash_f), absf(hills.squash_r)))
			tilt_jerk = maxf(tilt_jerk, absf(hills.tilt - tilt_prev - turn_prev))
			geo_jerk = maxf(geo_jerk, absf(atan(hills._slope(ground)) - geo_prev - geo_turn))
		was = hills.airborne
		vy_prev = hills.vy
		turn_prev = hills.tilt - tilt_prev
		tilt_prev = hills.tilt
		geo_turn = atan(hills._slope(ground)) - geo_prev
		geo_prev = atan(hills._slope(ground))
	check(hill_flights <= 2 and jerk < 1.5, "холмы с изломами: отрывов %d, рывок по вертикали на земле %.2f м/с за такт" % [hill_flights, jerk])
	# 7.1: подвеска отрабатывает изломы, не пробиваясь, рама идёт за колёсами без рывков
	check(hill_travel > 0.005 and hill_travel < BikeRide.SAG_MAX * 0.8 and tilt_jerk < geo_jerk * 0.5,
		"холмы: ход подвески %.3f м, рывок наклона рамы %.4f при %.4f у рельефа" % [hill_travel, tilt_jerk, geo_jerk])
	# ступенька 8 см: сначала сжимается вилка, задний ход — на базу позже
	ground.profile = func(d: float) -> float: return 0.08 if d > 1.0 else 0.0
	var step := bike(6.0)
	var first_f := -1
	var first_r := -1
	for i in 40:
		tick(step, 0.0, false, 1.0)
		if first_f < 0 and step.squash_f > 0.01:
			first_f = i
		if first_r < 0 and step.squash_r > 0.01:
			first_r = i
	check(first_f >= 0 and first_r > first_f, "ступенька: вилка сжимается на такте %d, задний ход на такте %d" % [first_f, first_r])
	# частые кочки 3 см: колесо идёт по ним, рама почти стоит — подвеска их поглощает
	ground.profile = func(d: float) -> float: return 0.03 * maxf(0.0, sin(d * 6.0))
	var rough := bike(8.0)
	var wheel_lo := INF
	var wheel_hi := -INF
	var frame_lo := INF
	var frame_hi := -INF
	for i in 120:
		tick(rough, 0.0, false, 1.0)
		if i > 30:
			var wheel_y := rough.y + rough.ground_f
			var frame_y := wheel_y - rough.squash_f
			wheel_lo = minf(wheel_lo, wheel_y)
			wheel_hi = maxf(wheel_hi, wheel_y)
			frame_lo = minf(frame_lo, frame_y)
			frame_hi = maxf(frame_hi, frame_y)
	check(not rough.airborne and frame_hi - frame_lo < (wheel_hi - wheel_lo) * 0.5,
		"кочки: колесо ходит на %.3f м, рама над ним на %.3f м" % [wheel_hi - wheel_lo, frame_hi - frame_lo])
	# торможение грузит вилку, рама клюёт носом
	ground.profile = func(_d: float) -> float: return 0.0
	var dive := bike(10.0)
	for i in 15:
		tick(dive, 0.0, false, -1.0)
	check(dive.squash_f > dive.squash_r + 0.01 and dive.tilt < 0.0, "торможение: вилка %.3f м, зад %.3f м" % [dive.squash_f, dive.squash_r])
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
	spring.squash_fv = 20.0
	spring.squash_rv = -20.0
	for i in 30:
		spring._step_suspension(0.1)
	check(absf(spring.squash_f) < 0.001 and absf(spring.squash_r) < 0.001 and is_finite(spring.squash_fv), "подвеска устойчива при длинном такте и сильном ударе")
	quit(1 if fails else 0)
