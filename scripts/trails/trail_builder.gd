class_name TrailBuilder
extends RefCounted
## Adapter to existing civil paths. Call on private preparation data before nature/finish_paths.
## No generator RNG, navigation implementation, mesh builder or physics model of its own.
## The one surface builder of the trail earthworks: Trail Lab (TrailSite.prepare) and the game (StageTrailPlan.apply)
## both call bake_elements.
## Largest displacement of one vertex by the explicit elements (rollers, dips, berms…), m. Decorative features only:
## the route's own earthworks (TrailShaping) have no depth limit.
const ELEMENT_CAP := 2.0
## Cell of the road-segment index used by the earthwork bake, m.
const ROAD_CELL := 8.0
## Overlapping zones of two routes blend over this difference of normalized distance (half widths), not by a seam.
const BLEND := 1.0

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
## The zone of influence of every route (TrailShaping profile `reach`, wider for deeper earthworks) gets metre patches:
## a cell without one gets a patch whose vertices lie exactly on the old triangles (or equal the neighbouring patch), so
## the prepared ground continues past the narrow strip of the path without a wall or a gap at the patch edge. Only the
## patches of these zones are visited. Water, bridges and tunnels and the other civil paths stay pinned.
static func bake_elements(h: Heightfield, definitions: Array[TrailDefinition], limits := {}) -> PackedStringArray:
	var r := h.road_refinement
	if r == null: return PackedStringArray(["finish_paths must run before trail earthworks"])
	if r.trail_elements_baked: return PackedStringArray(["Earthworks already baked; rebuild a fresh heightfield"])
	var errors := _validate(h.world, definitions, true)
	if not errors.is_empty(): return errors
	var started := Time.get_ticks_usec()
	var w := h.world
	var pin_at := pins(h, definitions)
	var profiles := {}
	var shapes := {}
	var reaches := {}
	for d in definitions:
		reaches[d.id] = d.width * 0.5 + RoadRefinement.REACH
		if d.earthwork > 0.0:
			shapes[d.id] = d.shape()
			profiles[d.id] = shapes[d.id].profile(h, d, pin_at)
			reaches[d.id] = profiles[d.id].reach
	# Cells of the zones: every vertex closer than the reach to a route lies only in such cells.
	var zone := {}
	for d in definitions:
		var reach: float = reaches[d.id]
		var span := reach + GameConfig.TILE
		var station := 0.0
		var total := d.route_length()
		while true:
			var p := d.point_at(minf(station, total))
			for cz in range(maxi(0, floori((p.y - span) / GameConfig.TILE - 0.5)), mini(w.H - 1, ceili((p.y + span) / GameConfig.TILE - 0.5))):
				for cx in range(maxi(0, floori((p.x - span) / GameConfig.TILE - 0.5)), mini(w.W - 1, ceili((p.x + span) / GameConfig.TILE - 0.5))):
					var key := cz * w.W + cx
					if zone.has(key): continue
					if is_finite(d.nearest(Vector2(cx + 1.0, cz + 1.0) * GameConfig.TILE, reach + GameConfig.TILE * 0.71).z):
						zone[key] = true
			if station >= total: break
			station += GameConfig.TILE
	var offsets := {}
	var staged := {}
	var added := {}
	var stats := {}
	var keys := zone.keys()
	keys.sort()
	for key: int in keys:
		var cancel: Callable = limits.get("cancel", Callable())
		if (cancel.is_valid() and cancel.call()) or Time.get_ticks_msec() >= int(limits.get("deadline", 9223372036854775807)):
			return PackedStringArray(["бюджет/отмена формирования"])
		var patch: Dictionary = r.patches.get(key, {})
		if patch.is_empty():
			patch = _ground_patch(h, key)
			added[key] = patch
		var hs: PackedFloat32Array = patch.h.duplicate()
		for iz in RoadRefinement.STRIDE:
			for ix in RoadRefinement.STRIDE:
				var gx := (key % w.W) * RoadRefinement.DIV + ix
				var gz := (key / w.W) * RoadRefinement.DIV + iz
				var vertex := Vector2i(gx, gz)
				if not offsets.has(vertex):
					var at := Vector2(gx, gz) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
					var cell := clampi(floori(at.y / GameConfig.TILE), 0, w.H - 1) * w.W + clampi(floori(at.x / GameConfig.TILE), 0, w.W - 1)
					var pin: float = pin_at.call(at)
					# The nearest route by normalized distance shapes the vertex; where two zones overlap, the two nearest
					# blend over BLEND half widths instead of meeting in a seam. Profiles never add up.
					var best := {rank = INF}
					var second := {rank = INF}
					for d in definitions:
						var near := d.nearest(at, reaches[d.id])
						if not is_finite(near.z): continue
						var score := near.z / (d.width * 0.5)
						var found := {rank = score, d = d, local = near}
						if score < best.rank:
							second = best
							best = found
						elif score < second.rank:
							second = found
					var offset := 0.0
					if best.has("d"):
						offset = _route_offset(h, best.d, best.local, at, shapes, profiles)
						if second.has("d"):
							var other := _route_offset(h, second.d, second.local, at, shapes, profiles)
							var t := smoothstep(0.0, 1.0, (second.rank - best.rank) / BLEND)
							offset = lerpf((offset + other) * 0.5, offset, t)
					if not is_finite(offset): return PackedStringArray(["Trail earthworks produced a non-finite terrain displacement"])
					var displacement := offset * pin
					var base := h.ground_at(at.x, at.y)
					if displacement < 0.0:
						displacement = maxf(displacement, minf(0.0, RoadBed._wet_near(h, cell) + RoadBed.WATER_GAP - base))
					offsets[vertex] = displacement
					if best.has("d") and (best.d as TrailDefinition).earthwork > 0.0:
						var id: String = best.d.id
						var record: Dictionary = stats.get(id, {cut_m3 = 0.0, fill_m3 = 0.0, max_cut = 0.0, max_fill = 0.0, vertices = 0})
						var volume := displacement * RoadRefinement.STEP * RoadRefinement.STEP
						record.cut_m3 += maxf(0.0, -volume)
						record.fill_m3 += maxf(0.0, volume)
						record.max_cut = maxf(record.max_cut, -displacement)
						record.max_fill = maxf(record.max_fill, displacement)
						record.vertices += 1
						stats[id] = record
				hs[iz * RoadRefinement.STRIDE + ix] += offsets[vertex]
		staged[key] = hs
	# Publish only after every vertex succeeded; a rejected extension cannot leave half a bake.
	for key: int in added: r.patches[key] = added[key]
	for key: int in staged: r.patches[key].h = staged[key]
	for id: String in profiles:
		var record: Dictionary = stats.get(id, {})
		var p: Dictionary = profiles[id]
		record.merge({grade_natural = p.grade_natural, grade_designed = p.grade_designed, grade_used = p.grade_used,
			bank_peak = p.bank_peak, reach = p.reach, deepest = p.deepest}, true)
		r.trail_shaping[id] = record
	r.build_timings.trail_patches_added = added.size()
	r.build_timings.trail_zone_patches = zone.size()
	r.trail_elements_baked = true
	r.build_timings.trail_elements_ms = (Time.get_ticks_usec() - started) / 1000.0
	return PackedStringArray()

