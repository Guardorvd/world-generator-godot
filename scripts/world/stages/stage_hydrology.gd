class_name StageHydrology
extends RefCounted
## Rare closed lakes on unchanged relief; rainfall does not require physical water.
## No global flood, drainage ordering, discharge accumulation or depression filling.

const PROGRESS := 0.2
const LABEL := "Осадки и редкие озёра"
const SHORE_LIFT := 0.003 # retained for the explicit river shaping tools
const LAKE_MIN := 24
const LAKE_MAX := 320
const LAKE_DEPTH := 0.004
const COAST_REACH := 32
## Региональный характер местности (14.11.2026, GEO 18, docs/MACRO_GEOGRAPHY.md). Осадки здесь — основа
## влажности почвы, поэтому через них без новых систем и без правки C# меняются биомы (StageClimate),
## густота и состав леса (StageVegetation) и открытость породы (MountainSurface). Два плавных слагаемых
## только из данных самой клетки (одинаково в плане и в OuterLand):
##   REGION_* — медленная волна того же шума влажности: сухие и влажные края размером в несколько км;
##              REGION_AMP — выраженность, REGION_SCALE — размер (больше — крупнее и реже);
##   RELIEF_* — положение в рельефе (position_field): дно долин и ложбин влажнее, гребни и вершины холмов
##              суше — относительно окрестности радиусом POSITION_R, а не по абсолютной высоте (долина на 40 м
##              влажная, гребень у моря сухой). POSITION_SCALE — перепад (в единицах h), дающий полную поправку.
## Выше REGION_KEEP (≈ 85–110 м) поправка гаснет: горы, их биомы и скальные склоны как были. Ноль — прежние осадки.
const REGION_SCALE := 640.0
const REGION_OX := 57.3
const REGION_OY := -21.9
const REGION_AMP := 0.26
const RELIEF_WET := 0.10
const RELIEF_DRY := 0.12
const POSITION_R := 24       # клеток (~100 м): масштаб долины и гребня; не больше OuterLand.PAD - 2
const POSITION_SCALE := 0.03 # ~8 м ниже или выше окрестности — полная поправка
const REGION_KEEP := Vector2(0.32, 0.42)
const DRY_FLOOR := 0.45 # ниже этих осадков сушь действует втрое слабее (не ниже прежних осадков)
## false — прежние осадки (до 14.11.2026) для сравнения в стендах (tools/macro_geo_look.gd --no-character)
static var regional := true


## noise_value — поле влажности (WorldData.NOISE_FIELDS.moist), region — медленная волна (region_field),
## e — высота клетки в единицах WorldData.h (ниже нуля — море: поправки нет),
## position — высота клетки минус средняя высота окрестности (position_field)
static func rainfall(noise_value: float, distance_to_ocean: float, region: float, e: float, position: float) -> float:
	# Compact coastal influence: OuterLand can reproduce it within its fixed halo.
	var far := exp(-COAST_REACH / 30.0)
	var coast := maxf(0.0, (exp(-distance_to_ocean / 30.0) - far) / (1.0 - far))
	var base := 0.66 + 0.48 * noise_value + 0.08 * coast
	var rain := base
	if e > 0.0 and regional:
		var valley := smoothstep(0.0, POSITION_SCALE, -position)
		var ridge := smoothstep(0.0, POSITION_SCALE, position)
		rain += (REGION_AMP * region + RELIEF_WET * valley - RELIEF_DRY * ridge) * (1.0 - smoothstep(REGION_KEEP.x, REGION_KEEP.y, e))
		# Сушь мягко упирается в DRY_FLOOR: сухие края — лесостепь и луга, а не голая степь (её цвет — почти песок)
		var floor_rain := minf(base, DRY_FLOOR)
		if rain < floor_rain:
			rain = floor_rain + (rain - floor_rain) * 0.3
	return clampf(rain, 0.12, 1.0)


