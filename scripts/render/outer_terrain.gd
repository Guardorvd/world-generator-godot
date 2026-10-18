class_name OuterTerrain
extends Node3D
## Рельеф за краем стартовой области (с 1.9.5): куски OuterLand вокруг игрока. Кусок считается и
## собирается в меш в задаче WorkerThreadPool, ближние первыми, а в дерево сцены и в OuterLand.chunks
## попадает в главном потоке. Дальние куски выгружаются. Меш раскрашен цветами биомов по вершинам
## (у стартовой области — запечённая текстура) и примыкает к её краю без щели: клетки карты на границе
## берутся из Heightfield.

const TILE := GameConfig.TILE
const HS := GameConfig.HS
const OCEAN_DEPTH := GameConfig.OCEAN_DEPTH
const C := OuterLand.C
const RADIUS := 1200.0   # куски ближе этого держатся загруженными (дальше всё равно туман)
const DROP := 1600.0     # куски дальше этого выгружаются
const TASKS := 3         # сколько кусков считается одновременно
const RECHECK := 32.0    # через сколько метров пути заново решать, какие куски нужны

var world: WorldData
var heights: Heightfield
var land: OuterLand
var _mat: ShaderMaterial
var _nodes := {}         # номер куска -> MeshInstance3D (или null, если в куске нечего рисовать)
var _tasks := {}         # номер куска -> {id, out}
var _queue: Array[Vector2i] = []   # нужные куски, которых ещё нет, ближние в конце
var _checked_at := Vector2.INF


func setup(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h
	land = w.outer
	_mat = TerrainBuilder.outer_material()


## Сразу загрузить все куски в радиусе radius (при старте игры), чтобы ближний рельеф не вырастал на глазах
func preload_around(x: float, z: float, radius: float = RADIUS) -> void:
	var keys: Array[Vector2i] = []
	for key: Vector2i in _wanted(x, z, radius):
		if not _nodes.has(key) and not _tasks.has(key):
			keys.append(key)
	if keys.is_empty():
		_checked_at = Vector2.INF
		return # группу задач без элементов не создаём
	var outs: Array = []
	outs.resize(keys.size())
	var lock := Mutex.new()
	var task := func(k: int) -> void:
		var r := _build(keys[k])
		lock.lock()
		outs[k] = r
		lock.unlock()
	var id := WorkerThreadPool.add_group_task(task, keys.size(), -1, true)
	WorkerThreadPool.wait_for_group_task_completion(id)
	for k in keys.size():
		_add(keys[k], outs[k])
	_checked_at = Vector2.INF # дальние куски догрузит update


## Каждый кадр: забрать готовые куски, выгрузить дальние, запустить расчёт ближайших недостающих
func update(x: float, z: float) -> void:
	for key: Vector2i in _tasks.keys():
		var t: Dictionary = _tasks[key]
		if WorkerThreadPool.is_task_completed(t.id):
			WorkerThreadPool.wait_for_task_completion(t.id)
			_tasks.erase(key)
			_add(key, t.out.r)
	if Vector2(x, z).distance_to(_checked_at) > RECHECK:
		_checked_at = Vector2(x, z)
		for key: Vector2i in _nodes.keys():
			if _center(key).distance_to(Vector2(x, z)) > DROP:
				if _nodes[key] != null:
					_nodes[key].queue_free()
				_nodes.erase(key)
				land.chunks.erase(key)
		_queue.clear()
		for key: Vector2i in _wanted(x, z):
			if not _nodes.has(key) and not _tasks.has(key):
				_queue.append(key)
		_queue.reverse()
	while _tasks.size() < TASKS and not _queue.is_empty():
		var key: Vector2i = _queue.pop_back()
		if _nodes.has(key):
			continue # уже загружен сразу (preload_around)
		var out := {}
		# низкий приоритет: растительность и кадр важнее дальнего рельефа
		var id := WorkerThreadPool.add_task(func() -> void: out.r = _build(key), false)
		_tasks[key] = {id = id, out = out}


## Дождаться запущенных задач (перед выгрузкой мира)
func finish() -> void:
	for key: Vector2i in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[key].id)
	_tasks.clear()


func _exit_tree() -> void:
	finish()


