class_name TrailSurvey
extends RefCounted
## Profile of the FINISHED surface along one route: what the wheel rolls on after earthworks, elements and decks.
## Read-only: samples Heightfield.surface_at along the centre line and carries the previous support height as the
## "feet", as BikeRide does, so a northshore is measured on its deck and never on the ground under it.
## Separate from TrailShaping's grade_natural / grade_designed: those describe the design profile before the elements.
## A point without a trustworthy reading is marked unmeasured, never given a made-up value.
## Problems are kept as distance intervals, not as one warning per sample. No UI, no scene access.

const SAMPLE := 0.5        # spacing of samples along the centre line, m
const GRADE_BASE := 4.0    # grade = rise over this run; TrailShaping._peak_grade uses the same 4 m
const CROSS_SHARE := 0.8   # cross slope between points at this share of the half width
const LAYER_JUMP := 0.1    # a change of support (ground <-> deck) by more than this is an edge, not a slope, m
const MERGE := 2.0         # problem runs closer than this form one interval, m
## What this survey does not judge. A passed grade check says nothing about these.
const UNCHECKED := ["прыжки и приземления", "скорость и безопасность", "объекты на линии", "сложность трассы"]

enum Layer { GROUND, DECK }

var route_id := ""
var length := 0.0
var grade_limit := 0.0 ## explicit requirement, m/m; 0 — none given, the grade is only reported
var stations := PackedFloat32Array()
var support := PackedFloat32Array() ## height of the chosen support, m
var layers := PackedByteArray()
var grade := PackedFloat32Array()   ## along the route, + uphill; NAN where the run crosses an edge
var cross := PackedFloat32Array()   ## right minus left over the tread; NAN on and beside decks
var curvature := PackedFloat32Array()
var elements: Array[Dictionary] = []   ## {index, title, from, to}
var exceeded: Array[Dictionary] = []   ## {from, to, peak, elements}
var unmeasured: Array[Dictionary] = [] ## {from, to, reason, elements}
var errors := PackedStringArray()
var peak_grade := 0.0       ## steepest measured grade, m/m
var peak_grade_track := 0.0 ## the same away from the elements
var climb := 0.0
var descent := 0.0
var peak_cross := 0.0
var min_radius := INF
var deck_length := 0.0
var survey_ms := 0.0

static func measure(h: Heightfield, d: TrailDefinition, limit := 0.0) -> TrailSurvey:
	var s := TrailSurvey.new()
	var started := Time.get_ticks_usec()
	s.grade_limit = maxf(0.0, limit)
	if d == null or h == null or d.points.size() < 2 or not d.route_length() > 0.0:
		s.errors.append("Нет трассы или опоры для измерения")
		return s
	s.route_id = d.id
	s.length = d.route_length()
	for i in d.elements.size():
		var e := d.elements[i]
		s.elements.append({index = i, title = TrailElementLibrary.title(e.profile), from = e.station - e.length * 0.5, to = e.station + e.length * 0.5})
	var count := maxi(2, ceili(s.length / SAMPLE))
	var step := s.length / count
	var half := d.width * 0.5 * CROSS_SHARE
	var edge := PackedByteArray()  # support jumped between this sample and the previous one
	var under := PackedByteArray() # an unreachable deck overhead: the reading is ambiguous
	var feet := -INF # Trail Lab starts every ride on the ground
	for j in count + 1:
		var station := step * j
		var p := d.point_at(station)
		var ground := h.ground_at(p.x, p.y)
		var deck := h.deck_at(p.x, p.y, feet)
		var y := maxf(ground, deck)
		if not is_finite(y):
			s.errors.append("Опора не определена на %.1f м" % station)
			return s
		var layer := Layer.DECK if deck >= ground else Layer.GROUND
		s.stations.append(station)
		s.support.append(y)
		s.layers.append(layer)
		s.curvature.append(d.curvature_at(station))
		edge.append(int(j > 0 and s.layers[j - 1] != layer and absf(y - s.support[j - 1]) > LAYER_JUMP))
		under.append(int(h.deck_at(p.x, p.y, INF) > y + Heightfield.STEP))
		var t := d.tangent_at(station)
		var right := p + Vector2(t.y, -t.x) * half
		var left := p - Vector2(t.y, -t.x) * half
		var clear := layer == Layer.GROUND and h.deck_at(p.x, p.y, INF) == -INF and h.deck_at(right.x, right.y, INF) == -INF and h.deck_at(left.x, left.y, INF) == -INF
		s.cross.append((h.ground_at(right.x, right.y) - h.ground_at(left.x, left.y)) / (2.0 * half) if clear else NAN)
		if j > 0:
			if layer == Layer.DECK: s.deck_length += step
			if not edge[j]:
				var rise := y - s.support[j - 1]
				s.climb += maxf(0.0, rise)
				s.descent += maxf(0.0, -rise)
		feet = y
	var k := maxi(1, roundi(GRADE_BASE * 0.5 / step))
	for j in count + 1:
		var a := maxi(0, j - k)
		var b := mini(count, j + k)
		var honest := under[a] == 0
		for m in range(a + 1, b + 1): honest = honest and edge[m] == 0 and under[m] == 0
		s.grade.append((s.support[b] - s.support[a]) / (s.stations[b] - s.stations[a]) if honest else NAN)
	for j in count + 1:
		var g := s.grade[j]
		if is_finite(g):
			s.peak_grade = maxf(s.peak_grade, absf(g))
			if s.on_elements(s.stations[j]).is_empty(): s.peak_grade_track = maxf(s.peak_grade_track, absf(g))
		if is_finite(s.cross[j]): s.peak_cross = maxf(s.peak_cross, absf(s.cross[j]))
		if absf(s.curvature[j]) > 0.0001: s.min_radius = minf(s.min_radius, 1.0 / absf(s.curvature[j]))
	for run in s._runs(func(j: int) -> bool: return not is_finite(s.grade[j])):
		var reason := "проход под настилом"
		for j in range(run.x, run.y + 1):
			if edge[j]: reason = "кромка настила"
		s.unmeasured.append({from = s.stations[run.x], to = s.stations[run.y], reason = reason, elements = s.on_elements(s.stations[run.x], s.stations[run.y])})
	if s.grade_limit > 0.0:
		for run in s._runs(func(j: int) -> bool: return is_finite(s.grade[j]) and absf(s.grade[j]) > s.grade_limit):
			var peak := 0.0
			for j in range(run.x, run.y + 1):
				if is_finite(s.grade[j]) and absf(s.grade[j]) > absf(peak): peak = s.grade[j]
			s.exceeded.append({from = s.stations[run.x], to = s.stations[run.y], peak = peak, elements = s.on_elements(s.stations[run.x], s.stations[run.y])})
	s.survey_ms = (Time.get_ticks_usec() - started) / 1000.0
	return s

