class_name TrailAccess
extends RefCounted
## Доступ трассы к дорожной сети (шаг 2): подход от дороги к старту и выход от финиша обратно к дороге. Работает на участке
## (TrailSite) поверх уже найденной линии и тем же построителем (TrailRouter с точкой примыкания): второго графа и
## независимого построителя поверхности нет. Геометрическая близость к дороге соединением не считается:
## - подход и выход — настоящие определения пути, которые начинаются или кончаются ТОЧНО на вершине существующего пути
##   (joins) — той же клетки и высоты, значит общий узел RoadNavigation;
## - они встречаются с трассой в той же точке, что старт или финиш. Поворот в стыке и направление примыкания — не
##   причина отказа: острый угол формирует рельеф (общая сборка), а ранжирование точек примыкания предпочитает пологие;
## - комплект «подход + трасса + выход» собирается одной сборкой TrailSite.prepare, и verify() проверяет на готовой
##   поверхности, что каждая линия измерена целиком и стыки непрерывны (скачок опоры у трассы и у дороги).
## Новых мостов и туннелей нет: сооружения, вода и границы запрещены построителем, как для любой линии.
## Точки примыкания (joins) выбирает вызывающий — только вершины дорожной сети, достижимой из дома.
## Бюджет общий: раскрытия берутся из остатка операции (left.budget), время — до left.deadline; затраты копятся в stats.

const ANGLE_REF := 90.0      # ранжирование точек примыкания: поворот на столько градусов удваивает «цену» расстояния
const RADIUS := 4.0          # желаемый радиус поворота подхода и выхода, м (соединения; у трассы свой)
const NEAREST := TrailRouter.MIN_SPAN + 2.0 # ближе к концу линии точку примыкания не взять: подход не построить, м
const LEAD := 8.0            # подход ведётся к точке на продолжении трассы за стартом (выход — от точки за финишем), м:
                             # последний участок соосен трассе, поворот уходит внутрь подхода плавной кривой, а не в стык
const UTURN_ANGLE := 100.0   # дорога «за спиной» конца трассы (угол больше): подход/выход разворачивается дугой
const UTURN_R := 5.0         # радиус этой дуги, м
const LENGTH_MAX := 140.0    # самый длинный подход или выход, м
const ATTEMPTS := 3          # точек примыкания, которые пробуются на один конец
const SPREAD := 20.0         # пробуемые точки примыкания отличаются хотя бы на столько, м
const CLEARANCE := 4.0       # подход не ближе к трассе вне зоны у конца: ширина + это, м
const END_ZONE := 14.0       # зона у стыка, где подход рядом с трассой — это сам стык, м
const JUMP_MAX := 0.1        # скачок опоры в стыке подхода и трассы, м
const ROAD_JUMP_MAX := 0.15  # и расхождение с поверхностью дороги в точке примыкания, м
const IDS := {inbound = "start_trail_in", outbound = "start_trail_out"}
const TITLES := {inbound = "Подход к трассе", outbound = "Выход с трассы"}

var joins: Array = []        ## точки примыкания, локальные метры участка
var stats := {expansions = 0, searches = 0, repairs = 0, ms = 0.0}
var last := {}               ## последний подобранный комплект: inbound / outbound → {join, length, turn}
var notes := PackedStringArray()
var _taken := {expansions = 0, searches = 0, repairs = 0, ms = 0.0}


## Затраты с прошлого вызова: Picker вносит их в общую работу операции.
func take_stats() -> Dictionary:
	var out := {}
	for key: String in stats:
		out[key] = stats[key] - _taken[key]
		_taken[key] = stats[key]
	return out


## Подход и выход для линии r (старт и финиш заданы её определением). {ok, extras, short, why}
func plan(r: TrailRouter, site: TrailSite, left: Dictionary) -> Dictionary:
	var trail := r.definition
	var budget: int = left.budget
	var entering := _connect(r, site, trail, true, left, budget)
	if not entering.ok:
		return entering
	budget -= entering.spent
	var leaving := _connect(r, site, trail, false, left, budget)
	if not leaving.ok:
		return leaving
	# подход и выход не должны идти друг по другу
	var a: TrailDefinition = entering.definition
	var b: TrailDefinition = leaving.definition
	for p in a.points:
		if p.distance_to(trail.points[0]) > END_ZONE and b.nearest(p, trail.width + CLEARANCE).z < trail.width + CLEARANCE and p.distance_to(trail.points[-1]) > END_ZONE:
			return _fail("подход и выход сходятся", "подход и выход идут рядом друг с другом у (%.0f, %.0f)" % [p.x, p.y])
	last = {inbound = entering.info, outbound = leaving.info}
	return {ok = true, extras = [a, b], short = "", why = ""}


