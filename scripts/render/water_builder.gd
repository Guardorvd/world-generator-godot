class_name WaterBuilder
extends RefCounted
## Вода: океан, озёра (каждое на своём уровне) и реки-ленты. Копия js/render3d/water.js.

const TILE := GameConfig.TILE
const HS := GameConfig.HS
const LAKE_DROP := 0.1   # м, см. _lake_mesh


static func _material(color: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.15
	m.metallic_specular = 0.6
	return m


## Узлы воды: океан, озёра, реки (озёр и рек может не быть). Узлы не в дереве сцены,
## поэтому их можно собирать в фоновом потоке
static func build(w: WorldData, heights: Heightfield) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var water_mat := _material(Color8(0x4f, 0x9c, 0xcc), 0.85)
	var ocean_mat := _material(Color8(0x24, 0x60, 0x9a), 0.88)
	var plane := PlaneMesh.new()
	plane.size = Vector2(w.W * TILE + 16000.0, w.H * TILE + 16000.0)
	plane.material = ocean_mat
	var ocean := MeshInstance3D.new()
	ocean.name = "Ocean"
	ocean.mesh = plane
	ocean.position = Vector3(w.W * TILE / 2.0, 0.0, w.H * TILE / 2.0)
	out.append(ocean)
	var lakes := _lake_mesh(w, water_mat)
	if lakes:
		out.append(lakes)
	var rivers := _river_mesh(heights.ribbons, water_mat)
	if rivers:
		out.append(rivers)
	return out


## Меш из вершин pos с общим материалом. idx — необязательный индексный буфер (по две клетки на
## четыре вершины экономят память); без него вершины идут тройками
static func _flat_mesh(pos: PackedVector3Array, mat: Material, node_name: String, idx: PackedInt32Array = PackedInt32Array()) -> MeshInstance3D:
	if pos.is_empty():
		return null
	var nor := PackedVector3Array()
	nor.resize(pos.size())
	nor.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	if not idx.is_empty():
		arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	return mi


## Озёра: ровная вода на уровне озера над каждой ячейкой сетки рельефа (вершины в центрах клеток), у которой
## хоть одна вершина в озере. Рельеф в ячейке — те же треугольники, поэтому берег — линия, где земля
## поднимается над водой, а не край квадрата клетки. До 1.9.9 вода лежала квадратами клеток и на пологих
## берегах равнин стояла над землёй прямоугольниками. Вода на LAKE_DROP ниже уровня: засыпанные мелкие
## впадины у озера лежат ровно на его уровне, и в одной плоскости с ними вода просвечивала бы сквозь землю
static func _lake_mesh(w: WorldData, mat: Material) -> MeshInstance3D:
	var W := w.W
	var H := w.H
	var pos := PackedVector3Array()
	var idx := PackedInt32Array()
	var lake := w.lake
	var filled := w.filled
	for j in H - 1:
		for i in W - 1:
			var a := j * W + i
			if lake[a] == 0 and lake[a + 1] == 0 and lake[a + W] == 0 and lake[a + W + 1] == 0:
				continue
			var y := -INF
			for k in [a, a + 1, a + W, a + W + 1]:
				if lake[k] != 0:
					y = maxf(y, filled[k] * HS - LAKE_DROP)
			var x0 := (i + 0.5) * TILE
			var x1 := (i + 1.5) * TILE
			var z0 := (j + 0.5) * TILE
			var z1 := (j + 1.5) * TILE
			var v := pos.size()
			pos.append_array([Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1)])
			idx.append_array([v, v + 1, v + 2, v, v + 2, v + 3])
	return _flat_mesh(pos, mat, "Lakes", idx)


## Реки: ленты вдоль средних линий из Heightfield.ribbons
static func _river_mesh(ribbons: Array, mat: Material) -> MeshInstance3D:
	var pos := PackedVector3Array()
	for pts in ribbons:
		var n: int = pts.size()
		if n < 2:
			continue # одна точка ленты не даёт ни одной полосы
		var L: Array[Vector3] = []
		var R: Array[Vector3] = []
		# направление поперёк ленты; если соседние точки совпадают (нулевой отрезок), берём прошлое
		var dx := 1.0
		var dz := 0.0
		for k in n:
			var a: Dictionary = pts[maxi(0, k - 1)]
			var b: Dictionary = pts[mini(n - 1, k + 1)]
			var ex: float = b.x - a.x
			var ez: float = b.z - a.z
			var ln := Grid.hypot(ex, ez)
			if ln > 0.000001:
				dx = ex / ln
				dz = ez / ln
			var p: Dictionary = pts[k]
			L.append(Vector3(p.x - dz * p.w, p.y, p.z + dx * p.w))
			R.append(Vector3(p.x + dz * p.w, p.y, p.z - dx * p.w))
		for k in n - 1:
			pos.append_array([L[k], R[k], L[k + 1], L[k + 1], R[k], R[k + 1]])
	return _flat_mesh(pos, mat, "Rivers")