## How much of the earthworks may change the ground at a point (1 — all, 0 — nothing): water and the support of wet
## triangles, the shore zone, bridges and tunnels with their protected ends, and the other civil paths (all but the
## shaped `definitions`; an authored road among them stays pinned) stay as they are. The same function pins the vertices of the bake and anchors the design profile
## (TrailShaping.profile), so the designed grade is planned with the places it cannot change.
static func pins(h: Heightfield, definitions: Array[TrailDefinition]) -> Callable:
	var w := h.world
	var ids := {}
	for d in definitions:
		if d.kind != "road": ids[d.id] = true # an authored road crossing the routes keeps its footprint like any road
	# Other civil path segments by ROAD_CELL cells within their reach: a point checks only the paths that can pin it
	# (a saved world site carries thousands of segments; the result is the same as checking all of them).
	var roads := {}
	for route: Dictionary in w.trails:
		if not RoadBed.KINDS.has(route.kind) or ids.has(route.get("trail_id", "")): continue
		for i in range(1, route.pts.size()):
			var a: Dictionary = route.pts[i - 1]
			var b: Dictionary = route.pts[i]
			var road := {a = Vector2(a.x, a.y) * GameConfig.TILE, b = Vector2(b.x, b.y) * GameConfig.TILE,
				half = maxf(a.w, b.w) * GameConfig.TILE * 0.5}
			var reach: float = road.half + RoadRefinement.REACH
			var lo: Vector2 = ((road.a as Vector2).min(road.b) - Vector2.ONE * reach) / ROAD_CELL
			var hi: Vector2 = ((road.a as Vector2).max(road.b) + Vector2.ONE * reach) / ROAD_CELL
			for gz in range(floori(lo.y), floori(hi.y) + 1):
				for gx in range(floori(lo.x), floori(hi.x) + 1):
					var key := Vector2i(gx, gz)
					if not roads.has(key): roads[key] = []
					(roads[key] as Array).append(road)
	return func(at: Vector2) -> float:
		var cell := clampi(floori(at.y / GameConfig.TILE), 0, w.H - 1) * w.W + clampi(floori(at.x / GameConfig.TILE), 0, w.W - 1)
		var pin := smoothstep(RoadBed.SHORE.x, RoadBed.SHORE.y, w.dist_water[cell])
		# Protect the support of wet triangles as well as the wet cell itself.
		for dz in [-1.0, 0.0, 1.0]:
			for dx in [-1.0, 0.0, 1.0]:
				var cx := clampi(floori((at.x + dx * GameConfig.TILE) / GameConfig.TILE), 0, w.W - 1)
				var cz := clampi(floori((at.y + dz * GameConfig.TILE) / GameConfig.TILE), 0, w.H - 1)
				if h.water_level[cz * w.W + cx] != -INF: return 0.0
		for s: Dictionary in h.structures:
			pin = minf(pin, smoothstep(RoadBed.PIN, RoadBed.PIN + RoadBed.PIN_FADE, Grid.segment_dist(at.x, at.y, s.ax, s.az, s.bx, s.bz)))
		for road: Dictionary in roads.get(Vector2i((at / ROAD_CELL).floor()), []):
			pin = minf(pin, smoothstep(road.half, road.half + RoadRefinement.REACH,
				Grid.segment_dist(at.x, at.y, road.a.x, road.a.y, road.b.x, road.b.y)))
		return pin

