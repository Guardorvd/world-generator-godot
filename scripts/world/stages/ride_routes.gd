class_name RideRoutes
extends RefCounted
## Природные велосипедные маршруты (с 07.11.2026): небольшая надстройка над дорожной сетью этапа StageTrails.
## Идёт последней частью этапа, на том же поиске (Pathfinder с его коридором и высотами), той же стоимости местности
## и той же публикации пути (StageTrails._add_trail: линия по рельефу, path_mask, дальше RoadSurface, RoadBed,
## растительность, кэш и сохранения — как у любой тропы). Ничего не запекается до выбора.
##
## 1. Опорные точки — на готовой сети (дороги, тропы, горные тропы), примерно через 40 м. Высокие (самая высокая точка
##    сети в радиусе TOP_R: седловина дороги, плечо, вершина горной тропы) — старты спусков; финиши — точки сети ниже
##    на DROP_MIN и больше на разумном расстоянии. Маршрут начинается и кончается на сети: горная тропа становится
##    подъёмом к началу спуска, а спуск выводит к другой дороге или тропе. Горы без сети получают виртуальные вершины
##    (самая высокая клетка блока ~100 м, выше соседних блоков, вдали от сети): к ним ищется подъём от ближайшей точки
##    сети (как горная тропа), и он публикуется, только если с вершины принят хотя бы один спуск.
## 2. На пару старт–финиш — несколько виртуальных линий тем же A*: плавная (мягкий предел уклона), техническая (крутая,
##    прямее) и лесная через промежуточный ориентир на плече склона (лес дешевле открытой земли).
## 3. Оценка — несколько простых чисел: перепад, длина, подъёмы на спуске (штраф), извилистость, разнообразие уклонов,
##    лес, доля новой земли (идти рядом с готовой сетью — дубликат).
## 4. Отбор жадный: сначала лучший маршрут каждого характера, потом по оценке. Маршрут, который больше чем на SAME_SHARE
##    идёт рядом с принятым, — дубликат. Ниже MIN_SCORE маршрута нет: где нет хороших склонов, трассы не навязываются.
## 5. Опубликованные полотна получают метки ride и ride_style. Направленные интервалы всего маршрута, включая
##    общий подъём и повторное использование сети, сохраняются отдельно в w.road_rides.
## Поиски последовательные: A* на C# занимает миллисекунды, а один FastGrid держит общие буферы поиска (параллельный
## поиск потребовал бы отдельных сеток и копий стоимости — выигрыша при десятках поисков нет).
## Откат: ENABLED = false или запуск с `-- --trail-network` (прежняя универсальная сеть, без этих маршрутов).

const ENABLED := true
const ANCHOR_STEP := 10.0  # клеток между опорными точками на сети (~40 м)
const TOP_R := 40          # старт — самая высокая опорная точка сети в таком радиусе, клеток (160 м)
const DROP_MIN := 40.0     # наименьший перепад маршрута, м
const D_MIN := 40          # прямое расстояние старт–финиш, клеток (160 м)
const D_MAX := 220         # (880 м)
const ENDS_PER_TOP := 3    # финишей на старт, в разных направлениях
const END_ANGLE := 0.6     # и не ближе этого по направлению (cos ~53°)
const NEAR_R := 10.0       # клетка ближе этого к готовой сети (клеток, 40 м) — «рядом с сетью»
const NEAR_MUL := 4.0      # во столько раз дороже клетки рядом с сетью: маршрут сразу уходит на новую землю
const OPEN_MUL := 1.8      # лесная линия: открытая земля дороже
const RIVER_MUL := 6.0     # клетка реки дороже во столько раз (брод и так стоит +12)
const FORD_RUN := 2        # подряд клеток воды на пути не больше (как брод тропы, StageTrails.FORD_LEN)
const WINDOW_MARGIN := 40  # окно поиска вокруг старта и финиша, клеток
const SEARCH_BUDGET := 300000 # раскрытий A* на поиск
const SEARCHES := 120      # поисков на мир 512 (w.scale = 1)
const MAX_RIDES := 10      # маршрутов на мир 512
const SAME_R := 6          # клетки ближе этого к принятому маршруту — «рядом»
const SAME_SHARE := 0.2    # больше этой доли рядом с принятым — дубликат (11.11.2026: было 0,3 — параллельные спуски)
const NEW_SHARE := 0.6     # не меньше этой доли — новая земля (дальше NEAR_R от готовой сети)
const MIN_SCORE := 1.2
const BLOCK := 24          # виртуальные вершины: самая высокая клетка блока таких размеров (~100 м)
const TOP_SLOPE := 0.12    # среди клеток положе этого (w.slope, ~26 %): плечо, куда можно подняться, а не скальный гребень
const VIRTUAL_GAP := 25.0  # и не ближе стольких клеток к сети (100 м): у сети и так есть свои старты
const APPROACH_MAX := 150.0 # подъём к ней от точки сети не дальше по прямой, клеток (600 м)
const VIRTUAL_TOPS := 10   # виртуальных вершин на мир 512
const ECHO_R := 20.0      # клетки ближе этого (80 м) к пути сети между теми же концами — «вдоль него»
const ECHO_SHARE := 0.5    # больше этой доли вдоль пути сети — маршрут повторяет его (спуск рядом с горной тропой)
## Поиск: climb — штраф за уклон (больше — ровнее и извилистее), grade — предел уклона шага.
const STYLES := {
	flow = {climb = 24.0, grade = 0.32, wood = false, via = false},
	traverse = {climb = 150.0, grade = 0.22, wood = false, via = false}, # 17.11: подъём очень дорог — путь по склону
	tech = {climb = 4.0, grade = 0.5, wood = false, via = false},
	forest = {climb = 12.0, grade = 0.36, wood = true, via = true},
}
const WOODED := [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE]
const WOOD_SCORE := 0.4    # вес доли леса в оценке маршрута
## 17.11.2026: траверс (характер traverse) — путь вокруг горы почти по одной высоте от горной тропы к другому пути
## сети. Те же пары, поиск, оценка и отбор, что у спусков; свои только условия пары и годности (_pairs, _score).
const TRAVERSE_BAND := 15.0  # м: конец не дальше по высоте от начала; путь — не дальше BAND + 10 м
const TRAVERSE_ANGLE := 80.0 # градусов вокруг вершины (w.peaks) между началом и концом хотя бы
const TRAVERSE_R := 120.0    # клеток: вершина не дальше от начала
const TRAVERSE_RISE := 30.0  # м: вершина выше начала хотя бы на столько
const TRAVERSE_LEN := Vector2(300.0, 1000.0) # м длины
const TRAVERSE_PAIRS := 6    # пар на мир 512 (в общем лимите поисков SEARCHES)
const TRAVERSE_PRIORITY := 80.0 # место пары в очереди поиска — как спуск с таким перепадом, м


