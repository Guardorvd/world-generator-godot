extends SceneTree
const TrailStandards := preload("res://scripts/trails/trail_standards.gd")
## Стенд стандартов элементов (01.11): прямая без мира, один элемент, заезды ровным газом с разной скоростью.
## Два режима:
##   замеры (по умолчанию) — элементы прежних размеров на 7–17 м/с: взлёт, полёт, место приземления, удар; у пампа и
##     волн — отрыв колёс; у техники — удары о кромки, потеря скорости, падения. По ним подобраны числа TrailStandards.
##   `-- --check` — элементы, рассчитанные TrailStandards на скорость входа (8–17 м/с) и уровень, проезжаются на этой
##     скорости: попадает ли приземление в зону, держатся ли колёса на пампе, нет ли падения. Это проверка стандартов.
##   `-- --only gap,table,roller,drop,pump,waves,tech,berm` — только эти виды.
## Только замеры, секунды на элемент. Лимит 240 с.
##   godot --headless --path . --script res://tools/trail_standards_stand.gd [-- --check] [--only pump]
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const T := TrailElement.Profile
const SPEEDS := [7.0, 9.0, 11.0, 13.0, 15.0, 17.0]
const DT := 1.0 / 60.0

var only := PackedStringArray()
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if "--only" in args: only = args[args.find("--only") + 1].split(",")
	if "--check" in args: check()
	else: measure()
	quit(1 if failures > 0 else 0)

func wanted(kind: String) -> bool:
	return only.is_empty() or kind in only

## Прямая с одним элементом; built — {d, e, h} или пусто с напечатанной причиной.
func straight(e: TrailElement, width := 4.5, curve := 0.0) -> Dictionary:
	var d := TrailDefinition.new()
	d.id = "standards_stand"
	d.width = width
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 0.0
	if is_zero_approx(curve):
		d.points = PackedVector2Array([Vector2(128, 240), Vector2(128, 16)])
	else:
		# прямая 60 м, дуга радиуса 1/|curve| на 90°, прямая: вираж проверяется в одном ровном повороте
		var pts := PackedVector2Array()
		var r := 1.0 / absf(curve)
		var side := signf(curve)
		for i in 31: pts.append(Vector2(128 - side * r * 0.5, 240 - i * 2.0))
		var c := Vector2(128 - side * r * 0.5 + side * r, 180)
		for i in range(1, 31):
			var a := PI * 0.5 * i / 30.0
			pts.append(c + Vector2(-side * r * cos(a), -r * sin(a)))
		var end := pts[-1]
		for i in range(1, 31): pts.append(end + Vector2(side * i * 2.0, 0))
		d.points = pts
	d.elements = [e]
	var errors := d.validate()
	if not errors.is_empty():
		print("  отказ определения: ", errors)
		return {}
	var routes: Array[TrailDefinition] = [d]
	var prepared := Fixture.prepare(routes)
	if not prepared.errors.is_empty():
		print("  отказ сборки: ", prepared.errors)
		return {}
	var h: Heightfield = prepared.heights
	if TrailElement.places_objects(e.profile):
		var tech := TrailTechnical.build(h, routes)
		h.obstacles.set_trail(tech.collide, tech.bumps)
	return {d = d, e = e, h = h}