## Положение в рельефе: высота суши (max(0, h)) минус средняя по квадрату ±POSITION_R клеток (у края поля квадрат
## обрезается). Отрицательно в долинах и ложбинах, положительно на гребнях. parallel — строками на всех ядрах
## (только для полного плана: OuterLand уже считается в потоках)
static func position_field(h: PackedFloat32Array, W: int, H: int, parallel := false) -> PackedFloat32Array:
	var R := POSITION_R
	var e := PackedFloat32Array()
	e.resize(W * H)
	for i in W * H:
		e[i] = maxf(0.0, h[i])
	# Средние по строкам (окно ±R по x), затем по столбцам этих средних: ширина окна в столбце одна,
	# поэтому это ровно среднее по прямоугольнику
	var row_job := func(y0: int, y1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((y1 - y0) * W)
		var pre := PackedFloat64Array()
		pre.resize(W + 1)
		for y in range(y0, y1):
			for x in W:
				pre[x + 1] = pre[x] + e[y * W + x]
			for x in W:
				var a := maxi(0, x - R)
				var b := mini(W - 1, x + R)
				out[(y - y0) * W + x] = (pre[b + 1] - pre[a]) / (b - a + 1)
		return out
	var rows := PackedFloat32Array()
	for part: PackedFloat32Array in (Parallel.bands(H, row_job) if parallel else [row_job.call(0, H)]):
		rows.append_array(part)
	var col_job := func(x0: int, x1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((x1 - x0) * H)
		var pre := PackedFloat64Array()
		pre.resize(H + 1)
		for x in range(x0, x1):
			for y in H:
				pre[y + 1] = pre[y] + rows[y * W + x]
			for y in H:
				var a := maxi(0, y - R)
				var b := mini(H - 1, y + R)
				out[(x - x0) * H + y] = (pre[b + 1] - pre[a]) / (b - a + 1)
		return out
	var position := PackedFloat32Array()
	position.resize(W * H)
	var x0 := 0
	for part: PackedFloat32Array in (Parallel.bands(W, col_job) if parallel else [col_job.call(0, W)]):
		var n := part.size() / H
		for k in n:
			for y in H:
				position[y * W + x0 + k] = e[y * W + x0 + k] - part[k * H + y]
		x0 += n
	return position


## Медленная волна влажности для rainfall по прямоугольнику клеток (тот же шум moist, свой масштаб и сдвиг)
static func region_field(w: WorldData, x0: int, y0: int, cw: int, ch: int, parallel_rows := false) -> PackedFloat64Array:
	return Parallel.fbm_rect(w.noise.moist, x0, y0, cw, ch, REGION_SCALE, 2, REGION_OX, REGION_OY, parallel_rows)


## lake_budget = 0 explicitly exercises a freshwater-free world; -1 selects by seed.
static func run(w: WorldData, lake_budget := -1) -> void:
	w.filled = w.h.duplicate()
	var empty_mask := PackedByteArray()
	empty_mask.resize(w.N)
	w.lake = empty_mask.duplicate()
	w.river = empty_mask.duplicate()
	w.river_area = w.river.duplicate()
	var empty_acc := PackedFloat32Array()
	empty_acc.resize(w.N)
	w.acc = empty_acc
	var no_down := PackedInt32Array()
	no_down.resize(w.N)
	no_down.fill(-1)
	w.down = no_down
	w.watershed = no_down.duplicate()
	w.order = PackedInt32Array()
	w.order_n = 0
	w.rivers.clear()
	w.river_exits.clear()
	w.dist_ocean = Grid.distance_field(w.W, w.H, w.ocean)
	var noise_values := w.noise_field("moist")
	var region := region_field(w, 0, 0, w.W, w.H, true)
	var dist_ocean := w.dist_ocean
	var h := w.h
	var W := w.W
	var position := position_field(h, W, w.H, true)
	# Полосами на всех ядрах: по клетке независимо, результат тот же, что подряд
	var rain := PackedFloat32Array()
	for part: PackedFloat32Array in Parallel.bands(w.H, func(y0: int, y1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((y1 - y0) * W)
		for i in range(y0 * W, y1 * W):
			out[i - y0 * W] = rainfall(noise_values[i], dist_ocean[i], region[i], h[i], position[i])
		return out):
		rain.append_array(part)
	w.rain = rain
	var budget_rng := WGRandom.new(WGRandom.derive(w.seed_num, "water.rare_lakes"))
	var want := mini(2, floori(budget_rng.next_float() * 3.0)) if lake_budget < 0 else clampi(lake_budget, 0, 2)
	var count := 0
	# Work is bounded independently of the number of depressions in the map.
	for attempt in (192 if want > 0 and mini(w.W, w.H) > 48 else 0):
		if count >= want: break
		var candidate := lake_candidate(w.seed_num, w.W, w.H, attempt)
		var x: int = candidate.x
		var y: int = candidate.y
		var c := y * w.W + x
		# A short local descent only proposes a basin; it never edits terrain.
		for step in 24:
			var best := c
			for k in 8:
				var n: int = c + Grid.DY[k] * w.W + Grid.DX[k]
				if n >= 0 and n < w.N and absi(n % w.W - c % w.W) <= 1 and w.h[n] < w.h[best]: best = n
			if best == c: break
			c = best
		if w.ocean[c] != 0 or w.lake[c] != 0 or w.dist_ocean[c] < 12.0: continue
		var level := w.h[c] + float(candidate.depth)
		# Зеркало пресного озера должно быть выше глобальной плоскости океана.
		if level * GameConfig.HS <= GameConfig.LAKE_DROP: continue
		var cells := _closed_basin(w, c, level)
		if cells.is_empty(): continue
		for i in cells:
			w.lake[i] = 1
			w.filled[i] = level
		count += 1
	w.generation_profile.freshwater_lakes = count


## Each proposal owns its random stream. Rejecting a basin must not consume or
## skip numbers belonging to later coordinates/depths. Terrain still decides
## which proposals form real lakes; the bounded lake budget is a separate policy.
## depth uses the same normalized height units as w.h (not metres).
static func lake_candidate(seed_num: int, width: int, height: int, attempt: int) -> Dictionary:
	var proposal := WGRandom.at(seed_num, "water.lake_candidate", attempt, 0)
	return {x=24+floori(proposal.next_float()*(width-48)),
		y=24+floori(proposal.next_float()*(height-48)), depth=0.006+proposal.next_float()*0.010}


## Reject open, narrow, oversized or overlapping pools. One constant level per lake.
## Eight-neighbour closure also rejects diagonal leaks; no artificial banks or steps.
static func _closed_basin(w: WorldData, start: int, level: float) -> PackedInt32Array:
	var cells := PackedInt32Array([start])
	var seen := {start: true}
	var head := 0
	var origin := Vector2i(start % w.W, start / w.W)
	var lo := origin
	var hi := origin
	while head < cells.size():
		var c := cells[head]
		head += 1
		var p := Vector2i(c % w.W, c / w.W)
		if p.x < 4 or p.y < 4 or p.x >= w.W - 4 or p.y >= w.H - 4 or absi(p.x - origin.x) > 20 or absi(p.y - origin.y) > 20:
			return PackedInt32Array()
		lo = lo.min(p)
		hi = hi.max(p)
		for k in 8:
			var n: int = c + Grid.DY[k] * w.W + Grid.DX[k]
			if w.ocean[n] != 0 or w.lake[n] != 0: return PackedInt32Array()
			if w.h[n] >= level or seen.has(n): continue
			seen[n] = true
			cells.append(n)
			if cells.size() > LAKE_MAX: return PackedInt32Array()
	var span := hi - lo + Vector2i.ONE
	if cells.size() < LAKE_MIN or mini(span.x, span.y) < 5 or float(cells.size()) / (span.x * span.y) < 0.3:
		return PackedInt32Array()
	return cells
