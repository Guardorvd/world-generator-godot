extends RefCounted
## One read queue for terrain AND both water layers; main thread polls, workers only produce arrays.
const MAX_ACTIVE := 2
const MAX_QUEUED := 6
const MAX_CROWN_TASKS := 2
const READ_BYTES := 32 * 1024 * 1024
const LRU := preload("res://scripts/core/byte_lru.gd")
const FarForest := preload("res://scripts/render/distant_forest.gd")
const DETAIL_LAYER := -2
var _far_cpu := LRU.new()
var _fine_cpu := LRU.new()
var _fine_reserved := 0
var _far_lock := Mutex.new()
var _far_tasks := {}
var cache: WorldCache
var world: WorldData
var heights: Heightfield
var size := 0
var groups: Array = []
var _cpu := LRU.new()
var _queue: Array[Dictionary] = []
var _active := {}
var _reserved := 0
var _startup := {}
var _startup_bytes := 0
var _wanted := {}
var _handoff := {} # At most MAX_ACTIVE uncached results awaiting upload, never startup pins.
var _handoff_bytes := 0
var _pins: Array[String] = []
var _persisted_refs: Array = []
var _stats_lock := Mutex.new()
var stats := {reads = 0, repairs = 0, pending_hits = 0, rebuilt_cells = 0, read_ms = 0.0, upload_bytes = 0, upload_ms = 0.0, max_upload_ms = 0.0, peak_reads = 0}
var closed := false

func setup(owner: WorldCache, w: WorldData, h: Heightfield, start_size: int, prepared: Array, budget: RefCounted) -> void:
	cache = owner
	world = w
	heights = h
	size = start_size
	groups = prepared
	_far_cpu.limit = 16 * 1024 * 1024
	_cpu.limit = 128 * 1024 * 1024
	_cpu.budget = budget
	if h.fine_relief != null:
		_fine_cpu.limit = h.fine_profile.mesh_mib * h.fine_profile.MIB
		_fine_cpu.budget = budget
		if budget != null:
			budget.register_owner(_fine_cpu._owner_id, "terrain_detail")
			_fine_reserved = h.fine_profile.tile_mib * h.fine_profile.MIB
			budget.reserve(_fine_reserved)
	for group: Dictionary in groups:
		for ref: Variant in group.values():
			if ref is Dictionary and ref.get("file", "") != "": _pins.append(cache.dir.path_join(ref.file))
	WorldCache.pin_files(_pins)

func _id(layer: int, key: Vector2i) -> Vector3i:
	return Vector3i(key.x, key.y, layer + 1)

func _cache_for(id: Vector3i) -> RefCounted:
	return _fine_cpu if id.z == DETAIL_LAYER + 1 else _cpu

## Cold startup consumes prepared RAM immediately while the FIFO writer persists far blocks.
func set_persisted_refs(refs: Array) -> void:
	_persisted_refs = refs
	var paths: Array[String] = []
	for group: Dictionary in refs:
		for ref: Dictionary in group.values(): paths.append(cache.dir.path_join(ref.file))
	WorldCache.pin_files(paths)
	_pins.append_array(paths)

func ready(layer: int, key: Vector2i) -> Variant:
	var id := _id(layer, key)
	if _handoff.has(id): return _handoff[id]
	return _startup[id] if _startup.has(id) else _cache_for(id).get_value(id)

## Far crown proxies of a terrain tile; null until computed. Never gates the terrain itself.
func crowns(key: Vector2i) -> Variant:
	_far_lock.lock()
	var value: Variant = _far_cpu.get_value(key)
	_far_lock.unlock()
	return value

## Рельеф, пришедший без крон, получает их в фоновой задаче после публикации.
func request_crowns(key: Vector2i) -> void:
	if closed or _far_tasks.size() >= MAX_CROWN_TASKS or _far_tasks.has(key) or crowns(key) != null: return
	_far_tasks[key] = WorkerThreadPool.add_task(func() -> void: _make_crowns(key), false, "Далёкий лес")

func _make_crowns(key: Vector2i) -> void:
	var batches := FarForest.plan(world, heights, key)
	_far_lock.lock()
	_far_cpu.put(key, batches)
	_far_lock.unlock()

