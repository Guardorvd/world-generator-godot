extends RefCounted
## Разбор проезда по участкам трассы (31.10): для каждого элемента и каждого поворота без своего элемента — что
## ожидается (точка входа, рабочая скорость, кромка, зона приземления, радиус, линия) и что вышло на деле (скорость и
## линия на входе, взлёт и место приземления, проеханный радиус, вынос, снос, удары, падение) с итогом словами.
## Один и тот же разбор — у записи заезда в Trail Lab (trail_lab_recorder.gd) и у замеров автопилотом
## (tools/trail_air_stats.gd), поэтому заезд человека и автопилота сравниваются по одним числам.
## Ожидания — оценки по геометрии элемента и стенду tools/trail_gap_stand.gd, не физика: «скорость» — диапазон,
## в котором приземление приходится на спуск; «радиус» — самый тугой радиус оси на участке.

## Участок кончается через столько метров после элемента: туда же приходятся приземления.
const TAIL := 8.0
## Перед элементом: вход считается отсюда (скорость и линия на входе), м.
const LEAD := 6.0
## Поворот оси туже этого радиуса без своего элемента — отдельный участок «поворот», м.
const TURN_R := 40.0
## Оценка бокового ускорения на ровном для «рабочей скорости поворота», м/с²; вираж прибавляет BERM_GAIN, контруклон отнимает.
const LAT := 9.0
const BERM_GAIN := 1.35
const OFF_CAMBER_LOSS := 0.75
## Техника: скорость, выше которой седок теряет чистую линию (как у манеры flow автопилота), м/с.
const TECH_SPEED := 9.5

const T := TrailElement.Profile
const JUMPS := [T.GAP, T.TABLETOP, T.ROLLER, T.DROP]
const TURNS := [T.BERM, T.S_BERM, T.OFF_CAMBER]
const RHYTHM := [T.PUMP, T.WAVES, T.RIPPLES]

var route: TrailDefinition
var features: Array = []     # ожидания по участкам (по станции)
var passes: Array = []       # законченные проезды участков
var _current := -1
var _pass := {}
var _prev_heading := 0.0
var _prev_station := -1.0
var _air_from := -1.0
var _air_time := 0.0
var _air_y0 := 0.0
var _air_apex := 0.0
var _air_v := 0.0


