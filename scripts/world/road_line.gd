extends RefCounted
## Линия природного пути по найденным клеткам (выделено из StageTrails 16.11.2026): срезание лесенки сетки, дуги
## поворотов по скорости и ускорению вида, заходы на примыкания, проверка участка (уклон, крен, вода) и профиля.
## Входы — точки поиска, оси сооружений, поверхность, вид и примыкания; выход — станции линии. Пределы уклона вида —
## в StageTrails (ROAD_LIMIT, TRAIL_GRADE, MOUNTAIN_GRADE, BENCH_CROSS), допуски срезания и бугра — RoadTuning.routing.
## Состояние: только счётчик fallbacks для стенда и причины в w.generation_profile.road_line_grade_fallbacks.

## Подбор дуг в коридоре исходной оси. Прямые участки дают место для захода на поворот.
const TURN_CORRIDOR := 0.65 # клеток от исходной оси
const TURN_SPEED := {"road": 5.0, "trail": 4.0, "mountain": 3.2} # м/с
const TURN_ACCEL := {"road": 5.4, "trail": 6.0, "mountain": 6.8} # м/с², запас на поворот и торможение
const TURN_TRIMS := [Vector2(1, 1), Vector2(1, 0.72), Vector2(0.72, 1),
	Vector2(0.72, 0.72), Vector2(0.52, 0.72), Vector2(0.72, 0.52), Vector2(0.52, 0.52),
	Vector2(0.38, 0.52), Vector2(0.52, 0.38), Vector2(0.38, 0.38)]
# Доли входного и выходного отрезков, затем множители длин касательных.
const GROUP_TRIMS := [Vector4(1, 1, 1, 1), Vector4(0.72, 1, 1, 1),
	Vector4(1, 0.72, 1, 1), Vector4(0.72, 0.72, 1, 1)]
const GROUP_LONG := Vector4(1, 1, 1.25, 1.25)
const GROUP_RETRIES := [Vector4(1, 1, 1.30, 1), Vector4(1, 1, 1, 1.30)]


static func build(w: WorldData, pts: Array, on_axis: PackedByteArray, surface: Heightfield,
		kind := "road", joins := {}, corridor := Callable(), smooth_kind := "") -> Array:
	var routing := RoadTuning.for_world(w).routing
	var relaxation: Dictionary = StageTrails.routing_overrides.get("line_relax", routing.line_relax)
	var relax: float = relaxation.get(kind if smooth_kind.is_empty() else smooth_kind, 0.0)
	if relax <= 1.0 or pts.size() < 3:
		return _build_with(w, pts, on_axis, surface, kind, joins, corridor, smooth_kind, 0.0)
	# Линия с поблажкой на бугры принимается, только если её профиль целиком (окна PROFILE_BASE, вне настилов) в пределе;
	# иначе — прежняя линия без поблажки.
	var line := _build_with(w, pts, on_axis, surface, kind, joins, corridor, smooth_kind, relax)
	var design := kind if smooth_kind.is_empty() else smooth_kind
	var grade := StageTrails.MOUNTAIN_GRADE if design == "mountain" else (StageTrails.TRAIL_GRADE if design == "trail" else StageTrails.ROAD_LIMIT)
	var down_ratio := 1.0
	if routing.expedition_grades.x > 0.0:
		grade = routing.expedition_grades.x
		down_ratio = routing.expedition_grades.y / grade
	var profile: Array = []
	var skip := PackedByteArray()
	for p: Dictionary in line:
		var at := Vector2(p.x, p.y)
		profile.append(at)
		skip.append(1 if axis_blocked(w, on_axis, at) else 0)
	if profile_ok(surface, profile, grade, skip, down_ratio):
		return line
	fallbacks += 1
	var decisions: Dictionary = w.generation_profile.get_or_add("road_line_grade_fallbacks", {})
	decisions[kind] = int(decisions.get(kind, 0)) + 1
	return _build_with(w, pts, on_axis, surface, kind, joins, corridor, smooth_kind, 0.0)


