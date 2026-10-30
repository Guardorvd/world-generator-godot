extends "res://tools/trail_polygon_audit.gd"
## Новая информация о запасе на ошибку. Изолированные настоящие участки №15/16/17, без правок физики.
## --preset 15|16|17. Каждый сценарий начинается заново; внутри него нет переносов/продолжения после падения.
const DT := 1.0 / 60.0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()

func run() -> void:
	started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	var number := int(args[args.find("--preset") + 1]) if "--preset" in args else 15
	out_path = "res://tools/control/runs/forgiveness_%d" % number
	if "--soft" in args: out_path += "_soft"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path))
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
	var corner := 0.0
	var sharpest := 0.0
	var table: TrailElement
	var pump: TrailElement
	for e in d.elements:
		if e.profile == TrailElement.Profile.BERM and absf(d.curvature_at(e.station)) > sharpest and e.station > 80.0:
			sharpest = absf(d.curvature_at(e.station))
			corner = e.station
		if e.profile == TrailElement.Profile.TABLETOP and (table == null or e.height > table.height): table = e
		if e.profile == TrailElement.Profile.PUMP and pump == null: pump = e
	var straight := straight_window()
	var climb := climb_window()
	var revision_output: Array = []
	var revision_code := OS.execute("git", ["rev-parse", "--short", "HEAD"], revision_output)
	var revision := str(revision_output[0]).strip_edges() if revision_code == 0 and not revision_output.is_empty() else "unknown"
	result = {revision = revision, preset = number, runs = [], skipped = [], sites = {
		corner = corner, radius = 1.0 / sharpest, table = table.station, pump = pump.station, straight = straight, climb = climb}}
	print("SITES ", number, " ", result.sites)
	if "--follow-up" in args:
		out_path += "_followup"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path))
		follow_up(number, corner, pump)
		result.elapsed_ms = Time.get_ticks_msec() - started
		save_result()
		print("FOLLOWUP COMPLETE ", result.runs.size(), " scenarios; wall ", result.elapsed_ms)
		quit(0)
		return
	# Вход начинается за 24 м до центра дуги, скорость одинаковая. Ошибки заданы только в начальном состоянии.
	for mode: String in ["reference", "outside", "inside", "wrong_heading", "delay_150", "delay_300", "brake", "body_back", "body_forward"]:
		measure({name = "turn_" + mode, group = "turn", mode = mode, from = corner - 24.0, to = corner + 60.0,
			feature = corner - 6.0, speed = 13.0, turn_sign = signf(d.curvature_at(corner)), max_time = 18.0})
	# Одинаковый вылет: действие начинается только после первого отрыва, не меняя исходную скорость на рампе.
	for mode: String in ["neutral", "body_back", "body_forward", "brake", "steer"]:
		measure({name = "landing_" + mode, group = "landing", mode = mode, from = table.station - table.length * 0.5 - 15.0,
			to = minf(d.route_length() - 2.0, table.station + table.length * 0.5 + 30.0), feature = table.station, speed = 17.0, max_time = 12.0})
	for mode: String in ["on", "off", "manual", "space", "steer", "brake"]:
		measure({name = "pump_" + mode, group = "pump", mode = mode, from = pump.station - pump.length * 0.5 - 12.0,
			to = pump.station + pump.length * 0.5 + 24.0, feature = pump.station - pump.length * 0.25, speed = 11.0, max_time = 15.0})
	for strength: float in [0.5, 1.0]:
		measure({name = "stop_%.1f" % strength, group = "stop", mode = "brake", from = straight.x + 2.0,
			to = minf(d.route_length() - 2.0, straight.x + 180.0), feature = straight.x + 2.0, speed = 13.0, strength = strength, max_time = 10.0})
	if number == 17:
		for mode: String in ["fresh", "exhausted", "boost"]:
			measure({name = "climb_" + mode, group = "climb", mode = mode, from = climb.x, to = climb.y,
				feature = climb.x, speed = 4.0, max_time = 40.0})
	result.elapsed_ms = Time.get_ticks_msec() - started
	save_result()
	print("FORGIVENESS COMPLETE ", result.runs.size(), " scenarios; wall ", result.elapsed_ms)
	quit(0)

