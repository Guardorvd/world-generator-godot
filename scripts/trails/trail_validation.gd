extends RefCounted
## Shared final-tread check. Conservative point model on the FINAL tread, not a BikeRide simulation.
## Every scenario carries speed and recovery distance from one feature to the next.
const S := preload("res://scripts/trails/trail_standards.gd")
const T := TrailElement.Profile
const SCENARIOS := {calm = 0.8, normal = 1.0, fast = 1.15}
const MAX_REPAIRS := 2
const FAST_AVERAGE := 12.0 # m/s, explicit performance target; never an acceptance requirement

static func footprint(d: TrailDefinition, allowed: Callable) -> PackedStringArray:
	var errors := PackedStringArray()
	if not allowed.is_valid(): return errors
	var s := 0.0
	while s <= d.route_length():
		var p := d.point_at(s)
		var t := d.tangent_at(s)
		var side := Vector2(t.y, -t.x)
		for lane in ceili(d.width / 0.5) + 1:
			var offset := -d.width * 0.5 + d.width * lane / ceili(d.width / 0.5)
			if not allowed.call(p + side * offset):
				errors.append("запрещённая зона/край полотна у %.1f м" % s)
				return errors
		s = minf(s + 0.5, d.route_length()) if s < d.route_length() else s + 1.0
	return errors

