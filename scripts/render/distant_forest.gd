extends RefCounted
## LOD3 and supplementary canopy for the terrain stream. Workers pack rows; shared meshes and
## materials are created at upload. Each site contributes either a plant silhouette or a small proxy.
const SHADER := preload("res://resources/distant_forest.gdshader")
const PLANT_SHADER := preload("res://resources/distant_plant.gdshader")
const Catalog := preload("res://scripts/render/asset_catalog.gd")
const Understory := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const TILE := GameConfig.TILE
const SIDE := 128.0 # Keep culling local, even when terrain tiles are 256 m wide.
const SPLIT := 620.0 # fine -> coarse, m from the camera
const SPLIT_BAND := 60.0
const NODE_MARGIN := 92.0 # instances of a 128 m cell are up to 91 m from its centre (node ranges are per node)
const SCRUB_STEP := 3 # cells (12 m) between open-land samples
const SCRUB_BEGIN := 144.0 # earliest handover (tall grass); bushes start at 150 m
const SCRUB_END := 950.0
const BUSH_END := 820.0
const OUTER_END := 940.0
const OUTER_SCRUB_END := 720.0
const PLANT_SHARE := 0.8
const TURF_SHARE := 1.0 # 17.11.2026: доля 12-метровых мест газона/степи/дернины с дальними дерновинами
enum { FINE, COARSE, SCRUB, PLANT }
enum Form { BROADLEAF, CONIFER, UMBRELLA, PALM, BUSH, SCRUB_BUSH, SCRUB_PINE, SCRUB_GRASS }
const PARTS := ["f", "c", "s", "p"]
static var _meshes: Array[ArrayMesh] = []
static var _materials: Array[ShaderMaterial] = []
static var active := true
static var far_end := 1400.0 # crown draw distance, m: set per quality level by VegetationLayer
static var near_begin := 240.0 # cells nearer than this are fully covered by real trees

## Coarse node ranges complement frustum culling and the exact per-plant fade.
static func apply_ranges(node: MultiMeshInstance3D, local_range := Vector2.ZERO) -> void:
	var isolated := local_range.y > 0.0
	var begin := local_range.x if isolated else near_begin
	var end := local_range.y if isolated else far_end
	var outer: bool = node.get_meta("outer_terrain", false)
	var scrub_end := minf(end, OUTER_SCRUB_END if outer else SCRUB_END)
	if outer: end = minf(end, OUTER_END)
	node.visible = isolated or active
	var lod: int = node.get_meta("far_lod", FINE)
	match lod:
		COARSE:
			node.visibility_range_begin = maxf(0.0, SPLIT - SPLIT_BAND * 0.5 - NODE_MARGIN)
			node.visibility_range_end = end + NODE_MARGIN
		SCRUB:
			node.visibility_range_begin = maxf(0.0, SCRUB_BEGIN - NODE_MARGIN)
			node.visibility_range_end = scrub_end + NODE_MARGIN
		PLANT:
			var form: int = node.get_meta("plant_form")
			var scrub := form >= Form.SCRUB_BUSH
			node.visibility_range_begin = maxf(0.0, SCRUB_BEGIN - NODE_MARGIN) if scrub else begin
			if scrub: end = scrub_end
			elif form == Form.BUSH: end = minf(end, BUSH_END)
			node.visibility_range_end = end + NODE_MARGIN
		FINE:
			node.visibility_range_begin = begin
			node.visibility_range_end = SPLIT + SPLIT_BAND * 0.5 + NODE_MARGIN
	node.visibility_range_begin_margin = 0.0
	node.visibility_range_end_margin = 0.0

static func plan(w: WorldData, h: Heightfield, key: Vector2i, include_scrub := true) -> Dictionary:
	var raw: Array = []
	var plants := {}
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
				if not _plan_dry(w, h, Vector2(x, z)): continue
				var size := float(w.obj_s[o])
				var ground := h.ground_at(x, z)
				var radius: float = Biomes.CROWN_RADIUS[kind] * TILE * size
				if kind == Biomes.T_ROCK:
					var half := Vector3(radius, radius * 0.45, radius)
					raw.append([Vector3(x, ground + half.y * 0.15, z), half, Color(0.5, 0.49, 0.46, 0.0), 0.0, 1.0])
					continue
				if tree:
					wooded[Vector2i(floori(x / (TILE * SCRUB_STEP)), floori(z / (TILE * SCRUB_STEP)))] = true
				var jitter := WGRandom.hash2(floori(w.obj_x[o] * 71), floori(w.obj_y[o] * 67), 23)
				var height := _nominal_height(kind) * size * lerpf(0.92, 1.12, jitter)
				_add_woody(raw, plants, kind, w.obj_v[o], Vector3(x, ground, z), radius, height, false)
	var scrub := _plan_scrub(w, h, rect, wooded, plants) if include_scrub else []
	return pack(raw, scrub, plants)


