extends RefCounted
## Dry gullies across existing singletrack. Only the final metre grid and local clearance change.

const TILE := GameConfig.TILE
const STEP := RoadRefinement.STEP
const DIV := RoadRefinement.DIV
const STRIDE := RoadRefinement.STRIDE
const HALF_LENGTH := 11
const APPROACH := 18
const BYPASS_OFFSET := 6.3
const BYPASS_HALF := 1.4
const SITE_SPACING := 100.0
const CANDIDATE_STEP := 23
const MAX_ATTEMPTS := 160
const GULLY_REACH := 5.1


static func apply(h: Heightfield, r: RoadRefinement, gap_clear: Callable) -> void:
	var w := h.world
	if w.biome.size() != w.N or w.dist_water.size() != w.N:
		return
	if WorldTemplate.has_single_road(w.template_id) and not WorldTemplate.allow_road_gaps(w.template_id):
		return
	var world_cells := Rect2i(0, 0, w.W, w.H)
	var seed := WGRandom.derive(w.seed_num, "road_gaps")
	var candidates: Array[Vector3i] = []
	for route: int in r.fit_routes:
		var trail: Dictionary = w.trails[route]
		if trail.kind != "trail" or trail.has("trail_id"):
			continue
		var points: PackedVector2Array = r.fit_routes[route].points
		var first := APPROACH + WGRandom.hash_cell(seed, route, 0, 0) % CANDIDATE_STEP
		if points.size() <= first + APPROACH:
			first = points.size() / 2
		for station in range(maxi(first, APPROACH), points.size() - APPROACH, CANDIDATE_STEP):
			var at := Vector2i((points[station] / TILE).floor())
			if not world_cells.has_point(at):
				continue
			var cell := at.y * w.W + at.x
			if w.biome[cell] in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE]:
				var global_at := at + w.world_origin
				candidates.append(Vector3i(WGRandom.hash_cell(seed, global_at.x, global_at.y, 1) >> 1, route, station))
	candidates.sort()
	var count := 2 + seed % 3
	var placed: Array[Vector2] = []
	for i in mini(candidates.size(), MAX_ATTEMPTS):
		var candidate := candidates[i]
		var route := candidate.y
		var station := candidate.z
		var points: PackedVector2Array = r.fit_routes[route].points
		var center := points[station]
		if placed.any(func(p: Vector2) -> bool: return p.distance_squared_to(center) < SITE_SPACING * SITE_SPACING):
			continue
		var rng := WGRandom.at(seed, "shape", roundi(center.x) + w.world_origin.x * int(TILE), roundi(center.y) + w.world_origin.y * int(TILE))
		if _place(h, r, route, points, station, rng, gap_clear):
			placed.append(center)
			if placed.size() >= count:
				break


static func _place(h: Heightfield, r: RoadRefinement, route: int, points: PackedVector2Array, station: int, rng: WGRandom, gap_clear: Callable) -> bool:
	# Center the pit on a metre vertex so both lips survive the triangle sampling more evenly.
	var center := points[station].snapped(Vector2.ONE * STEP)
	var axis := (points[station + HALF_LENGTH] - points[station - HALF_LENGTH]).normalized()
	var side := axis.orthogonal()
	var y0 := _ground(h, r, center - axis * HALF_LENGTH)
	var y1 := _ground(h, r, center + axis * HALF_LENGTH)
	var grade := (y1 - y0) / (2.0 * HALF_LENGTH)
	if axis == Vector2.ZERO or absf(grade) > 0.11:
		return false
	for offset in range(-APPROACH, APPROACH + 1, 3):
		var p := points[station + offset]
		var delta := p - center
		if absf(delta.dot(side)) > 0.8 or absf(_ground(h, r, p) - (y0 + (delta.dot(axis) + HALF_LENGTH) * grade)) > 0.8:
			return false
	var contact := r.sample(center.x, center.y, h.world.W)
	if contact.is_empty() or contact.road or contact.weight < 0.25:
		return false
	var material: int = contact.surface
	if material not in [RoadSurface.FOREST, RoadSurface.DIRT, RoadSurface.MEADOW]:
		return false
	var extent := axis.abs() * HALF_LENGTH + side.abs() * (BYPASS_OFFSET + BYPASS_HALF + STEP)
	var area := Rect2(center - extent, 2.0 * extent)
	var cells := _cells(area.grow(STEP), 0)
	if not _clear(h, center, cells) or not gap_clear.call(cells, center, route, station, APPROACH):
		return false
	var lip := lerpf(1.65, 1.8, rng.next_float())
	var rise := lerpf(0.97, 1.05, rng.next_float())
	var depth := lerpf(0.83, 0.98, rng.next_float())
	var left := _bypass(h, r, center, axis, -BYPASS_OFFSET, lip)
	var right := _bypass(h, r, center, axis, BYPASS_OFFSET, lip)
	var bypass := left if left.score < right.score + (rng.next_float() - 0.5) * 0.04 else right
	if bypass.score > 0.30:
		return false
	var shape := {center = center, axis = axis, side = side, base = (y0 + y1) * 0.5, grade = grade,
		lip = lip, rise = rise, depth = depth, ramp = 2.0 * rise / (TrailElement.GAP_LIP + 0.20),
		bend = lerpf(-0.85, 0.85, rng.next_float()), taper = lerpf(-0.55, 0.55, rng.next_float()),
		material = material, bypass = bypass, template_id = h.world.template_id}
	_bake(h, r, shape, _cells(area, 1))
	var line: Array = []
	var offsets: PackedFloat32Array = bypass.offsets
	for n in offsets.size():
		var p := center + axis * (n - HALF_LENGTH) + side * offsets[n]
		# Clearance includes the shoulders and the coarser vegetation grid's interpolation.
		line.append({x = p.x / TILE, y = p.y / TILE, w = 2.0 * (BYPASS_HALF + 0.65) / TILE})
	r.gaps.append({area = area, bypass = {kind = "trail", pts = line}})
	return true