static func enabled() -> bool:
	return ENABLED and not QuickTrails.network()


## finder — поиск этапа; on_axis — клетки осей мостов и туннелей
static func run(w: WorldData, finder: Pathfinder, surface: Heightfield, on_axis: PackedByteArray) -> void:
	var started := Time.get_ticks_usec()
	# Подъём к виртуальной вершине использует профиль горной тропы.
	var approach := {climb = RoadTuning.current().routing.climb_costs.mountain, grade = StageTrails.MOUNTAIN_GRADE}
	var stats := {anchors = 0, tops = 0, pairs = 0, searches = 0, found = 0, rejected = {}, accepted = 0,
		from_mountain = 0, virtual_tops = 0, virtual_failed = [], climbs = 0, climb_km = 0.0, km = 0.0, styles = {},
		by_search = {}, wood = {}, ms = 0.0} # by_search: стиль поиска → [попыток, линий, годных]
	w.generation_profile.rides = stats
	if not enabled() or surface == null:
		return
	# Flow/forest publish a wider trail than mountain approaches. Search its full width.
	StageTrails._route_surface(finder, surface, RoadTuning.current().section.widths.trail, "corridor_rides_ms")
	var W := w.W
	var hv := surface.hv
	# Расстояние до готовой сети (дороги, тропы, горные тропы) — одна проходка C#
	var fast := Grid.fast_grid()
	var net: PackedByteArray = fast.BytesAtLeast(w.path_mask, 2) if fast != null else _net_mask(w.path_mask)
	var dist := Grid.distance_field(W, w.H, net)
	# Стоимость маршрута: та же местность, рядом с сетью дороже (и сама сеть: протоптанная дешевизна не тянет вдоль дороги);
	# в том же проходе — самая высокая клетка каждого блока BLOCK×BLOCK (кандидаты в виртуальные вершины)
	var fields := cost_fields(w, hv, net, dist, fast)
	var cost: PackedFloat32Array = fields.cost
	var wood: PackedFloat32Array = fields.wood
	var block: PackedInt32Array = fields.block
	var bw := ceili(float(W) / BLOCK)
	stats.prepare_ms = (Time.get_ticks_usec() - started) / 1000.0
	var anchors := _anchors(w, hv, on_axis, cost)
	# Сеть V2 (шаг 7): без опорных точек рядом с развилками (RoadNetworkV2.ride_anchors)
	if StageTrails.network_v2:
		anchors = StageTrails.RoadNetworkV2.ride_anchors(w, finder, surface, on_axis, anchors)
	stats.anchors = anchors.size()
	var virtual := _virtual_tops(w, hv, dist, block, bw, anchors)
	stats.virtual_tops = virtual.map(func(v: Dictionary) -> Array: return [v.x, v.y, roundi(v.rise)])
	var pairs := _pairs(w, anchors, virtual, stats)
	var budget := roundi(SEARCHES * w.scale)
	var candidates: Array = []
	var cost_version := finder.next_cost_version()
	var wood_version := finder.next_cost_version()
	var network := StageTrails._network_cost(w)
	var network_version := finder.next_cost_version()
	finder.use_corridor = true
	for pair: Array in pairs:
		var s: Dictionary = pair[0]
		var t: Dictionary = pair[1]
		var echo := PackedInt32Array() # путь по готовой сети между теми же концами (пустой — его нет); ищется один раз на пару
		var echo_ready := false
		if s.virtual:
			# Подъём к виртуальной вершине от ближайшей точки сети — как горная тропа; один раз на вершину
			if not s.has("approach") and stats.searches < budget:
				s.approach = PackedInt32Array()
				for from: int in s.from:
					s.approach = _search(finder, w, cost, cost_version, from, s.i, approach, stats)
					if not s.approach.is_empty(): break
				# Не поднялись: вокруг вершины стены круче горной тропы (замер 07.11: путь есть только с уклоном больше 55 %)
				if s.approach.is_empty(): stats.virtual_failed.append([s.x, s.y, roundi(s.rise)])
			if s.get("approach", PackedInt32Array()).is_empty(): continue
			echo = s.approach # спуск той же стороной, что подъём, — повтор
			echo_ready = true
		for style: String in STYLES:
			if stats.searches >= budget: break
			if (style == "traverse") != (pair.size() > 3): continue # пара траверса — только поиск траверса
			var spec: Dictionary = STYLES[style]
			var path := PackedInt32Array()
			if spec.via:
				var via := _via(w, hv, dist, s, t)
				if via < 0: continue
				var a := _search(finder, w, wood if spec.wood else cost, wood_version if spec.wood else cost_version, s.i, via, spec, stats)
				var b := _search(finder, w, wood if spec.wood else cost, wood_version if spec.wood else cost_version, via, t.i, spec, stats) if not a.is_empty() else a
				if not b.is_empty():
					path = _join(w, a, b)
			else:
				path = _search(finder, w, wood if spec.wood else cost, wood_version if spec.wood else cost_version, s.i, t.i, spec, stats)
			var tally: Array = stats.by_search.get(style, [0, 0, 0])
			stats.by_search[style] = tally
			tally[0] += 1
			if path.is_empty(): continue
			stats.found += 1
			tally[1] += 1
			var c := _score(w, hv, dist, path, style == "traverse")
			# 11.11.2026: и не идёт подряд вдоль готовой сети на той же высоте (параллельное полотно)
			if c.reason.is_empty() and StageTrails._parallel_stats(w, path, dist, net).y > StageTrails.PARALLEL_RUN:
				c.reason = "вдоль готовой сети"
			if c.reason.is_empty():
				if not echo_ready:
					echo_ready = true
					finder.window = Rect2i()
					finder.search_budget = SEARCH_BUDGET
					echo = finder.find_path(network, s.i, t.i, 0.0, INF, network_version)
				# траверс: копия пути сети — только ближе NEAR_R (40 м); дальше — другой уровень склона (это и проверяет доля новой земли)
				if _echo_share(w, path, echo, NEAR_R if style == "traverse" else ECHO_R) > ECHO_SHARE: c.reason = "повторяет путь сети"
			if not c.reason.is_empty():
				stats.rejected[c.reason] = int(stats.rejected.get(c.reason, 0)) + 1
				continue
			tally[2] += 1
			c.top = s
			c.search = style
			candidates.append(c)
	finder.window = Rect2i()
	finder.search_budget = -1
	stats.search_ms = (Time.get_ticks_usec() - started) / 1000.0 - stats.prepare_ms
	var forks := StageTrails.RoadForks.new(w, on_axis)
	forks.refresh(on_axis)
	for c: Dictionary in candidates:
		c.fork_rank = float(c.score) - 0.60 * forks.ride_pressure(c.path)
	# Сеть V2 (шаг 4, 21.11): точки примыкания маршрутов — по правилам узлов сети V2 (RoadNetworkV2.ride_nodes)
	if StageTrails.network_v2:
		StageTrails.RoadNetworkV2.ride_nodes(w, finder, surface, on_axis, candidates)
	var chosen := _select(w, candidates, stats, forks)
	var publish_us := Time.get_ticks_usec()
	var number := 0
	for c: Dictionary in chosen:
		var top: Dictionary = c.top
		if top.virtual and not top.has("published"):
			# Подъём к вершине — часть маршрута: публикуется как горная тропа перед первым спуском с неё
			top.published = "climb_%d" % number
			top.ascent_legs = []
			for k: int in StageTrails._add_trail(w, top.approach, "mountain", PackedFloat32Array(), on_axis, surface,
					"", null, Callable(), top.ascent_legs):
				w.trails[k].ride = top.published
				w.trails[k].ride_style = "climb"
			stats.climbs += 1
			stats.climb_km += StageTrails._length(w, top.approach) * GameConfig.TILE / 1000.0
		var path: PackedInt32Array = c.path
		var id := "ride_%d" % number
		var descent: Array = []
		# Маршрут — участки сети: где он идёт по готовому пути, новых записей нет (11.11.2026)
		for k: int in StageTrails._add_trail(w, path, "mountain" if STYLES[c.search].grade > StageTrails.TRAIL_GRADE else "trail",
				PackedFloat32Array(), on_axis, surface, "", null, Callable(), descent):
			var route: Dictionary = w.trails[k]
			route.ride = id
			route.ride_style = c.style
			if top.virtual: route.ride_climb = top.published
		var ascent: Array = top.get("ascent_legs", [])
		w.road_rides.routes[id] = {style = c.style, legs = ascent.duplicate(true) + descent, ascent_legs = ascent.size()}
		number += 1
		stats.km += c.length / 1000.0
		stats.styles[c.style] = int(stats.styles.get(c.style, 0)) + 1
		# Доля пути по лесу (в процентах) у каждого принятого маршрута по характеру — отчёт стенда
		var woods: Array = stats.wood.get(c.style, [])
		woods.append(roundi(c.wood * 100.0))
		stats.wood[c.style] = woods
		if c.top.mountain: stats.from_mountain += 1
	stats.publish_ms = (Time.get_ticks_usec() - publish_us) / 1000.0
	stats.accepted = chosen.size()
	stats.km = snappedf(stats.km, 0.01)
	stats.climb_km = snappedf(stats.climb_km, 0.01)
	stats.ms = (Time.get_ticks_usec() - started) / 1000.0