static func _plan_dry(w: WorldData, h: Heightfield, p: Vector2, avoid_roads := false) -> bool:
	var cell := Vector2i((p / TILE).floor())
	if not Rect2i(0, 0, w.W, w.H).has_point(cell): return false
	var i := cell.y * w.W + cell.x
	if Biomes.LIST[w.biome[i]].get("water", false) or w.river[i] != 0: return false
	if avoid_roads and w.path_mask[i] != 0: return false
	return not ForestObstacles.on_tread(h, p.x, p.y) and h.depth_at(p.x, p.y) <= GameConfig.WATER_MARGIN


static func _nominal_height(kind: int) -> float:
	match kind:
		Biomes.T_BUSH: return 1.5
		Biomes.T_ACACIA: return 4.4
		Biomes.T_PALM: return 8.0
		Biomes.T_JUNGLE: return 8.8
		_: return float(ForestModels.NOMINAL[kind])


static func _form(kind: int) -> int:
	match kind:
		Biomes.T_BUSH, Biomes.T_MUGO: return Form.BUSH
		Biomes.T_PINE, Biomes.T_SNOWPINE: return Form.CONIFER
		Biomes.T_ACACIA: return Form.UMBRELLA
		Biomes.T_PALM: return Form.PALM
		_: return Form.BROADLEAF


static func _plant_hash(at: Vector3, salt: int) -> float:
	return WGRandom.hash2(floori(at.x * 17.0), floori(at.z * 19.0), salt)


static func _add_woody(raw: Array, plants: Dictionary, kind: int, variant: int, at: Vector3, radius: float,
		height: float, outer: bool) -> void:
	var color := tint(kind, variant, at.x / TILE, at.z / TILE)
	var is_bush := kind == Biomes.T_BUSH or kind == Biomes.T_MUGO
	var r := radius * (1.15 if kind == Biomes.T_MUGO else 1.0)
	if _plant_hash(at, 461) < PLANT_SHARE:
		# Open up the outline on the last LOD. Cards carry the gaps in the leaves.
		var age := variant / 3 if ForestModels.has_ages(kind) else ForestModels.ADULT_AGE
		var profile := lerpf(0.87, 1.19, _plant_hash(at, 727))
		if age == ForestModels.YOUNG_AGE: profile *= 0.84
		elif age == ForestModels.OLD_AGE: profile *= 1.18
		_append_plant(plants, at, r * profile * 1.13, height, color, _form(kind), outer, float(age))
	else:
		var center := 0.48 if is_bush else (0.60 if color.a > 0.5 else 0.70)
		var extent := 0.39 if is_bush or color.a > 0.5 else 0.29
		var stem_base := 0.0 if is_bush else -center / extent
		raw.append([at + Vector3.UP * height * center, Vector3(r, height * extent, r), color, stem_base, 0.0])