static var fallbacks := 0 # линий, где профиль с поблажкой вышел круче предела (счётчик для стенда)


static func _build_with(w: WorldData, pts: Array, on_axis: PackedByteArray, surface: Heightfield,
		kind: String, joins: Dictionary, corridor: Callable, smooth_kind: String, relax: float) -> Array:
	if pts.size() < 2:
		return pts
	var fixed := PackedByteArray()
	fixed.resize(pts.size())
	if not on_axis.is_empty():
		for k in pts.size():
			var p: Dictionary = pts[k]
			if axis_blocked(w, on_axis, Vector2(p.x, p.y)):
				for j in range(maxi(0, k - 2), mini(pts.size(), k + 3)):
					fixed[j] = 1
	var design_kind := kind if smooth_kind.is_empty() else smooth_kind
	var rules := {
		grade = StageTrails.MOUNTAIN_GRADE if design_kind == "mountain" else (StageTrails.TRAIL_GRADE if design_kind == "trail" else StageTrails.ROAD_LIMIT),
		cross = StageTrails.MOUNTAIN_GRADE if design_kind == "mountain" else StageTrails.BENCH_CROSS,
		speed = TURN_SPEED[design_kind], accel = TURN_ACCEL[design_kind], long_s_handles = kind == "road",
		probe = surface.fast_water(), axis = on_axis, corridor = corridor, relax = relax, down_ratio = 1.0,
	}
	var routing := RoadTuning.for_world(w).routing
	if routing.expedition_grades.x > 0.0:
		rules.grade = routing.expedition_grades.x
		rules.down_ratio = routing.expedition_grades.y / routing.expedition_grades.x
		rules.cross = routing.expedition_cross
		rules.speed = routing.expedition_turn_speed
	var straightening: Dictionary = StageTrails.routing_overrides.get("straighten", routing.straighten)
	var tolerance: float = straightening.get(design_kind, 0.0)
	if tolerance > 0.0 and pts.size() > 2:
		var pulled := straighten(surface, pts, fixed, rules, tolerance)
		pts = pulled[0]
		fixed = pulled[1]
	var bends: Array = [pts[0]]
	var pins := PackedByteArray([fixed[0]])
	for k in range(1, pts.size() - 1):
		var a := Vector2(pts[k - 1].x, pts[k - 1].y)
		var b := Vector2(pts[k].x, pts[k].y)
		var c := Vector2(pts[k + 1].x, pts[k + 1].y)
		if fixed[k] != 0 or pts[k].w != pts[k - 1].w or pts[k].w != pts[k + 1].w \
				or absf((b - a).normalized().angle_to((c - b).normalized())) > 0.001:
			bends.append(pts[k])
			pins.append(fixed[k])
	bends.append(pts[-1])
	pins.append(fixed[-1])

	var start := _approach(surface, bends[0], bends[1], joins.get(0, {}), rules) if pins[0] == 0 else []
	var finish := _approach(surface, bends[-1], bends[-2], joins.get(1, {}), rules) if pins[-1] == 0 else []
	var out: Array = [bends[0]] if start.is_empty() else start
	var k := 1
	while k < bends.size() - 1:
		var curve: Array = []
		if pins[k] == 0 and bends[k - 1].w == bends[k].w and bends[k + 1].w == bends[k].w:
			var a := Vector2(bends[k - 1].x, bends[k - 1].y)
			var b := Vector2(bends[k].x, bends[k].y)
			var c := Vector2(bends[k + 1].x, bends[k + 1].y)
			var last := k
			while last + 2 < bends.size() and last < k + 3 and pins[last + 1] == 0 \
					and bends[last + 2].w == bends[k].w:
				var next := Vector2(bends[last + 1].x, bends[last + 1].y)
				var prev := Vector2(bends[last].x, bends[last].y)
				if next.distance_to(prev) > 2.5:
					break
				last += 1
			var consumed := 0
			var pair: Array = []
			for end in range(last, k, -1):
				var path: Array = []
				for j in range(k - 1, end + 2):
					path.append(Vector2(bends[j].x, bends[j].y))
				curve = _bend_group(surface, path, bends[k].w, rules)
				if not curve.is_empty():
					consumed = end - k + 1
					break
				if end == k + 1:
					pair = path
			if consumed == 0 and kind == "road" and not pair.is_empty() and b.distance_squared_to(c) <= 2.25:
				curve = _bend_group(surface, pair, bends[k].w, rules, true)
				if not curve.is_empty():
					consumed = 2
			if consumed > 0:
				out.append_array(curve)
				k += consumed
				continue
			curve = _bend(surface, a, b, c, bends[k].w, rules)
		if curve.is_empty():
			out.append(bends[k])
		else:
			out.append_array(curve)
		k += 1
	if finish.is_empty():
		out.append(bends[-1])
	else:
		finish.reverse()
		out.append_array(finish)
	return stations(out)


