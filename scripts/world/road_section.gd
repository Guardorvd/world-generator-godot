extends RefCounted
## Station width is the usable tread, in cells. All offsets from its edge are in metres.
const Topology := preload("res://scripts/world/road_topology.gd")
const TILE := GameConfig.TILE
const AUTHORED_CLEARANCE := 1.5
const BRIDGE_HALF := 2.2
const BRIDGE_TRANSITION := 18.0
const WIDTH_RATE := 0.10 # metres of full width per metre along the ground axis


## Fit published natural roads once the full network and its structures are known.
static func fit(w: WorldData, surface: Object, accept := Callable()) -> void:
	var tuning := RoadTuning.current().section
	var routes: Array = []
	var junctions := {}
	for t: Dictionary in w.trails:
		if not RoadBed.KINDS.has(t.kind) or t.has("trail_id") or not t.has("road_id") or t.pts.size() < 2:
			continue
		routes.append(t)
		for n: int in [0, t.pts.size() - 1]:
			var p: Dictionary = t.pts[n]
			var key := Topology.anchor_key(Vector2(p.x, p.y), w.world_origin)
			junctions[key] = {owners = {}, low = INF, high = 0.0}
	for r in routes.size():
		var t: Dictionary = routes[r]
		var base: float = tuning.widths[t.kind]
		for p: Dictionary in t.pts:
			var key := Topology.anchor_key(Vector2(p.x, p.y), w.world_origin)
			if junctions.has(key):
				var joint: Dictionary = junctions[key]
				joint.owners[r] = true
				joint.low = minf(joint.low, base)
				joint.high = maxf(joint.high, base)
	var decks: Array = []
	for b: BridgeData in w.bridges:
		var a := Vector2(b.a % w.W + 0.5, b.a / w.W + 0.5) * TILE
		var z := Vector2(b.b % w.W + 0.5, b.b / w.W + 0.5) * TILE
		if a != z:
			decks.append([a, z, a.direction_to(z)])
	for t: Dictionary in routes:
		var shaped := _profile(w, t, surface, junctions, decks, tuning)
		if accept.is_valid() and not accept.call(shaped):
			# A regional bank can constrain widening. Preserve safe narrowing.
			for k in shaped.size():
				shaped[k].w = minf(shaped[k].w, t.pts[k].w)
			if not accept.call(shaped):
				continue
		t.pts = shaped


static func _profile(w: WorldData, route: Dictionary, surface: Object, junctions: Dictionary, decks: Array,
		tuning: RoadTuning.Section) -> Array:
	var pts: Array = route.pts
	var count := pts.size()
	var base: float = tuning.widths[route.kind]
	var side_cut: float = tuning.side_cut[route.kind]
	var rock_cut: float = tuning.rock_cut[route.kind]
	var ford_cut: float = tuning.ford_cut[route.kind]
	var axis := PackedVector2Array()
	var stations := PackedFloat64Array()
	var widths := PackedFloat64Array()
	var cross := PackedFloat64Array()
	var wet := PackedByteArray()
	var junction := PackedFloat64Array()
	var bridge := PackedFloat64Array()
	for p: Dictionary in pts:
		var at := Vector2(p.x, p.y) * TILE
		stations.append(stations[-1] + at.distance_to(axis[-1]) if not axis.is_empty() else 0.0)
		axis.append(at)
	for k in count:
		var at := axis[k]
		var direction := (axis[mini(k + 1, count - 1)] - axis[maxi(k - 1, 0)]).normalized()
		var side := direction.orthogonal() * 1.5
		var grade := absf(surface.ground_at(at.x + side.x, at.y + side.y) - surface.ground_at(at.x - side.x, at.y - side.y)) / 3.0
		cross.append(grade)
		var cell := clampi(floori(at.y / TILE), 0, w.H - 1) * w.W + clampi(floori(at.x / TILE), 0, w.W - 1)
		var rocky := w.biome[cell] in [Biomes.ROCK, Biomes.PEAK, Biomes.STONESHORE]
		var ford: bool = surface.depth_at(at.x, at.y) > 0.08
		wet.append(int(ford))
		var pinch := maxf(side_cut * smoothstep(0.14, 0.52, grade), rock_cut if rocky else 0.0)
		widths.append(base * (1.0 - maxf(pinch, ford_cut if ford else 0.0)))
		var p: Dictionary = pts[k]
		var joint: Dictionary = junctions.get(Topology.anchor_key(Vector2(p.x, p.y), w.world_origin), {})
		var target := -1.0
		if not joint.is_empty() and joint.owners.size() > 1:
			# A through road keeps its normal section. Joining ends meet at an intermediate width.
			target = (joint.low + joint.high) * 0.5 if k == 0 or k == count - 1 else base
		junction.append(target)
		bridge.append(2.0 * BRIDGE_HALF / TILE if _deck(at, axis[maxi(k - 1, 0)], axis[mini(k + 1, count - 1)], decks) else -1.0)

	widths = _blend_junctions(widths, stations, junction, base, wet, cross, axis, surface, tuning.junction_transition)
	widths = _limit_rate(widths, stations)
	var on_deck := _nearest_anchor(stations, bridge)
	var result: Array = []
	for k in count:
		var p: Dictionary = pts[k].duplicate()
		var n := on_deck[k]
		p.w = widths[k]
		if n >= 0:
			var fade := 1.0 - smoothstep(0.0, BRIDGE_TRANSITION, absf(stations[n] - stations[k]))
			p.w = lerpf(widths[k], bridge[n], fade)
		result.append(p)
	return result


