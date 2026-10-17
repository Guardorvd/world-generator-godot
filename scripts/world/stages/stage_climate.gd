class_name StageClimate
extends RefCounted
## Этап 5. Климат и биомы: высота для климата, крутизна, температура, влажность, выбор биома.
## Пишет: w.dist_water, elev, slope, temp, moist, biome.

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


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var N := w.N
	var h := w.h
	var ocean := w.ocean
	var lake := w.lake
	var river := w.river
	var filled := w.filled
	var rain := w.rain
	var dist_ocean := w.dist_ocean
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
	var temp_n := Parallel.fbm_field(w, w.noise.temp, 200.0, 3)
	var temp := PackedFloat32Array()
	temp.resize(N)
	var moist := PackedFloat32Array()
	moist.resize(N)
	var biome := PackedByteArray()
	biome.resize(N)
	for y in H:
		for x in W:
			var i := y * W + x
			var lat := float(y) / (H - 1) # север холодный, юг жаркий
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
	w.dist_water = dist_water
	w.elev = elev
	w.slope = slope
	w.temp = temp
	w.moist = moist
	w.biome = biome
