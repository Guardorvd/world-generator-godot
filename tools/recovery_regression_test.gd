extends SceneTree
## Synthetic road/settlement contracts; no world generation or user cache.
var fails := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("OK " if ok else "FAIL ", label)
	fails += int(not ok)

func world(grade: float) -> WorldData:
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = w.W * w.H
	w.seed_num = 42
	for key: String in ["h", "filled", "slope", "dist_water", "elev", "temp", "moist"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		w.set(key, values)
	w.dist_water.fill(100.0)
	for key: String in ["ocean", "lake", "river", "biome", "path_mask"]:
		var values := PackedByteArray()
		values.resize(w.N)
		w.set(key, values)
	w.biome.fill(Biomes.GRASS)
	for y in w.H:
		for x in w.W: w.h[y * w.W + x] = (40.0 + grade * y * GameConfig.TILE) / GameConfig.HS
	w.trails = [{kind = "road", pts = [{x = 8.5, y = 32.5, w = 0.9}, {x = 55.5, y = 32.5, w = 0.9}]}]
	for x in range(8, 56): w.path_mask[32 * w.W + x] = 3
	var s := SettlementData.new(32.5, 32.5, 32 * w.W + 32, "fixture")
	s.homes = 12
	s.town = true
	w.settlements = [s]
	RoadSurface.run(w)
	return w

func run() -> void:
	for grade: float in [0.0, 0.08, 0.16, 0.24]:
		var w := world(grade)
		StageLandmarks.lay_out(w)
		var final := Heightfield.new(w)
		var bad := 0
		for hut: HutData in w.settlements[0].huts:
			if not StageLandmarks._fits(w, final, w.river_cells(), Vector2(hut.x, hut.y), hut.a, hut.t): bad += 1
		print("LAYOUT grade=", grade, " huts=", w.settlements[0].huts.size(), " invalid_on_final=", bad)
		check(bad == 0, "houses fit the rendered road surface at grade %s" % grade)
	var w := world(0.0)
	var fountain := HutData.new(32.5, 31.48, 0, "fountain", 0.0)
	w.settlements[0].huts = [fountain] as Array[HutData]
	check(StageLandmarks._fits(w, Heightfield.new(w), w.river_cells(), Vector2(fountain.x, fountain.y), fountain.a, fountain.t), "small building has a clear checked footprint")
	StageTrails._clear_huts(w)
	check(w.settlements[0].huts.size() == 1, "cleanup preserves a checked small building beside the road")
	w = world(0.0)
	for y in w.H:
		for x in w.W: w.h[y * w.W + x] = (40.0 + minf(12.0, maxf(0.0, 20.0 - absf(y - 32.0) * 2.0))) / GameConfig.HS
	w.trails = []
	w.path_mask.fill(0)
	w.tunnels = [TunnelData.new(20 * w.W + 32, 44 * w.W + 32)]
	var p := Vector2(34.6, 32.5)
	var base := Heightfield.base_of(w)
	var final := Heightfield.new(w)
	print("TUNNEL fits_base=", StageLandmarks._fits(w, base, w.river_cells(), p, 0.0, "chalet"), " fits_final=", StageLandmarks._fits(w, final, w.river_cells(), p, 0.0, "chalet"))
	check(not StageLandmarks._fits(w, base, w.river_cells(), p, 0.0, "chalet"), "layout rejects a chalet whose foundation enters the tunnel cut")
	print("recovery_regression_test: ", fails, " failures")
	quit(1 if fails else 0)
