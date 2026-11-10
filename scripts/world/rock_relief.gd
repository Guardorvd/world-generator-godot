class_name RockRelief
extends RefCounted
## Скальный рельеф (09.11.2026): сама поверхность скальных склонов — пласты-уступы, гребешки и скальные
## зубцы — в высотах игрового Heightfield, а не только материал и отдельные модели поверх гладкого склона.
## Применяется в Heightfield.finish_paths, то есть ПОСЛЕ прокладки дорог и троп: поиск маршрутов его не
## видит и не замедляется, а меш, физика колёс, опора камней, трава и кэш поверхности получают одну и ту же
## поверхность. У путей (с запасом 14–26 м), воды, поселений, мест и края стартовой области слой гаснет до нуля.
##
## Форма — из уже готовых данных: высота, крутизна, открытость породы (MountainSurface) и серый скальный биом
## климата — те же признаки, что у материала (terrain.gdshader) и массивов (RockMassif). Пласты общие с
## поясами стен RockMassif (strata): стена встаёт на уступ рельефа, а не рядом с ним.

const MAX_SHIFT := 9.0       # наибольшая поправка высоты, м
const PATH_CLEAR := 14.0     # ближе этого к пути (м) — без поправки
const PATH_FULL := 26.0      # дальше — полная
const EDGE := 8              # клеток у края стартовой области без поправки (шов с землёй за краем)
const SALT := 0x524c4946


## Пласты массива в точке (клетки мира): x — шаг пласта, м; y — сдвиг отметок, м. Медленно меняются
## по массиву: шаг 9–21 м, отметки плавно «падают» — пласты наклонены, а не горизонтали карты.
static func strata(seed_num: int, x: float, y: float) -> Vector2:
	var spacing := lerpf(9.0, 21.0, RockMassif._value(seed_num, x, y, 70.0, 0x42414e44))
	return Vector2(spacing, RockMassif._value(seed_num, x, y, 45.0, 0x50484153) * spacing * 3.0)


## Насколько клетка скальная, 0..1: открытая порода или серый скальный биом в горах.
static func rockiness(elev: float, exposure: float, biome: int) -> float:
	var rocky := maxf(exposure, 0.62 if biome == Biomes.ROCK or biome == Biomes.PEAK else 0.0)
	return smoothstep(0.3, 0.62, rocky) * smoothstep(0.12, 0.3, elev)


## Решётка значений RockMassif._value (те же хеши и сглаживание), посчитанная один раз на прямоугольник:
## слой проходит десятки тысяч клеток, а хеш на каждую клетку и шум стоили секунды.
class Lattice:
	var step := 1.0
	var ix0 := 0
	var iy0 := 0
	var cols := 0
	var values := PackedFloat32Array()

	func _init(seed_num: int, s: float, salt: int, x0: float, y0: float, x1: float, y1: float) -> void:
		step = s
		ix0 = floori(x0 / s)
		iy0 = floori(y0 / s)
		cols = floori(x1 / s) - ix0 + 2
		var rows := floori(y1 / s) - iy0 + 2
		values.resize(cols * rows)
		for j in rows:
			for i in cols:
				values[j * cols + i] = WGRandom.hash2(ix0 + i, iy0 + j, seed_num ^ salt)

	func at(x: float, y: float) -> float:
		var gx := x / step
		var gy := y / step
		var ix := floori(gx)
		var iy := floori(gy)
		var tx := smoothstep(0.0, 1.0, gx - ix)
		var ty := smoothstep(0.0, 1.0, gy - iy)
		var k := (iy - iy0) * cols + ix - ix0
		return lerpf(lerpf(values[k], values[k + 1], tx), lerpf(values[k + cols], values[k + cols + 1], tx), ty)


## Поправка высоты (м) по значениям шумов места: sturdy (прочность), crag (скалистость), пласт st,
## n — зубцы (~20 м), spire — шпили (~12 м); h — исходная высота, sl — крутизна, convex — выпуклость (м).
static func shape(h: float, sl: float, convex: float, rock: float, sturdy: float, crag: float, st: Vector2, n: float, spire: float) -> float:
	# Соседние пласты имеют разную мощность. Профили сходятся к нулю на общей
	# отметке, поэтому смена мощности не разрывает поверхность.
	var u := (h - st.y) / st.x
	var f := u - floorf(u)
	var competence := smoothstep(0.24, 0.7, sturdy)
	var broken_bed := posmod(floori(u), 3) == 1
	var k := lerpf(2.8, 6.5, competence)
	var terrace := (pow(f, k) - f + (0.5 - 1.0 / (k + 1.0)) * 6.0 * f * (1.0 - f)) * st.x
	var ledge := lerpf(0.18, 1.0, competence)
	if broken_bed: ledge *= lerpf(0.22, 0.82, competence)
	var open := smoothstep(0.22, 0.72, crag)
	var steep := smoothstep(0.15, 0.5, sl)
	var shift := terrace * ledge * lerpf(0.3, 1.05, open) * steep
	# Разрушение проявляется пятнами. На пологой поверхности остаются только
	# отдельные выступы, привязанные к выпуклым плечам и гребням.
	var fracture := smoothstep(0.26, 0.77, n)
	var ribs := smoothstep(0.0, 0.65, convex)
	shift += (fracture - 0.45) * lerpf(2.0, 6.4, 1.0 - competence) * open * steep
	shift += smoothstep(0.52, 0.87, spire) * 5.2 * ribs * open
	shift *= rock
	return clampf(shift, -MAX_SHIFT, MAX_SHIFT)

