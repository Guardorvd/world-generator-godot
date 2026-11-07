extends RefCounted
## One survey of a prepared world; one local preparation and final check per candidate.
## Accepted patches ARE the game surface. No synthetic world, repair loop or second bake.
const Search := preload("res://scripts/trails/trail_site_search.gd")
const Layout := preload("res://scripts/trails/trail_layout.gd")
const Validation := preload("res://scripts/trails/trail_validation.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const Potential := preload("res://scripts/trails/trail_potential.gd")
const Character := preload("res://scripts/trails/trail_character.gd")
const Contract := preload("res://scripts/trails/trail_route_contract.gd")
const MARGIN := 12
const EARTHWORKS := {max_cut = 8.0, max_fill = 6.0, modification = 1.0}
const DESIGN_DEPTH := 4.0     # уровень полотна не дальше этого от земли, м: с виражами, откосами и элементами это в пределах EARTHWORKS
## Работы по виду: глубина (насколько полотно может уйти от земли) и самый крутой проектный уклон на 6 м. Круче этого место не
## строят, а обходят: ходок не идёт туда, где проект не может положить полотно мягче.
## Баланс линии и земли: подготовленные трассы (парк, флоу) формируются полностью — виражи, насыпи, выемки; лесные и горные
## маршруты держатся за исходный склон: полотно ближе к земле (глубина, доля проектного изменения `strength`), наклоняется вместе с
## боковым склоном (`side_follow`), короче окно выравнивания (`window`), круче откосы (`batter`), слабее вираж (`bank`).
## Это цели формирования, а не отказы: линия не бракуется за то, что земля осталась круче проекта.
const WORK := {
	park = {depth = 4.5, grade = 0.22}, flow = {depth = 4.5, grade = 0.22},
	downhill = {depth = 2.6, grade = 0.32, shape = {strength = 0.7, side_follow = 0.6, level_window = 5.0, batter = 0.9, bank_max = 0.28, grade_limit = 0.2}},
	enduro = {depth = 2.0, grade = 0.34, shape = {strength = 0.6, side_follow = 0.75, level_window = 4.0, batter = 1.0, bank_max = 0.22, grade_limit = 0.24}},
	tech = {depth = 1.6, grade = 0.38, shape = {strength = 0.5, side_follow = 0.85, level_window = 3.0, batter = 1.1, bank_max = 0.15, grade_limit = 0.3}},
	link = {depth = 1.6, grade = 0.34, shape = {strength = 0.5, side_follow = 0.85, level_window = 3.0, batter = 1.1, bank_max = 0.15, grade_limit = 0.3}}}
const REPLANS := 1            # столько раз линию прокладывают заново в обход крутых мест, прежде чем резать
const WALL_R := 9.0           # крутое место закрыто ходоку в таком радиусе, м
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
const ALTERNATIVES := 2       # вторых линий в сети не больше этого
const ALT_SHIFT := 40.0       # вариант уходит от основной линии в сторону не дальше, м
const ALT_MIN_LENGTH := 400.0 # вариант берёт участки не короче этого, м
const VARIANT_ELEMENTS := 3   # у варианта не меньше стольких элементов
const VARIANT_APART := 12.0   # и в среднем он не ближе этого к основной линии, м
const END_MARGIN := 60.0       # последний участок маршрута кончается не ближе этого к концу коридора, м
const MODE_PARKS := "parks"     # обычная игра: только велопарки (BikePark)
const MODE_NETWORK := "network" # опыты: универсальная сеть маршрутов вдоль коридоров и парк
const PARK_LINES := 7         # не больше стольких самых длинных линий одного трейл-парка
const PARK_GAIN := 6.0        # линий на единицу оценки сверх BikePark.PARK_QUALITY (две в худшем случае): хорошая площадка — больше линий
const PARK_MIN := 250.0       # короче линия парка не нужна, м
const PARK_END := 14.0        # концы линии парка отступают от родительской, м
const DIFFICULTY := [0.25, 0.4, 0.55]
const MODIFICATION := {flow = 0.7, park = 0.7, downhill = 0.6, enduro = 0.5, tech = 0.4}
static var surveys := 0
static var park_quality := 0.0 # оценка площадки последнего парка (диагностика: stats.park.quality)

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
	# Режим: «parks» — только велопарки (обычная игра); «network» — прежняя универсальная сеть маршрутов вдоль коридоров
	# (опыты и тесты: поиск коридоров, маршруты, варианты) вместе с парком. Без ключа — прежняя сеть.
	var parks_only: bool = options.get("mode", MODE_NETWORK) == MODE_PARKS
	var search_stats := {sites = 0, budget_exhausted = false}
	var corridors: Array[Dictionary] = []
	# лес и поляны мира (StageVegetation.cover_at) участвуют в оценке потенциала: лесные траверсы, открытые мягкие склоны
	var cover := func(p: Vector2) -> Vector2: return StageVegetation.cover_at(w, floori(p.x / GameConfig.TILE), floori(p.y / GameConfig.TILE))
	if not parks_only:
		var search := Search.new({size = w.W, seed = w.seed_num, heights = input.heights, water = input.water, input = input},
			{area = area.grow(-MARGIN), probe_budget = budget, corridor = CORRIDOR, rideable = true})
		surveys += 1
		corridors.assign(search.find(w.seed_num))
		search_stats = search.stats
		# Первыми места, которые лучше всего подходят какому-то виду катания (спуск, неровность, вид), и среди них длинные.
		# Границы работы — метры и числа, не время: секундомер только для диагностики и не выбирает канонический мир.
		var mean_work := 0.0
		for c: Dictionary in corridors: mean_work += float(c.probe.build_cost)
		mean_work = maxf(0.001, mean_work / maxi(1, corridors.size()))
		for c: Dictionary in corridors:
			c.probe.points = _downhill(input, c.probe.points)
			c.potential = Potential.assess(input, c.probe.points, cover)
			c.rank = Potential.rank(c.potential, float(c.probe.length), float(c.probe.build_cost) / mean_work)
		corridors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.rank) > float(b.rank) if a.rank != b.rank else a.trail_seed < b.trail_seed)
	var plan := {mode = "terrain_network", state = "none", reason = "нет принятых трасс", routes = [], entries = [], parks = [],
		area = area, stats = {mode = MODE_PARKS if parks_only else MODE_NETWORK, survey = search_stats, input_ms = input_ms, phases_ms = {}, attempted = 0, accepted = 0, rejected = {}, work_m = 0.0, length_m = 0.0, legs = 0, corridors = [], routes_m = []}}
	var ctx := {w = w, h = h, input = input, cover = cover, fords = fords, plan = plan, area = area.grow(-MARGIN - 1), length_target = float(options.get("length_target", LENGTH_TARGET)), work_limit = float(options.get("work_limit", WORK_LIMIT)), early_audit = options.get("early_audit", true), early_pruning = options.get("early_pruning", true), progress = options.get("on_progress", Callable()), styles = {}, legs = [], width = 0.0, walls = []}
	var park_started := Time.get_ticks_msec()
	var park: Array[Dictionary] = []
	if budget > 0: park = _park_candidates(ctx)
	plan.stats.park = {ms = Time.get_ticks_msec() - park_started, lines = park.size(), parks = plan.parks.size(), quality = snappedf(park_quality, 0.01),
		find_ms = snappedf(float(BikePark.last_stats.get("find_ms", 0.0)), 0.1), layout_ms = snappedf(float(BikePark.last_stats.get("layout_ms", 0.0)), 0.1),
		refused = BikePark.last_stats.get("refused", {}), found = BikePark.last_stats.get("found", []), reason = BikePark.last_reason}
	# Парк — сеть: подъезд от ближайшего пути к началу линии парка (магистрали, а если к ней подъехать не вышло — следующей линии)
	# и выезд с конца каждой линии к другим линиям или дорогам, чтобы после спуска можно было ехать дальше и вернуться к началу.
	var park_index := 0
	var entered := {}
	var built := {} # парк -> принятых линий
	for candidate: Dictionary in park:
		plan.stats.attempted += 1
		ctx.route = -100 - park_index
		ctx.park = true # линия парка — не участок маршрута: конец выкатом не требуется
		var line := _leg(ctx, candidate.points, candidate.region, candidate.style, candidate.title, candidate.trail_seed, candidate.difficulty, false)
		if line != null:
			built[candidate.park] = int(built.get(candidate.park, 0)) + 1
			ctx.width = line.width
			var tail := (line.points[-1] - line.points[-2]).normalized()
			if not entered.has(candidate.park):
				var entry := _entry(ctx, line.points[0], ctx.route, line.title, candidate.difficulty, candidate.trail_seed + 97)
				if entry != null or _road_distance(ctx.input, line.points[0]) < LINK_MIN: entered[candidate.park] = true # или и так у дороги
			_exit(ctx, line.points[-1], tail, ctx.route, line.title, candidate.difficulty, candidate.trail_seed + 191)
		park_index += 1
	ctx.erase("route")
	ctx.erase("park")
	for info: Dictionary in plan.parks:
		info.lines = int(built.get(info.index, 0))
		info.access = entered.has(info.index)
	var route_index := 0
	for corridor: Dictionary in corridors:
		if plan.stats.length_m >= ctx.length_target or plan.stats.work_m >= ctx.work_limit: break
		plan.stats.attempted += 1
		plan.stats.corridors.append(roundi(corridor.probe.length))
		route_index = _route(ctx, corridor.probe.points, corridor.trail_seed, route_index)
	ctx.erase("route")
	if not parks_only: _alternatives(ctx)
	if not plan.routes.is_empty(): _districts(ctx)
	if not plan.routes.is_empty():
		RoadSurface.rebuild_map(w)
		plan.state = "found"
		plan.reason = ""
		plan.definition = plan.routes[0]
	elif parks_only:
		plan.reason = BikePark.last_reason if not BikePark.last_reason.is_empty() else "парки не принялись"
	plan.stats.budget_exhausted = search_stats.budget_exhausted or plan.stats.attempted < corridors.size() + park.size()
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
	var cursor := _pick_start(ctx.input, guide, 0.0)
	var start := guide.point_at(cursor)
	var tangent := Vector2.ZERO
	var fails := 0
	var skips := 0 # сколько мест подряд пропущено: каждый следующий пропуск дальше
	var leg_index := 0
	var route_length := 0.0
	var previous := "" # вид прошлого участка: соседние участки сохраняют характер
	ctx.start_speed = 3.0
	ctx.width = 0.0
	route_index += 1
	ctx.route = route_index
	# Характер маршрута (темп, извилистость, насыщенность, смещение сложности): свой у каждого, одинаковый на всех его участках
	ctx.persona = Character.persona(hash([ctx.w.seed_num, route_index, seed_value]))
	var title := "Маршрут %d" % route_index
	var difficulty: float = DIFFICULTY[route_index % DIFFICULTY.size()]
	var entry := _entry(ctx, start, route_index, title, difficulty, seed_value + 97)
	if entry != null:
		start = entry.points[-1]
		tangent = (entry.points[-1] - entry.points[-2]).normalized()
		route_length += entry.route_length()
		ctx.width = entry.width
		previous = "flow"
	while cursor < total - MIN_LEG and plan.stats.work_m < ctx.work_limit and plan.stats.length_m < ctx.length_target:
		var hint := PackedVector2Array([start])
		if tangent != Vector2.ZERO: hint.append(start + tangent * LEG_LEAD)
		var s := cursor + LEG_LEAD
		# Коридор кончается там, где что-то мешает (вода, край области, круча): последний участок цели не берёт самый конец,
		# а кончается раньше, где есть выкат.
		var reach := total - END_MARGIN if total - cursor > MIN_LEG + END_MARGIN else total
		# Трудное место: после первой неудачи участок короче, чтобы закончить маршрут до него хорошим выкатом, а не терять всё
		var leg_len := LEG if fails < 2 else (LEG * 0.45 if fails == 2 else MIN_LEG * 1.6)
		var last := minf(reach, cursor + leg_len)
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
		var assessed := Potential.assess(ctx.input, hint, ctx.cover)
		var style := Potential.choose(assessed, ctx.styles, previous)
		if style.is_empty(): style = Layout.ORDER[(route_index + leg_index) % Layout.ORDER.size()]
		var entry_speed: float = ctx.start_speed
		var global := _leg(ctx, hint, Rect2i(lo, hi - lo), style, title, seed_value + leg_index * 7 + fails * 131, difficulty, true)
		if global == null:
			fails += 1
			if fails < 4: continue
			# Место не проходится: пропустить его; если до него уже есть маршрут, дальше идёт новый.
			fails = 0
			skips += 1
			if route_length > 0.0: route_length += _exit(ctx, start, tangent, route_index, title, difficulty, seed_value + 191)
			cursor += LEG_SKIP * minf(skips, 3.0)
			if cursor >= total: break
			cursor = _pick_start(ctx.input, guide, cursor)
			start = guide.point_at(cursor)
			tangent = Vector2.ZERO
			ctx.start_speed = 3.0
			previous = ""
			ctx.width = 0.0
			if route_length > 0.0:
				plan.stats.routes_m.append(roundi(route_length))
				route_length = 0.0
				route_index += 1
				ctx.persona = Character.persona(hash([ctx.w.seed_num, route_index, seed_value]))
				title = "Маршрут %d" % route_index
				difficulty = DIFFICULTY[route_index % DIFFICULTY.size()]
				ctx.route = route_index
				var reentry := _entry(ctx, start, route_index, title, difficulty, seed_value + 97 + route_index)
				if reentry != null:
					start = reentry.points[-1]
					tangent = (reentry.points[-1] - reentry.points[-2]).normalized()
					route_length += reentry.route_length()
					ctx.width = reentry.width
					previous = "flow"
			continue
		fails = 0
		skips = 0
		leg_index += 1
		previous = style
		ctx.width = global.width # весь маршрут одной ширины: переход между участками без ступеньки
		ctx.legs.append({hint = hint, global = global, style = style, assessed = assessed, arc = ctx.arc, peak = ctx.peak, speed = entry_speed, title = title, difficulty = difficulty})
		route_length += global.route_length()
		var end: Vector2 = global.points[-1]
		start = end
		tangent = (global.points[-1] - global.points[-2]).normalized()
		# Вперёд по коридору на столько, сколько участок прошёл вдоль своей части.
		cursor += maxf(MIN_LEG, RouteContract.project(hint, end).x)
	if route_length > 0.0:
		route_length += _exit(ctx, start, tangent, route_index, title, difficulty, seed_value + 191)
		plan.stats.routes_m.append(roundi(route_length))
	return route_index

