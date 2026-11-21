extends RefCounted
## Дорожная сеть V2 (docs/ROAD_NETWORK_V2_PLAN_2026_11_21.md): петли и ответвления после остова V1.
## Включается флагом StageTrails.network_v2 (по умолчанию выключен). Ядро — C# (Roads.Network, вход
## FastGrid.PlanNetworkV2 на экземпляре поиска этапа), публикация — общим конвейером StageTrails._add_trail + _note_way.
## Ошибка C# — push_error с текстом, без молчаливого отката на V1.

## Версия результата V2: входит в ключ слоя places только при включённом флаге (WorldCache._road_layer_suffixes).
const VERSION := 1

## Числа V2 (раздел 3 плана). Числа V1 берутся из StageTrails и RoadTuning в params(), здесь не повторяются.
const NODE_SEP := 25.0      # клеток (100 м) между узлами необязательных путей
const NODE_SAME := 0.6      # точки ближе — один узел
const MAX_DEGREE := 4
const LOOP_RATIO := 1.65    # кандидат петли: D_net / D_geo больше
const LOOP_ACCEPT := 1.25   # после петли отношение пары не больше
const LOOP_SHARE := 0.35    # петель не больше ceil(0,35 · N)
const LOOP_LEN_OLD := 2.0   # петля не длиннее двух старых путей
const FAR_R := 15.0         # клеток (60 м): петля отходит от старой связи дальше
const FAR_SHARE := 0.4      # хотя бы такой долей
const WINDOW_MARGIN := 14   # окно поиска вокруг грубого пути, клеток
const WINDOW_RETRY := 24
const RIDGE_TPI := 4.0      # м: Hσ − H3σ — хребет или отрог
const RIDGE_MUL := 0.82
const ECO_LOW := 0.25
const ECO_HIGH := 0.75
const ECO_MUL := 0.9
const MEANDER_AMP := 0.15
const SHORE_BAND := 3.0     # клеток у моря и озера
const SHORE_MUL := 1.5
const SHORE_SHARE := 0.25   # береговое ответвление: доля клеток у воды (без последних 4) не больше
const EXIT_ANGLE := 45.0    # петля: новый выезд своего поселения отличается от прежних выездов не меньше (градусы)
const EXIT_CHORD := 10.0    # клеток: хорда направления выезда (8–12)
const SPUR_NET_FLOOR := 2.0 # ответвление: клетка сети в окне не дешевле этого до множителя EXIT_MUL (как пол 2,0 в ride_routes.gd)
const MOUNTAIN_REACH := 1.5
const JOIN_SAME := 1.5
## Шаг 7: развилки природных маршрутов не ближе CROWD_R измерителя (10 клеток, 40 м) + 2 к другим развилкам
const RIDE_NODE_SEP := 12.0      # примыкание ближе этого (клеток) к развилке — в саму развилку (общий узел) # точка съезда горной тропы не дальше ближайшей точки сети × это + 8 клеток


## Подмена чисел V2 на время запуска стенда (road_plan_test -- --v2-param ключ=значение,…); в кэш игры не попадает.
static var overrides := {}
## Сессия ядра на этап путей: новый номер у петель (первый вызов V2 в этапе), ответвления и горные тропы — тот же.
## Ядро кэширует по нему неизменные поля и грубый граф (каждый кэш ещё и с ключом своих входов).
static var _session := -1
## Клетки небезопасных бродов этапа и оси, по которым они посчитаны: горные тропы берут их, если оси те же
static var _unsafe_cache := PackedByteArray()
static var _unsafe_axis := PackedByteArray()


## Суффикс ключа слоя places: пусто при выключенном флаге (ключ побайтно прежний).
static func cache_suffix(enabled: bool) -> String:
	return "|net=v2.%d" % VERSION if enabled else ""


