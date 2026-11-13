extends RefCounted
## Terrain-owned, opaque proxies of vegetation beyond the real models. CPU buffers are built by existing terrain jobs.
## Three sets share one material and one data pass over the tile:
##   fine   — tree clusters (~12 m) as 2–3 lobed crowns, from the real trees (plus world bushes and boulders);
##   coarse — 32 m clumps (area-preserving, 4 lobes) beyond SPLIT;
##   scrub  — thickets, juniper and young trees of the open-land communities (Understory.communities: the same
##            noise and fields as the near understory), from the edge of the real understory to SCRUB_END.
## Fine and coarse cross-dither per instance around SPLIT (no double drawing, no pop); the instance kind is
## INSTANCE_CUSTOM.x (0 fine, 1 coarse, 2 scrub), y — trees in the cluster, z — material (0 leaves, 1 rock).
const SHADER := preload("res://resources/distant_forest.gdshader")
const Understory := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const TILE := GameConfig.TILE
const SIDE := 128.0 # Keep culling local, even when terrain tiles are 256 m wide.
const SPLIT := 620.0 # fine -> coarse, m from the camera
const SPLIT_BAND := 60.0
const NODE_MARGIN := 92.0 # instances of a 128 m cell are up to 91 m from its centre (node ranges are per node)
const COARSE_CELL := 32.0
const SCRUB_STEP := 3 # cells (12 m) between open-land samples
const SCRUB_BEGIN := 150.0 # real bushes are at full density to 140 m and thin out beyond
const SCRUB_END := 950.0
enum { FINE, COARSE, SCRUB }
static var _meshes: Array[ArrayMesh] = []
static var _material: ShaderMaterial
static var active := true
static var far_end := 1400.0 # crown draw distance, m: set per quality level by VegetationLayer
static var near_begin := 240.0 # cells nearer than this are fully covered by real trees

## Draw ranges for one MultiMesh node (meta "far_lod"). The node ranges are coarse (per 128 m cell, with a margin);
## the shader cuts each instance exactly, so neighbouring rings never draw the same place twice.
static func apply_ranges(node: MultiMeshInstance3D, local_range := Vector2.ZERO) -> void:
	var isolated := local_range.y > 0.0
	var begin := local_range.x if isolated else near_begin
	var end := local_range.y if isolated else far_end
	node.visible = isolated or active
	var lod: int = node.get_meta("far_lod", FINE)
	match lod:
		COARSE:
			node.visibility_range_begin = maxf(0.0, SPLIT - SPLIT_BAND * 0.5 - NODE_MARGIN)
			node.visibility_range_end = end + 150.0
		SCRUB:
			node.visibility_range_begin = maxf(0.0, SCRUB_BEGIN - NODE_MARGIN)
			node.visibility_range_end = minf(end, SCRUB_END) + NODE_MARGIN
		_:
			node.visibility_range_begin = begin
			node.visibility_range_end = SPLIT + SPLIT_BAND * 0.5 + NODE_MARGIN
	node.visibility_range_begin_margin = 0.0
	node.visibility_range_end_margin = 0.0

