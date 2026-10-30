extends SceneTree
## Работа телом на препятствии (BikeRide.body_back / body_forward, модель двух контактов) на одной секции Trail Lab
## без мира: подход → бревно 0,3 м (или два камня вплотную) → поворот радиусом 8 м. Тот же вход, манеры:
## пассивно; только переднее (тело назад к касанию переднего колеса); оба (назад к переднему, вперёд к заднему, затем
## нейтраль); ошибка второго (вперёд с опозданием); частые нажатия назад без привязки к препятствию; вес назад постоянно.
## Моменты действий считаются от скорости: касание заднего колеса — через базу / скорость после переднего.
## Успех — проезд внутри полотна (не дальше половины ширины от оси), скорость после обоих колёс, удары, следующий
## поворот. Ряды по тактам (CSV) и графики (PNG) — в tools/control/runs/wheel_unweight.
##   godot --headless --path . --script res://tools/wheel_unweight_test.gd
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const OUT := "res://tools/control/runs/wheel_unweight"
const LOG := 30.0      # станция препятствия, м
const TURN := 40.0     # начало поворота, м
const RADIUS := 8.0
const MANNERS := ["пассивно", "только переднее", "оба колеса", "второе поздно", "частые нажатия", "вес назад", "банни-хоп"]
const COLORS := [Color(0.9, 0.9, 0.9), Color(1.0, 0.75, 0.2), Color(0.3, 0.9, 0.4), Color(0.9, 0.3, 0.3), Color(0.7, 0.4, 0.9), Color(0.4, 0.6, 1.0), Color(0.3, 0.9, 0.9)]
const HOP_E := 0.2     # с: банни-хоп — E через столько после Q
const HOP_TAKEOFF := 0.45 # с: Q за столько до касания переднего колеса, чтобы взлететь до препятствия
const LATE := 0.15     # с: «второе поздно» — тело вперёд на столько позже касания заднего колеса
const SPAM := 0.35     # с: период частых нажатий
var failures := 0
var checks := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 170)
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
	for i in int(TURN):
		pts.append(at)
		at += heading
	for i in int(PI * 0.5 * RADIUS):
		pts.append(at)
		heading = heading.rotated(1.0 / RADIUS)
		at += heading
	for i in 16:
		pts.append(at)
		at += heading
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


## Ввод тела в момент t: back / forward. t_front / t_rear — расчётные моменты касания кромки колёсами, shift — ошибка
## тайминга обоих действий, с.
static func body_input(manner: int, t: float, t_front: float, t_rear: float, shift: float) -> Vector2i:
	var lead := BikeRide.BODY_LEAD
	match manner:
		1: return Vector2i(int(t >= t_front - lead + shift and t < t_front + 0.12 + shift), 0)
		2:
			var back := t >= t_front - lead + shift and t < t_front + 0.05 + shift
			var fwd := t >= t_rear - lead + shift and t < t_rear + 0.1 + shift
			return Vector2i(int(back), int(fwd and not back))
		3:
			var back := t >= t_front - lead and t < t_front + 0.05
			var fwd := t >= t_rear + LATE and t < t_rear + LATE + 0.15
			return Vector2i(int(back), int(fwd and not back))
		4: return Vector2i(int(fposmod(t, SPAM) < 0.1), 0)
		5: return Vector2i(1, 0)
		6:
			var q := t >= t_front - HOP_TAKEOFF + shift and t < t_front - HOP_TAKEOFF + HOP_E + shift
			var e := t >= t_front - HOP_TAKEOFF + HOP_E + shift and t < t_front - HOP_TAKEOFF + HOP_E + 0.2 + shift
			return Vector2i(int(q), int(e))
	return Vector2i(0, 0)


