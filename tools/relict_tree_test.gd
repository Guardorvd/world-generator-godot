extends SceneTree
## Geometry/renderer contracts; with a GPU also saves gallery and overhead-canopy views.
const Fixture := preload("res://tools/vegetation_test.gd")
var fails := 0
var definitions: Dictionary
var layer: VegetationLayer

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	definitions = Models.tree_defs()
	for kind in [Biomes.T_RELICT_OAK, Biomes.T_RELICT_PINE]:
		for variant in ForestModels.VARIANTS:
			var def: Dictionary = definitions[kind + variant * ForestModels.MODEL_STRIDE]
			var normal: Dictionary = definitions[Biomes.base_tree(kind) + variant * ForestModels.MODEL_STRIDE]
			var height: float = def.trunk.get_aabb().merge(def.crown.get_aabb()).end.y
			var ordinary: float = normal.trunk.get_aabb().merge(normal.crown.get_aabb()).end.y
			check(height > ordinary * 1.5 and def.crown.get_aabb().position.y > height * 0.64,
				"Giant %d/%d: height %.1f m (%.2fx ordinary), canopy in upper third" % [kind, variant, height, height / ordinary])
			for part in ["trunk", "crown"]:
				var mesh: ArrayMesh = def[part]
				var arrays := mesh.surface_get_arrays(0)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
				var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
				var valid := vertices.size() == normals.size() and uv.size() == vertices.size() and colors.size() == vertices.size()
				var radius := 0.0
				var min_u := INF
				var max_u := -INF
				var max_v := -INF
				for i in vertices.size():
					valid = valid and vertices[i].is_finite() and normals[i].is_finite() and uv[i].is_finite()
					valid = valid and absf(normals[i].length() - 1.0) < 0.001
					radius = maxf(radius, Vector2(vertices[i].x, vertices[i].z).length())
					min_u = minf(min_u, uv[i].x)
					max_u = maxf(max_u, uv[i].x)
					max_v = maxf(max_v, uv[i].y)
				check(valid, "%s: finite vertices, unit normals, complete UV/color attributes" % part)
				if part == "crown":
					check(min_u == 0.0 and max_u == 1.0 and max_v == 1.0, "Continuous full-spray foliage UV coverage")
					check(radius <= Biomes.CROWN_RADIUS[kind] * GameConfig.TILE, "Canopy radius includes all geometry at every LOD")
				else:
					check(max_v > height * 0.5 and max_u >= 3, "Bark UV repeats along trunk arc and circumference")
				var previous := 100000000
				var counts := []
				for lod: ArrayMesh in mesh.get_meta("levels"):
					var indices: PackedInt32Array = lod.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
					check(indices.size() > 0 and indices.size() < previous and indices.size() % 3 == 0, "LOD simplifies the mesh and stays nonempty")
					previous = indices.size()
					counts.append(indices.size() / 3)
				print("Model ", kind, "/", variant, " ", part, " LOD triangles: ", counts)
			var repeat := ForestModels.definition(kind, variant)
			check(repeat.crown.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == def.crown.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], "Procedural giant is deterministic")
	var w := Fixture.fixture(0)
	var h := Heightfield.new(w, false)
	layer = VegetationLayer.new()
	root.add_child(layer)
	layer.setup(w, h, definitions, Models.grass_mesh())
	for kind in [Biomes.T_RELICT_OAK, Biomes.T_RELICT_PINE]:
		for variant in ForestModels.VARIANTS:
			var entry: Dictionary = layer._defs[kind + variant * ForestModels.MODEL_STRIDE]
			check(entry.trunk_mats[0].get_shader_parameter("height") == entry.crown_mats[0].get_shader_parameter("height"),
				"Trunk and canopy share wind deformation height")
	check(ForestObstacles.TRUNK.has(Biomes.T_RELICT_OAK) and ForestObstacles.TRUNK.has(Biomes.T_RELICT_PINE), "Giant trunks participate in collisions")
	# Root/trunk footprints protect paths, while high canopies may cover them.
	check(Biomes.ground_radius(Biomes.T_RELICT_OAK) < Biomes.CROWN_RADIUS[Biomes.T_RELICT_OAK], "Ground clearance is independent of overhead canopy")
	w.obj_x = PackedFloat64Array([128.0])
	w.obj_y = PackedFloat64Array([128.0])
	w.obj_k = PackedInt32Array([Biomes.T_RELICT_PINE])
	w.obj_v = PackedInt32Array([1])
	w.obj_s = PackedFloat64Array([1.6])
	w.obj_count = 1
	w.chunks[8 * w.CW + 8] = PackedInt32Array([0])
	var built := layer._build_chunk(Vector2i(8, 8))
	check(built.entries.size() == 1 and built.entries[0].bounds.size.y > 25.0, "Generated giant reaches the actual MultiMesh builder with its full AABB")
	layer._apply_chunk(built)
	var buffers_valid := true
	for entry: Dictionary in layer.veg.values():
		for node: MultiMeshInstance3D in entry.nodes:
			var mm := node.multimesh
			# Bulk buffer uploads are authoritative; per-instance getters may retain identity on headless RS.
			var data := mm.buffer
			var transform := Transform3D(Basis(Vector3(data[0], data[4], data[8]), Vector3(data[1], data[5], data[9]),
				Vector3(data[2], data[6], data[10])), Vector3(data[3], data[7], data[11]))
			buffers_valid = buffers_valid and mm.custom_aabb.encloses(transform * mm.mesh.get_aabb())
	check(buffers_valid, "Every giant LOD buffer encloses the scaled geometry and wind margin")
	var obstacles := ForestObstacles.new(w, h)
	obstacles.update(512.0, 512.0, PackedFloat32Array(), 0, true)
	check(obstacles.hits(512, 512, h.ground_at(512, 512), 0.3)
		and not obstacles.hits(517, 512, h.ground_at(517, 512), 0.3), "Giant trunk blocks movement; overhead crown leaves the ground passable")
	var floor_image: Image = load("res://scripts/render/forest_floor.gd").surface_image(w)
	check(floor_image.get_pixel(128, 128).r > 0.5 and floor_image.get_pixel(128, 128).g > 0.9, "Relict pine contributes canopy and needles to the forest floor")
	if DisplayServer.get_name() != "headless" and fails == 0:
		await render_views()
	print("Relict tree failures: ", fails)
	layer.free()
	quit(1 if fails else 0)

