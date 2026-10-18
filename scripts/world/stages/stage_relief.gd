class_name StageRelief
extends RefCounted
## Этап 1. Макрорельеф: континенты, хребты, холмы, уровень моря, микрорельеф суши.
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
## Сколько мест старта пробовать и какая доля суши в стартовой области подходит
const PICK_TRIES := 48
const PICK_MIN := 0.36
const PICK_MAX := 0.6


static func run(w: WorldData) -> void:
	var N := w.N
	_pick_start(w)
	var h := raw_rect(w, 0, 0, w.W, w.H, true)
	for i in N:
		h[i] = normalize(h[i])
	# Микрорельеф суши: мелкие неровности, из-за которых реки на равнинах петляют
	var micro := Parallel.fbm_field(w, w.noise.micro, 9.0, 2)
	for i in N:
		h[i] = add_micro(h[i], micro[i])
	w.h = h


## Стартовая область — окно в бесконечный мир. Мир один на сид, а окно выбирается сдвигом шума
## материков: пробуем сдвиги по спирали и берём первый, где доля суши в окне (по сетке 16 × 16 точек)
## подходит для игры, иначе самый близкий к w.land_frac. Шумы мельче материков не сдвигаются
static func _pick_start(w: WorldData) -> void:
	var n := w.noise
	var best := INF
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
		var miss := absf(frac - w.land_frac)
		if miss < best:
			best = miss
			w.macro_x = mx
			w.macro_y = my
		if frac >= PICK_MIN and frac <= PICK_MAX:
			return


## Высота относительно уровня моря: 0 — берег, суша до 1 (выше 1 редко, не выше 1.4), дно до -1 и ниже
static func normalize(v: float) -> float:
	return minf(pow((v - SEA_RAW) / (TOP_RAW - SEA_RAW), 1.25), 1.4) if v >= SEA_RAW else (v - SEA_RAW) / (SEA_RAW - BOTTOM_RAW)


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
	var base := c + minf(macro * MACRO_AMP, MACRO_LIFT) + 0.1
	# smoothstep развёрнут на месте (см. Parallel)
	var t := clampf((base - -0.05) / (0.25 - -0.05), 0.0, 1.0)
	var land := t * t * (3.0 - 2.0 * t)
	t = clampf((mask_n.fbm(X / 280.0 + 7.0, Y / 280.0 - 3.0, 3) - -0.15) / (0.3 - -0.15), 0.0, 1.0)
	var mask := t * t * (3.0 - 2.0 * t)
	var r := ridge.ridged(X / 120.0, Y / 120.0, 5)
	var hills := hill.fbm(X / 40.0, Y / 40.0, 4)
	return base * 0.55 + r * r * mask * land * 0.9 + hills * 0.05 * (0.3 + land)
