class_name AudioSurfaceClassifier
extends RefCounted
## Classifies world surface under wheels/feet into the 11 acoustic surface IDs
## using existing WorldData, Heightfield, RoadRefinement, and Biomes data.


static func classify(world: WorldData, heights: Heightfield, x: float, z: float, y: float, cfg) -> Dictionary:
	var out := {
		surface = &"dirt",
		legacy = "soft",
		rough = 0.25,
		brush = 0.0,
		depth = 0.0,
		on_deck = false,
	}
	if heights == null or world == null:
		return out
	var depth := heights.depth_at(x, z, y)
	out.depth = depth
	if depth > 0.025:
		out.surface = &"water"
		out.legacy = "splash"
		out.rough = 0.8
		return out
	if heights.deck_at(x, z, y + 0.15) > heights.ground_at(x, z) + 0.05:
		out.surface = &"wood"
		out.legacy = "wood"
		out.rough = 0.35
		out.on_deck = true
		return out

	var info := world.tile_info(x / GameConfig.TILE, z / GameConfig.TILE)
	var biome: int = info.get("biome", Biomes.GRASS) if not info.is_empty() else Biomes.GRASS
	var moist := _sample_moisture(world, heights, x, z, info)

	var surf := PlayerState.surface(info) if not info.is_empty() else RoadSurface.NONE
	var weight := 1.0 if surf != RoadSurface.NONE else 0.0
	if heights.road_refinement != null:
		var contact := heights.road_refinement.sample(x, z, world.W)
		if not contact.is_empty() and contact.weight > 0.25:
			surf = int(contact.surface)
			weight = float(contact.weight)
		else:
			surf = RoadSurface.NONE
			weight = 0.0

	if surf != RoadSurface.NONE:
		out.rough = float(RoadSurface.LIST[surf].rough)
		out.legacy = "gravel" if RoadSurface.LIST[surf].hard else "soft"
		match surf:
			RoadSurface.PACKED:
				out.surface = &"packed"
			RoadSurface.DIRT:
				out.surface = &"wet" if moist >= cfg.wet_moisture_threshold + 0.08 else &"dirt"
			RoadSurface.FOREST:
				out.surface = &"wet" if moist >= cfg.wet_moisture_threshold + 0.12 else &"forest"
			RoadSurface.GRAVEL:
				out.surface = &"gravel"
			RoadSurface.MEADOW:
				out.surface = &"grass"
			RoadSurface.SAND:
				out.surface = &"sand"
			RoadSurface.STONE:
				out.surface = &"stone"
			_:
				out.surface = &"dirt"
		if weight < 0.65:
			out.brush = _biome_brush(biome) * (1.0 - weight)
		return out

	# Off-road terrain: map biome & moisture to natural ground surfaces
	out.brush = _biome_brush(biome)
	match biome:
		Biomes.SNOW, Biomes.PEAK:
			out.surface = &"snow" if biome == Biomes.SNOW or moist > 0.3 else &"stone"
			out.legacy = "gravel" if out.surface == &"stone" else "soft"
			out.rough = 0.45
		Biomes.ROCK, Biomes.STONESHORE:
			out.surface = &"stone"
			out.legacy = "gravel"
			out.rough = 0.72
		Biomes.BEACH, Biomes.DESERT:
			out.surface = &"sand"
			out.legacy = "gravel"
			out.rough = 0.36
		Biomes.SWAMP:
			out.surface = &"wet"
			out.legacy = "soft"
			out.rough = 0.48
		Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE:
			out.surface = &"wet" if moist >= cfg.wet_moisture_threshold + 0.10 else &"forest"
			out.legacy = "soft"
			out.rough = 0.42
		Biomes.GRASS, Biomes.SAVANNA, Biomes.STEPPE, Biomes.TUNDRA:
			out.surface = &"wet" if moist >= cfg.wet_moisture_threshold + 0.12 else &"grass"
			out.legacy = "soft"
			out.rough = 0.34
		_:
			out.surface = &"dirt"
			out.legacy = "soft"
			out.rough = 0.35
	return out


static func _sample_moisture(world: WorldData, heights: Heightfield, x: float, z: float, info: Dictionary) -> float:
	var gm := heights.ground_moisture()
	if not gm.is_empty():
		var tx := clampi(floori(x / GameConfig.TILE), 0, world.W - 1)
		var tz := clampi(floori(z / GameConfig.TILE), 0, world.H - 1)
		return float(gm[tz * world.W + tx])
	return float(info.get("moist", 0.3))


static func _biome_brush(biome: int) -> float:
	match biome:
		Biomes.JUNGLE, Biomes.SWAMP:
			return 0.85
		Biomes.FOREST, Biomes.TAIGA:
			return 0.55
		Biomes.GRASS, Biomes.SAVANNA, Biomes.STEPPE:
			return 0.65
		Biomes.TUNDRA:
			return 0.25
		_:
			return 0.0
