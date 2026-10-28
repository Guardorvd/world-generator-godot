class_name TrailShaping
extends Resource
## How a route reshapes the terrain under and beside it. Roads, natural trails and bike tracks differ only
## by these numbers: one profile builder and one cross-section serve all of them.
## Everything works on the sparse metre patches of RoadRefinement, never on the world grid.
## The route is chosen first and the ground is prepared for it: grade_limit is the TARGET of the designed profile, not a
## cap on the land. Cut and fill are as deep as the profile needs (no depth limit); the side slopes run out at `batter`
## (and always steeper than the natural cross slope) until they meet the ground, and the zone of influence (`reach` of the
## profile) widens with the depth, so a deep cut never ends in a wall at the edge of a narrow strip.
@export_range(0.02, 0.6) var grade_limit := 0.16 ## designed longitudinal grade (target), m/m
@export_range(1.0, 40.0) var level_window := 7.0 ## length over which the centre line is levelled, m
@export_range(0.0, 1.0) var strength := 0.9 ## share of the designed change that is actually applied
@export_range(0.0, 1.0) var side_follow := 0.4 ## 0 — level bench cut into a slope, 1 — tread follows the natural cross slope
@export_range(0.0, 0.6) var bank_max := 0.38 ## steepest superelevation, m/m
@export_range(0.0, 20.0) var bank_gain := 9.0 ## superelevation per unit of curvature
@export_range(0.0, 30.0) var bank_ramp := 6.0 ## length over which a banked turn is entered and left, m
@export_range(0.0, 0.2) var crown := 0.0 ## rise of the tread centre over its edges, m
@export_range(0.2, 4.0) var batter := 0.7 ## slope of cut and fill sides, m/m
@export_range(0.0, 40.0) var end_fade := 12.0 ## distance over which the cross section of an open route levels out at its ends, m

## Side slopes are at least this much steeper than the natural cross slope, m/m: otherwise a cut into a slope steeper
## than `batter` would never meet the ground.
const SIDE_GAIN := 0.35
## Spare width past the computed run-out of the side slopes, m.
const SIDE_MARGIN := 1.5
## Share of the zone of influence over which the change blends into the untouched ground at its outer edge.
const FADE := 0.15
## Technical bound of the zone of influence past the tread edge, m (number of metre patches and bake time). Past the
## run-out the surface still blends continuously into the ground, only steeper.
const REACH_LIMIT := 40.0
## A place of the route where less than this share of the earthworks may act (TrailBuilder.pins) is an anchor of the
## design profile: the level stays on the ground there.
const ANCHOR := 0.5

static func preset(kind: String) -> TrailShaping:
	var s := TrailShaping.new()
	match kind:
		"road": # engineered: gentle grades, level benches, wide tidy slopes
			s.grade_limit = 0.07
			s.level_window = 14.0
			s.strength = 1.0
			s.side_follow = 0.0
			s.bank_max = 0.08
			s.bank_ramp = 10.0
			s.crown = 0.05
			s.batter = 0.5
			s.end_fade = 12.0
		"trail": # natural: stays close to the ground, only trims rough spots
			s.grade_limit = 0.3
			s.level_window = 3.0
			s.strength = 0.4
			s.side_follow = 0.85
			s.bank_max = 0.03
			s.bank_ramp = 4.0
			s.crown = 0.0
			s.batter = 1.0
			s.end_fade = 6.0
		_: # bike track: banked, bermed, flowing
			s.grade_limit = 0.16
			s.level_window = 7.0
			s.strength = 0.9
			s.side_follow = 0.35
			s.bank_max = 0.38
			s.bank_ramp = 6.0
			s.crown = 0.0
			s.batter = 0.7
			s.end_fade = 12.0
	return s

func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	for key in ["grade_limit", "level_window", "strength", "side_follow", "bank_max", "bank_gain", "bank_ramp", "crown", "batter", "end_fade"]:
		if not is_finite(get(key)): errors.append("Non-finite shaping value: " + key)
	if grade_limit <= 0.0 or batter <= 0.0 or level_window <= 0.0: errors.append("Shaping grade, window and batter must be positive")
	return errors

