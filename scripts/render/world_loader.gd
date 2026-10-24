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
var water_arrays: Array[Array] # [lake chunks, river chunks], CPU arrays with local origins
var map_image: Image
var from_cache := false   # мир взят из WorldCache (10.0) целиком, а не сгенерирован
## Время CPU-подготовки в мс. prepare_* перекрываются с generate, их нельзя складывать.
var timings := {}


## Пикселей текстуры рельефа на клетку. В JS-версии 8 / 6 / 4, здесь меньше: в GDScript запекание
## заметно медленнее. Начиная со среднего мира текстура и карта (2 пикселя на клетку) пекутся за один проход.
static func px_for(size: int) -> int:
	return 4 if size <= 256 else 2


## Загрузка мира; on_progress(p 0..1, подпись) — необязательно, вызывается из потока загрузки.
## Доли прогресса только растут: этапы генерации идут по порядку, а хвост загрузки продолжает с 0.88.
static func load_world(seed_text: String, size: int, on_progress: Callable = Callable(), services: ServiceScope = null) -> WorldLoader:
	if services == null:
		services = GameContext.scope
	var r := WorldLoader.new()
	r.service_scope = services
	var px := px_for(WorldGenerator.PLAN_SIZE) # одинаковая детализация одного мира при любом окне
	var side := Thread.new()
	var started := Time.get_ticks_usec()
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
			side.start(r._prepare.bind(r.world, px, null, view.is_empty()))
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
	var painted: Array = side.wait_to_finish() if side.is_started() else r._prepare(r.world, px)
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
	var changed := r.heights.finish_paths()
	r.timings.finish_paths_ms = (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	if changed.size() > 0:
		TerrainBuilder.patch(r.terrain_arrays, r.world, r.heights, changed)
	TerrainBuilder.refine_arrays(r.terrain_arrays, r.world, r.heights)
	r.timings.patch_refine_mesh_ms = (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	r.terrain_chunks = PlanTerrain.partition(r.terrain_arrays)
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
	if view.is_empty() and services.cache.enabled:
		services.cache.save_view(seed_text, size, {terrain = r.terrain_image, map = r.map_image, forest = r.forest_surface})
	r.timings.total_ms = (Time.get_ticks_usec() - started) / 1000.0
	return r


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
	t = Time.get_ticks_usec()
	terrain_arrays = TerrainBuilder.build_arrays(w, heights)
	timings.prepare_mesh_ms = (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	water_arrays = WaterBuilder.prepare(w, heights)
	timings.prepare_water_ms = (Time.get_ticks_usec() - t) / 1000.0
	return painted
