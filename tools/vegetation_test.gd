extends SceneTree
## Густой лес: без лимита на вид, точные AABB, LOD, повторное использование и переносы.

var fails := 0


static func fixture(copies: int = 8) -> WorldData:
	var w := WorldData.new()
	w.W = 256
	w.H = 256
	w.N = w.W * w.H
	w.CS = WorldData.CHUNK_SIZE
	w.CW = w.W / w.CS
	w.CH = w.H / w.CS
	for key in ["h", "filled", "elev", "temp", "moist", "slope", "dist_water"]:
		var a := PackedFloat32Array()
		a.resize(w.N)
		a.fill(0.1 if key == "h" or key == "filled" or key == "elev" else (0.6 if key == "temp" or key == "moist" else 0.0))
		w.set(key, a)
	for key in ["biome", "ocean", "lake", "river", "path_mask"]:
		var a := PackedByteArray()
		a.resize(w.N)
		# Без травы: стресс именно на деревья и их загрузку.
		if key == "biome":
			a.fill(Biomes.ROCK)
		w.set(key, a)
	for c in w.CW * w.CH:
		w.chunks.append(PackedInt32Array())
	for y in range(96, 160):
		for x in range(96, 160):
			for n in copies:
				var o := w.obj_x.size()
				w.obj_x.append(x + 0.15 + (n % 4) * 0.2)
				w.obj_y.append(y + 0.2 + (n / 4) * 0.2)
				w.obj_k.append(Biomes.T_PINE)
				w.obj_v.append(n % 3)
				w.obj_s.append(0.5 + (n % 4) * 0.3)
				w.chunks[(y / w.CS) * w.CW + x / w.CS].append(o)
	w.obj_count = w.obj_x.size()
	return w


