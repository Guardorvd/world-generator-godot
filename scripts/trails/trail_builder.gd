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
## Farthest a pinned point can lie from its routes' axes (zone reach), m: structures farther away are not checked.
const STRUCTURE_REACH := 400.0
## Cells of a bake whose vertices are evaluated together on the worker threads, and vertices per thread task.
const BATCH_CELLS := 256
const EVAL_BAND := 24

static func append_routes(w: WorldData, definitions: Array[TrailDefinition], rebuild_map := true) -> PackedStringArray:
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
	if rebuild_map: RoadSurface.rebuild_map(w)
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
	var again: Dictionary = limits.get("again", {}) # bake_without: only these cells are computed, the rest stays as baked
	var earthwork_source: Heightfield = limits.get("earthwork_source")
	var earthwork_input: Resource = limits.get("earthwork_input")
	var max_cut := -float(earthwork_input.earthwork_limits.max_cut) - 0.05 if earthwork_input != null else -INF
	var max_fill := float(earthwork_input.earthwork_limits.max_fill) + 0.05 if earthwork_input != null else INF
	var plan: Dictionary = again.plan if not again.is_empty() else _bake_plan(h, definitions)
	var pin_at: Callable = plan.pin_at
	var profiles: Dictionary = plan.profiles
	var shapes: Dictionary = plan.shapes
	var zone: Dictionary = plan.zone
	var spans := {} # of the elements as they are now: bake_without takes some out of a route after its plan was made
	for d: TrailDefinition in definitions: spans[d.id] = _spans(d)
	var offsets := {}
	var shades := {}
	var staged := {}
	var staged_colors := {}
	var added := {}
	var stats: Dictionary = again.get("stats", {}) # measured on the first bake: a removed element changes them little
	var keys: Array = again.cells.keys() if not again.is_empty() else zone.keys()
	keys.sort()
	var cancel: Callable = limits.get("cancel", Callable())
	var deadline := int(limits.get("deadline", 9223372036854775807))
	var first := 0
	while first < keys.size():
		# What a vertex gets depends only on the ground as it was before the bake (patches are published at the end), so the
		# vertices that no earlier cell met are evaluated for a batch of cells at once on the worker threads. The cells are
		# then applied one by one in the same order as before: limits, statistics and the first failure do not change.
		var last := mini(keys.size(), first + BATCH_CELLS)
		var slots: Array[Dictionary] = []
		var queued := {}
		var qx := PackedInt32Array()
		var qz := PackedInt32Array()
		var qslot := PackedInt32Array()
		for index in range(first, last):
			var key: int = keys[index]
			# one segment query per route for the whole cell (its vertices lie within the half diagonal of the centre)
			var center := Vector2((key % w.W) + 1.0, (key / w.W) + 1.0) * GameConfig.TILE
			var among := {}
			var joints := {}
			for d: TrailDefinition in zone[key]:
				var around := d.segments_around(center, zone[key][d], GameConfig.TILE * 0.71, d.width * 0.5 + RoadRefinement.REACH)
				among[d] = around.among
				joints[d] = around.joints
			for iz in RoadRefinement.STRIDE:
				for ix in RoadRefinement.STRIDE:
					var gx := (key % w.W) * RoadRefinement.DIV + ix
					var gz := (key / w.W) * RoadRefinement.DIV + iz
					var vertex := Vector2i(gx, gz)
					if offsets.has(vertex) or queued.has(vertex): continue
					queued[vertex] = qx.size()
					qx.append(gx)
					qz.append(gz)
					qslot.append(slots.size())
			slots.append({zone = zone[key], among = among, joints = joints})
		var evaluated := _evaluate(h, qx, qz, qslot, slots, profiles, shapes, spans, pin_at)
		for index in range(first, last):
			var key: int = keys[index]
			if (cancel.is_valid() and cancel.call()) or Time.get_ticks_msec() >= deadline:
				return PackedStringArray(["бюджет/отмена формирования"])
			var patch: Dictionary = r.patches.get(key, {})
			if patch.is_empty():
				patch = _ground_patch(h, key)
				added[key] = patch
			var touched := false
			var hs: PackedFloat32Array = patch.h.duplicate()
			var colors: PackedColorArray = patch.color.duplicate()
			var source_vertices := PackedFloat32Array()
			if earthwork_source != null and earthwork_source.road_refinement.patches.has(key):
				source_vertices = earthwork_source.road_refinement.patches[key].h
			for iz in RoadRefinement.STRIDE:
				for ix in RoadRefinement.STRIDE:
					var gx := (key % w.W) * RoadRefinement.DIV + ix
					var gz := (key / w.W) * RoadRefinement.DIV + iz
					var vertex := Vector2i(gx, gz)
					if not offsets.has(vertex):
						var n: int = queued[vertex]
						if evaluated.bad[n] != 0: return PackedStringArray(["Trail earthworks produced a non-finite terrain displacement"])
						var displacement: float = evaluated.displacement[n]
						offsets[vertex] = displacement
						var shade_value: float = evaluated.shade[n]
						if shade_value != 0.0: shades[vertex] = shade_value
						var best: TrailDefinition = evaluated.best[n]
						if again.is_empty() and best != null and best.earthwork > 0.0:
							var id: String = best.id
							if not stats.has(id): stats[id] = {cut_m3 = 0.0, fill_m3 = 0.0, max_cut = 0.0, max_fill = 0.0, vertices = 0}
							var record: Dictionary = stats[id]
							record.vertices += 1
							if displacement != 0.0:
								var volume := displacement * RoadRefinement.STEP * RoadRefinement.STEP
								record.cut_m3 += maxf(0.0, -volume)
								record.fill_m3 += maxf(0.0, volume)
								record.max_cut = maxf(record.max_cut, -displacement)
								record.max_fill = maxf(record.max_fill, displacement)
					hs[iz * RoadRefinement.STRIDE + ix] += offsets[vertex]
					if offsets[vertex] != 0.0: touched = true
					# Reject on the actual rounded final vertex, before spending the rest of
					# the bake on a doomed proposal. The normal final audit still covers the
					# entire surface, including base formation outside this zone.
					if earthwork_source != null and earthwork_input != null:
						var at := Vector2(gx, gz) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
						var n := iz * RoadRefinement.STRIDE + ix
						var delta: float = hs[n] - (source_vertices[n] if not source_vertices.is_empty() else earthwork_source.ground_at(at.x, at.y))
						if delta < max_cut or delta > max_fill:
							limits.failed_at = at
							return PackedStringArray(["превышен игровой предел земляных работ"])
						if absf(delta) > 0.05 and earthwork_input.blocked(at):
							limits.failed_at = at
							return PackedStringArray(["земляные работы затрагивают воду, инфраструктуру или готовый путь"])
					var shade: float = shades.get(vertex, 0.0)
					if shade != 0.0:
						touched = true
						var c := colors[iz * RoadRefinement.STRIDE + ix]
						var k := 1.0 + shade * c.a
						colors[iz * RoadRefinement.STRIDE + ix] = Color(c.r * k, c.g * k, c.b * k, c.a)
			# The zone only reached this cell, nothing changed: the old ground stays, no metre patch to mesh and store.
			if not touched and added.has(key) and _on_ground(h, key, hs):
				added.erase(key)
				continue
			staged[key] = hs
			staged_colors[key] = colors
		first = last
	# Publish only after every vertex succeeded; a rejected extension cannot leave half a bake.
	var before: Dictionary = again.get("before", {})
	if limits.get("keep_bake", false) and again.is_empty():
		for key: int in zone: before[key] = r.patches.get(key)
	for key: int in added: r.patches[key] = added[key]
	for key: int in staged:
		var patch: Dictionary = r.patches[key].duplicate()
		patch.h = staged[key]
		patch.color = staged_colors[key]
		r.patches[key] = patch
	if not again.is_empty():
		for key: int in zone:
			if again.cells.has(key): continue
			if again.baked[key] == null: r.patches.erase(key)
			else: r.patches[key] = again.baked[key]
	if limits.get("keep_bake", false):
		var baked := {}
		for key: int in zone: baked[key] = r.patches.get(key)
		limits.bake = {plan = plan, before = before, baked = baked, stats = stats}
	for id: String in profiles:
		var record: Dictionary = stats.get(id, {})
		var p: Dictionary = profiles[id]
		record.merge({grade_natural = p.grade_natural, grade_designed = p.grade_designed, grade_used = p.grade_used,
			bank_peak = p.bank_peak, reach = p.reach, deepest = p.deepest}, true)
		r.trail_shaping[id] = record
	r.build_timings.trail_patches_added = added.size()
	r.build_timings.trail_zone_patches = zone.size()
	r.build_timings.trail_profile_ms = 0.0 if not again.is_empty() else plan.profile_ms
	r.build_timings.trail_zone_ms = 0.0 if not again.is_empty() else plan.zone_ms
	r.trail_elements_baked = true
	r.build_timings.trail_elements_ms = (Time.get_ticks_usec() - started) / 1000.0
	if earthwork_source != null and earthwork_input != null: limits.checked = zone # every vertex of these patches passed the limits above
	return PackedStringArray()

