class_name Models
extends RefCounted
## Общая библиотека растительности; деревья (кроме кактуса) строит ForestModels.
## Модели вида: trunk — ствол (цвет bark), crown — крона (цвет из leaves по варианту объекта).
## Новый вид объекта: константа в Biomes.T_* и запись здесь.


static func _cyl(rt: float, rb: float, h: float, seg: int = 8, caps: bool = true) -> Array:
	var m := CylinderMesh.new()
	m.top_radius = rt
	m.bottom_radius = rb
	m.height = h
	m.radial_segments = seg
	m.rings = 0
	m.cap_top = caps
	m.cap_bottom = caps
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
	return preload("res://scripts/render/asset_catalog.gd").get_catalog().trees.duplicate(true)


static func build_tree_defs() -> Dictionary:
	var defs := {
		Biomes.T_CACTUS: {trunk = merge([_cyl(0.26, 0.32, 2.6, 7), _moved(_cyl(0.16, 0.19, 0.95, 6), Vector3(0.46, 1.0, 0)), _moved(_cyl(0.15, 0.18, 0.85, 6), Vector3(-0.46, 1.3, 0))]), bark = _c(79, 138, 60)},
	}
	for kind in [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_SNOWPINE, Biomes.T_PALM, Biomes.T_JUNGLE, Biomes.T_ACACIA, Biomes.T_DEAD, Biomes.T_BUSH]:
		for variant in ForestModels.form_count(kind):
			defs[kind + variant * ForestModels.MODEL_STRIDE] = ForestModels.definition(kind, variant)
	# Камыш — четыре силуэта, камни — шесть форм с общими LOD.
	for variant in ForestModels.VARIANTS:
		defs[Biomes.T_REED + variant * ForestModels.MODEL_STRIDE] = {crown = reeds(81 + variant * 13),
			leaves = [_c(196, 214, 150), _c(180, 204, 140), _c(208, 214, 160)]}
	for variant in RockModels.VARIANTS:
		defs[Biomes.T_ROCK + variant * ForestModels.MODEL_STRIDE] = {crown = boulder(Vector3(1.3, 0.78, 1.05), 72 + variant, 0.24),
			leaves = [_c(158, 152, 142), _c(142, 138, 130), _c(168, 160, 146)]}
	# Скальные выходы: те же камни T_ROCK, формы после шести валунов (RockModels.OUTCROP_V).
	for form in RockModels.OUTCROPS:
		defs[Biomes.T_ROCK + (RockModels.VARIANTS + form) * ForestModels.MODEL_STRIDE] = {crown = RockModels.outcrop_mesh(form),
			leaves = [_c(170, 167, 161), _c(152, 150, 146), _c(181, 176, 168)]}
	# 09.11.2026: скальные массивы (стена, ребро, останец, развал глыб) по два рисунка, после выходов.
	for model in RockModels.MASSIFS * RockModels.MASSIF_VARIANTS:
		defs[Biomes.T_ROCK + (RockModels.VARIANTS + RockModels.OUTCROPS + model) * ForestModels.MODEL_STRIDE] = {crown = RockModels.massif_mesh(model),
			leaves = [_c(168, 164, 157), _c(146, 145, 143), _c(182, 175, 163)]}
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


## Куртина камыша: изогнутые дугами листья разной высоты и початки рогоза.
static func reeds(seed: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_uv2(Vector2.ZERO)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for n in 12:
		st.set_uv2(Vector2(fposmod(n * 0.754878, 1.0), 0))
		var a := n * 2.399 + rng.randf_range(-0.28, 0.28)
		var base := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.03, 0.30)
		var lean := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.16, 0.44)
		var h := rng.randf_range(0.95, 1.65)
		var side := Vector3(-sin(a), 0, cos(a)) * rng.randf_range(0.032, 0.044)
		var mid := base + lean * 0.36 + Vector3(0, h * 0.56, 0)
		var tip := base + lean + Vector3(0, h * 0.96, 0)
		var normal := (Vector3.UP * 0.75 + lean).normalized()
		var low := Color(0.46, 0.55, 0.36)
		var mid_col := Color(0.72, 0.80, 0.56)
		var high := Color(0.94, 0.96, 0.78)
		for v: Array in [[base - side, low], [base + side, low], [mid + side * 0.72, mid_col],
				[base - side, low], [mid + side * 0.72, mid_col], [mid - side * 0.72, mid_col],
				[mid - side * 0.72, mid_col], [mid + side * 0.72, mid_col], [tip, high]]:
			st.set_color(v[1])
			st.set_normal(normal)
			st.add_vertex(v[0])
	# Початки: тонкий стебель без скрытых крышек и бархатистая бурая головка.
	st.set_uv2(Vector2.ZERO)
	for n in 3:
		var a := n * 2.1 + rng.randf()
		var foot := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.05, 0.24)
		var h := rng.randf_range(1.38, 1.76)
		var head := _cyl(0.036, 0.042, 0.26, 5, true)
		var stem := _cyl(0.007, 0.013, h, 3, false)
		for part: Array in [[stem, Vector3.ZERO, Color(0.56, 0.64, 0.40)], [head, Vector3(0, h - 0.32, 0), Color(0.34, 0.22, 0.13)]]:
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


## Один общий пучок: пять асимметричных листьев (высокие центральные и широкие боковые),
## расходящихся из плотного основания с глубоким затенением у корней и светлыми кончиками.
## UV.x — номер листа для индивидуального изгиба и силуэта в шейдере.
static func grass_mesh() -> ArrayMesh:
	return preload("res://scripts/render/asset_catalog.gd").get_catalog().grass


static func build_grass_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var offsets: Array[float] = [0.0, 0.18, -0.14, 0.22, -0.10]
	var tilts: Array[float] = [0.12, -0.18, 0.15, -0.12, 0.20]
	var feet: Array[float] = [0.020, 0.038, 0.016, 0.042, 0.028]
	var heights: Array[float] = [0.46, 0.28, 0.52, 0.36, 0.33]
	var widths: Array[float] = [0.045, 0.052, 0.036, 0.048, 0.041]
	var reaches: Array[float] = [0.14, 0.23, 0.11, 0.20, 0.16]
	for k in 5:
		var a := k * 2.399 + offsets[k]
		var radial := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-radial.z, 0, radial.x)
		var tilt := side * tilts[k]
		st.set_normal((Vector3.UP * 0.82 + radial * 0.34 + tilt).normalized())
		var foot := radial * feet[k]
		var h := heights[k]
		var width := widths[k]
		var reach := reaches[k]
		var tip: Vector3 = foot + radial * reach + tilt * 0.18 + Vector3.UP * h
		for v: Vector3 in [foot - side * width, foot + side * width, tip]:
			var is_base := v.y == 0.0
			var shade := (0.68 + 0.03 * k) if is_base else (1.01 + 0.02 * (k % 3))
			var col := Color(shade * (0.95 if is_base else 1.03), shade, shade * (0.92 if is_base else 0.96))
			st.set_color(col)
			st.set_uv(Vector2(float(k) / 5.0, v.y / h))
			st.add_vertex(v)
	return st.commit()
