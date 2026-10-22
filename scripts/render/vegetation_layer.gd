class_name VegetationLayer
extends Node3D
## Неподвижные MultiMesh по чанкам, видам и силуэтам, Mesh LOD и точные AABB.
## 6.6+: подлесок и лесная поверхность обновляются вместе с травой в фоне.
## Главный поток передаёт один чанк за кадр.
## С 8.4 чанки — Vector2i(cx, cy) в общих координатах: за краем стартовой области их объекты считает
## OuterLand.vegetation тем же кодом, что и на карте (трава и подлесок пока только на карте).

const TILE := GameConfig.TILE
const WATER_MARGIN := 0.3
const LOAD_RADIUS := GameConfig.TREE_R + 64.0 # запас на фоновую подготовку при движении
const DROP_RADIUS := LOAD_RADIUS + 96.0     # гистерезис: не пересоздаём чанк на границе
const RECHECK := 24.0
const Understory := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const Placement := preload("res://scripts/render/vegetation_placement.gd")
const UNDERSTORY_MAX := 2048 # на форму мелкого подлеска, только в радиусе травы
## С 9.8+ крупный подлесок (кусты, подрост, молодые деревья, валежник, сухостой, камни) виден дальше травы:
## с 9.4 он гуще и на границе GRASS_R (52 м) вырастал прямо перед игроком. Мелкие растения — как прежде.
const UNDERSTORY_FAR_R := 140.0
const UNDERSTORY_FAR_MAX := 12288 # на форму крупного подлеска: площадь круга в 7 раз больше
const OBSTACLE_R := GameConfig.GRASS_R + 16.0 # столкновения нужны только рядом с игроком
const SHADER := preload("res://resources/vegetation.gdshader")
const CUTOUT_SHADER := preload("res://resources/vegetation_cutout.gdshader")
const TRUNK_SHADER := preload("res://resources/vegetation_trunk.gdshader")
# [sway, flutter, sway_speed, ao, glow]; см. _wind_mat
const CALM := [0.0, 0.0, 1.0, 1.0, 0.0]
const WIND := {
	Biomes.T_OAK: [0.14, 0.035, 0.8, 0.72, 0.32],
	Biomes.T_BIRCH: [0.22, 0.06, 1.0, 0.8, 0.42],
	Biomes.T_PINE: [0.1, 0.012, 0.65, 0.7, 0.15],
	Biomes.T_SNOWPINE: [0.07, 0.008, 0.6, 0.62, 0.08],
	Biomes.T_PALM: [0.3, 0.08, 0.7, 0.8, 0.35],
	Biomes.T_JUNGLE: [0.1, 0.03, 0.6, 0.65, 0.25],
	Biomes.T_ACACIA: [0.1, 0.03, 0.7, 0.7, 0.25],
	Biomes.T_BUSH: [0.06, 0.035, 1.3, 0.75, 0.3],
	Biomes.T_REED: [0.16, 0.03, 1.4, 0.8, 0.3],
	Biomes.T_DEAD: [0.04, 0.0, 0.8, 0.8, 0.0],
}
const GRASS_WIND := [0.09, 0.02, 1.6, 0.85, 0.3]
const PLANT_WIND := [0.05, 0.02, 1.2, 0.85, 0.25]

var world: WorldData
var heights: Heightfield
var veg := {} # Vector3i(cx, cy, вид) -> буферы, MultiMesh и узлы
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
var _grass_box := AABB()
var understory: Array = [] # те же фоновые буферы и цикл обновления, что у травы
var _forest_surface: Image
var placement: Placement
var _understory_sites: Array = []
var obstacles := PackedFloat32Array() # 7.7: валежник и сухостой рядом с игроком для ForestObstacles (тот же формат)
var obstacles_version := 0            # растёт с каждой новой раскладкой подлеска
var _obstacles_next := PackedFloat32Array() # пишет фоновая задача
var _fill_at := Vector2.ZERO # центр последней раскладки травы и подлеска, м (фоновая задача)


