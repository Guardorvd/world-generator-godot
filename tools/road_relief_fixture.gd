extends RefCounted
## Small rideable stand. Production RoadBed, patches and BikeRide, no replacement physics.
static func world(origin := Vector2i.ZERO) -> WorldData:
	var w := WorldData.new()
	w.W = 96; w.H = 96; w.N = w.W * w.H; w.seed_num = 4407
	w.world_origin = origin
	for name: String in ["h", "filled", "elev", "slope", "temp", "moist", "dist_water"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		values.fill(20.0 if name == "dist_water" else 0.0)
		w.set(name, values)
	for z in w.H:
		for x in w.W:
			var px := (x + 0.5) * GameConfig.TILE
			# Unequal broad natural depressions/knolls; deliberately no periodic waves.
			var height := 20.0 + px * 0.012 + 0.55 * exp(-pow((px - 135.0) / 11.0, 2)) - 0.8 * exp(-pow((px - 225.0) / 18.0, 2))
			w.h[z * w.W + x] = height / GameConfig.HS
	for name: String in ["ocean", "lake", "river", "biome", "path_mask", "road_surface"]:
		var values := PackedByteArray()
		values.resize(w.N)
		values.fill(Biomes.GRASS if name == "biome" else 0)
		w.set(name, values)
	for lane in 3:
		var points: Array = []
		var covering := PackedByteArray()
		for x in range(8, 89):
			points.append({x = float(x), y = 16.5 + lane * 32.0, w = 0.9 if lane < 2 else 0.55})
			covering.append([RoadSurface.GRAVEL, RoadSurface.DIRT, RoadSurface.FOREST][lane])
		w.trails.append({kind = "road" if lane < 2 else "trail", pts = points, surf = covering})
	return w
