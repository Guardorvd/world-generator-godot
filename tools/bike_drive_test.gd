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

func run() -> void:
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
