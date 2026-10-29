extends RefCounted
## 6.6: простые ближние растения. Цвета частей запечены в вершины.
## 8.2: мелкие цветы, высокая трава, молодые деревья и характеры леса.
## UV2.x — ранг удаления отдельного листа вдали; жилки, стебли и сплошные лапы имеют ранг 0.

enum { FERN, MOSS, MUSHROOM, HERB, GRASS, BUSH, SAPLING, PINE, FLOWERS, HIGH_GRASS, YOUNG, YOUNG_PINE }
const COUNT := 12
## Характер леса: светлый (просветы, трава и цветы), тёмный (сомкнутый, чаще хвойный: мох и грибы),
## чаща (молодой участок: кусты и подрост стеной), папоротниковый (влажная тень).
enum { LIGHT, DARK, THICKET, FERNY }
# Множитель веса каждой формы для каждого характера, порядок как в enum форм.
const TEMPLATE := [
	[0.6, 0.4, 0.3, 1.4, 2.2, 1.2, 0.6, 0.6, 1.0, 1.0, 0.5, 0.4],
	[1.0, 1.7, 1.9, 0.5, 0.12, 0.45, 0.3, 0.5, 0.0, 0.0, 0.0, 0.6],
	[0.7, 0.5, 0.4, 0.8, 0.5, 3.2, 3.0, 3.0, 0.2, 0.3, 1.0, 1.0],
	[3.2, 1.2, 0.8, 0.8, 0.5, 0.6, 0.6, 0.6, 0.2, 0.3, 0.3, 0.3],
]
const DENSITY := [1.0, 0.8, 1.6, 1.4] # доля занятых мест подлеска (9.4: гуще, как в лесах KCD и Valheim)
const LOW_GRASS := [1.5, 0.3, 0.55, 0.7] # множитель низкой травы
const DEADWOOD := [0.7, 1.5, 0.9, 1.1]   # множитель валежника и сухостоя: в тёмном старом лесу его больше


static func meshes() -> Array[Mesh]:
	return preload("res://scripts/render/asset_catalog.gd").get_catalog().understory.duplicate()


