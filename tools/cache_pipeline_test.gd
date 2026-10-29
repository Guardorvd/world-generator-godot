extends SceneTree
## Isolated cache/storage/surface lifecycle. Synthetic fields and the existing flat trail fixture;
## never calls world generation, trail search or a full game scene.
const Files := preload("res://scripts/core/cache_file.gd")
const Surface := preload("res://scripts/game/surface_snapshot.gd")
const Fixture := preload("res://tools/trail_lab_fixture.gd")
const ROOT := "res://.godot/cache_pipeline_test"
var fails := 0
var checks := 0

class RefreshTerrain extends OuterTerrain:
	var refreshes := 0
	func refresh(_rect: Rect2i) -> void: refreshes += 1

class RefreshPlants extends VegetationLayer:
	var refreshes := 0
	func refresh(_rect: Rect2i) -> void: refreshes += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	fails += int(not ok)
	print("cache_pipeline: ", "OK " if ok else "FAIL ", label)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ROOT)
	var cache := WorldCache.new()
	cache.dir = ROOT.path_join("world")
	cache.enabled = true
	var path := cache.dir.path_join("protocol.wgc")
	cache._write(path, "test", var_to_bytes({value = 1}))
	cache._write(path, "test", var_to_bytes({value = 2}))
	check(cache._read(path, "test").value == 2, "new primary is readable")
	DirAccess.rename_absolute(path, path + ".interrupted")
	check(cache._read(path, "test").value == 1, "interruption after rotation retains readable backup")
	DirAccess.rename_absolute(path + ".interrupted", path)
	var broken := FileAccess.open(path, FileAccess.WRITE)
	broken.store_buffer(PackedByteArray([0, 1, 2, 3]))
	broken.close()
	check(cache._read(path, "test").value == 1, "corrupt primary falls back to validated backup")
	cache._queue_write(path, "test", {value = 3})
	cache._queue_write(path, "test", {value = 4})
	cache.wait_writes()
	check(cache._read(path, "test").value == 4, "two requests for the same key publish in request order")
	check(cache._read_file(path + ".bak", "test").value == 3, "valid recovery generation survives replacing a corrupt primary")
	var routes := Fixture.definitions()
	var prepared := Fixture.prepare(routes, true)
	check(prepared.errors.is_empty(), "flat authored trail fixture builds")
	var h: Heightfield = prepared.heights
	h.add_decks([{key = "cache_deck", half = 1.0, ax = 16.0, az = 16.0, ay = 18.0, bx = 28.0, bz = 16.0, by = 18.0}])
	# A narrow wet ribbon and a lake exercise exactly the sampling indexes rebuilt on restore.
	h.ribbons = [[{x = 8.0, z = 8.0, y = 17.0, w = 1.0, depth = 2.0, left = Vector3(8, 17, 9), right = Vector3(8, 17, 7)},
		{x = 20.0, z = 8.0, y = 17.0, w = 1.0, depth = 2.0, left = Vector3(20, 17, 9), right = Vector3(20, 17, 7)}]]
	h.index_ribbons()
	var snapshot := Surface.capture(h, "final")
	var restored := Surface.restore(h.world, bytes_to_var(var_to_bytes(snapshot)), "final")
	check(restored != null, "final surface restores without native objects")
	if restored == null:
		quit(1)
		return
	var same := true
	for z in range(4, 245, 3):
		for x in range(4, 245, 3):
			same = same and h.ground_at(x, z) == restored.ground_at(x, z) and h.depth_at(x, z) == restored.depth_at(x, z)
	check(same and h.structures == restored.structures and h._deck_keys == restored._deck_keys, "ground, water, decks and structures match exactly")
	check(h.road_refinement.patches == restored.road_refinement.patches and restored.road_refinement.trail_elements_baked, "all road/trail attributes and bake guard survive")
	var before := var_to_bytes(restored.road_refinement.patches)
	check(not TrailBuilder.bake_elements(restored, routes).is_empty() and before == var_to_bytes(restored.road_refinement.patches), "restored earthworks reject double apply")
	var invalid := snapshot.duplicate(true)
	invalid.hv.resize(1)
	check(Surface.restore(h.world, invalid, "final") == null and Surface.restore(h.world, snapshot, "base") == null, "invalid sizes and wrong readiness stage are rejected")
	var base := Heightfield.new(h.world, false)
	check(Surface.restore(h.world, Surface.capture(base, "base"), "base") != null, "base surface restores independently from roads")
	var arrays := TerrainBuilder.build_arrays(h.world, h)
	# build_arrays already applies refinement when the supplied surface is final.
	var pieces := PlanTerrain.partition(arrays)
	var water := WaterBuilder.prepare(h.world, h)
	var water_pieces := [WaterBuilder.partition_arrays(water[0]), WaterBuilder.partition_arrays(water[1])]
	cache.save_surface("fixture", 64, {heights = snapshot, trail = {state = "none", applied = false, errors = PackedStringArray()}}, pieces, water_pieces)
	cache.wait_writes()
	var saved := cache.load_artifact("fixture", 64, "surface")
	var stream := PlanTerrain.new()
	stream.setup(saved.chunks, StandardMaterial3D.new(), cache, h.world, restored)
	var chunks_equal := true
	for key: Vector2i in pieces: chunks_equal = chunks_equal and stream._read_arrays(key) == pieces[key]
	check(chunks_equal, "disk chunks preserve every vertex attribute and boundary")
	var water_equal := true
	for layer in 2:
		stream.water_layer = layer
		stream.chunks = saved.water_chunks[layer]
		for key: Vector2i in water_pieces[layer]: water_equal = water_equal and stream._read_arrays(key) == water_pieces[layer][key]
	check(water_equal and not water_pieces[1].is_empty(), "lazy water chunks preserve flow, normals, shore UVs and triangles")
	stream.water_layer = -1
	stream.chunks = saved.chunks
	var first: Vector2i = pieces.keys()[0]
	Files.remove(cache.dir.path_join(saved.chunks[first].file))
	check(stream._read_arrays(first) == pieces[first], "missing derivative chunk rebuilds from final surface without regeneration")
	stream.free()
	var lru := preload("res://scripts/core/byte_lru.gd").new()
	lru.limit = 24
	lru.put("a", PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
	lru.put("b", PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
	lru.get_value("a")
	lru.put("c", PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9]))
	check(lru.get_value("b") == null and lru.get_value("a") != null and lru.bytes <= lru.limit, "byte LRU respects recency and memory budget")
	await _test_regions()
	_test_world(cache)
	cache.wait_writes()
	await finish_suite(cache)

