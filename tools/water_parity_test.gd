extends SceneTree
## Requires a freshly built .NET assembly: dotnet build, then Godot --headless --script this file.
## Compares independent GDScript/native data traversal on the same base terrain, without roads/decks/OuterLand.
const MathSource := preload("res://scripts/core/water_math.gd")
const RANDOM_SAMPLES := 1000
const ABS_TOL := 1e-9
const REL_TOL := 1e-10
var fails := 0
var samples := 0
var exact := 0
var max_error := 0.0
var wet := 0
var dry := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func close(a: float, b: float) -> bool:
	if is_nan(a) or is_nan(b): return false
	if is_inf(a) or is_inf(b): return a == b
	return absf(a - b) <= ABS_TOL + REL_TOL * maxf(absf(a), absf(b))

func sample(h: Heightfield, fast: Object, x: float, z: float) -> void:
	var gd := h.depth_at(x, z)
	var native: float = fast.Depth(x, z)
	samples += 1
	wet += int(gd > 0.0)
	dry += int(gd == 0.0)
	exact += int(var_to_bytes(gd) == var_to_bytes(native))
	if is_finite(gd) and is_finite(native): max_error = maxf(max_error, absf(gd - native))
	if not close(gd, native):
		fails += 1
		if fails <= 8: printerr("Depth mismatch at (%.17f, %.17f): GD=%.17f C#=%.17f" % [x, z, gd, native])

func triangles(fast: Object) -> void:
	var a := Vector3(0, 1, 0)
	var b := Vector3(10, 2, 0)
	var c := Vector3(0, 3, 10)
	var same := true
	for points: Array in [[a, b, c], [c, b, a], [a, a, c],
		[Vector3.ZERO, Vector3(0.00001, 1, 0), Vector3(0, 2, 0.00001)]]:
		for q: Vector2 in [Vector2.ZERO, Vector2(10, 0), Vector2(0, 10), Vector2(5, 5), Vector2(2, 3),
			Vector2(-0.00005, 0), Vector2(-0.0002, 0), Vector2(5, 5.001)]:
			var gd := Heightfield._water_triangle(q.x, q.y, points[0], points[1], points[2])
			var native: float = fast.WaterTriangle(q.x, q.y, points[0], points[1], points[2])
			same = same and close(gd, native)
	check(same, "Barycentric parity: winding, edges, shore tolerance, degenerate triangles")
	check(is_equal_approx(Heightfield._water_triangle(2, 3, a, b, c), 1.8), "Barycentric known height")
	check(is_finite(Heightfield._water_triangle(-0.00005, 0, a, b, c))
		and Heightfield._water_triangle(-0.0002, 0, a, b, c) == -INF, "Shore tolerance has an explicit acceptance boundary")

