extends SceneTree
const Network = preload("res://scripts/trails/trail_world_network.gd")
const Source = preload("res://scripts/render/chunk_source.gd")
var failures := 0
class SlowFree extends Node:
	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE: OS.delay_usec(1000)
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)
func run() -> void:
	_test_pruning()
	_test_async_blocks()
	var vegetation := VegetationLayer.new()
	for i in 8: vegetation._trash.append(SlowFree.new())
	vegetation._free_trash(1)
	check(vegetation._trash.size() == 7, "one expensive retired node cannot force seven more deletions past the frame budget")
	vegetation._free_trash(0)
	check(vegetation._trash.is_empty(), "forced cleanup still releases every retired node")
	vegetation.free()
	print("optimization_contract: ", failures, " failures")
	quit(1 if failures else 0)
func _test_pruning() -> void:
	var input := TrailGenerationInput.new()
	input.size = Vector2i(64, 64)
	input.paths_soft = true
	for field in ["water", "rivers", "forbidden"]:
		var mask := PackedByteArray(); mask.resize(4096); input.set(field, mask)
	var region := Rect2i(0, 0, 64, 64)
	var start := Vector2(100, 100)
	input.water[25 * 64 + 25] = 1
	check(Network._start_blocked(input, region, start), "early pruning rejects a universally forbidden nominated start")
	input.water[25 * 64 + 25] = 0
	input.water[40 * 64 + 25] = 1
	check(not Network._start_blocked(input, region, start), "blocked middle or finish does not prune a valid detour or shorter leg")
	check(Network._start_blocked(input, region, Vector2(4, 4)), "nominated start outside construction bounds is rejected")
func _test_async_blocks() -> void:
	var cache := WorldCache.new()
	cache.dir = "res://.godot/async_blocks_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	cache.enabled = true
	var previous_pins := WorldCache._file_pins.size()
	var gate := Semaphore.new()
	cache._queue_job(func() -> void: gate.wait())
	var mesh := WaterBuilder._arrays(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD]), PackedInt32Array([0, 1, 2]))
	var pieces := {Vector2i.ZERO: mesh}
	var planned := {}
	var started := Time.get_ticks_usec()
	cache.save_surface("async", 8, {fixture = true}, pieces, [{}, {}], planned)
	check(Time.get_ticks_usec() - started < 1000000 and not FileAccess.file_exists(cache.artifact_path("async", 8, "surface")),
		"startup receives block addresses without waiting for a blocked writer or publishing a manifest")
	var w := WorldData.new(); w.W = 8; w.H = 8; w.N = 64; w.seed_text = "async"
	var source := Source.new()
	source.setup(cache, w, Heightfield.new(), 8, [pieces, {}, {}], null)
	source.set_persisted_refs([planned.chunks, planned.water_chunks[0], planned.water_chunks[1]])
	source.finish_startup()
	check(source.ready(-1, Vector2i.ZERO) == mesh and source.groups[0][Vector2i.ZERO] == planned.chunks[Vector2i.ZERO],
		"startup keeps ready RAM geometry while switching far chunks to immutable disk addresses")
	source._cpu.clear()
	check(source.read(-1, Vector2i.ZERO) == mesh and source.stats.pending_hits == 1 and source.stats.repairs == 0,
		"an evicted chunk still being written reads its reserved buffer without rebuilding or competing disk writes")
	gate.post()
	cache.wait_writes()
	check(cache.load_artifact("async", 8, "surface").get("fixture", false) and source.read(-1, Vector2i.ZERO) == mesh,
		"manifest commits after all blocks and the running source can read them exactly")
	source.close()
	cache.wait_writes()
	check(WorldCache._file_pins.size() == previous_pins, "closing the source releases every future-block pin")
	check(cache._writing_chunks.is_empty(), "completed persistence releases all pending buffer lookups")
	for name: String in DirAccess.get_files_at(cache.dir): DirAccess.remove_absolute(cache.dir.path_join(name))
	DirAccess.remove_absolute(cache.dir)
