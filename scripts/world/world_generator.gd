class_name WorldGenerator
extends RefCounted
## Генерация мира: запускает этапы из scripts/world/stages по порядку и возвращает WorldData.
## Мир — чистые данные (массивы и списки), без узлов сцены, поэтому генерацию можно вести в отдельном потоке.
##
## Главное правило: тот же сид — тот же мир. С 8.6 шумы, места, дома, имена и тропы имеют
## независимые ключи. Порядок географических стадий остаётся обязательным: климат читает готовую воду,
## а дороги — готовый рельеф. Эталон мира по сиду проверяет tools/selftest.gd.
## С 8.4 растительность берёт числа не из w.rng, а из хеша места (WGRandom.hash_cell): её чанки, как и
## местность за краем (OuterLand), воспроизводятся по отдельности.


## Фиксированный план для всех трёх размеров территории. Не подставлять сюда размер из меню:
## flood, реки и дорожная сеть должны видеть одни и те же границы при любом выборе игрока.
const PLAN_SIZE := 768
## Окно, открытое на старте. С 9.8 это весь план: мир один и большой, все его места сразу на карте.
## Окно меньше плана остаётся для инструментов (--size); тогда соседние земли открываются по ходу.
const START_SIZE := PLAN_SIZE
## Замороженные адреса перестановок 8.5: Simplex расходует ровно 255 чисел.
## Это сохраняет всю природную географию 8.5, но создание/перестановка шумов больше не делит RNG.
## Новые шумы используют derive(seed, "noise.<имя>"), старые адреса не перенумеровывать.
const NOISE_SLOTS := {warpX = 0, warpY = 1, cont = 2, mask = 3, ridge = 4, hill = 5,
	moist = 6, temp = 7, forest = 8, cost = 9, micro = 10}


static func noise_rng(seed_num: int, name: String) -> WGRandom:
	if NOISE_SLOTS.has(name):
		return WGRandom.new((seed_num + int(NOISE_SLOTS[name]) * 255 * 0x6d2b79f5) & WGRandom.MASK)
	return WGRandom.new(WGRandom.derive(seed_num, "noise." + name))


## seed — строка зерна, size — сторона доступной территории в клетках; on_progress(p 0..1, подпись этапа) — необязательно.
## after_climate(w) — необязательно: вызывается, когда рельеф, вода и биомы готовы. Следующие этапы их
## уже не меняют, поэтому то, что зависит только от них, можно считать в другом потоке параллельно с ними.
static func generate(seed_text: String, size: int, on_progress: Callable = Callable(), after_climate: Callable = Callable()) -> WorldData:
	return generate_layers(seed_text, size, on_progress, after_climate)


## Слои генерации для кэша миров (с 10.2, WorldCache): география (рельеф, вода, климат), места и пути,
## природа (растительность, озёра, полотно путей, окно территории). Слой читает только готовые прошлые слои.
const LAYERS := ["geo", "places", "nature"]


## Генерация по слоям. from — мир с готовыми слоями до start (из кэша: шумы на месте, без base_heights);
## on_layer(w, k) — после каждого слоя k, пока следующий его не тронул.
static func generate_layers(seed_text: String, size: int, on_progress: Callable = Callable(), after_climate: Callable = Callable(),
		from: WorldData = null, start := 0, on_layer: Callable = Callable()) -> WorldData:
	var w := _generate_plan(seed_text, PLAN_SIZE, on_progress, after_climate, from, start, on_layer, size)
	# Генерация не читает размер из меню: открываем окно только после всех этапов.
	w.territory_center = start_center(w)
	w.expand_territory(size)
	if on_layer.is_valid():
		on_layer.call(w, LAYERS.size() - 1)
	return w


## Центр стартовой территории: дом игрока (поселение), иначе середина плана.
static func start_center(w: WorldData) -> Vector2i:
	var home: Variant = PlayerState.home(w)
	return Vector2i(floori(home.x), floori(home.y)) if not home.is_empty() else Vector2i(w.W / 2, w.H / 2)