static func _net_mask(mask: PackedByteArray) -> PackedByteArray:
	var net := PackedByteArray()
	net.resize(mask.size())
	for i in mask.size():
		if mask[i] >= 2: net[i] = 1
	return net


## Стоимости маршрутов {cost, wood, block}: cost — местность, у сети (net, dist < NEAR_R) и реки дороже; wood — лесная
## линия (открытая земля дороже в OPEN_MUL); block — самая высокая клетка блока BLOCK×BLOCK положе TOP_SLOPE (-1 — нет).
## fast — FastGrid (копия RideCostFields, побайтно то же; сверка — tools/dod_verify.gd -- --only rides) или null
static func cost_fields(w: WorldData, hv: PackedFloat32Array, net: PackedByteArray, dist: PackedFloat32Array, fast: Object) -> Dictionary:
	var wooded := PackedByteArray()
	wooded.resize(Biomes.LIST.size())
	for b: int in WOODED: wooded[b] = 1
	if fast != null:
		return fast.RideCostFields(w.W, w.H, w.cost, net, dist, w.river_cells(), w.biome, wooded, w.slope, hv, BLOCK,
			NEAR_R, NEAR_MUL, RIVER_MUL, OPEN_MUL, TOP_SLOPE)
	var W := w.W
	var cost := PackedFloat32Array()
	cost.resize(w.N)
	var wood := PackedFloat32Array()
	wood.resize(w.N)
	var base := w.cost
	var biome := w.biome
	var slope := w.slope
	var river := w.river_cells()
	var bw := ceili(float(W) / BLOCK)
	var block := PackedInt32Array()
	block.resize(bw * ceili(float(w.H) / BLOCK))
	block.fill(-1)
	for i in w.N:
		var c: float = base[i]
		if c == INF:
			cost[i] = INF
			wood[i] = INF
			continue
		if net[i] != 0: c = maxf(c, 2.0) # протоптанная тропа 0,3 — как обычная земля
		if dist[i] < NEAR_R: c *= NEAR_MUL
		if river[i] != 0: c *= RIVER_MUL # реку — поперёк, коротким бродом, а не по руслу
		cost[i] = c
		wood[i] = c if wooded[biome[i]] != 0 else c * OPEN_MUL
		var b := (i / W / BLOCK) * bw + (i % W) / BLOCK
		if slope[i] < TOP_SLOPE and (block[b] < 0 or hv[i] > hv[block[b]]): block[b] = i
	return {cost = cost, wood = wood, block = block}


