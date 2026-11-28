extends "res://tools/bike_friendly_test.gd"
## Инварианты на стыках физики велосипеда (аудит 30.10.2026), затем прежний набор управляемости.
## Без генерации мира: ограничители подменяют только нужную проверку (габарит, свод).

## Свод на высоте top над землёй 100 м севернее from (курс 0 едет на −Z).
class LowRoof extends TestGround:
	var top := 101.9
	var from := INF
	func ceiling_at(_x: float, pz: float, _feet: float) -> float:
		return top if pz < from else INF

## Узкий коридор шириной 72 см, при can_exit_left открыт влево.
class SlotGround extends TestGround:
	var can_exit_left := false
	func wall_at(px: float, _pz: float, _feet: float, r := 0.0) -> bool:
		return px + r > 0.36 or (not can_exit_left and px - r < -0.36)

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

## Бревно с плоским верхом 0,3 м поперёк пути на z = -1 (ширина 0,6 м), без корня.
class LogTop extends RootBump:
	func wheel_support(_x: float, pz: float, _wheel_r: float, _climb: float) -> float:
		return 100.3 if absf(pz + 1.0) < 0.3 else -INF

func root_ground() -> TestGround:
	var rooty := TestGround.new(w)
	rooty.obstacles = RootBump.new(w, rooty)
	rooty.obstacles.bumps.resize(1)
	return rooty

## Состояние, от которого зависят следующие подшаги и телеметрия
func snapshot(b: BikeRide) -> Array:
	return [b.x, b.z, b.y, b.vy, b.heading, b.speed, b.lateral_speed, b.slick_f, b.slick_r, b.force_f, b.force_r,
		b.load_f, b.load_r, b.tire_f, b.tire_r, b.squash_f, b.squash_r, b.tilt, b.lean, b.hit_dv, b.crash_cause, b.crash_velocity]

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
		b.step(p, 0.0, 0.0, false, false, 1.0 / 60.0, rooty.world, rooty)
		slick = slick or b.slick_f < 1.0 or b.slick_r < 1.0
		kick = maxf(kick, maxf(absf(b.squash_fv), absf(b.squash_rv)))
	return {speed = b.speed, slick = slick, kick = kick, z = b.z}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func slot(lateral: float) -> BikeRide:
	var b := bike(12.0)
	b.lateral_speed = lateral
	return b

func run() -> void:
	# A1: доворот из заноса не выводит раму из допустимого курса, в обе стороны заноса
	var walls := SlotGround.new(w)
	for lateral: float in [7.0, -7.0]:
		var narrow := slot(lateral)
		var bad := 0
		for i in 12:
			narrow.step(p, 0.0, signf(lateral), false, false, 1.0 / 120.0, w, walls)
			bad += int(not narrow.fits(narrow.x, narrow.z, narrow.heading, w, walls))
		check(bad == 0 and not narrow.crashed, "A1 коридор, занос %+.0f: курс %.4f, вне габарита %d подшагов" % [lateral, narrow.heading, bad])
	# у угла открыта одна сторона: доворот в свободную сторону сохраняется
	var corner := slot(-7.0)
	walls.can_exit_left = true
	for i in 12:
		corner.step(p, 0.0, -1.0, false, false, 1.0 / 120.0, w, walls)
	check(corner.heading > 0.05 and corner.fits(corner.x, corner.z, corner.heading, w, walls), "A1 угол: доворот в открытую сторону %.3f" % corner.heading)
	# A4: велосипед после езды по корням с тормозом в дуге и свежий на одном старте едут одинаково
	var rooty := root_ground()
	var used := bike(9.0)
	for i in 90:
		used.step(p, -0.6, 0.8, false, false, 1.0 / 120.0, w, rooty)
	var used_motion := used.brake_pressure > 0.0 and absf(used.heading) > 0.05
	var fresh := bike(0.0)
	var runs: Array = []
	for b: BikeRide in [fresh, used]:
		b.x = 0.0
		b.z = 0.0
		b.y = 100.0
		b.heading = 0.0
		b.mount(p)
		b.speed = 8.0
		for i in 60:
			b.step(p, 0.5, 0.3, false, false, 1.0 / 120.0, w, rooty)
			if i == 0: runs.append(snapshot(b))
		runs.append(snapshot(b))
	check(used_motion and runs[0] == runs[2] and runs[1] == runs[3], "A4 сброс: первый подшаг и 0,5 с после посадки совпадают у свежего и ездившего")
	# B3: посадка передним колесом на бревно
	var logged := TestGround.new(w)
	logged.obstacles = LogTop.new(w, logged)
	logged.obstacles.data.resize(1)
	var lander := bike(5.0)
	lander.z = -1.0 + BikeRide.HUB
	var g := lander._contact_mid(lander.x, lander.z, logged)
	lander.airborne = true
	lander.y = g
	lander.vy = -3.0
	lander._land(g, lander._slope(logged), 1.0 / 60.0, logged, lander.config)
	var along := lander._slope(logged)
	var expected_vy := along * lander.speed
	check(along > 0.2 and absf(lander.vy - expected_vy) < 0.005 and not lander.crashed,
		"B3 посадка на кромку бревна: уклон опоры %.3f, vy после %.3f" % [along, lander.vy])
	# A3: обычный старт и подъём 15 % с газом
	ground.gradient = Vector2(0, -0.15)
	var climb := bike(0.0)
	for i in 240:
		tick(climb, 0.0, false, 60, 1.0)
	ground.gradient = Vector2.ZERO
	check(climb.speed > 3.0 and -climb.z > 15.0, "A3 подъём 15%% с места за 4 с: %.2f м/с, %.1f м" % [climb.speed, -climb.z])
	# B1: удар в стену и жёсткая посадка в одном подшаге — одно событие (первое), игрок на месте велосипеда
	var wall := WallGround.new(w)
	var both := bike(14.0)
	both.z = -1.0 + BikeRide.AXLE + BikeRide.BODY_R + 0.05
	both.airborne = true
	both.y = 100.01
	both.vy = -20.0
	both.step(p, 0.0, 0.0, false, false, 1.0 / 60.0, w, wall)
	check(both.crashed and both.crash_cause == BikeRide.CrashCause.COLLISION and both.crash_normal.z > 0.9 and both.crash_velocity.y < -19.0 and p.z == both.z,
		"B1 стена + посадка: причина %s, нормаль %s, vy %.1f" % [BikeRide.CrashCause.keys()[both.crash_cause], both.crash_normal, both.crash_velocity.y])
	# удар с нажатым пробелом: подготовка прыжка после падения не начинается, следующий шаг ничего не двигает
	var hopping := bike(14.0)
	hopping.z = both.z
	hopping.step(p, 0.0, 0.0, false, true, 1.0 / 60.0, w, wall)
	var at := Vector3(hopping.x, hopping.y, hopping.z)
	hopping.step(p, 1.0, 0.0, false, true, 1.0 / 60.0, w, wall)
	check(hopping.crashed and hopping.crash_cause == BikeRide.CrashCause.COLLISION and not hopping.hop_preparing \
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
	check(passing.z < -5.5 and not passing.crashed, "A2 проезд под сводом выше габарита: z=%.2f" % passing.z)
	super.run()