## One distant planting site per 12 m sample where the open-land community has enough vegetation.
static func _plan_scrub(w: WorldData, h: Heightfield, rect: Rect2i, wooded: Dictionary, plants: Dictionary) -> Array:
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
			if w.path_mask[k] != 0 or w.river[k] != 0 or Biomes.LIST[w.biome[k]].get("water", false): continue
			var edge := 0.0
			for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if wooded.has(cell + o): edge = 0.6
			var rock := float(rock_field[k]) / 255.0 if has_rock else Floor.rockiness(w, k)
			var light := StageClimate.natural_conditions(w, i, j).x
			var site := scrub_site(w.seed_num, i, j, w.biome[k], Floor.ground_moisture(w.moist[k], w.dist_water[k]), light,
				w.slope[k], w.elev[k], rock, w.dist_water[k], edge)
			if site.is_empty(): continue
			var p: Vector2 = site.at
			if not _plan_dry(w, h, p, true): continue
			_add_scrub(out, plants, site, p, h.ground_at(p.x, p.y), false)
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
		# 17.11.2026: лещина — прибавка к густоте (VegetationLayer._fill_open_cell): доли считаются без её весов
		total -= com[c] * (row[Understory.HAZEL] + row[Understory.HAZEL_TALL])
		woody += com[c] * (row[Understory.BUSH] + row[Understory.SAPLING] + row[Understory.PINE] + row[Understory.HAZEL])
		tall += com[c] * (row[Understory.YOUNG] + row[Understory.YOUNG_PINE] + row[Understory.HAZEL_TALL])
		herb += com[c] * (row[Understory.MEADOW] + row[Understory.HIGH_GRASS] + row[Understory.SEDGE] + row[Understory.STIPA] + row[Understory.FORBS] * 0.6)
	var wetland := Understory.open_wetland(bi, com[Understory.C_WET], water)
	var patch := Understory.open_patch(VegetationLayer._vnoise(i, j, 3.0, seed + 31), wetland)
	density *= Understory.open_exposure(rock, slope)
	# Bushes per 4 m cell (OPEN_SLOTS places, density share, woody share of the weights)
	var per_cell := density * Understory.OPEN_SLOTS * (woody + tall) / maxf(total, 0.001)
	if bi == Biomes.ROCK: per_cell *= 0.5
	# A thicket needs a few bushes in 12 m; the 12 m patch noise of the near layout makes the gaps.
	var mass := per_cell * patch
	var u := WGRandom.hash2(i, j, seed + 991)
	var v := WGRandom.hash2(i, j, seed + 993)
	if mass < 0.22 or WGRandom.hash2(i, j, seed + 977) > smoothstep(0.22, 0.6, mass) + 0.15:
		# 12.11.2026: без кустов холм вдали не голый — массивы высокотравья (куртины по пояс) тоже видны
		# низкими широкими валами: там, где ближняя раскладка ставит густые куртины, осоку и ковыль.
		var herb_mass := density * Understory.OPEN_SLOTS * herb / maxf(total, 0.001) * patch
		if herb_mass < 0.4 or WGRandom.hash2(i, j, seed + 979) > smoothstep(0.4, 1.6, herb_mass) * 0.85:
			# 17.11.2026: газон, степь и горный луг вдали — низкие дерновины-валы (продолжение ближних дерновин
			# VegetationLayer._open_sod): без них за 150 м такие луга были одной окраской земли.
			var lawn := com[Understory.C_LAWN] + com[Understory.C_TURF] + com[Understory.C_FORBS] * 0.6
			var sod := TURF_SHARE * clampf(lawn, 0.0, 1.0) * Understory.open_exposure(rock, slope) * (0.6 + 0.8 * patch)
			if WGRandom.hash2(i, j, seed + 983) > sod: return {}
			return {at = (Vector2(i, j) + Vector2(0.5 + (u - 0.5) * 2.2, 0.5 + (v - 0.5) * 2.2)) * TILE, mass = 1.0, tall = 0.0,
				juniper = false, conifer = false, u = u, turf = true, parch = clampf((0.55 - moisture) * 1.6 + dry * 0.35 + alt * 0.4, 0.0, 1.0)}
		return {at = (Vector2(i, j) + Vector2(0.5 + (u - 0.5) * 2.2, 0.5 + (v - 0.5) * 2.2)) * TILE, mass = 1.0, tall = 0.0, juniper = false,
			conifer = false, u = u, herb = true, parch = clampf((0.55 - moisture) * 1.6 + dry * 0.35 + alt * 0.4, 0.0, 1.0)}
	return {at = (Vector2(i, j) + Vector2(0.5 + (u - 0.5) * 2.2, 0.5 + (v - 0.5) * 2.2)) * TILE, mass = minf(mass, 1.6),
		tall = tall / maxf(woody + tall, 0.001), juniper = alt > 0.27 or rock > 0.3 or com[Understory.C_TURF] > 0.5,
		conifer = bi in [Biomes.TAIGA, Biomes.TUNDRA] or alt > 0.3, u = u}

