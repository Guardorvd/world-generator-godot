class_name TrailFlow
extends RefCounted
## Trail Lab: elements on a line already accepted by TrailRouter (found by TrailPicker or between two given points).
## Not a second composer: TrailComposer places the elements (profile "calm_flow": small roller, gentle dip, berm),
## this class only reads the accepted line and builds and judges the result.
##
## 1. Placement reads the finished profile of the accepted tread BEFORE elements (the base TrailSurvey): every element
##    TrailComposer proposes is checked over its whole length plus APPROACH / EXIT metres — local 4 m grade with the
##    element's own slope added, turns (straight elements on near-straight line, a berm in one steady turn), the route
##    ends, neighbouring elements, the earthwork limits of the request and the combined banking of the route's own
##    superelevation and a berm. A refused element is skipped, never forced in for a count.
## 2. The base line (axis, requirements, auto_bank) is not changed. The trail with elements is a copy of the base
##    definition plus elements, built on a fresh copy of the saved site (TrailSite.prepare) — never over the baked base.
## 3. At most two full builds after the base: the main variant and, when it fails, one simplified variant without the
##    elements tied to the failures. Otherwise the base line stays, with the reason. Requirements are never relaxed.
## 4. The result is judged anew on the final surface: the base report is not carried over.
## Deterministic in (base line, seed).

const APPROACH := 8.0          # free line before an element, m
const EXIT := 8.0              # and after it
const STRAIGHT := 1.0 / 40.0   # a roller or a dip only where the line bends less than this (1/m) around it
const BERM_TURN := 1.0 / 60.0  # a berm only in one turn at least this sharp along its whole length
const BANK_LIMIT := 0.38       # steepest tread cross slope with a berm: the bike-track preset's own bank_max
const SAME := 0.02             # outside the elements the final support must equal the base one within this, m
const BUILDS := 2
const ALLOWED := [TrailElement.Profile.ROLLER, TrailElement.Profile.DIP, TrailElement.Profile.BERM]
## What the element check does not judge.
const UNCHECKED := ["отрыв и приземление на элементах", "скорость входа в элементы (только один автопроезд)",
	"объекты и препятствия (их нет)", "сложность и безопасность трассы"]

var base: TrailRouter
var seed := 0
var definition: TrailDefinition   ## the trail in the scene: with elements, or the base one when they did not pass
var prepared := {}
var survey: TrailSurvey
var accepted := false             ## a trail with elements passed its own checks
var variant := ""                 ## основной / упрощённый / базовая линия
var message := ""
var proposed: Array[TrailElement] = [] ## what TrailComposer placed on the line
var removed: Array[Dictionary] = []    ## {title, station, why}
var refusals := {}                     ## why a proposal was refused -> count
var checks: Array[Dictionary] = []     ## of the final surface with elements
var stats := {compose_ms = 0.0, build_ms = 0.0, builds = 0, total_ms = 0.0}

var _site: TrailSite
var _accepted_zones: Array[Vector2] = []


## Elements on an accepted base line. The base router, its definition and its build are not changed.
static func dress(site: TrailSite, line: TrailRouter, seed_value: int) -> TrailFlow:
	var f := TrailFlow.new()
	var started := Time.get_ticks_usec()
	f._run(site, line, seed_value)
	f.stats.total_ms = (Time.get_ticks_usec() - started) / 1000.0
	return f


func _keep_base(why: String) -> void:
	accepted = false
	variant = "базовая линия"
	definition = base.definition
	prepared = base.prepared
	survey = base.survey
	message = why


