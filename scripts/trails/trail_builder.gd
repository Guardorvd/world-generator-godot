class_name TrailBuilder
extends RefCounted
## Adapter to existing civil paths. Call on private preparation data before nature/finish_paths.
## No generator RNG, navigation implementation, mesh builder or physics model of its own.
static func append_routes(w: WorldData, definitions: Array[TrailDefinition]) -> PackedStringArray:
	var errors := _validate(w, definitions, false)
	if not errors.is_empty(): return errors
	for route: Dictionary in w.trails:
		if not route.has("surf") or route.surf.size() != route.pts.size(): RoadSurface.assign_route(w, route)
	for d in definitions:
		var route := d.path_record()
		RoadSurface.assign_route(w, route)
		w.trails.append(route)
		Grid.stamp_path(w.path_mask, w.W, w.H, route.pts, 3 if d.kind == "road" else 2,
			maxf(0.0, d.width / GameConfig.TILE * 0.5 - Grid.PATH_IN))
	RoadSurface.rebuild_map(w)
	return errors

static func _validate(w: WorldData, definitions: Array[TrailDefinition], for_bake: bool) -> PackedStringArray:
	var errors := PackedStringArray()
	if w.path_mask.size() != w.N:
		errors.append("World path mask must be allocated before appending routes")
	var ids := {}
	var existing := {}
	for route: Dictionary in w.trails:
		if route.has("trail_id"): existing[route.trail_id] = route
	for d in definitions:
		if d == null:
			errors.append("Null definition")
			continue
		errors.append_array(d.validate())
		if ids.has(d.id) or (not for_bake and existing.has(d.id)):
			errors.append("Duplicate trail id: " + d.id)
		ids[d.id] = true
		if for_bake:
			if not existing.has(d.id):
				errors.append("Trail must be appended before baking: " + d.id)
			else:
				var record := d.path_record()
				if existing[d.id].pts != record.pts or existing[d.id].kind != d.kind or existing[d.id].get("surface_override", 0) != d.surface:
					errors.append("Trail changed after preparing its surface: " + d.id)
		for p in d.points:
			var margin := d.width * 0.5 + RoadRefinement.REACH + GameConfig.TILE
			if p.x < margin or p.y < margin or p.x > w.W * GameConfig.TILE - margin or p.y > w.H * GameConfig.TILE - margin:
				errors.append("Trail footprint outside prepared region: " + d.id)
	return errors

## Bake once on a fresh finished Heightfield, BEFORE TerrainBuilder.build_arrays.
## Only refined vertices change; mesh, wheels, walking and crash terrain share these values.
static func bake_elements(h: Heightfield, definitions: Array[TrailDefinition]) -> PackedStringArray:
	var r := h.road_refinement
	if r == null: return PackedStringArray(["finish_paths must run before trail earthworks"])
	if r.trail_elements_baked: return PackedStringArray(["Earthworks already baked; rebuild a fresh heightfield"])
	var errors := _validate(h.world, definitions, true)
	if not errors.is_empty(): return errors
	var started := Time.get_ticks_usec()
	var roads: Array[Dictionary] = []
	for route: Dictionary in h.world.trails:
		if route.kind != "road": continue
		for i in range(1, route.pts.size()):
			var a: Dictionary = route.pts[i - 1]
			var b: Dictionary = route.pts[i]
			roads.append({a = Vector2(a.x, a.y) * GameConfig.TILE, b = Vector2(b.x, b.y) * GameConfig.TILE,
				half = maxf(a.w, b.w) * GameConfig.TILE * 0.5})
	var offsets := {}
	var staged := {}
	for key: int in r.patches:
		var patch: Dictionary = r.patches[key]
		var hs: PackedFloat32Array = patch.h.duplicate()
		for iz in RoadRefinement.STRIDE:
			for ix in RoadRefinement.STRIDE:
				var gx := (key % h.world.W) * RoadRefinement.DIV + ix
				var gz := (key / h.world.W) * RoadRefinement.DIV + iz
				var vertex := Vector2i(gx, gz)
				if not offsets.has(vertex):
					var at := Vector2(gx, gz) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
					var offset := 0.0
					var cell := floori(at.y / GameConfig.TILE) * h.world.W + floori(at.x / GameConfig.TILE)
					var pin := smoothstep(RoadBed.SHORE.x, RoadBed.SHORE.y, h.world.dist_water[cell])
					if h.water_level[cell] != -INF: pin = 0.0
					for s: Dictionary in h.structures:
						pin = minf(pin, smoothstep(RoadBed.PIN, RoadBed.PIN + RoadBed.PIN_FADE, Grid.segment_dist(at.x, at.y, s.ax, s.az, s.bx, s.bz)))
					for road: Dictionary in roads:
						pin = minf(pin, smoothstep(road.half, road.half + RoadRefinement.REACH,
							Grid.segment_dist(at.x, at.y, road.a.x, road.a.y, road.b.x, road.b.y)))
					for d in definitions:
						if d.elements.is_empty(): continue
						var local := d.nearest(at)
						if local.z >= d.width * 0.5: continue
						for e in d.elements: offset += e.displacement(local.x, local.y, d.width * 0.5)
					if not is_finite(offset): return PackedStringArray(["Element produced non-finite terrain displacement"])
					# A crossing road remains authoritative; earthworks must not raise it.
					if patch.road[iz * RoadRefinement.STRIDE + ix] != 0: pin = 0.0
					offsets[vertex] = clampf(offset, -2.0, 2.0) * pin
				hs[iz * RoadRefinement.STRIDE + ix] += offsets[vertex]
		staged[key] = hs
	# Publish only after all elements succeeded; a rejected extension cannot leave half a bake.
	for key: int in staged: r.patches[key].h = staged[key]
	r.trail_elements_baked = true
	r.build_timings.trail_elements_ms = (Time.get_ticks_usec() - started) / 1000.0
	return PackedStringArray()
