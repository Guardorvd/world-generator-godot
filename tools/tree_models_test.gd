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
	var defs := Models.tree_defs()
	for kind in [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_SNOWPINE]:
		var silhouettes := []
		for variant in ForestModels.VARIANTS:
			var def: Dictionary = defs[kind + variant * ForestModels.MODEL_STRIDE]
			var triangles := 0
			for part in ["trunk", "crown"]:
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
				var surface := RenderingServer.mesh_get_surface(mesh.get_rid(), 0)
				var lods: Array = surface.get("lods", [])
				check(lods.size() == 2, "Нужны три уровня геометрии")
				var previous := idx.size()
				for lod: Dictionary in lods:
					var count: int = lod.index_data.size() / (2 if int(surface.vertex_count) < 65536 else 4)
					check(count < previous and count % 3 == 0, "LOD должен уменьшать число треугольников")
					previous = count
			check(triangles < 1200, "Превышен бюджет ближнего дерева")
			check(def.cutout and def.crown_texture.get_image().has_mipmaps(), "Листва должна иметь вырезанный силуэт и mipmaps")
			check(not silhouettes.has(def.crown.get_aabb()), "Силуэты вариантов должны отличаться")
			silhouettes.append(def.crown.get_aabb())
			var repeat := ForestModels.definition(kind, variant)
			check(repeat.crown.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == def.crown.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], "Модели должны быть воспроизводимыми")
			print("tree kind=%d variant=%d triangles=%d" % [kind, variant, triangles])
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
		for variant in 3:
			var def: Dictionary = defs[kind + variant * ForestModels.MODEL_STRIDE]
			for part in ["trunk", "crown"]:
				var node := MeshInstance3D.new()
				node.mesh = def[part]
				node.position = Vector3(variant * 7 - 7, 0, row * 10)
				var material := StandardMaterial3D.new()
				material.vertex_color_use_as_albedo = true
				material.vertex_color_is_srgb = true
				material.albedo_texture = def.get(part + "_texture", null)
				if part == "crown" and def.get("cutout", false):
					material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					material.alpha_scissor_threshold = 0.4
					material.cull_mode = BaseMaterial3D.CULL_DISABLED
				material.albedo_color = def.leaves[variant] if part == "crown" else Color.WHITE
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