static func field_of(w: WorldData) -> PackedByteArray:
	if w.generation.surface_rock.size() == w.N:
		return w.generation.surface_rock
	return preload("res://scripts/world/mountain_surface.gd").field(w.elev, w.slope, w.moist)


## Поправить высоты h.hv стартовой области (на месте). Возвращает число изменённых клеток.
static func apply(h: Heightfield) -> int:
	var w := h.world
	if w == null or w.N <= 0 or w.elev.size() != w.N or w.slope.size() != w.N or w.biome.size() != w.N:
		return 0
	var W := w.W
	var H := w.H
	var rock_field := field_of(w)
	# Расстояние до путей и до домов/мест, клетки (C#: FastGrid.DistanceField).
	var busy := PackedByteArray()
	busy.resize(w.N)
	for i in w.N:
		if w.path_mask.size() == w.N and w.path_mask[i] != 0: busy[i] = 1
	# Поселения (квадрат StageVegetation.VILLAGE_R) и места (их поляна) — как у растительности.
	for list: Array in [w.settlements, w.sites]:
		for s: EntityRecord in list:
			var r: float = StageVegetation.VILLAGE_R if list == w.settlements else maxf(2.0, s.get("clear") if "clear" in s else 3.0)
			for yy in range(maxi(0, floori(s.y - r)), mini(H, ceili(s.y + r) + 1)):
				for xx in range(maxi(0, floori(s.x - r)), mini(W, ceili(s.x + r) + 1)):
					busy[yy * W + xx] = 1
	var dist := Grid.distance_field(W, H, busy)
	var water: PackedByteArray = StageVegetation._TABLES.water
	var hs := GameConfig.HS
	var ox := w.world_origin.x
	var oy := w.world_origin.y
	var hv := h.hv
	var x0 := float(ox)
	var y0 := float(oy)
	var x1 := float(ox + W)
	var y1 := float(oy + H)
	var seed := w.seed_num
	var l_sturdy := Lattice.new(seed, 28.0, 0x434f4d50, x0, y0, x1, y1)
	var l_crag := Lattice.new(seed, 90.0, 0x43524147, x0, y0, x1, y1)
	var l_band := Lattice.new(seed, 70.0, 0x42414e44, x0, y0, x1, y1)
	var l_phase := Lattice.new(seed, 45.0, 0x50484153, x0, y0, x1, y1)
	var l_teeth := Lattice.new(seed ^ SALT, 5.0, 0x5a554243, x0, y0, x1, y1)
	var l_spire := Lattice.new(seed ^ SALT, 4.5, 0x53504952, x0, y0, x1, y1)
	var elev := w.elev
	var biome := w.biome
	var slope := w.slope
	var dw := w.dist_water if w.dist_water.size() == w.N else PackedFloat32Array()
	var seed_ox := ox
	var seed_oy := oy
	# Ряды независимы: считаются на всех ядрах (Parallel.bands), каждый в свой массив, склеиваются по порядку.
	var job := func(r0: int, r1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((r1 - r0) * W)
		for y in range(maxi(1, r0), mini(H - 1, r1)):
			for x in range(1, W - 1):
				var i := y * W + x
				var e := elev[i]
				if e < 0.12: continue
				var bi := biome[i]
				if water[bi] != 0: continue
				var rock := rockiness(e, float(rock_field[i]) / 255.0, bi)
				if rock <= 0.0: continue
				var edge := mini(mini(x, y), mini(W - 1 - x, H - 1 - y))
				rock *= smoothstep(float(EDGE), float(EDGE + 6), float(edge))
				rock *= smoothstep(PATH_CLEAR, PATH_FULL, dist[i] * GameConfig.TILE)
				if not dw.is_empty(): rock *= smoothstep(3.0, 6.0, dw[i])
				if rock <= 0.0: continue
				var convex := (e - (elev[i - 1] + elev[i + 1] + elev[i - W] + elev[i + W]) * 0.25) * hs
				if slope[i] <= 0.15 and convex <= 0.0: continue
				var wx := float(x + seed_ox)
				var wy := float(y + seed_oy)
				var spacing := lerpf(9.0, 21.0, l_band.at(wx, wy))
				var st := Vector2(spacing, l_phase.at(wx, wy) * spacing * 3.0)
				var d := shape(e * hs, slope[i], convex, rock, l_sturdy.at(wx, wy), l_crag.at(wx, wy), st, l_teeth.at(wx, wy), l_spire.at(wx, wy))
				if absf(d) >= 0.01: out[(y - r0) * W + x] = d
		return out
	var shifted := PackedFloat32Array()
	for part: PackedFloat32Array in Parallel.bands(H, job):
		shifted.append_array(part)
	var changed := 0
	for i in w.N:
		if shifted[i] != 0.0:
			hv[i] += shifted[i]
			changed += 1
	h.hv = hv
	return changed
