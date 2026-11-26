extends RefCounted
## Безопасный снимок для интерфейса; исходная запись и файл не изменяются.


static func make(source: Dictionary) -> Dictionary:
	var entry := source.duplicate()
	for key: String in ["bike", "foot", "time", "moving_time", "climb", "descent", "speed_avg", "speed_max", "jumps", "air_max", "falls", "photos", "quests"]:
		if entry.has(key) and (not _number(entry[key]) or float(entry[key]) < 0.0 or float(entry[key]) > 1.0e12):
			entry.erase(key)
	for key: String in ["alt_min", "alt_max"]:
		if entry.has(key) and (not _number(entry[key]) or absf(float(entry[key])) > 1.0e12):
			entry.erase(key)
	if entry.has("start") and (not _number(entry.start) or float(entry.start) < -62135596800.0 or float(entry.start) > 253402300799.0):
		entry.erase("start")
	for key: String in ["world_title", "seed", "template_id", "thumb"]:
		if entry.has(key) and not entry[key] is String:
			entry.erase(key)
	if entry.has("walk") and not entry.walk is bool:
		entry.erase("walk")
	for key: String in ["places", "photo_paths"]:
		var clean: Array[String] = []
		if entry.get(key) is Array:
			for value: Variant in entry[key]:
				if value is String:
					clean.append(value)
		entry[key] = clean
	var profile: Array = []
	if entry.get("profile") is Array:
		for value: Variant in entry.profile:
			if not _number(value) or absf(float(value)) > 1.0e12:
				profile.clear()
				break
			profile.append(value)
	entry.profile = profile
	var marks: Array = []
	if entry.get("fall_marks") is Array:
		for value: Variant in entry.fall_marks:
			if not value is Dictionary or not _coordinate(value.get("x")) or not _coordinate(value.get("z")):
				continue
			var mark: Dictionary = value.duplicate()
			if mark.has("progress") and (not _number(mark.progress) or float(mark.progress) < 0.0 or float(mark.progress) > 1.0):
				mark.erase("progress")
			marks.append(mark)
	entry.fall_marks = marks
	var legs: Array = []
	if entry.get("track") is Array:
		for leg: Variant in entry.track:
			if not leg is Array:
				continue
			var segment: Array = []
			for point: Variant in leg:
				if point is Array and point.size() == 2 and _coordinate(point[0]) and _coordinate(point[1]):
					segment.append(point)
				else:
					if segment.size() > 1:
						legs.append(segment)
					segment = []
			if segment.size() > 1:
				legs.append(segment)
	entry.track = legs
	return entry


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _coordinate(value: Variant) -> bool:
	return _number(value) and absf(float(value)) <= 1.0e12


static func world_name(entry: Dictionary) -> String:
	var title := str(entry.get("world_title", "")).strip_edges()
	if title.is_empty():
		title = str(entry.get("seed", "")).strip_edges()
	return title if not title.is_empty() else "Мир без названия"