## Заезд ровным газом со скоростью v до `hold_to` (станция; INF — весь заезд), руль ведёт по оси (и по линии line).
func ride(b: Dictionary, v: float, hold_to := INF, line := 0.0, look := 6.0, free_bars := false) -> Dictionary:
	var d: TrailDefinition = b.d
	var e: TrailElement = b.e
	var h: Heightfield = b.h
	var p := PlayerState.new()
	var bike := BikeRide.new()
	bike.contact_model = true
	var from := e.station - e.length * 0.5 - 30.0
	var at := d.point_at(from)
	bike.x = at.x
	bike.z = at.y
	bike.y = h.surface_at(bike.x, bike.z, -INF)
	bike.heading = d.heading_at(from)
	bike.mount(p)
	bike.speed = v
	var control := BikeController.new()
	var r := {flights = [], crash = "", hits = 0, max_hit = 0.0, entry = 0.0, exit = 0.0, min_speed = INF, max_off = 0.0, lifts = 0, lift_time = 0.0, max_lateral_g = 0.0, bottoms = 0, max_slip = 0.0, on_rock = 0, rock_top = 0.0}
	var flight := {}
	var t := 0.0
	var start := e.station - e.length * 0.5
	var finish := e.station + e.length * 0.5
	while t < 16.0:
		var near := d.nearest(Vector2(bike.x, bike.z), 20.0)
		var station := near.x
		if station > finish + 14.0: break
		var throttle := clampf((v - bike.speed) * 0.6, 0.0, 1.0) if station < hold_to else 0.0
		var off := near.y - line
		var steer := clampf(-wrapf(d.heading_at(station + look) - bike.heading, -PI, PI) * 2.0 + off * 0.25, -1.0, 1.0)
		# руль отпущен на элементе: снос и поворот курса — только от самих камней
		if free_bars and station >= start - 2.0: steer = 0.0
		var was := bike.airborne
		var before := bike.speed
		bike.wheel_impact = Vector2()
		control.ride(DT, p, bike, h.world, h, throttle, steer, false, false, false)
		t += DT
		if station >= start and r.entry == 0.0: r.entry = before
		if station >= start - 1.0 and station <= finish + 8.0:
			r.min_speed = minf(r.min_speed, bike.speed)
			r.max_off = maxf(r.max_off, absf(off))
			var hit := maxf(bike.wheel_impact.x, bike.wheel_impact.y)
			if hit > 0.0:
				r.hits += 1
				r.max_hit = maxf(r.max_hit, hit)
			if bike.bottom_out > 0.0: r.bottoms += 1
			if bike._o_f > BikeRide.SLICK_BUMP or bike._o_r > BikeRide.SLICK_BUMP: r.on_rock += 1
			r.rock_top = maxf(r.rock_top, maxf(bike._o_f, bike._o_r))
			r.max_slip = maxf(r.max_slip, absf(rad_to_deg(bike.slip)))
			if not bike.airborne and absf(bike.speed) > 2.0:
				r.max_lateral_g = maxf(r.max_lateral_g, absf(bike.speed * bike._yaw_rate) / GameConfig.GRAVITY)
		if station <= finish + 8.0:
			r.exit = bike.speed
			r.exit_off = off
			r.exit_heading = rad_to_deg(wrapf(bike.heading - d.heading_at(station), -PI, PI))
		if bike.crashed:
			r.crash = "%s у %+.1f м" % [BikeRide.CrashCause.keys()[bike.crash_cause], station - start]
			break
		if bike.airborne and not was:
			flight = {takeoff = station - start, speed = before, y0 = bike.y, apex = 0.0, air = 0.0}
		if bike.airborne and not flight.is_empty():
			flight.air += DT
			flight.apex = maxf(flight.apex, bike.y - flight.y0)
		if was and not bike.airborne and not flight.is_empty():
			flight.land = station - start
			flight.impact = bike.land_impact
			if flight.air >= 0.12 and station >= start - 2.0 and station <= finish + 10.0: r.flights.append(flight)
			flight = {}
	for f: Dictionary in r.flights:
		r.lifts += 1
		r.lift_time += f.air
	return r

func describe_jump(r: Dictionary, lip: float, land_from: float) -> String:
	if not r.crash.is_empty(): return "ПАДЕНИЕ " + r.crash
	if r.flights.is_empty(): return "не взлетел"
	var f: Dictionary = r.flights[0]
	for g: Dictionary in r.flights:
		if g.air > f.air: f = g
	return "взлёт %.1f м/с у %+.1f · %.2f с · выше %.2f · приземление %+.1f от идеала · удар %.1f" % [f.speed, f.takeoff - lip, f.air, f.apex, f.land - land_from, f.impact]