## Связи маршрута с сетью. Маршрут не висит в лесу: его начало подходит к дороге или к другому маршруту (подъезд), его конец
## выходит к ним (выезд), и после спуска можно ехать дальше. Это обычные участки того же маршрута (общее название, тот же
## построитель и приёмка), но спокойные: стиль flow, земля почти не меняется (WORK.link), конец не требует выката — он
## стыкуется. Ближайшая цель — любой существующий путь мира (дорога, тропа, принятый маршрут), кроме своего маршрута, не дальше
## LINK_MAX; ближе LINK_MIN маршрут и так касается пути. Не вышло построить — маршрут остаётся как был.
const LINK_MAX := 420.0       # дальше цель связи не ищется, м
const LINK_MIN := 60.0        # ближе цель — маршрут уже у пути, связь не нужна, м
const LINK_WALL := 0.5        # по прямой круче этого уклона на 12 м — не связь, м/м
const LINK_LEG := 40.0        # связь короче этого не берётся, м
const LINK_OVER := 6.0        # линия выхода заходит за ось цели, чтобы пересечь её, а не остановиться рядом, м

## Ближайшая достижимая точка существующего пути (кроме маршрута `route`) к `from`: {point, distance} или пусто. Путь, к которому
## по прямой лежит вода или стена, пропускается: связь на него не построить, а неудачная попытка стоит секунд.
static func _link_target(ctx: Dictionary, from: Vector2, route: int) -> Dictionary:
	var candidates: Array[Dictionary] = []
	for path: Dictionary in ctx.input.existing_paths:
		if int(path.get("route", -2)) == route: continue
		var pts: PackedVector2Array = path.points
		var best := LINK_MAX
		var found := Vector2.INF
		for k in range(1, pts.size()):
			var a := pts[k - 1]
			var delta := pts[k] - a
			var q := a + delta * clampf((from - a).dot(delta) / maxf(0.001, delta.length_squared()), 0.0, 1.0)
			var distance := from.distance_to(q)
			if distance < best:
				best = distance
				found = q
		if found != Vector2.INF: candidates.append({point = found, distance = best})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance < b.distance)
	for candidate: Dictionary in candidates:
		if float(candidate.distance) < LINK_MIN or _link_clear(ctx.input, from, candidate.point): return candidate
	return {}

