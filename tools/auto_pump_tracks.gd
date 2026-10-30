extends "res://tools/trail_polygon_audit.gd"
## Same prepared tracks and inputs with/without pumping. Parent stores actual trajectories and full metrics.
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()

func run() -> void:
	started = Time.get_ticks_msec()
	out_path = "res://tools/control/runs/auto_pump_tracks"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path))
	result = {runs = [], skipped = [], tracks = []}
	var args := OS.get_cmdline_user_args()
	if "--on-only" in args:
		out_path += "_final"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path))
	var presets: Array = [2, 9, 15]
	if "--presets" in args: presets = Array(args[args.find("--presets") + 1].split(",")).map(func(n: String) -> int: return int(n))
	for number: int in presets:
		var kit := TrailLabCatalog.routes(number - 1, Fixture)
		d = kit[0]
		var before := Time.get_ticks_msec()
		var prepared := Fixture.prepare(kit, true, TrailLabCatalog.LIST[number - 1].ground)
		if not prepared.errors.is_empty():
			print("TRACK BUILD FAILED ", number, " ", prepared.errors)
			quit(1)
			return
		h = prepared.heights
		var technical := TrailTechnical.build(h, kit)
		h.obstacles.set_trail(technical.collide, technical.bumps)
		result.tracks.append({preset = number, title = d.title, length = d.route_length(), build_ms = Time.get_ticks_msec() - before})
		var styles := ["careful", "flow", "race"] if number == 15 else ["flow"]
		if "--styles" in args: styles = Array(args[args.find("--styles") + 1].split(","))
		for style: String in styles:
			for enabled: bool in ([true] if "--on-only" in args else [false, true]):
				add_run({name = "p%d_%s_%s" % [number, style, "on" if enabled else "off"], style = style, mode = "pilot", pump = enabled,
					preset = number, from = 1.0, to = d.route_length() - 3.0, speed = 4.0, max_time = 420.0, hz = 60})
	result.elapsed_ms = Time.get_ticks_msec() - started
	save_result()
	print("AUTO PUMP TRACKS COMPLETE ", result.runs.size(), " rides, ", result.skipped.size(), " skipped, ", result.elapsed_ms, " ms")
	quit(0 if result.skipped.is_empty() else 2)
