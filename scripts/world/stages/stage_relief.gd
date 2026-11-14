class_name StageRelief
extends RefCounted
## Этап 1. Макрорельеф: континенты, горные массивы (с 1.9.7, см. mountain) и возвышенности (с 3.0), равнины и холмистые края (с 1.9.8), уровень моря, микрорельеф суши.
## Пишет: w.macro_x, macro_y — сдвиг шума материков (место старта), w.h — высота клетки (0 — уровень моря,
## суша до 1, дно до -1).
## Основа считается независимо по клеткам; слой склонов читает готовую основу с полосой соседей.
## Оба прохода можно распараллеливать. Native-копия — FastGrid.Relief.cs; результат бит в бит.

const Detail := preload("res://scripts/world/mountain_detail.gd")

const PROGRESS := 0.02
const LABEL := "Формирование континентов"


## Масштаб материков и океанов в клетках и их вклад в рельеф (с 1.9.6). Поверх шума континентов
## (масштаб 240) лежит медленный шум: где он высок — материк с заливами и озёрами, где низок — открытое
## море с островами. Так суша и вода за стартовой областью распределяются крупно, как на настоящей карте.
## Вверх шум материков поднимает рельеф не больше MACRO_LIFT: материк — это суша, а не сплошные горы
const MACRO := 1400.0
const MACRO_AMP := 1.2
const MACRO_LIFT := 0.25
## Уровень моря, самая высокая и самая низкая точка в шуме рельефа (до нормировки). С 1.9.6 постоянные,
## а не по самой карте: тогда соседние области того же мира стыкуются без ступенек
const SEA_RAW := 0.067
const TOP_RAW := 1.05
const BOTTOM_RAW := -0.7
## Негорный рельеф (с 1.9.8). CHARACTER — масштаб шума характера местности в клетках (около 2 км):
## равнина (0) или холмистый край (1). На равнине высота над морем — PLAIN_LIFT от прежней, а холмов
## PLAIN_HILLS. Предгорья — где сила гор (mask) от FOOTHILLS до 2 × FOOTHILLS: там холмы растут до полных
const CHARACTER := 520.0
const PLAIN_LIFT := 0.3
const PLAIN_HILLS := 0.15
const HILL_AMP := 0.07
const FOOTHILLS := 0.35
## Широкое основание предгорий (с 3.6), до нормировки высоты. Прорезается общими долинами.
const FOOTHILL_LIFT := 0.18
## Высота гор на единицу ширины гребней не больше этого (с GEO 7): крутизна массива ~ высота / ширина, поэтому у высоких
## и узких сочетаний сида гребни, долины и вершины шире (область гор та же). Сиды с пологими горами не меняются
const HEIGHT_PER_WIDTH := 0.7
## Доля мелких октав основания вглубь суши (с GEO 7), у берега 1
const INLAND_DETAIL := 0.35
## Ширина подъёма от равнины к горам (в долях шума гор)
const MASK_EDGE := 0.9
## Небольшие долины: масштаб шума в клетках, ширина (в долях шума) и глубина
const VALLEY := 260.0
const VALLEY_WIDTH := 0.24
const VALLEY_DEPTH := 0.06
## С 2.9 суши больше: шум материков сдвинут вверх на LAND_BIAS (было 0.1)
const LAND_BIAS := 0.18
## Прежний выбор старта (до 14.11.2026, GEO 16): первое по спирали окно 512 × 512 в углу плана,
## где суши хотя бы PICK_LAND. Остался для сравнения: StageRelief.legacy_start = true (tools/macro_geo_look.gd --legacy)
const PICK_TRIES := 48
const START_SIDE := 512
const PICK_LAND := 0.6
static var legacy_start := false
## Выбор старта с 14.11.2026 (GEO 17), см. docs/MACRO_GEOGRAPHY.md. Оценивается весь игровой план PICK_SIDE
## (= WorldGenerator.PLAN_SIZE, постоянный на сид при любом --size), из PICK_CANDIDATES сдвигов по спирали
## (первые 48 — прежние) выбирается лучший, а не первый подходящий. Время ограничено: подъём материка
## (один медленный шум) считается у всех, полный макрорельеф по сетке PICK_GRID² — у PICK_FINALISTS лучших.
const PICK_SIDE := 768
const PICK_CANDIDATES := 64
const PICK_FINALISTS := 8
const PICK_GRID := 12
## Мягкое предпочтение, не предел: до OCEAN_PREFER океана не штрафуется (обычная карта 0–10 %), больше —
## штраф, но если суше взяться неоткуда, берётся лучший из возможных. COASTAL_SHARE сидов (по хешу сида)
## предпочитают прибрежную карту с океаном в COASTAL_OCEAN — необычные морские миры остаются.
const OCEAN_PREFER := 0.10
const COASTAL_SHARE := 0.12
const COASTAL_OCEAN := Vector2(0.15, 0.35)
## Веса оценки: лишний океан, замкнутые «моря» внутри суши (не связаны с краем плана), изрезанность берега,
## разброс высот суши (поощряется слабо: скучная ровная суша не лучше карты с небольшой водой)
const PICK_W_OCEAN := 4.0
const PICK_W_POCKETS := 2.0
const PICK_W_COAST := 0.5
const PICK_W_RELIEF := 0.3