func _run(site: TrailSite, line: TrailRouter, seed_value: int) -> void:
	base = line
	seed = seed_value
	_site = site
	if line == null or not line.accepted:
		message = "нет принятой базовой линии"
		return
	var d := line.definition.duplicate(true) as TrailDefinition
	d.title = line.definition.title + " · спокойный flow"
	var started := Time.get_ticks_usec()
	var composed := TrailComposer.compose(d, TrailComposer.PROFILES.calm_flow, seed_value,
		func(at: Vector2) -> float: return site.ground_at(at), _fits.bind(d))
	stats.compose_ms = (Time.get_ticks_usec() - started) / 1000.0
	proposed.assign(composed.elements)
	if proposed.is_empty():
		_keep_base("элементам нет места на этой линии (%.0f м): %s" % [d.route_length(), _refusal_text()])
		return
	d.elements.assign(proposed)
	d.sections.assign(composed.sections)
	for build in BUILDS:
		var started_build := Time.get_ticks_usec()
		var got := site.prepare([d] as Array[TrailDefinition])
		stats.builds += 1
		var problems: Array[Dictionary] = []
		var s: TrailSurvey = null
		if not got.errors.is_empty():
			problems.append({index = -1, why = "сборка: " + "; ".join(got.errors)})
		else:
			s = TrailSurvey.measure(got.heights, d, base.request.grade)
			problems = _judge(got.heights, d, s)
		stats.build_ms += (Time.get_ticks_usec() - started_build) / 1000.0
		if problems.is_empty():
			accepted = true
			variant = "основной" if build == 0 else "упрощённый"
			definition = d
			prepared = got
			survey = s
			message = "%d элемент(ов) поставлено и проверено на готовой поверхности" % d.elements.size()
			return
		var blamed := {}
		var loose := PackedStringArray()
		for p: Dictionary in problems:
			if p.index >= 0: blamed[p.index] = p.why
			else: loose.append(p.why)
		if not loose.is_empty() or blamed.is_empty() or build == BUILDS - 1:
			var all := loose.duplicate()
			for i: int in blamed: all.append("%s на %.0f м: %s" % [TrailElementLibrary.title(d.elements[i].profile), d.elements[i].station, blamed[i]])
			_keep_base("вариант с элементами не прошёл проверку (%s): %s" % ["упрощённый" if build > 0 else "основной", "; ".join(all)])
			return
		var kept: Array[TrailElement] = []
		for i in d.elements.size():
			if blamed.has(i): removed.append({title = TrailElementLibrary.title(d.elements[i].profile), station = d.elements[i].station, why = blamed[i]})
			else: kept.append(d.elements[i])
		if kept.is_empty():
			_keep_base("после удаления проблемных элементов не осталось ни одного")
			return
		d.elements = kept


## TrailComposer asks whether element e fits the accepted line d (its base survey). Reasons of refusals are counted.
func _fits(e: TrailElement, d: TrailDefinition) -> bool:
	var why := _misfit(e, d)
	if why.is_empty():
		_accepted_zones.append(Vector2(e.station - e.length * 0.5 - APPROACH, e.station + e.length * 0.5 + EXIT))
		return true
	refusals[why] = refusals.get(why, 0) + 1
	return false


func _misfit(e: TrailElement, d: TrailDefinition) -> String:
	if e.profile not in ALLOWED: return "тип элемента не разрешён"
	var s := base.survey
	var r := base.request
	var a := e.station - e.length * 0.5
	var b := e.station + e.length * 0.5
	if a - APPROACH < 0.0 or b + EXIT > s.length: return "нет свободного подхода или выхода у конца трассы"
	for z in _accepted_zones:
		if a - APPROACH < z.y and b + EXIT > z.x: return "подход или выход занят соседним элементом"
	var half := d.width * 0.5
	var berm := e.profile == TrailElement.Profile.BERM
	# Turns over the element and its free approach and exit
	var turn_sign := 0.0
	for j in s.stations.size():
		var at := s.stations[j]
		if at < a - APPROACH or at > b + EXIT: continue
		var c := s.curvature[j]
		if not berm and absf(c) > STRAIGHT: return "поворот на длине элемента, подходе или выходе"
		if berm and at >= a and at <= b:
			if absf(c) < BERM_TURN or (turn_sign != 0.0 and signf(c) != turn_sign): return "поворот не держится на всей длине виража"
			turn_sign = signf(c)
	if berm and signf(e.bank) != turn_sign: return "вираж не на внешней стороне поворота"
	# The element's own slope along the axis, on the same 4 m base as the requirement
	var own := _own_grade(e, half)
	var cross_add := 0.0
	if berm: cross_add = absf(e.displacement(e.station, half * TrailSurvey.CROSS_SHARE, half) - e.displacement(e.station, -half * TrailSurvey.CROSS_SHARE, half)) / (2.0 * half * TrailSurvey.CROSS_SHARE)
	var top := -INF
	var low := INF
	for j in s.stations.size():
		var at := s.stations[j]
		if at < a - 2.0 or at > b + 2.0: continue
		if not is_finite(s.grade[j]) or absf(s.grade[j]) + own > r.grade: return "уклон полотна с элементом выше %.0f%%" % (r.grade * 100.0)
		var p := d.point_at(at)
		var shaped := s.support[j] - _site.ground_at(p) # displacement of the accepted tread at the axis
		var lift := e.displacement(at, half * signf(e.bank) if berm else 0.0, half) # a berm is highest at its outer edge
		top = maxf(top, shaped + absf(s.cross[j]) * half * float(berm) + maxf(0.0, lift))
		low = minf(low, shaped + minf(0.0, lift))
		if berm and (not is_finite(s.cross[j]) or absf(s.cross[j]) + cross_add > BANK_LIMIT):
			return "вираж полотна с элементом выше %.0f%% (автовираж трассы уже наклоняет поворот)" % (BANK_LIMIT * 100.0)
	if top > r.max_fill: return "насыпь с элементом выше %.1f м" % r.max_fill
	if low < -r.max_cut: return "выемка с элементом глубже %.1f м" % r.max_cut
	return ""


