extends RefCounted
## One survey of a prepared world; one local preparation and final check per candidate.
## Accepted patches ARE the game surface. No synthetic world, repair loop or second bake.
const Search := preload("res://scripts/trails/trail_site_search.gd")
const Layout := preload("res://scripts/trails/trail_layout.gd")
const Validation := preload("res://scripts/trails/trail_validation.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const Potential := preload("res://scripts/trails/trail_potential.gd")
const MARGIN := 12
const EARTHWORKS := {max_cut = 8.0, max_fill = 6.0, modification = 1.0}
const DESIGN_DEPTH := 4.0     # уровень полотна не дальше этого от земли, м: с виражами, откосами и элементами это в пределах EARTHWORKS
const RouteContract := preload("res://scripts/trails/trail_route_contract.gd")
## Коридоры сети: извилистые линии через весь мир, в обе стороны от начальной клетки, с разворотами.
const CORRIDOR := {box = 3072.0, two_way = true, pad = 0, steps = 160, edge = 80.0}
const CROSSABLE: Array[String] = ["animal"]
const PROBES := 64            # проб обзора
## Границы сети — работа, а не время: сборка стоит примерно пропорционально метрам линии.
const LENGTH_TARGET := 12000.0 # суммарной длины достаточно, м
const WORK_LIMIT := 18000.0   # всего собранных метров, с отказами и повторами
const LEG := 700.0            # участок маршрута вдоль коридора, м
const LEG_PAD := 24           # запас рабочей области участка вокруг коридора, клеток: ходку есть где вилять
const LEG_LEAD := 24.0        # начало участка продолжает курс прошлого, м
const LEG_CLEAR := 20.0       # у стыков участков нет элементов: там рельеф держится как у пересечения путей, м
const LEG_SKIP := 160.0       # шаг вперёд по коридору, когда место не проходится, м
const MIN_LEG := 80.0         # участок короче не нужен, м
const MIN_LINE := 200.0       # линия парка короче не нужна, м
const TRIM := 30.0            # запас от плохого места при обрезке линии, м
const WORK_EDGE := 12.0       # линия не ближе к краю рабочей зоны участка (TrailSite.inside_errors), м
const ADMIT_PASSES := 3
const END_MARGIN := 60.0       # последний участок маршрута кончается не ближе этого к концу коридора, м
const PARK_LINES := 3         # столько самых длинных линий трейл-парка
const PARK_MIN := 250.0       # короче линия парка не нужна, м
const PARK_END := 14.0        # концы линии парка отступают от родительской, м
const DIFFICULTY := [0.25, 0.4, 0.55]
const MODIFICATION := {flow = 0.7, park = 0.7, downhill = 0.6, enduro = 0.5, tech = 0.4}
static var surveys := 0

static func build(w: WorldData, h: Heightfield, area: Rect2i, options := {}) -> Dictionary:
	var started := Time.get_ticks_msec()
	var input = GI.from_world(w, h, CROSSABLE)
	# Запрет только там, где пройти нельзя: глубокая вода, дома, сооружения. Дороги и тропы пересекаются в одном уровне,
	# мелкие русла — бродом, как у дорог (StageTrails._unsafe_fords, GameConfig.FORD_DEPTH).
	input.paths_soft = true
	var fords: PackedByteArray = input.rivers
	input.rivers = _deep_rivers(w, h, fords)
	var input_ms := Time.get_ticks_msec() - started
	input.earthwork_limits = EARTHWORKS.duplicate()
	var budget := int(options.get("probe_budget", PROBES))
	var search := Search.new({size = w.W, seed = w.seed_num, heights = input.heights, water = input.water, input = input},
		{area = area.grow(-MARGIN), probe_budget = budget, corridor = CORRIDOR, rideable = true})
	surveys += 1
	var corridors := search.find(w.seed_num)
	# Первыми места, которые лучше всего подходят какому-то виду катания (спуск, неровность, вид), и среди них длинные.
	# Границы работы — метры и числа, не время: секундомер только для диагностики и не выбирает канонический мир.
	for c: Dictionary in corridors:
		c.probe.points = _downhill(input, c.probe.points)
		c.potential = Potential.assess(input, c.probe.points)
		c.rank = Potential.rank(c.potential, float(c.probe.length))
	corridors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.rank) > float(b.rank) if a.rank != b.rank else a.trail_seed < b.trail_seed)
	var plan := {mode = "terrain_network", state = "none", reason = "нет принятых трасс", routes = [], entries = [],
		area = area, stats = {survey = search.stats, input_ms = input_ms, phases_ms = {}, attempted = 0, accepted = 0, rejected = {}, work_m = 0.0, length_m = 0.0, legs = 0, corridors = [], routes_m = []}}
	var ctx := {w = w, h = h, input = input, fords = fords, plan = plan, area = area.grow(-MARGIN - 1), length_target = float(options.get("length_target", LENGTH_TARGET)), work_limit = float(options.get("work_limit", WORK_LIMIT)), early_audit = options.get("early_audit", true), early_pruning = options.get("early_pruning", true), progress = options.get("on_progress", Callable()), styles = {}}
	var park_started := Time.get_ticks_msec()
	var park: Array[Dictionary] = []
	if budget > 0: park = _park_candidates(w, h, ctx.area)
	plan.stats.park = {ms = Time.get_ticks_msec() - park_started, lines = park.size()}
	for candidate: Dictionary in park:
		plan.stats.attempted += 1
		_leg(ctx, candidate.points, candidate.region, "park", candidate.title, candidate.trail_seed, DIFFICULTY[plan.stats.accepted % DIFFICULTY.size()], false)
	var route_index := 0
	for corridor: Dictionary in corridors:
		if plan.stats.length_m >= ctx.length_target or plan.stats.work_m >= ctx.work_limit: break
		plan.stats.attempted += 1
		plan.stats.corridors.append(roundi(corridor.probe.length))
		route_index = _route(ctx, corridor.probe.points, corridor.trail_seed, route_index)
	if not plan.routes.is_empty():
		RoadSurface.rebuild_map(w)
		plan.state = "found"
		plan.reason = ""
		plan.definition = plan.routes[0]
	plan.stats.budget_exhausted = search.stats.budget_exhausted or plan.stats.attempted < corridors.size() + park.size()
	for style: String in ctx.styles: ctx.styles[style] = roundi(ctx.styles[style])
	plan.stats.styles = ctx.styles
	plan.stats.total_ms = Time.get_ticks_msec() - started
	return plan

