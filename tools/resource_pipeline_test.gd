extends "res://tools/cache_pipeline_test.gd"
## Extends the storage contract suite with a small authored surface, real scene start and resource phases.
## No WorldGenerator.generate/_generate_plan call; the 768-shaped cache is filled from synthetic fields.
const PROFILE := preload("res://scripts/core/resource_profile.gd")
var profile: RefCounted
var began := {}
var measurements := {}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	profile = PROFILE.new()
	began = profile.stamp()
	run.call_deferred()

func finish_suite(cache: WorldCache) -> void:
	var services := ServiceScope.new()
	services.cache = cache
	cache.cpu_budget = services.cpu_budget
	profile.phase("storage_contracts", began, services, {checks = checks, failures = fails})
	_test_queue(cache)
	_test_budget()
	_test_fairness()
	var stamp: Dictionary = profile.stamp()
	var fixture := make_fixture(144)
	var w: WorldData = fixture.world
	var h: Heightfield = fixture.heights
	var t := Time.get_ticks_usec()
	var all := TerrainBuilder.build_arrays(w, h)
	var pieces := PlanTerrain.partition(all)
	measurements.full_mesh_ms = (Time.get_ticks_usec() - t) / 1000.0
	var exact := true
	var local_ms := 0.0
	for key: Vector2i in pieces:
		t = Time.get_ticks_usec()
		var local := TerrainBuilder.build_chunk(w, h, key)
		local_ms += (Time.get_ticks_usec() - t) / 1000.0
		exact = exact and local == pieces[key]
	check(exact, "local terrain chunks match monolithic partition at all boundaries and road patches")
	measurements.local_all_chunks_ms = local_ms
	measurements.local_max_cells = 66 * 66
	measurements.reference_cells = w.N
	var water := WaterBuilder.prepare(w, fixture.base)
	var water_chunks := [WaterBuilder.partition_arrays(water[0]), WaterBuilder.partition_arrays(water[1])]
	var water_exact := true
	for layer in 2:
		for key: Vector2i in water_chunks[layer]: water_exact = water_exact and WaterBuilder.build_chunk(w, fixture.base, key, layer) == water_chunks[layer][key]
	check(water_exact and not water_chunks[0].is_empty() and not water_chunks[1].is_empty(), "local lake and river repair retains clipping, flow and boundary attributes")
	profile.phase("cold_fixture_preparation", stamp, services, measurements.duplicate(true))
	all = []
	var full := embed(fixture)
	stamp = profile.stamp()
	var state := cache._save_layer(full.world, 144, 0, {})
	state = cache._save_layer(full.world, 144, 1, state)
	cache._save_layer(full.world, 144, 2, state)
	cache.save_artifact(full.world.seed_text, 144, "base", Surface.capture(full.base, "base"))
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	img.fill(Color("486c3d"))
	cache.save_view(full.world.seed_text, 144, {terrain = img, map = img, forest = img})
	# Rebuild the small footprint against the full-sized sampling grid, never a full-sized mesh.
	var terrain := {}
	for key: Vector2i in pieces: terrain[key] = TerrainBuilder.build_chunk(full.world, full.heights, key)
	var lake_chunks := {}
	var river_chunks := {}
	for key: Vector2i in water_chunks[0]: lake_chunks[key] = WaterBuilder.build_chunk(full.world, full.base, key, 0)
	for key: Vector2i in water_chunks[1]: river_chunks[key] = WaterBuilder.build_chunk(full.world, full.base, key, 1)
	cache.save_surface(full.world.seed_text, 144, {heights = Surface.capture(full.heights, "final"), trail = fixture.trail}, terrain, [lake_chunks, river_chunks])
	cache.wait_writes()
	profile.phase("cold_fixture_cache_write", stamp, services)
	_test_generations(cache, full, terrain, [lake_chunks, river_chunks], fixture.trail)
	await _test_prefetch(services, full)
	_test_cold(services, fixture, pieces, water_chunks)
	await scene_checks(services, full, terrain, [lake_chunks, river_chunks])
	full.clear()
	state.clear()
	cache.wait_writes()
	await process_frame
	await process_frame
	profile.phase("after_release", profile.stamp(), services)
	check(services.cpu_budget.snapshot().reserved_bytes == 0 and services.cpu_budget.snapshot().retained_bytes == 0, "scene/readers release shared reservations and cached values")
	profile.save("res://.godot/resource_pipeline_report.json")
	print("resource_pipeline: ", checks, " checks, failures=", fails, " measurements=", JSON.stringify(measurements))
	# Process-wide asset caches intentionally survive worlds; release them before renderer teardown.
	services.resource_profile = null
	services.terrain.reset()
	GameContext.scope.terrain.reset()
	preload("res://scripts/render/asset_catalog.gd")._catalog = null
	await process_frame
	await process_frame
	quit(1 if fails else 0)

