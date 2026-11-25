class_name PlanTerrain
extends Node3D
## Готовый рельеф общего плана: CPU-геометрия сохраняется, дальние GPU-меши выгружаются.
## Все атрибуты копируются из одного окончательного меша, включая метровое полотно дорог.
## С 9.0 при старте и переносе сразу передаются только ближние части (near), дальние — по одной за кадр,
## сначала те, что впереди по ходу движения.
const CELLS := 64
const SIDE := CELLS * GameConfig.TILE
const RADIUS := 1800.0 # за плотным туманом; дальний силуэт не обрывается у стартового окна
const DROP := RADIUS + SIDE
const RECHECK := 32.0
const AHEAD := 600.0   # точка впереди по ходу, к которой тянется очередь
const MESH_POOL_LIMIT := 32
const ByteLru := preload("res://scripts/core/byte_lru.gd")
const LOD1_STEP := 2
const LOD2_STEP := 4
const LOD1_DIST := SIDE * 1.5
const LOD2_DIST := SIDE * 3.5
const LOD_HYSTERESIS := RECHECK
const LOD_RECHECK := 16.0
const LOD_CACHE_LIMIT := 32 * 1024 * 1024

var use_node_pool := true
var use_terrain_lod := true
var chunks := {}
var nodes := {}
var _node_lod := {}
var _lod_at := Vector2.INF
var _lod_cache := ByteLru.new()
var _lod_task := -1
var _lod_request := Vector3i.ZERO
var _lod_out := {}
var _lod_handoff := {}
var stream_stats := {lod_builds = 0, crown_cells = 0}
var pending: Array[Vector2i] = []
var _evict_pending: Array[Vector2i] = []
var _mesh_pool: Array[MeshInstance3D] = []
var pool_stats := {reused = 0, created = 0, pooled = 0}
var material: Material
## 15.11.2026: дальний вариант материала (TerrainBuilder.far_material) у частей, целиком лежащих дальше FAR_FROM.
## В шейдере ближняя деталь гаснет к DETAIL_FAR = 110 м; 40 м запаса — на камеру за игроком и путь между пересчётами
## (FAR_RECHECK) даже на спуске. null — как раньше, один материал (вода, инструменты).
const FAR_FROM := 150.0
const FAR_RECHECK := 8.0
var far_material: Material
var _far_at := Vector2.INF
var checked_at := Vector2.INF
var _cache: WorldCache
const FarForest := preload("res://scripts/render/distant_forest.gd")
var _crown_wait := {} # tile key -> pending crown publication, split into local cells
var crown_clock: RefCounted
var _world: WorldData
var _heights: Heightfield
var _cpu := preload("res://scripts/core/byte_lru.gd").new()
var _read_task := -1
var _read_key := Vector2i.ZERO
var _read_out := {}
var water_layer := -1
var _uncached_key: Variant = null
var _uncached_arrays: Array = [] # one oversized block, released as soon as it is uploaded
var source: RefCounted
var frame_budget: RefCounted
var relief_detail: RefCounted
var morph_lod: RefCounted
static var _recheck_frame := -1 # рельеф и два слоя воды пересчитывают очередь в разных кадрах


## Один проход по готовым треугольникам в потоке WorldLoader. Никакой новой триангуляции:
## общие высоты, нормали, UV, цвета и дорожные атрибуты остаются побайтно теми же.
static func partition(arrays: Array) -> Dictionary:
	var fast := Grid.fast_grid()
	if fast != null and not arrays.is_empty():
		return fast.PartitionTerrain(arrays, GameConfig.TILE, CELLS)
	return partition_reference(arrays)


