class_name TrailDefinition
extends Resource
## Authored route in WORLD METRES (Vector2.y is world Z), independent of the lab.
@export var id := "trail"
@export var title := "Trail"
@export_enum("trail", "mountain", "road") var kind := "mountain"
@export var points := PackedVector2Array()
@export var width := 4.0
## NONE asks RoadSurface to choose from the real biome/slope/seed.
@export_range(0, 7) var surface := RoadSurface.NONE
## Opt-in local shaping; production generation is unchanged until it supplies these definitions.
@export_range(0.0, 1.0) var earthwork := 0.0
@export_range(-2.0, 2.0) var elevation_offset := 0.0
@export_range(0.0, 1.0) var auto_bank := 0.0
@export var closed := false
@export var elements: Array[TrailElement] = []

func route_length() -> float:
	var result := 0.0
	for i in range(1, points.size()):
		result += points[i - 1].distance_to(points[i])
	return result

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
		if not is_finite(e.station) or not is_finite(e.length) or not is_finite(e.height) or not is_finite(e.bank):
			errors.append("Non-finite element")
		elif e.length < RoadRefinement.STEP * 4.0 or e.height < 0.0 or e.height > 2.0:
			errors.append("Element exceeds heightfield resolution/earthwork limits")
		elif e.station - e.length * 0.5 < 0.0 or e.station + e.length * 0.5 > route_length():
			errors.append("Element extends beyond route")
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
	var remaining := fposmod(station, route_length()) if closed else maxf(0.0, station)
	for i in range(1, points.size()):
		var span := points[i - 1].distance_to(points[i])
		if remaining <= span: return points[i - 1].lerp(points[i], remaining / span)
		remaining -= span
	return points[-1]

func nearest(at: Vector2) -> Vector3:
	var best := INF
	var result := Vector3.ZERO # station, signed across, distance
	var along := 0.0
	for i in range(1, points.size()):
		var delta := points[i] - points[i - 1]
		var span := delta.length()
		var t := clampf((at - points[i - 1]).dot(delta) / delta.length_squared(), 0.0, 1.0)
		var offset := at - (points[i - 1] + delta * t)
		if offset.length_squared() < best:
			best = offset.length_squared()
			result = Vector3(along + span * t, offset.cross(delta / span), offset.length())
		along += span
	return result

## Smooth frame over metres, independent of input point spacing; wraps at a circuit seam.
func tangent_at(station: float) -> Vector2:
	return (point_at(station + 2.0) - point_at(station - 2.0)).normalized()

func curvature_at(station: float) -> float:
	return tangent_at(station - 3.0).angle_to(tangent_at(station + 3.0)) / 6.0

## A heightfield cannot carry two different decks at a crossing: keep shared junctions grounded.
func junction_weight(at: Vector2, station: float) -> float:
	var along := 0.0
	var weight := 1.0
	var total := route_length()
	for i in range(1, points.size()):
		var delta := points[i] - points[i - 1]
		var span := delta.length()
		var t := clampf((at - points[i - 1]).dot(delta) / delta.length_squared(), 0.0, 1.0)
		var separation := absf(along + span * t - station)
		if closed: separation = minf(separation, total - separation)
		if separation > maxf(20.0, width * 3.0):
			var distance := at.distance_to(points[i - 1] + delta * t)
			weight = minf(weight, smoothstep(width * 0.5, width * 0.5 + RoadRefinement.REACH, distance))
		along += span
	return weight