static func plan(w: WorldData, h: Heightfield, key: Vector2i, include_scrub := true) -> Dictionary:
	var raw: Array = []
	var groups := {}
	var centers := {}
	var wooded := {} # 12 m cells with trees: open-land scrub is not sampled there (the forest proxies cover it)
	var rect := Rect2i(key * PlanTerrain.CELLS, Vector2i.ONE * PlanTerrain.CELLS)
	for cy in range(maxi(0, rect.position.y / w.CS), mini(w.CH, ceili(float(rect.end.y) / w.CS))):
		for cx in range(maxi(0, rect.position.x / w.CS), mini(w.CW, ceili(float(rect.end.x) / w.CS))):
			for o: int in w.chunks[cy * w.CW + cx]:
				var kind: int = w.obj_k[o]
				var tree := Biomes.is_tree(kind)
				if not tree and kind != Biomes.T_BUSH and kind != Biomes.T_ROCK: continue
				var x := float(w.obj_x[o]) * TILE
				var z := float(w.obj_y[o]) * TILE
				# Те же отказы, что у ближних деревьев (VegetationLayer._build_chunk): полотно дороги и вода.
				if ForestObstacles.on_tread(h, x, z): continue
				if kind != Biomes.T_ROCK and h.depth_at(x, z) > GameConfig.WATER_MARGIN: continue
				var size := float(w.obj_s[o])
				var ground := h.ground_at(x, z)
				var jitter := WGRandom.hash2(floori(w.obj_x[o] * 71), floori(w.obj_y[o] * 67), 23)
				if not tree:
					# World bushes and boulders: single small proxies in the fine ring (beyond the real models).
					var r: float = Biomes.CROWN_RADIUS[kind] * TILE * size
					var rock := kind == Biomes.T_ROCK
					var half := Vector3(r, r * (0.45 if rock else 0.6), r)
					raw.append([Vector3(x, ground + half.y * (0.35 if rock else 0.8), z), half,
						Color(0.5, 0.49, 0.46, 0.0) if rock else tint(Biomes.T_BUSH, w.obj_v[o], w.obj_x[o], w.obj_y[o]) * 0.85, 1, 1.0 if rock else 0.0])
					continue
				var height: float = ForestModels.NOMINAL.get(kind, 16.0) * size * lerpf(0.92, 1.12, jitter)
				var conifer := kind == Biomes.T_PINE or kind == Biomes.T_SNOWPINE
				var radius: float = Biomes.CROWN_RADIUS[kind] * TILE * size
				# Crown body: conifers from a fifth of the height to the top, broadleaf crowns from a third.
				var at := Vector3(x, ground + height * (0.6 if conifer else 0.66), z)
				var extent := Vector3(radius, height * (0.39 if conifer else 0.31), radius)
				var group := cluster_key(Vector2(x, z), centers)
				wooded[Vector2i(floori(x / (TILE * SCRUB_STEP)), floori(z / (TILE * SCRUB_STEP)))] = true
				var box := AABB(at - extent, extent * 2.0)
				var color := tint(kind, w.obj_v[o], w.obj_x[o], w.obj_y[o])
				if not groups.has(group): groups[group] = {box = box, color = color, count = 1}
				else:
					groups[group].box = groups[group].box.merge(box)
					groups[group].color += color
					groups[group].count += 1
	for group: Dictionary in groups.values():
		raw.append([group.box.get_center(), group.box.size * 0.5, group.color / float(group.count), group.count, 0.0])
	var scrub := _plan_scrub(w, h, rect, wooded) if include_scrub else []
	return pack(raw, scrub)

## Open-land woody plants of the plan tile: one proxy per 12 m sample where the community has enough of them.
static func _plan_scrub(w: WorldData, h: Heightfield, rect: Rect2i, wooded: Dictionary) -> Array:
	var out: Array = []
	var rock_field := w.generation.surface_rock
	var has_rock := rock_field.size() == w.N
	var x0 := ceili(float(rect.position.x) / SCRUB_STEP) * SCRUB_STEP
	var y0 := ceili(float(rect.position.y) / SCRUB_STEP) * SCRUB_STEP
	for j in range(y0, mini(rect.end.y, w.H), SCRUB_STEP):
		for i in range(x0, mini(rect.end.x, w.W), SCRUB_STEP):
			var cell := Vector2i(i / SCRUB_STEP, j / SCRUB_STEP)
			if wooded.has(cell): continue
			var k := j * w.W + i
			if w.path_mask[k] != 0 or w.river[k] != 0: continue
			var edge := 0.0
			for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if wooded.has(cell + o): edge = 0.6
			var rock := float(rock_field[k]) / 255.0 if has_rock else Floor.rockiness(w, k)
			var light := StageClimate.natural_conditions(w, i, j).x
			var site := scrub_site(w.seed_num, i, j, w.biome[k], Floor.ground_moisture(w.moist[k], w.dist_water[k]), light,
				w.slope[k], w.elev[k], rock, w.dist_water[k], edge)
			if site.is_empty(): continue
			var p: Vector2 = site.at
			out.append(_scrub_item(site, p, h.ground_at(p.x, p.y)))
	return out

