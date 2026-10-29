extends SceneTree
## Разгрузка переднего колеса (BikeRide.body_back, модель двух контактов) на одной фиксированной секции Trail Lab без
## мира: подход → бревно 0,3 м (или два камня вплотную) → поворот радиусом 8 м. Тот же вход, четыре манеры:
## пассивно, вовремя (пик рывка к касанию кромки), рано (на 0,55 с раньше), постоянно вес назад. Проверки сравнительные;
## запись ввода и ряда по тактам (CSV) и график скорости, нагрузки и силы переднего колеса (PNG) в
## tools/control/runs/wheel_unweight.
##   godot --headless --path . --script res://tools/wheel_unweight_test.gd
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const OUT := "res://tools/control/runs/wheel_unweight"
const LOG := 30.0      # станция препятствия, м
const TURN := 40.0     # начало поворота, м
const RADIUS := 8.0
const MANNERS := ["пассивно", "вовремя", "рано", "вес назад"]
const COLORS := [Color(0.9, 0.9, 0.9), Color(0.3, 0.9, 0.4), Color(1.0, 0.75, 0.2), Color(0.4, 0.6, 1.0)]
const EARLY := 0.55    # с: насколько раньше «рано»
const PRESS := 0.3     # с: сколько держать клавишу при рывке
var failures := 0
var checks := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	print("wheel_unweight: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1


func section() -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = "unweight_section"
	d.title = "Подход · бревно · поворот"
	d.width = 4.0
	d.surface = RoadSurface.PACKED
	var pts := PackedVector2Array()
	var at := Vector2(110, 205)
	var heading := Vector2(0, -1)
	for i in int(TURN): pts.append(at); at += heading
	for i in int(PI * 0.5 * RADIUS):
		pts.append(at)
		heading = heading.rotated(1.0 / RADIUS)
		at += heading
	for i in 16: pts.append(at); at += heading
	pts.append(at)
	d.points = pts
	d.elements = [] as Array[TrailElement]
	return d


func obstacle(h: Heightfield, d: TrailDefinition, kind: String) -> PackedFloat32Array:
	var at := d.point_at(LOG)
	var base := h.ground_at(at.x, at.y)
	if kind == "log":
		return PackedFloat32Array([at.x - 2.0, at.y, at.x + 2.0, at.y, 0.15, base, base + 0.3])
	return PackedFloat32Array([at.x, at.y, at.x, at.y, 0.4, base, base + 0.22, at.x, at.y - 0.75, at.x, at.y - 0.75, 0.4, base, base + 0.3])


## Один заезд: манера manner на скорости speed, частота hz. Ряд по тактам и итог.
func ride(h: Heightfield, d: TrailDefinition, manner: int, speed: float, hz: int) -> Dictionary:
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = true
	var start := d.point_at(2.0)
	b.x = start.x
	b.z = start.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(2.0)
	b.mount(p)
	b.speed = speed
	var control := BikeController.new()
	var dt := 1.0 / hz
	var length := d.route_length()
	var out := {result = "не доехал", before = speed, after = -1.0, hit = 0.0, hit_r = 0.0, turn_off = 0.0, exit = 0.0, time = 0.0, crash_at = -1.0,
		rows = PackedStringArray(["t;station;speed;load_f;load_r;tire_f;force_f;force_r;unweight;back;throttle;steer;crash"]),
		series = PackedVector4Array()}
	var pressed_at := -1.0
	var t := 0.0
	var contact := LOG - BikeRide.HUB - 0.5 # где передняя ступица, когда колесо касается кромки
	while t < 20.0:
		var near := d.nearest(Vector2(b.x, b.z))
		var station := near.x
		if station >= length - 2.0:
			out.result = "проехал"
			break
		var to_contact := (contact - station) / maxf(absf(b.speed), 0.5)
		var back := false
		match manner:
			1: if pressed_at < 0.0 and to_contact <= BikeRide.PULL_RISE: pressed_at = t
			2: if pressed_at < 0.0 and to_contact <= BikeRide.PULL_RISE + EARLY: pressed_at = t
			3: back = true
		if pressed_at >= 0.0 and t - pressed_at < PRESS: back = true
		b.body_back = back
		var look := maxf(4.0, absf(b.speed) * 0.6)
		var aim := d.point_at(minf(station + look, length))
		var delta := aim - Vector2(b.x, b.z)
		var steer := clampf(-wrapf(atan2(-delta.x, -delta.y) - b.heading, -PI, PI) * 2.0, -1.0, 1.0)
		# газ держит скорость до бревна и после него (поворот на той же скорости), у самого бревна — накат
		var throttle := clampf((speed - b.speed) * 0.8, 0.0, 1.0) if station < LOG - 6.0 or station > LOG + 3.0 else 0.0
		control.ride(dt, p, b, h.world, h, throttle, steer, false, false, false)
		t += dt
		if station < LOG - 1.5: out.before = b.speed
		if station >= LOG + 3.0 and out.after < 0.0: out.after = b.speed
		out.hit = maxf(out.hit, b.hit_dv.x)
		out.hit_r = maxf(out.hit_r, b.hit_dv.y)
		if station > TURN and station < TURN + PI * 0.5 * RADIUS: out.turn_off = maxf(out.turn_off, absf(d.nearest(Vector2(b.x, b.z)).y))
		out.rows.append("%.3f;%.2f;%.3f;%.3f;%.3f;%.3f;%.3f;%.3f;%.2f;%d;%.2f;%.2f;%d" % [t, station, b.speed, b.load_f, b.load_r, b.tire_f,
			b.force_f.length(), b.force_r.length(), b.unweight, int(back), throttle, steer, int(b.crashed)])
		out.series.append(Vector4(station, b.speed, b.tire_f, b.force_f.length()))
		if b.crashed:
			out.result = "через руль" if b.crash_cause == BikeRide.CrashCause.OBSTACLE else "упал"
			out.crash_at = station
			break
		if absf(b.speed) < 0.05 and station < LOG + 1.0 and t > 1.0:
			out.result = "встал"
			break
	out.exit = b.speed
	out.time = t
	if out.after < 0.0: out.after = b.speed
	return out


## Три полосы по станции: скорость, нагрузка шины переднего колеса, сила переднего колеса; бревно и поворот — линии,
## падение — крест.
func chart(runs: Array, length: float, path: String) -> void:
	var w := 900
	var lane := 170
	var img := Image.create(w, lane * 3, false, Image.FORMAT_RGB8)
	img.fill(Color(0.12, 0.13, 0.15))
	var limits := [Vector2(0, 10), Vector2(0, 1.2), Vector2(0, 10)]
	for row in 3:
		for x in w: img.set_pixel(x, row * lane + lane - 1, Color(0.3, 0.3, 0.3))
		for mark: float in [LOG, TURN]:
			var mx := int(mark / length * (w - 1))
			for y in range(row * lane, row * lane + lane): img.set_pixel(mx, y, Color(0.45, 0.3, 0.3) if mark == LOG else Color(0.3, 0.3, 0.45))
	for k in runs.size():
		var series: PackedVector4Array = runs[k].series
		for row in 3:
			var prev := Vector2i(-1, -1)
			for v in series:
				var value: float = [v.y, v.z, v.w][row]
				var lim: Vector2 = limits[row]
				var px := Vector2i(int(clampf(v.x / length, 0.0, 1.0) * (w - 1)), row * lane + lane - 2 - int(clampf((value - lim.x) / (lim.y - lim.x), 0.0, 1.0) * (lane - 4)))
				if prev.x >= 0: _line(img, prev, px, COLORS[k])
				prev = px
		if runs[k].crash_at >= 0.0:
			var cx := int(runs[k].crash_at / length * (w - 1))
			for o in range(-6, 7):
				for row in 3:
					var cy := row * lane + lane / 2
					img.set_pixel(clampi(cx + o, 0, w - 1), clampi(cy + o, 0, lane * 3 - 1), COLORS[k])
					img.set_pixel(clampi(cx + o, 0, w - 1), clampi(cy - o, 0, lane * 3 - 1), COLORS[k])
	img.save_png(ProjectSettings.globalize_path(path))


static func _line(img: Image, a: Vector2i, b: Vector2i, color: Color) -> void:
	var steps := maxi(absi(b.x - a.x), absi(b.y - a.y))
	for i in steps + 1:
		var p := Vector2(a).lerp(Vector2(b), float(i) / maxf(steps, 1))
		img.set_pixel(clampi(int(p.x), 0, img.get_width() - 1), clampi(int(p.y), 0, img.get_height() - 1), color)


func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var d := section()
	var kit: Array[TrailDefinition] = [d]
	var prepared := Fixture.prepare(kit)
	check(prepared.errors.is_empty(), "секция собрана: %s" % "; ".join(prepared.errors))
	if not prepared.errors.is_empty():
		quit(1)
		return
	var h: Heightfield = prepared.heights
	var length := d.route_length()
	var all := {}
	for kind: String in ["log", "rocks"]:
		h.obstacles.set_trail(obstacle(h, d, kind), PackedFloat32Array())
		h.obstacles.update(d.point_at(LOG).x, d.point_at(LOG).y, PackedFloat32Array(), 1, true)
		for speed: float in [7.0, 10.0]:
			var runs := []
			for manner in MANNERS.size():
				var r := ride(h, d, manner, speed, 60)
				runs.append(r)
				all["%s_%.1f_%d" % [kind, speed, manner]] = r
				var csv := FileAccess.open("%s/%s_%.1f_%d.csv" % [OUT, kind, speed, manner], FileAccess.WRITE)
				csv.store_string("\n".join(r.rows))
				print("%s %.1f м/с · %-9s: %s, %.1f → %.1f м/с (−%.1f), удар перед/зад %.1f/%.1f, поворот: с оси до %.2f м, выход %.1f м/с, %.1f с" % [
					"бревно" if kind == "log" else "камни", speed, MANNERS[manner], r.result, r.before, r.after, r.before - r.after, r.hit, r.hit_r, r.turn_off, r.exit, r.time])
			chart(runs, length, "%s/%s_%.1f.png" % [OUT, kind, speed])
	for kind: String in ["log", "rocks"]:
		var passive: Dictionary = all["%s_7.0_0" % kind]
		var timely: Dictionary = all["%s_7.0_1" % kind]
		var early: Dictionary = all["%s_7.0_2" % kind]
		var hold: Dictionary = all["%s_7.0_3" % kind]
		var name := "бревно" if kind == "log" else "камни"
		var lost_p: float = passive.before - passive.after
		var lost_t: float = timely.before - timely.after
		var lost_e: float = early.before - early.after
		check(lost_t < lost_p and timely.hit < passive.hit * 0.5, "%s, 7 м/с: вовремя — удар переднего колеса вдвое слабее, потеря скорости меньше (%.1f против %.1f м/с; удар %.1f против %.1f)" % [name, lost_t, lost_p, timely.hit, passive.hit])
		check(lost_e > lost_p * 0.8, "%s, 7 м/с: рано — колесо снова нагружено, потеря почти как пассивно (%.1f)" % [name, lost_e])
		# на пределе поворота (10 м/с, радиус 8 м) лёгкое переднее колесо держит хуже
		var fast_passive: Dictionary = all["%s_10.0_1" % kind]
		var fast_hold: Dictionary = all["%s_10.0_3" % kind]
		check(fast_hold.turn_off > fast_passive.turn_off + 0.3, "%s, 10 м/с: вес назад постоянно — поворот хуже, чем после своевременной разгрузки (с оси %.2f против %.2f м)" % [name, fast_hold.turn_off, fast_passive.turn_off])
	check(all["log_10.0_0"].result == "через руль" and all["log_10.0_1"].result == "проехал", "бревно, 10 м/с: пассивно — через руль, вовремя — проехал")
	# устойчивость к частоте тактов: пассивно и вовремя на бревне
	h.obstacles.set_trail(obstacle(h, d, "log"), PackedFloat32Array())
	h.obstacles.update(d.point_at(LOG).x, d.point_at(LOG).y, PackedFloat32Array(), 1, true)
	for manner in [0, 1]:
		var line := PackedStringArray()
		var base := ride(h, d, manner, 7.0, 60)
		var same := true
		for hz: int in [30, 120]:
			var r := ride(h, d, manner, 7.0, hz)
			line.append("%d Гц: %s %.1f→%.1f" % [hz, r.result, r.before, r.after])
			same = same and r.result == base.result and absf(r.after - base.after) < 0.4
		check(same, "бревно, %s: 30/60/120 Гц дают тот же исход (60 Гц: %.1f→%.1f; %s)" % [MANNERS[manner], base.before, base.after, ", ".join(line)])
	print("Графики и ряды: ", ProjectSettings.globalize_path(OUT))
	print("wheel_unweight: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)
