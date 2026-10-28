extends SceneTree
## Rendered frame-time probe. No progress/settings writes; same camera path in every mode.
## -- --seed <seed> --mode normal|nav|frozen|bare --out <json> --seconds 20
const Dev = preload("res://tools/control/control.gd")
class ProbeMenu extends "res://scripts/ui/main.gd":
	func _menu_background_job(_seed: String) -> void: pass
	func _save_current(_slot := "auto") -> bool: return true
var main: Node
var navigation: MeshInstance3D
var game: GameWorld
var phase := "boot"
var elapsed := 0.0
var last := 0
var rows: Array = []
var phases := {}
var road := PackedVector2Array()
var distances := PackedFloat32Array()
var origin := Vector3.ZERO
var mode := "normal"
var started := 0
var costs := {}
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	setup.call_deferred()
func setup() -> void:
	mode = Dev.arg("mode", "normal")
	main = load("res://scenes/main.tscn").instantiate()
	main.set_script(ProbeMenu)
	root.add_child(main)
	GameContext.scope.cache.enabled = true
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	GameContext.scope.settings.draw = int(Dev.arg("draw", "2"))
	root.scaling_3d_scale = float(Dev.arg("scale", "1"))
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	started = Time.get_ticks_msec()
	main.start_game(Dev.arg("seed", "Гроза-4711"), 768)
	phase = "loading"
func _process(dt: float) -> bool:
	if phase == "boot": return false
	if phase == "loading":
		game = main.game
		if game == null or game.player == null:
			if Time.get_ticks_msec() - started > 300000: quit(2)
			return false
		game.paused = true
		navigation = game.navigation_line
		if not Dev.arg("reference-line").is_empty():
			navigation = load(Dev.arg("reference-line")).new()
			root.add_child(navigation)
			navigation.setup(game.world,game.heights)
		main.hud.hide()
		if game.pause_requested.is_connected(main._toggle_pause): game.pause_requested.disconnect(main._toggle_pause)
		game.hour = 12
		game.day.apply(game.hour, game.time)
		origin = Vector3(game.player.x, game.player.feet + GameConfig.EYE, game.player.z)
		var best := 0.0
		for route: Dictionary in game.world.trails:
			if route.kind == "road" and Dev.path_length(route.pts) > best:
				best = Dev.path_length(route.pts)
				road.clear()
				for p: Dictionary in route.pts: road.append(Vector2(p.x, p.y) * GameConfig.TILE)
		if road.size() < 2: road = PackedVector2Array([Vector2(origin.x, origin.z), Vector2(origin.x, origin.z - 500)])
		distances.append(0)
		for i in range(1, road.size()): distances.append(distances[-1] + road[i-1].distance_to(road[i]))
		for key in ["vegetation_budgeted", "terrain_update", "outer_update", "region_update"]:
			var original: Callable = game.stream_coordinator.get(key)
			if original.is_valid(): game.stream_coordinator.set(key, time_call(original, key))
		print("PROBE loaded ", (Time.get_ticks_msec()-started)/1000.0, " seconds; ", RenderingServer.get_video_adapter_name(), " mode=", mode)
		phase = "warmup"
		elapsed = 0
		last = Time.get_ticks_usec()
		return false
	elapsed += dt
	costs = {}
	var position := origin
	if phase in ["ride_warmup", "ride"]:
		var station := maxf(0, elapsed - (2.0 if phase == "ride_warmup" else 0.0)) * 12.0
		var p := point_at(station)
		var ahead := point_at(station + 8.0)
		position = Vector3(p.x, game.heights.ground_at(p.x, p.y) + GameConfig.EYE, p.y)
		var target := Vector3(ahead.x, game.heights.ground_at(ahead.x, ahead.y) + GameConfig.EYE, ahead.y)
		game.camera.look_at_from_position(position, target)
	else:
		game.camera.position = position
		game.camera.rotation = Vector3(-0.05, elapsed * 0.4, 0)
	var t := Time.get_ticks_usec()
	if mode in ["normal", "nav"]: game.stream_coordinator.update(position)
	var stream_ms := (Time.get_ticks_usec()-t)/1000.0
	game.day.apply(12, elapsed)
	var nav_start := Time.get_ticks_usec()
	if mode == "nav": navigation.update_line(position - Vector3.UP * GameConfig.EYE, dt, true)
	var nav_ms := (Time.get_ticks_usec() - nav_start) / 1000.0
	var now := Time.get_ticks_usec()
	if phase in ["look", "ride"]:
		var row := {phase=phase, nav_ms=nav_ms, frame_ms=(now-last)/1000.0, stream_ms=stream_ms, costs=costs.duplicate(),
			gpu_ms=RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()),
			render_cpu_ms=RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()),
			process_ms=Performance.get_monitor(Performance.TIME_PROCESS)*1000,
			physics_ms=Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000,
			detail_s=game.vegetation._detail_seconds, lead=game.vegetation.grass_lead.length(),
			pending=game.vegetation._pending.size(), grass=game.vegetation.grass.visible_instance_count}
		rows.append(row)
	last = now
	if phase == "warmup" and elapsed > 3:
		phase = "look"
		elapsed = 0
	elif phase == "look" and elapsed > 6:
		prepare_ride()
	elif phase == "ride_warmup" and elapsed > 2:
		phase = "ride"
		elapsed = 0
		last = Time.get_ticks_usec()
	elif phase == "ride" and elapsed > float(Dev.arg("seconds", "20")):
		finish()
	return false
