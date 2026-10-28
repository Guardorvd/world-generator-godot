class_name TrailPicker
extends RefCounted
## Trail Lab: автоматический выбор места для одной велотрассы на сохранённой площадке. Сам ничего не строит:
## выбирает старт и финиш, а линию ищет, оценивает и собирает TrailRouter (тот же, что ручное построение).
##
## 1. Данные пригодности площадки (запреты, усреднённая земля, связные области) — TrailRouter.setup, один раз на
##    площадку и ширину, дальше из памяти.
## 2. Точки-кандидаты — узлы решётки через SPACING м (пространственно разнесены, не все клетки): свободные, с выходом
##    не круче требования. Пары отсекаются дёшево: финиш ниже старта на min_drop и больше, разные области, прямая длиннее
##    length_max или слишком коротка для length_min, перепад не уложить в длину при пределе уклона.
## 3. Ранжирование — простое и объяснимое: отклонение ожидаемой длины (прямая × DETOUR) от середины диапазона плюс
##    превышение среднего уклона прямой над 80 % предела (там понадобится обход), в долях. Из отсортированных пар берутся
##    не больше `pairs`, отличающиеся от уже взятых хотя бы на SPREAD м в сумме по старту и финишу.
## 4. Пары по порядку: TrailRouter.candidate (поиск + оценка без запекания) → оценка длины и перепада → полная сборка
##    (TrailRouter.complete) → фактические длина и перепад на готовой поверхности. При первом успехе — стоп.
## Доступ к дорожной сети (необязательно, шаг 2): request.near — точки примыкания к дороге (локальные метры), request.access —
## TrailAccess. Точки старта и финиша дальше near_max от ближайшей точки примыкания отсекаются, а ранжирование предпочитает
## близкие. Для каждой пары, прошедшей оценку, access.plan строит подход к старту и выход от финиша (общий бюджет, одна
## общая сборка), а после сборки access.verify проверяет стыки; нет доступа — пара отклонена, берётся следующая.
## Бюджеты (пары, раскрытия, исправления, полные сборки, таймаут) — на всю операцию: каждой паре выдаётся только
## остаток. Требования не ослабляются. Случайности нет: одинаковый запрос даёт одинаковый результат.

const SPACING := 20.0       # шаг решётки точек-кандидатов, м
const DETOUR := 1.15        # ожидаемая длина линии — прямая × это
const SPREAD := 40.0        # пары отличаются хотя бы на столько (старт + финиш), м
const DEFAULTS := {width = 3.0, grade = 0.15, max_cut = 1.2, max_fill = 1.0, min_radius = 6.0,
	length_min = 60.0, length_max = 140.0, min_drop = 4.0,
	pairs = 6, budget = 60000, repairs = 6, builds = 2, timeout_ms = 30000}
## Два заранее заданных класса трасс — одинаковые для любой площадки (поверх DEFAULTS; лимиты общие):
## descent — спуск от 4 м (DEFAULTS), rolling — равнинная, финиш не выше старта, перепад не требуется.
const PROFILES := {descent = {}, rolling = {min_drop = 0.0}}
const PROFILE_TITLES := {descent = "спуск", rolling = "равнинная"}

var request := {}
var accepted := false
var reason := ""
## Итог операции: found — трасса построена; no_pairs — ни одна пара не прошла дешёвый отсев (места нет при этих
## требованиях на решётке точек); refused_all — искались все пары, прошедшие отсев, и все отклонены по требованиям;
## budget — остановлено лимитом (пары, раскрытия, сборки, исправления, таймаут), пока оставались неиспробованные
## пары или пара не была проверена до конца: невозможность НЕ доказана.
var verdict := ""
var router: TrailRouter      ## линия выбранной пары (accepted) или null
var start := Vector2.ZERO
var finish := Vector2.ZERO
var tried: Array[Dictionary] = []   ## пары, которые искались: {start, finish, score, outcome, reason, ...}
var rejected := {}                  ## причина -> число (отсев точек и пар, исход поиска)
var stats := {points = 0, points_kept = 0, pairs_considered = 0, pairs_kept = 0, pairs_searched = 0, searches = 0,
	expansions = 0, repairs = 0, builds = 0, access_expansions = 0, access_searches = 0, access_ms = 0.0, prepare_ms = 0.0, prepare_reused = false, prepare_cost_ms = 0.0,
	select_ms = 0.0, search_ms = 0.0, build_ms = 0.0, total_ms = 0.0}


