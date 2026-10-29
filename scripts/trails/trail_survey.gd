class_name TrailSurvey
extends RefCounted
## Profile of the FINISHED surface along one route: what the wheel rolls on after earthworks, elements and decks.
## Read-only: samples Heightfield.surface_at along the centre line and carries the previous support height as the
## "feet", as BikeRide does, so a northshore is measured on its deck and never on the ground under it.
## Separate from TrailShaping's grade_natural / grade_designed: those describe the design profile before the elements.
## A point without a trustworthy reading is marked unmeasured, never given a made-up value; any unmeasured part makes
## the check incomplete. Problems are kept as distance intervals, not as one warning per sample. No UI, no scene access.

const SAMPLE := 0.5        # spacing of samples along the centre line, m
const GRADE_BASE := 4.0    # averaged grade = rise over this run; TrailShaping.peak_grade uses the same 4 m
const CROSS_SHARE := 0.8   # cross slope between points at this share of the half width
const LAYER_JUMP := 0.1    # a change of support (ground <-> deck) by more than this is an edge, not a slope, m
const MERGE := 2.0         # problem runs closer than this form one interval, m
## What this survey does not judge. A passed grade check says nothing about these.
const UNCHECKED := ["прыжки и приземления", "скорость и безопасность", "объекты на линии", "сложность трассы"]

enum Layer { GROUND, DECK }

var route_id := ""
var length := 0.0
var closed := false
var grade_limit := 0.0 ## explicit requirement on the 4 m grade, m/m; 0 — none given, the grade is only reported
var stations := PackedFloat32Array()
var support := PackedFloat32Array() ## height of the chosen support, m
var layers := PackedByteArray()
var grade := PackedFloat32Array()       ## averaged over GRADE_BASE, + uphill; NAN where the run crosses an edge
var grade_local := PackedFloat32Array() ## between this sample and the previous one; NAN across an edge
var cross := PackedFloat32Array()   ## right minus left over the tread; NAN on and beside decks
var curvature := PackedFloat32Array()
var elements: Array[Dictionary] = []   ## {index, title, from, to}
## Intervals {from, to, ...}; on a closed route from > to means the interval runs through the seam.
var exceeded: Array[Dictionary] = []   ## {from, to, peak, elements} — over the requirement by the 4 m grade
var unmeasured: Array[Dictionary] = [] ## {from, to, reason, elements}
var errors := PackedStringArray()
var peak_grade := 0.0       ## steepest measured 4 m grade, m/m
var peak_grade_track := 0.0 ## the same away from the elements
var peak_local := 0.0       ## steepest measured local grade, m/m
var peak_local_track := 0.0
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
	s.closed = d.closed
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
		var honest := j > 0 and not edge[j] and not under[j] and not under[j - 1]
		s.grade_local.append((y - s.support[j - 1]) / step if honest else NAN)
		if j > 0:
			if layer == Layer.DECK: s.deck_length += step
			if not edge[j]:
				var rise := y - s.support[j - 1]
				s.climb += maxf(0.0, rise)
				s.descent += maxf(0.0, -rise)
		feet = y
	# The first local grade of a circuit is the step over the seam (the last sample is the first point again).
	if s.closed: s.grade_local[0] = s.grade_local[count]
	# The 4 m window is centred on each sample. A circuit wraps it through the seam; an open route shortens it at the ends.
	var k := maxi(1, roundi(GRADE_BASE * 0.5 / step))
	for j in count + 1:
		var a := j - k
		var b := j + k
		if not s.closed:
			a = maxi(0, a)
			b = mini(count, b)
		var honest := under[s._wrap(a, count)] == 0
		for m in range(a + 1, b + 1):
			var at := s._wrap(m, count)
			honest = honest and under[at] == 0 and edge[count if s.closed and at == 0 else at] == 0
		s.grade.append((s.support[s._wrap(b, count)] - s.support[s._wrap(a, count)]) / ((b - a) * step) if honest else NAN)
	for j in count + 1:
		var away := s.on_elements(s.stations[j]).is_empty()
		if is_finite(s.grade[j]):
			s.peak_grade = maxf(s.peak_grade, absf(s.grade[j]))
			if away: s.peak_grade_track = maxf(s.peak_grade_track, absf(s.grade[j]))
		if is_finite(s.grade_local[j]):
			s.peak_local = maxf(s.peak_local, absf(s.grade_local[j]))
			if away: s.peak_local_track = maxf(s.peak_local_track, absf(s.grade_local[j]))
		if is_finite(s.cross[j]): s.peak_cross = maxf(s.peak_cross, absf(s.cross[j]))
		if absf(s.curvature[j]) > 0.0001: s.min_radius = minf(s.min_radius, 1.0 / absf(s.curvature[j]))
	for run in s._runs(func(j: int) -> bool: return not is_finite(s.grade[j])):
		var reason := "проход под настилом"
		for j in s._indices(run):
			if edge[j]: reason = "кромка настила"
		s.unmeasured.append({from = s.stations[run.x], to = s.stations[run.y], reason = reason, elements = s._run_elements(run)})
	if s.grade_limit > 0.0:
		for run in s._runs(func(j: int) -> bool: return is_finite(s.grade[j]) and absf(s.grade[j]) > s.grade_limit):
			var peak := 0.0
			for j in s._indices(run):
				if is_finite(s.grade[j]) and absf(s.grade[j]) > absf(peak): peak = s.grade[j]
			s.exceeded.append({from = s.stations[run.x], to = s.stations[run.y], peak = peak, elements = s._run_elements(run)})
	s.survey_ms = (Time.get_ticks_usec() - started) / 1000.0
	return s

