extends RefCounted
const TrailStandards := preload("res://scripts/trails/trail_standards.gd")
const Validation := preload("res://scripts/trails/trail_validation.gd")
const Composition := preload("res://scripts/trails/trail_character.gd")
const GenerationInput := preload("res://scripts/trails/trail_generation_input.gd")
const RouteContract := preload("res://scripts/trails/trail_route_contract.gd")
## Shared terrain layout for main-game preparation and Trail Lab: bounded terrain routes, independent style/difficulty/construction settings,
## planned approach/feature/recovery chains and optional engineered crossings.
## Deterministic in terrain, seed and settings. Final acceptance belongs to Fixture.prepare.

const MARGIN := 28.0
const STEP := 4.0
const MIN_RADIUS := 9.0  # туже — только разворот, когда упёрлись
const HAIRPIN := 6.0     # радиус такого разворота, м
const LOOK := 20.0
const SEP := 14.0        # своя линия не ближе этого (кроме последних OWN_SKIP м)
const OWN_SKIP := 40.0
const CLIFF := 0.5       # круче (м на м) наружный откос поворота — штраф
const GOAL_REACH := RouteContract.FINISH_RADIUS
const CLIMB_MAX := 0.08  # круче подъём на шаге — почти запрет (на стенке уступа седок встаёт)
## Стили: целевой уклон (спуск — отрицательный), длина, ширина, извилистость, крейсерская
## скорость и доля перегрузки в поворотах (под неё — радиус линии).
const STYLES := {
	flow = {title = "Flow", grade = -0.07, length = 1100.0, width = 4.5, wander = 0.06, cruise = 13.0, lat = 0.6},
	downhill = {title = "Даунхилл", grade = -0.14, length = 800.0, width = 4.0, wander = 0.05, cruise = 14.0, lat = 0.7},
	enduro = {title = "Эндуро", grade = -0.10, length = 1300.0, width = 3.5, wander = 0.08, cruise = 12.0, lat = 0.6},
	tech = {title = "Техничная", grade = -0.09, length = 900.0, width = 3.5, wander = 0.09, cruise = 10.0, lat = 0.55},
	# Park character; layout is selected independently below.
	park = {title = "Байк-парк", grade = -0.02, length = 900.0, width = 4.0, wander = 0.0, cruise = 13.0, lat = 0.7},
}
const ORDER := ["flow", "downhill", "enduro", "tech", "park"]
## Байк-парк: прямые (длина, м), их число, шаг между ними (м; разворот — полукруг радиуса шага/2).
const PARK_LANE := Vector2(90.0, 130.0) # длиннее — к середине прямой разгон до скорости столов (от 12 м/с)
const PARK_LANES := Vector2i(4, 7)
## Drainage: offset from the tread and useful channel length.
const DITCH_OFFSET := 2.0    # от края полотна до оси канавы, м
const DITCH_LENGTH := Vector2(20.0, 40.0)
## v3: петля над собой и овражки.
const LOOP_R := 16.0         # радиус петли, м (вираж на круге ставит составитель)
const LOOP_LEAD := 16.0      # прямая до X и от X до начала круга, м (равна радиусу: круг на 270° выводит на X)
const LOOP_CUT := 2.4        # выемка нижнего прохода под X, м (с мостком 1,2 м — просвет около 3,6 м)
const LOOP_DECK := 1.2
const LOOP_RELIEF := 5.0     # перепад земли под петлёй не больше, м
const RAVINE_SMOOTH := 1.2   # земля у овражка не дальше от прямой, м
const RAVINE_DEPTH := 1.8    # глубина овражка, м
const RAVINE_SPAN := 12.0    # овражек тянется в стороны от оси, м
const RAVINE_EVERY := 150.0  # в среднем один овражек на столько метров (v4: было 220)
const RAVINE_GAP := 90.0     # и не ближе друг к другу
const RAVINE_STRAIGHT := 35.0 # овражек — где ось на ±16 м не туже этого радиуса
const WANDER_V3 := 0.6       # v3: извилистость меньше — больше прямых под прыжки
const WALK_MARGIN := 1.5     # ходок игры держится дальше от запретных клеток, м
const OPEN_FINISH_MIN := 120.0 # ходок игры не отступает короче этого, м
const WALK_ENOUGH := 200.0  # такой длины линии ходока достаточно, м: подгонка к коридору чаще падает на приёмке
const SOFT_COST := 6.0       # шаг по дороге или броду
const CROSSING_CLEAR := 12.0 # столько метров у переезда и брода без элементов
const STEEP := 0.3          # круче этого склон на шаге ходок игры обходит траверсом
const STEEP_COST := 150.0
const WALL_COST := 60.0     # шаг в место, закрытое проверкой проекта (TrailWorldNetwork): дороже любого уклона, но не запрет
const HINT_WEIGHT := 2.0    # ходок игры сильнее держится коридора: вдали от него он заходит в тупики между ручьями

static var seed := 1
static var style := "flow"
static var difficulty := 0.5
static var modification := 0.5
static var mandatory_gaps := false
static var park_layout := "auto"
const PARK_LAYOUTS := ["serpentine", "horseshoe", "oval"]
static var stats := {}
static var speeds := PackedFloat32Array() ## профиль скорости «как едут», по которому ставились элементы
static var cuts: Array = []                ## врезки последней трассы (TrailLabTerrain.apply_cuts)


## Трасса по земле ground на поле size × size м. Пусто — линия не проложилась (stats.reason).
## avoid(Vector2) -> bool — необязательно: куда линии нельзя (вода окна мира); carve(Array) — необязательно: применить
## врезки к земле (после неё ground уже врезанная); без carve овражков и петли нет.
static func build(ground: Callable, size: float, seed_value: int, style_name: String, avoid := Callable(), carve := Callable(), options := {}) -> Array[TrailDefinition]:
	var settings := {difficulty = difficulty, modification = modification, mandatory_gaps = mandatory_gaps, park_layout = park_layout}
	settings.merge(options, true)
	var result := _build_core(ground, size, seed_value, style_name, avoid, carve, settings)
	result.style = style_name
	publish_project(result)
	var routes: Array[TrailDefinition] = []
	routes.assign(result.routes)
	return routes

## Game preparation fits the nominated corridor once; lab project solving remains opt-in.
static func generate(ground: Callable, extent: Vector2, seed_value: int, style_name: String, avoid: Callable, options := {}) -> Dictionary:
	var settings := options.duplicate(true)
	settings.extent = extent
	settings._corridor_variant = 0
	settings.geometry_attempts = 1
	# Source cut/fill limits are checked on the prepared surface. They do not require
	# the designed riding grade to inherit the steepest natural metre of this corridor.
	settings.use_designed_grade = true
	if settings.get("walk", false):
		# Ходок по коридору (как в лаборатории): держит уклон стиля траверсом, виляет и обходит воду. Ходок жадный и может
		# упереться раньше конца коридора — тогда берётся более длинная из его линии и точной подгонки к коридору.
		# Цена — только выборки земли, без формирования.
		var corridor_length := RouteContract.length(settings.route_hint)
		var walked := settings.duplicate()
		walked._corridor_variant = 3
		walked.geometry_attempts = 2
		walked.walk_length = corridor_length * 1.8
		walked.open_finish = true
		var result := _build_core(ground, minf(extent.x, extent.y), seed_value, style_name, avoid, Callable(), walked)
		var walked_length: float = result.stats.get("length", 0.0)
		if not result.routes.is_empty() and walked_length >= WALK_ENOUGH: return result
		var fitted := _build_core(ground, minf(extent.x, extent.y), seed_value, style_name, avoid, Callable(), settings)
		return result if float(fitted.stats.get("length", 0.0)) <= walked_length else fitted
	return _build_core(ground, minf(extent.x, extent.y), seed_value, style_name, avoid, Callable(), settings)

