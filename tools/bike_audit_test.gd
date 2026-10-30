extends "res://tools/bike_friendly_test.gd"
## Инварианты на стыках физики велосипеда (аудит 30.10.2026), затем прежний набор управляемости.
## Без генерации мира: ограничители подменяют только нужную проверку (габарит, свод).

class LowRoof extends TestGround:
	func ceiling_at(_x: float, _z: float, _feet: float) -> float:
		return 101.9

## Курс допустим только в полосе [low, high]: узкий коридор (обе стороны) или угол (одна).
class NarrowSlotBike extends BikeRide:
	var low := -0.005
	var high := 0.005
	func fits(_px: float, _pz: float, hd: float, _w: WorldData, _h: Heightfield) -> bool:
		return hd > low and hd < high

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
	var grounded := bike(6.0)
	var rear_up := bike(6.0)
	rear_up.lift_r = 0.2
	grounded._step_speed(1.0, false, 0.0, 1.0, 1.0 / 120.0)
	rear_up._step_speed(1.0, false, 0.0, 1.0, 1.0 / 120.0)
	print("AUDIT drive: rear_contact=%s grounded_v=%.6f rear_up_v=%.6f" % [rear_up.contact_r(), grounded.speed, rear_up.speed])
	var roof := LowRoof.new(w)
	var jumping := bike(0.0)
	var peak := jumping.y
	for i in 120:
		jumping.step(p, 0.0, 0.0, false, i == 0, 1.0 / 120.0, w, roof)
		peak = maxf(peak, jumping.y)
	print("AUDIT ceiling: roof=101.9 peak_feet=%.6f required_top=%.6f crashed=%s" % [peak, peak + BikeRecovery.CLEARANCE, jumping.crashed])
	super.run()
