extends "res://tools/trail_polygon_audit.gd"
## Реальные заезды по №16/17. --preset 16|17; --quick — три манеры; --capture — обзор и вид с трассы.
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()

func run() -> void:
	started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	var capture_only := "--capture-only" in args
	var number := int(args[args.find("--preset") + 1]) if "--preset" in args else 16
	out_path = "res://tools/control/runs/adventures_%d" % number
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path))
	var kit := TrailLabCatalog.routes(number - 1, Fixture)
	d = kit[0]
	var prepared := Fixture.prepare(kit, true, TrailLabCatalog.LIST[number - 1].ground)
	if not prepared.errors.is_empty():
		print("BUILD FAILED ", prepared.errors)
		quit(1)
		return
	h = prepared.heights
	var technical := TrailTechnical.build(h, kit)
	h.obstacles.set_trail(technical.collide, technical.bumps)
	var survey := TrailSurvey.measure(h, d, 0.25 if number == 16 else 0.18)
	result = {runs = [], skipped = [], preset = number, title = d.title, geometry = {
		length = d.route_length(), climb = survey.climb, descent = survey.descent, width = d.width,
		min_radius = survey.min_radius, peak_grade = survey.peak_grade_track, summary = survey.summary()}, elements = []}
	for e in d.elements:
		result.elements.append({kind = TrailElementLibrary.title(e.profile), station = e.station, length = e.length, height = e.height})
	result.profile = []
	for i in survey.stations.size():
		var at := d.point_at(survey.stations[i])
		result.profile.append({s = survey.stations[i], x = at.x, z = at.y, y = survey.support[i]})
	print("ADVENTURE ", number, " ", result.geometry)
	for style: String in ([] if capture_only else Pilot.ORDER):
		add_run({name = style, style = style, mode = "pilot", from = 2.0, to = d.route_length() - 3.0, speed = 4.0, max_time = 420.0, hz = 60})
	if "--quick" not in args and not capture_only:
		add_run({name = "keyboard", style = "flow", mode = "keyboard", from = 2.0, to = d.route_length() - 3.0, speed = 4.0, max_time = 420.0, hz = 60})
		# Обычная езда без распознавания разрывов: никаких обязательных прыжков/скрытого разгона.
		add_run({name = "no_gap_assist", style = "flow", mode = "no_gap", from = 2.0, to = d.route_length() - 3.0, speed = 4.0, max_time = 420.0, hz = 60})
		# Старт с нулевой скорости в реальном уклоне (в том числе на двух подъёмах XC).
		for fraction: float in [0.15, 0.65]:
			var station := d.route_length() * fraction
			add_run({name = "restart_%d" % station, style = "careful", mode = "pilot", from = station, to = station + 90.0, speed = 0.0, max_time = 40.0, hz = 60})
		var first_table: TrailElement
		for e in d.elements:
			if e.profile == TrailElement.Profile.TABLETOP:
				first_table = e
				break
		add_run({name = "brake_before_table", style = "flow", mode = "brake_release", from = first_table.station - first_table.length * 0.5 - 20.0,
			to = first_table.station + 45.0, speed = 13.0, max_time = 25.0, hz = 60})
		for e in d.elements:
			if e.profile not in [TrailElement.Profile.TABLETOP, TrailElement.Profile.LOG]: continue
			var from := e.station - e.length * 0.5 - 8.0
			var to := e.station + e.length * 0.5 + 12.0
			if e.profile == TrailElement.Profile.TABLETOP:
				add_run({name = "slow_table_%d" % e.station, style = "careful", mode = "fixed_speed", from = from, to = to, speed = 3.0, target = 4.0, max_time = 30.0, hz = 60})
			else:
				for mode: String in ["space", "manual", "bypass"]:
					add_run({name = "log_" + mode, style = "careful" if mode == "bypass" else "flow", mode = mode, from = from, to = to,
						speed = 7.0, target = 7.0, feature = e.station, max_time = 20.0, hz = 60})
	if d.closed and not capture_only: result.seam = ride_seam()
	result.elapsed_ms = Time.get_ticks_msec() - started
	if not capture_only: save_result()
	if "--capture" in args:
		var lab := preload("res://scenes/trail_lab.tscn").instantiate()
		root.size = Vector2i(1280, 720)
		root.add_child(lab)
		lab.set_physics_process(false)
		lab.ground_kind = TrailLabCatalog.LIST[number - 1].ground
		lab.rebuild(kit, -1.0, prepared)
		lab.preset = number - 1
		lab._mark_preset()
		lab.markers.hide()
		lab.survey_markers.hide()
		lab.set_overview(true)
		lab.markers.hide()
		lab.survey_markers.hide()
		lab.status.hide()
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out_path + "/overview.png")
		lab.set_overview(false)
		# Середина маршрута: не только стартовая площадка.
		lab.reset_ride(d.route_length() * 0.53)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out_path + "/rider.png")
		lab.queue_free()
		await process_frame
	var failed: bool = not result.skipped.is_empty()
	if result.has("seam"): failed = failed or not result.seam.passed
	for r: Dictionary in result.runs: failed = failed or r.status != "finished" or r.off_time > 0.5
	print("ADVENTURES COMPLETE ", result.runs.size(), " rides; ", "FAIL" if failed else "PASS", "; wall ", result.elapsed_ms)
	quit(1 if failed else 0)

## Настоящий переход через старт/финиш: продолжаем ехать и повторно читаем начало кольца, без teleport/reset.
func ride_seam() -> Dictionary:
	var from := d.route_length() - 25.0
	var p := PlayerState.new()
	var at := d.point_at(from)
	p.x = at.x
	p.z = at.y
	p.feet = h.surface_at(at.x, at.y, -INF)
	# Тот же путь создания, что GameWorld: park_near, включая новую модель по умолчанию.
	var b := BikeRide.park_near(p, d.heading_at(from), h.world, h)
	b.mount(p)
	b.speed = 10.0
	var pilot := Pilot.new()
	pilot.reset(d, h, from)
	var control := BikeController.new()
	var off := 0.0
	for i in 60 * 10:
		h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1)
		var input := pilot.drive(b, d)
		control.ride(1.0 / 60, p, b, h.world, h, input.throttle, input.turn, input.run, input.jump, false)
		off = maxf(off, d.nearest(Vector2(b.x, b.z), 12.0).z)
		if b.crashed: break
	var ok := not b.crashed and pilot.station > 40.0 and pilot.station < 180.0 and off < d.width * 0.5 and b.contact_model
	print("XC SEAM ", "PASS" if ok else "FAIL", " station ", pilot.station, " off ", off)
	return {passed = ok, station = pilot.station, off = off, crashed = b.crashed}