## The displacement of vertices (qx, qz) of the metre grid: `slot` of each is the cell that met it first (its routes, the segments
## near it and the junctions). Reads the ground as it is and changes nothing, so any order and thread give the same numbers;
## the result is in the order of the vertices. `bad` marks a non-finite offset, `shade` is the tint of a raised or dug feature.
static func _evaluate(h: Heightfield, qx: PackedInt32Array, qz: PackedInt32Array, qslot: PackedInt32Array, slots: Array[Dictionary], profiles: Dictionary, shapes: Dictionary, spans: Dictionary, pin_at: Callable) -> Dictionary:
	var w := h.world
	var cells_x := w.W
	var cells_z := w.H
	var parts := Parallel.bands(qx.size(), func(from: int, to: int) -> Dictionary:
		var displacements := PackedFloat64Array()
		var shades := PackedFloat64Array()
		var bad := PackedByteArray()
		var bests: Array = []
		for n in range(from, to):
			var at := Vector2(qx[n], qz[n]) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
			var slot: Dictionary = slots[qslot[n]]
			var zone: Dictionary = slot.zone
			var among: Dictionary = slot.among
			var joints: Dictionary = slot.joints
			# The nearest route by normalized distance shapes the vertex; where two zones overlap, the two nearest
			# blend over BLEND half widths instead of meeting in a seam. Profiles never add up.
			var best: TrailDefinition = null
			var best_rank := INF
			var best_local := Vector3.ZERO
			var second: TrailDefinition = null
			var second_rank := INF
			var second_local := Vector3.ZERO
			for d: TrailDefinition in zone:
				if (among[d] as PackedInt32Array).is_empty(): continue # no segment within reach of this cell
				var near := d.nearest(at, zone[d], among[d])
				if not is_finite(near.z): continue
				if profiles.has(d.id) and near.z > TrailShaping.reach_at(profiles[d.id], near.x): continue
				var score := near.z / (d.width * 0.5)
				if score < best_rank:
					second = best
					second_rank = best_rank
					second_local = best_local
					best = d
					best_rank = score
					best_local = near
				elif score < second_rank:
					second = d
					second_rank = score
					second_local = near
			var offset := 0.0
			if best != null:
				offset = _route_offset(h, best, best_local, at, shapes, profiles, joints[best], spans[best.id])
				if second != null:
					var other := _route_offset(h, second, second_local, at, shapes, profiles, joints[second], spans[second.id])
					var t := smoothstep(0.0, 1.0, (second_rank - best_rank) / BLEND)
					offset = lerpf((offset + other) * 0.5, offset, t)
			if not is_finite(offset):
				displacements.append(0.0)
				shades.append(0.0)
				bad.append(1)
				bests.append(null)
				continue
			var tint := _feature_shade(best, best_local, spans[best.id]) if best != null else 0.0
			# Past the run-out of the side slopes nothing changes: neither pins nor water matter.
			var pin: float = pin_at.call(at) if offset != 0.0 or tint != 0.0 else 1.0
			var displacement := offset * pin
			if displacement < 0.0:
				var cell := clampi(floori(at.y / GameConfig.TILE), 0, cells_z - 1) * cells_x + clampi(floori(at.x / GameConfig.TILE), 0, cells_x - 1)
				displacement = maxf(displacement, minf(0.0, RoadBed.wet_near(h, cell) + RoadBed.WATER_GAP - h.ground_at(at.x, at.y)))
			displacements.append(displacement)
			shades.append(tint * pin)
			bad.append(0)
			bests.append(best)
		return {displacement = displacements, shade = shades, bad = bad, best = bests}, EVAL_BAND)
	var displacement := PackedFloat64Array()
	var shade := PackedFloat64Array()
	var bad := PackedByteArray()
	var best: Array = []
	for part: Dictionary in parts:
		displacement.append_array(part.displacement)
		shade.append_array(part.shade)
		bad.append_array(part.bad)
		best.append_array(part.best)
	return {displacement = displacement, shade = shade, bad = bad, best = best}

