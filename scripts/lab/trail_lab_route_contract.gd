extends RefCounted
## A stopped walk is data, never implicitly a finished route.
const FINISH_RADIUS := 8.0
const CORRIDOR_WIDTH := 48.0
const MIN_LENGTH := 160.0

static func length(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, points.size()): total += points[i - 1].distance_to(points[i])
	return total

static func project(points: PackedVector2Array, p: Vector2) -> Vector2:
	var best := INF
	var station := 0.0
	var along := 0.0
	for i in range(1, points.size()):
		var ab := points[i] - points[i - 1]
		var t := clampf((p - points[i - 1]).dot(ab) / maxf(0.001, ab.length_squared()), 0, 1)
		var distance := p.distance_to(points[i - 1] + ab * t)
		if distance < best: best = distance; station = along + ab.length() * t
		along += ab.length()
	return Vector2(station, best)

static func endpoint(p: Vector2, tangent: Vector2, ground: Callable, allowed: Callable, width: float) -> Dictionary:
	var grade := absf(float(ground.call(p + tangent * 6)) - float(ground.call(p - tangent * 6))) / 12.0
	var side := tangent.orthogonal()
	var cross := absf(float(ground.call(p + side * width * 0.5)) - float(ground.call(p - side * width * 0.5))) / width
	var clear := true
	# Clear stopping apron, including a 12 m runout beyond the chosen finish.
	for s: float in [-6.0, 0.0, 6.0, 12.0]:
		for offset: float in [-width * 0.5 - 2, 0.0, width * 0.5 + 2]:
			if allowed.is_valid() and not allowed.call(p + tangent * s + side * offset): clear = false
	return {suitable = clear, clear = clear, grade = grade, cross = cross, estimated_work = cross * width * 0.5 + grade * 6.0}

static func plan(hint: PackedVector2Array, ground: Callable, allowed: Callable, width: float, short_route := false) -> Dictionary:
	if hint.size() < 2: return {hint = hint, error = "коридор не задан"}
	var d := TrailDefinition.new()
	d.points = hint
	var total := d.route_length()
	# Full routes retain the nominated finish. Short mode nominates a finish on the corridor FIRST.
	var end := total
	var nominated := hint[-1]
	if not short_route:
		var last_tangent := (hint[-1] - hint[-2]).normalized()
		if not endpoint(nominated, last_tangent, ground, allowed, width).suitable:
			var best := INF
			for dz in range(-4, 5):
				for dx in range(-4, 5):
					var at := hint[-1] + Vector2(dx, dz) * 8
					if at.distance_to(hint[-1]) > 32 or at.distance_to(hint[-2]) < 12: continue
					var area := endpoint(at, (at - hint[-2]).normalized(), ground, allowed, width)
					if not area.suitable: continue
					var score: float = at.distance_to(hint[-1]) + area.grade * 40 + area.cross * 20
					if score < best: best = score; nominated = at
	if short_route:
		var best := -INF
		end = -1
		for s in range(180, floori(minf(total - 24, 320)), 16):
			var p := d.point_at(s)
			var test := endpoint(p, d.tangent_at(s), ground, allowed, width)
			if not test.suitable: continue
			var drop := float(ground.call(hint[0])) - float(ground.call(p))
			var score := drop - float(test.grade) * 20 - absf(s - 240) * 0.02
			if score > best: best = score; end = s
		if end < 0: return {hint = hint, error = "нет подходящего самостоятельного короткого финиша"}
	var points := PackedVector2Array([hint[0]])
	var along := 0.0
	for i in range(1, hint.size()):
		along += hint[i - 1].distance_to(hint[i])
		if along >= end: break
		points.append(hint[i])
	points.append(d.point_at(end))
	if not short_route: points[-1] = nominated
	return {hint = points, finish = points[-1], kind = "short" if short_route else "full", original_length = total,
		original_finish = hint[-1], planned_length = length(points), selected_before_walk = true,
		finish_area = endpoint(points[-1], (points[-1] - points[-2]).normalized(), ground, allowed, width)}

static func measure(points: PackedVector2Array, hint: PackedVector2Array, finish: Vector2, stop: String, ground: Callable, allowed: Callable, width: float, kind := "full") -> Dictionary:
	var result := {complete = false, fragment = true, kind = kind, stop_reason = stop, length = length(points),
		finish_distance = INF, corridor_progress = 0.0, corridor_coverage = 0.0, backward_m = 0.0, reasons = []}
	if points.size() < 2: result.reasons.append("пустой фрагмент"); return result
	result.finish_distance = points[-1].distance_to(finish)
	var reached: bool = result.finish_distance <= FINISH_RADIUS and stop in ["reached_finish", "layout_complete", "corridor_fit"]
	result.reached_finish = reached
	if not reached: result.reasons.append("финиш не достигнут")
	if hint.size() > 1:
		var total := length(hint)
		var previous := 0.0
		var frontier := 0.0
		var actual := TrailDefinition.new()
		actual.points = points
		var samples := maxi(1, ceili(actual.route_length() / 4.0))
		for i in samples + 1:
			var p := actual.point_at(actual.route_length() * i / samples)
			var near := project(hint, p)
			if near.y <= CORRIDOR_WIDTH:
				result.backward_m += maxf(0, previous - near.x)
				# No teleport to the corridor's end across an unvisited middle.
				if near.x <= frontier + 32: frontier = maxf(frontier, near.x)
				previous = near.x
		result.corridor_progress = frontier / maxf(1, total)
		var covered := 0
		var count := 0
		var guide := TrailDefinition.new()
		guide.points = hint
		for s in range(0, ceili(total) + 1, 12):
			count += 1
			if project(points, guide.point_at(s)).y <= CORRIDOR_WIDTH: covered += 1
		result.corridor_coverage = float(covered) / maxi(1, count)
		if result.corridor_progress < 0.90 or result.corridor_coverage < 0.85 or result.backward_m > total * 0.20:
			result.reasons.append("нет последовательного продвижения по коридору")
	result.fragment = not reached or (hint.size() > 1 and (result.corridor_progress < 0.90 or result.corridor_coverage < 0.85 or result.backward_m > length(hint) * 0.20))
	result.finish_area = endpoint(points[-1], (points[-1] - points[-2]).normalized(), ground, allowed, width)
	if not result.finish_area.suitable: result.reasons.append("финиш без безопасного места остановки и выката")
	if result.length < MIN_LENGTH: result.reasons.append("слишком короткий самостоятельный маршрут")
	if result.length < 300 or kind == "short":
		var drop := float(ground.call(points[0])) - float(ground.call(points[-1]))
		var turns := 0
		var d := TrailDefinition.new()
		d.points = points
		var last := d.tangent_at(0)
		for s in range(16, floori(d.route_length()), 16):
			var next := d.tangent_at(s)
			if absf(last.angle_to(next)) > 0.25: turns += 1
			last = next
		result.standalone = {drop = drop, turns = turns, useful = drop >= 6 or turns >= 3}
		# Character is supplied by the completed tread and elements; a flat park line
		# is not an unfinished route merely because it has no natural descent.
	result.complete = result.reasons.is_empty()
	return result
