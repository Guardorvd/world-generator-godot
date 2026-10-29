extends SceneTree
## Статистика заездов для модели двух контактов (BikeRide.contact_model): все курсы Trail Lab (1–9) на ровной земле,
## автопилот с разными манерами и скоростями, прежняя и новая модель с тем же вводом. Без мира, только замеры:
## дошёл ли до конца, время, падения, уход с оси, рывки рыскания, снос, доля тактов на пределе сцепления колёс.
##   godot --headless --path . --script res://tools/wheel_ride_stats.gd [-- --courses 1,8 --sim 40]
const Fixture = preload("res://tools/trail_lab_fixture.gd")
## манера: целевая скорость и тормозит ли седок перед поворотом (по кривизне впереди)
const STYLES := [["осторожно 9", 9.0, true], ["осторожно 13", 13.0, true], ["быстро 13", 13.0, false], ["быстро 17", 17.0, false]]
const LAT_SAFE := 6.0 # осторожный седок едет поворот так, чтобы боковое ускорение было не больше этого, м/с²


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 420)
	run.call_deferred()


func ride(h: Heightfield, d: TrailDefinition, contact: bool, target: float, careful: bool, sim: float) -> Dictionary:
	var hz := 60
	var dt := 1.0 / hz
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = contact
	var at := d.point_at(1.0)
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(1.0)
	b.mount(p)
	b.speed = minf(target, 8.0)
	var control := BikeController.new()
	var length := d.route_length()
	var s := {done = false, time = 0.0, crashes = 0, off_max = 0.0, off_sum = 0.0, jerk = 0.0, slip = 0.0, sat_f = 0, sat_r = 0,
		unload = 0.0, air = 0.0, ticks = 0, station = 0.0, speed_sum = 0.0}
	var prev_rate := 0.0
	var prev_heading := b.heading
	var station := 1.0
	var t := 0.0
	while t < sim:
		var near := d.nearest(Vector2(b.x, b.z))
		# замкнутый курс: станция растёт только вперёд, без скачка через начало
		if near.x > station - 30.0: station = maxf(station, near.x)
		if station >= length - 3.0:
			s.done = true
			break
		var look := maxf(4.0, absf(b.speed) * 0.6)
		var aim := d.point_at(minf(station + look, length))
		var delta := aim - Vector2(b.x, b.z)
		var steer := clampf(-wrapf(atan2(-delta.x, -delta.y) - b.heading, -PI, PI) * 2.0, -1.0, 1.0)
		var want := target
		if careful:
			for ahead: float in [4.0, 8.0, 12.0, 16.0, 20.0]:
				var k := absf(d.curvature_at(minf(station + ahead, length)))
				if k > 0.0001: want = minf(want, maxf(4.0, sqrt(LAT_SAFE / k)))
		var throttle := clampf((want - b.speed) * 0.5, -1.0, 1.0)
		if throttle < 0.0 and b.speed - want < 1.0: throttle = 0.0
		control.ride(dt, p, b, h.world, h, throttle, steer, false, false, false)
		t += dt
		if b.crashed:
			s.crashes += 1
			# заново на оси с той же станции: считаем, сколько раз упал за заезд
			var back := d.point_at(station)
			b.reset_motion()
			b.x = back.x
			b.z = back.y
			b.y = h.surface_at(back.x, back.y, -INF)
			b.heading = d.heading_at(station)
			b.mount(p)
			b.speed = 4.0
			prev_heading = b.heading
			continue
		var rate := wrapf(b.heading - prev_heading, -PI, PI) / dt
		prev_heading = b.heading
		s.jerk += absf(rate - prev_rate)
		prev_rate = rate
		var off := absf(d.nearest(Vector2(b.x, b.z)).y)
		s.off_max = maxf(s.off_max, off)
		s.off_sum += off
		s.slip = maxf(s.slip, absf(b.slip))
		s.speed_sum += b.speed
		if b.airborne:
			s.air += dt
		else:
			s.sat_f += int(b.use_f > 0.98)
			s.sat_r += int(b.use_r > 0.98)
			if not b.contact_f() or not b.contact_r(): s.unload += dt
		s.ticks += 1
	s.time = t
	s.station = station
	return s


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var courses := [1, 2, 3, 4, 5, 6, 7, 8, 9]
	if "--courses" in args: courses = Array(args[args.find("--courses") + 1].split(",")).map(func(x: String) -> int: return int(x))
	var sim := float(args[args.find("--sim") + 1]) if "--sim" in args else 40.0
	print("курс | манера | модель | конец | время с | средн м/с | падений | с оси макс/средн м | рывки | снос ° | предел перед/зад % | без опоры с | полёт с")
	var totals := {}
	for index: int in courses:
		var kit := Fixture.course(index)
		var prepared := Fixture.prepare(kit)
		if not prepared.errors.is_empty():
			print("курс %d не собран: %s" % [index, prepared.errors])
			continue
		var h: Heightfield = prepared.heights
		var technical := TrailTechnical.build(h, kit)
		h.obstacles.set_trail(technical.collide, technical.bumps)
		var d := kit[0]
		for style: Array in STYLES:
			for contact in [false, true]:
				var r := ride(h, d, contact, style[1], style[2], sim)
				var n := maxf(1, r.ticks)
				var model := "новая" if contact else "старая"
				print("%d %s | %s | %s | %s | %5.1f | %4.1f | %d | %4.2f / %4.2f | %5.3f | %4.1f | %4.1f / %4.1f | %4.2f | %4.2f" % [index, d.title, style[0], model,
					"да" if r.done else "%.0f м" % r.station, r.time, r.speed_sum / n, r.crashes, r.off_max, r.off_sum / n, r.jerk / n, rad_to_deg(r.slip),
					100.0 * r.sat_f / n, 100.0 * r.sat_r / n, r.unload, r.air])
				var key: String = model + " · " + str(style[0])
				var tot: Dictionary = totals.get(key, {runs = 0, done = 0, crashes = 0, time = 0.0, off = 0.0, jerk = 0.0})
				tot.runs += 1
				tot.done += int(r.done)
				tot.crashes += r.crashes
				tot.time += r.time
				tot.off += r.off_sum / n
				tot.jerk += r.jerk / n
				totals[key] = tot
	print("\nИтог по манерам:")
	for key: String in totals:
		var tot: Dictionary = totals[key]
		print("  %s: доехал %d/%d, падений %d, время %.0f с, средний уход с оси %.2f м, рывки %.4f" % [key, tot.done, tot.runs, tot.crashes, tot.time, tot.off / tot.runs, tot.jerk / tot.runs])
	quit(0)