## climb_ok — подъём и быстрый спуск самого полотна не отказ, а усилие и мастерство: на длинном маршруте мира седок крутит,
## идёт пешком или сбрасывает скорость заранее. Настоящая опасность — элементы и земля — остаётся отказом.
static func measure(h: Heightfield, d: TrailDefinition, allowed := Callable(), climb_ok := false) -> Dictionary:
	var errors := d.validate()
	errors.append_array(footprint(d, allowed))
	var report := {accepted = false, errors = errors, issues = [], scenarios = {}, model = "final tread point model",
		assessments = {safety = false, jump_intent = false, fast_pass = false}}
	if not errors.is_empty(): return report
	var survey := TrailSurvey.measure(h, d)
	errors.append_array(survey.errors)
	if not errors.is_empty():
		report.errors = errors
		return report
	var n := ceili(d.route_length()) + 1
	var y := PackedFloat32Array()
	y.resize(n)
	for i in n:
		var at := minf(float(i), d.route_length()) / d.route_length() * (survey.support.size() - 1)
		var j := mini(int(at), survey.support.size() - 2)
		y[i] = lerpf(survey.support[j], survey.support[j + 1], at - j)
	for scenario: String in SCENARIOS:
		var factor: float = SCENARIOS[scenario]
		var caps := PackedFloat32Array()
		caps.resize(n)
		caps.fill(17.0 * factor)
		for i in n:
			var level: Dictionary = S.LEVELS[_level(d, i)]
			caps[i] = float(level.top) * factor
			var k := d.curvature_at(i)
			if absf(k) < 0.004: continue
			var p := d.point_at(i)
			var t := d.tangent_at(i)
			var side := Vector2(t.y, -t.x) * 0.5
			var bank := (h.ground_at(p.x + side.x, p.y + side.y) - h.ground_at(p.x - side.x, p.y - side.y)) * signf(k)
			var sample := clampi(roundi(float(i) / d.route_length() * (survey.layers.size() - 1)), 0, survey.layers.size() - 1)
			if survey.layers[sample] == TrailSurvey.Layer.DECK: bank = 0.0
			caps[i] = minf(caps[i], S.turn_speed(1.0 / absf(k), bank, float(level.lat)) * minf(factor, 1.0))
		var windows := {}
		for ei in d.elements.size():
			var e := d.elements[ei]
			var from := e.station - e.length * 0.5
			var to := e.station + e.length * 0.5
			# Endpoint grade excludes the feature's own rise; heights come from the baked surface.
			var grade := (y[mini(n - 1, ceili(to))] - y[maxi(0, floori(from))]) / e.length
			var w := S.window(e, d, grade, _level(d, e.station))
			windows[ei] = w
			if w.has("speed_hi"):
				var last := int(from) if e.profile in [T.TABLETOP, T.GAP] else ceili(to)
				for i in range(maxi(0, floori(from)), mini(n - 1, last) + 1): caps[i] = minf(caps[i], float(w.speed_hi))
		# Backward braking envelope includes gravity on the actual grade.
		for i in range(n - 2, -1, -1):
			var braking := maxf(0.1, S.BRAKE + S.G * (y[i + 1] - y[i]))
			caps[i] = minf(caps[i], sqrt(caps[i + 1] * caps[i + 1] + 2.0 * braking))
		var speeds := PackedFloat32Array()
		speeds.resize(n)
		speeds[0] = minf(3.0, caps[0])
		var flights := {}
		var starts := {}
		for ei in d.elements.size():
			var e := d.elements[ei]
			if e.profile in [T.GAP, T.TABLETOP, T.DROP]: starts[maxi(1, floori(e.station - e.length * 0.5))] = ei
		var i := 1
		while i < n:
			var v := speeds[i - 1]
			var a := -S.G * (y[i] - y[i - 1]) - S.ROLL - S.DRAG * v * v
			if v < S.CRUISE * factor: a += S.PEDAL * (1.0 - v / (S.CRUISE * factor))
			var possible := sqrt(maxf(0.0, v * v + 2.0 * a))
			if possible < 0.5: _issue(report, scenario, -1, i, "остановка на подъёме готового полотна", "effort" if climb_ok else "safety", {actual = possible, limit = 0.5, deviation = 0.5 - possible})
			var minimum := sqrt(maxf(0.0, v * v + 2.0 * (a - S.BRAKE)))
			if minimum > caps[i] + 0.5: _issue(report, scenario, -1, i, "не хватает торможения перед поворотом/элементом", "effort" if climb_ok else "safety", {actual = minimum, limit = caps[i] + 0.5, deviation = minimum - caps[i] - 0.5})
			speeds[i] = minf(possible, caps[i])
			if starts.has(i):
				var ei: int = starts[i]
				var flight := fly_surface(y, float(i), speeds[i], float(windows[ei].land_to) + 12.0)
				flights[ei] = flight
				if flight.flew:
					var end := mini(n - 1, ceili(float(flight.land)))
					for j in range(i + 1, end + 1): speeds[j] = float(flight.exit_speed)
					i = maxi(i, end)
			i += 1
		var recovery := 0.0
		for ei in d.elements.size():
			var e := d.elements[ei]
			var from := e.station - e.length * 0.5
			var to := e.station + e.length * 0.5
			var v := speeds[clampi(floori(from), 0, n - 1)]
			var w: Dictionary = windows[ei]
			var rollable := _rollable_table(d, e)
			if from < recovery: _issue(report, scenario, ei, from, "предыдущий элемент не оставляет места на восстановление", "safety", {actual = from, limit = recovery, deviation = recovery - from})
			if w.has("speed_lo") and v < float(w.speed_lo) - 0.5:
				_issue(report, scenario, ei, from, "скорость ниже окна", "jump_intent" if rollable else "safety", {actual = v, limit = float(w.speed_lo) - 0.5, deviation = float(w.speed_lo) - 0.5 - v})
			if w.has("speed_hi") and v > float(w.speed_hi) + 0.5: _issue(report, scenario, ei, from, "скорость выше окна", "safety", {actual = v, limit = float(w.speed_hi) + 0.5, deviation = v - float(w.speed_hi) - 0.5})
			if e.profile in [T.GAP, T.TABLETOP, T.DROP]:
				var land_to: float = w.get("land_to", to)
				var flight: Dictionary = flights.get(ei, {flew = false})
				if flight.get("unresolved", false): _issue(report, scenario, ei, from, "приземление не подтверждено в пределах расчёта")
				if flight.flew:
					if float(flight.land) < float(w.land_from) - 0.5:
						_issue(report, scenario, ei, from, "приземление раньше задуманной зоны", "jump_intent" if rollable else "safety", {actual = float(flight.land), limit = float(w.land_from) - 0.5, deviation = float(w.land_from) - 0.5 - float(flight.land)})
					if float(flight.land) > land_to + 0.5:
						_issue(report, scenario, ei, from, "приземление за зоной на готовом полотне", "safety", {actual = float(flight.land), limit = land_to + 0.5, deviation = float(flight.land) - land_to - 0.5})
					if float(flight.impact) > float(S.LEVELS[_level(d, e.station)].impact): _issue(report, scenario, ei, from, "жёсткое приземление на готовом полотне", "safety", {actual = float(flight.impact), limit = float(S.LEVELS[_level(d, e.station)].impact), deviation = float(flight.impact) - float(S.LEVELS[_level(d, e.station)].impact)})
					land_to = maxf(land_to, float(flight.land))
				else: _issue(report, scenario, ei, from, "прыжок без подтверждённого отрыва и приземления", "jump_intent" if rollable else "safety")
				var approach := S.tightest(d, maxf(0.0, from - S.HUB - v * float(BikeRide.LOOK[-1])), float(w.get("lip", from)))
				var landing := S.tightest(d, float(w.get("land_from", from)), minf(d.route_length(), land_to + S.recovery_distance(v, true)))
				var required_radius := v * v / (S.LAT_MAX * float(S.LEVELS[_level(d, e.station)].lat))
				if minf(approach, landing) < required_radius:
					_issue(report, scenario, ei, from, "поворот на подходе или приземлении", "safety", {actual = minf(approach, landing), limit = required_radius, deviation = required_radius - minf(approach, landing)})
				var clearance := S.recovery_distance(v, true)
				if land_to + clearance > d.route_length(): _issue(report, scenario, ei, from, "нет выката после приземления", "safety", {actual = d.route_length() - land_to, limit = clearance, deviation = land_to + clearance - d.route_length()})
				recovery = land_to + clearance
			elif TrailElement.places_objects(e.profile):
				recovery = to + S.recovery_distance(v, false)
		var seconds := 0.0
		for speed in speeds: seconds += 1.0 / maxf(0.1, speed)
		report.scenarios[scenario] = {speeds = speeds, top = Array(speeds).max(), windows = windows, flights = flights, seconds = seconds}
	for issue: Dictionary in report.issues:
		if issue.assessment != "safety": continue
		var source := "полотно" if int(issue.element) < 0 else "элемент %d" % (int(issue.element) + 1)
		errors.append("%s · %.1f м · %s: %s" % [issue.scenario, issue.station, source, issue.reason])
	report.errors = errors
	report.accepted = errors.is_empty()
	report.assessments = {safety = report.accepted,
		jump_intent = not report.issues.any(func(issue: Dictionary) -> bool: return issue.assessment == "jump_intent" or issue.element >= 0),
		fast_pass = not report.issues.any(func(issue: Dictionary) -> bool: return issue.scenario == "fast" and issue.assessment == "safety") and report.scenarios.fast.seconds <= d.route_length() / FAST_AVERAGE}
	return report

