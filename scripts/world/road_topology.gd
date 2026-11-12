extends RefCounted
## Physical records own the geometry. Graph edges refer to intervals of those records.
## Coordinates are in cells until the navigation adapter converts them to metres.
const SNAP := 1024.0
const EPS := 0.00025
const BIN := 4.0


static func _position(p: Dictionary) -> Vector2:
	return Vector2(p.x, p.y)


static func _key(p: Vector2, origin: Vector2i) -> String:
	return "%d:%d" % [roundi(p.x * SNAP) + origin.x * int(SNAP), roundi(p.y * SNAP) + origin.y * int(SNAP)]


## The ID survives edits to the point list after publication, e.g. insertion of a junction.
## For old records the same function derives an ID from the stored axis in either direction.
static func section_id(points: Array, origin: Vector2i) -> String:
	var keys := PackedStringArray()
	for p: Dictionary in points:
		var at := _position(p)
		keys.append(_key(at, origin) if at.is_finite() else "-")
	var forward := "/".join(keys)
	keys.reverse()
	var backward := "/".join(keys)
	return (forward if forward < backward else backward).sha256_text()


static func section(kind: String, points: Array, origin: Vector2i) -> Dictionary:
	return {kind = kind, pts = points, road_id = section_id(points, origin)}


## Publish the shared anchor in the physical host. Keep its section ID when inserting a vertex.
static func attach(w: WorldData, host: int, point: Vector2, changed_lines: Variant = null) -> void:
	var pts: Array = w.trails[host].pts
	var best := 0
	var best_d := INF
	for j in range(1, pts.size()):
		if minf(pts[j - 1].x, pts[j].x) > point.x + 1.0 or maxf(pts[j - 1].x, pts[j].x) < point.x - 1.0 \
				or minf(pts[j - 1].y, pts[j].y) > point.y + 1.0 or maxf(pts[j - 1].y, pts[j].y) < point.y - 1.0:
			continue
		var d := Geometry2D.get_closest_point_to_segment(point, _position(pts[j - 1]), _position(pts[j])).distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = j
	if best_d == INF:
		return
	var a := Vector2(pts[best - 1].x, pts[best - 1].y)
	var b := Vector2(pts[best].x, pts[best].y)
	var anchor := _key(point, w.world_origin)
	if _key(a, w.world_origin) == anchor or _key(b, w.world_origin) == anchor:
		return
	var f := clampf(a.distance_to(point) / maxf(a.distance_to(b), 0.000001), 0.0, 1.0)
	# Only touched arrays need a snapshot; point dictionaries themselves are not mutated.
	if changed_lines != null and not changed_lines.has(host): changed_lines[host] = pts.duplicate()
	pts.insert(best, {x = point.x, y = point.y, w = lerpf(float(pts[best - 1].w), float(pts[best].w), f)})


static func sections(w: WorldData, include_outer := false) -> Dictionary:
	var result := {}
	_collect(result, w.trails, w.world_origin)
	if include_outer and w.outer != null:
		_collect(result, w.outer.get_ledger().get("trails", []), w.world_origin)
	return result


static func _collect(result: Dictionary, records: Array, origin: Vector2i) -> void:
	for record: Dictionary in records:
		if record.get("kind", "animal") == "animal" or record.pts.size() < 2:
			continue
		var id: String = record.get("road_id", "")
		if id.is_empty():
			id = section_id(record.pts, origin)
		if not result.has(id) or record.kind == "road" and result[id].kind != "road":
			result[id] = record


static func passage_id(a: Vector2, b: Vector2, tunnel: bool, origin: Vector2i) -> String:
	var x := _key(a, origin)
	var y := _key(b, origin)
	return ("t:" if tunnel else "b:") + (x + "/" + y if x < y else y + "/" + x)


static func _passages(w: WorldData) -> Dictionary:
	var result := {}
	for tunnel: bool in [false, true]:
		for span: EntityRecord in w.tunnels if tunnel else w.bridges:
			var a := Vector2(span.a % w.W, span.a / w.W) + Vector2.ONE * 0.5
			var b := Vector2(span.b % w.W, span.b / w.W) + Vector2.ONE * 0.5
			result[passage_id(a, b, tunnel, w.world_origin)] = [a, b]
	if w.outer != null:
		for span: Dictionary in w.outer.get_ledger().get("bridges", []):
			result[passage_id(span.a, span.b, false, w.world_origin)] = [span.a, span.b]
	return result