static func build_meshes() -> Array[Mesh]:
	var green := Color(0.3, 0.47, 0.23)
	var bark := Color(0.35, 0.25, 0.14)
	var parts: Array = []
	var stalks: Array = []
	# Перистые вайи: отдельные пары листочков вдоль шести дуг.
	for arm in 6:
		var a := arm * TAU / 6.0
		var forward := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a))
		for step in 5:
			var t := (step + 1) / 6.0
			var p := _fern_point(t, forward)
			for sign_side: float in [-1.0, 1.0]:
				var tip := p + side * sign_side * (1.0 - t) * 0.32 + forward * 0.1
				parts.append([p - forward * 0.09, tip, p + forward * 0.09])
		# Листочки лежат на той же ломаной дуге, что и центральная жилка.
		for segment in 3:
			var start := _fern_point(segment / 3.0, forward)
			var end := _fern_point((segment + 1) / 3.0, forward)
			stalks.append([start - side * 0.009, start + side * 0.009, end + side * 0.006, end - side * 0.006])
	var persistent_from := parts.size()
	parts.append_array(stalks)
	var fern := _leaves(parts, green, persistent_from)
	parts = []
	for arm in 7:
		var a := arm * TAU / 7.0
		var p := Vector3(cos(a), 0, sin(a)) * 0.1
		var tip := Vector3(cos(a) * 0.32, 0.18 + (arm % 3) * 0.06, sin(a) * 0.32)
		var side := Vector3(-sin(a), 0, cos(a)) * 0.09
		var middle := p.lerp(tip, 0.6)
		parts.append([p, middle + side, tip, middle - side])
	var herb := _leaves(parts, Color(0.32, 0.46, 0.22))
	parts = []
	for arm in 7:
		var a := arm * 2.4
		var side := Vector3(cos(a), 0, sin(a)) * 0.025
		var p := Vector3(sin(a), 0, cos(a)) * 0.16
		parts.append([p - side, p + side, p + Vector3(sin(a) * 0.23, 0.65 + (arm % 3) * 0.12, cos(a) * 0.23)])
	var tall_grass := _leaves(parts, Color(0.47, 0.57, 0.25))
	var moss := _colored([[_mound(0.5, 0.07, 1.0, 0.18, 0.8), Color(0.36, 0.5, 0.2)], [Models._moved(_mound(0.33, 0.06, 1.0, 0.2, 1.0), Vector3(0.35, 0, 0.2)), Color(0.42, 0.56, 0.23)]])
	var mushrooms: Array = []
	for k in 3:
		var offset := Vector3(k * 0.14, 0, sin(k * 2.0) * 0.15)
		var height := 0.14 + k * 0.035
		mushrooms.append([Models._moved(Models._cyl(0.025, 0.035, height, 5), offset), Color(0.77, 0.70, 0.53)])
		mushrooms.append([Models._moved(_mound(0.11, height, 1.0, 0.45, 1.0), offset), Color(0.48 + k * 0.05, 0.26, 0.12)])
	var bush := _crowned(Models._cyl(0.02, 0.035, 0.3, 4), bark, Vector3(0.15, 0.36, 0.05), Vector3(0.62, 0.38, 0.5), 72)
	var sapling := _crowned(Models._cyl(0.025, 0.055, 1.5, 5), bark, Vector3(0.05, 1.1, 0), Vector3(0.45, 0.55, 0.42), 48)
	var pine := _spruce(1.7, bark, 3, 0.55, 0.22, Color(0.3, 0.47, 0.29))
	# Мелкие цветы: розетка листьев и несколько головок на тонких стеблях.
	var flowers: Array = []
	for k in 5:
		var a := k * 2.4
		var p := Vector3(cos(a), 0, sin(a)) * (0.06 + k * 0.035)
		var head := 0.2 + (k % 3) * 0.07
		flowers.append([Models._moved(Models._cyl(0.006, 0.01, head, 3), p), Color(0.3, 0.5, 0.2)])
		var petal: Color = [Color(0.92, 0.88, 0.62), Color(0.75, 0.55, 0.85), Color(0.95, 0.95, 0.9)][k % 3]
		flowers.append([Models._moved(_blossom(0.048, head), p), petal])
	flowers.append([_mound(0.14, 0.02, 1.0, 0.25, 1.0), Color(0.3, 0.48, 0.2)])
	# Высокая трава до 1.3 м: густой пучок длинных листьев.
	parts = []
	for arm in 11:
		var a := arm * 2.4
		var side := Vector3(cos(a), 0, sin(a)) * 0.03
		var p := Vector3(sin(a), 0, cos(a)) * (0.05 + (arm % 4) * 0.05)
		parts.append([p - side, p + side, p + Vector3(sin(a) * 0.35, 1.0 + (arm % 3) * 0.15, cos(a) * 0.35)])
	var high_grass := _leaves(parts, Color(0.52, 0.58, 0.27))
	# Молодые деревья 3–3.5 м: второй ярус под пологом; проходимы, как кусты и подрост.
	var young := _crowned(Models._cyl(0.04, 0.08, 3.0, 6), Color(0.62, 0.6, 0.55), Vector3(0, 2.35, 0), Vector3(0.85, 1.05, 0.85), 108)
	# Молодая ель: узкие ярусы хвои, как у взрослых елей.
	var young_pine := _spruce(3.3, bark, 5, 0.75, 0.22, Color(0.25, 0.41, 0.27))
	return [fern, moss, _colored(mushrooms), herb, tall_grass, bush, sapling, pine, _colored(flowers), high_grass, young, young_pine]


