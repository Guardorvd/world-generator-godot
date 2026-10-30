extends "res://tools/bike_audit_test.gd"
## Разгон, накат и тормоза (анализ 30.10.2026, T1–T7) без генерации мира: баланс сил, согласованные сигналы,
## замеры для сравнения ощущений. Затем инварианты аудита и прежний набор управляемости.
## -- --measure: печатать таблицы замеров (разгон, накат, тормоз) без проверок.

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()

## Изменение скорости вдоль рамы, которое объясняют силы последнего внешнего шага
static func explained(b: BikeRide) -> float:
	return (b.drive_force + b.slope_force + b.pump_force - b.roll_loss - b.air_loss - b.rough_loss - b.brake_force.x - b.brake_force.y) * b.tick_time

## Время (с) и путь (м), за которые скорость при газе throttle проходит from → to; -1, если не дошла за limit секунд
func span(from: float, to: float, throttle: float, ramp := true, limit := 30.0) -> Vector2:
	var b := bike(from)
	b.effort_ramp = ramp
	var z0 := b.z
	for i in int(limit * 60):
		tick(b, 0.0, false, 60, throttle)
		if (b.speed >= to) if to > from else (b.speed <= to):
			return Vector2((i + 1) / 60.0, absf(b.z - z0))
	return Vector2(-1.0, -1.0)

