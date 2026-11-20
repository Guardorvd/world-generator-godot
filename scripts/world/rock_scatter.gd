class_name RockScatter
extends RefCounted
## Отдельный слой 37. Только готовые поля; RNG создаётся один раз на чанк.
## 07.11.2026: скальные выходы (слой 38, RockModels.OUTCROP_V) на открытых крутых склонах и редкие
## останцы на пологих скалах; осыпи берут источник по линии падения на 8–24 м выше — под скалой
## мелкий острый обломок, у подножия осыпи крупные глыбы (они укатываются дальше).
const PATCH_CELLS := 8
const MAX_CHANCE := 0.48
const CONVEXITY_GAIN := 0.45
const MAX_CONVEXITY_FACTOR := 1.0 + CONVEXITY_GAIN
const OUTCROP_CHANCE := 0.12
const HILL_OUTCROP_CHANCE := 0.065
const HILL_OUTCROP_SLOPE := 0.28
const LOW_HILL_CHANCE := 0.052
const LOW_HILL_MIN := 0.018 # около 5 м над морем
const LOW_HILL_MAX := 0.085
const LOW_HILL_SLOPE := 0.16
const LOW_HILL_REACH := 4 # клеток: выпуклость бровки на 16 м
## Conservative projected upper-block footprint, in clear_path's boulder-scale units.
const OUTCROP_CLEAR := 2.2 # includes the projected upper blocks on a tilted instance
const FIELD_HALO := 15 # соседний источник массива, его полный круг просвета и выборки посадки
const TALUS_REACH := [2, 4, 6]
const Surface := preload("res://scripts/world/mountain_surface.gd")

## Маска путей для крупных форм: у плана полей с расстоянием её нет, она есть у ObjStore.
static func path_mask_of(f: Dictionary, store: StageVegetation.ObjStore) -> PackedByteArray:
	var mask: PackedByteArray = f.get("path", PackedByteArray())
	if mask.is_empty() and store.w != null: mask = store._path_mask
	return mask


