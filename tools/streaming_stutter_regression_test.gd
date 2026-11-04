extends SceneTree
const Source := preload("res://scripts/render/chunk_source.gd")
const Budget := preload("res://scripts/core/cpu_cache_budget.gd")
const FrameBudget := preload("res://scripts/render/stream_frame_budget.gd")
var failures := 0
var checks := 0

class MemorySource extends Source:
	var gate: Semaphore
	func read(layer: int, key: Vector2i) -> Array:
		if gate != null: gate.wait()
		return groups[layer + 1][key]

class DelayedTerrain extends PlanTerrain:
	func _arrays(key: Vector2i) -> Variant:
		OS.delay_usec(3000)
		return super._arrays(key)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	failures += int(not ok)
	print("PASS " if ok else "FAIL ", label)

func run() -> void:
	await _test_cancellation()
	_test_pool_and_slices()
	_test_deadlines()
	print("streaming_stutter: ", checks, " checks, ", failures, " failures")
	quit(1 if failures else 0)

func wait_reads(source: RefCounted) -> void:
	for item: Dictionary in source._active.values():
		while not WorkerThreadPool.is_task_completed(item.task): await process_frame

func _test_cancellation() -> void:
	var arrays := WaterBuilder._arrays(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD]), PackedInt32Array([0, 1, 2]))
	var pieces := {}
	for i in 12: pieces[Vector2i(i, 0)] = arrays
	var budget := Budget.new()
	budget.limit = 1 # Every completed read must use bounded handoff, not the LRU.
	var source := MemorySource.new()
	source.setup(WorldCache.new(), WorldData.new(), Heightfield.new(), 8, [pieces, {}, {}], budget)
	for i in 12: source.request(-1, Vector2i(i, 0), i)
	source.poll()
	await wait_reads(source)
	source.poll()
	check(source._startup.is_empty() and source._handoff.size() == 2 and source._active.is_empty(), "rejected reads use two bounded handoff slots and never startup pins")
	check(source.ready(-1, Vector2i.ZERO) == arrays and budget.snapshot().reserved_bytes == source._handoff_bytes, "oversized ready chunk remains available and fully accounted until consumed")
	source.request(-1, Vector2i(10, 0), -1.0)
	source.poll()
	await wait_reads(source)
	source.poll()
	check(source.ready(-1, Vector2i(10, 0)) == arrays and source.ready(-1, Vector2i(1, 0)) == null and source._handoff.size() == 2,
		"a more urgent read replaces a held result so two oversized chunks cannot deadlock the queue head")
	source.uploaded(-1, Vector2i.ZERO, arrays, 0.0)
	check(source._handoff.size() == 1, "GPU consumption releases a rejected-cache handoff")
	source.retain_layer(-1, [])
	check(source._handoff.is_empty() and source._queue.is_empty() and budget.snapshot().reserved_bytes == 0, "turning away drops queued and ready results with all reservations")
	source.gate = Semaphore.new()
	source.request(-1, Vector2i(10, 0), 0.0)
	source.poll()
	source.retain_layer(-1, [])
	source.gate.post()
	await wait_reads(source)
	source.poll()
	check(source._handoff.is_empty() and source._active.is_empty() and budget.snapshot().reserved_bytes == 0, "read completing after cancellation is discarded without repinning")
	source.gate = null
	# Repeated sharp turns cannot accumulate rejected reads.
	for i in 12:
		source.request(-1, Vector2i(i, 0), 0.0)
		source.poll()
		await wait_reads(source)
		source.poll()
		source.retain_layer(-1, [])
	check(source._startup_bytes == 0 and source._handoff_bytes == 0 and budget.snapshot().reserved_bytes == 0, "repeated changes of direction do not grow pinned CPU memory")
	source.groups[1][Vector2i.ZERO] = arrays
	source.request(-1, Vector2i.ZERO, 0.0)
	source.request(0, Vector2i.ZERO, 0.0)
	source.poll()
	await wait_reads(source)
	source.poll()
	source.retain_layer(-1, [])
	check(source.ready(0, Vector2i.ZERO) == arrays and source.ready(-1, Vector2i.ZERO) == null and source._handoff.size() == 1,
		"cancelling terrain demand preserves water waiting for its own upload")
	source.close()
	check(budget.snapshot().reserved_bytes == 0 and budget.snapshot().retained_bytes == 0, "source close releases every CPU allocation")
	await process_frame

