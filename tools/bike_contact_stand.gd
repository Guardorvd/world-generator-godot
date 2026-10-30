extends "res://tools/trail_polygon_audit.gd"
## Стенд контакта колеса с объектом трассы (30.10.2026): одна сборка готовой трассы без мира, несколько заездов к
## выбранному месту и разбор каждой встречи колеса с кромкой — что ударило (бревно, камень), высота, угол встречи,
## скорость подхода, доля нагрузки, доля порога через руль, был ли перед этим отрыв и с каким ударом приземление.
## godot --headless --path . --script res://tools/bike_contact_stand.gd -- [--preset 17] [--at 801] [--trace]
## Только замеры; падения — результат, не ошибка. Лимит 150 с.
const DT := 1.0 / 60.0
var trace := false
var corner := 0.0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	run.call_deferred()

func run() -> void:
	started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	var number := int(args[args.find("--preset") + 1]) if "--preset" in args else 17
	var at := float(args[args.find("--at") + 1]) if "--at" in args else 801.0
	trace = "--trace" in args
	var kit := TrailLabCatalog.routes(number - 1, Fixture)
	d = kit[0]
	var prepared := Fixture.prepare(kit, true, TrailLabCatalog.LIST[number - 1].ground)
	if not prepared.errors.is_empty():
		print("BUILD FAILED ", prepared.errors)
		quit(1)
		return
	h = prepared.heights
	var technical := TrailTechnical.build(h, kit)
	h.obstacles.set_trail(technical.collide, technical.bumps)
	print("BUILD %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	# Объекты трассы рядом с местом: станция, смещение от оси, высота, радиус, длина
	var solids: PackedFloat32Array = technical.collide
	for n in range(0, solids.size(), ForestObstacles.STRIDE):
		var mid := Vector2(solids[n] + solids[n + 2], solids[n + 1] + solids[n + 3]) * 0.5
		var near := d.nearest(mid, 12.0)
		if is_finite(near.z) and absf(near.x - at) < 25.0:
			print("OBJECT s %.1f off %+.2f tall %.2f r %.2f len %.2f" % [near.x, near.y, solids[n + 6] - solids[n + 5], solids[n + 4],
				Vector2(solids[n], solids[n + 1]).distance_to(Vector2(solids[n + 2], solids[n + 3]))])
	for e in d.elements:
		if absf(e.station - at) < 30.0:
			print("ELEMENT %s s %.1f len %.1f h %.2f count %d" % [TrailElement.Profile.keys()[e.profile], e.station, e.length, e.height, e.count])
	if "--start" in args:
		# Старт с места, как R в лаборатории: полный газ 4 с, состояние каждые 0,25 с — что держит велосипед
		for station in Array(args[args.find("--start") + 1].split(",")).map(func(s: String) -> float: return float(s)):
			start_probe(station)
		quit(0)
		return
	var sharpest := 0.0
	for e in d.elements:
		if e.profile == TrailElement.Profile.BERM and absf(d.curvature_at(e.station)) > sharpest and e.station > 80.0:
			sharpest = absf(d.curvature_at(e.station))
			corner = e.station
	for v: float in [6.0, 10.0, 14.0, 16.0, 18.0]:
		probe_hit({name = "coast_%d" % v, from = at - 16.0, to = at + 10.0, speed = v, pedal = false})
	probe_hit({name = "flow_pedal", from = at - 40.0, to = at + 10.0, speed = 10.0, pedal = true})
	probe_hit({name = "flow_space", from = at - 40.0, to = at + 10.0, speed = 10.0, pedal = true, jump = true})
	probe_hit({name = "brake_into", from = at - 16.0, to = at + 10.0, speed = 10.0, pedal = false, brake = 1.2})
	# Случай прежнего аудита: Q 0,2 с в дуге перед бревном, без автоматических прыжков
	if corner > 0.0 and corner < at:
		for hold: float in [0.2, 0.4]:
			probe_hit({name = "q_arc_%.1f" % hold, from = corner - 24.0, to = at + 10.0, speed = 13.0, pedal = true, q_at = corner - 6.0, q_hold = hold})
	print("STAND COMPLETE %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	quit(0)

func start_probe(station: float) -> void:
	var p := PlayerState.new()
	var b := BikeRide.new()
	var at := d.point_at(station)
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(at.x, at.y, -INF)
	b.heading = d.heading_at(station)
	b.mount(p)
	var control := BikeController.new()
	h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1, true)
	var start := Vector2(b.x, b.z)
	print("START s %.1f: fits %s, grade %+.3f, surface %.2f, obstacles near %d" % [station, b.fits(b.x, b.z, b.heading, h.world, h), b.grade(h), b.y, h.obstacles.data.size() / ForestObstacles.STRIDE])
	for i in 240:
		h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1)
		control.ride(DT, p, b, h.world, h, 1.0, 0.0, false, false, false)
		if i % 15 == 14 or b.crashed:
			print("  t %.2f v %.2f moved %.2f effort %.2f drive %.2f/%.2f slope %+.2f roll %.2f rough %.2f brake %.2f air %d fits %s on %d/%d tire %.2f/%.2f crashed %s" % [
				(i + 1) * DT, b.speed, start.distance_to(Vector2(b.x, b.z)), b.effort, b.drive_request, b.drive_force, b.slope_force, b.roll_loss, b.rough_loss,
				b.brake_pressure, int(b.airborne), b.fits(b.x, b.z, b.heading, h.world, h), b._on_f, b._on_r, b.tire_f, b.tire_r, b.crashed])
		if b.crashed: break

