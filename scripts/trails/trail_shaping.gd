class_name TrailShaping
extends Resource
## How a route reshapes the terrain under and beside it. Roads, natural trails and bike tracks differ only
## by these numbers: one profile builder and one cross-section serve all of them.
## Everything works on the sparse metre patches of RoadRefinement, never on the world grid.
@export_range(0.02, 0.6) var grade_limit := 0.16 ## steepest designed longitudinal grade, m/m
@export_range(1.0, 40.0) var level_window := 7.0 ## length over which the centre line is levelled, m
@export_range(0.0, 3.0) var max_cut := 1.2 ## deepest excavation, m
@export_range(0.0, 3.0) var max_fill := 1.0 ## highest embankment, m
@export_range(0.0, 1.0) var strength := 0.9 ## share of the designed change that is actually applied
@export_range(0.0, 1.0) var side_follow := 0.4 ## 0 — level bench cut into a slope, 1 — tread follows the natural cross slope
@export_range(0.0, 0.6) var bank_max := 0.38 ## steepest superelevation, m/m
@export_range(0.0, 20.0) var bank_gain := 9.0 ## superelevation per unit of curvature
@export_range(0.0, 30.0) var bank_ramp := 6.0 ## length over which a banked turn is entered and left, m
@export_range(0.0, 0.2) var crown := 0.0 ## rise of the tread centre over its edges, m
@export_range(0.2, 4.0) var batter := 0.7 ## slope of cut and fill sides, m/m
@export_range(0.0, 40.0) var end_fade := 12.0 ## distance over which an open route fades into the terrain, m

static func preset(kind: String) -> TrailShaping:
	var s := TrailShaping.new()
	match kind:
		"road": # engineered: gentle grades, level benches, wide tidy slopes
			s.grade_limit = 0.07
			s.level_window = 14.0
			s.max_cut = 2.0
			s.max_fill = 2.0
			s.strength = 1.0
			s.side_follow = 0.0
			s.bank_max = 0.08
			s.bank_ramp = 10.0
			s.crown = 0.05
			s.batter = 0.5
			s.end_fade = 12.0
		"trail": # natural: stays on the ground, only trims rough spots
			s.grade_limit = 0.3
			s.level_window = 3.0
			s.max_cut = 0.3
			s.max_fill = 0.2
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
			s.max_cut = 1.4
			s.max_fill = 1.0
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
	for key in ["grade_limit", "level_window", "max_cut", "max_fill", "strength", "side_follow", "bank_max", "bank_gain", "bank_ramp", "crown", "batter", "end_fade"]:
		if not is_finite(get(key)): errors.append("Non-finite shaping value: " + key)
	if grade_limit <= 0.0 or batter <= 0.0 or level_window <= 0.0: errors.append("Shaping grade, window and batter must be positive")
	return errors

## Design profile sampled once per metre step; vertices interpolate it instead of rebuilding it.
func profile(h: Heightfield, d: TrailDefinition) -> Dictionary:
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
	for pass_index in 3:
		_clamp_range(levels, ground)
		_limit_grade(levels, step, d.closed)
	levels = _smooth(levels, maxi(1, window / 3), d.closed)
	_clamp_range(levels, ground)
	var banks := PackedFloat32Array()
	for j in count + 1:
		banks.append(clampf(curvature[j] * bank_gain, -bank_max, bank_max) * d.auto_bank)
	banks = _smooth(banks, roundi(bank_ramp / step), d.closed)
	var follow := _smooth(cross, maxi(1, window / 2), d.closed)
	var peak_bank := 0.0
	for b in banks: peak_bank = maxf(peak_bank, absf(b))
	return {levels = levels, banks = banks, cross = follow, points = points, tangents = tangents, total = total,
		grade_natural = _peak_grade(ground, step), grade_designed = _peak_grade(levels, step), bank_peak = peak_bank}

## Displacement of the existing surface at `at` (positive — embankment, negative — excavation).
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
	var surface: float
	if local.z <= half:
		var a := clampf(across, -half, half)
		surface = level + slope * a + crown * (1.0 - (a / half) * (a / half))
	else:
		# Past the tread edge the surface climbs (cut) or falls (fill) at the batter until it meets the ground.
		var edge := level + signf(across) * slope * half
		var run := local.z - half
		surface = clampf(ground, edge - run * batter, edge + run * batter)
	var fade := 1.0 - smoothstep(half + RoadRefinement.REACH * 0.6, half + RoadRefinement.REACH, local.z)
	if not d.closed and end_fade > 0.0: fade *= smoothstep(0.0, end_fade, minf(local.x, p.total - local.x))
	return clampf((surface - ground) * strength * d.earthwork * fade, -max_cut, max_fill)

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

func _clamp_range(levels: PackedFloat32Array, ground: PackedFloat32Array) -> void:
	for j in levels.size(): levels[j] = clampf(levels[j], ground[j] - max_cut, ground[j] + max_fill)

## Forward then backward pass: no step of the profile is steeper than the limit. Closed routes go round twice.
func _limit_grade(levels: PackedFloat32Array, step: float, closed: bool) -> void:
	var n := levels.size()
	var rise := grade_limit * step
	var period := n - 1 if closed else n
	var span := period * 2 if closed else n
	for i in range(1, span):
		var a := i % period
		var b := (i - 1) % period
		levels[a] = clampf(levels[a], levels[b] - rise, levels[b] + rise)
	for i in range(1, span):
		var a := posmod(period - 1 - i, period)
		var b := (a + 1) % period
		levels[a] = clampf(levels[a], levels[b] - rise, levels[b] + rise)
	if closed: levels[n - 1] = levels[0]

static func _peak_grade(values: PackedFloat32Array, step: float) -> float:
	var peak := 0.0
	for j in range(0, values.size() - 4):
		peak = maxf(peak, absf(values[j + 4] - values[j]) / (4.0 * step))
	return peak
