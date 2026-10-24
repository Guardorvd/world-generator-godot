extends SceneTree
const Plants := preload("res://scripts/render/understory_models.gd")
const ForestFixture := preload("res://tools/massive_forest_test.gd")
var fails := 0
var layer: VegetationLayer
var meshes: Array[Mesh]

func check(ok: bool, label: String) -> void:
	if not ok:
		printerr("FAIL " + label)
		fails += 1

func _initialize() -> void:
	call_deferred("run")

func count_middle() -> int:
	var total := 0
	for kind in range(Plants.HAZEL_LOW, Plants.COUNT): total += layer.understory[kind].count
	return total

func run() -> void:
	meshes = Plants.meshes()
	check(meshes.size() == Plants.COUNT, "Plant registry includes every new model before floor details")
	for kind in range(Plants.HAZEL_LOW, Plants.COUNT):
		var mesh: ArrayMesh = meshes[kind]
		var arrays := mesh.surface_get_arrays(0)
		var p: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var valid := p.size() == n.size() and uv.size() == p.size() and colors.size() == p.size()
		for i in p.size(): valid = valid and p[i].is_finite() and uv[i].is_finite() and n[i].is_finite() and absf(n[i].length() - 1.0) < 0.001
		check(valid, "Model %d has finite vertices, unit normals, colors and UV" % kind)
		if kind in [Plants.JUNIPER_LOW, Plants.JUNIPER]:
			var green := 0
			for color in colors: green += int(color.g > color.r)
			check(green > colors.size() / 2, "Juniper preserves its needle colors through mesh merging and LOD")
		var lods: Array = RenderingServer.mesh_get_surface(mesh.get_rid(), 0).get("lods", [])
		check(not lods.is_empty(), "Middle-tier model %d has native mesh LOD" % kind)
		print("Plant ", kind, " height ", mesh.get_aabb().end.y, " m; triangles ", arrays[Mesh.ARRAY_INDEX].size() / 3, "; LODs ", lods.size())
	check(meshes[Plants.HAZEL].get_aabb().end.y > meshes[Plants.HAZEL_LOW].get_aabb().end.y
		and meshes[Plants.JUNIPER].get_aabb().end.y > meshes[Plants.JUNIPER_LOW].get_aabb().end.y, "Shrubs span low and tall forms")
	check(meshes[Plants.REED_GRASS].get_aabb().end.y > meshes[Plants.HIGH_GRASS].get_aabb().end.y
		and meshes[Plants.GREAT_FERN].get_aabb().end.y > meshes[Plants.FERN].get_aabb().end.y
		and meshes[Plants.GREAT_FERN].get_aabb().end.y < meshes[Plants.HAZEL].get_aabb().end.y, "Tall clumps bridge the gap below shrubs")
	var ch := Plants.character(0.9, 0.2, 0.75, 0.4, 0.9)
	var normal := Plants.weights(Biomes.FOREST, 0.75, 0.2, 0.9, ch)
	var wet := Plants.weights(Biomes.FOREST, 0.9, 0.2, 0.9, ch, 1, 0.1)
	var dry := Plants.weights(Biomes.TAIGA, 0.3, 0.35, 0.9, ch, 1, 0.9)
	var ordinary := true
	for kind in range(Plants.HAZEL_LOW, Plants.COUNT): ordinary = ordinary and normal[kind] == 0
	check(ordinary, "Ordinary forest keeps zero weights for the special middle tier")
	check(wet[Plants.HAZEL] > dry[Plants.HAZEL] and wet[Plants.GREAT_FERN] > dry[Plants.GREAT_FERN]
		and dry[Plants.JUNIPER] > wet[Plants.JUNIPER], "Moist deciduous shade and dry conifer forest select different communities")
	check(Plants.middle_strength(1, 0.1) == 0 and Plants.middle_strength(1, 0.9) > 0.9, "Relict interior, rather than open ground, supports the dense middle tier")
	var w := ForestFixture.fixture()
	w.moist.fill(0.75)
	w.filled = w.h.duplicate()
	var profile := StageVegetation.MassiveForest.profile(w)
	var tile: Vector2 = profile.center.clamp(Vector2(40, 40), Vector2(w.W - 40, w.H - 40))
	w.settlements = [{x = tile.x + 8, y = tile.y + 7, huts = [{x = tile.x + 8, y = tile.y + 7}]}]
	for y in w.H:
		w.path_mask[y * w.W + int(tile.x) + 4] = 3
		w.river[y * w.W + int(tile.x) - 6] = 1
	StageVegetation.run(w)
	var h := Heightfield.new(w, false)
	layer = VegetationLayer.new()
	root.add_child(layer)
	layer.setup(w, h, Models.tree_defs(), Models.grass_mesh())
	var at := tile * GameConfig.TILE
	layer.update(at.x, at.y, true)
	var saved: Array = []
	var counts := []
	for kind in range(Plants.HAZEL_LOW, Plants.COUNT):
		var entry: Dictionary = layer.understory[kind]
		check(entry.count > 0 and entry.count < entry.cap, "Middle form %d spawns without filling its buffer" % kind)
		check(entry.far and entry.node.material_override.get_shader_parameter("sway") > 0
			and entry.node.material_override.get_shader_parameter("height") == entry.box.end.y, "Tall form has far visibility and height-normalized shared wind")
		counts.append(entry.count)
		saved.append(entry.buf.duplicate())
		for i in entry.count:
			var o: int = i * VegetationLayer.STRIDE
			var data: PackedFloat32Array = entry.buf
			var transform := Transform3D(Basis(Vector3(data[o], data[o + 4], data[o + 8]), Vector3(data[o + 1], data[o + 5], data[o + 9]),
				Vector3(data[o + 2], data[o + 6], data[o + 10])), Vector3(data[o + 3], data[o + 7], data[o + 11]))
			var box: AABB = transform * entry.box
			check(entry.mm.custom_aabb.encloses(box), "Animated plant AABB includes all geometry")
			var center := box.get_center()
			for p: Vector2 in [Vector2(box.position.x, box.position.z), Vector2(box.end.x, box.end.z), Vector2(center.x, center.z)]:
				var cell := floori(p.y / GameConfig.TILE) * w.W + floori(p.x / GameConfig.TILE)
				check(w.path_mask[cell] == 0 and w.river[cell] == 0, "Entire plant footprint avoids roads and river")
				check(not StageVegetation.near_hut(w.settlements, p.x / 4.0, p.y / 4.0, 0.3), "Middle tier avoids houses")
	print("Relict middle counts: ", counts)
	var same_clearance := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 156
	for i in 150:
		var x := at.x + rng.randf_range(-34, 34)
		var z := at.y + rng.randf_range(-34, 34)
		var radius := rng.randf_range(0.2, 2.8)
		layer.placement.use_dry_cache = false
		var original := layer.placement.ground_clear(x, z, radius)
		layer.placement.use_dry_cache = true
		same_clearance = same_clearance and original == layer.placement.ground_clear(x, z, radius)
	check(same_clearance, "Dry-cell acceleration agrees with full footprint checks near roads, river and houses")
	var refill_start := Time.get_ticks_msec()
	layer.update(at.x, at.y, true)
	print("Relict refill ms: ", Time.get_ticks_msec() - refill_start)
	for kind in range(Plants.HAZEL_LOW, Plants.COUNT): check(saved[kind - Plants.HAZEL_LOW] == layer.understory[kind].buf, "Middle-tier regeneration is deterministic")
	if OS.get_cmdline_user_args().has("--perf"):
		var saved_profile := layer._massive_profile
		layer._massive_profile = {}
		refill_start = Time.get_ticks_msec()
		layer._fill_grass(at.x, at.y)
		print("Ordinary refill on same geometry ms: ", Time.get_ticks_msec() - refill_start)
		layer._massive_profile = saved_profile
	if DisplayServer.get_name() != "headless" and fails == 0: await render_views(at, h.ground_at(at.x, at.y))
	outside_fixture(w, h)
	print("Middle layer failures: ", fails)
	layer.free()
	quit(1 if fails else 0)

