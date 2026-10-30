extends SceneTree
## Управляемость через полный BikeRide.step без генерации: дуги, исправление ошибки, Q→E на уклонах.
class TestWorld extends WorldData:
	var surface := RoadSurface.PACKED
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = surface}

class TestGround extends Heightfield:
	var gradient := Vector2.ZERO
	var crest := false
	func _init(w: WorldData) -> void:
		super(w, false)
	func ground_at(px: float, pz: float, _raw := false) -> float:
		return 100.0 + gradient.dot(Vector2(px, pz)) - (maxf(0.0, -pz - 4.0) * 0.35 if crest else 0.0)
	func surface_at(px: float, pz: float, _feet := -INF) -> float:
		return ground_at(px, pz)
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true

var w := TestWorld.new()
var ground := TestGround.new(w)
var p := PlayerState.new()
var failures := 0
var checks := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("friendly: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func bike(pace := 12.0) -> BikeRide:
	var b := BikeRide.new()
	b.contact_model = true
	b.y = ground.surface_at(0, 0)
	b.mount(p)
	b.speed = pace
	return b

func tick(b: BikeRide, turn := 0.0, hop := false, hz := 60, throttle := 0.0) -> void:
	b.step(p, throttle, turn, false, hop, 1.0 / hz, w, ground)

func corner(pace: float, hz := 60, braking := false) -> Dictionary:
	var b := bike(pace)
	var peak := 0.0
	var entry := 0.0
	for i in hz * 2:
		tick(b, 1.0, false, hz, -1.0 if braking else 0.0)
		peak = maxf(peak, absf(b.slip))
		if i == int(hz * 0.25): entry = absf(b.heading)
	var heading := absf(b.heading)
	for i in hz:
		tick(b, 0.0, false, hz)
	return {bike = b, slip = rad_to_deg(peak), heading = heading, entry = entry}

func hop_ride(grade: float, delay: float, hz := 60, auto := false, overlap := false, pace := 8.0) -> Dictionary:
	ground.gradient = Vector2(0, -grade)
	var b := bike(pace)
	var takeoffs := 0
	var was := false
	var clearance := 0.0
	var nose := 0.0
	var popped := false
	for i in hz * 2:
		var t := float(i) / hz
		b.body_back = not auto and delay != -2.0 and t >= 0.3 and t < 0.3 + (0.5 if overlap else (delay if delay >= 0.0 else 0.2))
		b.body_forward = not auto and delay >= 0.0 and t >= 0.3 + delay and t < 0.6 + delay
		tick(b, 0.0, auto and i == roundi(0.3 * hz), hz)
		takeoffs += int(b.airborne and not was)
		popped = popped or b._hop_used
		was = b.airborne
		nose = maxf(nose, b.lift_f)
		clearance = maxf(clearance, b.y - b._contact(b.x, b.z, ground))
		if "--trace" in OS.get_cmdline_user_args() and grade == -0.45 and auto and i < hz:
			print("TRACE %.3f air %s vy %.2f clear %.3f auto %.3f front %.3f body %.2f link %.3f used %s" % [t, b.airborne, b.vy, b.y - b._contact(b.x, b.z, ground), b._auto_hop, b.lift_f, b.body_x, b._hop_link, b._hop_used])
	return {bike = b, takeoffs = takeoffs, clearance = clearance, nose = nose, popped = popped}

func run() -> void:
	for pace: float in [6.0, 10.0, 14.0, 18.0]:
		var r := corner(pace)
		print("TURN %.0f m/s: yaw %.2f, entry %.3f, slip %.2f°, speed %.2f" % [pace, r.heading, r.entry, r.slip, r.bike.speed])
		check(not r.bike.crashed and r.slip < 5.0, "устойчивая дуга на %.0f м/с" % pace)
		check(r.entry > 0.06 and r.heading > (0.9 if pace >= 14.0 else 1.2), "поворот начинает менять курс без долгого ожидания")
		check(absf(r.bike.lateral_speed) < 0.04 and absf(r.bike._yaw_rate) < 0.01, "отпущенный руль стабилизирует велосипед")
	var brake := corner(16.0, 60, true)
	check(not brake.bike.crashed and brake.slip < 12.0, "полный тормоз в повороте оставляет управление")
	var loose := corner(14.0)
	w.surface = RoadSurface.SAND
	var sand := corner(14.0)
	check(sand.heading < loose.heading and not sand.bike.crashed, "рыхлая поверхность расширяет дугу предсказуемо")
	w.surface = RoadSurface.PACKED
	var slow := corner(14.0, 30)
	var fast := corner(14.0, 120)
	check(absf(slow.heading - fast.heading) < 0.03, "поворот совпадает при 30 и 120 Гц")
	var correcting := bike(14.0)
	correcting.lateral_speed = 4.0
	for i in 60: tick(correcting)
	check(not correcting.crashed and absf(correcting.lateral_speed) < 0.05, "ошибка входа выправляется без езды боком")
	var reversing := bike(-1.5)
	for i in 30: tick(reversing, 1.0, false, 60, -1.0)
	check(reversing.heading > 0.05 and not reversing.crashed, "задний ход сохраняет правильное направление руля")
	var left := bike(14.0)
	for i in 30: tick(left, 1.0)
	for i in 30: tick(left, -1.0)
	check(left._yaw_rate > 0.2 and left.lean > 0.05 and not left.crashed, "перекладка руля плавная и уверенная")
	for grade: float in [-0.45, -0.25, 0.0, 0.25, 0.45]:
		var coast := hop_ride(grade, -2.0)
		check(coast.takeoffs == 0, "ровный склон %+.2f не создаёт ложных отрывов" % grade)
		for delay: float in [0.1, 0.15, 0.2, 0.3]:
			var r := hop_ride(grade, delay)
			print("HOP grade %+.2f Q→E %.2f: %d takeoffs, %.3f m" % [grade, delay, r.takeoffs, r.clearance])
			check(r.popped and r.takeoffs == 1 and r.clearance > 0.15 and not r.bike.crashed, "Q→E рабочий на уклоне, без повторного прыжка")
		var auto := hop_ride(grade, -1.0, 60, true)
		print("SPACE grade %+.2f: %d takeoffs, %.3f m" % [grade, auto.takeoffs, auto.clearance])
		check(auto.popped and auto.takeoffs == 1 and auto.clearance > 0.12 and not auto.bike.crashed, "Space надёжно прыгает на уклоне %+.2f" % grade)
	ground.gradient = Vector2.ZERO
	var q := hop_ride(0.0, -1.0)
	var nothing := hop_ride(0.0, -2.0)
	var simultaneous := hop_ride(0.0, 0.0)
	check(q.nose > 0.08 and q.takeoffs == 0 and nothing.takeoffs == 0 and simultaneous.takeoffs == 0, "Q поднимает только переднее; для прыжка нужна последовательность")
	var overlap := hop_ride(-0.25, 0.2, 60, false, true)
	check(overlap.takeoffs == 1, "E завершает прыжок при ещё зажатой Q")
	var late := hop_ride(0.0, 0.9)
	var manual := hop_ride(0.0, 0.2)
	var auto := hop_ride(0.0, -1.0, 60, true)
	check(late.takeoffs == 0 and manual.clearance > auto.clearance + 0.15, "точный ручной прыжок выше автоматического; поздний E не создаёт прыжок")
	for pace: float in [0.0, 14.0]:
		var r := hop_ride(-0.25, 0.2, 60, false, false, pace)
		check(r.takeoffs == 1 and r.clearance > 0.15, "баннихоп доступен при %.0f м/с" % pace)
	var h30 := hop_ride(-0.25, 0.2, 30)
	var h120 := hop_ride(-0.25, 0.2, 120)
	check(h30.takeoffs == 1 and h120.takeoffs == 1 and absf(h30.clearance - h120.clearance) < 0.06, "баннихоп совпадает при 30 и 120 Гц")
	ground.crest = true
	var crest := hop_ride(0.0, 0.2)
	check(crest.popped and crest.clearance > 0.15 and not crest.bike.crashed, "подготовленный прыжок работает у перегиба спуска")
	ground.crest = false
	ground.gradient = Vector2.ZERO
	var edge := bike()
	edge.airborne = true
	edge.air_time = 0.03
	edge._coyote = BikeRide.HOP_COYOTE
	edge.y += 0.1
	tick(edge, 0.0, true)
	check(edge.vy > 1.0 and edge._coyote == 0.0, "Space прощает нажатие сразу после схода с кромки")
	var buffered := bike()
	buffered.airborne = true
	buffered.air_time = 0.4
	buffered.y += 0.04
	buffered.vy = -3.0
	tick(buffered, 0.0, true)
	var jumped := false
	for i in 35:
		tick(buffered)
		jumped = jumped or buffered._hop_used
	check(jumped, "Space перед приземлением сохраняется и запускает следующий прыжок")
	var air := bike()
	air.airborne = true
	air.y += 8.0
	air.air_time = 0.5
	tick(air, 0.0, true)
	for i in 20: tick(air)
	check(air.vy < 0.0 and air._auto_hop < 0.0, "пробел в затяжном полёте не создаёт второй прыжок")
	var reset := hop_ride(0.0, 0.15).bike as BikeRide
	reset.reset_motion()
	check(reset._hop_link == 0.0 and not reset._hop_used and reset._auto_hop < 0.0, "сброс очищает подготовку и очередь прыжка")
	print("friendly: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