func setup(w: WorldData, h: Heightfield, defs: Dictionary, grass_mesh: Mesh, forest: Image = null) -> void:
	world = w
	heights = h
	placement = Placement.new(w, h)
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
			var shader := TRUNK_SHADER if part == "trunk" else (CUTOUT_SHADER if def.get("cutout", false) else SHADER)
			var mat := _wind_mat(shader, WIND.get(kind % ForestModels.MODEL_STRIDE, CALM), part == "crown")
			if def.has(part + "_texture"):
				mat.set_shader_parameter("albedo_tex", def[part + "_texture"])
			if part == "trunk":
				mat.set_shader_parameter("use_vertex_color", def.get("colored_bark", false))
				mat.set_shader_parameter("albedo_color", def.bark)
			entry[part + "_mat"] = mat
		# Высота у кроны и ствола общая, иначе листва отрывается от веток.
		for part in ["trunk", "crown"]:
			if entry.has(part + "_mat"):
				entry[part + "_mat"].set_shader_parameter("height", maxf(entry.box.end.y, 0.3))
		_defs[kind] = entry
	var grass_mat := _wind_mat(SHADER, GRASS_WIND, true)
	grass_mat.set_shader_parameter("height", grass_mesh.get_aabb().end.y)
	grass = _multimesh(grass_mesh, grass_mat, GameConfig.GRASS_MAX, true, false).multimesh
	_grass_margin = _radius(grass_mesh) * 1.5
	_grass_box = grass_mesh.get_aabb()
	grass_buf = _buffer(GameConfig.GRASS_MAX, 16)
	var meshes := Understory.meshes()
	meshes.append_array(Floor.meshes())
	for mesh in meshes:
		var kind := understory.size() - Floor.FIRST
		var shadows := kind in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STUMP, Floor.BOULDER] or understory.size() in [Understory.YOUNG, Understory.YOUNG_PINE]
		# Мох, подстилка, валежник и камни неподвижны.
		var still := kind >= 0 or understory.size() == Understory.MOSS
		var mat := _wind_mat(SHADER, CALM if still else PLANT_WIND, true)
		mat.set_shader_parameter("height", maxf(mesh.get_aabb().end.y, 0.2))
		var far := Placement.priority(understory.size()) < 2
		var cap := UNDERSTORY_FAR_MAX if far else UNDERSTORY_MAX
		var node := _multimesh(mesh, mat, cap, true, shadows)
		node.visibility_range_end = UNDERSTORY_FAR_R if far else GameConfig.GRASS_R
		node.visibility_range_end_margin = 8.0
		understory.append({mm = node.multimesh, buf = _buffer(cap, 16), count = 0, cap = cap, far = far,
			low = Vector3.INF, high = -Vector3.INF, box = mesh.get_aabb()})


## 6.7: ветер и свет по виду. sway/flutter — м, ao — свет неба у основания и в глубине кроны,
## glow — просвечивание листвы. Хвоя жёсткая и густая, берёза лёгкая и дрожит, пальма гибкая.
static func _wind_mat(shader: Shader, wind: Array, leaves: bool) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("sway", wind[0])
	mat.set_shader_parameter("flutter", wind[1] if leaves else 0.0)
	mat.set_shader_parameter("sway_speed", wind[2])
	mat.set_shader_parameter("ao_low", wind[3])
	mat.set_shader_parameter("translucency", wind[4] if leaves else 0.0)
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
		# С 9.8+ раскладка травы и подлеска дольше: готовые чанки деревьев не ждут её конца.
		if not _pending.is_empty():
			_apply_chunk(_pending.pop_back())
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
			var none: Array[Vector2i] = []
			_task = WorkerThreadPool.add_task(_fill.bind(px, pz, none), true, "Трава")
			return false
		_apply_chunk(_pending.pop_back())
		return true
	if not force and last_fill != Vector2.INF and p.distance_to(last_fill) < 8.0:
		return false
	# с 9.0 фон строит сначала чанки по ходу движения (направление — от прошлой раскладки)
	var ahead := p if force or last_fill == Vector2.INF else p + (p - last_fill).normalized() * LOAD_RADIUS * 0.5
	last_fill = p
	var missing := _wanted(p, ahead)
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


func _distance(chunk: Vector2i, p: Vector2) -> float:
	var side := world.CS * TILE
	var corner := Vector2(chunk) * side
	return p.distance_to(p.clamp(corner, corner + Vector2.ONE * side))


func _on_map(chunk: Vector2i) -> bool:
	return chunk.x >= 0 and chunk.y >= 0 and chunk.x < world.CW and chunk.y < world.CH


