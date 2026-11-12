extends RefCounted
## Terrain-owned, opaque crown proxies. CPU buffers are built by existing terrain jobs.
const SHADER := preload("res://resources/distant_forest.gdshader")
const TILE := GameConfig.TILE
const SIDE := 128.0 # Keep culling local, even when terrain tiles are 256 m wide.
static var _mesh: ArrayMesh
static var _material: ShaderMaterial
static var active := true
static var far_end := 1400.0 # crown draw distance, m: set per quality level by VegetationLayer

static func plan(w: WorldData, h: Heightfield, key: Vector2i) -> Dictionary:
	var out := {}
	var groups := {}
	var centers := {}
	var rect := Rect2i(key * PlanTerrain.CELLS, Vector2i.ONE * PlanTerrain.CELLS)
	for cy in range(maxi(0, rect.position.y / w.CS), mini(w.CH, ceili(float(rect.end.y) / w.CS))):
		for cx in range(maxi(0, rect.position.x / w.CS), mini(w.CW, ceili(float(rect.end.x) / w.CS))):
			for o: int in w.chunks[cy * w.CW + cx]:
				var kind: int = w.obj_k[o]
				if not Biomes.is_tree(kind): continue
				var x := float(w.obj_x[o]) * TILE
				var z := float(w.obj_y[o]) * TILE
				var size := float(w.obj_s[o])
				var height: float = ForestModels.NOMINAL.get(kind, 16.0) * size
				height *= lerpf(0.92, 1.12, WGRandom.hash2(floori(w.obj_x[o] * 71), floori(w.obj_y[o] * 67), 23))
				var ground := h.ground_at(x, z)
				var conifer := kind == Biomes.T_PINE or kind == Biomes.T_SNOWPINE
				var radius: float = Biomes.CROWN_RADIUS[kind] * TILE * size
				var at := Vector3(x, ground + height * 0.73, z)
				var extent := Vector3(radius, height * (0.30 if conifer else 0.25), radius)
				var group := cluster_key(Vector2(x, z), centers)
				var box := AABB(at - extent, extent * 2.0)
				var color := tint(kind, w.obj_v[o])
				if not groups.has(group): groups[group] = {box = box, color = color, count = 1}
				else:
					groups[group].box = groups[group].box.merge(box)
					groups[group].color += color
					groups[group].count += 1
	for group: Dictionary in groups.values():
		append(out, group.box.get_center(), group.box.size * 0.5, group.color / float(group.count))
	return out

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

static func tint(kind: int, variant: int) -> Color:
	var color := Color("7ca94e")
	if kind == Biomes.T_PINE: color = Color("568758")
	elif kind == Biomes.T_SNOWPINE: color = Color("a1b6aa")
	elif kind == Biomes.T_BIRCH: color = Color("8caf50")
	elif kind == Biomes.T_JUNGLE: color = Color("48824a")
	return color * (0.92 + (variant % 3) * 0.06)

static func append(out: Dictionary, at: Vector3, size: Vector3, color: Color) -> void:
	var key := Vector2i(floori(at.x / SIDE), floori(at.z / SIDE))
	if not out.has(key): out[key] = {buffer = PackedFloat32Array(), bounds = AABB(), count = 0}
	var entry: Dictionary = out[key]
	var center := (Vector2(key) + Vector2.ONE * 0.5) * SIDE
	var local := at - Vector3(center.x, 0, center.y)
	entry.buffer.append_array(PackedFloat32Array([size.x, 0, 0, local.x, 0, size.y, 0, local.y, 0, 0, size.z, local.z, color.r, color.g, color.b, 1]))
	var box := AABB(local - size, size * 2.0)
	entry.bounds = box if entry.count == 0 else entry.bounds.merge(box)
	entry.count += 1

static func attach(parent: Node3D, batches: Dictionary) -> void:
	if _mesh == null:
		_mesh = crown_mesh()
		_material = ShaderMaterial.new()
		_material.shader = SHADER
	for key: Vector2i in batches:
		var entry: Dictionary = batches[key]
		var node := MultiMeshInstance3D.new()
		node.name = "DistantForest"
		node.add_to_group("distant_forest")
		node.visible = active
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _mesh
		mm.instance_count = entry.count
		mm.buffer = entry.buffer
		mm.custom_aabb = entry.bounds
		node.multimesh = mm
		node.material_override = _material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(node)
		var center := (Vector2(key) + Vector2.ONE * 0.5) * SIDE
		node.global_position = Vector3(center.x, 0, center.y)
		node.visibility_range_end = far_end + 150.0
		node.visibility_range_begin = 165.0
		node.visibility_range_end_margin = 32.0

static func crown_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Two hexagonal rings and poles: 24 opaque triangles, visible from any elevation.
	for i in 6:
		var a := float(i) * TAU / 6.0
		var b := float(i + 1) * TAU / 6.0
		var low_a := Vector3(cos(a) * 0.86, -0.42, sin(a) * 0.86)
		var low_b := Vector3(cos(b) * 0.86, -0.42, sin(b) * 0.86)
		var high_a := Vector3(cos(a) * 0.80, 0.42, sin(a) * 0.80)
		var high_b := Vector3(cos(b) * 0.80, 0.42, sin(b) * 0.80)
		for v: Vector3 in [Vector3.DOWN, low_b, low_a, low_a, high_b, high_a, low_a, low_b, high_b, high_a, high_b, Vector3.UP]:
			st.set_normal(v.normalized())
			st.add_vertex(v)
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

static func outer(w: WorldData, h: Heightfield, key: Vector2i, f: Dictionary, regions: Dictionary, coverage := PackedFloat32Array()) -> Dictionary:
	var out := {}
	var side := OuterLand.C + 3
	for y in range(4, OuterLand.C, 8):
		for x in range(4, OuterLand.C, 8):
			var cell := key * OuterLand.C + Vector2i(x, y)
			if Rect2i(0, 0, w.W, w.H).has_point(cell): continue
			var i := (y + 1) * side + x + 1
			var amount := sample_cover(coverage, x, y) if not coverage.is_empty() else cover(w, f, i, cell.x, cell.y)
			if amount < 0.15: continue
			var kind := Biomes.T_PINE if f.biome[i] == Biomes.TAIGA else Biomes.T_OAK
			for j in 3:
				var u := WGRandom.hash2(cell.x, cell.y, 135 + j)
				var v := WGRandom.hash2(cell.x, cell.y, 171 + j)
				var p := (Vector2(cell) + Vector2(u - 0.5, v - 0.5) * 5.0) * TILE
				var at := Vector2i((p / TILE).floor()) - key * OuterLand.C + Vector2i.ONE
				var index := at.y * side + at.x
				if f.path[index] != 0 or f.river[index] != 0 or Biomes.LIST[f.biome[index]].get("water", false): continue
				var ground := RegionStream.snapshot_ground(w, h, regions, p.x, p.y)
				if ground < 1.0: continue
				var radius := lerpf(4.0, 10.0, amount) * lerpf(0.8, 1.1, u)
				append(out, Vector3(p.x, ground + 14.0 + v * 4.0, p.y), Vector3(radius, 6.0 + u * 4.0, radius), tint(kind, j))
	return out
