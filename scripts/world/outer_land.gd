class_name OuterLand
extends RefCounted
## Рельеф за краем карты (с 1.9.5): тот же шум, что у StageRelief, с теми же постоянными уровнями моря, поэтому на
## границе карты нет ступеньки. Считается кусками по C × C клеток вокруг игрока (OuterTerrain).
## Пока это только высота и биом по климату: рек, озёр, растительности, поселений и троп за краем нет,
## вода — море на уровне 0 везде, где рельеф ниже уровня моря.
## compute — чистая функция, её считают фоновые задачи; в chunks куски кладёт и убирает главный поток.
## Кольцо клеток вокруг карты считается сразу и потом не меняется: его читает и поток растительности
## (Heightfield.ground_at у самого края карты), а chunks — только главный поток.

const C := 64              # сторона куска в клетках

var world: WorldData
## Vector2i(номер куска по x, по y) -> поля compute по (C + 3)² клеткам с углом (x0 - 1, y0 - 1),
## где x0, y0 — первая клетка куска: с запасом на соседей для меша и нормалей
var chunks := {}
var _ring: Array[Dictionary] = []   # над картой, под ней, слева, справа


func _init(w: WorldData) -> void:
	world = w
	_ring = [compute(w, -1, -1, w.W + 2, 1), compute(w, -1, w.H, w.W + 2, 1),
		compute(w, -1, 0, 1, w.H), compute(w, w.W, 0, 1, w.H)]


## Поля клеток прямоугольника cw × ch с углом (x0, y0): h — высота в единицах WorldData.h (ниже 0 — море,
## в метры её переводит Heightfield.outer_meters), biome,
## temp, moist, elev, slope. Климат упрощён против StageClimate: влажность без близости воды, берег —
## клетка суши рядом с морем
static func compute(w: WorldData, x0: int, y0: int, cw: int, ch: int) -> Dictionary:
	# на клетку шире с каждой стороны: крутизне и берегу нужны соседи
	var pw := cw + 2
	var ph := ch + 2
	var raw := StageRelief.raw_rect(w, x0 - 1, y0 - 1, pw, ph, false)
	var micro := Parallel.fbm_rect(w.noise.micro, x0 - 1, y0 - 1, pw, ph, 9.0, 2)
	var hn := PackedFloat32Array()
	hn.resize(pw * ph)
	# StageRelief.normalize и add_micro развёрнуты на месте: куски считаются в потоках (см. Parallel)
	var sea := StageRelief.SEA_RAW
	var top := StageRelief.TOP_RAW
	var bottom := StageRelief.BOTTOM_RAW
	for k in pw * ph:
		var v := raw[k]
		var hh := minf(pow((v - sea) / (top - sea), 1.25), 1.4) if v >= sea else (v - sea) / (sea - bottom)
		hn[k] = maxf(1e-4, hh + micro[k] * 0.006 * minf(1.0, hh * 40.0)) if hh > 0.0 else hh
	var p: Array = WorldData.NOISE_FIELDS.temp
	var temp_n := Parallel.fbm_rect(w.noise.temp, x0, y0, cw, ch, p[0], p[1])
	p = WorldData.NOISE_FIELDS.moist
	var moist_n := Parallel.fbm_rect(w.noise.moist, x0, y0, cw, ch, p[0], p[1])
	var n := cw * ch
	var out := {h = PackedFloat32Array(), biome = PackedByteArray(), temp = PackedFloat32Array(),
		moist = PackedFloat32Array(), elev = PackedFloat32Array(), slope = PackedFloat32Array()}
	for key in out:
		out[key].resize(n)
	for j in ch:
		var lat := StageClimate.latitude(w, y0 + j)
		for i in cw:
			var c := (j + 1) * pw + i + 1
			var hh := hn[c]
			var o := j * cw + i
			var e := maxf(0.0, hh)
			var gx := maxf(0.0, hn[c + 1]) - maxf(0.0, hn[c - 1])
			var gy := maxf(0.0, hn[c + pw]) - maxf(0.0, hn[c - pw])
			var slope := sqrt(gx * gx + gy * gy) * 0.5 * 60.0
			var t := clampf(0.16 + lat * 0.86 + temp_n[o] * 0.18 - e * 0.6, 0.0, 1.0)
			var m := clampf(0.36 + 0.85 * moist_n[o], 0.02, 1.0)
			var b: int
			if hh < 0.0:
				b = Biomes.DEEP if hh < -0.35 else (Biomes.OCEAN if hh < -0.07 else Biomes.SHALLOW)
			else:
				var shore := hn[c + 1] < 0.0 or hn[c - 1] < 0.0 or hn[c + pw] < 0.0 or hn[c - pw] < 0.0
				b = StageClimate.land_biome(e, t, m, slope, 1.0 if shore else 99.0)
			out.h[o] = hh
			out.biome[o] = b
			out.temp[o] = t
			out.moist[o] = m
			out.elev[o] = e
			out.slope[o] = slope
	return out


## Поля куска key (для фоновой задачи)
static func compute_chunk(w: WorldData, key: Vector2i) -> Dictionary:
	return compute(w, key.x * C - 1, key.y * C - 1, C + 3, C + 3)


## Где лежит клетка (i, j) за краем карты: [поля, номер в них] или [] — куска ещё нет
func _locate(i: int, j: int) -> Array:
	var W := world.W
	var H := world.H
	if i >= -1 and j >= -1 and i <= W and j <= H:
		if j == -1:
			return [_ring[0], i + 1]
		if j == H:
			return [_ring[1], i + 1]
		if i == -1:
			return [_ring[2], j]
		return [_ring[3], j]
	var key := Vector2i(floori(float(i) / C), floori(float(j) / C))
	var f: Variant = chunks.get(key)
	if f == null:
		return []
	return [f, (j - key.y * C + 1) * (C + 3) + i - key.x * C + 1]


## Высота клетки за краем карты в единицах WorldData.h (ниже 0 — море); где кусок ещё не посчитан — уровень моря
func height(i: int, j: int) -> float:
	var at := _locate(i, j)
	return at[0].h[at[1]] if not at.is_empty() else 0.0


## Посчитана ли клетка за краем карты
func has(i: int, j: int) -> bool:
	return not _locate(i, j).is_empty()


## Сведения о клетке за краем карты в том же виде, что WorldData.tile_info, или {}, если куска нет
func info(i: int, j: int) -> Dictionary:
	var at := _locate(i, j)
	if at.is_empty():
		return {}
	var f: Dictionary = at[0]
	var k: int = at[1]
	return {i = -1, biome = f.biome[k], river = false, path = 0,
		elev = f.elev[k], temp = f.temp[k], moist = f.moist[k], slope = f.slope[k]}