## Эталон и путь для сборки без .NET.
static func partition_reference(arrays: Array) -> Dictionary:
	var out := {}
	if arrays.is_empty():
		return out
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var slots: Array[int] = []
	for slot: int in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR]:
		if arrays[slot] != null and arrays[slot].size() > 0:
			slots.append(slot)
	for at in range(0, indices.size(), 3):
		var a := pos[indices[at]]
		var b := pos[indices[at + 1]]
		var c := pos[indices[at + 2]]
		var key := Vector2i(floori((minf(a.x, minf(b.x, c.x)) / GameConfig.TILE - 0.5) / CELLS),
			floori((minf(a.z, minf(b.z, c.z)) / GameConfig.TILE - 0.5) / CELLS))
		if not out.has(key):
			var piece: Array = []
			piece.resize(Mesh.ARRAY_MAX)
			for slot in slots: piece[slot] = arrays[slot].slice(0, 0)
			piece[Mesh.ARRAY_INDEX] = PackedInt32Array()
			out[key] = {arrays = piece, ids = {}}
		var entry: Dictionary = out[key]
		for corner in 3:
			var id := indices[at + corner]
			if not entry.ids.has(id):
				entry.ids[id] = entry.ids.size()
				for slot in slots: entry.arrays[slot].append(arrays[slot][id])
			entry.arrays[Mesh.ARRAY_INDEX].append(entry.ids[id])
	for key: Vector2i in out.keys():
		out[key] = out[key].arrays # временная таблица перенумерации больше не нужна
	return out


func setup(prepared: Dictionary, mat: Material, cache: WorldCache = null, w: WorldData = null, h: Heightfield = null,
		shared_source: RefCounted = null, high_relief_detail := true) -> void:
	chunks = prepared
	material = mat
	_cache = cache
	_world = w
	_heights = h
	source = shared_source
	_lod_cache.limit = LOD_CACHE_LIMIT
	var src_cpu: Variant = source.get("_cpu") if source != null else null
	if src_cpu != null:
		_lod_cache.budget = src_cpu.budget
		if _lod_cache.budget != null:
			_lod_cache.budget.register_owner(_lod_cache._owner_id, "terrain_lod")
	if water_layer < 0 and h != null and h.fine_relief != null and source != null and mat is ShaderMaterial:
		if h.fine_lod:
			morph_lod = preload("res://scripts/render/plan_terrain_lod.gd").new()
			morph_lod.setup(h, chunks.keys(), mat)
		relief_detail = preload("res://scripts/render/plan_terrain_detail.gd").new()
		relief_detail.setup(self, h, source, mat, high_relief_detail)


func _read_arrays(key: Vector2i) -> Array:
	if source != null: return source.read(water_layer, key)
	var ref: Dictionary = chunks[key]
	var data: Variant = _cache._read(_cache.dir.path_join(ref.file), ref.key)
	if data is Dictionary and preload("res://scripts/game/surface_snapshot.gd").mesh_valid(data.get("arrays"), false):
		return data.arrays
	var arrays := WorldLoader.rebuild_chunk(key, _world, _heights) if water_layer < 0 else WaterBuilder.build_chunk(_world, _heights, key, water_layer)
	_cache._write(_cache.dir.path_join(ref.file), ref.key, var_to_bytes({arrays = arrays}))
	return arrays


func _arrays(key: Vector2i) -> Variant:
	if source != null: return source.ready(water_layer, key)
	if _uncached_key == key: return _uncached_arrays
	return chunks[key] if chunks[key] is Array else _cpu.get_value(key)


func _exit_tree() -> void:
	if relief_detail != null:
		relief_detail.close()
	if _lod_task != -1:
		WorkerThreadPool.wait_for_task_completion(_lod_task)
		_lod_task = -1
		_lod_out = {}
	_clear_lod_handoff()
	if _read_task != -1:
		WorkerThreadPool.wait_for_task_completion(_read_task)
		_read_task = -1
	_lod_cache.clear()
	_node_lod.clear()
	_mesh_pool.clear()


func _lod_enabled() -> bool:
	return use_terrain_lod and water_layer < 0 and _world != null and _heights != null and _heights.hv.size() >= _world.W * _world.H and Grid.fast_grid() != null


func _desired_lod(key: Vector2i, p: Vector2, current_lod: int, immediate := false) -> int:
	return _desired_lod_at(key, distance_to_chunk(key, p), current_lod, immediate)


