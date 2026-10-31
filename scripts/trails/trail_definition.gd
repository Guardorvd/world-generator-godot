class_name TrailDefinition
extends Resource
## Authored route in WORLD METRES (Vector2.y is world Z), independent of the lab.
@export var id := "trail"
@export var title := "Trail"
@export_enum("trail", "mountain", "road") var kind := "mountain"
@export var points := PackedVector2Array():
	set(value):
		points = value
		_along = PackedFloat32Array() # the station index is rebuilt on the next query
@export var width := 4.0
## NONE asks RoadSurface to choose from the real biome/slope/seed.
@export_range(0, 7) var surface := RoadSurface.NONE
## Opt-in local shaping; production generation is unchanged until it supplies these definitions.
@export_range(0.0, 1.0) var earthwork := 0.0
@export_range(-2.0, 2.0) var elevation_offset := 0.0
@export_range(0.0, 1.0) var auto_bank := 0.0
@export var closed := false
## Optional override of the per-kind terrain shaping preset.
@export var shaping: TrailShaping
@export var elements: Array[TrailElement] = []
## Composition sections from TrailComposer: {from, to, mood, difficulty}. Informational, never baked.
@export var sections: Array[Dictionary] = []

## Station of every point and a coarse grid of segments (GRID m cells -> indices of the segments ending at
## those points): point_at is a binary search and nearby queries look at a few segments instead of all.
const GRID := 8.0
var _along := PackedFloat32Array()
var _grid := {}

func _index() -> void:
	if _along.size() == points.size() and not _along.is_empty(): return
	_along.resize(points.size())
	_grid.clear()
	var sum := 0.0
	for i in points.size():
		if i > 0:
			sum += points[i - 1].distance_to(points[i])
			var lo := (points[i - 1].min(points[i]) / GRID).floor()
			var hi := (points[i - 1].max(points[i]) / GRID).floor()
			for gz in range(int(lo.y), int(hi.y) + 1):
				for gx in range(int(lo.x), int(hi.x) + 1):
					var key := Vector2i(gx, gz)
					if not _grid.has(key): _grid[key] = []
					(_grid[key] as Array).append(i)
		_along[i] = sum

## Segments (by end point index) that may come within `reach` of `at`; may repeat.
func _segments_near(at: Vector2, reach: float) -> Array:
	_index()
	var result := []
	var lo := ((at - Vector2.ONE * reach) / GRID).floor()
	var hi := ((at + Vector2.ONE * reach) / GRID).floor()
	for gz in range(int(lo.y), int(hi.y) + 1):
		for gx in range(int(lo.x), int(hi.x) + 1):
			var list: Variant = _grid.get(Vector2i(gx, gz))
			if list != null: result.append_array(list as Array)
	return result

func shape() -> TrailShaping:
	return shaping if shaping != null else TrailShaping.preset(kind)

func route_length() -> float:
	if points.size() < 2: return 0.0
	_index()
	return _along[-1]

func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if id.is_empty(): errors.append("Trail id is empty")
	if kind not in ["trail", "mountain", "road"]: errors.append("Unknown route kind")
	if points.size() < 2: errors.append("A trail needs two points")
	if not is_finite(width) or width < 2.0: errors.append("Width must be at least two metres")
	if surface < 0 or surface >= RoadSurface.LIST.size(): errors.append("Unknown surface")
	if not is_finite(earthwork) or earthwork < 0.0 or earthwork > 1.0: errors.append("Invalid earthwork strength")
	if not is_finite(elevation_offset) or absf(elevation_offset) > 2.0: errors.append("Invalid elevation offset")
	if not is_finite(auto_bank) or auto_bank < 0.0 or auto_bank > 1.0: errors.append("Invalid automatic banking")
	if shaping != null: errors.append_array(shaping.validate())
	if closed and (points.size() < 4 or points[0].distance_to(points[-1]) > 0.01): errors.append("Closed route must repeat its first point")
	for i in points.size():
		if not points[i].is_finite(): errors.append("Non-finite route point")
		if i > 0 and points[i].distance_to(points[i - 1]) < 0.01: errors.append("Repeated route point")
	for e in elements:
		if e == null:
			errors.append("Null element")
			continue
		if e.profile < 0 or e.profile >= TrailElement.Profile.size(): errors.append("Unknown element profile")
		if absf(e.bank) > 1.0: errors.append("Bank must be between -1 and 1")
		if e.count < 1 or e.count > 12 or e.skew < 0.15 or e.skew > 0.85: errors.append("Element count or skew out of range")
		elif e.profile == TrailElement.Profile.WAVES and e.length / e.count < RoadRefinement.STEP * 8.0: errors.append("Waves are too short for the heightfield resolution")
		elif e.profile == TrailElement.Profile.PUMP and e.length / e.count < RoadRefinement.STEP * 4.0: errors.append("Pump rollers are too short for the heightfield resolution")
		if e.lines < 1 or e.lines > 3 or e.density < 0.05 or e.density > 1.0 or e.gap < 1.0 or e.period < 1.5:
			errors.append("Technical element parameters out of range")
		elif e.profile == TrailElement.Profile.NARROW and e.gap > width - 0.5:
			errors.append("Narrow passage must be narrower than the route")
		elif e.profile == TrailElement.Profile.LOG and e.gap > width * 0.5 - 0.3:
			errors.append("Log bypass must fit beside the log")
		elif e.profile == TrailElement.Profile.NORTHSHORE and e.gap > width - 0.5:
			errors.append("Northshore deck must be narrower than the route")
		elif e.profile == TrailElement.Profile.GAP and e.length < e.gap_min_length():
			errors.append("Gap does not fit its kicker, gap and landing")
		if not is_finite(e.station) or not is_finite(e.length) or not is_finite(e.height) or not is_finite(e.bank):
			errors.append("Non-finite element")
		# настил норшора — сооружение, не земляные работы: мост над дорогой выше 2 м (31.10)
		elif e.length < RoadRefinement.STEP * 4.0 or e.height < 0.0 or e.height > (3.5 if e.profile == TrailElement.Profile.NORTHSHORE else 2.0):
			errors.append("Element exceeds heightfield resolution/earthwork limits")
		elif e.station - e.length * 0.5 < 0.0 or e.station + e.length * 0.5 > route_length():
			errors.append("Element extends beyond route")
	# Object-placing features never overlap: that is what keeps a line readable instead of cluttered.
	for i in elements.size():
		for j in range(i + 1, elements.size()):
			var a := elements[i]
			var b := elements[j]
			if a == null or b == null: continue
			if TrailElement.places_objects(a.profile) and TrailElement.places_objects(b.profile) and absf(a.station - b.station) < (a.length + b.length) * 0.5 + 4.0:
				errors.append("Technical features overlap or are closer than four metres")
	return errors