## Data-only job; never writes the legacy facade or active terrain. Scene construction stays on the main thread.
static func build_project(input: GenerationInput, seed_value: int, style_name: String, options := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var errors := input.validate()
	if not STYLES.has(style_name): errors.append("неизвестный характер трассы")
	if not errors.is_empty(): return _project_result([], {accepted = false, reason = "; ".join(errors)}, [], PackedFloat32Array(), seed_value)
	var settings: Dictionary = options.duplicate(true)
	settings.extent = Vector2(input.size) * input.cell_size
	if float(settings.get("modification", 0.5)) > float(input.earthwork_limits.modification):
		return _project_result([], {accepted = false, reason = "превышен предел изменения рельефа"}, [], PackedFloat32Array(), seed_value)
	var result := {}
	var context: GenerationInput
	var selection_attempts := []
	settings._base_budget = {remaining = 3}
	var guided: bool = settings.get("route_hint", PackedVector2Array()).size() > 1
	for variant in (4 if guided else 1):
		if settings._base_budget.remaining <= 0: break
		context = input.duplicate(true) as GenerationInput
		settings._source = context
		settings._corridor_variant = variant
		var attempt_started := Time.get_ticks_usec()
		result = _build_core(context.ground, minf(context.size.x, context.size.y) * context.cell_size, seed_value, style_name, context.blocked, context.apply_cuts, settings)
		var fit: Dictionary = result.stats.get("element_fit", {})
		var ready: bool = not result.routes.is_empty() and (fit.is_empty() or fit.get("accepted", false)) and context.cut_errors.is_empty()
		selection_attempts.append({method = "walk" if variant == 3 or not guided else "corridor", offset = [0.0, 8.0, -8.0, 0.0][variant],
			accepted = ready, reason = result.stats.get("reason", fit.get("reason", "")), ms = (Time.get_ticks_usec() - attempt_started) / 1000.0,
			walk_calls = result.stats.get("walk_calls", 0)})
		if ready: break
	result.stats.selection_attempts = selection_attempts
	result.stats.primary_method = "corridor" if guided else "walk"
	result.stats.fallbacks = selection_attempts.size() - 1
	result.stats.base_fit_calls = 3 - int(settings._base_budget.remaining)
	if not context.cut_errors.is_empty():
		result.routes = []
		result.stats.accepted = false
		result.stats.reason = "; ".join(context.cut_errors)
	# Element height is not fill depth (decks add no soil, dips excavate).
	# ElementFit audits the actual combined surface against the source limits.
	result.source_hash = input.fingerprint()
	result.style = style_name
	result.stats.ms = (Time.get_ticks_usec() - started) / 1000.0
	return result

static func publish_project(result: Dictionary) -> void:
	stats = result.stats.duplicate(true)
	cuts = result.cuts.duplicate(true)
	speeds = result.speeds.duplicate()
	seed = result.seed
	style = result.get("style", style)

static func _project_result(routes: Array, report: Dictionary, excavations: Array, velocity: PackedFloat32Array, seed_value: int) -> Dictionary:
	return {routes = routes, stats = report, cuts = excavations, speeds = velocity, seed = seed_value}

static func _build_core(ground: Callable, size: float, seed_value: int, style_name: String, avoid := Callable(), carve := Callable(), options := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var seed := seed_value
	var style := style_name if STYLES.has(style_name) else "flow"
	var st: Dictionary = STYLES[style].duplicate(true)
	if float(options.get("width", 0.0)) > 0.0: st.width = float(options.width) # участок длинного маршрута продолжает его ширину
	var skill := clampf(float(options.get("difficulty", 0.5)), 0.0, 0.99)
	var shaping_amount := clampf(float(options.get("modification", 0.5)), 0.0, 1.0)
	var gaps_ok := Composition.gap_allowed(style, skill, shaping_amount, bool(options.get("mandatory_gaps", false)))
	st.cruise *= lerpf(0.8, 1.15, skill)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("trail_lab_builder|%d|%s" % [seed, style])
	var stats := {}
	var speeds := PackedFloat32Array()
	var cuts: Array = []
	var extent: Vector2 = options.get("extent", Vector2.ONE * size)
	var bounds: Rect2 = options.get("bounds", Rect2(Vector2.ZERO, extent))
	var inside := func(p: Vector2) -> bool:
		return p.x >= 0 and p.y >= 0 and p.x < extent.x and p.y < extent.y and bounds.has_point(p) and not (avoid.is_valid() and avoid.call(p))
	var walk_inside := func(p: Vector2) -> bool:
		# open_finish (ходок игры): запас ходку, чтобы сглаженная линия не легла полотном на запретную клетку
		var half: float = st.width * 0.5 + (WALK_MARGIN if options.get("open_finish", false) else 0.0)
		for offset in [Vector2.ZERO, Vector2(half, 0), Vector2(-half, 0), Vector2(0, half), Vector2(0, -half)]:
			if not inside.call(p + offset): return false
		return true
	var cells: Array[Vector3] = []
	var nominated: PackedVector2Array = options.get("route_hint", PackedVector2Array())
	if nominated.size() > 1:
		for p in nominated: cells.append(Vector3(p.x, p.y, float(ground.call(p))))
	else:
		var at := MARGIN + 8.0
		while at < extent.x - MARGIN:
			var bt := MARGIN + 8.0
			while bt < extent.y - MARGIN:
				if walk_inside.call(Vector2(at, bt)): cells.append(Vector3(at, bt, float(ground.call(Vector2(at, bt)))))
				bt += 16.0
			at += 16.0
	if cells.size() < (2 if nominated.size() > 1 else 8):
		return _project_result([], {accepted = false, reason = "слишком мало сухого места в границах участка"}, cuts, speeds, seed)
	cells.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.z > b.z)
	var lo_h := cells[-1].z
	var hi_h := cells[0].z
	# характер местности: средний уклон поля — по нему целевой уклон (на пологой земле мягче, на крутой не круче стиля)
	var field_grade := (hi_h - lo_h) / (size * 0.7)
	var grade := clampf(float(st.grade), -maxf(0.03, field_grade * 0.9), -0.025)
	# рисунок линии — по сиду
	var shape := {pull = rng.randf_range(0.15, 0.6), wander = float(st.wander) * rng.randf_range(0.6, 1.5) * (WANDER_V3 if carve.is_valid() else 1.0),
		period = Vector2(rng.randf_range(30.0, 70.0), rng.randf_range(12.0, 26.0)), phase = Vector2(rng.randf() * TAU, rng.randf() * TAU)}
	shape.route_hint = options.get("route_hint", PackedVector2Array())
	if options.get("open_finish", false):
		shape.hint_weight = HINT_WEIGHT
		shape.steep_cost = true
	shape.soft = options.get("soft", Callable())
	shape.wall = options.get("wall", Callable())
	var finish_plan := {}
	if shape.route_hint.size() > 1:
		finish_plan = RouteContract.plan(shape.route_hint, ground, inside, st.width, bool(options.get("short_route", false)))
		if finish_plan.has("error"):
			return _project_result([], {accepted = false, reason = finish_plan.error, finish_plan = finish_plan, fragments = []}, [], speeds, seed)
		shape.route_hint = finish_plan.hint
	var upper := cells.slice(0, maxi(1, cells.size() / 5))
	var lower := cells.slice(cells.size() * 2 / 3)
	# своя четверть поля для старта по сиду (среди верхних 40 %): иначе спуски сходятся в одну ложбину
	var quarter := rng.randi() % 4
	var mine := cells.slice(0, maxi(1, cells.size() * 2 / 5)).filter(func(c: Vector3) -> bool:
		return int(c.x > size * 0.5) + 2 * int(c.y > size * 0.5) == quarter)
	if mine.size() >= 3: upper.assign(mine)
	shape.quarter = quarter
	var pts := PackedVector2Array()
	var goal := Vector2.ZERO
	var best_score := -INF
	var best_components := {}
	var completion := {}
	var fragments := []
	var finish_refused := []
	var completed_candidates := 0
	var promising: Array[Dictionary] = []
	var tries := 0
	var walk_calls := 0
	var walk_refused := 0
	var longest_trial := 0.0
	var walk_reasons := {}
	var layout: String = options.get("park_layout", "auto")
	if layout not in PARK_LAYOUTS: layout = PARK_LAYOUTS[posmod(seed, PARK_LAYOUTS.size())]
	var guided: bool = shape.route_hint.size() > 1
	if style == "park" and not guided:
		pts = _park_points(ground, walk_inside, size, rng, layout, bounds)
		if pts.size() > 1:
			goal = pts[-1]
			completion = RouteContract.measure(pts, PackedVector2Array(), goal, "layout_complete", ground, inside, st.width)
			if not completion.complete:
				if completion.fragment: fragments.append(completion)
				else: finish_refused.append(completion)
				pts = PackedVector2Array()
		best_score = INF
	var corridor_variant: int = options.get("_corridor_variant", 0)
	for k in (0 if style == "park" and not guided else int(options.get("geometry_attempts", (1 if corridor_variant < 3 else 3) if guided else 10))):
		tries += 1
		var s0: Vector3 = upper[rng.randi() % upper.size()]
		var start := Vector2(s0.x, s0.y)
		var g0: Vector3 = lower[rng.randi() % lower.size()]
		for j in 6:
			if Vector2(g0.x, g0.y).distance_to(start) >= size * 0.45: break
			g0 = lower[rng.randi() % lower.size()]
		var target := Vector2(g0.x, g0.y)
		var hint: PackedVector2Array = shape.route_hint
		if hint.size() > 1:
			start = hint[0]
			target = hint[-1]
		var attempt_shape := shape.duplicate(true)
		attempt_shape.phase += Vector2(0.71, 1.13) * k
		attempt_shape.pull *= 1.0 + 0.08 * k
		var line: PackedVector2Array
		if guided and options.get("exact_line", false):
			line = hint
			attempt_shape.trace = {goal = target, reason = "corridor_fit", method = "exact_line"}
		elif guided and corridor_variant < 3:
			line = _corridor_line(hint, [0.0, 8.0, -8.0][corridor_variant])
			attempt_shape.trace = {goal = target, reason = "corridor_fit", method = "whole_corridor"}
		else:
			walk_calls += 1
			line = _walk_with_loop(ground, walk_inside, start, target, maxf(float(st.length), float(options.get("walk_length", 0.0))), grade, attempt_shape, st, rng, lower, carve.is_valid() and shaping_amount >= 0.8 and skill >= 0.5 and style == "park")
		if line.size() < 2: continue
		longest_trial = maxf(longest_trial, line.size() * STEP)
		var trial := TrailDefinition.new()
		trial.width = st.width
		trial.points = _resample(_smooth(_smooth(line)), 2.0)
		var trace: Dictionary = attempt_shape.get("trace", {})
		var chosen_finish: Vector2 = finish_plan.get("finish", trace.get("goal", target))
		if options.get("open_finish", false):
			# Ходок игры: линия кончается там, где есть место остановки и выката, а не обязана
			# прийти именно туда. Без такого места — отступ назад по своей линии.
			while line.size() * STEP >= OPEN_FINISH_MIN and not RouteContract.endpoint(trial.points[-1], (trial.points[-1] - trial.points[-2]).normalized(), ground, inside, st.width).suitable:
				line = line.slice(0, line.size() - 3)
				trial.points = _resample(_smooth(_smooth(line)), 2.0)
			chosen_finish = trial.points[-1]
			trace.reason = "layout_complete"
		var finished := RouteContract.measure(trial.points, hint, chosen_finish, trace.get("reason", "unknown_stop"), ground, inside, st.width, finish_plan.get("kind", "full"))
		if not finished.complete:
			if finished.fragment: fragments.append(finished)
			else: finish_refused.append(finished)
			continue
		completed_candidates += 1
		var trial_errors := Validation.footprint(trial, inside)
		if not trial_errors.is_empty():
			walk_refused += 1
			for reason in trial_errors: walk_reasons[reason] = int(walk_reasons.get(reason, 0)) + 1
			continue
		var components := score_components(trial.points, ground, float(st.length), grade)
		if guided:
			var deviation := 0.0
			for p in trial.points: deviation += float(hint_guide(hint, p).distance)
			components.corridor = clampf(1.0 - deviation / maxf(1, trial.points.size()) / 64.0, 0, 1)
			components.total = components.total * 0.8 + components.corridor * 0.2
		var score: float = components.total
		promising.append({points = line, score = components, completion = finished, goal = chosen_finish})
		promising.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score.total > b.score.total)
		if promising.size() > 3: promising.resize(3)
		if score > best_score:
			best_score = score
			best_components = components
			completion = finished
			pts = line
			goal = chosen_finish
		if guided and corridor_variant < 3: break
		if best_score > 0.92 and promising.size() >= 3: break
	var walk_ms := (Time.get_ticks_usec() - started) / 1000.0
	if pts.size() < 2:
		var reason := "нет законченного маршрута: фрагментов %d, отказов финиша %d, завершённых кандидатов %d, отказов полотна %d" % [fragments.size(), finish_refused.size(), completed_candidates, walk_refused]
		if not finish_refused.is_empty(): reason += "; " + "; ".join(finish_refused[0].reasons)
		stats = {accepted = false, reason = reason,
			fragments = fragments, finish_refused = finish_refused, completed_candidates = completed_candidates, finish_plan = finish_plan, walk_refused = walk_refused, walk_reasons = walk_reasons, walk_calls = walk_calls}
		return _project_result([], stats, cuts, speeds, seed)
	if promising.is_empty(): promising.append({points = pts, score = best_components, completion = completion, goal = goal})
	var line := _resample(_smooth(_smooth(pts)), 2.0)
	var d := TrailDefinition.new()
	d.id = "generated_%s_%d" % [style, seed]
	d.title = "%s · сид %d" % [st.title, seed]
	d.kind = "mountain"
	d.width = st.width
	d.surface = RoadSurface.DIRT
	d.earthwork = shaping_amount
	d.auto_bank = lerpf(0.2, 1.0, shaping_amount)
	d.points = line
	d.closed = line[0].distance_to(line[-1]) < 0.01
	d.start_speed = float(options.get("start_speed", 3.0))
	# Линия ходока уже проверена как trial; готовая линия парка — ещё нет.
	if not guided and style == "park":
		var footprint_errors := Validation.footprint(d, inside)
		if not footprint_errors.is_empty():
			stats = {accepted = false, reason = "; ".join(footprint_errors)}
			return _project_result([], stats, cuts, speeds, seed)
	# v3: целевой уклон выравнивания — по самой крутой части самой линии (не ниже пресета): иначе после крутого спуска
	# полотно держит 16 % и уходит в насыпь до 10 м — под пролётом и в узле петли это яма, а не овражек
	var shaping := TrailShaping.preset(d.kind)
	var limited_earthworks: bool = not options.get("use_designed_grade", false) and (not options.has("_source") or not options._source.earthwork_limits.get("unlimited", false))
	if limited_earthworks: shaping.grade_limit = maxf(_steepest(d, ground) * 1.1, shaping.grade_limit)
	d.shaping = shaping
	var base_surface := {}
	var composing_ground := ground
	var base_attempts := []
	if options.has("_source"):
		var base_started := Time.get_ticks_usec()
		# At most three fits (each already has a bounded repair budget), shared by all lines.
		# No rerolls or renewed walk budgets when the first tread fails.
		var template := d.duplicate(true) as TrailDefinition
		var base_budget: Dictionary = options.get("_base_budget", {remaining = 3})
		for candidate: Dictionary in promising:
			if base_budget.remaining <= 0: break
			d = template.duplicate(true) as TrailDefinition
			d.points = _resample(_smooth(_smooth(candidate.points)), 2.0)
			d.closed = d.points[0].distance_to(d.points[-1]) < 0.01
			d.shaping = TrailShaping.preset(d.kind)
			if limited_earthworks: d.shaping.grade_limit = maxf(_steepest(d, ground) * 1.1, d.shaping.grade_limit)
			goal = candidate.goal
			completion = candidate.completion
			best_components = candidate.score
			var check_route := func(route: TrailDefinition) -> PackedStringArray:
				var errors := Validation.footprint(route, inside)
				var final_contract := RouteContract.measure(route.points, shape.route_hint, goal, completion.stop_reason, ground, inside, st.width, completion.kind)
				for reason: String in final_contract.reasons: errors.append(reason)
				return errors
			var fit_started := Time.get_ticks_usec()
			base_budget.remaining -= 1
			base_surface = load("res://scripts/lab/trail_lab_base_surface.gd").fit(options._source, d, check_route)
			var base_heights: Heightfield = base_surface.get("_heights")
			base_surface.erase("_heights")
			base_attempts.append({rank = base_attempts.size(), score = best_components, accepted = base_surface.accepted,
				reason = base_surface.get("reason", ""), ms = (Time.get_ticks_usec() - fit_started) / 1000.0,
				report = base_surface.duplicate(true)})
			if not base_surface.accepted: continue
			composing_ground = func(p: Vector2) -> float: return base_heights.ground_at(p.x, p.y)
			completion = RouteContract.measure(d.points, shape.route_hint, goal, completion.stop_reason, composing_ground, inside, st.width, completion.kind)
			line = d.points
			break
		base_surface.total_ms = (Time.get_ticks_usec() - base_started) / 1000.0
		if not base_surface.accepted:
			return _project_result([], {accepted = false, reason = "базовое полотно: " + base_surface.get("reason", "не принято"), base_surface = base_surface,
				base_attempts = base_attempts, retained_lines = promising.size(), walk_ms = walk_ms, walk_calls = walk_calls, ms = (Time.get_ticks_usec() - started) / 1000.0,
				line_score = best_components, completion = completion, finish_plan = finish_plan, fragments = fragments, finish_refused = finish_refused, completed_candidates = completed_candidates, composition_started = false}, [], speeds, seed)
	var profile := Composition.profile_for(style, skill, shaping_amount)
	# Участок длинного маршрута знает свою долю маршрута и место его пика: замысел один на всю поездку.
	if options.has("arc"):
		profile.arc = options.arc
		profile.peak = options.get("peak", 0.75)
	var band: Vector2 = profile.difficulty
	var level := clampi(int((band.x + band.y) * 0.5 * 4.0), 0, 3)
	# v3: петля и овражки — элементы, пролёты и врезки; составитель ставит своё вокруг них
	var features := {elements = [] as Array[TrailElement], spans = PackedVector3Array(), cuts = [], reserved = [] as Array[Vector2], loop = false, ravines = 0, gaps = 0, decks = 0, ditches = 0}
	var stage := Time.get_ticks_usec()
	if carve.is_valid() and shaping_amount >= 0.65:
		if style == "park" and shaping_amount >= 0.8: _plan_loop(d, ground, level, features, gaps_ok)
		if gaps_ok: _plan_ravines(d, ground, level, features, rng)
		cuts = features.cuts
		carve.call(cuts)
	d.open_spans = features.spans
	var reserved: Array[Vector2] = features.reserved
	var clear_ends := float(options.get("clear_ends", 0.0))
	if clear_ends > 0.0:
		reserved.append(Vector2(-INF, clear_ends))
		reserved.append(Vector2(d.route_length() - clear_ends, INF))
	var soft_at: Callable = options.get("soft", Callable())
	if soft_at.is_valid():
		var along := 0.0
		while along < d.route_length():
			if soft_at.call(d.point_at(along)): reserved.append(Vector2(along - CROSSING_CLEAR, along + CROSSING_CLEAR))
			along += 4.0
	var free := func(e: TrailElement) -> bool:
		for r in reserved:
			# Reserve the actual engineered crossing, not an extra six metres on either side.
			if e.station + e.length * 0.5 > r.x and e.station - e.length * 0.5 < r.y: return false
		return true
	var features_ms := (Time.get_ticks_usec() - stage) / 1000.0
	stage = Time.get_ticks_usec()
	var sequence := {recovery = 0.0, chains = [], refused = {}}
	var fits := func(e: TrailElement) -> bool:
		return free.call(e) and Composition.fits(d, e, composing_ground, sequence, gaps_ok, shaping_amount)
	var composed := TrailComposer.compose(d, profile, seed * 7919 + 13, composing_ground, fits)
	var compose_ms := (Time.get_ticks_usec() - stage) / 1000.0
	var own: Array[TrailElement] = []
	for e: TrailElement in composed.elements:
		if not free.call(e): continue
		# Auto-berms are proposals from the shared composer too; natural mode never bakes them.
		if not TrailElement.places_objects(e.profile) and shaping_amount <= 0.001:
			var why := "автовираж требует большего изменения рельефа"
			sequence.refused[why] = int(sequence.refused.get(why, 0)) + 1
			continue
		own.append(e)
	var all: Array[TrailElement] = own.duplicate()
	all.append_array(features.elements)
	all.sort_custom(func(x: TrailElement, y: TrailElement) -> bool: return x.station < y.station)
	d.elements.assign(all)
	d.sections.assign(composed.sections)
	if carve.is_valid() and shaping_amount >= 0.6 and style in ["flow", "park", "enduro"]:
		_plan_ditches(d, ground, features, rng, 0.25)
		cuts = features.cuts
		carve.call(cuts)
	var errors := d.validate()
	if not errors.is_empty():
		stats = {reason = "определение трассы: " + "; ".join(errors), accepted = false}
		cuts = []
		if carve.is_valid(): carve.call(cuts)
		return _project_result([], stats, cuts, speeds, seed)
	var element_fit := {}
	if options.has("_source") and not options.get("_diagnostic_raw_proposals", false):
		var fitting_started := Time.get_ticks_usec()
		options._require_safe_base = true
		element_fit = load("res://scripts/lab/trail_lab_element_fit.gd").fit(options._source, d, options)
		# Diagnose the bare tread before touching feature recovery. A refused base gets a bounded
		# geometry solve; its existing proposals are remapped and fitted again on the new surface.
		if not element_fit.get("base", {}).get("ride", {}).get("accepted", false):
			var braking: Dictionary = load("res://scripts/lab/trail_lab_braking_repair.gd").solve(options._source, d, options)
			base_surface.braking_repair = braking
			if braking.accepted and braking.get("changed", false):
				element_fit = braking.elements
				completion = RouteContract.measure(d.points, shape.route_hint, goal, completion.stop_reason, ground, inside, st.width, completion.kind)
				var repaired_base := d.duplicate(true) as TrailDefinition
				repaired_base.elements.clear()
				var rebaked: Dictionary = load("res://scripts/lab/trail_lab_base_surface.gd").bake(options._source, repaired_base)
				if not rebaked.errors.is_empty(): return _project_result([], {accepted = false, reason = "; ".join(rebaked.errors)}, [], speeds, seed)
				var repaired_heights: Heightfield = rebaked.heights
				composing_ground = func(p: Vector2) -> float: return repaired_heights.ground_at(p.x, p.y)
				completion = RouteContract.measure(d.points, shape.route_hint, goal, completion.stop_reason, composing_ground, inside, st.width, completion.kind)
				line = d.points
		element_fit.total_ms = (Time.get_ticks_usec() - fitting_started) / 1000.0
		base_surface.ride = element_fit.get("base", {}).get("ride", {})
		if not element_fit.get("accepted", false):
			return _project_result([], {accepted = false, reason = element_fit.get("reason", "подбор элементов не принят"),
				element_fit = element_fit, base_surface = base_surface, completion = completion,
				ms = (Time.get_ticks_usec() - started) / 1000.0}, cuts, speeds, seed)
	var length := d.route_length()
	var drop := float(ground.call(line[0])) - float(ground.call(line[-1]))
	speeds = TrailStandards.profile_from(d, TrailStandards.line_heights(d, ground), level, {}, false)
	var top := 0.0
	var mean := 0.0
	for v in speeds:
		top = maxf(top, v)
		mean += v
	if not speeds.is_empty(): mean /= speeds.size()
	var radii := []
	var s := 2.0
	while s < length - 2.0:
		var k := absf(d.curvature_at(s))
		if k > 1.0 / 40.0: radii.append(1.0 / k)
		s += 2.0
	radii.sort()
	stats = {length = snappedf(length, 1.0), drop = snappedf(drop, 0.1), grade = snappedf(-drop / maxf(length, 1.0) * 100.0, 0.1),
		element_fit = element_fit,
		base_surface = base_surface, base_attempts = base_attempts, retained_lines = promising.size(), composition_started = true,
		completion = completion, finish_plan = finish_plan, fragments = fragments, finish_refused = finish_refused, completed_candidates = completed_candidates,
		line_score = best_components,
		accepted = false, definition_valid = true, difficulty = skill, modification = shaping_amount, mandatory_gaps = gaps_ok, layout = layout if style == "park" else "terrain", sequence_refused = sequence.refused,
		elements = d.elements.size(), refused = composed.get("refused", {}), berms = d.elements.filter(func(e: TrailElement) -> bool: return e.profile in [TrailElement.Profile.BERM, TrailElement.Profile.S_BERM]).size(), speed_top = snappedf(top, 0.1),
		speed_mean = snappedf(mean, 0.1), radius_median = snappedf(float(radii[radii.size() / 2]) if not radii.is_empty() else 0.0, 0.1),
		start = line[0], goal = goal, target_grade = snappedf(grade * 100.0, 0.1), pull = snappedf(shape.pull, 0.01),
		ms = (Time.get_ticks_usec() - started) / 1000.0, title = st.title, tries = tries, walk_refused = walk_refused, walk_calls = walk_calls,
		walk_ms = snappedf(walk_ms, 1.0), features_ms = snappedf(features_ms, 1.0), compose_ms = snappedf(compose_ms, 1.0),
		loop = features.loop, ravines = d.open_spans.size(), ditches = features.ditches,
		gaps = d.elements.filter(func(e: TrailElement) -> bool: return e.profile == TrailElement.Profile.GAP).size(),
		decks = d.elements.filter(func(e: TrailElement) -> bool: return e.profile == TrailElement.Profile.NORTHSHORE).size(),
		jumps = d.elements.filter(func(e: TrailElement) -> bool: return e.profile in [TrailElement.Profile.TABLETOP, TrailElement.Profile.GAP, TrailElement.Profile.DROP]).size()}
	return _project_result([d], stats, cuts, speeds, seed)