## Один заезд: манера, скорость, частота тактов, ошибка тайминга. Ряд по тактам и итог.
func ride(h: Heightfield, d: TrailDefinition, manner: int, speed: float, hz: int, shift := 0.0) -> Dictionary:
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
	var out := {result = "не доехал", before = speed, after = -1.0, hit = 0.0, hit_r = 0.0, off = 0.0, turn_off = 0.0, exit = 0.0,
		time = 0.0, crash_at = -1.0, rows = PackedStringArray(["t;station;speed;load_f;load_r;tire_f;force_f;force_r;body_x;unweight;back;forward;crash"]),
		series = PackedVector4Array()}
	var t := 0.0
	var contact := LOG - BikeRide.HUB - 0.5 # где передняя ступица, когда колесо касается кромки
	var t_front := INF
	var t_rear := INF
	while t < 20.0:
		var near := d.nearest(Vector2(b.x, b.z))
		var station := near.x
		if station >= length - 2.0:
			out.result = "проехал"
			break
		# моменты касаний — по текущей скорости, пока колесо не дошло: седок оценивает их на глаз
		if station < contact: t_front = t + (contact - station) / maxf(absf(b.speed), 0.5)
		if station < contact + 2.0 * BikeRide.HUB: t_rear = t + (contact + 2.0 * BikeRide.HUB - station) / maxf(absf(b.speed), 0.5)
		var input := body_input(manner, t, t_front, t_rear, shift)
		b.body_back = input.x == 1
		b.body_forward = input.y == 1
		var aim := d.point_at(minf(station + maxf(4.0, absf(b.speed) * 0.6), length))
		var delta := aim - Vector2(b.x, b.z)
		var steer := clampf(-wrapf(atan2(-delta.x, -delta.y) - b.heading, -PI, PI) * 2.0, -1.0, 1.0)
		# газ держит скорость до бревна и после него (поворот на той же скорости), у самого бревна — накат
		var throttle := clampf((speed - b.speed) * 0.8, 0.0, 1.0) if station < LOG - 6.0 or station > LOG + 4.0 else 0.0
		control.ride(dt, p, b, h.world, h, throttle, steer, false, false, false)
		t += dt
		if station < LOG - 1.5: out.before = b.speed
		if station >= LOG + 2.0 * BikeRide.HUB + 1.5 and out.after < 0.0: out.after = b.speed
		out.hit = maxf(out.hit, b.hit_dv.x)
		out.hit_r = maxf(out.hit_r, b.hit_dv.y)
		var off := absf(d.nearest(Vector2(b.x, b.z)).y)
		out.off = maxf(out.off, off)
		if station > TURN and station < TURN + PI * 0.5 * RADIUS: out.turn_off = maxf(out.turn_off, off)
		out.rows.append("%.3f;%.2f;%.3f;%.3f;%.3f;%.3f;%.3f;%.3f;%.3f;%.3f;%d;%d;%d" % [t, station, b.speed, b.load_f, b.load_r, b.tire_f,
			b.force_f.length(), b.force_r.length(), b.body_x, b.unweight, input.x, input.y, int(b.crashed)])
		out.series.append(Vector4(station, b.speed, b.tire_f, b.tire_r))
		if b.crashed:
			out.result = "через руль" if b.crash_cause == BikeRide.CrashCause.OBSTACLE else "упал"
			out.crash_at = station
			break
		if absf(b.speed) < 0.05 and station < LOG + 1.0 and t > 1.0:
			out.result = "встал"
			break
	# внутри полотна — проезд; дальше половины ширины от оси — сход, даже если доехал до конца
	if out.result == "проехал" and out.off > d.width * 0.5: out.result = "сход с полотна"
	out.exit = b.speed
	out.time = t
	if out.after < 0.0: out.after = b.speed
	return out


## Три полосы по станции: скорость, нагрузка шины переднего и заднего колеса; бревно и поворот — линии, падение — крест.
func chart(runs: Array, length: float, path: String) -> void:
	var w := 900
	var lane := 170
	var img := Image.create(w, lane * 3, false, Image.FORMAT_RGB8)
	img.fill(Color(0.12, 0.13, 0.15))
	var limits := [Vector2(0, 11), Vector2(0, 1.2), Vector2(0, 1.2)]
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


func line(name: String, speed: float, r: Dictionary) -> String:
	return "%s %.0f м/с · %-15s: %s, %.1f → %.1f м/с после обоих колёс, удар перед/зад %.1f/%.1f, с оси до %.2f м (в повороте %.2f), выход %.1f м/с" % [
		name, speed, MANNERS[r.manner], r.result, r.before, r.after, r.hit, r.hit_r, r.off, r.turn_off, r.exit]


