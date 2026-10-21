extends RefCounted
## 6.6: простые ближние растения. Цвета частей запечены в вершины.

enum { FERN, MOSS, MUSHROOM, HERB, GRASS, BUSH, SAPLING, PINE }


static func meshes() -> Array[Mesh]:
	var green := Color(0.28, 0.48, 0.19)
	var parts: Array = []
	# Перистые вайи: отдельные пары листочков вдоль шести дуг.
	for arm in 6:
		var a := arm * TAU / 6.0
		var forward := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a))
		for step in 5:
			var t := (step + 1) / 6.0
			var p := forward * t * 0.7 + Vector3.UP * sin(t * PI * 0.85) * 0.55
			for sign_side: float in [-1.0, 1.0]:
				var tip := p + side * sign_side * (1.0 - t) * 0.27 + forward * 0.1
				parts.append([p - forward * 0.09, tip, p + forward * 0.09])
	var fern := _leaves(parts, green)
	parts = []
	for arm in 7:
		var a := arm * TAU / 7.0
		var p := Vector3(cos(a), 0, sin(a)) * 0.1
		var tip := Vector3(cos(a) * 0.32, 0.18 + (arm % 3) * 0.06, sin(a) * 0.32)
		var side := Vector3(-sin(a), 0, cos(a)) * 0.09
		parts.append([p, tip + side, tip, tip - side])
	var herb := _leaves(parts, Color(0.35, 0.55, 0.23))
	parts = []
	for arm in 7:
		var a := arm * 2.4
		var side := Vector3(cos(a), 0, sin(a)) * 0.025
		var p := Vector3(sin(a), 0, cos(a)) * 0.16
		parts.append([p - side, p + side, p + Vector3(sin(a) * 0.23, 0.65 + (arm % 3) * 0.12, cos(a) * 0.23)])
	var tall_grass := _leaves(parts, Color(0.47, 0.57, 0.25))
	var moss := _colored([[Models._ico(0.5, 0.07, 1.0, 0.18, 0.8), Color(0.28, 0.41, 0.15)], [Models._moved(Models._ico(0.33, 0.06, 1.0, 0.2, 1.0), Vector3(0.35, 0, 0.2)), Color(0.34, 0.46, 0.18)]])
	var mushrooms: Array = []
	for k in 3:
		var offset := Vector3(k * 0.14, 0, sin(k * 2.0) * 0.15)
		var height := 0.14 + k * 0.035
		mushrooms.append([Models._moved(Models._cyl(0.025, 0.035, height, 5), offset), Color(0.77, 0.70, 0.53)])
		mushrooms.append([Models._moved(Models._ico(0.11, height, 1.0, 0.45, 1.0), offset), Color(0.48 + k * 0.05, 0.26, 0.12)])
	var bush := _colored([[Models._ico(0.45, 0.36), green], [Models._moved(Models._ico(0.32, 0.29), Vector3(0.35, 0, 0.1)), Color(0.34, 0.51, 0.22)]])
	var bark := Color(0.35, 0.25, 0.14)
	var sapling := _colored([[Models._cyl(0.025, 0.055, 1.5, 5), bark], [Models._ico(0.42, 1.15, 1.0, 1.4, 0.8), Color(0.38, 0.57, 0.22)], [Models._moved(Models._ico(0.28, 0.8), Vector3(0.25, 0, 0)), green]])
	var pine := _colored([[Models._cyl(0.025, 0.06, 1.7, 5), bark], [Models._cone(0.5, 1.05, 0.35, 7), Color(0.23, 0.39, 0.23)], [Models._cone(0.34, 0.85, 0.95, 7), Color(0.29, 0.45, 0.25)]])
	return [fern, moss, _colored(mushrooms), herb, tall_grass, bush, sapling, pine]


static func _colored(parts: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for entry: Array in parts:
		var part: Array = entry[0]
		var arrays: Array = part[0].surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var xf: Transform3D = part[1]
		for i in indices:
			st.set_color(entry[1])
			st.set_normal((xf.basis.inverse().transposed() * normals[i]).normalized())
			st.add_vertex(xf * vertices[i])
	return st.commit()


static func _leaves(leaves: Array, color: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	st.set_color(color)
	for leaf: Array in leaves:
		for i in range(1, leaf.size() - 1):
			for v: Vector3 in [leaf[0], leaf[i], leaf[i + 1]]:
				st.add_vertex(v)
	return st.commit()


## Накопленные веса: влажная тень — мох/грибы, просветы — трава/кусты/молодняк.
static func weights(biome: int, moisture: float, light: float, canopy: float) -> PackedFloat32Array:
	var shade := 1.0 - light
	var wet := smoothstep(0.25, 0.8, moisture)
	var conifer := biome == Biomes.TAIGA
	return PackedFloat32Array([
		wet * shade * (0.7 if conifer else 1.2),
		wet * shade * (1.6 if conifer else 1.0),
		wet * shade * canopy * 0.28,
		0.18 + wet * 0.45,
		0.15 + light * 0.8,
		light * 0.22,
		light * canopy * (0.035 if conifer else 0.14),
		light * canopy * (0.16 if conifer else 0.025),
	])
