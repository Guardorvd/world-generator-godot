class_name RockMassif
extends RefCounted
## Скальные массивы (09.11.2026): где на готовом склоне стоят крупные образования (RockModels.MASSIF_*).
## Решение по месту — чистая функция мировых координат и готовых полей (высота, крутизна, открытость
## породы MountainSurface, биом, вода, пути): одинаково в плане и за его краем, при любом порядке чанков.
## Слой идёт после дорог, троп и сооружений (StageVegetation), поэтому поиск дорог его не видит и не
## замедляется; опора, коллизия и отрисовка — общие с выходами (RockModels.seat / outcrop_solids).
##
## Композиция, а не россыпь:
## - стены-уступы стоят поясами на общих отметках пластов (шаг 9–21 м и наклон пласта меняются по
##   массиву): место сдвигается вверх/вниз по склону к ближайшей отметке, соседние стены пояса
##   оказываются на одной горизонтали и вместе читаются как продолжающийся уступ;
## - рёбра — на выпуклых отрогах крутых склонов, вдоль линии падения;
## - развалы глыб — где порода разрушена (крупный шум «прочности» массива мал);
## - останцы — на выпуклых пологих скальных вершинах, где раньше был только серый материал;
## - крупная «скалистость» (~360 м) делает одни склоны и горы голыми и уступчатыми, другие мягкими.
## Деревья в теле массива не ставятся (covers), под стеной и ребром RockScatter кладёт осыпь (talus).

const LATTICE := 5          # шаг возможных мест, клеток (20 м): стены пояса почти смыкаются
const SNAP := 1.2           # насколько место сдвигается к отметке пласта, клеток
const MAX_R := RockModels.MASSIF_REACH / GameConfig.TILE
## Поля читаются в клетке места и у соседей (±1): место дальше чанка не более чем на MAX_R + SNAP,
## поэтому запас полей за краем — MAX_R + SNAP + 1 <= RockScatter.FIELD_HALO.
const STRIDE := 10          # x, y (клетки), obj_v, масштаб, оттенок, радиус пятна (клетки), вниз x, y, исходное место x, y
const LAYER := 0x4d415353
const Spec := RockModels.MASSIF_SPEC


## Гладкий шум значений по решётке step клеток (детерминирован, без Simplex и без состояния).
static func _value(seed_num: int, x: float, y: float, step: float, salt: int) -> float:
	var gx := x / step
	var gy := y / step
	var ix := floori(gx)
	var iy := floori(gy)
	var tx := smoothstep(0.0, 1.0, gx - ix)
	var ty := smoothstep(0.0, 1.0, gy - iy)
	var s := seed_num ^ salt
	return lerpf(lerpf(WGRandom.hash2(ix, iy, s), WGRandom.hash2(ix + 1, iy, s), tx),
		lerpf(WGRandom.hash2(ix, iy + 1, s), WGRandom.hash2(ix + 1, iy + 1, s), tx), ty)


