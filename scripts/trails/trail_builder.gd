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
	var roads: Array[Dictionary] = []
	for route: Dictionary in h.world.trails:
		if route.kind != "road": continue
		for i in range(1, route.pts.size()):
			var a: Dictionary = route.pts[i - 1]
			var b: Dictionary = route.pts[i]
			roads.append({a = Vector2(a.x, a.y) * GameConfig.TILE, b = Vector2(b.x, b.y) * GameConfig.TILE,
				id = route.get("trail_id", ""), half = maxf(a.w, b.w) * GameConfig.TILE * 0.5})
	var profiles := {}
	for d in definitions:
		if d.earthwork > 0.0: profiles[d.id] = _profile(h, d)
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
						var near := d.nearest(at)
						var score := near.z / (d.width * 0.5)
						if near.z < d.width * 0.5 + RoadRefinement.REACH and score < rank:
							winner = d
							local = near
							rank = score
					if winner != null:
						for road: Dictionary in roads:
							if road.id == winner.id: continue
							pin = minf(pin, smoothstep(road.half, road.half + RoadRefinement.REACH,
								Grid.segment_dist(at.x, at.y, road.a.x, road.a.y, road.b.x, road.b.y)))
						offset = _formation(h, winner, local, at, profiles.get(winner.id, {}))
						# Explicit features have a compact footprint, so the shoulders stay continuous.
						for e in winner.elements:
							offset += e.displacement(local.x, local.y, winner.width * 0.5)
					if winner != null and winner.earthwork > 0.0: offset *= winner.junction_weight(at, local.x)
					if not is_finite(offset): return PackedStringArray(["Element produced non-finite terrain displacement"])
					var cap := 0.35 if winner != null and winner.kind == "trail" else 2.0
					var displacement := clampf(offset, -cap, cap) * pin
					var base := h.ground_at(at.x, at.y)
					if displacement < 0.0:
						displacement = maxf(displacement, minf(0.0, RoadBed._wet_near(h, cell) + RoadBed.WATER_GAP - base))
					offsets[vertex] = displacement
				hs[iz * RoadRefinement.STRIDE + ix] += offsets[vertex]
		staged[key] = hs
	# Publish only after all elements succeeded; a rejected extension cannot leave half a bake.
	for key: int in staged: r.patches[key].h = staged[key]
	r.trail_elements_baked = true
	r.build_timings.trail_elements_ms = (Time.get_ticks_usec() - started) / 1000.0
	return PackedStringArray()

## Local cut/fill profile on the existing sparse refinement; no world-wide resampling.
const FORMATION := {
	"road": {window = 12.0, power = 1.0, cap = 2.0, bank = 0.08},
	"trail": {window = 3.0, power = 0.25, cap = 0.35, bank = 0.03},
	"mountain": {window = 6.0, power = 0.75, cap = 1.4, bank = 0.38},
}

## Sample once per metre, then interpolate instead of rebuilding the profile at every vertex.
static func _profile(h: Heightfield, d: TrailDefinition) -> Dictionary:
	var settings: Dictionary = FORMATION[d.kind]
	var total := d.route_length()
	var count := maxi(1, ceili(total / RoadRefinement.STEP))
	var levels := PackedFloat32Array()
	var banks := PackedFloat32Array()
	var points := PackedVector2Array()
	var tangents := PackedVector2Array()
	for j in count + 1:
		var station := total * j / count
		var window: float = settings.window
		if not d.closed: window = minf(window, minf(station, total - station))
		var level := 0.0
		for i in range(-4, 5):
			var p := d.point_at(station + window * i / 4.0)
			level += h.ground_at(p.x, p.y)
		levels.append(level / 9.0)
		points.append(d.point_at(station))
		tangents.append(d.tangent_at(station))
		banks.append(clampf(d.curvature_at(station) * 9.0, -float(settings.bank), float(settings.bank)) * d.auto_bank)
	return {levels = levels, banks = banks, points = points, tangents = tangents, total = total}

static func _formation(h: Heightfield, d: TrailDefinition, local: Vector3, at: Vector2, profile: Dictionary) -> float:
	if d.earthwork <= 0.0: return 0.0
	var settings: Dictionary = FORMATION[d.kind]
	var index: float = clampf(local.x / profile.total * (profile.levels.size() - 1), 0.0, profile.levels.size() - 1.0)
	var j := mini(floori(index), int(profile.levels.size()) - 2)
	var f := index - j
	var level := lerpf(profile.levels[j], profile.levels[j + 1], f)
	var tangent: Vector2 = profile.tangents[j].lerp(profile.tangents[j + 1], f).normalized()
	var center: Vector2 = profile.points[j].lerp(profile.points[j + 1], f)
	var across := (at - center).cross(tangent)
	var bank := lerpf(profile.banks[j], profile.banks[j + 1], f)
	var target := level + d.elevation_offset + across * bank
	var fade := 1.0 - smoothstep(d.width * 0.4, d.width * 0.5 + RoadRefinement.REACH, local.z)
	if not d.closed: fade *= smoothstep(0.0, 12.0, minf(local.x, profile.total - local.x))
	return clampf(target - h.ground_at(at.x, at.y), -float(settings.cap), float(settings.cap)) * float(settings.power) * d.earthwork * fade