static func _cells(area: Rect2, padding: int) -> Rect2i:
	var first := Vector2i((area.position / TILE - Vector2.ONE * 0.5).floor()) - Vector2i.ONE * padding
	var end := Vector2i((area.end / TILE - Vector2.ONE * 0.5).ceil()) + Vector2i.ONE * padding
	return Rect2i(first, end - first)


static func _clear(h: Heightfield, center: Vector2, cells: Rect2i) -> bool:
	var w := h.world
	if not Rect2i(1, 1, w.W - 3, w.H - 3).encloses(cells):
		return false
	for place: SettlementData in w.settlements:
		if center.distance_to(Vector2(place.x, place.y) * TILE) < 48.0:
			return false
	for place: SiteData in w.sites:
		if center.distance_to(Vector2(place.x, place.y) * TILE) < 22.0 + place.clear * TILE:
			return false
	for z in range(cells.position.y, cells.end.y):
		for x in range(cells.position.x, cells.end.x):
			var key := z * w.W + x
			if h._cells.has(key) or h.water_level[key] != -INF or w.dist_water[key] < 1.5:
				return false
	return true


static func _ground(h: Heightfield, r: RoadRefinement, at: Vector2) -> float:
	var y := r.height_at(at.x, at.y, h.world.W)
	return h.base_ground_at(at.x, at.y) if y == INF else y


static func _bypass(h: Heightfield, r: RoadRefinement, center: Vector2, axis: Vector2, offset: float, lip: float) -> Dictionary:
	var side := axis.orthogonal()
	var offsets := PackedFloat32Array()
	var heights := PackedFloat32Array()
	var score := 0.0
	for x in range(-HALF_LENGTH, HALF_LENGTH + 1):
		var across := offset * (1.0 - smoothstep(lip + 1.1, HALF_LENGTH, absf(x)))
		var p := center + axis * x + side * across
		var y := _ground(h, r, p)
		var a := _ground(h, r, p - side * BYPASS_HALF)
		var b := _ground(h, r, p + side * BYPASS_HALF)
		score = maxf(score, absf(a - b) / (2.0 * BYPASS_HALF))
		offsets.append(across)
		heights.append(y)
		if heights.size() > 2:
			score = maxf(score, absf(y - heights[-3]) * 0.5)
	var profile := heights.duplicate()
	for n in range(1, heights.size() - 1):
		profile[n] = (heights[n - 1] + 2.0 * heights[n] + heights[n + 1]) * 0.25
	return {offsets = offsets, profile = profile, score = score}