## Числа во вход C#: V1 — из StageTrails и RoadTuning, V2 — константы выше.
static func params(w: WorldData) -> Dictionary:
	var tuning := RoadTuning.current()
	var routing := tuning.routing
	var turns: Dictionary = StageTrails.routing_overrides.get("turn_costs", routing.turn_costs)
	var bends: Dictionary = StageTrails.routing_overrides.get("bend_costs", routing.bend_costs)
	var relax: Dictionary = StageTrails.routing_overrides.get("line_relax", routing.line_relax)
	return {W = w.W, H = w.H, tile = GameConfig.TILE, height_scale = StageTrails.HEIGHT_SCALE,
		trail_grade = StageTrails.TRAIL_GRADE, mountain_grade = StageTrails.MOUNTAIN_GRADE, bench_cross = StageTrails.BENCH_CROSS,
		climb_trail = routing.climb_costs.trail, climb_mountain = routing.climb_costs.mountain,
		turn_trail = turns.trail, turn_mountain = turns.mountain, bend_trail = bends.trail, bend_mountain = bends.mountain,
		width_trail = tuning.section.widths.trail, width_mountain = tuning.section.widths.mountain,
		exit_r = StageTrails.EXIT_R, exit_mul = StageTrails.EXIT_MUL, avoid_cost = routing.avoid_cost, avoid_r = StageTrails.AVOID_R,
		human_reuse = routing.human_reuse, parallel_run = StageTrails.PARALLEL_RUN, node_cells = StageTrails.NODE_CELLS,
		ford_len = StageTrails.FORD_LEN, cross_run = StageTrails.CROSS_RUN, jitter_run = StageTrails.JITTER_RUN,
		rejoin_gap = StageTrails.REJOIN_GAP, parallel_share = StageTrails.PARALLEL_SHARE, near_net = StageTrails.NEAR_NET,
		level_gap = StageTrails.LEVEL_GAP, node_sep = NODE_SEP, node_same = NODE_SAME, max_degree = MAX_DEGREE,
		loop_ratio = LOOP_RATIO, loop_accept = LOOP_ACCEPT, loop_share = LOOP_SHARE, loop_len_old = LOOP_LEN_OLD,
		far_r = FAR_R, far_share = FAR_SHARE, window_margin = WINDOW_MARGIN, window_retry = WINDOW_RETRY,
		ridge_tpi = RIDGE_TPI, ridge_mul = RIDGE_MUL, eco_low = ECO_LOW, eco_high = ECO_HIGH, eco_mul = ECO_MUL,
		meander_amp = MEANDER_AMP, meander_flat = 0.06, meander_slope = 0.01, shore_band = SHORE_BAND, shore_mul = SHORE_MUL,
		branch_len = StageTrails.BRANCH_LEN, shore_gap = StageTrails.SHORE_GAP, view_gap = StageTrails.VIEW_GAP,
		shore_reach = StageTrails.SHORE_MAX, view_reach = StageTrails.VIEW_MAX, shore_share = SHORE_SHARE,
		mountain_detour = StageTrails.MOUNTAIN_DETOUR, mountain_reach = MOUNTAIN_REACH,
		exit_angle = EXIT_ANGLE, exit_chord = EXIT_CHORD, spur_net_floor = SPUR_NET_FLOOR, ride_node_sep = RIDE_NODE_SEP,
		profile_base = StageTrails.RoadLine.PROFILE_BASE, line_relax = relax.trail, reach = RoadRefinement.REACH}.merged(overrides, true)


