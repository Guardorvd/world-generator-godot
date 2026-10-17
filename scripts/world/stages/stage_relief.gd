class_name StageRelief
extends RefCounted
## Этап 1. Макрорельеф: континенты, хребты, холмы, уровень моря, микрорельеф суши.
## Пишет: w.h — высота клетки (0 — уровень моря, суша до 1, дно до -1).
## Строки карты независимы, поэтому считаются параллельно полосами.

const PROGRESS := 0.02
const LABEL := "Формирование континентов"


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var N := w.N
	var h := PackedFloat32Array()
	for b in Parallel.bands(H, func(y0: int, y1: int) -> PackedFloat32Array: return _rows(w, y0, y1)):
		h.append_array(b)

	# Уровень моря по процентилю, чтобы суша занимала заданную долю карты
	var sorted := h.duplicate()
	sorted.sort()
	var sea := sorted[floori(N * (1.0 - w.land_frac))]
	var h_max := sorted[N - 1]
	var h_min := sorted[0]
	for i in N:
		var v := h[i]
		h[i] = pow((v - sea) / (h_max - sea), 1.25) if v >= sea else (v - sea) / (sea - h_min)
	# Микрорельеф суши: мелкие неровности, из-за которых реки на равнинах петляют
	var micro := Parallel.fbm_field(w, w.noise.micro, 9.0, 2)
	for i in N:
		if h[i] > 0.0:
			h[i] = maxf(1e-4, h[i] + micro[i] * 0.006 * minf(1.0, h[i] * 40.0))
	w.h = h


static func _rows(w: WorldData, y0: int, y1: int) -> PackedFloat32Array:
	var W := w.W
	var H := w.H
	var warp_x: Simplex = w.noise.warpX.clone()
	var warp_y: Simplex = w.noise.warpY.clone()
	var cont: Simplex = w.noise.cont.clone()
	var mask_n: Simplex = w.noise.mask.clone()
	var ridge: Simplex = w.noise.ridge.clone()
	var hill: Simplex = w.noise.hill.clone()
	var out := PackedFloat32Array()
	out.resize((y1 - y0) * W)
	for y in range(y0, y1):
		for x in W:
			var wx := warp_x.fbm(x / 170.0, y / 170.0, 3) * 45.0
			var wy := warp_y.fbm(x / 170.0 + 13.1, y / 170.0 - 7.7, 3) * 45.0
			var X := x + wx
			var Y := y + wy
			var c := cont.fbm(X / 240.0, Y / 240.0, 6)
			var dx := absf((float(x) / (W - 1)) * 2.0 - 1.0)
			var dy := absf((float(y) / (H - 1)) * 2.0 - 1.0)
			var d := sqrt(sqrt(dx * dx * dx * dx + dy * dy * dy * dy))
			# smoothstep развёрнут на месте (см. Parallel)
			var t := clampf((d - 0.55) / (1.0 - 0.55), 0.0, 1.0)
			var fall := t * t * (3.0 - 2.0 * t)
			var base := c + 0.1 - fall * 0.75
			t = clampf((base - -0.05) / (0.25 - -0.05), 0.0, 1.0)
			var land := t * t * (3.0 - 2.0 * t)
			t = clampf((mask_n.fbm(X / 280.0 + 7.0, Y / 280.0 - 3.0, 3) - -0.15) / (0.3 - -0.15), 0.0, 1.0)
			var mask := t * t * (3.0 - 2.0 * t)
			var r := ridge.ridged(X / 120.0, Y / 120.0, 5)
			var hills := hill.fbm(X / 40.0, Y / 40.0, 4)
			out[(y - y0) * W + x] = base * 0.55 + r * r * mask * land * 0.9 + hills * 0.05 * (0.3 + land)
	return out
