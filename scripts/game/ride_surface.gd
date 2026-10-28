class_name RideSurface
extends RefCounted
## Shared contact query for riding and diagnostics. Coordinates are world metres.
static func sample(w: WorldData, heights: Heightfield, x: float, z: float) -> Dictionary:
	var result := {surface = RoadSurface.NONE, weight = 0.0, across = 0.0}
	if heights.road_refinement != null:
		var contact := heights.path_contact(x, z)
		if not contact.is_empty():
			result.surface = contact.surface
			result.weight = smoothstep(0.05, 0.9, contact.weight)
			result.across = contact.across
	else:
		result.surface = PlayerState.surface(w.tile_info(x / GameConfig.TILE, z / GameConfig.TILE))
		result.weight = 1.0 if result.surface != RoadSurface.NONE else 0.0
	return result