## Рельеф карты: стартовая область, нормировка по уровню моря, микрорельеф суши
static func run(w: WorldData, include_detail: bool = true) -> void:
	var N := w.N
	configure(w)
	_pick_start(w)
	var h := raw_rect(w, 0, 0, w.W, w.H, true, include_detail)
	for i in N:
		h[i] = normalize(h[i])
	# Микрорельеф суши: небольшие неровности поверхности, с затуханием к берегу.
	var micro := Parallel.fbm_field(w.W, w.H, w.noise.micro, 9.0, 2)
	for i in N:
		h[i] = add_micro(h[i], micro[i])
	w.h = h


## Параметры всего мира, без расхода общего RNG. Не меняет окно старта и готовые высоты.
static func configure(w: WorldData) -> void:
	w.mountain_scale = 0.8 + 0.8 * WGRandom.hash2(31, 7, w.seed_num)
	w.mountain_bias = 0.05 + 0.4 * WGRandom.hash2(17, 19, w.seed_num)
	w.mountain_height = 0.75 + 0.6 * WGRandom.hash2(47, 3, w.seed_num)
	w.foothill_spread = 0.15 + 0.85 * WGRandom.hash2(73, 11, w.seed_num)


## Стартовая область — окно в бесконечный мир. Мир один на сид, а окно выбирается сдвигом шума
## материков (масштаб MACRO). Шумы мельче материков не сдвигаются: горы, холмы и долины сида на месте,
## от сдвига зависят береговая линия и высота равнин. Без расхода RNG, детерминированно по сиду
static func _pick_start(w: WorldData) -> void:
	if legacy_start:
		_pick_start_legacy(w)
		return
	var n := w.noise
	var coastal := is_coastal(w.seed_num)
	# 1. Подъём материка по плану (сетка 8 × 8) у всех кандидатов: чем выше, тем меньше океана
	var cands := []
	for k in PICK_CANDIDATES:
		var a := k * 2.39996323
		var r := MACRO * 0.6 * sqrt(float(k))
		var mx := roundf(r * cos(a))
		var my := roundf(r * sin(a))
		var lift := 0.0
		for sj in 8:
			for si in 8:
				var x := floorf((si + 0.5) * PICK_SIDE / 8.0)
				var y := floorf((sj + 0.5) * PICK_SIDE / 8.0)
				lift += minf(n.cont.fbm((x + mx) / MACRO + 91.7, (y + my) / MACRO - 43.1, 2) * MACRO_AMP, MACRO_LIFT)
		cands.append([lift, k, mx, my])
	cands.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0] or (p[0] == q[0] and p[1] < q[1]))
	# 2. Финалисты: обычный мир — самые «материковые»; прибрежный — равномерно по всему ряду подъёма
	var finalists := []
	for f in PICK_FINALISTS:
		finalists.append(cands[roundi(f * (cands.size() - 1) / float(PICK_FINALISTS - 1)) if coastal else f])
	# Финалисты оцениваются параллельно, у каждой задачи свои копии шумов; выбор — по порядку, как подряд
	var scores := Parallel.bands(finalists.size(), func(a: int, b: int) -> PackedFloat64Array:
		var own := {}
		for key: String in ["warpX", "warpY", "cont", "mask", "ridge", "hill"]:
			own[key] = w.noise[key].clone()
		var out := PackedFloat64Array()
		for f in range(a, b):
			out.append(_start_score(w, own, finalists[f][2], finalists[f][3], coastal))
		return out, 1)
	var best := INF
	for f in finalists.size():
		var score: float = scores[f][0]
		if score < best:
			best = score
			w.macro_x = finalists[f][2]
			w.macro_y = finalists[f][3]


