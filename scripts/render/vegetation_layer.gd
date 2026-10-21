class_name VegetationLayer
extends Node3D
## 6.4: неподвижные MultiMesh по чанкам и видам, штатный Mesh LOD и отсечение по AABB.
## Фон готовит только новые чанки и траву. Главный поток передаёт один чанк за кадр.

const TILE := GameConfig.TILE
const WATER_MARGIN := 0.3
const LOAD_RADIUS := GameConfig.TREE_R + 64.0 # запас на фоновую подготовку при движении
const DROP_RADIUS := LOAD_RADIUS + 96.0     # гистерезис: не пересоздаём чанк на границе
const RECHECK := 24.0

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


func setup(w: WorldData, h: Heightfield, defs: Dictionary, grass_mesh: Mesh) -> void:
	world = w
	heights = h
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
			if part == "trunk":
				mat.vertex_color_use_as_albedo = false
				mat.albedo_color = def.bark
			entry[part + "_mat"] = mat
		_defs[kind] = entry
	grass = _multimesh(grass_mesh, _vcolor_mat(true), GameConfig.GRASS_MAX, true, false).multimesh
	_grass_margin = _radius(grass_mesh) * 1.5
	grass_buf = _buffer(GameConfig.GRASS_MAX, 16)


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
		if not groups.has(kind):
			groups[kind] = {ids = [], ground = []}
		groups[kind].ids.append(o)
		groups[kind].ground.append(ground)
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
			lush *= 1.0 - 0.65 * StageVegetation.canopy_at(w, i + 0.5, j + 0.5)
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
				_put_xform(buf, n * 16, x, y - 0.05, z, WGRandom.hash2(i - m, j + m, 19) * 6.28, s, s)
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
