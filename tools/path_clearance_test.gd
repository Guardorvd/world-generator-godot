extends SceneTree
## Isolated clearance contracts, no world generation or saved fixtures.
var failures := 0

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 20)
	var fast := Grid.fast_grid()
	check(fast != null, "native backend available")
	if fast == null:
		quit(1)
		return
	var starts := PackedInt32Array([0, 2])
	var xs := PackedFloat64Array([4.5, 8.5])
	var ys := PackedFloat64Array([4.5, 4.5])
	var widths := PackedFloat64Array([0.25, 2.5])
	var margins := PackedFloat64Array([0.45])
	var field: PackedFloat32Array = fast.PathClearance(16, 16, starts, xs, ys, widths, margins, 4.0, 12.0)
	var allowed := Grid.allow_fast
	Grid.allow_fast = false
	var reference := Grid.path_clearance(16, 16, starts, xs, ys, widths, margins, 4.0, 12.0)
	Grid.allow_fast = allowed
	check(field == reference, "variable width native/reference byte parity")
	xs.reverse()
	ys.reverse()
	widths.reverse()
	check(field == fast.PathClearance(16, 16, starts, xs, ys, widths, margins, 4.0, 12.0), "clearance independent of route direction")
	var excess := 0.0
	for j in 49:
		for i in 49:
			var x := 2.0 + i * 0.2
			var y := 1.0 + j * 0.2
			# RoadRefinement uses the average width of the segment; no trunk may
			# be admitted by a lower estimate larger than that physical clearance.
			var distance := Vector2(x - clampf(x, 4.5, 8.5), y - 4.5).length() * 4.0
			var actual := distance - (0.25 + 2.5) * 4.0 * 0.25 - margins[0]
			excess = maxf(excess, Grid.clearance_at(field, 0, 0, 16, x, y) - actual)
	check(excess < 0.00001, "safe off-centre sampling across width transitions")
	check(Grid.clearance_at(field, 0, 0, 16, 4.5, 5.0) < 0.0, "narrow endpoint cannot admit a trunk into the averaged tread")
	# A translated field must keep exactly the same local sampling convention.
	check(Grid.clearance_at(field, -20, 30, 16, -15.5, 35.0) == Grid.clearance_at(field, 0, 0, 16, 4.5, 5.0), "regional origin sampling")
	print("PATH CLEARANCE RESULT ", failures, " failures")
	quit(1 if failures else 0)