func _wanted(p: Vector2, ahead: Vector2 = p) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var side := world.CS * TILE
	var x0 := floori((p.x - LOAD_RADIUS) / side)
	var x1 := floori((p.x + LOAD_RADIUS) / side)
	var y0 := floori((p.y - LOAD_RADIUS) / side)
	var y1 := floori((p.y + LOAD_RADIUS) / side)
	if world.outer == null: # без местности за краем — только чанки карты
		x0 = maxi(0, x0)
		y0 = maxi(0, y0)
		x1 = mini(world.CW - 1, x1)
		y1 = mini(world.CH - 1, y1)
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var c := Vector2i(cx, cy)
			if not _loaded.has(c) and _distance(c, p) <= LOAD_RADIUS:
				out.append(c)
	# Фон строит список от дальних к ближним; главный поток берёт с конца.
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _distance(a, p) + _distance(a, ahead) > _distance(b, p) + _distance(b, ahead))
	return out


func _drop(p: Vector2) -> void:
	for key: Vector3i in veg.keys():
		if _distance(Vector2i(key.x, key.y), p) > DROP_RADIUS:
			for node: MultiMeshInstance3D in veg[key].nodes:
				node.visible = false
				node.queue_free()
			veg.erase(key)
	for chunk: Vector2i in _loaded.keys():
		if _distance(chunk, p) > DROP_RADIUS:
			_loaded.erase(chunk)
			if world.outer != null:
				world.outer.veg.erase(chunk)


func _fill(px: float, pz: float, missing: Array[Vector2i]) -> void:
	_built = []
	for chunk in missing:
		_built.append(_build_chunk(chunk) if _on_map(chunk) else _build_outer(chunk))
	_fill_grass(px, pz)


## Чанк за краем стартовой области (в фоновой задаче): объекты OuterLand.vegetation, земля под ними — той же
## триангуляцией, что у меша OuterTerrain (клетки карты у края — из Heightfield.hv, остальные — из куска).
## Карта OuterLand.chunks здесь не читается: она главного потока.
func _build_outer(chunk: Vector2i) -> Dictionary:
	var f := OuterLand.vegetation(world, chunk)
	var fx: PackedFloat64Array = f.x
	var fy: PackedFloat64Array = f.y
	var fk: PackedInt32Array = f.k
	var fh: PackedFloat32Array = f.h
	var side: int = f.side
	var hx0: int = f.x0
	var hy0: int = f.y0
	var hv := heights.hv
	var W := world.W
	var H := world.H
	var items := {x = PackedFloat64Array(), y = PackedFloat64Array(), k = PackedInt32Array(), v = PackedInt32Array(),
		s = PackedFloat64Array(), ground = PackedFloat32Array()}
	var corner := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for o in fx.size():
		var kind := fk[o]
		if not _defs.has(kind):
			continue
		var gx := fx[o] - 0.5
		var gz := fy[o] - 0.5
		var i := floori(gx)
		var j := floori(gz)
		for c in 4:
			var ci := i + (c & 1)
			var cj := j + (c >> 1)
			if ci >= 0 and cj >= 0 and ci < W and cj < H:
				corner[c] = hv[cj * W + ci]
			else:
				corner[c] = Heightfield.outer_meters(fh[(cj - hy0) * side + ci - hx0])
		var tx := gx - i
		var tz := gz - j
		var ground: float
		if tx + tz <= 1.0:
			ground = corner[0] + (corner[1] - corner[0]) * tx + (corner[2] - corner[0]) * tz
		else:
			ground = corner[3] + (corner[2] - corner[3]) * (1.0 - tx) + (corner[1] - corner[3]) * (1.0 - tz)
		# за краем вода только морская, её уровень 0
		if kind != Biomes.T_REED and kind != Biomes.T_ROCK and ground < -WATER_MARGIN:
			continue
		items.x.append(fx[o])
		items.y.append(fy[o])
		items.k.append(kind)
		items.v.append(f.v[o])
		items.s.append(f.s[o])
		items.ground.append(ground)
	var built := _build_entries(items)
	built.chunk = chunk
	built.outer = items
	return built


