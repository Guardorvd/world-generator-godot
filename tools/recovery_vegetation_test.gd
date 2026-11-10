extends SceneTree
const Snapshots := preload("res://scripts/render/vegetation_snapshots.gd")
var fails := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 45)
	for colors: bool in [false, true]:
		var source := PackedFloat32Array()
		source.resize(2048 * (16 if colors else 12))
		for i in source.size(): source[i] = i * 0.03125
		Grid.allow_fast = false
		var started := Time.get_ticks_usec()
		var reference := VegetationLayer._tree_buffer(source, colors, 3.25)
		var reference_us := Time.get_ticks_usec() - started
		Grid.allow_fast = true
		check(Grid.fast_grid() != null, "native backend available")
		VegetationLayer._tree_buffer(source, colors, 3.25) # warm up the interop/JIT
		started = Time.get_ticks_usec()
		var actual := VegetationLayer._tree_buffer(source, colors, 3.25)
		var native_us := Time.get_ticks_usec() - started
		check(actual == reference, "tree expansion preserves every float, custom data and stamp (colors=%s)" % colors)
		print("TREE_PACK rows=2048 colors=", colors, " gdscript_us=", reference_us, " native_us=", native_us)
	var snapshots := Snapshots.new()
	var rows := PackedFloat32Array()
	rows.resize(60)
	for i in 3:
		VegetationLayer._put_xform(rows, i * 20, i * 10, 0, 0, 0, 1, 1)
	snapshots.merge(-1, rows, 3, AABB(), 1.0, 2.0)
	var before: PackedFloat32Array = snapshots.displayed[-1].duplicate()
	snapshots.exclude_rect(Rect2(9, -1, 2, 2))
	var frame := snapshots.merge(-1, rows.slice(0, 20), 1, AABB(), 1.0, 2.25)
	check(frame.count == 2, "region replacement never resurrects removed plants as outgoing history")
	for at in range(0, frame.count * 20, 20):
		var x: float = frame.buffer[at + 3]
		var old_stamp: float = before[(0 if x == 0 else 2) * 20 + 19]
		check(absf(Snapshots.opacity(frame.buffer[at + 19], 2.25) - Snapshots.opacity(old_stamp, 2.25)) < 0.00001, "region replacement preserves opacity outside its rectangle")
	print("recovery_vegetation_test: ", fails, " failures")
	quit(1 if fails else 0)
func check(ok: bool, label: String) -> void:
	print("OK " if ok else "FAIL ", label)
	fails += int(not ok)