## Строка для подписи: стиль, сид, длина, перепад, элементы.
static func label() -> String:
	if stats.is_empty(): return ""
	if stats.has("reason"): return str(stats.reason)
	var extra := PackedStringArray()
	if stats.get("loop", false): extra.append("петля над собой")
	if int(stats.get("ravines", 0)) > 0: extra.append("овражков %d" % stats.ravines)
	if int(stats.get("ditches", 0)) > 0: extra.append("канав %d" % stats.ditches)
	if stats.get("layout", "terrain") != "terrain": extra.append({serpentine = "серпантин", horseshoe = "подкова", oval = "овал"}.get(stats.layout, stats.layout))
	extra.append("сложность %.0f%%, изменение рельефа %.0f%%" % [float(stats.get("difficulty", 0.5)) * 100.0, float(stats.get("modification", 0.5)) * 100.0])
	return "%s · сид %d · %.0f м, %+.0f м (%.1f %%) · элементов %d (прыжков %d, виражей %d)%s · до %.0f м/с · %s" % [stats.title, seed, stats.length, -stats.drop, -stats.grade,
		stats.elements, stats.get("jumps", 0), stats.berms, (" · " + ", ".join(extra)) if not extra.is_empty() else "", stats.speed_top,
		"полотно проверено" if stats.get("accepted", false) else "проверка полотна ожидается"]