func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var w := fixture()
	var h := Heightfield.new(w, false)
	var defs := Models.tree_defs()
	var pine: ArrayMesh = defs[Biomes.T_PINE].crown
	var lods := ForestModels.lod_meshes(pine)
	check(lods.size() == 3 and lods[0] == pine, "Кроны хранят три отдельных LOD без дублирования")
	var fine: PackedInt32Array = pine.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	for level in range(1, lods.size()):
		var count: int = lods[level].surface_get_arrays(0)[Mesh.ARRAY_INDEX].size()
		check(count < fine.size() and count % 3 == 0, "LOD должен сокращать треугольники")
	var veg := VegetationLayer.new()
	root.add_child(veg)
	veg.setup(w, h, defs, Models.grass_mesh())
	# Загрузка ограничена группой силуэтов; отмена освобождает уже переданную часть чанка.
	var chunk := Vector2i(6, 6)
	var partial := veg._build_chunk(chunk)
	partial.epoch = veg._epoch
	check(partial.entries.size() == ForestModels.VARIANTS, "Фикстура содержит все силуэты в одном чанке")
	check(not veg._apply_chunk(partial, 1) and veg.veg.size() == 1, "За порцию загружается только один силуэт")
	veg._pending.append(partial)
	veg._upload_next()
	check(veg.veg.size() == 2 and partial.cursor in [1, 2] and veg._pending.size() == 1, "Следующий кадр продолжает тот же чанк в пределах бюджета")
	veg._clear_pending()
	check(veg.veg.is_empty() and not veg._loaded.has(chunk), "Отмена не оставляет частичный чанк готовым")
	partial = veg._build_chunk(chunk)
	check(not veg._apply_chunk(partial, 1, 1) and partial.cursor == 0 and partial.node_cursor == 1,
		"Исчерпанный бюджет передаёт один узел и сохраняет позицию внутри группы")
	var partial_key := Vector3i(chunk.x, chunk.y, partial.entries[0].kind)
	var first_node: Node = veg.veg[partial_key].nodes[0]
	while partial.cursor == 0:
		veg._apply_chunk(partial, 1, 1)
	check(veg.veg[partial_key].nodes.size() == 6 and veg.veg[partial_key].nodes[0] == first_node,
		"Продолжение достраивает все LOD ствола и кроны без дублирования")
	veg._discard_partial(partial)
	partial = veg._build_chunk(chunk)
	veg._apply_chunk(partial, 1, 1)
	veg._discard_partial(partial)
	check(veg.veg.is_empty() and not veg._loaded.has(chunk), "Отмена первой незавершённой группы освобождает её узлы")
	partial = veg._build_chunk(chunk)
	partial.epoch = veg._epoch
	veg._apply_chunk(partial, 1)
	veg._dirty[chunk] = veg._epoch + 1
	check(veg._apply_chunk(partial, 1) and veg.veg.is_empty(), "Устаревший частичный чанк удаляется при закреплении области")
	veg._dirty.clear()
	await process_frame
	partial = veg._build_chunk(chunk)
	veg._apply_chunk(partial, 1)
	veg._pending.append(partial)
	veg.update(512.0, 512.0, true)
	check(veg._pending.is_empty(), "Синхронный перенос отменяет частичную передачу перед полной загрузкой")
	var total := 0
	var max_batch := 0
	for entry: Dictionary in veg.veg.values():
		total += entry.count
		max_batch = maxi(max_batch, entry.count)
	check(total == w.obj_count and total > 24000, "Густой лес не должен обрезаться общим лимитом вида")
	check(max_batch <= 2048 and veg.veg.size() == 16 * ForestModels.VARIANTS, "Лес должен делиться по чанкам и вариантам силуэта")
	var key: Vector3i = veg.veg.keys()[0]
	var original: MultiMesh = veg.veg[key].crown
	veg.update(536.0, 512.0, true)
	check(veg.veg[key].crown == original, "Соседний шаг должен сохранять уже загруженный MultiMesh")
	for entry: Dictionary in veg.veg.values():
		for node: MultiMeshInstance3D in entry.nodes:
			if node.multimesh.use_colors:
				check(node.multimesh.mesh in ForestModels.lod_meshes(defs[entry.kind].crown), "Узлы крон используют общие LOD-меши")
		for part in ["trunk", "crown"]:
			var mm: MultiMesh = entry[part]
			var buf: PackedFloat32Array = mm.buffer
			var stride := 16 if mm.use_colors else 12
			for n in entry.count:
				var o: int = n * stride
				var xf := Transform3D(Basis(Vector3(buf[o], buf[o + 4], buf[o + 8]), Vector3(buf[o + 1], buf[o + 5], buf[o + 9]), Vector3(buf[o + 2], buf[o + 6], buf[o + 10])), Vector3(buf[o + 3], buf[o + 7], buf[o + 11]))
				check(mm.custom_aabb.grow(0.01).encloses(xf * mm.mesh.get_aabb()), "AABB должен включать повёрнутую и масштабированную модель")
	veg.update(1200.0, 1200.0, false)
	veg.update(512.0, 512.0, true)
	check(veg._pending.is_empty() and veg._task == -1, "Force должен отменять результаты прежнего положения")
	veg.update(5000.0, 5000.0, true)
	check(veg.veg.is_empty() and veg._loaded.is_empty(), "Дальние чанки должны выгружаться")
	veg.update(512.0, 512.0, false)
	await wait_task(veg)
	veg.update(512.0, 512.0, false)
	var waiting := veg._pending.size()
	check(waiting > 0, "Готовые чанки должны ожидать передачи")
	veg.update(536.0, 512.0, false)
	var kept := veg._pending.size()
	var queued_chunks: Array = veg._pending.map(func(b: Dictionary) -> Vector2i: return b.chunk)
	check(veg._task != -1 and kept > 0, "Очередь деревьев не должна задерживать обновление травы")
	await wait_task(veg)
	veg.update(536.0, 512.0, false)
	for queued_chunk: Vector2i in queued_chunks:
		check(veg._pending.any(func(b: Dictionary) -> bool: return b.chunk == queued_chunk) or veg._loaded.has(queued_chunk), "Независимая задача травы не должна терять готовые чанки")
	veg.update(5000.0, 5000.0, false)
	check(veg.veg.is_empty() and veg._pending.is_empty(), "Результаты прежнего положения не должны появляться после переноса")
	veg.update(512.0, 512.0, true)
	veg.update(540.0, 512.0, false)
	veg.queue_free()
	await process_frame
	print("vegetation_test: %d ошибок; %d деревьев, чанк <= %d; LOD %d" % [fails, total, max_batch, lods.size()])
	quit(1 if fails else 0)


func wait_task(veg: VegetationLayer) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while (veg._task != -1 and not WorkerThreadPool.is_task_completed(veg._task)) or (veg._tree_task != -1 and not WorkerThreadPool.is_task_completed(veg._tree_task)):
		if Time.get_ticks_msec() > deadline:
			check(false, "Таймаут фоновой подготовки густого леса")
			return
		await process_frame