## Split long chords at portals too, including old axes with no station at the portal.
static func _chords(a: Vector2, b: Vector2, passages: Dictionary, section_key: String, along: float) -> Array:
	var delta := b - a
	var length := delta.length()
	if length <= EPS:
		return []
	var cuts: Array[float] = [0.0, 1.0]
	var spans := {}
	for id: String in passages:
		var ends: Array = passages[id]
		var portal: Vector2 = ends[0]
		var axis: Vector2 = ends[1] - portal
		var tolerance := EPS * axis.length()
		# Measure the short chord against the long axis. The reverse amplifies rounding in diagonal stations.
		if absf(axis.cross(a - portal)) > tolerance or absf(axis.cross(b - portal)) > tolerance:
			continue
		var lo := delta.dot(portal - a) / delta.length_squared()
		var hi := delta.dot(ends[1] - a) / delta.length_squared()
		var start := maxf(0.0, minf(lo, hi))
		var end := minf(1.0, maxf(lo, hi))
		if (end - start) * length <= EPS:
			continue
		cuts.append(start)
		cuts.append(end)
		spans[id] = Vector2(start, end)
	if spans.is_empty():
		return [{a = a, b = b, section = section_key, along = along, passage = "", cuts = [a, b]}]
	cuts.sort()
	var result: Array = []
	for i in range(1, cuts.size()):
		var start := cuts[i - 1]
		var end := cuts[i]
		if (end - start) * length <= EPS:
			continue
		var middle := (start + end) * 0.5
		var passage := ""
		for id: String in spans:
			var range_on_axis: Vector2 = spans[id]
			if middle > range_on_axis.x and middle < range_on_axis.y:
				passage = id
				break
		var from := a.lerp(b, start)
		var to := a.lerp(b, end)
		result.append({a = from, b = to, section = section_key, along = along + start * length,
			passage = passage, cuts = [from, to]})
	return result


## A portal is the shared connection between the ground and the passage.
static func _level(p: Vector2, passage: String, passages: Dictionary) -> String:
	if passage.is_empty():
		return ""
	var ends: Array = passages[passage]
	return "" if p.distance_squared_to(ends[0]) <= EPS * EPS or p.distance_squared_to(ends[1]) <= EPS * EPS else passage


static func _join(a: Dictionary, b: Dictionary, p: Vector2, passages: Dictionary) -> void:
	if _level(p, a.passage, passages) == _level(p, b.passage, passages):
		a.cuts.append(p)
		b.cuts.append(p)


static func _contacts(a: Dictionary, b: Dictionary, passages: Dictionary) -> void:
	var hit: Variant = Geometry2D.segment_intersects_segment(a.a, a.b, b.a, b.b)
	if hit != null:
		_join(a, b, hit, passages)
		return
	# Coincident endpoints and a T connection into a collinear chord.
	for p: Vector2 in [a.a, a.b]:
		if p.distance_squared_to(Geometry2D.get_closest_point_to_segment(p, b.a, b.b)) <= EPS * EPS:
			_join(a, b, p, passages)
	for p: Vector2 in [b.a, b.b]:
		if p.distance_squared_to(Geometry2D.get_closest_point_to_segment(p, a.a, a.b)) <= EPS * EPS:
			_join(a, b, p, passages)


static func _index(chord: Dictionary, all: Array, bins: Dictionary, passages: Dictionary) -> void:
	var a: Vector2 = chord.a
	var b: Vector2 = chord.b
	var bounds := Rect2(a, b - a).abs().grow(EPS)
	var first := (bounds.position / BIN).floor()
	var last := (bounds.end / BIN).floor()
	var seen := {}
	for y in range(int(first.y), int(last.y) + 1):
		for x in range(int(first.x), int(last.x) + 1):
			var key := Vector2i(x, y)
			if not bins.has(key):
				bins[key] = []
			for i: int in bins[key]:
				var other: Dictionary = all[i]
				if chord.section == other.section or seen.has(i):
					continue
				seen[i] = true
				_contacts(chord, other, passages)
			bins[key].append(all.size())
	all.append(chord)


static func _node(nodes: Array, by_key: Dictionary, p: Vector2, passage: String, origin: Vector2i) -> int:
	var id := _key(p, origin) + "@" + passage
	if not by_key.has(id):
		by_key[id] = nodes.size()
		nodes.append({id = id, at = p, passage = passage})
	return by_key[id]


static func compile(w: WorldData, stop := Callable()) -> Dictionary:
	var physical := sections(w, true)
	var passages := _passages(w)
	var chords: Array = []
	var bins := {}
	for id: String in physical:
		var points: Array = physical[id].pts
		var along := 0.0
		for i in range(1, points.size()):
			if stop.is_valid() and stop.call():
				return {}
			var a := _position(points[i - 1])
			var b := _position(points[i])
			if not a.is_finite() or not b.is_finite():
				continue
			for chord: Dictionary in _chords(a, b, passages, id, along):
				_index(chord, chords, bins, passages)
			along += a.distance_to(b)
	var nodes: Array = []
	var edges: Array = []
	var by_key := {}
	for chord: Dictionary in chords:
		if stop.is_valid() and stop.call():
			return {}
		var a: Vector2 = chord.a
		var direction: Vector2 = a.direction_to(chord.b)
		var cuts: Array = chord.cuts
		if cuts.size() > 2:
			cuts.sort_custom(func(p: Vector2, q: Vector2) -> bool: return (p - a).dot(direction) < (q - a).dot(direction))
		var previous := -1
		var offset: float = chord.along
		for p: Vector2 in cuts:
			var node := _node(nodes, by_key, p, _level(p, chord.passage, passages), w.world_origin)
			if node == previous:
				continue
			var station: float = chord.along + (p - a).dot(direction)
			if previous >= 0:
				edges.append({section = chord.section, from = previous, to = node, from_m = offset * GameConfig.TILE,
					to_m = station * GameConfig.TILE})
			previous = node
			offset = station
	return {nodes = nodes, edges = edges}