func _desired_lod_at(key: Vector2i, d: float, current_lod: int, immediate: bool) -> int:
	if morph_lod != null:
		return morph_lod.desired(key, d, current_lod, immediate)
	if current_lod == 0:
		if d > LOD2_DIST + LOD_HYSTERESIS:
			return 2
		if d > LOD1_DIST + LOD_HYSTERESIS:
			return 1
		return 0
	if current_lod == 1:
		if d < LOD1_DIST - LOD_HYSTERESIS:
			return 0
		if d > LOD2_DIST + LOD_HYSTERESIS:
			return 2
		return 1
	if d < LOD1_DIST - LOD_HYSTERESIS:
		return 0
	if d < LOD2_DIST - LOD_HYSTERESIS:
		return 1
	return 2


func _lod_arrays(key: Vector2i, lod: int, immediate := true) -> Variant:
	var cache_key := Vector3i(key.x, key.y, lod)
	if _lod_handoff.get("key") == cache_key:
		return _lod_handoff.arrays
	var cached: Variant = _lod_cache.get_value(cache_key)
	if cached is Array:
		return cached
	var step := LOD1_STEP if lod == 1 else LOD2_STEP
	if morph_lod != null and not immediate:
		if _lod_task == -1:
			var detail: RefCounted = _heights.fine_relief
			var out := _lod_out
			_lod_request = cache_key
			_lod_task = WorkerThreadPool.add_task(func() -> void:
				out.arrays = detail.BuildMorphLod(key.x, key.y, step), false, "Рельеф LOD")
		return null
	var fast := Grid.fast_grid()
	if fast == null:
		return []
	var skirt := step * GameConfig.TILE * 0.5
	var arrays: Array
	if morph_lod != null:
		arrays = _heights.fine_relief.BuildMorphLod(key.x, key.y, step)
	elif _heights.fine_medium:
		arrays = _heights.fine_relief.BuildCoarseLod(key.x, key.y, step, skirt)
	else:
		arrays = fast.BuildTerrainLod(_world.W, _world.H, GameConfig.TILE, key.x, key.y, CELLS, step, _heights.hv, _world.path_mask, skirt)
	if not arrays.is_empty():
		_lod_cache.put(cache_key, arrays)
	return arrays


func _poll_lod() -> void:
	if _lod_task == -1 or not WorkerThreadPool.is_task_completed(_lod_task):
		return
	WorkerThreadPool.wait_for_task_completion(_lod_task)
	_lod_task = -1
	var arrays: Array = _lod_out.arrays
	_lod_out = {}
	stream_stats.lod_builds += 1
	# Retain even an invalid result so an unsupported tile can use the base mesh.
	if not _lod_cache.put(_lod_request, arrays):
		_clear_lod_handoff()
		var bytes := ByteLru.size_of(arrays)
		_lod_handoff = {key = _lod_request, arrays = arrays, bytes = bytes}
		if _lod_cache.budget != null:
			_lod_cache.budget.reserve(bytes)


func _clear_lod_handoff() -> void:
	if not _lod_handoff.is_empty() and _lod_cache.budget != null:
		_lod_cache.budget.release(_lod_handoff.bytes)
	_lod_handoff.clear()


func _step_lod(p: Vector2, near := INF, immediate := false) -> bool:
	var waiting_io := false
	for key: Vector2i in nodes:
		var distance := distance_to_chunk(key, p)
		if distance > near:
			continue
		if relief_detail != null and relief_detail.active(key):
			continue
		var current: int = _node_lod.get(key, 0)
		var wanted := _desired_lod_at(key, distance, current, immediate)
		if wanted == current:
			if morph_lod != null and morph_lod.wants_full(key, distance, current) and _arrays(key) == null:
				source.request(water_layer, key, distance)
			continue
		var node: MeshInstance3D = nodes[key]
		if wanted > 0:
			var lod_arrays: Variant = _lod_arrays(key, wanted, immediate)
			if lod_arrays == null:
				waiting_io = true
				continue
			if lod_arrays.is_empty():
				continue
			if not immediate and frame_budget != null and not frame_budget.allows_work():
				return false
			var started := Time.get_ticks_usec()
			_set_lod_mesh(node, key, wanted, p, lod_arrays)
			_node_lod[key] = wanted
			if morph_lod != null and not immediate:
				morph_lod.record(node, key, distance, current, wanted, (Time.get_ticks_usec() - started) / 1000.0)
			return true
		var arrays: Variant = _arrays(key)
		if arrays == null:
			waiting_io = true
			if source != null:
				source.request(water_layer, key, distance_to_chunk(key, p))
			elif _read_task == -1:
				_read_key = key
				_read_out = {}
				var out := _read_out
				_read_task = WorkerThreadPool.add_task(func() -> void: out.arrays = _read_arrays(key), false, "Чанк рельефа")
			continue
		if not immediate and frame_budget != null and not frame_budget.allows_work():
			return false
		var started := Time.get_ticks_usec()
		_set_lod_mesh(node, key, 0, p, arrays)
		_node_lod[key] = 0
		var elapsed := (Time.get_ticks_usec() - started) / 1000.0
		if source != null:
			source.uploaded(water_layer, key, arrays, elapsed)
		if morph_lod != null and not immediate:
			morph_lod.record(node, key, distance, current, 0, elapsed)
		if _uncached_key == key:
			_uncached_key = null
			_uncached_arrays = []
		return true
	# A local arrival scan cannot settle the LODs of the rest of the loaded plan.
	if not waiting_io and is_inf(near):
		_lod_at = p
	return false