## Сид предпочитает прибрежную карту (своя независимая случайность, общий RNG не расходуется)
static func is_coastal(seed_num: int) -> bool:
	return WGRandom.at(seed_num, "relief.coastal").next_float() < COASTAL_SHARE


## Оценка сдвига (меньше — лучше) по макрорельефу без слоя склонов на сетке PICK_GRID² плана
static func _start_score(w: WorldData, n: Dictionary, mx: float, my: float, coastal: bool) -> float:
	var G := PICK_GRID
	var sea := PackedByteArray()
	sea.resize(G * G)
	var heights := PackedFloat32Array()
	var sea_n := 0
	for sj in G:
		for si in G:
			var x := floorf((si + 0.5) * PICK_SIDE / float(G))
			var y := floorf((sj + 0.5) * PICK_SIDE / float(G))
			var raw := raw_at(n.warpX, n.warpY, n.cont, n.mask, n.ridge, n.hill, x, y, mx, my, w.mountain_scale, w.mountain_bias, w.mountain_height, w.foothill_spread)
			if raw < SEA_RAW:
				sea[sj * G + si] = 1
				sea_n += 1
			else:
				heights.append(normalize(raw))
	# Океан, связанный с краем плана; остальное — замкнутые понижения ниже моря посреди суши
	var open := PackedByteArray()
	open.resize(G * G)
	var stack := PackedInt32Array()
	for i in G * G:
		var on_edge := i % G == 0 or i % G == G - 1 or i / G == 0 or i / G == G - 1
		if on_edge and sea[i] != 0:
			open[i] = 1
			stack.append(i)
	while not stack.is_empty():
		var i := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		for d: int in [-1, 1, -G, G]:
			var j := i + d
			if j < 0 or j >= G * G or (absi(d) == 1 and j / G != i / G):
				continue
			if sea[j] != 0 and open[j] == 0:
				open[j] = 1
				stack.append(j)
	var pockets := 0
	var coast := 0
	for i in G * G:
		if sea[i] != 0 and open[i] == 0:
			pockets += 1
		if i % G < G - 1 and sea[i] != sea[i + 1]:
			coast += 1
		if i / G < G - 1 and sea[i] != sea[i + G]:
			coast += 1
	var cells := float(G * G)
	var ocean := sea_n / cells
	var excess := maxf(0.0, ocean - OCEAN_PREFER)
	if coastal:
		excess = maxf(0.0, COASTAL_OCEAN.x - ocean) + maxf(0.0, ocean - COASTAL_OCEAN.y)
	var relief := 0.0
	if heights.size() > 1:
		var mean := 0.0
		for v in heights:
			mean += v
		mean /= heights.size()
		for v in heights:
			relief += (v - mean) * (v - mean)
		relief = sqrt(relief / heights.size())
	return excess * PICK_W_OCEAN + pockets / cells * PICK_W_POCKETS + coast / (2.0 * G * (G - 1)) * PICK_W_COAST - relief * PICK_W_RELIEF


## Прежний выбор (до 14.11.2026): первый по спирали сдвиг, где суши в окне START_SIDE (сетка 16 × 16)
## не меньше PICK_LAND, иначе тот, где суши больше всего
static func _pick_start_legacy(w: WorldData) -> void:
	var n := w.noise
	var best := -1.0
	for k in PICK_TRIES:
		var a := k * 2.39996323
		var r := MACRO * 0.6 * sqrt(float(k))
		var mx := roundf(r * cos(a))
		var my := roundf(r * sin(a))
		var land := 0
		for sj in 16:
			for si in 16:
				var x := (si + 0.5) * START_SIDE / 16.0
				var y := (sj + 0.5) * START_SIDE / 16.0
				if raw_at(n.warpX, n.warpY, n.cont, n.mask, n.ridge, n.hill, floorf(x), floorf(y), mx, my, w.mountain_scale, w.mountain_bias, w.mountain_height, w.foothill_spread) >= SEA_RAW:
					land += 1
		var frac := land / 256.0
		if frac > best:
			best = frac
			w.macro_x = mx
			w.macro_y = my
		if frac >= PICK_LAND:
			return


## Высота относительно уровня моря: 0 — берег, суша до 1 (выше 1 редко, не выше 1.4), дно до -1 и ниже
static func normalize(v: float) -> float:
	return minf(pow((v - SEA_RAW) / (TOP_RAW - SEA_RAW), 1.25), 1.4) if v >= SEA_RAW else (v - SEA_RAW) / (SEA_RAW - BOTTOM_RAW)