static func _scrub_item(site: Dictionary, p: Vector2, ground: float) -> Array:
	var mass: float = site.mass
	var u: float = site.u
	if site.get("turf", false):
		# дерновина: широкий низкий вал, чуть темнее дёрна земли (шейдер берёт половину тона, как у крон)
		var turf_r := lerpf(2.2, 3.8, u)
		var turf_h := lerpf(0.45, 0.75, fposmod(u * 3.71, 1.0))
		var turf_c := Color("86a64c").lerp(Color("b4a463"), float(site.parch)) * lerpf(0.92, 1.08, fposmod(u * 6.17, 1.0))
		turf_c.a = 0.0
		return [Vector3(p.x, ground + turf_h * 0.25, p.y), Vector3(turf_r, turf_h * 0.5, turf_r), turf_c, 3.0, 0.0]
	if site.get("herb", false):
		# вал высокотравья: сочный оливково-зелёный, на сухом месте — соломенный (как ближние куртины)
		var grass_r := lerpf(3.2, 5.6, u)
		var grass_h := lerpf(0.8, 1.4, fposmod(u * 5.13, 1.0))
		var grass_c := Color("5f7d38").lerp(Color("93884a"), float(site.parch)) * lerpf(0.92, 1.06, u)
		grass_c.a = 0.0
		return [Vector3(p.x, ground + grass_h * 0.3, p.y), Vector3(grass_r, grass_h * 0.5, grass_r), grass_c, 3.0, 0.0]
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
	return [Vector3(p.x, ground + height * 0.42, p.y), Vector3(radius, height * 0.5, radius), color, 2.0, 0.0]

static func _add_scrub(proxies: Array, plants: Dictionary, site: Dictionary, p: Vector2, ground: float, outer: bool) -> void:
	var item := _scrub_item(site, p, ground)
	var at := Vector3(p.x, ground, p.y)
	if site.get("turf", false) or _plant_hash(at, 461) >= PLANT_SHARE: # дерновины — только непрозрачные валы
		proxies.append(item)
		return
	var form := Form.SCRUB_BUSH
	if site.get("herb", false): form = Form.SCRUB_GRASS
	elif site.conifer and site.tall > 0.3 and not site.juniper: form = Form.SCRUB_PINE
	var half: Vector3 = item[1]
	_append_plant(plants, at, half.x * 1.08, half.y * 2.0, item[2], form, outer, 0.0)

## Instance colour: rgb is the leaf tint, alpha is the conifer share (the shader narrows conifers into cones).
static func tint(kind: int, variant: int, x: float, y: float) -> Color:
	var color := Color("7ca94e")
	if kind == Biomes.T_PINE: color = Color("568758")
	elif kind == Biomes.T_SNOWPINE: color = Color("a1b6aa")
	elif kind == Biomes.T_ROWAN: color = Color("55863a")
	elif kind == Biomes.T_MUGO: color = Color("355e3a")
	elif kind == Biomes.T_BIRCH: color = Color("8caf50")
	elif kind == Biomes.T_JUNGLE: color = Color("48824a")
	elif kind == Biomes.T_BUSH: color = Color("6a8c42")
	elif kind == Biomes.T_PALM: color = Color("589943")
	elif kind == Biomes.T_ACACIA: color = Color("91a852")
	color = Biomes.leaf_tone(kind, color * (0.92 + (variant % 3) * 0.06), x, y) # тот же тон, что у ближней модели
	color.a = 1.0 if kind == Biomes.T_PINE or kind == Biomes.T_SNOWPINE else 0.0
	return color

## A crown keeps its anchor at both distances. Merging centres across slopes and shorelines
## can move a crown over empty space even when all its original positions are valid.
static func pack(raw: Array, scrub: Array = [], plants := {}, outer := false) -> Dictionary:
	var fine := {}
	var coarse := {}
	for item: Array in raw:
		var at: Vector3 = item[0]
		var size: Vector3 = item[1]
		var color: Color = item[2]
		var base: float = item[3]
		var stuff: float = item[4]
		_append_proxy(fine, at, size, color, FINE, base, stuff, outer)
		if base < 0.0:
			_append_proxy(coarse, at, size, color, COARSE, base, stuff, outer)
	var thickets := {}
	for item: Array in scrub:
		_append_proxy(thickets, item[0], item[1], item[2], SCRUB, item[3], item[4], outer)
	return {f = fine, c = coarse, s = thickets, p = plants}