static func find(site: TrailSite, req := {}) -> TrailPicker:
	var p := TrailPicker.new()
	var started := Time.get_ticks_usec()
	p._run(site, req)
	p.stats.total_ms = (Time.get_ticks_usec() - started) / 1000.0
	p.verdict = p._verdict()
	return p


## Пояснение к verdict для отчёта.
const VERDICTS := {found = "трасса найдена", no_pairs = "места нет: ни одна пара не прошла отсев",
	refused_all = "все пары после отсева испробованы и отклонены по требованиям",
	budget = "остановлено бюджетом: невозможность не доказана", input = "ошибка запроса или площадки"}


func _verdict() -> String:
	if accepted: return "found"
	if stats.points == 0: return "input"
	if stats.pairs_kept == 0: return "no_pairs"
	# пара, остановленная лимитом (раскрытия, сборки, исправления, таймаут), не проверена до конца
	for t: Dictionary in tried:
		if t.outcome == "budget" or (t.outcome == "refused" and _limited(t.reason)): return "budget"
	if rejected.has("таймаут операции") or rejected.has("общий бюджет раскрытий исчерпан"): return "budget"
	return "refused_all" if stats.pairs_searched >= stats.pairs_kept else "budget"


static func _limited(why: String) -> bool:
	return why.contains("бюджет") or why.contains("таймаут") or why.contains("исчерпаны попытки") or why.contains("попытки исправления исчерпаны") or why.contains("лимит") or why.contains("сборок")


func _reject(why: String) -> void:
	rejected[why] = rejected.get(why, 0) + 1


func _refuse(why: String) -> void:
	reason = why
	accepted = false


func _run(site: TrailSite, req: Dictionary) -> void:
	request = DEFAULTS.duplicate()
	request.merge(req, true)
	if request.length_min < 4.0 * request.min_radius or request.length_max < request.length_min or request.min_drop < 0.0:
		_refuse("диапазон длины: от %.0f м (4 радиуса) и не меньше минимума; перепад не отрицательный" % (4.0 * request.min_radius))
		return
	var deadline := Time.get_ticks_msec() + int(request.timeout_ms)
	var base := _router_request()
	var probe := TrailRouter.new()
	if not probe.setup(site, base):
		_refuse(probe.reason)
		return
	stats.prepare_ms = probe.stats.prepare_ms
	stats.prepare_reused = probe.stats.prepare_reused
	stats.prepare_cost_ms = probe.stats.prepare_cost_ms
	var started := Time.get_ticks_usec()
	var pairs := _select(probe)
	stats.select_ms = (Time.get_ticks_usec() - started) / 1000.0
	if pairs.is_empty():
		_refuse("на площадке нет пар старт/финиш, проходящих отсев: %s" % _rejections())
		return
	for n in pairs.size():
		var pair: Dictionary = pairs[n]
		if Time.get_ticks_msec() > deadline:
			_reject("таймаут операции")
			break
		# Исправления — равной долей остатка на оставшиеся пары: одна безнадёжная пара не забирает их у остальных
		var repairs_left: int = request.repairs - stats.repairs
		var left := {budget = request.budget - stats.expansions, repairs = ceili(float(repairs_left) / (pairs.size() - n)), builds = request.builds - stats.builds}
		if left.budget <= 0:
			_reject("общий бюджет раскрытий исчерпан")
			break
		stats.pairs_searched += 1
		var r := TrailRouter.new()
		var rq := base.duplicate()
		rq.merge({start = pair.start, finish = pair.finish, budget = left.budget, repairs = left.repairs, builds = maxi(1, left.builds),
			timeout_ms = maxi(1, deadline - Time.get_ticks_msec())}, true)
		var entry := pair.duplicate()
		var outcome := _try(r, site, rq, left.builds, deadline)
		_take_access_stats()
		stats.searches += r.stats.searches
		stats.expansions += r.stats.expansions
		stats.repairs += r.stats.repairs
		stats.builds += r.stats.builds
		stats.search_ms += r.stats.search_ms + r.stats.geometry_ms + r.stats.estimate_ms
		stats.build_ms += r.stats.build_ms
		entry.merge({outcome = outcome.kind, reason = outcome.why, expansions = r.stats.expansions, builds = r.stats.builds}, true)
		tried.append(entry)
		if outcome.kind == "ok":
			accepted = true
			router = r
			start = pair.start
			finish = pair.finish
			return
		_reject(outcome.short)
	_refuse("ни одна из %d пар не дала трассу с выполненными требованиями: %s" % [stats.pairs_searched, _rejections()])