## Микрорельеф на суше (h > 0); под водой (h <= 0) не действует. Тот же вид развёрнут в OuterLand.compute
static func add_micro(h: float, micro: float) -> float:
	return maxf(1e-4, h + micro * 0.006 * minf(1.0, h * 40.0)) if h > 0.0 else h


## Макрорельеф до уровня моря по прямоугольнику клеток cw × ch с углом (x0, y0), в том числе за краем карты.
## С 1.9.5 без спуска к краю карты: шум один для всей плоскости, карта — только стартовая область.
## parallel — считать полосами на всех ядрах (иначе в текущем потоке)
## include_detail — параметр запроса, а не глобальный переключатель: фоновые запросы независимы.
## false возвращает макрорельеф без слоя склонов для проб и стендов. Игровые вызовы используют true.
static func raw_rect(w: WorldData, x0: int, y0: int, cw: int, ch: int, parallel: bool, include_detail: bool = true) -> PackedFloat32Array:
	if cw <= 0 or ch <= 0:
		return PackedFloat32Array()
	var fast := Grid.fast_grid()
	if fast != null:
		var n := w.noise
		return fast.ReliefField(n.warpX.perm, n.warpY.perm, n.cont.perm, n.mask.perm, n.ridge.perm, n.hill.perm, w.macro_x, w.macro_y, x0, y0, cw, ch, w.mountain_scale, w.mountain_bias, w.mountain_height, w.foothill_spread, parallel, include_detail, GameConfig.HS, GameConfig.TILE)
	if not parallel:
		return _rows(w, x0, y0, cw, 0, ch, include_detail)
	var h := PackedFloat32Array()
	for b in Parallel.bands(ch, func(j0: int, j1: int) -> PackedFloat32Array: return _rows(w, x0, y0, cw, j0, j1, include_detail)):
		h.append_array(b)
	return h


## Строки j0..j1 прямоугольника (один кусок работы для Parallel.bands). Со слоем детализации
## основа считается с полосой DETAIL_PAD: склон в клетке берётся по соседям, поэтому
## результат не зависит от размера и положения запроса (области стыкуются без швов).
static func _rows(w: WorldData, x0: int, y0: int, cw: int, j0: int, j1: int, include_detail: bool = true) -> PackedFloat32Array:
	if not include_detail:
		return _base_rows(w, x0, y0 + j0, cw, j1 - j0)
	var P := Detail.DETAIL_PAD
	var bw := cw + 2 * P
	var base := _base_rows(w, x0 - P, y0 + j0 - P, bw, j1 - j0 + 2 * P)
	var ridge: Simplex = w.noise.ridge.clone()
	var hill: Simplex = w.noise.hill.clone()
	var out := PackedFloat32Array()
	out.resize((j1 - j0) * cw)
	for j in range(j0, j1):
		for i in cw:
			out[(j - j0) * cw + i] = Detail.apply(ridge, hill, base, bw, (j - j0 + P) * bw + i + P, x0 + i, y0 + j, SEA_RAW, TOP_RAW, GameConfig.HS, GameConfig.TILE)
	return out


## Макрорельеф без слоя детализации по прямоугольнику cw × ch с углом (x0, y0)
static func _base_rows(w: WorldData, x0: int, y0: int, cw: int, ch: int) -> PackedFloat32Array:
	var warp_x: Simplex = w.noise.warpX.clone()
	var warp_y: Simplex = w.noise.warpY.clone()
	var cont: Simplex = w.noise.cont.clone()
	var mask_n: Simplex = w.noise.mask.clone()
	var ridge: Simplex = w.noise.ridge.clone()
	var hill: Simplex = w.noise.hill.clone()
	var out := PackedFloat32Array()
	out.resize(ch * cw)
	for j in ch:
		for i in cw:
			out[j * cw + i] = raw_at(warp_x, warp_y, cont, mask_n, ridge, hill, x0 + i, y0 + j, w.macro_x, w.macro_y, w.mountain_scale, w.mountain_bias, w.mountain_height, w.foothill_spread)
	return out