func _test_pool_and_slices() -> void:
	var layer := VegetationLayer.new()
	root.add_child(layer)
	layer.world = WorldData.new()
	var mesh := BoxMesh.new()
	mesh.set_meta("lod_meshes", [BoxMesh.new(), BoxMesh.new()])
	var mats := []
	for i in 3: mats.append(ShaderMaterial.new())
	layer._defs[0] = {trunk = mesh, crown = mesh, trunk_mats = mats, crown_mats = mats}
	var buf := PackedFloat32Array(); buf.resize(12)
	var cbuf := PackedFloat32Array(); cbuf.resize(16)
	var built := {chunk = Vector2i.ZERO, entries = [{kind = 0, count = 1, tbuf = buf, cbuf = cbuf, bounds = AABB(Vector3.ZERO, Vector3.ONE)}]}
	check(not layer._apply_chunk(built, 1, Time.get_ticks_usec() + 1000000) and layer.node_stats.created == 4,
		"one runtime tree slice creates at most four render nodes even with time to spare")
	check(layer._apply_chunk(built, 1, Time.get_ticks_usec() + 1000000) and layer.node_stats.created == 6,
		"resuming a partial chunk publishes its remaining LOD nodes exactly once")
	var node: MultiMeshInstance3D = layer.veg[Vector3i.ZERO].nodes[0]
	var id := node.get_instance_id()
	layer._trash_node(node)
	layer._free_trash(1000000)
	check(layer._tree_pool.size() == 1 and node.multimesh.instance_count == 0 and node.multimesh.mesh == null and node.material_override == null,
		"pooled node stays registered but releases per-chunk buffers and material")
	var reused := layer._multimesh(mesh, mats[0], 2, true, false, false, true)
	check(reused.get_instance_id() == id and layer.node_stats.reused == 1 and not reused.has_meta("stream_retiring") and reused.visible and reused.visibility_range_end == 0.0,
		"reusing a node resets visibility, fade, LOD range and shadow configuration")
	for i in layer.TREE_POOL_LIMIT + 5:
		layer._trash_node(layer._multimesh(mesh, mats[0], 1, false, true, false, true))
	layer._free_trash(1000000)
	check(layer._tree_pool.size() == layer.TREE_POOL_LIMIT and layer._trash.is_empty(), "pool has a hard node limit; excess retired nodes are freed")
	layer.free()

func _test_deadlines() -> void:
	var budget := FrameBudget.new()
	budget.deadline_usec = Time.get_ticks_usec() - 1
	var layer := VegetationLayer.new()
	layer.frame_budget = budget
	layer._present.assign([-1])
	layer._present_next(budget.deadline_usec)
	check(layer._present == [-1], "expired shared deadline cannot force the first detail upload")
	var built := {chunk = Vector2i.ZERO, entries = [{kind = 0}]}
	layer._defs[0] = {trunk = BoxMesh.new()}
	check(not layer._apply_chunk(built, 1, budget.deadline_usec) and layer.node_stats.created == 0, "expired tree deadline leaves a resumable chunk without creating a node")
	layer.world = WorldData.new()
	check(not layer.update(0.0, 0.0, false, 0.01) and layer._tree_task == -1 and layer._task == -1,
		"expired shared deadline also defers tree rechecks and new detail jobs")
	layer.free()
	var terrain := DelayedTerrain.new()
	root.add_child(terrain)
	terrain.frame_budget = budget
	terrain.chunks = {Vector2i.ZERO: WaterBuilder._arrays(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD]), PackedInt32Array([0, 1, 2]))}
	budget.deadline_usec = Time.get_ticks_usec() + 1000
	check(not terrain.update(0.0, 0.0) and terrain.nodes.is_empty() and terrain.pending.size() == 1,
		"terrain rechecks the common deadline after preparation and defers GPU publication")
	check(terrain.update(0.0, 0.0, true) and terrain.nodes.size() == 1, "forced spawn publication still bypasses runtime deadline")
	terrain.free()
	var scheduler := WorldStreamCoordinator.new()
	var flags := []
	scheduler.vegetation_budgeted = func(_x: float, _z: float, _force: bool, allow: bool) -> bool:
		flags.append(allow)
		OS.delay_usec(3000)
		return true
	scheduler.terrain_update = func(_x: float, _z: float, _force: bool, allow: bool) -> bool:
		flags.append(allow)
		return false
	scheduler.update(Vector3.ZERO)
	check(flags == [true, false] and scheduler.frame_budget.deadline_usec == 0, "an indivisible overrun denies later uploads and deadline ends with its frame")
