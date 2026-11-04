extends TrailShaping
## Lab-only local profile repair, persisted with the route. No clipping at protected vertices.
@export var repair_intervals := PackedVector2Array()
@export var repair_shape: TrailShaping
@export var repair_weight := 0.85
const TRANSITION := 12.0

func profile(h: Heightfield, d: TrailDefinition, pin_at := Callable()) -> Dictionary:
	var result := super.profile(h, d, pin_at)
	if repair_shape != null and not repair_intervals.is_empty():
		result.original_profile = result.duplicate(true)
		result.repair_profile = repair_shape.profile(h, d, pin_at)
		result.reach = maxf(result.reach, result.repair_profile.reach)
		var wider := PackedFloat32Array()
		for j in result.reaches.size(): wider.append(maxf(result.reaches[j], result.repair_profile.reaches[j]))
		result.reaches = wider
	return result

func offset(h: Heightfield, d: TrailDefinition, local: Vector3, at: Vector2, p: Dictionary) -> float:
	var original := super.offset(h, d, local, at, p.get("original_profile", p))
	if not p.has("repair_profile"): return original
	var weight := 0.0
	for interval in repair_intervals:
		weight = maxf(weight, smoothstep(interval.x - TRANSITION, interval.x, local.x) * (1.0 - smoothstep(interval.y, interval.y + TRANSITION, local.x)))
	return lerpf(original, repair_shape.offset(h, d, local, at, p.repair_profile), weight * repair_weight)

func validate() -> PackedStringArray:
	var errors := super.validate()
	if not is_finite(repair_weight) or repair_weight < 0 or repair_weight > 1: errors.append("неверная сила локального исправления")
	for interval in repair_intervals:
		if not interval.is_finite() or interval.x < 0 or interval.y < interval.x: errors.append("неверный интервал исправления")
	if repair_shape != null: errors.append_array(repair_shape.validate())
	return errors