## Маленькие объёмы не требуют сферы на сотню треугольников.
static func _mound(r: float, y: float, sx := 1.0, sy := 1.0, sz := 1.0) -> Array:
	var mesh := SphereMesh.new()
	mesh.radius = r
	mesh.height = r * 2.0
	mesh.radial_segments = 8
	mesh.rings = 1
	return [mesh, Transform3D(Basis().scaled(Vector3(sx, sy, sz)), Vector3(0, y, 0))]


static func _fern_point(t: float, forward: Vector3) -> Vector3:
	var path: Array[Vector3] = [Vector3.ZERO, forward * 0.3 + Vector3.UP * 0.5,
		forward * 0.6 + Vector3.UP * 0.64, forward * 0.9 + Vector3.UP * 0.24]
	var at := clampf(t, 0, 1) * 3.0
	var segment := mini(2, floori(at))
	return path[segment].lerp(path[segment + 1], at - segment)


## Цветочная головка с пятью лепестками вместо почти невидимого многогранного шара.
static func _blossom(radius: float, y: float) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for k in 10:
		for v: int in [-1, k, k + 1]:
			var a := v * TAU / 10.0
			var r := radius * (1.0 if v % 2 == 0 else 0.55)
			st.add_vertex(Vector3(0, 0.006, 0) if v == -1 else Vector3(cos(a) * r, 0, sin(a) * r))
	st.index()
	return [st.commit(), Transform3D(Basis.IDENTITY, Vector3(0, y, 0))]