## Макрорельеф в клетке (x, y); (mx, my) — сдвиг шума материков. Копия — FastGrid.ReliefField
static func raw_at(warp_x: Simplex, warp_y: Simplex, cont: Simplex, mask_n: Simplex, ridge: Simplex, hill: Simplex,
		x: float, y: float, mx: float, my: float, mountain_scale: float = 1.0, mountain_bias: float = 0.3, mountain_height: float = 1.0, foothill_spread: float = 0.0) -> float:
	var wx := warp_x.fbm(x / 240.0, y / 240.0, 3) * 25.0
	var wy := warp_y.fbm(x / 240.0 + 13.1, y / 240.0 - 7.7, 3) * 25.0
	var X := x + wx
	var Y := y + wy
	# С 3.7 мелкие октавы основания слабее внутри гор: они дробили длинные склоны
	# на короткие крутые бугры, даже у широких сглаженных массивов.
	var mountain_field := mask_n.fbm(X / (MASSIF * mountain_scale) + 7.0, Y / (MASSIF * mountain_scale) - 3.0, 2) + mountain_bias
	var t := clampf(mountain_field / MASK_EDGE, 0.0, 1.0)
	var core := t * t * (3.0 - 2.0 * t)
	# Шесть октав континентального основания (масштаб 240); detail ослабляет четыре мелкие внутри гор
	var cx := X / 240.0
	var cy := Y / 240.0
	var low := 0.0
	var high := 0.0
	var amp := 1.0
	var fr := 1.0
	var norm := 0.0
	for o in 6:
		if o < 2:
			low += amp * cont.noise(cx * fr, cy * fr)
		else:
			high += amp * cont.noise(cx * fr, cy * fr)
		norm += amp
		amp *= 0.5
		fr *= 2.0
	var detail := 1.0 - 0.85 * core
	var c := (low + high * detail) / norm
	var fine_c := high * detail / norm
	var macro := cont.fbm((X + mx) / MACRO + 91.7, (Y + my) / MACRO - 43.1, 2)
	var base := c + minf(macro * MACRO_AMP, MACRO_LIFT) + LAND_BIAS
	# smoothstep развёрнут на месте (см. Parallel)
	t = clampf((base + 0.05) / (0.25 + 0.05), 0.0, 1.0)
	var land := t * t * (3.0 - 2.0 * t)
	# С 3.3 единая широкая область подъёма: две медленные октавы вместо мелкой пятнистой маски.
	# Плавный край даёт предгорья, сильная середина объединяет несколько гребней в один массив.
	# Берег определяется окончательной высотой, а не обрезает весь массив
	# по мелкому шуму континентов: такая маска превращала подножие в стену.
	var mask := core
	# Характер местности (с 1.9.8): медленный шум делит сушу на равнины и холмистые края. На равнинах
	# слабые окраины гор стихают (там, где горы во всю силу, массив остаётся), а вокруг гор холмистость
	# растёт сама (предгорья): равнина переходит в горы через холмы, без резкой границы
	t = clampf((hill.fbm(X / CHARACTER + 41.9, Y / CHARACTER - 66.1, 2) + 0.15) / 0.4, 0.0, 1.0)
	var rough := t * t * (3.0 - 2.0 * t)
	# Общие понижения проходят через холмы и предгорья, разрывая пояс у подножия.
	t = clampf((base - 0.18) / 0.17, 0.0, 1.0)
	var inland := t * t * (3.0 - 2.0 * t)
	t = clampf(1.0 - absf(ridge.noise(X / VALLEY + 5.3, Y / VALLEY - 9.4)) / VALLEY_WIDTH, 0.0, 1.0)
	var valley := t * t * (3.0 - 2.0 * t)
	# Пояс шире горной маски и неодинаков по периметру: зависит от сида и местных холмов.
	var width := 0.1 + 0.4 * foothill_spread * (0.6 + 0.4 * rough)
	t = clampf((mountain_field + width) / (MASK_EDGE * 0.65 + width), 0.0, 1.0)
	var foothills := t * t * (3.0 - 2.0 * t) * (1.0 - core) * foothill_spread * (0.5 + 0.5 * rough) * (1.0 - 0.5 * valley)
	t = clampf((mask - FOOTHILLS) / FOOTHILLS, 0.0, 1.0)
	mask *= rough + (1.0 - rough) * mask * mask
	rough = maxf(rough, t * t * (3.0 - 2.0 * t))
	rough += (1.0 - rough) * foothills
	# Суша на равнинах ниже и положе: высота над морем сжата до PLAIN_LIFT. Берега от этого не сдвигаются
	# С GEO 7 вглубь суши мелкие октавы основания слабее (до INLAND_DETAIL): каждая добавляла столько же
	# уклона, сколько крупная, и склоны на масштабе 30–60 м были смяты до 100–150 %. Берег (inland = 0) прежний
	var h := (base - fine_c * (1.0 - INLAND_DETAIL) * inland) * 0.55
	if h > SEA_RAW:
		h = SEA_RAW + (h - SEA_RAW) * (PLAIN_LIFT + (1.0 - PLAIN_LIFT) * rough)
	var hills := hill.fbm(X / 40.0, Y / 40.0, 4)
	if foothills > 0.0:
		# Холмы предгорий шире вместе с гребнями (с GEO 7)
		var foot_scale := 100.0 * maxf(mountain_scale, mountain_height / HEIGHT_PER_WIDTH)
		var rolling := hill.fbm(X / foot_scale + 32.4, Y / foot_scale - 18.6, 2)
		hills += (rolling - hills) * foothills
		h += foothills * (FOOTHILL_LIFT + 0.08 * rolling) * mountain_height
	# Мелкие холмы затухают внутри массива, оставляя место широким склонам и плечам.
	h += hills * HILL_AMP * (0.3 + land) * (PLAIN_HILLS + (1.0 - PLAIN_HILLS) * rough) * (1.0 - mask * 0.85)
	# Reuse the existing 20–160 m hill octaves and broad dry valley field.
	# Low amplitude, no extra noise calls; protect shore connections and massifs.
	var calm := (1.0 - rough) * (1.0 - mask) * (1.0 - mask) * (1.0 - foothills)
	var shore_fade := smoothstep(0.015, 0.08, h - SEA_RAW)
	h += (hills * 0.025 - valley * 0.008) * calm * shore_fade
	# То же поле понижений, что ослабляет предгорный подъём.
	h -= valley * VALLEY_DEPTH * rough * inland
	if mask > 0.0:
		var wide := mountain_scale * maxf(1.0, mountain_height / (mountain_scale * HEIGHT_PER_WIDTH))
		var relief := mountain(ridge, hill, (x + wx * MOUNTAIN_WARP) / wide, (y + wy * MOUNTAIN_WARP) / wide, inland)
		# An independent continental dome would bury the lower branches. Drain
		# its inland foundation into the SAME valleys; preserve the shoreline.
		var support := smoothstep(0.12, 0.55, relief)
		h -= maxf(0.0, h - SEA_RAW) * 0.60 * core * inland * (1.0 - support)
		h += relief * mask * MOUNTAIN_AMP * mountain_height
	return h