## What a bake of these routes needs once: pins, design profiles and the cells of their zones.
static func _bake_plan(h: Heightfield, definitions: Array[TrailDefinition]) -> Dictionary:
	var started := Time.get_ticks_usec()
	var w := h.world
	var pin_at := pins(h, definitions)
	var profiles := {}
	var shapes := {}
	for d in definitions:
		if d.earthwork > 0.0:
			shapes[d.id] = d.shape()
			profiles[d.id] = shapes[d.id].profile(h, d, pin_at)
	var profile_ms := (Time.get_ticks_usec() - started) / 1000.0
	# Cells of the zones: every vertex closer than the reach of its station lies only in such cells (a cell's vertices are
	# within its half diagonal of the centre; TILE leaves room for the metre between stations). Every zone cell maps the
	# routes that can reach it (in definition order) to their widest reach there: a vertex asks only those.
	var zone := {}
	for d in definitions:
		var plain := d.earthwork <= 0.0
		var stations := ceili(d.route_length() / RoadRefinement.STEP) if plain else (profiles[d.id].points as PackedVector2Array).size() - 1
		for j in stations + 1:
			var p: Vector2 = d.point_at(j * RoadRefinement.STEP) if plain else profiles[d.id].points[j]
			var reach: float = d.width * 0.5 + RoadRefinement.REACH if plain else profiles[d.id].reaches[j]
			var span := reach + GameConfig.TILE
			var limit := span * span
			for cz in range(maxi(0, floori((p.y - span) / GameConfig.TILE - 0.5)), mini(w.H - 1, ceili((p.y + span) / GameConfig.TILE - 0.5))):
				for cx in range(maxi(0, floori((p.x - span) / GameConfig.TILE - 0.5)), mini(w.W - 1, ceili((p.x + span) / GameConfig.TILE - 0.5))):
					if p.distance_squared_to(Vector2(cx + 1.0, cz + 1.0) * GameConfig.TILE) > limit: continue
					var key := cz * w.W + cx
					if not zone.has(key): zone[key] = {}
					if reach > float(zone[key].get(d, 0.0)): zone[key][d] = reach
	return {pin_at = pin_at, profiles = profiles, shapes = shapes, zone = zone, profile_ms = profile_ms, zone_ms = (Time.get_ticks_usec() - started) / 1000.0 - profile_ms}

