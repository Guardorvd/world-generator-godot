extends SceneTree
## Проверка и микрозамер оптимизаций 5.0. Без GPU: не является замером FPS.
## godot --headless --path . --script res://tools/audit_perf.gd -- [сид] [размер]

var failed := false


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	var args := OS.get_cmdline_user_args()
	var seed_text := args[0] if args.size() > 0 else "Север-1234"
	var size := int(args[1]) if args.size() > 1 else 256
	var loaded := WorldLoader.load_world(seed_text, size)
	print("LOAD ", JSON.stringify(loaded.timings))
	print("MESH vertices=%d triangles=%d patches=%d" % [
		loaded.terrain_arrays[Mesh.ARRAY_VERTEX].size(),
		loaded.terrain_arrays[Mesh.ARRAY_INDEX].size() / 3,
		loaded.heights.road_refinement.patches.size()])
	# Раздельная заливка должна давать те же байты, а не только похожие картинки.
	for px in [2, 4]:
		var both_ms: Array[float] = []
		var flat_ms: Array[float] = []
		var shaded_ms: Array[float] = []
		for repeat in 3:
			var t := Time.get_ticks_usec()
			var both := MapBaker.paint(loaded.world, px)
			both_ms.append((Time.get_ticks_usec() - t) / 1000.0)
			t = Time.get_ticks_usec()
			var flat := MapBaker.paint(loaded.world, px, true, false)
			flat_ms.append((Time.get_ticks_usec() - t) / 1000.0)
			t = Time.get_ticks_usec()
			var shaded := MapBaker.paint(loaded.world, px, false, true)
			shaded_ms.append((Time.get_ticks_usec() - t) / 1000.0)
			_check(flat[0] == both[0] and flat[1].is_empty(), "flat px=%d run=%d" % [px, repeat])
			_check(shaded[1] == both[1] and shaded[0].is_empty(), "shaded px=%d run=%d" % [px, repeat])
		print("PAINT px=%d both_ms=%s flat_ms=%s shaded_ms=%s bytes_saved_per_variant=%d" % [
			px, both_ms, flat_ms, shaded_ms, size * size * px * px * 3])
	var ref := loaded.heights.road_refinement
	var points := PackedVector2Array()
	# Середины обеих половин треугольника, края патчей, промежутки и выход за карту.
	for key: int in ref.patches:
		var origin := Vector2(key % size + 0.5, key / size + 0.5) * GameConfig.TILE
		for offset: Vector2 in [Vector2.ZERO, Vector2(0.2, 0.3), Vector2(0.9, 0.8), Vector2(3.99, 3.99)]:
			points.append(origin + offset)
	for z in range(-1, size + 2, 3):
		for x in range(-1, size + 2, 3):
			points.append(Vector2(x, z) * GameConfig.TILE)
	for point in points:
		var contact := ref.sample(point.x, point.y, size)
		var expected: float = contact.get("weight", 0.0)
		if ref.weight_at(point.x, point.y, size) != expected:
			_check(false, "weight at %s" % point)
	var checksum := 0.0
	var old_ms: Array[float] = []
	var new_ms: Array[float] = []
	for repeat in 5:
		var t := Time.get_ticks_usec()
		for point in points:
			checksum += float(ref.sample(point.x, point.y, size).get("weight", 0.0))
		old_ms.append((Time.get_ticks_usec() - t) / 1000.0)
		t = Time.get_ticks_usec()
		for point in points:
			checksum += ref.weight_at(point.x, point.y, size)
		new_ms.append((Time.get_ticks_usec() - t) / 1000.0)
	print("WEIGHT points=%d sample_ms=%s weight_ms=%s checksum=%f" % [points.size(), old_ms, new_ms, checksum])
	print("AUDIT ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)


func _check(ok: bool, label: String) -> void:
	if not ok:
		failed = true
		printerr("FAIL: ", label)
