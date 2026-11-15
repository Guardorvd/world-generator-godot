class_name Models
extends RefCounted
## Общая библиотека растительности; деревья (кроме кактуса) строит ForestModels.
## Модели вида: trunk — ствол (цвет bark), crown — крона (цвет из leaves по варианту объекта).
## Новый вид объекта: константа в Biomes.T_* и запись здесь.


static func _cyl(rt: float, rb: float, h: float, seg: int = 8, caps: bool = true, cap_bottom: bool = true) -> Array:
	var m := CylinderMesh.new()
	m.top_radius = rt
	m.bottom_radius = rb
	m.height = h
	m.radial_segments = seg
	m.rings = 0
	m.cap_top = caps
	m.cap_bottom = caps and cap_bottom
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
		Biomes.T_CACTUS: {trunk = merge([_cyl(0.26, 0.32, 2.6, 7, true, false), _moved(_cyl(0.16, 0.19, 0.95, 6), Vector3(0.46, 1.0, 0)), _moved(_cyl(0.15, 0.18, 0.85, 6), Vector3(-0.46, 1.3, 0))]), bark = _c(79, 138, 60)},
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


## 14.11.2026: дернина — плотный ковёр мелкой травы у игрока (GroundCarpet). Куртинка шириной ~1 м из двух ярусов:
## высокие травинки (выше в середине) и короткие широкие — подложка, закрывающая землю между ними. Куртинки стоят
## чаще своего радиуса и перекрываются: сплошной ковёр. Корни тёмные, кончики светлые — объём читается и на зелёной
## земле. Строится при запуске (каталог не меняется). UV.x — номер травинки для изгиба в шейдере, UV2.x — порог
## поредения вдали (подложка уходит первой).
## Виды (CARPET_KINDS): луговая, сухая соломенная (тонкие высокие стебли), теневая (розетки широких листьев и мох),
## цветы (несколько стебельков с венчиками; цвет венчика — цвет экземпляра).
## far — дальняя форма: только травинки с порогом ниже CARPET_FAR_KEEP, те самые, что шейдер оставляет вдали,
## поэтому смена формы по расстоянию не видна.
enum { CARPET_MEADOW, CARPET_DRY, CARPET_SHADE, CARPET_FLOWERS, CARPET_STONES, CARPET_KINDS }
const CARPET_R := 0.5
const CARPET_FAR_KEEP := 0.45
## [высоких, коротких, высота от, высота до, полуширина от, полуширина до, наклон кончика, цвет корня, цвет кончика, доля соломенных]
const CARPET_SHAPES := [
	[48, 36, 0.10, 0.26, 0.016, 0.029, 0.55, Color(0.56, 0.66, 0.42), Color(1.0, 1.42, 0.86), 0.14],
	[40, 22, 0.14, 0.40, 0.008, 0.016, 0.75, Color(0.66, 0.62, 0.40), Color(1.5, 1.34, 0.82), 0.55],
	[26, 30, 0.05, 0.13, 0.034, 0.062, 1.5, Color(0.42, 0.56, 0.34), Color(0.86, 1.28, 0.74), 0.0],
]

static func build_carpet_mesh(kind := CARPET_MEADOW, far := false) -> ArrayMesh:
	if kind == CARPET_FLOWERS:
		return _carpet_flowers(far)
	if kind == CARPET_STONES:
		return _carpet_stones(far)
	var shape: Array = CARPET_SHAPES[kind]
	var tall_n: int = shape[0]
	var pile_n: int = shape[1]
	var blades := tall_n + pile_n
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in blades:
		var pile := k >= tall_n
		var n := k - tall_n if pile else k
		var total := pile_n if pile else tall_n
		var h1 := WGRandom.hash2(k, 3 + kind * 31, 701)
		var h2 := WGRandom.hash2(k, 5 + kind * 31, 703)
		var h3 := WGRandom.hash2(k, 7 + kind * 31, 707)
		var rank := 0.62 + 0.38 * h1 if pile else 0.1 + 0.62 * WGRandom.hash2(k, 11 + kind * 31, 709)
		if far and rank >= CARPET_FAR_KEEP + 0.1:
			continue
		# Равномерно по кругу (золотой угол); край куртинки рыхлый и уходит в соседние.
		var a := n * 2.39996 + h1 * 0.6 + (1.3 if pile else 0.0)
		var rr := sqrt((n + 0.5) / total)
		var r := CARPET_R * rr * (0.8 + 0.3 * h2)
		var foot := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var lean_a := a + (h3 - 0.5) * 2.6
		var lean := Vector3(cos(lean_a), 0.0, sin(lean_a))
		var side := Vector3(-lean.z, 0.0, lean.x)
		var h: float
		var width: float
		var tip: Vector3
		if pile:
			h = 0.04 + 0.05 * h2
			width = 0.03 + 0.018 * h1
			tip = foot + lean * h * 0.6 + Vector3.UP * h
			st.set_normal((Vector3.UP * 0.95 + lean * 0.3).normalized())
		else:
			# Короче у края, выше в середине: силуэт куртинки — пологий холмик.
			h = lerpf(shape[2], shape[3], h2) * (1.25 - 0.5 * rr)
			width = lerpf(shape[4], shape[5], h1)
			tip = foot + lean * h * shape[6] * (0.45 + h3) + Vector3.UP * h
			# Нормаль по наклону травинки: солнечная сторона куртинки светлее теневой.
			st.set_normal((Vector3.UP * 0.85 + lean * 0.5).normalized())
		var dry: bool = not pile and h3 > 1.0 - shape[9]
		var value := 0.8 + 0.45 * h1
		var root: Color = shape[7] * (0.9 if pile else 1.0)
		var top: Color = Color(1.45, 1.3, 0.78) if dry else shape[8] * (0.82 if pile else 1.0)
		for v: Vector3 in [foot - side * width, foot + side * width, tip]:
			st.set_color(root if v.y == 0.0 else top * value)
			st.set_uv(Vector2(float(k) / blades, v.y / h))
			st.set_uv2(Vector2(rank, 0.0))
			st.add_vertex(v)
	return st.commit()


