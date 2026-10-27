extends SceneTree
## Контракт моделей и воспроизводимая витрина. Без --headless сохраняет PNG.

var fails := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		fails += 1
		printerr(message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var grass_arrays := Models.grass_mesh().surface_get_arrays(0)
	var grass_vertices: PackedVector3Array = grass_arrays[Mesh.ARRAY_VERTEX]
	var grass_uv: PackedVector2Array = grass_arrays[Mesh.ARRAY_TEX_UV]
	check(grass_vertices.size() == 15 and grass_uv.size() == 15, "Трава должна сохранять пять треугольников и данные вариации")
	for i in 5:
		check(is_equal_approx(grass_uv[i * 3 + 2].y, 1.0) and grass_uv[i * 3].y == 0.0, "Изгиб травы должен затрагивать кончик, а не основание")
	var defs := Models.tree_defs()
	var total := Vector3i.ZERO
	var previous_total := Vector3i.ZERO
	var stored_bytes := 0
	var previous_bytes := 0
	var baseline: GDScript
	var args := OS.get_cmdline_user_args()
	var baseline_at := args.find("--baseline")
	if baseline_at >= 0 and baseline_at + 1 < args.size():
		baseline = load(args[baseline_at + 1])
	for kind in [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_SNOWPINE, Biomes.T_PALM, Biomes.T_JUNGLE, Biomes.T_ACACIA, Biomes.T_DEAD, Biomes.T_BUSH]:
		var silhouettes := []
		for variant in ForestModels.VARIANTS:
			var def: Dictionary = defs[kind + variant * ForestModels.MODEL_STRIDE]
			var triangles := 0
			var cost := _cost(def)
			total += cost
			stored_bytes += _stored_bytes(def)
			check(cost.x > cost.y and cost.y > cost.z, "Каждый следующий LOD дерева должен уменьшать суммарную геометрию")
			if baseline != null:
				var previous: Dictionary = baseline.definition(kind, variant)
				previous_total += _cost(previous)
				previous_bytes += _stored_bytes(previous)
			for part in ["trunk", "crown"]:
				if not def.has(part):
					continue
				var mesh: ArrayMesh = def[part]
				var arrays := mesh.surface_get_arrays(0)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
				var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				triangles += idx.size() / 3
				check(vertices.size() == normals.size() and colors.size() == vertices.size(), "Нужны нормали и окраска всех вершин")
				for p in vertices:
					check(p.is_finite(), "Некорректная вершина")
				var levels: Array = ForestModels.lod_meshes(mesh)
				check(levels.size() == 3 and levels[0] == mesh, "Ближний меш используется напрямую, без копии вершин всех LOD")
				var previous := idx.size()
				for level_mesh: ArrayMesh in levels:
					var level_arrays := level_mesh.surface_get_arrays(0)
					var count: int = level_arrays[Mesh.ARRAY_VERTEX].size()
					var index_count: int = level_arrays[Mesh.ARRAY_INDEX].size()
					check(index_count <= previous and index_count % 3 == 0, "LOD части не должен увеличивать геометрию")
					previous = index_count
					var level_normals: PackedVector3Array = level_arrays[Mesh.ARRAY_NORMAL]
					for n in level_normals:
						check(n.is_finite() and n.length_squared() > 0.9, "Нормали каждого LOD должны быть конечными и единичными")
					for vertex_index: int in level_arrays[Mesh.ARRAY_INDEX]:
						check(vertex_index >= 0 and vertex_index < count, "Индексы LOD должны ссылаться на свои вершины")
				check(not mesh.has_meta("levels"), "Нет дублирующего набора мешей старого формата")
			check(triangles < 1200, "Превышен бюджет ближнего дерева")
			if def.has("crown"):
				check(def.cutout and def.crown_texture.get_image().has_mipmaps(), "Листва должна иметь вырезанный силуэт и mipmaps")
				check(not silhouettes.has(def.crown.get_aabb()), "Силуэты вариантов должны отличаться")
				silhouettes.append(def.crown.get_aabb())
			var repeat := ForestModels.definition(kind, variant)
			for part in ["trunk", "crown"]:
				if def.has(part):
					check(repeat[part].surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == def[part].surface_get_arrays(0)[Mesh.ARRAY_VERTEX], "Модели должны быть воспроизводимыми")
			print("tree kind=%d variant=%d triangles=%d" % [kind, variant, triangles])
	print("Total triangles LOD0/1/2: ", total)
	print("Stored geometry arrays: ", stored_bytes, " bytes")
	if baseline != null:
		print("Baseline triangles LOD0/1/2: ", previous_total)
		print("Baseline stored geometry arrays: ", previous_bytes, " bytes")
		check(stored_bytes < previous_bytes, "Хранимые массивы геометрии занимают меньше места")
		check(total.x <= previous_total.x and total.y <= previous_total.y, "Бюджет ближней и средней геометрии не увеличился")
	print("tree_models_test: %d ошибок" % fails)
	if DisplayServer.get_name() == "headless" or fails > 0:
		quit(1 if fails else 0)
		return
	DisplayServer.window_set_size(Vector2i(1440, 900))
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("b2c4ca")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("d4dfdf")
	environment.environment.ambient_light_energy = 0.7
	root.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -25, 0)
	light.light_color = Color("ffebce")
	light.shadow_enabled = true
	root.add_child(light)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("7b8062")
	ground.material_override = mat
	root.add_child(ground)
	for row in 3:
		var kind: int = [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE][row]
		for variant in ForestModels.VARIANTS:
			var def: Dictionary = defs[kind + variant * ForestModels.MODEL_STRIDE]
			for part in ["trunk", "crown"]:
				var node := MeshInstance3D.new()
				node.mesh = def[part]
				node.position = Vector3(variant * 7 - 10.5, 0, row * 10)
				var material := StandardMaterial3D.new()
				material.vertex_color_use_as_albedo = true
				material.vertex_color_is_srgb = true
				material.albedo_texture = def.get(part + "_texture", null)
				if part == "crown" and def.get("cutout", false):
					material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					material.alpha_scissor_threshold = 0.4
					material.cull_mode = BaseMaterial3D.CULL_DISABLED
				material.albedo_color = def.leaves[variant % def.leaves.size()] if part == "crown" else Color.WHITE
				node.material_override = material
				root.add_child(node)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	camera.look_at_from_position(Vector3(21, 14, -27), Vector3(0, 3, 9))
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tools/control/runs/trees65-gallery.png")
	camera.look_at_from_position(Vector3(7, 4, -10), Vector3(0, 3.4, 0))
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tools/control/runs/trees65-detail.png")
	quit()


func _cost(definition: Dictionary) -> Vector3i:
	var cost := Vector3i.ZERO
	for part in ["trunk", "crown"]:
		if definition.has(part):
			var levels: Array = ForestModels.lod_meshes(definition[part])
			for level in 3:
				cost[level] += levels[level].surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() / 3
	return cost


## Размер исходных массивов, без текстур и накладных расходов драйвера.
func _stored_bytes(definition: Dictionary) -> int:
	var visited := {}
	var bytes := 0
	for part in ["trunk", "crown"]:
		if not definition.has(part):
			continue
		var base: Mesh = definition[part]
		var meshes := ForestModels.lod_meshes(base)
		meshes.append(base)
		for mesh: Mesh in meshes:
			if visited.has(mesh.get_instance_id()):
				continue
			visited[mesh.get_instance_id()] = true
			var arrays := mesh.surface_get_arrays(0)
			for at in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_INDEX]:
				bytes += arrays[at].to_byte_array().size()
	return bytes
