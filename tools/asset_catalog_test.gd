extends SceneTree
## Isolated pixel comparison of authoring output and the baked resource at all explicit LODs.
const Catalog := preload("res://scripts/render/asset_catalog.gd")
const OUT := "res://.godot/asset_catalog_preview"
var failures := 0
var viewport: SubViewport
var stand: Node3D

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("asset_catalog_test requires a graphical renderer")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(OUT)
	var catalog := Catalog.get_catalog()
	ForestModels.baking = true
	var authored := Models.build_tree_defs()
	ForestModels.baking = false
	var plants := preload("res://scripts/render/understory_models.gd").meshes()
	plants.append(catalog.grass)
	var isolated: bool = preload("res://scripts/render/understory_models.gd").meshes().size() == 12
	print("asset_catalog: private instance lists=", isolated)
	failures += int(not isolated)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1440, 960)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b9ced2")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.8
	viewport.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	viewport.add_child(light)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 150.0
	viewport.add_child(camera)
	camera.look_at_from_position(Vector3(66, 100, 130), Vector3(66, 0, 25))
	camera.current = true
	for level in 3:
		populate(authored, level)
		await process_frame
		await RenderingServer.frame_post_draw
		var before := viewport.get_texture().get_image()
		before.save_png(OUT.path_join("authoring_lod%d.png" % level))
		populate(catalog.trees, level)
		await process_frame
		await RenderingServer.frame_post_draw
		var after := viewport.get_texture().get_image()
		after.save_png(OUT.path_join("baked_lod%d.png" % level))
		var equal := before.get_data() == after.get_data()
		print("asset_catalog: LOD", level, " pixels identical=", equal)
		failures += int(not equal)
	print("asset_catalog: failures=", failures)
	quit(1 if failures else 0)

func populate(defs: Dictionary, level: int) -> void:
	if stand != null:
		viewport.remove_child(stand)
		stand.free()
	stand = Node3D.new()
	viewport.add_child(stand)
	var n := 0
	for id: int in defs:
		var def: Dictionary = defs[id]
		for part: String in ["trunk", "crown"]:
			if not def.has(part): continue
			var levels := ForestModels.lod_meshes(def[part])
			var mesh := MeshInstance3D.new()
			mesh.mesh = levels[mini(level, levels.size() - 1)]
			mesh.position = Vector3(n % 12 * 12, 0, n / 12 * 16)
			var mat := StandardMaterial3D.new()
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.vertex_color_use_as_albedo = part == "crown" or def.get("colored_bark", false)
			mat.albedo_color = def.get("bark", Color.WHITE) if part == "trunk" else def.get("leaves", [Color.WHITE])[0]
			mat.albedo_texture = def.get(part + "_texture")
			if part == "crown" and def.get("cutout", false): mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			mesh.material_override = mat
			stand.add_child(mesh)
		n += 1
