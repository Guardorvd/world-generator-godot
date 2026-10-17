class_name WaterBuilder
extends RefCounted
## Вода: океан, озёра (каждое на своём уровне) и реки-ленты. Копия js/render3d/water.js.

const TILE := GameConfig.TILE
const HS := GameConfig.HS


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


static func _flat_mesh(pos: PackedVector3Array, mat: Material, node_name: String) -> MeshInstance3D:
	if pos.is_empty():
		return null
	var nor := PackedVector3Array()
	nor.resize(pos.size())
	nor.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	return mi


## Озёра: квадрат воды на уровне озера над каждой клеткой озера и её сухими соседями (чтобы закрыть берег)
static func _lake_mesh(w: WorldData, mat: Material) -> MeshInstance3D:
	var W := w.W
	var H := w.H
	var level := PackedFloat32Array()
	level.resize(w.N)
	level.fill(-INF)
	for j in H:
		for i in W:
			var k := j * W + i
			if w.lake[k] == 0:
				continue
			var l := w.filled[k] * HS
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var ni := i + di
					var nj := j + dj
					if ni < 0 or nj < 0 or ni >= W or nj >= H:
						continue
					var n := nj * W + ni
					if w.ocean[n] != 0:
						continue
					if w.lake[n] != 0 and n != k:
						continue
					if l > level[n]:
						level[n] = l
	var pos := PackedVector3Array()
	for j in H:
		for i in W:
			var y := level[j * W + i]
			if y == -INF:
				continue
			var x0 := i * TILE
			var x1 := (i + 1) * TILE
			var z0 := j * TILE
			var z1 := (j + 1) * TILE
			pos.append_array([Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1)])
	return _flat_mesh(pos, mat, "Lakes")


## Реки: ленты вдоль средних линий из Heightfield.ribbons
static func _river_mesh(ribbons: Array, mat: Material) -> MeshInstance3D:
	var pos := PackedVector3Array()
	for pts in ribbons:
		var L: Array[Vector3] = []
		var R: Array[Vector3] = []
		var n: int = pts.size()
		for k in n:
			var a: Dictionary = pts[maxi(0, k - 1)]
			var b: Dictionary = pts[mini(n - 1, k + 1)]
			var dx: float = b.x - a.x
			var dz: float = b.z - a.z
			var ln := Grid.hypot(dx, dz)
			if ln == 0.0:
				ln = 1.0
			dx /= ln
			dz /= ln
			var p: Dictionary = pts[k]
			L.append(Vector3(p.x - dz * p.w, p.y, p.z + dx * p.w))
			R.append(Vector3(p.x + dz * p.w, p.y, p.z - dx * p.w))
		for k in n - 1:
			pos.append_array([L[k], R[k], L[k + 1], L[k + 1], R[k], R[k + 1]])
	return _flat_mesh(pos, mat.duplicate(), "Rivers")
