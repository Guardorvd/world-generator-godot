extends "res://tools/bike_friendly_test.gd"
## Инварианты на стыках физики велосипеда (аудит 30.10.2026), затем прежний набор управляемости.
## Без генерации мира: ограничители подменяют только нужную проверку (габарит, свод).

## Свод на высоте top над землёй 100 м севернее from (курс 0 едет на −Z).
class LowRoof extends TestGround:
	var top := 101.9
	var from := INF
	func ceiling_at(_x: float, pz: float, _feet: float) -> float:
		return top if pz < from else INF

## Курс допустим только в полосе [low, high]: узкий коридор (обе стороны) или угол (одна).
class NarrowSlotBike extends BikeRide:
	var low := -0.005
	var high := 0.005
	func fits(_px: float, _pz: float, hd: float, _w: WorldData, _h: Heightfield) -> bool:
		return hd > low and hd < high

## Стена (как перила моста) севернее z = -1.
class WallGround extends TestGround:
	func wall_at(_x: float, pz: float, _feet: float, r: float = 0.0) -> bool:
		return pz - r < -1.0

## Один корень высотой height поперёк пути на z = -2; других препятствий нет.
class RootBump extends ForestObstacles:
	var height := 0.05
	func bump_at(_x: float, pz: float) -> float:
		return height if absf(pz + 2.0) < 0.15 else 0.0
	func hits(_x: float, _z: float, _feet: float, _r: float, _climb := 0.0) -> bool:
		return false
	func normal(_x: float, _z: float, _feet: float, _r: float, _climb := 0.0) -> Vector2:
		return Vector2.ZERO
	func wheel_support(_x: float, _z: float, _wheel_r: float, _climb: float) -> float:
		return -INF
	func wheel_contact(_x: float, _z: float, _wheel_r: float, _climb: float, _ground: float) -> Dictionary:
		return {}

## Проезд накатом 6 м/с через корень с колёсами, удерживаемыми на высоте lift (-1 — корня нет).
func over_root(lift: float) -> Dictionary:
	var rooty := TestGround.new(w)
	var root := RootBump.new(w, rooty)
	root.height = 0.05 if lift >= 0.0 else 0.0
	rooty.obstacles = root
	var b := bike(6.0)
	var slick := false
	var kick := 0.0
	for i in 60:
		if lift > 0.0:
			b.lift_f = lift
			b.lift_r = lift
			b.lift_fv = 0.0
			b.lift_rv = 0.0
		b.step(p, 0.0, 0.0, false, false, 1.0 / 120.0, w, rooty)
		slick = slick or b.slick_f < 1.0 or b.slick_r < 1.0
		kick = maxf(kick, maxf(absf(b.squash_fv), absf(b.squash_rv)))
	return {speed = b.speed, slick = slick, kick = kick, z = b.z}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func slot(lateral: float, low := -0.005, high := 0.005) -> NarrowSlotBike:
	var b := NarrowSlotBike.new()
	b.contact_model = true
	b.low = low
	b.high = high
	b.y = 100.0
	b.mount(p)
	b.speed = 12.0
	b.lateral_speed = lateral
	b.slip = atan2(lateral, 12.0)
	return b

