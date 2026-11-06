extends "res://tools/control/check.gd"
## One cold 768x768 game run; screenshots, trail/water diagnostics, no FPS.
const Saves := preload("res://scripts/game/save_game.gd")
var review := {checks = [], routes = [], bike_starts = []}
var review_done := false
var timings_saved := false

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 420)
	GameContext.scope.settings.settings_path = "res://.godot/full_water_review_settings.cfg"
	GameContext.scope.cache.dir = "res://.godot/full_water_review_cache"
	Saves.dir = "res://.godot/full_water_review_saves"
	RegionStream.root = "res://.godot/full_water_review_regions"
	super._initialize()
	want_fps = false
	check_review(not QuickTrails.active(), "ordinary full trail network, no quick mode")

func check_review(ok: bool, label: String) -> void:
	review.checks.append({ok = ok, label = label})
	print("PASS " if ok else "FAIL ", label)
	if not ok: failed = true

func _process(delta: float) -> bool:
	var was := phase
	if was == "loading" and not timings_saved and main.game != null and main.game.player != null:
		timings_saved = true
		review.wall_load_s = (Time.get_ticks_msec() - started) / 1000.0
		review.load_ms = main.game.load_timings.duplicate(true)
		review.generation_profile = main.game.world.generation_profile.duplicate(true)
		review.status = "game_loaded_before_audit"
		Dev.save_json(out.path_join("timings_checkpoint.json"), review)
	var returned := super._process(delta)
	if was == "loading" and phase == "shots" and not review_done:
		review_done = true
		inspect_game(main.game)
		if not shots.is_empty(): _place(main.game, shots[0])
	return returned

func inspect_game(game: GameWorld) -> void:
	var begin := Time.get_ticks_msec()
	var w := game.world
	var h := game.heights
	review.seed = w.seed_text
	review.size = w.W
	review.world = Dev.world_stats(w, true)
	review.network = w.trail_plan.get("stats", {})
	review.biomes = {}
	review.land_biomes = {}
	for i in w.N:
		var name: String = Biomes.LIST[w.biome[i]].name
		review.biomes[name] = review.biomes.get(name, 0) + 1
		if w.ocean[i] == 0 and w.lake[i] == 0:
			review.land_biomes[name] = review.land_biomes.get(name, 0) + 1
	var named_lakes := w.lakes.size()
	StageLakes.run(w)
	review.named_lakes = w.lakes.size()
	check_review(named_lakes == w.lakes.size(), "lake naming is stable in the loaded game")
	var seen := PackedByteArray()
	seen.resize(w.N)
	review.lakes = []
	var start := w.lake.find(1)
	while start >= 0:
		if seen[start] == 0:
			var cells := PackedInt32Array([start])
			seen[start] = 1
			var head := 0
			var flat := true
			var deepest := start
			while head < cells.size():
				var c := cells[head]
				head += 1
				flat = flat and w.filled[c] == w.filled[start]
				if w.h[c] < w.h[deepest]: deepest = c
				for k in 8:
					var n: int = c + Grid.DY[k] * w.W + Grid.DX[k]
					if n >= 0 and n < w.N and absi(n % w.W - c % w.W) <= 1 and w.lake[n] != 0 and seen[n] == 0:
						seen[n] = 1
						cells.append(n)
			var p := Vector2((deepest % w.W + 0.5) * GameConfig.TILE, (deepest / w.W + 0.5) * GameConfig.TILE)
			review.lakes.append({cells = cells.size(), area_m2 = cells.size() * GameConfig.TILE * GameConfig.TILE,
				level_m = w.filled[start] * GameConfig.HS - GameConfig.LAKE_DROP, depth_m = h.depth_at(p.x, p.y), flat = flat})
			check_review(flat, "lake %d has one water level" % review.lakes.size())
			if review.lakes.size() == 1:
				add_view("lake", Dev._look_from(h, Vector3(p.x, h.ground_at(p.x, p.y), p.y), 55.0, 16.0, 14.0), Vector3(p.x, w.filled[start] * GameConfig.HS, p.y))
		start = w.lake.find(1, start + 1)
	check_review(review.lakes.size() <= 2 and w.rivers.is_empty(), "at most two real lakes and no stream network")
	check_review(preload("res://tools/selftest.gd").settlement_network_valid(w), "settlement road network is valid")
	check_review(StageTrailPlan.consistency_errors(w).is_empty(), "loaded bicycle trail definitions are consistent")
	check_review(w.trail_plan.get("state") == "found", "full game has accepted bicycle routes")
	var definitions: Array[TrailDefinition] = []
	for record: Dictionary in w.trail_plan.get("routes", []):
		var d := StageTrailPlan.unpack(record)
		definitions.append(d)
		var length := d.route_length()
		var up := 0.0
		var down := 0.0
		var worst := 0.0
		var wet := 0
		var grades := PackedFloat32Array()
		var previous := INF
		var samples := ceili(length / 3.0)
		for k in samples + 1:
			var at := d.point_at(minf(length, k * 3.0))
			var level := h.surface_at(at.x, at.y, -INF)
			if not is_finite(level): continue
			if previous != INF:
				var dh := level - previous
				up += maxf(0, dh)
				down += maxf(0, -dh)
				var grade := absf(dh) / 3.0
				worst = maxf(worst, grade)
				grades.append(grade)
			previous = level
			if h.depth_at(at.x, at.y) > 0.3: wet += 1
		grades.sort()
		var elements := {}
		for e: TrailElement in d.elements:
			var key: String = TrailElement.Profile.keys()[e.profile]
			elements[key] = elements.get(key, 0) + 1
		review.routes.append({id = d.id, title = d.title, length_m = length, width_m = d.width,
			ascent_m = up, descent_m = down, max_grade_percent = worst * 100,
			p95_grade_percent = grades[int(grades.size() * 0.95)] * 100 if not grades.is_empty() else 0,
			deep_water_samples = wet, elements = elements, sections = d.sections})
	definitions.sort_custom(func(a: TrailDefinition, b: TrailDefinition) -> bool: return a.route_length() > b.route_length())
	if not definitions.is_empty():
		var selected: Array[int] = [0, definitions.size() / 2, definitions.size() - 1]
		var used := {}
		for index in selected:
			if used.has(index): continue
			used[index] = true
			var d := definitions[index]
			var station := minf(d.route_length() * 0.35, 100.0)
			var p := d.point_at(station)
			var q := d.point_at(station + 10.0)
			var target := Vector3(p.x, h.ground_at(p.x, p.y) + 0.5, p.y)
			add_view("trail_%02d_overview" % index, Dev._look_from(h, target, 48.0, 16.0, 16.0), target)
			add_view("trail_%02d_ride" % index, Vector3(p.x, h.surface_at(p.x, p.y, -INF) + 1.7, p.y), Vector3(q.x, h.surface_at(q.x, q.y, -INF) + 1.5, q.y))
			bike_start(game, d)
	var edge_x := (w.W - 4) * GameConfig.TILE
	var edge_z := w.H * GameConfig.TILE * 0.5
	add_view("plan_edge", Vector3(edge_x, h.ground_at(edge_x, edge_z) + 12, edge_z), Vector3(edge_x + 36, h.ground_at(edge_x + 36, edge_z) + 2, edge_z))
	var state := game.save_state()
	var saved := Saves.write_slot(state, "review")
	var loaded := Saves.read_slot(w.seed_text, "review")
	check_review(saved == OK and not loaded.data.is_empty() and loaded.data.get("signature") == state.signature and loaded.data.get("player", {}) == state.player, "real GameWorld progress saves and restores")
	review.audit_ms = Time.get_ticks_msec() - begin
	review.status = "audit_complete_before_screenshots"
	review.fps_measured = false
	Dev.save_json(out.path_join("review.json"), review)
	print("WORLD REVIEW ", JSON.stringify({lakes = review.lakes, routes = review.routes.size(), network_m = review.network.get("length_m", 0), audit_ms = review.audit_ms}))