## Ожидания по участкам трассы route. Технические линии — TrailTechnical.line_offsets (чистые проезды объектов).
func prepare(d: TrailDefinition) -> void:
	route = d
	features.clear()
	passes.clear()
	_current = -1
	_pass = {}
	_prev_station = -1.0
	_air_from = -1.0
	var covered: Array[Vector2] = []
	for i in d.elements.size():
		var e := d.elements[i]
		var from := e.station - e.length * 0.5
		var to := e.station + e.length * 0.5
		covered.append(Vector2(from, to))
		var f := {n = features.size() + 1, element = i, kind = _kind(e), title = TrailElementLibrary.title(e.profile), from = _r(from), to = _r(to),
			height = _r(e.height), length = _r(e.length)}
		match e.profile:
			T.GAP:
				var lip := from + e.gap_lip()
				var gs := e.gap_speed()
				f.merge({lip = _r(lip), land_from = _r(lip + e.gap), land_to = _r(to - 1.0), ideal_land = _r(lip + e.gap + 2.5),
					speed_lo = _r(gs - 1.5), speed_hi = _r(gs + 2.5), gap = _r(e.gap)})
			T.TABLETOP:
				var face := clampf(e.height / (TrailElement.LIP_MAX * e.length) * 2.0, 0.25, 0.35)
				f.merge({lip = _r(from + face * e.length), land_from = _r(from + 0.7 * e.length), land_to = _r(to + 2.0),
					ideal_land = _r(from + 0.78 * e.length), speed_lo = _r(8.5 + 1.5 * e.height), speed_hi = _r(13.0 + 1.5 * e.height)})
			T.ROLLER:
				f.merge({lip = _r(e.station), land_from = _r(e.station), land_to = _r(to + 3.0), ideal_land = _r(to - e.length * 0.2)})
			T.DROP:
				var edge := from + e.length * TrailElement.DROP_LIP + TrailElement.DROP_EDGE * 0.5
				f.merge({lip = _r(edge), land_from = _r(edge), land_to = _r(to + 4.0), ideal_land = _r(edge + 3.0), speed_lo = 4.0})
			T.NORTHSHORE:
				f.merge({deck_half = _r(e.gap * 0.5), bridge = e.skew > 0.5})
				if e.skew <= 0.5: f.merge({lip = _r(to), land_from = _r(to), land_to = _r(to + 5.0), ideal_land = _r(to + 2.0)})
		if e.profile in TURNS or e.profile == T.ROLLOVER or e.profile == T.DIP or e.profile in RHYTHM or f.kind == "tech":
			f.merge(_turn(d, from, to, e.profile))
		if e.profile in RHYTHM:
			var crests := []
			for k in e.count: crests.append(_r(from + e.length * (k + 0.5) / e.count))
			f.crests = crests
		if f.kind == "tech":
			f.lines = Array(TrailTechnical.line_offsets(d, e)).map(func(v: float) -> float: return _r(v))
			f.speed_hi = TECH_SPEED
		features.append(f)
	# повороты оси без своего элемента
	var length := d.route_length()
	var s := 2.0
	while s < length - 2.0:
		if absf(d.curvature_at(s)) < 1.0 / TURN_R or _inside(covered, s):
			s += 1.0
			continue
		var from := s
		var sign := signf(d.curvature_at(s))
		while s < length - 2.0 and absf(d.curvature_at(s)) >= 0.7 / TURN_R and signf(d.curvature_at(s)) == sign and not _inside(covered, s): s += 1.0
		if s - from >= 4.0:
			var f := {n = 0, element = -1, kind = "turn", title = "Поворот трассы", from = _r(from), to = _r(s)}
			f.merge(_turn(d, from, s, -1))
			features.append(f)
		s += 1.0
	features.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.from < b.from)
	for i in features.size(): features[i].n = i + 1

## Самый тугой радиус оси на [from, to], сторона поворота и рабочая скорость (оценка).
func _turn(d: TrailDefinition, from: float, to: float, profile: int) -> Dictionary:
	var peak := 0.0
	var side := 0.0
	var s := from
	while s <= to:
		var k := d.curvature_at(s)
		if absf(k) > peak:
			peak = absf(k)
			side = signf(k)
		s += 1.0
	if peak < 1.0 / 200.0: return {}
	var radius := 1.0 / peak
	var gain := BERM_GAIN if profile in [T.BERM, T.S_BERM] else (OFF_CAMBER_LOSS if profile == T.OFF_CAMBER else 1.0)
	# средний радиус оси на участке: длина на поворот курса — с ним сравнивается проеханный радиус
	var turned := 0.0
	s = from
	while s < to:
		turned += absf(wrapf(d.heading_at(minf(s + 1.0, to)) - d.heading_at(s), -PI, PI))
		s += 1.0
	return {radius = _r(radius), mean_radius = _r((to - from) / maxf(turned, 0.001)), turn_deg = _r(rad_to_deg(turned)),
		side = "влево" if side > 0.0 else "вправо", turn_speed = _r(sqrt(LAT * gain * radius))}

static func _kind(e: TrailElement) -> String:
	if e.profile in JUMPS or (e.profile == T.NORTHSHORE and e.skew <= 0.5): return "jump"
	if e.profile == T.NORTHSHORE: return "deck"
	if e.profile in TURNS: return "turn"
	if e.profile in RHYTHM: return "rhythm"
	if TrailElement.places_objects(e.profile) or e.profile in [T.RUTS, T.ROUGH]: return "tech"
	return "terrain"

static func _inside(covered: Array[Vector2], s: float) -> bool:
	for c: Vector2 in covered:
		if s > c.x - LEAD and s < c.y + TAIL: return true
	return false

static func _r(v: float) -> float:
	return snappedf(v, 0.1)

