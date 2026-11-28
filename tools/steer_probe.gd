extends SceneTree
## Замер поворота без генерации: настоящие Controls.bike_steer и BikeRide на ровном склоне.
## Для каждой скорости и уклона: короткое нажатие (TAP_TIME) — на сколько градусов довернул курс и на сколько метров
## сместилась линия за секунду; удержание 2 с — установившаяся угловая скорость, радиус дуги, боковое ускорение.
## Скорость удерживается (задаётся перед каждым тактом), чтобы сравнивать руль, а не разгон.
## 13.11: волны — тот же замер на спуске с волнами (колёса то прижаты, то разгружены): как гуляет угловая скорость
## при удержании (средняя, наименьшая, наибольшая за последние 1,5 с), наибольший снос и нагрузка переднего колеса.
## Запуск: godot --headless --path . --script res://tools/steer_probe.gd -- --sync
## --assert проверяет контракты на той же последовательности ввода.
class Ground extends Heightfield:
	var grade := 0.0
	var wave := 0.0 # м: высота волн поперёк хода (длина WAVE_LENGTH)
	var bank := 0.0
	var profile := ""
	var samples := 0
	func ground_at(x: float, z: float, _raw := false) -> float:
		var d := -z
		var h := 100.0 + grade * d + bank * x + wave * sin(z * TAU / WAVE_LENGTH)
		match profile:
			"ripple": return h + 0.045 * sin(d * TAU / 1.8)
			"step": return h + (0.08 if d >= 5.0 and d < 7.0 else 0.0)
			"roller": return h + 0.45 * pow(sin(PI * clampf((d - 3.0) / 5.0, 0.0, 1.0)), 2.0)
			"ramp": return h + clampf((d - 3.0) * 0.42, 0.0, 1.05)
			"drop": return h - (0.50 if d >= 7.0 else 0.0)
			"edge": return h + (0.24 if x < -0.32 else 0.0)
		return h
	func surface_at(x: float, z: float, feet: float) -> float:
		samples += 1
		return super.surface_at(x, z, feet)
	func depth_at(_x: float, _z: float, _feet := -INF) -> float: return 0.0
	func known(_x: float, _z: float) -> bool: return true

class World extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = RoadSurface.PACKED}

const HZ := 60
const TAP_TIME := 0.12
const WAVE_LENGTH := 10.0
const WAVE_HEIGHT := 0.06
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	if "--sync" in OS.get_cmdline_user_args():
		sync_probe()
		return
	print("уклон газ скорость | нажатие: курс°  смещение м | °/с через 0,6 с | удержание 2 с: °/с  радиус м  бок. м/с²  руль  снос")
	# уклон, газ (+) или тормоз (-): ровно накатом, подъём с педалями, спуск накатом, спуск с тормозом (половина и полный)
	for mode: Vector2 in [Vector2(0, 0), Vector2(0.25, 1), Vector2(-0.3, 0), Vector2(-0.3, -0.5), Vector2(-0.3, -1)]:
		var grade := mode.x
		for pace: float in ([2.0, 3.5, 5.0, 7.0] if mode.y > 0.0 else [3.0, 6.0, 10.0, 14.0, 18.0, 24.0]):
			var tap := ride(grade, pace, TAP_TIME, 1.0, mode.y)
			var hold := ride(grade, pace, 2.0, 2.0, mode.y)
			var early := ride(grade, pace, 0.6, 0.6, mode.y) # дуга через 0,6 с удержания: то, что чувствуется в начале поворота
			print("%5.2f %4.1f %5.1f м/с | %6.1f  %6.2f | %5.1f | %6.1f  %6.1f  %5.1f  %4.2f  %5.2f%s" % [grade, mode.y, pace,
				tap.turned, tap.offset, early.rate, hold.rate, pace / maxf(deg_to_rad(hold.rate), 0.001),
				pace * deg_to_rad(hold.rate), hold.steer, hold.slip, ("  ПАДЕНИЕ %d" % hold.cause) if hold.crashed or tap.crashed else ""])
	print("волны (спуск 0,15, удержание 2 с) | °/с средняя  наименьшая  наибольшая | снос макс °  перед мин (доля веса)")
	for pace: float in [10.0, 14.0, 18.0, 22.0]:
		var r := ride(-0.15, pace, 2.0, 2.0, 0.0, WAVE_HEIGHT)
		print("%5.1f м/с | %6.1f  %6.1f  %6.1f | %5.1f  %4.2f%s" % [pace, r.mean, r.low, r.high, rad_to_deg(r.peak_slip), r.front,
			("  ПАДЕНИЕ %d" % r.cause) if r.crashed else ""])
	quit(0)

