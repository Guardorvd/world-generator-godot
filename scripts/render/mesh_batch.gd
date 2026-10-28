class_name MeshBatch
extends RefCounted
## Много неподвижных одинаковых по материалу деталей (дома, мосты, туннели) в одном меше: по поверхности
## на материал. Каждый MeshInstance3D — отдельный вызов отрисовки, а деталей у мостов и домов тысячи.
## С 1.9.9: у мира 768 с длинными мостами их было больше тысячи на кадр.
## С 9.8 детали собираются по квадратам мира CELL: когда поселения стоят по всему плану, один меш на весь мир
## никогда не отсекался камерой и рисовал все дома мира (с тенями) в каждом кадре.

const CELL := 256.0   # сторона квадрата, м
const SEEN := 1400.0  # дальше центра квадрата не рисуется: туман на 900 м уже скрывает больше 80 % цвета

var _tools: Dictionary = {} # world square -> material -> CPU arrays
var _geometry := {} # one CPU read per primitive, not one render-server read per house detail


## Cache primitive arrays once. append_from(mesh) otherwise synchronizes with rendering for every detail
## when called by the regional worker (25 s observed for a region that took 1 s on the main thread).
func add(mesh: Mesh, xform: Transform3D, mat: Material) -> void:
	var key := Vector2i(floori(xform.origin.x / CELL), floori(xform.origin.z / CELL))
	if not _tools.has(key): _tools[key] = {}
	var groups: Dictionary = _tools[key]
	if not groups.has(mat):
		groups[mat] = {vertices = PackedVector3Array(), normals = PackedVector3Array(), uv = PackedVector2Array(), indices = PackedInt32Array()}
	var out: Dictionary = groups[mat]
	if not _geometry.has(mesh): _geometry[mesh] = mesh.get_mesh_arrays() if mesh is PrimitiveMesh else mesh.surface_get_arrays(0)
	var arrays: Array = _geometry[mesh]
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var offset: int = out.vertices.size()
	var normal_basis := xform.basis.inverse().transposed()
	for i in positions.size():
		out.vertices.append(xform * positions[i])
		out.normals.append((normal_basis * normals[i]).normalized() if i < normals.size() else Vector3.UP)
		out.uv.append(uv[i] if i < uv.size() else Vector2.ZERO)
	if indices.is_empty():
		for i in positions.size(): out.indices.append(offset + i)
	else:
		for i in indices: out.indices.append(offset + i)


func build(node_name: String) -> Node3D:
	if _tools.is_empty(): return null
	var root := Node3D.new()
	root.name = node_name
	for key: Vector2i in _tools:
		var mesh := ArrayMesh.new()
		var groups: Dictionary = _tools[key]
		var surface := 0
		for mat: Material in groups:
			var data: Dictionary = groups[mat]
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = data.vertices
			arrays[Mesh.ARRAY_NORMAL] = data.normals
			arrays[Mesh.ARRAY_TEX_UV] = data.uv
			arrays[Mesh.ARRAY_INDEX] = data.indices
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(surface, mat)
			surface += 1
		var mi := MeshInstance3D.new()
		mi.name = "%s_%d_%d" % [node_name, key.x, key.y]
		mi.mesh = mesh
		mi.visibility_range_end = SEEN
		root.add_child(mi)
	return root
