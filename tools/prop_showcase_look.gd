extends SceneTree
## Isolated visual & structural showcase of standalone rocks, outcrops/massifs, stone groups,
## logs, branches, twigs, snags, stumps, roots, and nurse logs. No full world generation.
## Run: godot --path . --script res://tools/prop_showcase_look.gd -- --out res://.godot/prop_before_studio

const Floor := preload("res://scripts/render/forest_floor.gd")

var out_dir := "res://.godot/prop_showcase"
var stage: Node3D
var camera: Camera3D


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	var args := OS.get_cmdline_user_args()
	var idx := args.find("--out")
	if idx >= 0 and idx + 1 < args.size():
		out_dir = args[idx + 1]
	call_deferred("_run")


func _make_rock_mat(tint: Color, contact := 0.55) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://resources/rock.gdshader")
	mat.set_shader_parameter("albedo_color", tint)
	mat.set_shader_parameter("fade_far", 500.0)
	mat.set_shader_parameter("fade_len", 40.0)
	mat.set_shader_parameter("rock_contact", contact)
	mat.set_shader_parameter("rock_scale", 1.0)
	return mat


func _make_veg_mat(trunk := false) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://resources/vegetation_trunk.gdshader") if trunk else preload("res://resources/vegetation.gdshader")
	mat.set_shader_parameter("albedo_color", Color.WHITE)
	mat.set_shader_parameter("fade_far", 500.0)
	mat.set_shader_parameter("fade_len", 40.0)
	mat.set_shader_parameter("wind_strength", 0.0)
	mat.set_shader_parameter("detail_full", 1.0)
	mat.set_shader_parameter("detail_fade", 0.5)
	return mat


func _clear_stage() -> void:
	for c in stage.get_children():
		c.queue_free()