## Compatibility entry point for the bounded line-quality score.
static func _score(line: PackedVector2Array, ground: Callable, length: float, grade: float) -> float:
	return float(score_components(line, ground, length, grade).total)

## Six bounded terms. This ranks candidates; hard constraints still gate the finished tread.
static func score_components(line: PackedVector2Array, ground: Callable, length: float, grade: float) -> Dictionary:
	if line.size() < 3: return {total = -INF}
	var run := 0.0
	var straight := 0.0
	var opportunities := 0.0
	var turns := 0
	var previous_sign := 0.0
	var sharp := 0.0
	var work := 0.0
	for k in range(1, line.size()):
		var delta := line[k] - line[k - 1]
		var span := delta.length()
		if span < 0.01: continue
		run += span
		var slope := (float(ground.call(line[k])) - float(ground.call(line[k - 1]))) / span
		var side := delta.orthogonal().normalized() * 2.0
		var cross := absf(float(ground.call(line[k] + side)) - float(ground.call(line[k] - side))) / 4.0
		work += span * (maxf(0.0, cross - 0.12) + maxf(0.0, absf(slope) - 0.16))
		var bend := delta.angle_to(line[k - 1] - line[maxi(0, k - 2)]) if k > 1 else 0.0
		var curvature := absf(bend) / span
		sharp += span * clampf((curvature - 1.0 / 25.0) * 25.0, 0, 1)
		if curvature < 1.0 / 60.0 and slope < 0.03 and slope > -0.18:
			straight += span
		else:
			if straight >= 25.0: opportunities += straight
			straight = 0.0
		if absf(bend) > 0.006:
			if previous_sign != 0 and signf(bend) != previous_sign: turns += 1
			previous_sign = signf(bend)
	if straight >= 25.0: opportunities += straight
	var drop := float(ground.call(line[0])) - float(ground.call(line[-1]))
	var endpoint_grade := 0.0
	for pair in [[0, mini(6, line.size() - 1)], [maxi(0, line.size() - 7), line.size() - 1]]:
		endpoint_grade += absf(float(ground.call(line[pair[0]])) - float(ground.call(line[pair[1]]))) / maxf(1, line[pair[0]].distance_to(line[pair[1]]))
	var result := {length = clampf(run / length, 0, 1), descent = clampf(drop / maxf(1, length * -grade), 0, 1),
		rhythm = clampf(1.0 - absf(turns / maxf(1.0, run / 100.0) - 1.5) / 3.0 - sharp / maxf(1, run), 0, 1),
		element_space = clampf(opportunities / maxf(1, run) / 0.45, 0, 1), earthworks = clampf(1.0 - work / maxf(1, run) / 0.3, 0, 1),
		endpoints = clampf(1.0 - endpoint_grade / 0.4, 0, 1)}
	result.total = result.length * 0.20 + result.descent * 0.15 + result.rhythm * 0.20 + result.element_space * 0.15 + result.earthworks * 0.20 + result.endpoints * 0.10
	return result

