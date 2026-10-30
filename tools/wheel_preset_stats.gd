extends SceneTree
## Статистика езды по готовым трассам Trail Lab (TrailLabCatalog) для модели двух контактов: автопилот в разных
## манерах, прежняя и новая модель, тот же ввод. Без мира, только замеры. Ищет боковое скатывание (велосипед едет
## боком быстрее, чем вперёд), сходы с трассы, нехватку руля (руль упёрт, а курс не догоняет) и падения.
##   godot --headless --path . --script res://tools/wheel_preset_stats.gd -- --presets 2,5,9 [--seed 2910 --count 10] [--sim 40]
## Без --presets берёт count случайных трасс из каталога (кроме полигона 1) по seed.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
## манера: имя, целевая скорость, тормозит ли перед поворотом, педали изо всех сил (Shift)
## и разгружает ли переднее колесо (Q) перед каждым низким препятствием на линии
const STYLES := [["медленно 4", 4.0, false, false, false], ["осторожно 9", 9.0, true, false, false], ["быстро 13", 13.0, false, false, false],
	["быстро 13 + Q", 13.0, false, false, true], ["максимум", 30.0, false, true, false]]
const LAT_SAFE := 6.0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 560)
	run.call_deferred()


## Станции низких препятствий (их встречает колесо) не дальше половины ширины от оси
func obstacle_stations(d: TrailDefinition, solids: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for n in range(0, solids.size(), ForestObstacles.STRIDE):
		if solids[n + 6] - solids[n + 5] > ForestObstacles.CLIMB_MAX: continue
		var mid := Vector2(solids[n] + solids[n + 2], solids[n + 1] + solids[n + 3]) * 0.5
		var near := d.nearest(mid)
		if absf(near.y) < d.width * 0.5 + 0.5: out.append(near.x - solids[n + 4])
	out.sort()
	return out


func ride(h: Heightfield, d: TrailDefinition, contact: bool, style: Array, sim: float, obstacles := PackedFloat32Array()) -> Dictionary:
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
	b.speed = minf(style[1], 6.0)
	var control := BikeController.new()
	var length := d.route_length()
	var half := d.width * 0.5
	var s := {done = false, time = 0.0, crash = {}, off_time = 0.0, off_max = 0.0, off_sum = 0.0, side_time = 0.0, side_max = 0.0,
		hits = 0, hit_loss = 0.0, light_time = 0.0, landings = 0, land_max = 0.0, pulls = 0, sat_time = 0.0, sat_side = 0.0, sat_load = 0.0, sat_light = 0.0, sat_air = 0.0, sat_slip = 0.0, sat_speed = 0.0, lag_time = 0.0, slip = 0.0, speed_sum = 0.0, ticks = 0, station = 0.0, side_where = PackedStringArray()}
	var station := 1.0
	var t := 0.0
	var side_run := 0.0
	var pressed := -1.0
	var next_obstacle := 0
	while t < sim:
		var near := d.nearest(Vector2(b.x, b.z))
		if near.x > station - 30.0: station = maxf(station, near.x)
		if station >= length - 3.0:
			s.done = true
			break
		var look := maxf(4.0, absf(b.speed) * 0.6)
		var aim := d.point_at(minf(station + look, length))
		var delta := aim - Vector2(b.x, b.z)
		var error := wrapf(atan2(-delta.x, -delta.y) - b.heading, -PI, PI)
		var steer := clampf(-error * 2.0, -1.0, 1.0)
		var want: float = style[1]
		if style[2]:
			for ahead: float in [4.0, 8.0, 12.0, 16.0, 20.0]:
				var k := absf(d.curvature_at(minf(station + ahead, length)))
				if k > 0.0001: want = minf(want, maxf(4.0, sqrt(LAT_SAFE / k)))
		var throttle := clampf((want - b.speed) * 0.5, -1.0, 1.0)
		if throttle < 0.0 and b.speed - want < 1.0: throttle = 0.0
		h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1)
		# Q: рывок так, чтобы пик пришёлся на касание кромки передним колесом (за 0,5 м до препятствия)
		var pull := false
		if style[4]:
			while next_obstacle < obstacles.size() and obstacles[next_obstacle] < station + BikeRide.HUB: next_obstacle += 1
			if next_obstacle < obstacles.size() and pressed < 0.0:
				var to_contact := (obstacles[next_obstacle] - 0.5 - station - BikeRide.HUB) / maxf(absf(b.speed), 0.5)
				if to_contact <= BikeRide.BODY_LEAD:
					pressed = t
					s.pulls += 1
			if pressed >= 0.0:
				pull = t - pressed < 0.3
				if t - pressed > 0.5: pressed = -1.0
		b.body_back = pull
		var hits_before := b.impacts.x + b.impacts.y
		var dv_before := b.hit_dv
		var was_air := b.airborne
		control.ride(dt, p, b, h.world, h, throttle, steer, style[3], false, false)
		t += dt
		if b.impacts.x + b.impacts.y > hits_before:
			s.hits += b.impacts.x + b.impacts.y - hits_before
			s.hit_loss += (b.hit_dv.x if b.hit_dv.x != dv_before.x else 0.0) + (b.hit_dv.y if b.hit_dv.y != dv_before.y else 0.0)
		if b.land_impact > 0.0 and was_air:
			s.landings += 1
			s.land_max = maxf(s.land_max, b.land_impact)
		b.land_impact = 0.0
		if not b.airborne and b.load_f + b.load_r < 0.3: s.light_time += dt
		if b.crashed:
			var cause: String = BikeRide.CrashCause.keys()[b.crash_cause]
			s.crash[cause] = s.crash.get(cause, 0) + 1
			var back := d.point_at(station)
			b.reset_motion()
			b.x = back.x
			b.z = back.y
			b.y = h.surface_at(back.x, back.y, -INF)
			b.heading = d.heading_at(station)
			b.mount(p)
			b.speed = 4.0
			continue
		var off := absf(d.nearest(Vector2(b.x, b.z)).y)
		s.off_max = maxf(s.off_max, off)
		s.off_sum += off
		if off > half: s.off_time += dt
		if not b.airborne:
			# боком: поперёк рамы быстрее, чем вдоль, при заметном движении
			var sideways := absf(b.lateral_speed) > maxf(absf(b.speed), 0.3) and Vector2(b.speed, b.lateral_speed).length() > 0.8
			if sideways:
				s.side_time += dt
				side_run += dt
				s.side_max = maxf(s.side_max, absf(b.lateral_speed))
			elif side_run > 0.0:
				if s.side_where.size() < 4: s.side_where.append("%.0f м (%.1f с, %s, уклон поперёк %.0f%%)" % [station, side_run, "вне трассы" if off > half else "на трассе", b.bank_slope * 100.0])
				side_run = 0.0
		s.slip = maxf(s.slip, absf(b.slip))
		# нехватка руля: руль упёрт, а курс отстаёт от нужного больше чем на 15°
		if absf(steer) >= 0.999:
			s.sat_time += dt
			# что держит руль на пределе: нагрузка шины переднего колеса, снос, полёт
			s.sat_side += b.side_f * dt
			s.sat_load += b.load_f * dt
			s.sat_light += dt if b.side_f < 0.3 else 0.0
			s.sat_air += dt if b.airborne else 0.0
			s.sat_slip += absf(b.slip) * dt
			s.sat_speed += absf(b.speed) * dt
		if absf(error) > 0.26: s.lag_time += dt
		s.speed_sum += b.speed
		s.ticks += 1
	s.time = t
	s.station = station
	return s


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var presets := []
	if "--presets" in args:
		presets = Array(args[args.find("--presets") + 1].split(",")).map(func(x: String) -> int: return int(x))
	else:
		var rng := RandomNumberGenerator.new()
		rng.seed = int(args[args.find("--seed") + 1]) if "--seed" in args else 2910
		var pool := range(2, TrailLabCatalog.LIST.size() + 1)
		var count := int(args[args.find("--count") + 1]) if "--count" in args else 10
		while presets.size() < count and not pool.is_empty():
			presets.append(pool.pop_at(rng.randi() % pool.size()))
	var sim := float(args[args.find("--sim") + 1]) if "--sim" in args else 40.0
	print("Трассы: ", presets)
	print("трасса | манера | модель | конец | время | ср. м/с | падения | вне трассы с | с оси макс/ср м | боком с (макс м/с) | руль упёрт с | курс отстаёт с | снос °")
	for number: int in presets:
		var kit := TrailLabCatalog.routes(number - 1, Fixture)
		var prepared := Fixture.prepare(kit, true, TrailLabCatalog.LIST[number - 1].ground)
		if not prepared.errors.is_empty():
			print("трасса %d не собрана: %s" % [number, prepared.errors])
			continue
		var h: Heightfield = prepared.heights
		var technical := TrailTechnical.build(h, kit)
		h.obstacles.set_trail(technical.collide, technical.bumps)
		var d := kit[0]
		var stations := obstacle_stations(d, technical.collide)
		for style: Array in STYLES:
			for contact in [false, true]:
				h.obstacles.update(d.points[0].x, d.points[0].y, PackedFloat32Array(), 1, true)
				var r := ride(h, d, contact, style, sim, stations)
				var n := maxf(1, r.ticks)
				print("%d %s | %s | %s | %s | %.1f | %.1f | %s | %.1f | %.2f/%.2f | %.1f (%.1f) | %.1f | %.1f | %.0f%s" % [number, d.title, style[0], "новая" if contact else "старая",
					"да" if r.done else "%.0f м" % r.station, r.time, r.speed_sum / n, str(r.crash) if not r.crash.is_empty() else "-", r.off_time,
					r.off_max, r.off_sum / n, r.side_time, r.side_max, r.sat_time, r.lag_time, rad_to_deg(r.slip),
					"" if r.side_where.is_empty() else "  · боком: " + "; ".join(r.side_where)])
				print("    препятствий встречено %d (потеря %.1f м/с), рывков Q %d, без опоры на земле %.1f с, приземлений %d (сильнейшее %.1f м/с)" % [
					r.hits, r.hit_loss, r.pulls, r.light_time, r.landings, r.land_max])
				if r.sat_time > 0.5:
					var st: float = r.sat_time
					print("    руль упёрт %.1f с: скорость %.1f м/с, шина перед %.2f (нагрузка %.2f), лёгкое перед %.0f%%, в полёте %.0f%%, снос %.0f°" % [st,
						r.sat_speed / st, r.sat_side / st, r.sat_load / st, 100.0 * r.sat_light / st, 100.0 * r.sat_air / st, rad_to_deg(r.sat_slip / st)])
	quit(0)
