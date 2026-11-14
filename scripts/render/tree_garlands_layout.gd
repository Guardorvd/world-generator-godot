class_name TreeGarlandsLayout
extends RefCounted
## Детерминированный отбор мест и расчёт геометрии парковых гирлянд поверх готового мира.
## Не изменяет генератор растительности, WorldData и ключи WorldCache; работает в фоне по снимку.

const TILE := GameConfig.TILE
const SEED := 15109
const MIN_CLUSTER_SPACING := 430.0
const CLUSTER_RADIUS := 86.0
const CORRIDOR_HALF := 14.5
const MIN_SPAN := 4.4
const MAX_SPAN := 15.2
const MIN_CLEARANCE := 3.7       # запас от полотна/настила до нижней точки лампы (с учётом камеры и прыжков)
const BULB_DROP := 0.24          # общая длина подвеса и колбы от провода вниз
const BULB_CENTER_Y := -0.165    # центр стеклянной колбы относительно точки крепления на проводе
const MIN_BULBS := 14
const TARGET_BULBS := 50
const MAX_BULBS := 62
const WIRE_SEGMENTS := 7
const SPAN_HALF_W := 0.015
const MAX_ATTACH_REL := 8.8
const MIN_TREE_HEIGHT := 9.2
const MIN_TRUNK_R := 0.14
const CLEAR_START_R := 50.0
const SETTLEMENT_NEAR := 56.0
const SETTLEMENT_FAR := 225.0
const SITE_NEAR := 20.0
const SITE_FAR := 112.0
const DEEP_FOREST_DIST := 240.0
const LIGHT_STEP := 16.0

enum Archetype { ALLEY_ZIGZAG, EDGE_PROMENADE, GLADE_CROWN }

const ELIGIBLE := {
	Biomes.T_PINE: true,
	Biomes.T_BIRCH: true,
	Biomes.T_OAK: true,
	Biomes.T_SNOWPINE: true,
	Biomes.T_JUNGLE: true,
}

## Доля высоты дерева от комля до нижних сучьев, пригодная для чистой обвязки ствола.
const CLEAR_TRUNK_FRAC := {
	Biomes.T_PINE: 0.44,
	Biomes.T_BIRCH: 0.43,
	Biomes.T_OAK: 0.40,
	Biomes.T_SNOWPINE: 0.34,
	Biomes.T_JUNGLE: 0.42,
}


## Общий трёхзонный меш лампы (подвес+патрон + колба) в 1 поверхности через UV (UV.x: 0 = патрон, 1 = колба).
static func bulb_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_frustum(st, 0.0, -0.055, 0.008, 0.009, 6, Vector2.ZERO)
	_append_frustum(st, -0.053, -0.104, 0.016, 0.025, 8, Vector2.ZERO)
	# Колба: от горловины (-0.100) до донца (-0.238); UV.y задаёт профиль яркости нити внутри.
	var rings := [
		[-0.100, 0.023, 0.20],
		[-0.125, 0.050, 0.55],
		[-0.165, 0.068, 1.00],
		[-0.206, 0.056, 0.80],
		[-0.230, 0.030, 0.45],
		[-0.238, 0.004, 0.25],
	]
	var segs := 10
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for r in rings.size():
		var y: float = rings[r][0]
		var rad: float = rings[r][1]
		var core_g: float = rings[r][2]
		var next_y: float = rings[mini(r + 1, rings.size() - 1)][0]
		var prev_y: float = rings[maxi(r - 1, 0)][0]
		var next_r: float = rings[mini(r + 1, rings.size() - 1)][1]
		var prev_r: float = rings[maxi(r - 1, 0)][1]
		var dr := next_r - prev_r
		var dy := next_y - prev_y
		for s in segs + 1:
			var a := float(s) * TAU / float(segs)
			var ca := cos(a)
			var sa := sin(a)
			verts.append(Vector3(ca * rad, y, sa * rad))
			var n := Vector3(ca * (-dy), dr, sa * (-dy))
			if n.length_squared() < 1e-6:
				n = Vector3.DOWN if r == rings.size() - 1 else Vector3.UP
			norms.append(n.normalized())
			uvs.append(Vector2(1.0, core_g))
	for r in rings.size() - 1:
		for s in segs:
			var a := r * (segs + 1) + s
			var b := a + segs + 1
			idx.append_array([a, b, a + 1, a + 1, b, b + 1])
	var sphere := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	sphere.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	st.append_from(sphere, 0, Transform3D.IDENTITY)
	st.index()
	return st.commit()


## Простой квад [-1..1] в XY для ночных billboard-ореолов.
static func halo_quad_mesh() -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-1.0, -1.0, 0.0), Vector3(1.0, -1.0, 0.0),
		Vector3(1.0, 1.0, 0.0), Vector3(-1.0, 1.0, 0.0),
	])
	arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func _append_frustum(st: SurfaceTool, y_top: float, y_bot: float, r_top: float, r_bot: float, segs: int, uv_tag: Vector2) -> void:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var slope_y := r_bot - r_top
	var slope_r := y_top - y_bot
	for i in range(segs + 1):
		var a := float(i) * TAU / float(segs)
		var ca := cos(a)
		var sa := sin(a)
		var n := Vector3(ca * slope_r, slope_y, sa * slope_r).normalized()
		verts.append(Vector3(ca * r_top, y_top, sa * r_top))
		norms.append(n)
		uvs.append(uv_tag)
		verts.append(Vector3(ca * r_bot, y_bot, sa * r_bot))
		norms.append(n)
		uvs.append(uv_tag)
	for i in segs:
		var a := i * 2
		idx.append_array([a, a + 1, a + 2, a + 2, a + 1, a + 3])
	var m := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	st.append_from(m, 0, Transform3D.IDENTITY)