## Точки готовой сети примерно через ANCHOR_STEP клеток: {i, h (м), mountain — на горной тропе}. Не на сооружениях
static func _anchors(w: WorldData, hv: PackedFloat32Array, on_axis: PackedByteArray, cost: PackedFloat32Array) -> Array:
	var out: Array = []
	var seen := {}
	for t: Dictionary in w.trails:
		if t.kind == "animal" or t.has("ride"): continue
		var pts: Array = t.pts
		var run := ANCHOR_STEP # первая точка — конец пути (поселение, вершина горной тропы)
		for k in pts.size():
			if k > 0: run += Grid.hypot(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y)
			if run < ANCHOR_STEP and k != pts.size() - 1: continue
			var i := clampi(floori(pts[k].y), 0, w.H - 1) * w.W + clampi(floori(pts[k].x), 0, w.W - 1)
			if seen.has(i) or on_axis[i] != 0 or cost[i] == INF or StageTrails._wet(w, i): continue
			seen[i] = true
			run = 0.0
			out.append({i = i, x = i % w.W, y = i / w.W, h = hv[i], mountain = t.kind == "mountain", virtual = false})
	return out


## Виртуальные вершины вдали от сети: самая высокая клетка блока, выше восьми соседних блоков (вершина или плечо
## хребта), дальше VIRTUAL_GAP от сети, с точкой сети не дальше APPROACH_MAX для подъёма. Самые высокие над этой точкой —
## первыми, не больше VIRTUAL_TOPS на мир 512. from — откуда подъём.
static func _virtual_tops(w: WorldData, hv: PackedFloat32Array, dist: PackedFloat32Array, block: PackedInt32Array, bw: int, anchors: Array) -> Array:
	var out: Array = []
	var bh := block.size() / bw
	for by in bh:
		for bx in bw:
			var i := block[by * bw + bx]
			if i < 0 or dist[i] < VIRTUAL_GAP or StageTrails._wet(w, i): continue
			if i % w.W < BLOCK / 2 or i / w.W < BLOCK / 2 or i % w.W >= w.W - BLOCK / 2 or i / w.W >= w.H - BLOCK / 2: continue # край карты
			var top := true
			for ny in range(maxi(0, by - 1), mini(bh, by + 2)):
				for nx in range(maxi(0, bx - 1), mini(bw, bx + 2)):
					var j := block[ny * bw + nx]
					if j >= 0 and j != i and hv[j] >= hv[i]: top = false
			if not top: continue
			var x := i % w.W
			var y := i / w.W
			# Ближайшие точки сети ниже вершины: до трёх, если к первой не подняться (через воду, обрыв)
			var near: Array = []
			for a: Dictionary in anchors:
				var d := Grid.hypot(a.x - x, a.y - y)
				if d <= APPROACH_MAX and hv[i] - a.h >= DROP_MIN * 0.5: near.append([d, a])
			if near.is_empty(): continue
			near.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0] if p[0] != q[0] else p[1].i < q[1].i)
			var from := PackedInt32Array()
			for k in mini(3, near.size()): from.append(near[k][1].i)
			out.append({i = i, x = x, y = y, h = hv[i], mountain = false, virtual = true, from = from, rise = hv[i] - near[0][1].h})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.rise > b.rise if a.rise != b.rise else a.i < b.i)
	return out.slice(0, maxi(1, roundi(VIRTUAL_TOPS * w.scale)))


