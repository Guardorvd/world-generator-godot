extends "res://tools/forest_scene_perf.gd"
## Identical forest, camera path and metrics as forest_scene_perf, with the
## actual game environment/day cycle. --hour 7.5 --quality 1 --cover 0.2
## --baseline uses extracted HEAD resources under .godot/lighting_baseline.
var cycle: RefCounted
var mist: Node3D

func setup() -> void:
	super.setup()
	var baseline := "--baseline" in OS.get_cmdline_user_args()
	var path := "res://.godot/lighting_baseline/scenes/game_world.tscn" if baseline else "res://scenes/game_world.tscn"
	var template: Node = load(path).instantiate()
	var sun: DirectionalLight3D
	var environment: Environment
	for child in root.get_children():
		if child is DirectionalLight3D:
			sun = child
		if child is WorldEnvironment:
			child.environment = template.get_node("WorldEnvironment").environment.duplicate(true)
			environment = child.environment
	var original: DirectionalLight3D = template.get_node("Sun")
	for property: String in ["shadow_bias", "shadow_normal_bias", "shadow_blur", "directional_shadow_mode",
		"directional_shadow_split_1", "directional_shadow_split_2", "directional_shadow_split_3",
		"directional_shadow_blend_splits", "directional_shadow_fade_start", "directional_shadow_max_distance"]:
		sun.set(property, original.get(property))
	if baseline:
		var script := GDScript.new()
		script.source_code = FileAccess.get_file_as_string("res://.godot/lighting_baseline/scripts/render/day_cycle.gd").replace("class_name DayCycle", "")
		assert(script.reload() == OK)
		cycle = script.new(environment, sun)
	else:
		cycle = DayCycle.new(environment, sun)
		preload("res://scripts/render/lighting_quality.gd").apply(environment, sun, int(Dev.arg("quality", "1")), true)
		cycle.cloud_cover_override = float(Dev.arg("cover", "-1"))
	cycle.camera = camera
	var base_image := Image.create(16, 16, false, Image.FORMAT_RGB8)
	base_image.fill(Color(0.3, 0.45, 0.2))
	var ground_material := TerrainBuilder.new().material(base_image)
	cycle.terrain_mats.append(ground_material)
	for child in root.get_children():
		if child is MeshInstance3D and child.mesh is PlaneMesh:
			child.material_override = ground_material
	if baseline:
		_replace_materials(veg._defs)
		_replace_materials(veg.understory)
		_replace_nodes(root)
	cycle.apply(float(Dev.arg("hour", "7.5")), 0.0)
	if "--no-fog" in OS.get_cmdline_user_args():
		environment.volumetric_fog_enabled = false
		cycle.apply(float(Dev.arg("hour", "7.5")), 0.0)
	if "--local-fog" in OS.get_cmdline_user_args():
		world.moist.fill(0.85)
		mist = preload("res://scripts/render/local_mist.gd").new()
		root.add_child(mist)
		mist.setup(world, Heightfield.new(world, false))
	results.hour = float(Dev.arg("hour", "7.5"))
	results.quality = int(Dev.arg("quality", "1"))
	results.adapter = RenderingServer.get_video_adapter_name()
	results.volumetric_fog = environment.volumetric_fog_enabled
	if "--lamp" in OS.get_cmdline_user_args():
		var lamp := preload("res://scripts/render/bike_lamp.gd").new()
		camera.add_child(lamp)
		lamp.position = Vector3(0.0, -0.6, -0.3)
		lamp.set_enabled(true)
	template.free()

func _process(delta: float) -> bool:
	var done := super._process(delta)
	if mist != null and camera != null:
		mist.update(camera.position, cycle, delta, elapsed)
		results.fog_stream = mist.stats.duplicate()
		results.fog_volumes = mist.patches.size()
	if camera != null and "--turns" in OS.get_cmdline_user_args():
		camera.rotate_y(sin(elapsed * 1.7) * 0.6)
	return done

func _replace_materials(value: Variant) -> void:
	if value is ShaderMaterial:
		var path: String = value.shader.resource_path
		if path.begins_with("res://resources/"):
			value.shader = load(path.replace("res://resources/", "res://.godot/lighting_baseline/resources/"))
	elif value is Dictionary:
		for entry: Variant in value.values():
			_replace_materials(entry)
	elif value is Array:
		for entry: Variant in value:
			_replace_materials(entry)

func _replace_nodes(node: Node) -> void:
	if node is GeometryInstance3D:
		_replace_materials(node.material_override)
	var mesh: Mesh
	if node is MeshInstance3D:
		mesh = node.mesh
	elif node is MultiMeshInstance3D and node.multimesh != null:
		mesh = node.multimesh.mesh
	if mesh != null:
		for i in mesh.get_surface_count():
			_replace_materials(mesh.surface_get_material(i))
	for child in node.get_children():
		_replace_nodes(child)