## Вход C#: поля мира (ссылки на массивы), оси путей людей, поселения. unsafe — клетки небезопасных бродов
## (StageTrails._unsafe_fords), on_axis — оси мостов и туннелей.
static func input(w: WorldData, finder: Pathfinder, surface: Heightfield, on_axis: PackedByteArray, unsafe: PackedByteArray) -> Dictionary:
	var d := params(w)
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var starts := PackedInt32Array()
	for t: Dictionary in w.trails:
		if t.kind == "animal": continue
		starts.append(xs.size())
		for p: Dictionary in t.pts:
			xs.append(p.x)
			ys.append(p.y)
	starts.append(xs.size())
	var settle := PackedInt32Array()
	var remote := PackedByteArray()
	for s: SettlementData in w.settlements:
		settle.append(s.i)
		remote.append(1 if StageTrails._single_access(s) else 0)
	var forest := PackedInt32Array([Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE])
	d.merge({cost = w.cost, heights = finder.heights, links = finder.links if finder.links.size() == w.N else PackedByteArray(),
		hv = surface.hv, h = w.h, ocean = w.ocean, lake = w.lake, river = w.river_cells(), biome = w.biome,
		unsafe = unsafe, on_axis = on_axis, noise = w.noise_field("cost"), forest_biomes = forest,
		owner = w.generation.road_owner, mask = w.path_mask, sections = w.trails.size(),
		sec_x = xs, sec_y = ys, sec_start = starts, settle = settle, remote = remote})
	return d


## Вызов ядра на экземпляре поиска этапа; ошибка — push_error и пустой словарь.
static func call_core(finder: Pathfinder, surface: Heightfield, data: Dictionary) -> Dictionary:
	var core: Object = finder.fast()
	var water: Object = surface.fast_water()
	if core == null or water == null:
		push_error("Сеть V2: нужен C# (Grid.native_grid) и земля с водой на C# (Heightfield.fast_water)")
		return {}
	var out: Dictionary = core.PlanNetworkV2(data, water)
	if out.has("error"):
		push_error("Сеть V2: " + String(out.error))
		return {}
	return out


## Клетки небезопасных бродов (правило V1 StageTrails._unsafe_ford) одним массивом W·H.
static func unsafe_mask(w: WorldData, surface: Heightfield, on_axis: PackedByteArray) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(w.N)
	for i: int in StageTrails._unsafe_fords(w, surface, on_axis): mask[i] = 1
	return mask


## Профиль: блок generation_profile.network_v2[часть] = вывод C# + время адаптера и публикации.
static func _profile(w: WorldData, part: String, out: Dictionary, publish_ms: float, total_ms: float, prep := {}) -> void:
	var block: Dictionary = w.generation_profile.get("network_v2", {})
	var entry: Dictionary = out.get("network_v2", {}).duplicate(true)
	entry.prepare_ms = prep
	entry.publish_ms = snappedf(publish_ms, 0.001)
	entry.total_ms = snappedf(total_ms, 0.001)
	entry.accepted = (out.get("paths", []) as Array).size()
	block[part] = entry
	w.generation_profile.network_v2 = block


## Петли (план V2, 3.5) вместо сокращений и обходов V1. Публикация в порядке принятия: _add_trail + _note_way,
## пары дописываются в paths (не основные связи), как у V1.
static func plan_loops(w: WorldData, finder: Pathfinder, paths: Array, road_cost: PackedFloat32Array, state: Dictionary) -> void:
	var started := Time.get_ticks_usec()
	var surface: Heightfield = state.get("surface")
	var unsafe := unsafe_mask(w, surface, state.on_axis)
	state.v2_unsafe = unsafe # те же оси и поверхность у ответвлений этого этапа
	_unsafe_cache = unsafe
	_unsafe_axis = state.on_axis.duplicate()
	_session = Time.get_ticks_usec()
	var prep := {unsafe = (Time.get_ticks_usec() - started) / 1000.0}
	var t0 := Time.get_ticks_usec()
	var data := input(w, finder, surface, state.on_axis, unsafe)
	prep.input = (Time.get_ticks_usec() - t0) / 1000.0
	data.mode = "loops"
	data.session = _session
	var pairs := PackedInt32Array()
	for e: Array in StageTrails._gabriel_pairs(w, paths):
		pairs.append(e[0])
		pairs.append(e[1])
	data.pairs = pairs
	var out := call_core(finder, surface, data)
	if out.is_empty(): return
	var publish := Time.get_ticks_usec()
	for k in out.paths.size():
		var cells: PackedInt32Array = out.paths[k]
		var pair: Array = out.pairs[k]
		StageTrails._note_way(w, out.what[k], _publish(w, out, cells, "trail", road_cost, state.on_axis, surface))
		paths.append([pair[0], pair[1], cells, false, Grid.hypot(w.settlements[pair[0]].x - w.settlements[pair[1]].x,
			w.settlements[pair[0]].y - w.settlements[pair[1]].y)])
	_profile(w, "loops", out, (Time.get_ticks_usec() - publish) / 1000.0, (Time.get_ticks_usec() - started) / 1000.0, prep)


