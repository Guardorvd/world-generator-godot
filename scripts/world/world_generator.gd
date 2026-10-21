class_name WorldGenerator
extends RefCounted
## Генерация мира: запускает этапы из scripts/world/stages по порядку и возвращает WorldData.
## Мир — чистые данные (массивы и списки), без узлов сцены, поэтому генерацию можно вести в отдельном потоке.
##
## Главное правило: тот же сид — тот же мир. Этапы делят один генератор случайных чисел w.rng,
## поэтому любое изменение порядка или числа вызовов rng меняет все миры. Генерация своя (с 1.8 она уже
## не повторяет JS-версию); эталон мира по сиду проверяет tools/selftest.gd.


## seed — строка зерна, size — сторона мира в клетках; on_progress(p 0..1, подпись этапа) — необязательно.
## after_climate(w) — необязательно: вызывается, когда рельеф, вода и биомы готовы. Следующие этапы их
## уже не меняют, поэтому то, что зависит только от них, можно считать в другом потоке параллельно с ними.
static func generate(seed_text: String, size: int, on_progress: Callable = Callable(), after_climate: Callable = Callable()) -> WorldData:
	var w := WorldData.new()
	w.W = size
	w.H = size
	w.N = size * size
	w.seed_text = seed_text
	w.seed_num = WGRandom.hash_string(seed_text)
	w.rng = WGRandom.new(w.seed_num)
	# Порядок создания шумов важен: каждый забирает числа из общего rng
	for name in ["warpX", "warpY", "cont", "mask", "ridge", "hill", "moist", "temp", "forest", "cost", "micro"]:
		w.noise[name] = Simplex.new(w.rng)
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
	if after_climate.is_valid():
		after_climate.call(w)
	step.call(StageLandmarks.PROGRESS, StageLandmarks.LABEL)
	StageLandmarks.run(w)
	step.call(StageTrails.PROGRESS, StageTrails.LABEL)
	StageTrails.run(w, step)
	step.call(StageVegetation.PROGRESS, StageVegetation.LABEL)
	StageVegetation.run(w)
	StageLakes.run(w)
	# слой полотна поверх готовых путей: покрытие, без rng и без изменения маршрутов
	RoadSurface.run(w)
	w.clear_noise_fields()
	step.call(0.86, "Отрисовка ландшафта")
	return w
