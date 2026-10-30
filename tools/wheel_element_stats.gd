extends SceneTree
## Проходимость элементов готовых трасс Trail Lab (TrailLabCatalog) в модели двух контактов: старт за 12 м до каждого
## элемента с заданной скоростью, проезд до 6 м после него, разные манеры руля и газа. Печатает каждый заезд одной
## строкой (для сводки) и итог по видам элементов. Только замеры, проверок нет.
##   godot --headless --path . --script res://tools/wheel_element_stats.gd -- --presets 2,3 [--speeds 4,8,12,16]
const Fixture = preload("res://tools/trail_lab_fixture.gd")
## руль: smooth — подруливание к точке впереди; taps — клавиша: полный руль, пока курс отстаёт больше 9°, иначе прямо;
## once — один раз зажал полный руль в сторону поворота до совпадения курса, дальше прямо.
## газ: hold — держать скорость входа; release — отпустить на входе в элемент; brake — затормозить до 60 % перед ним.
static var TRACE := false
const MANNERS := [["плавно, газ", "smooth", "hold"], ["плавно, сброс", "smooth", "release"], ["плавно, торможение", "smooth", "brake"],
	["нажатиями, газ", "taps", "hold"], ["зажал раз, газ", "once", "hold"]]


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 560)
	run.call_deferred()


## Точка чистой линии на станции: у технических элементов — их свободный проход (TrailTechnical.line_at: змейка
## слалома, объезд брёвен, линия каменного сада), иначе ось. Так едет седок, который видит линию.
func clean_line(d: TrailDefinition, station: float) -> Vector2:
	for e in d.elements:
		if not TrailElement.places_objects(e.profile) or absf(station - e.station) > e.length * 0.5 + 1.0: continue
		var offsets := TrailTechnical.line_offsets(d, e)
		var across := TrailTechnical.line_at(d, e, offsets[0], station)
		var t := d.tangent_at(station)
		return d.point_at(station) + Vector2(t.y, -t.x) * across
	return d.point_at(station)


