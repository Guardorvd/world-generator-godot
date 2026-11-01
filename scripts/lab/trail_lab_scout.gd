extends RefCounted
## Trail Lab, поисковик мест под трассы (01.11, v1 — простой). По миру генератора местности (TrailLabTerrain.world_h,
## world_wet) ищет окна CELLS × CELLS (как окно лаборатории, 512 м), где трассу можно проложить: без воды во
## внутренней части, перепад и уклон под какой-нибудь стиль, мало круч. Берёт лучшие непересекающиеся — от одного
## до MAX_SITES, сколько найдётся, — и даёт каждому стиль по рельефу (крутое — даунхилл, среднее — эндуро или flow,
## пологое — flow или техничная) и свой сид трассы. Быстро: выборка через SAMPLE клеток, без полной сборки.
## Детерминирован по (мир, seed).

const TrailLabTerrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const MAX_SITES := 8
const STRIDE := 24          # шаг окон-кандидатов, клеток
const SAMPLE := 4           # шаг выборки внутри окна, клеток
const INNER := 0.12         # отступ внутренней части окна от края (доля): там вода не допускается
const FALL := Vector2(25.0, 220.0) # годный перепад внутренней части, м
const STEEP := 0.7          # круче (м на м между выборками) — круча
const SPREAD := 0.75        # центры мест не ближе этой доли окна
const WATER_MAX := 0.12     # больше воды во внутренней части — место не годится (реки трасса обходит)

static var sites: Array[Dictionary] = []
static var stats := {}


## Места на текущем мире генератора местности. Пусто — мир не создан или мест нет (stats.reason).
static func find(seed_value: int) -> Array[Dictionary]:
	var started := Time.get_ticks_usec()
	sites = []
	stats = {}
	var n := TrailLabTerrain.world_size
	if n <= 0 or TrailLabTerrain.world_h.is_empty():
		stats = {reason = "мир не создан"}
		return sites
	var h := TrailLabTerrain.world_h
	var wet := TrailLabTerrain.world_wet
	var cells := TrailLabTerrain.CELLS
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("trail_lab_scout|%d|%d" % [TrailLabTerrain.world_seed, seed_value])
	var found: Array[Dictionary] = []
	var looked := 0
	var refused := {}
	var y0 := 0
	while y0 + cells <= n:
		var x0 := 0
		while x0 + cells <= n:
			looked += 1
			var c := _measure(h, wet, n, x0, y0, cells)
			if not c.reason.is_empty():
				refused[c.reason] = int(refused.get(c.reason, 0)) + 1
			else:
				found.append(c)
			x0 += STRIDE
		y0 += STRIDE
	# лучшие непересекающиеся; немного случайности в порядке — у другого сида поиска другой набор
	for c in found: c.score += rng.randf() * 0.15
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score > b.score)
	var spread := cells * SPREAD
	for c in found:
		if sites.size() >= MAX_SITES: break
		var free := true
		for s in sites:
			if Vector2(c.origin).distance_to(Vector2(s.origin)) < spread: free = false
		if free: sites.append(c)
	for i in sites.size():
		var s := sites[i]
		s.n = i + 1
		s.style = _style(s, rng)
		s.trail_seed = rng.randi_range(1, 99999)
	stats = {looked = looked, fit = found.size(), sites = sites.size(), refused = refused, ms = (Time.get_ticks_usec() - started) / 1000.0}
	if sites.is_empty(): stats.reason = "мест не нашлось (%s)" % [refused]
	return sites

## Окно с углом (x0, y0): перепад, средний уклон, доля круч и воды во внутренней части; reason — почему не годится.
static func _measure(h: PackedFloat32Array, wet: PackedByteArray, n: int, x0: int, y0: int, cells: int) -> Dictionary:
	var lo := INF
	var hi := -INF
	var slope_sum := 0.0
	var steep := 0
	var count := 0
	var margin := int(cells * INNER)
	var water := 0
	var edge_water := 0
	for z in range(0, cells, SAMPLE):
		for x in range(0, cells, SAMPLE):
			var i := (y0 + z) * n + x0 + x
			var inner := x >= margin and z >= margin and x < cells - margin and z < cells - margin
			if wet[i] != 0:
				if inner: water += 1
				else: edge_water += 1
				continue
			if not inner: continue
			lo = minf(lo, h[i])
			hi = maxf(hi, h[i])
			if x + SAMPLE < cells and z + SAMPLE < cells:
				var gx := (h[i + SAMPLE] - h[i]) / (SAMPLE * GameConfig.TILE)
				var gz := (h[i + SAMPLE * n] - h[i]) / (SAMPLE * GameConfig.TILE)
				var g := sqrt(gx * gx + gz * gz)
				slope_sum += g
				if g > STEEP: steep += 1
				count += 1
	var r := {origin = Vector2i(x0, y0), reason = "", score = 0.0}
	# реки — часть местности (трасса их обходит), а море и озеро на полокна — нет
	var inner_total := water + count
	var water_share := float(water) / maxf(1.0, inner_total)
	if water_share > WATER_MAX or count < 10: r.reason = "вода"
	if not r.reason.is_empty(): return r
	var fall := hi - lo
	var slope := slope_sum / count
	var steep_share := float(steep) / count
	if fall < FALL.x: r.reason = "ровно"
	elif fall > FALL.y: r.reason = "слишком крутой перепад"
	elif steep_share > 0.25: r.reason = "кручи"
	if not r.reason.is_empty(): return r
	# лучше: перепад 60–140 м, уклон 8–25 %, мало круч и воды у края
	var score := 1.0 - absf(fall - 100.0) / 120.0 - absf(slope - 0.16) * 2.0 - steep_share * 2.0 - water_share * 3.0 - edge_water * 0.002
	r.merge({fall = snappedf(fall, 0.1), slope = snappedf(slope, 0.001), steep = snappedf(steep_share, 0.01), water = snappedf(water_share, 0.01), score = score})
	return r

## Стиль по рельефу места (со случайностью между подходящими).
static func _style(s: Dictionary, rng: RandomNumberGenerator) -> String:
	var fall: float = s.fall
	if fall > 120.0: return ["downhill", "enduro"][rng.randi() % 2]
	if fall > 60.0: return ["enduro", "flow", "downhill", "tech"][rng.randi() % 4]
	return ["flow", "tech", "flow"][rng.randi() % 3]