static func _deck(at: Vector2, before: Vector2, after: Vector2, decks: Array) -> bool:
	for deck: Array in decks:
		var a: Vector2 = deck[0]
		var b: Vector2 = deck[1]
		var tangent: Vector2 = deck[2]
		if at.distance_squared_to(Geometry2D.get_closest_point_to_segment(at, a, b)) >= 0.0025:
			continue
		for p: Vector2 in [before, after]:
			if absf(at.direction_to(p).dot(tangent)) > 0.85 and p.distance_squared_to(Geometry2D.get_closest_point_to_segment(p, a, b)) < 0.0025:
				return true
	return false


static func _nearest_anchor(stations: PackedFloat64Array, targets: PackedFloat64Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(stations.size())
	var nearest := -1
	for k in stations.size():
		if targets[k] >= 0.0: nearest = k
		out[k] = nearest
	nearest = -1
	for k in range(stations.size() - 1, -1, -1):
		if targets[k] >= 0.0: nearest = k
		if nearest >= 0 and (out[k] < 0 or stations[nearest] - stations[k] < stations[k] - stations[out[k]]):
			out[k] = nearest
	return out


static func _blend_junctions(widths: PackedFloat64Array, stations: PackedFloat64Array, junction: PackedFloat64Array,
		base: float, wet: PackedByteArray, cross: PackedFloat64Array, axis: PackedVector2Array, surface: Object, transition: float) -> PackedFloat64Array:
	var closest := _nearest_anchor(stations, junction)
	for k in widths.size():
		var n := closest[k]
		if n < 0 or wet[k] != 0: continue
		var fade := 1.0 - smoothstep(0.0, transition, absf(stations[n] - stations[k]))
		if fade <= 0.0: continue
		var target := lerpf(widths[k], junction[n], fade)
		if target > base:
			var direction := (axis[mini(k + 1, axis.size() - 1)] - axis[maxi(k - 1, 0)]).normalized()
			var side := direction.orthogonal() * target * TILE * 0.5
			var at := axis[k]
			if cross[k] > 0.35 or surface.depth_at(at.x + side.x, at.y + side.y) > 0.08 or surface.depth_at(at.x - side.x, at.y - side.y) > 0.08:
				target = base
		widths[k] = target
	return widths


static func _limit_rate(widths: PackedFloat64Array, stations: PackedFloat64Array) -> PackedFloat64Array:
	for k in range(1, widths.size()):
		widths[k] = minf(widths[k], widths[k - 1] + (stations[k] - stations[k - 1]) * WIDTH_RATE / TILE)
	for k in range(widths.size() - 2, -1, -1):
		widths[k] = minf(widths[k], widths[k + 1] + (stations[k + 1] - stations[k]) * WIDTH_RATE / TILE)
	return widths