## Steepest 4 m slope the element itself adds along the axis.
static func _own_grade(e: TrailElement, half: float) -> float:
	var peak := 0.0
	var at := e.station - e.length * 0.5 - TrailSurvey.GRADE_BASE
	while at <= e.station + e.length * 0.5:
		var rise := e.displacement(at + TrailSurvey.GRADE_BASE, 0.0, half) - e.displacement(at, 0.0, half)
		peak = maxf(peak, absf(rise) / TrailSurvey.GRADE_BASE)
		at += 0.5
	return peak


## Checks of the final surface with elements; problems {index (element, -1 — not tied to one), why}.
func _judge(h: Heightfield, d: TrailDefinition, s: TrailSurvey) -> Array[Dictionary]:
	var problems: Array[Dictionary] = []
	checks.clear()
	var r := base.request
	if not s.errors.is_empty():
		problems.append({index = -1, why = "; ".join(s.errors)})
	if not s.unmeasured.is_empty():
		problems.append({index = -1, why = "проверка поверхности НЕПОЛНАЯ"})
	var outside := 0
	var on := PackedStringArray()
	for run: Dictionary in s.exceeded:
		if (run.elements as Array).is_empty():
			outside += 1
			problems.append({index = -1, why = "уклон %+.0f%% вне элементов на %.0f–%.0f м" % [run.peak * 100.0, run.from, run.to]})
		for i: int in run.elements:
			on.append("%s %+.0f%%" % [TrailElementLibrary.title(d.elements[i].profile), run.peak * 100.0])
			problems.append({index = i, why = "уклон %+.0f%% на %.0f–%.0f м" % [run.peak * 100.0, run.from, run.to]})
	checks.append({name = "Уклон 4 м ≤ %.0f%% вне элементов" % (r.grade * 100.0), state = "ok" if outside == 0 and s.unmeasured.is_empty() else "fail",
		detail = "вне элементов до %.1f%% (локальный 0,5 м до %.0f%%)" % [s.peak_grade_track * 100.0, s.peak_local_track * 100.0]})
	checks.append({name = "Уклон 4 м ≤ %.0f%% на элементах" % (r.grade * 100.0), state = "ok" if on.is_empty() else "fail",
		detail = "вся трасса до %.1f%% (локальный до %.0f%%)%s" % [s.peak_grade * 100.0, s.peak_local * 100.0, "" if on.is_empty() else " · превышения: " + ", ".join(on)]})
	var shaping: Dictionary = h.road_refinement.trail_shaping.get(d.id, {})
	var earth_ok: bool = not shaping.is_empty() and shaping.max_cut <= r.max_cut + 0.01 and shaping.max_fill <= r.max_fill + 0.01
	if not earth_ok:
		for i in d.elements.size():
			var raises := d.elements[i].profile != TrailElement.Profile.DIP
			if (raises and shaping.get("max_fill", 0.0) > r.max_fill + 0.01) or (not raises and shaping.get("max_cut", 0.0) > r.max_cut + 0.01):
				problems.append({index = i, why = "земляные работы сверх предела"})
	checks.append({name = "Выемка ≤ %.1f м, насыпь ≤ %.1f м (с элементами)" % [r.max_cut, r.max_fill], state = "ok" if earth_ok else "fail",
		detail = "фактически %.2f / %.2f м · объём %.0f / %.0f м³" % [shaping.get("max_cut", 0.0), shaping.get("max_fill", 0.0), shaping.get("cut_m3", 0.0), shaping.get("fill_m3", 0.0)]})
	# Banking: the route's own superelevation plus a berm must not exceed the limit (or the base where it already did)
	var bank_peak := 0.0
	var bank_bad := PackedStringArray()
	for i in d.elements.size():
		var e := d.elements[i]
		var worst := 0.0
		var base_worst := 0.0
		for j in s.stations.size():
			if absf(s.stations[j] - e.station) > e.length * 0.5: continue
			if is_finite(s.cross[j]): worst = maxf(worst, absf(s.cross[j]))
			if is_finite(base.survey.cross[j]): base_worst = maxf(base_worst, absf(base.survey.cross[j]))
		bank_peak = maxf(bank_peak, worst)
		if worst > maxf(BANK_LIMIT, base_worst) + 0.01:
			bank_bad.append("%s %.0f%%" % [TrailElementLibrary.title(e.profile), worst * 100.0])
			problems.append({index = i, why = "наклон полотна %.0f%% выше %.0f%%" % [worst * 100.0, BANK_LIMIT * 100.0]})
	checks.append({name = "Наклон полотна на элементах ≤ %.0f%% (автовираж + элемент)" % (BANK_LIMIT * 100.0), state = "ok" if bank_bad.is_empty() else "fail",
		detail = "до %.0f%%%s" % [bank_peak * 100.0, "" if bank_bad.is_empty() else " · " + ", ".join(bank_bad)]})
	# Outside the elements' reach the surface is the base one, so the base requirements still hold there
	var worst_out := 0.0
	var compared := 0
	for j in s.stations.size():
		var near := false
		for e in d.elements:
			if absf(s.stations[j] - e.station) <= e.length * 0.5 + TrailSurvey.GRADE_BASE: near = true
		if near or j >= base.survey.support.size(): continue
		compared += 1
		worst_out = maxf(worst_out, absf(s.support[j] - base.survey.support[j]))
	if worst_out > SAME: problems.append({index = -1, why = "поверхность вне элементов отличается от базовой на %.2f м" % worst_out})
	checks.append({name = "Вне элементов поверхность = базовая", state = "ok" if worst_out <= SAME else "fail",
		detail = "%d точек, расхождение до %.3f м" % [compared, worst_out]})
	return problems


