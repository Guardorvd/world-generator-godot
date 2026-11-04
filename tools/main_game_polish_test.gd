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

class PublicationTerrain extends OuterTerrain:
	var staged: Array[Vector2i] = []
	func stage_chunk(key: Vector2i, _built: Dictionary) -> MeshInstance3D:
		staged.append(key)
		var node := MeshInstance3D.new()
		add_child(node)
		node.visible = false
		return node

class PublicationPlants extends VegetationLayer:
	func refresh(_rect: Rect2i) -> void: pass

class PublicationStream extends RegionStream:
	var saved := {}
	var shown_revision := 0
	func _persist(_key: Vector2i) -> void:
		saved = ledger.duplicate(true)
	func _show(_key: Vector2i, arrays := {}) -> void:
		shown_revision = arrays.decor.revision
		add_child(arrays.decor.node)

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
	_test_join_cache_boundary()
	await _test_outer_publication()
	_test_frame_budget()
	_test_read_queue()
	_test_prewarm_pressure()
	_test_delayed_region(false)
	_test_delayed_region(true)
	_test_departed_region()
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

func _road_site(cause := TrailRouter.Block.PATH) -> TrailSite:
	var w := WorldData.new()
	w.W = 32; w.H = 32; w.N = w.W * w.H
	var distance := PackedFloat32Array()
	distance.resize(w.N)
	distance.fill(0.0 if cause == TrailRouter.Block.WATER else 100.0)
	w.dist_water = distance
	var h := Heightfield.new()
	h.world = w
	h.hv.resize(w.N)
	h.hv.fill(100)
	h.hv_raw = h.hv
	h.water_level.resize(w.N)
	h.water_level.fill(-INF)
	if cause == TrailRouter.Block.WATER: h.water_level[16 * w.W + 16] = 100
	var site := TrailSite.new()
	site.work = Rect2i(0, 0, w.W, w.H)
	site._template = h
	site.trails = [{kind = "road", pts = [{x = 16.0, y = 2.0, w = 1.0}, {x = 16.0, y = 30.0, w = 1.0}]}]
	if cause == TrailRouter.Block.STRUCTURE:
		site.structures = [{ax = 64.0, az = 48.0, bx = 64.0, bz = 80.0, half = 2.0}]
	return site

func _test_join_cache_boundary() -> void:
	TrailRouter.release()
	var site := _road_site()
	var join := Vector2(64, 64)
	var reused := TrailRouter.new()
	check(reused.setup(site, {width = 3.0, joins = [join]}) and reused.blocked(join) == TrailRouter.Block.FREE,
		"явное примыкание разрешает подойти к дороге")
	check(reused.setup(site, {width = 4.0}), "смена ширины готовит новую базовую сетку")
	var warm := TrailRouter.new()
	check(warm.setup(site, {width = 4.0}) and warm.stats.prepare_reused, "следующий поиск использует общий кэш площадки")
	var center := warm._node_at(join)
	check(warm._block[center] == TrailRouter.Block.PATH and warm._cost[center] == INF,
		"прошлое примыкание не открывает дорогу в общем кэше")
	var areas := warm.areas()
	var left := areas[warm._node_at(Vector2(40, 64))]
	var right := areas[warm._node_at(Vector2(88, 64))]
	check(left >= 0 and right >= 0 and left != right, "разрешение прошлого запроса не соединяет области по разные стороны дороги")
	TrailRouter.release()
	var cold := TrailRouter.new()
	cold.setup(site, {width = 4.0})
	check(warm._cost == cold._cost and warm._block == cold._block and areas == cold.areas(),
		"холодный и тёплый поиск видят одинаковые препятствия независимо от истории запросов")
	var joining := TrailRouter.new()
	joining.setup(site, {width = 4.0, joins = [join]})
	var plain := TrailRouter.new()
	plain.setup(site, {width = 4.0})
	check(joining._cost[center] == 1.0 and plain._cost[center] == INF,
		"разрешение примыкания меняет только стоимость своего поиска")
	for cause: int in [TrailRouter.Block.WATER, TrailRouter.Block.STRUCTURE]:
		var protected := TrailRouter.new()
		protected.setup(_road_site(cause), {joins = [join]})
		check(protected.blocked(join) == cause and protected._cost[protected._node_at(join)] == INF,
			"примыкание не отменяет защиту: %s" % TrailRouter.BLOCK_NAMES[cause])
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

func _publication_fixture(expired: bool) -> PublicationStream:
	var stream := PublicationStream.new()
	stream.world = WorldData.new()
	stream.world.outer = OuterLand.new()
	var terrain := PublicationTerrain.new()
	terrain.land = stream.world.outer
	stream.add_child(terrain)
	stream.terrain = terrain
	stream.vegetation = PublicationPlants.new()
	stream.add_child(stream.vegetation)
	stream.ledger = {regions = {}, settlements = []}
	stream._key = Vector2i.ZERO
	var plan := {state = "found", verdict = "accepted", stats = {}, definition = {id = "prepared_route"}}
	var accepted := {regions = {Vector2i.ZERO: {rect = Rect2i(0, 0, 2, 2), fields = {revision = 2}, trail_plan = plan}}, settlements = []}
	var baseline := accepted.duplicate(true)
	baseline.regions[Vector2i.ZERO].fields.revision = 1
	var chunks := {Vector2i.ZERO: {fields = {revision = 2}}, Vector2i.ONE: {fields = {revision = 2}}}
	var fallback := chunks.duplicate(true)
	for key: Vector2i in fallback: fallback[key].fields.revision = 1
	# Старые метаданные с истёкшим сроком воспроизводят паузу без реального ожидания.
	var done := {ready = true, trail = plan, ledger = accepted, chunks = chunks,
		decor = {node = Node3D.new(), revision = 2}, fallback_ledger = baseline, fallback_chunks = fallback,
		trail_started = Time.get_ticks_msec() - 20000, trail_deadline = 0 if expired else Time.get_ticks_msec() + 100000}
	stream._publishing = {done = done, pending_keys = chunks.keys(), nodes = {}}
	return stream

func _test_delayed_region(expire_during_upload: bool) -> void:
	var stream := _publication_fixture(not expire_during_upload)
	var terrain: PublicationTerrain = stream.terrain
	stream.update(0, 0)
	check(stream.ledger.regions.is_empty() and stream.saved.is_empty(), "частичная загрузка мешей не публикует область")
	if expire_during_upload: stream._publishing.done.trail_deadline = 0
	for tick in 4:
		if stream._publishing.is_empty(): break
		stream.update(0, 0)
	var entry: Dictionary = stream.ledger.regions[Vector2i.ZERO]
	check(entry.trail_plan.state == "found" and entry.fields.revision == 2,
		"готовая трасса сохраняется после ожидания %s" % ("между загрузками мешей" if expire_during_upload else "до первой загрузки"))
	check(terrain.staged.size() == 2 and terrain.land.chunks[Vector2i.ZERO].revision == 2,
		"готовые меши не удаляются и не загружаются повторно из-за прошедшего времени")
	check(stream.shown_revision == entry.fields.revision and stream.saved.regions[Vector2i.ZERO].trail_plan.state == "found",
		"декор, поверхность и сохраняемый результат остаются согласованными")
	stream.free()

func _test_departed_region() -> void:
	var stream := _publication_fixture(true)
	stream.update(RegionStream.REACH * 10, 0)
	check(stream._publishing.is_empty() and stream.ledger.regions.is_empty() and stream.saved.is_empty(),
		"уход игрока по-прежнему отменяет публикацию ненужной области")
	stream.free()
