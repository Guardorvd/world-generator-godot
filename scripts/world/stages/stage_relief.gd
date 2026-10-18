class_name StageRelief
extends RefCounted
## Этап 1. Макрорельеф: континенты, горные массивы (с 1.9.7, см. mountain) и возвышенности (с 3.0), равнины и холмистые края (с 1.9.8), уровень моря, микрорельеф суши.
## Пишет: w.macro_x, macro_y — сдвиг шума материков (место старта), w.h — высота клетки (0 — уровень моря,
## суша до 1, дно до -1).
## Строки карты независимы, поэтому считаются параллельно полосами. В сборке Godot .NET тот же цикл
## идёт на C# (FastGrid.ReliefField), результат тот же бит в бит.

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
## Ширина подъёма от равнины к горам (в долях шума гор)
const MASK_EDGE := 0.9
## Небольшие долины: масштаб шума в клетках, ширина (в долях шума) и глубина
const VALLEY := 260.0
const VALLEY_WIDTH := 0.16
const VALLEY_DEPTH := 0.06
## Сколько мест старта пробовать и какая доля суши в стартовой области подходит
const PICK_TRIES := 48
## С 2.9 суши больше: шум материков сдвинут вверх на LAND_BIAS (было 0.1), окно — первое по спирали,
## где суши хотя бы PICK_LAND. Верхней границы нет: сколько суши выше неё, решает сам шум
const LAND_BIAS := 0.18
const PICK_LAND := 0.6


## Рельеф карты: стартовая область, нормировка по уровню моря, микрорельеф суши
static func run(w: WorldData) -> void:
	var N := w.N
	_pick_start(w)
	var h := raw_rect(w, 0, 0, w.W, w.H, true)
	for i in N:
		h[i] = normalize(h[i])
	# Микрорельеф суши: мелкие неровности, из-за которых реки на равнинах петляют
	var micro := Parallel.fbm_field(w.W, w.H, w.noise.micro, 9.0, 2)
	for i in N:
		h[i] = add_micro(h[i], micro[i])
	w.h = h


## Стартовая область — окно в бесконечный мир. Мир один на сид, а окно выбирается сдвигом шума
## материков: пробуем сдвиги по спирали и берём первый, где доля суши в окне (по сетке 16 × 16 точек)
## не меньше PICK_LAND, иначе тот, где суши больше всего. Шумы мельче материков не сдвигаются
static func _pick_start(w: WorldData) -> void:
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
				var x := (si + 0.5) * w.W / 16.0
				var y := (sj + 0.5) * w.H / 16.0
				if raw_at(n.warpX, n.warpY, n.cont, n.mask, n.ridge, n.hill, floorf(x), floorf(y), mx, my) >= SEA_RAW:
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
static func raw_rect(w: WorldData, x0: int, y0: int, cw: int, ch: int, parallel: bool) -> PackedFloat32Array:
	var fast := Grid.fast_grid()
	if fast != null:
		var n := w.noise
		return fast.ReliefField(n.warpX.perm, n.warpY.perm, n.cont.perm, n.mask.perm, n.ridge.perm, n.hill.perm, w.macro_x, w.macro_y, x0, y0, cw, ch)
	if not parallel:
		return _rows(w, x0, y0, cw, 0, ch)
	var h := PackedFloat32Array()
	for b in Parallel.bands(ch, func(j0: int, j1: int) -> PackedFloat32Array: return _rows(w, x0, y0, cw, j0, j1)):
		h.append_array(b)
	return h


## Строки j0..j1 прямоугольника (один кусок работы для Parallel.bands)
static func _rows(w: WorldData, x0: int, y0: int, cw: int, j0: int, j1: int) -> PackedFloat32Array:
	var warp_x: Simplex = w.noise.warpX.clone()
	var warp_y: Simplex = w.noise.warpY.clone()
	var cont: Simplex = w.noise.cont.clone()
	var mask_n: Simplex = w.noise.mask.clone()
	var ridge: Simplex = w.noise.ridge.clone()
	var hill: Simplex = w.noise.hill.clone()
	var out := PackedFloat32Array()
	out.resize((j1 - j0) * cw)
	for j in range(j0, j1):
		for i in cw:
			out[(j - j0) * cw + i] = raw_at(warp_x, warp_y, cont, mask_n, ridge, hill, x0 + i, y0 + j, w.macro_x, w.macro_y)
	return out


