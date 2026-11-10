extends SceneTree
const F = preload("res://tools/trail_lab_fixture.gd")
const Network = preload("res://scripts/trails/trail_world_network.gd")
const Surface = preload("res://scripts/game/surface_snapshot.gd")
var failures := 0

class ProbeHeightfield extends Heightfield:
	var before_finish := Callable()
	func copy() -> Heightfield:
		var c := ProbeHeightfield.new()
		c.world = world
		c.hv = hv.duplicate(); c.hv_raw = hv_raw; c.water_level = water_level
		c.ribbons = ribbons; c._river_cells = _river_cells
		c._seg_pts = _seg_pts; c._pair_cells = _pair_cells; c._pair_segs = _pair_segs
		c.before_finish = before_finish
		return c
	func finish_paths() -> PackedInt32Array:
		if before_finish.is_valid(): before_finish.call()
		return super.finish_paths()

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)

func run() -> void:
	var d := TrailDefinition.new()
	d.id = "concurrency_stand"
	d.title = "Concurrency stand"
	d.points = PackedVector2Array([Vector2(100, 100), Vector2(100, 180)])
	d.elements = [TrailElementLibrary.make(TrailElement.Profile.ROLLER, 40, 12, 0.35)]
	var built := F.prepare([d] as Array[TrailDefinition])
	check(built.errors.is_empty(), "fixture prepares through production builders")
	if not built.errors.is_empty(): quit(1); return
	var w: WorldData = built.heights.world
	var pixels := MapBaker.paint(w, 2)
	var use_native := Grid.allow_fast
	Grid.allow_fast = false
	var reference := MapBaker.paint(w, 2)
	Grid.allow_fast = use_native
	check(pixels == reference, "native and GDScript map painters produce identical RGB")
	var packed := StageTrailPlan.pack(d)
	w.trail_plan = {version = StageTrailPlan.VERSION, mode = "terrain_network", state = "found",
		routes = [packed], definition = packed, entries = [{rect = Rect2i(12, 12, 40, 40), route = packed.duplicate(true)}]}
	check(StageTrailPlan.consistency_errors(w).is_empty(), "plan and complete civil path network agree")
	_test_consistency(w)
	_test_interleaving(w)
	print("trail_surface_concurrency: ", failures, " failures")
	quit(1 if failures else 0)

func _base(w: WorldData) -> ProbeHeightfield:
	var base := Heightfield.new(w, false)
	var h := ProbeHeightfield.new()
	h.world = w
	h.hv = base.hv; h.hv_raw = base.hv_raw; h.water_level = base.water_level
	h.ribbons = base.ribbons; h._river_cells = base._river_cells
	h._seg_pts = base._seg_pts; h._pair_cells = base._pair_cells; h._pair_segs = base._pair_segs
	return h

func _test_consistency(w: WorldData) -> void:
	var routes := w.trails.duplicate(true)
	var plan := w.trail_plan.duplicate(true)
	w.trails[0].pts[0].x += 1
	var base := _base(w)
	var before := base.hv.duplicate()
	var ready := base.copy()
	w.generation.trail_surface = ready
	var result := StageTrailPlan.prepare(base)
	check(not result.errors.is_empty() and not result.applied and base.hv == before and w.generation.trail_surface == ready,
		"geometry drift rejects before consuming the accepted handoff or changing terrain")
	w.generation.trail_surface = null
	w.trails = routes.duplicate(true)
	w.trails.append(w.trails[0].duplicate(true))
	check(not StageTrailPlan.consistency_errors(w).is_empty(), "duplicate path IDs are rejected")
	w.trails = routes.duplicate(true)
	w.trails.clear()
	check(not StageTrailPlan.consistency_errors(w).is_empty(), "a plan cannot render or restore a route absent from the network")
	w.trails = routes.duplicate(true)
	w.trail_plan.entries[0].route.elements[0].height += 0.1
	check(not StageTrailPlan.consistency_errors(w).is_empty(), "replay entry cannot diverge from the authored elements")
	w.trail_plan = plan.duplicate(true)
	w.trail_plan.routes.append(w.trail_plan.routes[0].duplicate(true))
	check(not StageTrailPlan.consistency_errors(w).is_empty(), "duplicate plan IDs are rejected")
	w.trail_plan = plan.duplicate(true)
	w.trail_plan.routes[0].points = "invalid"
	check(not StageTrailPlan.consistency_errors(w).is_empty(), "malformed geometry yields an error instead of aborting the loader")
	w.trail_plan = plan.duplicate(true)
	check(StageTrailPlan.consistency_errors(w).is_empty(), "restored canonical fixture remains consistent")

func _test_interleaving(w: WorldData) -> void:
	var canonical := var_to_bytes({trails = w.trails, paths = w.path_mask, surfaces = w.road_surface, plan = w.trail_plan})
	var serial := _base(w)
	var errors := Network.restore(serial, w.trail_plan)
	check(errors.is_empty(), "serial replay of saved definitions succeeds")
	if not errors.is_empty(): print(errors); return
	var expected_surface := var_to_bytes(Surface.capture(serial, "final"))
	var painted := MapBaker.paint(w, 1, false, true)
	var expected_map := MapBaker.finish(w, 1, [painted[1]], true)[0].get_data()
	for repeat in 3:
		var begin := Semaphore.new()
		var finished := Semaphore.new()
		var out := {}
		var worker := Thread.new()
		worker.start(func() -> void:
			begin.wait()
			out.map = MapBaker.finish(w, 1, [painted[1]], true)[0].get_data()
			out.canonical = var_to_bytes({trails = w.trails, paths = w.path_mask, surfaces = w.road_surface, plan = w.trail_plan})
			finished.post())
		var replay := _base(w)
		# Force the map reader to run at the exact phase which used to hide canonical routes.
		replay.before_finish = func() -> void:
			begin.post()
			finished.wait()
		errors = Network.restore(replay, w.trail_plan)
		worker.wait_to_finish()
		check(errors.is_empty() and out.map == expected_map and out.canonical == canonical,
			"concurrent map sees the complete immutable network during replay %d" % repeat)
		check(var_to_bytes(Surface.capture(replay, "final")) == expected_surface,
			"concurrent replay preserves every surface channel %d" % repeat)
	check(var_to_bytes({trails = w.trails, paths = w.path_mask, surfaces = w.road_surface, plan = w.trail_plan}) == canonical,
		"replay never mutates canonical paths, masks, materials or definitions")
	var bad := w.trail_plan.duplicate(true)
	bad.entries[0].rect = Rect2i(200, 200, 40, 40)
	var target := _base(w)
	var heights := target.hv.duplicate()
	errors = Network.restore(target, bad)
	check(not errors.is_empty() and target.hv == heights and target.road_refinement == null,
		"failed replay leaves the target surface untouched")
