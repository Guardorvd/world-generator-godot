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
	shared.set_shader_parameter("stream_birth", 0.0)
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
	layer._reveal_node(a, shared)
	check(a.material_override != shared and b.material_override == shared, "Reveal is private to the arriving node")
	layer.stream.clock += 0.25
	check(is_equal_approx(layer.Snapshots.opacity(a.material_override.get_shader_parameter("stream_birth"), layer.stream.clock), 0.5), "Halfway reveal is continuous")
	layer._clean_retired()
	check(a.material_override != shared, "No early promotion")
	layer.stream.clock += 0.25
	layer._clean_retired()
	check(a.material_override == shared and layer._appearing.is_empty(), "Completed reveal returns to shared material")
	layer._retire_nodes([a])
	check(a.material_override != shared and b.material_override == shared and shared.get_shader_parameter("stream_birth") == 0.0, "Retiring one mature node leaves its neighbours unchanged")
	var c := MultiMeshInstance3D.new()
	layer.add_child(c)
	layer._reveal_node(c, shared)
	layer.stream.clock += 0.2
	var before := layer.Snapshots.opacity(c.material_override.get_shader_parameter("stream_birth"), layer.stream.clock)
	layer._retire_nodes([c])
	check(is_equal_approx(before, layer.Snapshots.opacity(c.material_override.get_shader_parameter("stream_birth"), layer.stream.clock)), "Retiring during reveal preserves opacity")
	layer.stream.clock += 0.31
	layer._clean_retired()
	check(c.material_override != shared and layer._appearing.is_empty(), "A retiring node is not promoted back to opaque")
	var freed := MultiMeshInstance3D.new()
	layer.add_child(freed)
	layer._reveal_node(freed, shared)
	freed.free()
	layer._clean_retired()
	check(layer._appearing.is_empty(), "Evicted reveal nodes are removed safely")
	layer.stream.clock += 1.0
	layer._clean_retired()
	check(layer._retired.is_empty(), "Retirement queue drains")
	layer.queue_free()
	await process_frame
	quit(1 if fails else 0)
