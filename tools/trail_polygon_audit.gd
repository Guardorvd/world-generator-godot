extends SceneTree
## Read-only audit of preset 15. One prepared polygon, production controller/autopilot, no crash teleports.
## godot --headless --path . --script res://tools/trail_polygon_audit.gd
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const Polygon = preload("res://scripts/lab/trail_lab_polygon.gd")
const Pilot = preload("res://scripts/lab/trail_autopilot.gd")
const OUT := "res://tools/control/runs/polygon_audit"
var out_path := OUT
var started := 0
var result := {runs = [], skipped = []}
var d: TrailDefinition
var h: Heightfield

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()

func save_result() -> void:
	var file := FileAccess.open(out_path + "/results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))

func add_run(spec: Dictionary) -> void:
	# End cleanly with partial results well before the hard watchdog if a machine is unexpectedly slow.
	if Time.get_ticks_msec() - started > 245000:
		result.skipped.append(spec)
		save_result()
		return
	var measured := ride(spec)
	result.runs.append(measured)
	save_result()
	print("AUDIT ", spec.name, " | ", measured.status, " | s %.1f/%.1f | %.2f s | avg %.1f top %.1f km/h | off %.2f s | slip %.1f deg | land %.2f | hits %d | stamina %.2f" % [
		measured.station, spec.to, measured.time, measured.average_kmh, measured.top * 3.6, measured.off_time,
		measured.slip_ground, measured.land_max, measured.hits, measured.stamina_min])

func run() -> void:
	started = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var kit := TrailLabCatalog.routes(14, Fixture)
	d = kit[0]
	var prepared := Fixture.prepare(kit, true, "polygon")
	if not prepared.errors.is_empty():
		print("AUDIT BUILD FAILED ", prepared.errors)
		quit(1)
		return
	h = prepared.heights
	var technical := TrailTechnical.build(h, kit)
	h.obstacles.set_trail(technical.collide, technical.bumps)
	result.build_ms = Time.get_ticks_msec() - started
	result.build_timings = prepared.timings
	var revision_output := []
	var revision_code := OS.execute("git", ["rev-parse", "--short", "HEAD"], revision_output)
	result.revision = str(revision_output[0]).strip_edges() if revision_code == 0 and not revision_output.is_empty() else "unknown"
	result.scope = "Production BikeController, contact_model=true, authored objects and world tree trunks; no streamed decorative understory, no ragdoll/reset time."
	var survey := TrailSurvey.measure(h, d, 0.2)
	result.geometry = {length = d.route_length(), width = d.width, climb = survey.climb, descent = survey.descent,
		grade_peak = survey.peak_grade, grade_track = survey.peak_grade_track, local_peak = survey.peak_local,
		cross_peak = survey.peak_cross, min_radius = survey.min_radius, deck_length = survey.deck_length,
		unmeasured = survey.unmeasured, exceeded = survey.exceeded, summary = survey.summary()}
	result.elements = []
	for i in d.elements.size():
		var e := d.elements[i]
		result.elements.append({index = i, kind = TrailElementLibrary.title(e.profile), profile = e.profile, station = e.station,
			length = e.length, height = e.height, width_parameter = e.gap, count = e.count})
	result.profile = []
	for i in survey.stations.size():
		var at := d.point_at(survey.stations[i])
		result.profile.append({s = survey.stations[i], x = at.x, z = at.y, y = survey.support[i],
			grade = survey.grade[i] if is_finite(survey.grade[i]) else null, curvature = survey.curvature[i], layer = survey.layers[i]})
	var line := Polygon._line()
	result.corners = Array(line.corners)
	var gap := Polygon._crossing(d)
	result.gap = gap
	print("AUDIT BUILD ", result.build_ms, " ms; ", survey.summary())
	# Full rides: no resume after falls; completion is never inferred from an assisted reset.
	for style: String in Pilot.ORDER:
		add_run({name = style, style = style, mode = "pilot", from = 1.0, to = d.route_length() - 3.0, speed = 4.0, max_time = 420.0, hz = 60})
	add_run({name = "flow_without_gap_knowledge", style = "flow", mode = "no_gap", from = 1.0, to = d.route_length() - 3.0, speed = 4.0, max_time = 420.0, hz = 60})
	add_run({name = "keyboard_taps", style = "flow", mode = "keyboard", from = 1.0, to = d.route_length() - 3.0, speed = 4.0, max_time = 420.0, hz = 60})
	add_run({name = "coast_only", style = "flow", mode = "coast", from = 1.0, to = d.route_length() - 3.0, speed = 8.0, max_time = 420.0, hz = 60})
	# Gap: same short run-in with no hidden acceleration command; record the speed actually reached at takeoff.
	for pace: float in [8.0, 11.0, 14.0, 16.0, 18.0]:
		add_run({name = "gap_coast_%02d" % pace, style = "flow", mode = "coast", from = gap - 16.0, to = gap + 32.0, speed = pace, max_time = 15.0, hz = 60})
	add_run({name = "gap_late_brake", style = "flow", mode = "brake", from = gap - 24.0, to = gap + 32.0, speed = 14.0, max_time = 15.0, hz = 60})
	var log_element: TrailElement
	var skinny: TrailElement
	var pump: TrailElement
	for e in d.elements:
		if e.profile == TrailElement.Profile.LOG: log_element = e
		if e.profile == TrailElement.Profile.NORTHSHORE and skinny == null: skinny = e
		if e.profile == TrailElement.Profile.PUMP and e.station > gap and pump == null: pump = e
	for mode: String in ["axis", "space", "manual", "bypass"]:
		add_run({name = "log_" + mode, style = "flow" if mode != "bypass" else "careful", mode = mode,
			from = log_element.station - 18.0, to = log_element.station + 16.0, speed = 9.0, target = 9.0, feature = log_element.station, max_time = 20.0, hz = 60})
	for offset: float in [0.0, 0.4, 0.8, -0.8]:
		add_run({name = "skinny_offset_%+.1f" % offset, style = "flow", mode = "fixed_speed", from = skinny.station - skinny.length * 0.5 - 2.0,
			to = skinny.station + skinny.length * 0.5 + 10.0, speed = 9.0, target = 9.0, offset = offset, max_time = 15.0, hz = 60})
	for mode: String in ["coast", "pump_body"]:
		add_run({name = "pump_" + mode, style = "flow", mode = mode, from = pump.station - pump.length * 0.5 - 8.0,
			to = pump.station + pump.length * 0.5 + 8.0, speed = 12.0, feature = pump.station, feature_length = pump.length, feature_count = pump.count, max_time = 15.0, hz = 60})
	result.elapsed_ms = Time.get_ticks_msec() - started
	save_result()
	print("AUDIT COMPLETE ", result.runs.size(), " runs; skipped ", result.skipped.size(), "; wall ", result.elapsed_ms, " ms; ", ProjectSettings.globalize_path(OUT))
	quit(0 if result.skipped.is_empty() else 2)

## Pick only segments close in route station, so crossing another level cannot falsify progress or lateral error.
func local_near(at: Vector2, station: float) -> Vector3:
	var among := PackedInt32Array()
	var first := maxi(1, d._along.bsearch(maxf(0.0, station - 12.0)))
	var last := mini(d.points.size() - 1, d._along.bsearch(station + 28.0) + 1)
	for i in range(first, last + 1): among.append(i)
	return d.nearest(at, 80.0, among)

func ride(spec: Dictionary) -> Dictionary:
	var dt: float = 1.0 / spec.hz
	var pilot := Pilot.new()
	pilot.style = spec.style
	pilot.reset(d, h, spec.from)
	if spec.mode == "no_gap": pilot.gaps.clear()
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = true
	b.pump_enabled = spec.get("pump", true)
	var tangent := d.tangent_at(spec.from)
	var at: Vector2 = d.point_at(spec.from) + Vector2(tangent.y, -tangent.x) * spec.get("offset", 0.0)
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(spec.from)
	b.mount(p)
	b.speed = spec.speed
	h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1, true)
	var controller := BikeController.new()
	var r := {spec = spec, status = "simulation_limit", time = 0.0, station = spec.from, distance = 0.0, top = b.speed, off_time = 0.0,
		off_max = 0.0, off_integral = 0.0, slip_ground = 0.0, sideways_time = 0.0, steer_saturated = 0.0, air_time = 0.0,
		pedal_time = 0.0, brake_time = 0.0, boost_time = 0.0, coast_time = 0.0, hits = 0, land_max = 0.0, bottom_outs = 0,
		stamina_min = 1.0, jump_presses = 0, pop_count = 0, pump_time = 0.0, pump_boost = 0.0, pump_motion = 0.0, flights = [], events = [], elements = [], crash = null}
	for e in d.elements:
		r.elements.append({enter = -1.0, exit = -1.0, air = 0.0, off = 0.0, slip = 0.0, land = 0.0, hits = 0, deck_time = 0.0, samples = 0})
	var rows := PackedStringArray(["t,s,x,y,z,speed,lateral,slip_deg,air,turn,throttle,stamina,load_f,load_r,bank,clearance"])
	var station: float = spec.from
	var t := 0.0
	var still := 0.0
	var lost := 0.0
	var off_previous := false
	var flight := {}
	var jumped := false
	var manual_time := -1.0
	var popped_previous := false
	while t < spec.max_time:
		var input := pilot.drive(b, d)
		if spec.mode == "brake_release" and t < 1.0:
			input.throttle = -1.0
			input.jump = false
			input.run = false
		if spec.mode == "keyboard": input.turn = signf(input.turn) if absf(input.turn) > 0.18 else 0.0
		if spec.mode in ["coast", "pump_body"]: input.throttle = 0.0; input.jump = false; input.run = false
		if spec.mode == "brake": input.throttle = -1.0; input.jump = false; input.run = false
		if spec.mode in ["axis", "space", "manual", "bypass", "fixed_speed"]:
			input.throttle = clampf((float(spec.target) - b.speed) * 0.6, -1.0, 1.0)
			input.run = false
			input.jump = false
			if spec.mode in ["axis", "space", "manual"]:
				var aim := d.point_at(station + maxf(4.0, b.speed * 0.55)) - Vector2(b.x, b.z)
				input.turn = clampf(-wrapf(atan2(-aim.x, -aim.y) - b.heading, -PI, PI) * 2.0, -1.0, 1.0)
			if spec.mode in ["space", "manual"] and not jumped and float(spec.feature) - station < b.speed * 0.45 + 1.0:
				jumped = true
				if spec.mode == "space": input.jump = true
				else: manual_time = t
		b.body_back = manual_time >= 0.0 and t - manual_time < 0.2
		b.body_forward = manual_time >= 0.0 and t - manual_time >= 0.2 and t - manual_time < 0.4
		if spec.mode == "pump_body":
			var phase := fposmod((station - (spec.feature - spec.feature_length * 0.5)) / (spec.feature_length / spec.feature_count), 1.0)
			b.body_back = phase > 0.25 and phase < 0.5
			b.body_forward = phase >= 0.5 and phase < 0.75
		h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1)
		var before := Vector2(b.x, b.z)
		var was_air := b.airborne
		var before_speed := b.horizontal_velocity().length()
		var before_hits := b.impacts.x + b.impacts.y
		controller.ride(dt, p, b, h.world, h, input.throttle, input.turn, input.run, input.jump, false)
		t += dt
		var nearest := local_near(Vector2(b.x, b.z), station)
		if is_finite(nearest.z): station = maxf(station, nearest.x)
		var off := absf(nearest.y) if is_finite(nearest.z) else 80.0
		var clearance := b.y - h.surface_at(b.x, b.z, b.y)
		var hits := b.impacts.x + b.impacts.y - before_hits
		r.distance += before.distance_to(Vector2(b.x, b.z))
		r.top = maxf(r.top, b.horizontal_velocity().length())
		r.off_max = maxf(r.off_max, off)
		r.off_integral += off * dt
		r.off_time += dt if off > d.width * 0.5 else 0.0
		r.air_time += dt if b.airborne else 0.0
		r.steer_saturated += dt if absf(input.turn) > 0.99 else 0.0
		r.pedal_time += dt if input.throttle > 0.1 and not b.airborne else 0.0
		r.brake_time += dt if input.throttle < -0.1 and not b.airborne else 0.0
		r.boost_time += dt if input.run and controller.stamina.can_boost(true, input.throttle) and not b.airborne else 0.0
		r.coast_time += dt if absf(input.throttle) <= 0.1 and not b.airborne else 0.0
		r.hits += hits
		r.jump_presses += int(input.jump)
		r.pop_count += int(b._hop_used and not popped_previous)
		popped_previous = b._hop_used
		r.land_max = maxf(r.land_max, b.land_impact)
		r.bottom_outs += int(b.bottom_out > 0.0)
		r.stamina_min = minf(r.stamina_min, controller.stamina.value)
		r.pump_time += dt if absf(b.pump_motion) > 0.02 else 0.0
		r.pump_boost += b.pump_accel * dt
		r.pump_motion = maxf(r.pump_motion, absf(b.pump_motion))
		if not b.airborne:
			r.slip_ground = maxf(r.slip_ground, absf(rad_to_deg(b.slip)))
			r.sideways_time += dt if absf(b.lateral_speed) > maxf(absf(b.speed), 0.3) else 0.0
		if off > d.width * 0.5 and not off_previous: r.events.append({kind = "off", s = station, speed = b.speed, t = t})
		off_previous = off > d.width * 0.5
		if b.airborne and not was_air:
			flight = {from = station, to = station, duration = 0.0, takeoff_speed = before_speed, impact = 0.0, clearance = clearance, y0 = b.y, rise = 0.0}
		if b.airborne and not flight.is_empty():
			flight.duration += dt
			flight.to = station
			flight.clearance = maxf(flight.clearance, clearance)
			flight.rise = maxf(flight.rise, b.y - flight.y0)
		if was_air and not b.airborne and not flight.is_empty():
			flight.to = station
			flight.impact = b.land_impact
			r.flights.append(flight)
			flight = {}
		for i in d.elements.size():
			var e := d.elements[i]
			var stats: Dictionary = r.elements[i]
			var a := e.station - e.length * 0.5
			var z := e.station + e.length * 0.5
			if stats.enter < 0.0 and spec.from <= a and station >= a: stats.enter = b.speed
			if stats.exit < 0.0 and spec.from <= z and station >= z: stats.exit = b.speed
			if station < a or station > z + 6.0: continue
			stats.samples += 1
			stats.air += dt if b.airborne else 0.0
			stats.off += dt if off > d.width * 0.5 else 0.0
			stats.slip = maxf(stats.slip, absf(rad_to_deg(b.slip)) if not b.airborne else 0.0)
			stats.land = maxf(stats.land, b.land_impact)
			stats.hits += hits
			var deck := h.deck_at(b.x, b.z, INF)
			if not b.airborne and is_finite(deck) and absf(b.y - deck) < 0.2: stats.deck_time += dt
		if int(t / dt) % maxi(1, spec.hz / 10) == 0:
			rows.append("%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.4f,%.4f,%.4f,%.4f,%.3f" % [t, station, b.x, b.y, b.z, b.speed, b.lateral_speed, rad_to_deg(b.slip), int(b.airborne), input.turn, input.throttle, controller.stamina.value, b.load_f, b.load_r, b.bank_slope, clearance])
		if b.crashed:
			r.status = "crash"
			r.crash = {s = station, cause = BikeRide.CrashCause.keys()[b.crash_cause], velocity = b.crash_velocity.length(), impact = b.land_impact, off = off, t = t}
			break
		if station >= spec.to: r.status = "finished"; break
		still = still + dt if b.horizontal_velocity().length() < 0.35 else 0.0
		lost = lost + dt if off > 12.0 else 0.0
		if still > 4.0: r.status = "stalled"; break
		if lost > 2.0: r.status = "lost_line"; break
		b.land_impact = 0.0
		b.bottom_out = 0.0
	r.time = t
	r.station = station
	r.final_speed = b.speed
	r.average_kmh = r.distance / maxf(t, dt) * 3.6
	r.off_mean = r.off_integral / maxf(t, dt)
	r.stamina_final = controller.stamina.value
	r.gaps_known = Array(pilot.gaps)
	var csv := FileAccess.open(out_path + "/" + str(spec.name).replace("+", "p") + ".csv", FileAccess.WRITE)
	csv.store_string("\n".join(rows))
	return r
