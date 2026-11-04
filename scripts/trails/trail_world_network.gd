extends RefCounted
## One survey of a prepared world; one local preparation and final check per candidate.
## Accepted patches ARE the game surface. No synthetic world, repair loop or second bake.
const Search := preload("res://scripts/trails/trail_site_search.gd")
const Layout := preload("res://scripts/trails/trail_layout.gd")
const Validation := preload("res://scripts/trails/trail_validation.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const MARGIN := 12
const EARTHWORKS := {max_cut = 8.0, max_fill = 6.0, modification = 1.0}
const RouteContract := preload("res://scripts/trails/trail_route_contract.gd")
## Коридоры сети: в обе стороны от начальной клетки, квадрат 704 м (участок до 192 клеток).
const CORRIDOR := {box = 704.0, two_way = true, pad = 24, mark_paths = true}
const CROSSABLE: Array[String] = ["animal"]
## Границы сети — работа, а не время: сборка стоит примерно пропорционально метрам линии.
const ROUTE_TARGET := 10      # трасс достаточно
const LENGTH_TARGET := 9000.0 # суммарной длины достаточно, м
const WORK_LIMIT := 16000.0   # всего собранных метров, с отказами и повторами
const MIN_LINE := 200.0       # короче только когда длинных не вышло вовсе, м
const TRIM := 30.0            # запас от плохого места при обрезке линии, м
const WORK_EDGE := 12.0       # линия не ближе к краю рабочей зоны участка (TrailSite.inside_errors), м
const ADMIT_PASSES := 3
const PARK_LINES := 4         # столько самых длинных линий трейл-парка
const PARK_MIN := 250.0       # короче линия парка не нужна, м
const PARK_END := 14.0        # концы линии парка отступают от родительской, м
const DIFFICULTY := [0.25, 0.4, 0.55]
const MODIFICATION := {flow = 0.7, park = 0.7, downhill = 0.6, enduro = 0.5, tech = 0.4}
static var surveys := 0

static func build(w: WorldData, h: Heightfield, area: Rect2i, options := {}) -> Dictionary:
	var started := Time.get_ticks_msec()
	var input = GI.from_world(w, h, CROSSABLE)
	var input_ms := Time.get_ticks_msec() - started
	input.earthwork_limits = EARTHWORKS.duplicate()
	var search := Search.new({size = w.W, seed = w.seed_num, heights = input.heights, water = input.water, input = input},
		{area = area.grow(-MARGIN), probe_budget = int(options.get("probe_budget", maxi(64, w.N / (Search.STRIDE * Search.STRIDE)))), corridor = CORRIDOR})
	surveys += 1
	var candidates := search.find(w.seed_num)
	# Длинные — первыми: короткая линия, принятая раньше, перегородила бы длинную. Границы работы — метры и числа,
	# не время: секундомер только для диагностики и не выбирает канонический мир.
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.probe.length) > float(b.probe.length) if a.probe.length != b.probe.length else a.trail_seed < b.trail_seed)
	var park_started := Time.get_ticks_msec()
	var park: Array[Dictionary] = []
	if int(options.get("probe_budget", 1)) > 0: park = _park_candidates(w, h, area.grow(-MARGIN))
	candidates = park + candidates
	var park_ms := Time.get_ticks_msec() - park_started
	var plan := {mode = "terrain_network", state = "none", reason = "нет принятых трасс", routes = [], entries = [],
		area = area, stats = {survey = search.stats, input_ms = input_ms, phases_ms = {}, attempted = 0, accepted = 0, rejected = {}, work_m = 0.0, length_m = 0.0}}
	plan.stats.park = {ms = park_ms, lines = park.size()}
	var style_uses := {}
	for candidate in candidates:
		if plan.stats.accepted >= ROUTE_TARGET or plan.stats.length_m >= LENGTH_TARGET or plan.stats.work_m >= WORK_LIMIT: break
		if float(candidate.probe.length) < MIN_LINE and plan.stats.accepted > 0: break
		plan.stats.attempted += 1
		var progress: Callable = options.get("on_progress", Callable())
		if progress.is_valid():
			progress.call(0.79 + 0.05 * plan.stats.attempted / maxi(1, candidates.size()),
				"Велосипедные трассы: %d/%d · принято %d" % [plan.stats.attempted, candidates.size(), plan.stats.accepted])
		var phase := Time.get_ticks_usec()
		var context := context_rect(h, candidate.region)
		var cut := TrailSite.cut(w, h, context, MARGIN)
		_time(plan, "cut", phase)
		if not cut.errors.is_empty():
			_refuse(plan, "участок: " + cut.errors[0]); continue
		var site: TrailSite = cut.site
		phase = Time.get_ticks_usec()
		var local_input = input.window(site.origin, site.size)
		_time(plan, "window", phase)
		# The candidate's source and exclusions are immutable throughout layout and
		# validation. Repeated endpoint/footprint queries reuse exact point results.
		var ground_samples := {}
		var blocked_samples := {}
		var ground := func(p: Vector2) -> float:
			if not ground_samples.has(p): ground_samples[p] = site.ground_at(p)
			return ground_samples[p]
		var blocked := func(p: Vector2) -> bool:
			if not blocked_samples.has(p): blocked_samples[p] = local_input.blocked(p)
			return blocked_samples[p]
		phase = Time.get_ticks_usec()
		var hint := PackedVector2Array()
		for p: Vector2 in candidate.probe.points: hint.append(p - site.origin_m())
		# Характер — самый редкий среди подходящих рельефу (они в начале списка); сложность и работа с землёй — от него.
		var style: String = candidate.styles[0]
		for name: String in candidate.styles:
			if int(style_uses.get(name, 0)) < int(style_uses.get(style, 0)): style = name
		var settings := {bounds = Rect2(Vector2(candidate.region.position - site.origin) * GameConfig.TILE, Vector2(candidate.region.size) * GameConfig.TILE).grow(-WORK_EDGE),
			difficulty = DIFFICULTY[plan.stats.accepted % DIFFICULTY.size()], modification = MODIFICATION[style]}
		var line := func(route_hint: PackedVector2Array, walk: bool) -> Dictionary:
			var options_line := settings.duplicate()
			options_line.route_hint = route_hint
			options_line.walk = walk
			options_line.exact_line = not walk
			return Layout.generate(ground, Vector2(site.size) * GameConfig.TILE, candidate.trail_seed, style, blocked, options_line)
		var result: Dictionary = line.call(hint, not candidate.get("exact", false))
		_time(plan, "layout", phase)
		if result.routes.is_empty():
			_refuse(plan, result.stats.get("reason", "линия не построена")); continue
		var title: String = candidate.get("title", "%s · %d" % [Layout.STYLES[style].title, plan.entries.size() + 1])
		# Пока коридоры длинные, короткий обрывок ходока — не трасса; в мире без длинных мест годится и короткая.
		var admitted := _admit(plan, site, result.routes[0], title, line, blocked, local_input, options.get("early_audit", true), MIN_LINE if float(candidate.probe.length) >= MIN_LINE else 0.0)
		if admitted.is_empty(): continue
		var d: TrailDefinition = admitted.d
		var prepared: Dictionary = admitted.prepared
		var global := StageTrailPlan.to_world(d, site)
		var errors := TrailBuilder.append_routes(w, [global], false)
		if not errors.is_empty():
			_refuse(plan, errors[0]); continue
		publish(h, site, prepared.heights)
		# Reserve only an accepted line, not its search rectangle or a failed proposal.
		input.existing_paths.append({points = global.points, half_width = global.width * 0.5})
		plan.routes.append(StageTrailPlan.pack(global))
		plan.entries.append({rect = context, style = style, route = StageTrailPlan.pack(global),
			length = global.route_length(), elements = global.elements.size(), earthworks = h.road_refinement.trail_shaping[global.id]})
		plan.stats.accepted += 1
		plan.stats.length_m += global.route_length()
		style_uses[style] = int(style_uses.get(style, 0)) + 1
	if not plan.routes.is_empty():
		RoadSurface.rebuild_map(w)
		plan.state = "found"
		plan.reason = ""
		plan.definition = plan.routes[0]
	plan.stats.budget_exhausted = search.stats.budget_exhausted or plan.stats.attempted < candidates.size()
	plan.stats.total_ms = Time.get_ticks_msec() - started
	return plan

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
		out.append({region = Rect2i(lo, hi - lo).intersection(rect), exact = true, title = d.title, trail_seed = posmod(hash([w.seed_num, d.id]), 99999) + 1,
			styles = ["park", "flow"], probe = {points = points, length = RouteContract.length(points), build_cost = 0.0}})
	return out