func _terrain_mesh(key: Vector2i, arrays: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if morph_lod == null:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return mesh
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, TerrainBuilder.relief_mesh_format(arrays))
	# Include both morph endpoints in culling, including the shadow pass.
	mesh.custom_aabb = morph_lod.mesh_bounds(key, mesh.get_aabb())
	return mesh


func _set_lod_mesh(node: MeshInstance3D, key: Vector2i, lod: int, p: Vector2, arrays: Array) -> void:
	node.mesh = _terrain_mesh(key, arrays)
	if _lod_handoff.get("key") == Vector3i(key.x, key.y, lod):
		_clear_lod_handoff()
	if morph_lod != null:
		node.material_override = _material_for(key, p)
		morph_lod.configure(node, key, lod)


func _acquire_mesh_node(mesh: ArrayMesh, mat: Material, shadow_mode: GeometryInstance3D.ShadowCastingSetting) -> MeshInstance3D:
	var node: MeshInstance3D
	if use_node_pool and not _mesh_pool.is_empty():
		node = _mesh_pool.pop_back()
		pool_stats.reused += 1
	else:
		node = MeshInstance3D.new()
		add_child(node)
		pool_stats.created += 1
	node.mesh = mesh
	node.material_override = mat
	node.cast_shadow = shadow_mode
	node.visible = true
	return node


func _release_mesh_node(node: MeshInstance3D) -> void:
	if not is_instance_valid(node):
		return
	node.visible = false
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
	node.mesh = null
	node.material_override = null
	if use_node_pool and _mesh_pool.size() < MESH_POOL_LIMIT:
		_mesh_pool.append(node)
		pool_stats.pooled += 1
	else:
		node.queue_free()


## Far crown proxies join a terrain tile once their worker has finished; the tile itself never waits for them.
## allow — общий бюджет кадра разрешает публикацию; true в ответе — кадр занят передачей крон.
func _attach_crowns(p: Vector2, allow: bool) -> bool:
	var closest := INF
	var next: Variant = null
	var next_batches: Variant = null
	for key: Vector2i in _crown_wait.keys():
		var work: Dictionary = _crown_wait[key]
		if not is_instance_valid(work.node) or nodes.get(key) != work.node:
			_crown_wait.erase(key)
			continue
		var distance := distance_to_chunk(key, p)
		if distance > FarForest.far_end + SIDE:
			continue
		var crowns: Variant = null
		if not work.has("cells"):
			crowns = source.crowns(key)
			if crowns == null:
				source.request_crowns(key)
				continue
		if allow and distance < closest:
			closest = distance
			next = key
			next_batches = crowns
	if next == null:
		return false
	var work: Dictionary = _crown_wait[next]
	if next_batches != null:
		work.cells = FarForest.attachment_cells(next_batches, p)
	if work.cells.is_empty():
		_crown_wait.erase(next)
		return false
	var born: float = crown_clock.clock if crown_clock != null else 0.0
	FarForest.attach_cell(work.node, work.cells.pop_back(), Vector2.ZERO, false, born)
	stream_stats.crown_cells += 1
	if work.cells.is_empty():
		_crown_wait.erase(next)
	return true