## StageVegetation передаёт массивы чанка и геометрию их тел. Самостоятельный проход считает их здесь.
static func place_chunk(seed_num: int, x0: int, y0: int, x1: int, y1: int,
		f: Dictionary, ox: int, oy: int, stride: int, store: StageVegetation.ObjStore,
		massifs: Variant = null, cores: Variant = null) -> void:
	var rng := WGRandom.new(1)
	var biome: PackedByteArray = f.biome
	var slope: PackedFloat32Array = f.slope
	var elev: PackedFloat32Array = f.elev
	var dw: PackedFloat32Array = f.dw
	var stony: PackedFloat64Array = f.stony
	var forest: PackedFloat64Array = f.forest
	var paths: PackedFloat32Array = f.get("dist_path", PackedFloat32Array())
	# The full-plan fields carry distances, while ObjStore already owns the exact mask.
	# Use it too: otherwise enlarged outcrop clearance was applied only to outer chunks.
	var outcrop_path := path_mask_of(f, store)
	var villages: PackedByteArray = f.get("village", PackedByteArray())
	var rivers: PackedByteArray = f.get("river", PackedByteArray())
	var water: PackedByteArray = StageVegetation._TABLES.water
	var moist: PackedFloat32Array = f.get("moist", PackedFloat32Array())
	var has_moist := not moist.is_empty()
	var rock: PackedByteArray = f.get("rock", PackedByteArray())
	if rock.is_empty(): rock = Surface.field(elev, slope, moist)
	var rows := elev.size()/stride
	# Несколько хешей на чанк вместо нового шума на каждую клетку.
	var px0 := floori(float(x0) / PATCH_CELLS)
	var py0 := floori(float(y0) / PATCH_CELLS)
	var pw := floori(float(x1 - 1) / PATCH_CELLS) - px0 + 2
	var ph := floori(float(y1 - 1) / PATCH_CELLS) - py0 + 2
	var patches := PackedFloat32Array()
	patches.resize(pw * ph)
	for yy in ph:
		for xx in pw: patches[yy * pw + xx] = WGRandom.hash2(px0 + xx, py0 + yy, seed_num ^ 0x524f434b)
	# Скальные массивы этого чанка: владелец — чанк, в котором лежит точка массива.
	var big: PackedFloat32Array = massifs if massifs != null else RockMassif.sites(seed_num, x0, y0, x1, y1, f, ox, oy, stride, outcrop_path)
	var bodies: PackedVector3Array = RockMassif.cores(big) if cores == null else cores
	var has_bodies := not bodies.is_empty()
	for at in range(0, big.size(), RockMassif.STRIDE):
		if big[at] >= x0 and big[at] < x1 and big[at + 1] >= y0 and big[at + 1] < y1:
			store.add(big[at], big[at + 1], Biomes.T_ROCK, int(big[at + 2]), big[at + 3])
	for y in range(y0, y1):
		var gy := float(y) / PATCH_CELLS
		var ty := smoothstep(0.0, 1.0, gy - floor(gy))
		var patch_row := (floori(gy) - py0) * pw
		for x in range(x0, x1):
			var i := (y - oy) * stride + x - ox
			var bi := biome[i]
			if water[bi] != 0 or (not rivers.is_empty() and rivers[i] != 0) or (not villages.is_empty() and villages[i] != 0):
				continue
			var sl := slope[i]
			if dw[i] < 0.65: continue
			# 15.0: dist_path — просвет (м) до кромки полотна с запасом пути (StageVegetation.path_clearance)
			var dp: float = paths[i] if not paths.is_empty() else 100.0
			if dp < 0.0: continue
			var outcrop_clear := dp > 10.0 and dw[i] >= 1.5
			var e := elev[i]
			var low_hill := outcrop_clear and has_moist and sl > LOW_HILL_SLOPE and e > LOW_HILL_MIN and e < LOW_HILL_MAX \
				and (bi == Biomes.GRASS or bi == Biomes.STEPPE or bi == Biomes.SAVANNA) and moist[i] < 0.52
			var outcrop_site := outcrop_clear and (low_hill or sl > HILL_OUTCROP_SLOPE or (bi == Biomes.ROCK and sl > 0.12))
			# Грубый порог валунов до выборки месторождения.
			var hc := WGRandom.hash_cell(seed_num, x, y, 37)
			var roll := float(hc) / 4294967296.0
			var boulder_candidate := sl <= 0.85 and roll < MAX_CHANCE
			if not boulder_candidate and not outcrop_site: continue
			var mountain := smoothstep(0.12, 0.36, e)
			var exposed := float(rock[i]) / 255.0
			var gx := float(x) / PATCH_CELLS
			var tx := smoothstep(0.0, 1.0, gx - floor(gx))
			var pi := patch_row + floori(gx) - px0
			var deposit := lerpf(lerpf(patches[pi], patches[pi + 1], tx), lerpf(patches[pi + pw], patches[pi + pw + 1], tx), ty)
			# Коренная порода выходит там, где склон открыт и крут; на пологих скалах — редкие останцы.
			# Места выходов собраны в те же пятна, что россыпи: скальный пояс, а не ровный посев.
			if outcrop_site:
				var steep := smoothstep(0.45, 0.95, sl)
				var oc := 0.0
				if mountain > 0.0 and exposed > 0.3:
					var tor := smoothstep(0.12, 0.4, sl) * 0.03 if bi == Biomes.ROCK else 0.0
					oc = OUTCROP_CHANCE * smoothstep(0.3, 0.75, exposed) * mountain * maxf(steep, tor) * lerpf(0.04, 1.8, smoothstep(0.3, 0.85, deposit))
				if e > 0.035 and e < 0.15 and sl > HILL_OUTCROP_SLOPE and deposit > 0.55 and has_moist and moist[i] < 0.62:
					var convex := local_convexity(elev, i, stride)
					var hill := smoothstep(0.035, 0.07, e) * (1.0 - smoothstep(0.11, 0.15, e))
					var dry := 1.0 - smoothstep(0.42, 0.62, moist[i])
					var shoulder_chance := HILL_OUTCROP_CHANCE * hill * dry * smoothstep(0.15, 0.9, convex) \
						* smoothstep(HILL_OUTCROP_SLOPE, 0.62, sl) * smoothstep(0.55, 0.84, deposit)
					oc = maxf(oc, shoulder_chance)
				# Пологие бровки читаются в окне шире коротких перегибов обычного выхода.
				var low_chance := 0.0
				if low_hill and deposit > 0.62:
					var convex := local_convexity(elev, i, stride, LOW_HILL_REACH)
					var height := smoothstep(LOW_HILL_MIN, 0.036, e) * (1.0 - smoothstep(0.065, LOW_HILL_MAX, e))
					var dry := 1.0 - smoothstep(0.37, 0.52, moist[i])
					low_chance = LOW_HILL_CHANCE * height * dry * smoothstep(0.20, 1.0, convex) \
						* smoothstep(LOW_HILL_SLOPE, 0.36, sl) * smoothstep(0.62, 0.86, deposit)
				var chance_outcrop := maxf(oc, low_chance)
				var ho := WGRandom.hash_cell(seed_num, x, y, 38) if chance_outcrop > 0.0 else 0
				var outcrop_roll := float(ho) / 4294967296.0
				if outcrop_roll < chance_outcrop:
					# В теле массива ни выходов, ни валунов.
					if has_bodies and RockMassif.covers(bodies, x + 0.5, y + 0.5, 0.0): continue
					rng.reset(ho ^ 0x0c7c0e5)
					var ocx := x + 0.3 + rng.next_float() * 0.4
					var ocy := y + 0.3 + rng.next_float() * 0.4
					var r := rng.next_float()
					var os := 0.60 + r * r * 0.50 if outcrop_roll >= oc else 0.85 + r * r * 0.95 + steep * 0.25
					var otint := RockModels.OUTCROP_V + int(clampf(deposit * 3.0, 0.0, 2.0))
					var reach := os * OUTCROP_CLEAR
					if (outcrop_path.is_empty() or clear_path(outcrop_path, ox, oy, stride, ocx, ocy, reach)) \
							and (villages.is_empty() or clear_path(villages, ox, oy, stride, ocx, ocy, reach)) \
							and (rivers.is_empty() or clear_path(rivers, ox, oy, stride, ocx, ocy, reach)):
						store.add(ocx, ocy, Biomes.T_ROCK, otint, os)
						continue
			if not boulder_candidate: continue
			var patch := smoothstep(-0.15, 0.5, stony[i])
			var edge := 1.0 - absf(clampf(forest[i] + 0.5, 0.0, 1.0) * 2.0 - 1.0)
			var deposit_weight := lerpf(0.15, 1.65, smoothstep(0.2, 0.8, deposit))
			var ground_weight := deposit_weight * (1.0 - smoothstep(0.6, 0.85, sl))
			# Влажность уже несёт положение в рельефе. На сухих гребнях россыпи гуще.
			var moisture_weight := lerpf(1.6, 0.6, smoothstep(0.42, 0.82, moist[i])) if has_moist else 1.0
			var biome_weight := 1.0
			if bi == Biomes.SWAMP or bi == Biomes.SNOW:
				biome_weight = 0.35
			elif bi == Biomes.DESERT or bi == Biomes.BEACH:
				biome_weight = 0.5
			var base_chance := 0.005 + patch * (0.014 + edge * 0.014 + mountain * (0.05 * patch + exposed * 0.12))
			var talus_slope := 1.0 - smoothstep(0.45, 0.85, sl)
			var talus_gain := 0.12 + 0.14 * patch
			# Любой источник осыпи умножает talus_slope на число от 0 до 1.
			# Для раннего отказа берём предельный вклад осыпи и выпуклости.
			var upper_chance := (base_chance + mountain * talus_slope * talus_gain) * ground_weight * moisture_weight * biome_weight
			if roll >= upper_chance * MAX_CONVEXITY_FACTOR: continue
			if has_bodies and RockMassif.covers(bodies, x + 0.5, y + 0.5, 0.0): continue
			# Осыпь питает скала выше по линии падения, а не любой соседний склон: на 8, 16 и 24 м вверх.
			var source := 0.0
			var reach_cells := 0
			var down := Vector2.ZERO
			if mountain > 0.0:
				var lx := x - ox
				var ly := y - oy
				var ex := elev[i + 1] - elev[i - 1] if lx > 0 and lx + 1 < stride else 0.0
				var ey := elev[i + stride] - elev[i - stride] if ly > 0 and ly + 1 < rows else 0.0
				var gl := sqrt(ex * ex + ey * ey)
				if gl > 1e-7:
					down = Vector2(-ex, -ey) / gl
					for step: int in TALUS_REACH:
						var nx := lx - roundi(down.x * step)
						var ny := ly - roundi(down.y * step)
						if nx < 0 or ny < 0 or nx >= stride or ny >= rows: break
						var ni := ny * stride + nx
						if elev[ni] <= elev[i]: continue
						var src := float(rock[ni]) / 255.0 * (0.5 + 0.5 * smoothstep(0.4, 0.9, slope[ni]))
						if src > source:
							source = src
							reach_cells = step
			# Под лицом стены и у подножия ребра или развала — их обломки: источник известен точно.
			for at in range(0, big.size(), RockMassif.STRIDE):
				var md := Vector2(big[at + 6], big[at + 7])
				if md == Vector2.ZERO: continue
				var rel := Vector2(x + 0.5 - big[at], y + 0.5 - big[at + 1])
				var along := rel.dot(md)
				var across := absf(rel.dot(Vector2(-md.y, md.x)))
				var half: float = big[at + 5] * 0.8
				if along > 0.1 and along < RockMassif.TALUS_RANGE and across < half:
					if RockModels.massif_form(int(big[at + 2])) == RockModels.M_TOR: continue
					var fed := 0.92 * (1.0 - along / RockMassif.TALUS_RANGE) * (1.0 - smoothstep(half * 0.4, half, across))
					if fed > source:
						source = fed
						reach_cells = clampi(roundi(along), 2, 6)
						if down == Vector2.ZERO: down = md
			var talus := smoothstep(0.15, 0.55, source) * talus_slope
			var chance := (base_chance + mountain * talus * talus_gain) * ground_weight * moisture_weight * biome_weight
			# До множителя формы допускаем только кандидатов, которые ещё могут пройти порог.
			if roll >= chance * MAX_CONVEXITY_FACTOR: continue
			chance *= 1.0 + CONVEXITY_GAIN * clampf(local_convexity(elev, i, stride) / 0.9, -1.0, 1.0)
			if roll >= minf(MAX_CHANCE, chance): continue
			# Близость пути влияет на размер камней, густоту задают порода и осыпь.
			var shoulder := (1.0 - smoothstep(1.0, 8.0, dp)) * maxf(exposed, mountain)
			var toe := float(reach_cells) / 6.0
			rng.reset(hc ^ 0x51ed270b)
			var cx := x + 0.12 + rng.next_float() * 0.76
			var cy := y + 0.12 + rng.next_float() * 0.76
			var large := shoulder < 0.1 and rng.next_float() < 0.06 + exposed * 0.12 + talus * (0.04 + 0.2 * toe)
			var r := rng.next_float()
			var scale := (0.75 + r * r * 1.35) if large else ((0.24+r*r*0.48) if mountain>0.3 and r>0.55 else (0.07+r*r*0.30))
			if not paths.is_empty() and Grid.clearance_at(paths, ox, oy, stride, cx, cy, GameConfig.TILE) < rock_reach(scale): continue
			if not villages.is_empty() and not clear_path(villages,ox,oy,stride,cx,cy,scale): continue
			if not rivers.is_empty() and not clear_path(rivers,ox,oy,stride,cx,cy,scale): continue
			# Цвет в одном месторождении общий, формы и повороты остаются индивидуальными.
			var tint := int(clampf(deposit * 3.0, 0.0, 2.0))
			store.add(cx, cy, Biomes.T_ROCK, tint, scale)
			var count := 3 if large else (2 if shoulder > 0.2 or mountain > 0.4 else 1)
			# Под самой скалой обломков больше, и они мельче.
			if talus > 0.5 and toe < 0.5: count += 1
			var trail := talus > 0.3 and down != Vector2.ZERO
			for n in count:
				var a := rng.next_float() * TAU
				# В осыпи обломки вытянуты вниз по склону от крупного камня.
				if trail: a = atan2(down.y, down.x) + (a / TAU - 0.5) * 1.6
				var radius := 0.18 + rng.next_float() * (0.45 if large else 0.32)
				var px := cx + cos(a) * radius
				var py := cy + sin(a) * radius
				# Каждая группа имеет владельца-клетку: независима от порядка чанков.
				if floori(px) != x or floori(py) != y: continue
				var fragment := 0.055 + rng.next_float() * (0.16 + mountain * 0.16) * (1.0 - 0.35 * talus * (1.0 - toe))
				if not paths.is_empty() and Grid.clearance_at(paths, ox, oy, stride, px, py, GameConfig.TILE) < rock_reach(fragment): continue
				if not villages.is_empty() and not clear_path(villages,ox,oy,stride,px,py,fragment): continue
				if not rivers.is_empty() and not clear_path(rivers,ox,oy,stride,px,py,fragment): continue
				store.add(px, py, Biomes.T_ROCK, tint, fragment)


## Высота над средним соседей в метрах (радиус по умолчанию — 8 м). Положительная — выпуклое плечо.
## Весь план или его полоса соседей доступны в полях. На внешнем краю поля форма нейтральна.
static func local_convexity(elev: PackedFloat32Array, i: int, stride: int, radius := 2) -> float:
	var x := i % stride
	var d := radius * stride
	if x < radius or x + radius >= stride or i < d or i + d >= elev.size():
		return 0.0
	return (elev[i] - (elev[i - radius] + elev[i + radius] + elev[i - d] + elev[i + d]) * 0.25) * GameConfig.HS


## Радиус камня масштаба scale на земле, м: столько просвета ему нужно у кромки пути
static func rock_reach(scale: float) -> float:
	return Biomes.CROWN_RADIUS[Biomes.T_ROCK] * scale * GameConfig.TILE


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