## The only conversion between authoring metres and the existing civil path contract.
func path_record() -> Dictionary:
	var pts: Array = []
	for p in points:
		pts.append({x = p.x / GameConfig.TILE, y = p.y / GameConfig.TILE, w = width / GameConfig.TILE})
	return {kind = kind, pts = pts, trail_id = id, surface_override = surface, formation = Vector3(earthwork, elevation_offset, auto_bank), closed = closed}

func heading_at(station: float) -> float:
	var at := station if closed else clampf(station, 0.0, maxf(0.0, route_length() - 0.01))
	var direction := point_at(at + 0.01) - point_at(at)
	return atan2(-direction.x, -direction.y)

func point_at(station: float) -> Vector2:
	_index()
	var remaining := fposmod(station, route_length()) if closed else maxf(0.0, station)
	if points.size() < 2 or remaining >= _along[-1]: return points[-1]
	var i := maxi(1, _along.bsearch(remaining))
	var span := _along[i] - _along[i - 1]
	return points[i - 1].lerp(points[i], (remaining - _along[i - 1]) / span) if span > 0.0 else points[i]

## Station, signed across and distance of the closest route point. With a finite `reach` only segments
## near `at` are looked at, and a point farther than `reach` gives distance INF.
## Segments that matter to any point closer than `spread` to `at`, without repeats: one query for a group of nearby
## points (nearest / junction_weight with `among`), the same result as their own queries. Kept: every segment within
## `keep` of a point (junction_weight needs them all) and those that can still be the nearest one (not farther from `at`
## than the closest segment plus 2 * spread); none when no segment comes within `reach` of a point.
func segments_around(at: Vector2, reach: float, spread: float, keep: float) -> PackedInt32Array:
	_index()
	var seen := {}
	var dist := {}
	var closest := INF
	for i: int in _segments_near(at, reach + spread):
		if seen.has(i): continue
		seen[i] = true
		dist[i] = _project(at, i).z
		closest = minf(closest, dist[i])
	var out := PackedInt32Array()
	if closest > reach + spread: return out
	for i: int in dist:
		if dist[i] <= maxf(closest + 2.0 * spread, keep + spread): out.append(i)
	out.sort()
	return out

func nearest(at: Vector2, reach := INF, among := PackedInt32Array()) -> Vector3:
	_index()
	var best := INF
	var result := Vector3(0.0, 0.0, INF) # station, signed across, distance
	if is_finite(reach):
		for i: int in (among if not among.is_empty() else PackedInt32Array(_segments_near(at, reach))):
			var found := _project(at, i)
			if found.z < best:
				best = found.z
				result = found
		return result if best <= reach else Vector3(0.0, 0.0, INF)
	# A rider is almost always close to the route: look nearby first, scan everything only when that fails.
	result = nearest(at, 16.0)
	if is_finite(result.z): return result
	for i in range(1, points.size()):
		var found := _project(at, i)
		if found.z < best:
			best = found.z
			result = found
	return result

func _project(at: Vector2, i: int) -> Vector3:
	var delta := points[i] - points[i - 1]
	var span := delta.length()
	var t := clampf((at - points[i - 1]).dot(delta) / delta.length_squared(), 0.0, 1.0)
	var offset := at - (points[i - 1] + delta * t)
	return Vector3(_along[i - 1] + span * t, offset.cross(delta / span), offset.length())

## Smooth frame over metres, independent of input point spacing; wraps at a circuit seam.
func tangent_at(station: float) -> Vector2:
	return (point_at(station + 2.0) - point_at(station - 2.0)).normalized()

func curvature_at(station: float) -> float:
	var a := tangent_at(station - 3.0)
	var b := tangent_at(station + 3.0)
	# Past the end of an open route the tangent is zero: angle_to(0) gives 0 or π by the sign of zero, not a turn.
	if a == Vector2.ZERO or b == Vector2.ZERO: return 0.0
	return a.angle_to(b) / 6.0

## A heightfield cannot carry two different decks at a crossing: keep shared junctions grounded.
func junction_weight(at: Vector2, station: float, among := PackedInt32Array()) -> float:
	var weight := 1.0
	var total := route_length()
	# Farther segments give smoothstep 1 and cannot lower the weight.
	for i: int in (among if not among.is_empty() else PackedInt32Array(_segments_near(at, width * 0.5 + RoadRefinement.REACH))):
		var found := _project(at, i)
		var separation := absf(found.x - station)
		if closed: separation = minf(separation, total - separation)
		if separation > maxf(20.0, width * 3.0):
			weight = minf(weight, smoothstep(width * 0.5, width * 0.5 + RoadRefinement.REACH, found.z))
	return weight