static func _bake(h: Heightfield, r: RoadRefinement, shape: Dictionary, cells: Rect2i) -> void:
	var w := h.world.W
	var source := {}
	# Read common vertices from the old patches first, including the outside edge of the edit.
	var border := cells.grow(1).intersection(Rect2i(0, 0, w - 1, h.world.H - 1))
	for z in range(border.position.y, border.end.y):
		for x in range(border.position.x, border.end.x):
			var key := z * w + x
			if not r.patches.has(key):
				continue
			var patch: Dictionary = r.patches[key]
			for j in STRIDE:
				for i in STRIDE:
					var n := j * STRIDE + i
					var vertex := Vector2i(x * DIV + i, z * DIV + j)
					source[vertex] = [patch.h[n], patch.color[n], patch.uv[n], patch.surface[n], patch.road[n]]
	var rgb: Array = RoadSurface.LIST[shape.material].color
	var tint := Color8(rgb[0], rgb[1], rgb[2]).srgb_to_linear()
	var organic: float = RoadSurface.LIST[shape.material].organic
	var edited := {}
	for z in range(cells.position.y, cells.end.y):
		for x in range(cells.position.x, cells.end.x):
			var patch := {h = PackedFloat32Array(), color = PackedColorArray(), uv = PackedVector2Array(),
				surface = PackedByteArray(), road = PackedByteArray()}
			for j in STRIDE:
				for i in STRIDE:
					var vertex := Vector2i(x * DIV + i, z * DIV + j)
					if not edited.has(vertex):
						var at := Vector2(vertex) * STEP + Vector2.ONE * TILE * 0.5
						var value: Array = source.get(vertex, [])
						if value.is_empty():
							value = [h.base_ground_at(at.x, at.y), Color(0, 0, 0, 0), Vector2.ZERO, 0, 0]
						edited[vertex] = _vertex(at, value, shape, tint, organic)
					var value: Array = edited[vertex]
					patch.h.append(value[0])
					patch.color.append(value[1])
					patch.uv.append(value[2])
					patch.surface.append(value[3])
					patch.road.append(value[4])
			r.patches[z * w + x] = patch


static func _vertex(at: Vector2, value: Array, s: Dictionary, tint: Color, organic: float) -> Array:
	var delta: Vector2 = at - s.center
	var x: float = delta.dot(s.axis)
	var z: float = delta.dot(s.side)
	var distance := absf(x)
	if distance >= HALF_LENGTH or absf(z) > BYPASS_OFFSET + BYPASS_HALF + STEP:
		return value
	var height: float = value[0]
	var color: Color = value[1]
	var uv: Vector2 = value[2]
	var surface: int = value[3]
	var road: int = value[4]
	var drift := smoothstep(1.4, GULLY_REACH, absf(z))
	var cut := 1.0 - smoothstep(0.20, s.lip, absf(x - s.bend * drift))
	var gully := 1.0 - smoothstep(1.65, GULLY_REACH + s.taper * signf(z), absf(z))
	var jump := (1.0 - smoothstep(1.5, 2.6, absf(z))) * (1.0 - smoothstep(s.lip + s.ramp, s.lip + s.ramp + 2.0, distance))
	var bank := TrailElement.gap_kicker(s.ramp + s.lip - distance, s.ramp, s.rise)
	if distance < s.lip:
		bank = s.rise * smoothstep(0.20, s.lip - 0.20, distance)
	var drop: float = s.depth * cut
	var bank_base: float = s.base + (x - clampf(x, -s.lip, s.lip)) * s.grade
	height = lerpf(height - drop * gully, bank_base + bank - drop, jump)
	var bare := (1.0 - smoothstep(s.lip - 0.38, s.lip + 0.16, distance)) * (1.0 - smoothstep(1.35, 2.75, absf(z)))
	color.a *= 1.0 - bare
	if bare > 0.5:
		surface = RoadSurface.NONE
		road = 0
		uv = Vector2(2.0, 0.0)
	var n := floori(x + HALF_LENGTH)
	var t := x + HALF_LENGTH - n
	var offsets: PackedFloat32Array = s.bypass.offsets
	var profile: PackedFloat32Array = s.bypass.profile
	var slope := offsets[n + 1] - offsets[n]
	var across := (z - lerpf(offsets[n], offsets[n + 1], t)) / sqrt(1.0 + slope * slope)
	var fade := 1.0 - smoothstep(HALF_LENGTH - 2.5, HALF_LENGTH, distance)
	var bench := (1.0 - smoothstep(BYPASS_HALF * 0.7, BYPASS_HALF + 0.8, absf(across))) * fade
	height = lerpf(height, lerpf(profile[n], profile[n + 1], t), bench)
	var tread := RoadRefinement.tread_mask(BYPASS_HALF, absf(across), 0.0, organic, false, false, 0.0, str(s.get("template_id", ""))) * fade
	if tread > color.a and tread > 0.03:
		color = Color(tint.r, tint.g, tint.b, tread)
		uv = Vector2(across / BYPASS_HALF, float(s.material) + 0.25)
		surface = s.material
		road = 0
	return [height, color, uv, surface, road]
