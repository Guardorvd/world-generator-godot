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
const Floor := preload("res://scripts/render/forest_floor.gd")
const FarForest := preload("res://scripts/render/distant_forest.gd")
const C := OuterLand.C
const RADIUS := 1200.0   # куски ближе этого держатся загруженными (дальше всё равно туман)
const DROP := 1600.0     # куски дальше этого выгружаются
const TASKS := 8         # сколько кусков считается одновременно, не больше (12.2: было 3 на любом ПК)
const RECHECK := 32.0    # через сколько метров пути заново решать, какие куски нужны
const MESH_POOL_LIMIT := 32

var use_node_pool := true
var _mesh_pool: Array[MeshInstance3D] = []
var pool_stats := {reused = 0, created = 0, pooled = 0}

var world: WorldData
var heights: Heightfield
var land: OuterLand
var _mat: ShaderMaterial
var _far_mat: ShaderMaterial
var _far_radius := 0.0
var _far_drop := 0.0
var _far_chunk_cells := 128
var _far_step := 4
var _far_sink_m := 3.0
var _palette := PackedColorArray()
var _nodes := {}         # номер куска -> MeshInstance3D (или null, если в куске нечего рисовать)
var _tasks := {}         # номер куска -> {id, out}
var _queue: Array[Vector2i] = []   # нужные куски, которых ещё нет, ближние в конце
var _evict_pending: Array[Vector2i] = []
var _far_nodes := {}     # номер дальнего куска -> MeshInstance3D (или null)
var _far_tasks := {}     # номер дальнего куска -> {id, out}
var _far_queue: Array[Vector2i] = []
var _far_evict: Array[Vector2i] = []
var _crown_wait := {}
var crown_clock: RefCounted
var crown_cells_published := 0
var _checked_at := Vector2.INF
var _redo: Array[Vector2i] = []   # 13.9: загруженные куски закреплённой области, пересчитать поверх старых
var _stale := {}                  # куски, чей расчёт начат до закрепления: после него пересчитать снова
## Runtime jobs compete with physics and the vegetation workers; preload uses its own group.
var _task_limit := clampi(OS.get_processor_count() / 6, 1, TASKS)
var _cpu := preload("res://scripts/core/byte_lru.gd").new()
var _cpu_lock := Mutex.new()
var _cpu_epoch := 0
var cpu_budget: RefCounted
var frame_budget: RefCounted


func setup(w: WorldData, h: Heightfield) -> void:
	_cpu.budget = cpu_budget
	world = w
	heights = h
	land = w.outer
	_mat = terrain_builder.outer_material(w.template_id)
	var cfg := WorldTemplate.config(w.template_id)
	_far_radius = cfg.outer_far_radius
	_far_drop = maxf(cfg.outer_far_drop, _far_radius + 200.0) if _far_radius > 0.0 else 0.0
	_far_step = maxi(2, cfg.outer_far_step)
	_far_chunk_cells = maxi(_far_step * 4, (maxi(32, cfg.outer_far_chunk_cells) / _far_step) * _far_step)
	_far_sink_m = cfg.outer_far_sink_m
	_far_mat = terrain_builder.far_material(_mat) if _far_radius > 0.0 else null
	if _far_mat == null:
		_far_mat = _mat
	_palette.clear()
	for bd: Dictionary in Biomes.LIST:
		_palette.append(Color8(bd.color[0], bd.color[1], bd.color[2]))


## Сразу загрузить все куски в радиусе radius (при старте игры), чтобы ближний рельеф не вырастал на глазах
func preload_around(x: float, z: float, radius: float = RADIUS) -> void:
	var keys: Array[Vector2i] = []
	for key: Vector2i in _wanted(x, z, radius):
		if not _nodes.has(key) and not _tasks.has(key):
			keys.append(key)
	if not keys.is_empty():
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
	if _far_radius > 0.0:
		var far_r := minf(_far_radius, _far_radius * (radius / RADIUS))
		var far_keys: Array[Vector2i] = []
		for key: Vector2i in _wanted_far(x, z, far_r):
			if not _far_nodes.has(key) and not _far_tasks.has(key):
				far_keys.append(key)
		if not far_keys.is_empty():
			var far_outs: Array = []
			far_outs.resize(far_keys.size())
			var flock := Mutex.new()
			var ftask := func(k: int) -> void:
				var r := _compute_far(far_keys[k])
				flock.lock()
				far_outs[k] = r
				flock.unlock()
			var fid := WorkerThreadPool.add_group_task(ftask, far_keys.size(), -1, true)
			WorkerThreadPool.wait_for_group_task_completion(fid)
			for k in far_keys.size():
				_add_far(far_keys[k], far_outs[k])
	_checked_at = Vector2.INF # дальние куски догрузит update