## Замеры прежних размеров (как раньше ставил составитель): от них подобраны числа TrailStandards.
func measure() -> void:
	for c: Array in [["gap", T.GAP, 18.0, 1.4, 3.5], ["gap", T.GAP, 22.0, 1.7, 5.0], ["table", T.TABLETOP, 18.0, 1.1, 0.0], ["table", T.TABLETOP, 24.0, 2.0, 0.0]]:
		if not wanted(c[0]): continue
		var e := TrailElementLibrary.make(c[1], 100.0, c[2], c[3])
		if c[4] > 0.0: e.gap = c[4]
		var b := straight(e)
		if b.is_empty(): continue
		var z := TrailStandards.landing(e)
		print("\n%s · длина %.0f · высота %.1f · разрыв %.1f · кромка %.1f · зона %.1f/%.1f/%.1f" % [c[0], c[2], c[3], c[4], TrailStandards.lip(e), z.x, z.y, z.z])
		for v: float in SPEEDS:
			print("  %4.1f м/с: %s" % [v, describe_jump(ride(b, v, e.station - e.length * 0.5 + TrailStandards.lip(e)), TrailStandards.lip(e), z.y)])
			print("        модель: %s" % model_text(e, v, z.y))
	if wanted("roller"):
		for c: Array in [[10.0, 0.3], [13.0, 0.6], [16.0, 0.9]]:
			var e := TrailElementLibrary.make(T.ROLLER, 100.0, c[0], c[1])
			var b := straight(e)
			if b.is_empty(): continue
			print("\nроллер · длина %.0f · высота %.1f" % c)
			var z := TrailStandards.landing(e)
			for v: float in SPEEDS:
				print("  %4.1f м/с: %s" % [v, describe_jump(ride(b, v, e.station), c[0] * 0.5, z.y)])
				print("        модель: %s" % model_text(e, v, z.y))
	if wanted("drop"):
		for c: Array in [[12.0, 0.5], [15.0, 0.9], [18.0, 1.2]]:
			var e := TrailElementLibrary.make(T.DROP, 100.0, c[0], c[1])
			var b := straight(e)
			if b.is_empty(): continue
			var edge: float = c[0] * TrailElement.DROP_LIP + TrailElement.DROP_EDGE * 0.5
			print("\nдроп · длина %.0f · высота %.1f · кромка %.1f" % [c[0], c[1], edge])
			var z := TrailStandards.landing(e)
			for v: float in [4.0, 6.0] + SPEEDS:
				print("  %4.1f м/с: %s" % [v, describe_jump(ride(b, v, e.station), edge, z.y)])
				print("        модель: %s" % model_text(e, v, z.y))
	if wanted("pump") or wanted("waves"):
		for c: Array in [[T.PUMP, 4.8, 0.3, 4], [T.PUMP, 5.5, 0.55, 4], [T.PUMP, 7.0, 0.55, 4], [T.WAVES, 8.5, 0.15, 3], [T.WAVES, 10.0, 0.35, 3]]:
			if not wanted("pump" if c[0] == T.PUMP else "waves"): continue
			var e := TrailElementLibrary.make(c[0], 100.0, c[1] * c[3], c[2], 1.0, c[3])
			var b := straight(e)
			if b.is_empty(): continue
			print("\n%s · шаг %.1f · высота %.2f · гребней %d" % [TrailElementLibrary.title(c[0]), c[1], c[2], c[3]])
			for v: float in [5.0, 7.0] + SPEEDS:
				var r := ride(b, v)
				print("  %4.1f м/с: %s" % [v, "ПАДЕНИЕ " + r.crash if not r.crash.is_empty() else "отрывов %d (%.2f с) · выход %.1f м/с" % [r.lifts, r.lift_time, r.exit]])
	if wanted("tech"):
		for c: Array in [[T.ROCK_GARDEN, 16.0, 0.18, 0.6], [T.ROOTS, 14.0, 0.15, 0.6], [T.ROCK_GARDEN, 16.0, 0.12, 0.4]]:
			var e := TrailElementLibrary.make(c[0], 100.0, c[1], c[2])
			e.density = c[3]
			e.lines = 2
			e.seed = 7
			var b := straight(e, 4.0)
			if b.is_empty(): continue
			var lines := TrailTechnical.line_offsets(b.d, e)
			print("\n%s · длина %.0f · высота %.2f · плотность %.1f · линии %s" % [TrailElementLibrary.title(c[0]), c[1], c[2], c[3], lines])
			for v: float in SPEEDS:
				var rocky := rocky_lane(b.d, lines)
				var over := ride(b, v, INF, rocky)
				var clean := ride(b, v, INF, lines[0])
				var loose := ride(b, v, INF, rocky, 6.0, true)
				print("  %4.1f м/с: по камням (%+.1f м) — %s · по чистой линии — %s" % [v, rocky, tech_text(over), tech_text(clean)])
				print("          руль отпущен на камнях: на выходе в %+.2f м от полосы, курс %+.1f°, −%.1f м/с" % [loose.exit_off, loose.exit_heading, loose.entry - loose.min_speed])
	if wanted("berm"):
		for c: Array in [[12.0, 0.8], [20.0, 0.8], [30.0, 0.8], [20.0, 0.0]]:
			var e := TrailElementLibrary.make(T.BERM if c[1] > 0.0 else T.ROLLOVER, 0.0, 1.0, 0.01)
			var r_axis: float = c[0]
			var arc := PI * 0.5 * r_axis
			e.station = 60.0 + arc * 0.5
			e.length = arc + 6.0
			e.height = c[1] if c[1] > 0.0 else 0.05
			e.bank = 1.0
			var b := straight(e, 4.5, 1.0 / r_axis)
			if b.is_empty(): continue
			print("\n%s · радиус оси %.0f м · высота %.1f" % ["вираж" if c[1] > 0.0 else "поворот без виража", r_axis, c[1]])
			for v: float in SPEEDS:
				var r := ride(b, v, INF, 0.0, 4.0)
				print("  %4.1f м/с: вынос до %.1f м · боковая %.2f g · %s" % [v, r.max_off, r.max_lateral_g, "ПАДЕНИЕ " + r.crash if not r.crash.is_empty() else "выход %.1f м/с" % r.exit])