static func _append_proxy(out: Dictionary, at: Vector3, size: Vector3, color: Color, kind: int,
		base: float, stuff: float, outer: bool) -> void:
	var cell := Vector2i(floori(at.x / SIDE), floori(at.z / SIDE))
	var extent := Vector3(maxf(size.x, size.z), size.y, maxf(size.x, size.z)) * 1.25
	var bottom := Vector3(extent.x, maxf(extent.y, (-base + 0.05) * size.y), extent.z)
	_append(out, cell, cell, at, size, color, Vector4(kind, base, stuff, float(outer)), AABB(-bottom, bottom + extent))


static func _append_plant(out: Dictionary, at: Vector3, radius: float, height: float, color: Color,
		form: int, outer: bool, age: float) -> void:
	var cell := Vector2i(floori(at.x / SIDE), floori(at.z / SIDE))
	var key := Vector3i(cell.x, cell.y, form)
	var extent := radius * 1.55
	var bounds := AABB(Vector3(-extent, -height * 0.25, -extent), Vector3(extent * 2.0, height * 1.65, extent * 2.0))
	_append(out, key, cell, at, Vector3(radius, height, radius), color,
		Vector4(form, _plant_hash(at, 751), float(outer), age), bounds)


static func _append(out: Dictionary, key: Variant, cell: Vector2i, at: Vector3, size: Vector3, color: Color,
		custom: Vector4, bounds: AABB) -> void:
	if not out.has(key): out[key] = {buffer = PackedFloat32Array(), bounds = AABB(), count = 0}
	var entry: Dictionary = out[key]
	var center := (Vector2(cell) + Vector2.ONE * 0.5) * SIDE
	var local := at - Vector3(center.x, 0, center.y)
	var angle := WGRandom.hash2(floori(at.x * 3.0), floori(at.z * 3.0), 419) * TAU
	var c := cos(angle)
	var s := sin(angle)
	entry.buffer.append_array(PackedFloat32Array([c * size.x, 0, s * size.z, local.x, 0, size.y, 0, local.y, -s * size.x, 0, c * size.z, local.z,
		color.r, color.g, color.b, color.a, custom.x, custom.y, custom.z, custom.w]))
	var box := AABB(local + bounds.position, bounds.size)
	entry.bounds = box if entry.count == 0 else entry.bounds.merge(box)
	entry.count += 1

static func attach(parent: Node3D, batches: Dictionary, local_range := Vector2.ZERO, outer := false) -> void:
	if batches.is_empty(): return
	if _meshes.is_empty():
		_meshes = [lobe_mesh(FINE), lobe_mesh(COARSE), lobe_mesh(SCRUB)]
		for form in Form.size():
			_meshes.append(_plant_mesh(form))
		var proxy := ShaderMaterial.new()
		proxy.shader = SHADER
		var plant := ShaderMaterial.new()
		plant.shader = PLANT_SHADER
		var textures: Array[Texture2D] = Catalog.get_catalog().textures
		plant.set_shader_parameter("leaves", textures[1])
		plant.set_shader_parameter("needles", textures[2])
		_materials = [proxy, plant]
	for lod in PARTS.size():
		var cells: Dictionary = batches.get(PARTS[lod], {})
		for key in cells:
			var entry: Dictionary = cells[key]
			var plant := lod == PLANT
			var node := MultiMeshInstance3D.new()
			node.name = "VegetationLOD3" if plant else "DistantForest"
			if local_range.y <= 0.0:
				node.add_to_group("distant_forest")
			node.set_meta("far_lod", lod)
			node.set_meta("outer_terrain", outer)
			if plant: node.set_meta("plant_form", key.z)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.use_custom_data = true
			mm.mesh = _meshes[PLANT + key.z if plant else lod]
			mm.instance_count = entry.count
			mm.buffer = entry.buffer
			mm.custom_aabb = entry.bounds
			node.multimesh = mm
			node.material_override = _materials[int(plant)]
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			apply_ranges(node, local_range)
			parent.add_child(node)
			var center := (Vector2(key.x, key.y) + Vector2.ONE * 0.5) * SIDE
			node.global_position = Vector3(center.x, 0, center.y)