## Each layer replaces its pending demand before polling, including after turns/teleports.
func retain_layer(layer: int, keys: Array[Vector2i]) -> void:
	var wanted := {}
	for key in keys:
		var id := _id(layer, key)
		wanted[id] = _wanted.get(id, INF)
	for id: Vector3i in _wanted.keys():
		if id.z == layer + 1 and not wanted.has(id): _wanted.erase(id)
	_wanted.merge(wanted)
	_queue = _queue.filter(func(item: Dictionary) -> bool: return _wanted.has(item.id))
	for id: Vector3i in _handoff.keys():
		if not _wanted.has(id): _release_handoff(id)

func _release_handoff(id: Vector3i) -> void:
	if not _handoff.has(id): return
	var bytes := LRU.size_of(_handoff[id])
	_handoff.erase(id)
	_handoff_bytes -= bytes
	if _cpu.budget != null: _cpu.budget.release(bytes)

func read(layer: int, key: Vector2i) -> Array:
	var started := Time.get_ticks_usec()
	var ref: Variant = groups[layer + 1][key]
	var arrays: Array = []
	var repaired := false
	var pending: Variant = cache.writing_chunk(ref.get("file", "")) if ref is Dictionary else null
	if ref is Array:
		arrays = ref
	elif pending is Array:
		arrays = pending # Avoid a rebuild/competing repair write while cold persistence is in flight.
	else:
		var data: Variant = cache._read(cache.dir.path_join(ref.file), ref.key) if ref.get("file", "") != "" else null
		if data is Dictionary and preload("res://scripts/game/surface_snapshot.gd").mesh_valid(data.get("arrays"), false):
			arrays = data.arrays
		else:
			repaired = true
			if layer < 0: arrays = TerrainBuilder.build_chunk(world, heights, key)
			else:
				arrays = WaterBuilder.build_chunk(world, heights, key, layer)
			if ref.get("file", "") != "": cache._write(cache.dir.path_join(ref.file), ref.key, var_to_bytes({arrays = arrays}))
	if layer < 0 and heights.fine_medium and not arrays.is_empty():
		arrays = heights.fine_relief.ProjectCoarseMesh(arrays)
	if layer < 0 and heights.fine_lod and not arrays.is_empty():
		arrays = heights.fine_relief.DecorateFullLod(key.x, key.y, arrays)
	_stats_lock.lock()
	stats.reads += 1
	stats.repairs += int(repaired)
	stats.pending_hits += int(pending is Array)
	if repaired: stats.rebuilt_cells += mini(world.N, (PlanTerrain.CELLS + 2) * (PlanTerrain.CELLS + 2))
	stats.read_ms += (Time.get_ticks_usec() - started) / 1000.0
	_stats_lock.unlock()
	return arrays


func read_detail(key: Vector2i, coarse: Array) -> Array:
	if heights.fine_relief == null:
		return []
	var arrays := coarse if not coarse.is_empty() else read(-1, key)
	if arrays.is_empty():
		return []
	return heights.fine_relief.BuildMeshes(key.x, key.y, roundi(heights.fine_profile.piece_m / GameConfig.TILE), arrays)


## Called on the loading worker before the first force_terrain. Later builds go through the shared read queue.
func prewarm_detail(points: PackedVector2Array, radius: float) -> void:
	if heights.fine_relief == null or points.is_empty():
		return
	heights.fine_relief.Warm(points, radius)
	var nearby: Array[Vector2i] = []
	for key: Vector2i in groups[0]:
		for p: Vector2 in points:
			if _distance(key, p) <= radius:
				nearby.append(key)
				break
	nearby.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _distance(a, points[0]) > _distance(b, points[0]))
	var ready_coarse := {}
	for key: Vector2i in nearby:
		var value: Variant = ready(-1, key)
		if value is Array:
			ready_coarse[key] = value
	var pieces := Parallel.bands(nearby.size(), func(a: int, b: int) -> Array:
		var batch := []
		for i in range(a, b):
			var key := nearby[i]
			batch.append(read_detail(key, ready_coarse.get(key, [])))
		return batch, 1)
	var i := 0
	for batch: Array in pieces:
		for arrays: Array in batch:
			_fine_cpu.put(_id(DETAIL_LAYER, nearby[i]), arrays)
			i += 1