func _build_chunk(chunk: Vector2i) -> Dictionary:
	var items := {x = PackedFloat64Array(), y = PackedFloat64Array(), k = PackedInt32Array(), v = PackedInt32Array(),
		s = PackedFloat64Array(), ground = PackedFloat32Array()}
	for o in world.chunks[chunk.y * world.CW + chunk.x]:
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
		if kind != Biomes.T_REED and kind != Biomes.T_ROCK:
			if heights.depth_at(x, z) > WATER_MARGIN:
				continue
		items.x.append(ox)
		items.y.append(oy)
		items.k.append(kind)
		items.v.append(world.obj_v[o])
		items.s.append(world.obj_s[o])
		items.ground.append(heights.ground_at(x, z))
	var built := _build_entries(items)
	built.chunk = chunk
	return built


## Буферы MultiMesh по силуэтам для объектов items (столбцы x, y в клетках, k, v, s, ground — земля, м)
func _build_entries(items: Dictionary) -> Dictionary:
	var groups := {}
	var xs: PackedFloat64Array = items.x
	var ys: PackedFloat64Array = items.y
	for o in xs.size():
		var kind: int = items.k[o]
		var ox := xs[o]
		var oy := ys[o]
		var ground: float = items.ground[o]
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
			var ox := xs[o]
			var oy := ys[o]
			var v: int = items.v[o]
			var s: float = items.s[o] * (1.2 if kind % ForestModels.MODEL_STRIDE == Biomes.T_ROCK else 1.0)
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
	return {entries = entries}


func _apply_chunk(built: Dictionary) -> void:
	var chunk: Vector2i = built.chunk
	if _loaded.has(chunk):
		return
	if built.has("outer"):
		world.outer.veg[chunk] = built.outer
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
		veg[Vector3i(chunk.x, chunk.y, kind)] = entry
	_loaded[chunk] = true


func _apply_grass() -> void:
	obstacles = _obstacles_next
	obstacles_version += 1
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
	var rF := UNDERSTORY_FAR_R / TILE
	var tx := px / TILE
	var tz := pz / TILE
	var buf := grass_buf
	var n := 0
	var low := Vector3.INF
	var high := -Vector3.INF
	_fill_at = Vector2(px, pz)
	placement.clear_occupied()
	_obstacles_next = PackedFloat32Array()
	placement.prepare(px, pz, UNDERSTORY_FAR_R + 12.0)
	_understory_sites.clear()
	for entry: Dictionary in understory:
		entry.count = 0
		entry.low = Vector3.INF
		entry.high = -Vector3.INF
	# Без раннего выхода по полному буферу травы: подлесок дальних рядов собирается всегда.
	for j in range(maxi(0, floori(tz - rF)), mini(w.H - 1, floori(tz + rF)) + 1):
		for i in range(maxi(0, floori(tx - rF)), mini(w.W - 1, floori(tx + rF)) + 1):
			var k := j * w.W + i
			var bd: Dictionary = Biomes.LIST[w.biome[k]]
			if not bd.has("grass") or w.river[k] != 0:
				continue
			var d2 := (i + 0.5 - tx) ** 2 + (j + 0.5 - tz) ** 2
			if d2 > rF * rF:
				continue
			if d2 > rT * rT:
				# За кругом травы — только крупный подлесок
				_fill_understory(i, j, _forest_surface.get_pixel(i, j), StageClimate.natural_conditions(w, i, j).x, px, pz)
				continue
			var gr: Dictionary = bd.grass
			# Почвенная влага и освещение общие с генератором леса.
			var lush := clampf(1.0 - 0.45 * (w.slope[k] - 0.5), 0.35, 1.0) * (1.25 if w.dist_water[k] < 3.0 else 1.0)
			var light := StageClimate.natural_conditions(w, i, j).x
			lush *= (0.45 + 0.75 * w.moist[k]) * (0.65 + 0.7 * light)
			var surface := _forest_surface.get_pixel(i, j)
			lush *= 1.0 - 0.65 * surface.r
			lush *= _fill_understory(i, j, surface, light, px, pz)
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
				if heights.depth_at(x, z) > 0.0:
					continue
				var s := 0.8 + WGRandom.hash2(i + m, j - m, 17) * 0.7
				var sy := s * (0.55 + WGRandom.hash2(i + m, j, 31) * 0.9)
				_put_xform(buf, n * 16, x, y - 0.05, z, WGRandom.hash2(i - m, j + m, 19) * 6.28, s, sy)
				var origin := Vector3(x, y - 0.05, z)
				low = low.min(origin)
				high = high.max(origin)
				var v := 1.25 + WGRandom.hash2(m, i + j, 23) * 0.3 # 9.4: светлее, основание темнит меш
				buf[n * 16 + 12] = tc[0] * v
				buf[n * 16 + 13] = tc[1] * v
				buf[n * 16 + 14] = tc[2] * v
				buf[n * 16 + 15] = 1.0 - surface.r # открытость неба: свет и ветер под пологом
				n += 1
	_grass_n = n
	_grass_bounds = AABB(low, high - low).grow(_grass_margin) if n > 0 else AABB()
	for priority in 3:
		for site: Array in _understory_sites:
			if Placement.priority(site[0]) == priority:
				_put_understory(site[0], site[1], site[2], site[3], site[4], site[5])
	_fill_tree_roots(px, pz)
	_filter_grass()
	_understory_sites.clear()


