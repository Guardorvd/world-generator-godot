class_name MeshBatch
extends RefCounted
## Много неподвижных одинаковых по материалу деталей (дома, мосты, туннели) в одном меше: по поверхности
## на материал. Каждый MeshInstance3D — отдельный вызов отрисовки, а деталей у мостов и домов тысячи.
## С 1.9.9: у мира 768 с длинными мостами их было больше тысячи на кадр.
## С 9.8 детали собираются по квадратам мира CELL: когда поселения стоят по всему плану, один меш на весь мир
## никогда не отсекался камерой и рисовал все дома мира (с тенями) в каждом кадре.

const CELL := 256.0   # сторона квадрата, м
const SEEN := 1400.0  # дальше центра квадрата не рисуется: туман на 900 м уже скрывает больше 80 % цвета

var _tools: Dictionary = {}   # Vector2i квадрат -> {материал -> SurfaceTool}


## Добавить меш (первую поверхность) с преобразованием xform и материалом mat
func add(mesh: Mesh, xform: Transform3D, mat: Material) -> void:
	var key := Vector2i(floori(xform.origin.x / CELL), floori(xform.origin.z / CELL))
	var tools: Dictionary = _tools.get(key, {})
	if tools.is_empty():
		_tools[key] = tools
	var st: SurfaceTool = tools.get(mat)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(mat)
		tools[mat] = st
	st.append_from(mesh, 0, xform)


## Узел со всем добавленным: по MeshInstance3D на квадрат (или null, если ничего не добавлено)
func build(node_name: String) -> Node3D:
	if _tools.is_empty():
		return null
	var root := Node3D.new()
	root.name = node_name
	for key: Vector2i in _tools:
		var mesh := ArrayMesh.new()
		var tools: Dictionary = _tools[key]
		for mat in tools:
			tools[mat].commit(mesh)
		var mi := MeshInstance3D.new()
		mi.name = "%s_%d_%d" % [node_name, key.x, key.y]
		mi.mesh = mesh
		mi.visibility_range_end = SEEN
		root.add_child(mi)
	return root
