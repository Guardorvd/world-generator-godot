extends SceneTree
## No authored elements: full production steps over arbitrary profiles, both bike models and manual overrides.
const Friendly = preload("res://tools/bike_friendly_test.gd")
class Ground extends Friendly.TestGround:
	var profile: Callable = func(_s: float) -> float: return 0.0
	var wet := false
	var deck := false
	var unknown := false
	func ground_at(_x: float, pz: float, _raw := false) -> float:
		return 100.0 + float(profile.call(-pz))
	func known(_x: float, pz: float) -> bool:
		return not unknown
	func immersion_at(_x: float, _z: float, _feet: float) -> float:
		return 0.2 if wet else 0.0
	func deck_at(_x: float, _z: float, _feet: float) -> float:
		return 100.0 if deck else -INF

var world := Friendly.TestWorld.new()
var ground := Ground.new(world)
var failures := 0
var checks := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("auto_pump: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func bike(enabled := true, pace := 8.0, contact := true) -> BikeRide:
	var b := BikeRide.new()
	b.pump_enabled = enabled
	b.contact_model = contact
	b.y = ground.surface_at(0.0, 0.0, -INF)
	b.mount(PlayerState.new())
	b.speed = pace
	return b

func ride(profile: Callable, enabled := true, pace := 8.0, seconds := 4.0, hz := 60, contact := true, action := "") -> Dictionary:
	ground.profile = profile
	var b := bike(enabled, pace, contact)
	var p := PlayerState.new()
	var out := {air = 0.0, motion = 0.0, accel = 0.0, load = 0.0, boost = 0.0, speed = pace, height = 0.0, popped = false}
	for i in roundi(seconds * hz):
		var t := float(i) / hz
		b.body_back = action == "manual" and t >= 0.8 and t < 1.0
		b.body_forward = action == "manual" and t >= 1.0 and t < 1.2
		b.step(p, -0.6 if action == "brake" and t >= 0.8 else 0.0, 0.0, false, action == "space" and i == roundi(0.8 * hz), 1.0 / hz, world, ground)
		out.air += 1.0 / hz if b.airborne else 0.0
		out.motion = maxf(out.motion, absf(b.pump_motion))
		out.accel = maxf(out.accel, b.pump_accel)
		out.load = maxf(out.load, absf(b.pump_load))
		out.boost += b.pump_accel / hz
		out.speed = b.speed
		out.height = maxf(out.height, b.y - b._contact(b.x, b.z, ground))
		out.popped = out.popped or b._hop_used
		if b.crashed: break
	out.bike = b
	return out

func run() -> void:
	var flat := func(_s: float) -> float: return 0.0
	var hill := func(s: float) -> float: return -s * 0.25
	var waves := func(s: float) -> float: return 0.25 * (1.0 - cos(s * TAU / 6.0))
	var rolling := func(s: float) -> float: return -s * 0.2 + 0.22 * (1.0 - cos(s * TAU / 7.0))
	var single := func(s: float) -> float: return 0.4 * pow(sin(PI * clampf((s - 3.0) / 8.0, 0.0, 1.0)), 2.0)
	for profile: Callable in [flat, hill]:
		var on := ride(profile)
		var off := ride(profile, false)
		check(on.accel < 0.00001 and on.motion < 0.001 and absf(on.speed - off.speed) < 0.0001, "плоскость и постоянный уклон не создают памп или ускорение")
	for contact: bool in [false, true]:
		for profile: Callable in [waves, rolling, single]:
			var on := ride(profile, true, 8.0, 4.0, 60, contact)
			var off := ride(profile, false, 8.0, 4.0, 60, contact)
			print("PROFILE contact=%s: air %.3f/%.3f motion %.3f dv %.3f boost %.3f" % [contact, on.air, off.air, on.motion, on.speed - off.speed, on.boost])
			check(on.motion > 0.015 and on.boost > 0.0005 and not on.bike.crashed and not on.popped, "рельеф без разметки: работа телом и ограниченная помощь, без баннихопа")
			check(on.air <= off.air + 0.1, "памп не создаёт дополнительных отрывов на волнах")
	var a := ride(waves, true, 8.0, 5.0, 30)
	var b := ride(waves, true, 8.0, 5.0, 120)
	check(absf(a.speed - b.speed) < 0.03 and absf(a.bike.z - b.bike.z) < 0.05, "30/120 Гц совпадают")
	var high := ride(waves, true, 16.0, 2.0)
	check(high.accel < 0.00001, "на большой скорости автопамп не добавляет тягу")
	var tiny := ride(func(s: float) -> float: return 0.003 * sin(s * 5.0))
	check(tiny.accel < 0.0001 and tiny.motion < 0.001, "мелкое зерно земли не превращается в двигатель")
	var ramp := func(s: float) -> float: return clampf(s - 3.0, 0.0, 5.0) * 0.4
	var ledge := func(s: float) -> float: return -3.0 if s > 5.0 else 0.0
	var step := func(s: float) -> float: return 0.35 if s > 5.0 else 0.0
	for profile: Callable in [ramp, ledge, step]:
		var on := ride(profile)
		var off := ride(profile, false)
		check(absf(on.air - off.air) < 0.08 and absf(on.height - off.height) < 0.1, "трамплин, край и ступень сохраняют штатный отрыв/столкновение")
	for action: String in ["manual", "space"]:
		var on := ride(waves, true, 8.0, 2.0, 60, true, action)
		check(on.popped and on.height > 0.1, "ручное действие перехватывает памп: " + action)
	# Direct same-substep override after active pumping; only pose may return smoothly.
	ground.profile = waves
	for action: String in ["Q", "E", "jump", "brake", "steer"]:
		var rider := bike()
		var player := PlayerState.new()
		for i in 40: rider.step(player, 0.0, 0.0, false, false, 1.0 / 60, world, ground)
		rider.body_back = action == "Q"
		rider.body_forward = action == "E"
		rider.step(player, -1.0 if action == "brake" else 0.0, 0.4 if action == "steer" else 0.0, false, action == "jump", 1.0 / 120, world, ground)
		check(rider.pump_accel == 0.0 and rider.pump_load == 0.0 and rider._pump_reach == 0.0, "мгновенный приоритет " + action)
		rider.body_back = false
		rider.body_forward = false
		for i in 6: rider.step(player, 0.0, 0.0, false, false, 1.0 / 60, world, ground)
		check(rider.pump_accel == 0.0 and rider._pump_reach == 0.0, "пауза после ручного действия: " + action)
		var resumed := false
		for i in 120:
			rider.step(player, 0.0, 0.0, false, false, 1.0 / 60, world, ground)
			resumed = resumed or rider.pump_accel > 0.0001
		check(resumed and not rider.crashed, "плавный возврат автоматики: " + action)
	ground.profile = waves
	var flying := bike()
	flying.airborne = true
	flying.y += 5.0
	flying.pump_motion = 0.5
	flying.step(PlayerState.new(), 1.0, 0.0, false, false, 1.0 / 60, world, ground)
	check(flying.pump_accel == 0.0 and flying.pump_load == 0.0 and flying._pump_reach == 0.0, "в полёте нет сил пампа")
	for obstacle: String in ["wet", "deck", "unknown"]:
		ground.set(obstacle, true)
		var r := ride(waves)
		check(r.accel == 0.0 and r.motion < 0.001, "нет пампа: " + obstacle)
		ground.set(obstacle, false)
	var reverse := ride(waves, true, -1.5)
	check(reverse.accel == 0.0 and reverse.motion == 0.0, "задним ходом памп отключён")
	var repeat := ride(waves, true, 12.0, 25.0)
	check(repeat.bike.horizontal_velocity().length() < BikeRide.PUMP_TOP + 0.5 and not repeat.bike.crashed, "долгая серия волн не разгоняет бесконечно")
	repeat.bike.reset_motion()
	check(repeat.bike.pump_motion == 0.0 and repeat.bike.pump_accel == 0.0 and repeat.bike._pump_reach == 0.0, "сброс очищает автоматику")
	print("auto_pump: %d failures / %d checks" % [failures, checks])
	quit(1 if failures else 0)