func _fail(short: String, why: String) -> Dictionary:
	return {ok = false, extras = [], short = short, why = why}


## Пригодность точки примыкания j для конца линии end с направлением движения tangent: чем меньше, тем лучше; INF — только
## технически (ближе NEAREST или дальше LENGTH_MAX / 1.15). Сторона «против трассы» — дороже, но не запрещена.
static func rank_join(j: Vector2, end: Vector2, tangent: Vector2, entering: bool) -> float:
	var dist := j.distance_to(end)
	if dist < NEAREST or dist > LENGTH_MAX / 1.15:
		return INF
	var heading := (end - j) if entering else (j - end)
	var angle := absf(rad_to_deg(heading.angle_to(tangent)))
	return dist * (1.0 + angle / ANGLE_REF)


## Подход (entering) или выход к одной из точек примыкания; пробуется до ATTEMPTS разнесённых точек по близости.
func _connect(r: TrailRouter, site: TrailSite, trail: TrailDefinition, entering: bool, left: Dictionary, budget: int) -> Dictionary:
	var end := trail.points[0] if entering else trail.points[-1]
	var title: String = TITLES.inbound if entering else TITLES.outbound
	# Точки примыкания по пригодности: ближе и с той стороны, куда трасса смотрит (подход идёт навстречу движению по
	# трассе, выход — по нему) — лучше; дальше и «против шерсти» — хуже
	var tangent := trail.tangent_at(2.0) if entering else trail.tangent_at(trail.route_length() - 2.0)
	var scored: Array = []
	for j: Vector2 in joins:
		var rank := rank_join(j, end, tangent, entering)
		if is_finite(rank):
			# и с меньшим перепадом: подход круче цели уклона дороже (предпочтение, не запрет)
			var rise := absf(r.mean_at(j) - r.mean_at(end)) / maxf(1.0, j.distance_to(end))
			rank *= 1.0 + maxf(0.0, rise - r.request.grade) / r.request.grade
			scored.append({at = j, rank = rank})
	scored.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.rank < y.rank)
	var chosen: Array[Vector2] = []
	for entry: Dictionary in scored:
		var apart := true
		for c in chosen:
			if entry.at.distance_to(c) < SPREAD: apart = false
		if apart: chosen.append(entry.at)
		if chosen.size() >= ATTEMPTS: break
	if chosen.is_empty():
		return _fail("%s: нет дороги рядом" % title.to_lower(), "%s: нет точки примыкания к дорожной сети дома от %.0f до %.0f м от конца линии" % [title, NEAREST, LENGTH_MAX / 1.15])
	var spent := 0
	var reasons := PackedStringArray()
	for n in chosen.size():
		var share: int = (budget - spent) / (chosen.size() - n)
		var time_left := int(left.deadline) - Time.get_ticks_msec() if int(left.deadline) > 0 else int(r.request.timeout_ms)
		if share <= 0 or time_left <= 0:
			reasons.append("бюджет раскрытий или время исчерпаны")
			break
		var sub := TrailRouter.new()
		var shape := _joint_shape(r, end, tangent, entering, chosen[n])
		var lead: Vector2 = shape.lead
		var rq := {start = chosen[n] if entering else lead, finish = lead if entering else chosen[n], width = r.request.width,
			grade = r.request.grade, min_radius = minf(RADIUS, r.request.min_radius),
			budget = share, repairs = 0, builds = 1, timeout_ms = time_left, cancel = r.request.get("cancel", Callable()), joins = [chosen[n]]}
		var started := Time.get_ticks_usec()
		var ok := sub.setup(site, rq) and sub.begin() and sub.candidate()
		stats.expansions += sub.stats.expansions
		stats.searches += sub.stats.searches
		stats.ms += (Time.get_ticks_usec() - started) / 1000.0
		spent += sub.stats.expansions
		if not ok:
			reasons.append("(%.0f, %.0f): %s" % [chosen[n].x, chosen[n].y, sub.reason])
			continue
		var d := sub.definition.duplicate(true) as TrailDefinition
		d.id = IDS.inbound if entering else IDS.outbound
		d.title = title
		var points := d.points
		points[0 if entering else points.size() - 1] = chosen[n]  # точно на вершине пути
		var anchor: Vector2 = shape.anchor
		if lead != anchor:
			var eased := _ease(points, anchor, lead, entering, sub)
			if not eased.is_empty(): points = eased
		points[points.size() - 1 if entering else 0] = anchor
		var arc: PackedVector2Array = shape.arc
		if not arc.is_empty(): # разворот у конца трассы: дуга от старта/финиша до anchor
			if entering:
				var back := _reversed(arc)
				points.append_array(back.slice(1))
			else:
				var joined := arc.duplicate()
				joined.append_array(points.slice(1))
				points = joined
		points[points.size() - 1 if entering else 0] = end         # точно в старте или финише трассы
		d.points = points
		var why := _acceptable(d, trail, entering)
		if not why.is_empty():
			reasons.append("(%.0f, %.0f): %s" % [chosen[n].x, chosen[n].y, why])
			continue
		var turn := _turn(d, trail, entering)
		return {ok = true, definition = d, spent = spent, short = "", why = "",
			info = {join = chosen[n], length = d.route_length(), turn = turn}}
	return {ok = false, extras = [], spent = spent, short = "%s: не построен" % title.to_lower(),
		why = "%s не построен: %s" % [title, "; ".join(reasons)]}