## Clusters of lobes in the unit box. Each lobe is a hexagonal bipyramid with an off-centre waist (12 triangles):
## a rounded top and a flatter underside. UV — lobe centre (x, z), UV2 — (lobe index, lobe-local height -1..1);
## the shader turns lobes into cones for conifers, varies their height and drops extra lobes of small clusters.
## Fine and coarse use a single crown at the source tree. Scrub can still have several lobes.
const LOBES := {
	FINE: [[Vector3.ZERO, Vector3(0.66, 0.9, 0.66)]],
	COARSE: [[Vector3.ZERO, Vector3(0.66, 0.9, 0.66)]],
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
		var sides := 4 if kind == COARSE else 6
		for i in sides:
			var a := (float(i) + 0.5 * (index % 2)) * TAU / sides
			var b := (float(i + 1) + 0.5 * (index % 2)) * TAU / sides
			var ring_a := Vector3(cos(a), -0.12, sin(a))
			var ring_b := Vector3(cos(b), -0.12, sin(b))
			for v: Vector3 in [top, ring_a, ring_b, bottom, ring_b, ring_a]:
				var local := Vector3(v.x * r.x, v.y * r.y, v.z * r.z)
				st.set_normal((v * Vector3(1.0, 0.8, 1.0)).normalized())
				st.set_uv(Vector2(c.x, c.z))
				st.set_uv2(Vector2(index * 4.0 + c.y + 1.0, v.y))
				st.add_vertex(c + local)
	if kind != SCRUB:
		for i in 2:
			_stem_card(st, float(i) * PI * 0.5)
	return st.commit()


static func _stem_card(st: SurfaceTool, angle: float) -> void:
	var across := Vector3(cos(angle), 0, sin(angle))
	for corner: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
		st.set_normal(across.cross(Vector3.UP))
		st.set_uv(Vector2.ZERO)
		st.set_uv2(Vector2(17.0, corner.y))
		st.add_vertex(across * (corner.x * 2.0 - 1.0) * lerpf(0.075, 0.027, corner.y))


## Normalized plant geometry. The meshes use the catalog leaf cutouts and spend triangles
## on distinct silhouettes and a grounded stem. Every form shares the same shader.
static func _plant_mesh(form: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match form:
		Form.CONIFER, Form.SCRUB_PINE:
			_stem(st, 0.82, 0.055)
			for i in 3:
				var angle := float(i) * PI / 3.0
				_card(st, Vector3(0, 0.50, 0), angle, Vector2(0.99, 0.35), 0.40, 2.0)
				_card(st, Vector3(0, 0.80, 0), angle + 0.3, Vector2(0.64, 0.25), 0.30, 2.0)
		Form.PALM:
			_stem(st, 0.88, 0.07, 0.20)
			for i in 6:
				var angle := TAU * float(i) / 6.0
				var dir := Vector3(cos(angle), 0, sin(angle))
				_card(st, Vector3(0.2, 0.91, 0) + dir * 0.57, angle, Vector2(0.71, 0.18), 0.70, 2.0, 1.4)
		Form.UMBRELLA:
			_stem(st, 0.79, 0.068)
			_rounded_crown(st, 0.77, 0.23)
		Form.BUSH, Form.SCRUB_BUSH:
			_rounded_crown(st, 0.47, 0.49)
		Form.SCRUB_GRASS:
			for i in 3:
				_card(st, Vector3(0, 0.40, 0), float(i) * PI / 3.0, Vector2(1.04, 0.51), 0.96, 3.0)
		_:
			_stem(st, 0.74, 0.085)
			_rounded_crown(st, 0.70, 0.32)
	return st.commit()


static func _rounded_crown(st: SurfaceTool, y: float, height: float) -> void:
	for i in 3:
		_card(st, Vector3(0, y, 0), float(i) * PI / 3.0, Vector2(0.99, height), 0.77, 1.0)
	_card(st, Vector3(0.43, y + height * 0.19, 0.29), 0.82, Vector2(0.71, height * 0.88), 0.82, 1.0, 0.56)
	_card(st, Vector3(-0.37, y - height * 0.15, -0.26), 2.16, Vector2(0.66, height * 0.85), 0.80, 1.0, 0.69)


static func _stem(st: SurfaceTool, height: float, radius: float, lean := 0.0) -> void:
	for i in 2:
		_card(st, Vector3(0, (height - 0.1) * 0.5, 0), float(i) * PI * 0.5,
			Vector2(radius, (height + 0.1) * 0.5), 0.33, 0.0, 0.0, Vector3(lean, 0, 0))


static func _card(st: SurfaceTool, center: Vector3, angle: float, size: Vector2, taper: float, material: float,
		tilt := 0.0, lean := Vector3.ZERO) -> void:
	var along := Vector3(cos(angle), 0, sin(angle))
	var across := along.cross(Vector3.UP)
	var up := Vector3.UP * cos(tilt) + across * sin(tilt)
	var normal := along.cross(up).lerp(Vector3.UP, 0.36).normalized()
	for corner: Vector2 in [Vector2(0, 1), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), Vector2(0, 0), Vector2(1, 0)]:
		var top := 1.0 - corner.y
		st.set_normal(normal)
		st.set_uv(corner)
		st.set_uv2(Vector2(material, 0))
		st.add_vertex(center + along * (corner.x * 2.0 - 1.0) * size.x * lerpf(1.0, taper, top)
			+ up * (top * 2.0 - 1.0) * size.y + lean * top)

static func _cover(w: WorldData, f: Dictionary, i: int, x: float, y: float, bias: float) -> float:
	var bi: int = f.biome[i]
	if bi not in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.SWAMP, Biomes.GRASS]: return 0.0
	if not outer_dry(f, i) or f.elev[i] > 0.72 or f.slope[i] > 0.85: return 0.0
	var n: Simplex = w.noise.forest
	var wood := n.fbm(x / StageVegetation.WOOD_SCALE + StageVegetation.WOOD_OX, y / StageVegetation.WOOD_SCALE + StageVegetation.WOOD_OY, StageVegetation.WOOD_OCT)
	var fine := n.fbm(x / 36.0, y / 36.0, 3)
	var c := wood * 1.15 + bias + fine * 0.4
	var altitude := 1.0 - smoothstep(0.35, 0.72, f.elev[i])
	if bi == Biomes.GRASS:
		var stand := n.fbm(x / StageVegetation.STAND_SCALE + StageVegetation.STAND_OX,
			y / StageVegetation.STAND_SCALE + StageVegetation.STAND_OY, 2)
		var positions: Variant = f.get("meadow_position")
		var position: float = positions[i] if positions != null else 0.0
		return StageVegetation.meadow_cover(c, stand, f.moist[i], position) * altitude
	var amount := smoothstep(-0.3, 0.12, c)
	var glade := n.fbm(x / StageVegetation.GLADE_SCALE + StageVegetation.GLADE_OX, y / StageVegetation.GLADE_SCALE + StageVegetation.GLADE_OY, 2)
	return amount * (1.0 - smoothstep(0.3, 0.45, glade) * 0.92) * altitude