## Горы: связанный скелет в мировых координатах продолжается за краем карты.
## Медленные шумы масштаба MASSIF (около 2,6 км) задают область подъёма и характер: направление гребней,
## высоту и острые молодые или сглаженные старые формы. Копия — FastGrid.Mountain
const MASSIF := 650.0
const MOUNTAIN_AMP := 1.0
## Общее основание под гребнями (с 3.3). Растёт вместе с маской массива, даже в седловинах.
## У возвышенностей ниже; часть высоты гребня отдана основанию, чтобы не раздувать вершины.
const MASSIF_BASE := 0.15
const CREST_SHARE := 1.10
## Горы искривлены слабее остального рельефа: при полном искривлении гребни вытягиваются в одинаковые
## волнистые полосы
const MOUNTAIN_WARP := 0.35
## Направления гребней 0°, 60° и 120° (cos, sin): массив берёт одно, между массивами плавный переход
const DIR_C: Array[float] = [1.0, 0.5, -0.5]
const DIR_S: Array[float] = [0.0, 0.8660254037844386, 0.8660254037844386]
## Во сколько раз один склон главного гребня круче другого (у острых гор; у сглаженных склоны равны)
const ASYM := 1.8
## Предел гребня с вершиной (без вершин гребень до 1)
const PEAK_CAP := 1.05
## Доля шума формы, с которой массив считается острым; с 3.2 острые массивы реже
const SHARP_SHIFT := 0.28
## Возвышенности (с 3.0): медленный шум масштаба MASSIF превращает часть массивов в холмистые
## возвышенности и широкие склоны: форма гребня шире (r вместо r^1.5..r^2), высота UPLAND_AMP от горной,
## мелких гребней меньше (UPLAND_SMOOTH)
## С 3.2 возвышенностей больше, их высота ниже: прежние гребни становятся широкими холмами
const UPLAND_SHIFT := 0.24
const UPLAND_AMP := 0.3
## Какую долю мелких гребней и отрогов возвышенность теряет
const UPLAND_SMOOTH := 0.8
## Горы выше PEAK_KNEE растут всё медленнее (PEAK_SOFT — насколько плавно): высоких пиков меньше, но они есть
const PEAK_KNEE := 0.50
const PEAK_SOFT := 0.40


