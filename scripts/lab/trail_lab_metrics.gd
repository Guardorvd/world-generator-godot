class_name TrailLabMetrics
extends RefCounted
## Ride and feature metrics for Trail Lab. Fed once per physics tick; pure data, no scene access.

const ZONE_TAIL := 8.0 # metres after an element that still count towards its landing

# whole run
var time := 0.0
var distance := 0.0
var top_speed := 0.0
var peak_slip := 0.0
var peak_grip := 0.0
var peak_fork := 0.0
var peak_shock := 0.0
var bottom_outs := 0
var worst_landing := 0.0
var jumps := 0

# last jump
var air_time := 0.0
var jump_length := 0.0
var jump_apex := 0.0
var jump_takeoff_speed := 0.0
var landing_impact := 0.0
var _takeoff := Vector3()
var _takeoff_speed := 0.0
var _apex := 0.0
var _was_air := false

# element being crossed (or just crossed)
var element := -1
var entry_speed := 0.0
var exit_speed := 0.0
var zone_peak_squash := 0.0
var zone_air := 0.0
var zone_landing := 0.0
var zone_time := 0.0
var _inside := false
var _prev_xz := Vector2()

func reset(bike: BikeRide) -> void:
	for p in get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and p.type in [TYPE_FLOAT, TYPE_INT]:
			set(p.name, type_convert(0, p.type))
	element = -1
	_inside = false
	_was_air = false
	_prev_xz = Vector2(bike.x, bike.z)

func tick(dt: float, bike: BikeRide, route: TrailDefinition) -> void:
	var here := Vector2(bike.x, bike.z)
	var step := _prev_xz.distance_to(here)
	_prev_xz = here
	time += dt
	distance += step
	var ms := absf(bike.speed)
	top_speed = maxf(top_speed, ms)
	peak_slip = maxf(peak_slip, absf(bike.slip))
	peak_grip = maxf(peak_grip, bike.grip_usage)
	peak_fork = maxf(peak_fork, bike.squash_f)
	peak_shock = maxf(peak_shock, bike.squash_r)
	if bike.bottom_out > 0.0: bottom_outs += 1
	if bike.land_impact > 0.0:
		worst_landing = maxf(worst_landing, bike.land_impact)
		landing_impact = bike.land_impact
		if _inside: zone_landing = maxf(zone_landing, bike.land_impact)
	_track_jump(dt, bike, here)
	_track_element(dt, bike, route, ms)

func _track_jump(dt: float, bike: BikeRide, here: Vector2) -> void:
	if bike.airborne:
		if not _was_air:
			_takeoff = Vector3(here.x, bike.y, here.y)
			_takeoff_speed = absf(bike.speed)
			_apex = 0.0
			air_time = 0.0
		air_time += dt
		_apex = maxf(_apex, bike.y - _takeoff.y)
		jump_length = here.distance_to(Vector2(_takeoff.x, _takeoff.z))
		jump_apex = _apex
		jump_takeoff_speed = _takeoff_speed
	elif _was_air:
		jumps += 1
	_was_air = bike.airborne

func _track_element(dt: float, bike: BikeRide, route: TrailDefinition, ms: float) -> void:
	var station := route.nearest(Vector2(bike.x, bike.z)).x
	var found := -1
	for i in route.elements.size():
		var e := route.elements[i]
		if station >= e.station - e.length * 0.5 and station <= e.station + e.length * 0.5 + ZONE_TAIL:
			found = i
			break
	if found != element and found >= 0:
		element = found
		entry_speed = ms
		exit_speed = ms
		zone_peak_squash = 0.0
		zone_air = 0.0
		zone_landing = 0.0
		zone_time = 0.0
		_inside = true
	elif found < 0:
		_inside = false
	if _inside:
		zone_time += dt
		exit_speed = ms
		zone_peak_squash = maxf(zone_peak_squash, maxf(bike.squash_f, bike.squash_r))
		if bike.airborne: zone_air += dt

## Speeds are stored in m/s and shown in km/h.
func report(route: TrailDefinition) -> String:
	var lines := PackedStringArray()
	lines.append("Заезд %.1f с · путь %.0f м · макс. %.0f км/ч" % [time, distance, top_speed * 3.6])
	lines.append("Пик: снос %.1f° · сцепление %.0f%% · вилка %.3f м · зад %.3f м" % [rad_to_deg(peak_slip), peak_grip * 100.0, peak_fork, peak_shock])
	lines.append("Пробоев подвески %d · худшее приземление %.1f м/с" % [bottom_outs, worst_landing])
	if jumps > 0 or air_time > 0.0:
		lines.append("Прыжок: %.2f с · %.1f м · пик %.2f м · взлёт %.0f км/ч · удар %.1f м/с" % [air_time, jump_length, jump_apex, jump_takeoff_speed * 3.6, landing_impact])
	if element >= 0 and element < route.elements.size():
		var e := route.elements[element]
		lines.append("Элемент %d · %s: вход %.0f → выход %.0f км/ч (%+.0f)" % [element + 1, TrailElement.Profile.keys()[e.profile], entry_speed * 3.6, exit_speed * 3.6, (exit_speed - entry_speed) * 3.6])
		lines.append("  в воздухе %.2f с · сжатие %.3f м · приземление %.1f м/с · %.1f с" % [zone_air, zone_peak_squash, zone_landing, zone_time])
	return "\n".join(lines)
