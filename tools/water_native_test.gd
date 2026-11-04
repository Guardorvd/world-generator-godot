extends SceneTree
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()
func run() -> void:
	Heightfield.allow_fast_water_levels = false
	var w := WorldGenerator._geography("Север-1234", 192)
	var started := Time.get_ticks_usec()
	var before := Heightfield.new(w, false)
	var before_ms := (Time.get_ticks_usec() - started) / 1000.0
	Heightfield.allow_fast_water_levels = true
	started = Time.get_ticks_usec()
	var after := Heightfield.new(w, false)
	var after_ms := (Time.get_ticks_usec() - started) / 1000.0
	for field: String in ["hv", "hv_raw", "ribbons", "water_level", "_seg_pts", "_pair_cells", "_pair_segs"]:
		var same: bool = before.get(field) == after.get(field)
		print("PASS " if same else "FAIL ", field)
		failures += int(not same)
	print("water_native: ", failures, " failures, rivers=", before.ribbons.size(), " before_ms=", before_ms, " after_ms=", after_ms,
		" before=", before.path_timings, " after=", after.path_timings)
	quit(1 if failures else 0)