## Woody part of the open-land community at a 12 m sample (the same Understory.communities and noise as
## VegetationLayer._open_community, without the verge strip): {} or {at, mass, tall, juniper}.
static func scrub_site(seed_num: int, i: int, j: int, bi: int, moisture: float, light: float, slope: float, alt: float,
		rock: float, water: float, edge: float) -> Dictionary:
	# 13.11.2026: те же биомы, что у ближней раскладки (VegetationLayer._fill_grass: есть трава или скалы):
	# раньше дальние заросли пропускали пляж и вставали на каменистом берегу, где ближних нет.
	if not Biomes.LIST[bi].has("grass") and bi != Biomes.ROCK: return {}
	if slope > 1.15: return {}
	var seed := seed_num ^ 8803
	var big := VegetationLayer._vnoise(i, j, 36.0, seed)
	var mid := VegetationLayer._vnoise(i, j, 11.0, seed + 17)
	var dry := VegetationLayer.open_dry(bi)
	var com := Understory.communities(big, mid, moisture, light, slope, alt, rock, water, edge, 0.0, dry)
	var density := 0.0
	var woody := 0.0
	var tall := 0.0
	var herb := 0.0
	var total := 0.0
	for c in Understory.COMMUNITIES:
		density += com[c] * Understory.COMMUNITY_DENSITY[c]
		var row: Array = Understory.COMMUNITY[c]
		for f in Understory.COUNT:
			total += com[c] * row[f]
		woody += com[c] * (row[Understory.BUSH] + row[Understory.SAPLING] + row[Understory.PINE])
		tall += com[c] * (row[Understory.YOUNG] + row[Understory.YOUNG_PINE])
		herb += com[c] * (row[Understory.MEADOW] + row[Understory.HIGH_GRASS] + row[Understory.SEDGE] + row[Understory.STIPA] + row[Understory.FORBS] * 0.6)
	density *= (1.0 - 0.6 * rock) * (1.0 - 0.75 * smoothstep(0.55, 1.1, slope))
	# Bushes per 4 m cell (OPEN_SLOTS places, density share, woody share of the weights)
	var per_cell := density * Understory.OPEN_SLOTS * (woody + tall) / maxf(total, 0.001)
	if bi == Biomes.ROCK: per_cell *= 0.5
	# A thicket needs a few bushes in 12 m; the 12 m patch noise of the near layout makes the gaps.
	var patch := smoothstep(0.1, 0.45, VegetationLayer._vnoise(i, j, 3.0, seed + 31))
	var mass := per_cell * patch
	var u := WGRandom.hash2(i, j, seed + 991)
	var v := WGRandom.hash2(i, j, seed + 993)
	if mass < 0.22 or WGRandom.hash2(i, j, seed + 977) > smoothstep(0.22, 0.6, mass) + 0.15:
		# 12.11.2026: без кустов холм вдали не голый — массивы высокотравья (куртины по пояс) тоже видны
		# низкими широкими валами: там, где ближняя раскладка ставит густые куртины, осоку и ковыль.
		var herb_mass := density * Understory.OPEN_SLOTS * herb / maxf(total, 0.001) * smoothstep(0.2, 0.55, VegetationLayer._vnoise(i, j, 3.0, seed + 47))
		if herb_mass < 0.4 or WGRandom.hash2(i, j, seed + 979) > smoothstep(0.4, 1.6, herb_mass) * 0.85: return {}
		return {at = (Vector2(i, j) + Vector2(0.5 + (u - 0.5) * 2.2, 0.5 + (v - 0.5) * 2.2)) * TILE, mass = 1.0, tall = 0.0, juniper = false,
			conifer = false, u = u, herb = true, parch = clampf((0.55 - moisture) * 1.6 + dry * 0.35 + alt * 0.4, 0.0, 1.0)}
	return {at = (Vector2(i, j) + Vector2(0.5 + (u - 0.5) * 2.2, 0.5 + (v - 0.5) * 2.2)) * TILE, mass = minf(mass, 1.6),
		tall = tall / maxf(woody + tall, 0.001), juniper = alt > 0.27 or rock > 0.3 or com[Understory.C_TURF] > 0.5,
		conifer = bi in [Biomes.TAIGA, Biomes.TUNDRA] or alt > 0.3, u = u}

