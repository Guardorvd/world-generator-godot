extends "res://scripts/trails/trail_generation_input.gd"
## Lab-owned spatial index. Same exact road exclusion, bounded work per terrain query.
var _indexed := false
var _segments := {}
const INDEX_CELL := 32.0

static func indexed_copy(source):
	var out = load("res://scripts/lab/trail_lab_game_input.gd").new()
	for key in ["size", "cell_size", "origin", "heights", "water", "rivers", "forbidden", "existing_paths", "river_policy", "earthwork_limits", "provenance"]:
		out.set(key, source.get(key))
	return out

func blocked(at: Vector2) -> bool:
	var p := Vector2i(((at - origin) / cell_size).floor())
	if p.x < 0 or p.y < 0 or p.x >= size.x or p.y >= size.y: return true
	var i := p.y * size.x + p.x
	if water[i] != 0 or forbidden[i] != 0 or (river_policy == RiverPolicy.STRICT and rivers[i] != 0): return true
	if not _indexed:
		_segments.clear()
		for path in existing_paths:
			var points: PackedVector2Array = path.points
			var reach := float(path.get("half_width", 2.0)) + 2.0
			for k in range(1, points.size()):
				var bounds := Rect2(points[k - 1], points[k] - points[k - 1]).abs().grow(reach)
				var lo := Vector2i((bounds.position / INDEX_CELL).floor())
				var hi := Vector2i((bounds.end / INDEX_CELL).floor())
				for z in range(lo.y, hi.y + 1):
					for x in range(lo.x, hi.x + 1):
						var key := Vector2i(x, z)
						if not _segments.has(key): _segments[key] = []
						_segments[key].append([points[k - 1], points[k], reach])
		_indexed = true
	for segment: Array in _segments.get(Vector2i((at / INDEX_CELL).floor()), []):
		var a: Vector2 = segment[0]
		var b: Vector2 = segment[1]
		if Grid.segment_dist(at.x, at.y, a.x, a.y, b.x, b.y) <= float(segment[2]): return true
	return false
