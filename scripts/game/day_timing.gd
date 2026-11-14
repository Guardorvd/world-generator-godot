extends RefCounted
## Fractions of real cycle time at 04:00, 06:30, 17:30, 20:00 and the next 04:00.
## Daylight including twilight receives 65%, with 20% of that for each twilight.
const DAWN := 4.0
const HOURS := [0.0, 2.5, 13.5, 16.0, 24.0]
const PHASES := [0.0, 0.13, 0.52, 0.65, 1.0]
const DAWN_RATE := 0.13 / 2.5
const DAY_RATE := 0.39 / 11.0
const NIGHT_RATE := 0.35 / 8.0
# Slopes of real cycle time per game hour. The shared tangent at each boundary
# keeps the apparent speeds of the clock, sun and stars continuous.
const TWILIGHT_TANGENT := 2.0 * DAWN_RATE * DAY_RATE / (DAWN_RATE + DAY_RATE)
const NIGHT_TANGENT := 2.0 * DAWN_RATE * NIGHT_RATE / (DAWN_RATE + NIGHT_RATE)
const TANGENTS := [NIGHT_TANGENT, TWILIGHT_TANGENT, TWILIGHT_TANGENT, NIGHT_TANGENT, NIGHT_TANGENT]


## Advance an unwrapped clock so large steps and midnight retain the day number.
static func advance(hour: float, cycle_fraction: float, long_twilight: bool) -> float:
	if cycle_fraction == 0.0:
		return hour
	if not long_twilight:
		return hour + cycle_fraction * 24.0
	var since_dawn := hour - DAWN
	var day := floorf(since_dawn / 24.0)
	var h := since_dawn - day * 24.0
	var segment := _segment(h, HOURS)
	var width: float = HOURS[segment + 1] - HOURS[segment]
	var u: float = (h - HOURS[segment]) / width
	var elapsed_cycles := _phase(segment, width, u) + cycle_fraction
	var whole_cycles := floorf(elapsed_cycles)
	var phase := elapsed_cycles - whole_cycles
	segment = _segment(phase, PHASES)
	width = HOURS[segment + 1] - HOURS[segment]
	var start: float = PHASES[segment]
	var span: float = PHASES[segment + 1] - start
	var a: float = width * TANGENTS[segment]
	var b: float = width * TANGENTS[segment + 1]
	var quadratic := 3.0 * span - 2.0 * a - b
	var cubic := a + b - 2.0 * span
	var target := phase - start
	u = target / span
	# The monotone cubic's tangent stays positive. Linear interpolation gives
	# a close starting point even when a step crosses a boundary or midnight.
	for iteration in 5:
		var slope := a + u * (2.0 * quadratic + 3.0 * u * cubic)
		var elapsed := u * (a + u * (quadratic + u * cubic))
		u = clampf(u - (elapsed - target) / slope, 0.0, 1.0)
	return (day + whole_cycles) * 24.0 + DAWN + HOURS[segment] + u * width


static func _segment(value: float, boundaries: Array) -> int:
	for i in range(1, boundaries.size() - 1):
		if value < boundaries[i]:
			return i - 1
	return boundaries.size() - 2


static func _phase(segment: int, width: float, u: float) -> float:
	var start: float = PHASES[segment]
	var span: float = PHASES[segment + 1] - PHASES[segment]
	var a: float = width * TANGENTS[segment]
	var b: float = width * TANGENTS[segment + 1]
	return start + u * (a + u * (3.0 * span - 2.0 * a - b + u * (a + b - 2.0 * span)))