## Массивы, чьё пятно может задеть клетки [x0, x1) × [y0, y1). Поля f — как у RockScatter (elev, slope, rock,
## biome, dw, river, village; клетка (x, y) лежит по номеру (y - oy) * stride + x - ox). path — маска путей.
## stats (необязательно) — счётчики для диагностики: кандидаты, отказы по причинам.
static func sites(seed_num: int, x0: int, y0: int, x1: int, y1: int, f: Dictionary, ox: int, oy: int, stride: int,
		path: PackedByteArray, stats: Dictionary = {}) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var elev: PackedFloat32Array = f.elev
	var slope: PackedFloat32Array = f.slope
	var biome: PackedByteArray = f.biome
	var dw: PackedFloat32Array = f.dw
	var rock: PackedByteArray = f.get("rock", PackedByteArray())
	if rock.is_empty(): return out
	var rivers: PackedByteArray = f.get("river", PackedByteArray())
	var villages: PackedByteArray = f.get("village", PackedByteArray())
	var water: PackedByteArray = StageVegetation._TABLES.water
	var rows := elev.size() / stride
	var hs := GameConfig.HS
	var reach := maxf(MAX_R + SNAP, TALUS_RANGE + 1.0)
	for ly in range(floori((y0 - reach) / LATTICE), floori((y1 + reach) / LATTICE) + 1):
		for lx in range(floori((x0 - reach) / LATTICE), floori((x1 + reach) / LATTICE) + 1):
			var sx := (lx + 0.15 + 0.7 * WGRandom.hash2(lx, ly, seed_num ^ LAYER)) * LATTICE
			var sy := (ly + 0.15 + 0.7 * WGRandom.hash2(lx, ly, seed_num ^ 0x53495445)) * LATTICE
			if sx < x0 - reach or sy < y0 - reach or sx >= x1 + reach or sy >= y1 + reach: continue
			var site := Vector2(sx, sy)
			var cx := floori(sx) - ox
			var cy := floori(sy) - oy
			if cx < 1 or cy < 1 or cx + 1 >= stride or cy + 1 >= rows: continue
			var i := cy * stride + cx
			var e := elev[i]
			var mountain := smoothstep(0.12, 0.32, e)
			if mountain <= 0.0: continue
			var bi := biome[i]
			if water[bi] != 0 or (not rivers.is_empty() and rivers[i] != 0) or (not villages.is_empty() and villages[i] != 0): continue
			if dw[i] < 2.5: continue
			var sl := slope[i]
			# Каменистость места: открытая порода MountainSurface или серый скальный биом климата —
			# там материал рельефа уже скальный (terrain.gdshader: grey), и форма должна это объяснять.
			var exposed := maxf(float(rock[i]) / 255.0, 0.62 if bi == Biomes.ROCK or bi == Biomes.PEAK else 0.0)
			var gx := (elev[i + 1] - elev[i - 1]) * 0.5 * hs
			var gy := (elev[i + stride] - elev[i - stride]) * 0.5 * hs
			var g := sqrt(gx * gx + gy * gy)
			var down := Vector2(-gx, -gy) / g if g > 1e-3 else Vector2.ZERO
			# Выпуклость, м: отрог или вершина выше среднего соседей.
			var convex := e * hs - (elev[i + 1] + elev[i - 1] + elev[i + stride] + elev[i - stride]) * 0.25 * hs
			var sturdy := _value(seed_num, sx, sy, 28.0, 0x434f4d50)
			var crag := _value(seed_num, sx, sy, 90.0, 0x43524147)
			var roll := WGRandom.hash2(lx, ly, seed_num ^ 0x524f4c4c)
			var form := -1
			var chance := 0.0
			var high_rock := bi == Biomes.ROCK or bi == Biomes.PEAK or (bi == Biomes.TUNDRA and mountain > 0.7)
			# Пороги открытости выше, чем у материала: массив стоит там, где рельеф уже читается скальным
			# (forest.a / COLOR.a у terrain.gdshader), а не крупной плитой на траве.
			if sl >= 0.42 and exposed >= 0.4:
				if convex > 0.35 and roll < 0.5:
					form = RockModels.M_RIB
					chance = 0.7
				elif sturdy > 0.4:
					form = RockModels.M_WALL
					chance = 0.92
				else:
					form = RockModels.M_BLOCKS
					chance = 0.6
				chance *= smoothstep(0.4, 0.7, exposed)
			elif sl >= 0.24 and exposed >= 0.6: # средняя крутизна — только на явно скальной земле, не плитой на траве
				if sturdy > 0.55 and sl >= 0.3:
					form = RockModels.M_WALL # низкий уступ на скальном склоне средней крутизны
					chance = 0.6
				elif convex > 0.3:
					form = RockModels.M_RIB
					chance = 0.45
				else:
					form = RockModels.M_BLOCKS
					chance = 0.35 * (1.0 if sturdy < 0.55 else 0.5)
				chance *= smoothstep(0.45, 0.72, exposed)
			elif high_rock and sl < 0.42 and convex > -0.05:
				# Останцы на пологих скальных вершинах и плечах (не в ложбинах).
				form = RockModels.M_TOR
				chance = 0.3 + 0.3 * smoothstep(0.0, 0.4, convex)
			if form < 0: continue
			# Одни горы и склоны голые и уступчатые, другие мягче — крупная «скалистость».
			chance *= lerpf(0.2, 1.25, smoothstep(0.20, 0.72, crag)) * lerpf(0.5, 1.0, mountain)
			if form == RockModels.M_WALL:
				# Пояс: место сдвигается по линии падения к ближайшей отметке пласта.
				# Те же пласты, что у уступов рельефа (RockRelief): стена встаёт на обрыв полки.
				var st := RockRelief.strata(seed_num, sx, sy)
				var spacing := st.x
				var phase := st.y
				var h := e * hs + gx * (sx - floorf(sx) - 0.5) + gy * (sy - floorf(sy) - 0.5)
				var band := roundf((h - phase) / spacing) * spacing + phase
				var shift := (band - h) / maxf(g, 0.5)
				if absf(shift) <= SNAP and down != Vector2.ZERO:
					sx -= down.x * shift
					sy -= down.y * shift
				else:
					form = RockModels.M_BLOCKS
					chance *= 0.35
			if WGRandom.hash2(lx, ly, seed_num ^ 0x52494221) >= chance: continue
			stats.candidates = stats.get("candidates", 0) + 1
			var r := WGRandom.hash2(lx, ly, seed_num ^ 0x5343414c)
			# Чем круче и голее склон, тем крупнее стены и рёбра (до ~29 м по фронту и 15 м высоты).
			var scale := 0.72 + 0.3 * r + 0.42 * smoothstep(0.45, 1.0, sl) * crag
			if form == RockModels.M_TOR: scale = 0.68 + 0.36 * r
			scale = minf(scale, 1.5 if form == RockModels.M_WALL or form == RockModels.M_RIB else 1.12)
			var radius: float = Spec[form].r * scale * 1.2 / GameConfig.TILE
			# Пятно не задевает пути, поселения, реки и воду (маски проверяются целиком по кругу).
			var blocked := ""
			var clearance := radius + 0.6
			if sx - clearance < ox or sy - clearance < oy or sx + clearance >= ox + stride or sy + clearance >= oy + rows:
				continue
			var clearance_sq := clearance * clearance
			for yy in range(floori(sy - clearance), floori(sy + clearance) + 1):
				for xx in range(floori(sx - clearance), floori(sx + clearance) + 1):
					var lxx := xx - ox
					var lyy := yy - oy
					if lxx < 0 or lyy < 0 or lxx >= stride or lyy >= rows: continue
					var dx := maxf(maxf(xx - sx, sx - xx - 1.0), 0.0)
					var dy := maxf(maxf(yy - sy, sy - yy - 1.0), 0.0)
					if dx * dx + dy * dy >= clearance_sq: continue
					var k := lyy * stride + lxx
					if not path.is_empty() and path[k] != 0: blocked = "path"
					elif not villages.is_empty() and villages[k] != 0: blocked = "village"
					elif not rivers.is_empty() and rivers[k] != 0 or water[biome[k]] != 0: blocked = "water"
					if blocked != "": break
				if blocked != "": break
			if blocked != "":
				stats[blocked] = stats.get(blocked, 0) + 1
				continue
			# Крупные формы редки. Два силуэта могут делить чанк, но число групп
			# по-прежнему ограничено общими моделями каталога.
			var silhouette := WGRandom.hash2(lx, ly, seed_num ^ 0x56415249)
			var low_wall := lerpf(0.74, 0.32, smoothstep(0.3, 1.1, sl))
			var variant := int(silhouette >= (low_wall if form == RockModels.M_WALL else 0.5))
			var tint := int(clampf(sturdy * 3.0, 0.0, 2.0))
			out.append_array(PackedFloat32Array([sx, sy, RockModels.massif_v(form, variant, tint), scale, tint, radius, down.x, down.y, site.x, site.y]))
	return out