## Цели ответвлений правилами V1: берег (_shore от точек перегонов), смотровые (_overlook), вершины без тропы.
## Коридор прежних путей, расстояние до воды, берег и смотровые — StageTrails._corridor, _water_dist, _shore, _overlook
## (порты на C#: CorridorMask, WaterDistance, ShoreTargets, Overlooks; сверка — road_v2_test). Береговые цели расставлены через
## SHORE_GAP, как в V1 (и неудачная попытка занимает место); их не больше 3 × предел троп к берегу.
## Возвращает {targets, kinds, anchors, peaks_keep}.
static func spur_targets(w: WorldData, finder: Pathfinder, paths: Array, mountain: bool, max_shores: int, times := {}) -> Dictionary:
	var targets := PackedInt32Array()
	var kinds := PackedInt32Array()
	var anchors := PackedInt32Array()
	var keep := PackedInt32Array()
	for pk in w.peaks:
		if w.path_mask[pk.i] < 2: keep.append(pk.i)
	if mountain:
		for i: int in keep:
			targets.append(i)
			kinds.append(2)
			anchors.append(-1)
		return {targets = targets, kinds = kinds, anchors = anchors, peaks_keep = keep}
	var t0 := Time.get_ticks_usec()
	var cells := PackedInt32Array()
	for e: Array in paths: cells.append_array(e[2])
	var corr: PackedByteArray = finder.fast().CorridorMask(w.W, w.H, cells, StageTrails.AVOID_R)
	var settle_d := StageTrails._settle_dist(w)
	var water_d: PackedFloat32Array = finder.fast().WaterDistance(w.W, w.H, w.ocean, w.lake)
	times.fields = (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var spaced: Array[Vector2i] = []
	var shore_anchors := StageTrails._shore_anchors(w, paths, settle_d, water_d)
	var shore_found: PackedInt32Array = finder.fast().ShoreTargets(w.W, w.H, shore_anchors, corr, w.cost, water_d,
		StageTrails.SHORE_MIN, StageTrails.SHORE_MAX)
	for k in shore_anchors.size():
		if spaced.size() >= 3 * max_shores: break
		var t := shore_found[k]
		if t < 0: continue
		var tv := Vector2i(t % w.W, t / w.W)
		var free := true
		for o: Vector2i in spaced:
			if (o - tv).length_squared() < StageTrails.SHORE_GAP * StageTrails.SHORE_GAP: free = false
		if not free: continue
		spaced.append(tv)
		targets.append(t)
		kinds.append(0)
		anchors.append(shore_anchors[k])
	times.shore = (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var view_anchors := StageTrails._shore_anchors(w, paths, settle_d, PackedFloat32Array())
	var view_found: PackedInt32Array = finder.fast().Overlooks(w.W, w.H, view_anchors, corr, w.cost, w.h, w.ocean, w.lake,
		StageTrails.VIEW_RISE / (StageTrails.HEIGHT_SCALE * GameConfig.TILE), StageTrails.VIEW_MIN, StageTrails.VIEW_MAX, StageTrails.VIEW_STEP)
	for k in view_anchors.size():
		var t := view_found[k]
		if t < 0: continue
		targets.append(t)
		kinds.append(1)
		anchors.append(view_anchors[k])
	times.view = (Time.get_ticks_usec() - t0) / 1000.0
	return {targets = targets, kinds = kinds, anchors = anchors, peaks_keep = keep}


## Ответвления (план V2, 3.6): mountain = false — берег и смотровые (коридор троп, вместо веток _second_ways),
## true — горные тропы (коридор горных троп, вместо _mountain_trails). on_axis — оси сооружений.
static func plan_spurs(w: WorldData, finder: Pathfinder, paths: Array, road_cost: PackedFloat32Array, on_axis: PackedByteArray,
		surface: Heightfield, mountain: bool, known_unsafe := PackedByteArray()) -> void:
	var started := Time.get_ticks_usec()
	if known_unsafe.size() != w.N and _unsafe_cache.size() == w.N and _unsafe_axis == on_axis:
		known_unsafe = _unsafe_cache
	var unsafe := known_unsafe if known_unsafe.size() == w.N else unsafe_mask(w, surface, on_axis)
	var prep := {unsafe = (Time.get_ticks_usec() - started) / 1000.0}
	var t0 := Time.get_ticks_usec()
	var data := input(w, finder, surface, on_axis, unsafe)
	prep.input = (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var max_shores := maxi(2, w.settlements.size() / 4)
	var goals := spur_targets(w, finder, paths, mountain, max_shores, prep)
	prep.targets = (Time.get_ticks_usec() - t0) / 1000.0
	data.mode = "spurs"
	if _session < 0: _session = Time.get_ticks_usec()
	data.session = _session
	data.mountain = mountain
	data.targets = goals.targets
	data.target_kinds = goals.kinds
	data.anchors = goals.anchors
	data.peaks_keep = goals.peaks_keep
	data.max_shores = max_shores
	data.max_views = w.settlements.size()
	var out := call_core(finder, surface, data)
	if out.is_empty(): return
	var publish := Time.get_ticks_usec()
	for k in out.paths.size():
		var cells: PackedInt32Array = out.paths[k]
		var what: String = out.what[k]
		if what == "mountain":
			StageTrails._note_way(w, what, _publish(w, out, cells, "mountain", PackedFloat32Array(), on_axis, surface))
		else:
			StageTrails._note_way(w, what, _publish(w, out, cells, "trail", road_cost, on_axis, surface))
	_profile(w, "mountain" if mountain else "spurs", out, (Time.get_ticks_usec() - publish) / 1000.0, (Time.get_ticks_usec() - started) / 1000.0, prep)


## Шаг 4 (21.11): точки примыкания природных маршрутов по тем же правилам узлов (NodeSep, MaxDegree, ExitR).
## Для каждого кандидата RideRoutes: c.v2_reject — причина по готовой сети (пусто — годится), c.v2_nodes — клетки точек
## примыкания. Только при StageTrails.network_v2.
static func ride_nodes(w: WorldData, finder: Pathfinder, surface: Heightfield, on_axis: PackedByteArray, candidates: Array) -> void:
	var started := Time.get_ticks_usec()
	var known := _unsafe_cache if _unsafe_cache.size() == w.N and _unsafe_axis == on_axis else unsafe_mask(w, surface, on_axis)
	var data := input(w, finder, surface, on_axis, known)
	data.mode = "nodes"
	data.session = _session
	var paths: Array = []
	for c: Dictionary in candidates: paths.append(c.path)
	data.paths = paths
	# шаг 9: подъёмы к виртуальным вершинам (по одному на вершину)
	var tops: Array = []
	var approaches: Array = []
	for c: Dictionary in candidates:
		var top: Dictionary = c.top
		if top.virtual and not tops.has(top) and not top.get("approach", PackedInt32Array()).is_empty():
			tops.append(top)
			approaches.append(top.approach)
	data.approaches = approaches
	var out := call_core(finder, surface, data)
	if out.is_empty(): return
	for k in candidates.size():
		var c: Dictionary = candidates[k]
		c.v2_reject = String(out.verdicts[k])
		c.v2_nodes = PackedInt32Array(out.nodes[k])
		var t := tops.find(c.top)
		if t < 0: continue
		var why := String(out.approach_verdicts[t])
		if why.is_empty() and _touches_approach(w, c.path, c.top.approach): why = "spur_touch спуск касается подъёма"
		if c.v2_reject.is_empty() and not why.is_empty(): c.v2_reject = "approach_" + why
		var both: PackedInt32Array = c.v2_nodes.duplicate()
		both.append_array(PackedInt32Array(out.approach_nodes[t]))
		c.v2_nodes = both
	_profile(w, "rides", out, 0.0, (Time.get_ticks_usec() - started) / 1000.0, {})


## Шаг 9: спуск path касается или пересекает свой подъём approach где-то кроме общей вершины (начала спуска):
## клетка спуска на подъёме или рядом с ним (8 соседей) вне первой такой серии от вершины.
static func _touches_approach(w: WorldData, path: PackedInt32Array, approach: PackedInt32Array) -> bool:
	var near := {}
	for c: int in approach:
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				near[c + dy * w.W + dx] = true
	var k := 0
	while k < path.size() and near.has(path[k]): k += 1 # общая вершина и спуск вдоль самого подъёма у неё
	for j in range(k, path.size()):
		if near.has(path[j]): return true
	return false


## Точки примыкания маршрута nodes не ближе RIDE_NODE_SEP к точкам уже принятых маршрутов (совпадающие — общий узел).
static func ride_nodes_spaced(w: WorldData, nodes: PackedInt32Array, chosen: Array) -> bool:
	for other: PackedInt32Array in chosen:
		for a: int in nodes:
			for b: int in other:
				var d := Vector2(a % w.W - b % w.W, a / w.W - b / w.W).length()
				if d > 1.5 and d < RIDE_NODE_SEP: return false
	return true


## Развилки сети для StageTrails._join_point на время публикации путей V2: развилки графа ядра (концы участков на оси
## другого участка, точки примыкания принятых путей), по ячейкам. Точка, не лежащая на оси хозяина, при публикации не
## используется (StageTrails._v2_junction).
static func junctions(out: Dictionary) -> Dictionary:
	var result := {}
	var flat: PackedFloat64Array = out.get("junctions", PackedFloat64Array())
	for k in range(0, flat.size() - 1, 2):
		var p := Vector2(flat[k], flat[k + 1])
		var list: Array = result.get_or_add(Vector2i(floori(p.x), floori(p.y)), [])
		list.append(p)
	return result


## Публикация пути V2 общим конвейером с общими узлами у развилок (StageTrails.v2_junctions на время вызова).
static func _publish(w: WorldData, out: Dictionary, cells: PackedInt32Array, kind: String, road_cost: PackedFloat32Array,
		on_axis: PackedByteArray, surface: Heightfield) -> Array:
	if not out.has("_junction_cells"): out._junction_cells = junctions(out)
	StageTrails.v2_junctions = out._junction_cells
	var added := StageTrails._add_trail(w, cells, kind, road_cost, on_axis, surface)
	StageTrails.v2_junctions = {}
	return added


## Шаг 7: опорные точки природных маршрутов (RideRoutes._anchors) без точек в кольце 0,6 < до развилки < RIDE_NODE_SEP:
## отбор идёт по точкам, годным для узла (у самой развилки — общий узел). Подъёмы к виртуальным вершинам начинаются
## от тех же опорных точек.
static func ride_anchors(w: WorldData, finder: Pathfinder, surface: Heightfield, on_axis: PackedByteArray, anchors: Array) -> Array:
	var known := _unsafe_cache if _unsafe_cache.size() == w.N and _unsafe_axis == on_axis else unsafe_mask(w, surface, on_axis)
	var data := input(w, finder, surface, on_axis, known)
	data.mode = "node_dist"
	data.session = _session
	var out := call_core(finder, surface, data)
	if out.is_empty(): return anchors
	var dist: PackedFloat32Array = out.node_dist
	return anchors.filter(func(a: Dictionary) -> bool: return dist[a.i] <= NODE_SAME or dist[a.i] >= RIDE_NODE_SEP)


## Фаза 3.1: линия пути на C# (LineBuilder, порт RoadLine.build один к одному) для всех путей при network_v2.
## Вход и правила — те же, что у RoadLine.build (поблажка, срезание лесенки, скорость и ускорение поворота вида);
## счётчики отказов поблажки — те же (RoadLine.fallbacks, generation_profile.road_line_grade_fallbacks).
## Коридор областей (Callable) — только GDScript: вызывающий проверяет его сам.
static func line(w: WorldData, pts: Array, on_axis: PackedByteArray, surface: Heightfield, kind := "road", joins := {},
		smooth_kind := "") -> Array:
	var water: Object = surface.fast_water()
	if water == null:
		push_error("Сеть V2: линия на C# требует земли и воды на C# (Heightfield.fast_water)")
		return StageTrails.RoadLine.build(w, pts, on_axis, surface, kind, joins, Callable(), smooth_kind)
	var routing := RoadTuning.current().routing
	var design := kind if smooth_kind.is_empty() else smooth_kind
	var relaxation: Dictionary = StageTrails.routing_overrides.get("line_relax", routing.line_relax)
	var straightening: Dictionary = StageTrails.routing_overrides.get("straighten", routing.straighten)
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var ws := PackedFloat64Array()
	for p: Dictionary in pts:
		xs.append(p.x)
		ys.append(p.y)
		ws.append(p.w)
	var data := {x = xs, y = ys, w = ws, axis = on_axis, W = w.W, H = w.H, kind = kind, smooth = smooth_kind,
		relax = float(relaxation.get(design, 0.0)), tolerance = float(straightening.get(design, 0.0)),
		road_limit = StageTrails.ROAD_LIMIT, trail_grade = StageTrails.TRAIL_GRADE, mountain_grade = StageTrails.MOUNTAIN_GRADE,
		bench_cross = StageTrails.BENCH_CROSS, speed = StageTrails.RoadLine.TURN_SPEED[design], accel = StageTrails.RoadLine.TURN_ACCEL[design],
		smooth_line = smooth_lines and design != "road", biharmonic = smooth_biharmonic, profile_base = StageTrails.RoadLine.PROFILE_BASE}
	for end in 2:
		var join: Dictionary = joins.get(end, {})
		if not join.is_empty(): data["join%d" % end] = PackedFloat64Array([join.tangent.x, join.tangent.y])
	var core: Object = _line_core if _line_core != null else Grid.native_grid()
	_line_core = core
	var out: Dictionary = core.BuildRoadLine(data, water)
	if out.has("error"):
		push_error("Сеть V2: " + String(out.error))
		return StageTrails.RoadLine.build(w, pts, on_axis, surface, kind, joins, Callable(), smooth_kind)
	if not (out.smooth as Dictionary).is_empty():
		var block: Dictionary = w.generation_profile.get_or_add("network_v2", {})
		var smooth: Dictionary = block.get_or_add("smooth", {lines = 0, moved = 0, rejected = 0, hairpins = 0, hairpins_moved = 0})
		smooth.lines += 1
		for key: String in ["moved", "rejected", "hairpins", "hairpins_moved"]: smooth[key] += int(out.smooth[key])
	if out.fallback:
		StageTrails.RoadLine.fallbacks += 1
		var decisions: Dictionary = w.generation_profile.get_or_add("road_line_grade_fallbacks", {})
		decisions[kind] = int(decisions.get(kind, 0)) + 1
	var result: Array = []
	var ox: PackedFloat64Array = out.x
	var oy: PackedFloat64Array = out.y
	var ow: PackedFloat64Array = out.w
	for k in ox.size(): result.append({x = ox[k], y = oy[k], w = ow[k]})
	return result


static var _line_core: Object = null
## Фаза 3.2: монотонное сглаживание линий троп и горных троп (дорог road — нет). false — линия ровно как RoadLine.build.
static var smooth_lines := true
## Фаза 3.3: к сглаживанию — член Δ⁴ (меньше изломов на хордах 4 м)
static var smooth_biharmonic := true