## Design profile sampled once per metre step; vertices interpolate it instead of rebuilding it.
## Open routes keep both ends on the ground (they join roads and each other there), and so does every place the
## earthworks may not change (pin_at(point) < ANCHOR: water and its shore, bridges and tunnels, other paths — the same
## pins as the bake). Between these anchors the levelled ground is limited to the target grade; where two anchors differ
## in height more than the target allows over the distance between them, that stretch takes the least grade that joins
## them (`grade_used` is the steepest such stretch): the ground is shaped, the route is kept.
func profile(h: Heightfield, d: TrailDefinition, pin_at := Callable()) -> Dictionary:
	var total := d.route_length()
	var count := maxi(8, ceili(total / RoadRefinement.STEP))
	var step := total / count
	var half := d.width * 0.5
	var ground := PackedFloat32Array()
	var cross := PackedFloat32Array()
	var curvature := PackedFloat32Array()
	var points := PackedVector2Array()
	var tangents := PackedVector2Array()
	for j in count + 1:
		var station := step * j
		var p := d.point_at(station)
		var t := d.tangent_at(station)
		var lateral := Vector2(t.y, -t.x) # direction of positive "across"
		ground.append(h.ground_at(p.x, p.y))
		var right := p + lateral * half
		var left := p - lateral * half
		cross.append((h.ground_at(right.x, right.y) - h.ground_at(left.x, left.y)) / (2.0 * half))
		curvature.append(d.curvature_at(station))
		points.append(p)
		tangents.append(t)
	var window := maxi(1, roundi(level_window / step))
	var levels := _smooth(ground, window, d.closed)
	var grade := grade_limit
	if d.closed:
		_limit_grade(levels, step, true, grade)
	else:
		var anchors := PackedInt32Array()
		for j in count + 1:
			if j == 0 or j == count or (pin_at.is_valid() and float(pin_at.call(points[j])) < ANCHOR): anchors.append(j)
		# rise allowed per step: the target, more only between anchors that need it
		var rise := PackedFloat32Array()
		rise.resize(count)
		rise.fill(grade_limit * step)
		for k in range(1, anchors.size()):
			var a := anchors[k - 1]
			var c := anchors[k]
			var need := absf(ground[c] - ground[a]) / (c - a) * (1.0001 if c == a + 1 else 1.02)
			for m in range(a, c): rise[m] = maxf(rise[m], need)
		for m in count: grade = maxf(grade, rise[m] / step)
		# every level within reach of every anchor, so the grade passes below never move the anchors
		var upper := PackedFloat32Array()
		var lower := PackedFloat32Array()
		upper.resize(count + 1)
		lower.resize(count + 1)
		upper.fill(INF)
		lower.fill(-INF)
		for j in anchors:
			upper[j] = ground[j]
			lower[j] = ground[j]
		for j in range(1, count + 1):
			upper[j] = minf(upper[j], upper[j - 1] + rise[j - 1])
			lower[j] = maxf(lower[j], lower[j - 1] - rise[j - 1])
		for j in range(count - 1, -1, -1):
			upper[j] = minf(upper[j], upper[j + 1] + rise[j])
			lower[j] = maxf(lower[j], lower[j + 1] - rise[j])
		for j in count + 1: levels[j] = clampf(levels[j], lower[j], upper[j])
		for j in range(1, count + 1): levels[j] = clampf(levels[j], levels[j - 1] - rise[j - 1], levels[j - 1] + rise[j - 1])
		for j in range(count - 1, -1, -1): levels[j] = clampf(levels[j], levels[j + 1] - rise[j], levels[j + 1] + rise[j])
	levels = _smooth(levels, maxi(1, window / 3), d.closed)
	var banks := PackedFloat32Array()
	for j in count + 1:
		banks.append(clampf(curvature[j] * bank_gain, -bank_max, bank_max) * d.auto_bank)
	banks = _smooth(banks, roundi(bank_ramp / step), d.closed)
	var follow := _smooth(cross, maxi(1, window / 2), d.closed)
	var peak_bank := 0.0
	for b in banks: peak_bank = maxf(peak_bank, absf(b))
	# Side slopes: at least `batter` and steeper than the natural cross slope by SIDE_GAIN, so they meet the ground;
	# the zone of influence is as wide as the deepest edge needs.
	var sides := PackedFloat32Array()
	var reach := half + RoadRefinement.REACH
	var deepest := 0.0
	for j in count + 1:
		var c := absf(follow[j])
		var side := maxf(batter, c + SIDE_GAIN)
		sides.append(side)
		var slope := clampf(side_follow * follow[j] + banks[j], -0.6, 0.6)
		var axis := absf(levels[j] + d.elevation_offset - ground[j])
		deepest = maxf(deepest, axis)
		reach = maxf(reach, half + (axis + absf(slope - follow[j]) * half) / (side - c) + SIDE_MARGIN)
	reach = minf(reach, half + REACH_LIMIT)
	return {levels = levels, banks = banks, cross = follow, sides = sides, points = points, tangents = tangents, total = total,
		reach = reach, grade_used = grade, deepest = deepest,
		grade_natural = _peak_grade(ground, step), grade_designed = _peak_grade(levels, step), bank_peak = peak_bank}

