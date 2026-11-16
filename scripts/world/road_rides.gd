extends RefCounted
## Generated natural bike itineraries. The intervals use the same section IDs and metre
## offsets as RoadTopology edges, independent of graph splits at intersections.

const Topology := preload("res://scripts/world/road_topology.gd")
const VERSION := 1
const EPS_M := 0.001
const END_TOLERANCE_M := 0.01


static func append_interval(legs: Array, section: String, from_m: float, to_m: float) -> void:
	if absf(to_m - from_m) <= EPS_M:
		return
	if not legs.is_empty():
		var prev: Dictionary = legs[-1]
		if prev.section == section and absf(prev.to_m - from_m) <= EPS_M \
				and (prev.to_m - prev.from_m) * (to_m - from_m) > 0.0:
			prev.to_m = to_m
			return
	legs.append({section = section, from_m = from_m, to_m = to_m})


static func validation_error(w: WorldData) -> String:
	var data := w.road_rides
	if data.is_empty():
		return ""
	var context := "road_rides (%s)" % w.seed_text
	if not data.get("version") is int or data.version != VERSION or not data.get("routes") is Dictionary:
		return "%s: unsupported version or invalid routes table" % context
	if data.routes.is_empty():
		return ""
	var sections := {}
	for t: Dictionary in w.trails:
		if t.kind != "animal" and not t.has("trail_id") and not t.get("road_id", "").is_empty():
			sections[t.road_id] = t
	var lengths := {}
	for id: Variant in data.routes:
		if not id is String or id.is_empty():
			return "%s: route ID %s must be a non-empty String" % [context, id]
		var route: Variant = data.routes[id]
		if not route is Dictionary or not route.get("style") is String or route.style.is_empty() \
				or not route.get("legs") is Array or route.legs.is_empty():
			return "%s: invalid route %s" % [context, id]
		if not route.get("ascent_legs") is int or route.ascent_legs < 0 or route.ascent_legs >= route.legs.size():
			return "%s: invalid ascent or missing descent for %s" % [context, id]
		for i in route.legs.size():
			var leg: Variant = route.legs[i]
			var at := "%s: %s legs[%d]" % [context, id, i]
			if not leg is Dictionary or not leg.get("section") is String or not sections.has(leg.section):
				return at + " references an unknown natural section"
			if not lengths.has(leg.section):
				lengths[leg.section] = Topology.length_m(sections[leg.section].pts)
			if not _station_valid(leg.get("from_m"), lengths[leg.section]) \
					or not _station_valid(leg.get("to_m"), lengths[leg.section]) \
					or absf(leg.to_m - leg.from_m) <= EPS_M:
				return at + " has invalid metre offsets"
	return ""


static func _station_valid(value: Variant, length: float) -> bool:
	return (value is float or value is int) and is_finite(value) and value >= 0.0 and value <= length + END_TOLERANCE_M
