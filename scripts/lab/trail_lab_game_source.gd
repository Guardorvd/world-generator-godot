extends RefCounted
## Lab-only adapter. Complete production world, never published into the running game.
const GenerationInput := preload("res://scripts/trails/trail_generation_input.gd")

static func geometry_fingerprint(input) -> String:
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(var_to_bytes(GenerationInput._canonical([input.size, input.cell_size, input.origin, input.heights, input.water, input.rivers, input.forbidden, input.existing_paths])))
	return digest.finish().hex_encode()

static func generate(seed_text: String):
	var started := Time.get_ticks_usec()
	var w := WorldGenerator.generate(seed_text, WorldGenerator.PLAN_SIZE, func(_p: float, label: String) -> void: print("GAME SOURCE ", seed_text, " ", label))
	var h: Heightfield = w.generation.trail_surface
	if h == null:
		h = Heightfield.new(w, false)
		StageTrailPlan.prepare(h)
	else:
		w.generation.trail_surface = null
	var input = GenerationInput.from_world(w, h)
	# Preserve the laboratory's conservative one-cell verge.
	for z in w.H:
		for x in w.W:
			if w.path_mask[z * w.W + x] != 0: input.protect(Vector2(x, z), 1)
	input.provenance = {source = "Trail Lab", game_seed = seed_text, complete_game_world = true,
		stages_ms = w.generation_profile.get("stages_ms", {}), source_ms = (Time.get_ticks_usec() - started) / 1000.0,
		structures_policy = "12 m exclusion around buildings and entire structures"}
	return input

static func open(path: String) -> Dictionary:
	if path.get_extension() not in ["res", "tres"] or not FileAccess.file_exists(path): return {error = "снимок .res/.tres не найден"}
	var input = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if not input is GenerationInput: return {error = "ожидается снимок TrailGenerationInput (.tres/.res)"}
	var errors = input.validate()
	if not errors.is_empty(): return {error = "; ".join(errors)}
	if input.size.x != input.size.y or input.size.x < 128 or input.cell_size != GameConfig.TILE or input.origin != Vector2.ZERO:
		return {error = "нужен квадратный мир от 128 клеток с шагом 4 м и началом (0, 0)"}
	return {input = input}

static func terrain(input, dry_channels := false) -> Dictionary:
	var source = input.duplicate(true)
	# Runtime timings describe a run, not the identity of the terrain/project source.
	source.provenance.erase("stages_ms")
	source.provenance.erase("source_ms")
	# Automatic Lab construction ranks earthwork cost instead of inheriting the old 2 m stand cap.
	source.earthwork_limits.unlimited = true
	if dry_channels:
		source.river_policy = GenerationInput.RiverPolicy.LAB_DRY_CHANNELS
		source.provenance.source = "Trail Lab"
	else: source.river_policy = GenerationInput.RiverPolicy.STRICT
	var blocked = source.water.duplicate()
	for i in blocked.size():
		if source.forbidden[i] != 0 or (not dry_channels and source.rivers[i] != 0): blocked[i] = 1
	return {heights = source.heights.duplicate(), water = blocked, rivers = source.rivers.duplicate(),
		size = source.size.x, seed = hash(source.provenance.get("game_seed", "snapshot")), input = source, info = input.provenance.duplicate(true)}

static func window(input, corner: Vector2i, side: int):
	return input.window(corner, Vector2i(side, side))