## По прямой от `from` к `to` нет воды и запретных клеток (не больше одной точки через 12 м) и нет стены круче LINK_WALL.
static func _link_clear(input: GI, from: Vector2, to: Vector2) -> bool:
	var steps := maxi(2, ceili(from.distance_to(to) / 12.0))
	var bad := 0
	var previous := input.natural_ground(from)
	for k in range(1, steps + 1):
		var p := from.lerp(to, float(k) / steps)
		var y := input.natural_ground(p)
		if input.blocked(p) or absf(y - previous) / 12.0 > LINK_WALL: bad += 1
		previous = y
	return bad <= 1

## Линия связи по подсказке `hint` (мировые метры): участок маршрута со своей областью, как у обычного участка.
static func _link(ctx: Dictionary, hint: PackedVector2Array, title: String, difficulty: float, seed_value: int) -> TrailDefinition:
	var box := Rect2(hint[0], Vector2.ZERO)
	for p in hint: box = box.expand(p)
	var lo := Vector2i((box.position / GameConfig.TILE).floor()) - Vector2i.ONE * LEG_PAD
	var hi := Vector2i((box.end / GameConfig.TILE).ceil()) + Vector2i.ONE * LEG_PAD
	var saved_arc = ctx.get("arc")
	ctx.link = true
	ctx.min_leg = LINK_LEG
	ctx.arc = Vector2(0.0, 1.0)
	var result := _leg(ctx, hint, Rect2i(lo, hi - lo), "flow", title, seed_value, minf(difficulty, 0.3), true)
	ctx.erase("link")
	ctx.erase("min_leg")
	if saved_arc != null: ctx.arc = saved_arc
	return result

