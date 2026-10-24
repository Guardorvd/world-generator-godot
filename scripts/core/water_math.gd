extends RefCounted
## Canonical scalar water math. Regenerate WaterMath.cs with tools/generate_water_math.py.
## Keep this small numerical subset scalar-only: intermediate arithmetic must stay float64.
const LAKE_DROP := 0.1
const TRIANGLE_AREA_EPS := 1e-8
const SHORE_EPS := 1e-5
const LEVEL_EPS := 0.001
const GRID_EDGE_INSET := 1.001


static func triangle_height(x: float, z: float, ax: float, ay: float, az: float, bx: float, by: float, bz: float, cx: float, cy: float, cz: float) -> float:
	var denominator := (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
	if absf(denominator) < TRIANGLE_AREA_EPS:
		return -INF
	var u := ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / denominator
	var v := ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / denominator
	if u < -SHORE_EPS or v < -SHORE_EPS or u + v > 1.0 + SHORE_EPS:
		return -INF
	return u * ay + v * by + (1.0 - u - v) * cy


static func ground_height(a: float, b: float, c: float, d: float, tx: float, tz: float) -> float:
	if tx + tz <= 1.0:
		return a + (b - a) * tx + (c - a) * tz
	return d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz)


static func lake_height(filled: float, height_scale: float) -> float:
	return filled * height_scale - LAKE_DROP


static func depth(ground: float, river: float, lake: float) -> float:
	return maxf(0.0, maxf(0.0, maxf(river, lake)) - ground)