static func mountain(ridge: Simplex, hill: Simplex, X: float, Y: float, inland: float = 1.0) -> float:
	var s := clampf(ridge.fbm(X / MASSIF + 31.4, Y / MASSIF - 17.2, 2) * 3.0 + 1.5, 0.0, 2.999)
	var k := int(s)
	var t := clampf((s - k - 0.3) / 0.4, 0.0, 1.0)
	var f := t * t * (3.0 - 2.0 * t)
	t = clampf((hill.fbm(X / MASSIF + 63.2, Y / MASSIF + 12.5, 2) + 0.25 - SHARP_SHIFT) / 0.5, 0.0, 1.0)
	var sharp := t * t * (3.0 - 2.0 * t)
	# Возвышенность вместо гор (с 3.0): те же гребни, но ниже, с широкими склонами и почти без мелких гребней
	t = clampf((hill.fbm(X / MASSIF + 25.1, Y / MASSIF - 71.3, 2) + UPLAND_SHIFT) / 0.4, 0.0, 1.0)
	var up := t * t * (3.0 - 2.0 * t)
	# С 3.2 холмистый характер смягчает и форму склона, а не только высоту гребня
	sharp *= 1.0 - up
	var structure := inland * (1.0 - 0.62 * up)
	var asym := 1.0 + (ASYM - 1.0) * sharp + 0.22 * structure
	# С 3.1 мелкая складчатость зависит и от формы массива: у сглаженных гор главный гребень
	# цельный, у острых остаются скалистые детали. Возвышенности по-прежнему теряют большую их часть
	var fine := (1.0 - UPLAND_SMOOTH * up) * (0.35 + 0.65 * sharp)
	var r := 0.0
	var last_crest := _crest(ridge, X, Y, DIR_C[2], DIR_S[2], asym, fine, 1.0 - 0.55 * up, structure) if k == 2 else 0.0
	if f < 1.0:
		r += (last_crest if k == 2 else _crest(ridge, X, Y, DIR_C[k], DIR_S[k], asym, fine, 1.0 - 0.55 * up, structure)) * (1.0 - f)
	if f > 0.0:
		r += (last_crest if k == 2 else _crest(ridge, X, Y, DIR_C[mini(k + 1, 2)], DIR_S[mini(k + 1, 2)], asym, fine, 1.0 - 0.55 * up, structure)) * f
	# Вершины и седловины: высота гребня меняется вдоль него. Выше PEAK_CAP не поднимается, иначе
	# у острых гор вырастают тонкие иглы
	var pk := hill.fbm(X / 150.0 + 17.7, Y / 150.0 - 29.3, 2)
	r = minf(r * (1.0 + (0.35 + 0.70 * structure) * pk * r), PEAK_CAP)
	# Острые горы — узкие гребни (r^2), сглаженные — широкие (r^1.5)
	var q := sqrt(r) * r
	t = clampf((hill.fbm(X / MASSIF - 8.3, Y / MASSIF + 44.6, 2) + 0.3) / 0.6, 0.0, 1.0)
	var amp := 0.6 + 0.55 * t * t * (3.0 - 2.0 * t)
	var m := (q + (r * r - q) * sharp) * amp
	m += (r * UPLAND_AMP - m) * up
	# Incise inland foundations only: lowering coastal saddles can flood dry road links.
	var foundation := 1.0 - 0.45 * inland * (1.0 - up) * (1.0 - smoothstep(0.12, 0.65, r))
	m = MASSIF_BASE * amp * (1.0 - (1.0 - UPLAND_AMP) * up) * foundation + m * CREST_SHARE
	# Мягкий предел высоты: выше PEAK_KNEE рост замедляется, пик скругляется, а не обрезается
	if m > PEAK_KNEE:
		m = PEAK_KNEE + (m - PEAK_KNEE) / (1.0 + (m - PEAK_KNEE) / PEAK_SOFT)
	return m


