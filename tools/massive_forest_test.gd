extends SceneTree
const Massive := preload("res://scripts/world/massive_forest.gd")
var fails := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

static func fixture(seed_num := 630, mountain := false, strong := true) -> WorldData:
	while strong and Massive.character(seed_num) < 0.95: seed_num += 1
	var w := WorldData.new()
	w.W = 256
	w.H = 256
	w.N = w.W * w.H
	w.seed_num = seed_num
	w.rng = WGRandom.new(seed_num)
	for name: String in WorldGenerator.NOISE_SLOTS:
		w.noise[name] = Simplex.new(WorldGenerator.noise_rng(seed_num, name))
	for key in ["h", "elev", "temp", "moist", "slope", "dist_water", "dist_ocean"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		values.fill(0.21 if mountain else 0.08)
		if key in ["temp", "moist"]: values.fill(0.6)
		if key in ["dist_water", "dist_ocean"]: values.fill(8)
		if key == "slope": values.fill(0.1)
		w.set(key, values)
	for key in ["biome", "ocean", "lake", "river", "path_mask"]:
		var values := PackedByteArray()
		values.resize(w.N)
		if key == "biome": values.fill(Biomes.FOREST if mountain else Biomes.GRASS)
		w.set(key, values)
	return w

func signature(st: StageVegetation.ObjStore) -> PackedByteArray:
	return var_to_bytes([st.x, st.y, st.k, st.v, st.s])

func place(w: WorldData, f: Dictionary, rect: Rect2i, key: Vector2i) -> StageVegetation.ObjStore:
	var st := StageVegetation.ObjStore.new(null)
	var lo := key * WorldData.CHUNK_SIZE
	StageVegetation.place_chunk(w.seed_num, lo.x, lo.y, lo.x + 16, lo.y + 16, f,
		rect.position.x, rect.position.y, rect.size.x, null, st)
	return st

func largest(mask: PackedByteArray, width: int) -> int:
	var seen := PackedByteArray()
	seen.resize(mask.size())
	var best := 0
	for start in mask.size():
		if mask[start] == 0 or seen[start]: continue
		var queue := PackedInt32Array([start])
		seen[start] = 1
		var head := 0
		while head < queue.size():
			var cell := queue[head]
			head += 1
			for next: int in [cell - 1 if cell % width > 0 else -1, cell + 1 if cell % width < width - 1 else -1, cell - width, cell + width]:
				if next < 0 or next >= mask.size() or seen[next] or not mask[next]: continue
				seen[next] = 1
				queue.append(next)
		best = maxi(best, queue.size())
	return best

func cover(w: WorldData, fields: Dictionary, profile: Dictionary) -> Dictionary:
	var core_trees := 0
	var species := {}
	var occupancy := PackedByteArray()
	occupancy.resize(64 * 64)
	for cy in 16:
		for cx in 16:
			var st := place(w, fields, Rect2i(0, 0, w.W, w.H), Vector2i(cx, cy))
			for i in st.x.size():
				if not Biomes.is_tree(st.k[i]): continue
				var delta: Vector2 = (Vector2(st.x[i], st.y[i]) - profile.center) / profile.radius
				if delta.length() < 0.5:
					core_trees += 1
					var base := Biomes.base_tree(st.k[i])
					var area: float = pow(Biomes.CROWN_RADIUS[st.k[i]] * st.s[i], 2.0)
					species[base] = float(species.get(base, 0.0)) + area
				var radius: float = Biomes.CROWN_RADIUS[st.k[i]] * st.s[i] + 0.5
				for y in range(maxi(0, floori((st.y[i] - radius) / 4)), mini(64, ceili((st.y[i] + radius) / 4))):
					for x in range(maxi(0, floori((st.x[i] - radius) / 4)), mini(64, ceili((st.x[i] + radius) / 4))):
						if Vector2(x * 4.0 + 2 - st.x[i], y * 4.0 + 2 - st.y[i]).length() < radius:
							occupancy[y * 64 + x] = 1
	return {core = core_trees, species = species, connected = largest(occupancy, 64)}

func accessibility(w: WorldData, profile: Dictionary) -> void:
	StageVegetation.run(w)
	var giants := w.obj_k.count(Biomes.T_RELICT_OAK) + w.obj_k.count(Biomes.T_RELICT_PINE)
	check(giants > 0, "Procedural forest generation emits the new giant species (%d)" % giants)
	var footprints_safe := true
	for o in w.obj_count:
		if not Biomes.is_relict(w.obj_k[o]): continue
		var cx := fposmod(w.obj_x[o], WorldData.CHUNK_SIZE)
		var cy := fposmod(w.obj_y[o], WorldData.CHUNK_SIZE)
		var reach := Biomes.ground_radius(w.obj_k[o]) * w.obj_s[o] + 0.25
		footprints_safe = footprints_safe and minf(minf(cx, WorldData.CHUNK_SIZE - cx), minf(cy, WorldData.CHUNK_SIZE - cy)) >= reach
	check(footprints_safe, "Giant root bases do not overlap unqueried neighbour chunks")
	var h := Heightfield.new(w, false)
	h.obstacles = ForestObstacles.new(w, h)
	var center: Vector2 = profile.center.clamp(Vector2(12, 12), Vector2(w.W - 12, w.H - 12)) * GameConfig.TILE
	h.obstacles.update(center.x, center.y, PackedFloat32Array(), 0, true)
	var clear_walk := 0
	var clear_bike := 0
	for j in 20:
		for i in 20:
			var x := center.x - 10.0 + i
			var z := center.y - 10.0 + j
			var feet := h.ground_at(x, z)
			clear_walk += int(PlayerState.is_passable(w, h, x, z, feet, PlayerState.BODY_R))
			var bike := BikeRide.new()
			bike.y = feet
			clear_bike += int(bike.fits(x, z, 0.0, w, h))
	print("Relict core accessibility: walk ", clear_walk, "/400, bike ", clear_bike, "/400")
	check(clear_walk > 320 and clear_bike > 260, "Dense relict forest still leaves space for walking and cycling")

func actual_worlds() -> void:
	for seed_text in ["Север-1234", "Туман-4821"]:
		var w := WorldGenerator._geography(seed_text, 256)
		var profile := Massive.profile(w)
		print("World character for ", seed_text, ": ", Massive.character(w.seed_num))
		if profile.is_empty():
			w.clear_noise_fields()
			continue
		var fields := Massive.fields(w, 0, 0, w.W, w.H)
		var wet := w.river_cells()
		var strong := 0
		for i in w.N:
			if wet[i] != 0: continue
			var strength: float = fields.massive[i] * Massive.suitability(profile.scenario, w.biome[i], w.elev[i], w.slope[i], w.moist[i], w.temp[i])
			strong += int(strength > 0.3)
		check(strong > 0, "%s: suitable dry forest cells %d, scenario %d" % [seed_text, strong, profile.scenario])
		w.clear_noise_fields()

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var expressed := 0
	var partial := 0
	for seed_num in 10000:
		var value := Massive.character(seed_num)
		expressed += int(value > 0.0)
		partial += int(value > 0.0 and value < 1.0)
	check(expressed > 0 and expressed < 10000 and partial > 0, "Forest character has ordinary, transitional and relict worlds; no fixed quota")
	print("Character distribution: ", expressed, "/10000 with relict influence, ", partial, " transitional")
	var w := fixture()
	var before := var_to_bytes([w.h, w.elev, w.biome, w.moist, w.path_mask])
	var rng_before := w.rng._a
	var profile := Massive.profile(w)
	check(not profile.is_empty() and profile == Massive.profile(w), "One deterministic profile per eligible world")
	check(profile.scenario == Massive.OAK, "Lowland habitat selects the ancient oak grove")
	var mountain := fixture(630, true)
	check(Massive.profile(mountain).scenario == Massive.PINE, "Mountain habitat selects the pine forest")
	check(w.rng._a == rng_before and before == var_to_bytes([w.h, w.elev, w.biome, w.moist, w.path_mask]), "Profile leaves RNG, geography and roads unchanged")
	var disabled_seed := 0
	while Massive.character(disabled_seed) > 0.0: disabled_seed += 1
	var ordinary := fixture(disabled_seed, false, false)
	check(Massive.profile(ordinary).is_empty() and not StageVegetation.structure_rect(ordinary, -16, -16, 32, 32).has("massive"), "Inactive seeds retain the ordinary structure fields")
	var full_rect := Rect2i(-128, -128, 512, 512)
	var full := StageVegetation.structure_rect(w, -128, -128, 512, 512)
	var strong := PackedByteArray()
	strong.resize(full_rect.get_area())
	for i in strong.size(): strong[i] = int(full.massive[i] > 0.75)
	check(strong.count(1) > 1000 and largest(strong, 512) > strong.count(1) * 0.98,
		"Low-frequency mask has a large connected core (%d cells)" % strong.count(1))
	check(not Massive.fields(w, 10000, -10000, 32, 32).has("massive"), "Massif is unique and bounded, not repeated throughout the infinite world")
	var rectangles_same := true
	for rect: Rect2i in [Rect2i(-32, -16, 64, 64), Rect2i(240, 240, 64, 64), Rect2i(64, 64, 16, 16)]:
		var part := StageVegetation.structure_rect(w, rect.position.x, rect.position.y, rect.size.x, rect.size.y)
		for name in ["wood", "stand", "glade", "massive"]:
			for y in rect.size.y:
				for x in rect.size.x:
					rectangles_same = rectangles_same and full[name][(rect.position.y + y + 128) * 512 + rect.position.x + x + 128] == (part[name][y * rect.size.x + x] if part.has(name) else 0.0)
	check(rectangles_same, "Structure fields are byte-equivalent across negative coordinates, plan edges and rectangle sizes")
	Grid.allow_fast = false
	var gd := StageVegetation.structure_rect(w, 64, 64, 32, 32)
	Grid.allow_fast = true
	var native := StageVegetation.structure_rect(w, 64, 64, 32, 32)
	check(var_to_bytes(gd) == var_to_bytes(native), "Native and GDScript noise produce identical forest structure")
	var f := StageVegetation.fields(w)
	var standard := f.duplicate()
	standard.erase("massive")
	standard.erase("massive_scenario")
	var relic := cover(w, f, profile)
	var control := cover(w, standard, profile)
	print("Oak core trees: ", relic.core, " vs ordinary ", control.core, "; connected 4x4 cells: ", relic.connected, " vs ", control.connected)
	check(relic.connected > control.connected, "Actual giant canopy becomes more connected without requiring extra trunks")
	check(relic.species.size() >= 3 and float(relic.species.get(Biomes.T_OAK, 0)) / (float(relic.species.get(Biomes.T_OAK, 0)) + float(relic.species.get(Biomes.T_BIRCH, 0)) + float(relic.species.get(Biomes.T_PINE, 0))) > 0.75, "Relict oak canopy dominance preserves mixed companion species")
	var outer_rect := Rect2i(-17, -17, 50, 50)
	var outer_fields := OuterLand.vegetation_fields(w, outer_rect)
	var key := Vector2i(-1, -1)
	var direct := place(w, outer_fields, outer_rect, key)
	var streamed := OuterLand.vegetation(w, key)
	check(signature(direct) == var_to_bytes([streamed.x, streamed.y, streamed.k, streamed.v, streamed.s]), "OuterLand chunk objects match placement from a larger overlapping rectangle")
	var again := OuterLand.vegetation(w, key)
	check(var_to_bytes(streamed) == var_to_bytes(again), "Streaming regeneration is deterministic")
	var pine_fields := StageVegetation.fields(mountain)
	var pines := cover(mountain, pine_fields, Massive.profile(mountain))
	check(float(pines.species.get(Biomes.T_PINE, 0)) / (float(pines.species.get(Biomes.T_OAK, 0)) + float(pines.species.get(Biomes.T_BIRCH, 0)) + float(pines.species.get(Biomes.T_PINE, 0))) > 0.75, "Mountain core is pine-dominated")
	accessibility(w, profile)
	var meadow := {biome = Biomes.GRASS, moist = 0.6}
	var oak_floor := VegetationLayer._outer_surface(meadow, 1.0, Massive.OAK)
	var pine_floor := VegetationLayer._outer_surface(meadow, 1.0, Massive.PINE)
	check(oak_floor.r > 0.5 and pine_floor.r > 0.5 and pine_floor.g > oak_floor.g,
		"Streamed former meadows receive forest cover and the matching leaves/needles")
	for biome in [Biomes.DESERT, Biomes.JUNGLE, Biomes.SNOW, Biomes.OCEAN]:
		check(Massive.suitability(Massive.OAK, biome, 0.08, 0.1, 0.6, 0.6) == 0, "Unsuitable biome %d is not converted to oak forest" % biome)
	check(Massive.suitability(Massive.PINE, Biomes.FOREST, 0.5, 0.1, 0.6, 0.6) == 0
		and Massive.suitability(Massive.OAK, Biomes.GRASS, 0.08, 1.2, 0.6, 0.6) == 0, "Treeline and cliffs remain protected")
	if OS.get_cmdline_user_args().has("--worlds"): actual_worlds()
	print("Massive forest failures: ", fails)
	quit(1 if fails else 0)