## The route d after bake_elements with limits.keep_bake, with removed elements already taken out of it: nothing else
## about the route changed, so only the cells under these elements are computed again; the result is the same as a new bake.
## Share of the zone recomputed goes to limits.again_share.
static func bake_without(h: Heightfield, d: TrailDefinition, removed: Array[TrailElement], limits: Dictionary) -> PackedStringArray:
	var r := h.road_refinement
	var bake: Dictionary = limits.bake
	var zone: Dictionary = bake.plan.zone
	var cells := {}
	var span := d.width * 0.5 + TrailElement.FOOTPRINT + GameConfig.TILE
	for e in removed:
		var station := maxf(0.0, e.station - e.length * 0.5 - RoadRefinement.STEP)
		while station <= e.station + e.length * 0.5 + RoadRefinement.STEP:
			var p := d.point_at(station)
			for cz in range(maxi(0, floori((p.y - span) / GameConfig.TILE - 0.5)), mini(h.world.H - 1, ceili((p.y + span) / GameConfig.TILE - 0.5))):
				for cx in range(maxi(0, floori((p.x - span) / GameConfig.TILE - 0.5)), mini(h.world.W - 1, ceili((p.x + span) / GameConfig.TILE - 0.5))):
					var key := cz * h.world.W + cx
					if zone.has(key) and p.distance_squared_to(Vector2(cx + 1.0, cz + 1.0) * GameConfig.TILE) <= span * span: cells[key] = true
			station += RoadRefinement.STEP
	for key: int in bake.before:
		if bake.before[key] == null: r.patches.erase(key)
		else: r.patches[key] = bake.before[key]
	r.trail_elements_baked = false
	limits.again = {plan = bake.plan, cells = cells, before = bake.before, baked = bake.baked, stats = bake.stats}
	limits.again_share = float(cells.size()) / maxi(1, zone.size())
	return bake_elements(h, [d] as Array[TrailDefinition], limits)

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
	# Only structures that can reach the routes' zones (exact: a farther one gives smoothstep 1 everywhere they are asked).
	var box := Rect2(definitions[0].points[0], Vector2.ZERO) if not definitions.is_empty() and not definitions[0].points.is_empty() else Rect2()
	for d in definitions:
		for p in d.points: box = box.expand(p)
	box = box.grow(RoadBed.PIN + RoadBed.PIN_FADE + STRUCTURE_REACH)
	var structures: Array[Dictionary] = []
	for s: Dictionary in h.structures:
		if Rect2(Vector2(s.ax, s.az), Vector2.ZERO).expand(Vector2(s.bx, s.bz)).intersects(box, true): structures.append(s)
	# Called from several threads at once: it keeps nothing between calls.
	return func(at: Vector2) -> float:
		var cell := clampi(floori(at.y / GameConfig.TILE), 0, w.H - 1) * w.W + clampi(floori(at.x / GameConfig.TILE), 0, w.W - 1)
		var pin := smoothstep(RoadBed.SHORE.x, RoadBed.SHORE.y, w.dist_water[cell])
		# Protect the support of wet triangles as well as the wet cell itself (the 3 x 3 cells around).
		var ax := floori(at.x / GameConfig.TILE)
		var az := floori(at.y / GameConfig.TILE)
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if h.water_level[clampi(az + dz, 0, w.H - 1) * w.W + clampi(ax + dx, 0, w.W - 1)] != -INF: return 0.0
		for s: Dictionary in structures:
			pin = minf(pin, smoothstep(RoadBed.PIN, RoadBed.PIN + RoadBed.PIN_FADE, Grid.segment_dist(at.x, at.y, s.ax, s.az, s.bx, s.bz)))
		for road: Dictionary in roads.get(Vector2i((at / ROAD_CELL).floor()), []):
			pin = minf(pin, smoothstep(road.half, road.half + RoadRefinement.REACH,
				Grid.segment_dist(at.x, at.y, road.a.x, road.a.y, road.b.x, road.b.y)))
		return pin