## Displacement of the existing surface at `at` (positive — embankment, negative — excavation). No depth limit: the
## designed surface is reached; past `p.reach` nothing changes, and the last FADE share of the zone blends into the
## ground (this matters only where the natural ground keeps rising faster than the side slope).
func offset(h: Heightfield, d: TrailDefinition, local: Vector3, at: Vector2, p: Dictionary) -> float:
	if d.earthwork <= 0.0: return 0.0
	var last: int = p.levels.size() - 1
	var index: float = clampf(local.x / p.total * last, 0.0, float(last))
	var j := mini(floori(index), last - 1)
	var f := index - j
	var level: float = lerpf(p.levels[j], p.levels[j + 1], f) + d.elevation_offset
	var tangent: Vector2 = p.tangents[j].lerp(p.tangents[j + 1], f).normalized()
	var center: Vector2 = p.points[j].lerp(p.points[j + 1], f)
	var slope := clampf(side_follow * lerpf(p.cross[j], p.cross[j + 1], f) + lerpf(p.banks[j], p.banks[j + 1], f), -0.6, 0.6)
	var across := (at - center).cross(tangent)
	var half := d.width * 0.5
	var ground := h.ground_at(at.x, at.y)
	# At the ends of an open route the level is already the ground (profile), so only the cross section fades out over
	# end_fade: the tread is level across where it meets a road or the next route, and the grade is shaped to the end.
	if not d.closed and end_fade > 0.0: slope *= smoothstep(0.0, end_fade, minf(local.x, p.total - local.x))
	var surface: float
	if local.z <= half:
		var a := clampf(across, -half, half)
		surface = level + slope * a + crown * (1.0 - (a / half) * (a / half))
	else:
		# Past the tread edge the surface climbs (cut) or falls (fill) at the side slope until it meets the ground.
		var edge := level + signf(across) * slope * half
		var run := local.z - half
		var side: float = lerpf(p.sides[j], p.sides[j + 1], f)
		surface = clampf(ground, edge - run * side, edge + run * side)
	var reach: float = p.reach
	var fade := 1.0 - smoothstep(reach - maxf(1.2, (reach - half) * FADE), reach, local.z)
	return (surface - ground) * strength * d.earthwork * fade

## Moving average; open routes keep their ends and shrink the window towards them.
static func _smooth(values: PackedFloat32Array, radius: int, closed: bool) -> PackedFloat32Array:
	var n := values.size()
	if radius <= 0 or n < 3: return values.duplicate()
	var period := n - 1 if closed else n
	var prefix := PackedFloat64Array()
	prefix.resize(n + 2 * radius + 1)
	for k in n + 2 * radius:
		var i := k - radius
		i = posmod(i, period) if closed else clampi(i, 0, n - 1)
		prefix[k + 1] = prefix[k] + values[i]
	var result := PackedFloat32Array()
	result.resize(n)
	for i in n:
		var r := radius if closed else mini(radius, mini(i, n - 1 - i))
		result[i] = (prefix[i + r + radius + 1] - prefix[i - r + radius]) / (2 * r + 1)
	if closed: result[n - 1] = result[0]
	return result

## Closed routes: forward then backward pass round the circuit twice, no step steeper than `grade`.
static func _limit_grade(levels: PackedFloat32Array, step: float, closed: bool, grade: float) -> void:
	var n := levels.size()
	var rise := grade * step
	var period := n - 1 if closed else n
	for i in range(1, period * 2):
		var a := i % period
		var b := (i - 1) % period
		levels[a] = clampf(levels[a], levels[b] - rise, levels[b] + rise)
	for i in range(1, period * 2):
		var a := posmod(period - 1 - i, period)
		var b := (a + 1) % period
		levels[a] = clampf(levels[a], levels[b] - rise, levels[b] + rise)
	if closed: levels[n - 1] = levels[0]

static func _peak_grade(values: PackedFloat32Array, step: float) -> float:
	var peak := 0.0
	for j in range(0, values.size() - 4):
		peak = maxf(peak, absf(values[j + 4] - values[j]) / (4.0 * step))
	return peak