## Банни-хоп на ровном подходе (до бревна): Q в момент 0, E через delay (меньше нуля — без E; NAN — без Q, только E;
## «пробел» — space). Возвращает наибольший подъём переднего колеса, высоту прыжка и был ли полёт.
func hop(h: Heightfield, d: TrailDefinition, delay: float, space := false, hz := 60) -> Dictionary:
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = true
	var start := d.point_at(4.0)
	b.x = start.x
	b.z = start.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(4.0)
	b.mount(p)
	b.speed = 6.0
	var control := BikeController.new()
	var lift := 0.0
	var lift_r := 0.0
	var flew := false
	var t := 0.0
	var dt := 1.0 / hz
	while t < 2.0:
		var q := not is_nan(delay) and t >= 0.3 and t < 0.3 + 0.2
		var e := delay >= 0.0 and t >= 0.3 + (0.0 if is_nan(delay) else delay) and t < 0.3 + (0.0 if is_nan(delay) else delay) + 0.2
		if is_nan(delay): e = t >= 0.3 and t < 0.5
		b.body_back = q and not e
		b.body_forward = e
		control.ride(dt, p, b, h.world, h, clampf((6.0 - b.speed) * 0.8, 0.0, 1.0), 0.0, false, space and t >= 0.3 and t < 0.3 + dt * 1.5, false)
		t += dt
		if OS.get_cmdline_user_args().has("--hop-trace") and t > 0.25 and t < 0.9 and int(t * hz) % 2 == 0:
			print("  H %.2f с Q%d E%d тело %+.2f (%+.1f) снято %+.2f · колёса %.2f / %.2f · нагрузка %.2f / %.2f%s" % [t, int(b.body_back), int(b.body_forward), b.body_x, b.body_v, b.unweight, b.lift_f, b.lift_r, b.load_f, b.load_r, " ПОЛЁТ" if b.airborne else ""])
		lift = maxf(lift, b.lift_f)
		lift_r = maxf(lift_r, b.lift_r)
		flew = flew or b.airborne
	return {lift = lift, lift_r = lift_r, flew = flew, height = b.hop_height if flew else 0.0}


