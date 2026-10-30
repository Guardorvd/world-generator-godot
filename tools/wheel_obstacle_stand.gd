extends SceneTree
## Колесо и препятствие (модель двух контактов): ровное полотно Trail Lab без мира, одно бревно поперёк или валун
## на оси, подъезд на разной скорости накатом или с педалями, прежняя и новая модель. Печатает таблицу исходов:
## проехал / встал / упал (причина), скорость после, потерю скорости. Только замеры, проверок нет.
##   godot --headless --path . --script res://tools/wheel_obstacle_stand.gd
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const AT := 150.0 # z бревна, м (едем на север, к меньшим z)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()


func lane() -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = "obstacle_stand"
	d.title = "Стенд препятствий"
	d.points = PackedVector2Array([Vector2(128, 200), Vector2(128, 100)])
	d.width = 4.0
	d.surface = RoadSurface.PACKED
	d.elements = [] as Array[TrailElement]
	return d


## Препятствие в формате ForestObstacles.STRIDE: бревно поперёк (kind "log") или валун на оси ("rock")
func obstacle(h: Heightfield, kind: String, tall: float) -> PackedFloat32Array:
	var base := h.ground_at(128, AT)
	if kind == "log":
		return PackedFloat32Array([126.0, AT, 130.0, AT, tall * 0.5, base, base + tall])
	return PackedFloat32Array([128.0, AT, 128.0, AT, 0.5, base, base + tall])


func ride(h: Heightfield, contact: bool, speed: float, throttle: float) -> Dictionary:
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = contact
	b.x = 128.0
	b.z = AT + 12.0
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = 0.0
	b.mount(p)
	b.speed = speed
	var control := BikeController.new()
	var dt := 1.0 / 60.0
	var before := -1.0
	var still := 0.0
	var impact := 0.0
	for tick in 60 * 12:
		if b.z > AT + 1.5: before = b.speed
		# держать скорость подъезда до препятствия, дальше — заданный ввод
		var t := throttle if b.z < AT + 3.0 else clampf((speed - b.speed) * 0.8, 0.0, 1.0)
		control.ride(dt, p, b, h.world, h, t, 0.0, false, false, false)
		# удар колеса о кромку — отдельное событие (wheel_impact), приземление после подскока — land_impact
		impact = maxf(impact, maxf(b.land_impact, maxf(b.wheel_impact.x, b.wheel_impact.y)))
		b.land_impact = 0.0
		b.wheel_impact = Vector2()
		if b.crashed:
			return {result = "падение (%s)" % BikeRide.CrashCause.keys()[b.crash_cause], before = before, after = b.speed, impact = impact}
		if b.z < AT - 2.0:
			return {result = "проехал", before = before, after = b.speed, impact = impact}
		still = still + dt if absf(b.speed) < 0.1 else 0.0
		if still > 1.0:
			return {result = "встал (%.2f м до оси)" % (b.z - AT), before = before, after = 0.0, impact = impact}
	return {result = "не доехал", before = before, after = b.speed, impact = impact}


func run() -> void:
	var d := lane()
	var kit: Array[TrailDefinition] = [d]
	var prepared := Fixture.prepare(kit)
	var h: Heightfield = prepared.heights
	print("препятствие | подъезд м/с | ввод | модель | исход | скорость у препятствия → после | удар колеса м/с")
	for spec: Array in [["log", 0.1], ["log", 0.2], ["log", 0.3], ["log", 0.4], ["rock", 0.3]]:
		h.obstacles.set_trail(obstacle(h, spec[0], spec[1]), PackedFloat32Array())
		h.obstacles.update(128.0, AT, PackedFloat32Array(), 1, true)
		for speed: float in [1.5, 3.0, 5.0, 7.0, 10.0, 13.0]:
			for throttle: float in [0.0, 0.6]:
				for contact in [false, true]:
					var r := ride(h, contact, speed, throttle)
					print("%s %.1f м | %4.1f | %s | %s | %s | %.1f → %.1f | %.1f" % ["бревно" if spec[0] == "log" else "валун", spec[1], speed,
						"педали" if throttle > 0.0 else "накат", "новая" if contact else "старая", r.result, r.before, r.after, r.impact])
	quit(0)
