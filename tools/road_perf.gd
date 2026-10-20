extends SceneTree
## Точное сравнение исходного и пакетного выбора сегмента на одном дорожном рельефе.
## godot --headless --path . --script res://tools/road_perf.gd -- [сид] [размер] [старый скрипт]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var seed_text := args[0] if args.size() > 0 else "Север-1234"
	var size := int(args[1]) if args.size() > 1 else 256
	if Grid.fast_grid() == null:
		printerr("Требуется собранный C#-модуль")
		quit(1)
		return
	var w := WorldGenerator.generate(seed_text, size)
	var h := Heightfield.new(w, false)
	RoadBed.refine(h)
	h.build_structures()
	RoadRefinement.allow_fast_nearest = false
	var baseline: Script = load(args[2]) if args.size() > 2 else null
	if args.size() > 2 and (baseline == null or not baseline.can_instantiate()):
		printerr("Не удалось загрузить исходный скрипт")
		quit(1)
		return
	var started := Time.get_ticks_usec()
	var before: Variant = baseline.build(h) if baseline != null else RoadRefinement.build(h)
	var before_ms := (Time.get_ticks_usec() - started) / 1000.0
	RoadRefinement.allow_fast_nearest = true
	started = Time.get_ticks_usec()
	var after := RoadRefinement.build(h)
	var after_ms := (Time.get_ticks_usec() - started) / 1000.0
	var same: bool = before.patches == after.patches and before.fit_routes == after.fit_routes
	# В 5.3+ внутренние нормали берутся прямо из p.h. Сверяем со старой выборкой
	# через Heightfield, а не только сравниваем данные двух вариантов RoadRefinement.
	h.road_refinement = after
	var normals_same := true
	var normal_count := 0
	var normal_mismatches := 0
	var arrays := TerrainBuilder.build_arrays(w, h)
	TerrainBuilder.refine_arrays(arrays, w, h)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in range(w.N, vertices.size()):
		var point := vertices[i]
		var sampled := TerrainBuilder._local_normal(h, point.x, point.z)
		if normals[i] != sampled:
			normals_same = false
			normal_mismatches += 1
			if normal_mismatches <= 2:
				print("NORMAL ", {point = point, actual = normals[i], expected = sampled})
		normal_count += 1
	if not same:
		var shown := 0
		for key: int in before.patches:
			if before.patches[key] != after.patches.get(key):
				printerr("Патч ", key)
				var actual: Dictionary = after.patches.get(key, {})
				for field: String in before.patches[key]:
					if before.patches[key][field] != actual.get(field):
						printerr("  отличается ", field)
				shown += 1
				if shown >= 5:
					break
	print(JSON.stringify({seed = seed_text, size = size, same = same, normals_same = normals_same, normal_count = normal_count, normal_mismatches = normal_mismatches,
		before_ms = before_ms, after_ms = after_ms,
		before = before.get("build_timings"), after = after.build_timings}))
	quit(0 if same and normals_same else 1)