static func _scrub_item(site: Dictionary, p: Vector2, ground: float) -> Array:
	var mass: float = site.mass
	var u: float = site.u
	if site.get("herb", false):
		# вал высокотравья: сочный оливково-зелёный, на сухом месте — соломенный (как ближние куртины)
		var grass_r := lerpf(3.2, 5.6, u)
		var grass_h := lerpf(0.8, 1.4, fposmod(u * 5.13, 1.0))
		var grass_c := Color("5f7d38").lerp(Color("93884a"), float(site.parch)) * lerpf(0.92, 1.06, u)
		grass_c.a = 0.0
		return [Vector3(p.x, ground + grass_h * 0.3, p.y), Vector3(grass_r, grass_h * 0.5, grass_r), grass_c, 2, 0.0]
	# Area of the bushes of 9 cells, ~3 m² each; young trees make some thickets taller.
	var radius := clampf(sqrt(mass * 9.0 * 3.0 / PI), 1.6, 4.2) * lerpf(0.85, 1.15, u)
	var height := lerpf(1.3, 2.2, u) + float(site.tall) * lerpf(2.0, 4.5, u)
	# конец лета: заросли оливковые, часть — с рыжиной (как ближние кусты)
	var color := Color("667c3a").lerp(Color("8a7636"), smoothstep(0.6, 0.95, fposmod(u * 7.31, 1.0)) * (0.2 if site.conifer else 0.7)) * lerpf(0.9, 1.05, u)
	color.a = 1.0 if site.conifer and site.tall > 0.3 else 0.0
	if site.juniper:
		radius *= 1.3
		height *= 0.45
		color = Color("4c6650") * lerpf(0.9, 1.05, u)
		color.a = 0.0
	return [Vector3(p.x, ground + height * 0.42, p.y), Vector3(radius, height * 0.5, radius), color, 2, 0.0]

static func cluster_key(p: Vector2, centers: Dictionary) -> Vector2i:
	var cell := Vector2i((p / 12.0).floor())
	var best := cell
	var distance := INF
	for y in range(cell.y - 1, cell.y + 2):
		for x in range(cell.x - 1, cell.x + 2):
			var key := Vector2i(x, y)
			if not centers.has(key):
				centers[key] = (Vector2(key) + Vector2(WGRandom.hash2(x, y, 193), WGRandom.hash2(x, y, 297)) * 0.8 + Vector2.ONE * 0.1) * 12.0
			var d: float = p.distance_squared_to(centers[key])
			if d < distance:
				distance = d
				best = key
	return best

## Instance colour: rgb is the leaf tint, alpha is the conifer share (the shader narrows conifers into cones).
static func tint(kind: int, variant: int, x: float, y: float) -> Color:
	var color := Color("7ca94e")
	if kind == Biomes.T_PINE: color = Color("568758")
	elif kind == Biomes.T_SNOWPINE: color = Color("a1b6aa")
	elif kind == Biomes.T_BIRCH: color = Color("8caf50")
	elif kind == Biomes.T_JUNGLE: color = Color("48824a")
	elif kind == Biomes.T_BUSH: color = Color("6a8c42")
	color = Biomes.leaf_tone(kind, color * (0.92 + (variant % 3) * 0.06), x, y) # тот же тон, что у ближней модели
	color.a = 1.0 if kind == Biomes.T_PINE or kind == Biomes.T_SNOWPINE else 0.0
	return color

## raw: Array of [centre, half-extent, colour, trees, material] -> {f = fine cells, c = coarse cells, s = scrub cells}.
static func pack(raw: Array, scrub: Array = []) -> Dictionary:
	var fine := {}
	var coarse := {}
	var merged := {}
	for item: Array in raw:
		var at: Vector3 = item[0]
		var size: Vector3 = item[1]
		var color: Color = item[2]
		var count: int = item[3] if item.size() > 3 else 1
		var stuff: float = item[4] if item.size() > 4 else 0.0
		append(fine, at, size, color, FINE, count, stuff)
		if stuff > 0.5 or size.y < 2.5: continue # boulders and lone bushes vanish in the far ring
		var key := Vector2i(floori(at.x / COARSE_CELL), floori(at.z / COARSE_CELL))
		var weight := size.x * size.z
		if not merged.has(key): merged[key] = {area = 0.0, at = Vector3.ZERO, hy = 0.0, color = Color(0, 0, 0, 0), n = 0}
		var m: Dictionary = merged[key]
		m.area += weight
		m.at += at * weight
		m.hy += size.y * weight
		m.color += color * weight
		m.n += count
	for m: Dictionary in merged.values():
		# Slightly overlapping clumps read as continuous canopy instead of separate pebbles from far away.
		var radius := minf(sqrt(m.area) * 1.15, 26.0)
		var half := minf(maxf(m.hy / m.area * 1.25, radius * 0.4), 13.0)
		append(coarse, m.at / m.area + Vector3(0, (half - m.hy / m.area) * 0.5, 0), Vector3(radius, half, radius), m.color / m.area, COARSE, m.n, 0.0)
	var thickets := {}
	for item: Array in scrub:
		append(thickets, item[0], item[1], item[2], SCRUB, 1, item[4])
	return {f = fine, c = coarse, s = thickets}