## Ожидаемый отступ от оси на станции: ближайшая к оси чистая линия технического элемента, иначе ось.
func line_target(station: float) -> float:
	if route == null: return 0.0
	for e in route.elements:
		if not TrailElement.places_objects(e.profile) or e.profile == T.NORTHSHORE: continue
		if absf(station - e.station) > e.length * 0.5: continue
		var best := INF
		for line in TrailTechnical.line_offsets(route, e):
			var at := TrailTechnical.line_at(route, e, line, station)
			if absf(at) < absf(best): best = at
		return best if is_finite(best) else 0.0
	return 0.0

## Номер участка (в features), в котором лежит станция, или -1.
func feature_at(station: float) -> int:
	for i in features.size():
		var f: Dictionary = features[i]
		if station >= f.from - LEAD and station <= f.to + TAIL: return i
	return -1

## Такт: станция и знаковый отступ от оси (+ вправо). Возвращает законченный проезд участка или пустой словарь.
func tick(bike: BikeRide, station: float, lateral: float, dt: float, t: float, crashed := false) -> Dictionary:
	if route == null or station < 0.0: return {}
	var done := {}
	# полёт целиком: взлёт и приземление по станции
	if bike.airborne and _air_from < 0.0:
		_air_from = _prev_station if _prev_station >= 0.0 else station
		_air_time = 0.0
		_air_y0 = bike.y
		_air_apex = 0.0
		_air_v = bike.horizontal_velocity().length()
	if bike.airborne:
		_air_time += dt
		_air_apex = maxf(_air_apex, bike.y - _air_y0)
	var landed := {}
	if not bike.airborne and _air_from >= 0.0:
		if _air_time >= 0.12: landed = {takeoff = _r(_air_from), land = _r(station), air = snappedf(_air_time, 0.01), apex = _r(_air_apex),
			takeoff_speed = _r(_air_v), impact = _r(bike.land_impact)}
		_air_from = -1.0
	var index := feature_at(station)
	if index != _current:
		done = _close()
		_current = index
		if index >= 0: _open(index, bike, station, lateral, t)
	if _current >= 0:
		var p := _pass
		var f: Dictionary = features[_current]
		var speed := bike.horizontal_velocity().length()
		p.exit_speed = _r(speed)
		p.min_speed = minf(p.min_speed, _r(speed))
		p.max_speed = maxf(p.max_speed, _r(speed))
		var off := lateral - line_target(station)
		p.max_lateral = maxf(p.max_lateral, _r(absf(lateral)))
		p.max_line_off = maxf(p.max_line_off, _r(absf(off)))
		p.off_route = maxf(p.off_route, _r(absf(lateral) - route.width * 0.5))
		if not bike.airborne:
			p.max_slip = maxf(p.max_slip, _r(absf(rad_to_deg(bike.slip))))
			p.brake_time += dt if bike.brake_pressure > 0.1 else 0.0
			# проеханный радиус: путь на изменение курса, только где рама действительно поворачивает
			if _prev_station >= 0.0 and station >= f.from and station <= f.to:
				var dh := absf(wrapf(bike.heading - _prev_heading, -PI, PI))
				p._turned += dh
				p._path += speed * dt
		p.time += dt
		p.hits += int(bike.wheel_impact != Vector2.ZERO)
		p.bottom_outs += int(bike.bottom_out > 0.0)
		if crashed and not p.crashed:
			p.crashed = true
			p.crash_at = _r(station)
			p.crash_cause = BikeRide.CrashCause.keys()[bike.crash_cause]
		if not landed.is_empty(): (p.flights as Array).append(landed)
	_prev_heading = bike.heading
	_prev_station = station
	return done

## Закончить текущий участок (конец поездки или смена участка).
func finish() -> Dictionary:
	var done := _close()
	_current = -1
	return done