## Сборка и проверка одной линии. Один плохой участок не выбрасывает всю длинную линию: элемент, не прошедший проверку,
## снимается, а по месту, где не годится само полотно, линия обрезается до большего годного куска. Не больше ADMIT_PASSES
## сборок на кандидата. {d, prepared} или пусто (причина — в статистике). Лабораторный ремонт основания здесь не вызывается.
static func _admit(plan: Dictionary, site: TrailSite, first: TrailDefinition, title: String, line: Callable, blocked: Callable, local_input: GI, early_audit: bool, min_line := 0.0) -> Dictionary:
	var d := first
	# Заранее: сборка короткой линии, которую всё равно не возьмём, не нужна.
	if d.route_length() < min_line:
		_refuse(plan, "линия короче нужного")
		return {}
	var allowed := func(p: Vector2) -> bool: return not blocked.call(p)
	var reason := ""
	var was_cut := false # обрезка — одна на кандидата: второе плохое место значит, что линия плоха вся
	for pass_index in ADMIT_PASSES:
		d.id = "world_trail_%d" % plan.entries.size()
		d.title = title
		# The saved world-space float32 line is canonical. Bake its roundtrip, so replay cannot
		# introduce a second geometry through precision lost when adding the window origin.
		var canonical := StageTrailPlan.to_world(d, site)
		var local_points := PackedVector2Array()
		for p in canonical.points: local_points.append(p - site.origin_m())
		d.points = local_points
		var phase := Time.get_ticks_usec()
		var limits := {earthwork_source = site.surface(), earthwork_input = local_input} if early_audit else {}
		var routes: Array[TrailDefinition] = [d]
		var prepared := site.prepare(routes, true, limits)
		_time(plan, "prepare", phase)
		plan.stats.work_m += d.route_length()
		for key: String in prepared.timings:
			plan.stats.phases_ms["prepare_" + key] = float(plan.stats.phases_ms.get("prepare_" + key, 0.0)) + maxf(0, prepared.timings[key])
		var bad := INF # станция, где не годится само полотно
		if not prepared.errors.is_empty():
			reason = prepared.errors[0]
			if limits.has("failed_at"): bad = d.nearest(limits.failed_at).x
		else:
			phase = Time.get_ticks_usec()
			var earth := audit(site, prepared.heights, local_input)
			_time(plan, "audit", phase)
			if not earth.is_empty():
				_refuse(plan, earth[0])
				return {}
			phase = Time.get_ticks_usec()
			var checked := Validation.measure(prepared.heights, d, allowed)
			_time(plan, "validation", phase)
			if checked.accepted and d.route_length() < min_line:
				_refuse(plan, "линия короче нужного")
				return {}
			if checked.accepted:
				var final_ground := func(p: Vector2) -> float: return prepared.heights.ground_at(p.x, p.y)
				var finish := RouteContract.endpoint(d.points[-1], d.tangent_at(d.route_length()), final_ground, allowed, d.width)
				if finish.suitable: return {d = d, prepared = prepared}
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
						if not drop.has(k): kept.append(d.elements[k])
					d.elements = kept
					plan.stats.elements_dropped = int(plan.stats.get("elements_dropped", 0)) + drop.size()
					continue
		if not is_finite(bad) or was_cut: break
		was_cut = true
		var piece := _piece(d, bad)
		if piece.size() < 2: break
		var result: Dictionary = line.call(piece, false)
		if result.routes.is_empty():
			reason = result.stats.get("reason", "линия не построена")
			break
		d = result.routes[0]
		plan.stats.lines_cut = int(plan.stats.get("lines_cut", 0)) + 1
	_refuse(plan, reason)
	return {}

## Больший кусок линии по одну сторону от плохой станции; короче MIN_LINE — пусто.
static func _piece(d: TrailDefinition, bad: float) -> PackedVector2Array:
	var total := d.route_length()
	var before := bad - TRIM
	var after := total - bad - TRIM
	if maxf(before, after) < MIN_LINE: return PackedVector2Array()
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
static func audit(site: TrailSite, h: Heightfield, input: GI) -> PackedStringArray:
	for key: int in h.road_refinement.patches:
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
	var w := h.world
	var original: Array = w.trails
	var ids := {}
	for record: Dictionary in plan.routes: ids[record.id] = true
	w.trails = original.filter(func(route: Dictionary) -> bool: return not ids.has(route.get("trail_id", "")))
	h.finish_paths()
	var errors := PackedStringArray()
	for entry: Dictionary in plan.entries:
		var cut := TrailSite.cut(w, h, entry.rect, MARGIN)
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
		publish(h, site, prepared.heights)
	w.trails = original
	RoadSurface.rebuild_map(w)
	return errors