## Выезд: от конца `from` (курс `tangent`) к ближайшему пути. Добавленная длина, м (0 — связи нет).
static func _exit(ctx: Dictionary, from: Vector2, tangent: Vector2, route: int, title: String, difficulty: float, seed_value: int) -> float:
	if tangent == Vector2.ZERO: return 0.0
	var target := _link_target(ctx, from, route)
	if target.is_empty() or float(target.distance) < LINK_MIN: return 0.0
	var aim: Vector2 = target.point - from
	var direction := aim.normalized()
	var hint := PackedVector2Array([from, from + tangent * LEG_LEAD])
	var s := LEG_LEAD
	while s < aim.length() - 8.0:
		hint.append(from + direction * s)
		s += 16.0
	hint.append(target.point + direction * LINK_OVER)
	var link := _link(ctx, hint, title, difficulty, seed_value)
	_count(ctx.plan, "links", "exit" if link != null else "exit_failed")
	return link.route_length() if link != null else 0.0

## Подъезд: от ближайшего пути к началу маршрута `start`. Определение связи (конец у `start`) или null.
static func _entry(ctx: Dictionary, start: Vector2, route: int, title: String, difficulty: float, seed_value: int) -> TrailDefinition:
	var target := _link_target(ctx, start, route)
	if target.is_empty() or float(target.distance) < LINK_MIN: return null
	var from: Vector2 = target.point
	var aim := start - from
	var direction := aim.normalized()
	var hint := PackedVector2Array([from, from + direction * LEG_LEAD])
	var s := LEG_LEAD + 16.0
	while s < aim.length() - 8.0:
		hint.append(from + direction * s)
		s += 16.0
	hint.append(start)
	ctx.start_speed = 3.0
	var link := _link(ctx, hint, title, difficulty, seed_value)
	_count(ctx.plan, "links", "entry" if link != null else "entry_failed")
	return link

