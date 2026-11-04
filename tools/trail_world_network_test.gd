extends SceneTree
const Network := preload("res://scripts/trails/trail_world_network.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const Lab := preload("res://scripts/lab/trail_lab_builder.gd")
const Snapshot := preload("res://scripts/game/surface_snapshot.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 420 if "--game" in OS.get_cmdline_user_args() else 150)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

static func synthetic() -> WorldData:
	var w := WorldData.new()
	w.W = 192; w.H = 192; w.N = w.W * w.H
	w.seed_text = "network stand"; w.seed_num = 17027
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var value: Variant = owner.get(property.name)
			if value is GridBuffer2D.Float32 or value is GridBuffer2D.Byte or value is GridBuffer2D.Int32: value.resize()
	w.biome.fill(Biomes.GRASS); w.dist_water.fill(100); w.lake_id.fill(-1)
	for z in w.H:
		for x in w.W:
			var i := z * w.W + x
			w.h[i] = (30 + z * 0.25 + sin(x * 0.025) * 2) / GameConfig.HS
			w.elev[i] = w.h[i]; w.filled[i] = w.h[i]; w.slope[i] = 0.065
	w.base_heights = Heightfield.new(w, false)
	return w

static func same_surface(a: Heightfield, b: Heightfield) -> bool:
	if a.hv != b.hv:
		print("DIFF coarse heights"); return false
	if a.road_refinement.patches.size() != b.road_refinement.patches.size():
		print("DIFF patch count"); return false
	for key: int in a.road_refinement.patches:
		if not b.road_refinement.patches.has(key): return false
		for field in ["h", "uv", "surface", "road", "color"]:
			if a.road_refinement.patches[key][field] != b.road_refinement.patches[key][field]:
				print("DIFF patch ", key, " field ", field); return false
	return true

func run() -> void:
	if "--game" in OS.get_cmdline_user_args():
		await game_world()
		quit(1 if failures else 0)
		return
	var w := synthetic()
	var base := w.base_heights.copy()
	base.finish_paths()
	var facade_seed := Lab.seed
	var plan := Network.build(w, base, Rect2i(0, 0, w.W, w.H))
	plan.version = StageTrailPlan.VERSION
	w.trail_plan = plan
	print("NETWORK ", plan.stats)
	check(plan.state == "found", "completed routes are playable on the prepared synthetic world")
	check(plan.stats.accepted == plan.entries.size() and plan.routes.size() == plan.entries.size(), "only admitted routes are published")
	check(Lab.seed == facade_seed, "game generation does not mutate the lab facade")
	check(plan.stats.attempted <= plan.stats.survey.sites + plan.stats.park.lines, "each proposed site is attempted once")
	check(plan.stats.work_m <= Network.WORK_LIMIT + 3000.0 * Network.ADMIT_PASSES, "work is bounded by metres, not by a wall clock")
	var shortest := INF
	for entry: Dictionary in plan.entries: shortest = minf(shortest, entry.length)
	print("ROUTES ", plan.entries.size(), " total ", roundi(plan.stats.length_m), " m, shortest ", roundi(shortest), " m, ", plan.stats.total_ms, " ms")
	var repeated := synthetic()
	var repeated_surface := repeated.base_heights.copy()
	repeated_surface.finish_paths()
	var repeated_plan := Network.build(repeated, repeated_surface, Rect2i(0, 0, w.W, w.H))
	check(plan.routes == repeated_plan.routes and same_surface(base, repeated_surface), "repeat generation preserves definitions and every surface channel")
	if FileAccess.file_exists("res://.godot/network_before.gd"):
		var before_world := synthetic()
		var before_surface := before_world.base_heights.copy()
		before_surface.finish_paths()
		var before: Dictionary = load("res://.godot/network_before.gd").build(before_world, before_surface, Rect2i(0, 0, w.W, w.H), 120000)
		print("BEFORE ", before.stats)
		check(before.routes == plan.routes and same_surface(before_surface, base), "optimization preserves uncapped baseline routes and exact patches")
	w.generation.trail_surface = base
	var target := w.base_heights.copy()
	var searches := Network.surveys
	var report := StageTrailPlan.prepare(target)
	check(report.applied and report.errors.is_empty() and w.generation.trail_surface == null, "cold loader consumes the accepted surface")
	check(same_surface(base, target), "cold preparation hands off exact patches, materials and ground")
	var packed := Snapshot.capture(target, "final")
	var loaded := Snapshot.restore(w, packed, "final")
	check(loaded != null and same_surface(target, loaded), "normal final-surface snapshot retains the accepted result")
	var original := w.trails.duplicate(true)
	var replay := w.base_heights.copy()
	var replay_report := StageTrailPlan.prepare(replay)
	check(replay_report.applied and replay_report.errors.is_empty(), "missing derivative replays definitions without regeneration")
	check(Network.surveys == searches and w.trails == original, "replay neither surveys nor duplicates canonical paths")
	check(same_surface(target, replay), "replay reproduces the exact accepted surface")
	for record: Dictionary in plan.routes:
		var d := StageTrailPlan.unpack(record)
		check(d.sections == record.sections, "trail character survives serialization")
	var input = GI.from_world(w, target)
	check(input.validate().is_empty(), "shared game input is complete")
	var sampled := PackedFloat32Array()
	sampled.resize(w.N)
	for i in w.N: sampled[i] = target.ground_at((i % w.W + 0.5) * GameConfig.TILE, (i / w.W + 0.5) * GameConfig.TILE)
	check(input.heights == sampled, "bulk input matches ground_at at every cell including patches and clamped edges")
	var corner := Vector2i(19, 23)
	var side := Vector2i(47, 38)
	var window = input.window(corner, side)
	var crop_matches := true
	for key in ["heights", "water", "rivers", "forbidden"]:
		for z in side.y:
			for x in side.x: crop_matches = crop_matches and window.get(key)[z * side.x + x] == input.get(key)[(corner.y + z) * w.W + corner.x + x]
	check(crop_matches, "window row slices preserve all four source arrays exactly")
	if not plan.routes.is_empty():
		var first := StageTrailPlan.unpack(plan.routes[0])
		check(input.window(Vector2i.ZERO, Vector2i(w.W, w.H)).blocked(first.points[0]), "published paths remain protected for subsequent construction")
	var rejected_world := synthetic()
	var empty := Network.build(rejected_world, rejected_world.base_heights.copy(), Rect2i(0, 0, w.W, w.H), {probe_budget = 0})
	check(empty.state == "none" and rejected_world.trails.is_empty(), "zero work budget publishes no incomplete paths")
	print("trail_world_network: ", failures, " failures")
	quit(1 if failures else 0)

## Explicit test-fixture import: old schema keys are accepted ONLY here, not by the game cache.
## Prefer the saved pre-network places backup; nature's path records must not reintroduce old trails.
func fixture_world(cache: WorldCache, seed: String) -> WorldData:
	var data := {}
	for layer in WorldGenerator.LAYERS.size():
		var path := cache.path_for(seed, WorldGenerator.START_SIZE, layer)
		if layer == 1 and FileAccess.file_exists(path + ".bak"):
			var backup: Variant = cache._read(path + ".bak", cache._cache_header_key(path + ".bak"))
			if backup is Dictionary and backup.get("trail_plan", {}).get("routes", []).is_empty(): path += ".bak"
		var part: Variant = cache._read(path, cache._cache_header_key(path))
		if not part is Dictionary: return null
		if layer == 2:
			part.erase("trails")
			part.erase("road_surface")
		data.merge(part, true)
	return cache._restore(data, true)

func game_world() -> void:
	var seed := "Север-1234"
	var cache := GameContext.scope.cache
	cache.dir = "res://tools/control/runs/network_game_cache"
	cache.enabled = true
	var existing := "--existing" in OS.get_cmdline_user_args()
	if not existing: cache.remove_seed(seed)
	var searches := Network.surveys
	var progress := func(_p: float, label: String) -> void: print("GAME ", label)
	var reference: Heightfield
	if existing:
		# Reuse the first run's complete world. No calls to WorldGenerator on this path.
		var w := fixture_world(cache, seed)
		check(w != null, "existing real-world fixture is available")
		if w == null: return
		check(w.trail_plan.get("routes", []).is_empty(), "fixture has no previously admitted network")
		if not w.trail_plan.get("routes", []).is_empty(): return
		reference = Snapshot.restore(w, cache.load_artifact(seed, WorldGenerator.START_SIZE, "base"), "base")
		check(reference != null, "existing geographic surface restores without regeneration")
		if reference == null: return
		reference.finish_paths()
		w.trail_plan = Network.build(w, reference, w.available_rect)
		w.trail_plan.version = StageTrailPlan.VERSION
		print("EXISTING NETWORK ", w.trail_plan.stats)
		check(w.trail_plan.state == "found", "existing world receives admitted tracks")
		if w.trail_plan.state != "found": return
		# Only dependent nature and cache records change when paths change.
		StageVegetation.run(w)
		w.clear_noise_fields()
		cache._save_layer(w, WorldGenerator.START_SIZE, 1, {})
		cache._save_layer(w, WorldGenerator.START_SIZE, 2, {})
		cache.wait_writes()
		for path in [cache.path_for(seed, WorldGenerator.START_SIZE, WorldGenerator.LAYERS.size()), cache.artifact_path(seed, WorldGenerator.START_SIZE, "surface")]:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var a := WorldLoader.load_world(seed, WorldGenerator.START_SIZE, progress)
	cache.wait_writes()
	check(a.error.is_empty(), "main loader accepts the world: " + a.error)
	if not a.error.is_empty(): return
	check(Network.surveys == searches + 1, "one survey of the real world")
	if reference != null: check(same_surface(reference, a.heights), "cached definitions reproduce the newly admitted real-world surface")
	check(a.world.trail_plan.state == "found", "main game has admitted tracks")
	print("GAME NETWORK ", a.world.trail_plan.stats)
	print("GAME STAGES ", JSON.stringify(a.world.generation_profile.get("stages_ms", {})))
	print("COLD LOAD ", JSON.stringify(a.timings))
	check(preload("res://tools/selftest.gd").settlement_network_valid(a.world), "real game world advertises only valid settlement connections")
	print("GAME ROUTES ", a.world.trail_plan.get("entries", []).map(func(entry: Dictionary) -> Dictionary:
		return {style = entry.style, length = entry.length, elements = entry.elements, earthworks = entry.earthworks}))
	a.chunk_source.close()
	var b := WorldLoader.load_world(seed, WorldGenerator.START_SIZE)
	check(b.error.is_empty() and b.surface_hit and b.from_cache, "warm load restores the final surface from disk")
	print("WARM LOAD ", JSON.stringify(b.timings))
	check(a.world.trail_plan == b.world.trail_plan and same_surface(a.heights, b.heights), "warm load preserves definitions, terrain and materials exactly")
	b.chunk_source.close()
	# Remove only the derivative manifest, preserving all canonical layers and geography.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cache.artifact_path(seed, WorldGenerator.START_SIZE, "surface")))
	var c := WorldLoader.load_world(seed, WorldGenerator.START_SIZE)
	check(c.error.is_empty() and c.from_cache and not c.surface_hit, "missing surface rebuilds from cached world definitions")
	print("REPLAY LOAD ", JSON.stringify(c.timings))
	check(Network.surveys == searches + 1, "both cache paths skip discovery and world regeneration")
	check(same_surface(a.heights, c.heights), "rebuilt real-world surface equals the originally accepted surface")
	if not c.error.is_empty(): return
	# Real game scene and real main HUD, with the menu script disabled: no second background world.
	var shell := load("res://scenes/main.tscn").instantiate() as Node
	shell.set_script(null)
	root.add_child(shell)
	var hud := shell.get_node("UI/Root/Hud") as Hud
	var game := load("res://scenes/game_world.tscn").instantiate() as GameWorld
	root.add_child(game)
	game.start(c, hud)
	game.set_process(false)
	game.set_physics_process(false)
	check(game.world == c.world and game.heights == c.heights, "GameWorld uses the admitted world and physics terrain")
	check(hud.trail_places().size() == c.world.trail_plan.routes.size(), "all track starts are available on the game map")
	if not c.world.trail_plan.routes.is_empty():
		var d := StageTrailPlan.unpack(c.world.trail_plan.routes[0])
		var trees := 0
		for i in c.world.obj_count:
			var at := Vector2(c.world.obj_x[i], c.world.obj_y[i]) * GameConfig.TILE
			if d.nearest(at, d.width * 0.5 + 1.0).z < d.width * 0.5: trees += 1
		check(trees == 0, "nature generation leaves the accepted tread clear")
		game._finish_opening()
		var at := d.point_at(2.0)
		game.player.x = at.x; game.player.z = at.y
		game.player.feet = c.heights.surface_at(at.x, at.y, -INF)
		game.player.on_ground = true
		game.stream_coordinator.force_terrain(Vector3(at.x, game.player.feet, at.y), GameWorld.NEAR)
		game.stream_coordinator.force_vegetation(Vector3(at.x, game.player.feet, at.y))
		game.heights.obstacles.update(at.x, at.y, game.vegetation.obstacles, game.vegetation.obstacles_version, true)
		game.bike.x = at.x; game.bike.z = at.y; game.bike.y = game.player.feet
		game.bike.heading = d.heading_at(2.0)
		game.bike.mount(game.player)
		game.bike.speed = 3.0
		var advanced := 0.0
		var crashed := false
		for tick in 180:
			var here := Vector2(game.bike.x, game.bike.z)
			var near := d.nearest(here)
			advanced = maxf(advanced, near.x)
			var forward := d.point_at(near.x + 6) - here
			var steer := clampf(-wrapf(atan2(-forward.x, -forward.y) - game.bike.heading, -PI, PI) * 2, -1, 1)
			game.bike.step(game.player, 0.5 if game.bike.speed < 4 else -0.3, steer, false, false, 1.0 / 60.0, c.world, c.heights)
			if game.bike.crashed: crashed = true; break
		check(not crashed and advanced > 6, "real BikeRide starts moving on the track without a fall (%.1f m)" % advanced)
	await process_frame
	game.queue_free()
	shell.queue_free()
	await process_frame
	cache.wait_writes()
	print("trail_world_network game: ", failures, " failures")
