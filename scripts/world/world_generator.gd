class_name WorldGenerator
extends RefCounted
## Генерация мира: запускает этапы из scripts/world/stages по порядку и возвращает WorldData.
## Мир — чистые данные (массивы и списки), без узлов сцены, поэтому генерацию можно вести в отдельном потоке.
##
## Главное правило: тот же сид — тот же мир. Этапы делят один генератор случайных чисел w.rng,
## поэтому любое изменение порядка или числа вызовов rng меняет все миры. Генерация повторяет
## JS-версию 1.2 бит в бит (проверка: tools/selftest.gd).


## seed — строка зерна, size — сторона мира в клетках; on_progress(p 0..1, подпись этапа) — необязательно
static func generate(seed_text: String, size: int, on_progress: Callable = Callable()) -> WorldData:
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
	step.call(StageOcean.PROGRESS, StageOcean.LABEL)
	StageOcean.run(w)
	step.call(StageHydrology.PROGRESS, StageHydrology.LABEL)
	StageHydrology.run(w)
	step.call(StageRivers.PROGRESS, StageRivers.LABEL)
	StageRivers.run(w)
	step.call(StageClimate.PROGRESS, StageClimate.LABEL)
	StageClimate.run(w)
	step.call(StageLandmarks.PROGRESS, StageLandmarks.LABEL)
	StageLandmarks.run(w)
	step.call(StageTrails.PROGRESS, StageTrails.LABEL)
	StageTrails.run(w, step)
	step.call(StageVegetation.PROGRESS, StageVegetation.LABEL)
	StageVegetation.run(w)
	step.call(0.86, "Отрисовка ландшафта")
	return w