## 15.11.2026: срезание лесенки сетки до сглаживания. Из центров клеток выбрасываются промежуточные точки, если прямой
## отрезок между дальними точками отходит от исходной ломаной не дальше tolerance клеток и проходит ту же проверку
## участка, что дуги (segment_ok: уклон по пределу вида, крен, вода), не задевает осей мостов и туннелей и проверку
## коридора (соседние области). Закреплённые точки (у сооружений) и смена ширины не срезаются; концы остаются.
## Маршрут тот же, по тем же склонам, без ступенек 45°/90°. Допуск по видам — straighten (0 — выключено); виды —
## по расчёту линии (связи поселений — «road»), природные маршруты — по своему виду (trail/mountain).
const STRAIGHT_SPAN := 10 # клеток пути в одной хорде, не больше


static func straighten(surface: Heightfield, pts: Array, fixed: PackedByteArray, rules: Dictionary, tolerance: float) -> Array:
	var n := pts.size()
	var out: Array = [pts[0]]
	var out_fixed := PackedByteArray([fixed[0]])
	var i := 0
	while i < n - 1:
		var best := i + 1
		if fixed[i] == 0:
			var j := mini(n - 1, i + STRAIGHT_SPAN)
			while j > i + 1:
				if _chord_ok(surface, pts, fixed, i, j, rules, tolerance):
					best = j
					break
				j -= 1
		out.append(pts[best])
		out_fixed.append(fixed[best])
		i = best
	return [out, out_fixed]


static func _chord_ok(surface: Heightfield, pts: Array, fixed: PackedByteArray, i: int, j: int, rules: Dictionary, tolerance: float) -> bool:
	var a := Vector2(pts[i].x, pts[i].y)
	var b := Vector2(pts[j].x, pts[j].y)
	if pts[j].w != pts[i].w:
		return false
	for k in range(i + 1, j):
		if fixed[k] != 0 or pts[k].w != pts[i].w:
			return false
		var p := Vector2(pts[k].x, pts[k].y)
		if p.distance_squared_to(Geometry2D.get_closest_point_to_segment(p, a, b)) > tolerance * tolerance:
			return false
	var length := a.distance_to(b)
	if length < 0.001:
		return false
	var normal := (b - a).orthogonal() * (float(pts[i].w) * 0.5 / length)
	var samples := ceili(length / 0.25)
	var line: Array = []
	for k in samples + 1:
		var p := a.lerp(b, float(k) / samples)
		for side: float in [-1.0, 0.0, 1.0]:
			if axis_blocked(surface.world, rules.axis, p + normal * side):
				return false
		if k % 2 == 0 or k == samples:
			line.append(_point(p, pts[i].w))
	if rules.corridor.is_valid() and not rules.corridor.call(line):
		return false
	var relax: float = rules.relax
	if relax <= 1.0:
		return segment_ok(surface, pts[i], pts[j], rules.grade, rules.cross, rules.probe)
	if not segment_ok(surface, pts[i], pts[j], rules.grade * relax, rules.cross, rules.probe):
		return false
	var profile: Array = []
	for k in samples + 1:
		profile.append(a.lerp(b, float(k) / samples))
	return profile_ok(surface, profile, rules.grade, PackedByteArray(), rules.down_ratio)


