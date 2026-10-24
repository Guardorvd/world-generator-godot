extends SceneTree
const Spline = preload("res://scripts/world/river_spline.gd")
var fails := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func flow(grade: float, pulse: float, lake_source := false) -> Dictionary:
	var w := WorldData.new()
	w.W = 9
	w.H = 9
	w.N = 81
	w.h.resize(w.N)
	w.ocean.resize(w.N)
	for y in w.H:
		for x in w.W:
			w.h[y * w.W + x] = 0.4 - y * grade
	var flood := StageHydrology._priority_flood(w)
	if grade > 0.0:
		# Match run(): steepest descent after flood supplies the primary thalweg.
		for y in range(1, w.H - 1):
			for x in range(1, w.W - 1):
				flood.down[y * w.W + x] = (y + 1) * w.W + x
	var rain := PackedFloat32Array()
	rain.resize(w.N)
	rain.fill(0.2)
	var lake := PackedByteArray()
	lake.resize(w.N)
	var source := 4 * w.W + 4
	if lake_source:
		lake[source] = 1
	var baseline := StageHydrology._accumulate(w, flood.filled, flood.down, flood.order, flood.order_n, rain, lake)
	rain[source] += pulse
	var acc := StageHydrology._accumulate(w, flood.filled, flood.down, flood.order, flood.order_n, rain, lake)
	var mass := 0.0
	for i in w.N:
		if flood.down[i] < 0:
			mass += acc[i] - baseline[i]
	check(absf(mass - pulse) < maxf(0.0001, pulse * 1e-5), "Distributed flow conserves water, including flat fallback")
	return {w = w, source = source, down = flood.down, acc = acc, base = baseline}

func distribution() -> void:
	var gentle := flow(0.0001, 0.8)
	var source: int = gentle.source
	var receivers := 0
	for dx in [-1, 0, 1]:
		var n: int = source + gentle.w.W + dx
		if gentle.acc[n] - gentle.base[n] > 0.01:
			receivers += 1
	check(receivers == 3, "Gentle slope spreads nascent runoff to all lower neighbours")
	for test: Dictionary in [flow(0.01, 0.8), flow(0.0001, 80.0), flow(0.0001, 0.8, true)]:
		var d: int = test.down[test.source]
		for dx in [-1, 0, 1]:
			var n: int = test.source + test.w.W + dx
			if n != d:
				check(test.acc[n] <= test.base[n] + 1e-6, "Steep slopes, main channels and lakes keep a single outlet")
	flow(0.0, 0.8)

func splines() -> void:
	var controls: Array = [{x = 0.0, y = 0.0, w = 0.4, e = 0.2},
		{x = 1.0, y = 0.0, w = 0.6, e = 0.1999}, {x = 1.0, y = 1.0, w = 0.5, e = 0.1},
		{x = 2.0, y = 1.2, w = 0.9, e = 0.1}, {x = 2.1, y = 4.5, w = 0.8, e = 0.09}]
	var sampled := Spline.sample(controls)
	check(sampled[0] == controls[0] and sampled[-1] == controls[-1], "Preserve exact confluence and outlet endpoints")
	for p: Dictionary in controls:
		check(sampled.has(p), "Catmull-Rom interpolates every control point")
	var curved := false
	for k in range(1, sampled.size()):
		var a: Dictionary = sampled[k - 1]
		var b: Dictionary = sampled[k]
		check(b.e <= a.e + 1e-12, "Water never climbs, including steep/flat transitions")
		check(b.w > 0.0, "Interpolated widths stay positive")
		check(Vector2(b.x - a.x, b.y - a.y).length() <= Spline.MAX_STEP + 1e-5, "Adaptive spacing respects maximum step")
		if b.x < 1.0 and b.y < -0.001:
			curved = true
	check(curved, "Vector river follows a curved spline instead of the grid polyline")
	var straight: Array = [{x = 0.0, y = 0.0, w = 0.5, e = 0.2}, {x = 1.0, y = 0.0, w = 0.5, e = 0.2},
		{x = 2.0, y = 0.0, w = 0.5, e = 0.2}, {x = 3.0, y = 0.0, w = 0.5, e = 0.2}]
	var bends := straight.duplicate(true)
	bends[2].y = 1.0
	bends[3].y = 1.0
	check(Spline.sample(bends).size() > Spline.sample(straight).size(), "Adaptive sampling adds detail at bends")
	var flat := controls.duplicate(true)
	for p: Dictionary in flat:
		p.e = 0.2
	check(sampled.size() > Spline.sample(flat).size(), "Adaptive sampling resolves changes in water slope")
	var repeated := controls.duplicate(true)
	repeated.insert(2, controls[1].duplicate())
	check(Spline.sample(repeated) == sampled, "Coincident control points produce no singularities")
	var short := Spline.sample([controls[0], controls[1]])
	check(short.size() >= 2 and short[0] == controls[0] and short[-1] == controls[1], "Preserve short tributaries")
	print("Adaptive river: %d controls, %d samples" % [controls.size(), sampled.size()])

func _init() -> void:
	distribution()
	splines()
	print("MFD/spline regression failures: %d" % fails)
	quit(1 if fails > 0 else 0)
