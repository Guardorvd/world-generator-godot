class_name OuterTerrain
extends Node3D
var terrain_builder: TerrainBuilder = GameContext.scope.terrain
## Рельеф за краем стартовой области (с 1.9.5): куски OuterLand вокруг игрока. Кусок считается и
## готовится в массивах в задаче WorkerThreadPool, ближние первыми, а меш, узел и OuterLand.chunks
## попадает в главном потоке. Дальние куски выгружаются. Меш раскрашен цветами биомов по вершинам
## (у стартовой области — запечённая текстура) и примыкает к её краю без щели: клетки карты на границе
## берутся из Heightfield.

const TILE := GameConfig.TILE
const HS := GameConfig.HS
const OCEAN_DEPTH := GameConfig.OCEAN_DEPTH
const C := OuterLand.C
const RADIUS := 1200.0   # куски ближе этого держатся загруженными (дальше всё равно туман)
const DROP := 1600.0     # куски дальше этого выгружаются
const TASKS := 8         # сколько кусков считается одновременно, не больше (12.2: было 3 на любом ПК)
const RECHECK := 32.0    # через сколько метров пути заново решать, какие куски нужны

var world: WorldData
var heights: Heightfield
var land: OuterLand
var _mat: ShaderMaterial
var _palette := PackedColorArray()
var _nodes := {}         # номер куска -> MeshInstance3D (или null, если в куске нечего рисовать)
var _tasks := {}         # номер куска -> {id, out}
var _queue: Array[Vector2i] = []   # нужные куски, которых ещё нет, ближние в конце
var _checked_at := Vector2.INF
var _redo: Array[Vector2i] = []   # 13.9: загруженные куски закреплённой области, пересчитать поверх старых
var _stale := {}                  # куски, чей расчёт начат до закрепления: после него пересчитать снова
## по куску на два ядра: главному потоку и растительности остаются свои
var _task_limit := clampi(OS.get_processor_count() / 2, 1, TASKS)
var _cpu := preload("res://scripts/core/byte_lru.gd").new()
var _cpu_lock := Mutex.new()
var _cpu_epoch := 0
var cpu_budget: RefCounted


func setup(w: WorldData, h: Heightfield) -> void:
	_cpu.budget = cpu_budget
	world = w
	heights = h
	land = w.outer
	_mat = terrain_builder.outer_material()
	_palette.clear()
	for bd: Dictionary in Biomes.LIST:
		_palette.append(Color8(bd.color[0], bd.color[1], bd.color[2]))


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
func update(x: float, z: float, allow_apply: bool = true) -> void:
	# Не более одного готового куска за кадр, без временного массива ключей каждый кадр.
	var done: Variant = null
	for key: Vector2i in _tasks:
		var t: Dictionary = _tasks[key]
		if allow_apply and WorkerThreadPool.is_task_completed(t.id):
			WorkerThreadPool.wait_for_task_completion(t.id)
			done = key
			# При переносе игрока результат старого запроса уже может оказаться слишком далеко.
			if not _stale.has(key) and _center(key).distance_to(Vector2(x, z)) <= DROP:
				_add(key, t.out.r)
			break
	if done != null:
		_tasks.erase(done)
		if _stale.has(done):
			_stale.erase(done)
			if _nodes.has(done):
				_redo.append(done)
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
	while _tasks.size() < _task_limit and not _redo.is_empty():
		var key: Vector2i = _redo.pop_back()
		if not _nodes.has(key) or _tasks.has(key):
			continue
		var out := {}
		var id := WorkerThreadPool.add_task(func() -> void: out.r = _build(key), false)
		_tasks[key] = {id = id, out = out}
	while _tasks.size() < _task_limit and not _queue.is_empty():
		var key: Vector2i = _queue.pop_back()
		if _nodes.has(key):
			continue # уже загружен сразу (preload_around)
		var out := {}
		# низкий приоритет: растительность и кадр важнее дальнего рельефа
		var id := WorkerThreadPool.add_task(func() -> void: out.r = _build(key), false)
		_tasks[key] = {id = id, out = out}