func follow_up(number: int, corner: float, pump: TrailElement) -> void:
	if number == 15:
		for variant: Dictionary in [
			{mode = "manual", speed = 11.0, prep = 0.1, shift = 0.0},
			{mode = "manual", speed = 11.0, prep = 0.3, shift = 0.0},
			{mode = "manual", speed = 11.0, prep = 0.2, shift = -2.0},
			{mode = "manual", speed = 11.0, prep = 0.2, shift = 2.0},
			{mode = "manual", speed = 13.0, prep = 0.2, shift = 0.0},
			{mode = "on", speed = 13.0, prep = 0.2, shift = 0.0},
			{mode = "off", speed = 13.0, prep = 0.2, shift = 0.0},
			{mode = "space", speed = 13.0, prep = 0.2, shift = 0.0},
		]:
			measure({name = "pump_%s_v%d_p%.1f_shift%.0f" % [variant.mode, variant.speed, variant.prep, variant.shift],
				group = "pump", mode = variant.mode, from = pump.station - pump.length * 0.5 - 12.0,
				to = pump.station + pump.length * 0.5 + 24.0, feature = pump.station - pump.length * 0.25 + variant.shift,
				speed = variant.speed, prep = variant.prep, max_time = 15.0})
	if number == 17:
		for variant: Dictionary in [
			{speed = 13.0, duration = 0.2, shift = 0.0}, {speed = 13.0, duration = 0.4, shift = 0.0},
			{speed = 8.0, duration = 0.6, shift = 0.0}, {speed = 10.0, duration = 0.6, shift = 0.0},
			{speed = 13.0, duration = 0.6, shift = 16.0},
		]:
			measure({name = "q_v%d_hold%.1f_shift%.0f" % [variant.speed, variant.duration, variant.shift],
				group = "turn", mode = "body_back", from = corner - 24.0, to = corner + 24.0,
				feature = corner - 6.0 + variant.shift, speed = variant.speed, duration = variant.duration,
				turn_sign = signf(d.curvature_at(corner)), max_time = 18.0})

func straight_window() -> Vector2:
	var best := Vector2.ZERO
	var start := -1.0
	for i in range(20, floori(d.route_length()) - 20):
		var clear := absf(d.curvature_at(i)) < 0.008
		for e in d.elements:
			if absf(i - e.station) < e.length * 0.5 + 3.0: clear = false
		if clear and start < 0.0: start = i
		if not clear and start >= 0.0:
			if i - start > best.y - best.x: best = Vector2(start, i)
			start = -1.0
	return best

func climb_window() -> Vector2:
	var best := Vector2.ZERO
	var rise := -INF
	for i in range(30, floori(d.route_length()) - 120, 5):
		var a := d.point_at(i)
		var b := d.point_at(i + 100)
		var delta := h.surface_at(b.x, b.y, INF) - h.surface_at(a.x, a.y, INF)
		if delta > rise:
			rise = delta
			best = Vector2(i, i + 100)
	return best

func measure(spec: Dictionary) -> void:
	if Time.get_ticks_msec() - started > 205000:
		result.skipped.append(spec)
		save_result()
		return
	var measured := probe(spec)
	result.runs.append(measured)
	save_result()
	print("PROBE ", spec.name, " ", measured.status, " s %.1f, t %.2f, off %.2f/%.2f s, slip %.1f, impact %.2f, speed %.2f, air %.2f" % [
		measured.station, measured.time, measured.off_max, measured.off_time, measured.slip_max, measured.impact, measured.exit_speed, measured.air_time])

