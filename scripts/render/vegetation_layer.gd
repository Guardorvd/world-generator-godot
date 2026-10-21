class_name VegetationLayer
extends Node3D
## Неподвижные MultiMesh по чанкам, видам и силуэтам, Mesh LOD и точные AABB.
## 6.6+: подлесок и лесная поверхность обновляются вместе с травой в фоне.
## Главный поток передаёт один чанк за кадр.

const TILE := GameConfig.TILE
const WATER_MARGIN := 0.3
const LOAD_RADIUS := GameConfig.TREE_R + 64.0 # запас на фоновую подготовку при движении
const DROP_RADIUS := LOAD_RADIUS + 96.0     # гистерезис: не пересоздаём чанк на границе
const RECHECK := 24.0
const Understory := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const UNDERSTORY_MAX := 2048 # на форму, только в радиусе травы

var world: WorldData
var heights: Heightfield
var veg := {} # Vector2i(чанк, вид) -> буферы, MultiMesh и узлы
var grass: MultiMesh
var grass_buf: PackedFloat32Array
var last_fill := Vector2.INF
var last_trees := Vector2.INF
var _task := -1
var _pending: Array = [] # готовые чанки, ближайшие в конце
var _built: Array = []   # пишет задача, читаем после wait_for_task_completion
var _loaded := {}       # включая пустые чанки
var _defs := {}         # неизменяемые меши, материалы и локальные AABB
var _grass_n := 0
var _grass_bounds := AABB()
var _grass_margin := 0.0
var understory: Array = [] # те же фоновые буферы и цикл обновления, что у травы
var _forest_surface: Image


func setup(w: WorldData, h: Heightfield, defs: Dictionary, grass_mesh: Mesh, forest: Image = null) -> void:
	world = w
	heights = h
	_forest_surface = forest if forest != null else Floor.surface_image(w)
	for kind in defs:
		var def: Dictionary = defs[kind]
		var entry := {leaves = def.get("leaves", []), box = AABB()}
		var first := true
		for part in ["trunk", "crown"]:
			if not def.has(part):
				continue
			entry[part] = def[part]
			var box: AABB = def[part].get_aabb()
			entry.box = box if first else entry.box.merge(box)
			first = false
			var mat := _vcolor_mat(false)
			mat.albedo_texture = def.get(part + "_texture", null)
			if part == "crown" and def.get("cutout", false):
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				mat.alpha_scissor_threshold = 0.4
				mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			if part == "trunk":
				mat.vertex_color_use_as_albedo = def.get("colored_bark", false)
				mat.albedo_color = def.bark
			entry[part + "_mat"] = mat
		_defs[kind] = entry
	grass = _multimesh(grass_mesh, _vcolor_mat(true), GameConfig.GRASS_MAX, true, false).multimesh
	_grass_margin = _radius(grass_mesh) * 1.5
	grass_buf = _buffer(GameConfig.GRASS_MAX, 16)
	var meshes := Understory.meshes()
	meshes.append_array(Floor.meshes())
	for mesh in meshes:
		var kind := understory.size() - Floor.FIRST
		var shadows := kind in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG]
		var node := _multimesh(mesh, _vcolor_mat(true), UNDERSTORY_MAX, true, shadows)
		node.visibility_range_end = GameConfig.GRASS_R
		node.visibility_range_end_margin = 8.0
		understory.append({mm = node.multimesh, buf = _buffer(UNDERSTORY_MAX, 16), count = 0,
			low = Vector3.INF, high = -Vector3.INF, box = mesh.get_aabb()})


