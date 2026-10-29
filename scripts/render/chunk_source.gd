extends RefCounted
## One read queue for terrain AND both water layers; main thread polls, workers only produce arrays.
const MAX_ACTIVE := 2
const MAX_QUEUED := 6
const READ_BYTES := 32 * 1024 * 1024
const LRU := preload("res://scripts/core/byte_lru.gd")
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
var _pins: Array[String] = []
var _base: Heightfield
var _base_lock := Mutex.new()
var _stats_lock := Mutex.new()
var stats := {reads = 0, repairs = 0, rebuilt_cells = 0, read_ms = 0.0, upload_bytes = 0, upload_ms = 0.0, max_upload_ms = 0.0, peak_reads = 0}
var closed := false

func setup(owner: WorldCache, w: WorldData, h: Heightfield, start_size: int, prepared: Array, budget: RefCounted) -> void:
	cache = owner
	world = w
	heights = h
	size = start_size
	groups = prepared
	_cpu.limit = 128 * 1024 * 1024
	_cpu.budget = budget
	for group: Dictionary in groups:
		for ref: Variant in group.values():
			if ref is Dictionary and ref.get("file", "") != "": _pins.append(cache.dir.path_join(ref.file))
	WorldCache.pin_files(_pins)

func _id(layer: int, key: Vector2i) -> Vector3i:
	return Vector3i(key.x, key.y, layer + 1)

func ready(layer: int, key: Vector2i) -> Variant:
	var id := _id(layer, key)
	return _startup[id] if _startup.has(id) else _cpu.get_value(id)

func read(layer: int, key: Vector2i) -> Array:
	var started := Time.get_ticks_usec()
	var ref: Variant = groups[layer + 1][key]
	var arrays: Array = []
	var repaired := false
	if ref is Array:
		arrays = ref
	else:
		var data: Variant = cache._read(cache.dir.path_join(ref.file), ref.key) if ref.get("file", "") != "" else null
		if data is Dictionary and preload("res://scripts/game/surface_snapshot.gd").mesh_valid(data.get("arrays"), false):
			arrays = data.arrays
		else:
			repaired = true
			if layer < 0: arrays = TerrainBuilder.build_chunk(world, heights, key)
			else:
				_base_lock.lock()
				if _base == null:
					_base = preload("res://scripts/game/surface_snapshot.gd").restore(world, cache.load_artifact(world.seed_text, size, "base"), "base")
					if _base == null: _base = Heightfield.new(world, false)
				var base := _base
				_base_lock.unlock()
				arrays = WaterBuilder.build_chunk(world, base, key, layer)
			if ref.get("file", "") != "": cache._write(cache.dir.path_join(ref.file), ref.key, var_to_bytes({arrays = arrays}))
	_stats_lock.lock()
	stats.reads += 1
	stats.repairs += int(repaired)
	if repaired: stats.rebuilt_cells += mini(world.N, (PlanTerrain.CELLS + 2) * (PlanTerrain.CELLS + 2))
	stats.read_ms += (Time.get_ticks_usec() - started) / 1000.0
	_stats_lock.unlock()
	return arrays

## Executed by WorldLoader/travel worker before scene publication; these arrays are pinned until upload.
func prewarm(points: Array, radius: float) -> void:
	for group in groups.size():
		var keys: Array = groups[group].keys()
		keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _distance(a, points[0]) < _distance(b, points[0]))
		for key: Vector2i in keys:
			var needed := false
			for p: Vector2 in points: needed = needed or _distance(key, p) <= radius
			var id := _id(group - 1, key)
			if not needed or _startup.has(id): continue
			var arrays := read(group - 1, key)
			var bytes := LRU.size_of(arrays)
			_startup[id] = arrays
			_startup_bytes += bytes
			if _cpu.budget != null: _cpu.budget.reserve(bytes)

static func _distance(key: Vector2i, point: Vector2) -> float:
	var corner := Vector2(key) * PlanTerrain.SIDE + Vector2.ONE * GameConfig.TILE * 0.5
	return point.distance_to(point.clamp(corner, corner + Vector2.ONE * PlanTerrain.SIDE))

func uploaded(layer: int, key: Vector2i, arrays: Array, elapsed: float) -> void:
	var id := _id(layer, key)
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
			_cpu.put(_id(group - 1, key), arrays)
			groups[group][key] = {file = "", key = "", bytes = LRU.size_of(arrays)}

func request(layer: int, key: Vector2i, priority: float) -> void:
	if closed: return
	var id := _id(layer, key)
	if _startup.has(id) or _cpu.get_value(id) != null or _active.has(id): return
	for item: Dictionary in _queue:
		if item.id == id:
			item.priority = priority
			return
	var ref: Variant = groups[layer + 1][key]
	var bytes: int = ref.get("bytes", 8 * 1024 * 1024) if ref is Dictionary else LRU.size_of(ref)
	_queue.append({id = id, layer = layer, key = key, bytes = bytes, priority = priority})
	_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.priority < b.priority)
	if _queue.size() > MAX_QUEUED: _queue.pop_back()

func poll() -> void:
	for id: Vector3i in _active.keys():
		var item: Dictionary = _active[id]
		if not WorkerThreadPool.is_task_completed(item.task): continue
		WorkerThreadPool.wait_for_task_completion(item.task)
		_reserved -= item.bytes
		if _cpu.budget != null: _cpu.budget.release(item.bytes)
		if not _cpu.put(id, item.out.arrays):
			_startup[id] = item.out.arrays
			var bytes := LRU.size_of(item.out.arrays)
			_startup_bytes += bytes
			if _cpu.budget != null: _cpu.budget.reserve(bytes)
		_active.erase(id)
	while _active.size() < MAX_ACTIVE and not _queue.is_empty():
		var item: Dictionary = _queue[0]
		if _reserved + item.bytes > READ_BYTES and not _active.is_empty(): break
		_queue.pop_front()
		var out := {}
		item.out = out
		_reserved += item.bytes
		if _cpu.budget != null: _cpu.budget.reserve(item.bytes)
		item.task = WorkerThreadPool.add_task(func() -> void: out.arrays = read(item.layer, item.key), false, "Чтение чанка")
		_active[item.id] = item
		_stats_lock.lock()
		stats.peak_reads = maxi(stats.peak_reads, _active.size())
		_stats_lock.unlock()

func finish() -> void:
	_queue.clear()
	for item: Dictionary in _active.values():
		WorkerThreadPool.wait_for_task_completion(item.task)
		if _cpu.budget != null: _cpu.budget.release(item.bytes)
	_active.clear()
	_reserved = 0

func close() -> void:
	if closed: return
	finish()
	closed = true
	if _cpu.budget != null: _cpu.budget.release(_startup_bytes)
	_startup.clear()
	_startup_bytes = 0
	_cpu.clear()
	_release_pins()

func _release_pins() -> void:
	if _pins.is_empty(): return
	WorldCache.unpin_files(_pins)
	_pins.clear()
	cache.request_collection(world.seed_text, size)

func _notification(what: int) -> void:
	# A RefCounted script cannot call an instance method on itself at zero references.
	if what != NOTIFICATION_PREDELETE: return
	if not closed and _cpu.budget != null: _cpu.budget.release(_startup_bytes)
	if not _pins.is_empty():
		WorldCache.unpin_files(_pins)
		cache.request_collection(world.seed_text, size)