func tree(scene: Node3D, kind: int, variant: int, position: Vector3) -> void:
	var model := kind + variant * ForestModels.MODEL_STRIDE
	var def: Dictionary = definitions[model]
	for part in ["trunk", "crown"]:
		var node := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = part == "crown"
		mm.mesh = def[part].get_meta("levels")[0]
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D(Basis.IDENTITY, position))
		if mm.use_colors: mm.set_instance_color(0, def.leaves[variant % def.leaves.size()])
		node.multimesh = mm
		node.material_override = layer._defs[model][part + "_mats"][0].duplicate()
		node.material_override.set_shader_parameter("lod_level", -1)
		node.custom_aabb = mm.mesh.get_aabb().grow(0.5)
		node.position = position
		mm.set_instance_transform(0, Transform3D.IDENTITY)
		scene.add_child(node)

func render_views() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1440, 900)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene := Node3D.new()
	viewport.add_child(scene)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b5cbd9")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("c6d3dc")
	env.environment.ambient_light_energy = 0.65
	scene.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -24, 0)
	sun.light_color = Color("ffe6c5")
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	scene.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(220, 220)
	ground.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("6e7352")
	ground.material_override = material
	scene.add_child(ground)
	var trees := Node3D.new()
	scene.add_child(trees)
	for row in 2:
		for variant in 3:
			tree(trees, Biomes.T_RELICT_PINE if row else Biomes.T_RELICT_OAK, variant, Vector3((variant - 1) * 24.0, 0, row * 30.0))
	tree(trees, Biomes.T_OAK, 0, Vector3(-36, 0, -6))
	tree(trees, Biomes.T_PINE, 0, Vector3(-43, 0, -1))
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.current = true
	camera.far = 250
	camera.fov = 50
	camera.look_at_from_position(Vector3(52, 29, 75), Vector3(-2, 12, 14))
	for i in 12: await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png("res://.godot/15_5_relict_gallery.png") == OK, "Saved GPU model gallery")
	trees.free()
	trees = Node3D.new()
	scene.add_child(trees)
	for y in range(-1, 2):
		for x in range(-1, 2): tree(trees, Biomes.T_RELICT_OAK, (x + y + 4) % 3, Vector3(x * 12.0, 0, y * 12.0))
	camera.fov = 85
	camera.look_at_from_position(Vector3(6, 1.8, 6), Vector3(1, 23, -2))
	for i in 12: await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png("res://.godot/15_5_relict_canopy.png") == OK, "Saved eye-height canopy view")
	viewport.free()
