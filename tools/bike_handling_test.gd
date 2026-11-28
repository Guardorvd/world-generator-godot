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
	preload("res://tools/watchdog.gd").arm(self, 180)
	w.surface = RoadSurface.PACKED
	var stopped := corner(0.0, RoadSurface.PACKED)
	check(stopped.heading == 0.0 and stopped.lean == 0.0, "на месте нет поворота корпуса и завала")
	var tight := corner(5.0, RoadSurface.PACKED)
	var fast := corner(16.0, RoadSurface.PACKED)
	var loose := corner(16.0, RoadSurface.SAND)
	check(absf(tight.heading) > absf(fast.heading) and fast.heading < 0.0, "на скорости дуга шире, направление предсказуемо")
	check(absf(loose.heading) < absf(fast.heading), "песок расширяет дугу по сравнению с плотной землёй")
	check(fast.lean < -0.15 and absf(fast.lean) <= BikePhysicsConfig.current().lean_max + 0.001, "скоростной поворот на ровном даёт сдержанный крен")
	for i in 30:
		tick(fast, -1.0)
	check(fast.lean > 0.1, "контрруление уверенно перекладывает велосипед")
	for i in 60:
		tick(fast)
	check(absf(fast.lean) < 0.01 and absf(fast.yaw_rate) < 0.001, "отпущенный руль быстро стабилизирует курс")
	check(corner(-1.5, RoadSurface.PACKED).heading > 0.0, "руль предсказуемо работает задним ходом")
	var turn30 := corner(12.0, RoadSurface.PACKED, 30)
	var turn120 := corner(12.0, RoadSurface.PACKED, 120)
	check(absf(turn30.heading - turn120.heading) < 0.05, "поворот близок при 30 и 120 тактах/с")
	w.surface = RoadSurface.PACKED
	var jump := bike()
	tick(jump, 0.0, true)
	var preloading := jump.hop_preparing
	for i in 15:
		if jump.airborne:
			break
		tick(jump)
	check(preloading and jump.airborne and jump.y > 100.0 and jump.vy > 2.5, "Space поднимает велосипед с первого такта")
	var vy0 := jump.vy
	tick(jump, 0.0, true)
	check(jump.vy < vy0, "повторный пробел не даёт двойного прыжка")
	check(is_zero_approx(jump.tilt) and is_zero_approx(jump.pitch_vel), "в полёте без Q/E сохраняется тангаж отрыва")
	var apex := jump.y
	var min_squash := jump.squash
	var max_squash := jump.squash
	for i in 90:
		tick(jump)
		apex = maxf(apex, jump.y)
		min_squash = minf(min_squash, jump.squash)
		max_squash = maxf(max_squash, jump.squash)
	var compression := max_squash - min_squash
	check(apex > 100.2 and apex < 100.7, "высота обычного прыжка контролируема")
	check(not jump.airborne and not jump.crashed and max_squash > 0.005 and compression > 0.03, "приземление сжимает подвеску без падения (%.3f м)" % compression)
	check(absf(jump.squash) < 0.005, "подвеска успокаивается после приземления")
	var front_first := bike(8.0)
	front_first.airborne = true
	front_first.air_time = 0.35
	front_first.y = 100.17
	front_first.tilt = -0.30
	front_first.vy = -2.0
	tick(front_first)
	check(front_first.contact_f() and not front_first.contact_r() and front_first.y > 100.10
		and front_first.squash_f > front_first.squash_r and not front_first.crashed,
		"носовая посадка начинается на вилке, пока заднее колесо в воздухе")
	var second_touch := false
	var max_rebound := 0.0
	var last_y := front_first.y
	for i in 60:
		front_first.clear_tick_events()
		tick(front_first)
		second_touch = second_touch or front_first.airborne or not front_first.landing_info.is_empty()
		max_rebound = maxf(max_rebound, front_first.y - last_y)
		last_y = front_first.y
	check(not second_touch and max_rebound < 0.002 and front_first.contact_r(),
		"посадка гасится за одно касание (обратный ход рамы %.3f м)" % max_rebound)
	var buffered := bike()
	buffered.airborne = true
	buffered.air_time = 0.4
	buffered.y += 0.06
	buffered.vy = -4.0
	tick(buffered, 0.0, true)
	for i in 20:
		tick(buffered)
		if buffered.airborne and buffered.vy > 2.5:
			break
	check(buffered.airborne and buffered.vy > 2.5, "нажатие перед приземлением запускает следующий прыжок")
	ground.profile = func(d: float) -> float: return -2.0 if d > 0.7 else 0.0
	var ledge := bike(2.0)
	for i in 60:
		tick(ledge)
		if ledge.airborne:
			break
	check(ledge.airborne and not ledge.crashed, "с края падаем даже на малой скорости")
	tick(ledge, 0.0, true)
	check(ledge.vy > 2.0, "короткий запас прыжка после схода с края")
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
	var slow_crest := bike(4.0)
	slow_crest.z = -2.5
	slow_crest.y = ground.ground_at(slow_crest.x, slow_crest.z)
	var slow_flight := false
	for i in 65:
		tick(slow_crest)
		slow_flight = slow_flight or slow_crest.airborne
	check(not slow_flight and slow_crest.z < -4.5, "медленно гребень проезжается без отрыва")
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
	check(hill_travel > 0.005 and hill_travel < hills.config.sag_max * 0.8 and tilt_jerk < geo_jerk * 0.5,
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
			var frame_y := wheel_y - rough.squash_f + rough.ground_extension
			wheel_lo = minf(wheel_lo, wheel_y)
			wheel_hi = maxf(wheel_hi, wheel_y)
			frame_lo = minf(frame_lo, frame_y)
			frame_hi = maxf(frame_hi, frame_y)
	check(not rough.airborne and frame_hi - frame_lo < (wheel_hi - wheel_lo) * 0.6,
		"кочки: колесо ходит на %.3f м, рама над ним на %.3f м" % [wheel_hi - wheel_lo, frame_hi - frame_lo])
	# торможение грузит вилку, рама клюёт носом
	ground.profile = func(_d: float) -> float: return 0.0
	var dive := bike(10.0)
	for i in 15:
		tick(dive, 0.0, false, -1.0)
	check(dive.squash_f > dive.squash_r + 0.01 and dive.load_f > 0.5, "торможение: вилка %.3f м, зад %.3f м" % [dive.squash_f, dive.squash_r])
	ground.profile = func(d: float) -> float: return 0.4 * d if d < 3.0 else 1.2
	check(takeoffs(10.0, 120) == 1, "трамплин даёт один отрыв за весь проезд с приземлением")
	ground.profile = func(_d: float) -> float: return 0.0
	var air_turn := bike(12.0)
	air_turn.airborne = true
	air_turn.y += 20.0
	for i in 20:
		tick(air_turn, 1.0)
	check(absf(air_turn.heading) < 0.15 and absf(air_turn.tilt) < 0.56, "в полёте ограничены доворот и клевок")
	var flat_land := bike(10.0)
	flat_land.vy = -9.5
	flat_land._land(100.0, 0.0, DT, ground, flat_land.config)
	ground.profile = func(d: float) -> float: return -0.4 * d
	var slope_land := bike(10.0)
	slope_land.vy = -9.5
	slope_land._land(100.0, -0.4, DT, ground, slope_land.config)
	check(slope_land.land_impact < flat_land.land_impact and slope_land.speed > flat_land.speed, "приземление вдоль склона мягче и лучше сохраняет скорость")
	ground.profile = func(_d: float) -> float: return 0.0
	var spring := bike(0.0)
	spring.squash_fv = 20.0
	spring.squash_rv = -20.0
	for i in 30:
		tick(spring, 0.0, false, 0.0, 0.1)
	check(absf(spring.squash_f) < 0.001 and absf(spring.squash_r) < 0.001 and is_finite(spring.squash_fv), "подвеска устойчива при длинном такте и сильном ударе")
	quit(1 if fails else 0)