## Пары старт–финиш: старт — самая высокая опорная точка в радиусе TOP_R; финиши ниже на DROP_MIN в D_MIN..D_MAX,
## в разных направлениях, лучший — с наибольшим перепадом при посильном среднем уклоне. Сначала пары с большим перепадом.
static func _pairs(w: WorldData, anchors: Array, virtual: Array, stats: Dictionary) -> Array:
	var tops: Array = []
	for a: Dictionary in anchors:
		var top := true
		for b: Dictionary in anchors:
			if b.h > a.h or b.h == a.h and b.i < a.i:
				if absi(b.x - a.x) <= TOP_R and absi(b.y - a.y) <= TOP_R and Grid.hypot(b.x - a.x, b.y - a.y) <= TOP_R:
					top = false
					break
		if top: tops.append(a)
	stats.tops = tops.size()
	tops.append_array(virtual)
	var pairs: Array = []
	for s: Dictionary in tops:
		var ends: Array = []
		for t: Dictionary in anchors:
			var drop: float = s.h - t.h
			var d := Grid.hypot(t.x - s.x, t.y - s.y)
			if drop < DROP_MIN or d < D_MIN or d > D_MAX: continue
			var grade := drop / (d * GameConfig.TILE)
			if grade < 0.04 or grade > 0.45: continue # слишком полого — не спуск; круче — путь всё равно уйдёт в обход
			ends.append([t, drop, d])
		ends.sort_custom(func(p: Array, q: Array) -> bool: return p[1] > q[1] if p[1] != q[1] else p[0].i < q[0].i)
		var taken: Array = []
		for e: Array in ends:
			var t: Dictionary = e[0]
			var ok := true
			for o: Array in taken:
				var u: Dictionary = o[0]
				var cosine: float = ((t.x - s.x) * (u.x - s.x) + (t.y - s.y) * (u.y - s.y)) / maxf(e[2] * o[2], 1.0)
				if cosine > END_ANGLE: ok = false
			if not ok: continue
			taken.append(e)
			# Вершина горной тропы — готовый подъём к спуску: небольшой приоритет
			pairs.append([s, t, e[1] * (1.25 if s.mountain else 1.0)])
			if taken.size() >= ENDS_PER_TOP: break
	_traverse_pairs(w, anchors, pairs)
	pairs.sort_custom(func(p: Array, q: Array) -> bool: return p[2] > q[2] if p[2] != q[2] else p[0].i * 7 + p[1].i < q[0].i * 7 + q[1].i)
	stats.pairs = pairs.size()
	return pairs