## Buffer per instance: basis (rotation about Y × half-extent) and origin, colour, custom (kind, trees, material, 0).
static func append(out: Dictionary, at: Vector3, size: Vector3, color: Color, kind := FINE, count := 1, stuff := 0.0) -> void:
	var key := Vector2i(floori(at.x / SIDE), floori(at.z / SIDE))
	if not out.has(key): out[key] = {buffer = PackedFloat32Array(), bounds = AABB(), count = 0}
	var entry: Dictionary = out[key]
	var center := (Vector2(key) + Vector2.ONE * 0.5) * SIDE
	var local := at - Vector3(center.x, 0, center.y)
	var angle := WGRandom.hash2(floori(at.x * 3.0), floori(at.z * 3.0), 419) * TAU
	var c := cos(angle)
	var s := sin(angle)
	entry.buffer.append_array(PackedFloat32Array([c * size.x, 0, s * size.z, local.x, 0, size.y, 0, local.y, -s * size.x, 0, c * size.z, local.z,
		color.r, color.g, color.b, color.a, float(kind), float(count), stuff, 0.0]))
	var box := AABB(local - Vector3(maxf(size.x, size.z), size.y, maxf(size.x, size.z)) * 1.25, Vector3(maxf(size.x, size.z), size.y, maxf(size.x, size.z)) * 2.5)
	entry.bounds = box if entry.count == 0 else entry.bounds.merge(box)
	entry.count += 1

static func attach(parent: Node3D, batches: Dictionary, local_range := Vector2.ZERO) -> void:
	if _meshes.is_empty():
		_meshes = [lobe_mesh(FINE), lobe_mesh(COARSE), lobe_mesh(SCRUB)]
		_material = ShaderMaterial.new()
		_material.shader = SHADER
	for lod in 3:
		var cells: Dictionary = batches.get(["f", "c", "s"][lod], {})
		for key: Vector2i in cells:
			var entry: Dictionary = cells[key]
			var node := MultiMeshInstance3D.new()
			node.name = "DistantForest"
			if local_range.y <= 0.0:
				node.add_to_group("distant_forest")
			node.set_meta("far_lod", lod)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.use_custom_data = true
			mm.mesh = _meshes[lod]
			mm.instance_count = entry.count
			mm.buffer = entry.buffer
			mm.custom_aabb = entry.bounds
			node.multimesh = mm
			node.material_override = _material
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			apply_ranges(node, local_range)
			parent.add_child(node)
			var center := (Vector2(key) + Vector2.ONE * 0.5) * SIDE
			node.global_position = Vector3(center.x, 0, center.y)

## Clusters of lobes in the unit box. Each lobe is a hexagonal bipyramid with an off-centre waist (12 triangles):
## a rounded top and a flatter underside. UV — lobe centre (x, z), UV2 — (lobe index, lobe-local height -1..1);
## the shader turns lobes into cones for conifers, varies their height and drops extra lobes of small clusters.
## Fine: 3 lobes (36 triangles), coarse: 4 lobes (48), scrub: 3 low lobes (36).
const LOBES := {
	FINE: [[Vector3(0.0, 0.08, 0.0), Vector3(0.66, 0.9, 0.66)], [Vector3(0.44, -0.14, 0.3), Vector3(0.5, 0.7, 0.5)],
		[Vector3(-0.4, -0.1, -0.34), Vector3(0.52, 0.76, 0.52)]],
	COARSE: [[Vector3(0.0, 0.1, 0.0), Vector3(0.56, 0.9, 0.56)], [Vector3(0.5, -0.12, 0.22), Vector3(0.46, 0.72, 0.46)],
		[Vector3(-0.46, -0.06, 0.3), Vector3(0.46, 0.78, 0.46)], [Vector3(0.04, -0.16, -0.52), Vector3(0.46, 0.68, 0.46)]],
	SCRUB: [[Vector3(0.0, 0.0, 0.0), Vector3(0.62, 1.0, 0.62)], [Vector3(0.5, -0.2, 0.22), Vector3(0.48, 0.75, 0.48)],
		[Vector3(-0.42, -0.25, -0.32), Vector3(0.5, 0.7, 0.5)]],
}