## Shaping of route d at a vertex (no depth limit), the explicit elements (capped at ELEMENT_CAP) and the weight of shared
## junctions with itself (`joints`: empty — no such place near this vertex).
static func _route_offset(h: Heightfield, d: TrailDefinition, local: Vector3, at: Vector2, shapes: Dictionary, profiles: Dictionary, joints: PackedInt32Array, span: Dictionary) -> float:
	var offset := 0.0
	if d.earthwork > 0.0: offset = (shapes[d.id] as TrailShaping).offset(h, d, local, at, profiles[d.id])
	# Explicit features have a compact footprint, so the shoulders stay continuous.
	var features := 0.0
	if absf(local.y) < d.width * 0.5 + TrailElement.FOOTPRINT:
		var stations: PackedFloat64Array = span.station
		var halves: PackedFloat64Array = span.half
		for k in stations.size():
			if absf(local.x - stations[k]) < halves[k]: # displacement() is zero outside the element
				features += d.elements[k].displacement(local.x, local.y, d.width * 0.5)
	# открытый пролёт (генератор v3): элементы не насыпаются, полотно опускается на глубину овражка от своего уровня
	var open := d.open_at(local.x) if not d.open_spans.is_empty() else Vector2.ZERO
	offset += clampf(features, -ELEMENT_CAP, ELEMENT_CAP) * (1.0 - open.x) - open.y * open.x
	if d.earthwork > 0.0 and not joints.is_empty(): offset *= d.junction_weight(at, local.x, joints)
	return offset

