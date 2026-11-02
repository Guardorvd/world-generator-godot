extends SceneTree
## Independent runs: production BikeRide + BikeController on the same baked surface as the validator.
const F := preload("res://tools/trail_lab_fixture.gd")
const V := preload("res://scripts/lab/trail_lab_validation.gd")
const Pilot := preload("res://scripts/lab/trail_autopilot.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const Standards := preload("res://scripts/trails/trail_standards.gd")
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func run() -> void:
	var output := {model = "production BikeRide + BikeController, contact_model=true, dt=1/60, no resets", cases = []}
	for name: String in ["straight", "rollable_table", "table_jump", "gap_short_runin", "sharp_turn"]:
		var d := TrailDefinition.new()
		d.id = "bike_validation_" + name
		d.width = 5.0
		d.points = PackedVector2Array([Vector2(100, 220), Vector2(100, 40)])
		if name == "rollable_table": d.elements = [TrailElementLibrary.make(TrailElement.Profile.TABLETOP, 55, 18, 0.35)]
		if name == "table_jump": d.elements = [TrailElementLibrary.make(TrailElement.Profile.TABLETOP, 65, 16, 1.0)]
		if name == "gap_short_runin":
			d.elements = [TrailElementLibrary.make(TrailElement.Profile.GAP, 14, 20, 1.5)]
			d.elements[0].gap = 8.0
			d.elements[0].length = d.elements[0].gap_min_length() + 2.0
			d.elements[0].station = d.elements[0].length * 0.5 + 1.0
		if name == "sharp_turn": d.points = PackedVector2Array([Vector2(100, 220), Vector2(100, 140), Vector2(190, 140)])
		var input := GI.new()
		input.size = Vector2i(64, 64)
		for key in ["heights", "water", "rivers", "forbidden"]:
			var values = input.get(key)
			values.resize(4096)
			input.set(key, values)
		for z in 64:
			for x in 64: input.heights[z * 64 + x] = 12 + (z + 0.5) * 4 * 0.035
		var prepared := F.prepare([d] as Array[TrailDefinition], true, "flat", input)
		check(prepared.errors.is_empty(), name + " baked")
		if not prepared.errors.is_empty(): continue
		var h: Heightfield = prepared.heights
		var technical := TrailTechnical.build(h, [d] as Array[TrailDefinition])
		h.obstacles.set_trail(technical.collide, technical.bumps)
		var report := V.measure(h, d)
		var record := {name = name, validator = {accepted = report.accepted, assessments = report.assessments, issues = report.issues}, rides = []}
		for speed: float in [4.0, 10.0, 16.0]: record.rides.append(ride(h, d, speed))
		if report.scenarios.has("normal"):
			record.rides.append(ride(h, d, 0.0, report.scenarios.normal.speeds))
		output.cases.append(record)
		print("BIKE CASE ", JSON.stringify(record))
		if name == "straight": check(report.accepted and record.rides[0].safe_pass, "known good straight agrees with BikeRide")
		if name == "rollable_table": check(report.accepted and record.rides[0].safe_pass, "safe slow table passage remains eligible")
		if name == "gap_short_runin": check(not report.accepted, "short mandatory gap is rejected")
		if name == "sharp_turn":
			check(record.rides[0].safe_pass and not record.rides[2].safe_pass, "sharp turn separates safe passage from constant high speed")
			check(not report.accepted or record.rides[-1].safe_pass, "accepted braking profile agrees with BikeRide on sharp turn")
	var file := FileAccess.open("res://docs/data/trail_bikeride_validation_2026_11_02.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(output, "  "))
	quit(1 if failures else 0)

func ride(h: Heightfield, d: TrailDefinition, target: float, profile := PackedFloat32Array()) -> Dictionary:
	var player := PlayerState.new()
	var bike := BikeRide.new()
	var at := d.point_at(1)
	bike.x = at.x
	bike.z = at.y
	bike.y = h.surface_at(at.x, at.y, -INF)
	bike.heading = d.heading_at(1)
	bike.mount(player)
	bike.speed = target if profile.is_empty() else profile[1]
	var control := BikeController.new()
	var pilot := Pilot.new()
	pilot.reset(d, h, 1)
	var result := {target_speed = target, policy = "constant speed stress" if profile.is_empty() else "validator normal braking profile", status = "timeout", safe_pass = false, jump_intent = false, fast_pass = false,
		air_time = 0.0, max_impact = 0.0, max_offset = 0.0, landings = [], time = 0.0}
	var station := 1.0
	var jump_started := false
	h.obstacles.update(bike.x, bike.z, PackedFloat32Array(), 1, true)
	for tick in 7200:
		var input := pilot.drive(bike, d)
		if not profile.is_empty(): target = profile[clampi(floori(station + maxf(1.0, bike.speed * 0.25)), 0, profile.size() - 1)]
		var was_air := bike.airborne
		h.obstacles.update(bike.x, bike.z, PackedFloat32Array(), 1)
		control.ride(1.0 / 60.0, player, bike, h.world, h, clampf((target - bike.speed) * 0.8, -1, 1), input.turn, false, false, false)
		var near := d.nearest(Vector2(bike.x, bike.z), 12)
		if is_finite(near.z) and near.x < station + 15: station = maxf(station, near.x)
		result.time = (tick + 1) / 60.0
		result.max_offset = maxf(result.max_offset, absf(near.y) if is_finite(near.z) else 99)
		result.max_impact = maxf(result.max_impact, bike.land_impact)
		if bike.airborne: result.air_time += 1.0 / 60.0; jump_started = true
		if was_air and not bike.airborne:
			result.landings.append({station = station, impact = bike.land_impact})
			for e in d.elements:
				var landing := Standards.landing(e)
				var from := e.station - e.length * 0.5
				if jump_started and station >= from + landing.x and station <= from + landing.z: result.jump_intent = true
		if bike.crashed: result.status = "crash:" + BikeRide.CrashCause.keys()[bike.crash_cause]; break
		if result.max_offset > d.width * 0.5: result.status = "left_tread"; break
		if station >= d.route_length() - 3:
			result.status = "finished"
			result.safe_pass = true
			result.fast_pass = target >= 16.0 and result.time <= d.route_length() / 12.0
			break
		bike.land_impact = 0
		bike.bottom_out = 0
	result.station = station
	return result