static func cover_field(w: WorldData, key: Vector2i, f: Dictionary) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	var bias := StageVegetation.world_cover(w.seed_num)
	for y in range(0, OuterLand.C + 1, 8):
		for x in range(0, OuterLand.C + 1, 8):
			var cell := key * OuterLand.C + Vector2i(x, y)
			values.append(_cover(w, f, (y + 1) * (OuterLand.C + 3) + x + 1, cell.x, cell.y, bias))
	return values

static func sample_cover(values: PackedFloat32Array, x: float, y: float) -> float:
	var ix := mini(7, floori(x / 8.0))
	var iy := mini(7, floori(y / 8.0))
	var tx := x / 8.0 - ix
	var ty := y / 8.0 - iy
	var k := iy * 9 + ix
	return lerpf(lerpf(values[k], values[k + 1], tx), lerpf(values[k + 9], values[k + 10], tx), ty)

static func outer_dry(f: Dictionary, index: int) -> bool:
	return f.path[index] == 0 and f.river[index] == 0 and not Biomes.LIST[f.biome[index]].get("water", false) \
		and not is_finite(f.water[index]) and f.h[index] > 0.0


## Both terrain index buffers keep these vertices. Place far instances there so a
## terrain LOD switch on a steep slope cannot leave them hovering above its triangles.
static func _outer_anchor(p: Vector2) -> Vector2:
	return (((p / TILE - Vector2.ONE * 0.5) * 0.5).round() * 2.0 + Vector2.ONE * 0.5) * TILE


## Read the same vertex heights as OuterTerrain, including generated land outside
## committed regions. Refined trails use their own mesh. INF means no valid anchor.
static func _outer_ground(plan: Rect2i, origin: Vector2i, f: Dictionary, heights: PackedFloat32Array,
		regions: Dictionary, p: Vector2, cell: Vector2i) -> float:
	if plan.has_point(cell): return INF
	var side := OuterLand.C + 3
	var index := (cell.y - origin.y + 1) * side + cell.x - origin.x + 1
	if not outer_dry(f, index): return INF
	var refined := OuterLand.refined_at(regions, p.x, p.y)
	if not refined.is_empty() and refined.weight > 0.05: return INF
	var ground: float = heights[index] if refined.is_empty() else refined.h
	return ground if ground >= 0.2 else INF