func probe(spec: Dictionary) -> Dictionary:
	var p := PlayerState.new()
	var b := BikeRide.new()
	var tangent := d.tangent_at(spec.from)
	# The authored lateral vector is the clockwise normal: positive curvature places outside on its positive side.
	var offset := float(spec.get("turn_sign", 1.0)) * (0.9 if spec.mode == "outside" else (-0.9 if spec.mode == "inside" else 0.0))
	var at := d.point_at(spec.from) + Vector2(tangent.y, -tangent.x) * offset
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(at.x, at.y, -INF)
	b.heading = d.heading_at(spec.from)
	if spec.mode == "wrong_heading": b.heading -= float(spec.turn_sign) * deg_to_rad(12.0)
	b.mount(p)
	b.speed = spec.speed
	b.pump_enabled = not (spec.group == "pump" and spec.mode == "off")
	var control := BikeController.new()
	if spec.mode == "exhausted": control.stamina.value = 0.0; control.stamina.exhausted = true
	var pilot := Pilot.new()
	pilot.reset(d, h, spec.from)
	var r := {spec = spec, status = "simulation_limit", station = spec.from, time = 0.0, off_max = absf(offset), off_time = 0.0,
		slip_max = 0.0, side_max = 0.0, air_time = 0.0, impact = 0.0, jumps = 0, lands = [], load_min = 10.0,
		saturated_time = 0.0, no_front_time = 0.0, steer_saturated = 0.0, pump_time = 0.0, interference = 0.0, lift_max = 0.0, hop_height = 0.0,
		stamina_min = control.stamina.value, exhausted_time = 0.0, boost_time = 0.0, recover_time = -1.0, hits = 0,
		stop_distance = -1.0, stop_time = -1.0, crash = null, exit_speed = b.speed, speed_min = b.speed}
	var rows := PackedStringArray(["t,s,speed,lateral_m,heading_error_deg,slip_deg,air,turn,throttle,body,load_f,load_r,use_f,use_r,brake_pressure,brake_skid,brake_risk,pump_accel,pump_reach,stamina,tilt"])
	var station: float = spec.from
	var t := 0.0
	var event := -1.0
	var first_air := -1.0
	var after_land := -1.0
	var stable := 0.0
	var queue: Array[Dictionary] = []
	var stop_from := Vector2.ZERO
	var stop_at := -1.0
	h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1, true)
	while t < spec.max_time:
		var input := pilot.drive(b, d)
		input.run = false
		input.jump = false
		if spec.mode in ["delay_150", "delay_300"]:
			queue.append(input.duplicate())
			var ticks := 9 if spec.mode == "delay_150" else 18
			input = queue.pop_front() if queue.size() > ticks else {throttle = 0.0, turn = 0.0, run = false, jump = false}
		if event < 0.0 and station >= spec.feature: event = t
		var active := event >= 0.0 and t - event < float(spec.get("duration", 1.0 if spec.mode == "brake" else 0.6))
		b.body_back = false
		b.body_forward = false
		if spec.group == "turn" and active:
			if spec.mode == "brake": input.throttle = -1.0
			b.body_back = spec.mode == "body_back"
			b.body_forward = spec.mode == "body_forward"
		if spec.group == "landing":
			# Run-in at the same speed; steering still follows the real route.
			input.throttle = clampf((17.0 - b.speed) * 0.6, -1.0, 1.0)
			var flight_action := first_air >= 0.0 and (after_land < 0.0 or t - after_land < 0.5)
			if flight_action:
				b.body_back = spec.mode == "body_back"
				b.body_forward = spec.mode == "body_forward"
				if spec.mode == "brake": input.throttle = -1.0
				if spec.mode == "steer" and t - first_air < 0.2: input.turn = 0.6
		if spec.group == "pump":
			input.throttle = 0.0
			if active:
				if spec.mode == "manual":
					var prep: float = spec.get("prep", 0.2)
					b.body_back = t - event < prep
					b.body_forward = t - event >= prep and t - event < prep + 0.2
				if spec.mode == "space": input.jump = t - event < DT * 0.5
				if spec.mode == "brake": input.throttle = -1.0
				if spec.mode == "steer" and t - event < 0.2: input.turn = 0.6
		if spec.group == "stop":
			input.throttle = -float(spec.strength) if t >= 0.5 else 0.0
			if stop_at < 0.0 and t >= 0.5:
				stop_at = t
				stop_from = Vector2(b.x, b.z)
		if spec.group == "climb":
			input.throttle = 1.0
			input.run = spec.mode == "boost"
		h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1)
		var was_air := b.airborne
		var previous_speed := b.speed
		var previous_tilt := b.tilt
		var previous_hits := b.impacts.x + b.impacts.y
		control.ride(DT, p, b, h.world, h, input.throttle, input.turn, input.run, input.jump, false)
		t += DT
		var near := local_near(Vector2(b.x, b.z), station)
		if is_finite(near.z): station = maxf(station, near.x)
		var off := absf(near.y) if is_finite(near.z) else 80.0
		var heading_error := absf(wrapf(b.heading - d.heading_at(station), -PI, PI))
		r.off_max = maxf(r.off_max, off)
		r.off_time += DT if off > d.width * 0.5 else 0.0
		r.slip_max = maxf(r.slip_max, absf(rad_to_deg(b.slip)) if not b.airborne else 0.0)
		r.side_max = maxf(r.side_max, absf(b.lateral_speed))
		r.air_time += DT if b.airborne else 0.0
		r.load_min = minf(r.load_min, minf(b.tire_f, b.tire_r))
		r.lift_max = maxf(r.lift_max, b.lift_f)
		# BikeRide.hop_height has no valid takeoff origin on an ordinary terrain flight.
		# Only the explicitly armed bunny hop may contribute to this diagnostic.
		if b._hop_used: r.hop_height = maxf(r.hop_height, b.hop_height)
		r.no_front_time += DT if not b.airborne and not b.contact_f() else 0.0
		r.saturated_time += DT if not b.airborne and maxf(b.use_f, b.use_r) > 0.95 else 0.0
		r.steer_saturated += DT if absf(input.turn) > 0.99 else 0.0
		r.impact = maxf(r.impact, b.land_impact)
		r.speed_min = minf(r.speed_min, b.speed)
		r.hits += b.impacts.x + b.impacts.y - previous_hits
		r.stamina_min = minf(r.stamina_min, control.stamina.value)
		r.exhausted_time += DT if control.stamina.exhausted else 0.0
		r.boost_time += DT if input.run and control.stamina.can_boost(true, input.throttle) else 0.0
		r.pump_time += DT if b.pump_accel > 0.00001 else 0.0
		if input.throttle < -0.05 or absf(input.turn) > 0.25 or input.jump or b.body_back or b.body_forward:
			r.interference = maxf(r.interference, absf(b.pump_accel) + absf(b.pump_load) + b._pump_reach)
		if b.airborne and not was_air:
			r.jumps += 1
			if first_air < 0.0: first_air = t
		if was_air and not b.airborne:
			if after_land < 0.0: after_land = t
			r.lands.append({s = station, t = t, impact = b.land_impact, speed_before = previous_speed, speed_after = b.speed,
				tilt_before = rad_to_deg(previous_tilt), body = b.body_x, off = off, pressure = b.brake_pressure})
		stable = stable + DT if off < 0.35 and heading_error < deg_to_rad(5.0) and absf(b.slip) < deg_to_rad(3.0) and not b.airborne else 0.0
		if r.recover_time < 0.0 and stable >= 0.5: r.recover_time = t - 0.5
		rows.append("%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.5f,%.4f,%.4f,%.4f" % [t, station, b.speed, near.y, rad_to_deg(heading_error), rad_to_deg(b.slip), int(b.airborne), input.turn, input.throttle, b.body_x, b.tire_f, b.tire_r, b.use_f, b.use_r, b.brake_pressure, b.brakes.skid, b.brakes.risk, b.pump_accel, b._pump_reach, control.stamina.value, b.tilt])
		if b.crashed:
			r.status = "crash"
			r.crash = {cause = BikeRide.CrashCause.keys()[b.crash_cause], s = station, impact = b.land_impact}
			break
		if spec.group == "stop" and stop_at >= 0.0 and absf(b.speed) < 0.1:
			r.status = "stopped"
			r.stop_distance = stop_from.distance_to(Vector2(b.x, b.z))
			r.stop_time = t - stop_at
			break
		if station >= spec.to: r.status = "finished"; break
		if off > 12.0: r.status = "lost_line"; break
		b.land_impact = 0.0
		b.bottom_out = 0.0
	r.time = t
	r.station = station
	r.exit_speed = b.speed
	var file := FileAccess.open(out_path + "/" + str(spec.name) + ".csv", FileAccess.WRITE)
	file.store_string("\n".join(rows))
	return r