## Executed by WorldLoader/travel worker before scene publication; these arrays are pinned until upload.
func prewarm(points: Array, radius: float) -> void:
	var missing: Array[Vector3i] = []
	for group in groups.size():
		for key: Vector2i in groups[group]:
			var needed := false
			for p: Vector2 in points:
				if _distance(key, p) <= radius:
					needed = true
					break
			var id := _id(group - 1, key)
			if not needed or _startup.has(id): continue
			# Сначала закрепить ВСЕ попадания в RAM: чтение отсутствующего блока может
			# вытеснить нужную воду/землю из другого слоя до её очереди.
			var cached: Variant = _cpu.get_value(id)
			if cached == null:
				missing.append(id)
			else:
				_cpu.erase(id)
				_pin(id, cached)
	for id: Vector3i in missing:
		_pin(id, read(id.z - 1, Vector2i(id.x, id.y)))

func _pin(id: Vector3i, arrays: Array) -> void:
	var bytes := LRU.size_of(arrays)
	_startup[id] = arrays
	_startup_bytes += bytes
	if _cpu.budget != null: _cpu.budget.reserve(bytes)

static func _distance(key: Vector2i, point: Vector2) -> float:
	var corner := Vector2(key) * PlanTerrain.SIDE + Vector2.ONE * GameConfig.TILE * 0.5
	return point.distance_to(point.clamp(corner, corner + Vector2.ONE * PlanTerrain.SIDE))

func uploaded(layer: int, key: Vector2i, arrays: Array, elapsed: float) -> void:
	var id := _id(layer, key)
	_release_handoff(id)
	_wanted.erase(id)
	var bytes := LRU.size_of(arrays)
	if _startup.has(id):
		_startup.erase(id)
		_startup_bytes -= bytes
		if _cpu.budget != null: _cpu.budget.release(bytes)
	_cpu.put(id, arrays)
	_stats_lock.lock()
	stats.upload_bytes += bytes
	stats.upload_ms += elapsed
	stats.max_upload_ms = maxf(stats.max_upload_ms, elapsed)
	_stats_lock.unlock()

func snapshot() -> Dictionary:
	_stats_lock.lock()
	var result := stats.duplicate(true)
	_stats_lock.unlock()
	result.queued = _queue.size()
	result.active = _active.size()
	result.startup_bytes = _startup_bytes
	result.handoff_bytes = _handoff_bytes
	result.handoff_count = _handoff.size()
	return result

func finish_startup() -> void:
	for id: Vector3i in _startup:
		var arrays: Array = _startup[id]
		var bytes := LRU.size_of(arrays)
		if _cpu.budget != null: _cpu.budget.release(bytes)
		_cpu.put(id, arrays)
	_startup.clear()
	_startup_bytes = 0
	# Cold callers also switch to recipes/references; the full set of arrays no longer bypasses LRU.
	for group in groups.size():
		for key: Vector2i in groups[group].keys():
			var arrays: Variant = groups[group][key]
			if not arrays is Array: continue
			# These are raw disk-cache arrays. The terrain reader projects them onto C on demand.
			if group != 0 or not (heights.fine_medium or heights.fine_lod):
				_cpu.put(_id(group - 1, key), arrays)
			groups[group][key] = _persisted_refs[group][key] if not _persisted_refs.is_empty() else {file = "", key = "", bytes = LRU.size_of(arrays)}
	_persisted_refs = []

func request(layer: int, key: Vector2i, priority: float) -> void:
	if closed: return
	var id := _id(layer, key)
	_wanted[id] = priority
	if _startup.has(id) or _handoff.has(id) or _cache_for(id).get_value(id) != null or _active.has(id): return
	var queued := false
	for item: Dictionary in _queue:
		if item.id == id:
			item.priority = priority
			queued = true
			break
	if not queued:
		var ref: Variant = groups[maxi(layer + 1, 0)][key]
		var bytes: int = ref.get("bytes", 8 * 1024 * 1024) if ref is Dictionary else LRU.size_of(ref)
		if layer == DETAIL_LAYER:
			# Even if every original triangle is split into four, this bounds the in-flight data.
			bytes *= 4
		_queue.append({id = id, layer = layer, key = key, bytes = bytes, priority = priority})
	_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.priority < b.priority)
	if _queue.size() > MAX_QUEUED: _queue.pop_back()