## 15.11.2026: россыпь у дорожного полотна — горсть гранёных камней (или комьев: цвет даёт экземпляр) 10–30 см (с масштабом экземпляра).
## Настоящая геометрия поверх фактуры полотна: у камня есть силуэт, грани ловят свет, низ тёмный (тень у земли —
## теней от ковра нет). Раскладывает GroundCarpet по кромкам, обочинам и между колеями. Дальняя форма — половина камней.
static func _carpet_stones(far: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stones := 4 if far else 7
	for k in stones:
		var h1 := WGRandom.hash2(k, 51, 721)
		var h2 := WGRandom.hash2(k, 53, 723)
		var h3 := WGRandom.hash2(k, 57, 727)
		var a := k * 2.39996 + h1
		var r := 0.30 * sqrt((k + 0.5) / 7.0)
		var centre := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var w := 0.03 + 0.05 * h2 * h2
		var h := w * (0.55 + 0.6 * h3)
		var rank := 0.1 + 0.5 * h1
		var tone := 0.8 + 0.35 * h3
		var low: Array[Vector3] = []
		var mid: Array[Vector3] = []
		for n in 5:
			var b := n * TAU / 5.0 + h1 * 3.0
			var rr := w * (0.75 + 0.5 * WGRandom.hash2(k * 7 + n, 59, 729))
			low.append(centre + Vector3(cos(b) * rr, -0.01, sin(b) * rr * 0.8))
			mid.append(centre + Vector3(cos(b) * rr * 0.72, h * 0.62, sin(b) * rr * 0.58))
		var top := centre + Vector3((h1 - 0.5) * w * 0.5, h, (h2 - 0.5) * w * 0.5)
		var faces: Array = []
		for n in 5:
			var m := (n + 1) % 5
			faces.append([low[n], mid[n], mid[m]])
			faces.append([low[n], mid[m], low[m]])
			faces.append([mid[n], top, mid[m]])
		for face: Array in faces:
			var normal: Vector3 = (face[1] - face[0]).cross(face[2] - face[0]).normalized()
			if normal.dot(face[0] + face[1] + face[2] - centre * 3.0 + Vector3.UP * 0.01) < 0.0:
				normal = -normal
			for v: Vector3 in face:
				var lit := 0.62 if v.y < 0.0 else (0.95 if v.y < h * 0.9 else 1.12)
				st.set_normal(normal)
				st.set_color(Color(lit * tone, lit * tone, lit * tone))
				st.set_uv(Vector2(float(k) / stones, clampf(v.y / h, 0.0, 1.0)))
				st.set_uv2(Vector2(rank, 0.0))
				st.add_vertex(v)
	return st.commit()


## Цветы в ковре: стебельки с венчиком из двух скрещённых лепестков-ромбов. Венчик белый — красит цвет экземпляра,
## стебель тёмно-зелёный. Дальняя форма — половина стебельков.
static func _carpet_flowers(far: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stems := 8 # дальняя форма та же: стебельков мало
	for k in stems:
		var h1 := WGRandom.hash2(k, 41, 711)
		var h2 := WGRandom.hash2(k, 43, 713)
		var a := k * 2.39996 + h1
		var r := 0.38 * sqrt((k + 0.5) / 8.0)
		var foot := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var h := 0.13 + 0.14 * h2
		var lean := Vector3(cos(a * 1.7), 0.0, sin(a * 1.7)) * 0.04
		var top := foot + lean + Vector3.UP * h
		var side := Vector3(-sin(a), 0.0, cos(a))
		var rank := 0.1 + 0.4 * h1
		st.set_normal(Vector3.UP)
		for v: Vector3 in [foot - side * 0.006, foot + side * 0.006, top]:
			st.set_color(Color(0.22, 0.34, 0.14) if v.y < h else Color(0.3, 0.44, 0.2))
			st.set_uv(Vector2(float(k) / 8.0, v.y / h))
			st.set_uv2(Vector2(rank, 0.0))
			st.add_vertex(v)
		# Венчик: два ромба крест-накрест, чуть наклонены к зрителю сверху
		var size := 0.028 + 0.016 * h1
		for turn in 2:
			var u := side if turn == 0 else Vector3(side.z, 0.0, -side.x)
			var w := Vector3(side.z, 0.0, -side.x) if turn == 0 else side
			var quad := [top - u * size, top + w * size * 0.45 + Vector3.UP * size * 0.5, top + u * size, top - w * size * 0.45 + Vector3.UP * size * 0.5]
			for index in [0, 1, 2, 0, 2, 3]:
				st.set_color(Color(1.5, 1.5, 1.5))
				st.set_uv(Vector2(float(k) / 8.0, 1.0))
				st.set_uv2(Vector2(rank, 0.0))
				st.add_vertex(quad[index])
	return st.commit()


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
