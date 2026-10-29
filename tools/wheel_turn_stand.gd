extends SceneTree
## Стенд поворотов для модели двух контактов (BikeRide.contact_model): широкое плотное полотно Trail Lab без мира,
## один и тот же ввод в прежней и новой модели на разных скоростях. Печатает таблицу: средняя скорость рыскания,
## её рывки от такта к такту, снос, потеря скорости, нагрузка переднего колеса. Не тест: проверок нет, только замеры.
##   godot --headless --path . --script res://tools/wheel_turn_stand.gd [-- --surface grass]
const Fixture = preload("res://tools/trail_lab_fixture.gd")


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()


func lane() -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = "turn_stand"
	d.title = "Стенд поворотов"
	d.points = PackedVector2Array([Vector2(128, 215), Vector2(128, 45)])
	d.width = 36.0
	d.surface = RoadSurface.PACKED
	d.elements = [] as Array[TrailElement]
	return d


## Прямо 1 с на скорости `speed`, затем руль `steer` в течение `hold` с (газ держит скорость), затем руль прямо 0,6 с.
func ride(h: Heightfield, contact: bool, hz: int, speed: float, steer: float, hold: float, start: Vector2, trace := false) -> Dictionary:
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = contact
	b.x = start.x
	b.z = start.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = 0.0
	b.mount(p)
	b.speed = speed
	var control := BikeController.new()
	var dt := 1.0 / hz
	var yaw := PackedFloat32Array()
	var loads := PackedFloat32Array()
	var slips := PackedFloat32Array()
	var prev_heading := b.heading
	var v0 := 0.0
	var settle := 0.0
	var ticks := int((1.0 + hold + 0.6) * hz)
	for tick in ticks:
		var t := tick * dt
		var s := steer if t >= 1.0 and t < 1.0 + hold else 0.0
		var throttle := clampf((speed - b.speed) * 0.6, 0.0, 1.0)
		control.ride(dt, p, b, h.world, h, throttle, s, false, false, false)
		var rate := wrapf(b.heading - prev_heading, -PI, PI) / dt
		if trace and t >= 1.6 and t < 1.9:
			print("  t %.3f · рыскание %.3f · шина %.3f/%.3f · снос %.2f° · бок %.3f · руль %.2f · use %.2f/%.2f" % [t, rate, b.tire_f, b.tire_r, rad_to_deg(b.slip), b.lateral_speed, b.steer, b.use_f, b.use_r])
		prev_heading = b.heading
		if is_equal_approx(t, 1.0) or (t >= 1.0 and v0 == 0.0): v0 = b.speed
		# последние 2/3 удержания руля — установившийся поворот
		if t >= 1.0 + hold / 3.0 and t < 1.0 + hold:
			yaw.append(rate)
			loads.append(b.tire_f)
			slips.append(absf(b.slip))
		if t >= 1.0 + hold and absf(rate) > 0.05: settle = t - 1.0 - hold
		if b.crashed: break
	var mean := 0.0
	for r in yaw: mean += absf(r)
	mean /= maxf(1, yaw.size())
	var jerk := 0.0
	for i in range(1, yaw.size()): jerk += absf(yaw[i] - yaw[i - 1])
	jerk /= maxf(1, yaw.size() - 1)
	var lo := INF
	var hi := 0.0
	var lmean := 0.0
	for l in loads:
		lo = minf(lo, l)
		hi = maxf(hi, l)
		lmean += l
	lmean /= maxf(1, loads.size())
	var slip := 0.0
	for x in slips: slip = maxf(slip, x)
	return {yaw = mean, jerk = jerk, radius = b.speed / maxf(mean, 0.001), slip = rad_to_deg(slip), loss = v0 - b.speed,
		load_lo = lo, load_hi = hi, load = lmean, settle = settle, crashed = b.crashed}


func run() -> void:
	var d := lane()
	var kit: Array[TrailDefinition] = [d]
	var grass := "--surface" in OS.get_cmdline_user_args() and "grass" in OS.get_cmdline_user_args()
	var prepared := Fixture.prepare(kit if not grass else [] as Array[TrailDefinition])
	if not prepared.errors.is_empty():
		print("стенд не собран: ", prepared.errors)
		quit(1)
		return
	var h: Heightfield = prepared.heights
	if "--trace" in OS.get_cmdline_user_args():
		ride(h, true, 60, 14.0, 1.0, 1.5, Vector2(128, 205), true)
		quit(0)
		return
	var hz_list := [60]
	if "--hz" in OS.get_cmdline_user_args(): hz_list = [30, 60, 120]
	print("Покрытие: ", "трава (вне полотна)" if grass else "плотный грунт")
	print("скорость руль модель Гц | рыскание рад/с | рывки рад/с за такт | радиус м | снос ° | потеря м/с | шина перед (мин…макс, сред) | успокоение с")
	for speed: float in [6.0, 10.0, 14.0, 18.0]:
		for steer: float in [0.5, 1.0]:
			for contact in [false, true]:
				for hz: int in hz_list:
					var r := ride(h, contact, hz, speed, steer, 1.5, Vector2(128, 205))
					print("%4.0f %4.1f %-6s %3d | %5.2f | %6.3f | %5.1f | %4.1f | %5.2f | %.2f…%.2f (%.2f) | %.2f%s" % [speed, steer, "новая" if contact else "старая", hz,
						r.yaw, r.jerk, r.radius, r.slip, r.loss, r.load_lo, r.load_hi, r.load, r.settle, " ПАДЕНИЕ" if r.crashed else ""])
	quit(0)