## Пары траверса (четвёртый элемент — вершина): начало — опорная точка горной тропы, вершина w.peaks в TRAVERSE_R выше
## на TRAVERSE_RISE; конец — опорная точка сети той же высоты (±TRAVERSE_BAND), повёрнутая вокруг вершины на
## TRAVERSE_ANGLE и больше, на расстоянии длины траверса. Одна пара на вершину — с наименьшим поворотом; не больше TRAVERSE_PAIRS.
static func _traverse_pairs(w: WorldData, anchors: Array, pairs: Array) -> void:
	var added := 0
	var used := {}
	for s: Dictionary in anchors:
		if added >= roundi(TRAVERSE_PAIRS * w.scale): break
		if not s.mountain: continue
		var peak: Variant = null
		var pd := TRAVERSE_R
		for pk in w.peaks:
			var d := Grid.hypot(pk.x - s.x, pk.y - s.y)
			if d < pd and not used.has(pk.i):
				pd = d
				peak = pk
		if peak == null or pd < 6.0: continue
		var from := Vector2(s.x - peak.x, s.y - peak.y)
		var best: Dictionary = {}
		var best_angle := INF
		for t: Dictionary in anchors:
			if absf(t.h - s.h) > TRAVERSE_BAND or t.i == s.i: continue
			var to := Vector2(t.x - peak.x, t.y - peak.y)
			var d := Grid.hypot(t.x - s.x, t.y - s.y) * GameConfig.TILE
			if to.length() < 6.0 or d < TRAVERSE_LEN.x * 0.5 or d > TRAVERSE_LEN.y * 0.8: continue
			var angle := rad_to_deg(absf(from.angle_to(to)))
			if angle >= TRAVERSE_ANGLE and angle < best_angle:
				best_angle = angle
				best = t
		if best.is_empty(): continue
		# вершина выше начала (высота вершины — по самой высокой опорной точке, если в w.peaks её нет)
		var top_h: float = s.h
		for a: Dictionary in anchors:
			if Grid.hypot(a.x - peak.x, a.y - peak.y) < 8.0: top_h = maxf(top_h, a.h)
		if top_h - s.h < TRAVERSE_RISE: continue
		used[peak.i] = true
		pairs.append([s, best, TRAVERSE_PRIORITY, peak])
		added += 1


## Промежуточный ориентир: плечо склона в стороне от прямой старт–финиш — та из двух точек сбоку от середины, что выше,
## если её высота между стартом и финишем и она на новой земле. -1 — нет ориентира.
static func _via(w: WorldData, hv: PackedFloat32Array, dist: PackedFloat32Array, s: Dictionary, t: Dictionary) -> int:
	var mx: float = (s.x + t.x) * 0.5
	var my: float = (s.y + t.y) * 0.5
	var nx: float = -(t.y - s.y) * 0.3
	var ny: float = (t.x - s.x) * 0.3
	var best := -1
	for side: float in [-1.0, 1.0]:
		var x := clampi(roundi(mx + nx * side), 1, w.W - 2)
		var y := clampi(roundi(my + ny * side), 1, w.H - 2)
		var i := y * w.W + x
		if w.cost[i] == INF or dist[i] < NEAR_R or StageTrails._wet(w, i): continue
		var drop: float = s.h - t.h
		if hv[i] > s.h - drop * 0.15 or hv[i] < t.h + drop * 0.3: continue
		if best < 0 or hv[i] > hv[best]: best = i
	return best


static func _search(finder: Pathfinder, w: WorldData, cost: PackedFloat32Array, version: int, a: int, b: int, spec: Dictionary, stats: Dictionary) -> PackedInt32Array:
	stats.searches += 1
	var x0 := mini(a % w.W, b % w.W) - WINDOW_MARGIN
	var y0 := mini(a / w.W, b / w.W) - WINDOW_MARGIN
	var x1 := maxi(a % w.W, b % w.W) + WINDOW_MARGIN + 1
	var y1 := maxi(a / w.W, b / w.W) + WINDOW_MARGIN + 1
	finder.window = Rect2i(maxi(0, x0), maxi(0, y0), mini(w.W, x1) - maxi(0, x0), mini(w.H, y1) - maxi(0, y0))
	finder.search_budget = SEARCH_BUDGET
	return finder.find_path(cost, a, b, spec.climb, spec.grade, version)


