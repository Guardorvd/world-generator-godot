extends RefCounted
const GenerationInput := preload("res://scripts/trails/trail_generation_input.gd")
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
static func snapshot() -> GenerationInput:
	var input := GenerationInput.new()
	input.size = Vector2i(Terrain.CELLS, Terrain.CELLS)
	input.heights = (Terrain._base_cells if not Terrain._base_cells.is_empty() else Terrain.cells).duplicate()
	input.water = Terrain._wet_cells.duplicate() if Terrain.window_mode else PackedByteArray()
	input.water.resize(input.heights.size())
	input.rivers = Terrain._river_cells.duplicate() if Terrain.window_mode else PackedByteArray()
	input.rivers.resize(input.heights.size())
	input.forbidden.resize(input.heights.size())
	input.river_policy = GenerationInput.RiverPolicy.LAB_DRY_CHANNELS
	input.earthwork_limits = {max_cut = 3.5, max_fill = 12.0, modification = 1.0}
	input.provenance = {source = "Trail Lab", world_seed = Terrain.world_seed, origin = Terrain.origin, kind = Terrain.kind, dry_rivers = true}
	return input
