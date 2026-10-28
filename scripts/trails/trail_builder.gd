class_name TrailBuilder
extends RefCounted
## Adapter to existing civil paths. Call on private preparation data before nature/finish_paths.
## No generator RNG, navigation implementation, mesh builder or physics model of its own.
## Largest total displacement of one vertex (shaping plus explicit elements), m.
const ELEMENT_CAP := 2.0
## Cell of the road-segment index used by the earthwork bake, m.
const ROAD_CELL := 8.0

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
				if existing[d.id].pts != record.pts or existing[d.id].kind != d.kind or existing[d.id].get("surface_override", 0) != d.surface or existing[d.id].get("formation", Vector3.ZERO) != record.formation or existing[d.id].get("closed", false) != d.closed:
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
	# Road segments by ROAD_CELL cells within their reach: a vertex checks only the roads that can pin it
	# (a saved world site carries thousands of road segments; the result is the same as checking all of them).
	var roads := {}
	for route: Dictionary in h.world.trails:
		if route.kind != "road": continue
		for i in range(1, route.pts.size()):
			var a: Dictionary = route.pts[i - 1]
			var b: Dictionary = route.pts[i]
			var road := {a = Vector2(a.x, a.y) * GameConfig.TILE, b = Vector2(b.x, b.y) * GameConfig.TILE,
				id = route.get("trail_id", ""), half = maxf(a.w, b.w) * GameConfig.TILE * 0.5}
			var reach: float = road.half + RoadRefinement.REACH
			var lo: Vector2 = ((road.a as Vector2).min(road.b) - Vector2.ONE * reach) / ROAD_CELL
			var hi: Vector2 = ((road.a as Vector2).max(road.b) + Vector2.ONE * reach) / ROAD_CELL
			for gz in range(floori(lo.y), floori(hi.y) + 1):
				for gx in range(floori(lo.x), floori(hi.x) + 1):
					var key := Vector2i(gx, gz)
					if not roads.has(key): roads[key] = []
					(roads[key] as Array).append(road)
	var profiles := {}
	var shapes := {}
	for d in definitions:
		if d.earthwork > 0.0:
			shapes[d.id] = d.shape()
			profiles[d.id] = shapes[d.id].profile(h, d)
	var offsets := {}
	var staged := {}
	var stats := {}
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
					# Protect the support of wet triangles as well as the wet cell itself.
					for dz in [-1.0, 0.0, 1.0]:
						for dx in [-1.0, 0.0, 1.0]:
							var cx := clampi(floori((at.x + dx * GameConfig.TILE) / GameConfig.TILE), 0, h.world.W - 1)
							var cz := clampi(floori((at.y + dz * GameConfig.TILE) / GameConfig.TILE), 0, h.world.H - 1)
							if h.water_level[cz * h.world.W + cx] != -INF: pin = 0.0
					for s: Dictionary in h.structures:
						pin = minf(pin, smoothstep(RoadBed.PIN, RoadBed.PIN + RoadBed.PIN_FADE, Grid.segment_dist(at.x, at.y, s.ax, s.az, s.bx, s.bz)))
					# Resolve overlaps by normalized distance, never add competing route profiles.
					var winner: TrailDefinition = null
					var local := Vector3.ZERO
					var rank := INF
					for d in definitions:
						var near := d.nearest(at, d.width * 0.5 + RoadRefinement.REACH)
						var score := near.z / (d.width * 0.5)
						if near.z < d.width * 0.5 + RoadRefinement.REACH and score < rank:
							winner = d
							local = near
							rank = score
					if winner != null:
						for road: Dictionary in roads.get(Vector2i((at / ROAD_CELL).floor()), []):
							if road.id == winner.id: continue
							pin = minf(pin, smoothstep(road.half, road.half + RoadRefinement.REACH,
								Grid.segment_dist(at.x, at.y, road.a.x, road.a.y, road.b.x, road.b.y)))
						if winner.earthwork > 0.0: offset = shapes[winner.id].offset(h, winner, local, at, profiles[winner.id])
						# Explicit features have a compact footprint, so the shoulders stay continuous.
						for e in winner.elements:
							offset += e.displacement(local.x, local.y, winner.width * 0.5)
					if winner != null and winner.earthwork > 0.0: offset *= winner.junction_weight(at, local.x)
					if not is_finite(offset): return PackedStringArray(["Element produced non-finite terrain displacement"])
					var displacement := clampf(offset, -ELEMENT_CAP, ELEMENT_CAP) * pin
					var base := h.ground_at(at.x, at.y)
					if displacement < 0.0:
						displacement = maxf(displacement, minf(0.0, RoadBed._wet_near(h, cell) + RoadBed.WATER_GAP - base))
					offsets[vertex] = displacement
					if winner != null and winner.earthwork > 0.0:
						var record: Dictionary = stats.get(winner.id, {cut_m3 = 0.0, fill_m3 = 0.0, max_cut = 0.0, max_fill = 0.0, vertices = 0})
						var volume := displacement * RoadRefinement.STEP * RoadRefinement.STEP
						record.cut_m3 += maxf(0.0, -volume)
						record.fill_m3 += maxf(0.0, volume)
						record.max_cut = maxf(record.max_cut, -displacement)
						record.max_fill = maxf(record.max_fill, displacement)
						record.vertices += 1
						stats[winner.id] = record
				hs[iz * RoadRefinement.STRIDE + ix] += offsets[vertex]
		staged[key] = hs
	# Publish only after all elements succeeded; a rejected extension cannot leave half a bake.
	for key: int in staged: r.patches[key].h = staged[key]
	for id: String in profiles:
		var record: Dictionary = stats.get(id, {})
		var p: Dictionary = profiles[id]
		record.merge({grade_natural = p.grade_natural, grade_designed = p.grade_designed, bank_peak = p.bank_peak}, true)
		r.trail_shaping[id] = record
	r.trail_elements_baked = true
	r.build_timings.trail_elements_ms = (Time.get_ticks_usec() - started) / 1000.0
	return PackedStringArray()