func run() -> void:
	# T2: усилие нарастает быстро и без мёртвой задержки, отпускание не оставляет тяги
	var pedal := bike(0.0)
	tick(pedal, 0.0, false, 60, 1.0)
	var first_tick := pedal.speed
	for i in 5: tick(pedal, 0.0, false, 60, 1.0)
	var at_100ms := pedal.effort
	for i in 54: tick(pedal, 0.0, false, 60, 1.0)
	for i in 9: tick(pedal, 0.0, false, 60, 0.0)
	check(first_tick > 0.0 and at_100ms > 0.6 and at_100ms < 0.85 and pedal.effort < 0.06 and pedal.drive_force < 0.05,
		"T2 усилие: первый такт %.3f м/с, за 0,1 с %.2f, через 0,15 с после отпускания %.3f (тяга %.3f)" % [first_tick, at_100ms, pedal.effort, pedal.drive_force])
	var levels := []
	for level: float in [0.25, 0.5, 1.0]:
		var b := bike(0.0)
		for i in 120: tick(b, 0.0, false, 60, level)
		levels.append([b.effort, b.speed])
	check(absf(levels[0][0] - 0.25) < 0.01 and absf(levels[1][0] - 0.5) < 0.01 and levels[0][1] < levels[1][1] and levels[1][1] < levels[2][1],
		"T2 аналоговый ввод 25/50/100%%: скорость за 2 с %.2f / %.2f / %.2f" % [levels[0][1], levels[1][1], levels[2][1]])
	var s05 := span(0.0, 5.0, 1.0)
	var s05_old := span(0.0, 5.0, 1.0, false)
	var s510 := span(5.0, 10.0, 1.0)
	print("T2 разгон 0→5 м/с: %.2f с (мгновенная тяга %.2f с); 5→10: %.2f с" % [s05.x, s05_old.x, s510.x])
	check(s05.x > s05_old.x and s05.x < s05_old.x + 0.2, "T2 старт мягче, но без заметной задержки: +%.2f с" % (s05.x - s05_old.x))
	# T3: накат — тот же воздух на земле и в полёте, пассивный накат по ровному не создаёт скорость
	var rolling := bike(12.0)
	tick(rolling, 0.0, false, 60)
	var aloft := bike(12.0)
	aloft.airborne = true
	aloft.y = 110.0
	tick(aloft, 0.0, false, 60)
	check(absf(rolling.air_loss - aloft.air_loss) < 0.01 * rolling.air_loss, "T3 воздух на земле %.3f и в полёте %.3f м/с²" % [rolling.air_loss, aloft.air_loss])
	var coast := bike(12.0)
	var rising := false
	for i in 600:
		var before := coast.speed
		tick(coast, 0.0, false, 60)
		rising = rising or coast.speed > before + 1e-6
	check(not rising, "T3 пассивный накат по ровному не разгоняет")
	for surface: int in [RoadSurface.PACKED, RoadSurface.FOREST, RoadSurface.SAND]:
		w.surface = surface
		var hi := span(15.0, 10.0, 0.0)
		var lo := span(10.0, 5.0, 0.0)
		print("T3 накат «%s»: 15→10 м/с %.1f с, %.0f м; 10→5 м/с %.1f с, %.0f м" % [RoadSurface.LIST[surface].name, hi.x, hi.y, lo.x, lo.y])
	w.surface = RoadSurface.PACKED
	for grade: float in [0.05, 0.1, 0.2]:
		ground.gradient = Vector2(0, grade)
		var down := bike(5.0)
		for i in 300: tick(down, 0.0, false, 60)
		print("T3 спуск %d%% накатом с 5 м/с: через 5 с %.1f м/с" % [roundi(grade * 100), down.speed])
	ground.gradient = Vector2.ZERO
	# T4: каденс от виртуальной передачи — видимое нажатие на старте, 55–110 об/мин в езде, без скачков и накатом стоят
	var legs := bike(0.0)
	var pushed := 0.0
	for i in 12:
		var c0 := legs.crank
		tick(legs, 0.0, false, 60, 1.0)
		pushed += absf(angle_difference(c0, legs.crank))
	ground.gradient = Vector2(0, 0.08)
	var rpm_low := INF
	var rpm_high := 0.0
	var jerk := 0.0
	var last_rate := -1.0
	for i in 600:
		var c0 := legs.crank
		tick(legs, 0.0, false, 60, 1.0)
		var rate := absf(angle_difference(c0, legs.crank)) * 60.0
		if legs.speed > 4.0:
			rpm_low = minf(rpm_low, rate * 60.0 / TAU)
			rpm_high = maxf(rpm_high, rate * 60.0 / TAU)
		if last_rate >= 0.0: jerk = maxf(jerk, absf(rate - last_rate))
		last_rate = rate
	ground.gradient = Vector2.ZERO
	var top_speed := legs.speed
	var c1 := legs.crank
	for i in 30: tick(legs, 0.0, false, 60, 0.0)
	check(pushed > 0.05 and rpm_low > 55.0 and rpm_high < 115.0 and jerk < 0.6 and legs.crank == c1,
		"T4 каденс: нажатие на старте %.2f рад, %.0f–%.0f об/мин до %.1f м/с, скачок %.2f рад/с за такт, накатом стоят" % [pushed, rpm_low, rpm_high, top_speed, jerk])
	# T5: один тормоз — монотонное дозирование, разгруженное колесо отдаёт долю другому, без скачка при возврате
	var levels_brake: Array[float] = []
	for command: float in [0.25, 0.5, 0.75, 1.0]:
		var b := bike(10.0)
		for i in 30: tick(b, 0.0, false, 60, -command)
		levels_brake.append(b.brake_force.x + b.brake_force.y)
	check(levels_brake[0] < levels_brake[1] and levels_brake[1] < levels_brake[2] and levels_brake[2] < levels_brake[3],
		"T5 дозирование 25/50/75/100%%: %.2f / %.2f / %.2f / %.2f м/с²" % levels_brake)
	var nose_up := bike(8.0)
	var before_return := 0.0
	var dip := INF
	for i in 60:
		if i < 30:
			nose_up.lift_f = 0.15
			nose_up.lift_fv = 0.0
		tick(nose_up, 0.0, false, 60, -1.0)
		var total := nose_up.brake_force.x + nose_up.brake_force.y
		if i == 25: check(nose_up.brake_force.x < 0.01 and nose_up.brake_force.y > 3.0, "T5 переднее поднято: перед %.2f, зад %.2f м/с² (в пределах переноса нагрузки)" % [nose_up.brake_force.x, nose_up.brake_force.y])
		if i == 29: before_return = total
		if i >= 30: dip = minf(dip, total)
	var after_return := nose_up.brake_force.x + nose_up.brake_force.y
	check(dip >= before_return - 0.05 and after_return > before_return + 2.0 and not nose_up.crashed, "T5 возврат переднего колеса: тормоз %.2f, не ниже %.2f, затем %.2f м/с² — без провала" % [before_return, dip, after_return])
	for pace: float in [6.0, 12.0, 18.0]:
		var full_stop := bike(pace)
		var half_stop := bike(pace)
		var tf := 0
		var th := 0
		while full_stop.speed > 0.05 and tf < 600:
			tick(full_stop, 0.0, false, 60, -1.0)
			tf += 1
		while half_stop.speed > 0.05 and th < 900:
			tick(half_stop, 0.0, false, 60, -0.5)
			th += 1
		print("T5 остановка с %.0f м/с: полный %.2f с, %.1f м; половина %.2f с, %.1f м" % [pace, tf / 60.0, -full_stop.z, th / 60.0, -half_stop.z])
		check(not full_stop.crashed and tf < th, "T5 полный тормоз с %.0f м/с останавливает без падения и быстрее половинного" % pace)
	# T6: тормоз, держащий скорость на спуске, сжимает вилку; потеря хода в подъём без тормоза — нет
	ground.gradient = Vector2(0, 0.12)
	var held := bike(6.0)
	var dive_held := 0.0
	for i in 180:
		tick(held, 0.0, false, 60, -clampf((held.speed - 6.0) * 2.0 + 0.3, 0.0, 1.0))
		if i > 120: dive_held = maxf(dive_held, held.squash_f - held.squash_r)
	ground.gradient = Vector2(0, -0.15)
	var uphill := bike(8.0)
	var dive_up := 0.0
	for i in 60:
		tick(uphill, 0.0, false, 60)
		if i > 30: dive_up = maxf(dive_up, uphill.squash_f - uphill.squash_r)
	ground.gradient = Vector2.ZERO
	var level := bike(8.0)
	var dive_flat := 0.0
	for i in 60:
		tick(level, 0.0, false, 60)
		if i > 30: dive_flat = maxf(dive_flat, level.squash_f - level.squash_r)
	check(absf(held.feel_acceleration) < 0.5 and dive_held > dive_flat + 0.01 and dive_up < dive_flat + (dive_held - dive_flat) * 0.4,
		"T6 вилка (перед минус зад): спуск под тормозом %.3f м (ускорение %.2f), подъём накатом %.3f, ровное %.3f" % [dive_held, held.feel_acceleration, dive_up, dive_flat])
	# T7: тормоз, зажатый на ходу, заканчивается стоянкой; повторное нажатие у остановки — задний ход
	var stopping := bike(8.0)
	for i in 240: tick(stopping, 0.0, false, 60, -1.0)
	var parked := stopping.speed
	for i in 3: tick(stopping, 0.0, false, 60, 0.0)
	for i in 60: tick(stopping, 0.0, false, 60, -1.0)
	check(parked == 0.0 and stopping.speed < -1.0, "T7 удержание после остановки: %.2f м/с через 3 с; повторное нажатие — %.2f м/с" % [parked, stopping.speed])
	# T7: граница опасной скорости плавная — 13,9 и 14,1 м/с дают почти одинаковую перегрузку
	var risks: Array[float] = []
	for pace: float in [13.9, 14.1]:
		var brakes = preload("res://scripts/game/bike_brakes.gd").new()
		for i in 120: brakes.step(1.0 / 60.0, 1.0, pace, -0.35, 1.0, 0.0)
		risks.append(brakes.risk)
	check(absf(risks[0] - risks[1]) < 0.2, "T7 предупреждение у порога скорости: риск %.2f и %.2f" % risks)
	# T7: уверенный тормоз в пределах сцепления не звучит как юз
	var confident := bike(8.0)
	for i in 20: tick(confident, 0.0, false, 60, -0.6)
	check(confident.brakes.skid < 0.05 and confident.braking > 0.2, "T7 звук: тормоз %.2f при насыщении %.2f" % [confident.braking, confident.brakes.skid])
	# T1: силы объясняют изменение скорости — педали, накат, тормоз на ровном и на спуске
	for case: Array in [[1.0, 0.0, 5.0], [0.0, 0.0, 8.0], [-1.0, 0.0, 8.0], [-0.5, 0.1, 6.0], [1.0, -0.12, 3.0]]:
		ground.gradient = Vector2(0, case[1])
		var b := bike(case[2])
		var worst := 0.0
		for i in 60:
			var before := b.speed
			tick(b, 0.0, false, 60, case[0])
			if b.speed > 0.05 or before > 0.05:
				worst = maxf(worst, absf(b.speed - before - explained(b)))
		check(worst < 0.0005, "T1 баланс сил: газ %+.1f уклон %+.2f — расхождение %.5f м/с за такт" % [case[0], -case[1], worst])
	ground.gradient = Vector2.ZERO
	# T1: в полёте ни тормоз, ни педали не дают силы колёс
	var flying := bike(8.0)
	flying.airborne = true
	flying.y = 103.0
	tick(flying, 0.0, false, 60, -1.0)
	var braked := flying.brake_force
	tick(flying, 0.0, false, 60, 1.0)
	check(braked == Vector2() and flying.drive_force == 0.0 and flying.air_loss > 0.0, "T1 в полёте: тормоз %s, тяга %.2f" % [braked, flying.drive_force])
	# T1: перепроекция рамы в полёте (поворот при сносе) не даёт ложного продольного ускорения
	var turning := bike(8.0)
	turning.airborne = true
	turning.y = 110.0
	turning.lateral_speed = 3.0
	var frame := 0.0
	var felt := 0.0
	for i in 20:
		var before := turning.speed
		tick(turning, 1.0, false, 60)
		frame = maxf(frame, absf(turning.speed - before) * 60.0)
		felt = maxf(felt, absf(turning.feel_acceleration))
	check(felt < 0.5 and frame > felt + 0.3, "T1 перепроекция: по раме до %.2f м/с², по мировой скорости до %.2f" % [frame, felt])
	# T1: сигнал за внешний шаг — среднее по подшагам, одинаковое при 60 Гц и двух подшагах 120 Гц
	var a := bike(4.0)
	var c := bike(4.0)
	tick(a, 0.0, false, 60, 1.0)
	c.step(p, 1.0, 0.0, false, false, 1.0 / 120.0, w, ground)
	var first := c.drive_force
	c.step(p, 1.0, 0.0, false, false, 1.0 / 120.0, w, ground)
	check(absf(a.drive_force - (first + c.drive_force) * 0.5) < 0.0001 and absf(a.speed - c.speed) < 0.00001, "T1 агрегирование: %.4f = среднее %.4f" % [a.drive_force, (first + c.drive_force) * 0.5])
	super.run()
