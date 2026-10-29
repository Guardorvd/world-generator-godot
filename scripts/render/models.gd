class_name Models
extends RefCounted
## Общая библиотека растительности; деревья (кроме кактуса) строит ForestModels.
## Модели вида: trunk — ствол (цвет bark), crown — крона (цвет из leaves по варианту объекта).
## Новый вид объекта: константа в Biomes.T_* и запись здесь.


static func _cyl(rt: float, rb: float, h: float, seg: int = 8) -> Array:
	var m := CylinderMesh.new()
	m.top_radius = rt
	m.bottom_radius = rb
	m.height = h
	m.radial_segments = seg
	m.rings = 0
	return [m, Transform3D(Basis(), Vector3(0, h / 2.0, 0))]


## Сдвинуть часть модели
static func _moved(part: Array, offset: Vector3) -> Array:
	var t: Transform3D = part[1]
	return [part[0], Transform3D(t.basis, t.origin + offset)]


## Объединение частей в один меш
static func merge(parts: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	for p in parts:
		st.append_from(p[0], 0, p[1])
	st.index()
	return _with_lods(st.commit())


## Уровни детализации для дальних объектов, которые рисуются до TREE_R
static func _with_lods(source: ArrayMesh) -> ArrayMesh:
	var importer := ImporterMesh.new()
	importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, source.surface_get_arrays(0))
	importer.generate_lods(25.0, 60.0, [])
	return importer.get_mesh()


static func _c(r: int, g: int, b: int) -> Color:
	return Color8(r, g, b)


static func tree_defs() -> Dictionary:
	var defs := {
		Biomes.T_CACTUS: {trunk = merge([_cyl(0.28, 0.32, 2.6, 7), _moved(_cyl(0.18, 0.18, 0.9, 6), Vector3(0.5, 1.0, 0)), _moved(_cyl(0.18, 0.18, 0.8, 6), Vector3(-0.5, 1.3, 0))]), bark = _c(79, 138, 60)},
	}
	for kind in [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_SNOWPINE, Biomes.T_PALM, Biomes.T_JUNGLE, Biomes.T_ACACIA, Biomes.T_DEAD, Biomes.T_BUSH]:
		for variant in ForestModels.VARIANTS:
			defs[kind + variant * ForestModels.MODEL_STRIDE] = ForestModels.definition(kind, variant)
	# Камыш — три силуэта, камни — шесть форм с общими LOD.
	for variant in ForestModels.VARIANTS:
		defs[Biomes.T_REED + variant * ForestModels.MODEL_STRIDE] = {crown = reeds(81 + variant * 13),
			leaves = [_c(196, 214, 150), _c(180, 204, 140), _c(208, 214, 160)]}
	for variant in RockModels.VARIANTS:
		defs[Biomes.T_ROCK + variant * ForestModels.MODEL_STRIDE] = {crown = boulder(Vector3(1.3, 0.78, 1.05), 72 + variant, 0.24),
			leaves = [_c(158, 152, 142), _c(142, 138, 130), _c(168, 160, 146)]}
	return defs


## Гладкий шум значений в точке p (для неровностей камня)
static func _noise3(p: Vector3, seed: int) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector3.ONE * 3.0 - f * 2.0)
	var out := 0.0
	for c in 8:
		var o := Vector3(c & 1, (c >> 1) & 1, c >> 2)
		var q := i + o
		var w := (f.x if o.x > 0 else 1.0 - f.x) * (f.y if o.y > 0 else 1.0 - f.y) * (f.z if o.z > 0 else 1.0 - f.z)
		out += WGRandom.hash2(int(q.x) + int(q.z) * 157, int(q.y), seed) * w
	return out


## Общая библиотека сколотых камней мира и лесной подстилки, полуоси size.
## Цвет вершин: камень яркости tone, сверху мох (доля moss).
static func boulder(size: Vector3, seed: int, moss: float, tone := 1.0) -> ArrayMesh:
	return RockModels.mesh(size, seed, moss, tone)


## 9.4: куртина камыша: изогнутые листья и несколько початков. Цвет листьев — оттенок экземпляра.
static func reeds(seed: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_uv2(Vector2.ZERO)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for n in 12:
		st.set_uv2(Vector2(fposmod(n * 0.754878, 1.0), 0))
		var a := rng.randf() * TAU
		var base := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.0, 0.32)
		var lean := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.1, 0.35)
		var h := rng.randf_range(1.0, 1.6)
		var side := Vector3(-sin(a), 0, cos(a)) * 0.035
		var mid := base + lean * 0.4 + Vector3(0, h * 0.55, 0)
		var tip := base + lean + Vector3(0, h, 0)
		var normal := (Vector3.UP + lean).normalized()
		var low := Color(0.55, 0.62, 0.42)
		var high := Color(0.92, 0.95, 0.8)
		for v: Array in [[base - side, low], [base + side, low], [mid + side * 0.7, low.lerp(high, 0.55)],
				[base - side, low], [mid + side * 0.7, low.lerp(high, 0.55)], [mid - side * 0.7, low.lerp(high, 0.55)],
				[mid - side * 0.7, low.lerp(high, 0.55)], [mid + side * 0.7, low.lerp(high, 0.55)], [tip, high]]:
			st.set_color(v[1])
			st.set_normal(normal)
			st.add_vertex(v[0])
	# Початки: тонкий стебель и бурая головка — без отдельного материала, цветом вершин
	st.set_uv2(Vector2.ZERO)
	for n in 3:
		var a := n * 2.1 + rng.randf()
		var foot := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.05, 0.25)
		var h := rng.randf_range(1.35, 1.75)
		var head := _cyl(0.04, 0.04, 0.24, 5)
		var stem := _cyl(0.008, 0.012, h, 3)
		for part: Array in [[stem, Vector3.ZERO, Color(0.6, 0.66, 0.42)], [head, Vector3(0, h - 0.3, 0), Color(0.36, 0.25, 0.16)]]:
			var mesh_arrays: Array = part[0][0].get_mesh_arrays()
			var verts: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = mesh_arrays[Mesh.ARRAY_NORMAL]
			var xf: Transform3D = part[0][1]
			for i: int in mesh_arrays[Mesh.ARRAY_INDEX]:
				st.set_color(part[2])
				st.set_normal(normals[i])
				st.add_vertex(xf * verts[i] + foot + part[1])
	st.index()
	return st.commit()


## Один общий пучок: пять разных острых листьев, которые расходятся из компактного основания.
## UV.x — номер листа для небольших отличий между экземплярами в шейдере.
static func grass_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 5:
		var a := k * 2.399
		var radial := Vector3(cos(a), 0, sin(a))
		st.set_normal((Vector3.UP + radial * 0.25).normalized())
		var side := Vector3(-radial.z, 0, radial.x)
		var foot := radial * (0.025 + 0.018 * (k % 3))
		var h: float = [0.40, 0.31, 0.47, 0.35, 0.42][k]
		var width: float = [0.042, 0.033, 0.038, 0.047, 0.031][k]
		var tip: Vector3 = foot + radial * [0.14, 0.20, 0.09, 0.17, 0.12][k] + Vector3.UP * h
		for v: Vector3 in [foot - side * width, foot + side * width, tip]:
			var shade := 0.78 + 0.035 * k if v.y == 0.0 else 0.96 + 0.01 * k
			st.set_color(Color(shade, shade, shade))
			st.set_uv(Vector2(float(k) / 5.0, v.y / h))
			st.add_vertex(v)
	return st.commit()
