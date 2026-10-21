class_name StageGeography
extends RefCounted
## Общие производные рельефа и воды после гидрологии и формирования русел.
## Пишет: w.dist_water, elev, slope. Не использует rng.
## Климат, дороги, растительность и карта читают эти поля из одного WorldData.
## Все изменения географии должны закончиться до этого этапа и after_climate.


const PROGRESS := 0.34
const LABEL := "Высоты, уклоны и берега"


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var N := w.N
	var h := w.h
	var ocean := w.ocean
	var lake := w.lake
	var river := w.river
	var filled := w.filled
	var water_src := PackedByteArray()
	water_src.resize(N)
	for i in N:
		water_src[i] = 1 if (ocean[i] != 0 or lake[i] != 0 or river[i] != 0) else 0
	var dist_water := Grid.distance_field(W, H, water_src)
	var elev := PackedFloat32Array()
	elev.resize(N)
	for i in N:
		elev[i] = 0.0 if ocean[i] != 0 else (filled[i] if lake[i] != 0 else maxf(0.0, h[i]))
	var slope := PackedFloat32Array()
	slope.resize(N)
	for y in H:
		for x in W:
			var l := elev[y * W + maxi(0, x - 1)]
			var r := elev[y * W + mini(W - 1, x + 1)]
			var u := elev[maxi(0, y - 1) * W + x]
			var d := elev[mini(H - 1, y + 1) * W + x]
			var gx := r - l
			var gy := d - u
			slope[y * W + x] = sqrt(gx * gx + gy * gy) * 0.5 * 60.0
	w.dist_water = dist_water
	w.elev = elev
	w.slope = slope
