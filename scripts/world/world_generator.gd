class_name WorldGenerator
extends RefCounted
## Генерация мира: запускает этапы из scripts/world/stages по порядку и возвращает WorldData.
## Мир — чистые данные (массивы и списки), без узлов сцены, поэтому генерацию можно вести в отдельном потоке.
##
## Главное правило: тот же сид — тот же мир. С 8.6 шумы, места, дома, имена и тропы имеют
## независимые ключи. Порядок географических стадий остаётся обязательным: климат читает осадки и готовые маски воды,
## а дороги — готовый рельеф. Эталон мира по сиду проверяет tools/selftest.gd.
## С 8.4 растительность берёт числа не из w.rng, а из хеша места (WGRandom.hash_cell): её чанки, как и
## местность за краем (OuterLand), воспроизводятся по отдельности.


## Фиксированный план для всех трёх размеров территории. Не подставлять сюда размер из меню:
## география, редкие озёра и дорожная сеть должны видеть одни и те же границы при любом выборе игрока.
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
## природа (растительность и окно территории). Слой читает только готовые прошлые слои.
const LAYERS := ["geo", "places", "nature"]
enum PlanMode { STAND, WORLD }


## Генерация по слоям. from — мир с готовыми слоями до start (из кэша: шумы на месте, без base_heights);
## on_layer(w, k) — после каждого слоя k, пока следующий его не тронул.
static func generate_layers(seed_text: String, size: int, on_progress: Callable = Callable(), after_climate: Callable = Callable(),
		from: WorldData = null, start := 0, on_layer: Callable = Callable()) -> WorldData:
	var w := _generate_plan(seed_text, PLAN_SIZE, on_progress, after_climate, from, start, on_layer, PlanMode.WORLD)
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
	var t := Time.get_ticks_usec()
	StageRelief.run(w)
	w.start_noise_fields(["moist"])
	t = _stage_time(w, "relief", t)
	step.call(StageOcean.PROGRESS, StageOcean.LABEL)
	StageOcean.run(w)
	t = _stage_time(w, "ocean", t)
	step.call(StageHydrology.PROGRESS, StageHydrology.LABEL)
	StageHydrology.run(w)
	t = _stage_time(w, "hydrology", t)
	w.start_noise_fields(["temp"])
	step.call(StageRivers.PROGRESS, StageRivers.LABEL)
	StageRivers.run(w)
	t = _stage_time(w, "rivers", t)
	step.call(StageGeography.PROGRESS, StageGeography.LABEL)
	# Последняя граница изменений географии: общие поля нужны всем зависимым системам.
	StageGeography.run(w)
	t = _stage_time(w, "geography", t)
	step.call(StageClimate.PROGRESS, StageClimate.LABEL)
	StageClimate.run(w)
	_stage_time(w, "climate", t)
	return w


## Время этапа в generation_profile.stages_ms (мс); возвращает новую отметку. Для отчёта загрузки и стендов.
static func _stage_time(w: WorldData, stage: String, since_us: int) -> int:
	var now := Time.get_ticks_usec()
	if not w.generation_profile.has("stages_ms"):
		w.generation_profile.stages_ms = {}
	w.generation_profile.stages_ms[stage] = (now - since_us) / 1000.0
	return now


static func _generate_plan(seed_text: String, side: int, on_progress: Callable = Callable(), after_climate: Callable = Callable(),
		from: WorldData = null, start := 0, on_layer: Callable = Callable(), mode := PlanMode.STAND) -> WorldData:
	var w := from
	if start == 0:
		w = _geography(seed_text, side, on_progress)
		if on_layer.is_valid():
			on_layer.call(w, 0)
	else:
		# 10.2: география из кэша. Общий базовый рельеф строится заново (тот же, см. Heightfield.base_of),
		# поля шума — из сида
		if w.base_heights == null:
			w.base_heights = Heightfield.new(w, false)
	w.start_noise_fields(["cost", "forest"])
	if after_climate.is_valid():
		after_climate.call(w)
	var step := func(p: float, label: String) -> void:
		if on_progress.is_valid():
			on_progress.call(p, label)
	if start <= 1:
		step.call(StageLandmarks.PROGRESS, StageLandmarks.LABEL)
		var t := Time.get_ticks_usec()
		StageLandmarks.run(w)
		t = _stage_time(w, "landmarks", t)
		step.call(StageTrails.PROGRESS, StageTrails.LABEL)
		StageTrails.run(w, step)
		t = _stage_time(w, "trails", t)
		step.call(StageSites.PROGRESS, StageSites.LABEL)
		StageSites.run(w)
		t = _stage_time(w, "sites", t)
		StageLakes.run(w)
		t = _stage_time(w, "lakes", t)
		# Prepared parks are temporarily disabled in normal worlds. Explicit developer
		# network modes retain the original pipeline; Lab/manual definitions use StageTrailPlan directly.
		if mode == PlanMode.WORLD:
			if QuickTrails.network():
				StageTrailPlan.run(w, step)
			else:
				w.trail_plan = {version = StageTrailPlan.VERSION, state = "none", reason = "автоматические велопарки отключены"}
			_stage_time(w, "trail_plan", t)
		if on_layer.is_valid():
			on_layer.call(w, 1)
	var later := Time.get_ticks_usec()
	step.call(StageVegetation.PROGRESS, StageVegetation.LABEL)
	var surface: Heightfield = w.generation.trail_surface
	if surface == null:
		# Слой природы и загрузчик используют одну восстановленную поверхность.
		surface = Heightfield.base_of(w)
		w.generation.surface_rock = RockRelief.field_of(w)
		if w.trail_plan.get("mode", "") == "terrain_network":
			var errors: PackedStringArray = load(StageTrailPlan.NETWORK_SCRIPT).restore(surface, w.trail_plan)
			if errors.is_empty():
				surface.weaken_world()
				w.generation.trail_surface = surface
			else:
				surface.finish_paths()
		else:
			RoadSurface.run(w)
			surface.finish_paths()
	StageVegetation.run(w, surface)
	_stage_time(w, "vegetation", later)
	w.clear_noise_fields()
	w.base_heights = null
	step.call(0.86, "Отрисовка ландшафта")
	return w
