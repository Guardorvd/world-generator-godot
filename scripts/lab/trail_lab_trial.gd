extends RefCounted
## A complete attempt: pre-start spawn, ordered gates, result, explicit retry. No simulator shortcuts.
enum Phase { READY, APPROACH, RUNNING, FINISHED, FAILED }
var phase := Phase.READY
var elapsed := 0.0
var progress := 0.0
var next_gate := 0
var gates := PackedFloat32Array()
var route: TrailDefinition
var spawn := {}
var result := {}
var previous := Vector2.ZERO
var assisted := false
var attempts := 0
var best := INF
var title := ""
var pace_note := ""

static func safe_spawn(h: Heightfield, d: TrailDefinition, source) -> Dictionary:
	var tangent := d.tangent_at(0)
	var side := tangent.orthogonal()
	for distance: float in [8.0, 6.0, 4.0, 2.0]:
		for lateral: float in [0.0, -1.0, 1.0]:
			var at := d.points[0] - tangent * distance + side * lateral
			var direction := (d.points[0] - at).normalized()
			var across_direction := direction.orthogonal()
			var clear := true
			# Check the entire approach footprint, including the bicycle behind its spawn point.
			for along in range(-2, ceili(at.distance_to(d.points[0])) + 1):
				for across: float in [-1.0, 0.0, 1.0]:
					var p := at + direction * along + across_direction * across
					if source.blocked(p): clear = false
			var grade := absf(h.ground_at(at.x + direction.x, at.y + direction.y) - h.ground_at(at.x - direction.x, at.y - direction.y)) * 0.5
			var cross := absf(h.ground_at(at.x + across_direction.x, at.y + across_direction.y) - h.ground_at(at.x - across_direction.x, at.y - across_direction.y)) * 0.5
			if clear and grade <= 0.16 and cross <= 0.20:
				return {accepted = true, position = at, heading = atan2(-direction.x, -direction.y), distance = distance, lateral = lateral, grade = grade, cross = cross,
					height = h.surface_at(at.x, at.y, -INF)}
	return {accepted = false, reason = "перед стартом нет безопасной площадки появления"}

func configure(d: TrailDefinition, location: Dictionary) -> void:
	route = d
	title = d.title
	spawn = location.duplicate(true)
	gates = PackedFloat32Array([0.0])
	for s in range(20, floori(d.route_length() - 10), 20): gates.append(s)
	gates.append(d.route_length())
	retry()
	attempts = 0 # The caller's explicit first spawn/retry starts attempt 1.

func retry() -> void:
	phase = Phase.READY; elapsed = 0; progress = 0; next_gate = 0; result = {}; assisted = false
	previous = spawn.position
	attempts += 1

func begin() -> void:
	if phase == Phase.READY: phase = Phase.APPROACH

func fail(reason: String) -> void:
	if phase in [Phase.FINISHED, Phase.FAILED]: return
	phase = Phase.FAILED
	result = {finished = false, reason = reason, seconds = elapsed, progress = progress, assisted = assisted, attempt = attempts}

func tick(dt: float, at: Vector2, crashed := false, mounted := true) -> void:
	if phase not in [Phase.APPROACH, Phase.RUNNING]: return
	if crashed: fail("Падение"); return
	if not mounted: fail("Заезд прерван"); return
	if previous.distance_to(at) > maxf(3.0, dt * 40): fail("Нарушена непрерывность заезда"); return
	var near := route.nearest_along(at, progress, 28, 32)
	if not is_finite(near.z) or absf(near.y) > route.width * 0.5 + 0.6: fail("Сход с трассы"); return
	if near.x <= progress + maxf(3, previous.distance_to(at) * 2 + 1): progress = maxf(progress, near.x)
	if phase == Phase.RUNNING: elapsed += dt
	if next_gate < gates.size():
		var station := gates[next_gate]
		var point := route.point_at(station)
		var tangent := route.tangent_at(station)
		var crossed := (previous - point).dot(tangent) <= 0.01 and (at - point).dot(tangent) >= 0
		var lateral := absf((at - point).cross(tangent))
		if crossed and lateral <= route.width * 0.5 + 0.4 and progress >= station - 2:
			if next_gate == 0: phase = Phase.RUNNING; elapsed = 0
			next_gate += 1
			if next_gate == gates.size():
				phase = Phase.FINISHED
				if not assisted: best = minf(best, elapsed)
				result = {finished = true, seconds = elapsed, progress = route.route_length(), assisted = assisted, attempt = attempts,
					gates = gates.size(), best = best if is_finite(best) else -1.0}
	previous = at
