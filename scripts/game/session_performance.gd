extends RefCounted
## Монитор обычной игры. Замер в начале кадра читает работу после предыдущей отметки.
const DIRECTORY := "user://session_performance"
static var dir := DIRECTORY
const WINDOW_US := 1_000_000
const TOP_FRAMES := 20
const UNMARKED_MIN_MS := 2.0 # неразмеченная работа _process меньше этого в доказательства долгого кадра не идёт
const GPU_EVIDENCE_MS := 1.0
const AFTER_SWITCH_US := 600_000 # кадр в пределах 0,6 с после смены режима помечается этой сменой
const MISSED_REFRESH := 1.5     # кадр дольше полутора кадров экрана — пропуск обновления экрана (видно глазом)
const FrameStatistics := preload("res://scripts/core/frame_statistics.gd")
const Report := preload("res://scripts/game/session_performance_report.gd")
const CacheFile := preload("res://scripts/core/cache_file.gd")

var _start_us: int
var _last_us: int
var _started_at: String
var _serial: int
var _machine: Dictionary
var _loading: Dictionary
var _seed: String
var _viewport: RID
var _graphical: bool
var _mode: String
var _settings := {}
var _context := {}
var _context_due := 0
var _timeline: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _long_frames: Array[Dictionary] = []
var _worst: Array[Dictionary] = []
var _frames := PackedFloat32Array()
var _window: Dictionary
var _sum_ms := 0.0
var _over := Vector3i.ZERO
var _hitch_count := 0
var _work_totals := {}
var _previous_ticks := {}
var _tick_delta := {}
var _stream_frame := 0
var _stream_active := false
var _previous_chunks := {}
var _chunk_delta := {}
var _previous_pipelines: Vector4i
var _pipeline_delta := Vector4i.ZERO
var _pipeline_totals := Vector4i.ZERO
var _gc_probe: RefCounted
var _previous_gc := Vector4i.ZERO
var _gc_delta := Vector4i.ZERO
var _gc_totals := Vector4i.ZERO
var _render := {}
var _peaks := {}
var _baseline_by_mode := {}
var _main_work: Array[Dictionary] = []
var _sampling_us := 0
var _sampling_peak_us := 0
var _gpu_pending: Array[Dictionary] = []  # долгие кадры прошлого замера: ждут время GPU следующего кадра
var _frame_events: Array[String] = []     # события игры в измеряемом кадре
var _mode_since_us := 0
var _last_switch := {}                    # {at_us, from, held_s}: последняя смена режима
var _refresh_ms := 1000.0 / 60.0          # кадр экрана
var _missed_refresh := 0


func _init(game: Node, mode: String, now_us: int, loading := {}) -> void:
	_start_us = now_us
	_last_us = now_us
	_started_at = Time.get_datetime_string_from_system(false, true)
	_serial = OS.get_process_id()
	_seed = game.world.seed_text
	_loading = loading
	_mode = mode
	_viewport = game.get_viewport().get_viewport_rid()
	_graphical = DisplayServer.get_name() != "headless"
	_mode_since_us = now_us
	if _graphical:
		RenderingServer.viewport_set_measure_render_time(_viewport, true)
		var refresh_hz := DisplayServer.screen_get_refresh_rate()
		if refresh_hz >= 24.0:
			_refresh_ms = 1000.0 / refresh_hz
	_machine = {
		refresh_hz = 1000.0 / _refresh_ms,
		version = ProjectSettings.get_setting("application/config/version"),
		engine = Engine.get_version_info().string, os = OS.get_name(),
		cpu = OS.get_processor_name(), threads = OS.get_processor_count(),
		gpu = RenderingServer.get_video_adapter_name() if _graphical else null,
		renderer = RenderingServer.get_current_rendering_method(), debug = OS.is_debug_build(),
	}
	_window = _new_window()
	_previous_ticks = game.tick_us.duplicate()
	_stream_frame = game.stream_coordinator.stats.frames
	_previous_pipelines = FrameStatistics.pipeline_counts()
	var process_metrics := load("res://scripts/core/ProcessMetrics.cs") as Script
	if process_metrics != null and process_metrics.can_instantiate():
		var probe: RefCounted = process_metrics.new()
		if probe.has_method("CaptureGc"):
			_gc_probe = probe
			_previous_gc = _gc_probe.CaptureGc()
	_read_chunks(game)
	_read_context(game, now_us)