func model_text(e: TrailElement, v: float, ideal: float) -> String:
	var f := TrailStandards.fly(e, v)
	if not f.flew: return "не взлетает" if not f.stalled else "не въезжает"
	return "взлёт %.1f м/с у %+.1f · %.2f с · выше %.2f · приземление %+.1f от идеала · удар %.1f" % [f.takeoff_speed, f.takeoff - TrailStandards.lip(e), f.air, f.apex, f.land - ideal, f.impact]

## Полоса дальше всего от чистых линий (там объекты гуще всего), м от оси.
func rocky_lane(d: TrailDefinition, lines: PackedFloat32Array) -> float:
	var edge := d.width * 0.5 * TrailTechnical.EDGE - 0.3
	var best := 0.0
	var far := -1.0
	var at := -edge
	while at <= edge:
		var gap := INF
		for l in lines: gap = minf(gap, absf(at - l))
		if gap > far:
			far = gap
			best = at
		at += 0.1
	return best

func tech_text(r: Dictionary) -> String:
	if not r.crash.is_empty(): return "ПАДЕНИЕ " + r.crash
	return "ударов %d (до %.1f) · −%.1f м/с · отступ %.1f · пробоев %d · снос %.0f° · на камне %d тактов, до %.2f м" % [r.hits, r.max_hit, r.entry - r.min_speed, r.max_off, r.bottoms, r.max_slip, r.on_rock, r.rock_top]

