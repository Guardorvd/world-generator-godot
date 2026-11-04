extends SceneTree
## Reuse a validated geographic cache; never regenerate geography for profiling.
## One build per process: -- --reference saves a reference with the same acceptance
## rules, full neighbour indexing and no early audit. Default compares against it.
const Network := preload("res://scripts/trails/trail_world_network.gd")
const Check := preload("res://tools/selftest.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	failures += int(not ok)

func prepared_copy(base: Heightfield) -> Heightfield:
	var h := base.copy()
	h.structures = base.structures
	h.index_structures()
	h.road_refinement = RoadRefinement.from_patches(base.road_refinement.patches.duplicate(), base.world.H)
	return h

func run() -> void:
	var cache := WorldCache.new()
	cache.dir = "res://tools/control/runs/network_game_cache"
	var seed := "Север-1234"
	var path := cache.path_for(seed, WorldGenerator.START_SIZE, 0)
	var data: Variant = cache._read(path, cache._key(seed, WorldGenerator.START_SIZE, 0))
	check(data is Dictionary, "validated geographic fixture exists")
	if not data is Dictionary: quit(1); return
	var w := cache._restore(data, false)
	check(w != null, "geographic fixture passes WorldData validation")
	if w == null: quit(1); return
	var geo := var_to_bytes([w.h, w.ocean, w.lake, w.rivers])
	w.base_heights = Heightfield.new(w, false)
	w.start_noise_fields()
	StageLandmarks.run(w)
	StageTrails.run(w, func(_p: float, _label: String) -> void: pass)
	StageSites.run(w)
	RoadSurface.run(w)
	var base := w.base_heights.copy()
	base.finish_paths()
	var reference := "--reference" in OS.get_cmdline_user_args()
	RoadRefinement.restrict_local_index = not reference
	var h := prepared_copy(base)
	var plan := Network.build(w, h, Rect2i(0, 0, w.W, w.H), {early_audit = not reference,
		on_progress = func(_p: float, label: String) -> void: print(label)})
	print("REFERENCE " if reference else "OPTIMIZED ", JSON.stringify(plan.stats))
	var result_path := "res://.godot/trail_network_cost_reference.bin"
	var snapshot := preload("res://scripts/game/surface_snapshot.gd")
	if reference:
		FileAccess.open(result_path, FileAccess.WRITE).store_var({routes = plan.routes, surface = snapshot.capture(h, "final")})
	elif FileAccess.file_exists(result_path):
		var saved: Dictionary = FileAccess.open(result_path, FileAccess.READ).get_var()
		check(saved.routes == plan.routes, "all routes match the reference with identical acceptance rules")
		var restored: Heightfield = snapshot.restore(w, saved.surface, "final")
		check(restored != null and preload("res://tools/trail_world_network_test.gd").same_surface(restored, h), "every real-world patch and material matches")
	check(geo == var_to_bytes([w.h, w.ocean, w.lake, w.rivers]), "geography remains byte-identical")
	check(Check.settlement_network_valid(w), "settlement connections remain physically valid")
	print("COST RESULT ", failures, " failures")
	quit(1 if failures else 0)