## Районы. Маршруты, которые касаются друг друга (конец одного у линии другого) или начинаются рядом, образуют район; он
## называется по ближайшему названному месту мира, и название стоит перед названием каждого его маршрута: на карте видно, где
## район, какие в нём маршруты и откуда въезд. plan.districts: {name, routes (названия), length, center, entry (мировые метры)}.
const DISTRICT_TOUCH := 40.0   # конец маршрута у линии другого не дальше этого — они связаны, м
const DISTRICT_NEAR := 260.0   # концы двух маршрутов не дальше этого — один район, м
const DISTRICT_NAME_R := 2500.0 # названное место дальше этого районного имени не даёт, м
static func _districts(ctx: Dictionary) -> void:
	var plan: Dictionary = ctx.plan
	var groups: Array[Dictionary] = []
	var by_base := {}
	for r: Dictionary in plan.routes:
		var base := String(r.title).get_slice(" · вариант", 0)
		if not by_base.has(base):
			by_base[base] = groups.size()
			groups.append({base = base, points = PackedVector2Array(), ends = PackedVector2Array(), length = 0.0, first = r.points[0]})
		var group: Dictionary = groups[by_base[base]]
		var pts: PackedVector2Array = r.points
		group.points = group.points + pts
		group.ends = group.ends + PackedVector2Array([pts[0], pts[-1]])
		group.length += _polyline_length(pts)
	var parent := PackedInt32Array()
	for i in groups.size(): parent.append(i)
	for a in groups.size():
		for b in range(a + 1, groups.size()):
			if _joined(groups[a], groups[b]): _union(parent, a, b)
	var members := {}
	for i in groups.size():
		var root := _find(parent, i)
		if not members.has(root): members[root] = []
		(members[root] as Array).append(i)
	var places: Array = (ctx.w._places().places as Dictionary).values()
	var districts: Array[Dictionary] = []
	var names_used := {}
	for root: int in members:
		var center := Vector2.ZERO
		var count := 0
		var length := 0.0
		var titles: Array[String] = []
		var entry := Vector2.INF
		for i: int in members[root]:
			var group: Dictionary = groups[i]
			for p: Vector2 in group.ends:
				center += p
				count += 1
			length += group.length
			titles.append(group.base)
			if entry == Vector2.INF: entry = group.first
		center /= maxi(1, count)
		var best := DISTRICT_NAME_R
		var name := ""
		for place: Dictionary in places:
			if String(place.name).is_empty(): continue
			var distance := (Vector2(place.x, place.y) * GameConfig.TILE).distance_to(center)
			if distance < best:
				best = distance
				name = String(place.name)
		var label := "Район «%s»" % name if not name.is_empty() else "Район %d" % (districts.size() + 1)
		if names_used.has(label): label += " %d" % (int(names_used[label]) + 1)
		names_used[label] = int(names_used.get(label, 0)) + 1
		districts.append({name = label, routes = titles, length = length, center = center, entry = entry})
	# название района — перед названием каждого его маршрута (в плане и в записях)
	var rename := {}
	for district: Dictionary in districts:
		for base: String in district.routes: rename[base] = "%s · %s" % [district.name, base]
	for list: Array in [plan.routes, plan.entries.map(func(e: Dictionary) -> Dictionary: return e.route)]:
		for r: Dictionary in list:
			var base := String(r.title).get_slice(" · вариант", 0)
			if rename.has(base): r.title = String(rename[base]) + String(r.title).substr(base.length())
	plan.districts = districts

static func _polyline_length(pts: PackedVector2Array) -> float:
	var total := 0.0
	for k in range(1, pts.size()): total += pts[k - 1].distance_to(pts[k])
	return total

static func _joined(a: Dictionary, b: Dictionary) -> bool:
	for end: Vector2 in a.ends:
		for other: Vector2 in b.ends:
			if end.distance_to(other) <= DISTRICT_NEAR: return true
		for p: Vector2 in b.points:
			if end.distance_to(p) <= DISTRICT_TOUCH: return true
	for end: Vector2 in b.ends:
		for p: Vector2 in a.points:
			if end.distance_to(p) <= DISTRICT_TOUCH: return true
	return false

static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i: i = parent[i]
	return i

static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	parent[_find(parent, b)] = _find(parent, a)

## Вторые линии там, где местность даёт две интересные: на участке принятого маршрута, у которого другой вид почти так же
## хорош, прокладывается вариант другого вида. Он начинается и кончается в тех же точках, а посередине уходит в сторону на
## ALT_SHIFT м: ответвление, которое возвращается на маршрут (соединение в обоих концах, у стыков элементов нет).
## Не больше ALTERNATIVES, лучшие места первыми; вариант, который не прошёл, просто не строится.
static func _alternatives(ctx: Dictionary) -> void:
	var plan: Dictionary = ctx.plan
	var picks: Array[Dictionary] = []
	for leg: Dictionary in ctx.legs:
		if leg.global.route_length() < ALT_MIN_LENGTH: continue
		var alt := Potential.alternative(leg.assessed, leg.style)
		if not alt.is_empty(): picks.append({leg = leg, style = alt.style, value = alt.value})
	picks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.value > b.value)
	var made := 0
	for pick: Dictionary in picks:
		if made >= ALTERNATIVES or plan.stats.work_m >= ctx.work_limit: break
		var leg: Dictionary = pick.leg
		var main: TrailDefinition = leg.global
		var line := PackedVector2Array()
		var s := 0.0
		while s < main.route_length():
			line.append(main.point_at(s))
			s += 16.0
		line.append(main.points[-1])
		var hint := _around(ctx.input, line, ALT_SHIFT)
		var box := Rect2(hint[0], Vector2.ZERO)
		for p in hint: box = box.expand(p)
		var lo := Vector2i((box.position / GameConfig.TILE).floor()) - Vector2i.ONE * LEG_PAD
		var hi := Vector2i((box.end / GameConfig.TILE).ceil()) + Vector2i.ONE * LEG_PAD
		ctx.start_speed = leg.speed
		ctx.arc = leg.arc
		ctx.peak = leg.peak
		ctx.width = main.width
		ctx.reference = main
		plan.stats.attempted += 1
		var alternative := _leg(ctx, hint, Rect2i(lo, hi - lo), pick.style, leg.title + " · вариант", plan.stats.accepted * 31 + 7, leg.difficulty, true)
		if alternative != null: made += 1
	ctx.erase("reference")
	plan.stats.alternatives = made