static func _vcolor_mat(two_sided: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 1.0
	if two_sided:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func _buffer(cap: int, stride: int) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(cap * stride)
	return b


static func _radius(mesh: Mesh) -> float:
	var box := mesh.get_aabb()
	return box.position.length() + box.size.length()


func _multimesh(mesh: Mesh, mat: Material, count: int, colors: bool, shadows: bool = true) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.material_override = mat
	node.lod_bias = 0.6
	if not shadows:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


## true — в кадре была передача на GPU; дальний рельеф уступает этот кадр.
## force используется при появлении/переносе: дождаться фона и показать только нужное место.
func update(px: float, pz: float, force: bool) -> bool:
	var p := Vector2(px, pz)
	if force:
		_finish()
		_pending.clear()
		_built.clear()
	elif _task != -1:
		if WorkerThreadPool.is_task_completed(_task):
			_finish()
			if p.distance_to(last_fill) > LOAD_RADIUS:
				_built.clear()
				_pending.clear()
				last_fill = Vector2.INF
				return false
			_pending.append_array(_built)
			_built = []
			_apply_grass()
			return true
		return false
	# Проверяем положение и до передачи очереди: старые результаты переноса не показываем.
	if force or last_trees == Vector2.INF or p.distance_to(last_trees) >= RECHECK:
		last_trees = p
		_drop(p)
		_pending = _pending.filter(func(b: Dictionary) -> bool: return _distance(b.chunk, p) <= LOAD_RADIUS)
	if not force and not _pending.is_empty():
		if p.distance_to(last_fill) >= 8.0:
			last_fill = p
			var none: Array[int] = []
			_task = WorkerThreadPool.add_task(_fill.bind(px, pz, none), true, "Трава")
			return false
		_apply_chunk(_pending.pop_back())
		return true
	if not force and last_fill != Vector2.INF and p.distance_to(last_fill) < 8.0:
		return false
	last_fill = p
	var missing := _wanted(p)
	if force:
		_fill(px, pz, missing)
		for built: Dictionary in _built:
			_apply_chunk(built)
		_built.clear()
		_apply_grass()
	else:
		_task = WorkerThreadPool.add_task(_fill.bind(px, pz, missing), true, "Растительность")
	return force


func _finish() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _exit_tree() -> void:
	_finish()


func _distance(chunk: int, p: Vector2) -> float:
	var side := world.CS * TILE
	var corner := Vector2(chunk % world.CW, chunk / world.CW) * side
	return p.distance_to(p.clamp(corner, corner + Vector2.ONE * side))


func _wanted(p: Vector2) -> Array[int]:
	var out: Array[int] = []
	var side := world.CS * TILE
	for cy in range(maxi(0, floori((p.y - LOAD_RADIUS) / side)), mini(world.CH - 1, floori((p.y + LOAD_RADIUS) / side)) + 1):
		for cx in range(maxi(0, floori((p.x - LOAD_RADIUS) / side)), mini(world.CW - 1, floori((p.x + LOAD_RADIUS) / side)) + 1):
			var c := cy * world.CW + cx
			if not _loaded.has(c) and _distance(c, p) <= LOAD_RADIUS:
				out.append(c)
	# Фон строит список от дальних к ближним; главный поток берёт с конца.
	out.sort_custom(func(a: int, b: int) -> bool: return _distance(a, p) > _distance(b, p))
	return out


func _drop(p: Vector2) -> void:
	for key: Vector2i in veg.keys():
		if _distance(key.x, p) > DROP_RADIUS:
			for node: MultiMeshInstance3D in veg[key].nodes:
				node.visible = false
				node.queue_free()
			veg.erase(key)
	for chunk: int in _loaded.keys():
		if _distance(chunk, p) > DROP_RADIUS:
			_loaded.erase(chunk)


func _fill(px: float, pz: float, missing: Array[int]) -> void:
	_built = []
	for chunk in missing:
		_built.append(_build_chunk(chunk))
	_fill_grass(px, pz)


func _build_chunk(chunk: int) -> Dictionary:
	var groups := {}
	for o in world.chunks[chunk]:
		var kind := world.obj_k[o]
		if not _defs.has(kind):
			continue
		var ox := world.obj_x[o]
		var oy := world.obj_y[o]
		var cell := floori(oy) * world.W + floori(ox)
		if world.path_mask[cell] >= 2:
			continue
		var x := ox * TILE
		var z := oy * TILE
		var ground := heights.ground_at(x, z)
		if kind != Biomes.T_REED and kind != Biomes.T_ROCK and ground < heights.water_level[cell] - WATER_MARGIN:
			if heights.depth_at(x, z) > WATER_MARGIN:
				continue
		# Выбор силуэта по координатам независим от оттенка и возраста дерева.
		var model := kind
		if _defs.has(kind + ForestModels.MODEL_STRIDE):
			var variant := mini(ForestModels.VARIANTS - 1, int(WGRandom.hash2(floori(ox * 113), floori(oy * 109), 65) * ForestModels.VARIANTS))
			model += variant * ForestModels.MODEL_STRIDE
		if not groups.has(model):
			groups[model] = {ids = [], ground = []}
		groups[model].ids.append(o)
		groups[model].ground.append(ground)
	var entries: Array = []
	for kind: int in groups:
		var def: Dictionary = _defs[kind]
		var group: Dictionary = groups[kind]
		var count: int = group.ids.size()
		var entry := {kind = kind, count = count, bounds = AABB()}
		if def.has("trunk"):
			entry.tbuf = _buffer(count, 12)
		if def.has("crown"):
			entry.cbuf = _buffer(count, 16)
		for n in count:
			var o: int = group.ids[n]
			var ox := world.obj_x[o]
			var oy := world.obj_y[o]
			var v := world.obj_v[o]
			var s := world.obj_s[o] * (1.2 if kind == Biomes.T_ROCK else 1.0)
			var sy := s * (0.9 + (v % 3) * 0.08)
			var rot := WGRandom.hash2(floori(ox * 97), floori(oy * 89), 7) * TAU
			var pos := Vector3(ox * TILE, group.ground[n] - 0.1, oy * TILE)
			# Точный повёрнутый AABB вместо большой сферы вокруг всего вида.
			var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3(s, sy, s)), pos)
			var box: AABB = xf * def.box
			entry.bounds = box if n == 0 else entry.bounds.merge(box)
			if entry.has("tbuf"):
				_put_xform(entry.tbuf, n * 12, pos.x, pos.y, pos.z, rot, s, sy)
			if entry.has("cbuf"):
				var buf: PackedFloat32Array = entry.cbuf
				_put_xform(buf, n * 16, pos.x, pos.y, pos.z, rot, s, sy)
				var col: Color = def.leaves[v % def.leaves.size()]
				buf[n * 16 + 12] = col.r
				buf[n * 16 + 13] = col.g
				buf[n * 16 + 14] = col.b
				buf[n * 16 + 15] = 1.0
		entries.append(entry)
	return {chunk = chunk, entries = entries}


