extends SceneTree
## Модель двух контактов колёс (BikeRide.contact_model) на одной секции Trail Lab, без мира: роллер, контруклон, корни.
## Каждый заезд — тот же старт и тот же ввод в прежней модели и в новой; проверки сравнительные:
## тормоз на гребне держит хуже, чем в ложбине; контруклон сносит вниз; корень то прижимает, то разгружает колесо.
##   godot --headless --path . --script res://tools/wheel_contact_test.gd
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const ROLLER := 40.0
const CAMBER := 100.0
const ROOTS := 150.0
const LOG := 70.0
var failures := 0
var checks := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	print("wheel_contact: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1


func section() -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = "contact_section"
	d.title = "Два контакта"
	d.points = PackedVector2Array([Vector2(40, 220), Vector2(40, 30)])
	d.width = 3.0
	d.surface = RoadSurface.PACKED
	var list: Array[TrailElement] = []
	for spec: Array in [[TrailElement.Profile.ROLLER, ROLLER, 9.0, 1.0, 1.0, 0.5], [TrailElement.Profile.OFF_CAMBER, CAMBER, 24.0, 0.9, 1.0, 0.5],
			[TrailElement.Profile.ROOTS, ROOTS, 14.0, 0.14, 1.0, 0.9]]:
		var e := TrailElement.new()
		e.profile = spec[0]
		e.station = spec[1]
		e.length = spec[2]
		e.height = spec[3]
		e.bank = spec[4]
		e.density = spec[5]
		# у корней две линии по бокам: ось ими перекрыта, заезд по оси проверяет удары корней
		e.lines = 2 if spec[0] == TrailElement.Profile.ROOTS else 1
		list.append(e)
	d.elements = list
	return d


## Заезд с station `from` на скорости `speed` до station `to`. brake — [от, до] станции полного тормоза;
## follow — рулить к оси (иначе руль прямо). Возвращает скорость на входе и выходе из окна тормоза, снос от оси и нагрузки.
func ride(h: Heightfield, d: TrailDefinition, contact: bool, hz: int, from: float, to: float, speed: float, brake := Vector2(-1, -1), follow := false, zone := Vector2(-1, -1), trace := false, turn := Vector2(-1, -1)) -> Dictionary:
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = contact
	var at := d.point_at(from)
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(from)
	b.mount(p)
	b.speed = speed
	var control := BikeController.new()
	var out := {brake_in = -1.0, brake_out = -1.0, brake_time = 0.0, brake_air = 0, brake_load = 0.0, offset = 0.0, min_load_f = INF, max_load_f = 0.0, air = 0, crashed = false, peak_use_r = 0.0, bank = 0.0, yaw = 0.0, yaw_time = 0.0}
	var prev_heading := b.heading
	for tick in hz * 30:
		var station := d.nearest(Vector2(b.x, b.z)).x
		if station >= to: break
		var braking := station >= brake.x and station <= brake.y
		if braking:
			if out.brake_in < 0.0: out.brake_in = b.speed
			out.brake_out = b.speed
			out.brake_time += 1.0 / hz
			out.brake_air += int(b.airborne)
			out.brake_load += (b.load_f + b.load_r) / hz
		var steer := 0.0
		if follow:
			var target := d.point_at(station + 6.0)
			var delta := target - Vector2(b.x, b.z)
			steer = clampf(-wrapf(atan2(-delta.x, -delta.y) - b.heading, -PI, PI) * 2.0, -1.0, 1.0)
		var turning := station >= turn.x and station <= turn.y
		if turning: steer = 1.0
		control.ride(1.0 / hz, p, b, h.world, h, -1.0 if braking else 0.0, steer, false, false, false)
		if turning:
			out.yaw += absf(wrapf(b.heading - prev_heading, -PI, PI))
			out.yaw_time += 1.0 / hz
		prev_heading = b.heading
		if trace and station >= brake.x - 3.0 and station <= brake.y + 1.0:
			print("  %.2f м: v %.2f · g %+.2f · нагрузка %.2f / %.2f · тормоз %.2f · %s" % [station, b.speed, b.vertical_g, b.load_f, b.load_r, b.brake_deceleration, "полёт" if b.airborne else "земля"])
		if b.crashed:
			out.crashed = true
			break
		if station >= zone.x and station <= zone.y:
			out.offset = maxf(out.offset, absf(d.nearest(Vector2(b.x, b.z)).y))
			out.air += int(b.airborne)
			out.peak_use_r = maxf(out.peak_use_r, b.use_r)
			out.bank = maxf(out.bank, absf(b.bank_slope))
			if not b.airborne:
				out.min_load_f = minf(out.min_load_f, b.load_f)
				out.max_load_f = maxf(out.max_load_f, b.load_f)
	out.decel = (out.brake_in - out.brake_out) / maxf(out.brake_time, 0.001)
	out.exit = b.speed
	out.brake_load /= maxf(out.brake_time, 0.001)
	out.yaw /= maxf(out.yaw_time, 0.001)
	return out


## Накатом к бревну на станции LOG: проехал / встал / через руль (OBSTACLE) / упал иначе
func over_log(h: Heightfield, d: TrailDefinition, contact: bool, speed: float) -> Dictionary:
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = contact
	var at := d.point_at(LOG - 10.0)
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(LOG - 10.0)
	b.mount(p)
	b.speed = speed
	var control := BikeController.new()
	var before := speed
	var still := 0.0
	for tick in 60 * 10:
		var station := d.nearest(Vector2(b.x, b.z)).x
		var hold := clampf((speed - b.speed) * 0.8, 0.0, 1.0) if station < LOG - 3.0 else 0.0
		if station < LOG - 1.5: before = b.speed
		control.ride(1.0 / 60.0, p, b, h.world, h, hold, 0.0, false, false, false)
		if b.crashed:
			return {result = "через руль" if b.crash_cause == BikeRide.CrashCause.OBSTACLE else "упал", before = before, after = b.speed}
		if station > LOG + 2.0: return {result = "проехал", before = before, after = b.speed}
		still = still + 1.0 / 60.0 if absf(b.speed) < 0.1 else 0.0
		if still > 1.0: return {result = "встал", before = before, after = 0.0}
	return {result = "не доехал", before = before, after = b.speed}


## Согласованность контактов: сила шины не больше её нагрузки, разгруженное колесо не тормозит и не держит бок —
## на гребне роллера с полным тормозом и рулём, при 30/60/120 Гц.
func consistency(h: Heightfield, d: TrailDefinition) -> void:
	for hz: int in [30, 60, 120]:
		var p := PlayerState.new()
		var b := BikeRide.new()
		b.contact_model = true
		var at := d.point_at(ROLLER - 16.0)
		b.x = at.x
		b.z = at.y
		b.y = h.surface_at(b.x, b.z, -INF)
		b.heading = d.heading_at(ROLLER - 16.0)
		b.mount(p)
		b.speed = 10.0
		var control := BikeController.new()
		var over_load := 0
		var unloaded_force := 0
		var unloaded := 0
		# Сила хранится от последнего подшага. При 30 Гц колесо может восстановить контакт
		# внутри кадра: сравнивать эту силу с нагрузкой НАЧАЛА всего кадра неверно.
		# Здесь проверяем каждый подшаг; заезды выше и crossings проверяют полный шаг 30/60/120 Гц.
		var substeps := maxi(1, ceili(BikeRide.SUB_HZ / hz))
		for tick in hz * 4:
			var station := d.nearest(Vector2(b.x, b.z)).x
			if station > ROLLER + 8.0 or b.crashed: break
			var near := station > ROLLER - 3.0
			for substep in substeps:
				var was := Vector2(b.load_f, b.load_r)
				control.ride(1.0 / hz / substeps, p, b, h.world, h, -1.0 if near else 0.0, 1.0 if near else 0.0, false, false, false)
				if b.airborne: continue
				over_load += int(b.tire_f > b.load_f + 1e-5 or b.tire_r > b.load_r + 1e-5 or b.side_f > b.tire_f + 1e-5 or b.side_r > b.tire_r + 1e-5)
				for wheel: Array in [[was.x, b.force_f], [was.y, b.force_r]]:
					if wheel[0] <= 1e-4:
						unloaded += 1
						unloaded_force += int((wheel[1] as Vector2).length() > 1e-3)
		check(over_load == 0, "%d Гц: сила шины не больше её нагрузки" % hz)
		check(unloaded_force == 0, "%d Гц: разгруженное колесо не тормозит и не держит бок (%d тактов без нагрузки)" % [hz, unloaded])


## Бревно прямо и наискось (45°), два камня вплотную: потеря, снос вдоль бревна, число встреч; 30/60/120 Гц.
func crossings(h: Heightfield, d: TrailDefinition, technical: Dictionary) -> void:
	var at := d.point_at(LOG)
	var base := h.ground_at(at.x, at.y)
	var forward := d.tangent_at(LOG)
	var across := Vector2(forward.y, -forward.x)
	var slant := (across + forward) * 1.6
	var cases := {
		straight = PackedFloat32Array([at.x - across.x * 2.0, at.y - across.y * 2.0, at.x + across.x * 2.0, at.y + across.y * 2.0, 0.15, base, base + 0.3]),
		oblique = PackedFloat32Array([at.x - slant.x, at.y - slant.y, at.x + slant.x, at.y + slant.y, 0.15, base, base + 0.3]),
		rocks = PackedFloat32Array([at.x, at.y, at.x, at.y, 0.4, base, base + 0.22,
			at.x + forward.x * 0.75, at.y + forward.y * 0.75, at.x + forward.x * 0.75, at.y + forward.y * 0.75, 0.4, base, base + 0.3]),
	}
	var result := {}
	for name: String in cases:
		h.obstacles.set_trail(technical.collide + cases[name], technical.bumps)
		h.obstacles.update(at.x, at.y, PackedFloat32Array(), 1, true)
		var line := PackedStringArray()
		for hz: int in [30, 60, 120]:
			var r := cross(h, d, hz, 7.0)
			result["%s_%d" % [name, hz]] = r
			line.append("%d Гц: %s, %.1f→%.1f м/с, вбок %.2f м, встреч %d/%d" % [hz, r.result, r.before, r.after, r.drift, r.impacts.x, r.impacts.y])
		print("%s: %s" % [name, " · ".join(line)])
		var same := true
		for hz: int in [30, 120]:
			same = same and result["%s_%d" % [name, hz]].result == result["%s_60" % name].result and absf(result["%s_%d" % [name, hz]].after - result["%s_60" % name].after) < 0.35
		check(same, "%s: 30/60/120 Гц дают тот же исход" % name)
	var s: Dictionary = result.straight_60
	var o: Dictionary = result.oblique_60
	check(o.result == "проехал" and o.before - o.after < (s.before - s.after) * 0.8, "наискось бревно отнимает меньше скорости, чем прямо (%.1f против %.1f м/с)" % [o.before - o.after, s.before - s.after])
	check(o.drift > s.drift + 0.05, "наискось бревно сдвигает колесо вдоль себя (%.2f м против %.2f)" % [o.drift, s.drift])
	check(result.rocks_60.impacts.x == 2, "два камня вплотную — две встречи переднего колеса (%d)" % result.rocks_60.impacts.x)
	h.obstacles.set_trail(technical.collide, technical.bumps)


## Задним ходом в бревно: удар не разгоняет назад (импульс вычитается из вектора скорости)
func reverse_hit(h: Heightfield, d: TrailDefinition, technical: Dictionary) -> void:
	var at := d.point_at(LOG)
	var base := h.ground_at(at.x, at.y)
	var forward := d.tangent_at(LOG)
	var across := Vector2(forward.y, -forward.x)
	h.obstacles.set_trail(technical.collide + PackedFloat32Array([at.x - across.x * 2.0, at.y - across.y * 2.0, at.x + across.x * 2.0, at.y + across.y * 2.0, 0.1, base, base + 0.2]), technical.bumps)
	h.obstacles.update(at.x, at.y, PackedFloat32Array(), 1, true)
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = true
	var start := d.point_at(LOG + 2.5)
	b.x = start.x
	b.z = start.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(LOG)
	b.mount(p)
	var control := BikeController.new()
	var fastest := 0.0
	var hits := 0
	for tick in 60 * 6:
		control.ride(1.0 / 60.0, p, b, h.world, h, -1.0, 0.0, false, false, false)
		fastest = maxf(fastest, -b.speed)
		hits = b.impacts.x + b.impacts.y
	print("Задний ход в бревно: наибольшая скорость назад %.2f м/с, встреч %d" % [fastest, hits])
	check(hits > 0 and fastest <= GameConfig.BIKE_REVERSE + 0.01, "задним ходом удар о бревно не разгоняет назад (%.2f м/с)" % fastest)
	h.obstacles.set_trail(technical.collide, technical.bumps)


func cross(h: Heightfield, d: TrailDefinition, hz: int, speed: float) -> Dictionary:
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = true
	var at := d.point_at(LOG - 10.0)
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(LOG - 10.0)
	b.mount(p)
	b.speed = speed
	var control := BikeController.new()
	var before := speed
	var drift := 0.0
	for tick in hz * 8:
		var near := d.nearest(Vector2(b.x, b.z))
		if near.x < LOG - 1.5: before = b.speed
		control.ride(1.0 / hz, p, b, h.world, h, clampf((speed - b.speed) * 0.8, 0.0, 1.0) if near.x < LOG - 3.0 else 0.0, 0.0, false, false, false)
		drift = maxf(drift, absf(near.y))
		if b.crashed: return {result = "через руль" if b.crash_cause == BikeRide.CrashCause.OBSTACLE else "упал", before = before, after = b.speed, drift = drift, impacts = b.impacts}
		if near.x > LOG + 3.0: return {result = "проехал", before = before, after = b.speed, drift = drift, impacts = b.impacts}
	return {result = "не доехал", before = before, after = b.speed, drift = drift, impacts = b.impacts}


func run() -> void:
	var d := section()
	var kit: Array[TrailDefinition] = [d]
	var prepared := Fixture.prepare(kit)
	check(prepared.errors.is_empty(), "секция собрана: %s" % "; ".join(prepared.errors))
	if not prepared.errors.is_empty():
		quit(1)
		return
	var h: Heightfield = prepared.heights
	var technical := TrailTechnical.build(h, kit)
	h.obstacles.set_trail(technical.collide, technical.bumps)
	var profile := PackedStringArray()
	for s: float in [ROLLER - 8.0, ROLLER - 6.0, ROLLER - 4.0, ROLLER, ROLLER + 4.0]:
		var q := d.point_at(s)
		profile.append("%.0f м: %.2f" % [s, h.ground_at(q.x, q.y)])
	print("Профиль роллера: ", ", ".join(profile))
	# 1. Тормоз: на гребне колёса разгружены — замедление ниже, чем в ложбине перед роллером, где они прижаты.
	var crest := Vector2(ROLLER - 1.0, ROLLER + 1.0)
	var trough := Vector2(ROLLER - 5.5, ROLLER - 3.5)
	var result := {}
	for hz in [60, 120]:
		for name: String in ["crest", "trough"]:
			for contact in [false, true]:
				var r := ride(h, d, contact, hz, ROLLER - 16.0, ROLLER + 10.0, 9.0, crest if name == "crest" else trough)
				result["%s_%s_%d" % [name, "new" if contact else "old", hz]] = r
	if "--trace" in OS.get_cmdline_user_args():
		ride(h, d, true, 60, ROLLER - 16.0, ROLLER + 10.0, 9.0, crest, false, Vector2(-1, -1), true)
	for hz in [60, 120]:
		var crest_ratio: float = result["crest_new_%d" % hz].decel / maxf(result["crest_old_%d" % hz].decel, 0.01)
		var trough_ratio: float = result["trough_new_%d" % hz].decel / maxf(result["trough_old_%d" % hz].decel, 0.01)
		print("%d Гц: замедление на гребне %.2f → %.2f м/с² (×%.2f, нагрузка %.2f, в воздухе %d), в ложбине %.2f → %.2f м/с² (×%.2f, нагрузка %.2f)" % [hz,
			result["crest_old_%d" % hz].decel, result["crest_new_%d" % hz].decel, crest_ratio, result["crest_new_%d" % hz].brake_load, result["crest_new_%d" % hz].brake_air,
			result["trough_old_%d" % hz].decel, result["trough_new_%d" % hz].decel, trough_ratio, result["trough_new_%d" % hz].brake_load])
		check(crest_ratio < 0.95 and trough_ratio > crest_ratio + 0.1, "%d Гц: тормоз на гребне держит хуже, чем в ложбине" % hz)
	check(absf(result.crest_new_60.decel - result.crest_new_120.decel) < 0.6, "гребень: 60 и 120 Гц совпадают (%.2f / %.2f)" % [result.crest_new_60.decel, result.crest_new_120.decel])
	# 1б. Поворот: на гребне переднее колесо разгружено — велосипед поворачивает слабее, чем в ложбине.
	var turns := {}
	for name: String in ["crest", "trough"]:
		for contact in [false, true]:
			turns["%s_%s" % [name, "new" if contact else "old"]] = ride(h, d, contact, 60, ROLLER - 16.0, ROLLER + 10.0, 9.0, Vector2(-1, -1), false, Vector2(-1, -1), false, crest if name == "crest" else trough).yaw
	var crest_turn: float = turns.crest_new / maxf(turns.crest_old, 0.001)
	var trough_turn: float = turns.trough_new / maxf(turns.trough_old, 0.001)
	print("Поворот: на гребне %.2f → %.2f рад/с (×%.2f), в ложбине %.2f → %.2f рад/с (×%.2f)" % [turns.crest_old, turns.crest_new, crest_turn, turns.trough_old, turns.trough_new, trough_turn])
	check(crest_turn < 0.95 and trough_turn > crest_turn + 0.05, "на гребне поворот слабее, чем в ложбине")
	# 2. Контруклон: тяжесть поперёк тянет вниз; тормоз отнимает запас у заднего колеса и сносит сильнее.
	var zone := Vector2(CAMBER - 12.0, CAMBER + 12.0)
	var old_coast := ride(h, d, false, 60, CAMBER - 22.0, CAMBER + 14.0, 8.0, Vector2(-1, -1), true, zone)
	var new_coast := ride(h, d, true, 60, CAMBER - 22.0, CAMBER + 14.0, 8.0, Vector2(-1, -1), true, zone)
	var new_brake := ride(h, d, true, 60, CAMBER - 22.0, CAMBER + 14.0, 8.0, Vector2(CAMBER - 4.0, CAMBER + 2.0), true, zone)
	print("Контруклон: снос от оси %.2f м (прежняя) / %.2f м (два контакта) / %.2f м с тормозом; заднее колесо до %.0f%% / %.0f%%; поперечный уклон до %.0f%%" % [
		old_coast.offset, new_coast.offset, new_brake.offset, new_coast.peak_use_r * 100.0, new_brake.peak_use_r * 100.0, new_coast.bank * 100.0])
	check(new_coast.offset > old_coast.offset + 0.05, "контруклон сносит вниз в модели двух контактов")
	check(new_brake.offset > new_coast.offset + 0.3, "тормоз на контруклоне отнимает запас у поворота: сносит сильнее")
	check(not new_coast.crashed and not new_brake.crashed, "контруклон проезжается без падения")
	# 3. Корни: удар прижимает переднее колесо, отскок его разгружает.
	var roots := ride(h, d, true, 60, ROOTS - 12.0, ROOTS + 10.0, 8.0, Vector2(-1, -1), false, Vector2(ROOTS - 7.0, ROOTS + 7.0))
	print("Корни: нагрузка переднего колеса %.2f … %.2f доли веса (стоя 0,5)" % [roots.min_load_f, roots.max_load_f])
	check(technical.bumps.size() > 0, "корни разложены (%d)" % (technical.bumps.size() / ForestObstacles.BUMP_STRIDE))
	# влияние корней: тот же заезд без них — корни должны заметно отнимать ход (BUMP_DRAG) или раскачивать нагрузку
	h.obstacles.set_trail(technical.collide, PackedFloat32Array())
	var bare := ride(h, d, true, 60, ROOTS - 12.0, ROOTS + 10.0, 8.0, Vector2(-1, -1), false, Vector2(ROOTS - 7.0, ROOTS + 7.0))
	h.obstacles.set_trail(technical.collide, technical.bumps)
	print("Корни: скорость после %.2f против %.2f м/с без корней; размах нагрузки %.2f против %.2f" % [roots.exit, bare.exit, roots.max_load_f - roots.min_load_f, bare.max_load_f - bare.min_load_f])
	check(roots.max_load_f - roots.min_load_f > bare.max_load_f - bare.min_load_f, "корни раскачивают нагрузку переднего колеса")
	# корни скользкие: тормоз на них держит хуже, чем на голой земле
	var window := Vector2(ROOTS - 6.0, ROOTS - 2.0)
	var brake_roots := ride(h, d, true, 60, ROOTS - 12.0, ROOTS + 10.0, 10.0, window)
	h.obstacles.set_trail(technical.collide, PackedFloat32Array())
	var brake_bare := ride(h, d, true, 60, ROOTS - 12.0, ROOTS + 10.0, 10.0, window)
	h.obstacles.set_trail(technical.collide, technical.bumps)
	print("Тормоз на корнях: %.2f м/с² против %.2f без корней" % [brake_roots.decel, brake_bare.decel])
	# корень узкий (0,2 м): на 10 м/с колесо скользит на нём сотые доли секунды, тормозной путь почти тот же —
	# заметен срыв только при повороте и торможении на частых корнях. Проверяем, что тормоз на корнях не сильнее.
	check(brake_roots.decel <= brake_bare.decel + 0.05, "тормоз на корнях не держит лучше, чем на голой земле")
	# 4. Бревно поперёк: в прежней модели — стена; в новой колесо встречает кромку: медленно встаёт, средне
	# переваливает с потерей скорости, быстро — полёт через руль. Низкое бревно проезжается на любой скорости.
	for tall: float in [0.1, 0.4]:
		var at := d.point_at(LOG)
		var base := h.ground_at(at.x, at.y)
		var log := PackedFloat32Array([at.x - 2.0, at.y, at.x + 2.0, at.y, tall * 0.5, base, base + tall])
		h.obstacles.set_trail(technical.collide + log, technical.bumps)
		h.obstacles.update(at.x, at.y, PackedFloat32Array(), 1, true)
		var line := PackedStringArray()
		for speed: float in [2.5, 5.0, 10.0]:
			for contact in [false, true]:
				var r := over_log(h, d, contact, speed)
				line.append("%s %.0f м/с: %s %.1f→%.1f" % ["новая" if contact else "старая", speed, r.result, r.before, r.after])
				if not contact:
					check(r.result != "проехал", "%.1f м, %.0f м/с, прежняя модель: бревно — стена" % [tall, speed])
				elif tall < 0.2:
					check(r.result == "проехал" and r.after > r.before * 0.6, "%.1f м, %.0f м/с: низкое бревно проезжается, теряя меньше 40%% скорости" % [tall, speed])
				elif speed < 3.0:
					check(r.result == "встал", "%.1f м, %.0f м/с накатом: колесо упирается, велосипед встаёт без падения" % [tall, speed])
				elif speed < 6.0:
					check(r.result == "проехал" and r.after < r.before * 0.75, "%.1f м, %.0f м/с: переваливает с заметной потерей скорости" % [tall, speed])
				else:
					check(r.result == "через руль", "%.1f м, %.0f м/с: полёт через руль" % [tall, speed])
		print("Бревно %.1f м: %s" % [tall, " · ".join(line)])
	h.obstacles.set_trail(technical.collide, technical.bumps)
	consistency(h, d)
	reverse_hit(h, d, technical)
	crossings(h, d, technical)
	print("wheel_contact: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)