func _router_request() -> Dictionary:
	var out := {}
	for key: String in ["width", "grade", "max_cut", "max_fill", "min_radius"]: out[key] = request[key]
	return out


## Одна пара: кандидат → оценка длины и перепада → (если остались сборки) полная сборка → факт. {kind, short, why}
func _try(r: TrailRouter, site: TrailSite, rq: Dictionary, builds_left: int, deadline := 0) -> Dictionary:
	if not r.setup(site, rq) or not r.begin():
		return {kind = "refused", short = _short(r), why = r.reason}
	if not r.candidate():
		return {kind = "refused", short = _short(r), why = r.reason}
	var e: Dictionary = r.stats.estimate
	if e.length < request.length_min or e.length > request.length_max:
		return {kind = "estimate", short = "длина вне диапазона (оценка)", why = "оценка длины %.0f м вне %.0f–%.0f м" % [e.length, request.length_min, request.length_max]}
	if e.drop < request.min_drop:
		return {kind = "estimate", short = "перепад меньше требуемого (оценка)", why = "оценка перепада %.1f м < %.1f м" % [e.drop, request.min_drop]}
	if builds_left <= 0:
		return {kind = "budget", short = "лимит полных сборок исчерпан", why = "кандидат прошёл оценку, но полных сборок не осталось (%d)" % request.builds}
	var access: Variant = request.get("access")
	if access != null:
		var left := {budget = request.budget - stats.expansions - r.stats.expansions, deadline = deadline}
		var plan: Dictionary = access.plan(r, site, left)
		if not plan.ok:
			return {kind = "access", short = plan.short, why = plan.why}
		r.extras.assign(plan.extras)
	if not r.complete():
		return {kind = "built", short = "не прошла проверку готовой поверхности", why = r.reason if not r.reason.is_empty() else r._failed_checks()}
	var length := r.definition.route_length()
	var drop: float = r.survey.support[0] - r.survey.support[-1]
	if length < request.length_min or length > request.length_max:
		return {kind = "built", short = "фактическая длина вне диапазона", why = "длина %.0f м вне %.0f–%.0f м" % [length, request.length_min, request.length_max]}
	if drop < request.min_drop:
		return {kind = "built", short = "фактический перепад меньше требуемого", why = "перепад %.1f м < %.1f м" % [drop, request.min_drop]}
	if access != null:
		var checked: Dictionary = access.verify(r, site)
		if not checked.ok:
			return {kind = "access", short = checked.short, why = checked.why}
	return {kind = "ok", short = "", why = ""}


## Затраты доступа (его подходы ищут свои построители) — в общую работу операции и отдельной строкой.
func _take_access_stats() -> void:
	var access: Variant = request.get("access")
	if access == null: return
	var spent: Dictionary = access.take_stats()
	stats.access_expansions += spent.expansions
	stats.expansions += spent.expansions
	stats.access_searches += spent.searches
	stats.repairs += spent.repairs
	stats.access_ms += spent.ms
	stats.search_ms += spent.ms