## Маршрут вдоль общего коридора: участок за участком. Принятый участок остаётся в мире, следующий начинается с его конца
## и его курсом; рельеф на стыке держится как у пересечения путей. Плохое место стоит только последнего участка: от него
## остаётся годное начало. Участок совсем не вышел — другая попытка, затем пропуск места и новый маршрут дальше по коридору.
## Цена растёт с длиной, а не с квадратом отказов. Возвращает номер последнего маршрута.
static func _route(ctx: Dictionary, corridor: PackedVector2Array, seed_value: int, route_index: int) -> int:
	var plan: Dictionary = ctx.plan
	var guide := TrailDefinition.new()
	guide.points = _downhill(ctx.input, corridor)
	corridor = guide.points
	var total := guide.route_length()
	ctx.peak = _peak(ctx.input, corridor)
	var cursor := 0.0
	var start := corridor[0]
	var tangent := Vector2.ZERO
	var fails := 0
	var leg_index := 0
	var route_length := 0.0
	ctx.start_speed = 3.0
	route_index += 1
	var title := "Маршрут %d" % route_index
	var difficulty: float = DIFFICULTY[route_index % DIFFICULTY.size()]
	while cursor < total - MIN_LEG and plan.stats.work_m < ctx.work_limit and plan.stats.length_m < ctx.length_target:
		var hint := PackedVector2Array([start])
		if tangent != Vector2.ZERO: hint.append(start + tangent * LEG_LEAD)
		var s := cursor + LEG_LEAD
		# Коридор кончается там, где что-то мешает (вода, край области, круча): последний участок цели не берёт самый конец,
		# а кончается раньше, где есть выкат.
		var reach := total - END_MARGIN if total - cursor > MIN_LEG + END_MARGIN else total
		var last := minf(reach, cursor + LEG)
		while s < last:
			hint.append(guide.point_at(s))
			s += 16.0
		hint.append(guide.point_at(last))
		var box := Rect2(hint[0], Vector2.ZERO)
		for p in hint: box = box.expand(p)
		var lo := Vector2i((box.position / GameConfig.TILE).floor()) - Vector2i.ONE * LEG_PAD
		var hi := Vector2i((box.end / GameConfig.TILE).ceil()) + Vector2i.ONE * LEG_PAD
		# Вид участка — по тому, что даёт его местность; вида, которого в сети уже много, берётся реже.
		ctx.arc = Vector2(cursor / total, 1.0 if last >= reach else last / total) # доля маршрута, которую займёт участок: замысел один на весь маршрут
		var style := Potential.choose(ctx.input, hint, ctx.styles)
		if style.is_empty(): style = Layout.ORDER[(route_index + leg_index) % Layout.ORDER.size()]
		var global := _leg(ctx, hint, Rect2i(lo, hi - lo), style, title, seed_value + leg_index * 7 + fails * 131, difficulty, true)
		if global == null:
			fails += 1
			if fails < 2: continue
			# Место не проходится: пропустить его; если до него уже есть маршрут, дальше идёт новый.
			fails = 0
			cursor += LEG_SKIP
			if cursor >= total: break
			start = guide.point_at(cursor)
			tangent = Vector2.ZERO
			ctx.start_speed = 3.0
			if route_length > 0.0:
				plan.stats.routes_m.append(roundi(route_length))
				route_length = 0.0
				route_index += 1
				title = "Маршрут %d" % route_index
				difficulty = DIFFICULTY[route_index % DIFFICULTY.size()]
			continue
		fails = 0
		leg_index += 1
		route_length += global.route_length()
		var end: Vector2 = global.points[-1]
		start = end
		tangent = (global.points[-1] - global.points[-2]).normalized()
		# Вперёд по коридору на столько, сколько участок прошёл вдоль своей части.
		cursor += maxf(MIN_LEG, RouteContract.project(hint, end).x)
	if route_length > 0.0: plan.stats.routes_m.append(roundi(route_length))
	return route_index

