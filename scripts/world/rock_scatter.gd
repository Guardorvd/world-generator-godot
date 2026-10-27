class_name RockScatter
extends RefCounted
## Отдельный слой 37. Только готовые поля; RNG создаётся один раз на чанк.
const PATCH_CELLS := 8
const MAX_CHANCE := 0.48

static func place_chunk(seed_num: int, x0: int, y0: int, x1: int, y1: int,
		f: Dictionary, ox: int, oy: int, stride: int, store: StageVegetation.ObjStore) -> void:
	var rng := WGRandom.new(1)
	var biome: PackedByteArray = f.biome
	var slope: PackedFloat32Array = f.slope
	var elev: PackedFloat32Array = f.elev
	var dw: PackedFloat32Array = f.dw
	var stony: PackedFloat64Array = f.stony
	var forest: PackedFloat64Array = f.forest
	var paths: PackedFloat32Array = f.get("dist_path", PackedFloat32Array())
	var path_mask: PackedByteArray = f.get("path", PackedByteArray())
	var villages: PackedByteArray = f.get("village", PackedByteArray())
	var rivers: PackedByteArray = f.get("river", PackedByteArray())
	var water: PackedByteArray = StageVegetation._TABLES.water
	# Несколько хешей на чанк вместо нового шума на каждую клетку.
	var px0 := floori(float(x0) / PATCH_CELLS)
	var py0 := floori(float(y0) / PATCH_CELLS)
	var pw := floori(float(x1 - 1) / PATCH_CELLS) - px0 + 2
	var ph := floori(float(y1 - 1) / PATCH_CELLS) - py0 + 2
	var patches := PackedFloat32Array()
	patches.resize(pw * ph)
	for yy in ph:
		for xx in pw: patches[yy * pw + xx] = WGRandom.hash2(px0 + xx, py0 + yy, seed_num ^ 0x524f434b)
	for y in range(y0, y1):
		for x in range(x0, x1):
			var i := (y - oy) * stride + x - ox
			var bi := biome[i]
			if water[bi] != 0 or (not rivers.is_empty() and rivers[i] != 0) or (not villages.is_empty() and villages[i] != 0):
				continue
			var sl := slope[i]
			if sl > 1.05 or dw[i] < 0.65: continue
			var dp: float = paths[i] if not paths.is_empty() else 100.0
			if dp < 0.5: continue
			# Верхняя граница вероятности отсекает дорогие расчёты и RNG у половины клеток.
			var hc := WGRandom.hash_cell(seed_num, x, y, 37)
			var roll := float(hc) / 4294967296.0
			if roll >= MAX_CHANCE: continue
			var patch := smoothstep(-0.15, 0.5, stony[i])
			var mountain := smoothstep(0.12, 0.36, elev[i])
			var shoulder := 1.0 - smoothstep(1.0, 3.0, dp)
			var uphill := sl
			if mountain > 0.0:
				if i >= stride: uphill = maxf(uphill, slope[i - stride])
				if i + stride < slope.size(): uphill = maxf(uphill, slope[i + stride])
				if i % stride > 0: uphill = maxf(uphill, slope[i - 1])
				if i % stride < stride - 1: uphill = maxf(uphill, slope[i + 1])
			var talus := smoothstep(0.35, 1.4, uphill) * (1.0 - smoothstep(0.65, 1.05, sl))
			var edge := 1.0 - absf(clampf(forest[i] + 0.5, 0.0, 1.0) * 2.0 - 1.0)
			var gx := float(x) / PATCH_CELLS
			var gy := float(y) / PATCH_CELLS
			var tx := smoothstep(0.0, 1.0, gx - floor(gx))
			var ty := smoothstep(0.0, 1.0, gy - floor(gy))
			var pi := (floori(gy) - py0) * pw + floori(gx) - px0
			var deposit := lerpf(lerpf(patches[pi], patches[pi + 1], tx), lerpf(patches[pi + pw], patches[pi + pw + 1], tx), ty)
			var deposit_weight := lerpf(0.15, 1.65, smoothstep(0.2, 0.8, deposit))
			var chance := 0.005 + patch * (0.014 + edge * 0.014 + mountain * (0.15 * patch + talus * 0.1))
			chance += shoulder * (0.14 + patch * 0.19)
			chance *= deposit_weight * (1.0 - smoothstep(0.65, 1.05, sl))
			if bi == Biomes.SWAMP or bi == Biomes.SNOW: chance *= 0.35
			if bi == Biomes.DESERT or bi == Biomes.BEACH: chance *= 0.5
			if roll >= minf(MAX_CHANCE, chance): continue
			rng.reset(hc ^ 0x51ed270b)
			var cx := x + 0.12 + rng.next_float() * 0.76
			var cy := y + 0.12 + rng.next_float() * 0.76
			var large := shoulder < 0.1 and rng.next_float() < 0.12 + mountain * 0.28
			var r := rng.next_float()
			var scale := (0.65 + r * r * 1.35) if large else (0.07 + r * r * 0.34)
			if not path_mask.is_empty() and not clear_path(path_mask, ox, oy, stride, cx, cy, scale): continue
			# Цвет в одном месторождении общий, формы и повороты остаются индивидуальными.
			var tint := int(clampf(deposit * 3.0, 0.0, 2.0))
			store.add(cx, cy, Biomes.T_ROCK, tint, scale)
			var count := 3 if large else (2 if shoulder > 0.2 or mountain > 0.4 else 1)
			for n in count:
				var a := rng.next_float() * TAU
				var radius := 0.18 + rng.next_float() * (0.45 if large else 0.32)
				var px := cx + cos(a) * radius
				var py := cy + sin(a) * radius
				# Каждая группа имеет владельца-клетку: независима от порядка чанков.
				if floori(px) != x or floori(py) != y: continue
				var fragment := 0.055 + rng.next_float() * (0.16 + mountain * 0.16)
				if not path_mask.is_empty() and not clear_path(path_mask, ox, oy, stride, px, py, fragment): continue
				store.add(px, py, Biomes.T_ROCK, tint, fragment)


## Внешний ObjStore не хранит WorldData: проверяем весь радиус по маске снимка.
static func clear_path(mask: PackedByteArray, ox: int, oy: int, stride: int, x: float, y: float, scale: float) -> bool:
	var radius: float = Biomes.CROWN_RADIUS[Biomes.T_ROCK] * scale + 0.25
	var rows := mask.size() / stride
	for yy in range(maxi(oy, floori(y - radius)), mini(oy + rows, floori(y + radius) + 1)):
		for xx in range(maxi(ox, floori(x - radius)), mini(ox + stride, floori(x + radius) + 1)):
			if mask[(yy - oy) * stride + xx - ox] == 0: continue
			var dx := maxf(maxf(xx - x, x - xx - 1.0), 0.0)
			var dy := maxf(maxf(yy - y, y - yy - 1.0), 0.0)
			if dx * dx + dy * dy < radius * radius: return false
	return true