## Nearest position plus 32 m lookahead uses every segment of the scout corridor.
## Distance only adds a soft cost: geometry and protected zones can move the line away.
static func hint_guide(hint: PackedVector2Array, p: Vector2) -> Dictionary:
	var best := INF
	var index := 1
	var progress := 0.0
	for k in range(1, hint.size()):
		var ab := hint[k] - hint[k - 1]
		var t := clampf((p - hint[k - 1]).dot(ab) / maxf(0.001, ab.length_squared()), 0, 1)
		var distance := p.distance_squared_to(hint[k - 1] + ab * t)
		if distance < best: best = distance; index = k; progress = t
	var aim := hint[index - 1].lerp(hint[index], progress)
	var remaining := 32.0
	for k in range(index, hint.size()):
		var span := aim.distance_to(hint[k])
		if span >= remaining: aim = aim.move_toward(hint[k], remaining); break
		remaining -= span
		aim = hint[k]
	return {aim = aim, distance = sqrt(best)}

static func _hint_segments(hint: PackedVector2Array, p: Vector2, reach: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var limit := reach * reach
	for k in range(1, hint.size()):
		var ab := hint[k] - hint[k - 1]
		var t := clampf((p - hint[k - 1]).dot(ab) / maxf(0.001, ab.length_squared()), 0, 1)
		if p.distance_squared_to(hint[k - 1] + ab * t) <= limit: out.append(k)
	return out

static func _hint_distance(hint: PackedVector2Array, p: Vector2, segments: PackedInt32Array) -> float:
	var best := INF
	for k in segments:
		var ab := hint[k] - hint[k - 1]
		var t := clampf((p - hint[k - 1]).dot(ab) / maxf(0.001, ab.length_squared()), 0, 1)
		best = minf(best, p.distance_squared_to(hint[k - 1] + ab * t))
	return sqrt(best)

static func _corridor_line(hint: PackedVector2Array, offset: float) -> PackedVector2Array:
	var d := TrailDefinition.new()
	d.points = hint
	var points := PackedVector2Array()
	var count := maxi(1, ceili(d.route_length() / 8))
	for i in count + 1:
		var s := d.route_length() * i / count
		points.append(d.point_at(s) + d.tangent_at(s).orthogonal() * offset * sin(PI * i / count))
	return _resample(_smooth(_smooth(points)), STEP)

## Ходок. heading — начальный курс (NAN — на цель); prior — уже проложенные точки (своя линия до петли: от них тоже
## держится SEP); s0 и v0 — пройденное и скорость на старте. Возвращает точки от start.
## Линия с петлёй (v3): ходок до LOOP_AT доли длины, петля, если ей хватает места, и ходок дальше от её выхода.
const LOOP_AT := Vector2(0.2, 0.45)
const LOOP_TRIES := 6
const LOOP_RETRY := 40.0
static func _walk_with_loop(ground: Callable, inside: Callable, start: Vector2, goal: Vector2, length: float, grade: float, shape: Dictionary, st: Dictionary,
		rng: RandomNumberGenerator, lower: Array, loop: bool) -> PackedVector2Array:
	if not loop: return _walk(ground, inside, start, goal, length, grade, shape, st, rng, lower)
	var first := length * rng.randf_range(LOOP_AT.x, LOOP_AT.y)
	var a := _walk(ground, inside, start, goal, first, grade, shape, st, rng, [])
	if a.size() < 8: return a
	var heading := (a[-1] - a[-2]).angle()
	var m := _loop_points(ground, inside, a, heading)
	# не помещается — ещё LOOP_RETRY м и снова (до LOOP_TRIES раз, пока не дошли до 3/4 длины)
	var tries := 1
	while m.is_empty() and tries < LOOP_TRIES and a.size() * STEP < length * 0.75:
		tries += 1
		var more := _walk(ground, inside, a[-1], goal, a.size() * STEP + LOOP_RETRY, grade, shape, st, rng, lower, heading, a.slice(0, a.size() - 1), a.size() * STEP, 10.0)
		if more.size() < 3: break
		a.append_array(more.slice(1))
		heading = (a[-1] - a[-2]).angle()
		m = _loop_points(ground, inside, a, heading)
	if m.is_empty():
		var tail := _walk(ground, inside, a[-1], goal, length, grade, shape, st, rng, lower, heading, a.slice(0, a.size() - 1), a.size() * STEP, 10.0)
		a.append_array(tail.slice(1))
		return a
	var done := a.duplicate()
	done.append_array(m.points)
	var rest := _walk(ground, inside, done[-1], goal, length, grade, shape, st, rng, lower, m.exit, done.slice(0, done.size() - 1), done.size() * STEP * 0.9, 9.0)
	done.append_array(rest.slice(1))
	return done

## Точки петли от конца линии a с курсом heading: LOOP_LEAD до X, LOOP_LEAD дальше, круг LOOP_R на 270° в сторону, где
## выход ниже, прямая обратно через X и ещё LOOP_LEAD. {points, exit, x} или пусто, если места нет.
static func _loop_points(ground: Callable, inside: Callable, a: PackedVector2Array, heading: float) -> Dictionary:
	var grid := {}
	for k in a.size(): _mark(grid, a[k], k)
	var p := a[-1]
	var f := Vector2.from_angle(heading)
	var x := p + f * LOOP_LEAD
	var best := {}
	var best_drop := -INF
	for side: float in [1.0, -1.0]:
		var pts := PackedVector2Array()
		for k in range(1, int(LOOP_LEAD * 2.0 / 2.0) + 1): pts.append(p + f * (2.0 * k))
		var h := heading
		var q := pts[-1]
		var arc := 1.5 * PI * LOOP_R
		var steps := int(arc / 2.0)
		for k in steps:
			h += side * 2.0 / LOOP_R
			q += Vector2.from_angle(h) * 2.0
			pts.append(q)
		# прямая обратно через X и дальше
		var back := (x - q).normalized()
		var to_x := q.distance_to(x)
		var t := 2.0
		while t < to_x + LOOP_LEAD:
			pts.append(q + back * t)
			t += 2.0
		var ok := true
		for k in pts.size():
			var c := pts[k]
			if not inside.call(c): ok = false
			# не у прежней линии (кроме её последних 40 м — оттуда петля начинается)
			elif _near_own(grid, a.size(), c): ok = false
			if not ok: break
		# петля замыкается: курс после круга смотрит на X (иначе пересечение не поперёк)
		if absf(Vector2.from_angle(h).angle_to(back)) > 0.35: ok = false
		# земля под петлёй почти ровная: тогда полотно идёт по земле, и у пересечения под мостком честный просвет
		if ok:
			var lo := INF
			var hi := -INF
			for c in pts:
				lo = minf(lo, float(ground.call(c)))
				hi = maxf(hi, float(ground.call(c)))
			if hi - lo > LOOP_RELIEF: ok = false
		if not ok: continue
		var drop := float(ground.call(x)) - float(ground.call(pts[-1]))
		if drop > best_drop:
			best_drop = drop
			best = {points = pts, exit = back.angle(), x = x}
	if best.is_empty() or best_drop < 0.3: return {}
	return best

static func _walk(ground: Callable, inside: Callable, start: Vector2, goal: Vector2, length: float, grade: float, shape: Dictionary, st: Dictionary, rng: RandomNumberGenerator, lower: Array = [],
		heading := NAN, prior := PackedVector2Array(), s0 := 0.0, v0 := 3.0) -> PackedVector2Array:
	var trace := {reason = "length_budget", goal = goal}
	shape.trace = trace
	var pts := PackedVector2Array([start])
	var p := start
	var a := (goal - start).angle() if is_nan(heading) else heading
	var hint: PackedVector2Array = shape.get("route_hint", PackedVector2Array())
	if hint.size() > 1 and is_nan(heading): a = (hint_guide(hint, start).aim - start).angle()
	var s := s0
	var ph: Vector2 = shape.phase
	var period: Vector2 = shape.period
	var wander: float = shape.wander
	var cruise: float = st.cruise
	var accel: float = TrailStandards.LAT_MAX * float(st.lat) + 1.5 # наклон полотна трассы добавляет немного
	var v := v0
	var bend := 0.0
	var stuck := 0
	var on_steep := false
	var hint_near := PackedInt32Array()
	var steep_cost: bool = shape.get("steep_cost", false)
	var grid := {}
	# прежние точки: номер по расстоянию от их конца в шагах (отрицательный) — последние OWN_SKIP м не мешают продолжению
	var back := 0.0
	for k in range(prior.size() - 1, -1, -1):
		if k < prior.size() - 1: back += prior[k].distance_to(prior[k + 1])
		_mark(grid, prior[k], -1 - int(back / STEP))
	_mark(grid, start, 0)
	while s < length:
		if p.distance_to(goal) < GOAL_REACH:
			# у цели линия кончается; рано (крутой стиль быстро сходит вниз) — новая цель, самая дальняя из низких
			if hint.size() > 1 or s >= length * 0.6 or lower.is_empty() or s0 > 0.0:
				trace.reason = "reached_finish"
				break
			var far := goal
			for c: Vector3 in lower:
				if Vector2(c.x, c.y).distance_to(p) > far.distance_to(p): far = Vector2(c.x, c.y)
			if far.distance_to(p) < GOAL_REACH * 2.0:
				trace.reason = "reached_finish"
				break
			goal = far
			trace.goal = goal
		# поворот за шаг — не круче радиуса, который седок держит на этой скорости
		var max_turn := STEP / maxf(MIN_RADIUS, v * v / accel)
		var here_y := float(ground.call(p))
		var want := (wander * sin(s / period.x + ph.x) + wander * 0.6 * sin(s / period.y + ph.y)) * STEP
		want += clampf(Vector2.from_angle(a).angle_to(goal - p), -1.0, 1.0) * float(shape.pull) * max_turn
		if hint.size() > 1:
			var guide := hint_guide(hint, p)
			want += clampf(Vector2.from_angle(a).angle_to(guide.aim - p), -1.0, 1.0) * max_turn * 0.65
			# Шаг уходит не дальше STEP: ближайший отрезок для него — из тех, что не дальше ближайшего к p на 2 STEP.
			hint_near = _hint_segments(hint, p, float(guide.distance) + 2.0 * STEP)
		var best := INF
		var best_o := 0.0
		var best_g := 0.0
		# обычный веер; упёрлись — второй, разворотом радиуса HAIRPIN (с шагом вперёд, без излома на месте)
		# на круче (ходок игры) веер шире: линия уходит траверсом, а не падает по склону
		var fan := max_turn if stuck == 0 and not on_steep else STEP / HAIRPIN
		for k in 13:
			var o := -fan + fan * k / 6.0
			var dir := Vector2.from_angle(a + o)
			var next := p + dir * STEP
			if not inside.call(next) or _near_own(grid, pts.size(), next): continue
			var here := float(ground.call(next))
			var g := (here - here_y) / STEP
			var side := Vector2(-dir.y, dir.x)
			# уклон к цели стиля (подъём — дорого), поперечный склон, плавность и «волна» изгибов
			var cost := absf(g - grade) * 60.0 + maxf(0.0, g) * 80.0
			if cost >= best: continue
			var cross := absf(float(ground.call(next + side * 2.0)) - float(ground.call(next - side * 2.0))) / 4.0
			cost += maxf(0.0, cross - 0.25) * 8.0
			cost += absf(o - want) * 1.5
			# Дальше к цене только добавляется: ход, который уже не лучше найденного, дорогих расчётов не стоит
			if cost >= best: continue
			if hint.size() > 1: cost += minf(_hint_distance(hint, next, hint_near) / 32.0, 4.0) * 2.0 * float(shape.get("hint_weight", 1.0))
			if cost >= best: continue
			# Дорогу или брод пересекает коротко, а не идёт вдоль
			var soft: Callable = shape.get("soft", Callable())
			if soft.is_valid() and soft.call(next): cost += SOFT_COST
			# место, где проект не уложил бы полотно мягко: дорого, а не запрещено (нет обхода — линию отрежет проверка проекта)
			var wall: Callable = shape.get("wall", Callable())
			if wall.is_valid() and wall.call(next): cost += WALL_COST
			# стенка уступа или крутой подъём — седок встанет: только если другого хода нет
			if g > CLIMB_MAX: cost += 200.0
			if steep_cost: cost += maxf(0.0, -g - STEEP) * STEEP_COST
			if cost >= best: continue
			# обрыв снаружи поворота: вылет наружу — вниз по откосу (падение 01.11 с 30 м)
			if absf(o) > max_turn * 0.3:
				var outer := side * (-signf(o))
				var fall := (here - float(ground.call(next + outer * 5.0))) / 5.0
				cost += maxf(0.0, fall - CLIFF) * 12.0
				if cost >= best: continue
			# взгляд вперёд — не короче тормозного пути до разворотной скорости: тупик виден заранее
			var look := maxf(LOOK, (v * v - accel * HAIRPIN) / (2.0 * TrailStandards.BRAKE))
			for j in range(1, 5):
				var ahead := p + dir * (STEP + look * j / 4.0)
				if not inside.call(ahead) or _near_own(grid, pts.size(), ahead):
					cost += 30.0 / j - (1.0 if signf(o) == signf(bend) else 0.0)
					break
				if wall.is_valid() and wall.call(ahead):
					cost += WALL_COST / j
					break
			if cost < best:
				best = cost
				best_o = o
				best_g = g
		if best == INF:
			# упёрлись: следующий шаг — веером разворота; не нашлось и его — линия кончилась
			stuck += 1
			if stuck > 1:
				trace.reason = "blocked_or_self_approach"
				break
			continue
		if stuck > 0: v = minf(v, sqrt(accel * HAIRPIN)) # разворот: седок тормозит до разворотной скорости
		stuck = 0
		a += best_o
		bend = best_o
		on_steep = steep_cost and (best_g < -STEEP or best_g > STEEP)
		# скорость «как едут»: тяжесть на уклоне, качение, воздух, педали до крейсерской
		var acc: float = -TrailStandards.G * best_g / sqrt(1.0 + best_g * best_g) - TrailStandards.ROLL - TrailStandards.DRAG * v * v
		if v < cruise: acc += TrailStandards.PEDAL * (1.0 - v / cruise)
		v = clampf(sqrt(maxf(1.0, v * v + 2.0 * acc * STEP)), 3.0, 20.0)
		p += Vector2.from_angle(a) * STEP
		s += STEP
		pts.append(p)
		_mark(grid, p, pts.size() - 1)
	if p.distance_to(goal) <= GOAL_REACH: trace.reason = "reached_finish"
	return pts

## v3: петля над собой на готовой линии — пересечение двух её участков (станции далеко друг от друга). Верхний проход —
## гэп по стандарту, если на его скорости разрыв перекрывает нижнюю трассу, иначе мосток; нижний — в выемке LOOP_CUT.
static func _plan_loop(d: TrailDefinition, ground: Callable, level: int, f: Dictionary, allow_gaps := false) -> void:
	var cross := _self_crossing(d)
	if cross == Vector2.ZERO: return
	var up := cross.x
	var low := cross.y
	var v := TrailStandards.profile_from(d, TrailStandards.line_heights(d, ground), level, {}, false)
	var speed := v[clampi(int(up) - 12, 0, v.size() - 1)]
	var e: TrailElement = null
	var gap := TrailStandards.spec("gap", snappedf(speed, 0.5), level, TrailStandards.element_grade(d, ground, up - 12.0))
	if allow_gaps and not gap.is_empty() and float(gap.gap) >= d.width + 1.5 and speed >= float(gap.get("speed_lo", 0.0)) - 0.5 and speed <= float(gap.get("speed_hi", INF)) + 0.5:
		e = TrailStandards.element(gap, 0.0)
		var start := up - (e.gap_lip() + e.gap * 0.5)
		e.station = start + e.length * 0.5
		f.gaps += 1
	else:
		e = TrailElementLibrary.make(TrailElement.Profile.NORTHSHORE, up, 24.0, LOOP_DECK, 1.0, 3, 0.75)
		e.gap = minf(3.2, d.width - 0.5) # same clearance as TrailDefinition.validate
		f.decks += 1
	f.elements.append(e)
	f.reserved.append(Vector2(e.station - e.length * 0.5, e.station + e.length * 0.5))
	f.reserved.append(Vector2(low - 14.0, low + 14.0)) # нижний проход чистый
	# выемка нижнего прохода: полная у X, на нет за 30 м
	var pts := PackedVector2Array()
	var depth := PackedFloat32Array()
	var s := maxf(0.0, low - 32.0)
	while s <= minf(d.route_length(), low + 32.0):
		pts.append(d.point_at(s))
		depth.append(LOOP_CUT * (1.0 - smoothstep(5.0, 30.0, absf(s - low))))
		s += 4.0
	f.cuts.append({points = pts, depth = depth, half = d.width * 0.5 + 0.4, wall = 0.9})
	f.loop = true

## Самый крутой уклон земли под осью на базе 8 м, м на м.
static func _steepest(d: TrailDefinition, ground: Callable) -> float:
	var worst := 0.0
	var s := 4.0
	var length := d.route_length()
	while s < length - 4.0:
		worst = maxf(worst, absf(float(ground.call(d.point_at(s + 4.0))) - float(ground.call(d.point_at(s - 4.0)))) / 8.0)
		s += 4.0
	return worst

## Three park layouts: contour serpentine, broad horseshoe and closed oval. Fit the chosen region without scaling terrain.
static func _park_points(ground: Callable, inside: Callable, size: float, rng: RandomNumberGenerator, layout := "serpentine", bounds := Rect2()) -> PackedVector2Array:
	if not bounds.has_area(): bounds = Rect2(Vector2.ZERO, Vector2.ONE * size)
	for attempt in 12:
		var c := bounds.get_center() + Vector2(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12)) * bounds.size
		var gx := float(ground.call(c + Vector2(20, 0))) - float(ground.call(c - Vector2(20, 0)))
		var gz := float(ground.call(c + Vector2(0, 20))) - float(ground.call(c - Vector2(0, 20)))
		var down := -Vector2(gx, gz).normalized() if Vector2(gx, gz).length() > 0.4 else Vector2.from_angle(rng.randf() * TAU)
		var along := down.orthogonal() # прямые — вдоль горизонтали, от прямой к прямой — вниз
		var lanes := maxi(3, rng.randi_range(PARK_LANES.x, PARK_LANES.y) - attempt / 4) if layout == "serpentine" else 2
		var lane := rng.randf_range(PARK_LANE.x, PARK_LANE.y) if layout == "serpentine" else rng.randf_range(140.0, 220.0)
		lane = minf(lane, minf(bounds.size.x, bounds.size.y) * 0.65) * (1.0 - 0.05 * attempt)
		var r := rng.randf_range(9.0, 14.0) if layout == "serpentine" else rng.randf_range(24.0, 38.0)
		var start := c - along * lane * 0.5 - down * 2.0 * r * (lanes - 1) * 0.5
		var pts := PackedVector2Array([start])
		var p := start
		var dir := along
		for i in lanes:
			var n := int(lane / 2.0)
			for k in n:
				p += dir * 2.0
				pts.append(p)
			if i == lanes - 1: break
			# полукруг к следующей прямой (вниз по склону)
			var center := p + down * r
			var a0 := (p - center).angle()
			var turn := signf(dir.cross(down)) # в сторону «вниз»
			var steps := int(PI * r / 2.0)
			for k in range(1, steps + 1):
				pts.append(center + Vector2.from_angle(a0 + turn * PI * k / steps) * r)
			p = pts[-1]
			dir = -dir
		if layout == "oval":
			var center := p - down * r
			var a0 := (p - center).angle()
			var turn := signf(dir.cross(-down))
			var steps := int(PI * r / 2.0)
			for k in range(1, steps + 1): pts.append(center + Vector2.from_angle(a0 + turn * PI * k / steps) * r)
			pts[-1] = start
		var ok := true
		for q in pts:
			if not inside.call(q):
				ok = false
				break
		if ok and pts.size() > 40: return pts
	return PackedVector2Array()