func finish_suite(_cache: WorldCache) -> void:
	print("cache_pipeline: ", checks, " checks, failures=", fails)
	quit(1 if fails else 0)

func _test_regions() -> void:
	var dir := ROOT.path_join("regions")
	var key := Vector2i(3, 0)
	var rect := Rect2i(key * 2, Vector2i(2, 2))
	var fields := {h = PackedFloat32Array([1, 2, 3, 4]), water_level = PackedFloat32Array([-INF, -INF, -INF, -INF]), biome = PackedByteArray([1, 1, 1, 1])}
	var current := {regions = {key: {rect = rect, fields = fields, decor = {settlements = [], bridges = [], trails = []}}}, settlements = []}
	check(RegionStream.save(dir, current, key) == OK, "region generation commits")
	var previous: Dictionary = RegionStream._read(dir.path_join("ledger.bin"))
	var old_ref: Dictionary = previous.ledger.regions[key]
	fields = fields.duplicate(true)
	fields.h[0] = 9.0
	# Simulate a newly written block whose ledger has not committed.
	RegionStream._write(dir.path_join("uncommitted.region"), {format = RegionStream.FORMAT, rect = rect, fields = fields})
	check(RegionStream._read_fields(dir, key, old_ref).h[0] == 1.0, "orphan new block cannot change the committed region")
	current.regions[key].fields = fields
	check(RegionStream.save(dir, current, key) == OK, "next region generation commits")
	DirAccess.rename_absolute(dir.path_join("ledger.bin"), dir.path_join("ledger.interrupted"))
	var recovered: Dictionary = RegionStream._read(dir.path_join("ledger.bin"))
	check(RegionStream._read_fields(dir, key, recovered.ledger.regions[key]).h[0] == 1.0, "interrupted ledger replacement restores a matching previous block")
	DirAccess.rename_absolute(dir.path_join("ledger.interrupted"), dir.path_join("ledger.bin"))
	check(RegionStream._read_fields(dir, key, RegionStream._read(dir.path_join("ledger.bin")).ledger.regions[key]).h[0] == 9.0, "current ledger references current immutable block")
	var legacy := dir.path_join("legacy.region")
	var file := FileAccess.open_compressed(legacy, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	file.store_var({format = RegionStream.FORMAT, rect = rect, fields = fields})
	file.close()
	check(RegionStream._read(legacy).fields == fields, "legacy compressed regions remain readable")
	var streaming := RegionStream.new()
	streaming.world = WorldData.new()
	streaming.world.outer = OuterLand.new()
	streaming.ledger = RegionStream._read(dir.path_join("ledger.bin")).ledger
	var test_terrain := RefreshTerrain.new()
	var test_plants := RefreshPlants.new()
	streaming.terrain = test_terrain
	streaming.vegetation = test_plants
	# Pin the test directory through the normal root/world identifier API.
	var old_root := RegionStream.root
	RegionStream.root = ROOT
	streaming.world.region_basis_id = "regions"
	streaming.world.region_store_leaf = "regions"
	streaming._request_fields(key)
	check(not streaming.ledger.regions[key].has("fields") and streaming._field_task != -1, "request schedules disk read without publishing in the caller")
	while not WorkerThreadPool.is_task_completed(streaming._field_task): await process_frame
	streaming.update(0, 0)
	check(streaming.ledger.regions[key].fields.h[0] == 9.0 and test_terrain.refreshes == 1 and test_plants.refreshes == 1, "async completion publishes fields and invalidates the terrain/plant halo")
	streaming._evict(key)
	var ref: Dictionary = streaming.ledger.regions[key]
	var block := dir.path_join(ref.field_file)
	DirAccess.rename_absolute(block, block + ".test_hidden")
	streaming._request_fields(key)
	while not WorkerThreadPool.is_task_completed(streaming._field_task): await process_frame
	streaming.update(0, 0)
	check(streaming.ledger.regions[key].fields.h[0] == 9.0 and streaming._field_bytes <= RegionStream.FIELD_CACHE_BYTES, "return to a retired region uses bounded RAM cache with disk unavailable")
	DirAccess.rename_absolute(block + ".test_hidden", block)
	var good_bytes := FileAccess.get_file_as_bytes(block)
	Files.replace(block, good_bytes)
	var corrupt := FileAccess.open(block, FileAccess.WRITE)
	corrupt.store_buffer(PackedByteArray([0, 1, 2, 3]))
	corrupt.close()
	check(RegionStream._read_fields(dir, key, ref).h[0] == 9.0, "region block backup is validated against the ledger digest when primary is corrupt")
	Files.replace(block, good_bytes, true)
	streaming.finish()
	streaming.free()
	test_terrain.free()
	test_plants.free()
	RegionStream.root = old_root

func _test_world(cache: WorldCache) -> void:
	var w := WorldData.new()
	w.W = WorldGenerator.PLAN_SIZE
	w.H = w.W
	w.N = w.W * w.H
	w.seed_text = "cache synthetic"
	w.seed_num = WGRandom.hash_string(w.seed_text)
	for field: String in WorldCache.PER_CELL:
		var value: Variant = w.get(field)
		value.resize(w.N)
		w.set(field, value)
	w.h.fill(0.05)
	w.filled.fill(0.05)
	w.trail_plan = {version = StageTrailPlan.VERSION, state = "none"}
	w.generation_profile = {stages_ms = {historic = 999999}}
	var prev := cache._save_layer(w, w.W, 0, {})
	w.trails = [{kind = "trail", pts = [{x = 2.0, y = 2.0, w = 0.4}, {x = 4.0, y = 2.0, w = 0.4}], surf = PackedByteArray([0, 0])}]
	prev = cache._save_layer(w, w.W, 1, prev)
	w.trails[0].pts[0].w = 0.7
	w.trails[0].surf[0] = RoadSurface.DIRT
	check(prev.trails[0].pts[0].w == 0.4 and prev.trails[0].surf[0] == 0, "layer snapshot is independent of nested mutations in the next stage")
	cache._save_layer(w, w.W, 2, prev)
	var img := Image.create(2, 2, false, Image.FORMAT_RGB8)
	cache.save_view(w.seed_text, w.W, {terrain = img, map = img, forest = img})
	var h := Heightfield.new()
	h.world = w
	h.hv.resize(w.N)
	h.hv.fill(13.0)
	h.hv_raw = h.hv
	h.water_level.resize(w.N)
	h.water_level.fill(-INF)
	h.road_refinement = RoadRefinement.from_patches({}, w.H)
	var a := WaterBuilder._arrays(PackedVector3Array([Vector3(2, 13, 2), Vector3(6, 13, 2), Vector3(2, 13, 6)]), PackedInt32Array([0, 1, 2]))
	cache.save_surface(w.seed_text, w.W, {heights = Surface.capture(h, "final"), water = [[], []], trail = {state = "none", applied = false, errors = PackedStringArray()}}, {Vector2i.ZERO: a})
	cache.wait_writes()
	var canonical: Dictionary = cache._load(w.seed_text, w.W)
	check(canonical.layers == 3 and canonical.world.trails[0].pts[0].w == 0.7 and canonical.world.trails[0].surf[0] == RoadSurface.DIRT, "explicit layer writers retain nested point/surface changes")
	var services := ServiceScope.new()
	services.cache = cache
	cache.io_timings["previous_load_marker"] = 1
	var loaded := WorldLoader.load_world(w.seed_text, w.W, Callable(), services)
	check(loaded.error.is_empty() and loaded.surface_hit and loaded.from_cache, "production WorldLoader hits synthetic canonical/view/surface cache")
	check(not loaded.timings.has("prepare_mesh_ms") and loaded.timings.finish_paths_ms < 1.0 and loaded.heights.hv == h.hv, "warm load skips terrain build, roads and trail apply")
	check(loaded.timings.profile_origin == "stored_generation" and loaded.timings.has("cache_io"), "current IO metrics are separate from historical generation profile")
	check(not loaded.timings.cache_io.has("previous_load_marker"), "IO counters from earlier loads/installations do not enter the current report")
	var passport := cache.describe_artifacts(w.seed_text, w.W)
	check(passport.size() == 6 and passport[5].header_matches and passport[5].bytes > 0, "artifact passport reports actual file bytes and readiness headers")
	var geo := cache.path_for(w.seed_text, w.W, 0)
	var bundled := ROOT.path_join("bundled")
	DirAccess.make_dir_recursive_absolute(bundled)
	var place := cache.path_for(w.seed_text, w.W, 1)
	var old_key := "obsolete-schema"
	cache._write(bundled.path_join(geo.get_file()), old_key, var_to_bytes({old = true}))
	var manifest := {format = WorldCache.FORMAT, files = [{name = geo.get_file(), seed = w.seed_text, size = w.W, layer = 0, key = old_key,
		sha256 = Util.sha256(FileAccess.get_file_as_bytes(bundled.path_join(geo.get_file()))).hex_encode()}]}
	var mf := FileAccess.open(bundled.path_join("manifest.json"), FileAccess.WRITE)
	mf.store_string(JSON.stringify(manifest))
	mf.close()
	var geo_bytes := FileAccess.get_file_as_bytes(geo)
	cache.install_bundled(bundled)
	check(FileAccess.get_file_as_bytes(geo) == geo_bytes, "obsolete bundled never replaces current user geography")
	var geo_key := cache._key(w.seed_text, w.W, 0)
	cache._write(bundled.path_join(geo.get_file()), geo_key, var_to_bytes(cache._read(geo, geo_key)))
	manifest.files[0].key = geo_key
	manifest.files[0].sha256 = Util.sha256(FileAccess.get_file_as_bytes(bundled.path_join(geo.get_file()))).hex_encode()
	var surface_path := cache.artifact_path(w.seed_text, w.W, "surface")
	var surface_key := cache.artifact_key(w.seed_text, w.W, "surface")
	var surface: Dictionary = cache.load_artifact(w.seed_text, w.W, "surface")
	Files.replace(bundled.path_join(surface_path.get_file()), FileAccess.get_file_as_bytes(surface_path))
	for ref: Dictionary in surface.chunks.values():
		Files.replace(bundled.path_join(ref.file), FileAccess.get_file_as_bytes(cache.dir.path_join(ref.file)))
	manifest.artifacts = [{artifact = "surface", name = surface_path.get_file(), seed = w.seed_text, size = w.W, key = surface_key,
		sha256 = Util.sha256(FileAccess.get_file_as_bytes(surface_path)).hex_encode()}]
	mf = FileAccess.open(bundled.path_join("manifest.json"), FileAccess.WRITE)
	mf.store_string(JSON.stringify(manifest))
	mf.close()
	var target := WorldCache.new()
	target.dir = ROOT.path_join("bundle_target")
	target.invalidate_from(w.seed_text, w.W, 0)
	target.install_bundled(bundled)
	var installed := target.load_artifact(w.seed_text, w.W, "surface")
	var all_blocks := not installed.is_empty()
	if all_blocks:
		for ref: Dictionary in installed.chunks.values(): all_blocks = all_blocks and target._read(target.dir.path_join(ref.file), ref.key) != null
	check(target._load(w.seed_text, w.W).layers == 1 and all_blocks, "compatible bundled geography and complete derived block set install into an empty cache")
	var current_user := FileAccess.get_file_as_bytes(geo)
	cache.install_bundled(bundled)
	check(FileAccess.get_file_as_bytes(geo) == current_user, "compatible bundled leaves the valid user layer untouched")
	# A same-length but different valid PNG must remain the user's preview.
	var preview_image := Image.create(WorldCache.PREVIEW_SIZE, WorldCache.PREVIEW_SIZE, false, Image.FORMAT_RGB8)
	preview_image.fill(Color.RED)
	var preview_name := cache._base(w.seed_text, WorldGenerator.START_SIZE) + ".preview"
	preview_image.save_png(bundled.path_join(preview_name))
	manifest.files = []
	manifest.previews = [{name = preview_name, sha256 = Util.sha256(FileAccess.get_file_as_bytes(bundled.path_join(preview_name))).hex_encode()}]
	mf = FileAccess.open(bundled.path_join("manifest.json"), FileAccess.WRITE)
	mf.store_string(JSON.stringify(manifest))
	mf.close()
	var preview_path := cache.dir.path_join(preview_name + ".png")
	preview_image.fill(Color.BLUE)
	preview_image.save_png(preview_path)
	var user_preview := FileAccess.get_file_as_bytes(preview_path)
	cache.install_bundled(bundled)
	check(FileAccess.get_file_as_bytes(preview_path) == user_preview, "valid user preview is preserved independently of bundled content")
	cache.invalidate_from(w.seed_text, w.W, 1)
	check(FileAccess.file_exists(geo) and not FileAccess.file_exists(place) and cache._load(w.seed_text, w.W).layers == 1, "local plan invalidation preserves readable geography")
	var id := RegionStream.store_dir(w)
	check(id == RegionStream.store_dir(w) and not w.region_basis_id.is_empty(), "region basis identifier is cached on the world")
