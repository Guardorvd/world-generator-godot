class_name StageRelief
extends RefCounted
## Этап 1. Макрорельеф: континенты, хребты, холмы, уровень моря, микрорельеф суши.
## Пишет: w.h — высота клетки (0 — уровень моря, суша до 1, дно до -1), w.sea_raw, top_raw, bottom_raw.
## Строки карты независимы, поэтому считаются параллельно полосами. В сборке Godot .NET тот же цикл
## идёт на C# (FastGrid.ReliefField), результат тот же бит в бит.

const PROGRESS := 0.02
const LABEL := "Формирование континентов"


static func run(w: WorldData) -> void:
	var N := w.N
	var h := raw_rect(w, 0, 0, w.W, w.H, true)

	# Уровень моря по процентилю, чтобы суша занимала заданную долю карты. Те же уровни берёт
	# рельеф за краем карты (OuterLand), поэтому на границе нет ступеньки
	var sorted := h.duplicate()
	sorted.sort()
	w.sea_raw = sorted[floori(N * (1.0 - w.land_frac))]
	w.top_raw = sorted[N - 1]
	w.bottom_raw = sorted[0]
	for i in N:
		h[i] = normalize(w, h[i])
	# Микрорельеф суши: мелкие неровности, из-за которых реки на равнинах петляют
	var micro := Parallel.fbm_field(w, w.noise.micro, 9.0, 2)
	for i in N:
		h[i] = add_micro(h[i], micro[i])
	w.h = h


## Высота относительно уровня моря: 0 — берег, суша до 1, дно до -1 (за картой бывает и выше, и ниже)
static func normalize(w: WorldData, v: float) -> float:
	return pow((v - w.sea_raw) / (w.top_raw - w.sea_raw), 1.25) if v >= w.sea_raw else (v - w.sea_raw) / (w.sea_raw - w.bottom_raw)


static func add_micro(h: float, micro: float) -> float:
	return maxf(1e-4, h + micro * 0.006 * minf(1.0, h * 40.0)) if h > 0.0 else h


## Макрорельеф до уровня моря по прямоугольнику клеток cw × ch с углом (x0, y0), в том числе за краем карты.
## С 1.9.5 без спуска к краю карты: шум один для всей плоскости, карта — только стартовая область.
## parallel — считать полосами на всех ядрах (иначе в текущем потоке)
static func raw_rect(w: WorldData, x0: int, y0: int, cw: int, ch: int, parallel: bool) -> PackedFloat32Array:
	var fast := Grid.fast_grid()
	if fast != null:
		var n := w.noise
		return fast.ReliefField(n.warpX.perm, n.warpY.perm, n.cont.perm, n.mask.perm, n.ridge.perm, n.hill.perm, x0, y0, cw, ch)
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
		var y := y0 + j
		for i in cw:
			var x := x0 + i
			var wx := warp_x.fbm(x / 170.0, y / 170.0, 3) * 45.0
			var wy := warp_y.fbm(x / 170.0 + 13.1, y / 170.0 - 7.7, 3) * 45.0
			var X := x + wx
			var Y := y + wy
			var c := cont.fbm(X / 240.0, Y / 240.0, 6)
			var base := c + 0.1
			# smoothstep развёрнут на месте (см. Parallel)
			var t := clampf((base - -0.05) / (0.25 - -0.05), 0.0, 1.0)
			var land := t * t * (3.0 - 2.0 * t)
			t = clampf((mask_n.fbm(X / 280.0 + 7.0, Y / 280.0 - 3.0, 3) - -0.15) / (0.3 - -0.15), 0.0, 1.0)
			var mask := t * t * (3.0 - 2.0 * t)
			var r := ridge.ridged(X / 120.0, Y / 120.0, 5)
			var hills := hill.fbm(X / 40.0, Y / 40.0, 4)
			out[(j - j0) * cw + i] = base * 0.55 + r * r * mask * land * 0.9 + hills * 0.05 * (0.3 + land)
	return out
