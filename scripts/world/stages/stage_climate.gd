class_name StageClimate
extends RefCounted
## Этап 5. Климат и биомы по готовым полям StageGeography.
## Читает: w.elev, slope, dist_water, dist_ocean, rain, h и маски воды.
## Пишет: w.temp, moist, biome.

const PROGRESS := 0.38
const LABEL := "Климат и биомы"


## Правило выбора биома для клетки суши. e — высота, t — температура, m — влажность (0..1)
static func land_biome(e: float, t: float, m: float, slope: float, dist_ocean: float) -> int:
	if e > 0.62 or (e > 0.42 and t < 0.2):
		return Biomes.PEAK
	if e > 0.4 or slope > 1.3:
		return Biomes.ROCK
	if dist_ocean <= 2.5 and e < 0.03:
		return Biomes.STONESHORE if t < 0.3 else Biomes.BEACH
	if t < 0.12:
		return Biomes.SNOW
	if t < 0.24:
		return Biomes.TAIGA if m > 0.6 else Biomes.TUNDRA
	if t < 0.42:
		return Biomes.STEPPE if m < 0.3 else Biomes.TAIGA
	if t < 0.7:
		if m < 0.25:
			return Biomes.STEPPE
		if m < 0.45:
			return Biomes.GRASS
		if m > 0.82 and e < 0.12 and slope < 0.25:
			return Biomes.SWAMP
		return Biomes.FOREST
	if m < 0.27:
		return Biomes.DESERT
	if m < 0.42:
		return Biomes.SAVANNA
	if m < 0.55:
		return Biomes.GRASS
	if m > 0.86 and e < 0.1 and slope < 0.25:
		return Biomes.SWAMP
	return Biomes.JUNGLE


## Широта строки y для температуры: 0 — холодный север, 1 — жаркий юг. С 1.9.6 шкала не зависит от
## размера карты (LAT_CELLS клеток на весь размах, середина карты — 0.5) и продолжается за край:
## к северу холоднее, к югу жарче
const LAT_CELLS := 511.0


static func latitude(w: WorldData, y: int) -> float:
	return 0.5 + (y - w.H * 0.5 + 0.5) / LAT_CELLS


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var N := w.N
	var h := w.h
	var ocean := w.ocean
	var lake := w.lake
	var rain := w.rain
	var dist_ocean := w.dist_ocean
	var dist_water := w.dist_water
	var elev := w.elev
	var slope := w.slope
	var temp_n := w.noise_field("temp")
	var temp := PackedFloat32Array()
	temp.resize(N)
	var moist := PackedFloat32Array()
	moist.resize(N)
	var biome := PackedByteArray()
	biome.resize(N)
	for y in H:
		for x in W:
			var i := y * W + x
			var lat := latitude(w, y)
			var e := elev[i]
			var t := clampf(0.16 + lat * 0.86 + temp_n[i] * 0.18 - e * 0.6, 0.0, 1.0)
			var m := clampf(rain[i] + 0.22 * exp(-dist_water[i] / 4.0), 0.0, 1.0)
			temp[i] = t
			moist[i] = m
			var b: int
			if ocean[i] != 0:
				b = Biomes.DEEP if h[i] < -0.35 else (Biomes.OCEAN if h[i] < -0.07 else Biomes.SHALLOW)
			elif lake[i] != 0:
				b = Biomes.LAKE
			else:
				# t и m в JS читаются из локальных переменных (double), а не из Float32Array
				b = land_biome(e, t, m, slope[i], dist_ocean[i])
			biome[i] = b
	w.temp = temp
	w.moist = moist
	w.biome = biome
