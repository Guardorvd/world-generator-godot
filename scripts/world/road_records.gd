extends RefCounted
## Validation at publication and load boundaries. The stored dictionaries belong to their callers.

enum Phase { COMPATIBLE, PUBLISHED, SURFACED }

const KINDS := ["road", "trail", "mountain", "animal"]


## Compatible input may predate station surfaces or physical IDs. Newly published natural
## sections must have an ID. Finished records must have one material per station.
static func validation_error(records: Variant, context: String, phase := Phase.COMPATIBLE) -> String:
	if not records is Array:
		return "%s: trails must be an Array" % context
	var roads := {}
	var prepared := {}
	for i in records.size():
		var record: Variant = records[i]
		var issue := _record_error(record, phase)
		if issue.is_empty():
			issue = _id_error(record, "road_id", roads, i)
		if issue.is_empty():
			issue = _id_error(record, "trail_id", prepared, i)
		if not issue.is_empty():
			return "%s: trails[%d]%s" % [context, i, issue]
	return ""


static func _record_error(record: Variant, phase: Phase) -> String:
	if not record is Dictionary:
		return " must be a Dictionary"
	var kind: Variant = record.get("kind")
	if not kind is String or kind not in KINDS:
		return ".kind must be road, trail, mountain or animal"
	var pts: Variant = record.get("pts")
	if not pts is Array or pts.size() < 2:
		return ".pts must be an Array with at least two stations"
	for i in pts.size():
		var p: Variant = pts[i]
		if not p is Dictionary:
			return ".pts[%d] must be a Dictionary" % i
		if not _finite_number(p.get("x")):
			return ".pts[%d].x must be a finite coordinate" % i
		if not _finite_number(p.get("y")):
			return ".pts[%d].y must be a finite coordinate" % i
		if not Vector2(p.x, p.y).is_finite():
			return ".pts[%d] coordinates exceed Vector2 range" % i
		if not _finite_number(p.get("w")) or p.w <= 0.0:
			return ".pts[%d].w must be a finite positive width in cells" % i
	if record.has("surf"):
		var surf: Variant = record.surf
		if not surf is PackedByteArray:
			return ".surf must be a PackedByteArray"
		if surf.size() != pts.size():
			return ".surf has %d entries for %d stations" % [surf.size(), pts.size()]
		for i in surf.size():
			if surf[i] >= RoadSurface.LIST.size() or kind == "animal" and surf[i] != RoadSurface.NONE:
				return ".surf[%d] has invalid material %d for %s" % [i, surf[i], kind]
	elif phase == Phase.SURFACED:
		return ".surf is missing after surface assignment"
	if kind == "animal" and (record.has("trail_id") or record.get("road_id", "") != "" or record.has("ride")):
		return " animal trails cannot have a road, prepared trail or ride ID"
	if record.has("trail_id"):
		var issue := _prepared_error(record, pts)
		if not issue.is_empty():
			return issue
	elif phase == Phase.PUBLISHED and kind != "animal" and record.get("road_id", "") == "":
		return ".road_id is missing on a newly published natural section"
	if record.has("reconstruction_ranges_m"):
		var ranges: Variant = record.reconstruction_ranges_m
		if kind == "animal" or record.has("trail_id") or not ranges is PackedFloat64Array or ranges.is_empty() or ranges.size() % 2 != 0:
			return ".reconstruction_ranges_m must be pairs of stations on a natural road"
		var length := 0.0
		for i in range(1, pts.size()):
			length += Vector2(pts[i - 1].x, pts[i - 1].y).distance_to(Vector2(pts[i].x, pts[i].y)) * GameConfig.TILE
		var last := 0.0
		for i in range(0, ranges.size(), 2):
			var start: float = ranges[i]
			var finish: float = ranges[i + 1]
			if (not is_finite(start) or not is_finite(finish) or start < last or finish <= start
					or finish > length + 0.01 or finish - start > 96.01):
				return ".reconstruction_ranges_m are outside the section or overlap"
			last = finish
	for field: String in ["ride", "ride_style", "ride_climb"]:
		if record.has(field) and (not record[field] is String or record[field].is_empty()):
			return ".%s must be a non-empty String" % field
	if record.has("ride") != record.has("ride_style") or record.has("ride_climb") and not record.has("ride"):
		return " ride metadata needs both ride and ride_style"
	return ""


static func _prepared_error(record: Dictionary, pts: Array) -> String:
	var override: Variant = record.get("surface_override", RoadSurface.NONE)
	if not override is int or override < RoadSurface.NONE or override >= RoadSurface.LIST.size():
		return ".surface_override must be a valid material ID"
	var formation: Variant = record.get("formation", Vector3.ZERO)
	if not formation is Vector3 or not formation.is_finite() or formation.x < 0.0 or formation.x > 1.0 \
			or absf(formation.y) > 2.0 or formation.z < 0.0 or formation.z > 1.0:
		return ".formation must contain finite earthwork [0, 1], elevation offset [-2, 2] m and auto bank [0, 1]"
	var closed: Variant = record.get("closed", false)
	if not closed is bool:
		return ".closed must be a bool"
	if closed:
		var first := Vector2(pts[0].x, pts[0].y)
		var last := Vector2(pts[-1].x, pts[-1].y)
		if pts.size() < 4 or first.distance_to(last) * GameConfig.TILE > 0.01:
			return ".pts of a closed trail must repeat the first station at the end"
	return ""


static func _id_error(record: Dictionary, field: String, seen: Dictionary, index: int) -> String:
	if not record.has(field):
		return ""
	var id: Variant = record[field]
	if not id is String or field == "trail_id" and id.is_empty():
		return ".%s must be %s" % [field, "a non-empty String" if field == "trail_id" else "a String"]
	# RoadTopology also treats an old empty road_id as absent.
	if id.is_empty():
		return ""
	if seen.has(id):
		return ".%s duplicates trails[%d].%s (%s)" % [field, seen[id], field, id]
	seen[id] = index
	return ""


static func _finite_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))