func probe_hit(spec: Dictionary) -> void:
	var p := PlayerState.new()
	var b := BikeRide.new()
	var start := d.point_at(spec.from)
	b.x = start.x
	b.z = start.y
	b.y = h.surface_at(start.x, start.y, -INF)
	b.heading = d.heading_at(spec.from)
	b.mount(p)
	b.speed = spec.speed
	var control := BikeController.new()
	var pilot := Pilot.new()
	pilot.reset(d, h, spec.from)
	h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1, true)
	var station: float = spec.from
	var t := 0.0
	var q_from := -1.0
	var last_land := -10.0
	var last_land_impact := 0.0
	var air_before := 0.0
	var history: Array[String] = []
	var hits := 0
	var status := "finished"
	while t < 14.0:
		var input := pilot.drive(b, d)
		input.run = false
		input.jump = input.jump and spec.get("jump", false)
		if not spec.pedal: input.throttle = minf(input.throttle, 0.0)
		if spec.has("brake") and station > spec.from + 6.0: input.throttle = -1.0 if station < spec.from + 6.0 + spec.brake * 10.0 else 0.0
		b.body_back = false
		if spec.has("q_at") and station >= spec.q_at and q_from < 0.0: q_from = t
		if q_from >= 0.0 and t - q_from < spec.q_hold: b.body_back = true
		h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1)
		var was_air := b.airborne
		var before := b.impacts
		var tire_before := Vector2(b.tire_f, b.tire_r)
		control.ride(DT, p, b, h.world, h, input.throttle, input.turn, input.run, input.jump, false)
		t += DT
		var near := local_near(Vector2(b.x, b.z), station)
		if is_finite(near.z): station = maxf(station, near.x)
		if b.airborne: air_before = t
		if was_air and not b.airborne:
			last_land = t
			last_land_impact = b.land_impact
		history.append("  t %.2f s %.2f v %.2f air %d vy %+.2f tire %.2f/%.2f load %.2f/%.2f sq %.3f/%.3f lift %.2f/%.2f body %+.2f on %d/%d" % [
			t, station, b.speed, int(b.airborne), b.vy, b.tire_f, b.tire_r, b.load_f, b.load_r, b.squash_f, b.squash_r, b.lift_f, b.lift_r, b.body_x, b._on_f, b._on_r])
		if history.size() > 30: history.pop_front()
		if b.impacts != before:
			hits += 1
			var hit: Dictionary = b.last_hit
			print("HIT %s %s s %.2f v %.2f off %+.2f | angle %.1f° approach %.2f share %.2f (tire before %.2f) rise %.2f soak %.2f dv %.2f endo %.2f | ground %.2f support %.2f vy %+.2f lift %.2f | landed %.2f s ago (impact %.2f), last air %.2f s ago, crash %s" % [
				spec.name, "front" if hit.front else "rear", station, b.speed, near.y, rad_to_deg(hit.angle), hit.approach, hit.share,
				tire_before.x if hit.front else tire_before.y, hit.rise, hit.soak, hit.dv, hit.endo, hit.ground, hit.support, hit.vy, hit.lift,
				t - last_land, last_land_impact, t - air_before, BikeRide.CrashCause.keys()[b.crash_cause] if b.crashed else "-"])
			if trace and (b.crashed or hit.endo > 0.6):
				print("\n".join(history))
		if b.crashed:
			status = "crash %s s %.2f land %.2f slip %.1f°" % [BikeRide.CrashCause.keys()[b.crash_cause], station, b.land_impact, rad_to_deg(b.slip)]
			if trace and b.crash_cause != BikeRide.CrashCause.OBSTACLE: print("\n".join(history))
			break
		if station >= spec.to: break
		if absf(near.y) > 12.0 or not is_finite(near.z): status = "lost_line"; break
		b.land_impact = 0.0
	print("RUN %s: %s, hits %d, t %.2f, speed %.2f" % [spec.name, status, hits, t, b.speed])
