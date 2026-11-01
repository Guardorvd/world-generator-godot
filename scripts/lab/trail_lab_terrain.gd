extends RefCounted
## Trail Lab, генератор местности, v2 (01.11). Окно 512 × 512 м рельефа того же генератора, что игра (StageRelief:
## шумы, нормализация, микрорельеф; без рек, дорог и поселений), из мира с сидом «Trail Lab #<seed>», и поверх —
## простые формы характера. Детерминирован по (seed, kind).
## v2 по заездам 01.11 (v1 давала похожие склоны: всегда лучшее окно по перепаду, одна ориентация):
##  1. окно — случайное (по сиду) среди подходящих по перепаду и без воды, не лучшее; поворот на 0/90/180/270° и
##     отражение — тоже по сиду;
##  2. многоуровневость — уступы (TERRACE): высоты сводятся к полкам шага step с короткими крутыми подъёмами между
##     ними, доля strength; у «плато» — всегда, у прочих — иногда и слабее;
##  3. овраги и гребни (GULLY) — по ребристому шуму: V-образные ложбины глубиной depth; у «хребтов» — всегда;
##  4. сила форм, шаг уступов и глубина — случайные в пределах характера: два сида одного характера разные.
## Позже сюда же — окно настоящего мира игры (область вокруг игрока), чтобы трассы искались там.

const CELLS := 128                      ## клеток на сторону (как у главного полигона): 512 м
const SIZE := CELLS * GameConfig.TILE   ## м
## Характеры: перепад окна (м); terrace — вероятность уступов и их сила; gully — вероятность оврагов и их глубина, м.
const KINDS := {
	hills = {title = "Холмы", fall = Vector2(25.0, 60.0), terrace = Vector3(0.3, 0.3, 0.6), gully = Vector3(0.4, 2.0, 5.0)},
	mountain = {title = "Гора", fall = Vector2(70.0, 140.0), terrace = Vector3(0.35, 0.3, 0.6), gully = Vector3(0.4, 3.0, 7.0)},
	steep = {title = "Крутая гора", fall = Vector2(130.0, 230.0), terrace = Vector3(0.25, 0.2, 0.45), gully = Vector3(0.3, 4.0, 9.0)},
	plateau = {title = "Плато с уступами", fall = Vector2(50.0, 120.0), terrace = Vector3(1.0, 0.65, 0.9), gully = Vector3(0.25, 2.0, 5.0)},
	ridges = {title = "Хребты и овраги", fall = Vector2(50.0, 130.0), terrace = Vector3(0.15, 0.3, 0.5), gully = Vector3(1.0, 6.0, 12.0)},
}
const ORDER := ["hills", "mountain", "steep", "plateau", "ridges"]
## Сетка окон-кандидатов (шаг в клетках) и выборка по каждому для оценки.
const PROBE := 8
const STEP := 64
const GRID := 14
const BASE := 12.0 # высота нижней точки окна, м (как у прочих земель лаборатории)

static var seed := 1
static var kind := "mountain"
static var cells := PackedFloat32Array()
static var info := {}  ## {fall, window, title, forms}: что выбрано
static var _key := ""