func _apply_chunk(built: Dictionary) -> void:
	var chunk: int = built.chunk
	if _loaded.has(chunk):
		return
	for entry: Dictionary in built.entries:
		var kind: int = entry.kind
		var def: Dictionary = _defs[kind]
		entry.nodes = []
		for part in ["trunk", "crown"]:
			if not def.has(part):
				continue
			var node := _multimesh(def[part], def[part + "_mat"], entry.count, part == "crown")
			var mm := node.multimesh
			mm.buffer = entry.tbuf if part == "trunk" else entry.cbuf
			mm.custom_aabb = entry.bounds
			mm.visible_instance_count = entry.count
			# Выбор LOD и видимость — по локальному чанку, а не всему лесу.
			node.visibility_range_end = GameConfig.TREE_R + world.CS * TILE * 0.7072
			node.visibility_range_end_margin = 16.0
			entry[part] = mm
			entry.nodes.append(node)
		veg[Vector2i(chunk, kind)] = entry
	_loaded[chunk] = true


func _apply_grass() -> void:
	grass.buffer = grass_buf
	grass.custom_aabb = _grass_bounds
	grass.visible_instance_count = _grass_n
	for entry: Dictionary in understory:
		entry.mm.buffer = entry.buf
		entry.mm.custom_aabb = AABB(entry.low, entry.high - entry.low) if entry.count > 0 else AABB()
		entry.mm.visible_instance_count = entry.count