func add_view(name: String, pos: Vector3, target: Vector3) -> void:
	shots.append({name = name, pos = pos, target = target, hour = 12.0, suffix = ""})

func bike_start(game: GameWorld, d: TrailDefinition) -> void:
	var player := game.player
	var bike := game.bike
	var original := {x = player.x, z = player.z, feet = player.feet, bike_x = bike.x, bike_z = bike.z, bike_y = bike.y, heading = bike.heading}
	game._finish_opening()
	var at := d.point_at(2.0)
	player.x = at.x; player.z = at.y
	player.feet = game.heights.surface_at(at.x, at.y, -INF)
	player.on_ground = true
	game.stream_coordinator.force_terrain(Vector3(at.x, player.feet, at.y), GameWorld.NEAR)
	game.stream_coordinator.force_vegetation(Vector3(at.x, player.feet, at.y))
	game.heights.obstacles.update(at.x, at.y, game.vegetation.obstacles, game.vegetation.obstacles_version, true)
	bike.reset_motion()
	bike.crashed = false
	bike.x = at.x; bike.z = at.y; bike.y = player.feet
	bike.heading = d.heading_at(2.0)
	bike.mount(player)
	bike.speed = 3.0
	var advanced := 2.0
	var crashed := false
	for tick in 180:
		var here := Vector2(bike.x, bike.z)
		var near := d.nearest(here)
		advanced = maxf(advanced, near.x)
		var forward := d.point_at(near.x + 6.0) - here
		var steer := clampf(-wrapf(atan2(-forward.x, -forward.y) - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		bike.step(player, 0.5 if bike.speed < 4.0 else -0.3, steer, false, false, 1.0 / 60.0, game.world, game.heights)
		if bike.crashed:
			crashed = true
			break
	review.bike_starts.append({id = d.id, progress_m = advanced - 2.0, crashed = crashed})
	check_review(not crashed and advanced > 6.0, "BikeRide start %s: %.1f m, crashed=%s" % [d.id, advanced - 2.0, crashed])
	bike.riding = false
	bike.crashed = false
	bike.reset_motion()
	player.x = original.x; player.z = original.z; player.feet = original.feet
	bike.x = original.bike_x; bike.z = original.bike_z; bike.y = original.bike_y; bike.heading = original.heading

func _after_run() -> void:
	done = true
	review.load_ms = load_ms
	review.wall_load_s = timing.get("load", 0)
	review.completed = review_done and not failed
	review.status = "completed" if review.completed else "incomplete"
	review.fps_measured = false
	review.failures = review.checks.filter(func(c: Dictionary) -> bool: return not c.ok).size()
	review.machine = {cpu = OS.get_processor_name(), gpu = RenderingServer.get_video_adapter_name(), renderer = RenderingServer.get_current_rendering_method()}
	Dev.save_json(out.path_join("review.json"), review)
	Dev.save_json(out.path_join("route_lengths.json"), review.get("routes", []))
	print("FULL WATER GAME REVIEW ", JSON.stringify({failures = review.failures, load_s = review.wall_load_s, routes = review.get("routes", []).size(), network_m = review.get("network", {}).get("length_m", 0), fps_measured = false}))
	quit(1 if failed else 0)