## Поиск редких парковых и лесных кластеров на базовой карте мира.
static func find_base_clusters(world: WorldData, heights: Heightfield, clear_spots: Array[Vector2]) -> Array[Dictionary]:
	if world == null or heights == null or world.W <= 0 or world.H <= 0:
		return []
	var margin := 24.0
	var inner := Rect2(margin, margin, maxf(0.0, world.W * TILE - margin * 2.0), maxf(0.0, world.H * TILE - margin * 2.0))
	var settlements := _entity_points(world.settlements)
	var sites := _entity_points(world.sites)
	var authored := _authored_routes(world.trail_plan)
	var gates := _gate_positions(heights)
	var candidates := _scan_trails(world, heights, world.trails, authored, gates, settlements, sites, clear_spots, inner, false)
	var area_km2 := (world.W * TILE / 1000.0) * (world.H * TILE / 1000.0)
	var cap := clampi(roundi(area_km2 * 0.60), 2, 7)
	return _select_spaced_clusters(candidates, [], cap)


## Поиск кластеров при коммите нового внешнего региона RegionStream (с учётом уже выбранных центров).
static func find_region_clusters(world: WorldData, heights: Heightfield, region_key: Vector2i, region: Dictionary, existing: Array[Dictionary], clear_spots: Array[Vector2]) -> Array[Dictionary]:
	if world == null or heights == null or not region.has("rect") or not region.has("fields"):
		return []
	var rect: Rect2i = region.rect
	var reg_trails: Array = region.get("decor", {}).get("trails", [])
	if reg_trails.is_empty():
		return []
	var reg_box := Rect2(Vector2(rect.position) * TILE, Vector2(rect.size) * TILE).grow(-92.0)
	if reg_box.size.x <= 0.0 or reg_box.size.y <= 0.0:
		return []
	var settlements := _entity_points(world.settlements)
	settlements.append_array(_entity_points(region.get("decor", {}).get("settlements", [])))
	settlements.append_array(_entity_points(region.get("settlements", [])))
	var sites := _entity_points(world.sites)
	var authored := _authored_routes(region.get("trail_plan", {}))
	var gates := _gate_positions(heights)
	var candidates := _scan_trails(world, heights, reg_trails, authored, gates, settlements, sites, clear_spots, reg_box, true, region_key)
	var area_km2 := (rect.size.x * TILE / 1000.0) * (rect.size.y * TILE / 1000.0)
	var cap := clampi(roundi(area_km2 * 1.3), 1, 2)
	return _select_spaced_clusters(candidates, existing, cap)


static func _entity_points(list: Array) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for item in list:
		out.append(Vector2(item.x, item.y) * TILE)
	return out


static func _authored_routes(plan: Dictionary) -> Dictionary:
	var out := {}
	if plan.get("state") == "found":
		for d: TrailDefinition in StageTrailPlan._kit(plan):
			out[d.id] = d
	return out


static func _gate_positions(heights: Heightfield) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if heights == null or heights.trail_technical.is_empty():
		return out
	for p: Dictionary in heights.trail_technical.get("props", []):
		if p.get("kind") == "gate" and p.has("pos"):
			var v: Vector3 = p.pos
			out.append(Vector2(v.x, v.z))
	return out


static func _trail_point(t: Dictionary, idx: int) -> Vector2:
	var p = t.pts[idx]
	return Vector2(p.x, p.y) * TILE