## Сохраняем вершины дуг и якоря; длинные прямые делим для профиля и покрытия.
static func stations(points: Array) -> Array:
	var out: Array = [points[0]]
	for k in range(1, points.size()):
		var a: Dictionary = points[k - 1]
		var b: Dictionary = points[k]
		var length := Grid.hypot(b.x - a.x, b.y - a.y) * GameConfig.TILE
		var steps := ceili(length / 2.0)
		for j in range(1, steps):
			var t := float(j) / steps
			out.append({x = lerpf(a.x, b.x, t), y = lerpf(a.y, b.y, t), w = lerpf(a.w, b.w, t)})
		out.append(b)
	return out


static func axis_blocked(w: WorldData, axis: PackedByteArray, p: Vector2) -> bool:
	var x := floori(p.x)
	var y := floori(p.y)
	return x < 0 or y < 0 or x >= w.W or y >= w.H or (not axis.is_empty() and axis[y * w.W + x] != 0)


## Объединяем короткие ступени решётки, если одна кривая помещается в коридоре.
static func _bend_group(surface: Heightfield, path: Array, width: float, rules: Dictionary, retry := false) -> Array:
	var a: Vector2 = path[0]
	var b: Vector2 = path[1]
	var c: Vector2 = path[-2]
	var d: Vector2 = path[-1]
	var incoming := (b - a).normalized()
	var outgoing := (d - c).normalized()
	var axis := (d - a).normalized()
	var angle := absf(incoming.angle_to(outgoing))
	if angle > PI * 0.75:
		return []
	for j in range(1, path.size()):
		var direction: Vector2 = (path[j] - path[j - 1]).normalized()
		if axis.dot(direction) < 0.25:
			return []
	var speed: float = rules.speed * (0.62 if angle >= deg_to_rad(105.0) else 1.0)
	var handle := 3.0 * pow(cos(angle * 0.25), 2.0)
	var left := minf(a.distance_to(b) * 0.49, 3.5)
	var right := minf(c.distance_to(d) * 0.49, 3.5)
	var short_s := false
	if rules.long_s_handles and path.size() == 4 and b.distance_squared_to(c) <= 2.25:
		var middle := (c - b).normalized()
		var first_turn := incoming.cross(middle)
		var second_turn := middle.cross(outgoing)
		short_s = first_turn * second_turn < 0.0 and minf(absf(first_turn), absf(second_turn)) >= 0.65
	var parallel := incoming.dot(outgoing) >= 0.99
	var attempts := GROUP_TRIMS
	if retry:
		if not short_s:
			return []
		attempts = GROUP_RETRIES if parallel else [GROUP_LONG] + GROUP_RETRIES
	elif short_s and parallel:
		attempts = GROUP_TRIMS + [GROUP_LONG]
	for trim: Vector4 in attempts:
		var p := b - incoming * left * trim.x
		var q := c + outgoing * right * trim.y
		var lead := p.distance_to(q) / handle
		var curve := fit_curve(surface, [p, p + incoming * (lead * trim.z), q - outgoing * (lead * trim.w), q], path, width, speed, rules)
		if not curve.is_empty():
			return curve
	return []


static func _bend(surface: Heightfield, a: Vector2, b: Vector2, c: Vector2, width: float, rules: Dictionary) -> Array:
	var incoming := (b - a).normalized()
	var outgoing := (c - b).normalized()
	var angle := absf(incoming.angle_to(outgoing))
	if angle < 0.04 or angle > PI - 0.04:
		return []
	var hairpin := angle >= deg_to_rad(105.0)
	var speed: float = rules.speed * (0.62 if hairpin else 1.0)
	var left := minf(a.distance_to(b) * 0.49, 3.0)
	var right := minf(b.distance_to(c) * 0.49, 3.0)
	var handle := 4.0 / 3.0 * tan(angle * 0.25) / tan(angle * 0.5)
	# У стеснённого поворота допускаем более медленный проход, сохраняя запас на уклоне.
	for factor: float in [1.0, 0.72, 0.55]:
		for trim: Vector2 in TURN_TRIMS:
			var l := left * trim.x
			var r := right * trim.y
			var p := b - incoming * l
			var q := b + outgoing * r
			var curve := fit_curve(surface, [p, p + incoming * l * handle, q - outgoing * r * handle, q],
				[a, b, c], width, speed * factor, rules)
			if not curve.is_empty():
				return curve
	return []


