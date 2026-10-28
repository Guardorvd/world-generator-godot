extends SceneTree
## Нагрузка на подгрузку: растительность и край карты одновременно, без управления игроком.
## godot --path . --script res://tools/streaming_perf.gd -- [файл.json]
## Здесь нет камеры: это нагрузка на CPU и передачу буферов, не замер FPS отрисованной игры.
## Обычную игру измеряет tools/control/perf.gd.

const Dev := preload("res://tools/control/control.gd")
var veg: VegetationLayer
var outer: OuterTerrain
var world: WorldData
var frame_ms := PackedFloat32Array()
var submit_ms := PackedFloat32Array()
var steady_frame_ms := PackedFloat32Array()
var steady_submit_ms := PackedFloat32Array()
var last_us := 0
var started := 0
var ticks := 0
var ready := false
var settling_at := 0
var route_result := {}


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	call_deferred("_setup")


func _setup() -> void:
	Engine.max_fps = 120
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var loaded := WorldLoader.load_world("Север-1234", 512)
	world = loaded.world
	veg = VegetationLayer.new()
	root.add_child(veg)
	veg.setup(world, loaded.heights, Models.tree_defs(), Models.grass_mesh())
	outer = OuterTerrain.new()
	root.add_child(outer)
	outer.setup(world, loaded.heights)
	var bytes := veg.grass_buf.size() * 4
	for e: Dictionary in veg.veg.values():
		if e.has("tbuf"):
			bytes += e.tbuf.size() * 4
		if e.has("cbuf"):
			bytes += e.cbuf.size() * 4
	print("Буферы растительности: %d байт" % bytes)
	started = Time.get_ticks_msec()
	last_us = Time.get_ticks_usec()
	ready = true


func _process(_delta: float) -> bool:
	if not ready:
		return false
	if settling_at != 0:
		var uploaded := veg.update((world.W - 20) * GameConfig.TILE, (20 + 99 * 8) * GameConfig.TILE, false)
		outer.update((world.W - 20) * GameConfig.TILE, (20 + 99 * 8) * GameConfig.TILE, not uploaded)
		var settled := outer._tasks.is_empty() and outer._queue.is_empty() and veg._task == -1 and veg._pending.is_empty()
		if not settled and Time.get_ticks_msec() - settling_at < 10000:
			return false
		route_result.settle_ms = Time.get_ticks_msec() - settling_at
		route_result.settled = settled
		route_result.chunks_after_settle = outer._nodes.size()
		_finish(settled)
		return false
	var now := Time.get_ticks_usec()
	if ticks > 0:
		frame_ms.append((now - last_us) / 1000.0)
		if ticks >= 120:
			steady_frame_ms.append((now - last_us) / 1000.0)
	last_us = now
	# Фиксированный маршрут: ровно 32 м за 12 кадров, потом вдоль края на юг.
	var step := ticks / 12
	var x := (world.W - 20) * GameConfig.TILE
	var z := (20 + step * 8) * GameConfig.TILE
	var t0 := Time.get_ticks_usec()
	var uploaded := veg.update(x, z, false)
	outer.update(x, z, not uploaded)
	submit_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
	if ticks >= 120:
		steady_submit_ms.append(submit_ms[-1])
	ticks += 1
	if ticks < 1200:
		return false
	route_result = {version = Dev.version(), headless = DisplayServer.get_name() == "headless",
		elapsed_s = (Time.get_ticks_msec() - started) / 1000.0,
		frames = _stats(frame_ms), submit = _stats(submit_ms), chunks = outer._nodes.size(),
		steady_frames = _stats(steady_frame_ms), steady_submit = _stats(steady_submit_ms)}
	settling_at = Time.get_ticks_msec()
	return false


func _finish(ok: bool) -> void:
	print(JSON.stringify(route_result))
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		Dev.save_json(args[0], route_result)
	root.remove_child(veg)
	veg.free()
	root.remove_child(outer)
	outer.free()
	quit(0 if ok else 1)


func _stats(samples: PackedFloat32Array) -> Dictionary:
	var sorted := samples.duplicate()
	sorted.sort()
	return {p50_ms = sorted[int(sorted.size() * 0.5)], p99_ms = sorted[int(sorted.size() * 0.99)],
		max_ms = sorted[-1], samples = sorted.size()}