func hops(h: Heightfield, d: TrailDefinition) -> void:
	if OS.get_cmdline_user_args().has("--hop-trace"):
		print("— только Q"); hop(h, d, -1.0)
		print("— только E"); hop(h, d, NAN)
		print("— Q→E 0,15"); hop(h, d, 0.15)
		return
	var only_q := hop(h, d, -1.0)
	var only_e := hop(h, d, NAN)
	print("Только Q: переднее колесо до %.2f м, полёт %s · только E: заднее до %.2f м, полёт %s" % [only_q.lift, only_q.flew, only_e.lift_r, only_e.flew])
	check(only_q.lift > 0.1 and not only_q.flew, "Q отрывает переднее колесо (%.2f м), велосипед не взлетает" % only_q.lift)
	check(not only_e.flew, "только E — без прыжка")
	var best := 0.0
	var window := PackedStringArray()
	var flying := 0
	for delay: float in [0.0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5]:
		var r := hop(h, d, delay)
		window.append("%.2f с: %s" % [delay, "%.2f м" % r.height if r.flew else "нет"])
		best = maxf(best, r.height)
		flying += int(r.flew)
	print("Q→E, задержка E: ", " · ".join(window))
	var space := hop(h, d, -1.0, true)
	print("Пробел: прыжок %s %.2f м (лучший ручной %.2f м)" % [space.flew, space.height, best])
	check(best > 0.2, "вовремя Q→E — банни-хоп выше 0,2 м (%.2f)" % best)
	check(flying > 0 and flying < 9, "прыжок получается не при любой задержке E (%d из 9)" % flying)
	check(space.flew and space.height < best and space.height > 0.05, "пробел — прыжок слабее лучшего ручного (%.2f против %.2f м)" % [space.height, best])
	var same := true
	for hz: int in [30, 120]:
		var r := hop(h, d, 0.15, false, hz)
		var base := hop(h, d, 0.15)
		same = same and r.flew == base.flew and absf(r.height - base.height) < 0.06
	check(same, "банни-хоп одинаков при 30/60/120 Гц")


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
		var name := "бревно" if kind == "log" else "камни"
		h.obstacles.set_trail(obstacle(h, d, kind), PackedFloat32Array())
		h.obstacles.update(d.point_at(LOG).x, d.point_at(LOG).y, PackedFloat32Array(), 1, true)
		for speed: float in [6.0, 8.0, 10.0]:
			var runs := []
			for manner in MANNERS.size():
				var r := ride(h, d, manner, speed, 60)
				r.manner = manner
				runs.append(r)
				all["%s_%.0f_%d" % [kind, speed, manner]] = r
				var csv := FileAccess.open("%s/%s_%.0f_%d.csv" % [OUT, kind, speed, manner], FileAccess.WRITE)
				csv.store_string("\n".join(r.rows))
				print(line(name, speed, r))
			chart(runs, length, "%s/%s_%.0f.png" % [OUT, kind, speed])
		var passive: Dictionary = all["%s_8_0" % kind]
		var front: Dictionary = all["%s_8_1" % kind]
		var both: Dictionary = all["%s_8_2" % kind]
		var late: Dictionary = all["%s_8_3" % kind]
		var spam: Dictionary = all["%s_8_4" % kind]
		check(passive.result == "проехал" and both.result == "проехал", "%s, 8 м/с: пассивно и оба колеса — проезд внутри полотна (%s, %s)" % [name, passive.result, both.result])
		check(front.hit < passive.hit * 0.5 and front.hit_r > passive.hit_r, "%s, 8 м/с: только переднее — удар переднего %.1f против %.1f, заднего сильнее (%.1f против %.1f)" % [name, front.hit, passive.hit, front.hit_r, passive.hit_r])
		var hop: Dictionary = all["%s_8_6" % kind]
		if kind == "log":
			check(both.hit + both.hit_r < (passive.hit + passive.hit_r) * 0.7 and both.after > passive.after + 0.3,
				"%s, 8 м/с: оба колеса — суммарный удар %.1f против %.1f, скорость после %.1f против %.1f м/с" % [name, both.hit + both.hit_r, passive.hit + passive.hit_r, both.after, passive.after])
		else:
			# два камня подряд: заднее колесо встречает оба, разгрузка по очереди не помогает — нужен прыжок
			print("камни: разгрузка по очереди %.1f м/с против %.1f пассивно (заднее бьётся о оба камня)" % [both.after, passive.after])
		check(hop.result == "проехал" and hop.hit + hop.hit_r < 0.05 and hop.after > passive.after + 1.0,
			"%s, 8 м/с: банни-хоп — без ударов, скорость после %.1f против %.1f м/с" % [name, hop.after, passive.after])
		if kind == "log": check(late.after < both.after - 0.2, "%s, 8 м/с: второе поздно — хуже правильной последовательности (%.1f против %.1f м/с)" % [name, late.after, both.after])
		check(spam.result != "проехал" or spam.after <= hop.after - 0.2, "%s, 8 м/с: частые нажатия не лучше техники (%s, %.1f против %.1f м/с)" % [name, spam.result, spam.after, hop.after])
	check(all.log_10_0.result == "через руль" and all.log_10_2.result == "проехал", "бревно, 10 м/с: пассивно — через руль, оба колеса — проезд (%s)" % all.log_10_2.result)
	check(all.log_10_5.turn_off > all.log_10_2.turn_off + 0.15, "бревно, 10 м/с: вес назад постоянно — следующий поворот хуже (с оси %.2f против %.2f м)" % [all.log_10_5.turn_off, all.log_10_2.turn_off])
	# окно: ошибка тайминга обоих действий
	h.obstacles.set_trail(obstacle(h, d, "log"), PackedFloat32Array())
	h.obstacles.update(d.point_at(LOG).x, d.point_at(LOG).y, PackedFloat32Array(), 1, true)
	var passive8: Dictionary = all.log_8_0
	var window := PackedStringArray()
	var inside := 0
	for shift: float in [-0.15, -0.1, -0.05, 0.0, 0.05, 0.1, 0.15]:
		var r := ride(h, d, 2, 8.0, 60, shift)
		var gain: float = r.after - passive8.after
		window.append("%+.2f с: %.1f м/с (%+.1f)" % [shift, r.after, gain])
		if absf(shift) <= 0.05: inside += int(gain > 0.3)
	print("Окно тайминга (оба колеса, бревно 8 м/с): ", " · ".join(window))
	check(inside == 3, "ошибка тайминга до ±0,05 с ещё даёт выигрыш скорости")
	hops(h, d)
	# частота тактов
	var same := true
	var hz_line := PackedStringArray()
	for manner in [0, 2]:
		var base := ride(h, d, manner, 8.0, 60)
		for hz: int in [30, 120]:
			var r := ride(h, d, manner, 8.0, hz)
			hz_line.append("%s %d Гц: %s %.1f" % [MANNERS[manner], hz, r.result, r.after])
			same = same and r.result == base.result and absf(r.after - base.after) < 0.4
	check(same, "бревно 8 м/с: 30/60/120 Гц дают тот же исход (%s)" % ", ".join(hz_line))
	print("Графики и ряды: ", ProjectSettings.globalize_path(OUT))
	print("wheel_unweight: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)
