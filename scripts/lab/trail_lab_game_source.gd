extends RefCounted
## Lab-only adapter. Complete production world, never published into the running game.
const GenerationInput := preload("res://scripts/trails/trail_generation_input.gd")

static func generate(seed_text: String):
	var started := Time.get_ticks_usec()
	var w := WorldGenerator.generate(seed_text, WorldGenerator.PLAN_SIZE, func(_p: float, label: String) -> void: print("GAME SOURCE ", seed_text, " ", label))
	var input = GenerationInput.from_world(w)
	var h := Heightfield.new(w)
	for z in w.H:
		for x in w.W:
			input.heights[z * w.W + x] = h.ground_at((x + 0.5) * GameConfig.TILE, (z + 0.5) * GameConfig.TILE)
	# Path cells and a one-cell verge; exact path widths remain in the input too.
	for z in w.H:
		for x in w.W:
			if w.path_mask[z * w.W + x] != 0: protect(input, Vector2(x, z), 1)
	for group in [w.settlements, w.sites]:
		for place in group:
			for hut in place.huts: protect(input, Vector2(hut.x, hut.y), 3)
	for group in [w.bridges, w.tunnels]:
		for structure in group:
			var a := Vector2(structure.a % w.W, structure.a / w.W)
			var b := Vector2(structure.b % w.W, structure.b / w.W)
			var steps := maxi(1, ceili(a.distance_to(b)))
			for k in steps + 1: protect(input, a.lerp(b, float(k) / steps), 3)
	input.provenance = {source = "Trail Lab", game_seed = seed_text, complete_game_world = true,
		stages_ms = w.generation_profile.get("stages_ms", {}), source_ms = (Time.get_ticks_usec() - started) / 1000.0,
		structures_policy = "12 m exclusion around buildings and entire structures"}
	return input

static func protect(input, at: Vector2, radius: int) -> void:
	for z in range(maxi(0, floori(at.y) - radius), mini(input.size.y, ceili(at.y) + radius + 1)):
		for x in range(maxi(0, floori(at.x) - radius), mini(input.size.x, ceili(at.x) + radius + 1)):
			input.forbidden[z * input.size.x + x] = 1

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
	var out := preload("res://scripts/lab/trail_lab_game_input.gd").new()
	out.size = Vector2i(side, side)
	for key in ["heights", "water", "rivers", "forbidden"]:
		var values = input.get(key)
		var cropped = values.duplicate()
		cropped.resize(side * side)
		for z in side:
			for x in side: cropped[z * side + x] = values[(corner.y + z) * input.size.x + corner.x + x]
		out.set(key, cropped)
	var offset: Vector2 = Vector2(corner) * input.cell_size
	var box := Rect2(offset, Vector2.ONE * side * input.cell_size).grow(32.0)
	for path in input.existing_paths:
		var points: PackedVector2Array = path.points
		var half := float(path.get("half_width", 2.0))
		var bounds := Rect2(points[0], Vector2.ZERO)
		for point in points: bounds = bounds.expand(point)
		if not box.intersects(bounds.grow(half + 2.0), true): continue
		# Keep only nearby segments, including segments whose endpoints lie outside the window.
		var local := PackedVector2Array()
		for k in range(1, points.size()):
			var segment := Rect2(points[k - 1], points[k] - points[k - 1]).abs().grow(half + 2.0)
			if box.intersects(segment, true):
				if local.is_empty(): local.append(points[k - 1] - offset)
				local.append(points[k] - offset)
			elif not local.is_empty():
				out.existing_paths.append({points = local, half_width = half})
				local = PackedVector2Array()
		if not local.is_empty(): out.existing_paths.append({points = local, half_width = half})
	out.earthwork_limits = input.earthwork_limits.duplicate(true)
	out.river_policy = input.river_policy
	out.provenance = input.provenance.duplicate(true)
	out.provenance.world_origin = corner
	out.provenance.origin = corner
	out.provenance.world_seed = hash(input.provenance.get("game_seed", "snapshot"))
	return out