static func _put_xform(buf: PackedFloat32Array, o: int, x: float, y: float, z: float, rot: float, s: float, sy: float) -> void:
	var c := cos(rot)
	var sn := sin(rot)
	buf[o] = c * s
	buf[o + 1] = 0.0
	buf[o + 2] = sn * s
	buf[o + 3] = x
	buf[o + 4] = 0.0
	buf[o + 5] = sy
	buf[o + 6] = 0.0
	buf[o + 7] = y
	buf[o + 8] = -sn * s
	buf[o + 9] = 0.0
	buf[o + 10] = c * s
	buf[o + 11] = z


func _fill_grass(px: float, pz: float) -> void:
	var w := world
	var rT := GameConfig.GRASS_R / TILE
	var tx := px / TILE
	var tz := pz / TILE
	var buf := grass_buf
	var n := 0
	var low := Vector3.INF
	var high := -Vector3.INF
	for entry: Dictionary in understory:
		entry.count = 0
		entry.low = Vector3.INF
		entry.high = -Vector3.INF
	for j in range(maxi(0, floori(tz - rT)), mini(w.H - 1, floori(tz + rT)) + 1):
		# Буфер полон: дальнейшие строки всё равно не смогут добавить экземпляры.
		if n >= GameConfig.GRASS_MAX:
			break
		for i in range(maxi(0, floori(tx - rT)), mini(w.W - 1, floori(tx + rT)) + 1):
			# Буфер полон: остальные клетки уже не поместятся
			if n >= GameConfig.GRASS_MAX:
				break
			var k := j * w.W + i
			var bd: Dictionary = Biomes.LIST[w.biome[k]]
			if not bd.has("grass") or w.river[k] != 0:
				continue
			if (i + 0.5 - tx) ** 2 + (j + 0.5 - tz) ** 2 > rT * rT:
				continue
			var gr: Dictionary = bd.grass
			# Почвенная влага и освещение общие с генератором леса.
			var lush := clampf(1.0 - 0.45 * (w.slope[k] - 0.5), 0.35, 1.0) * (1.25 if w.dist_water[k] < 3.0 else 1.0)
			var light := StageClimate.natural_conditions(w, i, j).x
			lush *= (0.45 + 0.75 * w.moist[k]) * (0.65 + 0.7 * light)
			var canopy := _forest_surface.get_pixel(i, j).r
			lush *= 1.0 - 0.65 * canopy
			_fill_understory(i, j, canopy, light, px, pz)
			var cnt := floori(gr.dens * (0.5 + WGRandom.hash2(i, j, 5)) * lush)
			var tc: Array = gr.tint
			for m in cnt:
				if n >= GameConfig.GRASS_MAX:
					break
				var x := (i + WGRandom.hash2(i * 7 + m, j, 11)) * TILE
				var z := (j + WGRandom.hash2(i, j * 7 + m, 13)) * TILE
				# Плавная, неодинаковая обочина вместо пустых квадратов клеточной маски.
				if heights.road_refinement != null:
					var weight := heights.road_refinement.weight_at(x, z, w.W)
					if weight > 0.0 and weight > WGRandom.hash2(i + m, j, 29) * 0.8 + 0.08:
						continue
				elif w.path_mask[k] >= 2:
					continue
				var y := heights.ground_at(x, z)
				if y < heights.water_level[k] and heights.depth_at(x, z) > 0.0:
					continue
				var s := 0.8 + WGRandom.hash2(i + m, j - m, 17) * 0.7
				var sy := s * (0.55 + WGRandom.hash2(i + m, j, 31) * 0.9)
				_put_xform(buf, n * 16, x, y - 0.05, z, WGRandom.hash2(i - m, j + m, 19) * 6.28, s, sy)
				var origin := Vector3(x, y - 0.05, z)
				low = low.min(origin)
				high = high.max(origin)
				var v := 1.0 + WGRandom.hash2(m, i + j, 23) * 0.3
				buf[n * 16 + 12] = tc[0] * v
				buf[n * 16 + 13] = tc[1] * v
				buf[n * 16 + 14] = tc[2] * v
				buf[n * 16 + 15] = 1.0
				n += 1
	_grass_n = n
	_grass_bounds = AABB(low, high - low).grow(_grass_margin) if n > 0 else AABB()
	_fill_tree_roots(px, pz)