## Каждый кадр: забрать готовые куски, выгрузить дальние, запустить расчёт ближайших недостающих
func update(x: float, z: float, allow_apply: bool = true, keep_current := false) -> bool:
	if not _within_frame_budget():
		return false
	var applied := false
	# Не более одного готового куска за кадр, без временного массива ключей каждый кадр.
	var done: Variant = null
	var completed := {}
	for key: Vector2i in _tasks:
		var t: Dictionary = _tasks[key]
		if allow_apply and _within_frame_budget() and WorkerThreadPool.is_task_completed(t.id):
			WorkerThreadPool.wait_for_task_completion(t.id)
			done = key
			# При переносе игрока результат старого запроса уже может оказаться слишком далеко.
			if not _stale.has(key) and _center(key).distance_to(Vector2(x, z)) <= DROP:
				completed = t.out.r
			break
	if done != null:
		_tasks.erase(done)
		# Публикация инвалидирует незавершённые задачи этой клетки. Свою уже забрали:
		# иначе готовый кусок помечает сам себя устаревшим и пересобирается бесконечно.
		if not completed.is_empty():
			_add(done, completed, true)
			applied = true
		if _stale.has(done):
			_stale.erase(done)
			if _nodes.has(done):
				_redo.append(done)
			else:
				_checked_at = Vector2.INF
	if _far_radius > 0.0 and not applied and allow_apply and _within_frame_budget():
		var fdone: Variant = null
		var fcompleted := {}
		for key: Vector2i in _far_tasks:
			var t: Dictionary = _far_tasks[key]
			if WorkerThreadPool.is_task_completed(t.id):
				WorkerThreadPool.wait_for_task_completion(t.id)
				fdone = key
				if _far_center(key).distance_to(Vector2(x, z)) <= _far_drop:
					fcompleted = t.out.r
				break
		if fdone != null:
			_far_tasks.erase(fdone)
			if not fcompleted.is_empty():
				_add_far(fdone, fcompleted)
				applied = true
	# Пересчёт очереди и запуск задач тоже работают на главном потоке.
	if not _within_frame_budget():
		return applied
	if Vector2(x, z).distance_to(_checked_at) > RECHECK:
		_checked_at = Vector2(x, z)
		if not keep_current:
			_evict_pending.clear()
			for key: Vector2i in _nodes:
				if _center(key).distance_to(Vector2(x, z)) > DROP:
					_evict_pending.append(key)
		_queue.clear()
		for key: Vector2i in _wanted(x, z):
			if not _nodes.has(key) and not _tasks.has(key):
				_queue.append(key)
		_queue.reverse()
		if _far_radius > 0.0:
			if not keep_current:
				_far_evict.clear()
				for key: Vector2i in _far_nodes:
					if _far_center(key).distance_to(Vector2(x, z)) > _far_drop:
						_far_evict.append(key)
			_far_queue.clear()
			for key: Vector2i in _wanted_far(x, z, _far_radius):
				if not _far_nodes.has(key) and not _far_tasks.has(key):
					_far_queue.append(key)
			_far_queue.reverse()
	while _tasks.size() < _task_limit and not _redo.is_empty() and _within_frame_budget():
		var key: Vector2i = _redo.pop_back()
		if not _nodes.has(key) or _tasks.has(key):
			continue
		var out := {}
		var id := WorkerThreadPool.add_task(func() -> void: out.r = _build(key), false)
		_tasks[key] = {id = id, out = out}
	while _tasks.size() < _task_limit and not _queue.is_empty() and _within_frame_budget():
		var key: Vector2i = _queue.pop_back()
		if _nodes.has(key):
			continue # уже загружен сразу (preload_around)
		var out := {}
		# низкий приоритет: растительность и кадр важнее дальнего рельефа
		var id := WorkerThreadPool.add_task(func() -> void: out.r = _build(key), false)
		_tasks[key] = {id = id, out = out}
	while _far_radius > 0.0 and _tasks.size() + _far_tasks.size() < _task_limit and not _far_queue.is_empty() and _within_frame_budget():
		var key: Vector2i = _far_queue.pop_back()
		if _far_nodes.has(key) or _far_tasks.has(key):
			continue
		var out := {}
		var id := WorkerThreadPool.add_task(func() -> void: out.r = _compute_far(key), false)
		_far_tasks[key] = {id = id, out = out}
	if not keep_current and allow_apply and not applied and not _crown_wait.is_empty() and _within_frame_budget():
		var key: Vector2i = _crown_wait.keys()[0]
		var work: Dictionary = _crown_wait[key]
		if not work.has("cells"):
			work.cells = FarForest.attachment_cells(work.batches, Vector2(x, z))
			work.erase("batches")
		if not work.cells.is_empty():
			var born: float = crown_clock.clock if crown_clock != null else 0.0
			FarForest.attach_cell(_nodes[key], work.cells.pop_back(), Vector2.ZERO, true, born)
			crown_cells_published += 1
			applied = true
		if work.cells.is_empty():
			_crown_wait.erase(key)
	if not keep_current and allow_apply and not applied and not _evict_pending.is_empty() and _within_frame_budget():
		var key: Vector2i = _evict_pending.pop_back()
		if _nodes.has(key) and _center(key).distance_to(Vector2(x, z)) > DROP:
			if _nodes[key] != null:
				_release_mesh_node(_nodes[key])
			_nodes.erase(key)
			_crown_wait.erase(key)
			land.chunks.erase(key)
			applied = true
	if _far_radius > 0.0 and not keep_current and allow_apply and not applied and not _far_evict.is_empty() and _within_frame_budget():
		var key: Vector2i = _far_evict.pop_back()
		if _far_nodes.has(key) and _far_center(key).distance_to(Vector2(x, z)) > _far_drop:
			if _far_nodes[key] != null:
				_release_mesh_node(_far_nodes[key])
			_far_nodes.erase(key)
			applied = true
	return applied