## Место пика маршрута (доля длины): середина 150 м с самым большим спуском вдоль коридора, не раньше трети и не позже
## 85 %. Начало маршрута разгоняет, после пика он идёт на спад. Коридор уже идёт вниз.
static func _peak(input: GI, corridor: PackedVector2Array) -> float:
	var guide := TrailDefinition.new()
	guide.points = corridor
	var total := guide.route_length()
	if total < 400.0: return 0.75
	var best := 0.0
	var at := 0.5
	var s := 0.0
	while s + 150.0 <= total:
		var a := guide.point_at(s)
		var b := guide.point_at(s + 150.0)
		var drop := input.natural_ground(a) - input.natural_ground(b)
		if drop > best:
			best = drop
			at = (s + 75.0) / total
		s += 30.0
	return clampf(at, 0.33, 0.85)

## Коридор в ту сторону, где у него больше спуска, чем подъёма: маршрут едут ради спуска.
static func _downhill(input: GI, corridor: PackedVector2Array) -> PackedVector2Array:
	var rise := 0.0
	var drop := 0.0
	var previous := input.natural_ground(corridor[0])
	for k in range(1, corridor.size()):
		var y := input.natural_ground(corridor[k])
		rise += maxf(0.0, y - previous)
		drop += maxf(0.0, previous - y)
		previous = y
	if rise <= drop: return corridor
	var reversed := corridor.duplicate()
	reversed.reverse()
	return reversed

