extends SceneTree
## Material sharing lifecycle without world generation or rendering.
var fails := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func run() -> void:
	var layer := VegetationLayer.new()
	root.add_child(layer)
	var shared := ShaderMaterial.new()
	shared.shader = preload("res://resources/vegetation.gdshader")
	shared.set_shader_parameter("lod_level", 0)
	var definition := {trunk_mats = [shared]}
	check(layer._shared_tree_material(definition, "trunk", 0, false) == shared, "Mature trees reuse the canonical material")
	var small := layer._shared_tree_material(definition, "trunk", 0, true)
	check(small == layer._shared_tree_material(definition, "trunk", 0, true) and small != shared, "Small rocks have one separate shared material")
	check(small.get_shader_parameter("lod_level") == -1 and shared.get_shader_parameter("lod_level") == 0, "Small-rock settings do not change the tree material")
	var a := MultiMeshInstance3D.new()
	var b := MultiMeshInstance3D.new()
	layer.add_child(a)
	layer.add_child(b)
	a.material_override = shared
	b.material_override = shared
	for node: MultiMeshInstance3D in [a, b]:
		node.multimesh = MultiMesh.new()
		node.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		node.multimesh.use_custom_data = true
		node.multimesh.mesh = BoxMesh.new()
		node.multimesh.instance_count = 1
		node.multimesh.buffer = layer._tree_buffer(PackedFloat32Array([1, 0, 0, 2, 0, 1, 0, 3, 0, 0, 1, 4]), false, 0.0)
	layer._reveal_node(a, shared)
	# The headless dummy renderer does not retain MultiMesh transform/custom data.
	if DisplayServer.get_name() != "headless":
		check(a.multimesh.get_instance_custom_data(0).a == a.get_meta("stream_birth")
			and b.multimesh.get_instance_custom_data(0).a == 0.0, "GPU timestamps are private without shader instance uniforms")
		check(a.multimesh.get_instance_transform(0).origin == Vector3(2, 3, 4), "Fade upload preserves the tree transform")
	var crown := layer._tree_buffer(PackedFloat32Array([1, 0, 0, 2, 0, 1, 0, 3, 0, 0, 1, 4, 0.2, 0.3, 0.4, 1]), true, -10.0)
	check(crown.slice(12, 16) == PackedFloat32Array([0.2, 0.3, 0.4, 1]) and crown[19] == -10.0,
		"Crown tint and fade occupy independent GPU channels")
	check(a.material_override == shared and b.material_override == shared and a.get_meta("stream_birth", 0.0) > 0.0, "Reveal shares the material but has a private timestamp")
	layer.stream.clock += 0.25
	check(is_equal_approx(layer.Snapshots.opacity(a.get_meta("stream_birth", 0.0), layer.stream.clock), 0.5), "Halfway reveal is continuous")
	layer._clean_retired()
	check(a.get_meta("stream_birth", 0.0) > 0.0, "No early promotion")
	layer.stream.clock += 0.25
	layer._clean_retired()
	check(a.get_meta("stream_birth", 0.0) == 0.0 and layer._appearing.is_empty(), "Completed reveal clears the timestamp")
	if DisplayServer.get_name() != "headless":
		check(a.multimesh.get_instance_custom_data(0).a > 0.0,
			"Mature GPU timestamp remains opaque without another buffer upload")
	layer._retire_nodes([a])
	check(a.material_override == shared and b.material_override == shared and a.get_meta("stream_birth", 0.0) < 0.0 and b.get_meta("stream_birth", 0.0) == 0.0, "Retiring one mature node leaves its neighbours unchanged")
	var c := MultiMeshInstance3D.new()
	layer.add_child(c)
	layer._reveal_node(c, shared)
	layer.stream.clock += 0.2
	var before := layer.Snapshots.opacity(c.get_meta("stream_birth", 0.0), layer.stream.clock)
	layer._retire_nodes([c])
	check(is_equal_approx(before, layer.Snapshots.opacity(c.get_meta("stream_birth", 0.0), layer.stream.clock)), "Retiring during reveal preserves opacity")
	layer.stream.clock += 0.31
	layer._clean_retired()
	check(c.material_override == shared and c.get_meta("stream_birth", 0.0) < 0.0 and layer._appearing.is_empty(), "A retiring node is not promoted back to opaque")
	var freed := MultiMeshInstance3D.new()
	layer.add_child(freed)
	layer._reveal_node(freed, shared)
	freed.free()
	layer._clean_retired()
	check(layer._appearing.is_empty(), "Evicted reveal nodes are removed safely")
	layer.stream.clock += 1.0
	layer._clean_retired()
	check(layer._retired.is_empty(), "Retirement queue drains")
	if "--render" in OS.get_cmdline_user_args():
		var scene := Node3D.new()
		root.add_child(scene)
		var camera := Camera3D.new()
		camera.position = Vector3(32, 32, 100)
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 75
		scene.add_child(camera)
		camera.current = true
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE * 0.5
		for i in 4200:
			var node := layer._multimesh(mesh, shared, 1, false, false, true, true)
			var source := PackedFloat32Array([1, 0, 0, i % 70, 0, 1, 0, i / 70, 0, 0, 1, 0])
			node.multimesh.buffer = layer._tree_buffer(source, false, 0.0)
			node.multimesh.visible_instance_count = 1
		await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://.godot/audit-vegetation-limit.png") == OK,
			"Rendered 4200 vegetation nodes beyond the shader instance limit")
		scene.queue_free()
	layer.queue_free()
	await process_frame
	print("vegetation_material_test: ", fails, " failures")
	quit(1 if fails else 0)