func arrival_chunks(p: Vector2) -> Array[Vector2i]:
	return _wanted(p.x, p.y, C * TILE * 0.5)


func arrival_ready(keys: Array[Vector2i]) -> bool:
	for key in keys:
		if not _nodes.has(key):
			return false
	return true


func recheck() -> void:
	_checked_at = Vector2.INF


func _within_frame_budget() -> bool:
	return frame_budget == null or frame_budget.allows_work()


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
	for key: Vector2i in _far_tasks:
		WorkerThreadPool.wait_for_task_completion(_far_tasks[key].id)
	_far_tasks.clear()


func _exit_tree() -> void:
	finish()
	_mesh_pool.clear()


func _acquire_mesh_node() -> MeshInstance3D:
	if use_node_pool and not _mesh_pool.is_empty():
		var reused: MeshInstance3D = _mesh_pool.pop_back()
		pool_stats.reused += 1
		return reused
	var created := MeshInstance3D.new()
	add_child(created)
	pool_stats.created += 1
	return created


func _release_mesh_node(node: MeshInstance3D) -> void:
	if not is_instance_valid(node):
		return
	node.visible = false
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
	node.mesh = null
	node.material_override = null
	node.position = Vector3.ZERO
	node.lod_bias = 1.0
	node.visibility_range_end = 0.0
	node.visibility_range_end_margin = 0.0
	if use_node_pool and _mesh_pool.size() < MESH_POOL_LIMIT:
		_mesh_pool.append(node)
		pool_stats.pooled += 1
	else:
		node.queue_free()


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


func _add(key: Vector2i, built: Dictionary, defer_crowns := false) -> void:
	var node := stage_chunk(key, built, not defer_crowns)
	publish_chunks({key: built}, {key: node})
	if defer_crowns and node != null and not built.get("crowns", {}).is_empty():
		_crown_wait[key] = {batches = built.crowns}


