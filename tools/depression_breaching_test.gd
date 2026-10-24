extends SceneTree
## Regression: preserve depressions, breach their outlets, retain lakes and soil moisture.
var fails := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func bowl(depth: float, radius: float, scale_value := 1.0) -> WorldData:
	var w := WorldData.new()
	w.W = 32
	w.H = 32
	w.N = 1024
	w.scale = scale_value
	w.h.resize(w.N)
	w.ocean.resize(w.N)
	w.seed_num = 123
	w.noise.moist = Simplex.new(WGRandom.new(123))
	w.noise.temp = Simplex.new(WGRandom.new(456))
	for y in w.H:
		for x in w.W:
			var r := Vector2(x - 16, y - 16).length()
			# Sloping outside, rising bowl floor inside a closed circular rim.
			w.h[y * w.W + x] = 0.3 - depth * (1.0 - r / radius) if r < radius else 0.3 - (r - radius) * 0.008
	return w

func inspect_bowl(depth: float, radius: float, scale_value := 1.0) -> void:
	var w := bowl(depth, radius, scale_value)
	var before := w.h.duplicate()
	StageHydrology.run(w)
	check(w.lake.count(1) == 0, "Rejected depression must stay dry")
	check(w.wetland.count(1) > 0, "Rejected depression retains wetland footprint")
	var cut := 0
	var kept := 0
	for i in w.N:
		check(w.h[i] <= before[i] + 1e-7, "Breaching must never raise terrain")
		if w.h[i] < before[i] - 1e-7:
			cut += 1
		elif w.wetland[i] != 0:
			kept += 1
	check(cut > 0 and kept > cut, "A narrow outlet preserves most of the bowl")
	var c := 16 * w.W + 16
	var visited := {}
	while c >= 0:
		check(not visited.has(c), "Outlet has no cycle")
		if visited.has(c): break
		visited[c] = true
		var d := w.down[c]
		if d >= 0:
			check(w.h[d] <= w.h[c] + 1e-7, "Carved outlet flows downhill on actual terrain")
		c = d
	StageGeography.run(w)
	StageClimate.run(w)
	var wet_moist := w.moist.duplicate()
	var wetland := w.wetland
	w.wetland = PackedByteArray()
	StageClimate.run(w)
	var boosted := 0
	for i in w.N:
		if wetland[i] != 0 and wet_moist[i] > w.moist[i] + 0.01:
			boosted += 1
		if wetland[i] == 0:
			check(wet_moist[i] == w.moist[i], "Wetland moisture stays local")
	check(boosted > 0, "Wetland increases climate moisture")
	print("bowl depth=%s radius=%s: cuts=%d preserved=%d wetland=%d" % [depth, radius, cut, kept, wetland.count(1)])

func least_cost() -> void:
	var w := bowl(0.02, 7.0)
	w.h.fill(0.6)
	var pit := 16 * w.W + 16
	w.h[pit] = 0.2
	# The longer northern outlet requires much less excavation than the short east route.
	for y in range(0, 16):
		w.h[y * w.W + 16] = 0.22 if y > 0 else 0.1
	w.h[16 * w.W + 18] = 0.1
	var lake := PackedByteArray()
	lake.resize(w.N)
	var terrain := w.h.duplicate()
	StageHydrology._breach_from(w, terrain, lake, pit)
	check(terrain[15 * w.W + 16] < 0.2, "Choose the cheaper northern channel")
	check(terrain[16 * w.W + 17] == w.h[16 * w.W + 17], "Keep the expensive eastern ridge")
	check(terrain[pit] == 0.2 or absf(terrain[pit] - 0.2) < 1e-7, "Preserve pit floor")

func _init() -> void:
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	inspect_bowl(0.02, 7.0) # broad but shallow
	inspect_bowl(0.08, 2.5) # deep but small
	inspect_bowl(0.08, 7.0, 0.02) # oversized closed basin
	var lake_world := bowl(0.08, 7.0)
	var bottom := lake_world.h[16 * 32 + 16]
	StageHydrology.run(lake_world)
	check(lake_world.lake.count(1) >= StageHydrology.LAKE_MIN, "Keep qualifying lakes")
	check(lake_world.h[16 * 32 + 16] == bottom, "Keep lake bottom")
	check(lake_world.wetland[16 * 32 + 16] == 0, "Lake is not wetland")
	least_cost()
	print("Depression regression failures: %d" % fails)
	quit(1 if fails > 0 else 0)
