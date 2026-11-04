extends SceneTree
## Изолированная публикация рельефа, бюджет кадра и снимки поиска. Генерацию мира не запускает.
class SmallRouter extends TrailRouter:
	func _setup_grid() -> void:
		_w = 5 if request.width == 2 else 7
		_h = _w
		_cost = PackedFloat32Array()
		_cost.resize(_w * _h)
		_cost.fill(1.0)
		_cost[0] = INF

class QuietTerrain extends OuterTerrain:
	func _wanted(_x: float, _z: float, _radius := RADIUS) -> Array[Vector2i]:
		return []

class MemorySource extends "res://scripts/render/chunk_source.gd":
	func read(layer: int, key: Vector2i) -> Array:
		stats.reads += 1
		return groups[layer + 1][key]

var failures := 0
var checks := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", message)

func run() -> void:
	_test_search_snapshots()
	await _test_outer_publication()
	_test_frame_budget()
	_test_read_queue()
	_test_prewarm_pressure()
	print("main_game_polish: ", checks, " checks, ", failures, " failures")
	quit(1 if failures else 0)

func _test_search_snapshots() -> void:
	TrailRouter.release()
	var site := TrailSite.new()
	var a := SmallRouter.new()
	var b := SmallRouter.new()
	check(a.setup(site, {width = 2.0}) and b.setup(site, {width = 4.0}), "два поиска подготовлены на разных сетках")
	var area_b := b.areas()
	var area_a := a.areas()
	check(area_a.size() == 25 and area_b.size() == 49 and area_a[0] == -1 and area_a[1] == 0,
		"чередование поисков сохраняет собственную карту связности и запреты")
	var same := SmallRouter.new()
	check(same.setup(site, {width = 4.0}) and same.stats.prepare_reused and same.areas() == area_b,
		"ленивая карта повторно используется без пересборки сетки")
	TrailRouter.release()
	check(a.areas() == area_a and b.areas() == area_b, "очистка общего кэша не ломает активный поиск")
	check(a.setup(site, {width = 4.0}) and a.areas().size() == 49 and same.areas() == area_b,
		"повторная настройка экземпляра не изменяет опубликованные снимки")
	TrailRouter.release()

func _queue_result(terrain: OuterTerrain, key: Vector2i, built: Dictionary) -> void:
	var task := WorkerThreadPool.add_task(func() -> void: pass)
	# Задача завершена, но ещё не забрана — ровно состояние перед публикацией в кадре.
	while not WorkerThreadPool.is_task_completed(task): await process_frame
	terrain._tasks[key] = {id = task, out = {r = built}}

func _test_outer_publication() -> void:
	var terrain := QuietTerrain.new()
	terrain.land = OuterLand.new()
	terrain._checked_at = Vector2.ZERO
	terrain._task_limit = 0
	var key := Vector2i.ZERO
	var first := {fields = {revision = 1}, arrays = [], lods = {}}
	await _queue_result(terrain, key, first)
	check(terrain.update(0, 0) and terrain.land.chunks[key].revision == 1, "готовый внешний чанк опубликован и учтён в бюджете")
	check(terrain._tasks.is_empty() and terrain._stale.is_empty() and terrain._redo.is_empty(),
		"публикация не ставит собственный чанк на повторную пересборку")
	check(not terrain.update(0, 0), "без нового результата публикация не повторяется")
	await _queue_result(terrain, key, first)
	var replacement := {fields = {revision = 2}, arrays = [], lods = {}}
	terrain.publish_chunks({key: replacement}, {key: null})
	check(not terrain.update(0, 0) and terrain.land.chunks[key].revision == 2 and terrain._redo == [key],
		"публикация области по-прежнему отбрасывает результат старой задачи")
	terrain.free()