## Drainage on the uphill side of an unobstructed sloping straight, with a downhill outlet.
static func _plan_ditches(d: TrailDefinition, ground: Callable, f: Dictionary, rng: RandomNumberGenerator, chance: float) -> void:
	var length := d.route_length()
	var s := 30.0
	while s < length - 50.0:
		var span := rng.randf_range(DITCH_LENGTH.x, DITCH_LENGTH.y)
		if TrailStandards.tightest(d, s, s + span) < 60.0 or rng.randf() > chance:
			s += 12.0
			continue
		var clear := true
		for e in d.elements:
			if e.station + e.length * 0.5 + 12.0 > s and e.station - e.length * 0.5 - 12.0 < s + span: clear = false
		var grade := TrailStandards.grade_of(d, ground, s, s + span)
		var at := d.point_at(s + span * 0.5)
		var across := d.tangent_at(s + span * 0.5).orthogonal()
		var cross := (float(ground.call(at + across * 4.0)) - float(ground.call(at - across * 4.0))) / 8.0
		# Drainage on the uphill side, with a downhill outlet; never a random punishment at a landing.
		if not clear or grade > -0.015 or grade < -0.15 or absf(cross) < 0.04 or absf(cross) > 0.35:
			s += 12.0
			continue
		var side := signf(cross)
		var offset := d.width * 0.5 + DITCH_OFFSET
		var pts := PackedVector2Array()
		var depth := PackedFloat32Array()
		var t := s
		while t <= s + span:
			pts.append(d.point_at(t) + d.tangent_at(t).orthogonal() * side * offset)
			depth.append(0.35 * smoothstep(0.0, 6.0, t - s) * smoothstep(0.0, 6.0, s + span - t))
			t += 4.0
		f.cuts.append({points = pts, depth = depth, half = 0.5, wall = 0.8})
		f.ditches += 1
		s += span + 30.0