## 13.9: область rect (клетки) закреплена — её куски пересчитываются. Старый кусок остаётся,
## пока новый не готов: земля под игроком не пропадает.
func refresh(rect: Rect2i) -> void:
	# A changed shore/normal affects the halo too; conservatively invalidate retired CPU chunks.
	_cpu_lock.lock()
	_cpu_epoch += 1
	_cpu.clear()
	_cpu_lock.unlock()
	for key: Vector2i in _nodes.keys() + _tasks.keys():
		if not Rect2i(key * C - Vector2i.ONE, Vector2i.ONE * (C + 3)).intersects(rect):
			continue
		if _tasks.has(key):
			_stale[key] = true
		elif not _redo.has(key):
			_redo.append(key)


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
	var node := stage_chunk(key, built)
	publish_chunks({key: built}, {key: node})


func publish_chunks(chunks: Dictionary, nodes: Dictionary) -> void:
	for key: Vector2i in chunks:
		if _nodes.get(key) != null:
			_nodes[key].visible = false
			_nodes[key].queue_free()
		land.chunks[key] = chunks[key].fields
		_nodes[key] = nodes[key]
		if nodes[key] != null: nodes[key].visible = true
		if _tasks.has(key): _stale[key] = true


func stage_chunk(key: Vector2i, built: Dictionary) -> MeshInstance3D:
	var mi: MeshInstance3D = null
	if not built.arrays.is_empty():
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, built.arrays, [], built.lods)
		mi = MeshInstance3D.new()
		mi.mesh = mesh
		var center := _center(key)
		mi.position = Vector3(center.x, 0.0, center.y)
		mi.material_override = _mat
		mi.lod_bias = 0.25
		# Радиус загрузки считается до ближайшей точки куска, видимость — с запасом на его половину.
		mi.visibility_range_end = RADIUS + C * TILE * sqrt(2.0) * 0.5
		mi.visibility_range_end_margin = RECHECK
		# Terrain must occlude sunlight too; the directional shadow frustum culls distant chunks.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		add_child(mi)
		mi.visible = false
	return mi


## Поля куска и его меш (в фоновой задаче). Вершины — центры клеток от первой клетки куска до первой
## клетки следующего, поэтому соседние куски и карта смыкаются; квадраты целиком на карте пропускаются
func _build(key: Vector2i, snapshot: Variant = null, prepared_fields := {}) -> Dictionary:
	if snapshot != null or not prepared_fields.is_empty(): return _compute(key, snapshot, prepared_fields)
	_cpu_lock.lock()
	var cached: Variant = _cpu.get_value(key)
	var epoch := _cpu_epoch
	_cpu_lock.unlock()
	if cached != null: return cached
	var built := _compute(key)
	_cpu_lock.lock()
	if epoch == _cpu_epoch: _cpu.put(key, built)
	_cpu_lock.unlock()
	return built