func run() -> void:
	# A1: доворот из заноса не выводит раму из допустимого курса, в обе стороны заноса
	for lateral: float in [7.0, -7.0]:
		var narrow := slot(lateral)
		var bad := 0
		for i in 12:
			narrow.step(p, 0.0, 0.0, false, false, 1.0 / 120.0, w, ground)
			bad += int(not narrow.fits(narrow.x, narrow.z, narrow.heading, w, ground))
		check(bad == 0 and not narrow.crashed, "A1 коридор, занос %+.0f: курс %.4f, вне габарита %d подшагов" % [lateral, narrow.heading, bad])
	# у угла открыта одна сторона: доворот в свободную сторону сохраняется
	var corner := slot(-7.0, -0.005, 1.0)
	for i in 12:
		corner.step(p, 0.0, 0.0, false, false, 1.0 / 120.0, w, ground)
	check(corner.heading > 0.05 and corner.fits(corner.x, corner.z, corner.heading, w, ground), "A1 угол: доворот в открытую сторону %.3f" % corner.heading)
	var reused := bike()
	reused.slick_r = BikeRide.ROOT_GRIP
	reused.force_r = Vector2(2.0, 3.0)
	reused.reset_motion()
	print("AUDIT reset: slick_r=%.3f force_r=%s" % [reused.slick_r, reused.force_r])
	# A3: педали тянут только через заднее колесо на земле
	var grounded := bike(6.0)
	var rear_up := bike(6.0)
	rear_up.lift_r = 0.2
	grounded._step_speed(1.0, false, 0.0, 1.0, 1.0 / 120.0)
	rear_up._step_speed(1.0, false, 0.0, 1.0, 1.0 / 120.0)
	check(grounded.speed > 6.0 and rear_up.speed < 6.0, "A3 газ с поднятым задним: на земле %.4f, поднято %.4f м/с" % [grounded.speed, rear_up.speed])
	# скользкое заднее на ходу тянет в пределах запаса, у старта — помощь в полную силу
	var slick := bike(8.0)
	slick.slick_r = BikeRide.ROOT_GRIP
	var full := bike(8.0)
	slick._step_speed(1.0, false, 0.0, 1.0, 1.0 / 120.0, 0.5)
	full._step_speed(1.0, false, 0.0, 1.0, 1.0 / 120.0, 0.5)
	var start_slick := bike(0.5)
	start_slick.slick_r = BikeRide.ROOT_GRIP
	var start := bike(0.5)
	start_slick._step_speed(1.0, false, 0.0, 1.0, 1.0 / 120.0, 0.5)
	start._step_speed(1.0, false, 0.0, 1.0, 1.0 / 120.0, 0.5)
	check(slick.speed < full.speed and is_equal_approx(start_slick.speed, start.speed),
		"A3 тяга по запасу: на корне %.4f < %.4f; старт на корне %.4f = %.4f" % [slick.speed, full.speed, start_slick.speed, start.speed])
	# обычный старт и подъём 15 % с газом
	ground.gradient = Vector2(0, -0.15)
	var climb := bike(0.0)
	for i in 240:
		tick(climb, 0.0, false, 60, 1.0)
	ground.gradient = Vector2.ZERO
	check(climb.speed > 3.0 and -climb.z > 15.0, "A3 подъём 15%% с места за 4 с: %.2f м/с, %.1f м" % [climb.speed, -climb.z])
	# B2: поднятое выше корня колесо его не чувствует; ниже вершины — чувствует
	var plain := over_root(-1.0)
	var rolled := over_root(0.0)
	var lifted := over_root(0.2)
	var grazing := over_root(0.03)
	check(rolled.z < -2.5 and rolled.speed < plain.speed - 0.01 and rolled.slick, "B2 корень на земле: %.3f против %.3f без корня, скользко %s" % [rolled.speed, plain.speed, rolled.slick])
	check(absf(lifted.speed - plain.speed) < 0.001 and not lifted.slick and lifted.kick <= plain.kick + 0.001,
		"B2 колёса выше корня: %.4f = %.4f, скользко %s, толчок %.3f" % [lifted.speed, plain.speed, lifted.slick, lifted.kick])
	check(grazing.speed < plain.speed - 0.001 and grazing.slick, "B2 колёса ниже вершины корня: %.3f, скользко %s" % [grazing.speed, grazing.slick])
	# B1: удар в стену и жёсткая посадка в одном подшаге — одно событие (первое), игрок на месте велосипеда
	var wall := WallGround.new(w)
	var both := bike(14.0)
	both.z = -1.0 + BikeRide.AXLE + BikeRide.BODY_R + 0.05
	both.airborne = true
	both.y = 100.01
	both.vy = -20.0
	both.step(p, 0.0, 0.0, false, false, 1.0 / 120.0, w, wall)
	check(both.crashed and both.crash_cause == BikeRide.CrashCause.COLLISION and both.crash_normal.z > 0.9 and both.crash_velocity.y < -19.0 and p.z == both.z,
		"B1 стена + посадка: причина %s, нормаль %s, vy %.1f" % [BikeRide.CrashCause.keys()[both.crash_cause], both.crash_normal, both.crash_velocity.y])
	# удар с нажатым пробелом: подготовка прыжка после падения не начинается, следующий шаг ничего не двигает
	var hopping := bike(14.0)
	hopping.z = both.z
	hopping.step(p, 0.0, 0.0, false, true, 1.0 / 120.0, w, wall)
	var at := Vector3(hopping.x, hopping.y, hopping.z)
	hopping.step(p, 1.0, 0.0, false, true, 1.0 / 120.0, w, wall)
	check(hopping.crashed and hopping.crash_cause == BikeRide.CrashCause.COLLISION and hopping._auto_hop < 0.0 and hopping._hop_buf == 0.0 \
		and Vector3(hopping.x, hopping.y, hopping.z) == at and p.z == hopping.z, "B1 стена + пробел: прыжок не готовится, после падения шаг не двигает")
	# A2: прыжок под сводом не поднимает габарит седока выше свода (с места и на ходу, 60 и 144 Гц)
	var roof := LowRoof.new(w)
	for hz: int in [60, 144]:
		for pace: float in [0.0, 6.0]:
			var jumping := bike(pace)
			var peak := jumping.y
			var lowest := jumping.y
			for i in hz * 2:
				jumping.step(p, 0.0, 0.0, false, i == 0, 1.0 / hz, w, roof)
				peak = maxf(peak, jumping.y)
				lowest = minf(lowest, jumping.y)
			check(peak + BikeRecovery.CLEARANCE <= roof.top + 0.0001 and lowest >= 100.0 - 0.0001 and not jumping.crashed and not jumping.airborne,
				"A2 прыжок под сводом %.0f м/с %d Гц: верх %.3f при своде %.3f" % [pace, hz, peak + BikeRecovery.CLEARANCE, roof.top])
	# въезд под свод ниже габарита: велосипед останавливается у кромки, не въезжает и не падает
	var low := LowRoof.new(w)
	low.top = 101.5
	low.from = -3.0
	var entering := bike(6.0)
	for i in 120:
		entering.step(p, 0.5, 0.0, false, false, 1.0 / 120.0, w, low)
	check(entering.z > -3.0 and not entering.crashed and absf(entering.y - 100.0) < 0.001, "A2 въезд под низкий свод: остановка у кромки z=%.2f" % entering.z)
	# свод выше габарита: проезд свободный
	var high := LowRoof.new(w)
	high.from = -3.0
	var passing := bike(6.0)
	for i in 120:
		passing.step(p, 0.5, 0.0, false, false, 1.0 / 120.0, w, high)
	check(passing.z < -6.0 and not passing.crashed, "A2 проезд под сводом выше габарита: z=%.2f" % passing.z)
	super.run()