## Возвращает множитель низкой травы по характеру леса (вне леса 1).
func _fill_understory(i: int, j: int, surface: Color, sunlight: float, px: float, pz: float) -> float:
	var k := j * world.W + i
	var bi := world.biome[k]
	var canopy := surface.r
	if bi not in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.SWAMP] and canopy < 0.15:
		return 1.0
	var moisture := surface.b
	# 8.2: характер леса от полога, хвои, влаги, солнца и возраста участка
	var ch := Understory.character(canopy, surface.g, moisture, sunlight, StageVegetation.age_at(world, i, j))
	var grass_mul := Understory.mix(Understory.LOW_GRASS, ch)
	if world.path_mask[k] > 0 or world.slope[k] > 0.9:
		return grass_mul
	var light := sunlight * (1.0 - canopy * 0.85)
	var weights := Understory.weights(bi, moisture, light, canopy, ch)
	var floor_weights := Floor.weights(canopy, surface.g, moisture, light, surface.a)
	var deadwood := Understory.mix(Understory.DEADWOOD, ch)
	for f in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STUMP]:
		floor_weights[f] *= deadwood
	weights.append_array(floor_weights)
	var total := 0.0
	for weight in weights:
		total += weight
	# Пятна по 12 м и случайные пропуски; соседние клетки связаны без нового шума.
	var seed := world.seed_num ^ 6601
	var patch := WGRandom.hash2(floori(i / 3.0), floori(j / 3.0), seed)
	var density := (0.3 + 0.75 * patch) * (0.5 + 0.5 * moisture) * Understory.mix(Understory.DENSITY, ch) # 9.4: гуще
	# В чаще мест больше: кусты и подрост стоят стеной.
	for m in 5 + roundi(3.0 * ch[Understory.THICKET]):
		if WGRandom.hash2(i * 8 + m, j, seed + 1) > density:
			continue
		var pick := WGRandom.hash2(i * 8 + m, j, seed + 2) * total
		var kind := 0
		while kind < weights.size() - 1 and pick >= weights[kind]:
			pick -= weights[kind]
			kind += 1
		var x := (i + 0.1 + 0.8 * WGRandom.hash2(i * 8 + m, j, seed + 3)) * TILE
		var z := (j + 0.1 + 0.8 * WGRandom.hash2(i * 8 + m, j, seed + 4)) * TILE
		var reach := UNDERSTORY_FAR_R if understory[kind].far else GameConfig.GRASS_R
		if Vector2(x - px, z - pz).length_squared() > reach * reach:
			continue
		var scale := 0.7 + WGRandom.hash2(i * 8 + m, j, seed + 5) * 0.6
		var rot := WGRandom.hash2(i * 8 + m, j, seed + 6) * TAU
		var tint := 0.85 + WGRandom.hash2(i * 8 + m, j, seed + 7) * 0.3
		_understory_sites.append([kind, x, z, rot, scale, tint])
	return grass_mul