func time_call(original: Callable, key: String) -> Callable:
	return func(a: Variant = null, b: Variant = null, c: Variant = null, d: Variant = null, e: Variant = null) -> Variant:
		var args := [a, b, c, d, e]
		while not args.is_empty() and args[-1] == null: args.pop_back()
		var started_us := Time.get_ticks_usec()
		var result: Variant = original.callv(args)
		costs[key] = (Time.get_ticks_usec() - started_us) / 1000.0
		return result
func point_at(station: float) -> Vector2:
	station = fposmod(station, distances[-1])
	for i in range(1, road.size()):
		if station <= distances[i]: return road[i-1].lerp(road[i], (station-distances[i-1]) / maxf(0.001, distances[i]-distances[i-1]))
	return road[-1]
func prepare_ride() -> void:
	var at := point_at(0)
	game.vegetation.update(at.x, at.y, true)
	game.terrain_stream.update(at.x, at.y, true)
	if mode == "bare": game.vegetation.hide()
	if mode == "nav":
		var begin := Time.get_ticks_usec()
		navigation.set_goal({kind="marker", x=road[-1].x/GameConfig.TILE, y=road[-1].y/GameConfig.TILE}, at, game.heights.ground_at(at.x, at.y))
		print("PROBE initial_navigation_ms=", (Time.get_ticks_usec()-begin)/1000.0)
	phase = "ride_warmup"
	elapsed = 0
	last = Time.get_ticks_usec()
func finish() -> void:
	for name in ["look", "ride"]:
		var selected := rows.filter(func(r: Dictionary) -> bool: return r.phase == name)
		var summary := {}
		for key in ["frame_ms", "nav_ms", "stream_ms", "gpu_ms", "render_cpu_ms", "process_ms", "physics_ms"]:
			var values: Array = selected.map(func(r: Dictionary): return r[key])
			values.sort()
			var total := 0.0
			for v: float in values: total += v
			summary[key] = {mean=total/maxi(1,values.size()), p99=values[int(values.size()*0.99)], max=values[-1]}
		var slow := selected.filter(func(r: Dictionary) -> bool: return r.frame_ms > 33.33)
		summary.slow_frames = slow.size()
		summary.frames = selected.size()
		summary.fps = 1000.0/summary.frame_ms.mean
		selected.sort_custom(func(a: Dictionary,b: Dictionary): return a.frame_ms > b.frame_ms)
		summary.worst = selected.slice(0, 12)
		phases[name] = summary
		print("PROBE %s: %.1f FPS, p99 %.1fms, max %.1fms, nav max %.1fms, stream max %.1fms" % [name, summary.fps, summary.frame_ms.p99, summary.frame_ms.max, summary.nav_ms.max, summary.stream_ms.max])
	var out := Dev.arg("out", "res://tools/control/runs/stutter_probe.json")
	Dev.save_json(Dev.abs_dir(out), {mode=mode, reference_line=Dev.arg("reference-line"), seed=Dev.arg("seed", "Гроза-4711"), road_hash=hash(road), road_length=distances[-1], scale=root.scaling_3d_scale, shadows=GameContext.scope.settings.shadows, msaa=root.msaa_3d, method=RenderingServer.get_current_rendering_method(), cpu=OS.get_processor_name(), phases=phases, rows=rows, gpu=RenderingServer.get_video_adapter_name(), draw=GameContext.scope.settings.draw, viewport=str(root.size)})
	quit(0)

