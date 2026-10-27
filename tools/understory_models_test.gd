extends SceneTree
## Геометрия подлеска, ранги деталей и компактная передача буферов. Без генерации мира.
const Plants := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
var fails := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func cost(meshes: Array) -> Vector2i:
	var result := Vector2i.ZERO
	for mesh: Mesh in meshes:
		var a := mesh.surface_get_arrays(0)
		result.x += (a[Mesh.ARRAY_INDEX].size() if a[Mesh.ARRAY_INDEX] != null and not a[Mesh.ARRAY_INDEX].is_empty() else a[Mesh.ARRAY_VERTEX].size()) / 3
		for data in a:
			if data != null:
				result.y += data.to_byte_array().size()
	return result

func run() -> void:
	var plants := Plants.meshes()
	var floor_meshes := Floor.meshes()
	var all: Array = plants.duplicate()
	all.append_array(floor_meshes)
	all.append(Models.grass_mesh())
	all.append(Models.reeds(81))
	for kind in all.size():
		var a: Array = all[kind].surface_get_arrays(0)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		check(not v.is_empty() and n.size() == v.size(), "Растение содержит вершины и нормали: %d" % kind)
		for i in v.size():
			check(v[i].is_finite() and n[i].is_finite() and n[i].length_squared() > 0.9, "Конечные вершины и единичные нормали")
		for i in idx:
			check(i >= 0 and i < v.size(), "Индексы ссылаются на свои вершины")
		if a[Mesh.ARRAY_TEX_UV2] != null:
			var ranks: PackedVector2Array = a[Mesh.ARRAY_TEX_UV2]
			check(ranks.size() == v.size(), "Ранг есть у каждой вершины")
			for i in range(0, idx.size(), 3):
				check(ranks[idx[i]].x == ranks[idx[i + 1]].x and ranks[idx[i]].x == ranks[idx[i + 2]].x, "Поредение выключает целый треугольник")
			for rank in ranks:
				check(rank.x >= 0.0 and rank.x < 1.0, "Ранг поредения находится в [0,1)")
			if kind in [Plants.BUSH, Plants.SAPLING, Plants.YOUNG, Plants.PINE, Plants.YOUNG_PINE]:
				var low := Vector3.INF
				var high := -Vector3.INF
				for i in v.size():
					if ranks[i].x <= 0.5:
						low = low.min(v[i])
						high = high.max(v[i])
				var far_size := high - low
				var near_size: Vector3 = all[kind].get_aabb().size
				check(far_size.x > near_size.x * 0.65 and far_size.y > near_size.y * 0.8 and far_size.z > near_size.z * 0.65, "Поредение сохраняет высоту и основные границы кроны")
	check(var_to_bytes(plants[Plants.BUSH].surface_get_arrays(0)) == var_to_bytes(Plants.meshes()[Plants.BUSH].surface_get_arrays(0)), "Куст воспроизводится без глобального RNG")
	print("Understory triangles/array bytes: ", cost(plants))
	print("Floor triangles/array bytes: ", cost(floor_meshes))
	var args := OS.get_cmdline_user_args()
	var at := args.find("--baseline")
	if at >= 0 and at + 1 < args.size():
		var old: GDScript = load(args[at + 1] + "/understory_models.gd")
		var old_floor: GDScript = load(args[at + 1] + "/forest_floor.gd")
		var before := cost(old.meshes())
		var before_floor := cost(old_floor.meshes())
		print("Baseline understory triangles/array bytes: ", before)
		print("Baseline floor triangles/array bytes: ", before_floor)
		check(cost(plants).x < before.x and cost(plants).y < before.y, "Геометрия подлеска дешевле исходной")
		check(cost(floor_meshes).x < before_floor.x and cost(floor_meshes).y < before_floor.y, "Геометрия подстилки дешевле исходной")
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = Models.grass_mesh()
	mm.instance_count = 4096
	var buffer := VegetationLayer._buffer(4096, VegetationLayer.STRIDE)
	for i in 4096:
		VegetationLayer._put_xform(buffer, i * VegetationLayer.STRIDE, i, 0, 0, 0, 1, 1)
	for count in [10, 100, 95, 3000, 8, 0, 4096]:
		VegetationLayer._upload_instances(mm, buffer, count)
		check(mm.visible_instance_count == count and mm.instance_count >= count, "Изменение ёмкости сохраняет все видимые экземпляры")
		check(mm.instance_count <= maxi(64, count * 4), "GPU не хранит большой пустой хвост")
		if count > 0:
			check(mm.buffer.slice(0, count * VegetationLayer.STRIDE) == buffer.slice(0, count * VegetationLayer.STRIDE), "Переданные преобразования не повреждаются при смене ёмкости")
	print("understory_models_test: %d ошибок" % fails)
	quit(1 if fails else 0)
