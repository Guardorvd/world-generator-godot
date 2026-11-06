extends SceneTree
## Reuse a validated geographic cache; never regenerate geography for profiling.
## One build per process: -- --reference saves a reference with the same acceptance
## rules, full neighbour indexing and no early audit. Default compares against it.
const Network := preload("res://scripts/trails/trail_world_network.gd")
const Check := preload("res://tools/selftest.gd")
var failures := 0

func _initialize() -> void:
	# быстрый режим (--part): мир готовится ~20 с, сеть ~20 с; лимит с запасом для второго ПК
	preload("res://tools/watchdog.gd").arm(self, 150 if "--part" in OS.get_cmdline_user_args() else 300)
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
	# --part: быстрый режим (QuickTrails): сеть только в середине мира (треть по каждой стороне) и короче обычной —
	# та же область и те же пределы длины, что у игры с ключом --quick-trails. Своё имя файла эталона (_part):
	# `-- --part --save` снимает эталон быстрого режима, обычный `-- --part` сверяет с ним. Полный эталон не трогается.
	var area := Rect2i(0, 0, w.W, w.H)
	var options := {early_audit = not reference}
	var quick := "--part" in OS.get_cmdline_user_args()
	if quick:
		area = QuickTrails.area(area)
		options.merge(QuickTrails.options())
		print("PART ", area, " длина сети до ", QuickTrails.LENGTH_TARGET, " м, собрано не больше ", QuickTrails.WORK_LIMIT, " м")
	var started := Time.get_ticks_msec()
	options.on_progress = func(_p: float, label: String) -> void: print("[%6.1f с] %s" % [(Time.get_ticks_msec() - started) / 1000.0, label])
	var plan := Network.build(w, h, area, options)
	print("BUILD ", (Time.get_ticks_msec() - started) / 1000.0, " с")
	print("REFERENCE " if reference else "OPTIMIZED ", JSON.stringify(plan.stats))
	print("DISTRICTS ", JSON.stringify(plan.get("districts", [])))
	print("ROUTES ", JSON.stringify(plan.routes.map(func(r: Dictionary) -> Array: return [r.title, roundi(StageTrailPlan.unpack(r).route_length()), snappedf(r.points[0].x, 1), snappedf(r.points[0].y, 1)])))
	print("EARTH ", JSON.stringify(earth_summary(plan)))
	var result_path := "res://.godot/trail_network_cost_reference%s.bin" % ("_part" if "--part" in OS.get_cmdline_user_args() else "")
	var snapshot := preload("res://scripts/game/surface_snapshot.gd")
	if reference or "--save" in OS.get_cmdline_user_args():
		FileAccess.open(result_path, FileAccess.WRITE).store_var({routes = plan.routes, surface = snapshot.capture(h, "final")})
	elif not FileAccess.file_exists(result_path):
		print("ЭТАЛОНА НЕТ: ", result_path, " (", "быстрый режим: -- --part --save" if quick else "полный режим: -- --reference", ")")
	else:
		var saved: Dictionary = FileAccess.open(result_path, FileAccess.READ).get_var()
		check(saved.routes == plan.routes, "all routes match the reference with identical acceptance rules")
		var restored: Heightfield = snapshot.restore(w, saved.surface, "final")
		check(restored != null and preload("res://tools/trail_world_network_test.gd").same_surface(restored, h), "every real-world patch and material matches")
	check(geo == var_to_bytes([w.h, w.ocean, w.lake, w.rivers]), "geography remains byte-identical")
	check(Check.settlement_network_valid(w), "settlement connections remain physically valid")
	print("COST RESULT ", failures, " failures")
	quit(1 if failures else 0)

## Земляные работы по видам: кубометры выемки и насыпи на 100 м линии, самая глубокая выемка и самая высокая насыпь, м.
static func earth_summary(plan: Dictionary) -> Dictionary:
	var out := {}
	for entry: Dictionary in plan.get("entries", []):
		var row: Dictionary = out.get(entry.style, {legs = 0, length = 0.0, cut = 0.0, fill = 0.0, deepest = 0.0})
		row.legs += 1
		row.length += entry.length
		var worked: Dictionary = entry.get("earthworks", {})
		row.cut += float(worked.get("cut_m3", 0.0))
		row.fill += float(worked.get("fill_m3", 0.0))
		row.deepest = maxf(row.deepest, float(worked.get("max_cut", 0.0)))
		out[entry.style] = row
	for style: String in out:
		var row: Dictionary = out[style]
		row.cut_per_100m = snappedf(row.cut / maxf(1.0, row.length) * 100.0, 0.1)
		row.fill_per_100m = snappedf(row.fill / maxf(1.0, row.length) * 100.0, 0.1)
		row.erase("cut")
		row.erase("fill")
	return out