## Макрорельеф в клетке (x, y); (mx, my) — сдвиг шума материков. Копия — FastGrid.ReliefField
static func raw_at(warp_x: Simplex, warp_y: Simplex, cont: Simplex, mask_n: Simplex, ridge: Simplex, hill: Simplex,
		x: float, y: float, mx: float, my: float) -> float:
	var wx := warp_x.fbm(x / 170.0, y / 170.0, 3) * 45.0
	var wy := warp_y.fbm(x / 170.0 + 13.1, y / 170.0 - 7.7, 3) * 45.0
	var X := x + wx
	var Y := y + wy
	var c := cont.fbm(X / 240.0, Y / 240.0, 6)
	var macro := cont.fbm((X + mx) / MACRO + 91.7, (Y + my) / MACRO - 43.1, 2)
	var base := c + minf(macro * MACRO_AMP, MACRO_LIFT) + LAND_BIAS
	# smoothstep развёрнут на месте (см. Parallel)
	var t := clampf((base + 0.05) / (0.25 + 0.05), 0.0, 1.0)
	var land := t * t * (3.0 - 2.0 * t)
	# Где горы. Медленный шум размера сдвигает порог: где он высок, массив большой, где низок — небольшая группа гор
	var lo := -0.15 - mask_n.fbm(X / MASSIF - 21.3, Y / MASSIF + 5.9, 2) * 0.3
	# С 1.9.8 подъём к горам вдвое шире (MASK_EDGE вместо 0.45), середина подъёма на прежнем месте:
	# иначе у края массива на ровном месте вырастал уступ в десятки метров
	t = clampf((mask_n.fbm(X / 280.0 + 7.0, Y / 280.0 - 3.0, 3) - lo + (MASK_EDGE - 0.45) * 0.5) / MASK_EDGE, 0.0, 1.0)
	var mask := t * t * (3.0 - 2.0 * t) * land
	# Характер местности (с 1.9.8): медленный шум делит сушу на равнины и холмистые края. На равнинах
	# слабые окраины гор стихают (там, где горы во всю силу, массив остаётся), а вокруг гор холмистость
	# растёт сама (предгорья): равнина переходит в горы через холмы, без резкой границы
	t = clampf((hill.fbm(X / CHARACTER + 41.9, Y / CHARACTER - 66.1, 2) + 0.15) / 0.4, 0.0, 1.0)
	var rough := t * t * (3.0 - 2.0 * t)
	t = clampf((mask - FOOTHILLS) / FOOTHILLS, 0.0, 1.0)
	mask *= rough + (1.0 - rough) * mask * mask
	rough = maxf(rough, t * t * (3.0 - 2.0 * t))
	# Суша на равнинах ниже и положе: высота над морем сжата до PLAIN_LIFT. Берега от этого не сдвигаются
	var h := base * 0.55
	if h > SEA_RAW:
		h = SEA_RAW + (h - SEA_RAW) * (PLAIN_LIFT + (1.0 - PLAIN_LIFT) * rough)
	var hills := hill.fbm(X / 40.0, Y / 40.0, 4)
	# С 3.2 мелкие холмы слабее внутри массива: широкие склоны не покрываются частыми буграми
	h += hills * HILL_AMP * (0.3 + land) * (PLAIN_HILLS + (1.0 - PLAIN_HILLS) * rough) * (1.0 - mask * 0.6)
	t = clampf((base - 0.18) / 0.17, 0.0, 1.0)
	var inland := t * t * (3.0 - 2.0 * t)
	# Небольшие долины в холмистых краях: узкие ложбины вдоль линий нуля шума
	t = clampf(1.0 - absf(ridge.noise(X / VALLEY + 5.3, Y / VALLEY - 9.4)) / VALLEY_WIDTH, 0.0, 1.0)
	h -= t * t * (3.0 - 2.0 * t) * VALLEY_DEPTH * rough * inland
	if mask > 0.0:
		h += mountain(ridge, hill, x + wx * MOUNTAIN_WARP, y + wy * MOUNTAIN_WARP) * mask * MOUNTAIN_AMP
	return h