## Короткая причина отказа построителя для сводки.
static func _short(r: TrailRouter) -> String:
	if r.reason.contains("бюджет"): return "бюджет раскрытий исчерпан"
	if r.reason.contains("разделены"): return "разделены водой или путём"
	if r.reason.contains("радиус"): return "не хватает места на радиус поворота"
	if r.reason.contains("оценка уклона"): return "уклон не держится (оценка)"
	if r.reason.contains("нет пути"): return "нет пути в пределах уклона"
	if r.reason.contains("во всех направлениях"): return "у конца слишком круто"
	if r.reason.contains("таймаут"): return "таймаут"
	if r.reason.contains("сборок"): return "лимит полных сборок исчерпан"
	return r.stage


## Точки решётки и отсев пар; не больше request.pairs пространственно разнесённых пар в порядке ранжирования.
func _select(probe: TrailRouter) -> Array[Dictionary]:
	var area := probe.areas()
	var linked := probe.reach_areas()
	var lo: Vector2 = probe._lo
	var hi: Vector2 = probe._hi
	var points: Array[Vector2] = []
	var heights := PackedFloat32Array()
	var labels := PackedInt32Array()
	var slopes := PackedInt32Array() # область достижимости при пределе уклона поиска (TrailRouter.reach_areas)
	var near: Array = request.get("near", [])
	var near_max: float = request.get("near_max", 90.0)
	var gap := PackedFloat32Array() # расстояние до ближайшей точки примыкания к дороге (только при доступе)
	var count := Vector2i(((hi - lo) / SPACING).floor()) + Vector2i.ONE
	var shift := (hi - lo - Vector2(count - Vector2i.ONE) * SPACING) * 0.5 # решётка по центру зоны
	for gz in count.y:
		for gx in count.x:
			var p := lo + shift + Vector2(gx, gz) * SPACING
			stats.points += 1
			if probe.blocked(p) != TrailRouter.Block.FREE:
				_reject("точка: запрещённое место")
				continue
			if probe.end_open(p) == 0:
				_reject("точка: круче предела во все стороны")
				continue
			var to_road := 0.0
			if not near.is_empty():
				to_road = INF
				for j: Vector2 in near: to_road = minf(to_road, p.distance_to(j))
				if to_road > near_max:
					_reject("точка: далеко от дорожной сети")
					continue
			points.append(p)
			gap.append(to_road)
			heights.append(probe.mean_at(p))
			labels.append(area[probe._free_node(p)])
			slopes.append(linked[probe._free_node(p)])
	stats.points_kept = points.size()
	var ranked: Array[Dictionary] = []
	var reach: float = request.length_max
	var shortest: float = request.length_min / DETOUR / 1.3 # прямая короче — линия почти наверняка не наберёт длину
	for a in points.size():
		for b in points.size():
			if a == b: continue
			stats.pairs_considered += 1
			var drop := heights[a] - heights[b]
			if drop < request.min_drop:
				_reject("пара: финиш не ниже старта на %.0f м" % request.min_drop)
				continue
			var d := points[a].distance_to(points[b])
			if d > reach or d < shortest:
				_reject("пара: расстояние не подходит к длине")
				continue
			if drop / request.grade > request.length_max:
				_reject("пара: перепад не уложить в длину при пределе уклона")
				continue
			if labels[a] < 0 or labels[a] != labels[b]:
				_reject("пара: разные доступные области")
				continue
			if slopes[a] != slopes[b]:
				_reject("пара: по рельефу не соединить при пределе уклона поиска")
				continue
			var target: float = (request.length_min + request.length_max) * 0.5
			var score: float = absf(d * DETOUR - target) / target + maxf(0.0, drop / d - 0.8 * request.grade) / request.grade
			if not near.is_empty():
				# у обоих концов должна быть подходящая точка примыкания (по прямой старт → финиш как направлению трассы)
				var way := (points[b] - points[a]).normalized()
				var fit_a := INF
				var fit_b := INF
				for j: Vector2 in near:
					fit_a = minf(fit_a, TrailAccess.rank_join(j, points[a], way, true, 4.0 * minf(TrailAccess.RADIUS, request.min_radius) + 2.0))
					fit_b = minf(fit_b, TrailAccess.rank_join(j, points[b], way, false, 4.0 * minf(TrailAccess.RADIUS, request.min_radius) + 2.0))
				if not is_finite(fit_a) or not is_finite(fit_b):
					_reject("пара: у конца нет подходящей точки примыкания к дороге")
					continue
				score += 0.8 * (fit_a + fit_b) / near_max # предпочесть пары с короткими и ровными подходами
			ranked.append({start = points[a], finish = points[b], score = score, straight = d, drop = drop, index = ranked.size()})
	stats.pairs_kept = ranked.size()
	ranked.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.score < y.score or (x.score == y.score and x.index < y.index))
	var chosen: Array[Dictionary] = []
	for pair: Dictionary in ranked:
		if chosen.size() >= int(request.pairs): break
		var apart := true
		for c: Dictionary in chosen:
			# та же линия, сдвинутая параллельно: оба конца ближе SPREAD к концам взятой пары
			if maxf((pair.start as Vector2).distance_to(c.start), (pair.finish as Vector2).distance_to(c.finish)) < SPREAD: apart = false
		if apart: chosen.append(pair)
	return chosen


