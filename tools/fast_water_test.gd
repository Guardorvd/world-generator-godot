extends SceneTree
var fails := 0

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	fails += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 45)
	var probe: Object = load("res://tools/WaterInputProbe.cs").new()
	for result: String in probe.InvalidCases():
		print(result)
		fails += int(not result.begins_with("PASS "))
	var w := WorldData.new()
	w.W = 12; w.H = 10; w.N = 120
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var value: Variant = owner.get(property.name)
			if value is GridBuffer2D.Float32 or value is GridBuffer2D.Byte or value is GridBuffer2D.Int32: value.resize()
	w.dist_water.fill(100)
	for i in w.N:
		w.h[i] = 0.1 + (i % w.W) * 0.001
		w.filled[i] = 0.12
		if i % w.W in [4, 5] and i / w.W in [4, 5]: w.lake[i] = 1
	var h := Heightfield.new(w, false)
	h.ribbons = [[{left = Vector3(28, 32, 8), right = Vector3(36, 31.5, 8)},
		{left = Vector3(28, 30, 28), right = Vector3(36, 29.5, 28)}]]
	h.index_ribbons()
	var native := h.fast_water()
	check(native != null and native.WaterReady(), "GDScript configures a complete native water snapshot")
	if native == null: quit(1); return
	var expected := PackedInt32Array()
	for i in w.N:
		var deep := false
		for dz in [-0.4, 0.0, 0.4]:
			for dx in [-0.4, 0.0, 0.4]:
				deep = deep or h.depth_at((i % w.W + 0.5 + dx) * 4, (i / w.W + 0.5 + dz) * 4) > 0.3
		if deep: expected.append(i)
	var all := PackedInt32Array()
	for i in w.N: all.append(i)
	check(native.DeepFords(all, 0.3) == expected, "native ford samples match GDScript rivers, lakes and triangle heights")
	var same := true
	for y in range(2, 8):
		for x in range(2, 10):
			var a := {x = float(x), y = float(y), w = 0.9}
			var b := {x = float(x + 1), y = float(y + 1), w = 0.9}
			same = same and StageTrails._road_segment(h, a, b, 0.35, 0.8) == native.RoadSegment(a.x, a.y, b.x, b.y, a.w, 0.35, 0.8)
	check(same, "native road grade, cross slope and depth decisions match GDScript")
	var replacement := h.hv.duplicate()
	replacement.fill(80)
	check(native.SetGround(replacement) and native.DeepFords(all, 0.3).is_empty(), "valid ground replacement changes depths without a stale terrain cache")
	check(not native.SetGround(PackedFloat32Array()) and not native.WaterReady(), "GDScript receives explicit rejection of incomplete ground")
	check(not native.RoadSegment(2, 2, 3, 3, 1, 1, 1), "incomplete state cannot approve a road")
	print("FAST WATER RESULT ", fails, " failures")
	quit(1 if fails else 0)
