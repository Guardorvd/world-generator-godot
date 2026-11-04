extends SceneTree
const F = preload("res://tools/trail_lab_fixture.gd")
var failures := 0
class FixtureCache extends WorldCache:
	var fixture: WorldData
	var gate := Semaphore.new()
	func generate(_seed: String, _size: int, _progress := Callable(), _after_climate := Callable()) -> Dictionary:
		return {world = fixture, layers = WorldGenerator.LAYERS.size()}
	func save_surface(seed_text: String, size: int, data: Dictionary, chunks: Dictionary, water_chunks: Array = [{}, {}], planned_refs := {}) -> Dictionary:
		_queue_job(func() -> void: gate.wait())
		return super.save_surface(seed_text, size, data, chunks, water_chunks, planned_refs)
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)
func run() -> void:
	var prepared := F.prepare(F.definitions())
	var w: WorldData = prepared.heights.world
	w.trail_plan = {version = StageTrailPlan.VERSION, state = "none"}
	for name: String in WorldGenerator.NOISE_SLOTS: w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	var cache := FixtureCache.new()
	cache.fixture = w
	cache.enabled = true
	cache.dir = "res://.godot/cold_async_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var services := ServiceScope.new()
	services.cache = cache
	cache.cpu_budget = services.cpu_budget
	var loaded := WorldLoader.load_world(w.seed_text, w.W, Callable(), services)
	check(loaded.error.is_empty() and loaded.chunk_source != null and cache._pending_jobs > 0,
		"production loader returns prewarmed geometry while its surface writer is blocked")
	if loaded.chunk_source != null:
		loaded.chunk_source.finish_startup()
		check(loaded.chunk_source.groups[0].values()[0] is Dictionary and not cache._writing_chunks.is_empty(),
			"cold startup adopts future file addresses before persistence completes")
	cache.gate.post()
	cache.wait_writes()
	check(not cache.load_artifact(w.seed_text, w.W, "surface").is_empty(), "background persistence eventually commits the complete surface manifest")
	if loaded.chunk_source != null: loaded.chunk_source.close()
	cache.wait_writes()
	check(services.cpu_budget.snapshot().reserved_bytes == 0, "cold loader and background writer release memory reservations")
	for name: String in DirAccess.get_files_at(cache.dir): DirAccess.remove_absolute(cache.dir.path_join(name))
	DirAccess.remove_absolute(cache.dir)
	print("cold_cache_async: ", failures, " failures")
	quit(1 if failures else 0)
