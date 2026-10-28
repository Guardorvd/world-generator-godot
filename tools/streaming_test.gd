extends SceneTree
## Передача результатов по кадрам, принудительное заполнение и выгрузка при незаконченной задаче.

class TrackedVegetation extends VegetationLayer:
	var uploads := 0
	func _apply_chunk(built: Dictionary) -> void:
		uploads += 1
		super._apply_chunk(built)

var fails := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	call_deferred("_run")


func _run() -> void:
	Engine.max_fps = 120
	var nodes_before := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var loaded := WorldLoader.load_world("Север-1234", 256)
	_check(Performance.get_monitor(Performance.OBJECT_NODE_COUNT) == nodes_before, "фоновый загрузчик не создаёт узлы")
	_check(loaded.world._fields.is_empty() and loaded.world._fields_thread == null, "временные поля генерации освобождены")
	_check(loaded.terrain_arrays.size() == Mesh.ARRAY_MAX and loaded.water_arrays.size() == 2, "загрузчик возвращает массивы геометрии")
	_check_patch(loaded)
	var veg := TrackedVegetation.new()
	root.add_child(veg)
	veg.setup(loaded.world, loaded.heights, Models.tree_defs(), Models.grass_mesh())
	veg.update(500.0, 500.0, true)
	veg.update(700.0, 500.0, false)
	if await _wait_vegetation(veg):
		veg.update(700.0, 500.0, false)
		_check(veg._task == -1 and not veg._pending.is_empty(), "трава передана, деревья ожидают")
		while not veg._pending.is_empty():
			var before := veg.uploads
			veg.update(700.0, 500.0, false)
			_check(veg.uploads - before == 1 and veg._task == -1, "один чанк за кадр, буферы не перезаписываются")
		_check_buffers(veg)
	# Force дожидается старого расчёта и показывает только новое положение.
	veg.update(580.0, 500.0, false)
	veg.update(800.0, 500.0, true)
	_check(veg._task == -1 and veg._pending.is_empty(), "force во время расчёта")
	_check_buffers(veg)
	veg.update(840.0, 500.0, false)
	if await _wait_vegetation(veg):
		veg.update(840.0, 500.0, false)
		veg.update(400.0, 400.0, true)
		_check(veg._pending.is_empty(), "force во время передачи")
		_check_buffers(veg)
	var outer := OuterTerrain.new()
	root.add_child(outer)
	outer.setup(loaded.world, loaded.heights)
	_check_geometry(outer)
	outer.update(0.0, 0.0, false)
	var deadline := Time.get_ticks_msec() + 10000
	var complete := false
	while not complete and Time.get_ticks_msec() < deadline:
		complete = true
		for t: Dictionary in outer._tasks.values():
			complete = complete and WorkerThreadPool.is_task_completed(t.id)
		await process_frame
	_check(complete and not outer._tasks.is_empty(), "фоновые куски готовы")
	outer.update(0.0, 0.0, false)
	_check(outer.land.chunks.is_empty(), "кадр занят растительностью: куски ожидают")
	outer.update(0.0, 0.0)
	_check(outer.land.chunks.size() == 1, "не более одного куска за кадр")
	outer.update(100000.0, 100000.0)
	_check(outer.land.chunks.is_empty(), "устаревшие результаты не попадают в игру после переноса")
	# _exit_tree обязан дождаться задач, которые держат ссылки на эти узлы.
	veg.update(440.0, 400.0, false)
	veg.queue_free()
	outer.queue_free()
	await process_frame
	print("streaming_test: %d ошибок" % fails)
	quit(0 if fails == 0 else 1)


func _wait_vegetation(veg: VegetationLayer) -> bool:
	var deadline := Time.get_ticks_msec() + 10000
	while veg._task != -1 and not WorkerThreadPool.is_task_completed(veg._task):
		if Time.get_ticks_msec() > deadline:
			_check(false, "таймаут растительности")
			return false
		await process_frame
	return true


func _check_buffers(veg: VegetationLayer) -> void:
	_check(veg.grass.buffer == veg.grass_buf and veg.grass.visible_instance_count == veg._grass_n, "буфер и число пучков травы")
	_check_bounds(veg.grass)
	for k in veg.veg:
		var e: Dictionary = veg.veg[k]
		for part: String in ["trunk", "crown"]:
			if e.has(part):
				var buf: PackedFloat32Array = e.tbuf if part == "trunk" else e.cbuf
				_check(e[part].buffer == buf and e[part].visible_instance_count == e.count, "буфер и число деревьев %s %s" % [str(k), part])
				_check_bounds(e[part])