func publish_chunks(chunks: Dictionary, nodes: Dictionary) -> void:
	for key: Vector2i in chunks:
		_crown_wait.erase(key)
		if _nodes.get(key) != null:
			_release_mesh_node(_nodes[key])
		land.chunks[key] = chunks[key].fields
		_nodes[key] = nodes[key]
		if nodes[key] != null: nodes[key].visible = true
		if _tasks.has(key): _stale[key] = true


func stage_chunk(key: Vector2i, built: Dictionary, attach_crowns := true) -> MeshInstance3D:
	var mi: MeshInstance3D = null
	if not built.arrays.is_empty():
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, built.arrays, [], built.lods)
		mi = _acquire_mesh_node()
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
		mi.visible = false
		if attach_crowns:
			FarForest.attach(mi, built.get("crowns", {}), Vector2.ZERO, true)
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
	var ledger: Dictionary = snapshot if snapshot is Dictionary else world.outer.get_ledger()
	var f: Dictionary
	if prepared_fields.is_empty():
		f = OuterLand.compute_chunk(world, key, ledger)
	else:
		f = prepared_fields.duplicate()
		for field: String in ["h", "elev", "biome", "slope", "dist", "dw", "river", "temp", "moist", "light", "dist_path", "village"]:
			if f.has(field): f[field] = f[field].duplicate()
		OuterLand._overlay_regions(ledger, Rect2i(key * C - Vector2i.ONE, Vector2i.ONE * (C + 3)), f)
		f.rock = preload("res://scripts/world/mountain_surface.gd").field(f.elev, f.slope, f.moist)
	var regions: Dictionary = ledger.get("regions", {})
	var forest_cover := FarForest.cover_field(world, key, f)
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
	var rock_tint := Color8(int(MapBaker.ROCKC[0]), int(MapBaker.ROCKC[1]), int(MapBaker.ROCKC[2]))
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
				bi = fb[k]
				var sea := bi == Biomes.SHALLOW or bi == Biomes.OCEAN or bi == Biomes.DEEP
				hs[k] = Heightfield.outer_meters(h, not sea)
			var elevation: float = f.elev[k]
			if Biomes.LIST[bi].get("water", false):
				col[k] = Color8(112, 108, 91)
			elif bi == Biomes.SNOW or bi == Biomes.PEAK:
				col[k] = _palette[bi]
			else:
				col[k] = _palette[bi].lerp(rock_tint, 0.45 * smoothstep(0.3, 0.6, elevation))
			col[k].a = float(f.rock[k]) / 255.0 if f.has("rock") and not Biomes.LIST[bi].get("water", false) and f.river[k] == 0 else 0.0
	var V := C + 1
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var vc := PackedColorArray()
	var climate_uv := PackedVector2Array()
	pos.resize(V * V)
	nor.resize(V * V)
	vc.resize(V * V)
	climate_uv.resize(V * V)
	for b in V:
		for a in V:
			var k := (b + 1) * S + a + 1
			var v := b * V + a
			pos[v] = Vector3((a + 0.5 - C * 0.5) * TILE, hs[k], (b + 0.5 - C * 0.5) * TILE)
			var cell := Vector2i(i0 + a, j0 + b)
			if cell.x >= 0 and cell.y >= 0 and cell.x < W and cell.y < H:
				nor[v] = TerrainBuilder._normal(hv, W, H, cell.x, cell.y)
			else:
				nor[v] = Vector3(hs[k - 1] - hs[k + 1], 2.0 * TILE, hs[k - S] - hs[k + S]).normalized()
			vc[v] = col[k]
			var cover := FarForest.sample_cover(forest_cover, a, b) if FarForest.outer_dry(f, k) else 0.0
			climate_uv[v] = Vector2(Floor.ground_moisture(f.moist[k], f.dw[k]), cover)
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
				var p := b * V + a
				for rz in RoadRefinement.STRIDE:
					for rx in RoadRefinement.STRIDE:
						var tx := float(rx) / RoadRefinement.DIV
						var tz := float(rz) / RoadRefinement.DIV
						climate_uv.append(climate_uv[p].lerp(climate_uv[p + 1], tx).lerp(
							climate_uv[p + V].lerp(climate_uv[p + V + 1], tx), tz))
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
						tint.a=col[(b+1)*S+a+1].a*(1.0-patch.color[n].a)
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
		arrays[Mesh.ARRAY_TEX_UV] = climate_uv
		arrays[Mesh.ARRAY_INDEX] = idx
		# Частично закрытые картой куски сохраняют исходные треугольники и точный край выреза.
		if not refined and not (i0 < W - 1 and i0 + C > 0 and j0 < H - 1 and j0 + C > 0):
			lods = _lod(pos)
	var crowns := {} if arrays.is_empty() else FarForest.outer(world, key, f, hs, regions, forest_cover)
	return {fields = f, arrays = arrays, lods = lods, crowns = crowns}


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