## Наибольшее отклонение земли под осью от прямой между концами [from, to], м.
static func _relief(d: TrailDefinition, ground: Callable, from: float, to: float) -> float:
	var a := float(ground.call(d.point_at(from)))
	var b := float(ground.call(d.point_at(to)))
	var worst := 0.0
	var s := from
	while s <= to:
		worst = maxf(worst, absf(float(ground.call(d.point_at(s))) - lerpf(a, b, (s - from) / maxf(to - from, 0.01))))
		s += 2.0
	return worst

## Станции верхнего и нижнего прохода над одним местом (пересечение линии с собой), Vector2.ZERO — нет.
static func _self_crossing(d: TrailDefinition) -> Vector2:
	var grid := {}
	var length := d.route_length()
	var s := 0.0
	while s < length:
		var key := Vector2i((d.point_at(s) / 4.0).floor())
		if not grid.has(key): grid[key] = []
		(grid[key] as Array).append(s)
		s += 1.0
	var best := Vector2.ZERO
	var best_dist := 1.6
	s = 0.0
	while s < length:
		var at := d.point_at(s)
		var key := Vector2i((at / 4.0).floor())
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				for t: float in grid.get(key + Vector2i(ox, oz), []):
					if t - s < 60.0: continue
					var dist := d.point_at(t).distance_to(at)
					if dist < best_dist:
						best_dist = dist
						best = Vector2(s, t)
		s += 1.0
	return best

