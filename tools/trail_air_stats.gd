extends "res://tools/trail_polygon_audit.gd"
## Полёты на готовых трассах Trail Lab (31.10): автопилот трёх манер проезжает трассу целиком; после падения заезд
## продолжается в 8 м дальше. По каждому отрыву длиннее 0,15 с — элемент, скорость взлёта, время, высота над точкой
## взлёта, просвет над землёй, удар; по трассе — время в воздухе, число прыжков, падения. Только замеры.
##   godot --headless --path . --script res://tools/trail_air_stats.gd -- --presets 15,18 [--styles flow]
const MIN_AIR := 0.15

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 900)
	run.call_deferred()

func add_run(spec: Dictionary) -> void:
	result.runs.append(ride(spec))

func element_at(station: float) -> String:
	for e in d.elements:
		if absf(station - e.station) <= e.length * 0.5 + 2.0: return "%s@%.0f" % [TrailElementLibrary.title(e.profile), e.station]
	return "—@%.0f" % station

func run() -> void:
	started = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	var presets := [15, 16, 17, 18]
	if "--presets" in args: presets = Array(args[args.find("--presets") + 1].split(",")).map(func(s: String) -> int: return int(s))
	var styles: Array = Pilot.ORDER
	if "--styles" in args: styles = Array(args[args.find("--styles") + 1].split(","))
	out_path = "user://trail_air_stats"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path))
	for number: int in presets:
		var kit := TrailLabCatalog.routes(number - 1, Fixture)
		var prepared := Fixture.prepare(kit, true, TrailLabCatalog.LIST[number - 1].ground)
		if not prepared.errors.is_empty():
			print("BUILD FAILED ", number, " ", prepared.errors)
			continue
		h = prepared.heights
		var technical := TrailTechnical.build(h, kit)
		h.obstacles.set_trail(technical.collide, technical.bumps)
		for lane in kit.size(): ride_lane(number, kit[lane], styles)
	print("\nвремя замера %.0f с" % ((Time.get_ticks_msec() - started) / 1000.0))
	quit()

func ride_lane(number: int, route: TrailDefinition, styles: Array) -> void:
		d = route
		var length := d.route_length()
		var survey := TrailSurvey.measure(h, d, 0.3)
		print("\n=== №%d %s · %.0f м · элементов %d · %s" % [number, d.title, length, d.elements.size(), survey.summary()])
		for style: String in styles:
			var from := 2.0
			var time := 0.0
			var air := 0.0
			var crashes: Array = []
			var flights: Array = []
			var top := 0.0
			while from < length - 10.0:
				result.runs.clear()
				add_run({name = "%d_%s_%s" % [number, d.id, style], style = style, mode = "pilot", from = from, to = length - 3.0,
					speed = 4.0 if from < 3.0 else 8.0, max_time = 420.0, hz = 60})
				var r: Dictionary = result.runs[0]
				time += r.time
				air += r.air_time
				top = maxf(top, r.top)
				for f: Dictionary in r.flights:
					if f.duration >= MIN_AIR: flights.append(f)
				if r.status == "crash":
					crashes.append("%s %s %.0f км/ч" % [element_at(r.crash.s), r.crash.cause, r.crash.velocity * 3.6])
					from = r.crash.s + 8.0
				elif r.status == "finished": break
				else:
					crashes.append("%s у %.0f м" % [r.status, r.station])
					from = r.station + 8.0
			print("— %s: %.1f с · в воздухе %.1f с · прыжков %d · макс %.0f км/ч · падений %d %s" % [style, time, air, flights.size(), top * 3.6, crashes.size(), crashes])
			for f: Dictionary in flights:
				print("    %-22s с %6.1f м · взлёт %4.1f м/с · %.2f с · выше взлёта %.2f м · просвет %.2f м · %4.1f м · удар %.1f" % [
					element_at(f.from), f.from, f.takeoff_speed, f.duration, f.rise, f.clearance, f.to - f.from, f.impact])