static func lobe_mesh(kind: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lobes: Array = LOBES[kind]
	for index in lobes.size():
		var c: Vector3 = lobes[index][0]
		var r: Vector3 = lobes[index][1]
		var top := Vector3(0, 1.0, 0)
		var bottom := Vector3(0, -0.7, 0)
		for i in 6:
			var a := (float(i) + 0.5 * (index % 2)) * TAU / 6.0
			var b := (float(i + 1) + 0.5 * (index % 2)) * TAU / 6.0
			var ring_a := Vector3(cos(a), -0.12, sin(a))
			var ring_b := Vector3(cos(b), -0.12, sin(b))
			for v: Vector3 in [top, ring_a, ring_b, bottom, ring_b, ring_a]:
				var local := Vector3(v.x * r.x, v.y * r.y, v.z * r.z)
				st.set_normal((v * Vector3(1.0, 0.8, 1.0)).normalized())
				st.set_uv(Vector2(c.x, c.z))
				st.set_uv2(Vector2(index * 4.0 + c.y + 1.0, v.y))
				st.add_vertex(c + local)
	return st.commit()

static func cover(w: WorldData, f: Dictionary, i: int, x: float, y: float) -> float:
	var bi: int = f.biome[i]
	if bi not in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.SWAMP, Biomes.GRASS]: return 0.0
	if f.river[i] != 0 or f.path[i] != 0 or f.elev[i] > 0.72 or f.slope[i] > 0.85: return 0.0
	var n: Simplex = w.noise.forest
	var wood := n.fbm(x / StageVegetation.WOOD_SCALE + StageVegetation.WOOD_OX, y / StageVegetation.WOOD_SCALE + StageVegetation.WOOD_OY, StageVegetation.WOOD_OCT)
	var fine := n.fbm(x / 36.0, y / 36.0, 3)
	var c := wood * 1.15 + StageVegetation.world_cover(w.seed_num) + fine * 0.4
	var amount := smoothstep(-0.3, 0.12, c) if bi != Biomes.GRASS else smoothstep(0.2, 0.55, c) * smoothstep(0.3, 0.42, f.moist[i])
	var glade := n.fbm(x / StageVegetation.GLADE_SCALE + StageVegetation.GLADE_OX, y / StageVegetation.GLADE_SCALE + StageVegetation.GLADE_OY, 2)
	return amount * (1.0 - smoothstep(0.3, 0.45, glade) * 0.92) * (1.0 - smoothstep(0.35, 0.72, f.elev[i]))

static func cover_field(w: WorldData, key: Vector2i, f: Dictionary) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for y in range(0, OuterLand.C + 1, 8):
		for x in range(0, OuterLand.C + 1, 8):
			var cell := key * OuterLand.C + Vector2i(x, y)
			values.append(cover(w, f, (y + 1) * (OuterLand.C + 3) + x + 1, cell.x, cell.y))
	return values

static func sample_cover(values: PackedFloat32Array, x: float, y: float) -> float:
	var ix := mini(7, floori(x / 8.0))
	var iy := mini(7, floori(y / 8.0))
	var tx := x / 8.0 - ix
	var ty := y / 8.0 - iy
	var k := iy * 9 + ix
	return lerpf(lerpf(values[k], values[k + 1], tx), lerpf(values[k + 9], values[k + 10], tx), ty)