func work(name: String, began_us: int, ended_us: int, result := "", background := false) -> void:
	var row := {kind = name, t_s = _seconds(began_us), duration_ms = (ended_us - began_us) / 1000.0,
		result = result, background = background}
	_events.append(row)
	if not background:
		_main_work.append(row)


func sample(game: Node, next_mode: String, now_us: int) -> void:
	var sampling_began := Time.get_ticks_usec()
	var ms := (now_us - _last_us) / 1000.0
	if ms <= 0.0:
		return
	var frame_start := _last_us
	_last_us = now_us
	var typical: float = _baseline_by_mode.get(_mode, _baseline_by_mode.get("gameplay", minf(ms, 33.3)))
	var limit := FrameStatistics.hitch_limit(typical)
	var hitch := ms > limit
	# Вес длинного кадра ограничен, чтобы отдельный рывок не скрыл следующие.
	_baseline_by_mode[_mode] = lerpf(typical, clampf(ms, typical * 0.5, typical * 1.5), 0.05)
	_frames.append(ms)
	_sum_ms += ms
	var over := Vector3i(int(ms > 16.7), int(ms > 33.3), int(ms > 100.0))
	_over += over
	_hitch_count += int(hitch)
	_missed_refresh += int(ms > _refresh_ms * MISSED_REFRESH)
	_measure(game)
	# GPU-таймер отстаёт на кадр-два: время следующего кадра дописывается к прошлым долгим кадрам
	for row: Dictionary in _gpu_pending:
		row.render.gpu_next_ms = _render.gpu_ms
		if _render.gpu_ms != null and _render.gpu_ms >= GPU_EVIDENCE_MS:
			row.evidence.append({part = "gpu_next", ms = _render.gpu_ms})
	_gpu_pending.clear()
	# события игры этого кадра (открытие места, обзор, падение, снимок)
	_frame_events.clear()
	for event: Dictionary in game.take_perf_events():
		event.t_s = _seconds(frame_start)
		_events.append(event)
		_frame_events.append(event.kind)
	_window.frames += 1
	_window.hitches += int(hitch)
	_window.over += over
	_window.min_ms = minf(_window.min_ms, ms)
	_window.sum_ms += ms

	var long_frame := hitch or ms > 100.0
	var top: bool = (hitch or ms > 16.7) and (_worst.size() < TOP_FRAMES or ms > _worst[-1].ms)
	var window_peak: bool = ms > _window.max_ms
	if now_us >= _context_due or long_frame:
		_read_context(game, now_us)
	if long_frame or top or window_peak:
		var row := _frame_details(game, frame_start, ms, limit, hitch)
		if long_frame:
			_long_frames.append(row)
			_gpu_pending.append(row)
		if window_peak:
			_window.max_ms = ms
			_window.peak = {t_s = row.t_s, evidence = row.evidence, camera = row.camera}
		if top:
			_worst.append(row)
			_worst.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.ms > b.ms)
			if _worst.size() > TOP_FRAMES:
				_worst.pop_back()
	_main_work.clear()
	if now_us - _window.start_us >= WINDOW_US or _mode != next_mode:
		_flush_window()
	if _mode != next_mode:
		var held_s := (now_us - _mode_since_us) / 1000000.0
		_events.append({kind = "mode", t_s = _seconds(now_us), from = _mode, to = next_mode, held_s = held_s})
		_last_switch = {at_us = now_us, from = _mode, held_s = held_s}
		_mode_since_us = now_us
		_mode = next_mode
		_context_due = now_us
	var elapsed := Time.get_ticks_usec() - sampling_began
	_sampling_us += elapsed
	_sampling_peak_us = maxi(_sampling_peak_us, elapsed)