func ride(h: Heightfield, d: TrailDefinition, e: TrailElement, speed: float, manner: Array) -> Dictionary:
	var dt := 1.0 / 60.0
	var length := d.route_length()
	var start := maxf(1.0, e.station - e.length * 0.5 - 12.0)
	var enter := e.station - e.length * 0.5
	var finish := minf(length - 1.0, e.station + e.length * 0.5 + 6.0)
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = true
	var at := d.point_at(start)
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(start)
	b.mount(p)
	b.speed = speed
	var control := BikeController.new()
	var r := {result = "не доехал", entry = -1.0, exit = 0.0, off = 0.0, slip = 0.0, air = 0.0, land = 0.0, front_limit = 0.0, hits = 0, time = 0.0, side = ""}
	var station := start
	var once := 0 # 0 — ещё не нажимал, 1 — держит, 2 — отпустил
	var once_sign := 0.0
	var t := 0.0
	h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1, true)
	while t < 25.0:
		var near := d.nearest(Vector2(b.x, b.z))
		if near.x > station - 20.0: station = maxf(station, near.x)
		if station >= finish:
			r.result = "проехал" if r.off < 0.01 else "проехал со сходом"
			break
		# в технических элементах седок смотрит ближе: линия петляет между препятствиями
		var look := maxf(4.0, absf(b.speed) * 0.6)
		if TrailElement.places_objects(e.profile) and station > enter - 3.0 and station < e.station + e.length * 0.5: look = clampf(absf(b.speed) * 0.35, 1.8, 3.0)
		var aim := clean_line(d, minf(station + look, length))
		var delta := aim - Vector2(b.x, b.z)
		var error := wrapf(atan2(-delta.x, -delta.y) - b.heading, -PI, PI)
		var steer := 0.0
		match manner[1]:
			"smooth": steer = clampf(-error * 2.0, -1.0, 1.0)
			"taps": steer = -signf(error) if absf(error) > 0.15 else 0.0
			"once":
				# до элемента — как плавно; в элементе один раз полный руль, пока курс не догонит
				if station < enter: steer = clampf(-error * 2.0, -1.0, 1.0)
				elif once == 0 and absf(error) > 0.1:
					once = 1
					once_sign = -signf(error)
				if once == 1:
					steer = once_sign
					if -signf(error) != once_sign or absf(error) < 0.03: once = 2
		# держит скорость в обе стороны: на спуске подтормаживает, если разогнался больше чем на 1 м/с
		var throttle := clampf((speed - b.speed) * 0.8, 0.0, 1.0) if b.speed < speed + 1.0 else -clampf((b.speed - speed - 1.0) * 0.5, 0.2, 1.0)
		if manner[2] == "release" and station >= enter: throttle = 0.0
		if manner[2] == "brake" and station >= enter - 8.0 and station < enter: throttle = -1.0 if b.speed > speed * 0.6 else 0.0
		elif manner[2] == "brake" and station >= enter: throttle = clampf((speed * 0.6 - b.speed) * 0.8, 0.0, 1.0)
		h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1)
		var was_air := b.airborne
		control.ride(dt, p, b, h.world, h, throttle, steer, false, false, false)
		t += dt
		if station >= enter and r.entry < 0.0: r.entry = b.speed
		if TRACE and station >= enter - 2.0 and int(t * 60.0) % 6 == 0:
			print("  T %.0f м v %.1f · бок полотна %+.2f · рыскание %+.2f · шина %.2f/%.2f · с оси %+.2f · снос %.0f°" % [station, b.speed, b.bank_slope, b._yaw_rate, b.side_f, b.side_r, near.y, rad_to_deg(b.slip)])
		if b.crashed:
			# упал ещё до элемента (старт в хвосте предыдущего) — не заезд этого элемента
			r.result = "падение " + str(BikeRide.CrashCause.keys()[b.crash_cause]) if r.entry >= 0.0 else "старт в другом элементе"
			break
		if station >= enter:
			var lateral := d.nearest(Vector2(b.x, b.z)).y
			if absf(lateral) > d.width * 0.5:
				r.off += dt
				# наружу поворота или внутрь (срезал): знак смещения против знака кривизны
				# смещение к центру поворота отрицательно при положительной кривизне (TrailDefinition._project)
				if r.side == "": r.side = "наружу" if signf(lateral) == signf(d.curvature_at(station)) else "внутрь"
			r.slip = maxf(r.slip, absf(b.slip))
			if b.airborne: r.air += dt
			if absf(steer) > 0.0 and b.use_f > 0.98: r.front_limit += dt
		if was_air and b.land_impact > 0.0: r.land = maxf(r.land, b.land_impact)
		b.land_impact = 0.0
		if absf(b.speed) < 0.2 and t > 1.5:
			r.result = "встал"
			break
	r.exit = b.speed
	r.hits = b.impacts.x
	r.time = t
	return r


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var presets := range(1, TrailLabCatalog.LIST.size() + 1)
	if "--presets" in args: presets = Array(args[args.find("--presets") + 1].split(",")).map(func(x: String) -> int: return int(x))
	var speeds := [4.0, 8.0, 12.0, 16.0]
	if "--speeds" in args: speeds = Array(args[args.find("--speeds") + 1].split(",")).map(func(x: String) -> float: return float(x))
	TRACE = "--trace" in args
	var kinds := PackedStringArray()
	if "--kinds" in args: kinds = args[args.find("--kinds") + 1].split(",")
	var summary := {}
	for number: int in presets:
		var spec: Dictionary = TrailLabCatalog.LIST[number - 1]
		var kit := TrailLabCatalog.routes(number - 1, Fixture)
		var prepared := Fixture.prepare(kit, true, spec.ground)
		if not prepared.errors.is_empty():
			print("трасса %d не собрана: %s" % [number, prepared.errors])
			continue
		var h: Heightfield = prepared.heights
		var technical := TrailTechnical.build(h, kit)
		h.obstacles.set_trail(technical.collide, technical.bumps)
		var d := kit[0]
		print("ТРАССА %d %s (%d элементов)" % [number, spec.title, d.elements.size()])
		for e in d.elements:
			var kind := TrailElementLibrary.title(e.profile)
			if not kinds.is_empty() and not kind in kinds: continue
			var bend := absf(d.curvature_at(e.station))
			for speed: float in speeds:
				for manner: Array in MANNERS:
					var r := ride(h, d, e, speed, manner)
					print("Э|%d|%s|%.0f|R%.0f|h%.2f|%.0f|%s|%s|%.1f|%.1f|%.1f|%.0f|%.1f|%.1f|%.1f|%d" % [number, kind, e.station, 1.0 / maxf(bend, 0.001), e.height, speed, manner[0],
						r.result + ("" if r.side == "" else " " + r.side), r.entry, r.exit, r.off, rad_to_deg(r.slip), r.air, r.land, r.front_limit, r.hits])
					if r.result == "старт в другом элементе": continue
					var key := "%s|%.0f|%s" % [kind, speed, manner[0]]
					var s: Dictionary = summary.get(key, {n = 0, ok = 0, off = 0, crash = 0, stop = 0, keep = 0.0})
					s.n += 1
					s.ok += int(r.result == "проехал")
					s.off += int(r.result == "проехал со сходом" or r.off > 0.0)
					s.crash += int(str(r.result).begins_with("падение"))
					s.stop += int(r.result == "встал" or r.result == "не доехал")
					s.keep += r.exit / maxf(r.entry, 0.5) if r.entry > 0.0 else 0.0
					summary[key] = s
	print("ИТОГ вид|скорость|манера|заездов|чисто|сход|падение|встал|сохранил скорость")
	var keys := summary.keys()
	keys.sort()
	for key: String in keys:
		var s: Dictionary = summary[key]
		print("И|%s|%d|%d|%d|%d|%d|%.2f" % [key, s.n, s.ok, s.off, s.crash, s.stop, s.keep / s.n])
	quit(0)
