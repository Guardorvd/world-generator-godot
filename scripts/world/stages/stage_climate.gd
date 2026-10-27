class_name StageClimate
extends RefCounted
## Этап 5. Климат и биомы по готовым полям StageGeography.
## Читает: w.elev, slope, dist_water, dist_ocean, rain, h и маски воды.
## Пишет: w.temp, moist, biome.

const PROGRESS := 0.38
const LABEL := "Климат и биомы"


## x — относительное освещение склона (0..1), y — удержание влаги в микроложбинах.
## Солнце с юга; это средний прогрев, без трассировки теней. Только готовые высоты,
## без дополнительных полей мира. На границе берём ближайшую клетку.
static func natural_conditions(w: WorldData, x: int, y: int) -> Vector2:
	# В массовых численных выборках берём packed-буфер контекста один раз.
	var elev := w.geology.elev.data
	var W := w.W
	var H := w.H
	var i := y * W + x
	var gx := (elev[y * W + mini(W - 1, x + 1)] - elev[y * W + maxi(0, x - 1)]) * 30.0
	var gy := (elev[mini(H - 1, y + 1) * W + x] - elev[maxi(0, y - 1) * W + x]) * 30.0
	var light := clampf(0.5 - 0.5 * gy / sqrt(1.0 + gx * gx + gy * gy), 0.0, 1.0)
	var around := (elev[y * W + maxi(0, x - 2)] + elev[y * W + mini(W - 1, x + 2)]
		+ elev[maxi(0, y - 2) * W + x] + elev[mini(H - 1, y + 2) * W + x]) * 0.25
	return Vector2(light, clampf((around - elev[i]) * 18.0, -0.16, 0.16))


## Влажность почвы: осадки, вода, накопление в ложбинах, дренаж и испарение.
static func soil_moisture(rain: float, dw: float, sl: float, t: float, conditions: Vector2) -> float:
	return clampf(rain + 0.22 * exp(-dw / 4.0) + conditions.y
		- 0.10 * clampf(sl, 0.0, 1.5) - (conditions.x - 0.5) * (0.08 + 0.12 * t), 0.0, 1.0)


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
## размера карты (LAT_CELLS клеток на весь размах, фиксированная строка 255.5 — 0.5) и продолжается за край:
## к северу холоднее, к югу жарче
const LAT_CELLS := 511.0


static func latitude(_w: WorldData, y: int) -> float:
	return 0.5 + (y - 255.5) / LAT_CELLS


static func run(w: WorldData) -> void:
	var temp_n := w.noise_field("temp")
	var started := Time.get_ticks_usec()
	var fast := Grid.fast_grid()
	var fields: Dictionary = fast.ClimateFields(w.W, w.H, w.h, w.ocean, w.lake, w.rain,
		w.dist_ocean, w.dist_water, w.elev, w.slope, temp_n, LAT_CELLS, biome_ids()) if fast != null else fields_reference(w, temp_n)
	w.temp = fields.temp
	w.moist = fields.moist
	w.biome = fields.biome
	w.generation.light = fields.light
	w.generation_profile.climate_field_ms = (Time.get_ticks_usec() - started) / 1000.0


static func biome_ids() -> PackedByteArray:
	return PackedByteArray([Biomes.DEEP, Biomes.OCEAN, Biomes.SHALLOW, Biomes.LAKE, Biomes.BEACH,
		Biomes.DESERT, Biomes.SAVANNA, Biomes.STEPPE, Biomes.GRASS, Biomes.FOREST, Biomes.JUNGLE,
		Biomes.SWAMP, Biomes.TAIGA, Biomes.TUNDRA, Biomes.SNOW, Biomes.ROCK, Biomes.PEAK, Biomes.STONESHORE])


## Исходные численные правила. light сохраняет ровно float32-компонент Vector2.
static func fields_reference(w: WorldData, temp_n: PackedFloat64Array) -> Dictionary:
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
	var temp := PackedFloat32Array()
	temp.resize(N)
	var moist := PackedFloat32Array()
	moist.resize(N)
	var biome := PackedByteArray()
	biome.resize(N)
	var light := PackedFloat32Array()
	light.resize(N)
	for y in H:
		var lat := latitude(w, y)
		for x in W:
			var i := y * W + x
			var e := elev[i]
			var conditions := natural_conditions(w, x, y)
			light[i] = conditions.x
			var t := clampf(0.16 + lat * 0.86 + temp_n[i] * 0.18 - e * 0.6, 0.0, 1.0)
			var m := clampf(rain[i] + 0.22 * exp(-dist_water[i] / 4.0), 0.0, 1.0)
			if ocean[i] == 0 and lake[i] == 0:
				t = clampf(t + (conditions.x - 0.5) * 0.08, 0.0, 1.0)
				m = soil_moisture(rain[i], dist_water[i], slope[i], t, conditions)
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
				# Быстрые горные потоки обнажают камень; равнинные берега остаются
				# травянистыми. Используем готовые уклон и расстояние, без нового поля.
				if dist_water[i] <= 1.0 and dist_ocean[i] > 2.5 and slope[i] > 0.55 and e < 0.62:
					b = Biomes.STONESHORE
			biome[i] = b
	return {temp = temp, moist = moist, biome = biome, light = light}