static func _scan_trails(world: WorldData, heights: Heightfield, trails: Array, authored: Dictionary, gates: Array[Vector2], settlements: Array[Vector2], sites: Array[Vector2], clear_spots: Array[Vector2], bounds: Rect2, is_outer: bool, region_key := Vector2i.ZERO) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	var origin_tiles := Vector2(world.world_origin)
	var next_id := 0
	for route_idx in trails.size():
		var t: Dictionary = trails[route_idx]
		var kind: String = t.get("kind", "")
		if kind != "road" and kind != "trail":
			continue
		var pts: Array = t.get("pts", [])
		if pts.size() < 4:
			continue
		# Предрассчёт пробега вдоль линии.
		var stations := PackedFloat32Array([0.0])
		var total_len := 0.0
		var prev := _trail_point(t, 0)
		for i in range(1, pts.size()):
			var cur := _trail_point(t, i)
			total_len += prev.distance_to(cur)
			stations.append(total_len)
			prev = cur
		if total_len < 68.0:
			continue
		var trail_def: TrailDefinition = authored.get(t.get("trail_id", ""))
		var last_sampled := -100.0
		for i in range(1, pts.size() - 1):
			var s := stations[i]
			if s < 26.0 or s > total_len - 26.0:
				continue
			if s - last_sampled < 22.0:
				continue
			last_sampled = s
			var center := _trail_point(t, i)
			if not bounds.has_point(center):
				continue
			if _near_any(center, clear_spots, CLEAR_START_R) or _near_any(center, gates, 18.0):
				continue
			if _protected_station(trail_def, s, 28.0) or _near_structure_or_water(heights, center):
				continue
			var min_s := _min_dist(center, settlements)
			var min_site := _min_dist(center, sites)
			var park_zone := min_s >= SETTLEMENT_NEAR and min_s <= SETTLEMENT_FAR
			var site_zone := min_site >= SITE_NEAR and min_site <= SITE_FAR and min_s >= SETTLEMENT_NEAR * 0.75
			var deep_forest := min_s > DEEP_FOREST_DIST and min_site > 140.0
			if not park_zone and not site_zone and not deep_forest:
				continue
			var cell := Vector2i((center / TILE + origin_tiles).floor())
			var roll := WGRandom.hash2(cell.x, cell.y, world.seed_num ^ SEED)
			var tree_score := _quick_tree_count(world, center, is_outer)
			if not is_outer and tree_score < 6:
				continue
			var threshold := 0.36 if park_zone else (0.30 if site_zone else 0.085)
			if roll >= threshold:
				continue
			var crop := _crop_route(t, stations, i, CLUSTER_RADIUS + 20.0)
			if crop.pts.size() < 2:
				continue
			var arch := Archetype.ALLEY_ZIGZAG
			if deep_forest and WGRandom.hash2(cell.x * 3, cell.y * 5, world.seed_num ^ (SEED + 7)) < 0.45:
				arch = Archetype.GLADE_CROWN
			elif site_zone and WGRandom.hash2(cell.x * 3, cell.y * 5, world.seed_num ^ (SEED + 11)) < 0.35:
				arch = Archetype.GLADE_CROWN
			var priority := (2.0 if park_zone else (1.5 if site_zone else 0.7)) + minf(float(tree_score), 18.0) * 0.04 + (1.0 - roll)
			var seed_val := int(world.seed_num ^ (SEED + cell.x * 73856093 ^ cell.y * 19349663))
			next_id += 1
			candidates.append({
				id = (region_key.y * 100003 + region_key.x * 1009 + next_id) if is_outer else next_id,
				center = center,
				route_pts = crop.pts,
				route_widths = crop.widths,
				archetype = arch,
				seed = seed_val,
				priority = priority,
				is_outer = is_outer,
				bbox = Rect2(center - Vector2.ONE * (CLUSTER_RADIUS + 18.0), Vector2.ONE * (CLUSTER_RADIUS + 18.0) * 2.0),
			})
	return candidates


static func _select_spaced_clusters(candidates: Array[Dictionary], existing: Array[Dictionary], cap: int) -> Array[Dictionary]:
	if candidates.is_empty() or cap <= 0:
		return []
	var sorted := candidates.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(a.priority, b.priority):
			return a.priority > b.priority
		return a.center.y < b.center.y or (is_equal_approx(a.center.y, b.center.y) and a.center.x < b.center.x))
	var chosen: Array[Dictionary] = []
	var min_sq := MIN_CLUSTER_SPACING * MIN_CLUSTER_SPACING
	for c: Dictionary in sorted:
		var ok := true
		for ex: Dictionary in existing:
			if c.center.distance_squared_to(ex.center) < min_sq:
				ok = false
				break
		if ok:
			for ch: Dictionary in chosen:
				if c.center.distance_squared_to(ch.center) < min_sq:
					ok = false
					break
		if ok:
			chosen.append(c)
			if chosen.size() >= cap:
				break
	return chosen


static func _crop_route(t: Dictionary, stations: PackedFloat32Array, mid_idx: int, half_len: float) -> Dictionary:
	var mid_s := stations[mid_idx]
	var pts := PackedVector2Array()
	var widths := PackedFloat32Array()
	for i in t.pts.size():
		if absf(stations[i] - mid_s) <= half_len:
			pts.append(_trail_point(t, i))
			widths.append(float(t.pts[i].w) * TILE * 0.5)
	return {pts = pts, widths = widths}


static func _near_any(p: Vector2, spots: Array[Vector2], r: float) -> bool:
	var r2 := r * r
	for s in spots:
		if p.distance_squared_to(s) < r2:
			return true
	return false


static func _min_dist(p: Vector2, spots: Array[Vector2]) -> float:
	var best := INF
	for s in spots:
		best = minf(best, p.distance_to(s))
	return best


static func _protected_station(d: TrailDefinition, station: float, extent: float) -> bool:
	if d == null:
		return false
	if station < extent + 10.0 or station > d.route_length() - extent - 10.0:
		return true
	for e: TrailElement in d.elements:
		var margin := 12.0 if e.profile in [TrailElement.Profile.TABLETOP, TrailElement.Profile.GAP, TrailElement.Profile.DROP] else 6.0
		if absf(station - e.station) <= e.length * 0.5 + extent + margin:
			return true
	return false


static func _near_structure_or_water(heights: Heightfield, center: Vector2) -> bool:
	if heights.depth_at(center.x, center.y) > 0.0:
		return true
	for dz in [-16.0, 0.0, 16.0]:
		for dx in [-16.0, 0.0, 16.0]:
			if heights._cell_list(center.x + dx, center.y + dz) != null:
				return true
	return false


static func _quick_tree_count(world: WorldData, center: Vector2, is_outer: bool) -> int:
	if is_outer or world.CS <= 0 or world.chunks.is_empty():
		return 10
	var count := 0
	var r := 32.0
	var span := world.CS * TILE
	for cy in range(maxi(0, floori((center.y - r) / span)), mini(world.CH, floori((center.y + r) / span) + 1)):
		for cx in range(maxi(0, floori((center.x - r) / span)), mini(world.CW, floori((center.x + r) / span) + 1)):
			for o: int in world.chunks[cy * world.CW + cx]:
				var k := world.obj_k[o]
				if not ELIGIBLE.has(k):
					continue
				var p := Vector2(world.obj_x[o], world.obj_y[o]) * TILE
				if p.distance_squared_to(center) <= r * r:
					count += 1
	return count