func _test_frame_budget() -> void:
	var stream := WorldStreamCoordinator.new()
	stream.publication_budget_us = 1000000
	var outer_ready := [true]
	var uploads := [0]
	var region_calls := [0]
	stream.vegetation_budgeted = func(_x: float, _z: float, _force: bool, _allow: bool) -> bool: return false
	stream.outer_update = func(_x: float, _z: float, allow: bool) -> bool:
		if allow and outer_ready[0]: uploads[0] += 1; return true
		return false
	stream.region_update = func(_x: float, _z: float) -> bool:
		region_calls[0] += 1; uploads[0] += 1; return true
	stream.update(Vector3.ZERO)
	check(uploads[0] == 1 and region_calls[0] == 0, "внешний рельеф и область не публикуются в одном кадре")
	outer_ready[0] = false
	stream.update(Vector3.ZERO)
	check(region_calls[0] == 1, "свободный кадр сразу достаётся соседней области")
	outer_ready[0] = true
	var at_most_one := true
	for frame in 30:
		var before: int = uploads[0]
		stream.update(Vector3.ZERO)
		at_most_one = at_most_one and uploads[0] - before <= 1
	check(at_most_one and region_calls[0] >= 4, "непрерывная очередь рельефа не блокирует области и не удваивает публикацию")
	# Региону нужен кадр независимо от того, подключена ли система растительности.
	stream.vegetation_budgeted = Callable()
	var before: int = region_calls[0]
	for frame in 30: stream.update(Vector3.ZERO)
	check(region_calls[0] >= before + 3, "отсутствие растительности не блокирует соседние области")
	stream.region_priority = func() -> bool: return true
	before = region_calls[0]
	stream.update(Vector3.ZERO)
	check(region_calls[0] == before + 1, "готовая область получает приоритет без обработчика растительности")

func _test_read_queue() -> void:
	var source := MemorySource.new()
	var data := {Vector2i.ZERO: [], Vector2i(1, 0): [], Vector2i(2, 0): []}
	source.setup(WorldCache.new(), WorldData.new(), null, 64, [data, {}, {}], null)
	source.request(-1, Vector2i.ZERO, 10)
	source.request(-1, Vector2i(1, 0), 20)
	source.request(-1, Vector2i(2, 0), 30)
	source.request(-1, Vector2i(2, 0), 1)
	check(source._queue[0].key == Vector2i(2, 0) and source._queue.size() == 3,
		"приближение чанка сразу меняет порядок чтения без дубликата запроса")
	source.request(-1, Vector2i(2, 0), 40)
	check(source._queue.back().key == Vector2i(2, 0), "удалившийся чанк уступает очередь ближайшим")
	source.close()

func _test_prewarm_pressure() -> void:
	var source := MemorySource.new()
	var budget := preload("res://scripts/core/cpu_cache_budget.gd").new()
	var payload := PackedByteArray()
	payload.resize(128)
	var ground := [payload]
	var water := [PackedByteArray([1, 2, 3, 4])]
	var bytes: int = source.LRU.size_of(ground) + source.LRU.size_of(water)
	budget.limit = bytes - 1
	source.setup(WorldCache.new(), WorldData.new(), null, 64,
		[{Vector2i.ZERO: ground}, {Vector2i.ZERO: water}, {}], budget)
	source._cpu.put(Vector3i(0, 0, 1), water)
	source.prewarm([Vector2(3, 3)], 0)
	check(source.stats.reads == 1 and source.ready(-1, Vector2i.ZERO) == ground and source.ready(0, Vector2i.ZERO) == water,
		"нехватка памяти не вытесняет нужную кэшированную воду до её прогрева")
	check(budget.snapshot().reserved_bytes == bytes and budget.snapshot().retained_bytes == 0,
		"все нужные блоки закреплены ровно один раз, включая блоки другого слоя")
	var reads: int = source.stats.reads
	source.prewarm([Vector2(3, 3), Vector2(3, 3)], 0)
	source.prewarm([], 0)
	check(source.stats.reads == reads and budget.snapshot().reserved_bytes == bytes,
		"повторные и пустые точки прогрева не дублируют чтения и память")
	source.close()
	check(budget.snapshot().reserved_bytes == 0, "закреплённые блоки освобождаются даже при тесном бюджете")