## Sample index of window position `m`: a circuit wraps (the last sample is the first point), an open route clamps.
func _wrap(m: int, count: int) -> int:
	return posmod(m, count) if closed else clampi(m, 0, count)

## Sample index runs where `bad` holds; runs closer than MERGE are joined. On a circuit the last sample repeats
## the first and is skipped, and runs touching the seam become one run with x > y.
func _runs(bad: Callable) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var last := stations.size() - (2 if closed else 1)
	for j in last + 1:
		if not bad.call(j): continue
		if not result.is_empty() and stations[j] - stations[result[-1].y] <= MERGE:
			result[-1] = Vector2i(result[-1].x, j)
		else:
			result.append(Vector2i(j, j))
	if closed and result.size() > 1 and stations[result[0].x] + length - stations[result[-1].y] <= MERGE:
		result[0] = Vector2i(result[-1].x, result[0].y)
		result.pop_back()
	return result

func _indices(run: Vector2i) -> Array[int]:
	var result: Array[int] = []
	if run.x <= run.y:
		for j in range(run.x, run.y + 1): result.append(j)
	else:
		for j in range(run.x, stations.size() - 1): result.append(j)
		for j in range(0, run.y + 1): result.append(j)
	return result

func _run_elements(run: Vector2i) -> Array[int]:
	if run.x <= run.y: return on_elements(stations[run.x], stations[run.y])
	var result := on_elements(stations[run.x], length)
	for i in on_elements(0.0, stations[run.y]):
		if i not in result: result.append(i)
	return result

## Indices of the elements whose footprint (widened by the grade run) touches [from, to].
func on_elements(from: float, to := NAN) -> Array[int]:
	var last := from if is_nan(to) else to
	var result: Array[int] = []
	for e: Dictionary in elements:
		if last >= e.from - GRADE_BASE * 0.5 and from <= e.to + GRADE_BASE * 0.5: result.append(e.index)
	return result

## The whole route was measured. Unmeasured parts mean the check is incomplete, whatever else it found.
func complete() -> bool:
	return errors.is_empty() and unmeasured.is_empty()

## "error" — no honest profile; "no_requirement" — values only; "exceeded" — over the requirement where it was
## measured (complete or not); "incomplete" — nothing found, but parts were not measured; "within" — all measured, none over.
func level() -> String:
	if not errors.is_empty(): return "error"
	if grade_limit <= 0.0: return "no_requirement"
	if not exceeded.is_empty(): return "exceeded"
	return "within" if complete() else "incomplete"

func exceeded_on_elements() -> int:
	var count := 0
	for run: Dictionary in exceeded: count += int(not (run.elements as Array).is_empty())
	return count

func _where(run: Dictionary) -> String:
	var names := PackedStringArray()
	for i: int in run.elements: names.append(elements[i].title)
	return "%.0f–%.0f м%s%s" % [run.from, run.to, " через стык" if run.from > run.to else "", (" (" + ", ".join(names) + ")") if not names.is_empty() else ""]

## Short report for the lab diagnostics.
func summary(limit_lines := 4) -> String:
	if not errors.is_empty(): return "Поверхность: ошибка · " + "; ".join(errors)
	var lines := PackedStringArray()
	lines.append("Готовая поверхность · %.0f м%s" % [length, " · кольцо" if closed else ""])
	lines.append("Уклон на базе 4 м до %.0f%% (вне элементов %.0f%%) · локальный (0,5 м) до %.0f%% (вне элементов %.0f%%)" % [peak_grade * 100.0, peak_grade_track * 100.0, peak_local * 100.0, peak_local_track * 100.0])
	lines.append("Набор %.1f м · сброс %.1f м · поперечный до %.0f%% · радиус от %s%s" % [climb, descent, peak_cross * 100.0,
		"%.0f м" % min_radius if is_finite(min_radius) else "—", (" · настил %.0f м" % deck_length) if deck_length > 0.0 else ""])
	var rule := "Предел %.0f%% по уклону на базе 4 м" % (grade_limit * 100.0)
	match level():
		"no_requirement": lines.append("Предел уклона не задан: только фактические значения")
		"within": lines.append(rule + ": превышений нет (проверен только уклон)")
		"incomplete": lines.append(rule + ": проверка НЕПОЛНАЯ — в измеренной части превышений нет")
		"exceeded": lines.append(rule + ": превышений %d, из них на элементах %d%s" % [exceeded.size(), exceeded_on_elements(), "" if complete() else " · проверка НЕПОЛНАЯ"])
	for i in mini(exceeded.size(), limit_lines):
		lines.append("  %+.0f%% · %s" % [exceeded[i].peak * 100.0, _where(exceeded[i])])
	if exceeded.size() > limit_lines: lines.append("  … ещё %d" % (exceeded.size() - limit_lines))
	for run: Dictionary in unmeasured:
		lines.append("Не измерено: %s · %s" % [run.reason, _where(run)])
	lines.append("Не проверяется: " + ", ".join(UNCHECKED))
	return "\n".join(lines)