## У слияния держим различимый угол к основной дороге, у Т-образного узла выпрямляем въезд.
## Касание осей остаётся в закреплённой точке. Подход не выходит за половину первого отрезка.
static func _approach(surface: Heightfield, end: Dictionary, next: Dictionary, join: Dictionary, rules: Dictionary) -> Array:
	if join.is_empty() or end.w != next.w:
		return []
	var a := Vector2(end.x, end.y)
	var b := Vector2(next.x, next.y)
	var direction := (b - a).normalized()
	var host: Vector2 = join.tangent
	var side := signf(host.cross(direction))
	if side == 0.0:
		return []
	if host.dot(direction) < 0.0:
		host = -host
		side = -side
	var angle := absf(host.angle_to(direction))
	var target := deg_to_rad(30.0) if angle < deg_to_rad(30.0) else angle
	if angle >= deg_to_rad(60.0):
		target = PI * 0.5
	if absf(target - angle) < 0.04:
		return []
	var heading := host.rotated(side * target)
	for scale: float in [1.0, 0.8, 0.6]:
		var lead := minf(a.distance_to(b) * 0.49, 3.0) * scale
		var q := a + direction * lead
		var curve := fit_curve(surface, [a, a + heading * lead / 3.0, q - direction * lead / 3.0, q],
			[a, b], end.w, rules.speed * 0.72, rules)
		if not curve.is_empty():
			curve[0] = end
			return curve
	return []


static func fit_curve(surface: Heightfield, control: Array, corridor: Array, width: float, speed: float, rules: Dictionary) -> Array:
	var a: Vector2 = control[0]
	var b: Vector2 = control[1]
	var c: Vector2 = control[2]
	var d: Vector2 = control[3]
	var steps := maxi(8, ceili((a.distance_to(b) + b.distance_to(c) + c.distance_to(d)) / 0.25))
	var curve: Array = []
	var grade: float = rules.grade
	for k in steps + 1:
		var t := float(k) / steps
		var ab := a.lerp(b, t)
		var bc := b.lerp(c, t)
		var cd := c.lerp(d, t)
		var left := ab.lerp(bc, t)
		var right := bc.lerp(cd, t)
		var p := left.lerp(right, t)
		var tangent := (right - left) * 3.0
		var second := (cd - 2.0 * bc + ab) * 6.0
		var length := tangent.length()
		if length < 0.001:
			return []
		var curvature := absf(tangent.cross(second)) / (length * length * length * GameConfig.TILE)
		var lateral := speed * speed * curvature
		var brake_sq: float = rules.accel * rules.accel - lateral * lateral
		if brake_sq <= 0.0 or curvature * (width * GameConfig.TILE * 0.5 + 0.15) >= 1.0:
			return []
		grade = minf(grade, sqrt(brake_sq) / GameConfig.GRAVITY)
		var deviation := INF
		for j in range(1, corridor.size()):
			var closest := Geometry2D.get_closest_point_to_segment(p, corridor[j - 1], corridor[j])
			deviation = minf(deviation, p.distance_squared_to(closest))
		if deviation > TURN_CORRIDOR * TURN_CORRIDOR:
			return []
		var normal := tangent.orthogonal() * (width * 0.5 / length)
		for side: float in [-1.0, 0.0, 1.0]:
			if axis_blocked(surface.world, rules.axis, p + normal * side):
				return []
		curve.append(_point(p, width))
	if rules.corridor.is_valid() and not rules.corridor.call(curve):
		return []
	var relax: float = rules.relax
	var local := grade * relax if relax > 1.0 else grade
	for k in range(1, curve.size()):
		if not segment_ok(surface, curve[k - 1], curve[k], local, rules.cross, rules.probe):
			return []
	if relax > 1.0:
		var profile: Array = []
		for p: Dictionary in curve:
			profile.append(Vector2(p.x, p.y))
		if not profile_ok(surface, profile, grade, PackedByteArray(), rules.down_ratio):
			return []
	return curve