func ride(grade: float, pace: float, press: float, total: float, throttle := 0.0, wave := 0.0) -> Dictionary:
	var w := World.new()
	var h := Ground.new()
	h.world = w
	h.grade = grade
	h.wave = wave
	var b := BikeRide.new()
	var c := Controls.new()
	b.riding = true
	b.y = 100.0
	b.speed = pace
	var p := PlayerState.new()
	var dt := 1.0 / HZ
	for tick in HZ: # разгон модели: нагрузки колёс и подвеска успокаиваются
		b.speed = pace
		b.step(p, maxf(throttle, 0.0), 0.0, false, false, dt, w, h)
	var h0 := b.heading
	var x0 := b.x
	var z0 := b.z
	var last := b.heading
	var rate := 0.0
	var sum := 0.0
	var count := 0
	var low := INF
	var high := 0.0
	var peak_slip := 0.0
	var front := INF
	for tick in roundi(total * HZ):
		if throttle >= 0.0: b.speed = pace # с тормозом скорость после входа свободная: вечный полный тормоз на 18 м/с — не езда
		last = b.heading
		b.step(p, throttle, c.bike_steer(1.0 if tick * dt < press else 0.0, dt, b.speed), false, false, dt, w, h)
		rate = angle_difference(last, b.heading) / dt
		if b.crashed: break
		peak_slip = maxf(peak_slip, absf(b.slip))
		if tick * dt >= 0.5:
			sum += absf(rate)
			count += 1
			low = minf(low, absf(rate))
			high = maxf(high, absf(rate))
			front = minf(front, b.load_f)
	var side := Vector2(cos(h0), -sin(h0)) # вправо от исходного курса (курс 0 — на -Z)
	return {turned = absf(rad_to_deg(b.heading - h0)), offset = absf(Vector2(b.x - x0, b.z - z0).dot(side)),
		rate = absf(rad_to_deg(rate)), steer = absf(b.steer), slip = b.slip, crashed = b.crashed, cause = b.crash_cause,
		mean = rad_to_deg(sum / maxi(count, 1)), low = rad_to_deg(low), high = rad_to_deg(high), peak_slip = peak_slip, front = front}


func sync_probe() -> void:
	print("PHYSICS ", BikePhysicsConfig.VERSION, " | сырые входы на одинаковых тактах 60 Гц")
	for pace: float in [3.0, 6.0, 10.0, 14.0, 18.0, 24.0]:
		sync_ride("тап", pace, "", 0.0, 0.0)
		sync_ride("серия", pace, "", 0.0, 0.0)
		if pace >= 10.0:
			sync_ride("дуга", pace, "", -0.30, 0.28)
			sync_ride("тормоз", pace, "", -0.30, 0.28)
			sync_ride("дуга", pace, "ripple", -0.15, 0.0)
	for profile: String in ["step", "roller", "ramp", "drop"]:
		for pace: float in [8.0, 16.0]:
			sync_ride("накат", pace, profile, 0.0, 0.0)
	sync_ride("дуга", 14.0, "edge", 0.0, 0.0)
	sync_ride("прыжок", 12.0, "", 0.0, 0.0)
	print("SYNC проверок с нарушениями ", failures)
	quit(1 if failures > 0 else 0)


