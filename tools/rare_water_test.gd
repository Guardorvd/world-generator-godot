extends SceneTree
const Regions := preload("res://scripts/world/region_preparation.gd")
const Saves := preload("res://scripts/game/save_game.gd")
var failures := 0
var reports: Array = []
const OUT := "res://.godot/rare_water_validation"

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 900)
	call_deferred("run")

func validate_geo(w: WorldData) -> void:
	var validation_started := Time.get_ticks_msec()
	check(w.rivers.is_empty() and w.river.find(1) < 0 and w.order_n == 0 and w.down.count(-1) == w.N, w.seed_text + " no drainage/tracing")
	check(int(w.generation_profile.get("freshwater_lakes", 0)) <= 2, "at most two actual lakes")
	for name: String in WorldCache.PER_CELL:
		if name in ["cost", "path_mask", "road_surface", "lake_id"]: continue
		check(w.get(name).size() == w.N, "contract " + name)
	var native_biome := w.biome.duplicate()
	var native_temp := w.temp.duplicate()
	var ref_fields := StageClimate.fields_reference(w, w.noise_field("temp"))
	check(native_biome == ref_fields.biome and native_temp == ref_fields.temp, "C#/GDScript climate agreement")
	var land := 0
	var forest := 0
	var hot := 0
	var hist := {}
	var seen := PackedByteArray()
	seen.resize(w.N)
	var count := 0
	var s := w.lake.find(1)
	while s >= 0:
		if seen[s] == 0:
			count += 1
			var cells := PackedInt32Array([s])
			seen[s] = 1
			var head := 0
			var flat := true
			while head < cells.size():
				var c := cells[head]
				head += 1
				flat = flat and w.filled[c] == w.filled[s]
				for k in 8:
					var n: int = c + Grid.DY[k] * w.W + Grid.DX[k]
					if n >= 0 and n < w.N and absi(n % w.W - c % w.W) <= 1 and w.lake[n] != 0 and seen[n] == 0:
						seen[n] = 1
						cells.append(n)
			check(flat and cells.size() >= StageHydrology.LAKE_MIN and cells.size() <= StageHydrology.LAKE_MAX, "actual connected lake has one level and bounded area")
		s = w.lake.find(1, s + 1)
	check(count <= 2 and count == int(w.generation_profile.get("freshwater_lakes", count)), "count real connected water bodies independently")
	for i in w.N:
		var b: int = w.biome[i]
		hist[b] = hist.get(b, 0) + 1
		if not Biomes.LIST[b].get("water", false):
			land += 1
			if b in [Biomes.FOREST, Biomes.TAIGA]: forest += 1
			if b in [Biomes.DESERT, Biomes.JUNGLE, Biomes.SAVANNA]: hot += 1
	check(hot < land * 0.01 and forest > land * 0.5, "forest majority and less than 1% hot biomes")
	var image := Image.create(w.W, w.H, false, Image.FORMAT_RGB8)
	for i in w.N:
		var c: Array = Biomes.LIST[w.biome[i]].color
		image.set_pixel(i % w.W, i / w.W, Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0))
	image.save_png(OUT.path_join(w.seed_text + ".png"))
	reports.append({seed = w.seed_text, stages_ms = w.generation_profile.get("stages_ms", {}).duplicate(), lakes = count,
		lake_cells = w.lake.count(1), forest_percent = 100.0 * forest / maxi(1, land), hot_cells = hot, biomes = hist,
		validation_ms = Time.get_ticks_msec() - validation_started})

