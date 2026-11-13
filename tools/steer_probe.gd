extends SceneTree
## Замер поворота без генерации: настоящие Controls.bike_steer и BikeRide на ровном склоне.
## Для каждой скорости и уклона: короткое нажатие (TAP_TIME) — на сколько градусов довернул курс и на сколько метров
## сместилась линия за секунду; удержание 2 с — установившаяся угловая скорость, радиус дуги, боковое ускорение.
## Скорость удерживается (задаётся перед каждым тактом), чтобы сравнивать руль, а не разгон.
## 13.11: волны — тот же замер на спуске с волнами (колёса то прижаты, то разгружены): как гуляет угловая скорость
## при удержании (средняя, наименьшая, наибольшая за последние 1,5 с), наибольший снос и нагрузка переднего колеса.
## Запуск: godot --headless --path . --script res://tools/steer_probe.gd  (секунды)
class Ground extends Heightfield:
	var grade := 0.0
	var wave := 0.0 # м: высота волн поперёк хода (длина WAVE_LENGTH)
	func ground_at(_x: float, z: float, _raw := false) -> float:
		return 100.0 - grade * z + wave * sin(z * TAU / WAVE_LENGTH)
	func depth_at(_x: float, _z: float, _feet := -INF) -> float: return 0.0
	func known(_x: float, _z: float) -> bool: return true

class World extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = RoadSurface.PACKED}

const HZ := 60
const TAP_TIME := 0.12
const WAVE_LENGTH := 10.0
const WAVE_HEIGHT := 0.06

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
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
		rate = (b.heading - last) / dt
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