static func _rollable_table(d: TrailDefinition, e: TrailElement) -> bool:
	if e.profile != T.TABLETOP: return false
	for span in d.open_spans:
		if span.y >= e.station - e.length * 0.5 and span.x <= e.station + e.length * 0.5: return false
	return true

static func _level(d: TrailDefinition, station: float) -> int:
	for section: Dictionary in d.sections:
		if station >= float(section.from) and station <= float(section.to): return clampi(int(float(section.difficulty) * 4.0), 0, 3)
	return 2

static func _height(y: PackedFloat32Array, s: float) -> float:
	var at := clampf(s, 0.0, y.size() - 1.0)
	var i := mini(floori(at), y.size() - 2)
	return lerpf(y[i], y[i + 1], at - i)

static func _contact(y: PackedFloat32Array, s: float) -> float:
	return (_height(y, s - S.HUB) + _height(y, s + S.HUB)) * 0.5

## Follows the sampled finished tread through takeoff and landing, including cuts and decks.
static func fly_surface(y: PackedFloat32Array, start: float, entry: float, end: float) -> Dictionary:
	var s := start
	var v := entry
	var dt := 1.0 / BikeRide.SUB_HZ
	var airborne := false
	var height := _contact(y, s)
	var vy := 0.0
	var air := 0.0
	for tick in 6000:
		if s >= minf(end, y.size() - 1.0) or v < 0.5: break
		if not airborne:
			var grade := (_height(y, s + S.HUB) - _height(y, s - S.HUB)) / (2.0 * S.HUB)
			vy = grade * v
			height = _contact(y, s)
			for look: float in BikeRide.LOOK:
				if height + vy * look - S.G * look * look * 0.5 - _contact(y, s + v * look) > BikeRide.LIFT:
					airborne = true
					break
			if not airborne:
				v += (-S.G * grade / sqrt(1.0 + grade * grade) - S.ROLL - S.DRAG * v * v) * dt
				s += maxf(v, 0.0) * dt
				continue
		s += v * dt
		height += (vy - S.G * dt * 0.5) * dt
		vy -= S.G * dt
		air += dt
		if height <= _contact(y, s):
			var grade := (_contact(y, s + 0.1) - _contact(y, s - 0.1)) / 0.2
			var impact := maxf(0.0, (v * grade - vy) / sqrt(1.0 + grade * grade))
			if air >= 0.12:
				return {flew = true, land = s, impact = impact, exit_speed = maxf(0.5, v - maxf(0.0, impact - S.IMPACT_SOFT) * 0.5)}
			airborne = false
			air = 0.0
	return {flew = false, unresolved = airborne, land = s, impact = 0.0, exit_speed = v}

static func _issue(report: Dictionary, scenario: String, element: int, station: float, reason: String, assessment := "safety", metrics := {}) -> void:
	# A concise headline plus EVERY violating station and numeric peak; never discard later violations.
	for issue: Dictionary in report.issues:
		if issue.scenario != scenario or issue.element != element or issue.reason != reason: continue
		issue.to = maxf(issue.to, station)
		issue.samples.append({station = station, metrics = metrics.duplicate(true)})
		if float(metrics.get("deviation", 0)) > issue.max_deviation:
			issue.max_deviation = metrics.deviation; issue.worst_station = station
		return
	report.issues.append({scenario = scenario, element = element, station = station, to = station, worst_station = station,
		reason = reason, assessment = assessment, max_deviation = float(metrics.get("deviation", 0)), samples = [{station = station, metrics = metrics.duplicate(true)}]})

## A local repair never removes features or changes a cut/open span. Rebuild from fresh source afterwards.
static func repair(d: TrailDefinition, report: Dictionary, repaired: Dictionary) -> Dictionary:
	for issue: Dictionary in report.issues:
		var i: int = issue.element
		if i < 0 or repaired.has(i): continue
		var e := d.elements[i]
		if e.profile != T.DROP or not issue.reason.begins_with("скорость ниже"): continue
		if not d.open_spans.is_empty(): continue
		var before := e.profile
		e.profile = T.ROLLER
		e.height = minf(e.height, 0.35)
		repaired[i] = true
		return {element = i, station = e.station, before = before, after = e.profile, reason = issue.reason}
	return {}
