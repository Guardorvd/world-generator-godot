extends RefCounted
## Автопилот Trail Lab (30.10): едет по трассе тем же вводом, что игрок (газ/тормоз, руль, Shift, Space), в одной из
## манер. Видит только данные трассы: линию, кривизну, элементы и готовую поверхность под ней (разрывы, Heightfield).
## Манеры отличаются целевой скоростью, боковым запасом в поворотах, скоростью на технике, линией и прыжками:
##   careful — осторожно: тормозит заранее, технику проходит медленно по чистой линии, бревно объезжает;
##   flow    — flow: держит скорость, на виражах смелее, через бревно прыгает, камни и корни — по чистой линии;
##   race    — на пределе: максимум скорости, Shift на прямых, едет по оси и перепрыгивает брёвна.
## Перед разрывом (овраг, гэп) любая манера разгоняется: медленнее перелёт не долетит.

const STYLES := {
	careful = {title = "осторожно", top = 9.0, lateral = 5.5, tech = 6.0, hop = [], axis = false, run = false},
	flow = {title = "flow", top = 13.0, lateral = 7.5, tech = 9.5, hop = [TrailElement.Profile.LOG], axis = false, run = false},
	race = {title = "на пределе", top = 17.0, lateral = 9.5, tech = INF, hop = [TrailElement.Profile.LOG], axis = true, run = true},
}
const ORDER := ["careful", "flow", "race"]
const BRAKE := 4.5        # замедление, на которое рассчитан тормозной путь, м/с²
const LOOK := 32.0         # насколько вперёд смотрит на повороты и элементы, м
const BERM_GRIP := 1.5     # на вираже боковой запас больше во столько раз
const GAP_DROP := 2.5      # поверхность падает больше этого за 3 м — разрыв, м
const COMMIT := 40.0       # за столько метров до разрыва — полный газ и без тормоза, м
const COMMIT_SPEED := 16.0 # скорость, к которой разгоняется перед разрывом, м/с

var style := "flow"
var station := 0.0
var gaps := PackedFloat32Array()
var _hopped := {}

## Начать с места station; разрывы трассы находятся один раз по готовой поверхности.
func reset(d: TrailDefinition, h: Heightfield, at_station: float) -> void:
	station = at_station
	_hopped.clear()
	gaps.clear()
	var s := 1.0
	var length := d.route_length()
	while s < length - 3.0:
		var a := d.point_at(s)
		var b := d.point_at(s + 3.0)
		# по земле (настилы не в счёт): под мостом нижний проход не должен казаться разрывом
		if h.ground_at(a.x, a.y) - h.ground_at(b.x, b.y) > GAP_DROP and (gaps.is_empty() or s - gaps[-1] > 10.0):
			gaps.append(s)
		s += 1.0

func title() -> String:
	return STYLES[style].title

## Ввод на такт: {throttle, turn, run, jump}.
func drive(bike: BikeRide, d: TrailDefinition) -> Dictionary:
	var spec: Dictionary = STYLES[style]
	var length := d.route_length()
	var here := Vector2(bike.x, bike.z)
	# Ближайшая точка оси только рядом с прежней: на пересечении трассы с собой не перескочить на другой проход.
	var near := d.nearest(here, 12.0)
	if d.closed and station > length - 12.0 and is_finite(near.z) and near.x < 12.0:
		# Продолжить следующий круг без переноса велосипеда или сброса его скорости.
		station = near.x
		_hopped.clear()
	if is_finite(near.z) and near.x > station - 10.0 and near.x < station + 30.0: station = maxf(station, near.x)
	var speed := absf(bike.speed)
	var ahead := station + maxf(4.0, speed * 0.55)
	if d.closed: ahead = fposmod(ahead, length)
	var aim := d.point_at(minf(ahead, length))
	var offset := _line(d, ahead, spec)
	if offset != 0.0:
		var t := d.tangent_at(ahead)
		aim += Vector2(t.y, -t.x) * offset
	var delta := aim - here
	var turn := clampf(-wrapf(atan2(-delta.x, -delta.y) - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
	var want: float = spec.top
	var commit := false
	for g in gaps:
		if station > g - COMMIT and station < g + 2.0: commit = true
	# гэп (31.10): за COMMIT до кромки — скорость, с которой приземление приходится на спуск, а не в разрыв
	var gap_speed := 0.0
	for e in d.elements:
		if e.profile != TrailElement.Profile.GAP: continue
		var lip := e.station - e.length * 0.5 + e.gap_lip()
		if station > lip - COMMIT and station < lip: gap_speed = e.gap_speed()
	if commit:
		want = COMMIT_SPEED
	elif gap_speed > 0.0:
		want = gap_speed
		commit = true
	else:
		var k_at := 0.0
		while k_at <= LOOK:
			var s := fposmod(station + k_at, length) if d.closed else minf(station + k_at, length)
			var k := absf(d.curvature_at(s))
			if k > 0.0001:
				var grip: float = spec.lateral * (BERM_GRIP if _on(d, s, TrailElement.Profile.BERM) else 1.0)
				want = minf(want, sqrt(grip / k + 2.0 * BRAKE * k_at))
			var tech := _technical(d, s)
			if tech != null and tech.profile not in spec.hop and is_finite(spec.tech):
				want = minf(want, sqrt(spec.tech * spec.tech + 2.0 * BRAKE * k_at))
			k_at += 2.0
	var throttle := clampf((want - speed) * 0.6, -1.0, 1.0)
	if throttle < 0.0 and speed - want < (0.3 if gap_speed > 0.0 else 0.7): throttle = 0.0
	# прыжок через бревно: нажать за время подготовки до него (брёвна серии — как в TrailTechnical._logs)
	var jump := false
	for i in d.elements.size():
		var e := d.elements[i]
		if e.profile not in spec.hop: continue
		var count := clampi(e.count, 1, 4)
		for n in count:
			var to := e.station - e.length * 0.5 + e.length * (n + 0.5) / count - station
			if not _hopped.has(Vector2i(i, n)) and to > 0.0 and to < speed * 0.22 + 0.9:
				jump = true
				_hopped[Vector2i(i, n)] = true
	return {throttle = throttle, turn = turn, run = spec.run and throttle > 0.5 and not commit, jump = jump}

## Боковое смещение линии у станции s: чистая линия технического элемента, ближайшая к оси; ось — у манеры
## «на пределе» (кроме слалома, где ось перегорожена) и у прыгаемых ею объектов.
func _line(d: TrailDefinition, s: float, spec: Dictionary) -> float:
	var e: TrailElement = _technical(d, s)
	if e == null: return 0.0
	if e.profile == TrailElement.Profile.SLALOM: return TrailTechnical.line_at(d, e, 0.0, s)
	if spec.axis or e.profile in spec.hop: return 0.0
	var best := INF
	for line in TrailTechnical.line_offsets(d, e):
		if absf(line) < absf(best): best = line
	return best if is_finite(best) else 0.0

## Технический элемент с объектами, внутри которого (с запасом 4 м до начала) лежит станция s.
func _technical(d: TrailDefinition, s: float) -> TrailElement:
	for e in d.elements:
		if TrailElement.places_objects(e.profile) and e.profile != TrailElement.Profile.NORTHSHORE and s > e.station - e.length * 0.5 - 4.0 and s < e.station + e.length * 0.5:
			return e
	return null

func _on(d: TrailDefinition, s: float, profile: int) -> bool:
	for e in d.elements:
		if e.profile == profile and absf(s - e.station) < e.length * 0.5: return true
	return false
