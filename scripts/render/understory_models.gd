extends RefCounted
## 6.6: простые ближние растения. Цвета частей запечены в вершины.
## 8.2: мелкие цветы, высокая трава, молодые деревья и характеры леса.

enum { FERN, MOSS, MUSHROOM, HERB, GRASS, BUSH, SAPLING, PINE, FLOWERS, HIGH_GRASS, YOUNG, YOUNG_PINE, HAZEL_LOW, HAZEL, JUNIPER_LOW, JUNIPER, REED_GRASS, GREAT_FERN }
const BASE_COUNT := 12
const COUNT := 18
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
	var green := Color(0.34, 0.55, 0.22) # 9.4: светлее
	var bark := Color(0.35, 0.25, 0.14)
	var parts: Array = []
	# Перистые вайи: отдельные пары листочков вдоль шести дуг.
	for arm in 6:
		var a := arm * TAU / 6.0
		var forward := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a))
		for step in 5:
			var t := (step + 1) / 6.0
			var p := forward * t * 0.9 + Vector3.UP * sin(t * PI * 0.85) * 0.65 # 9.4: пышнее, как в лесах KCD
			for sign_side: float in [-1.0, 1.0]:
				var tip := p + side * sign_side * (1.0 - t) * 0.32 + forward * 0.1
				parts.append([p - forward * 0.09, tip, p + forward * 0.09])
	var fern := _leaves(parts, green)
	parts = []
	for arm in 7:
		var a := arm * TAU / 7.0
		var p := Vector3(cos(a), 0, sin(a)) * 0.1
		var tip := Vector3(cos(a) * 0.32, 0.18 + (arm % 3) * 0.06, sin(a) * 0.32)
		var side := Vector3(-sin(a), 0, cos(a)) * 0.09
		parts.append([p, tip + side, tip, tip - side])
	var herb := _leaves(parts, Color(0.4, 0.6, 0.26))
	parts = []
	for arm in 7:
		var a := arm * 2.4
		var side := Vector3(cos(a), 0, sin(a)) * 0.025
		var p := Vector3(sin(a), 0, cos(a)) * 0.16
		parts.append([p - side, p + side, p + Vector3(sin(a) * 0.23, 0.65 + (arm % 3) * 0.12, cos(a) * 0.23)])
	var tall_grass := _leaves(parts, Color(0.47, 0.57, 0.25))
	var moss := _colored([[Models._ico(0.5, 0.07, 1.0, 0.18, 0.8), Color(0.36, 0.5, 0.2)], [Models._moved(Models._ico(0.33, 0.06, 1.0, 0.2, 1.0), Vector3(0.35, 0, 0.2)), Color(0.42, 0.56, 0.23)]])
	var mushrooms: Array = []
	for k in 3:
		var offset := Vector3(k * 0.14, 0, sin(k * 2.0) * 0.15)
		var height := 0.14 + k * 0.035
		mushrooms.append([Models._moved(Models._cyl(0.025, 0.035, height, 5), offset), Color(0.77, 0.70, 0.53)])
		mushrooms.append([Models._moved(Models._ico(0.11, height, 1.0, 0.45, 1.0), offset), Color(0.48 + k * 0.05, 0.26, 0.12)])
	var bush := _crowned(Models._cyl(0.02, 0.035, 0.3, 4), bark, Vector3(0.15, 0.36, 0.05), Vector3(0.62, 0.38, 0.5), 120)
	var sapling := _crowned(Models._cyl(0.025, 0.055, 1.5, 5), bark, Vector3(0.05, 1.1, 0), Vector3(0.45, 0.55, 0.42), 80)
	var pine := _spruce(1.7, bark, 3, 0.55, 0.22, Color(0.3, 0.47, 0.29))
	# Мелкие цветы: розетка листьев и несколько головок на тонких стеблях.
	var flowers: Array = []
	for k in 5:
		var a := k * 2.4
		var p := Vector3(cos(a), 0, sin(a)) * (0.06 + k * 0.035)
		var head := 0.2 + (k % 3) * 0.07
		flowers.append([Models._moved(Models._cyl(0.006, 0.01, head, 3), p), Color(0.3, 0.5, 0.2)])
		var petal: Color = [Color(0.92, 0.88, 0.62), Color(0.75, 0.55, 0.85), Color(0.95, 0.95, 0.9)][k % 3]
		flowers.append([Models._moved(Models._ico(0.035, head, 1.0, 0.5, 1.0), p), petal])
	flowers.append([Models._ico(0.14, 0.02, 1.0, 0.25, 1.0), Color(0.3, 0.48, 0.2)])
	# Высокая трава до 1.3 м: густой пучок длинных листьев.
	parts = []
	for arm in 11:
		var a := arm * 2.4
		var side := Vector3(cos(a), 0, sin(a)) * 0.03
		var p := Vector3(sin(a), 0, cos(a)) * (0.05 + (arm % 4) * 0.05)
		parts.append([p - side, p + side, p + Vector3(sin(a) * 0.35, 1.0 + (arm % 3) * 0.15, cos(a) * 0.35)])
	var high_grass := _leaves(parts, Color(0.52, 0.58, 0.27))
	# Молодые деревья 3–3.5 м: второй ярус под пологом; проходимы, как кусты и подрост.
	var young := _crowned(Models._cyl(0.04, 0.08, 3.0, 6), Color(0.62, 0.6, 0.55), Vector3(0, 2.35, 0), Vector3(0.85, 1.05, 0.85), 180)
	# Молодая ель: узкие ярусы хвои, как у взрослых елей.
	var young_pine := _spruce(3.3, bark, 5, 0.75, 0.22, Color(0.25, 0.41, 0.27))
	return [fern, moss, _colored(mushrooms), herb, tall_grass, bush, sapling, pine, _colored(flowers), high_grass, young, young_pine,
		_hazel(1.7, 15601), _hazel(4.1, 15602), _juniper(1.25), _juniper(3.1), _reed_grass(), _great_fern()]