func _far_center(key: Vector2i) -> Vector2:
	return (Vector2(key) + Vector2(0.5, 0.5)) * float(_far_chunk_cells) * TILE


func _on_map_far(key: Vector2i) -> bool:
	var i0 := key.x * _far_chunk_cells
	var j0 := key.y * _far_chunk_cells
	return i0 >= 0 and j0 >= 0 and i0 + _far_chunk_cells <= world.W - 1 and j0 + _far_chunk_cells <= world.H - 1


func _wanted_far(x: float, z: float, radius: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _far_radius <= 0.0 or radius <= 0.0:
		return out
	var side := float(_far_chunk_cells) * TILE
	var r := ceili(radius / side)
	var ck := Vector2i(floori(x / side), floori(z / side))
	var inner_skip := maxf(0.0, RADIUS - 96.0)
	var dist := {}
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var key := ck + Vector2i(dx, dy)
			if _on_map_far(key):
				continue
			var x0 := float(key.x) * side
			var x1 := float(key.x + 1) * side
			var z0 := float(key.y) * side
			var z1 := float(key.y + 1) * side
			var px := clampf(x, x0, x1)
			var pz := clampf(z, z0, z1)
			var d_min := Vector2(px - x, pz - z).length()
			if d_min > radius:
				continue
			var fx := x0 if absf(x - x0) > absf(x - x1) else x1
			var fz := z0 if absf(z - z0) > absf(z - z1) else z1
			if Vector2(fx - x, fz - z).length() < inner_skip:
				continue
			out.append(key)
			dist[key] = d_min
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return dist[a] < dist[b])
	return out


func _add_far(key: Vector2i, built: Dictionary) -> void:
	var node := stage_far_chunk(key, built)
	if _far_nodes.get(key) != null:
		_release_mesh_node(_far_nodes[key])
	_far_nodes[key] = node
	if node != null:
		node.visible = true


func stage_far_chunk(key: Vector2i, built: Dictionary) -> MeshInstance3D:
	var mi: MeshInstance3D = null
	if not built.get("arrays", []).is_empty():
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, built.arrays)
		mi = _acquire_mesh_node()
		mi.mesh = mesh
		var center := _far_center(key)
		mi.position = Vector3(center.x, 0.0, center.y)
		mi.material_override = _far_mat
		mi.lod_bias = 0.25
		mi.visibility_range_end = _far_radius + float(_far_chunk_cells) * TILE * sqrt(2.0) * 0.5
		mi.visibility_range_end_margin = RECHECK
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
	return mi