## Один участок (или линия парка): вырезка, линия, сборка, проверка, публикация. Принятое определение в мировых метрах или null.
static func _leg(ctx: Dictionary, world_hint: PackedVector2Array, region: Rect2i, style: String, title: String, seed_value: int, difficulty: float, is_leg: bool) -> TrailDefinition:
	var w: WorldData = ctx.w
	var h: Heightfield = ctx.h
	var plan: Dictionary = ctx.plan
	var fords: PackedByteArray = ctx.fords
	var progress: Callable = ctx.progress
	if progress.is_valid():
		progress.call(0.79 + 0.05 * minf(1.0, plan.stats.length_m / float(ctx.length_target)), "Велосипедные маршруты: %.1f км" % (plan.stats.length_m / 1000.0))
	region = region.intersection(ctx.area)
	if region.size.x < 16 or region.size.y < 16:
		_refuse(plan, "участок за краем области")
		return null
	# Every layout alternative preserves the nominated start. A blocked/out-of-bounds
	# start cannot pass final footprint validation; reject before the expensive site cut.
	# Do not prune a blocked middle/end: the walker can detour or finish a shorter safe leg.
	if is_leg and ctx.get("early_pruning", true) and _start_blocked(ctx.input, region, world_hint[0]):
		plan.stats.pruned_starts = int(plan.stats.get("pruned_starts", 0)) + 1
		_refuse(plan, "непроходимый старт коридора")
		return null
	var phase := Time.get_ticks_usec()
	var context := context_rect(h, region)
	var cut := TrailSite.cut(w, h, context, MARGIN)
	_time(plan, "cut", phase)
	if not cut.errors.is_empty():
		_refuse(plan, "участок: " + cut.errors[0])
		return null
	var site: TrailSite = cut.site
	phase = Time.get_ticks_usec()
	var local_input = ctx.input.window(site.origin, site.size)
	_time(plan, "window", phase)
	var ground := func(p: Vector2) -> float: return site.ground_at(p)
	var blocked := func(p: Vector2) -> bool: return local_input.blocked(p)
	phase = Time.get_ticks_usec()
	var hint := PackedVector2Array()
	for p: Vector2 in world_hint: hint.append(p - site.origin_m())
	var settings := {bounds = Rect2(Vector2(region.position - site.origin) * GameConfig.TILE, Vector2(region.size) * GameConfig.TILE).grow(-WORK_EDGE),
		difficulty = difficulty, modification = MODIFICATION[style], arc = ctx.get("arc", Vector2(0.0, 1.0)) if is_leg else Vector2(0.0, 1.0), peak = ctx.get("peak", 0.75), clear_ends = LEG_CLEAR if is_leg else 0.0, start_speed = float(ctx.get("start_speed", 3.0)) if is_leg else 3.0,
		soft = func(p: Vector2) -> bool:
			var cell := Vector2i((p / GameConfig.TILE).floor()) + site.origin
			return (cell.x >= 0 and cell.y >= 0 and cell.x < w.W and cell.y < w.H and fords[cell.y * w.W + cell.x] != 0) or local_input.near_path(p)}
	var line := func(route_hint: PackedVector2Array, walk: bool) -> Dictionary:
		var options_line := settings.duplicate()
		options_line.route_hint = route_hint
		options_line.walk = walk
		options_line.exact_line = not walk
		return Layout.generate(ground, Vector2(site.size) * GameConfig.TILE, seed_value, style, blocked, options_line)
	var result: Dictionary = line.call(hint, is_leg)
	_time(plan, "layout", phase)
	for key: String in ["walk_ms", "compose_ms"]:
		plan.stats.phases_ms["layout_" + key] = float(plan.stats.phases_ms.get("layout_" + key, 0.0)) + float(result.stats.get(key, 0.0))
	if result.routes.is_empty():
		_refuse(plan, result.stats.get("reason", "линия не построена"))
		return null
	var admitted := _admit(plan, site, result.routes[0], title, line, blocked, local_input, ctx.early_audit, MIN_LEG if is_leg else MIN_LINE, is_leg)
	if admitted.is_empty(): return null
	ctx.start_speed = admitted.exit_speed
	var d: TrailDefinition = admitted.d
	var global := StageTrailPlan.to_world(d, site)
	var errors := TrailBuilder.append_routes(w, [global], false)
	if not errors.is_empty():
		_refuse(plan, errors[0])
		return null
	publish(h, site, admitted.prepared.heights)
	ctx.input.existing_paths.append({points = global.points, half_width = global.width * 0.5})
	plan.routes.append(StageTrailPlan.pack(global))
	plan.entries.append({rect = context, style = style, route = StageTrailPlan.pack(global),
		length = global.route_length(), elements = global.elements.size(), earthworks = h.road_refinement.trail_shaping[global.id]})
	plan.stats.accepted += 1
	plan.stats.legs += 1
	plan.stats.length_m += global.route_length()
	ctx.styles[style] = float(ctx.styles.get(style, 0.0)) + global.route_length()
	return global