func _fill_understory(i: int, j: int, canopy: float, sunlight: float, px: float, pz: float) -> void:
	var k := j * world.W + i
	var bi := world.biome[k]
	if bi not in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.SWAMP] and canopy < 0.15:
		return
	if world.path_mask[k] > 0 or world.slope[k] > 0.9:
		return
	var surface := _forest_surface.get_pixel(i, j)
	var moisture := surface.b
	var light := sunlight * (1.0 - canopy * 0.85)
	var weights := Understory.weights(bi, moisture, light, canopy)
	weights.append_array(Floor.weights(canopy, surface.g, moisture, light, surface.a))
	var total := 0.0
	for weight in weights:
		total += weight
	# Пятна по 12 м и случайные пропуски; соседние клетки связаны без нового шума.
	var seed := world.seed_num ^ 6601
	var patch := WGRandom.hash2(floori(i / 3.0), floori(j / 3.0), seed)
	var density := (0.25 + 0.7 * patch) * (0.5 + 0.5 * moisture)
	for m in 4:
		if WGRandom.hash2(i * 4 + m, j, seed + 1) > density:
			continue
		var pick := WGRandom.hash2(i * 4 + m, j, seed + 2) * total
		var kind := 0
		while kind < weights.size() - 1 and pick >= weights[kind]:
			pick -= weights[kind]
			kind += 1
		var x := (i + 0.1 + 0.8 * WGRandom.hash2(i * 4 + m, j, seed + 3)) * TILE
		var z := (j + 0.1 + 0.8 * WGRandom.hash2(i * 4 + m, j, seed + 4)) * TILE
		if Vector2(x - px, z - pz).length_squared() > GameConfig.GRASS_R ** 2:
			continue
		var scale := 0.7 + WGRandom.hash2(i * 4 + m, j, seed + 5) * 0.6
		var rot := WGRandom.hash2(i * 4 + m, j, seed + 6) * TAU
		var tint := 0.85 + WGRandom.hash2(i * 4 + m, j, seed + 7) * 0.3
		_put_understory(kind, x, z, rot, scale, tint)


func _put_understory(kind: int, x: float, z: float, rot: float, scale: float, tint: float = 1.0) -> void:
	var entry: Dictionary = understory[kind]
	if entry.count >= UNDERSTORY_MAX:
		return
	var floor_kind := kind - Floor.FIRST
	var local_box: AABB = entry.box
	var radius := 0.0
	if floor_kind >= 0:
		var reach := local_box.position.abs().max(local_box.end.abs()) * scale
		radius = Vector2(reach.x, reach.z).length()
	if not _floor_clear(x, z, radius):
		return
	if floor_kind in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG] and not _trunks_clear(x, z, rot, scale, local_box, radius):
		return
	var pos := Vector3(x, heights.ground_at(x, z) - 0.015, z)
	var offset: int = entry.count * 16
	var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * scale), pos)
	_put_xform(entry.buf, offset, x, pos.y, z, rot, scale, scale)
	if kind == Understory.MOSS or (floor_kind >= 0 and floor_kind != Floor.SNAG):
		# Почвенные детали и валежник следуют склону; сухостой остаётся вертикальным.
		var dx := heights.ground_at(x + 0.3, z) - heights.ground_at(x - 0.3, z)
		var dz := heights.ground_at(x, z + 0.3) - heights.ground_at(x, z - 0.3)
		xf.basis.x.y = (dx * xf.basis.x.x + dz * xf.basis.x.z) / 0.6
		xf.basis.z.y = (dx * xf.basis.z.x + dz * xf.basis.z.z) / 0.6
		entry.buf[offset + 4] = xf.basis.x.y
		entry.buf[offset + 6] = xf.basis.z.y
	for c in 3:
		entry.buf[offset + 12 + c] = tint
	entry.buf[offset + 15] = 1.0
	var box: AABB = xf * local_box
	entry.low = entry.low.min(box.position)
	entry.high = entry.high.max(box.end)
	entry.count += 1