static func outer(w: WorldData, key: Vector2i, f: Dictionary, heights: PackedFloat32Array, regions: Dictionary,
		coverage: PackedFloat32Array) -> Dictionary:
	var raw: Array = []
	var scrub: Array = []
	var plants := {}
	var plan_rect := Rect2i(0, 0, w.W, w.H)
	var origin := key * OuterLand.C
	var side := OuterLand.C + 3
	var planted := {}
	var cover_bias := StageVegetation.world_cover(w.seed_num)
	for y in range(4, OuterLand.C, 8):
		for x in range(4, OuterLand.C, 8):
			var cell := origin + Vector2i(x, y)
			var amount := sample_cover(coverage, x, y)
			if amount < 0.15:
				_outer_scrub(w, plan_rect, origin, f, heights, regions, Vector2i(x, y), amount, scrub, plants, planted)
				continue
			for j in 2:
				var u := WGRandom.hash2(cell.x, cell.y, 135 + j)
				var v := WGRandom.hash2(cell.x, cell.y, 171 + j)
				var p := _outer_anchor((Vector2(cell) + Vector2(u - 0.5, v - 0.5) * 5.0) * TILE)
				if planted.has(p): continue
				var anchor := Vector2i((p / TILE).floor())
				var at := anchor - origin + Vector2i.ONE
				var index := at.y * side + at.x
				var site_cover := _cover(w, f, index, p.x / TILE, p.y / TILE, cover_bias)
				if site_cover < 0.12: continue
				var ground := _outer_ground(plan_rect, origin, f, heights, regions, p, anchor)
				if ground == INF: continue
				var kind := Biomes.T_OAK
				match f.biome[index]:
					Biomes.TAIGA: kind = Biomes.T_PINE
					Biomes.JUNGLE: kind = Biomes.T_JUNGLE
					Biomes.GRASS: kind = Biomes.T_BIRCH
				var scale := lerpf(0.65, 1.2, site_cover) * lerpf(0.84, 1.13, u)
				var radius: float = Biomes.CROWN_RADIUS[kind] * TILE * scale
				var height := _nominal_height(kind) * scale
				_add_woody(raw, plants, kind, j, Vector3(p.x, ground, p.y), radius, height, true)
				planted[p] = true
	return pack(raw, scrub, plants, true)

## Outer land: the same community rule on the 32 m grid of the forest samples (4 samples of 12 m around each).
static func _outer_scrub(w: WorldData, plan: Rect2i, origin: Vector2i, f: Dictionary, heights: PackedFloat32Array,
		regions: Dictionary, sample: Vector2i, amount: float, out: Array, plants: Dictionary, planted: Dictionary) -> void:
	var side := OuterLand.C + 3
	for sub in [Vector2i(-2, -2), Vector2i(1, -2), Vector2i(-2, 1), Vector2i(1, 1)]:
		var local: Vector2i = sample + sub
		var k: int = (local.y + 1) * side + local.x + 1
		if not outer_dry(f, k): continue
		var cell := origin + local
		var moist: float = f.moist[k]
		var light: float = f.light[k]
		var elev: float = f.elev[k]
		var slope: float = f.slope[k]
		var rock := float(f.rock[k]) / 255.0
		var site := scrub_site(w.seed_num, cell.x, cell.y, f.biome[k], Floor.ground_moisture(moist, f.dw[k]), light, slope, elev, rock,
			float(f.dw[k]), smoothstep(0.02, 0.14, amount) * 0.6)
		if site.is_empty(): continue
		var p := _outer_anchor(site.at)
		if planted.has(p): continue
		var anchor := Vector2i((p / TILE).floor())
		var at := anchor - origin + Vector2i.ONE
		var i := at.y * side + at.x
		var bi: int = f.biome[i]
		if f.slope[i] > 1.15 or (not Biomes.LIST[bi].has("grass") and bi != Biomes.ROCK): continue
		var ground := _outer_ground(plan, origin, f, heights, regions, p, anchor)
		if ground == INF: continue
		_add_scrub(out, plants, site, p, ground, true)
		planted[p] = true