static func _start_blocked(input: GI, region: Rect2i, start: Vector2) -> bool:
	return input.blocked(start) or not Rect2(Vector2(region.position) * GameConfig.TILE, Vector2(region.size) * GameConfig.TILE).grow(-WORK_EDGE).has_point(start)

## Клетки русел, где брода нет: глубже порога брода или круто. Тот же ответ, что у StageTrails._unsafe_fords, на готовом рельефе.
static func _deep_rivers(w: WorldData, h: Heightfield, rivers: PackedByteArray) -> PackedByteArray:
	var deep := PackedByteArray()
	deep.resize(w.N)
	var cells := PackedInt32Array()
	for i in w.N:
		if rivers[i] != 0:
			cells.append(i)
			if w.slope[i] > StageTrails.FORD_SLOPE: deep[i] = 1
	for i in cells:
		if deep[i] != 0: continue # already too steep for a ford: depth cannot change the answer
		if h.depth_at((i % w.W + 0.5) * GameConfig.TILE, (i / w.W + 0.5) * GameConfig.TILE, INF) > GameConfig.FORD_DEPTH - 0.15: deep[i] = 1
	return deep

## Первая станция, где линия заходит глубже брода (узкое русло между центрами клеток), или INF.
static func _too_deep(h: Heightfield, d: TrailDefinition) -> float:
	var s := 0.0
	while s < d.route_length():
		var p := d.point_at(s)
		if h.depth_at(p.x, p.y, INF) >= GameConfig.FORD_DEPTH: return s
		s += 2.0
	return INF

## Трейл-парк: линии BikePark в самой большой свободной области как готовые кандидаты сети. Только прокладка и кандидаты:
## элементы, формирование и приёмка — общие. Концы отступают от родительской линии: сеть держит пути раздельно.
static func _park_candidates(w: WorldData, h: Heightfield, rect: Rect2i) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var park := BikePark.build(w, h, rect, "park")
	var lines := park.routes.duplicate()
	lines.sort_custom(func(a: TrailDefinition, b: TrailDefinition) -> bool: return a.route_length() > b.route_length())
	for d: TrailDefinition in lines.slice(0, PARK_LINES):
		var total := d.route_length()
		if total - PARK_END * 2.0 < PARK_MIN: continue
		var points := PackedVector2Array()
		var s := PARK_END
		while s < total - PARK_END:
			points.append(d.point_at(s))
			s += 4.0
		var box := Rect2(points[0], Vector2.ZERO)
		for p in points: box = box.expand(p)
		var lo := Vector2i((box.position / GameConfig.TILE).floor()) - Vector2i.ONE * 8
		var hi := Vector2i((box.end / GameConfig.TILE).ceil()) + Vector2i.ONE * 8
		out.append({region = Rect2i(lo, hi - lo).intersection(rect), title = d.title, trail_seed = posmod(hash([w.seed_num, d.id]), 99999) + 1, points = points})
	return out