## Чистая фоновая сборка геометрии кластера по снимку мира и высот.
static func build_cluster(desc: Dictionary, snapshot: Dictionary) -> Dictionary:
	var center: Vector2 = desc.center
	var heights: Heightfield = snapshot.get("heights")
	if heights == null:
		return {valid = false}
	var gathered := _gather_trees_and_blockers(center, heights, snapshot)
	var trees: Array = gathered.trees
	var all_trunks: Array = gathered.all_trunks
	if trees.size() < 4:
		return {valid = false}
	var route_pts: PackedVector2Array = desc.route_pts
	var route_widths: PackedFloat32Array = desc.route_widths
	_project_trees_to_route(trees, route_pts, route_widths)
	var spans := _plan_spans(desc, trees, all_trunks, heights, snapshot)
	if spans.size() < 3:
		return {valid = false}
	return _assemble_buffers(desc, spans, trees, all_trunks, heights)


static func _gather_trees_and_blockers(center: Vector2, heights: Heightfield, snapshot: Dictionary) -> Dictionary:
	var trees: Array = []
	var all_trunks: Array = []
	var scan_r := CLUSTER_RADIUS + 20.0
	var override_trees: Array = snapshot.get("trees_override", [])
	if not override_trees.is_empty():
		for item: Dictionary in override_trees:
			var t := _make_tree_record(item.x, item.z, item.kind, item.v, item.s, item.ground, heights, true)
			all_trunks.append({pos = Vector2(item.x, item.z), r = t.trunk_r if not t.is_empty() else 0.25})
			if not t.is_empty() and Vector2(item.x, item.z).distance_to(center) <= scan_r:
				trees.append(t)
		return {trees = trees, all_trunks = all_trunks}

	var world: WorldData = snapshot.get("world")
	if world != null and world.CS > 0 and not world.chunks.is_empty():
		var side := world.CS * TILE
		for cy in range(maxi(0, floori((center.y - scan_r) / side)), mini(world.CH, floori((center.y + scan_r) / side) + 1)):
			for cx in range(maxi(0, floori((center.x - scan_r) / side)), mini(world.CW, floori((center.x + scan_r) / side) + 1)):
				for o: int in world.chunks[cy * world.CW + cx]:
					var wx := world.obj_x[o] * TILE
					var wz := world.obj_y[o] * TILE
					if absf(wx - center.x) > scan_r or absf(wz - center.y) > scan_r:
						continue
					var kind := world.obj_k[o]
					if not Biomes.is_tree(kind) and kind != Biomes.T_DEAD and kind != Biomes.T_ROCK:
						continue
					if ForestObstacles.on_tread(heights, wx, wz):
						continue
					var ground := heights.ground_at(wx, wz)
					if heights.depth_at(wx, wz) > GameConfig.WATER_MARGIN:
						continue
					var s := world.obj_s[o]
					var trunk_r: float = float(StageVegetation.TRUNK.get(kind, 0.23)) * s
					if kind == Biomes.T_ROCK:
						trunk_r = Biomes.CROWN_RADIUS[kind] * TILE * s
					all_trunks.append({pos = Vector2(wx, wz), r = trunk_r})
					var rec := _make_tree_record(wx, wz, kind, world.obj_v[o], s, ground, heights, false)
					if not rec.is_empty():
						trees.append(rec)

	var outer_veg: Dictionary = snapshot.get("outer_veg", {})
	for items: Dictionary in outer_veg.values():
		var xs: PackedFloat64Array = items.x
		var ys: PackedFloat64Array = items.y
		var ks: PackedInt32Array = items.k
		var vs: PackedInt32Array = items.v
		var ss: PackedFloat64Array = items.s
		var gs: PackedFloat32Array = items.ground
		for o in xs.size():
			var wx: float = xs[o] * TILE
			var wz: float = ys[o] * TILE
			if absf(wx - center.x) > scan_r or absf(wz - center.y) > scan_r:
				continue
			var kind: int = ks[o]
			if not Biomes.is_tree(kind) and kind != Biomes.T_DEAD and kind != Biomes.T_ROCK:
				continue
			var s: float = ss[o]
			var trunk_r: float = float(StageVegetation.TRUNK.get(kind, 0.23)) * s
			if kind == Biomes.T_ROCK:
				trunk_r = Biomes.CROWN_RADIUS[kind] * TILE * s
			all_trunks.append({pos = Vector2(wx, wz), r = trunk_r})
			var rec := _make_tree_record(wx, wz, kind, vs[o], s, gs[o], heights, true)
			if not rec.is_empty():
				trees.append(rec)
	return {trees = trees, all_trunks = all_trunks}