## Горы (с 1.9.7). Как и весь рельеф, функция мировых координат, поэтому за краем карты горы продолжаются.
## Медленные шумы масштаба MASSIF (около 2,5 км) дают каждому массиву свой характер: направление гребней,
## высоту и острые молодые или сглаженные старые формы. Копия — FastGrid.Mountain
const MASSIF := 650.0
const MOUNTAIN_AMP := 1.0
## Горы искривлены слабее остального рельефа: при полном искривлении гребни вытягиваются в одинаковые
## волнистые полосы
const MOUNTAIN_WARP := 0.35
## Гребни вытянуты: длина и ширина пятна шума в клетках
const RIDGE_ALONG := 220.0
const RIDGE_ACROSS := 125.0
## Направления гребней 0°, 60° и 120° (cos, sin): массив берёт одно, между массивами плавный переход
const DIR_C: Array[float] = [1.0, 0.5, -0.5]
const DIR_S: Array[float] = [0.0, 0.8660254037844386, 0.8660254037844386]
## Во сколько раз один склон главного гребня круче другого (у острых гор; у сглаженных склоны равны)
const ASYM := 1.8
## Предел гребня с вершиной (без вершин гребень до 1)
const PEAK_CAP := 1.05
## Скругление главного гребня (в долях шума): без него гребень — острый излом, а вершины — иглы
const CREST_ROUND := 0.12
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
const PEAK_KNEE := 0.36
const PEAK_SOFT := 0.25


static func mountain(ridge: Simplex, hill: Simplex, X: float, Y: float) -> float:
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
	var asym := 1.0 + (ASYM - 1.0) * sharp
	# С 3.1 мелкая складчатость зависит и от формы массива: у сглаженных гор главный гребень
	# цельный, у острых остаются скалистые детали. Возвышенности по-прежнему теряют большую их часть
	var fine := (1.0 - UPLAND_SMOOTH * up) * (0.35 + 0.65 * sharp)
	var r := 0.0
	if f < 1.0:
		r += _crest(ridge, X, Y, DIR_C[k], DIR_S[k], asym, fine) * (1.0 - f)
	if f > 0.0:
		r += _crest(ridge, X, Y, DIR_C[mini(k + 1, 2)], DIR_S[mini(k + 1, 2)], asym, fine) * f
	# Вершины и седловины: высота гребня меняется вдоль него. Выше PEAK_CAP не поднимается, иначе
	# у острых гор вырастают тонкие иглы
	r = minf(r * (1.0 + 0.35 * hill.fbm(X / 85.0 + 17.7, Y / 85.0 - 29.3, 2) * r), PEAK_CAP)
	# Отроги: мелкие гребни на склонах (на гребне и у подножия их нет)
	var sp := ridge.ridged(X / 70.0 - 57.1, Y / 70.0 + 11.9, 2)
	r = maxf(0.0, r + sp * sp * maxf(0.0, r * (1.0 - r)) * 0.55 * fine)
	# Острые горы — узкие гребни (r^2), сглаженные — широкие (r^1.5)
	var q := sqrt(r) * r
	t = clampf((hill.fbm(X / MASSIF - 8.3, Y / MASSIF + 44.6, 2) + 0.3) / 0.6, 0.0, 1.0)
	var amp := 0.6 + 0.55 * t * t * (3.0 - 2.0 * t)
	var m := (q + (r * r - q) * sharp) * amp
	m += (r * UPLAND_AMP - m) * up
	# Мягкий предел высоты: выше PEAK_KNEE рост замедляется, пик скругляется, а не обрезается
	if m > PEAK_KNEE:
		m = PEAK_KNEE + (m - PEAK_KNEE) / (1.0 + (m - PEAK_KNEE) / PEAK_SOFT)
	return m


## Гребень одного направления (dc, ds) = (cos, sin): ridged-шум в повёрнутых и вытянутых координатах. Первая октава (главный
## гребень) несимметрична: с одной стороны склон круче в asym раз. С 3.1 больше веса у главного гребня,
## мелких октав две вместо трёх, их вес убывает быстрее: они уточняют склон, а не дробят его на бугры
static func _crest(ridge: Simplex, X: float, Y: float, dc: float, ds: float, asym: float, fine: float) -> float:
	var u := (X * dc + Y * ds) / RIDGE_ALONG
	var v := (Y * dc - X * ds) / RIDGE_ACROSS
	var a := 0.6
	var fq := 1.0
	var s := 0.0
	var wt := 1.0
	for o in 4:
		var n := ridge.noise(u * fq, v * fq)
		# С 3.1 асимметрия до скругления: умножение e давало разные высоты справа и слева
		# от n = 0, то есть отвесную ступеньку вдоль гребня даже при плавном шуме
		if o == 0:
			n *= asym if n > 0.0 else 1.0 / asym
		var e := sqrt(n * n + CREST_ROUND * CREST_ROUND)
		var val := maxf(0.0, 1.0 - e)
		val *= val
		val *= wt
		wt = minf(1.0, maxf(0.0, val * 2.0))
		s += val * a * (fine if o >= 2 else 1.0)
		fq *= 2.1
		a = 0.25 if o == 0 else a * 0.3
	return s
