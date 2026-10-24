extends RefCounted
## Centripetal Catmull-Rom in plan, monotone cubic water height in knot time.
## Adaptive sampling bounds chord length, plan error and vertical error.
const MAX_STEP := 0.75 # cells
const PLAN_ERROR := 0.015 # cells
const HEIGHT_ERROR := 0.03 / GameConfig.HS # 3 cm
const MAX_DEPTH := 10

static func sample(source: Array) -> Array:
	var pts: Array = []
	for p: Dictionary in source:
		if not pts.is_empty() and Vector2(p.x - pts[-1].x, p.y - pts[-1].y).length_squared() < 1e-10:
			continue
		pts.append(p.duplicate())
	if pts.size() < 2:
		return pts
	var n := pts.size()
	var times := PackedFloat64Array([0.0])
	var secants := PackedFloat64Array()
	for k in range(1, n):
		var a: Dictionary = pts[k - 1]
		var b: Dictionary = pts[k]
		var dt := sqrt(Vector2(b.x - a.x, b.y - a.y).length()) # alpha = 1/2
		times.append(times[-1] + dt)
		secants.append((b.e - a.e) / dt)
	var slopes := PackedFloat64Array()
	slopes.resize(n)
	slopes[0] = secants[0]
	slopes[n - 1] = secants[-1]
	for k in range(1, n - 1):
		var a := secants[k - 1]
		var b := secants[k]
		if a * b <= 0.0:
			slopes[k] = 0.0
		else:
			var before := times[k] - times[k - 1]
			var after := times[k + 1] - times[k]
			var wa := 2.0 * after + before
			var wb := after + 2.0 * before
			slopes[k] = (wa + wb) / (wa / a + wb / b)
	var out: Array = [pts[0].duplicate()]
	for k in range(n - 1):
		var a := Vector2(pts[k].x, pts[k].y)
		var b := Vector2(pts[k + 1].x, pts[k + 1].y)
		var prev := Vector2(pts[k - 1].x, pts[k - 1].y) if k > 0 else a * 2.0 - b
		var next := Vector2(pts[k + 2].x, pts[k + 2].y) if k + 2 < n else b * 2.0 - a
		var dt := times[k + 1] - times[k]
		var before := times[k] - times[k - 1] if k > 0 else dt
		var after := times[k + 2] - times[k + 1] if k + 2 < n else dt
		# Nonuniform Catmull-Rom tangents, expressed on the segment's unit interval.
		var ta := dt * ((a - prev) / before - (b - prev) / (before + dt) + (b - a) / dt)
		var tb := dt * ((b - a) / dt - (next - a) / (dt + after) + (next - b) / after)
		var segment := {a = pts[k], b = pts[k + 1], pa = a, pb = b, ta = ta, tb = tb,
			ma = slopes[k] * dt, mb = slopes[k + 1] * dt}
		_subdivide(segment, 0.0, 1.0, pts[k], pts[k + 1], out, 0)
	return out

static func _point(s: Dictionary, t: float) -> Dictionary:
	var t2 := t * t
	var t3 := t2 * t
	var ha := 2.0 * t3 - 3.0 * t2 + 1.0
	var hb := -2.0 * t3 + 3.0 * t2
	var ht := t3 - 2.0 * t2 + t
	var hu := t3 - t2
	var pos: Vector2 = s.pa * ha + s.pb * hb + s.ta * ht + s.tb * hu
	return {x = float(pos.x), y = float(pos.y), w = lerpf(s.a.w, s.b.w, t),
		e = clampf(ha * s.a.e + hb * s.b.e + ht * s.ma + hu * s.mb, minf(s.a.e, s.b.e), maxf(s.a.e, s.b.e))}

static func _subdivide(s: Dictionary, lo: float, hi: float, a: Dictionary, b: Dictionary, out: Array, depth: int) -> void:
	var split := Vector2(b.x - a.x, b.y - a.y).length() > MAX_STEP
	for fraction in [0.25, 0.5, 0.75]:
		var p := _point(s, lerpf(lo, hi, fraction))
		var chord := Vector2(lerpf(a.x, b.x, fraction), lerpf(a.y, b.y, fraction))
		if Vector2(p.x, p.y).distance_to(chord) > PLAN_ERROR or absf(p.e - lerpf(a.e, b.e, fraction)) > HEIGHT_ERROR:
			split = true
	if split and depth < MAX_DEPTH:
		var mid := (lo + hi) * 0.5
		var p := _point(s, mid)
		_subdivide(s, lo, mid, a, p, out, depth + 1)
		_subdivide(s, mid, hi, p, b, out, depth + 1)
	else:
		out.append(b.duplicate())