static func _make_tree_record(wx: float, wz: float, kind: int, v: int, s_raw: float, ground: float, heights: Heightfield, skip_tread_check: bool) -> Dictionary:
	if not ELIGIBLE.has(kind):
		return {}
	if not skip_tread_check and (ForestObstacles.on_tread(heights, wx, wz) or heights.depth_at(wx, wz) > GameConfig.WATER_MARGIN):
		return {}
	var age: int = v / 3 if ForestModels.has_ages(kind) else ForestModels.ADULT_AGE
	if age == ForestModels.YOUNG_AGE:
		return {}
	var stretch_y := lerpf(0.92, 1.12, WGRandom.hash2(floori(wx / TILE * 71.0), floori(wz / TILE * 67.0), 23))
	var nominal_h: float = float(ForestModels.NOMINAL.get(kind, 7.8))
	var total_h: float = nominal_h * s_raw * stretch_y
	if total_h < MIN_TREE_HEIGHT:
		return {}
	if kind == Biomes.T_SNOWPINE and total_h < 12.2:
		return {}
	var trunk_r: float = float(StageVegetation.TRUNK.get(kind, 0.23)) * s_raw
	if trunk_r < MIN_TRUNK_R:
		return {}
	var frac: float = float(CLEAR_TRUNK_FRAC.get(kind, 0.40))
	if age == ForestModels.OLD_AGE:
		frac *= 0.86
	var clear_top: float = total_h * frac
	if clear_top < MIN_CLEARANCE + 0.35:
		return {}
	return {
		pos2 = Vector2(wx, wz),
		base_y = ground - 0.1,
		trunk_r = trunk_r,
		collar_r = trunk_r * 0.83,
		total_h = total_h,
		clear_top = clear_top,
		station = 0.0,
		lateral = 0.0,
		road_half = 1.6,
		road_ground = ground,
		degree = 0,
		dirs = [] as Array[Vector2],
	}


static func _project_trees_to_route(trees: Array, pts: PackedVector2Array, widths: PackedFloat32Array) -> void:
	if pts.size() < 2:
		return
	var cum := PackedFloat32Array([0.0])
	var acc := 0.0
	for i in range(1, pts.size()):
		acc += pts[i - 1].distance_to(pts[i])
		cum.append(acc)
	for t: Dictionary in trees:
		var p: Vector2 = t.pos2
		var best_d2 := INF
		var best_s := 0.0
		var best_lat := 0.0
		var best_w := 1.6
		for i in range(1, pts.size()):
			var a := pts[i - 1]
			var b := pts[i]
			var ab := b - a
			var len2 := ab.length_squared()
			if len2 < 1e-4:
				continue
			var u := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
			var proj := a + ab * u
			var d2 := p.distance_squared_to(proj)
			if d2 < best_d2:
				best_d2 = d2
				var dir := ab / sqrt(len2)
				var side := Vector2(-dir.y, dir.x)
				best_s = cum[i - 1] + sqrt(len2) * u
				best_lat = (p - proj).dot(side)
				best_w = lerpf(widths[i - 1], widths[i], u)
		t.station = best_s
		t.lateral = best_lat
		t.road_half = best_w


static func _plan_spans(desc: Dictionary, trees: Array, all_trunks: Array, heights: Heightfield, snapshot: Dictionary) -> Array[Dictionary]:
	var center: Vector2 = desc.center
	var seed: int = desc.seed
	var arch: int = desc.archetype
	var huts: Array[Vector3] = []
	var raw_huts: Variant = snapshot.get("huts")
	if raw_huts is Array:
		huts.assign(raw_huts)
	var gates: Array[Vector2] = []
	var raw_gates: Variant = snapshot.get("gates")
	if raw_gates is Array:
		gates.assign(raw_gates)

	if arch == Archetype.GLADE_CROWN:
		var glade := _build_glade_spans(center, trees, all_trunks, heights, huts, gates, seed)
		if glade.size() >= 4:
			return glade

	var left: Array = []
	var right: Array = []
	for i in trees.size():
		var t: Dictionary = trees[i]
		var abs_lat := absf(t.lateral)
		if abs_lat < t.road_half + 0.65 or abs_lat > CORRIDOR_HALF:
			continue
		if t.lateral < 0.0:
			left.append(i)
		else:
			right.append(i)
	left.sort_custom(func(a: int, b: int) -> bool: return trees[a].station < trees[b].station)
	right.sort_custom(func(a: int, b: int) -> bool: return trees[a].station < trees[b].station)

	var spans: Array[Dictionary] = []
	var est_bulbs := 0
	if left.size() >= 3 and right.size() >= 3:
		var chain := _zigzag_chain(left, right, trees, all_trunks, heights, huts, gates, seed)
		spans = chain.spans
		est_bulbs = chain.bulbs
	if spans.size() < 4:
		var dominant := left if left.size() >= right.size() else right
		if dominant.size() >= 4:
			var edge := _single_edge_chain(dominant, trees, all_trunks, heights, huts, gates, seed)
			if edge.spans.size() > spans.size():
				spans = edge.spans
				est_bulbs = edge.bulbs
	if spans.size() < 3 or est_bulbs < MIN_BULBS:
		return []
	return spans