func _compute(key: Vector2i, snapshot: Variant = null, prepared_fields := {}) -> Dictionary:
	var f: Dictionary = prepared_fields.duplicate() if not prepared_fields.is_empty() else OuterLand.compute_chunk(world, key)
	var ledger: Dictionary = snapshot if snapshot is Dictionary else world.outer.get_ledger()
	OuterLand._overlay_regions(ledger, Rect2i(key * C - Vector2i.ONE, Vector2i.ONE * (C + 3)), f)
	var regions: Dictionary = ledger.get("regions", {})
	var refined := false
	var W := world.W
	var H := world.H
	var hv := heights.hv
	var biome := world.biome
	var fh: PackedFloat32Array = f.h
	var fb: PackedByteArray = f.biome
	var S := C + 3
	var i0 := key.x * C
	var j0 := key.y * C
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
			col[k] = _palette[bi]
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
			pos[v] = Vector3((a + 0.5 - C * 0.5) * TILE, hs[k], (b + 0.5 - C * 0.5) * TILE)
			nor[v] = Vector3(hs[k - 1] - hs[k + 1], 2.0 * TILE, hs[k - S] - hs[k + S]).normalized()
			vc[v] = col[k]
	var idx := PackedInt32Array()
	for b in C:
		var j := j0 + b
		for a in C:
			var i := i0 + a
			if i >= 0 and j >= 0 and i + 1 <= W - 1 and j + 1 <= H - 1:
				continue
			var patch := OuterLand.refined_patch(regions, Vector2i(i, j))
			if not patch.is_empty():
				refined = true
				var first := pos.size()
				for rz in RoadRefinement.STRIDE:
					for rx in RoadRefinement.STRIDE:
						var n := rz * RoadRefinement.STRIDE + rx
						pos.append(Vector3((a + 0.5 - C * 0.5) * TILE + rx * RoadRefinement.STEP, patch.h[n], (b + 0.5 - C * 0.5) * TILE + rz * RoadRefinement.STEP))
						var dx: float = patch.h[rz * RoadRefinement.STRIDE + mini(rx + 1, RoadRefinement.DIV)] - patch.h[rz * RoadRefinement.STRIDE + maxi(0, rx - 1)]
						var dz: float = patch.h[mini(rz + 1, RoadRefinement.DIV) * RoadRefinement.STRIDE + rx] - patch.h[maxi(0, rz - 1) * RoadRefinement.STRIDE + rx]
						nor.append(Vector3(-dx, 2.0 * RoadRefinement.STEP, -dz).normalized())
						var tint: Color = col[(b + 1) * S + a + 1]
						var surface: int = patch.surface[n]
						if surface > 0:
							var rgb: Array = RoadSurface.LIST[surface].color
							tint = tint.lerp(Color8(rgb[0], rgb[1], rgb[2]), patch.color[n].a)
						vc.append(tint)
				for rz in RoadRefinement.DIV:
					for rx in RoadRefinement.DIV:
						var q := first + rz * RoadRefinement.STRIDE + rx
						idx.append_array([q, q + 1, q + RoadRefinement.STRIDE, q + 1, q + RoadRefinement.STRIDE + 1, q + RoadRefinement.STRIDE])
				continue
			var p := b * V + a
			# два треугольника квадрата; без временного массива на каждый квадрат
			idx.append(p)
			idx.append(p + 1)
			idx.append(p + V)
			idx.append(p + 1)
			idx.append(p + V + 1)
			idx.append(p + V)
	var arrays: Array = []
	var lods := {}
	if not idx.is_empty():
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nor
		arrays[Mesh.ARRAY_COLOR] = vc
		arrays[Mesh.ARRAY_INDEX] = idx
		# Частично закрытые картой куски сохраняют исходные треугольники и точный край выреза.
		if not refined and not (i0 < W - 1 and i0 + C > 0 and j0 < H - 1 and j0 + C > 0):
			lods = _lod(pos)
	return {fields = f, arrays = arrays, lods = lods}


## Один LOD с шагом две клетки. Периметр остаётся с шагом в клетку при любом LOD соседей.
## Выбор по экранной ошибке делает Godot; отдельного переключателя в игровом кадре нет.
static func _lod(pos: PackedVector3Array) -> Dictionary:
	var V := C + 1
	var idx := PackedInt32Array()
	var error := 0.0
	for b in range(0, C, 2):
		for a in range(0, C, 2):
			var p := b * V + a
			var q := p + 2 * V
			var h00 := pos[p].y
			var h10 := pos[p + 2].y
			var h01 := pos[q].y
			var h11 := pos[q + 2].y
			error = maxf(error, absf(pos[p + 1].y - (h00 + h10) * 0.5))
			error = maxf(error, absf(pos[q + 1].y - (h01 + h11) * 0.5))
			error = maxf(error, absf(pos[p + V].y - (h00 + h01) * 0.5))
			error = maxf(error, absf(pos[p + V + 2].y - (h10 + h11) * 0.5))
			error = maxf(error, absf(pos[p + V + 1].y - (h10 + h01) * 0.5))
			if a > 0 and b > 0 and a + 2 < C and b + 2 < C:
				idx.append_array([p, p + 2, q, p + 2, q + 2, q])
				continue
			# Веер к центру квадрата: только внешние рёбра сохраняют промежуточную вершину.
			var ring: Array[int] = [p]
			if b == 0:
				ring.append(p + 1)
			ring.append(p + 2)
			if a + 2 == C:
				ring.append(p + V + 2)
			ring.append(q + 2)
			if b + 2 == C:
				ring.append(q + 1)
			ring.append(q)
			if a == 0:
				ring.append(p + V)
			for k in ring.size():
				idx.append_array([p + V + 1, ring[k], ring[(k + 1) % ring.size()]])
	# Запас на смену диагоналей у края. На резком рельефе LOD включается дальше.
	return {maxf(0.5, error * 2.0): idx}