func _rejections() -> String:
	var keys := rejected.keys()
	keys.sort_custom(func(x: String, y: String) -> bool: return rejected[x] > rejected[y] or (rejected[x] == rejected[y] and x < y))
	var out := PackedStringArray()
	for k: String in keys: out.append("%s — %d" % [k, rejected[k]])
	return "; ".join(out)


## Отчёт для лаборатории.
func summary() -> String:
	var lines := PackedStringArray()
	if accepted:
		var r := router
		lines.append("Трасса найдена: старт (%.0f, %.0f) → финиш (%.0f, %.0f)" % [start.x, start.y, finish.x, finish.y])
		lines.append("Длина %.0f м (нужно %.0f–%.0f) · перепад вниз %.1f м (нужно от %.1f) · уклон до %.1f%% (предел %.0f%%) · радиус от %.1f м" % [
			r.stats.length, request.length_min, request.length_max, r.stats.drop, request.min_drop, r.stats.peak_grade * 100.0, request.grade * 100.0, r.stats.min_radius])
		lines.append("Земляные работы: выемка %.0f м³, насыпь %.0f м³" % [r.stats.cut_m3, r.stats.fill_m3])
		for c: Dictionary in r.checks: lines.append("%s %s · %s" % [TrailRouter.MARKS[c.state], c.name, c.detail])
	else:
		lines.append("Трасса не найдена (%s): %s" % [VERDICTS.get(verdict, verdict), reason])
	lines.append("Точек %d (годных %d) · пар рассмотрено %d, прошло отсев %d, искалось %d из %d" % [
		stats.points, stats.points_kept, stats.pairs_considered, stats.pairs_kept, stats.pairs_searched, request.get("pairs", 0)])
	lines.append("Поисков %d · раскрытий %d из %d · исправлений %d из %d · полных сборок %d из %d" % [
		stats.searches, stats.expansions, request.get("budget", 0), stats.repairs, request.get("repairs", 0), stats.builds, request.get("builds", 0)])
	if not rejected.is_empty(): lines.append("Отклонено: " + _rejections())
	lines.append("Время: %s · выбор пар %.0f мс · поиск и оценка %.0f · полные сборки %.0f · всего %.0f мс" % [
		TrailRouter.prepare_text(stats), stats.select_ms, stats.search_ms, stats.build_ms, stats.total_ms])
	var unchecked := PackedStringArray(TrailSurvey.UNCHECKED)
	unchecked.append_array(TrailRouter.UNCHECKED)
	lines.append("Не проверяется: " + ", ".join(unchecked))
	return "\n".join(lines)