func _put_understory(kind: int, x: float, z: float, rot: float, scale: float, tint: float = 1.0, owner: int = -1) -> void:
	var entry: Dictionary = understory[kind]
	if entry.count >= entry.cap:
		return
	var floor_kind := kind - Floor.FIRST
	var local_box: AABB = entry.box
	var reach := local_box.position.abs().max(local_box.end.abs()) * scale
	var radius := Vector2(reach.x, reach.z).length()
	if not placement.ground_clear(x, z, radius):
		return
	if not placement.objects_clear(x, z, rot, scale, local_box, radius, owner):
		return
	var pos := Vector3(x, heights.ground_at(x, z) - 0.015, z)
	var offset: int = entry.count * 16
	var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * scale), pos)
	if kind == Understory.MOSS or (floor_kind >= 0 and floor_kind not in [Floor.SNAG, Floor.STUMP, Floor.BOULDER]):
		# Почвенные детали и валежник следуют склону; сухостой, пни и валуны остаются вертикальными.
		var dx := heights.ground_at(x + 0.3, z) - heights.ground_at(x - 0.3, z)
		var dz := heights.ground_at(x, z + 0.3) - heights.ground_at(x, z - 0.3)
		xf.basis.x.y = (dx * xf.basis.x.x + dz * xf.basis.x.z) / 0.6
		xf.basis.z.y = (dx * xf.basis.z.x + dz * xf.basis.z.z) / 0.6
		if not placement.terrain_fits(xf, local_box):
			return
	var box: AABB = xf * local_box
	if not placement.details_clear(box):
		return
	_put_xform(entry.buf, offset, x, pos.y, z, rot, scale, scale)
	entry.buf[offset + 4] = xf.basis.x.y
	entry.buf[offset + 6] = xf.basis.z.y
	for c in 3:
		entry.buf[offset + 12 + c] = tint
	entry.buf[offset + 15] = 1.0 - _forest_surface.get_pixel(floori(x / TILE), floori(z / TILE)).r
	entry.low = entry.low.min(box.position)
	entry.high = entry.high.max(box.end)
	entry.count += 1
	if Placement.priority(kind) < 2:
		placement.occupy(box.grow(0.03))
	if Vector2(x, z).distance_squared_to(_fill_at) > OBSTACLE_R * OBSTACLE_R:
		return
	if floor_kind == Floor.LOG or floor_kind == Floor.MOSS_LOG:
		# бревно — капсула вдоль ствола (меш: от -2,2 до 2,1 м по X, толщина 0,23 м), верх ~0,45 м
		var a := xf * Vector3(-2.2, 0.0, 0.0)
		var b := xf * Vector3(2.1, 0.0, 0.07)
		_obstacles_next.append_array([a.x, a.z, b.x, b.z, 0.2 * scale, pos.y, pos.y + 0.42 * scale])
	elif floor_kind == Floor.SNAG:
		_obstacles_next.append_array([x, z, x, z, 0.16 * scale, pos.y, INF])
	elif floor_kind == Floor.STUMP: # невысокий, перепрыгивается
		_obstacles_next.append_array([x, z, x, z, 0.3 * scale, pos.y, pos.y + 0.45 * scale])
	elif floor_kind == Floor.BOULDER:
		_obstacles_next.append_array([x, z, x, z, 0.75 * scale, pos.y, pos.y + 0.95 * scale])


func _filter_grass() -> void:
	var write := 0
	for n in _grass_n:
		var offset := n * 16
		var pos := Vector3(grass_buf[offset + 3], grass_buf[offset + 7], grass_buf[offset + 11])
		var xf := Transform3D(Basis(Vector3(grass_buf[offset], 0, grass_buf[offset + 8]), Vector3(0, grass_buf[offset + 5], 0), Vector3(grass_buf[offset + 2], 0, grass_buf[offset + 10])), pos)
		var box: AABB = xf * _grass_box
		if not placement.details_clear(box):
			continue
		var local_box := AABB(box.position - pos, box.size)
		var reach := local_box.position.abs().max(local_box.end.abs())
		if not placement.objects_clear(pos.x, pos.z, 0.0, 1.0, local_box, Vector2(reach.x, reach.z).length()):
			continue
		if write != n:
			for c in 16:
				grass_buf[write * 16 + c] = grass_buf[offset + c]
		write += 1
	_grass_n = write


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
				_put_understory(Floor.FIRST + Floor.ROOTS, x, z, rot, clampf(world.obj_s[o] * 0.7, 0.6, 1.3), 1.0, o)