func outside_fixture(w: WorldData, h: Heightfield) -> void:
	var rect := Rect2i(w.W, 0, WorldData.REGION_SIZE, WorldData.REGION_SIZE)
	var fields := {}
	for name in ["h", "slope", "dw", "water_level"]:
		var values := PackedFloat32Array()
		values.resize(rect.get_area())
		values.fill(0.08 if name == "h" else (8.0 if name == "dw" else (-INF if name == "water_level" else 0)))
		fields[name] = values
	for name in ["biome", "river", "lake", "path", "village"]:
		var values := PackedByteArray()
		values.resize(rect.get_area())
		if name == "biome": values.fill(Biomes.FOREST)
		fields[name] = values
	for y in rect.size.y: fields.path[y * rect.size.x + 12] = 3
	fields.lake[100 * rect.size.x + 18] = 1
	fields.village[102 * rect.size.x + 18] = 1
	layer._outer_regions = {Vector2i(1, 0): {rect = rect, fields = fields}}
	layer._massive_profile = {center = Vector2(w.W + 8, 100), radius = Vector2(150, 150), strength = 1.0, scenario = StageVegetation.MassiveForest.OAK}
	layer._outer_vegetation = {Vector2i(16, 6): {x = PackedFloat64Array([w.W + 8.0]), y = PackedFloat64Array([100.0]),
		k = PackedInt32Array([Biomes.T_RELICT_OAK]), s = PackedFloat64Array([1.0])}}
	layer.update((w.W + 8) * 4.0, 400.0, true)
	var total := 0
	for kind in range(Plants.HAZEL_LOW, Plants.COUNT):
		var entry: Dictionary = layer.understory[kind]
		for i in entry.count:
			var data: PackedFloat32Array = entry.buf
			var o: int = i * VegetationLayer.STRIDE
			if data[o + 3] <= w.W * 4.0: continue
			total += 1
			check(absf(data[o + 7] - (0.08 * GameConfig.HS - 0.015)) < 0.001, "Outer plant uses snapshotted region ground")
			var cell := floori(data[o + 11] / 4.0) * rect.size.x + floori(data[o + 3] / 4.0) - w.W
			check(fields.path[cell] == 0 and fields.lake[cell] == 0 and fields.village[cell] == 0, "Streamed middle tier avoids regional roads, water and clearings")
	check(total > 0, "Middle tier is actually placed beyond the plan (%d)" % total)
	print("Streamed middle-tier instances: ", total)
	var same := true
	for dx in range(-5, 15):
		var x := (w.W + 8) * 4.0 + dx
		layer.placement.use_dry_cache = false
		var original := layer.placement.ground_clear(x, 400.0, 2.0)
		layer.placement.use_dry_cache = true
		same = same and original == layer.placement.ground_clear(x, 400.0, 2.0)
	check(same, "Regional dry-cell acceleration agrees with full snapshot footprint checks")
	check(not layer.placement.ground_clear((w.W + 0.1) * 4.0, 0.4, 0.05), "Unknown neighbouring region heights cannot produce floating plants")
	check(not layer.placement.ground_clear((w.W + 12) * 4.0, 400, 0.5), "Regional road blocks full plant footprints")
	check(not layer.placement.objects_clear((w.W + 8) * 4.0, 400, 0, 1, AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE), 1), "Streamed giant trunk participates in placement exclusion")
	layer.update(10000, 10000, true)
	check(count_middle() == 0, "Teleport clears the old middle layer")