## Сборка и проверка одной линии. Один плохой участок не выбрасывает всю длинную линию: элемент, не прошедший проверку,
## снимается, а по месту, где не годится само полотно, линия обрезается до большего годного куска. Не больше ADMIT_PASSES
## сборок на кандидата. {d, prepared} или пусто (причина — в статистике). Лабораторный ремонт основания здесь не вызывается.
static func _admit(plan: Dictionary, site: TrailSite, first: TrailDefinition, title: String, line: Callable, blocked: Callable, local_input: GI, early_audit: bool, min_line := 0.0, prefix_only := false) -> Dictionary:
	var d := first
	var allowed := func(p: Vector2) -> bool: return not blocked.call(p)
	var reason := ""
	var limits := {}
	var prepared := {}
	var removed: Array[TrailElement] = [] # только что снятые элементы: сборка пересчитывается только под ними
	var builds := 0 # полные сборки; снятие элемента почти ничего не стоит и каждый раз убирает хотя бы один
	while builds < ADMIT_PASSES:
		# Сборка короткой линии, которую всё равно не возьмём, не нужна.
		if d.route_length() < min_line:
			_refuse(plan, "линия короче нужного")
			return {}
		# Полотно строится по проекту, в пределах земляных работ: половина работ оставляла стенки, а без предела сборка отказывала.
		d.earthwork = 1.0
		d.shaping.depth_cap = DESIGN_DEPTH
		d.id = "world_trail_%d" % plan.entries.size()
		d.title = title
		# The saved world-space float32 line is canonical. Bake its roundtrip, so replay cannot
		# introduce a second geometry through precision lost when adding the window origin.
		var canonical := StageTrailPlan.to_world(d, site)
		var local_points := PackedVector2Array()
		for p in canonical.points: local_points.append(p - site.origin_m())
		var same_line := local_points == d.points
		d.points = local_points
		var phase := Time.get_ticks_usec()
		if not removed.is_empty() and same_line:
			prepared = site.rebake(prepared, d, removed, limits)
		else:
			builds += 1
			limits = {keep_bake = true, earthwork_source = site.surface(), earthwork_input = local_input} if early_audit else {keep_bake = true}
			var routes: Array[TrailDefinition] = [d]
			prepared = site.prepare(routes, true, limits)
		removed = []
		_time(plan, "prepare", phase)
		plan.stats.work_m += d.route_length() * (0.3 if not prepared.errors.is_empty() else float(limits.get("again_share", 1.0))) # отказ при запекании прерывает работу рано
		for key: String in prepared.timings:
			plan.stats.phases_ms["prepare_" + key] = float(plan.stats.phases_ms.get("prepare_" + key, 0.0)) + maxf(0, prepared.timings[key])
		var bad := INF # станция, где не годится само полотно
		if not prepared.errors.is_empty():
			reason = prepared.errors[0]
			if limits.has("failed_at"): bad = d.nearest(limits.failed_at).x
		else:
			phase = Time.get_ticks_usec()
			var earth := audit(site, prepared.heights, local_input, limits.get("checked", {}))
			_time(plan, "audit", phase)
			if not earth.is_empty():
				_refuse(plan, earth[0])
				return {}
			phase = Time.get_ticks_usec()
			var checked := Validation.measure(prepared.heights, d, allowed, true)
			_time(plan, "validation", phase)
			var deep_at := _too_deep(prepared.heights, d)
			if is_finite(deep_at):
				reason = "линия заходит глубже брода"
				bad = deep_at
			elif checked.accepted:
				var final_ground := func(p: Vector2) -> float: return prepared.heights.ground_at(p.x, p.y)
				var finish := RouteContract.endpoint(d.points[-1], d.tangent_at(d.route_length()), final_ground, allowed, d.width)
				if finish.suitable: return {d = d, prepared = prepared, exit_speed = float(checked.scenarios.normal.speeds[-1])}
				reason = "нет выката на готовом полотне"
				bad = d.route_length()
			else:
				reason = checked.errors[0]
				var drop := {}
				for issue: Dictionary in checked.issues:
					if issue.assessment != "safety": continue
					if int(issue.element) >= 0: drop[int(issue.element)] = true
					elif not is_finite(bad): bad = issue.worst_station
				if checked.issues.is_empty() and reason.contains(" у "): bad = reason.get_slice(" у ", 1).to_float()
				if not drop.is_empty():
					var kept: Array[TrailElement] = []
					for k in d.elements.size():
						if drop.has(k): removed.append(d.elements[k])
						else: kept.append(d.elements[k])
					d.elements = kept
					plan.stats.elements_dropped = int(plan.stats.get("elements_dropped", 0)) + drop.size()
					continue
		if not is_finite(bad): break
		var piece := _piece(d, bad, min_line, prefix_only)
		if piece.size() < 2: break
		var result: Dictionary = line.call(piece, false)
		if result.routes.is_empty():
			reason = result.stats.get("reason", "линия не построена")
			break
		d = result.routes[0]
		plan.stats.lines_cut = int(plan.stats.get("lines_cut", 0)) + 1
	_refuse(plan, reason)
	return {}