func lake_fixture(rng: RandomNumberGenerator) -> void:
	var w := WorldData.new()
	w.W = 8
	w.H = 8
	w.N = 64
	w.lake.resize(w.N)
	w.filled.resize(w.N)
	for cell in [27, 28, 35, 36]:
		w.lake[cell] = 1
		w.filled[cell] = float(cell - 25) / 100.0
	var h := Heightfield.new()
	h.world = w
	h.hv.resize(w.N)
	h.hv.fill(1.0)
	h.hv_raw = h.hv.duplicate()
	var fast := h.fast_water()
	var expected: float = float(w.filled[36]) * GameConfig.HS - 0.1 - 1.0
	check(close(h.depth_at(14.0, 14.0), expected) and close(fast.Depth(14.0, 14.0), expected),
		"Lake corners select the highest level with the shared 0.1 m offset")
	for i in 100:
		sample(h, fast, rng.randf_range(10.0, 22.0), rng.randf_range(10.0, 22.0))
	for x: float in [9.9999999, 10.0, 10.0000001, 14.0, 17.9999999, 18.0, 18.0000001, 22.0]:
		for z: float in [9.9999999, 10.0, 14.0, 18.0, 22.0]: sample(h, fast, x, z)
	var old: float = fast.Depth(14.0, 14.0)
	h.hv[27] -= 2.0
	fast = h.fast_water()
	sample(h, fast, 14.0, 14.0)
	check(close(fast.Depth(14.0, 14.0), old + 2.0), "Refreshing the native snapshot observes terrain excavation")
	h.road_refinement = RoadRefinement.new()
	check(h.fast_water() == null, "Native base sampler refuses refined runtime roads")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	Grid.allow_fast = true
	var probe := Grid.fast_grid()
	if probe == null or not probe.has_method("WaterMathSourceHash") or not probe.has_method("Depth"):
		printerr("water_parity_test requires current C# support; run dotnet build first")
		quit(1)
		return
	# Normalize checkout line endings just like the generator (Windows CRLF / Unix LF).
	var source := FileAccess.get_file_as_string("res://scripts/core/water_math.gd").replace("\r\n", "\n")
	check(probe.WaterMathSourceHash() == source.sha256_text(), "Compiled C# math matches the canonical source hash")
	if fails:
		quit(1)
		return
	check(WaterBuilder.LAKE_DROP == MathSource.LAKE_DROP, "Renderer uses the shared lake offset")
	triangles(probe)
	var rng := RandomNumberGenerator.new()
	rng.seed = 153001
	var w := WorldGenerator._geography("Север-1234", 256)
	var h := Heightfield.base_of(w)
	var fast := h.fast_water()
	check(fast != null, "Native base-water sampler is available")
	if fast == null:
		w.clear_noise_fields()
		quit(1)
		return
	check(not h._river_cells.is_empty(), "Generated world contains river triangles")
	var lakes: Array[int] = []
	for i in w.N:
		if w.lake[i] != 0: lakes.append(i)
	print("Generated lake cells: ", lakes.size(), "; explicit lake fixtures are tested separately")
	# Exactly 1000 uniform random float64 world coordinates; no float32 Vector2 quantization.
	for i in RANDOM_SAMPLES:
		sample(h, fast, rng.randf_range(0.0, w.W * GameConfig.TILE), rng.randf_range(0.0, w.H * GameConfig.TILE))
	check(wet > 0 and dry > 0, "Random world samples exercise both wet and dry ground")
	print("Random world parity: %d/%d byte-identical, max error %.12f m" % [exact, samples, max_error])
	# Uniform sampling alone rarely hits thin rivers and almost never the shore tolerance.
	var cells := h._river_cells.keys()
	for i in 300:
		if cells.is_empty(): break
		var segments: Array = h._river_cells[cells[rng.randi_range(0, cells.size() - 1)]]
		var s: Dictionary = segments[rng.randi_range(0, segments.size() - 1)]
		var a: Vector3 = s.a.left
		var b: Vector3 = s.a.right
		var c: Vector3 = s.b.left
		if i % 2: a = s.b.right
		var u := rng.randf()
		var v := rng.randf() * (1.0 - u)
		sample(h, fast, u * float(a.x) + v * float(b.x) + (1.0 - u - v) * float(c.x),
			u * float(a.z) + v * float(b.z) + (1.0 - u - v) * float(c.z))
		for bank: Vector3 in [s.a.left, s.a.right, s.b.left, s.b.right]:
			sample(h, fast, bank.x, bank.z)
			sample(h, fast, float(bank.x) + 1e-7, float(bank.z) - 1e-7)
	for i in 100:
		if lakes.is_empty(): break
		var cell: int = lakes[rng.randi_range(0, lakes.size() - 1)]
		sample(h, fast, (cell % w.W + rng.randf()) * GameConfig.TILE, (cell / w.W + rng.randf()) * GameConfig.TILE)
	for x: float in [-0.001, 0.0, 2.0, w.W * GameConfig.TILE - 0.001, w.W * GameConfig.TILE]:
		for z: float in [-0.001, 0.0, 2.0, w.H * GameConfig.TILE - 0.001, w.H * GameConfig.TILE]:
			sample(h, fast, x, z)
	# Road-generator consumers must classify the same nine-point ford probes.
	var probes := PackedInt32Array()
	for i in 100: probes.append(rng.randi_range(0, w.N - 1))
	for limit: float in [0.3, GameConfig.FORD_DEPTH]:
		var expected := PackedInt32Array()
		for cell in probes:
			var deep := false
			for dz: float in [-0.4, 0.0, 0.4]:
				for dx: float in [-0.4, 0.0, 0.4]:
					deep = deep or h.depth_at((cell % w.W + 0.5 + dx) * GameConfig.TILE,
						(cell / w.W + 0.5 + dz) * GameConfig.TILE) > limit
			if deep: expected.append(cell)
		check(fast.DeepFords(probes, limit) == expected, "DeepFords agrees with runtime depth at threshold %.2f m" % limit)
	var roads_same := true
	for i in 50:
		var a := {x = rng.randf_range(2, w.W - 3), y = rng.randf_range(2, w.H - 3), w = 1.0}
		var b := {x = a.x + rng.randf_range(-1, 1), y = a.y + rng.randf_range(-1, 1), w = 1.0}
		roads_same = roads_same and StageTrails._road_segment(h, a, b) == StageTrails._road_segment(h, a, b,
			StageTrails.ROAD_LIMIT, StageTrails.BENCH_CROSS, fast)
	check(roads_same, "RoadSegment agrees with the GDScript road safety check")
	w.clear_noise_fields()
	lake_fixture(rng)
	print("All depth samples: %d, byte-identical: %d, wet: %d, dry: %d, max error: %.12f m" % [samples, exact, wet, dry, max_error])
	print("Water parity failures: ", fails)
	quit(1 if fails else 0)