static func _zigzag_chain(left: Array, right: Array, trees: Array, all_trunks: Array, heights: Heightfield, huts: Array[Vector3], gates: Array[Vector2], seed: int) -> Dictionary:
	var merged: Array = []
	var il := 0
	var ir := 0
	while il < left.size() or ir < right.size():
		if ir >= right.size() or (il < left.size() and trees[left[il]].station <= trees[right[ir]].station):
			merged.append({idx = left[il], side = 0})
			il += 1
		else:
			merged.append({idx = right[ir], side = 1})
			ir += 1

	var spans: Array[Dictionary] = []
	var est_bulbs := 0
	var used_pairs := {}
	if merged.size() < 4:
		return {spans = spans, bulbs = 0}
	var cur: int = merged[0].idx
	var cur_side: int = merged[0].side
	var cursor := 1
	while cursor < merged.size() and est_bulbs < TARGET_BULBS:
		var chosen := -1
		var chosen_side := cur_side
		var chosen_span := {}
		# Предпочитаем противоположный берег дороги в окне [4.5..15.2] м, иначе шаг вперёд по своей стороне.
		for want_cross in [true, false]:
			for look in range(cursor, mini(merged.size(), cursor + 6)):
				var cand: int = merged[look].idx
				var side: int = merged[look].side
				if want_cross and side == cur_side:
					continue
				if not want_cross and side != cur_side:
					continue
				if cand == cur or used_pairs.has(_pair_key(cur, cand)):
					continue
				var span := _validate_span(cur, cand, trees, all_trunks, heights, huts, gates, seed + spans.size() * 37)
				if not span.is_empty():
					chosen = cand
					chosen_side = side
					chosen_span = span
					cursor = look + 1
					break
			if chosen >= 0:
				break
		if chosen < 0:
			cur = merged[cursor].idx
			cur_side = merged[cursor].side
			cursor += 1
			continue
		_accept_span(cur, chosen, trees, chosen_span, spans, used_pairs)
		est_bulbs += chosen_span.bulb_est
		cur = chosen
		cur_side = chosen_side
	return {spans = spans, bulbs = est_bulbs}


static func _single_edge_chain(side_list: Array, trees: Array, all_trunks: Array, heights: Heightfield, huts: Array[Vector3], gates: Array[Vector2], seed: int) -> Dictionary:
	var spans: Array[Dictionary] = []
	var used_pairs := {}
	var est_bulbs := 0
	var cur: int = side_list[0]
	var cursor := 1
	while cursor < side_list.size() and est_bulbs < TARGET_BULBS:
		var chosen := -1
		var chosen_span := {}
		for look in range(cursor, mini(side_list.size(), cursor + 4)):
			var cand: int = side_list[look]
			if used_pairs.has(_pair_key(cur, cand)):
				continue
			var span := _validate_span(cur, cand, trees, all_trunks, heights, huts, gates, seed + spans.size() * 41)
			if not span.is_empty():
				chosen = cand
				chosen_span = span
				cursor = look + 1
				break
		if chosen < 0:
			cur = side_list[cursor]
			cursor += 1
			continue
		_accept_span(cur, chosen, trees, chosen_span, spans, used_pairs)
		est_bulbs += chosen_span.bulb_est
		cur = chosen
	return {spans = spans, bulbs = est_bulbs}


static func _build_glade_spans(center: Vector2, trees: Array, all_trunks: Array, heights: Heightfield, huts: Array[Vector3], gates: Array[Vector2], seed: int) -> Array[Dictionary]:
	var ring: Array = []
	for i in trees.size():
		var d: float = trees[i].pos2.distance_to(center)
		if d >= 6.0 and d <= 24.0:
			ring.append(i)
	if ring.size() < 5:
		return []
	ring.sort_custom(func(a: int, b: int) -> bool:
		var da: Vector2 = trees[a].pos2 - center
		var db: Vector2 = trees[b].pos2 - center
		return atan2(da.y, da.x) < atan2(db.y, db.x))
	if ring.size() > 11:
		ring = ring.slice(0, 11)
	var spans: Array[Dictionary] = []
	var used_pairs := {}
	var est_bulbs := 0
	for k in ring.size():
		var a: int = ring[k]
		var b: int = ring[(k + 1) % ring.size()]
		var span := _validate_span(a, b, trees, all_trunks, heights, huts, gates, seed + spans.size() * 29)
		if not span.is_empty():
			_accept_span(a, b, trees, span, spans, used_pairs)
			est_bulbs += span.bulb_est
	# Добавляем 2–3 перекрёстных пролёта через центр поляны, если запас по высоте чист.
	var cross_step := maxi(2, ring.size() / 2)
	for k in mini(3, ring.size() / 2):
		if est_bulbs >= TARGET_BULBS:
			break
		var a: int = ring[k]
		var b: int = ring[(k + cross_step) % ring.size()]
		if used_pairs.has(_pair_key(a, b)):
			continue
		var span := _validate_span(a, b, trees, all_trunks, heights, huts, gates, seed + spans.size() * 53)
		if not span.is_empty():
			_accept_span(a, b, trees, span, spans, used_pairs)
			est_bulbs += span.bulb_est
	return spans if est_bulbs >= MIN_BULBS else []


static func _accept_span(a: int, b: int, trees: Array, span: Dictionary, spans: Array[Dictionary], used_pairs: Dictionary) -> void:
	used_pairs[_pair_key(a, b)] = true
	trees[a].degree += 1
	trees[b].degree += 1
	var d_xz := Vector2(span.p1.x - span.p0.x, span.p1.z - span.p0.z).normalized()
	trees[a].dirs.append(d_xz)
	trees[b].dirs.append(-d_xz)
	spans.append(span)