## Форма стыка с трассой для точки примыкания join. Подход и выход отходят от конца трассы по её оси (forward — от
## трассы наружу): точка join в этой стороне — ведущая точка lead на LEAD м по оси; join «за спиной» (угол больше
## UTURN_ANGLE) — сначала разворот дугой радиуса UTURN_R в сторону join (arc от конца до anchor), потом lead по новому
## направлению. Так поворот всегда формируется кривой с радиусом, а не углом в стыке. Заблокированная форма упрощается.
## {anchor, lead, arc}
static func _joint_shape(r: TrailRouter, end: Vector2, tangent: Vector2, entering: bool, join: Vector2) -> Dictionary:
	var forward := -tangent if entering else tangent
	var plain := {anchor = end, lead = end, arc = PackedVector2Array()}
	var straight := {anchor = end, lead = end + forward * LEAD, arc = PackedVector2Array()}
	if r.blocked(straight.lead) != TrailRouter.Block.FREE or straight.lead.distance_to(join) < NEAREST: straight = plain
	if absf(rad_to_deg(forward.angle_to(join - end))) <= UTURN_ANGLE: return straight
	var side := signf(forward.cross(join - end))
	if side == 0.0: side = 1.0
	var normal := Vector2(-forward.y, forward.x) * side
	var center := end + normal * UTURN_R
	var arc := PackedVector2Array([end])
	var steps := ceili(PI * UTURN_R / TrailRouter.SAMPLE)
	for k in range(1, steps + 1):
		var p := center + (end - center).rotated(side * PI * k / steps)
		if r.blocked(p) != TrailRouter.Block.FREE: return straight
		arc.append(p)
	var anchor := arc[-1]
	var lead := anchor - forward * LEAD
	if r.blocked(lead) != TrailRouter.Block.FREE or lead.distance_to(join) < NEAREST: return straight
	return {anchor = anchor, lead = lead, arc = arc}