func _test_queue(cache: WorldCache) -> void:
	var gate := Semaphore.new()
	var order: Array[int] = []
	cache._queue_job(func() -> void:
		gate.wait()
		order.append(1), 16)
	var start := Time.get_ticks_usec()
	cache._queue_job(func() -> void: order.append(2), 16)
	measurements.enqueue_ms = (Time.get_ticks_usec() - start) / 1000.0
	check(cache.queue_stats.peak_jobs >= 2, "producer queues the next snapshot while the writer is still busy")
	gate.post()
	cache.wait_writes()
	check(order == [1, 2] and cache._pending_bytes == 0, "one FIFO writer drains in order and releases estimated bytes")

func _test_budget() -> void:
	var budget := preload("res://scripts/core/cpu_cache_budget.gd").new()
	budget.limit = 128
	var a := preload("res://scripts/core/byte_lru.gd").new()
	var b := preload("res://scripts/core/byte_lru.gd").new()
	a.budget = budget
	b.budget = budget
	var bytes := PackedByteArray()
	bytes.resize(80)
	a.put("a", bytes)
	b.put("b", bytes)
	check(a.get_value("a") == null and b.get_value("b") != null and budget.snapshot().retained_bytes <= 128, "independent caches obey one global budget")
	budget.reserve(60)
	check(budget.snapshot().retained_bytes <= 68, "active jobs reserve headroom by evicting retired data")
	budget.release(60)
	b = null
	a = null
	check(budget.snapshot().retained_bytes == 0, "cache destruction releases its namespace")

func _test_fairness() -> void:
	var scheduler := WorldStreamCoordinator.new()
	scheduler.vegetation_budgeted = func(_x: float, _z: float, _force: bool, allow: bool) -> bool: return allow
	scheduler.terrain_update = func(_x: float, _z: float, _force: bool, allow: bool) -> bool: return allow
	scheduler.water_update = scheduler.terrain_update
	for frame in 9: scheduler.update(Vector3.ZERO)
	check(scheduler.stats.grants == [3, 3, 3], "continuous vegetation, terrain and water work each gets publication turns")

func _test_prefetch(services: ServiceScope, full: Dictionary) -> void:
	var surface := services.cache.load_artifact(full.world.seed_text, 144, "surface")
	var source := preload("res://scripts/render/chunk_source.gd").new()
	source.setup(services.cache, full.world, full.heights, 144, [surface.chunks] + surface.water_chunks, services.cpu_budget)
	for group in source.groups.size():
		for key: Vector2i in source.groups[group]: source.request(group - 1, key, float(key.length_squared()))
	check(source._queue.size() <= source.MAX_QUEUED, "terrain and both water layers share one bounded prefetch queue")
	source.poll()
	check(source._active.size() == 2, "read queue overlaps at most two independent block reads")
	while not source._active.is_empty() or not source._queue.is_empty():
		await process_frame
		source.poll()
	check(source.stats.reads <= source.MAX_QUEUED and source._reserved == 0, "prefetch drains and releases active-read reservations")
	source.close()