## Подсказка `line`, выгнутая в сторону на `shift` м посередине и сходящаяся с ней в концах. Сторона — та, где земля у
## середины ближе по высоте к самой линии (меньше подъёма).
static func _around(input: GI, line: PackedVector2Array, shift: float) -> PackedVector2Array:
	var n := line.size()
	if n < 5: return line
	var mid := line[n / 2]
	var side := (line[n / 2 + 1] - line[n / 2 - 1]).normalized().orthogonal()
	var y := input.natural_ground(mid)
	var sign := 1.0 if absf(input.natural_ground(mid + side * shift) - y) <= absf(input.natural_ground(mid - side * shift) - y) else -1.0
	var out := line.duplicate()
	for k in range(2, n - 1):
		var across := (line[k + 1] - line[k - 1]).normalized().orthogonal()
		out[k] = line[k] + across * shift * sign * sin(PI * k / (n - 1))
	return out

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

## Старт маршрута: ближайшая к `cursor` точка коридора (в пределах START_SEARCH м вперёд), где есть удобная площадка —
## свободное место позади и впереди, ровный спуск, без бокового уклона. Нет такой — прежняя точка.
const START_SEARCH := 56.0
static func _pick_start(input: GI, guide: TrailDefinition, cursor: float) -> float:
	var ground := func(p: Vector2) -> float: return input.natural_ground(p)
	var free := func(p: Vector2) -> bool: return not input.blocked(p)
	var s := cursor
	while s <= minf(cursor + START_SEARCH, guide.route_length() - MIN_LEG):
		if Contract.start_area(guide.point_at(s), guide.tangent_at(s), ground, free, 4.0).suitable: return s
		s += 8.0
	return cursor

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
	var surface := site.surface()
	var ground := func(p: Vector2) -> float: return surface.ground_at(p.x, p.y)
	var blocked := func(p: Vector2) -> bool: return local_input.blocked(p)
	phase = Time.get_ticks_usec()
	var hint := PackedVector2Array()
	for p: Vector2 in world_hint: hint.append(p - site.origin_m())
	var settings := {bounds = Rect2(Vector2(region.position - site.origin) * GameConfig.TILE, Vector2(region.size) * GameConfig.TILE).grow(-WORK_EDGE),
		difficulty = difficulty, modification = MODIFICATION[style], mandatory_gaps = true, keep_start = true, strict_finish = ctx.get("reference") == null and not ctx.get("link", false) and not ctx.get("park", false), persona = ctx.get("persona", Character.persona(seed_value)), width = ctx.get("width", 0.0) if is_leg else 0.0, arc = ctx.get("arc", Vector2(0.0, 1.0)) if is_leg else Vector2(0.0, 1.0), peak = ctx.get("peak", 0.75), clear_ends = LEG_CLEAR if is_leg else 0.0, start_speed = float(ctx.get("start_speed", 3.0)) if is_leg else 3.0,
		# лесистость и поляны под линией (StageVegetation.cover_at): горные и природные характеры меняют по ним настроение участков
		cover = func(p: Vector2) -> Vector2: return StageVegetation.cover_at(w, floori(p.x / GameConfig.TILE) + site.origin.x, floori(p.y / GameConfig.TILE) + site.origin.y),
		soft = func(p: Vector2) -> bool:
			var cell := Vector2i((p / GameConfig.TILE).floor()) + site.origin
			return (cell.x >= 0 and cell.y >= 0 and cell.x < w.W and cell.y < w.H and fords[cell.y * w.W + cell.x] != 0) or local_input.near_path(p)}
	# Места, где проект не уложил бы полотно мягко (ctx.walls, мировые метры): ходок их обходит, как запретные клетки.
	var walls: Array[Vector2] = []
	var near := Rect2(site.origin_m(), Vector2(site.size) * GameConfig.TILE).grow(WALL_R)
	for c: Vector2 in ctx.walls:
		if near.has_point(c): walls.append(c - site.origin_m())
	settings.wall = func(p: Vector2) -> bool:
		for c: Vector2 in walls:
			if p.distance_squared_to(c) < WALL_R * WALL_R: return true
		return false
	var line := func(route_hint: PackedVector2Array, walk: bool) -> Dictionary:
		var options_line := settings.duplicate()
		options_line.route_hint = route_hint
		options_line.walk = walk
		options_line.exact_line = not walk
		return Layout.generate(ground, Vector2(site.size) * GameConfig.TILE, seed_value, style, blocked, options_line)
	var result: Dictionary = line.call(hint, is_leg)
	_time(plan, "layout", phase)
	_count(plan, "layout", "calls")
	if result.stats.has("fit_ms"):
		_count(plan, "layout", "fitted")
		plan.stats.phases_ms.layout_fit_ms = float(plan.stats.phases_ms.get("layout_fit_ms", 0.0)) + float(result.stats.fit_ms)
	for key: String in ["walk_ms", "compose_ms"]:
		plan.stats.phases_ms["layout_" + key] = float(plan.stats.phases_ms.get("layout_" + key, 0.0)) + float(result.stats.get(key, 0.0))
	# Почему составитель и правила места отказали элементам: сводка по всей сети (диагностика, мира не касается).
	for key: String in ["refused", "sequence_refused"]:
		var why_counts: Dictionary = plan.stats.get("element_refusals", {})
		for why: String in result.stats.get(key, {}): why_counts[why] = int(why_counts.get(why, 0)) + int(result.stats[key][why])
		plan.stats.element_refusals = why_counts
	if result.routes.is_empty():
		_refuse(plan, result.stats.get("reason", "линия не построена"))
		return null
	for e: TrailElement in result.routes[0].elements: _count(plan, "proposed", TrailElementLibrary.title(e.profile))
	var replan := func() -> Dictionary: return line.call(hint, is_leg)
	var admitted := _admit(ctx, site, result.routes[0], title, line, replan if is_leg else Callable(), walls, blocked, local_input, WORK["link" if ctx.get("link", false) else style], float(ctx.get("min_leg", MIN_LEG)) if is_leg else MIN_LINE, is_leg)
	if admitted.is_empty(): return null
	ctx.start_speed = admitted.exit_speed
	var d: TrailDefinition = admitted.d
	var global := StageTrailPlan.to_world(d, site)
	var variant_error := _variant_error(ctx, d, global)
	if not variant_error.is_empty():
		_refuse(plan, variant_error)
		return null
	var errors := TrailBuilder.append_routes(w, [global], false)
	if not errors.is_empty():
		_refuse(plan, errors[0])
		return null
	publish(h, site, admitted.prepared.heights)
	ctx.input.existing_paths.append({points = global.points, half_width = global.width * 0.5, route = ctx.get("route", -1)})
	plan.routes.append(StageTrailPlan.pack(global))
	plan.entries.append({rect = context, style = style, route = StageTrailPlan.pack(global),
		length = global.route_length(), elements = global.elements.size(), earthworks = h.road_refinement.trail_shaping[global.id]})
	plan.stats.accepted += 1
	plan.stats.legs += 1
	plan.stats.length_m += global.route_length()
	ctx.styles[style] = float(ctx.styles.get(style, 0.0)) + global.route_length()
	return global