## Проверка: элементы по TrailStandards на скорость входа v, проезд на этой скорости.
func check() -> void:
	var levels := TrailStandards.LEVELS.size()
	var fails := []
	for kind: String in ["table", "gap", "roller", "drop", "pump", "tech", "berm"]:
		if not wanted(kind): continue
		print("\n— %s —" % kind)
		for level in levels:
			for v: float in TrailStandards.DESIGN_SPEEDS:
				var spec := TrailStandards.spec(kind, v, level)
				if spec.is_empty():
					var why := TrailStandards.why_not(kind, v, level)
					print("  %s · %4.1f м/с: не ставится (%s)" % [TrailStandards.LEVELS[level].title, v, why if not why.is_empty() else "нет размеров, при которых приземление на идеал"])
					continue
				var e := TrailStandards.element(spec, 100.0 + spec.length * 0.5 - 0.0)
				e.station = 100.0
				var curve: float = 1.0 / spec.radius if kind == "berm" else 0.0
				if kind == "berm": e.station = 60.0 + spec.length * 0.5 - 3.0
				var b := straight(e, 4.5, curve)
				if b.is_empty():
					fails.append("%s %s %.0f: не собрался" % [kind, level, v])
					continue
				var w := TrailStandards.window(e, b.d)
				var r := ride(b, v, (e.station - e.length * 0.5 + float(w.get("lip", e.length * 0.5))) if kind in ["table", "gap", "roller", "drop"] else INF, 0.0, 4.0 if kind == "berm" else 6.0)
				var verdict := judge(kind, e, w, r, v)
				print("  %s · %4.1f м/с · %s → %s" % [TrailStandards.LEVELS[level].title, v, TrailStandards.text(spec), verdict.text])
				if not verdict.ok: fails.append("%s %s %.0f м/с: %s" % [kind, TrailStandards.LEVELS[level].title, v, verdict.text])
	print("\nИТОГ: %d несоответствий" % fails.size())
	for f: String in fails: print("  ✗ " + f)
	failures = fails.size()

func judge(kind: String, e: TrailElement, w: Dictionary, r: Dictionary, v: float) -> Dictionary:
	if not r.crash.is_empty(): return {ok = false, text = "ПАДЕНИЕ " + r.crash}
	var start := e.station - e.length * 0.5
	match kind:
		"table", "gap", "roller", "drop":
			if r.flights.is_empty():
				# роллер перекатывают; низкий дроп (до 0,6 м) на малой скорости скатывают — оба допустимо
				var rolled := kind == "roller" or (kind == "drop" and e.height <= 0.6)
				return {ok = rolled, text = "не взлетел" + (" (перекатывается — допустимо)" if rolled else "")}
			var f: Dictionary = r.flights[0]
			for g: Dictionary in r.flights:
				if g.air > f.air: f = g
			var land: float = f.land + start
			var ok: bool = land >= float(w.land_from) - 0.5 and land <= float(w.land_to) + 0.5 and f.impact < TrailStandards.IMPACT_SOFT
			return {ok = ok, text = "приземление %+.1f м от идеала (зона %+.1f…%+.1f), удар %.1f" % [land - float(w.ideal_land), float(w.land_from) - float(w.ideal_land), float(w.land_to) - float(w.ideal_land), f.impact]}
		"pump":
			return {ok = r.lift_time < 0.25, text = "отрывов %d (%.2f с), выход %.1f м/с" % [r.lifts, r.lift_time, r.exit]}
		"tech":
			return {ok = r.max_hit < TrailStandards.IMPACT_SOFT, text = "ударов %d до %.1f, −%.1f м/с" % [r.hits, r.max_hit, r.entry - r.min_speed]}
		"berm":
			return {ok = r.max_off <= 1.5, text = "вынос %.1f м, боковая %.2f g" % [r.max_off, r.max_lateral_g]}
	return {ok = true, text = ""}