## 15.11.2026: полотно (RoadBed) выравнивает профиль дороги на десятках метров, поэтому линия по найденному пути
## проверяется так же: на каждые PROFILE_BASE клеток уклон не круче предела вида, а короткий бугор (по segment_ok)
## не круче предела × line_relax. Иначе прямая или дуга через бугор в 4 м запрещена, и линия остаётся «пилой» сетки,
## хотя маршрут в целом в пределе (разбор 15.11, отрог у озера на «Север-1234»). Поиск пути этим не меняется.
const PROFILE_BASE := 3.0 # клеток (12 м)


## points — точки вдоль линии (Vector2, клетки), не реже 0,25 клетки
static func profile_ok(surface: Heightfield, points: Array, grade: float, skip := PackedByteArray(), down_ratio := 1.0) -> bool:
	var T := GameConfig.TILE
	var heights := PackedFloat64Array()
	var along := PackedFloat64Array()
	var run := 0.0
	for k in points.size():
		var p: Vector2 = points[k]
		if k > 0: run += p.distance_to(points[k - 1])
		along.append(run)
		heights.append(surface.ground_at(p.x * T, p.y * T))
	# окно от j до k; точка на настиле сооружения (skip) начинает окно заново
	var j := 0
	for k in range(1, points.size()):
		if not skip.is_empty() and skip[k] != 0:
			j = k
			continue
		while j + 1 < k and along[k] - along[j + 1] >= PROFILE_BASE:
			j += 1
		var rise := heights[k] - heights[j]
		var limit := grade * down_ratio if rise < 0.0 else grade
		if absf(rise) > limit * (along[k] - along[j]) * T + 0.00001:
			return false
	return true


## probe — Heightfield.fast_water(): та же проверка на C# (FastGrid.RoadSegment)
static func segment_ok(surface: Heightfield, a: Dictionary, b: Dictionary, max_grade := StageTrails.ROAD_LIMIT, max_cross := StageTrails.BENCH_CROSS, probe: Object = null) -> bool:
	if probe != null:
		return probe.RoadSegment(a.x, a.y, b.x, b.y, a.w, max_grade, max_cross)
	var dx: float = b.x - a.x
	var dy: float = b.y - a.y
	var length := Grid.hypot(dx, dy)
	if length < 0.00001:
		return true
	var steps := maxi(1, ceili(length / 0.1))
	var nx := -dy / length * float(a.w) * 0.5
	var ny := dx / length * float(a.w) * 0.5
	for side in [-1.0, 0.0, 1.0]:
		var previous := 0.0
		for k in steps + 1:
			var t := float(k) / steps
			var x: float = (a.x + dx * t + nx * side) * GameConfig.TILE
			var z: float = (a.y + dy * t + ny * side) * GameConfig.TILE
			var h := surface.ground_at(x, z)
			if surface.depth_at(x, z) > 0.3 or k > 0 and absf(h - previous) > max_grade * length * GameConfig.TILE / steps + 0.00001:
				return false
			previous = h
	# Поперёк стены ось может быть горизонтальной. Не срезаем туда безопасный поворот.
	for k in steps + 1:
		var t := float(k) / steps
		var x: float = (a.x + dx * t) * GameConfig.TILE
		var z: float = (a.y + dy * t) * GameConfig.TILE
		var across := absf(surface.ground_at(x + nx * GameConfig.TILE, z + ny * GameConfig.TILE) - surface.ground_at(x - nx * GameConfig.TILE, z - ny * GameConfig.TILE))
		if across > max_cross * float(a.w) * GameConfig.TILE + 0.00001:
			return false
	return true


static func _point(p: Vector2, width: float) -> Dictionary:
	return {x = p.x, y = p.y, w = width}