## Стартовая область, которую откроет expand_territory(size) на пустом окне; нужна до конца генерации (StageTrailPlan).
static func start_rect(w: WorldData, size: int) -> Rect2i:
	var side := clampi(size, 1, mini(w.W, w.H))
	var center := start_center(w)
	return Rect2i(Vector2i(clampi(center.x - side / 2, 0, w.W - side), clampi(center.y - side / 2, 0, w.H - side)), Vector2i(side, side))


## Только декоративный фон меню; не игровой мир и не источник соседних областей.
static func menu_background(seed_text: String) -> WorldData:
	return _generate_plan(seed_text, 192)


## Общая природная география без домов и дорог. Соседние области — прямоугольники этого же плана
## (WorldData.region_rect), а не flood в отдельном окне другого размера.
static func geography(seed_text: String, on_progress: Callable = Callable()) -> WorldData:
	var w := _geography(seed_text, PLAN_SIZE, on_progress)
	w.clear_noise_fields()
	w.base_heights = null
	return w


static func _geography(seed_text: String, side: int, on_progress: Callable = Callable()) -> WorldData:
	var w := WorldData.new()
	w.W = side
	w.H = side
	w.N = w.W * w.H
	w.seed_text = seed_text
	w.seed_num = WGRandom.hash_string(seed_text)
	for name: String in NOISE_SLOTS:
		w.noise[name] = Simplex.new(noise_rng(w.seed_num, name))
	w.scale = float(w.N) / (512 * 512)

	var step := func(p: float, label: String) -> void:
		if on_progress.is_valid():
			on_progress.call(p, label)

	step.call(StageRelief.PROGRESS, StageRelief.LABEL)
	StageRelief.run(w)
	w.start_noise_fields()
	step.call(StageOcean.PROGRESS, StageOcean.LABEL)
	StageOcean.run(w)
	step.call(StageHydrology.PROGRESS, StageHydrology.LABEL)
	StageHydrology.run(w)
	step.call(StageRivers.PROGRESS, StageRivers.LABEL)
	StageRivers.run(w)
	step.call(StageGeography.PROGRESS, StageGeography.LABEL)
	# Последняя граница изменений географии: общие поля нужны всем зависимым системам.
	StageGeography.run(w)
	step.call(StageClimate.PROGRESS, StageClimate.LABEL)
	StageClimate.run(w)
	return w


static func _generate_plan(seed_text: String, side: int, on_progress: Callable = Callable(), after_climate: Callable = Callable(),
		from: WorldData = null, start := 0, on_layer: Callable = Callable(), size := 0) -> WorldData:
	var w := from
	if start == 0:
		w = _geography(seed_text, side, on_progress)
		if on_layer.is_valid():
			on_layer.call(w, 0)
	else:
		# 10.2: география из кэша. Общий базовый рельеф строится заново (тот же, см. Heightfield.base_of),
		# поля шума — из сида
		w.base_heights = Heightfield.new(w, false)
		w.start_noise_fields()
	if after_climate.is_valid():
		after_climate.call(w)
	var step := func(p: float, label: String) -> void:
		if on_progress.is_valid():
			on_progress.call(p, label)
	if start <= 1:
		step.call(StageLandmarks.PROGRESS, StageLandmarks.LABEL)
		StageLandmarks.run(w)
		step.call(StageTrails.PROGRESS, StageTrails.LABEL)
		StageTrails.run(w, step)
		step.call(StageSites.PROGRESS, StageSites.LABEL)
		StageSites.run(w)
		# Одна автоматическая трасса стартовой области — до растительности, чтобы лес и покрытия видели её полотно
		StageTrailPlan.run(w, size)
		if on_layer.is_valid():
			on_layer.call(w, 1)
	step.call(StageVegetation.PROGRESS, StageVegetation.LABEL)
	StageVegetation.run(w)
	StageLakes.run(w)
	# слой полотна поверх готовых путей: покрытие, без rng и без изменения маршрутов
	RoadSurface.run(w)
	w.clear_noise_fields()
	w.base_heights = null
	step.call(0.86, "Отрисовка ландшафта")
	return w