func _test_cold(services: ServiceScope, fixture: Dictionary, pieces: Dictionary, water: Array) -> void:
	var source := preload("res://scripts/render/chunk_source.gd").new()
	var groups: Array = [pieces.duplicate(true), water[0].duplicate(true), water[1].duplicate(true)]
	source.setup(services.cache, fixture.world, fixture.heights, 144, groups, services.cpu_budget)
	source.prewarm([Vector2(288, 288)], 200.0)
	source.finish_startup()
	var recipes := true
	for group: Dictionary in groups:
		for value: Variant in group.values(): recipes = recipes and value is Dictionary
	check(recipes, "cold mesh arrays are replaced by bounded-cache entries and local repair recipes")
	source._cpu.clear()
	var key: Vector2i = pieces.keys()[0]
	check(source.read(-1, key) == pieces[key], "evicted cold terrain can be rebuilt locally without a backing file")
	source.close()

func make_fixture(side: int) -> Dictionary:
	var w := WorldData.new()
	w.W = side
	w.H = side
	w.N = side * side
	w.seed_text = "resource-fixture"
	w.seed_num = WGRandom.hash_string(w.seed_text)
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var value: Variant = owner.get(property.name)
			if value is GridBuffer2D.Float32 or value is GridBuffer2D.Byte or value is GridBuffer2D.Int32: value.resize()
	w.biome.fill(Biomes.GRASS)
	w.dist_water.fill(100.0)
	w.lake_id.fill(-1)
	for z in side:
		for x in side:
			var at := z * side + x
			w.h[at] = (13.0 + 0.012 * z + 0.1 * sin(x * 0.2)) / GameConfig.HS
			w.elev[at] = w.h[at]
			w.filled[at] = w.h[at]
	# A lake and ribbon straddle a 64-cell mesh boundary.
	for z in range(72, 84):
		for x in range(60, 70):
			w.lake[z * side + x] = 1
			w.filled[z * side + x] = 16.0 / GameConfig.HS
	var routes := Fixture.definitions()
	var cross := TrailDefinition.new()
	cross.id = "boundary"
	cross.kind = "trail"
	cross.points = PackedVector2Array([Vector2(225, 200), Vector2(290, 200)])
	cross.surface = RoadSurface.DIRT
	routes.append(cross)
	check(TrailBuilder.append_routes(w, routes).is_empty(), "synthetic road/trail kit is admitted")
	var base := Heightfield.new(w, false)
	base.ribbons = [[{x = 240.0, z = 350.0, y = 16.0, w = 4.0, depth = 2.0, left = Vector3(240, 16, 354), right = Vector3(240, 16, 346), motion = Vector4(1, 0, 0.5, 0)},
		{x = 280.0, z = 350.0, y = 16.0, w = 4.0, depth = 2.0, left = Vector3(280, 16, 354), right = Vector3(280, 16, 346), motion = Vector4(1, 0, 0.5, 0)}]]
	base.index_ribbons()
	var h := base.copy()
	h.finish_paths()
	w.trail_plan = {version = StageTrailPlan.VERSION, state = "found", definition = StageTrailPlan.pack(routes[0]),
		routes = routes.map(func(d: TrailDefinition) -> Dictionary: return StageTrailPlan.pack(d))}
	var trail := StageTrailPlan.apply(h)
	check(trail.applied, "production StageTrailPlan applies the authored earthworks kit")
	h.add_decks([{key = "boundary_deck", half = 1.0, ax = 245.0, az = 345.0, ay = 17.0, bx = 270.0, bz = 345.0, by = 17.0}])
	return {world = w, heights = h, base = base, trail = trail}

