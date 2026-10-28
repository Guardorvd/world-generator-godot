extends SceneTree
## Boundary/negative coordinates, shared vertices, empty and optional attributes.
func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var a: Array = []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-254, 1, -254), Vector3(2, 2, 2), Vector3(258, 3, 2),
		Vector3(258, 4, 258), Vector3(514, 5, 258), Vector3(2, 6, 258)])
	a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 2, 3, 2, 4, 3, 1, 3, 5])
	var ok := Grid.fast_grid() != null and PlanTerrain.partition([]).is_empty()
	for full in [false, true]:
		if full:
			a[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK])
			a[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.ONE, Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT])
			a[Mesh.ARRAY_TEX_UV2] = a[Mesh.ARRAY_TEX_UV]
			a[Mesh.ARRAY_COLOR] = PackedColorArray([Color.RED, Color.GREEN, Color.BLUE, Color.WHITE, Color.BLACK, Color.TRANSPARENT])
		var expected := PlanTerrain.partition_reference(a)
		var actual := PlanTerrain.partition(a)
		ok = ok and expected.size() == actual.size()
		for key: Vector2i in expected:
			ok = ok and actual.has(key)
			if not actual.has(key): continue
			for slot in Mesh.ARRAY_MAX:
				ok = ok and var_to_bytes(expected[key][slot]) == var_to_bytes(actual[key][slot])
	print("Terrain partition boundaries/attributes: ", ok)
	quit(0 if ok else 1)