## Подход до точки lead на продолжении трассы → плавная кривая (квадратичная Безье с вершиной в lead) в конец линии end:
## её касательная в end совпадает с направлением трассы, а в начале — с направлением подхода. Выход — зеркально.
## Пусто, если кривая задевает запретное место (тогда остаётся ломаная к lead и прямая в end).
static func _ease(points: PackedVector2Array, end: Vector2, lead: Vector2, entering: bool, sub: TrailRouter) -> PackedVector2Array:
	var d := TrailDefinition.new()
	d.points = points if entering else _reversed(points) # от дороги к lead
	var length := d.route_length()
	var from := maxf(0.0, length - LEAD)
	var a := d.point_at(from)
	var out := PackedVector2Array()
	for p in d.points:
		if d.nearest(p).x < from - 0.5: out.append(p)
	out.append(a)
	var steps := maxi(4, ceili((a.distance_to(lead) + lead.distance_to(end)) / TrailRouter.SAMPLE))
	for k in range(1, steps + 1):
		var t := float(k) / steps
		var p := a.lerp(lead, t).lerp(lead.lerp(end, t), t)
		if sub.blocked(p) != TrailRouter.Block.FREE and p.distance_to(end) > 0.5: return PackedVector2Array()
		if p.distance_to(out[-1]) > 0.3: out.append(p)
	if out[-1].distance_to(end) > 0.01: out.append(end)
	return out if entering else _reversed(out)


static func _reversed(points: PackedVector2Array) -> PackedVector2Array:
	var out := points.duplicate()
	out.reverse()
	return out


## Поворот в стыке подхода (entering) или выхода с трассой, градусов.
static func _turn(d: TrailDefinition, trail: TrailDefinition, entering: bool) -> float:
	var length := d.route_length()
	var inbound := d.tangent_at(length - 2.0) if entering else trail.tangent_at(trail.route_length() - 2.0)
	var outbound := trail.tangent_at(2.0) if entering else d.tangent_at(2.0)
	return absf(rad_to_deg(inbound.angle_to(outbound)))


func _acceptable(d: TrailDefinition, trail: TrailDefinition, entering: bool) -> String:
	if d.route_length() > LENGTH_MAX:
		return "длиннее %.0f м (%.0f м)" % [LENGTH_MAX, d.route_length()]
	if not d.validate().is_empty():
		return "определение не проходит проверку: " + "; ".join(d.validate())
	var joint := trail.points[0] if entering else trail.points[-1]
	for p in d.points:
		if p.distance_to(joint) > END_ZONE and trail.nearest(p, trail.width + CLEARANCE).z < trail.width + CLEARANCE:
			return "идёт вплотную к трассе у (%.0f, %.0f)" % [p.x, p.y]
	return ""


## После общей сборки комплекта: каждая линия измерена на готовой поверхности целиком, стыки без скачка. Уклон —
## фактическое значение в отчёте (в `last`), не порог. {ok, short, why}
func verify(r: TrailRouter, site: TrailSite) -> Dictionary:
	var h: Heightfield = r.prepared.heights
	for entering in [true, false]:
		var d: TrailDefinition = r.extras[0 if entering else 1]
		var s := TrailSurvey.measure(h, d, r.request.grade)
		var name: String = TITLES.inbound if entering else TITLES.outbound
		if not s.complete():
			return {ok = false, short = "%s: поверхность не измерена" % name.to_lower(), why = "%s: готовая поверхность измерена не целиком (%s)" % [
				name, "; ".join(s.errors) if not s.errors.is_empty() else "%d неизмеренных участков" % s.unmeasured.size()]}
		var info: Dictionary = last.get("inbound" if entering else "outbound", {})
		info.peak_grade = s.peak_grade
		# стык с трассой: опора подхода в конце и трассы в начале (выхода в начале и трассы в конце)
		var mine := s.support[-1] if entering else s.support[0]
		var theirs: float = r.survey.support[0] if entering else r.survey.support[-1]
		if absf(mine - theirs) > JUMP_MAX:
			return {ok = false, short = "%s: скачок в стыке с трассой" % name.to_lower(), why = "%s: опора в стыке с трассой расходится на %.2f м (допуск %.2f)" % [name, absf(mine - theirs), JUMP_MAX]}
		# примыкание к дороге: опора в точке пути равна поверхности дороги
		var join: Vector2 = last.get("inbound" if entering else "outbound", {}).get("join", d.points[0 if entering else -1])
		var road := site.surface().surface_at(join.x, join.y, INF)
		var here: float = s.support[0] if entering else s.support[-1]
		if is_finite(road) and absf(here - road) > ROAD_JUMP_MAX:
			return {ok = false, short = "%s: скачок у дороги" % name.to_lower(), why = "%s: у точки примыкания опора расходится с дорогой на %.2f м (допуск %.2f)" % [name, absf(here - road), ROAD_JUMP_MAX]}
	return {ok = true, short = "", why = ""}
