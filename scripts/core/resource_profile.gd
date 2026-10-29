extends RefCounted
## Opt-in diagnostics; unsupported GPU monitors are null, never invented zero measurements.
var phases: Array[Dictionary] = []
var frames: Array[Dictionary] = []
var _process_probe: RefCounted
var _last_frame_us := 0

func _init() -> void:
	var script := load("res://scripts/core/ProcessMetrics.cs")
	if script != null: _process_probe = script.new()

func stamp() -> Dictionary:
	return {us = Time.get_ticks_usec(), process = _process_probe.Capture() if _process_probe != null else {}}

func phase(name: String, before: Dictionary, services: ServiceScope, details := {}) -> Dictionary:
	var after := stamp()
	var row := {name = name, elapsed_ms = (after.us - before.us) / 1000.0,
		process = after.process, delta = {}, cache = services.cpu_budget.snapshot(),
		write_queue = services.cache.queue_stats.duplicate(), details = details}
	for field: String in ["cpu_ms", "calling_thread_cpu_ms", "managed_allocated_bytes", "gc0", "gc1", "gc2"]:
		if before.process.has(field) and after.process.has(field): row.delta[field] = after.process[field] - before.process[field]
	phases.append(row)
	return row

func frame(viewport: Viewport, elapsed_ms: float, game: GameWorld) -> void:
	# Frame time is wall time between calls; engine delta is smoothed/clamped and kept only for reference.
	var now := Time.get_ticks_usec()
	var wall_ms := (now - _last_frame_us) / 1000.0 if _last_frame_us != 0 else elapsed_ms
	_last_frame_us = now
	if frames.size() >= 600: return
	var graphical := DisplayServer.get_name() != "headless"
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid()) if graphical else 0.0
	frames.append({elapsed_ms = wall_ms, engine_delta_ms = elapsed_ms, process_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		render_cpu_ms = RenderingServer.viewport_get_measured_render_time_cpu(viewport.get_viewport_rid()) if graphical else null,
		render_setup_cpu_ms = RenderingServer.get_frame_setup_time_cpu() if graphical else null,
		gpu_ms = gpu_ms if gpu_ms > 0.0 else null, gpu_status = "measured" if gpu_ms > 0.0 else "unavailable",
		draw_calls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		triangles = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		video_bytes = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
		upload = game.chunk_source.snapshot() if game.chunk_source != null else {}, publication = game.stream_coordinator.stats.duplicate(true)})

func report() -> Dictionary:
	var times: Array[float] = []
	for row: Dictionary in frames: times.append(row.elapsed_ms)
	times.sort()
	return {phases = phases, frames = frames, p95_ms = _percentile(times, 0.95), p99_ms = _percentile(times, 0.99),
		notes = ["CPU/RSS counters are process snapshots; peak RSS is process lifetime.",
			"Cache and upload bytes are estimates, not measured VRAM/RSS caps.", "Unavailable GPU timers are null, never a zero-time GPU claim."]}

func save(path := "res://.godot/resource_report.json") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report(), "\t"))

func _percentile(values: Array[float], percentile: float) -> Variant:
	return values[mini(values.size() - 1, ceili(values.size() * percentile) - 1)] if not values.is_empty() else null
