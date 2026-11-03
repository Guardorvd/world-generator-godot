extends RefCounted
## Production motion, continuous runs, no recovery teleports. Shared by section and full-route checks.
const Pilot := preload("res://scripts/lab/trail_autopilot.gd")

static func run(h: Heightfield, route: TrailDefinition, spec: Dictionary) -> Dictionary:
	var from: float = spec.get("from", 0.0)
	var to: float = spec.get("to", route.route_length())
	var full_route := from == 0 and to >= route.route_length()
	var profile: PackedFloat32Array = spec.get("profile", PackedFloat32Array())
	var pilot := Pilot.new()
	pilot.style = spec.get("style", "careful")
	pilot.reset(route, h, from)
	var bike := BikeRide.new()
	var player := PlayerState.new()
	var at := route.point_at(from)
	bike.x = at.x; bike.z = at.y; bike.y = h.surface_at(at.x, at.y, -INF)
	bike.heading = route.heading_at(from)
	bike.mount(player)
	bike.speed = spec.get("speed", 3.0)
	var controller := BikeController.new()
	var station := from
	var still := 0.0
	var result := {status = "time_limit", completed = false, from = from, to = to, station = from, time = 0.0,
		max_offset = 0.0, max_impact = 0.0, top_speed = bike.speed, max_slip = 0.0, samples = [], policy = spec.get("policy", "pilot"), resets = 0}
	result.completion_kind = "full_route" if full_route else "section"
	h.obstacles.update(bike.x, bike.z, PackedFloat32Array(), 1, true)
	for tick in ceili(float(spec.get("max_time", 240.0)) * 60):
		var input := pilot.drive(bike, route)
		var cap := -1.0
		if not profile.is_empty():
			cap = profile[clampi(floori(station + maxf(1.0, bike.speed * 0.25)), 0, profile.size() - 1)]
			input.throttle = clampf((cap - bike.speed) * 0.8, -1, 1)
			input.run = false; input.jump = false
		h.obstacles.update(bike.x, bike.z, PackedFloat32Array(), 1)
		controller.ride(1.0 / 60, player, bike, h.world, h, input.throttle, input.turn, input.run, input.jump, false)
		var near := route.nearest_along(Vector2(bike.x, bike.z), station, 28, 32)
		if is_finite(near.z): station = maxf(station, near.x)
		var off := absf(near.y) if is_finite(near.z) else 99.0
		result.time = (tick + 1) / 60.0
		result.station = station
		result.max_offset = maxf(result.max_offset, off)
		result.max_impact = maxf(result.max_impact, bike.land_impact)
		result.max_slip = maxf(result.max_slip, absf(bike.slip))
		result.top_speed = maxf(result.top_speed, bike.speed)
		if tick % 6 == 0: result.samples.append({t = result.time, station = station, speed = bike.speed, cap = cap, throttle = input.throttle, turn = input.turn,
			offset = off, x = bike.x, z = bike.z, y = bike.y, slip = bike.slip, impact = bike.land_impact, airborne = bike.airborne})
		if bike.crashed: result.status = "crash:" + BikeRide.CrashCause.keys()[bike.crash_cause]; break
		if off > route.width * 0.5: result.status = "left_tread"; break
		var past_finish := (Vector2(bike.x, bike.z) - route.points[-1]).dot(route.tangent_at(route.route_length())) >= 0
		if station >= to and (not full_route or past_finish):
			result.status = "finished" if full_route else "section_complete"
			result.completed = true
			break
		still = still + 1.0 / 60 if absf(bike.speed) < 0.3 else 0.0
		if still > 4: result.status = "stalled"; break
		bike.land_impact = 0; bike.bottom_out = 0
	return result