func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	Saves.dir = OUT.path_join("saves")
	RegionStream.root = OUT.path_join("regions")
	# Closed bowl: actual water through existing Heightfield, no terrain modification.
	var fixture := WorldGenerator._geography("dry-fixture", 64)
	var heights := PackedFloat32Array()
	heights.resize(fixture.N)
	for i in fixture.N:
		var p := Vector2(i % 64 - 32, i / 64 - 32)
		heights[i] = 0.12 + p.length_squared() * 0.00025
	fixture.h = heights
	fixture.ocean.fill(0)
	StageHydrology.run(fixture, 2)
	check(fixture.h == heights and fixture.lake.count(1) >= StageHydrology.LAKE_MIN, "natural closed bowl retains relief and produces real lake")
	var wet := fixture.lake.duplicate()
	StageHydrology.run(fixture, 2)
	check(wet == fixture.lake, "lake selection deterministic")
	StageRivers.run(fixture)
	check(fixture.base_heights.depth_at(130, 130) > 0.3, "existing Heightfield sees lake depth")
	StageHydrology.run(fixture, 0)
	StageRivers.run(fixture)
	StageGeography.run(fixture)
	StageClimate.run(fixture)
	check(fixture.lake.count(1) == 0 and fixture.dist_water[32 * 64 + 32] > 1e8, "water-free world keeps real no-source distance")
	StageLandmarks.run(fixture)
	StageTrails.run(fixture, func(_p: float, _s: String) -> void: pass)
	StageVegetation.run(fixture)
	StageLakes.run(fixture)
	check(not fixture.settlements.is_empty() and fixture.lakes.is_empty(), "dry settlements, roads, vegetation and lake naming complete")
	for seed_text: String in ["Север-1234", "Ущелье", "Туман-4821"]:
		print("BEGIN ", seed_text)
		var cache := WorldCache.new()
		cache.enabled = true
		cache.dir = OUT.path_join("final_cache_" + seed_text)
		var cached := "--cached" in OS.get_cmdline_user_args()
		if not cached: cache.invalidate_from(seed_text, 768, 0)
		var started := Time.get_ticks_msec()
		var result := cache._load(seed_text, 768) if cached else cache.generate(seed_text, 768, func(_p: float, label: String) -> void: print(label), validate_geo)
		var w: WorldData = result.world
		if cached:
			w.start_noise_fields()
			validate_geo(w)
		reports.back().generation_ms = Time.get_ticks_msec() - started - reports.back().validation_ms
		check(not w.settlements.is_empty() and not w.trails.is_empty(), "settlements and road network exist")
		check(StageTrailPlan.consistency_errors(w).is_empty(), "bicycle trail plan consistency")
		reports.back().trail_state = w.trail_plan.get("state", "none")
		reports.back().trail_stats = w.trail_plan.get("stats", {})
		reports.back().settlements = w.settlements.size()
		reports.back().roads = w.trails.size()
		reports.back().stages_ms = w.generation_profile.get("stages_ms", {}).duplicate()
		cache.wait_writes()
		started = Time.get_ticks_msec()
		var loaded := cache._load(seed_text, 768)
		check(loaded.layers == 3, "all cache layers restore")
		if loaded.world != null:
			check(loaded.world.h == w.h and loaded.world.biome == w.biome and loaded.world.lake == w.lake and loaded.world.trail_plan == w.trail_plan, "cache geography and bicycle trails round trip")
		reports.back().cache_read_ms = Time.get_ticks_msec() - started
		var regions: Array = []
		var networks: Array = []
		for key in [Vector2i(3, 1), Vector2i(3, 2)]:
			var region := Regions.prepare(w, key)
			regions.append(region)
			var network := Regions.prepare_water(region)
			check(network.rivers.is_empty() and network.unresolved.is_empty() and network.surface.ready, "neighbor without freshwater remains ready")
			networks.append(network)
		var batch := Regions.finish_neighbors(w, regions, networks)
		check(batch.ready, "neighbor water and settlements batch ready")
		var roads := Regions.prepare_roads(w, regions, batch)
		var committed := Regions.commit({}, regions, networks, batch, roads)
		check(committed.ready, "dry neighbors accept roads and commit")
		var regional_path := RegionStream.store_dir(w)
		check(RegionStream._save_generation(regional_path, committed.ledger, Vector2i(3, 1)) == OK, "regional journal and immutable fields save")
		var ledger := RegionStream.read_ledger(w)
		check(ledger.get("regions", {}).size() == 2, "regional journal restores")
		for key: Vector2i in ledger.get("regions", {}):
			check(not RegionStream._read_fields(regional_path, key, ledger.regions[key]).is_empty(), "regional water and terrain fields restore")
		var state := {format = 1, seed = seed_text, signature = "rare-water", saved_at = 1,
			visited = {}, goal = "", quest = preload("res://scripts/game/quests.gd").new().save_state(),
			player = {x = 4.0, z = 4.0, feet = 0.0, yaw = 0.0, pitch = 0.0, hour = 12.0},
			bike = {x = 4.0, z = 4.0, y = 0.0, heading = 0.0, riding = false}}
		check(Saves.write_slot(state) == OK and Saves.read_slot(seed_text).data == state, "player progress round trip")
		print("REPORT ", JSON.stringify(reports.back()))
		w.base_heights = null
		await process_frame
	var f := FileAccess.open(OUT.path_join("cached_checks.json" if "--cached" in OS.get_cmdline_user_args() else "report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({failures = failures, quick_trails = QuickTrails.active(), worlds = reports}, "\t"))
	print("RARE WATER RESULT ", failures, " failures")
	quit(1 if failures else 0)