## Shaping of route d at a vertex (no depth limit), the explicit elements (capped at ELEMENT_CAP) and the weight of shared
## junctions with itself.
static func _route_offset(h: Heightfield, d: TrailDefinition, local: Vector3, at: Vector2, shapes: Dictionary, profiles: Dictionary) -> float:
	var offset := 0.0
	if d.earthwork > 0.0: offset = (shapes[d.id] as TrailShaping).offset(h, d, local, at, profiles[d.id])
	# Explicit features have a compact footprint, so the shoulders stay continuous.
	var features := 0.0
	for e in d.elements:
		features += e.displacement(local.x, local.y, d.width * 0.5)
	offset += clampf(features, -ELEMENT_CAP, ELEMENT_CAP)
	if d.earthwork > 0.0: offset *= d.junction_weight(at, local.x)
	return offset

## A patch over cell `key` that changes nothing: vertices shared with a neighbouring patch take its values, the rest lie
## exactly on the coarse triangles (the patch splits a square along the same diagonal as the coarse grid).
static func _ground_patch(h: Heightfield, key: int) -> Dictionary:
	var w := h.world
	var r := h.road_refinement
	var n := RoadRefinement.STRIDE * RoadRefinement.STRIDE
	var hs := PackedFloat32Array()
	hs.resize(n)
	var colors := PackedColorArray()
	colors.resize(n)
	colors.fill(Color(0, 0, 0, 0))
	var uvs := PackedVector2Array()
	uvs.resize(n)
	var surfaces := PackedByteArray()
	surfaces.resize(n)
	var roads := PackedByteArray()
	roads.resize(n)
	var cx := key % w.W
	var cz := key / w.W
	for iz in RoadRefinement.STRIDE:
		for ix in RoadRefinement.STRIDE:
			var gx := cx * RoadRefinement.DIV + ix
			var gz := cz * RoadRefinement.DIV + iz
			var at := Vector2(gx, gz) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
			var value := h.base_ground_at(at.x, at.y)
			var k := iz * RoadRefinement.STRIDE + ix
			# the same metre vertex in a neighbouring patch (patch keys are cells; a vertex on an edge or corner is shared)
			for qz in [gz / RoadRefinement.DIV, gz / RoadRefinement.DIV - 1]:
				for qx in [gx / RoadRefinement.DIV, gx / RoadRefinement.DIV - 1]:
					var lx: int = gx - qx * RoadRefinement.DIV
					var lz: int = gz - qz * RoadRefinement.DIV
					if qx < 0 or qz < 0 or lx > RoadRefinement.DIV or lz > RoadRefinement.DIV: continue
					var q: Dictionary = r.patches.get(qz * w.W + qx, {})
					if q.is_empty(): continue
					var m := lz * RoadRefinement.STRIDE + lx
					value = q.h[m]
					colors[k] = q.color[m]
					uvs[k] = q.uv[m]
					surfaces[k] = q.surface[m]
					roads[k] = q.road[m]
			hs[k] = value
	return {h = hs, color = colors, uv = uvs, surface = surfaces, road = roads}