## Куски, которые задевает круг radius вокруг (x, z), без лежащих целиком на карте; ближние первыми
func _wanted(x: float, z: float, radius: float = RADIUS) -> Array[Vector2i]:
	var side := C * TILE
	var r := ceili(radius / side)
	var ck := Vector2i(floori(x / side), floori(z / side))
	var out: Array[Vector2i] = []
	var dist := {}
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var key := ck + Vector2i(dx, dy)
			if _on_map(key):
				continue
			# расстояние до ближайшей точки куска
			var px := clampf(x, key.x * side, (key.x + 1) * side)
			var pz := clampf(z, key.y * side, (key.y + 1) * side)
			var d := Vector2(px - x, pz - z).length()
			if d <= radius:
				out.append(key)
				dist[key] = d
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return dist[a] < dist[b])
	return out


## Все клетки-вершины куска на карте: его рисует меш стартовой области
func _on_map(key: Vector2i) -> bool:
	var i0 := key.x * C
	var j0 := key.y * C
	return i0 >= 0 and j0 >= 0 and i0 + C <= world.W - 1 and j0 + C <= world.H - 1


func _center(key: Vector2i) -> Vector2:
	return (Vector2(key) + Vector2(0.5, 0.5)) * C * TILE


func _add(key: Vector2i, built: Dictionary) -> void:
	land.chunks[key] = built.fields
	var mi: MeshInstance3D = null
	if built.mesh != null:
		mi = MeshInstance3D.new()
		mi.mesh = built.mesh
		mi.material_override = _mat
		# далёкий рельеф без теней: каждая тень — ещё по проходу отрисовки на кусок, а вдали их скрывает туман
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	_nodes[key] = mi


## Поля куска и его меш (в фоновой задаче). Вершины — центры клеток от первой клетки куска до первой
## клетки следующего, поэтому соседние куски и карта смыкаются; квадраты целиком на карте пропускаются
func _build(key: Vector2i) -> Dictionary:
	var f := OuterLand.compute_chunk(world, key)
	var W := world.W
	var H := world.H
	var hv := heights.hv
	var biome := world.biome
	var fh: PackedFloat32Array = f.h
	var fb: PackedByteArray = f.biome
	var S := C + 3
	var i0 := key.x * C
	var j0 := key.y * C
	var palette := PackedColorArray()
	for bd: Dictionary in Biomes.LIST:
		palette.append(Color8(bd.color[0], bd.color[1], bd.color[2]))
	# высоты и цвета клеток куска с запасом в клетку (для нормалей): на карте — из неё
	var hs := PackedFloat32Array()
	var col := PackedColorArray()
	hs.resize(S * S)
	col.resize(S * S)
	for b in S:
		var j := j0 - 1 + b
		for a in S:
			var i := i0 - 1 + a
			var k := b * S + a
			var bi: int
			if i >= 0 and j >= 0 and i < W and j < H:
				hs[k] = hv[j * W + i]
				bi = biome[j * W + i]
			else:
				# Heightfield.outer_meters, развёрнута на месте (тот же расчёт, что в ней)
				var h := fh[k]
				hs[k] = h * HS if h >= 0.0 else maxf(-OCEAN_DEPTH, h * OCEAN_DEPTH) - 0.5
				bi = fb[k]
			col[k] = palette[bi]
	var V := C + 1
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var vc := PackedColorArray()
	pos.resize(V * V)
	nor.resize(V * V)
	vc.resize(V * V)
	for b in V:
		for a in V:
			var k := (b + 1) * S + a + 1
			var v := b * V + a
			pos[v] = Vector3((i0 + a + 0.5) * TILE, hs[k], (j0 + b + 0.5) * TILE)
			nor[v] = Vector3(hs[k - 1] - hs[k + 1], 2.0 * TILE, hs[k - S] - hs[k + S]).normalized()
			vc[v] = col[k]
	var idx := PackedInt32Array()
	for b in C:
		var j := j0 + b
		for a in C:
			var i := i0 + a
			if i >= 0 and j >= 0 and i + 1 <= W - 1 and j + 1 <= H - 1:
				continue
			var p := b * V + a
			# два треугольника квадрата; без временного массива на каждый квадрат
			idx.append(p)
			idx.append(p + 1)
			idx.append(p + V)
			idx.append(p + 1)
			idx.append(p + V + 1)
			idx.append(p + V)
	var mesh: ArrayMesh = null
	if not idx.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nor
		arrays[Mesh.ARRAY_COLOR] = vc
		arrays[Mesh.ARRAY_INDEX] = idx
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {fields = f, mesh = mesh}