func _trunks_clear(x: float, z: float, rot: float, scale: float, box: AABB, radius: float) -> bool:
	var footprint := Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z)).grow(0.3 / scale)
	for cy in range(maxi(0, floori((z - radius - 1.0) / (world.CS * TILE))), mini(world.CH, ceili((z + radius + 1.0) / (world.CS * TILE)))):
		for cx in range(maxi(0, floori((x - radius - 1.0) / (world.CS * TILE))), mini(world.CW, ceili((x + radius + 1.0) / (world.CS * TILE)))):
			for o in world.chunks[cy * world.CW + cx]:
				if not Biomes.is_tree(world.obj_k[o]):
					continue
				var dx := world.obj_x[o] * TILE - x
				var dz := world.obj_y[o] * TILE - z
				var local := Vector2(cos(rot) * dx - sin(rot) * dz, sin(rot) * dx + cos(rot) * dz) / scale
				if footprint.has_point(local):
					return false
	return true


## Проверяем весь след крупных деталей, а не только центр бревна у дороги/воды.
func _floor_clear(x: float, z: float, radius: float) -> bool:
	if StageVegetation.near_hut(world.settlements, x / TILE, z / TILE, radius / TILE + 0.3):
		return false
	var steps := ceili(radius * 2.0)
	for j in steps + 1:
		for i in steps + 1:
			var px := x + lerpf(-radius, radius, float(i) / maxi(1, steps))
			var pz := z + lerpf(-radius, radius, float(j) / maxi(1, steps))
			var cx := floori(px / TILE)
			var cy := floori(pz / TILE)
			if cx < 0 or cy < 0 or cx >= world.W or cy >= world.H:
				return false
			var k := cy * world.W + cx
			if world.path_mask[k] > 0 or world.river[k] != 0:
				return false
			if heights.road_refinement != null and heights.road_refinement.weight_at(px, pz, world.W) > 0.08:
				return false
			if heights.ground_at(px, pz) < heights.water_level[k] and heights.depth_at(px, pz) > 0.0:
				return false
	return true


func _fill_tree_roots(px: float, pz: float) -> void:
	var r := GameConfig.GRASS_R / TILE
	for cy in range(maxi(0, floori((pz / TILE - r) / world.CS)), mini(world.CH, ceili((pz / TILE + r) / world.CS))):
		for cx in range(maxi(0, floori((px / TILE - r) / world.CS)), mini(world.CW, ceili((px / TILE + r) / world.CS))):
			for o in world.chunks[cy * world.CW + cx]:
				if not Biomes.is_tree(world.obj_k[o]) or world.obj_s[o] < 0.85:
					continue
				var x := world.obj_x[o] * TILE
				var z := world.obj_y[o] * TILE
				if Vector2(x - px, z - pz).length_squared() > GameConfig.GRASS_R ** 2:
					continue
				var k := floori(z / TILE) * world.W + floori(x / TILE)
				if world.slope[k] > 0.9:
					continue
				var rot := WGRandom.hash2(floori(x * 97.0), floori(z * 89.0), 6677) * TAU
				_put_understory(Floor.FIRST + Floor.ROOTS, x, z, rot, clampf(world.obj_s[o] * 0.7, 0.6, 1.3))