## Sample index runs where `bad` holds; runs closer than MERGE are joined.
func _runs(bad: Callable) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for j in stations.size():
		if not bad.call(j): continue
		if not result.is_empty() and stations[j] - stations[result[-1].y] <= MERGE:
			result[-1] = Vector2i(result[-1].x, j)
		else:
			result.append(Vector2i(j, j))
	return result

## Indices of the elements whose footprint (widened by the grade run) touches [from, to].
func on_elements(from: float, to := NAN) -> Array[int]:
	var last := from if is_nan(to) else to
	var result: Array[int] = []
	for e: Dictionary in elements:
		if last >= e.from - GRADE_BASE * 0.5 and from <= e.to + GRADE_BASE * 0.5: result.append(e.index)
	return result

## "error" — no honest profile; "exceeded" — outside the given requirement; "within"; "no_requirement".
func level() -> String:
	if not errors.is_empty(): return "error"
	if grade_limit <= 0.0: return "no_requirement"
	return "exceeded" if not exceeded.is_empty() else "within"

func exceeded_on_elements() -> int:
	var count := 0
	for run: Dictionary in exceeded: count += int(not (run.elements as Array).is_empty())
	return count

func _where(run: Dictionary) -> String:
	var names := PackedStringArray()
	for i: int in run.elements: names.append(elements[i].title)
	return "%.0f–%.0f м%s" % [run.from, run.to, (" (" + ", ".join(names) + ")") if not names.is_empty() else ""]

## Short report for the lab diagnostics.
func summary(limit_lines := 4) -> String:
	if not errors.is_empty(): return "Поверхность: ошибка · " + "; ".join(errors)
	var lines := PackedStringArray()
	lines.append("Готовая поверхность · %.0f м · уклон до %.0f%% (вне элементов %.0f%%)" % [length, peak_grade * 100.0, peak_grade_track * 100.0])
	lines.append("Набор %.1f м · сброс %.1f м · поперечный до %.0f%% · радиус от %s%s" % [climb, descent, peak_cross * 100.0,
		"%.0f м" % min_radius if is_finite(min_radius) else "—", (" · настил %.0f м" % deck_length) if deck_length > 0.0 else ""])
	match level():
		"no_requirement": lines.append("Предел уклона не задан: только фактические значения")
		"within": lines.append("Уклон ≤ %.0f%%: превышений нет (проверен только уклон)" % (grade_limit * 100.0))
		"exceeded": lines.append("Уклон ≤ %.0f%%: превышений %d, из них на элементах %d" % [grade_limit * 100.0, exceeded.size(), exceeded_on_elements()])
	for i in mini(exceeded.size(), limit_lines):
		lines.append("  %+.0f%% · %s" % [exceeded[i].peak * 100.0, _where(exceeded[i])])
	if exceeded.size() > limit_lines: lines.append("  … ещё %d" % (exceeded.size() - limit_lines))
	for run: Dictionary in unmeasured:
		lines.append("Не измерено: %s · %s" % [run.reason, _where(run)])
	lines.append("Не проверяется: " + ", ".join(UNCHECKED))
	return "\n".join(lines)