## Разреженный скелет хребтов: извилистый главный водораздел и неравные
## боковые рёбра, привязанные к нему концами. Геометрия определяется расстоянием
## до этих линий; долины — промежутки между рёбрами, а не отдельный шумовый вырез.
## Узлы адресуются мировыми координатами через перестановку сида. Нет состояния,
## растровой эрозии, границ окна, фиксированного набора вершин или расхода RNG.
static func _crest(ridge: Simplex, X: float, Y: float, dc: float, ds: float, asym: float, fine: float, interior: float = 0.0, structure: float = 0.0) -> float:
	var along := X * dc + Y * ds
	var across := Y * dc - X * ds
	var band := floori(across / 260.0)
	var knot := floori(along / 130.0)
	var height := 0.0
	for row in range(band - 2, band + 3):
		if absf(across - row * 260.0) > 480.0: continue
		var center := _divide(ridge, row, along)
		var offset := across - center
		var width := 52.0 + 28.0 * (1.0 - interior)
		var d := offset * (asym if offset > 0.0 else 1.0 / asym) / width
		var peak := _divide_height(ridge, row, along)
		var crown := maxf(0.0, 1.0 - d * d / 9.0)
		var local := peak * crown * crown * crown * crown
		# Каждый отрог начинается на водоразделе; противоположные борта имеют
		# разные узлы, длины, ширины и направление, без симметричного «гребешка».
		for column in range(knot - 2, knot + 3):
			for side: float in [-1.0, 1.0]:
				var salt := 17 if side < 0.0 else 83
				var root := (column + 0.15 + 0.7 * _node(ridge, column, row, salt)) * 130.0
				var root_across := _divide(ridge, row, root)
				var dx := (_node(ridge, column, row, salt + 1) - 0.5) * 240.0
				var dy := side * (125.0 + 105.0 * _node(ridge, column, row, salt + 2))
				var px := along - root
				var py := across - root_across
				var t := clampf((px * dx + py * dy) / (dx * dx + dy * dy), 0.0, 1.0)
				var bow := 4.0 * t * (1.0 - t) * (_node(ridge, column, row, salt + 4) - 0.5) * 55.0
				var length := sqrt(dx * dx + dy * dy)
				var ex := px - dx * t + dy / length * bow
				var ey := py - dy * t - dx / length * bow
				var rib_width := 22.0 + 23.0 * _node(ridge, column, row, salt + 3) + 12.0 * (1.0 - interior)
				var face := 1.0 + 0.65 * fine * structure * smoothstep(-0.2, 0.25, (ex * -dy + ey * dx) / (length * rib_width))
				var profile := maxf(0.0, 1.0 - (ex * ex + ey * ey) * face / (3.0 * rib_width * rib_width))
				# Resistant beds form a short headwall with a broad shoulder, only
				# midway down selected spurs. The lip follows the rib coordinate,
				# never an absolute height or a ring around the whole mountain.
				var competence := smoothstep(0.30, 0.85, _node(ridge, column, row, salt + 5))
				var rock_face := competence * structure * (0.35 + 0.65 * fine) * smoothstep(0.10, 0.30, t) * (1.0 - smoothstep(0.72, 0.95, t))
				var lip := 0.28 + 0.24 * t
				var worn := profile * profile
				var bedrock := 0.38 * worn + 0.62 * smoothstep(lip - 0.14, lip + 0.14, profile)
				var rib := _divide_height(ridge, row, root) * (1.0 - 0.88 * t) * lerpf(worn, bedrock, rock_face)
				# Smooth union keeps the roots seated in the parent ridge.
				local = _join(local, rib, 0.045)
		# Broad talus foot and a steeper upper face, varying between ranges.
		var shoulder := smoothstep(0.12, 0.32, local) * (1.0 - smoothstep(0.32, 0.55, local))
		local += (0.31 - local) * shoulder * (0.15 + 0.35 * fine) * structure
		height = _join(height, local, 0.035)
	return height


static func _node(ridge: Simplex, x: int, y: int, salt: int) -> float:
	return ridge.perm[(x + ridge.perm[(y + salt) & 255]) & 255] / 255.0


static func _divide(ridge: Simplex, row: int, along: float) -> float:
	var u := along / 280.0
	var k := floori(u)
	var t := u - k
	t = t * t * (3.0 - 2.0 * t)
	return row * 260.0 + lerpf(_node(ridge, k, row, 131), _node(ridge, k + 1, row, 131), t) * 190.0 - 95.0


static func _divide_height(ridge: Simplex, row: int, along: float) -> float:
	var u := along / 150.0
	var k := floori(u)
	var t := u - k
	t = t * t * (3.0 - 2.0 * t)
	return 0.58 + 0.44 * lerpf(_node(ridge, k, row, 211), _node(ridge, k + 1, row, 211), t)


static func _join(a: float, b: float, width: float) -> float:
	width = minf(width, minf(a, b))
	if width <= 0.0: return maxf(a, b)
	var h := maxf(0.0, 1.0 - absf(a - b) / width)
	return maxf(a, b) + width * h * h * 0.25