## Две части через ориентир без «шипа»: срезаем возврат в общей клетке частей.
## Каждый оставшийся шаг уже проверен поиском; соседство клеток само по себе этого не доказывает.
static func _join(w: WorldData, a: PackedInt32Array, b: PackedInt32Array) -> PackedInt32Array:
	var tail := {}
	for j in range(maxi(0, a.size() - 40), a.size()):
		tail[a[j]] = j
	var cut_a := a.size() - 1
	var cut_b := 0
	for k in range(1, mini(b.size(), 40)):
		var c := b[k]
		var j: int = tail.get(c, -1)
		# Keep only already validated edges: splice at a shared vertex.
		if j >= 0 and j <= a.size() - 3 and (k > cut_b or k == cut_b and j < cut_a):
			cut_a = j
			cut_b = k
	var out := a.slice(0, cut_a + 1)
	if out[-1] != b[cut_b]: out.append(b[cut_b])
	out.append_array(b.slice(cut_b + 1))
	return StageTrails._no_backtrack(out)


## Доля точек пути (через три клетки) ближе ECHO_R к пути сети echo между теми же концами: спуск в паре десятков метров
## от горной тропы к той же дороге — её копия, а не новый маршрут. Путь сети далеко — другой склон, это годится.
static func _echo_share(w: WorldData, path: PackedInt32Array, echo: PackedInt32Array, r := ECHO_R) -> float:
	if echo.is_empty(): return 0.0
	var W := w.W
	var near := 0
	var total := 0
	for k in range(0, path.size(), 3):
		total += 1
		var px := path[k] % W
		var py := path[k] / W
		for m in range(0, echo.size(), 3):
			var dx := echo[m] % W - px
			var dy := echo[m] / W - py
			if dx * dx + dy * dy < r * r:
				near += 1
				break
	return float(near) / maxi(1, total)


## Оценка виртуальной линии: {path, length (м), drop, score, style, reason — пусто, если линия годна}
static func _score(w: WorldData, hv: PackedFloat32Array, dist: PackedFloat32Array, path: PackedInt32Array, traverse := false) -> Dictionary:
	var W := w.W
	var length := 0.0
	var climb := 0.0
	var fresh := 0
	var wooded := 0
	var wet_run := 0
	var ford := 0
	for k in path.size():
		var i := path[k]
		wet_run = wet_run + 1 if StageTrails._wet(w, i) else 0
		ford = maxi(ford, wet_run)
		if dist[i] >= NEAR_R: fresh += 1
		if w.biome[i] in WOODED: wooded += 1
		if k > 0:
			var j := path[k - 1]
			length += Grid.hypot(i % W - j % W, i / W - j / W) * GameConfig.TILE
	# Подъёмы на спуске — по сглаженным высотам (шаг ~5 клеток), чтобы не считать мелкие неровности
	var smooth := PackedFloat32Array()
	for k in range(0, path.size(), 5):
		smooth.append(hv[path[k]])
	smooth.append(hv[path[-1]])
	for k in range(1, smooth.size()):
		climb += maxf(0.0, smooth[k] - smooth[k - 1])
	var drop: float = hv[path[0]] - hv[path[-1]]
	var straight := Grid.hypot(path[0] % W - path[-1] % W, path[0] / W - path[-1] / W) * GameConfig.TILE
	var out := {path = path, length = length, drop = drop, climb = climb, score = 0.0, style = "", reason = ""}
	if traverse:
		# 17.11: траверс — по одной высоте; оценка: длина, доля новой земли и леса
		var off := 0.0
		for i: int in path: off = maxf(off, absf(hv[i] - hv[path[0]]))
		if ford > FORD_RUN: out.reason = "долгий брод"
		elif off > TRAVERSE_BAND + 10.0: out.reason = "траверс уходит с высоты"
		elif length < TRAVERSE_LEN.x or length > TRAVERSE_LEN.y: out.reason = "траверс не той длины"
		elif float(fresh) / path.size() < NEW_SHARE: out.reason = "вдоль готовой сети"
		if not out.reason.is_empty(): return out
		out.style = "traverse"
		out.wood = float(wooded) / path.size()
		out.score = MIN_SCORE + 0.6 * length / 1000.0 + WOOD_SCORE * out.wood
		return out
	if ford > FORD_RUN: out.reason = "долгий брод"
	elif drop < DROP_MIN: out.reason = "мал перепад"
	elif length < 300.0: out.reason = "короткий"
	elif climb > drop * 0.25 + 10.0: out.reason = "много подъёмов"
	elif float(fresh) / path.size() < NEW_SHARE: out.reason = "вдоль готовой сети"
	elif length > straight * 3.5: out.reason = "большой обход"
	if not out.reason.is_empty(): return out
	var grade := drop / length
	# Извилистость: смена направления больше ~30° на отрезках по 4 клетки, на километр
	var turns := 0
	var grades := PackedFloat32Array()
	var prev := Vector2.ZERO
	for k in range(4, path.size(), 4):
		var d := Vector2(path[k] % W - path[k - 4] % W, path[k] / W - path[k - 4] / W)
		if prev != Vector2.ZERO and d != Vector2.ZERO and absf(prev.angle_to(d)) > 0.52: turns += 1
		if d != Vector2.ZERO: prev = d
		grades.append((hv[path[k - 4]] - hv[path[k]]) / maxf(d.length() * GameConfig.TILE, 1.0))
	var mean := 0.0
	for g in grades: mean += g
	mean /= maxf(1.0, grades.size())
	var spread := 0.0
	for g in grades: spread += (g - mean) * (g - mean)
	spread = sqrt(spread / maxf(1.0, grades.size()))
	var turns_km := turns / (length / 1000.0)
	var wood_share := float(wooded) / path.size()
	# Характер по готовой линии: крутая — техническая, длинная пологая — плавный спуск, остальная в лесу — лесная
	out.style = "tech" if grade >= 0.14 else ("flow" if length >= 900.0 and grade < 0.11 or wood_share < 0.5 else "forest")
	out.wood = wood_share
	out.grade = grade
	out.turns_km = turns_km
	out.score = minf(drop, 300.0) / 100.0 + 0.6 * minf(length, 2500.0) / 1000.0 + 0.4 * minf(turns_km / 12.0, 1.0) \
		+ 0.4 * minf(spread / 0.08, 1.0) + WOOD_SCORE * wood_share - 2.0 * climb / drop
	return out