func _open(index: int, bike: BikeRide, station: float, lateral: float, t: float) -> void:
	var speed := bike.horizontal_velocity().length()
	_pass = {n = features[index].n, title = features[index].title, kind = features[index].kind, t = snappedf(t, 0.01),
		entry_station = _r(station), entry_speed = _r(speed), entry_lateral = _r(lateral),
		entry_heading_err = _r(rad_to_deg(wrapf(bike.heading - route.heading_at(station), -PI, PI))),
		exit_speed = _r(speed), min_speed = _r(speed), max_speed = _r(speed), max_lateral = 0.0, max_line_off = 0.0, off_route = 0.0,
		max_slip = 0.0, brake_time = 0.0, time = 0.0, hits = 0, bottom_outs = 0, crashed = false, flights = [], _turned = 0.0, _path = 0.0}

func _close() -> Dictionary:
	if _current < 0 or _pass.is_empty(): return {}
	var p := _pass
	var f: Dictionary = features[_current]
	if p._turned > 0.05: p.driven_radius = _r(p._path / p._turned)
	p.erase("_turned")
	p.erase("_path")
	p.brake_time = snappedf(p.brake_time, 0.01)
	p.time = snappedf(p.time, 0.01)
	p.verdict = _verdict(f, p)
	passes.append(p)
	_pass = {}
	return p

## Итог проезда словами: главное отклонение от ожидания.
func _verdict(f: Dictionary, p: Dictionary) -> String:
	var notes := PackedStringArray()
	if p.crashed: notes.append("ПАДЕНИЕ %s у %.0f м" % [p.crash_cause, p.crash_at])
	var speed_note := ""
	if f.has("speed_lo") and p.entry_speed < f.speed_lo: speed_note = "медленно на входе (%.1f м/с при %.1f–%.1f)" % [p.entry_speed, f.speed_lo, f.get("speed_hi", INF)]
	elif f.has("speed_hi") and p.entry_speed > f.speed_hi + (1.5 if f.kind == "tech" else 0.0):
		speed_note = "быстро на входе (%.1f м/с при %s%.1f)" % [p.entry_speed, ("%.1f–" % f.speed_lo) if f.has("speed_lo") else "до ", f.speed_hi]
	# у прыжка скорость — только объяснение промаха: попал в зону — скорость была рабочей
	if not speed_note.is_empty() and f.kind != "jump": notes.append(speed_note)
	if f.kind == "jump":
		var main: Dictionary = {}
		for fl: Dictionary in p.flights:
			if fl.takeoff >= f.from - 2.0 and fl.takeoff <= f.to:
				main = fl
				break
		if main.is_empty(): notes.append("без отрыва (перекатился)")
		else:
			p.takeoff_vs_lip = _r(main.takeoff - f.lip)
			p.land_vs_ideal = _r(main.land - f.ideal_land)
			var table := route.elements[f.element].profile == T.TABLETOP if f.element >= 0 else false
			if main.land < f.land_from and table and main.land > f.lip:
				notes.append("на стол: %.1f м до спуска (с %.0f м), удар %.1f" % [f.land_from - main.land, f.land_from, main.impact])
			elif main.land < f.land_from: notes.append("недолёт %.1f м до зоны приземления (с %.0f м), удар %.1f" % [f.land_from - main.land, f.land_from, main.impact])
			elif main.land > f.land_to: notes.append("перелёт %.1f м за зону приземления (до %.0f м), удар %.1f" % [main.land - f.land_to, f.land_to, main.impact])
			if main.land < f.land_from or main.land > f.land_to:
				if not speed_note.is_empty(): notes.append(speed_note)
			else: p.landed_in_zone = true
	if f.has("mean_radius") and p.has("driven_radius") and f.kind in ["turn", "terrain"]:
		if p.driven_radius > f.mean_radius * 1.3 + 2.0 or p.max_lateral > route.width * 0.45:
			notes.append("дуга шире оси: %.0f м при среднем радиусе %.0f м (тугой %.0f), вынос до %.1f м" % [p.driven_radius, f.mean_radius, f.radius, p.max_lateral])
	if f.kind == "rhythm":
		var hops := 0
		for fl: Dictionary in p.flights: hops += 1
		if hops > 0: notes.append("отрывов на волнах: %d (памп должен держать колёса на земле)" % hops)
		p.speed_gain = _r(p.exit_speed - p.entry_speed)
	if f.kind == "tech" and p.max_line_off > 0.6: notes.append("сошёл с чистой линии на %.1f м" % p.max_line_off)
	if f.kind == "deck" and p.max_lateral > f.deck_half: notes.append("съехал с настила (отступ %.1f м при полуширине %.1f)" % [p.max_lateral, f.deck_half])
	if p.off_route > 0.0: notes.append("вне полотна на %.1f м" % p.off_route)
	if p.max_slip > 8.0: notes.append("снос до %.0f°" % p.max_slip)
	if p.hits > 0: notes.append("удары колёс: %d" % p.hits)
	if p.bottom_outs > 0: notes.append("пробои подвески: %d" % p.bottom_outs)
	return "чисто" if notes.is_empty() else "; ".join(notes)