## Крупная геометрия дальних гольцов (без BFS/FarForest и с лёгким дальним материалом).
func _compute_far(key: Vector2i) -> Dictionary:
	var FC := _far_chunk_cells
	var step := _far_step
	var n_steps := FC / step
	var V := n_steps + 1
	var S := V + 2
	var i0 := key.x * FC
	var j0 := key.y * FC
	var W := world.W
	var H := world.H
	var cfg := WorldTemplate.config(world.template_id)
	var axis: ValleyAxis = ValleyAxis.for_world(world) if cfg.valley_relief else null
	var hs_raw := StageRelief.valley_coarse_rect(world, i0 - step, j0 - step, S, S, step, false) \
		if cfg.valley_relief else PackedFloat32Array()
	if hs_raw.is_empty():
		return {arrays = []}
	var temp_n: Simplex = world.noise.temp.clone()
	var moist_n: Simplex = world.noise.moist.clone()
	var tp0 := float(WorldData.NOISE_FIELDS.temp[0])
	var tp1 := int(WorldData.NOISE_FIELDS.temp[1])
	var mp0 := float(WorldData.NOISE_FIELDS.moist[0])
	var mp1 := int(WorldData.NOISE_FIELDS.moist[1])
	var rock_tint := Color8(int(MapBaker.ROCKC[0]), int(MapBaker.ROCKC[1]), int(MapBaker.ROCKC[2]))
	var temp_lapse := cfg.outer_temp_lapse
	var exp_surf := preload("res://scripts/world/mountain_surface.gd")

	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var vc := PackedColorArray()
	var uv := PackedVector2Array()
	pos.resize(V * V)
	nor.resize(V * V)
	vc.resize(V * V)
	uv.resize(V * V)
	var step_tile := float(step) * TILE
	for b in V:
		var wy := j0 + b * step
		var lat := StageClimate.latitude(world, wy)
		for a in V:
			var wx := i0 + a * step
			var k := (b + 1) * S + a + 1
			var hh := hs_raw[k]
			var v := b * V + a
			var hm := Heightfield.outer_meters(hh, true) - _far_sink_m
			pos[v] = Vector3((float(a * step) + 0.5 - float(FC) * 0.5) * TILE, hm, (float(b * step) + 0.5 - float(FC) * 0.5) * TILE)
			var hl := hs_raw[k - 1] * HS
			var hr := hs_raw[k + 1] * HS
			var hu := hs_raw[k - S] * HS
			var hd := hs_raw[k + S] * HS
			nor[v] = Vector3(hl - hr, 2.0 * step_tile, hu - hd).normalized()
			var e := axis.eco_elev(wy, hh) if axis != null else maxf(0.0, hh)
			var el := axis.eco_elev(wy, hs_raw[k - 1]) if axis != null else maxf(0.0, hs_raw[k - 1])
			var er := axis.eco_elev(wy, hs_raw[k + 1]) if axis != null else maxf(0.0, hs_raw[k + 1])
			var eu := axis.eco_elev(wy - step, hs_raw[k - S]) if axis != null else maxf(0.0, hs_raw[k - S])
			var ed := axis.eco_elev(wy + step, hs_raw[k + S]) if axis != null else maxf(0.0, hs_raw[k + S])
			var gx := (er - el) / float(step)
			var gy := (ed - eu) / float(step)
			var slope := sqrt(gx * gx + gy * gy) * 0.5 * 60.0
			var light := clampf(0.5 - 0.5 * (gy * 30.0) / sqrt(1.0 + gx * gx * 900.0 + gy * gy * 900.0), 0.0, 1.0)
			var t := clampf(0.43 + lat * 0.32 + temp_n.fbm(float(wx) / tp0, float(wy) / tp0, tp1) * 0.18 - e * temp_lapse + (light - 0.5) * 0.08, 0.0, 1.0)
			var rain := clampf(0.66 + 0.48 * moist_n.fbm(float(wx) / mp0, float(wy) / mp0, mp1), 0.12, 1.0)
			var m := StageClimate.soil_moisture(rain, 1e9, slope, t, Vector2(light, 0.0))
			var bi := StageClimate.land_biome(e, t, m, slope, 1e9, 1e9,
				cfg.peak_elev, cfg.peak_cold_elev, cfg.snow_temp, cfg.rock_elev, cfg.rock_slope, cfg.treeline_elev)
			var c := _palette[bi] if (bi == Biomes.SNOW or bi == Biomes.PEAK) else _palette[bi].lerp(rock_tint, 0.45 * smoothstep(0.3, 0.6, e))
			c.a = exp_surf.exposure(e, slope, m)
			vc[v] = c
			uv[v] = Vector2(Floor.ground_moisture(m, 1e9), 0.0)
	var idx := PackedInt32Array()
	for qb in n_steps:
		var j := j0 + qb * step
		for qa in n_steps:
			var i := i0 + qa * step
			if i >= 0 and j >= 0 and i + step <= W - 1 and j + step <= H - 1:
				continue
			var p := qb * V + qa
			idx.append(p)
			idx.append(p + 1)
			idx.append(p + V)
			idx.append(p + 1)
			idx.append(p + V + 1)
			idx.append(p + V)
	if idx.is_empty():
		return {arrays = []}
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_COLOR] = vc
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	return {arrays = arrays}
