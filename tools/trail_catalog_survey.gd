extends SceneTree
## Обзор готовых трасс Trail Lab (TrailLabCatalog): что на каждой есть и что на ней происходит с велосипедом.
## Геометрия (длина, ширина, повороты по радиусу, перепад), элементы по видам и один заезд автопилотом в модели двух
## контактов (осторожно 9 м/с): время, сходы, полёт, встречи с препятствиями, гребни без опоры, сильнейшее приземление.
## Только замеры, проверок нет.
##   godot --headless --path . --script res://tools/trail_catalog_survey.gd [-- --presets 2,5]
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const LAT_SAFE := 6.0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()


func geometry(h: Heightfield, d: TrailDefinition) -> Dictionary:
	var length := d.route_length()
	var tight := 0.0
	var medium := 0.0
	var min_r := INF
	var lo := INF
	var hi := -INF
	var climb := 0.0
	var prev := NAN
	var s := 0.0
	while s < length:
		var k := absf(d.curvature_at(s))
		if k > 1.0 / 15.0: tight += 1.0
		elif k > 1.0 / 35.0: medium += 1.0
		if k > 0.0001: min_r = minf(min_r, 1.0 / k)
		var p := d.point_at(s)
		var g := h.ground_at(p.x, p.y)
		lo = minf(lo, g)
		hi = maxf(hi, g)
		if not is_nan(prev) and g > prev: climb += g - prev
		prev = g
		s += 1.0
	return {length = length, tight = tight, medium = medium, min_r = min_r, drop = hi - lo, climb = climb}


func ride(h: Heightfield, d: TrailDefinition, target: float) -> Dictionary:
	var dt := 1.0 / 60.0
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = true
	var at := d.point_at(1.0)
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(1.0)
	b.mount(p)
	b.speed = 6.0
	var control := BikeController.new()
	var length := d.route_length()
	var r := {where = PackedStringArray(), done = false, time = 0.0, off = 0.0, air = 0.0, hits = 0, crashes = 0, light = 0.0, land = 0.0, top = 0.0}
	var station := 1.0
	var t := 0.0
	var still := 0.0
	var was_off := false
	while t < 90.0:
		var near := d.nearest(Vector2(b.x, b.z))
		if near.x > station - 30.0: station = maxf(station, near.x)
		if station >= length - 3.0:
			r.done = true
			break
		var aim := d.point_at(minf(station + maxf(4.0, absf(b.speed) * 0.6), length))
		var delta := aim - Vector2(b.x, b.z)
		var steer := clampf(-wrapf(atan2(-delta.x, -delta.y) - b.heading, -PI, PI) * 2.0, -1.0, 1.0)
		var want := target
		for ahead: float in [4.0, 8.0, 12.0, 16.0, 20.0]:
			var k := absf(d.curvature_at(minf(station + ahead, length)))
			if k > 0.0001: want = minf(want, maxf(4.0, sqrt(LAT_SAFE / k)))
		var throttle := clampf((want - b.speed) * 0.5, -1.0, 1.0)
		if throttle < 0.0 and b.speed - want < 1.0: throttle = 0.0
		h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1)
		var was_air := b.airborne
		control.ride(dt, p, b, h.world, h, throttle, steer, false, false, false)
		t += dt
		if b.crashed:
			r.crashes += 1
			r.where.append("падение %s на %.0f м (%s)" % [BikeRide.CrashCause.keys()[b.crash_cause], station, _element_at(d, station)])
			var back := d.point_at(station)
			b.reset_motion()
			b.x = back.x
			b.z = back.y
			b.y = h.surface_at(back.x, back.y, -INF)
			b.heading = d.heading_at(station)
			b.mount(p)
			b.speed = 4.0
			continue
		var off := absf(d.nearest(Vector2(b.x, b.z)).y) > d.width * 0.5
		if off:
			r.off += dt
			if not was_off: r.where.append("сход на %.0f м (%s, %.0f км/ч)" % [station, _element_at(d, station), b.speed * 3.6])
		was_off = off
		still = still + dt if absf(b.speed) < 0.3 else 0.0
		if still > 3.0:
			r.where.append("застрял на %.0f м (%s)" % [station, _element_at(d, station)])
			break
		if b.airborne: r.air += dt
		elif b.load_f + b.load_r < 0.3: r.light += dt
		if was_air and b.land_impact > 0.0: r.land = maxf(r.land, b.land_impact)
		b.land_impact = 0.0
		r.top = maxf(r.top, b.speed)
	r.hits = b.impacts.x
	r.time = t
	return r


static func _element_at(d: TrailDefinition, station: float) -> String:
	for e in d.elements:
		if absf(station - e.station) <= e.length * 0.5 + 3.0: return TrailElementLibrary.title(e.profile)
	return "между элементами"


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var presets := range(1, TrailLabCatalog.LIST.size() + 1)
	if "--presets" in args: presets = Array(args[args.find("--presets") + 1].split(",")).map(func(x: String) -> int: return int(x))
	for number: int in presets:
		var spec: Dictionary = TrailLabCatalog.LIST[number - 1]
		var kit := TrailLabCatalog.routes(number - 1, Fixture)
		var prepared := Fixture.prepare(kit, true, spec.ground)
		if not prepared.errors.is_empty():
			print("%d не собрана: %s" % [number, prepared.errors])
			continue
		var h: Heightfield = prepared.heights
		var technical := TrailTechnical.build(h, kit)
		h.obstacles.set_trail(technical.collide, technical.bumps)
		h.obstacles.update(kit[0].points[0].x, kit[0].points[0].y, PackedFloat32Array(), 1, true)
		var d := kit[0]
		var g := geometry(h, d)
		var kinds := {}
		for route in kit:
			for e in route.elements:
				var name := TrailElementLibrary.title(e.profile)
				kinds[name] = kinds.get(name, 0) + 1
		var r := ride(h, d, 9.0)
		print("%d %s | %s, ширина %.1f м | %.0f м, крутых поворотов %.0f м, средних %.0f м, мин. радиус %.0f м, перепад %.0f м, набор %.0f м | %s" % [
			number, spec.title, spec.ground, d.width, g.length, g.tight, g.medium, g.min_r, g.drop, g.climb, kinds])
		print("    заезд 9 м/с: %s за %.0f с, макс %.0f км/ч, вне трассы %.1f с, полёт %.1f с, без опоры %.1f с, встреч с препятствиями %d, падений %d, приземление до %.1f м/с" % [
			"доехал" if r.done else "не доехал", r.time, r.top * 3.6, r.off, r.air, r.light, r.hits, r.crashes, r.land])
		if not r.where.is_empty(): print("    где: ", "; ".join(r.where.slice(0, 6)))
	quit(0)
