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
var heights: Heightfield
var terrain_arrays: Array
var terrain_image: Image
var water_arrays: Array[Array]
var map_image: Image


## Пикселей текстуры рельефа на клетку. В JS-версии 8 / 6 / 4, здесь меньше: в GDScript запекание
## заметно медленнее. Начиная со среднего мира текстура и карта (2 пикселя на клетку) пекутся за один проход.
static func px_for(size: int) -> int:
	return 4 if size <= 256 else 2


## Загрузка мира; on_progress(p 0..1, подпись) — необязательно, вызывается из потока загрузки.
## Доли прогресса только растут: этапы генерации идут по порядку, а хвост загрузки продолжает с 0.88.
static func load_world(seed_text: String, size: int, on_progress: Callable = Callable()) -> WorldLoader:
	var r := WorldLoader.new()
	var px := px_for(size)
	var side := Thread.new()
	r.world = WorldGenerator.generate(seed_text, size, on_progress, func(w: WorldData) -> void:
		side.start(r._prepare.bind(w, px)))
	# Обычно поток уже запущен генератором на этапе климата; если нет, готовим рельеф прямо здесь
	if on_progress.is_valid():
		on_progress.call(0.88, "Рельеф, вода и заливка")
	var painted: Array = side.wait_to_finish() if side.is_started() else r._prepare(r.world, px)
	# пути, мосты и туннели известны только после троп: полотно путей ложится на рельеф (RoadBed, с 4.3),
	# рельеф опускается под туннелями, меш поправляется. Без потока (_prepare здесь же) рельеф всё равно
	# построен без них, чтобы путь был один
	var changed := RoadBed.refine(r.heights)
	changed.append_array(r.heights.build_structures())
	if changed.size() > 0:
		TerrainBuilder.patch(r.terrain_arrays, r.world, r.heights, changed)
	r.heights.road_refinement = RoadRefinement.build(r.heights)
	TerrainBuilder.refine_arrays(r.terrain_arrays, r.world, r.heights)
	# рельеф за краем карты: кольцо клеток вокруг неё сразу, остальное — кусками по ходу игры
	r.world.outer = OuterLand.new(r.world)
	if on_progress.is_valid():
		on_progress.call(0.93, "Текстура рельефа и карта")
	# Текстура рельефа без отмывки (свет считает движок) и карта с отмывкой для мини-карты;
	# векторный слой на них рисуется одновременно в двух потоках
	var tex_bytes: Array[PackedByteArray] = [painted[0][0]]
	var map_bytes: Array[PackedByteArray] = [painted[-1][1]]
	var map_task := WorkerThreadPool.add_task(func() -> void: r.map_image = MapBaker.finish(r.world, 2, map_bytes)[0], true)
	r.terrain_image = MapBaker.finish(r.world, px, tex_bytes, false)[0]
	WorkerThreadPool.wait_for_task_completion(map_task)
	return r


## Часть загрузки, которой нужны только рельеф, вода и биомы: картинки, высоты и массивы геометрии.
## Возвращает заливку [[без отмывки, с отмывкой] для px] и, если px не 2, ещё такую же пару для карты
func _prepare(w: WorldData, px: int) -> Array:
	var painted := [MapBaker.paint(w, px)]
	if px != 2:
		painted.append(MapBaker.paint(w, 2))
	heights = Heightfield.new(w, false)
	terrain_arrays = TerrainBuilder.build_arrays(w, heights)
	water_arrays = WaterBuilder.prepare(w, heights)
	return painted