func embed(fixture: Dictionary) -> Dictionary:
	var original: WorldData = fixture.world
	var w := WorldData.new()
	w.W = WorldGenerator.PLAN_SIZE
	w.H = w.W
	w.N = w.W * w.H
	w.seed_text = original.seed_text
	w.seed_num = original.seed_num
	for name: String in WorldCache.PER_CELL:
		var value: Variant = w.get(name)
		value.resize(w.N)
		w.set(name, value)
	w.h.fill(13.0 / GameConfig.HS)
	w.filled.fill(13.0 / GameConfig.HS)
	w.biome.fill(Biomes.GRASS)
	w.dist_water.fill(100.0)
	w.lake_id.fill(-1)
	for name: String in WorldCache.PER_CELL:
		var source: Variant = original.get(name)
		if source.size() != original.N: continue
		var target: Variant = w.get(name)
		for z in original.H:
			for x in original.W: target[z * w.W + x] = source[z * original.W + x]
		w.set(name, target)
	w.trails = original.trails.duplicate(true)
	w.trail_plan = original.trail_plan.duplicate(true)
	w.available_rect = Rect2i(0, 0, original.W, original.H)
	w.territory_center = Vector2i(72, 72)
	w.settlements = [SettlementData.new(72, 72)]
	w.CW = w.W / w.CS
	w.CH = w.H / w.CS
	w.chunks.resize(w.CW * w.CH)
	for k in w.chunks.size(): w.chunks[k] = PackedInt32Array()
	for i in 24:
		var x := 55.0 + (i % 6) * 6.0
		var z := 55.0 + (i / 6) * 7.0
		w.obj_x.append(x)
		w.obj_y.append(z)
		w.obj_k.append(Biomes.T_PINE if i % 2 == 0 else Biomes.T_OAK)
		w.obj_v.append(i % 4)
		w.obj_s.append(1.0)
		w.chunks[int(z / w.CS) * w.CW + int(x / w.CS)].append(i)
	w.obj_count = w.obj_x.size()
	var outputs := {world = w}
	for pair: Array in [["heights", fixture.heights, "final"], ["base", fixture.base, "base"]]:
		var source: Heightfield = pair[1]
		var snap := Surface.capture(source, pair[2])
		snap.width = w.W
		snap.height = w.H
		for name: String in ["hv", "hv_raw", "water_level"]:
			var values := PackedFloat32Array()
			values.resize(w.N)
			values.fill(-INF if name == "water_level" else 13.0)
			for z in original.H:
				for x in original.W: values[z * w.W + x] = source.get(name)[z * original.W + x]
			snap[name] = values
		var patches := {}
		for key: int in snap.patches: patches[int(key / original.W) * w.W + key % original.W] = snap.patches[key]
		snap.patches = patches
		outputs[pair[0]] = Surface.restore(w, snap, pair[2])
	return outputs

func _test_generations(cache: WorldCache, full: Dictionary, terrain: Dictionary, water: Array, trail: Dictionary) -> void:
	var seed_text: String = full.world.seed_text
	var old: Dictionary = cache.load_artifact(seed_text, 144, "surface")
	var pins: Array[String] = []
	for refs: Dictionary in [old.chunks] + old.water_chunks:
		for ref: Dictionary in refs.values(): pins.append(cache.dir.path_join(ref.file))
	WorldCache.pin_files(pins)
	for generation in 2:
		cache.save_surface(seed_text, 144, {heights = Surface.capture(full.heights, "final"), trail = trail}, terrain, water)
		cache.wait_writes()
	var pinned := true
	for path: String in pins: pinned = pinned and FileAccess.file_exists(path)
	check(pinned, "collection retains a generation held by an active reader")
	WorldCache.unpin_files(pins)
	var removed := cache.collect_chunks(seed_text, 144)
	check(removed > 0, "unreachable generation is collected after the reader releases it")
	var current: Dictionary = cache.load_artifact(seed_text, 144, "surface")
	var backup: Dictionary = cache._read(cache.artifact_path(seed_text, 144, "surface") + ".bak", cache.artifact_key(seed_text, 144, "surface"))
	var readable := true
	for snapshot: Dictionary in [current, backup]:
		for refs: Dictionary in [snapshot.chunks] + snapshot.water_chunks:
			for ref: Dictionary in refs.values(): readable = readable and FileAccess.file_exists(cache.dir.path_join(ref.file))
	check(readable, "current and backup manifests keep every reachable block")
	cache.take_io_timings()
	cache.collect_chunks(seed_text, 144)
	check(cache.take_io_timings().get("decompress_bytes", 0) == 0, "unchanged validated manifest roots do not decode physics again during collection")