## Жадный отбор: лучший каждого характера, затем по оценке; не больше двух спусков с одного старта; без дубликатов
static func _select(w: WorldData, candidates: Array, stats: Dictionary, forks: RefCounted = null) -> Array:
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var first: float = a.get("fork_rank", a.score)
		var second: float = b.get("fork_rank", b.score)
		return first > second if first != second else a.path[0] * 7 + a.path[-1] < b.path[0] * 7 + b.path[-1])
	var near := PackedByteArray()
	near.resize(w.N)
	var chosen: Array = []
	var used := {}
	var per_top := {}
	var limit := maxi(1, roundi(MAX_RIDES * w.scale))
	var v2_chosen: Array = [] # точки примыкания принятых маршрутов (только сеть V2)
	# Prefer space between the chosen junctions both within each style and when
	# filling the remaining slots. Revisit the original candidates in each fallback.
	for pass_n in 4:
		var styles := {}
		for c: Dictionary in chosen: styles[c.style] = true
		for n in candidates.size():
			var c: Dictionary = candidates[n]
			if chosen.size() >= limit: break
			if c.score < MIN_SCORE or used.has(n) or int(per_top.get(c.top.i, 0)) >= 2: continue
			if pass_n < 2 and styles.has(c.style): continue
			var path: PackedInt32Array = c.path
			if forks != null and pass_n % 2 == 0 and forks.crowds_chosen(path): continue
			if c.has("v2_reject"):
				var why: String = c.v2_reject
				if why.is_empty() and not StageTrails.RoadNetworkV2.ride_nodes_spaced(w, c.v2_nodes, v2_chosen): why = "node_pair_rides"
				if not why.is_empty():
					if pass_n == 3: stats.rejected["узлы V2: " + why.get_slice(" ", 0)] = int(stats.rejected.get("узлы V2: " + why.get_slice(" ", 0), 0)) + 1
					continue
			var same := 0
			for i: int in path:
				if near[i] != 0: same += 1
			if float(same) / path.size() > SAME_SHARE:
				if pass_n == 3: stats.rejected["похож на принятый"] = int(stats.rejected.get("похож на принятый", 0)) + 1
				continue
			chosen.append(c)
			if c.has("v2_nodes"): v2_chosen.append(c.v2_nodes)
			used[n] = true
			styles[c.style] = true
			per_top[c.top.i] = int(per_top.get(c.top.i, 0)) + 1
			if forks != null: forks.reserve(path)
			for k in range(0, path.size(), 2): # путь непрерывный: через клетку хватает при радиусе SAME_R
				var i := path[k]
				var cx := i % w.W
				var cy := i / w.W
				for y in range(maxi(0, cy - SAME_R), mini(w.H, cy + SAME_R + 1)):
					for x in range(maxi(0, cx - SAME_R), mini(w.W, cx + SAME_R + 1)):
						near[y * w.W + x] = 1
	return chosen