func _material_for(key: Vector2i, p: Vector2) -> Material:
	if morph_lod != null:
		return morph_lod.material_for(far_material as ShaderMaterial if distance_to_chunk(key, p) >= FAR_FROM else null)
	return far_material if far_material != null and distance_to_chunk(key, p) >= FAR_FROM else material


func distance_to_chunk(key: Vector2i, p: Vector2) -> float:
	var corner := Vector2(key) * SIDE + Vector2.ONE * GameConfig.TILE * 0.5
	var last := corner + Vector2.ONE * SIDE
	if morph_lod != null:
		last = last.min((Vector2(_world.W, _world.H) - Vector2.ONE * 0.5) * GameConfig.TILE)
	return p.distance_to(p.clamp(corner, last))


func arrival_ready(p: Vector2, radius: float) -> bool:
	return p.distance_to(checked_at) < RECHECK and not _has_near_pending(p, radius) \
		and (relief_detail == null or relief_detail.ready_at(p, radius))


func _has_near_pending(p: Vector2, radius: float) -> bool:
	# The arrival queue has no look-ahead and is ordered by distance.
	return not pending.is_empty() and distance_to_chunk(pending.back(), p) <= radius


## force — старт: части ближе near передаются сразу, остальные ждут очереди.
## Иначе не больше одной передачи на GPU за кадр. true означает, что этот кадр уже занят передачей геометрии.
func update(x: float, z: float, force := false, allow_apply := true, near := INF) -> bool:
	var p := Vector2(x, z)
	if force:
		_lod_at = Vector2.INF
	if morph_lod != null and morph_lod.follow(p):
		# A stationary arrival can still need the next finer level after recovery.
		_lod_at = Vector2.INF
	if relief_detail != null:
		relief_detail.follow(p, force, AHEAD, LOD_RECHECK)
	if not force and frame_budget != null and not frame_budget.allows_work():
		return false
	_poll_lod()
	var uploaded := false
	if _read_task != -1 and WorkerThreadPool.is_task_completed(_read_task):
		WorkerThreadPool.wait_for_task_completion(_read_task)
		_read_task = -1
		if not _cpu.put(_read_key, _read_out.arrays):
			_uncached_key = _read_key
			_uncached_arrays = _read_out.arrays
		_read_out = {}
	var due := force or p.distance_to(checked_at) >= RECHECK
	if due and not force and _recheck_frame == Engine.get_process_frames() and p.distance_to(checked_at) < RECHECK * 2.0:
		due = false # в этом кадре очередь уже пересчитал другой слой; отложить на кадр
	if due:
		if not force: _recheck_frame = Engine.get_process_frames()
		# последние RECHECK метров пути задают направление: очередь берёт сначала части впереди
		var ahead := p if force or checked_at == Vector2.INF else p + (p - checked_at).normalized() * AHEAD
		checked_at = p
		if force or near == INF:
			_evict_pending.clear()
			for key: Vector2i in nodes:
				if distance_to_chunk(key, p) > DROP:
					_evict_pending.append(key)
		# Ключ сортировки — один раз на часть (раньше четыре расстояния в каждом сравнении); порядок тот же.
		var keyed: Array = []
		for key: Vector2i in chunks:
			if not nodes.has(key):
				var near_d := distance_to_chunk(key, p)
				if near_d <= RADIUS:
					keyed.append([near_d + distance_to_chunk(key, ahead), key])
		keyed.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
		pending.clear()
		for item: Array in keyed:
			pending.append(item[1])
	if source != null:
		if due:
			var requested: Array[Vector2i] = pending if force or near == INF else pending.filter(func(key: Vector2i) -> bool:
				return distance_to_chunk(key, p) <= near)
			if morph_lod != null:
				requested = requested.duplicate()
				for key: Vector2i in nodes:
					if morph_lod.wants_full(key, distance_to_chunk(key, p), _node_lod[key]):
						requested.append(key)
			source.retain_layer(water_layer, requested)
		for offset in mini(3, pending.size()):
			var at: Vector2i = pending[pending.size() - 1 - offset]
			if not force and near < INF and distance_to_chunk(at, p) > near: break
			# Preserve the consumer's order, including look-ahead and equal-distance ties.
			source.request(water_layer, at, distance_to_chunk(at, p) + offset * (RADIUS + SIDE))
		source.poll()
	if not force and allow_apply and relief_detail != null and (frame_budget == null or frame_budget.allows_work()):
		uploaded = relief_detail.step(p, false)
	while _has_near_pending(p, near) and (force or allow_apply and not uploaded):
		if not force and frame_budget != null and not frame_budget.allows_work(): break
		var key: Vector2i = pending.back()
		var wanted_lod := _desired_lod(key, p, 0, true) if _lod_enabled() else 0
		var arrays: Variant = null
		var used_lod := 0
		if wanted_lod > 0:
			var lod_arrays: Variant = _lod_arrays(key, wanted_lod, force)
			if lod_arrays == null:
				break
			if not lod_arrays.is_empty():
				arrays = lod_arrays
				used_lod = wanted_lod
		if arrays == null:
			arrays = _arrays(key)
		if arrays == null:
			if source != null:
				source.request(water_layer, key, distance_to_chunk(key, p))
				break
			elif force:
				arrays = _read_arrays(key)
				_cpu.put(key, arrays)
			else:
				if _read_task == -1:
					_read_key = key
					_read_out = {}
					var out := _read_out
					_read_task = WorkerThreadPool.add_task(func() -> void: out.arrays = _read_arrays(key), false, "Чанк рельефа")
				break
		if not force and frame_budget != null and not frame_budget.allows_work(): break
		pending.pop_back()
		var started := Time.get_ticks_usec()
		var mesh := _terrain_mesh(key, arrays)
		var shadow_mode := GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED if water_layer < 0 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var node := _acquire_mesh_node(mesh, _material_for(key, p), shadow_mode)
		if morph_lod != null:
			morph_lod.configure(node, key, used_lod)
		if _lod_handoff.get("key") == Vector3i(key.x, key.y, wanted_lod):
			_clear_lod_handoff()
		if water_layer < 0 and _world != null:
			if source == null: FarForest.attach(node, FarForest.plan(_world, _heights, key))
			else: _crown_wait[key] = {node = node}
		nodes[key] = node
		_node_lod[key] = used_lod
		if used_lod == 0:
			if source != null: source.uploaded(water_layer, key, arrays, (Time.get_ticks_usec() - started) / 1000.0)
			if _uncached_key == key:
				_uncached_key = null
				_uncached_arrays = []
		uploaded = true
	if force and allow_apply and relief_detail != null:
		if _lod_enabled():
			while _step_lod(p, minf(near, relief_detail.enter_m), true):
				pass
		relief_detail.follow(p, true, AHEAD, LOD_RECHECK)
		while relief_detail.step(p, true):
			uploaded = true
	if (force or near == INF) and far_material != null and (force or p.distance_to(_far_at) >= FAR_RECHECK):
		_far_at = p
		for key: Vector2i in nodes:
			var wanted := _material_for(key, p)
			if nodes[key].material_override != wanted:
				nodes[key].material_override = wanted
	if (near == INF or relief_detail != null) and allow_apply and not uploaded and _lod_enabled() and p.distance_to(_lod_at) >= LOD_RECHECK and (frame_budget == null or frame_budget.allows_work()):
		if _step_lod(p, near, force):
			uploaded = true
	# Кроны — после рельефа: только в кадре без передачи чанка и в пределах общего бюджета.
	if (force or near == INF) and _attach_crowns(p, allow_apply and not uploaded and (frame_budget == null or frame_budget.allows_work())):
		uploaded = true
	if near == INF and allow_apply and not uploaded and not _evict_pending.is_empty() and (frame_budget == null or frame_budget.allows_work()):
		var key: Vector2i = _evict_pending.pop_back()
		if nodes.has(key) and distance_to_chunk(key, p) > DROP:
			if relief_detail != null:
				relief_detail.forget(key)
			if morph_lod != null:
				morph_lod.forget(key)
			_release_mesh_node(nodes[key])
			nodes.erase(key)
			_node_lod.erase(key)
			_crown_wait.erase(key)
			uploaded = true
	return uploaded