## 12.11.2026: клетка куска за краем плана — вода (озеро закреплённой области, море или дно ниже метра, как у меша
## OuterTerrain). Прежняя проверка шла по высоте плана у края, а не по самой клетке: на воде вдали стояли кроны и заросли.
static func _outer_wet(f: Dictionary, index: int) -> bool:
	if f.has("water") and is_finite(f.water[index]): return true
	var bi: int = f.biome[index]
	var sea := bi == Biomes.SHALLOW or bi == Biomes.OCEAN or bi == Biomes.DEEP
	return Heightfield.outer_meters(f.h[index], not sea) < 1.0

static func outer(w: WorldData, h: Heightfield, key: Vector2i, f: Dictionary, regions: Dictionary, coverage := PackedFloat32Array()) -> Dictionary:
	var raw: Array = []
	var scrub: Array = []
	var side := OuterLand.C + 3
	for y in range(4, OuterLand.C, 8):
		for x in range(4, OuterLand.C, 8):
			var cell := key * OuterLand.C + Vector2i(x, y)
			if Rect2i(0, 0, w.W, w.H).has_point(cell): continue
			var i := (y + 1) * side + x + 1
			var amount := sample_cover(coverage, x, y) if not coverage.is_empty() else cover(w, f, i, cell.x, cell.y)
			if amount < 0.15:
				_outer_scrub(w, h, key, f, regions, x, y, amount, scrub)
				continue
			var kind := Biomes.T_PINE if f.biome[i] == Biomes.TAIGA else Biomes.T_OAK
			for j in 3:
				var u := WGRandom.hash2(cell.x, cell.y, 135 + j)
				var v := WGRandom.hash2(cell.x, cell.y, 171 + j)
				var p := (Vector2(cell) + Vector2(u - 0.5, v - 0.5) * 5.0) * TILE
				var at := Vector2i((p / TILE).floor()) - key * OuterLand.C + Vector2i.ONE
				var index := at.y * side + at.x
				if f.path[index] != 0 or f.river[index] != 0 or Biomes.LIST[f.biome[index]].get("water", false) or _outer_wet(f, index): continue
				var ground := RegionStream.snapshot_ground(w, h, regions, p.x, p.y)
				if ground < 1.0: continue
				var radius := lerpf(4.0, 10.0, amount) * lerpf(0.8, 1.1, u)
				var height := 16.0 + v * 4.0
				raw.append([Vector3(p.x, ground + height * 0.62, p.y), Vector3(radius, height * 0.33, radius), tint(kind, j, p.x / TILE, p.y / TILE), 3, 0.0])
	return pack(raw, scrub)

## Outer land: the same community rule on the 32 m grid of the forest samples (4 samples of 12 m around each).
static func _outer_scrub(w: WorldData, h: Heightfield, key: Vector2i, f: Dictionary, regions: Dictionary, x: int, y: int,
		amount: float, out: Array) -> void:
	var side := OuterLand.C + 3
	for sub in [Vector2i(-2, -2), Vector2i(1, -2), Vector2i(-2, 1), Vector2i(1, 1)]:
		var lx: int = x + sub.x
		var ly: int = y + sub.y
		var k: int = (ly + 1) * side + lx + 1
		if f.path[k] != 0 or f.river[k] != 0: continue
		var cell: Vector2i = key * OuterLand.C + Vector2i(lx, ly)
		var moist: float = f.moist[k] if f.has("moist") else 0.5
		var light: float = f.light[k] if f.has("light") else 0.6
		var elev: float = OuterLand._saved_elev(f, k)
		var slope: float = f.slope[k]
		var rock := StageVegetation.Surface.exposure(elev, slope, moist)
		var site := scrub_site(w.seed_num, cell.x, cell.y, f.biome[k], Floor.ground_moisture(moist, f.dw[k]), light, slope, elev, rock,
			float(f.dw[k]), smoothstep(0.02, 0.14, amount) * 0.6)
		if site.is_empty(): continue
		var p: Vector2 = site.at
		var at := (Vector2i((p / TILE).floor()) - key * OuterLand.C + Vector2i.ONE).clamp(Vector2i.ZERO, Vector2i.ONE * (side - 1))
		if _outer_wet(f, at.y * side + at.x): continue
		var ground := RegionStream.snapshot_ground(w, h, regions, p.x, p.y)
		if ground < 1.0: continue
		out.append(_scrub_item(site, p, ground))