func _read_context(game: Node, now_us: int) -> void:
	var latest: Dictionary = game.performance_context()
	for key: String in ["biome", "region", "light", "settlement_zone", "settlement_id", "view"]:
		if not _context.is_empty() and latest[key] != _context[key]:
			_events.append({kind = key, t_s = _seconds(now_us), from = _context[key], to = latest[key]})
	_context = latest
	_context_due = now_us + WINDOW_US
	var settings: Dictionary = game.performance_settings()
	if settings != _settings:
		_events.append({kind = "graphics", t_s = _seconds(now_us), settings = settings})
		_settings = settings


func _measure(game: Node) -> void:
	for row: Dictionary in _main_work:
		_record_work(row.kind, roundi(row.duration_ms * 1000.0))
	for part: String in game.tick_us:
		var current: int = game.tick_us[part]
		var elapsed := maxi(current - int(_previous_ticks.get(part, 0)), 0)
		_previous_ticks[part] = current
		_tick_delta[part] = elapsed
		if part != "ticks" and part != "frames":
			_record_work(part, elapsed)
	var stream: Dictionary = game.stream_coordinator.stats
	_stream_active = stream.frames != _stream_frame
	_stream_frame = stream.frames
	if _stream_active:
		for i in stream.group_names.size():
			_record_work("stream/" + stream.group_names[i], stream.group_last_us[i])
		var vegetation: Dictionary = game.vegetation.phase_stats
		for i in vegetation.names.size():
			_record_work("vegetation/" + vegetation.names[i], vegetation.last_us[i])
	_read_chunks(game)
	var pipelines := FrameStatistics.pipeline_counts()
	_pipeline_delta = pipelines - _previous_pipelines
	_previous_pipelines = pipelines
	_pipeline_totals += _pipeline_delta
	_window.pipelines += _pipeline_delta
	if _gc_probe != null:
		var gc: Vector4i = _gc_probe.CaptureGc()
		_gc_delta = gc - _previous_gc
		_previous_gc = gc
		_gc_totals += _gc_delta
		_window.gc += _gc_delta
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_viewport) if _graphical else 0.0
	var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(_viewport) if _graphical else 0.0
	_monitor("gpu_ms", gpu_ms if gpu_ms > 0.0 else null)
	_monitor("render_cpu_ms", cpu_ms if cpu_ms > 0.0 else null)
	_monitor("draw_calls", int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)) if _graphical else null)
	_monitor("primitives", int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)) if _graphical else null)
	_monitor("physics_ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_monitor("process_ms", Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_monitor("video_mb", Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0 if _graphical else null)
	_monitor("static_mb", Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)
	_monitor("nodes", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func _read_chunks(game: Node) -> void:
	if game.chunk_source == null:
		return
	var stats: Dictionary = game.chunk_source.stats
	for key: String in ["reads", "read_ms", "upload_ms", "upload_bytes", "repairs"]:
		var value: float = stats[key]
		var change := maxf(value - float(_previous_chunks.get(key, value)), 0.0)
		_chunk_delta[key] = change
		_previous_chunks[key] = value
		_window.chunks[key] = _window.chunks.get(key, 0.0) + change


func _monitor(key: String, value: Variant) -> void:
	_render[key] = value
	if value == null:
		return
	var sums: Dictionary = _window.monitors
	var entry: Vector2 = sums.get(key, Vector2.ZERO)
	sums[key] = Vector2(entry.x + float(value), entry.y + 1.0)
	_peaks[key] = maxf(_peaks.get(key, 0.0), float(value))


func _record_work(part: String, elapsed_us: int) -> void:
	var totals: Vector2i = _window.work.get(part, Vector2i.ZERO)
	_window.work[part] = Vector2i(totals.x + elapsed_us, maxi(totals.y, elapsed_us))


func _frame_details(game: Node, began_us: int, ms: float, limit: float, hitch: bool) -> Dictionary:
	var tick_ms := {}
	var stream_ms := {}
	var vegetation_ms := {}
	var evidence: Array[Dictionary] = []
	for part: String in _tick_delta:
		if part != "ticks" and part != "frames":
			tick_ms[part] = float(_tick_delta[part]) / 1000.0
	for row: Dictionary in _main_work:
		evidence.append({part = row.kind, ms = row.duration_ms})
	for kind: String in _frame_events:
		evidence.append({part = "event_" + kind})
	# 20.11: кадр вскоре после смены режима (закрыли карту, вышли из паузы) — откуда и сколько там пробыли
	if not _last_switch.is_empty() and began_us - int(_last_switch.at_us) <= AFTER_SWITCH_US:
		evidence.append({part = "after_mode", from = _last_switch.from, held_s = _last_switch.held_s})
	_add_largest(evidence, tick_ms, "")
	if _stream_active:
		var stream: Dictionary = game.stream_coordinator.stats
		var vegetation: Dictionary = game.vegetation.phase_stats
		for i in stream.group_names.size():
			stream_ms[stream.group_names[i]] = stream.group_last_us[i] / 1000.0
		for i in vegetation.names.size():
			vegetation_ms[vegetation.names[i]] = vegetation.last_us[i] / 1000.0
		_add_largest(evidence, stream_ms, "stream/")
		_add_largest(evidence, vegetation_ms, "vegetation/")
	# 20.11: _process всех узлов за кадр минус размеченные части кадра GameWorld (frame_*) — работа интерфейса,
	# main и прочих узлов, которую замеры не называют (так прятались ~50 мс у открытия мест)
	var marked_ms := 0.0
	for part: String in tick_ms:
		if part.begins_with("frame_"):
			marked_ms += tick_ms[part]
	var unmarked_ms: float = _render.process_ms - marked_ms
	if unmarked_ms >= UNMARKED_MIN_MS:
		evidence.append({part = "process_unmarked", ms = unmarked_ms})
	if _render.gpu_ms != null and _render.gpu_ms >= 1.0:
		evidence.append({part = "gpu", ms = _render.gpu_ms})
	if _render.render_cpu_ms != null and _render.render_cpu_ms >= 1.0:
		evidence.append({part = "render_cpu", ms = _render.render_cpu_ms})
	if _chunk_delta.get("upload_ms", 0.0) >= 0.5:
		evidence.append({part = "chunk_upload", ms = _chunk_delta.upload_ms})
	var compiled := _pipeline_delta
	if compiled != Vector4i.ZERO:
		evidence.append({part = "pipeline_compilation", count = compiled.x + compiled.y + compiled.z + compiled.w})
	if _gc_delta.w > 0:
		evidence.append({part = "dotnet_gc", ms = _gc_delta.w})
	var navigation_us := {}
	if game.navigation_line != null and tick_ms.get("frame_route", 0.0) > 0.0:
		navigation_us = game.navigation_line.timings_us.duplicate()
	return {
		t_s = _seconds(began_us), ms = ms, fps = 1000.0 / ms, hitch = hitch, hitch_limit_ms = limit,
		mode = _mode, context = _context, camera = game.performance_camera(), evidence = evidence,
		tick_ms = tick_ms, physics_ticks = _tick_delta.get("ticks", 0), stream_ms = stream_ms,
		vegetation_ms = vegetation_ms, render = _render.duplicate(), chunks = _chunk_delta.duplicate(),
		pipelines = _pipeline_data(compiled), dotnet_gc = _gc_data(_gc_delta), navigation_us = navigation_us,
	}


func _add_largest(evidence: Array[Dictionary], parts: Dictionary, prefix: String) -> void:
	var biggest := ""
	var ms := 0.0
	for part: String in parts:
		if parts[part] > ms:
			biggest = part
			ms = parts[part]
	if ms >= 0.5:
		evidence.append({part = prefix + biggest, ms = ms})


func _new_window() -> Dictionary:
	return {start_us = _last_us, frames = 0, hitches = 0, over = Vector3i.ZERO, sum_ms = 0.0,
		min_ms = INF, max_ms = 0.0, peak = {}, monitors = {}, work = {}, chunks = {},
		pipelines = Vector4i.ZERO, gc = Vector4i.ZERO}


func _flush_window() -> void:
	if _window.frames == 0:
		return
	var n: int = _window.frames
	var averages := {}
	for key: String in _render:
		var samples: Vector2 = _window.monitors.get(key, Vector2.ZERO)
		averages[key] = samples.x / samples.y if samples.y > 0.0 else null
	var work := {}
	for key: String in _window.work:
		var current: Vector2i = _window.work[key]
		var total: Vector2 = _work_totals.get(key, Vector2.ZERO)
		_work_totals[key] = Vector2(total.x + current.x, maxf(total.y, current.y))
		work[key] = {avg_ms = current.x / (1000.0 * n), peak_ms = current.y / 1000.0}
	_timeline.append({
		from_s = _seconds(_window.start_us), to_s = _seconds(_last_us),
		mode = _mode, context = _context, frames = n, frame_ms_total = _window.sum_ms,
		fps = 1000.0 * n / _window.sum_ms, min_fps = 1000.0 / _window.max_ms, max_fps = 1000.0 / _window.min_ms,
		worst_ms = _window.max_ms, hitches = _window.hitches, peak = _window.peak,
		over_16_7_ms = _window.over.x, over_33_3_ms = _window.over.y, over_100_ms = _window.over.z,
		render_avg = averages, work = work, chunks = _window.chunks, pipelines = _pipeline_data(_window.pipelines),
		dotnet_gc = _gc_data(_window.gc),
	})
	_window = _new_window()


func _summary() -> Dictionary:
	var n := _frames.size()
	var out := {frames = n, fps = null, min_fps = null, max_fps = null, ms = {}, low1_fps = null, low01_fps = null,
		hitches = _hitch_count, over_16_7_ms = _over.x, over_33_3_ms = _over.y, over_100_ms = _over.z,
		missed_refresh = _missed_refresh}
	if n == 0:
		return out
	_frames.sort()
	out.fps = 1000.0 * n / _sum_ms
	out.min_fps = 1000.0 / _frames[-1]
	out.max_fps = 1000.0 / _frames[0]
	out.low1_fps = FrameStatistics.tail_fps(_frames, 100)
	if n >= 1000:
		out.low01_fps = FrameStatistics.tail_fps(_frames, 1000)
	out.ms = {min = _frames[0], avg = _sum_ms / n, max = _frames[-1]}
	for percentile: int in [50, 95, 99]:
		out.ms["p%d" % percentile] = FrameStatistics.percentile(_frames, percentile / 100.0)
	return out


func finish(reason: String, save_began_us: int, save_ended_us: int) -> Dictionary:
	_flush_window()
	if _graphical:
		RenderingServer.viewport_set_measure_render_time(_viewport, false)
	_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.t_s < b.t_s)
	var report := {
		format = 1, seed = _seed, started_at = _started_at,
		ended_at = Time.get_datetime_string_from_system(false, true), ended_by = reason,
		duration_s = _seconds(save_began_us), world_save_ms = (save_ended_us - save_began_us) / 1000.0,
		machine = _machine, world_load = _loading, summary = _summary(), peaks = _peaks,
		sampling = {avg_ms = _sampling_us / (1000.0 * maxi(1, _frames.size())), peak_ms = _sampling_peak_us / 1000.0},
		pipelines = _pipeline_data(_pipeline_totals), dotnet_gc = _gc_data(_gc_totals), timeline = _timeline,
		events = _events, long_frames = _long_frames, worst_frames = _worst, work = {},
	}
	for part: String in _work_totals:
		var value: Vector2 = _work_totals[part]
		report.work[part] = {avg_ms = value.x / (1000.0 * maxi(1, _frames.size())), peak_ms = value.y / 1000.0}
	report.context_groups = Report.groups(_timeline)
	var stamp := _started_at.replace(":", "-").replace(" ", "_")
	var path := dir.path_join("%s_%d_%d" % [stamp, _serial, _start_us])
	var json_error := CacheFile.replace(path + ".json", JSON.stringify(report, "", false).to_utf8_buffer())
	var markdown_error := CacheFile.replace(path + ".md", Report.markdown(report).to_utf8_buffer())
	return {path = path, json_error = json_error, markdown_error = markdown_error}


func _seconds(us: int) -> float:
	return (us - _start_us) / 1000000.0


static func _pipeline_data(counts: Vector4i) -> Dictionary:
	return {mesh = counts.x, surface = counts.y, draw = counts.z, canvas = counts.w}


func _gc_data(counts: Vector4i) -> Variant:
	return {gen0 = counts.x, gen1 = counts.y, gen2 = counts.z, pause_ms = counts.w} if _gc_probe != null else null