static func _pair_key(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


static func _validate_span(a_idx: int, b_idx: int, trees: Array, all_trunks: Array, heights: Heightfield, huts: Array[Vector3], gates: Array[Vector2], seed: int) -> Dictionary:
	var ta: Dictionary = trees[a_idx]
	var tb: Dictionary = trees[b_idx]
	if ta.degree >= 3 or tb.degree >= 3:
		return {}
	var pa2: Vector2 = ta.pos2
	var pb2: Vector2 = tb.pos2
	var span_len := pa2.distance_to(pb2)
	if span_len < MIN_SPAN or span_len > MAX_SPAN:
		return {}
	var dir2 := (pb2 - pa2) / span_len
	if not _angle_clear(ta.dirs, dir2) or not _angle_clear(tb.dirs, -dir2):
		return {}
	# Обход построек, ворот, мостов/туннелей и третьих стволов по трассе пролёта.
	for h: Vector3 in huts:
		var closest := Geometry2D.get_closest_point_to_segment(Vector2(h.x, h.y), pa2, pb2)
		if closest.distance_to(Vector2(h.x, h.y)) < h.z + 1.6:
			return {}
	for g: Vector2 in gates:
		var closest := Geometry2D.get_closest_point_to_segment(g, pa2, pb2)
		if closest.distance_to(g) < 8.0:
			return {}
	for tr: Dictionary in all_trunks:
		var tp: Vector2 = tr.pos
		if tp.distance_squared_to(pa2) < 0.05 or tp.distance_squared_to(pb2) < 0.05:
			continue
		var closest := Geometry2D.get_closest_point_to_segment(tp, pa2, pb2)
		if closest.distance_to(tp) < tr.r + 0.50:
			return {}

	var sag_k := lerpf(0.072, 0.105, WGRandom.hash2(roundi(pa2.x), roundi(pb2.y), seed))
	var sag := clampf(span_len * sag_k, 0.25, 0.92)
	var max_a_y: float = ta.base_y + minf(ta.clear_top, MAX_ATTACH_REL)
	var max_b_y: float = tb.base_y + minf(tb.clear_top, MAX_ATTACH_REL)
	var ya := clampf(ta.base_y + 4.35, ta.base_y + 3.4, max_a_y)
	var yb := clampf(tb.base_y + 4.35, tb.base_y + 3.4, max_b_y)

	# Проверка габарита над полотном и настилами NORTHSHORE вдоль всей кривой провисания.
	var deficit := 0.0
	for s in 7:
		var t := float(s) / 6.0
		var px := lerpf(pa2.x, pb2.x, t)
		var pz := lerpf(pa2.y, pb2.y, t)
		if heights._cell_list(px, pz) != null or heights.depth_at(px, pz) > 0.0:
			return {}
		var ground_y := heights.ground_at(px, pz)
		var surface_y := maxf(ground_y, heights.surface_at(px, pz, ground_y + 2.5))
		var arc_y := lerpf(ya, yb, t) - 4.0 * sag * t * (1.0 - t)
		deficit = maxf(deficit, (surface_y + MIN_CLEARANCE + BULB_DROP) - arc_y)
	if deficit > 0.0:
		var lift := deficit + 0.15
		if ya + lift > max_a_y or yb + lift > max_b_y:
			return {}
		ya += lift
		yb += lift

	var p0 := Vector3(pa2.x, ya, pa2.y)
	var p1 := Vector3(pb2.x, yb, pb2.y)
	var spacing := lerpf(1.75, 2.25, WGRandom.hash2(roundi(pb2.x * 3.0), roundi(pa2.y * 5.0), seed + 9))
	var margin_m := maxf(maxf(ta.trunk_r, tb.trunk_r) + 0.78, 0.96)
	var usable_len := maxf(0.0, span_len - margin_m * 2.0)
	var bulb_est := clampi(floori(usable_len / spacing) + 1, 2, 7) if usable_len > 0.8 else 0
	if bulb_est < 2:
		return {}
	return {
		a = a_idx, b = b_idx, p0 = p0, p1 = p1, sag = sag, span_len = span_len,
		ta = p0 + Vector3(dir2.x, 0.0, dir2.y) * (ta.trunk_r * 0.25),
		tb = p1 - Vector3(dir2.x, 0.0, dir2.y) * (tb.trunk_r * 0.25),
		margin_m = margin_m, bulb_est = bulb_est,
		phase = WGRandom.hash2(roundi(pa2.x + pb2.x), roundi(pa2.y + pb2.y), seed + 3),
	}


static func _angle_clear(dirs: Array[Vector2], cand: Vector2) -> bool:
	for d in dirs:
		if d.dot(cand) > 0.78: # < ~38 градусов между проводами от одного дерева
			return false
	return true


static func _assemble_buffers(desc: Dictionary, spans: Array[Dictionary], trees: Array, all_trunks: Array, heights: Heightfield) -> Dictionary:
	var center2: Vector2 = desc.center
	var origin_y := heights.ground_at(center2.x, center2.y)
	var origin := Vector3(center2.x, origin_y, center2.y)

	var w_verts := PackedVector3Array()
	var w_norms := PackedVector3Array()
	var w_uvs := PackedVector2Array()
	var w_cols := PackedColorArray()
	var w_idx := PackedInt32Array()

	var bulb_xfs: Array[Transform3D] = []
	var bulb_customs: Array[Color] = []
	var halo_xfs: Array[Transform3D] = []
	var light_candidates: Array[Vector3] = []
	var bounds := AABB()
	var have_bounds := false
	var cluster_shift := WGRandom.hash2(roundi(center2.x), roundi(center2.y), desc.seed + 13) * 0.05

	for si in spans.size():
		var sp: Dictionary = spans[si]
		var ta: Vector3 = sp.ta - origin
		var tb: Vector3 = sp.tb - origin
		var sag: float = sp.sag
		var phase: float = sp.phase

		_append_wire_arc(w_verts, w_norms, w_uvs, w_cols, w_idx, ta, tb, sag, SPAN_HALF_W, phase, 1.0, WIRE_SEGMENTS)
		light_candidates.append((sp.p0 + sp.p1) * 0.5 - Vector3(0.0, sag * 0.85 + 0.9, 0.0))

		var left_slots := MAX_BULBS - bulb_xfs.size()
		if left_slots <= 0:
			continue
		var count := mini(sp.bulb_est, left_slots)
		var m_t := clampf(sp.margin_m / sp.span_len, 0.08, 0.34)
		for bi in count:
			var frac := 0.5 if count == 1 else float(bi) / float(count - 1)
			var u := lerpf(m_t, 1.0 - m_t, frac)
			var u_jit := (WGRandom.hash2(si * 31 + bi, roundi(center2.x), desc.seed + 29) - 0.5) * 0.025
			u = clampf(u + u_jit, m_t * 0.85, 1.0 - m_t * 0.85)
			var p_local := _catenary(ta, tb, sag, u)
			var p_world2 := Vector2(origin.x + p_local.x, origin.z + p_local.z)
			if _hits_third_trunk(p_world2, all_trunks):
				continue
			var sag_w := 4.0 * u * (1.0 - u)
			var r_dim := WGRandom.hash2(si * 97 + bi * 13, roundi(center2.y), desc.seed + 59)
			var bulb_g := r_dim * 0.02 if r_dim < 0.02 else lerpf(0.08, 1.0, WGRandom.hash2(si * 53 + bi, bi * 7, desc.seed + 71))
			var thr := clampf(cluster_shift + lerpf(0.01, 0.13, WGRandom.hash2(bi * 41 + si, roundi(center2.x + center2.y), desc.seed + 83)), 0.01, 0.18)
			var custom := Color(phase, bulb_g, thr, sag_w)
			bulb_xfs.append(Transform3D(Basis.IDENTITY, p_local))
			bulb_customs.append(custom)
			halo_xfs.append(Transform3D(Basis.IDENTITY, p_local + Vector3(0.0, BULB_CENTER_Y, 0.0)))
			var b_box := AABB(p_local - Vector3(0.8, 0.8, 0.8), Vector3(1.6, 1.6, 1.6))
			bounds = bounds.merge(b_box) if have_bounds else b_box
			have_bounds = true

	for v in w_verts:
		bounds = bounds.expand(v) if have_bounds else AABB(v, Vector3.ZERO)
		have_bounds = true

	var wire_arrays := []
	wire_arrays.resize(Mesh.ARRAY_MAX)
	wire_arrays[Mesh.ARRAY_VERTEX] = w_verts
	wire_arrays[Mesh.ARRAY_NORMAL] = w_norms
	wire_arrays[Mesh.ARRAY_TEX_UV] = w_uvs
	wire_arrays[Mesh.ARRAY_COLOR] = w_cols
	wire_arrays[Mesh.ARRAY_INDEX] = w_idx

	var light_anchors := _select_light_anchors(light_candidates)
	return {
		valid = bulb_xfs.size() >= MIN_BULBS,
		id = desc.id,
		center = center2,
		origin = origin,
		wire_arrays = wire_arrays,
		bulb_xfs = bulb_xfs,
		bulb_customs = bulb_customs,
		halo_xfs = halo_xfs,
		light_anchors = light_anchors,
		bounds = bounds.grow(1.2),
		bulb_count = bulb_xfs.size(),
		span_count = spans.size(),
	}


static func _catenary(a: Vector3, b: Vector3, sag: float, t: float) -> Vector3:
	var p := a.lerp(b, t)
	p.y -= 4.0 * sag * t * (1.0 - t)
	return p


static func _hits_third_trunk(p2: Vector2, all_trunks: Array) -> bool:
	for tr: Dictionary in all_trunks:
		var tp: Vector2 = tr.pos
		if p2.distance_to(tp) < tr.r + 0.42:
			return true
	return false


static func _append_wire_arc(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, a: Vector3, b: Vector3, sag: float, half_w: float, phase: float, sway_scale: float, segs: int) -> void:
	var first := verts.size()
	var col := Color(half_w, phase, sway_scale, 1.0)
	for s in segs + 1:
		var t := float(s) / float(segs)
		var p := _catenary(a, b, sag, t)
		var t0 := maxf(0.0, t - 0.02)
		var t1 := minf(1.0, t + 0.02)
		var dir := (_catenary(a, b, sag, t1) - _catenary(a, b, sag, t0)).normalized()
		verts.append(p)
		norms.append(dir)
		uvs.append(Vector2(-1.0, t))
		cols.append(col)
		verts.append(p)
		norms.append(dir)
		uvs.append(Vector2(1.0, t))
		cols.append(col)
	for s in segs:
		var i := first + s * 2
		idx.append_array([i, i + 2, i + 1, i + 1, i + 2, i + 3])


static func _select_light_anchors(candidates: Array[Vector3]) -> PackedVector3Array:
	var out := PackedVector3Array()
	var step2 := LIGHT_STEP * LIGHT_STEP
	for c in candidates:
		var ok := true
		for ex in out:
			if c.distance_squared_to(ex) < step2:
				ok = false
				break
		if ok:
			out.append(c)
	return out
