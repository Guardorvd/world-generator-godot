extends RefCounted
## Trail Lab, генератор местности (01.11, первая версия — простая, будет часто меняться). Берёт окно 512 × 512 м
## рельефа того же генератора, что игра (StageRelief: шумы, нормализация, микрорельеф; без рек, дорог и поселений),
## из мира с сидом «Trail Lab #<seed>»: из сетки окон этого мира выбирается то, чей перепад ближе всего к характеру
## (холмы, гора, крутая гора) и где нет воды. Результат — высоты клеток (4 м), из которых Fixture строит землю
## («generated»), а генератор трасс (TrailLabBuilder) ищет по ним линию. Детерминирован по (seed, kind).
## Позже сюда же — поиск такого окна в настоящем мире игры (область вокруг игрока), чтобы трассы искались там.

const CELLS := 128                      ## клеток на сторону (как у главного полигона): 512 м
const SIZE := CELLS * GameConfig.TILE   ## м
## Характеры местности: перепад от высшей до низшей точки окна, м, и заголовок.
const KINDS := {
	hills = {title = "Холмы", fall = Vector2(25.0, 55.0)},
	mountain = {title = "Гора", fall = Vector2(70.0, 130.0)},
	steep = {title = "Крутая гора", fall = Vector2(130.0, 220.0)},
}
const ORDER := ["hills", "mountain", "steep"]
## Сетка окон-кандидатов (шаг в клетках) и выборка по каждому для оценки.
const PROBE := 8
const STEP := 96
const BASE := 12.0 # высота нижней точки окна, м (как у прочих земель лаборатории)

static var seed := 1
static var kind := "mountain"
static var cells := PackedFloat32Array()
static var info := {}  ## {fall, lo, hi, window, title}: что выбрано
static var _key := ""


## Сгенерировать местность для (seed_value, kind_name); повторный вызов с теми же значениями — из памяти.
static func generate(seed_value: int, kind_name: String) -> void:
	var key := "%d|%s" % [seed_value, kind_name]
	if key == _key and not cells.is_empty(): return
	var started := Time.get_ticks_usec()
	seed = seed_value
	kind = kind_name if KINDS.has(kind_name) else "mountain"
	var w := WorldData.new()
	w.W = 16
	w.H = 16
	w.N = w.W * w.H
	w.seed_text = "Trail Lab #%d" % seed
	w.seed_num = WGRandom.hash_string(w.seed_text)
	for name: String in WorldGenerator.NOISE_SLOTS: w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	StageRelief.run(w) # горы мира и сдвиг стартовой области, как в игре
	var want: Vector2 = KINDS[kind].fall
	var n := w.noise
	var best := Vector2i.ZERO
	var best_score := INF
	var best_fall := 0.0
	for cy in 10:
		for cx in 10:
			var x0 := (cx - 5) * STEP
			var y0 := (cy - 5) * STEP
			var lo := INF
			var hi := -INF
			for sj in PROBE:
				for si in PROBE:
					var sx := x0 + (si + 0.5) * CELLS / float(PROBE)
					var sy := y0 + (sj + 0.5) * CELLS / float(PROBE)
					var raw := StageRelief.raw_at(n.warpX, n.warpY, n.cont, n.mask, n.ridge, n.hill, sx, sy, w.macro_x, w.macro_y, w.mountain_scale, w.mountain_bias, w.mountain_height, w.foothill_spread)
					var m := StageRelief.normalize(raw) * GameConfig.HS
					lo = minf(lo, m)
					hi = maxf(hi, m)
			var fall := hi - lo
			# суша без воды (нормализованная высота выше уровня моря с запасом) и перепад характера
			var score := absf(fall - (want.x + want.y) * 0.5) + (1000.0 if lo < 3.0 else 0.0)
			if score < best_score:
				best_score = score
				best = Vector2i(x0, y0)
				best_fall = fall
	var raw_cells := StageRelief.raw_rect(w, best.x, best.y, CELLS, CELLS, true)
	var micro := Parallel.fbm_rect(n.micro, best.x, best.y, CELLS, CELLS, 9.0, 2)
	var out := PackedFloat32Array()
	out.resize(CELLS * CELLS)
	var low := INF
	var high := -INF
	for i in out.size():
		out[i] = StageRelief.add_micro(StageRelief.normalize(raw_cells[i]), micro[i]) * GameConfig.HS
		low = minf(low, out[i])
		high = maxf(high, out[i])
	for i in out.size(): out[i] = out[i] - low + BASE
	cells = out
	_key = key
	info = {fall = snappedf(high - low, 0.1), window = best, title = KINDS[kind].title, probe_fall = snappedf(best_fall, 0.1),
		ms = (Time.get_ticks_usec() - started) / 1000.0}


## Высота земли, м (билинейно по центрам клеток, как прочие земли Fixture).
static func ground(at: Vector2) -> float:
	if cells.is_empty(): generate(seed, kind)
	var fx := clampf(at.x / GameConfig.TILE - 0.5, 0.0, CELLS - 1.0)
	var fz := clampf(at.y / GameConfig.TILE - 0.5, 0.0, CELLS - 1.0)
	var ix := mini(floori(fx), CELLS - 2)
	var iz := mini(floori(fz), CELLS - 2)
	var a := lerpf(cells[iz * CELLS + ix], cells[iz * CELLS + ix + 1], fx - ix)
	var b := lerpf(cells[(iz + 1) * CELLS + ix], cells[(iz + 1) * CELLS + ix + 1], fx - ix)
	return lerpf(a, b, fz - iz)

## Строка для подписи: характер, сид, перепад.
static func label() -> String:
	if info.is_empty(): return ""
	return "%s · сид %d · перепад %.0f м" % [info.title, seed, info.fall]