## 9.4: ёлочка из звёздчатых ярусов с поникшими лапами и вырезами между ними вместо гладких конусов.
## Концы лап светлее (молодая хвоя), нормали наружу и вверх — мягкий объём.
static func _spruce(height: float, bark: Color, tiers: int, r0: float, r1: float, needles: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
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
		for k in 18:
			var a := k * TAU / 18.0 + n * 0.9
			var reach := r * (1.0 if k % 2 == 0 else 0.6)
			rim.append(Vector3(cos(a) * reach, y - reach * 0.3, sin(a) * reach))
		for k in 18:
			for p: Vector3 in [apex, rim[k], rim[(k + 1) % 18]]:
				var out := Vector3(p.x, 0, p.z)
				st.set_normal((out.normalized() * 0.8 + Vector3.UP * 0.6).normalized() if out.length() > 0.01 else Vector3.UP)
				var light := 0.8 + 0.35 * out.length() / r
				st.set_color(Color(needles.r * light, needles.g * light, needles.b * light))
				st.add_vertex(p)
	return st.commit()


static func _colored(parts: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for entry: Array in parts:
		var part: Array = entry[0]
		var arrays: Array = part[0].surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(vertices.size()))
		var xf: Transform3D = part[1]
		for i in indices:
			st.set_color(entry[1])
			st.set_normal((xf.basis.inverse().transposed() * normals[i]).normalized())
			st.add_vertex(xf * vertices[i])
	return st.commit()


## 8.2: ствол и крона из отдельных листьев внутри эллипсоида: листва не гладкий шар, как у текстурных деревьев.
## Нормали от центра кроны дают объём, оттенок листьев немного гуляет.
static func _crowned(trunk: Array, bark: Color, center: Vector3, size: Vector3, count: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var arrays: Array = trunk[0].surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var xf: Transform3D = trunk[1]
	for i: int in arrays[Mesh.ARRAY_INDEX]:
		st.set_color(bark)
		st.set_normal(normals[i])
		st.add_vertex(xf * vertices[i])
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
		var side := Vector3(sin(n * 12.9898), cos(n * 78.233) * 0.6, sin(n * 37.719)).normalized() * 0.12
		var up := side.cross(Vector3(cos(n * 4.1), sin(n * 9.7), cos(n * 2.3))).normalized() * 0.14
		var shade := 0.8 + 0.4 * fmod(n * 0.381966, 1.0)
		st.set_color(Color(0.3 * shade, 0.46 * shade, 0.18 * shade))
		st.set_normal(normal)
		for q: Vector3 in [p - side, p + up, p + side, p - side, p + side, p - up * 0.8]:
			st.add_vertex(q)
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
static func weights(biome: int, moisture: float, light: float, canopy: float, ch := PackedFloat32Array([0.25, 0.25, 0.25, 0.25]), relict := 0.0, needles := 0.0) -> PackedFloat32Array:
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
	for k in BASE_COUNT:
		before += out[k]
		out[k] *= TEMPLATE[0][k] * ch[0] + TEMPLATE[1][k] * ch[1] + TEMPLATE[2][k] * ch[2] + TEMPLATE[3][k] * ch[3]
		after += out[k]
	for k in BASE_COUNT:
		out[k] *= before / maxf(after, 0.0001)
	# Чаща не ждёт просветов: подрост и кусты стоят стеной и под пологом.
	var thicket := ch[THICKET]
	out[BUSH] += thicket * 0.45
	out[SAPLING] += thicket * (0.08 if conifer else 0.3)
	out[PINE] += thicket * (0.3 if conifer else 0.08)
	out[YOUNG] += thicket * (0.04 if conifer else 0.14)
	out[YOUNG_PINE] += thicket * (0.14 if conifer else 0.04)
	var old_total := 0.0
	for value in out: old_total += value
	out.resize(COUNT)
	var middle := middle_strength(relict, canopy)
	if middle > 0.0:
		var balance := PackedFloat32Array([
			(0.5 + wet * 0.5) * (1.0 - needles * 0.65),
			(0.35 + wet * 0.8) * (1.0 - needles * 0.8),
			(0.6 + needles * 0.8) * (1.0 - wet * 0.35),
			(0.35 + needles) * (1.0 - wet * 0.5),
			0.45 + light * 0.65 + needles * 0.25,
			wet * shade * (1.2 - needles * 0.55),
		])
		var sum := 0.0
		for value in balance: sum += value
		for k in BASE_COUNT: out[k] *= 1.0 - middle * 0.45
		for k in balance.size(): out[BASE_COUNT + k] = old_total * middle * 0.9 * balance[k] / maxf(sum, 0.001)
	return out


static func is_middle(kind: int) -> bool:
	return kind >= HAZEL_LOW and kind <= GREAT_FERN


static func is_shrub(kind: int) -> bool:
	return kind >= HAZEL_LOW and kind <= JUNIPER


static func middle_strength(relict: float, canopy: float) -> float:
	return clampf(relict, 0.0, 1.0) * smoothstep(0.25, 0.8, canopy)


## Shared wind shader: stiffer woody stems, lighter fronds and long grass blades.
static func middle_wind(kind: int) -> Array:
	if kind in [JUNIPER_LOW, JUNIPER]: return [0.11, 0.018, 0.8, 0.75, 0.18]
	if kind in [HAZEL_LOW, HAZEL]: return [0.19, 0.035, 0.7, 0.72, 0.28]
	if kind == GREAT_FERN: return [0.21, 0.045, 1.15, 0.75, 0.3]
	return [0.25, 0.055, 1.45, 0.8, 0.3]


## Indexed plant meshes with the project's native LOD importer; stable UV/normal/color layout.
static func _middle_mesh(source: ArrayMesh) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.create_from(source, 0)
	st.index()
	var arrays := st.commit_to_arrays()
	if arrays[Mesh.ARRAY_TEX_UV] == null:
		var uv := PackedVector2Array()
		for p: Vector3 in arrays[Mesh.ARRAY_VERTEX]: uv.append(Vector2(p.x * 0.5, p.y * 0.5))
		arrays[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return Models._with_lods(mesh)


static func _leaf(st: SurfaceTool, center: Vector3, along: Vector3, width: float, color: Color) -> void:
	var side := along.cross(Vector3.UP).normalized() * width
	if side.length_squared() < 0.00001: side = Vector3.RIGHT * width
	var points := [center - along * 0.45, center + side + Vector3.UP * width * 0.4, center + along * 0.55 + Vector3.UP * width * 0.25, center - side - Vector3.UP * width * 0.15]
	var normal := (side.cross(along).normalized() + Vector3.UP * 0.35).normalized()
	if normal.y < 0: normal = -normal
	var uv := [Vector2(0.5, 1), Vector2(0, 0.5), Vector2(0.5, 0), Vector2(1, 0.5)]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_color(color)
		st.set_normal(normal)
		st.set_uv(uv[i])
		st.add_vertex(points[i])


## Multi-stem hazel: bowed canes and leaves distributed along branching twigs, not a solid ball.
static func _hazel(height: float, seed_num: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_num
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bark := Color("796443")
	var rings := 6 if height < 2.0 else 8
	for stem in (4 if height < 2.0 else 6):
		var a := stem * 2.399 + rng.randf_range(-0.2, 0.2)
		var direction := Vector3(cos(a), 0, sin(a))
		var path: Array[Vector3] = []
		var top := height * rng.randf_range(0.82, 1.0)
		for i in rings + 1:
			var t := float(i) / rings
			path.append(direction * (0.08 + pow(t, 1.5) * height * 0.22) + Vector3.UP * top * t)
		ForestModels._tube(st, [path, height * 0.012, 0.006, bark, false], 4, true)
		for i in range(3, rings + 1):
			var t := float(i) / rings
			var out := direction.rotated(Vector3.UP, -0.65 if i % 2 else 0.65)
			var end := path[i] + out * height * (0.14 - t * 0.065) + Vector3.UP * 0.08
			ForestModels._tube(st, [[path[i], end], 0.014, 0.003, bark, false], 3, true)
			for leaf in 5:
				var p := path[i].lerp(end, 0.3 + leaf * 0.16)
				var axis := out.rotated(Vector3.UP, -0.8 if leaf % 2 else 0.8) * (0.18 + height * 0.035) + Vector3.UP * (0.1 + height * 0.025)
				_leaf(st, p, axis, 0.08 + height * 0.014, Color(0.4 + t * 0.08, 0.56 + t * 0.09, 0.23))
	return _middle_mesh(st.commit())


## Juniper grows as several unequal evergreen shoots; low spreading and taller columnar forms.
static func _juniper(height: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for shoot in 4:
		var a := shoot * 2.399
		var h := height * (0.7 + shoot * 0.1)
		var mesh := _spruce(h, Color("6e624b"), 5, height * 0.24, 0.08, Color("557449"))
		st.append_from(mesh, 0, Transform3D(Basis.IDENTITY, Vector3(cos(a), 0, sin(a)) * height * 0.12))
	return _middle_mesh(st.commit())


## Curved ribbon blades, with joints along their height so wind bends the whole tuft.
static func _reed_grass() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade in 16:
		var a := blade * 2.399
		var direction := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a))
		var height := 2.0 + (blade % 5) * 0.14
		for joint in 7:
			for corner: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 0), Vector2i(1, 1), Vector2i(0, 1)]:
				var t := (joint + corner.x) / 7.0
				var center := direction * (0.12 + 0.7 * t * t) + Vector3.UP * height * (t - 0.15 * pow(t, 4))
				var width := 0.06 * (1.0 - t * 0.93)
				st.set_normal((Vector3.UP * 0.35 - direction).normalized())
				st.set_color(Color(0.38 + t * 0.12, 0.5 + t * 0.1, 0.22))
				st.set_uv(Vector2(corner.y, t))
				st.add_vertex(center + side * (corner.y * 2.0 - 1.0) * width)
	return _middle_mesh(st.commit())


## Large fern clump: arched rachises with paired pinnae; lower than the hazel/juniper canopy.
static func _great_fern() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for frond in 8:
		var a := frond * 2.399
		var forward := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a))
		var path: Array[Vector3] = []
		for step in 9:
			var t := step / 8.0
			path.append(forward * (0.05 + t * 1.35) + Vector3.UP * (0.02 + sin(t * PI * 0.85) * (2.05 + frond % 3 * 0.1)))
		ForestModels._tube(st, [path, 0.015, 0.004, Color("617d36"), false], 3, true)
		for step in range(2, 9):
			var t := step / 8.0
			for sign_side: float in [-1.0, 1.0]:
				var reach := 0.5 * (1.0 - t * 0.8)
				_leaf(st, path[step] + side * sign_side * reach * 0.5, side * sign_side * reach + forward * 0.12 + Vector3.UP * 0.12 * (1.0 - t),
					0.1 * (1.0 - t * 0.5), Color(0.33 + t * 0.08, 0.52 + t * 0.09, 0.23))
	return _middle_mesh(st.commit())
