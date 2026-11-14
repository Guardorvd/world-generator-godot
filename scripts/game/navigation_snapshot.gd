extends RefCounted
## Capture on the main thread. Workers only read this private view, never live streaming dictionaries.
## include_places = false — без поселений и мест мира: их глубокая копия — почти вся цена снимка (около 4 мс на
## мире 768), а сборке узлов области (RegionStream.build_decor) они не нужны: она берёт поселения своей области.
static func capture(source: Heightfield, include_graph := true, include_places := true) -> Heightfield:
	var original := source.world
	var w := WorldData.new()
	w.W = original.W
	w.H = original.H
	w.N = original.N
	w.available_rect = original.available_rect
	w.territory_revision = original.territory_revision
	w.world_origin = original.world_origin
	# Route records are immutable after generation; only the list is mutable.
	if include_graph:
		w.trails = original.trails.duplicate()
		w.bridges = EntityCodec.copy(original.bridges)
		w.tunnels = EntityCodec.copy(original.tunnels)
	if include_places:
		w.settlements = EntityCodec.copy(original.settlements)
		w.sites = EntityCodec.copy(original.sites)
	w.lake = original.lake.duplicate()
	w.filled = original.filled.duplicate()
	if original.outer != null:
		var outer := OuterLand.new()
		outer.W = original.outer.W
		outer.H = original.outer.H
		# Published field/ring/ledger records are immutable; copy the mutable lookup tables.
		outer._ring = original.outer._ring.duplicate()
		outer.chunks = original.outer.chunks.duplicate()
		outer._ledger = original.outer.get_ledger()
		outer.settlements = EntityCodec.copy(original.outer.settlements)
		w.outer = outer
	var h := source.copy()
	h.world = w
	h.structures = source.structures.duplicate(true)
	h._cells = source._cells.duplicate(true)
	h._outer_cells = source._outer_cells.duplicate(true)
	# Refinement is immutable after preparation; region surfaces belong to the captured outer ledger.
	h.road_refinement = source.road_refinement
	if source.obstacles != null:
		h.obstacles = ForestObstacles.new(w, h)
		h.obstacles.data = source.obstacles.data.duplicate()
		h.obstacles._grid = source.obstacles._grid.duplicate(true)
	return h