## Сгенерировать местность для (seed_value, kind_name); повторный вызов с теми же значениями — из памяти.
static func generate(seed_value: int, kind_name: String) -> void:
	var key := "%d|%s" % [seed_value, kind_name]
	if key == _key and not cells.is_empty(): return
	var started := Time.get_ticks_usec()
	seed = seed_value
	kind = kind_name if KINDS.has(kind_name) else "mountain"
	var spec: Dictionary = KINDS[kind]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("trail_lab_terrain|%d|%s" % [seed, kind])
	var w := WorldData.new()
	w.W = 16
	w.H = 16
	w.N = w.W * w.H
	w.seed_text = "Trail Lab #%d" % seed
	w.seed_num = WGRandom.hash_string(w.seed_text)
	for name: String in WorldGenerator.NOISE_SLOTS: w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	StageRelief.run(w) # горы мира и сдвиг стартовой области, как в игре
	var want: Vector2 = spec.fall
	var n := w.noise
	# окна-кандидаты: годные (перепад характера с запасом, без воды) — и случайное из них; иначе ближайшее по перепаду
	var good: Array[Vector2i] = []
	var best := Vector2i.ZERO
	var best_score := INF
	for cy in GRID:
		for cx in GRID:
			var x0 := (cx - GRID / 2) * STEP
			var y0 := (cy - GRID / 2) * STEP
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
			if lo < 3.0: continue # вода
			if fall >= want.x * 0.85 and fall <= want.y * 1.15: good.append(Vector2i(x0, y0))
			var score := absf(fall - (want.x + want.y) * 0.5)
			if score < best_score:
				best_score = score
				best = Vector2i(x0, y0)
	if not good.is_empty(): best = good[rng.randi() % good.size()]
	var raw_cells := StageRelief.raw_rect(w, best.x, best.y, CELLS, CELLS, true)
	var micro := Parallel.fbm_rect(n.micro, best.x, best.y, CELLS, CELLS, 9.0, 2)
	var base := PackedFloat32Array()
	base.resize(CELLS * CELLS)
	for i in base.size(): base[i] = StageRelief.add_micro(StageRelief.normalize(raw_cells[i]), micro[i]) * GameConfig.HS
	# поворот и отражение
	var turns := rng.randi() % 4
	var mirror := rng.randf() < 0.5
	var out := PackedFloat32Array()
	out.resize(base.size())
	for z in CELLS:
		for x in CELLS:
			var sx := CELLS - 1 - x if mirror else x
			var sz := z
			for t in turns:
				var k := sx
				sx = CELLS - 1 - sz
				sz = k
			out[z * CELLS + x] = base[sz * CELLS + sx]
	var low := INF
	var high := -INF
	for v in out:
		low = minf(low, v)
		high = maxf(high, v)
	for i in out.size(): out[i] -= low
	var forms := PackedStringArray()
	# овраги: ребристый шум |n| < ширины — V-образная ложбина
	var g: Vector3 = spec.gully
	if rng.randf() < g.x:
		var depth := rng.randf_range(g.y, g.z)
		var scale := rng.randf_range(90.0, 170.0) # м между оврагами
		var noise := Simplex.new(WorldGenerator.noise_rng(w.seed_num + 77, "ridge"))
		for z in CELLS:
			for x in CELLS:
				var v := absf(noise.noise(x * GameConfig.TILE / scale, z * GameConfig.TILE / scale))
				out[z * CELLS + x] -= depth * pow(1.0 - smoothstep(0.0, 0.16, v), 1.5)
		forms.append("овраги до %.0f м" % depth)
	# уступы: полки шага step, подъём между ними на доле RISER высоты шага; strength — сколько от полки
	var tr: Vector3 = spec.terrace
	if rng.randf() < tr.x:
		var span := high - low
		var step := clampf(span / rng.randf_range(4.0, 8.0), 6.0, 30.0)
		var strength := rng.randf_range(tr.y, tr.z)
		for i in out.size():
			var h := out[i] / step
			var shelf := (floorf(h) + smoothstep(1.0 - RISER, 1.0, h - floorf(h))) * step
			out[i] = lerpf(out[i], shelf, strength)
		forms.append("уступы через %.0f м (%.0f %%)" % [step, strength * 100.0])
	low = INF
	high = -INF
	for v in out:
		low = minf(low, v)
		high = maxf(high, v)
	for i in out.size(): out[i] = out[i] - low + BASE
	cells = out
	_key = key
	info = {fall = snappedf(high - low, 0.1), window = best, title = spec.title, forms = forms, turns = turns, mirror = mirror,
		candidates = good.size(), ms = (Time.get_ticks_usec() - started) / 1000.0}

## Доля шага уступа, на которой поднимается его стенка (остальное — полка).
const RISER := 0.35

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
	var forms: PackedStringArray = info.get("forms", PackedStringArray())
	return "%s · сид %d · перепад %.0f м%s" % [info.title, seed, info.fall, (" · " + ", ".join(forms)) if not forms.is_empty() else ""]
