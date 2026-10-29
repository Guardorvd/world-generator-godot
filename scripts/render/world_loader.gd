class_name WorldLoader
extends RefCounted
## Данные для игры, подготовленные в фоне: мир, высоты, массивы геометрии и изображения.
## Узлы отображения и GPU-ресурсы создаёт GameWorld.start в главном потоке.
## Заливка текстуры и карты, рельеф и вода зависят только от рельефа, климата и биомов (без троп и поселений),
## поэтому считаются в отдельном потоке, пока генератор прокладывает тропы и сажает лес.
## Этот поток читает только то, что после климата уже не меняется (рельеф, вода, реки, биомы). Мосты и
## туннели пишет этап троп, поэтому они встраиваются в рельеф после генерации, в одном потоке: так
## результат один и тот же, как бы ни легли задачи (до 2.0 поток мог застать их недописанными).

var world: WorldData
var service_scope: ServiceScope
var heights: Heightfield
var terrain_arrays: Array
var terrain_chunks := {} # CPU-кэш окончательной геометрии, без узлов и GPU
var terrain_image: Image
var forest_surface: Image
var water_arrays: Array[Array]
var water_chunks: Array[Dictionary] = []
var cache_size := 0
var map_image: Image
var error := ""            # причина, по которой мир не опубликовать (Main показывает её и возвращается в меню)
var trail := {}           # итог StageTrailPlan.apply: state (found / none), applied, variant, errors
var from_cache := false   # мир взят из WorldCache (10.0) целиком, а не сгенерирован
## Время CPU-подготовки в мс. prepare_* перекрываются с generate, их нельзя складывать.
var timings := {}
const Surface := preload("res://scripts/game/surface_snapshot.gd")
var surface_hit := false
var chunk_source: RefCounted
var opening_spot := {}
var opening_prepared := false
var startup_at := Vector2.INF


## Пикселей текстуры рельефа на клетку. В JS-версии 8 / 6 / 4, здесь меньше: в GDScript запекание
## заметно медленнее. Начиная со среднего мира текстура и карта (2 пикселя на клетку) пекутся за один проход.
static func px_for(size: int) -> int:
	return 4 if size <= 256 else 2