## Таблица для сводки: по участкам — ожидание, число проездов, медианы входа и итоги.
func table() -> PackedStringArray:
	var lines := PackedStringArray()
	for f: Dictionary in features:
		var mine := passes.filter(func(p: Dictionary) -> bool: return p.n == f.n)
		if mine.is_empty(): continue
		var expect := PackedStringArray()
		if f.has("speed_lo"): expect.append("скорость %.1f–%s м/с" % [f.speed_lo, ("%.1f" % f.speed_hi) if f.has("speed_hi") else "…"])
		elif f.has("speed_hi"): expect.append("до %.1f м/с" % f.speed_hi)
		if f.has("lip"): expect.append("кромка %.0f м" % f.lip)
		if f.has("land_from"): expect.append("приземление %.0f–%.0f м" % [f.land_from, f.land_to])
		if f.has("radius"): expect.append("R %.0f м %s, ~%.1f м/с" % [f.radius, f.side, f.turn_speed])
		var entries := mine.map(func(p: Dictionary) -> float: return p.entry_speed)
		entries.sort()
		var clean := mine.filter(func(p: Dictionary) -> bool: return p.verdict == "чисто").size()
		lines.append("%2d · %s %.0f–%.0f м · ожидание: %s · проездов %d (чисто %d) · вход медиана %.1f м/с" % [
			f.n, f.title, f.from, f.to, ", ".join(expect) if not expect.is_empty() else "—", mine.size(), clean, entries[entries.size() / 2]])
		for p: Dictionary in mine:
			if p.verdict != "чисто": lines.append("      t=%.1f с · вход %.1f м/с, отступ %+.1f м · %s" % [p.t, p.entry_speed, p.entry_lateral, p.verdict])
	return lines

## Строка для F3: текущий или ближайший участок впереди с ожиданиями и итог прошлого проезда.
func live(station: float, speed: float) -> String:
	if route == null or station < 0.0: return ""
	var lines := PackedStringArray()
	for f: Dictionary in features:
		if f.to + TAIL < station: continue
		var expect := PackedStringArray()
		if f.has("speed_lo"): expect.append("вход %.1f–%s м/с" % [f.speed_lo, ("%.1f" % f.speed_hi) if f.has("speed_hi") else "…"])
		elif f.has("speed_hi"): expect.append("до %.1f м/с" % f.speed_hi)
		if f.has("lip"): expect.append("кромка через %.0f м" % (f.lip - station) if f.lip > station else "кромка позади")
		if f.has("land_from"): expect.append("приземление %.0f–%.0f м" % [f.land_from, f.land_to])
		if f.has("radius"): expect.append("R %.0f м %s, ~%.1f м/с" % [f.radius, f.side, f.turn_speed])
		lines.append("Участок %d · %s %s %.0f м: %s · сейчас %.1f м/с" % [f.n, f.title, "через" if f.from > station else "на", absf(f.from - station) if f.from > station else station,
			", ".join(expect) if not expect.is_empty() else "—", speed])
		break
	if not passes.is_empty():
		var p: Dictionary = passes[-1]
		lines.append("Прошлый участок %d · %s: %s" % [p.n, p.title, p.verdict])
	return "\n".join(lines)