func _check_bounds(mm: MultiMesh) -> void:
	var bounds := mm.custom_aabb.grow(0.01)
	var buf := mm.buffer
	var stride := 16 if mm.use_colors else 12
	for i in mm.visible_instance_count:
		# Проверяем переданные числа без чтения отдельных трансформов через RenderingServer.
		var o := i * stride
		var basis := Basis(Vector3(buf[o], buf[o + 4], buf[o + 8]), Vector3(buf[o + 1], buf[o + 5], buf[o + 9]), Vector3(buf[o + 2], buf[o + 6], buf[o + 10]))
		var transform := Transform3D(basis, Vector3(buf[o + 3], buf[o + 7], buf[o + 11]))
		var transformed := transform * mm.mesh.get_aabb()
		if not bounds.encloses(transformed):
			_check(false, "рамка отсечения содержит каждый отображаемый экземпляр")
			return


func _check_patch(loaded: WorldLoader) -> void:
	var original := loaded.heights.hv.duplicate()
	var changed := PackedInt32Array([0, loaded.world.N / 2 + loaded.world.W / 2, loaded.world.N - 1])
	for i in changed:
		loaded.heights.hv[i] += 1.25
	TerrainBuilder.patch(loaded.terrain_arrays, loaded.world, loaded.heights, changed)
	var rebuilt := TerrainBuilder.build_arrays(loaded.world, loaded.heights)
	_check(loaded.terrain_arrays[Mesh.ARRAY_VERTEX] == rebuilt[Mesh.ARRAY_VERTEX] and loaded.terrain_arrays[Mesh.ARRAY_NORMAL] == rebuilt[Mesh.ARRAY_NORMAL], "исправление высот и нормалей до загрузки на GPU")
	loaded.heights.hv = original
	loaded.terrain_arrays = TerrainBuilder.build_arrays(loaded.world, loaded.heights)


func _check_geometry(outer: OuterTerrain) -> void:
	var key := Vector2i(4, 2)
	var built := outer._build(key)
	var pos: PackedVector3Array = built.arrays[Mesh.ARRAY_VERTEX]
	var center := outer._center(key)
	_check(Vector2(pos[0].x + center.x, pos[0].z + center.y).is_equal_approx(Vector2(key * OuterLand.C) * GameConfig.TILE + Vector2.ONE * GameConfig.TILE * 0.5), "локальные вершины сохраняют мировые координаты")
	var fine: PackedInt32Array = built.arrays[Mesh.ARRAY_INDEX]
	_check_topology(fine, pos)
	for coarse: PackedInt32Array in built.lods.values():
		_check(coarse.size() < fine.size(), "LOD уменьшает число треугольников")
		_check_topology(coarse, pos)
	var partial := outer._build(Vector2i(3, 2))
	_check(partial.lods.is_empty() and partial.arrays[Mesh.ARRAY_INDEX].size() == OuterLand.C * 6, "край карты сохраняет точный вырез и полную детализацию")
	var neighbor := outer._build(key + Vector2i.RIGHT)
	var next_pos: PackedVector3Array = neighbor.arrays[Mesh.ARRAY_VERTEX]
	var next_nor: PackedVector3Array = neighbor.arrays[Mesh.ARRAY_NORMAL]
	var nor: PackedVector3Array = built.arrays[Mesh.ARRAY_NORMAL]
	for row in OuterLand.C + 1:
		var i := row * (OuterLand.C + 1)
		_check(is_equal_approx(pos[i + OuterLand.C].y, next_pos[i].y) and nor[i + OuterLand.C].is_equal_approx(next_nor[i]), "высоты и нормали соседних кусков совпадают")


func _check_topology(idx: PackedInt32Array, pos: PackedVector3Array) -> void:
	var edges := {}
	var area := 0.0
	for i in range(0, idx.size(), 3):
		var a := idx[i]
		var b := idx[i + 1]
		var c := idx[i + 2]
		_check(a >= 0 and b >= 0 and c >= 0 and maxi(a, maxi(b, c)) < pos.size(), "индексы в пределах буфера")
		var cross := (pos[b] - pos[a]).cross(pos[c] - pos[a]).y
		_check(cross < 0.0, "невырожденные треугольники с правильным обходом")
		area -= cross * 0.5
		for edge: Vector2i in [Vector2i(a, b), Vector2i(b, c), Vector2i(c, a)]:
			var sorted := Vector2i(mini(edge.x, edge.y), maxi(edge.x, edge.y))
			edges[sorted] = edges.get(sorted, 0) + 1
	var boundary := 0
	for edge: Vector2i in edges:
		_check(edges[edge] <= 2, "нет наложенных рёбер")
		if edges[edge] == 1:
			boundary += 1
			var a: int = edge.x
			var b: int = edge.y
			var V := OuterLand.C + 1
			_check((a / V == b / V and (a / V == 0 or a / V == V - 1) and absi(a - b) == 1) or (a % V == b % V and (a % V == 0 or a % V == V - 1) and absi(a - b) == V), "периметр с шагом в клетку, без внутренних щелей")
	_check(boundary == OuterLand.C * 4 and is_equal_approx(area, pow(OuterLand.C * GameConfig.TILE, 2)), "полная площадь и совпадающий периметр при любом LOD")


func _check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: " + label)
