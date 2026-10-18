class_name MeshBatch
extends RefCounted
## Много неподвижных одинаковых по материалу деталей (дома, мосты, туннели) в одном меше: по поверхности
## на материал. Каждый MeshInstance3D — отдельный вызов отрисовки, а деталей у мостов и домов тысячи.
## С 1.9.9: у мира 768 с длинными мостами их было больше тысячи на кадр.

var _tools: Dictionary = {}   # материал -> SurfaceTool


## Добавить меш (первую поверхность) с преобразованием xform и материалом mat
func add(mesh: Mesh, xform: Transform3D, mat: Material) -> void:
	var st: SurfaceTool = _tools.get(mat)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(mat)
		_tools[mat] = st
	st.append_from(mesh, 0, xform)


## Узел со всем добавленным (или null, если ничего не добавлено)
func build(node_name: String) -> MeshInstance3D:
	if _tools.is_empty():
		return null
	var mesh := ArrayMesh.new()
	for mat in _tools:
		_tools[mat].commit(mesh)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	return mi