func poll() -> void:
	for key: Vector2i in _far_tasks.keys():
		if WorkerThreadPool.is_task_completed(_far_tasks[key]):
			WorkerThreadPool.wait_for_task_completion(_far_tasks[key])
			_far_tasks.erase(key)
	for id: Vector3i in _active.keys():
		var item: Dictionary = _active[id]
		if not WorkerThreadPool.is_task_completed(item.task): continue
		WorkerThreadPool.wait_for_task_completion(item.task)
		_reserved -= item.bytes
		if _cpu.budget != null: _cpu.budget.release(item.bytes)
		if _wanted.has(id) and not _cache_for(id).put(id, item.out.arrays):
			var bytes := LRU.size_of(item.out.arrays)
			_handoff[id] = item.out.arrays
			_handoff_bytes += bytes
			if _cpu.budget != null: _cpu.budget.reserve(bytes)
		_active.erase(id)
	# A turn can make the queue head more urgent than both held oversized results.
	# Retaining those forever would block the read needed by PlanTerrain.pending.back().
	if _active.size() + _handoff.size() >= MAX_ACTIVE and not _handoff.is_empty() and not _queue.is_empty():
		var farthest: Vector3i = _handoff.keys()[0]
		for id: Vector3i in _handoff:
			if _wanted.get(id, INF) > _wanted.get(farthest, INF): farthest = id
		if _queue[0].priority < _wanted.get(farthest, INF): _release_handoff(farthest)
	while _active.size() + _handoff.size() < MAX_ACTIVE and not _queue.is_empty():
		var item: Dictionary = _queue[0]
		if _reserved + item.bytes > READ_BYTES and not _active.is_empty(): break
		_queue.pop_front()
		var out := {}
		item.out = out
		_reserved += item.bytes
		if _cpu.budget != null: _cpu.budget.reserve(item.bytes)
		if item.layer == DETAIL_LAYER:
			var coarse: Variant = ready(-1, item.key)
			item.task = WorkerThreadPool.add_task(func() -> void:
				out.arrays = read_detail(item.key, coarse if coarse is Array else []), false, "Точный рельеф")
		else:
			item.task = WorkerThreadPool.add_task(func() -> void: out.arrays = read(item.layer, item.key), false, "Чтение чанка")
		_active[item.id] = item
		_stats_lock.lock()
		stats.peak_reads = maxi(stats.peak_reads, _active.size())
		_stats_lock.unlock()

func finish() -> void:
	for task: int in _far_tasks.values(): WorkerThreadPool.wait_for_task_completion(task)
	_far_tasks.clear()
	_queue.clear()
	_wanted.clear()
	for item: Dictionary in _active.values():
		WorkerThreadPool.wait_for_task_completion(item.task)
		if _cpu.budget != null: _cpu.budget.release(item.bytes)
	_active.clear()
	_reserved = 0
	for id: Vector3i in _handoff.keys(): _release_handoff(id)

func close() -> void:
	if closed: return
	finish()
	closed = true
	if _cpu.budget != null: _cpu.budget.release(_startup_bytes)
	_startup.clear()
	_startup_bytes = 0
	_cpu.clear()
	_fine_cpu.clear()
	if _cpu.budget != null: _cpu.budget.release(_fine_reserved)
	_fine_reserved = 0
	_far_cpu.clear()
	_release_pins()

func _release_pins() -> void:
	if _pins.is_empty(): return
	WorldCache.unpin_files(_pins)
	_pins.clear()
	cache.request_collection(world.seed_text, size)

func _notification(what: int) -> void:
	# A RefCounted script cannot call an instance method on itself at zero references.
	if what != NOTIFICATION_PREDELETE: return
	if not closed and _cpu.budget != null: _cpu.budget.release(_startup_bytes + _handoff_bytes + _fine_reserved)
	if not _pins.is_empty():
		WorldCache.unpin_files(_pins)
		cache.request_collection(world.seed_text, size)