## 9.4: ёлочка из звёздчатых ярусов с поникшими лапами и вырезами между ними вместо гладких конусов.
## Концы лап светлее (молодая хвоя), нормали наружу и вверх — мягкий объём.
static func _spruce(height: float, bark: Color, tiers: int, r0: float, r1: float, needles: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_uv2(Vector2.ZERO)
	var trunk := Models._cyl(0.025, 0.06 * height / 1.7, height, 5)
	var arrays: Array = trunk[0].get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i: int in arrays[Mesh.ARRAY_INDEX]:
		st.set_color(bark)
		st.set_normal(normals[i])
		st.add_vertex(trunk[1] * vertices[i])
	var step := (height - 0.35) / tiers
	for n in tiers:
		var t := n / maxf(1.0, tiers - 1.0)
		var y := 0.3 + n * step
		var r := lerpf(r0, r1, t)
		var apex := Vector3(0, y + step * 1.5, 0)
		var rim: Array[Vector3] = []
		for k in 12:
			var a := k * TAU / 12.0 + n * 0.9
			var reach := r * (1.0 if k % 2 == 0 else 0.6)
			rim.append(Vector3(cos(a) * reach, y - reach * 0.3, sin(a) * reach))
		for k in 12:
			# Сплошные лапы сохраняются целиком: удаление отдельных граней оставляет дыры.
			st.set_uv2(Vector2.ZERO)
			for p: Vector3 in [apex, rim[k], rim[(k + 1) % 12]]:
				var out := Vector3(p.x, 0, p.z)
				st.set_normal((out.normalized() * 0.8 + Vector3.UP * 0.6).normalized() if out.length() > 0.01 else Vector3.UP)
				var light := 0.8 + 0.35 * out.length() / r
				st.set_color(Color(needles.r * light, needles.g * light, needles.b * light))
				st.add_vertex(p)
	st.index()
	return st.commit()


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
		var normal_basis := xf.basis.inverse().transposed()
		for i in indices:
			st.set_color(entry[1])
			st.set_normal((normal_basis * normals[i]).normalized())
			st.add_vertex(xf * vertices[i])
	st.index()
	return st.commit()


## 8.2: ствол и крона из отдельных листьев внутри эллипсоида: листва не гладкий шар, как у текстурных деревьев.
## Нормали от центра кроны дают объём, оттенок листьев немного гуляет.
static func _crowned(trunk: Array, bark: Color, center: Vector3, size: Vector3, count: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_uv2(Vector2.ZERO)
	var arrays: Array = trunk[0].surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var xf: Transform3D = trunk[1]
	for i: int in arrays[Mesh.ARRAY_INDEX]:
		st.set_color(bark)
		st.set_normal(normals[i])
		st.add_vertex(xf * vertices[i])
	# Три несущих побега выходят из ствола в разные доли кроны.
	var top: float = (xf * trunk[0].get_aabb()).end.y
	for branch in 3:
		var a := branch * 2.39996 + 0.7
		var end := center + Vector3(cos(a) * size.x * 0.52, size.y * (0.1 + branch * 0.15), sin(a) * size.z * 0.52)
		var start := Vector3(0, top * (0.15 if top < 0.6 else 0.48), 0)
		var delta := end - start
		var limb := Models._cyl(0.006, 0.018 if top < 0.6 else 0.025, delta.length(), 3)
		var at: Transform3D = Transform3D(Basis(Quaternion(Vector3.UP, delta.normalized())), start) * limb[1]
		var data: Array = limb[0].surface_get_arrays(0)
		for i: int in data[Mesh.ARRAY_INDEX]:
			st.set_color(bark)
			st.set_normal((at.basis * data[Mesh.ARRAY_NORMAL][i]).normalized())
			st.add_vertex(at * data[Mesh.ARRAY_VERTEX][i])
	# Несколько комков листвы со сдвигами: неровный силуэт. Лист повёрнут как угодно,
	# а нормаль смотрит от центра кроны — освещение объёмное, без чешуи на поверхности.
	for n in count:
		var clump := n % 6
		var ca := clump * 2.39996 + 0.7
		var off := Vector3(cos(ca) * 0.45, 0.25 * sin(clump * 1.7) + (0.35 if clump == 0 else 0.0), sin(ca) * 0.45) * size
		if clump == 0:
			off.x = 0.0
			off.z = 0.0
		var u := fmod(n * 0.618034, 1.0)
		var v := fmod(n * 0.754878, 1.0)
		var r := pow(fmod(n * 0.569840, 1.0), 0.4) * 0.6
		var dir := Vector3(sqrt(1.0 - (2.0 * v - 1.0) ** 2) * cos(u * TAU), 2.0 * v - 1.0, sqrt(1.0 - (2.0 * v - 1.0) ** 2) * sin(u * TAU))
		var p := center + off + dir * size * r
		var normal := ((p - center) / size + Vector3.UP * 0.35).normalized()
		var leaf_size := 0.85 + 0.35 * fposmod(n * 0.569840, 1.0)
		var side := Vector3(sin(n * 12.9898), cos(n * 78.233) * 0.6, sin(n * 37.719)).normalized() * 0.14 * leaf_size
		var up := side.cross(Vector3(cos(n * 4.1), sin(n * 9.7), cos(n * 2.3))).normalized() * 0.17 * leaf_size
		var shade := 0.8 + 0.4 * fmod(n * 0.381966, 1.0)
		st.set_color(Color(0.3 * shade, 0.46 * shade, 0.18 * shade))
		st.set_normal(normal)
		st.set_uv2(Vector2(fposmod(n * 0.754878, 1.0), 0))
		for q: Vector3 in [p - side, p + up, p + side, p - side, p + side, p - up * 0.8]:
			st.add_vertex(q)
	st.index()
	return st.commit()


static func _leaves(leaves: Array, color: Color, persistent_from := -1) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for n in leaves.size():
		var leaf: Array = leaves[n]
		var low := INF
		var high := -INF
		for p: Vector3 in leaf:
			low = minf(low, p.y)
			high = maxf(high, p.y)
		var normal: Vector3 = (leaf[1] - leaf[0]).cross(leaf[2] - leaf[0]).normalized()
		if normal.y < 0.0:
			normal = -normal
		st.set_normal((normal * 0.35 + Vector3.UP * 0.65).normalized())
		st.set_uv2(Vector2(0.0 if persistent_from >= 0 and n >= persistent_from else fposmod(n * 0.754878, 1.0), 0))
		for i in range(1, leaf.size() - 1):
			for v: Vector3 in [leaf[0], leaf[i], leaf[i + 1]]:
				var progress := (v.y - low) / maxf(0.001, high - low)
				var shade := lerpf(0.82, 1.06, progress) + 0.04 * sin(n * 2.4)
				st.set_color(Color(color.r * shade, color.g * shade, color.b * shade))
				st.set_uv(Vector2(float(n) / maxf(1, leaves.size()), progress))
				st.add_vertex(v)
	st.index()
	return st.commit()


## Доли четырёх характеров (сумма 1). canopy — полог, conifer — доля хвои, sun — освещённость склона,
## age — возраст участка (тот же шум, что у размеров деревьев): молодые участки зарастают чащей.
static func character(canopy: float, conifer: float, moisture: float, sun: float, age: float) -> PackedFloat32Array:
	var wet := smoothstep(0.3, 0.85, moisture)
	var shade := 1.0 - sun * (1.0 - canopy * 0.85)
	var out := PackedFloat32Array([
		sun * (1.25 - canopy) * (1.0 - 0.6 * conifer) * (0.5 + 0.5 * age),
		canopy * canopy * (0.3 + 0.7 * conifer) * (0.4 + 0.6 * age) * (1.2 - 0.5 * sun),
		smoothstep(0.35, 0.05, age) * (0.4 + canopy) * (0.6 + 0.4 * moisture),
		wet * shade * (1.0 - 0.6 * conifer),
	])
	# Квадрат делает господствующий характер заметным, переходы остаются плавными.
	var total := 0.0
	for c in 4:
		out[c] = out[c] * out[c] + 0.002
		total += out[c]
	for c in 4:
		out[c] /= total
	return out


static func mix(table: Array, ch: PackedFloat32Array) -> float:
	var v := 0.0
	for c in 4:
		v += ch[c] * table[c]
	return v


## Накопленные веса: влажная тень — мох/грибы, просветы — трава/кусты/молодняк.
## ch — доли характеров; без них лес смешанный.
static func weights(biome: int, moisture: float, light: float, canopy: float, ch := PackedFloat32Array([0.25, 0.25, 0.25, 0.25])) -> PackedFloat32Array:
	var shade := 1.0 - light
	var wet := smoothstep(0.25, 0.8, moisture)
	var conifer := biome == Biomes.TAIGA
	var out := PackedFloat32Array([
		wet * shade * (0.7 if conifer else 1.2),
		wet * shade * (1.6 if conifer else 1.0),
		wet * shade * canopy * 0.28,
		0.18 + wet * 0.45,
		0.15 + light * 0.8,
		light * 0.22,
		light * canopy * (0.035 if conifer else 0.14),
		light * canopy * (0.16 if conifer else 0.025),
		light * (1.0 - canopy) * 0.35,
		light * (1.0 - canopy * 0.7) * 0.3,
		canopy * (0.02 if conifer else 0.07),
		canopy * (0.07 if conifer else 0.015),
	])
	# Характер меняет состав, а не долю растений рядом с подстилкой: её задаёт DENSITY.
	var before := 0.0
	var after := 0.0
	for k in COUNT:
		before += out[k]
		out[k] *= TEMPLATE[0][k] * ch[0] + TEMPLATE[1][k] * ch[1] + TEMPLATE[2][k] * ch[2] + TEMPLATE[3][k] * ch[3]
		after += out[k]
	for k in COUNT:
		out[k] *= before / maxf(after, 0.0001)
	# Чаща не ждёт просветов: подрост и кусты стоят стеной и под пологом.
	var thicket := ch[THICKET]
	out[BUSH] += thicket * 0.45
	out[SAPLING] += thicket * (0.08 if conifer else 0.3)
	out[PINE] += thicket * (0.3 if conifer else 0.08)
	out[YOUNG] += thicket * (0.04 if conifer else 0.14)
	out[YOUNG_PINE] += thicket * (0.14 if conifer else 0.04)
	return out