func render_views(at: Vector2, floor_y: float) -> void:
	DisplayServer.window_set_size(Vector2i(1280, 800))
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b6cad5")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_energy = 0.7
	env.environment.ambient_light_color = Color("d4dfd5")
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -25, 0)
	sun.light_color = Color("ffebce")
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	ground.mesh = PlaneMesh.new()
	ground.mesh.size = Vector2(500, 500)
	ground.position = Vector3(at.x, floor_y - 0.02, at.y)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("696b48")
	ground.material_override = material
	root.add_child(ground)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	camera.far = 450
	camera.fov = 60
	layer.visible = false
	var gallery := Node3D.new()
	root.add_child(gallery)
	for kind in range(Plants.HAZEL_LOW, Plants.COUNT):
		var plant := MeshInstance3D.new()
		plant.mesh = meshes[kind]
		plant.material_override = layer.understory[kind].node.material_override.duplicate()
		plant.material_override.set_shader_parameter("fade_far", 100000)
		plant.position = Vector3(at.x + (kind - Plants.HAZEL_LOW - 2.5) * 2.7, floor_y, at.y)
		gallery.add_child(plant)
	camera.look_at_from_position(Vector3(at.x + 7, floor_y + 3.8, at.y + 15), Vector3(at.x, floor_y + 1.6, at.y))
	for i in 12: await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png("res://.godot/15_6_middle_gallery.png") == OK, "Saved middle-tier model gallery")
	gallery.free()
	layer.visible = true
	camera.look_at_from_position(Vector3(at.x, floor_y + 1.8, at.y), Vector3(at.x - 3, floor_y + 2.6, at.y - 18))
	for i in 12: await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png("res://.godot/15_6_middle_forest.png") == OK, "Saved middle tier under the relict canopy")