## Загрузка мира; on_progress(p 0..1, подпись) — необязательно, вызывается из потока загрузки.
## Доли прогресса только растут: этапы генерации идут по порядку, а хвост загрузки продолжает с 0.88.
static func load_world(seed_text: String, size: int, on_progress: Callable = Callable(), services: ServiceScope = null, retried := false, start_at := Vector2.INF) -> WorldLoader:
	if services == null:
		services = GameContext.scope
	var r := WorldLoader.new()
	r.service_scope = services
	r.cache_size = size
	var px := px_for(WorldGenerator.PLAN_SIZE) # одинаковая детализация одного мира при любом окне
	var side := Thread.new()
	var started := Time.get_ticks_usec()
	var profile_before: Dictionary = services.resource_profile.stamp() if services.resource_profile != null else {}
	if services.cache.enabled:
		services.cache.wait_writes()
		r.timings.previous_write_wait_ms = (Time.get_ticks_usec() - started) / 1000.0
		services.cache.take_io_timings() # preceding loads/installations are not this load's I/O
	# 10.0: готовый мир из кэша (WorldCache) вместо генерации; рельеф и всё остальное считаются как обычно.
	# С 10.2 кэш по слоям: подошли не все — генерация продолжается с первого неподходящего слоя
	var on_climate := func(w: WorldData) -> void:
		side.start(r._prepare.bind(w, px, w.base_heights))
	# Картинки мира (текстура, карта, подстилка) тоже из кэша, если мир из кэша целиком (10.2)
	var view := {}
	if services.cache.enabled:
		var got := services.cache.generate(seed_text, size, on_progress, on_climate)
		r.world = got.world
		r.from_cache = got.layers == WorldGenerator.LAYERS.size()
		r.timings.cache_layers = got.layers
		if r.from_cache:
			if on_progress.is_valid():
				on_progress.call(0.5, "Мир из кэша")
			view = services.cache.load_view(seed_text, size)
			r.timings.cache_view = int(not view.is_empty())
			var restore_started := Time.get_ticks_usec()
			var saved := services.cache.load_artifact(seed_text, size, "surface")
			if saved.get("trail") is Dictionary and saved.get("water_chunks") is Array and saved.get("chunks") is Dictionary and saved.get("heights") is Dictionary:
				var water_ok: bool = saved.water_chunks.size() == 2
				for refs: Variant in [saved.chunks] + saved.water_chunks:
					water_ok = water_ok and refs is Dictionary
					if not water_ok: break
					for at: Variant in refs:
						var ref: Variant = refs[at]
						water_ok = water_ok and at is Vector2i and ref is Dictionary and ref.get("file") is String and ref.get("key") is String
						if water_ok: water_ok = ref.file == ref.file.get_file()
				if water_ok and not saved.chunks.is_empty():
					r.heights = Surface.restore(r.world, saved.heights, "final")
					if r.heights != null and saved.trail.get("state") in ["found", "none"] and (saved.trail.state != "found" or saved.trail.get("applied", false)):
						r.surface_hit = true
						r.water_arrays.assign([[], []])
						r.water_chunks.assign(saved.water_chunks)
						r.trail = saved.trail
						r.terrain_chunks = saved.chunks
				r.timings.surface_restore_ms = (Time.get_ticks_usec() - restore_started) / 1000.0
			r.timings.cache_surface = int(r.surface_hit)
			if not r.surface_hit:
				var base := Surface.restore(r.world, services.cache.load_artifact(seed_text, size, "base"), "base")
				side.start(r._prepare.bind(r.world, px, base, view.is_empty()))
			elif view.is_empty():
				side.start(r._paint.bind(r.world, px))
	else:
		r.world = WorldGenerator.generate(seed_text, size, on_progress, on_climate)
	var generated := Time.get_ticks_usec()
	var t := Time.get_ticks_usec()
	# Состав леса известен после генерации; параллельная заливка его не читает (с 10.0 — пока она идёт).
	# С 12.2 подстилка и картинки считаются в задачах пула рядом с полотном путей: они читают только
	# мир (объекты, тропы, реки), а полотно меняет только рельеф. Время каждой задачи пишется после ожидания
	var side_ms := {}
	var forest_task := -1
	if not view.is_empty():
		r.forest_surface = view.forest
	else:
		var forest_job := func() -> void:
			var t0 := Time.get_ticks_usec()
			r.forest_surface = preload("res://scripts/render/forest_floor.gd").surface_image(r.world)
			side_ms.forest_surface_ms = (Time.get_ticks_usec() - t0) / 1000.0
		forest_task = WorkerThreadPool.add_task(forest_job, true, "Подстилка леса")
	# Обычно поток уже запущен генератором на этапе климата; если нет, готовим рельеф прямо здесь
	if on_progress.is_valid():
		on_progress.call(0.88, "Рельеф, вода и заливка")
	var waited := Time.get_ticks_usec()
	var painted: Array = side.wait_to_finish() if side.is_started() else ([] if r.surface_hit else r._prepare(r.world, px))
	r.timings["cache_read_ms" if r.from_cache else "generate_ms"] = (generated - started) / 1000.0
	r.timings.prepare_wait_ms = (Time.get_ticks_usec() - waited) / 1000.0
	var image_tasks: Array[int] = []
	if not view.is_empty():
		r.terrain_image = view.terrain
		r.map_image = view.map
	else:
		# Текстура рельефа без отмывки (свет считает движок) и карта с отмывкой для мини-карты;
		# векторный слой на них рисуется одновременно в двух потоках
		var tex_bytes: Array[PackedByteArray] = [painted[0][0]]
		var map_bytes: Array[PackedByteArray] = [painted[-1][1]]
		var map_job := func() -> void:
			var t0 := Time.get_ticks_usec()
			r.map_image = MapBaker.finish(r.world, 2, map_bytes)[0]
			side_ms.map_ms = (Time.get_ticks_usec() - t0) / 1000.0
		var texture_job := func() -> void:
			var t0 := Time.get_ticks_usec()
			r.terrain_image = MapBaker.finish(r.world, px, tex_bytes, false)[0]
			side_ms.terrain_image_ms = (Time.get_ticks_usec() - t0) / 1000.0
		image_tasks.append(WorkerThreadPool.add_task(map_job, true, "Карта"))
		image_tasks.append(WorkerThreadPool.add_task(texture_job, true, "Текстура рельефа"))
	t = Time.get_ticks_usec()
	# пути, мосты и туннели известны только после троп: полотно путей ложится на рельеф (RoadBed, с 4.3),
	# рельеф опускается под туннелями, меш поправляется. Без потока (_prepare здесь же) рельеф всё равно
	# построен без них, чтобы путь был один
	var changed := PackedInt32Array() if r.surface_hit else r.heights.finish_paths()
	r.timings.finish_paths_ms = (Time.get_ticks_usec() - t) / 1000.0
	r.timings.path_details = r.heights.path_timings.duplicate(true)
	# Автоматическая трасса стартовой области (StageTrailPlan): формирование и элементы запекаются на свежем рельефе
	# до меша, столкновений и карты, поэтому весь мир видит один окончательный результат
	t = Time.get_ticks_usec()
	if not r.surface_hit: r.trail = StageTrailPlan.apply(r.heights)
	r.timings.trail_ms = (Time.get_ticks_usec() - t) / 1000.0
	for message: String in r.trail.errors:
		push_warning("Трасса стартовой области: " + message)
	t = Time.get_ticks_usec()
	if not r.surface_hit and changed.size() > 0:
		TerrainBuilder.patch(r.terrain_arrays, r.world, r.heights, changed)
	if not r.surface_hit: TerrainBuilder.refine_arrays(r.terrain_arrays, r.world, r.heights)
	r.timings.patch_refine_mesh_ms = (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	if not r.surface_hit: r.terrain_chunks = PlanTerrain.partition(r.terrain_arrays)
	if services.cache.enabled: r.terrain_arrays = [] # inspection tools without caching retain the source mesh
	if not r.surface_hit:
		for arrays: Array in r.water_arrays: r.water_chunks.append(WaterBuilder.partition_arrays(arrays))
	r.timings.partition_ms = (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	# рельеф за краем карты: кольцо клеток вокруг неё сразу, остальное — кусками по ходу игры
	r.world.outer = OuterLand.new(r.world)
	r.timings.outer_ms = (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	if on_progress.is_valid():
		on_progress.call(0.93, "Текстура рельефа и карта")
	if forest_task >= 0:
		WorkerThreadPool.wait_for_task_completion(forest_task)
	for task in image_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	r.timings.overlays_wait_ms = (Time.get_ticks_usec() - t) / 1000.0
	r.timings.merge(side_ms)
	# Устаревший план трассы (кэш другой версии кода, «есть» или «нет»): мир не публикуется и не помечается skip — файлы
	# кэша этого сида удаляются, и мир готовится заново по нынешнему коду (один раз)
	if r.trail.get("state", "") == "stale":
		push_warning("Трасса стартовой области: %s" % "; ".join(r.trail.get("errors", PackedStringArray())))
		if services.cache.enabled:
			services.cache.wait_writes()
			services.cache.invalidate_from(seed_text, size, 1)
		if not retried:
			return load_world(seed_text, size, on_progress, services, true, start_at)
		r.error = "Не удалось подготовить мир: план трассы стартовой области устарел и после пересоздания."
		return r
	# Откат: трасса добавлена в мир, но применить её не удалось — мир с недостроенным путём не публикуется. Кэш мира
	# удаляется, сид помечается, и мир собирается заново без трассы (повторный вызов, один раз); не вышло и так — отказ.
	if r.trail.get("state", "none") == "found" and not r.trail.get("applied", false):
		push_error("Трасса стартовой области не применена (%s): мир пересобирается без неё" % "; ".join(r.trail.get("errors", PackedStringArray())))
		if services.cache.enabled:
			services.cache.wait_writes()
			services.cache.invalidate_from(seed_text, size, 1)
		StageTrailPlan.skip[seed_text] = true
		if not retried:
			return load_world(seed_text, size, on_progress, services, true, start_at)
		r.error = "Не удалось подготовить мир: трасса стартовой области не применилась. " + "; ".join(r.trail.get("errors", PackedStringArray()))
		return r
	if view.is_empty() and services.cache.enabled:
		services.cache.save_view(seed_text, size, {terrain = r.terrain_image, map = r.map_image, forest = r.forest_surface})
	if services.cache.enabled and not r.surface_hit:
		var ticket := services.cache.save_surface(seed_text, size, {heights = Surface.capture(r.heights, "final"), trail = r.trail}, r.terrain_chunks, r.water_chunks)
		var wait_started := Time.get_ticks_usec()
		services.cache.wait_writes() # publishing file references now requires this result
		r.timings.surface_write_wait_ms = (Time.get_ticks_usec() - wait_started) / 1000.0
		if not ticket.result.is_empty():
			r.terrain_chunks = ticket.result.chunks
			r.water_chunks.assign(ticket.result.water_chunks)
	if services.cache.enabled: r.prepare_streaming(start_at)
	r.timings.cache_io = services.cache.take_io_timings()
	r.timings.profile_origin = "stored_generation" if r.from_cache else "current_generation"
	r.timings.total_ms = (Time.get_ticks_usec() - started) / 1000.0
	if services.resource_profile != null:
		var kind := "same_process_reentry" if services.loaded_worlds > 0 else "disk_load"
		if not r.from_cache: kind = "partial_generation" if r.timings.get("cache_layers", 0) > 0 else "cold_generation"
		services.resource_profile.phase(kind, profile_before, services, r.timings.duplicate(true))
	services.loaded_worlds += 1
	return r


func prepare_streaming(start_at := Vector2.INF) -> void:
	if chunk_source != null: return
	var t := Time.get_ticks_usec()
	var home := PlayerState.spawn(world, heights)
	var points: Array[Vector2] = [Vector2(home.x, home.z)]
	opening_prepared = true
	if start_at.is_finite():
		points.push_front(start_at)
	else:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		opening_spot = preload("res://scripts/game/opening_route.gd").choose(world, heights, rng)
		if not opening_spot.is_empty(): points.push_front(Vector2(opening_spot.position.x, opening_spot.position.z))
	startup_at = points[0]
	if water_chunks.is_empty():
		for arrays: Array in water_arrays: water_chunks.append(WaterBuilder.partition_arrays(arrays))
	if water_chunks.size() != 2: water_chunks.assign([{}, {}])
	chunk_source = preload("res://scripts/render/chunk_source.gd").new()
	chunk_source.setup(service_scope.cache, world, heights, cache_size, [terrain_chunks, water_chunks[0], water_chunks[1]], service_scope.cpu_budget)
	chunk_source.prewarm(points, PlanTerrain.RADIUS / 2.0)
	water_arrays.assign([[], []])
	timings.startup_prefetch_ms = (Time.get_ticks_usec() - t) / 1000.0


## Часть загрузки, которой нужны только рельеф, вода и биомы: картинки, высоты и массивы геометрии.
## Возвращает пары [без отмывки, с отмывкой]; при разных разрешениях ненужный вариант пустой.
## base — общий рельеф генератора (9.7), снятый в момент запуска потока: к концу генерации его уже нет в мире;
## paint — false, когда картинки взяты из кэша (10.2)
func _prepare(w: WorldData, px: int, base: Heightfield = null, paint := true) -> Array:
	var t := Time.get_ticks_usec()
	var painted := []
	if paint:
		painted.append(MapBaker.paint(w, px, true, px == 2))
		if px != 2:
			painted.append(MapBaker.paint(w, 2, false, true))
		timings.prepare_paint_ms = (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	heights = base.copy() if base != null else Heightfield.new(w, false)
	timings.prepare_heights_ms = (Time.get_ticks_usec() - t) / 1000.0
	if base == null and service_scope != null and service_scope.cache.enabled:
		service_scope.cache.save_artifact(w.seed_text, cache_size, "base", Surface.capture(heights, "base"))
	t = Time.get_ticks_usec()
	terrain_arrays = TerrainBuilder.build_arrays(w, heights)
	timings.prepare_mesh_ms = (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	water_arrays = WaterBuilder.prepare(w, heights)
	timings.prepare_water_ms = (Time.get_ticks_usec() - t) / 1000.0
	return painted


func _paint(w: WorldData, px: int) -> Array:
	var painted := [MapBaker.paint(w, px, true, px == 2)]
	if px != 2: painted.append(MapBaker.paint(w, 2, false, true))
	return painted


## Damaged derivative chunk: recover from the restored physics surface, never regenerate the world.
static func rebuild_chunk(key: Vector2i, w: WorldData, h: Heightfield) -> Array:
	return TerrainBuilder.build_chunk(w, h, key)


static func rebuild_water_chunk(key: Vector2i, layer: int, w: WorldData, cache: WorldCache, size: int) -> Array:
	var base := Surface.restore(w, cache.load_artifact(w.seed_text, size, "base"), "base")
	if base == null: base = Heightfield.new(w, false)
	return WaterBuilder.build_chunk(w, base, key, layer)
