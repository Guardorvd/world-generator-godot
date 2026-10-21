class_name StageOcean
extends RefCounted
## Этап 2. Океан: всё, что ниже уровня моря и связано с краем карты. Если у края моря нет, океана на карте
## нет (с 1.9.6 вода тогда стекает за край карты, см. StageHydrology).
## Пишет: w.ocean (1 — океан).

const PROGRESS := 0.16
const LABEL := "Наполнение океанов"


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var N := w.N
	var h := w.h
	var ocean := PackedByteArray()
	ocean.resize(N)
	var q := PackedInt32Array()
	q.resize(N)
	var qh := 0
	var qt := 0
	for x in W:
		for y: int in [0, H - 1]:
			var i: int = y * W + x
			if h[i] < 0.0 and ocean[i] == 0:
				ocean[i] = 1
				q[qt] = i
				qt += 1
	for y in H:
		for x: int in [0, W - 1]:
			var i: int = y * W + x
			if h[i] < 0.0 and ocean[i] == 0:
				ocean[i] = 1
				q[qt] = i
				qt += 1
	while qh < qt:
		var c := q[qh]
		qh += 1
		var cx := c % W
		var cy := c / W
		# с 6.9 — 8 соседей, как у заполнения впадин: море за диагональным перешейком тоже океан,
		# а не суша ниже уровня моря
		for k in 8:
			var nx: int = cx + Grid.DX[k]
			var ny: int = cy + Grid.DY[k]
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var n := ny * W + nx
			if ocean[n] == 0 and h[n] < 0.0:
				ocean[n] = 1
				q[qt] = n
				qt += 1
	w.ocean = ocean