## Вариант (ctx.reference — основная линия) принимается, если у него есть содержание и он заметно отличается от основной.
## Обычные участки (reference нет) не проверяются.
static func _variant_error(ctx: Dictionary, d: TrailDefinition, global: TrailDefinition) -> String:
	var reference: TrailDefinition = ctx.get("reference")
	if reference == null: return ""
	if d.elements.size() < VARIANT_ELEMENTS: return "вариант без содержания"
	var apart := 0.0
	var count := 0
	var s := 0.0
	while s < global.route_length():
		apart += reference.nearest(global.point_at(s)).z
		count += 1
		s += 8.0
	if count == 0 or apart / count < VARIANT_APART: return "вариант сливается с основной линией"
	return ""

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

## Расстояние от точки до ближайшего пути мира (дороги, тропы; принятые линии сети не считаются), м; INF — путей нет.
static func _road_distance(input: GI, from: Vector2) -> float:
	var best := INF
	for path: Dictionary in input.existing_paths:
		if path.has("route"): continue
		var pts: PackedVector2Array = path.points
		for k in range(1, pts.size()):
			best = minf(best, from.distance_squared_to(Geometry2D.get_closest_point_to_segment(from, pts[k - 1], pts[k])))
	return sqrt(best) if best < INF else INF

## Трейл-парки: площадки и линии BikePark (от нуля до трёх, по оценке простора, склона, перепада и доступа от дорог) как
## готовые кандидаты сети. Только прокладка и кандидаты: элементы, формирование и приёмка — общие. Описание каждого парка
## — в ctx.plan.parks. Концы отступают от родительской линии: сеть держит пути раздельно.
static func _park_candidates(ctx: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var w: WorldData = ctx.w
	var h: Heightfield = ctx.h
	var input: GI = ctx.input
	var rect: Rect2i = ctx.area
	park_quality = 0.0
	var parks := BikePark.build_all(w, h, rect, "park", func(p: Vector2) -> float: return _road_distance(input, p))
	var line_index := 0
	for index in parks.size():
		var park := parks[index]
		park_quality = maxf(park_quality, park.quality)
		# чем лучше склон, простор и перепад высот, тем больше линий
		var wanted := clampi(roundi(2.0 + (park.quality - BikePark.PARK_QUALITY) * PARK_GAIN), 2, PARK_LINES)
		var order_of: Array[int] = []
		order_of.assign(range(park.routes.size()))
		order_of.sort_custom(func(a: int, b: int) -> bool: return park.routes[a].route_length() > park.routes[b].route_length())
		var picked: Array[int] = []
		for n: int in order_of:
			if park.routes[n].route_length() - PARK_END * 2.0 >= PARK_MIN: picked.append(n)
			if picked.size() >= wanted: break
		# Сложность по крутизне линии: самая пологая треть — лёгкая, круче — средняя и сложная
		var steepness: Array[float] = []
		for n: int in picked:
			var d: TrailDefinition = park.routes[n]
			steepness.append(absf(h.ground_at(d.points[0].x, d.points[0].y) - h.ground_at(d.points[-1].x, d.points[-1].y)) / maxf(1.0, d.route_length()))
		var order := range(picked.size())
		order.sort_custom(func(a: int, b: int) -> bool: return steepness[a] < steepness[b])
		var tier := {}
		for rank in order.size(): tier[order[rank]] = mini(2, rank * 3 / maxi(1, order.size()))
		var title := "Велопарк %s" % park.park_name
		var length := 0.0
		for slot in picked.size():
			var d: TrailDefinition = park.routes[picked[slot]]
			var total := d.route_length()
			length += total
			var points := PackedVector2Array()
			var s := PARK_END
			while s < total - PARK_END:
				points.append(d.point_at(s))
				s += 4.0
			var box := Rect2(points[0], Vector2.ZERO)
			for p in points: box = box.expand(p)
			var lo := Vector2i((box.position / GameConfig.TILE).floor()) - Vector2i.ONE * 8
			var hi := Vector2i((box.end / GameConfig.TILE).ceil()) + Vector2i.ONE * 8
			out.append({park = index, region = Rect2i(lo, hi - lo).intersection(rect), title = "%s · %s" % [title, d.title], trail_seed = posmod(hash([w.seed_num, d.id]), 99999) + 1,
				points = points, difficulty = DIFFICULTY[tier[slot]], style = park.styles[picked[slot]]})
			line_index += 1
		ctx.plan.parks.append({index = index, name = park.park_name, character = park.character, center = park.center, radius = snappedf(park.radius, 1.0),
			extent = snappedf(park.extent, 1.0), quality = snappedf(park.quality, 0.01), access_m = snappedf(park.access, 1.0), candidates = picked.size(),
			length = snappedf(length, 1.0), lines = 0, access = false})
	return out
## Сборка и проверка одной линии. Один плохой участок не выбрасывает всю длинную линию: элемент, не прошедший проверку,
## снимается, а по месту, где не годится само полотно, линия обрезается до большего годного куска. Не больше ADMIT_PASSES
## сборок на кандидата. {d, prepared} или пусто (причина — в статистике). Лабораторный ремонт основания здесь не вызывается.
static func _admit(ctx: Dictionary, site: TrailSite, first: TrailDefinition, title: String, line: Callable, replan: Callable, walls: Array[Vector2], blocked: Callable, local_input: GI, work: Dictionary, min_line := 0.0, prefix_only := false) -> Dictionary:
	var plan: Dictionary = ctx.plan
	var early_audit: bool = ctx.early_audit
	var replans := 0
	var pins := Callable() # закрепления участка: для всех линий участка одни, считаются один раз
	var reach_box := TrailDefinition.new()
	reach_box.points = PackedVector2Array([Vector2.ZERO, Vector2(site.size) * GameConfig.TILE])
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
		d.shaping.depth_cap = float(work.depth)
		for key: String in work.get("shape", {}): d.shaping.set(key, work.shape[key])
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
		var bad := INF # станция, где не годится само полотно
		var steep := {} # проект полотна круче допустимого: {at, over}
		var full := removed.is_empty() or not same_line
		# Проект полотна, до сборки: линия, которую профиль не может положить мягче допустимого, не собирается. Сначала на
		# поверхности участка (дёшево), затем на готовом полотне самого пути (оно чуть другое) — до земляных работ.
		if full:
			var pins_started := Time.get_ticks_usec()
			pins = pins if pins.is_valid() else TrailBuilder.pins(site.surface(), [reach_box] as Array[TrailDefinition])
			_time(plan, "pins", pins_started)
			steep = TrailBuilder.design(site.surface(), d, float(work.grade), pins)
			_time(plan, "design", phase)
			_count(plan, "admit", "design")
			if steep.grade <= 1.0: steep = {}
			else: _count(plan, "admit", "steep_before_prepare")
		if steep.is_empty():
			phase = Time.get_ticks_usec()
			if not full:
				prepared = site.rebake(prepared, d, removed, limits)
			else:
				builds += 1
				_count(plan, "admit", "prepare")
				limits = {keep_bake = true, earthwork_source = site.surface(), earthwork_input = local_input} if early_audit else {keep_bake = true}
				limits.guard = func(prepared_heights: Heightfield) -> PackedStringArray:
					var design := TrailBuilder.design(prepared_heights, d, float(work.grade))
					if design.grade <= 1.0: return PackedStringArray()
					limits.steep = design
					return PackedStringArray(["проектный уклон выше допустимого"])
				var routes: Array[TrailDefinition] = [d]
				prepared = site.prepare(routes, true, limits)
				if limits.has("steep"):
					_count(plan, "admit", "steep_after_surface")
					steep = limits.steep
					builds -= 1 # отказ до запекания почти ничего не стоит; число таких отказов ограничено REPLANS и обрезкой
			removed = []
			_time(plan, "prepare", phase)
			plan.stats.work_m += d.route_length() * (0.1 if not steep.is_empty() else 0.3 if not prepared.errors.is_empty() else float(limits.get("again_share", 1.0))) # отказ при запекании прерывает работу рано
			for key: String in prepared.timings:
				plan.stats.phases_ms["prepare_" + key] = float(plan.stats.phases_ms.get("prepare_" + key, 0.0)) + maxf(0, prepared.timings[key])
		if not steep.is_empty():
			plan.stats.steep = int(plan.stats.get("steep", 0)) + 1
			reason = "проектный уклон выше допустимого"
			if replan.is_valid() and replans < REPLANS:
				replans += 1
				for c: Vector2 in steep.over:
					walls.append(c)
					ctx.walls.append(c + site.origin_m())
				plan.stats.replans = int(plan.stats.get("replans", 0)) + 1
				var again: Dictionary = replan.call()
				if not again.routes.is_empty():
					d = again.routes[0]
					removed = []
					continue
			bad = steep.at
		elif not prepared.errors.is_empty():
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
					if int(issue.element) >= 0: drop[int(issue.element)] = issue.reason
					elif not is_finite(bad): bad = issue.worst_station
				if checked.issues.is_empty() and reason.contains(" у "): bad = reason.get_slice(" у ", 1).to_float()
				if not drop.is_empty():
					var kept: Array[TrailElement] = []
					for k in d.elements.size():
						if drop.has(k):
							removed.append(d.elements[k])
							_count(plan, "dropped", "%s: %s" % [TrailElementLibrary.title(d.elements[k].profile), drop[k]])
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

## Счётчик в plan.stats (диагностика): сколько элементов какого вида предложено составителем и снято проверкой.
static func _count(plan: Dictionary, group: String, key: String) -> void:
	var counts: Dictionary = plan.stats.get(group, {})
	counts[key] = int(counts.get(key, 0)) + 1
	plan.stats[group] = counts

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