func _refusal_text() -> String:
	if refusals.is_empty(): return "композитор не предложил ни одного элемента (линия короче подходов и выходов)"
	var keys := refusals.keys()
	keys.sort_custom(func(x: String, y: String) -> bool: return refusals[x] > refusals[y] or (refusals[x] == refusals[y] and x < y))
	var out := PackedStringArray()
	for k: String in keys: out.append("%s — %d" % [k, refusals[k]])
	return "; ".join(out)


## Report in three parts: the base line, the final surface with elements, what the element check does not judge.
func summary() -> String:
	var lines := PackedStringArray()
	lines.append("— Базовая линия (принята построителем, без элементов):")
	if base != null:
		for c: Dictionary in base.checks: lines.append("  %s %s · %s" % [TrailRouter.MARKS[c.state], c.name, c.detail])
	lines.append("— Элементы (спокойный flow, seed %d): %s · вариант: %s" % [seed, message, variant])
	if definition != null and accepted:
		var names := PackedStringArray()
		for e in definition.elements: names.append("%s %.1f/%.0f м на %.0f м" % [TrailElementLibrary.title(e.profile), e.height, e.length, e.station])
		lines.append("  Поставлено %d: %s" % [definition.elements.size(), ", ".join(names)])
	for x: Dictionary in removed: lines.append("  Убран %s на %.0f м: %s" % [x.title, x.station, x.why])
	if not refusals.is_empty(): lines.append("  Не подошли предложения: " + _refusal_text())
	if accepted:
		lines.append("— Окончательная поверхность с элементами:")
		for c: Dictionary in checks: lines.append("  %s %s · %s" % [TrailRouter.MARKS[c.state], c.name, c.detail])
		lines.append("  Длина %.0f м · набор %.1f / сброс %.1f м · поперечный до %.0f%%" % [survey.length, survey.climb, survey.descent, survey.peak_cross * 100.0])
	elif not checks.is_empty():
		lines.append("— Последний вариант с элементами не прошёл:")
		for c: Dictionary in checks: lines.append("  %s %s · %s" % [TrailRouter.MARKS[c.state], c.name, c.detail])
	lines.append("— Не проверяется для элементов: " + ", ".join(UNCHECKED))
	lines.append("Время: композиция %.1f мс · дополнительные сборки %d за %.0f мс · всего %.0f мс" % [stats.compose_ms, stats.builds, stats.build_ms, stats.total_ms])
	return "\n".join(lines)