func _place(mesh: Mesh, pos: Vector3, mat: Material, rot_y := 0.0, scale := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation.y = rot_y
	mi.scale = scale
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	stage.add_child(mi)
	return mi


func _shot(name: String, cam_pos: Vector3, target: Vector3, fov := 40.0) -> void:
	camera.fov = fov
	camera.position = cam_pos
	camera.look_at(target, Vector3.UP)
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var path := out_dir.path_join(name + ".png")
	camera.get_viewport().get_texture().get_image().save_png(path)
	print("prop_showcase: saved ", path)


func _run() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.76, 0.80, 0.78)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.84, 0.88, 0.94)
	env.environment.ambient_light_energy = 0.52
	root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -32, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	root.add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(180, 180)
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.45, 0.44, 0.34)
	gmat.roughness = 0.96
	ground.mesh = plane
	ground.material_override = gmat
	root.add_child(ground)

	stage = Node3D.new()
	root.add_child(stage)
	camera = Camera3D.new()
	root.add_child(camera)

	var rock_mat := _make_rock_mat(Color(0.62, 0.59, 0.54), 0.55)
	var floor_rock_mat := _make_rock_mat(Color.WHITE, 0.55)
	var pebbles_mat := _make_rock_mat(Color.WHITE, 0.20)
	var log_bark_mat := _make_veg_mat(true)
	log_bark_mat.set_shader_parameter("bark_detail", 3.0)
	var upright_bark_mat := _make_veg_mat(true)
	upright_bark_mat.set_shader_parameter("bark_detail", 4.0)
	var veg_mat := _make_veg_mat(false)
	var defs := Models.tree_defs()
	var floor_meshes := Floor.meshes()
	var mat_for := func(idx_f: int) -> Material:
		var k := Floor.base_kind(idx_f)
		if k == Floor.BOULDER:
			return floor_rock_mat
		if k == Floor.STONES:
			return pebbles_mat
		if idx_f in [Floor.SNAG, Floor.SNAG_FORK, Floor.STUMP, Floor.STUMP_HOLLOW, Floor.ROOT_STUMP]:
			return upright_bark_mat
		if k in [Floor.LOG, Floor.MOSS_LOG, Floor.BRANCH, Floor.TWIG, Floor.ROOT_SPAN]:
			return log_bark_mat
		return veg_mat

	# 1. Standalone Boulders (all RockModels.VARIANTS) + LOD0/1/2 comparison of Variant 0
	var cols := mini(5, maxi(3, int(ceil(float(RockModels.VARIANTS) / 2.0))))
	for v in RockModels.VARIANTS:
		var gx := (v % cols - (cols - 1) * 0.5) * 2.7
		var gz := (v / cols) * 2.5 - 1.2
		var m := defs[Biomes.T_ROCK + v * ForestModels.MODEL_STRIDE].crown as ArrayMesh
		_place(m, Vector3(gx, 0, gz), rock_mat, 0.25)
	await _shot("boulders_variants", Vector3(0.0, 5.2, 8.8), Vector3(0.0, 0.25, 0.2), 38.0)

	_clear_stage()
	var lod0 := defs[Biomes.T_ROCK].crown as ArrayMesh
	var lods := ForestModels.lod_meshes(lod0)
	for li in lods.size():
		_place(lods[li], Vector3((li - 1) * 2.4, 0, 0), rock_mat, 0.35)
	if RockModels.VARIANTS > 1:
		var lod0_b := defs[Biomes.T_ROCK + ForestModels.MODEL_STRIDE].crown as ArrayMesh
		var lods_b := ForestModels.lod_meshes(lod0_b)
		for li in lods_b.size():
			_place(lods_b[li], Vector3((li - 1) * 2.4, 0, -2.5), rock_mat, 0.15)
	await _shot("boulders_lods", Vector3(0.0, 2.8, 5.8), Vector3(0.0, 0.3, -1.0), 40.0)

	# 2. Outcrops (3 forms) & Massifs (4 archetypes)
	_clear_stage()
	for f in RockModels.OUTCROPS:
		var om := defs[Biomes.T_ROCK + (RockModels.VARIANTS + f) * ForestModels.MODEL_STRIDE].crown as ArrayMesh
		_place(om, Vector3((f - 1) * 5.2, 0, 4.2), rock_mat, 0.2, Vector3.ONE * 1.15)
	for m_idx in RockModels.MASSIFS:
		var mm_id := Biomes.T_ROCK + (RockModels.VARIANTS + RockModels.OUTCROPS + m_idx * RockModels.MASSIF_VARIANTS) * ForestModels.MODEL_STRIDE
		var mm := defs[mm_id].crown as ArrayMesh
		_place(mm, Vector3((m_idx - 1.5) * 6.5, 0, -3.5), rock_mat, 0.15, Vector3.ONE * 0.45)
	await _shot("outcrops_massifs", Vector3(0.0, 6.2, 16.5), Vector3(0.0, 1.0, 0.0), 42.0)

	# 3. Stones & Boulders from ForestFloor + GroundCarpet CARPET_STONES
	_clear_stage()
	var stone_forms := [Floor.STONES, Floor.STONE_SINGLE, Floor.STONES_PAIR, Floor.BOULDER, Floor.MOSS_BOULDER, Floor.MOSS_BOULDER_LOW]
	for i in stone_forms.size():
		var idx_f: int = stone_forms[i]
		var px := (i % 3 - 1.0) * 2.8
		var pz := 1.4 if i < 3 else -1.5
		_place(floor_meshes[idx_f], Vector3(px, 0, pz), mat_for.call(idx_f), 0.1)
	_place(Models.build_carpet_mesh(Models.CARPET_STONES, false), Vector3(0.0, 0.005, 3.3), veg_mat, 0.0)
	await _shot("stones_and_floor_boulders", Vector3(0.0, 3.6, 7.6), Vector3(0.0, 0.2, 0.3), 42.0)

	# 4. Logs, Branches, Twigs, Root Spans
	_clear_stage()
	var log_forms := [Floor.LOG, Floor.LOG_BROKEN, Floor.MOSS_LOG, Floor.MOSS_LOG_BROKEN, Floor.BRANCH, Floor.TWIG, Floor.ROOT_SPAN]
	for i in log_forms.size():
		var idx_f: int = log_forms[i]
		var col := i % 4
		var row := i / 4
		var px := (col - 1.5) * 3.8
		var pz := -2.0 + row * 3.6
		_place(floor_meshes[idx_f], Vector3(px, 0, pz), mat_for.call(idx_f), 0.35)
	await _shot("logs_branches_twigs", Vector3(0.0, 4.6, 8.2), Vector3(0.0, 0.15, -0.2), 45.0)

	# 5. Stumps, Snags, Roots, Root Plates, Upturned Rootballs
	_clear_stage()
	var root_forms := [Floor.SNAG, Floor.STUMP, Floor.ROOTS, Floor.ROOT_STUMP, Floor.ROOT_PLATE, Floor.ROOT_UPTURNED]
	for i in root_forms.size():
		var idx_f: int = root_forms[i]
		var px := (i % 3 - 1.0) * 3.6
		var pz := 2.0 if i >= 3 else -1.8
		_place(floor_meshes[idx_f], Vector3(px, 0, pz), mat_for.call(idx_f), 0.25)
	await _shot("stumps_snags_roots", Vector3(0.0, 3.8, 8.8), Vector3(0.0, 0.45, 0.1), 42.0)

	# 6. Nurse Logs (expedition large fallen trunks)
	_clear_stage()
	var nurse_forms := [Floor.NURSE_LOG, Floor.NURSE_LOG_SPLIT, Floor.NURSE_LOG_LONG, Floor.NURSE_LOG_HOLLOW, Floor.NURSE_LOG_PAIR]
	for i in nurse_forms.size():
		var idx_f: int = nurse_forms[i]
		var px := (i % 3 - 1.0) * 6.8
		var pz := 2.4 if i >= 3 else -2.2
		_place(floor_meshes[idx_f], Vector3(px, 0, pz), mat_for.call(idx_f), 0.25)
	await _shot("nurse_logs", Vector3(0.0, 5.2, 11.8), Vector3(0.0, 0.3, 0.0), 46.0)

	# 7. New Variety Silhouettes (added variants across logs, branches, twigs, snags, stumps, clusters)
	if Floor.COUNT > Floor.NURSE_LOG_PAIR + 1:
		_clear_stage()
		var new_forms := [Floor.LOG_HOLLOW, Floor.MOSS_LOG_SPLIT, Floor.BRANCH_FORKED, Floor.BRANCH_PINE, Floor.TWIG_FORK, Floor.SNAG_FORK, Floor.STUMP_HOLLOW, Floor.BOULDER_CLUSTER]
		for i in new_forms.size():
			var idx_f: int = new_forms[i]
			var px := (i % 4 - 1.5) * 3.8
			var pz := -1.8 if i < 4 else 2.2
			_place(floor_meshes[idx_f], Vector3(px, 0, pz), mat_for.call(idx_f), 0.32)
		await _shot("new_variety_forms", Vector3(0.0, 4.6, 8.8), Vector3(0.0, 0.2, 0.2), 45.0)

	quit(0)