func scene_checks(services: ServiceScope, full: Dictionary, terrain: Dictionary, water: Array) -> void:
	var cache := services.cache
	var saved_surface := cache.load_artifact(full.world.seed_text, 144, "surface")
	for refs: Dictionary in [saved_surface.chunks, saved_surface.water_chunks[1]]:
		var ref: Dictionary = refs.values()[0]
		Files.remove(cache.dir.path_join(ref.file))
		var bad := FileAccess.open(cache.dir.path_join(ref.file), FileAccess.WRITE)
		bad.store_buffer(PackedByteArray([0, 1, 2, 3]))
		bad.close()
	services.resource_profile = profile
	var loaded := WorldLoader.load_world(full.world.seed_text, 144, Callable(), services, false, Vector2(288, 288))
	check(loaded.surface_hit and loaded.trail.applied and loaded.chunk_source.stats.repairs == 2, "surface-hit loader repairs terrain and water before scene publication")
	var same := true
	for key: Vector2i in terrain: same = same and loaded.chunk_source.ready(-1, key) == terrain[key]
	for key: Vector2i in water[1]: same = same and loaded.chunk_source.ready(1, key) == water[1][key]
	check(same and loaded.heights.road_refinement.trail_elements_baked, "prewarmed geometry and bike-park earthworks equal the original result")
	# No outer generation in this stand; the real GameWorld lifecycle runs on the authored footprint.
	loaded.world.outer = null
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	var hud: Hud = shell.get_node("UI/Root/Hud")
	hud.get_parent().remove_child(hud)
	shell.free()
	root.add_child(hud)
	var spawn := PlayerState.spawn(loaded.world, loaded.heights)
	var saved := {player = {x = spawn.x, z = spawn.z, feet = spawn.feet, yaw = 0.0, pitch = 0.0, hour = 9.0},
		bike = {x = spawn.x, z = spawn.z, y = spawn.feet, heading = 0.0, riding = false}, visited = {},
		quest = preload("res://scripts/game/quests.gd").new().save_state(), goal = ""}
	var reads: int = loaded.chunk_source.stats.reads
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	root.add_child(game)
	game.start(loaded, hud, saved, services)
	game.set_paused(true)
	check(game.chunk_source.stats.reads == reads and game.terrain_stream.nodes.size() == terrain.size(), "real scene start creates nodes/uploads without synchronous disk reads or repairs")
	check(game.chunk_source.stats.upload_bytes > 0, "source records publication bytes and elapsed upload time")
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		game.camera.look_at_from_position(Vector3(288, 40, 370), Vector3(250, 15, 240))
		for frame in 30: await process_frame
		profile.frames.clear()
		var render_stamp: Dictionary = profile.stamp()
		for frame in 120: await process_frame
		profile.phase("fixed_view_render", render_stamp, services, {paused = true, vsync = false, rendering_method = RenderingServer.get_current_rendering_method()})
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://.godot/resource_pipeline_scene.png")
	var stamp: Dictionary = profile.stamp()
	game.free()
	hud.free()
	loaded = null
	await process_frame
	await process_frame
	profile.phase("scene_release", stamp, services)
	var again := WorldLoader.load_world(full.world.seed_text, 144, Callable(), services, false, Vector2(288, 288))
	check(again.surface_hit and again.chunk_source.stats.repairs == 0, "same-process reentry reads repaired immutable blocks without rebuilding")
	again.chunk_source.close()
	again = null