func sync_ride(mode: String, pace: float, profile: String, grade: float, bank: float) -> void:
	var w := World.new()
	var h := Ground.new()
	h.world = w
	h.grade = grade
	h.bank = bank
	h.profile = profile
	var p := PlayerState.new()
	var b := BikeRide.new()
	var c := Controls.new()
	var dt := 1.0 / HZ
	b.y = h.ground_at(0.0, 0.0)
	b.mount(p)
	b.speed = pace
	var takeoffs := 0
	var landings := 0
	var air_ticks := 0
	var wrong_side := 0
	var yaw_gaps := 0
	var peak_accel := 0.0
	var peak_roll := 0.0
	var peak_impact := 0.0
	var max_y_step := 0.0
	var max_frame_step := 0.0
	var max_wheel := 0.0
	var min_wheel := INF
	var front := 100.0
	var rear := 100.0
	var frame_y := b.y
	var y := b.y
	var elapsed_us := 0
	var ticks := 0
	for i in 120:
		var steer_in := 0.0
		match mode:
			"тап": steer_in = 1.0 if i < 7 else 0.0
			"серия": steer_in = (1.0 if floori(i / 12.0) % 2 == 0 else -1.0) if i < 48 else 0.0
			"дуга", "тормоз": steer_in = 1.0
		var turn := c.bike_steer(steer_in, dt, b.speed)
		var throttle := c.bike_brake(-0.75, dt) if mode == "тормоз" else 0.0
		var was_air := b.airborne
		var heading := b.heading
		var at := Vector2(b.x, b.z)
		var stamp := Time.get_ticks_usec()
		b.step(p, throttle, turn, false, mode == "прыжок" and i == 15, dt, w, h)
		elapsed_us += Time.get_ticks_usec() - stamp
		ticks += 1
		var yaw := angle_difference(heading, b.heading)
		var mid := heading + yaw * 0.5
		var side := (Vector2(b.x, b.z) - at).dot(Vector2(cos(mid), -sin(mid)))
		if steer_in != 0.0 and i >= 10 and absf(b.steer) >= 0.28:
			wrong_side += int(not was_air and yaw * b.steer < -0.0005 and side * b.steer < -0.0005)
			yaw_gaps += int(absf(yaw) < 0.0005 and b.speed > 4.0)
		peak_accel = maxf(peak_accel, absf(yaw * b.speed / dt))
		peak_roll = maxf(peak_roll, absf(b.lean))
		takeoffs += int(b.airborne and not was_air)
		landings += int(not b.landing_info.is_empty())
		air_ticks += int(b.airborne)
		peak_impact = maxf(peak_impact, b.land_impact)
		front = b.y + b.ground_f
		rear = b.y + b.ground_r
		var extension: Variant = b.get("ground_extension")
		var next_frame := (front + rear - b.squash_f - b.squash_r) * 0.5 + (0.0 if extension == null else float(extension))
		if i > 2:
			max_y_step = maxf(max_y_step, absf(b.y - y))
			max_frame_step = maxf(max_frame_step, absf(next_frame - frame_y))
			max_wheel = maxf(max_wheel, front)
			min_wheel = minf(min_wheel, front)
		frame_y = next_frame
		y = b.y
		b.clear_tick_events()
		if b.crashed: break
	print("%s %-6s %4.0f | курс %6.1f° x %6.2f | a %.2f крен %.2f против %d паузы %d | полёт %d/%d %d т. удар %.2f | ход %.0f/%.0f мм колесо %.0f мм | %.1f проб/т %.1f мкс/т | авария %s" % [
		mode, profile, pace, rad_to_deg(b.heading), b.x, peak_accel, peak_roll, wrong_side, yaw_gaps,
		takeoffs, landings, air_ticks, peak_impact, max_y_step * 1000.0, max_frame_step * 1000.0,
		(max_wheel - min_wheel) * 1000.0, float(h.samples) / ticks, float(elapsed_us) / ticks, b.crashed])
	if "--assert" not in OS.get_cmdline_user_args():
		return
	var clean := not b.crashed and wrong_side == 0 and yaw_gaps == 0
	if profile == "edge":
		clean = clean and peak_accel <= b.config.max_lat_accel + 0.02
	if profile in ["ripple", "step"]:
		clean = clean and takeoffs == 0
	if profile == "step":
		clean = clean and max_frame_step < 0.025
	if profile == "drop" or (profile == "ramp" and pace >= 16.0) or mode == "прыжок":
		clean = clean and takeoffs == 1 and landings == 1
	if not clean:
		failures += 1
		printerr("FAIL %s %s %.0f" % [mode, profile, pace])
