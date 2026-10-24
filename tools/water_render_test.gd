extends SceneTree
## GPU smoke test: run WITHOUT --headless. Saves a synthetic river/lake seam.
const Junction = preload("res://scripts/render/water_junction.gd")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(960, 640)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var scene := Node3D.new()
	vp.add_child(scene)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.35, 0.46, 0.56)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.7
	scene.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-65, -25, 0)
	scene.add_child(light)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 15)
	ground.mesh = plane
	ground.position.y = -0.4
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.27, 0.32, 0.21)
	ground.material_override = material
	scene.add_child(ground)
	var lake := WaterBuilder._arrays(PackedVector3Array([Vector3(0, 1, -3), Vector3(6, 1, -3), Vector3(0, 1, 3),
		Vector3(6, 1, -3), Vector3(6, 1, 3), Vector3(0, 1, 3)]))
	var river: Array = []
	for p: Vector3 in [Vector3(-6, 1.4, -1), Vector3(-3, 1.2, 0.5), Vector3(-1, 1, 0), Vector3(2, 1, 0)]:
		river.append({x = p.x, y = p.y, z = p.z, w = 1.0, left = p + Vector3(0, 0, 1), right = p - Vector3(0, 0, 1)})
	var surfaces := Junction.partition(lake, WaterBuilder._river_arrays([river]))
	for mi in WaterBuilder.build_chunks(WaterBuilder.chunk_arrays(surfaces[0]), WaterBuilder._material(), "Lake"):
		scene.add_child(mi)
	for mi in WaterBuilder.build_chunks(WaterBuilder.chunk_arrays(surfaces[1]), WaterBuilder._material(false, true), "River"):
		scene.add_child(mi)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.look_at_from_position(Vector3(8, 10, 12), Vector3(0, 1, 0))
	camera.current = true
	for k in 8:
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if img == null or img.is_empty():
		printerr("GPU water render produced no image")
		quit(1)
		return
	var path := "res://.godot/water15_3_render.png"
	var error := img.save_png(path)
	print("GPU water render: %s (%dx%d), save=%d" % [path, img.get_width(), img.get_height(), error])
	quit(0 if error == OK else 1)
