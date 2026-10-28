extends SceneTree
## Integration check of the automatic start trail with its access to the roads (StageTrailPlan, TrailAccess) in a REAL
## game world: new generation of a seed through WorldLoader (the game's own path, world cache on in a temporary
## directory), then loading the same seed again from the cache. Prints preparation times. Checks: approach, trail and exit
## are in the world exactly once, the plan is stored (also "no trail"), the second load does not search again and gives
## the same plan, the same paths and the same final ground (no accumulation of earthworks), no forest on the routes, the
## finished surface measured whole (grade and earthworks reported against the target — no limits since step 2), smooth joints, the start is reachable from the home road network and the way
## back from the finish exists in the existing RoadNavigation graph of the RELOADED world, and one short ride over approach,
## trail and exit with the game's own bike controller and forest obstacles without a fall. On the control seed (the
## default) finding a trail with access is mandatory.
## --scene also starts the real GameWorld on the reloaded world (display; one frame with --capture, needs a window).
##   godot --headless --path . --script res://tools/trail_world_test.gd -- --seed Север-1234
## The cache directory user://trail_world_test_cache is removed at the end. A few minutes.
const OUT := "res://tools/control/runs/trail_world"
const CACHE := "user://trail_world_test_cache"
const GRADE := 0.15 # target grade of the kit (reported, not a limit)
const Rider = preload("res://tools/trail_access_test.gd") # the same look-ahead rider as the isolated access test
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
	print("Земляные работы комплекта: ", a.trail.get("earthworks", {}))
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
			var sh: Dictionary = b.trail.get("earthworks", {}).get(part.id, {})
			print("Готовая поверхность «%s»: длина %.0f м, уклон до %.1f%% (цель %.0f%%), выемка до %.2f м (%.0f м³), насыпь до %.2f м (%.0f м³), зона %.1f м от оси, элементов %d" % [
				part.id, s.length, s.peak_grade * 100.0, GRADE * 100.0, sh.get("max_cut", 0.0), sh.get("cut_m3", 0.0), sh.get("max_fill", 0.0), sh.get("fill_m3", 0.0), sh.get("reach", 0.0), part.elements.size()])
			check(s.complete(), "%s: the finished world surface is measured along the whole axis" % part.id)
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
		var target := d.point_at(near.x + Rider.rider_look(d, near.x)) - here
		var steer := clampf(-wrapf(atan2(-target.x, -target.y) - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		h.obstacles.update(player.x, player.z, PackedFloat32Array(), -1)
		controller.ride(1.0 / 60.0, player, bike, loaded.world, h, Rider.rider_pedal(d, near.x, bike.speed), steer, false, false, false)
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
	if "--regions" in OS.get_cmdline_user_args():
		GameContext.scope.settings.infinite_world = true
		RegionStream.root = OUT + "/region_store"
	game.start(loaded, main.hud)
	main._show("")
	game.set_physics_process(false)
	game.set_process(false)
	check(game.world == loaded.world and game.heights == loaded.heights, "the game scene is built from the same world and ground (%d ms)" % (Time.get_ticks_msec() - t0))
	if d != null:
		game._finish_opening()
		game.hour = 12.0
		game.day.apply(12.0, 0.0)
		main.hud.visible = false
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
		game.bike.speed = 0.0
		for tick in 12: game.bike.step(game.player, 0.0, 0.0, false, false, 1.0 / 60.0, game.world, game.heights)
		game.player.on_ground = true
		game._snap()
		game.bike_view.draw(1.0)
		game.stream_coordinator.force_terrain(Vector3(at.x, game.player.feet, at.y), GameWorld.NEAR)
		game.stream_coordinator.force_vegetation(Vector3(at.x, game.player.feet, at.y))
		game.heights.obstacles.update(at.x, at.y, game.vegetation.obstacles, game.vegetation.obstacles_version, true)
		game._update_camera(1.0, 0.0)
		check(not game.opening_active() and game.bike.riding and game._prev.distance_to(Vector3(game.player.x, game.player.feet, game.player.z)) < 0.01, "opening ended, player/bike/camera synchronized and chunks loaded")
		if capture:
			var kit: Array[TrailDefinition] = [StageTrailPlan.unpack(loaded.world.trail_plan.access.inbound), d, StageTrailPlan.unpack(loaded.world.trail_plan.access.outbound)]
			var views := {tread = d.route_length() * 0.5, junction = 0.0, exit = d.route_length(), cut = 0.0}
			var deepest := 0.0
			for station in ceili(d.route_length()):
				var pt := d.point_at(station)
				var depth := game.heights.base_ground_at(pt.x, pt.y) - game.heights.ground_at(pt.x, pt.y)
				if depth > deepest:
					deepest = depth
					views.cut = float(station)
			print("Scene deepest cut: %.2f m at %.1f m" % [deepest, views.cut])
			for name: String in views:
				var pt := d.point_at(views[name])
				var target := Vector3(pt.x, game.heights.ground_at(pt.x, pt.y) + 0.5, pt.y)
				var direction := Vector2(sin(d.heading_at(views[name])), cos(d.heading_at(views[name])))
				var side := direction.orthogonal()
				if game.heights.ground_at(pt.x + side.x * 15, pt.y + side.y * 15) > game.heights.ground_at(pt.x - side.x * 15, pt.y - side.y * 15): side = -side
				var offset := Vector3(side.x * 15.0 + direction.x * 9.0, 10.0, side.y * 15.0 + direction.y * 9.0)
				offset.y = maxf(offset.y, game.heights.ground_at(target.x + offset.x, target.z + offset.z) + 4.0 - target.y)
				game.camera.look_at_from_position(target + offset, target)
				game.stream_coordinator.force_terrain(target, GameWorld.NEAR)
				game.stream_coordinator.force_vegetation(target)
				for frame in 3: await process_frame
				await RenderingServer.frame_post_draw
				check(preload("res://tools/shot_util.gd").save_png(root, OUT, name), "frame saved: " + name)
		mesh_support(game, d)
		plant_support(game)
	if "--regions" in OS.get_cmdline_user_args():
		game = await regional_scene(game, main, loaded, capture)
	main._free_game()
	main.queue_free()
	await process_frame


func mesh_support(game: GameWorld, d: TrailDefinition) -> void:
	var worst := 0.0
	var samples := 0
	for node: MeshInstance3D in game.terrain_stream.nodes.values():
		var arrays := node.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in range(0, indices.size(), 111):
			var a := vertices[indices[i]]
			var b := vertices[indices[i + 1]]
			var c := vertices[indices[i + 2]]
			var mid := (a + b + c) / 3.0
			if d.nearest(Vector2(mid.x, mid.z), 45.0).z == INF: continue
			worst = maxf(worst, absf(mid.y - game.heights.ground_at(mid.x, mid.z)))
			samples += 1
	check(samples > 0 and worst < 0.005, "visible triangles equal wheel/foot/collision ground: %d probes, max %.6f m" % [samples, worst])

func plant_support(game: GameWorld) -> void:
	var trees := 0
	var rocks := 0
	var worst := 0.0
	for entry: Dictionary in game.vegetation.veg.values():
		var rock: bool = entry.kind % ForestModels.MODEL_STRIDE == Biomes.T_ROCK
		if not entry.has("tbuf") and not rock: continue
		var buffer: PackedFloat32Array = entry.cbuf if rock else entry.tbuf
		for at in range(0, buffer.size(), 16 if rock else 12):
			var x := buffer[at + 3]
			var z := buffer[at + 11]
			var shift := Vector3(buffer[at], buffer[at + 4], buffer[at + 8]).length() * 0.08 if rock else 0.1
			worst = maxf(worst, absf(buffer[at + 7] + shift - game.heights.ground_at(x, z)))
			if rock: rocks += 1
			else: trees += 1
	check(trees > 0 and worst < 0.005, "displayed tree/rock roots seated on final ground: %d trees, %d rocks, max %.6f m" % [trees, rocks, worst])

func regional_scene(game: GameWorld, main: Node, loaded: WorldLoader, capture: bool) -> GameWorld:
	var stream := game.regions
	check(stream != null, "RegionStream connected in the real scene")
	if stream == null: return game
	var first := Vector2i(ceili(float(game.world.W) / WorldData.REGION_SIZE), game.world.H / 2 / WorldData.REGION_SIZE)
	var keys: Array[Vector2i] = [first, first + Vector2i.RIGHT]
	var frame_max := 0.0
	var found := 0
	var searches := TrailScout.runs
	for key in keys:
		var at := Vector2(key * WorldData.REGION_SIZE) * GameConfig.TILE + Vector2(-16.0, WorldData.REGION_SIZE * GameConfig.TILE * 0.5)
		# Walk from the available side towards the next boundary. The queue is fixed to these two regions.
		var start_x := game.player.x
		for step in 30:
			game.player.x = lerpf(start_x, at.x, (step + 1) / 30.0)
			game.player.z = at.y
			game.player.feet = game.heights.ground_at(game.player.x, game.player.z)
			game.bike.x = game.player.x
			game.bike.z = game.player.z
			game.bike.y = game.player.feet
			game._snap()
			await process_frame
		var deadline := Time.get_ticks_msec() + 60000
		while not stream.ledger.get("regions", {}).has(key) and not stream.failed.has(key) and Time.get_ticks_msec() < deadline:
			var t := Time.get_ticks_usec()
			stream._checked_at = at
			if stream._task == -1 and stream._publishing.is_empty(): stream.queue.assign([key])
			stream.update(at.x, at.y)
			game.outer.update(at.x, at.y, false)
			await process_frame
			frame_max = maxf(frame_max, (Time.get_ticks_usec() - t) / 1000.0)
		check(stream.ledger.get("regions", {}).has(key), "travel: new region published within bounded wait: %s" % key)
		if not stream.ledger.get("regions", {}).has(key): continue
		var entry: Dictionary = stream.ledger.regions[key]
		var plan: Dictionary = entry.trail_plan
		print("REGIONAL RESULT ", key, " ", plan.state, "/", plan.verdict, " ", plan.stats)
		check(plan.version == 1 and plan.state in ["found", "none"], "regional result/version recorded, including none")
		# A kit cannot affect the shared boundary: its complete zone is strictly inside this region.
		if plan.state == "found":
			found += 1
			var kit: Array[TrailDefinition] = [StageTrailPlan.unpack(plan.access.inbound), StageTrailPlan.unpack(plan.definition), StageTrailPlan.unpack(plan.access.outbound)]
			ride(loaded, kit)
			joints(game.heights, kit)
			var point := kit[1].point_at(kit[1].route_length() * 0.5)
			game.player.x = point.x
			game.player.z = point.y
			game.player.feet = game.heights.ground_at(point.x, point.y)
			game.bike.x = point.x
			game.bike.z = point.y
			game.bike.y = game.player.feet
			game._snap()
			game.stream_coordinator.force_vegetation(Vector3(point.x, game.player.feet, point.y))
			plant_support(game)
			var target := Vector3(point.x, game.player.feet, point.y)
			game.camera.look_at_from_position(target + Vector3(15, 15, 20), target)
			if capture:
				for frame in 3: await process_frame
				await RenderingServer.frame_post_draw
				preload("res://tools/shot_util.gd").save_png(root, OUT, "region_%d_%d" % [key.x, key.y])
		var before := hash(entry.fields)
		stream.finish()
		stream._evict(key)
		check(not stream.ledger.regions[key].has("fields"), "region unloaded")
		stream._load_fields(key)
		game.world.outer.set_ledger(stream.ledger)
		check(hash(stream.ledger.regions[key].fields) == before, "return restores exact terrain and patches without reapplying earthworks")
		check(TrailScout.runs <= searches + keys.size(), "no duplicate searches after eviction/return")
	check(found > 0, "at least one accessible kit in the two fixed new regions")
	print("Region publication maximum frame interval: %.2f ms; apply max %.2f; GPU max %s" % [frame_max, stream.stats.get("max_publish_ms", 0.0), stream.stats])
	check(frame_max < 100.0, "publication has no frame stall >= 100 ms (frame intervals, not average FPS)")
	var searches_before := TrailScout.runs
	var saved := game.save_state()
	var Saves := preload("res://scripts/game/save_game.gd")
	Saves.dir = OUT + "/saves"
	check(Saves.write_slot(saved) == OK, "game saved in a prepared region")
	var fields_before := {}
	for key: Vector2i in stream.ledger.regions: fields_before[key] = hash(stream.ledger.regions[key].fields)
	game.queue_free()
	await process_frame
	main.hud.clear_world()
	var restored: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	main.game = restored
	main.add_child(restored)
	restored.start(loaded, main.hud, Saves.read_slot(saved.seed).data)
	restored.set_process(false)
	restored.set_physics_process(false)
	var same := TrailScout.runs == searches_before
	for key: Vector2i in fields_before:
		same = same and restored.regions.ledger.regions.has(key) and hash(restored.regions.ledger.regions[key].fields) == fields_before[key]
	check(same, "game load restores regional kits and fields without any new search")
	return restored