## Годный кусок линии по одну сторону от плохой станции: начало (участок маршрута) или больший; короче min_line — пусто.
static func _piece(d: TrailDefinition, bad: float, min_line: float, prefix_only: bool) -> PackedVector2Array:
	var total := d.route_length()
	var before := bad - TRIM
	var after := -INF if prefix_only else total - bad - TRIM
	if maxf(before, after) < maxf(min_line, 16.0): return PackedVector2Array()
	var from := 0.0 if before >= after else bad + TRIM
	var to := bad - TRIM if before >= after else total
	var out := PackedVector2Array()
	var s := from
	while s < to:
		out.append(d.point_at(s))
		s += 4.0
	out.append(d.point_at(to))
	return out

static func _time(plan: Dictionary, key: String, since: int) -> void:
	plan.stats.phases_ms[key] = float(plan.stats.phases_ms.get(key, 0.0)) + (Time.get_ticks_usec() - since) / 1000.0

static func _refuse(plan: Dictionary, reason: String) -> void:
	plan.stats.rejected[reason] = int(plan.stats.rejected.get(reason, 0)) + 1

## Capture entire nearby structures once, even when only their protected end touches the data margin.
## This grows the read-only context, not the area offered to the route builder.
static func context_rect(h: Heightfield, work: Rect2i) -> Rect2i:
	var data := work.grow(MARGIN)
	for pass_index in h.structures.size() + 1:
		var before := data
		for structure: Dictionary in h.structures:
			var metres := TrailSite.structure_foot(structure)
			var foot := Rect2(metres.position / GameConfig.TILE, metres.size / GameConfig.TILE)
			var cells := Rect2i(Vector2i(foot.position.floor()), Vector2i(foot.end.ceil()) - Vector2i(foot.position.floor()))
			if data.intersects(cells): data = data.merge(cells)
		if data == before: break
	return data.grow(-MARGIN)

