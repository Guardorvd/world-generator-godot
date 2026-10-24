extends SceneTree
var fails := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func area(arrays: Array) -> float:
	var total := 0.0
	for f: Dictionary in WaterBuilder.WaterJunction._faces(arrays):
		total += absf((f.b.x - f.a.x) * (f.c.z - f.a.z) - (f.b.z - f.a.z) * (f.c.x - f.a.x)) * 0.5
	return total

func _init() -> void:
	var lake := WaterBuilder._arrays(PackedVector3Array([Vector3(-80, 2, -10), Vector3(140, 2, -10), Vector3(-80, 2, 90),
		Vector3(140, 2, -10), Vector3(140, 2, 90), Vector3(-80, 2, 90)]), PackedInt32Array([0, 1, 2, 3, 4, 5]))
	var river := WaterBuilder._river_arrays([[{x = -80.0, z = 32.0, y = 3.0, w = 5.0,
		left = Vector3(-80, 3, 27), right = Vector3(-80, 3, 37)},
		{x = 140.0, z = 32.0, y = 2.0, w = 5.0, left = Vector3(140, 2, 27), right = Vector3(140, 2, 37)}]])
	for source: Array in [lake, river]:
		var chunks := WaterBuilder.chunk_arrays(source)
		var total := 0.0
		var valid := true
		var attributes := true
		for chunk: Dictionary in chunks:
			total += area(chunk.arrays)
			for i in chunk.arrays[Mesh.ARRAY_VERTEX].size():
				var p: Vector3 = chunk.arrays[Mesh.ARRAY_VERTEX][i]
				valid = valid and p.x >= -0.001 and p.z >= -0.001 and p.x <= 64.001 and p.z <= 64.001
				if source[Mesh.ARRAY_TANGENT] != null:
					var uv: Vector2 = chunk.arrays[Mesh.ARRAY_TEX_UV][i]
					var world: Vector3 = p + chunk.origin
					attributes = attributes and absf(uv.x - (world.z - 27.0) / 10.0) < 0.0001
					attributes = attributes and absf(uv.y - (world.x - 140.0) * sqrt(1.0 + 1.0 / (220.0 * 220.0))) < 0.001
		check(chunks.size() > 1 and valid, "Geometry stays inside 64 m chunks, including negative coordinates")
		check(absf(total - area(source)) < 0.01, "Clipping preserves total area without overlap or gaps")
		check(attributes, "River spline UV interpolation survives cuts")
		var material := WaterBuilder._material()
		for node in WaterBuilder.build_chunks(chunks, material, "Test"):
			check(node.custom_aabb.size.x <= 64.021 and node.custom_aabb.size.z <= 64.021
				and node.custom_aabb.size.y > 0 and node.mesh.surface_get_material(0) == material,
				"Independent bounded mesh shares its material")
			node.free()
	check(WaterBuilder.chunk_arrays([]).is_empty(), "Empty water produces no chunks")
	check(fmod(WorldData.REGION_SIZE * GameConfig.TILE, WaterBuilder.CHUNK_SIZE) == 0, "Chunks align with regions")
	var world := WorldData.new()
	world.W = 16
	world.H = 16
	var built := WaterBuilder.build(world, [WaterBuilder.chunk_arrays(lake), WaterBuilder.chunk_arrays(river)])
	check(built.size() > 3 and built[0].mesh is PlaneMesh, "World assembly accepts prepared chunks and keeps cheap ocean")
	for node in built: node.free()
	var levels := PackedFloat32Array()
	levels.resize(32 * 32)
	levels.fill(0.1)
	var wet := PackedByteArray()
	wet.resize(32 * 32)
	wet.fill(1)
	var region := {rect = Rect2i(-256, -256, 32, 32), fields = {water_level = levels, river = wet, lake = wet}}
	var regional := WaterBuilder.chunk_arrays(RegionStream.water_arrays(region))
	check(regional.size() == 4 and regional[0].origin.x <= -960, "RegionStream water uses the same global chunk grid")
	print("Water chunk failures: ", fails)
	quit(fails)