## Where each element acts along its route (station and half length), in element order: a vertex compares two numbers
## per element instead of reading the element's properties.
static func _spans(d: TrailDefinition) -> Dictionary:
	var stations := PackedFloat64Array()
	var halves := PackedFloat64Array()
	for e in d.elements:
		stations.append(e.station)
		halves.append(e.length * 0.5)
	return {station = stations, half = halves}

## Readable features (31.10): the tread of a raised feature is lighter (dry, packed by tyres), a dug one darker (damp),
## so pump rollers, tables and gaps read from a distance instead of blending into the trail. Brightness change, -1..1.
const SHADE_UP := 0.28
const SHADE_DOWN := 0.22
static func _feature_shade(d: TrailDefinition, local: Vector3, span: Dictionary) -> float:
	var features := 0.0
	if absf(local.y) >= d.width * 0.5 + TrailElement.FOOTPRINT: return 0.0
	var stations: PackedFloat64Array = span.station
	var halves: PackedFloat64Array = span.half
	for k in stations.size():
		if absf(local.x - stations[k]) < halves[k]:
			var e: TrailElement = d.elements[k]
			if not TrailElement.places_objects(e.profile) \
					and e.profile not in [TrailElement.Profile.BERM, TrailElement.Profile.S_BERM, TrailElement.Profile.OFF_CAMBER]:
				features += e.displacement(local.x, local.y, d.width * 0.5)
	if features >= 0.0: return SHADE_UP * smoothstep(0.1, 0.9, features)
	return -SHADE_DOWN * smoothstep(0.05, 0.5, -features)

## Do the vertices of a patch over cell `key` lie on the coarse ground, to the precision of the stored heights?
static func _on_ground(h: Heightfield, key: int, hs: PackedFloat32Array) -> bool:
	for iz in RoadRefinement.STRIDE:
		for ix in RoadRefinement.STRIDE:
			var at := Vector2((key % h.world.W) * RoadRefinement.DIV + ix, (key / h.world.W) * RoadRefinement.DIV + iz) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
			if absf(hs[iz * RoadRefinement.STRIDE + ix] - h.base_ground_at(at.x, at.y)) > 0.001: return false
	return true

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
					if qx == cx and qz == cz: continue # this very cell has no patch: that is why it is made
					var found: Variant = r.patches.get(qz * w.W + qx)
					if found == null: continue
					var q: Dictionary = found
					var m := lz * RoadRefinement.STRIDE + lx
					value = q.h[m]
					colors[k] = q.color[m]
					uvs[k] = q.uv[m]
					surfaces[k] = q.surface[m]
					roads[k] = q.road[m]
			hs[k] = value
	return {h = hs, color = colors, uv = uvs, surface = surfaces, road = roads}
