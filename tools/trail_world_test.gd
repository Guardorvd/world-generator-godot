extends SceneTree
## Integration check of the automatic start trail with its access to the roads (StageTrailPlan, TrailAccess) in a REAL
## game world: new generation of a seed through WorldLoader (the game's own path, world cache on in a temporary
## directory), then loading the same seed again from the cache. Prints preparation times. Checks: approach, trail and exit
## are in the world exactly once, the plan is stored (also "no trail"), the second load does not search again and gives
## the same plan, the same paths and the same final ground (no accumulation of earthworks), no forest on the routes, the
## finished surface meets the requirement, smooth joints, the start is reachable from the home road network and the way
## back from the finish exists in the existing RoadNavigation graph of the RELOADED world, and one short ride over approach,
## trail and exit with the game's own bike controller and forest obstacles without a fall. On the control seed (the
## default) finding a trail with access is mandatory.
## --scene also starts the real GameWorld on the reloaded world (display; one frame with --capture, needs a window).
##   godot --headless --path . --script res://tools/trail_world_test.gd -- --seed Север-1234
## The cache directory user://trail_world_test_cache is removed at the end. A few minutes.
const OUT := "res://tools/control/runs/trail_world"
const CACHE := "user://trail_world_test_cache"
const GRADE := 0.15
var failures := 0
var checks := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 590)
	run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	print("trail_world: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1


func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var args := OS.get_cmdline_user_args()
	var seed: String = args[args.find("--seed") + 1] if "--seed" in args else "Север-1234"
	var cache := GameContext.scope.cache
	cache.dir = CACHE
	cache.enabled = true
	cache.remove_seed(seed)
	var searches := TrailScout.runs
	var t0 := Time.get_ticks_msec()
	var a := WorldLoader.load_world(seed, WorldGenerator.START_SIZE)
	var first_ms := Time.get_ticks_msec() - t0
	cache.wait_writes()
	var plan_a: Dictionary = a.world.trail_plan
	check(a.error.is_empty() and not a.from_cache and TrailScout.runs == searches + 1, "new generation: one automatic search (%d runs)" % (TrailScout.runs - searches))
	print("Новый мир «%s»: загрузка %d мс (генерация %.0f, finish_paths %.0f, запекание комплекта %.0f, всего %.0f); план: %s" % [
		seed, first_ms, a.timings.get("generate_ms", 0.0), a.timings.finish_paths_ms, a.timings.trail_ms, a.timings.total_ms, plan_a.state])
	print("Стадия трассы: ", plan_a.get("stats", {}), " · ", plan_a.get("verdict", ""), " ", plan_a.get("reason", ""), " · окна: ", plan_a.get("windows", []))
	check(plan_a.get("version", 0) == StageTrailPlan.VERSION and plan_a.state in ["found", "none"] and plan_a.has("stats"), "plan stored with a state: %s" % plan_a.state)
	if not "--seed" in args:
		check(plan_a.state == "found", "the control seed gets a trail with access (mandatory): %s" % plan_a.get("reason", ""))
	var routes_a := trail_records(a.world)
	check(routes_a.size() == (3 if plan_a.state == "found" else 0), "approach, trail and exit are in the world exactly once: %d route(s)" % routes_a.size())
	t0 = Time.get_ticks_msec()
	searches = TrailScout.runs
	var b := WorldLoader.load_world(seed, WorldGenerator.START_SIZE)
	var second_ms := Time.get_ticks_msec() - t0
	print("Повторная загрузка из кэша: %d мс (чтение кэша %.0f, finish_paths %.0f, запекание комплекта %.0f, всего %.0f)" % [
		second_ms, b.timings.get("cache_read_ms", 0.0), b.timings.finish_paths_ms, b.timings.trail_ms, b.timings.total_ms])
	check(b.from_cache and TrailScout.runs == searches, "second load: from the cache, no new search")
	check(b.world.trail_plan == plan_a, "the stored plan (state, kit, statistics) is identical after reload")
	var routes_b := trail_records(b.world)
	var same_paths := routes_b.size() == routes_a.size()
	for k in mini(routes_a.size(), routes_b.size()):
		same_paths = same_paths and routes_b[k].pts == routes_a[k].pts
	check(same_paths, "the same approach, trail and exit paths after reload, not duplicated")
	check(b.trail.applied == (plan_a.state == "found") and b.trail.errors.is_empty(), "second load applied the kit without errors (%s)" % b.trail.variant)
	var d: TrailDefinition = null
	if plan_a.state != "found":
		print("Трассы нет — нормальный результат; запись «трассы нет» сохранена и повторно не ищется.")
	else:
		d = StageTrailPlan.unpack(plan_a.definition)
		var inbound := StageTrailPlan.unpack(plan_a.access.inbound)
		var outbound := StageTrailPlan.unpack(plan_a.access.outbound)
		var info: Dictionary = plan_a.access.info
		print("Подход %.0f м (поворот в стыке %.0f°), трасса %.0f м, выход %.0f м (%.0f°), примыкания %s и %s" % [inbound.route_length(), info.inbound.turn,
			d.route_length(), outbound.route_length(), info.outbound.turn, inbound.points[0], outbound.points[-1]])
		check(inbound.points[-1] == d.points[0] and outbound.points[0] == d.points[-1], "approach and exit meet the trail exactly at its start and finish")
		check(a.trail.applied and a.trail.errors.is_empty(), "first load applied the kit without errors (%s)" % a.trail.variant)
		var kit: Array[TrailDefinition] = [inbound, d, outbound]
		check(patch_hash(a.heights, kit) == patch_hash(b.heights, kit), "the final ground along approach, trail and exit is the same after reload (no accumulation, no loss)")
		for part in kit:
			var s := TrailSurvey.measure(b.heights, part, GRADE)
			print("Готовая поверхность «%s»: длина %.0f м, уклон до %.1f%%, уровень проверки %s, элементов %d" % [part.id, s.length, s.peak_grade * 100.0, s.level(), part.elements.size()])
			check(s.level() == "within", "%s: the finished world surface meets the grade requirement" % part.id)
			check(trees_on_trail(b.world, part) == 0, "%s: no forest object on the axis (%.1f m half width)" % [part.id, part.width * 0.5])
		joints(b.heights, kit)
		ride(b, kit)
		navigation(b, kit)
	if "--scene" in args:
		await scene(b, d, "--capture" in args)
	cache.wait_writes()
	cache.remove_seed(seed)
	cache.enabled = false
	print("trail_world: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)


func trail_records(w: WorldData) -> Array:
	var ids := [TrailAccess.IDS.inbound, StageTrailPlan.ID, TrailAccess.IDS.outbound]
	var out := []
	for id: String in ids:
		out.append_array(w.trails.filter(func(t: Dictionary) -> bool: return t.get("trail_id", "") == id))
	return out


## SHA-256 of the metre patches and base cells around the kit (the whole final ground the game uses there).
func patch_hash(h: Heightfield, kit: Array[TrailDefinition]) -> String:
	var w := h.world
	var lo := kit[0].points[0]
	var hi := lo
	for part in kit:
		for p in part.points:
			lo = lo.min(p)
			hi = hi.max(p)
	var cells := Rect2i(Vector2i((lo / GameConfig.TILE).floor()) - Vector2i(6, 6), Vector2i(((hi - lo) / GameConfig.TILE).ceil()) + Vector2i(12, 12))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var keys: Array = []
	for key: int in h.road_refinement.patches:
		if cells.has_point(Vector2i(key % w.W, key / w.W)):
			keys.append(key)
	keys.sort()
	for key: int in keys:
		ctx.update(PackedInt32Array([key]).to_byte_array())
		ctx.update((h.road_refinement.patches[key].h as PackedFloat32Array).to_byte_array())
	for z in range(cells.position.y, cells.end.y):
		ctx.update(h.hv.slice(z * w.W + cells.position.x, z * w.W + cells.end.x).to_byte_array())
	return ctx.finish().hex_encode()


func trees_on_trail(w: WorldData, d: TrailDefinition) -> int:
	var count := 0
	var reach := d.width * 0.5
	for o in w.obj_count:
		var at := Vector2(w.obj_x[o], w.obj_y[o]) * GameConfig.TILE
		if d.nearest(at, reach + 1.0).z < reach:
			count += 1
	return count


## Smooth surface across the joints of approach, trail and exit (finished world ground).
func joints(h: Heightfield, kit: Array[TrailDefinition]) -> void:
	var worst := 0.0
	for k in 2:
		var a := kit[k]
		var b := kit[k + 1]
		for offset in [-1.0, -0.25, 0.25, 1.0]:
			var fore := a.point_at(a.route_length() + minf(0.0, offset))
			var aft := b.point_at(maxf(0.0, offset))
			worst = maxf(worst, absf(h.surface_at(fore.x, fore.y, INF) - h.surface_at(aft.x, aft.y, INF)))
	check(worst < 0.25, "continuous finished surface across both joints: step up to %.2f m" % worst)


## One short ride over approach, trail and exit on the loaded world with the game's controller and the world's forest obstacles.
func ride(loaded: WorldLoader, kit: Array[TrailDefinition]) -> void:
	var h := loaded.heights
	h.obstacles = ForestObstacles.new(loaded.world, h)
	var d := TrailDefinition.new()
	var all := PackedVector2Array()
	for part in kit:
		for pt in part.points:
			if all.is_empty() or all[-1].distance_to(pt) > 0.01: all.append(pt)
	d.points = all
	var controller := BikeController.new()
	var player := PlayerState.new()
	var bike := BikeRide.new()
	var at := d.point_at(2.0)
	player.x = at.x
	player.z = at.y
	player.feet = h.surface_at(at.x, at.y, -INF)
	player.on_ground = true
	bike.x = player.x
	bike.z = player.z
	bike.y = player.feet
	bike.heading = d.heading_at(2.0)
	bike.mount(player)
	bike.speed = 3.0
	h.obstacles.update(player.x, player.z, PackedFloat32Array(), -1, true)
	var ticks := 0
	var worst := 0.0
	var top := 0.0
	var crashed := false
	while ticks < 60 * 120:
		var here := Vector2(bike.x, bike.z)
		var near := d.nearest(here)
		worst = maxf(worst, near.z)
		if near.x > d.route_length() - 3.0: break
		var target := d.point_at(near.x + 6.0) - here
		var steer := clampf(-wrapf(atan2(-target.x, -target.y) - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		h.obstacles.update(player.x, player.z, PackedFloat32Array(), -1)
		controller.ride(1.0 / 60.0, player, bike, loaded.world, h, 0.6, steer, false, false, false)
		top = maxf(top, absf(bike.speed))
		ticks += 1
		if bike.crashed:
			crashed = true
			break
	var ridden := d.nearest(Vector2(bike.x, bike.z)).x
	check(ridden > d.route_length() - 4.0 and not crashed,
		"one short ride over approach, trail and exit in the real world: %.0f of %.0f m in %.1f s, off axis up to %.2f m, top %.1f m/s, fall: %s (not a safety guarantee)" % [
		ridden, d.route_length(), ticks / 60.0, worst, top, crashed])


## Connectivity in the game's navigation graph of the reloaded world: the home network reaches the start, the finish leads back.
func navigation(loaded: WorldLoader, kit: Array[TrailDefinition]) -> void:
	var w := loaded.world
	var t0 := Time.get_ticks_msec()
	var nav = preload("res://scripts/game/road_navigation.gd").new()
	nav.build(w, loaded.heights)
	var home: SettlementData = PlayerState.home(w)
	var home_at := Vector2(home.x, home.y) * GameConfig.TILE
	var home_comp: int = nav.component_near(home_at)
	var comps := [nav.component_near(kit[0].points[0]), nav.component_near(kit[1].points[0]), nav.component_near(kit[1].points[-1]), nav.component_near(kit[2].points[-1])]
	var build_ms := Time.get_ticks_msec() - t0
	check(home_comp >= 0 and comps.all(func(c: int) -> bool: return c == home_comp),
		"home network, approach, start, finish and exit are one component of the navigation graph (%s vs home %d), graph built in %d ms" % [str(comps), home_comp, build_ms])
	var to_start: PackedVector2Array = nav.route_to(home_at, kit[1].points[0])
	var to_start_ok: bool = nav.complete
	var back: PackedVector2Array = nav.route_to(kit[1].points[-1], home_at)
	var back_ok: bool = nav.complete
	check(to_start_ok and back_ok, "from home to the start and from the finish back home: routes found (%d and %d points)" % [to_start.size(), back.size()])


## The real GameWorld on the reloaded world: built from the same data; the rider on the trail; one frame with --capture.
func scene(loaded: WorldLoader, d: TrailDefinition, capture: bool) -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	GameContext.scope.cache.enabled = false
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	main.game = game
	main.add_child(game)
	var t0 := Time.get_ticks_msec()
	game.start(loaded, main.hud)
	main._show("")
	game.set_physics_process(false)
	game.set_process(false)
	check(game.world == loaded.world and game.heights == loaded.heights, "the game scene is built from the same world and ground (%d ms)" % (Time.get_ticks_msec() - t0))
	if d != null:
		var at := d.point_at(d.route_length() * 0.5)
		game.player.x = at.x
		game.player.z = at.y
		game.player.feet = game.heights.surface_at(at.x, at.y, -INF)
		game.bike.x = at.x
		game.bike.z = at.y
		game.bike.y = game.player.feet
		game.bike.heading = d.heading_at(d.route_length() * 0.5)
		game.yaw = game.bike.heading
		game.bike.mount(game.player)
		for tick in 30:
			game._physics_process(1.0 / 60.0)
			game._update_camera(1.0, 1.0 / 60.0)
		check(not game.bike.crashed and game.bike.riding, "the rider stands on the trail in the game scene")
		if capture:
			await process_frame
			await RenderingServer.frame_post_draw
			check(preload("res://tools/shot_util.gd").save_png(root, OUT, "trail"), "frame saved")
	main._free_game()
	main.queue_free()
	await process_frame