## Только опёртые массивы закрывают место для подлеска и питают осыпь.
static func seated(candidates: PackedFloat32Array, surface: Heightfield) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var tile := GameConfig.TILE
	for at in range(0, candidates.size(), STRIDE):
		var x := candidates[at] * tile
		var z := candidates[at + 1] * tile
		var v := int(candidates[at + 2])
		var pose := RockModels.seat(surface, x, z, candidates[at + 3] * 1.2, v)
		if pose.x == INF: continue
		var item := candidates.slice(at, at + STRIDE)
		var down := Vector2(pose.y, pose.w)
		if down.length_squared() > 0.004 * 0.004:
			down = down.normalized()
			item[6] = down.x
			item[7] = down.y
		out.append_array(item)
	return out


## Тот же отбор, что у внешнего рендера, до расчёта просветов и осыпи.
static func seated_snapshot(candidates: PackedFloat32Array, snapshot: Dictionary, hv: PackedFloat32Array, width: int, height: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for at in range(0, candidates.size(), STRIDE):
		var pose := RockModels.seat_snapshot_any(snapshot, hv, width, height, candidates[at] * GameConfig.TILE,
			candidates[at + 1] * GameConfig.TILE, candidates[at + 3] * 1.2, int(candidates[at + 2]))
		if pose.x == INF: continue
		var item := candidates.slice(at, at + STRIDE)
		var down := Vector2(pose.y, pose.w)
		if down.length_squared() > 0.004 * 0.004:
			down = down.normalized()
			item[6] = down.x
			item[7] = down.y
		out.append_array(item)
	return out


## Соседние массивы могут влиять на осыпь за пределами собственного пятна.
const TALUS_RANGE := 6.5


static func near(all: PackedFloat32Array, x0: int, y0: int, x1: int, y1: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var reach := TALUS_RANGE + 1.0 # включая поперечную ширину веера
	for at in range(0, all.size(), STRIDE):
		var sx := all[at]
		var sy := all[at + 1]
		if sx < x0 - reach or sy < y0 - reach or sx >= x1 + reach or sy >= y1 + reach: continue
		out.append_array(all.slice(at, at + STRIDE))
	return out


## Лежит ли точка (px, py) в плотном теле одного из массивов list (с запасом pad, клеток).
static func covers(list: PackedFloat32Array, px: float, py: float, pad: float) -> bool:
	for at in range(0, list.size(), STRIDE):
		var c := core(list, at)
		var r: float = c.z + pad
		if (px - c.x) * (px - c.x) + (py - c.y) * (py - c.y) < r * r: return true
	return false


## Центр (x, y) и радиус (z) плотного тела массива номер at, в клетках: стена смещена в склон.
static func core(list: PackedFloat32Array, at: int) -> Vector3:
	var spec: Dictionary = Spec[RockModels.massif_form(int(list[at + 2]))]
	var s: float = list[at + 3] * 1.2 / GameConfig.TILE
	var offset: Vector3 = spec.core
	return Vector3(list[at] + list[at + 6] * offset.z * s, list[at + 1] + list[at + 7] * offset.z * s, spec.core_r * s)