## v3: овражки поперёк трассы на прямых: гэп по стандарту, если скорость в его окне и уровень позволяет, иначе мосток.
## Под пролётом — открытый пролёт (природная земля, то есть сам овражек).
static func _plan_ravines(d: TrailDefinition, ground: Callable, level: int, f: Dictionary, rng: RandomNumberGenerator) -> void:
	var length := d.route_length()
	var v := TrailStandards.profile_from(d, TrailStandards.line_heights(d, ground), level, {}, false)
	var want := clampi(int(length / RAVINE_EVERY), 1, 6)
	var last := -INF
	var s := 60.0 + rng.randf() * 40.0
	while s < length - 50.0 and f.ravines < want:
		var clear := s - last >= RAVINE_GAP
		for r: Vector2 in f.reserved:
			if s + 20.0 > r.x - 10.0 and s - 20.0 < r.y + 10.0: clear = false
		if not clear or TrailStandards.tightest(d, s - 16.0, s + 16.0) < RAVINE_STRAIGHT:
			s += 6.0
			continue
		# земля вдоль оси на ±16 м гладкая (почти прямая): трасса идёт по ней, без больших насыпей
		if _relief(d, ground, s - 16.0, s + 16.0) > RAVINE_SMOOTH:
			s += 6.0
			continue
		var speed := v[clampi(int(s) - 12, 0, v.size() - 1)]
		var e: TrailElement = null
		var span := Vector3.ZERO
		var floor_half := 0.8
		var gap := TrailStandards.spec("gap", snappedf(speed, 0.5), level, TrailStandards.element_grade(d, ground, s - 12.0))
		if not gap.is_empty() and speed >= float(gap.get("speed_lo", 0.0)) - 0.5 and speed <= float(gap.get("speed_hi", INF)) + 0.5:
			e = TrailStandards.element(gap, 0.0)
			var start := s - (e.gap_lip() + e.gap * 0.5)
			e.station = start + e.length * 0.5
			span = Vector3(start + e.gap_lip() + 0.3, start + e.gap_lip() + e.gap - 0.3, RAVINE_DEPTH)
			floor_half = maxf(0.5, e.gap * 0.5 - 1.2)
			f.gaps += 1
		elif speed >= 4.0:
			e = TrailElementLibrary.make(TrailElement.Profile.NORTHSHORE, s, 14.0, 0.5, 1.0, 3, 0.75)
			e.gap = minf(2.4, d.width - 0.6)
			span = Vector3(s - 2.5, s + 2.5, RAVINE_DEPTH)
			f.decks += 1
		else:
			s += 6.0
			continue
		var lo := e.station - e.length * 0.5
		var hi := e.station + e.length * 0.5
		if lo < 20.0 or hi > length - 20.0:
			s += 6.0
			continue
		f.elements.append(e)
		f.spans.append(span)
		f.reserved.append(Vector2(lo, hi))
		var at := d.point_at(s)
		var n := d.tangent_at(s).orthogonal()
		f.cuts.append({points = PackedVector2Array([at - n * RAVINE_SPAN, at, at + n * RAVINE_SPAN]),
			depth = PackedFloat32Array([RAVINE_DEPTH * 0.7, RAVINE_DEPTH, RAVINE_DEPTH * 0.7]), half = floor_half, wall = 0.8})
		f.ravines += 1
		last = s
		s += RAVINE_GAP

## Индекс точек линии по клеткам SEP: {клетка: [Vector3(x, z, номер)]}.
static func _mark(grid: Dictionary, p: Vector2, index: int) -> void:
	var key := Vector2i((p / SEP).floor())
	if not grid.has(key): grid[key] = []
	(grid[key] as Array).append(Vector3(p.x, p.y, index))

## Своя линия ближе SEP к q, кроме последних OWN_SKIP м.
static func _near_own(grid: Dictionary, count: int, q: Vector2) -> bool:
	var last := count - int(OWN_SKIP / STEP)
	var key := Vector2i((q / SEP).floor())
	for oz in range(-1, 2):
		for ox in range(-1, 2):
			for e: Vector3 in grid.get(key + Vector2i(ox, oz), []):
				if int(e.z) < last and Vector2(e.x, e.y).distance_squared_to(q) < SEP * SEP: return true
	return false

## Чайкин: углы ломаной срезаются, концы остаются на месте.
static func _smooth(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	for i in pts.size() - 1:
		out.append(pts[i].lerp(pts[i + 1], 0.25))
		out.append(pts[i].lerp(pts[i + 1], 0.75))
	out.append(pts[-1])
	return out

static func _resample(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	var carry := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var span := a.distance_to(b)
		var t := step - carry
		while t <= span:
			out.append(a.lerp(b, t / span))
			t += step
		carry = span - (t - step)
	if out[-1].distance_to(pts[-1]) > 0.5: out.append(pts[-1])
	return out