## Compare actual metre vertices against the prepared source, including side slopes.
## There is no universal 2 m laboratory limit, and protection is never relaxed.
## Patches in `checked` already passed the same comparison vertex by vertex during the bake.
static func audit(site: TrailSite, h: Heightfield, input: GI, checked := {}) -> PackedStringArray:
	for key: int in h.road_refinement.patches:
		if checked.has(key): continue
		var patch: Dictionary = h.road_refinement.patches[key]
		var previous: PackedFloat32Array = site.patches[key].h if site.patches.has(key) else PackedFloat32Array()
		# Prepared source patches are immutable. An unchanged patch has exactly zero
		# earthworks; don't resample every old road for every proposed new trail.
		if not previous.is_empty() and patch.h == previous: continue
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				var at := Vector2((key % h.world.W) * RoadRefinement.DIV + x, (key / h.world.W) * RoadRefinement.DIV + z) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
				# A cropped edge can sample a different neighbouring/coarse triangle.
				# Compare saved vertices directly wherever source patches already exist.
				var n := z * RoadRefinement.STRIDE + x
				var delta: float = patch.h[n] - (previous[n] if not previous.is_empty() else site.ground_at(at))
				if not is_finite(delta): return PackedStringArray(["неконечная высота готового полотна"])
				if delta < -float(input.earthwork_limits.max_cut) - 0.05 or delta > float(input.earthwork_limits.max_fill) + 0.05:
					return PackedStringArray(["превышен игровой предел земляных работ"])
				if absf(delta) > 0.05 and input.blocked(at): return PackedStringArray(["земляные работы затрагивают воду, инфраструктуру или готовый путь"])
	return PackedStringArray()

## Publish exactly the accepted local surface; all values use the same world metre grid.
static func publish(h: Heightfield, site: TrailSite, local: Heightfield) -> void:
	for z in site.size.y:
		for x in site.size.x:
			h.hv[(site.origin.y + z) * h.world.W + site.origin.x + x] = local.hv[z * site.size.x + x]
	for key: int in local.road_refinement.patches:
		var global_key := (site.origin.y + key / site.size.x) * h.world.W + site.origin.x + key % site.size.x
		h.road_refinement.patches[global_key] = local.road_refinement.patches[key]
	h.road_refinement.trail_shaping.merge(local.road_refinement.trail_shaping, true)
	h.road_refinement.trail_elements_baked = true

## A missing derived surface replays saved definitions, never discovery or the world generator.
static func restore(h: Heightfield, plan: Dictionary) -> PackedStringArray:
	var errors := StageTrailPlan.consistency_errors(h.world)
	if not errors.is_empty(): return errors
	# Maps and other derivatives may read the canonical world concurrently. Replay only
	# changes a private civil network; large immutable geography arrays stay shared.
	var source := h.world
	var w := WorldData.new()
	for field: String in WorldData.CACHE_FIELDS: w.set(field, source.get(field))
	w.world_origin = source.world_origin
	w.outer = source.outer
	w.path_mask = source.path_mask.duplicate()
	w.road_surface = source.road_surface.duplicate()
	var ids := {}
	for record: Dictionary in plan.routes: ids[record.id] = true
	w.trails = source.trails.filter(func(route: Dictionary) -> bool: return not ids.has(route.get("trail_id", ""))).duplicate(true)
	var replay := h.copy()
	replay.world = w
	replay.finish_paths()
	for entry: Dictionary in plan.entries:
		var cut := TrailSite.cut(w, replay, entry.rect, MARGIN)
		if not cut.errors.is_empty(): errors = cut.errors; break
		var site: TrailSite = cut.site
		var global := StageTrailPlan.unpack(entry.route)
		var local := global.duplicate(true) as TrailDefinition
		var points := PackedVector2Array()
		for p in global.points: points.append(p - site.origin_m())
		local.points = points
		var prepared := site.prepare([local])
		if not prepared.errors.is_empty(): errors = prepared.errors; break
		errors = TrailBuilder.append_routes(w, [global], false)
		if not errors.is_empty(): break
		publish(replay, site, prepared.heights)
	if errors.is_empty(): StageTrailPlan.copy_surface(h, replay)
	return errors
