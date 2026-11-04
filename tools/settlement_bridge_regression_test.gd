extends SceneTree
## Road-stage integration on the reported seeds. No Trail Network, nature or game
## scene generation: those stages cannot repair a StageTrails connection/bridge.
## Default: one seed. -- --seed NAME selects another; --all explicitly runs the list.
const Check := preload("res://tools/selftest.gd")
const Bridges := preload("res://tools/bridge_test.gd")
const SEEDS := ["Север-1234", "Ущелье", "Заря-4787", "Туман-4821", "Ветер-1470"]
var fails := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 420)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	fails += int(not ok)

func geography(seed: String) -> WorldData:
	var cache := WorldCache.new()
	for folder in ["res://tools/control/runs/settlement_bridge_cache", "res://tools/control/runs/network_game_cache", "user://road_plan_test"]:
		cache.dir = folder
		var data: Variant = cache._read(cache.path_for(seed, WorldGenerator.START_SIZE, 0), cache._key(seed, WorldGenerator.START_SIZE, 0))
		if data is Dictionary:
			var restored := cache._restore(data, false)
			if restored != null:
				print("GEOGRAPHY cached ", seed)
				return restored
	print("GEOGRAPHY generate once ", seed)
	var w := WorldGenerator._geography(seed, WorldGenerator.PLAN_SIZE)
	cache.dir = "res://tools/control/runs/settlement_bridge_cache"
	cache.enabled = true
	cache._save_layer(w, WorldGenerator.START_SIZE, 0, {})
	cache.wait_writes()
	return w

func geo_bytes(w: WorldData) -> PackedByteArray:
	return var_to_bytes([w.h, w.filled, w.elev, w.ocean, w.lake, w.river_area, w.rivers, w.river_exits, w.temp, w.moist, w.biome])

func run() -> void:
	var results := []
	var args := OS.get_cmdline_user_args()
	var selected: Array = [SEEDS[0]]
	if "--all" in args: selected = SEEDS
	elif "--seed" in args and args.find("--seed") + 1 < args.size(): selected = [args[args.find("--seed") + 1]]
	for seed: String in selected:
		results.append(run_seed(seed))
		FileAccess.open("res://tools/control/runs/settlement_bridge_results.json", FileAccess.WRITE).store_string(JSON.stringify(results, "  "))
	print("SETTLEMENT BRIDGE RESULT ", fails, " failures")
	quit(1 if fails else 0)

func run_seed(seed: String) -> Dictionary:
	var w := geography(seed)
	var original := geo_bytes(w)
	if w.base_heights == null:
		w.base_heights = Heightfield.new(w, false)
		w.start_noise_fields()
	StageLandmarks.run(w)
	StageTrails.run(w, func(_p: float, label: String) -> void: print(seed, ": ", label))
	check(Check.settlements_connected(w) and Check.settlement_network_valid(w), seed + ": all published settlements are reachable")
	RoadSurface.run(w)
	var h := w.base_heights.copy()
	h.finish_paths()
	w.base_heights = null
	w.clear_noise_fields()
	w.outer = OuterLand.new(w)
	h.obstacles = ForestObstacles.new(w, h)
	if not w.bridges.is_empty():
		var s: Dictionary = h.structures[0]
		var entry := Vector2(s.ax - s.ux * 2, s.az - s.uz * 2) / GameConfig.TILE
		w.available_rect = Rect2i(0, 0, 1, 1)
		check(not w.accessible(entry.x, entry.y), seed + ": a closed territory rejects entry independently of bridge geometry")
		w.available_rect = Rect2i(0, 0, w.W, w.H)
		check(w.accessible(entry.x, entry.y), seed + ": opening the tested territory restores entry permission")
	var report := Bridges.audit(w, h)
	for message: String in report.errors: print("BRIDGE DETAIL ", seed, ": ", message)
	check(report.errors.is_empty(), seed + ": bridge mesh/support and both-direction walking/cycling")
	check(original == geo_bytes(w), seed + ": all original geography fields remain byte-identical")
	var result := {seed = seed, settlements = w.settlements.size(), candidates = w.generation_profile.settlement_candidates,
		rejected = w.generation_profile.settlement_rejected, trails = w.trails.size(), bridges = w.bridges.size(),
		passed = report.passed, errors = Array(report.errors), connected = Check.settlements_connected(w)}
	print("SEED RESULT ", JSON.stringify(result))
	return result
