class_name MeshBatch
extends RefCounted
## Много неподвижных одинаковых по материалу деталей (дома, мосты, туннели) в одном меше: по поверхности
## на материал. Каждый MeshInstance3D — отдельный вызов отрисовки, а деталей у мостов и домов тысячи.
## С 9.8 детали собираются по квадратам мира CELL (256 м) с отсечением на 1400 м.
## С 16.11 постройки поселений поддерживают 3 явных уровня детализации (LOD0/1/2: 60 / 250 / 1400 м)
## и MultiMesh с цветом экземпляра (обязательно для Compatibility) для мелких деталей.

const CELL := 256.0     # сторона квадрата, м
const SEEN := 1400.0    # дальше не рисуется: туман на 900 м уже скрывает больше 80 % цвета
const LOD_ENDS := [60.0, 250.0, SEEN]
const DETAIL_SEEN := 60.0

var _tools: Dictionary = {}       # world square -> material -> CPU arrays (мосты, туннели, туры)
var _lod_tools: Dictionary = {}   # world square -> [level 0..2 dict: material -> CPU arrays]
var _lod_centers: Dictionary = {} # world square -> {sum: Vector3, count: int}
var _details: Dictionary = {}     # world square -> material -> mesh -> Array[{xform, color}]
var _geometry := {}               # cache (mesh, surface) -> surface arrays


func _arrays_of(mesh: Mesh, surface: int) -> Array:
	var cached: Variant = _geometry.get(mesh)
	if cached == null:
		cached = {}
		_geometry[mesh] = cached
	if not cached.has(surface):
		cached[surface] = mesh.get_mesh_arrays() if mesh is PrimitiveMesh else mesh.surface_get_arrays(surface)
	return cached[surface]


## Добавить простую геометрию (мосты, туннели, туры, руины) в общий меш квадрата без сдвига и LOD.
func add(mesh: Mesh, xform: Transform3D, mat: Material) -> void:
	var key := Vector2i(floori(xform.origin.x / CELL), floori(xform.origin.z / CELL))
	if not _tools.has(key):
		_tools[key] = {}
	var groups: Dictionary = _tools[key]
	if not groups.has(mat):
		groups[mat] = {vertices = PackedVector3Array(), normals = PackedVector3Array(), uv = PackedVector2Array(), indices = PackedInt32Array()}
	var out: Dictionary = groups[mat]
	var arrays: Array = _arrays_of(mesh, 0)
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
		for i in positions.size():
			out.indices.append(offset + i)
	else:
		for i in indices:
			out.indices.append(offset + i)


## Добавить геометрию уровня детализации level (0..2) в квадрат 256 м с опциональным тонированием ячеек атласа.
func add_lod(mesh: Mesh, xform: Transform3D, mats: Array, level: int, cell_tints: Dictionary = {}, count_center := true) -> void:
	if mesh == null or mats.is_empty():
		return
	var lvl := clampi(level, 0, 2)
	var key := Vector2i(floori(xform.origin.x / CELL), floori(xform.origin.z / CELL))
	if not _lod_tools.has(key):
		_lod_tools[key] = [{}, {}, {}]
	if not _lod_centers.has(key):
		_lod_centers[key] = {sum = Vector3.ZERO, count = 0}
	if count_center and lvl == 0:
		_lod_centers[key].sum += xform.origin
		_lod_centers[key].count += 1
	var groups: Dictionary = _lod_tools[key][lvl]
	var normal_basis := xform.basis.inverse().transposed()
	var has_tints := not cell_tints.is_empty()
	for s in mesh.get_surface_count():
		var mat: Material = mats[mini(s, mats.size() - 1)]
		if not groups.has(mat):
			groups[mat] = {vertices = PackedVector3Array(), normals = PackedVector3Array(), uv = PackedVector2Array(), colors = PackedColorArray(), indices = PackedInt32Array()}
		var out: Dictionary = groups[mat]
		var arrays := _arrays_of(mesh, s)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var offset: int = out.vertices.size()
		for i in positions.size():
			out.vertices.append(xform * positions[i])
			out.normals.append((normal_basis * normals[i]).normalized() if i < normals.size() else Vector3.UP)
			var tuv: Vector2 = uv[i] if i < uv.size() else Vector2.ZERO
			out.uv.append(tuv)
			var col: Color = colors[i] if i < colors.size() else Color.WHITE
			if has_tints:
				var cell := SettlementModels.cell_at_uv(tuv)
				var tint: Color = cell_tints.get(cell, Color.WHITE)
				col = Color(col.r * tint.r, col.g * tint.g, col.b * tint.b, col.a * tint.a)
			out.colors.append(col)
		if indices.is_empty():
			for i in positions.size():
				out.indices.append(offset + i)
		else:
			for i in indices:
				out.indices.append(offset + i)


## Добавить мелкую повторяющуюся деталь (ящик с цветами, скамья, поленья) для MultiMesh квадрата 256 м.
func add_detail(mesh: Mesh, xform: Transform3D, color: Color, mat: Material) -> void:
	if mesh == null or mat == null:
		return
	var key := Vector2i(floori(xform.origin.x / CELL), floori(xform.origin.z / CELL))
	if not _details.has(key):
		_details[key] = {}
	var by_mat: Dictionary = _details[key]
	if not by_mat.has(mat):
		by_mat[mat] = {}
	var by_mesh: Dictionary = by_mat[mat]
	if not by_mesh.has(mesh):
		by_mesh[mesh] = []
	by_mesh[mesh].append({xform = xform, color = color})


func build(node_name: String) -> Node3D:
	if _tools.is_empty() and _lod_tools.is_empty() and _details.is_empty():
		return null
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

	for key: Vector2i in _lod_tools:
		var center := _square_center(key)
		var levels: Array = _lod_tools[key]
		for level in 3:
			var groups: Dictionary = levels[level]
			if groups.is_empty():
				continue
			var mesh := ArrayMesh.new()
			var surface := 0
			for mat: Material in groups:
				var data: Dictionary = groups[mat]
				var verts: PackedVector3Array = data.vertices
				var local_verts := PackedVector3Array()
				local_verts.resize(verts.size())
				for i in verts.size():
					local_verts[i] = verts[i] - center
				var arrays := []
				arrays.resize(Mesh.ARRAY_MAX)
				arrays[Mesh.ARRAY_VERTEX] = local_verts
				arrays[Mesh.ARRAY_NORMAL] = data.normals
				arrays[Mesh.ARRAY_TEX_UV] = data.uv
				arrays[Mesh.ARRAY_COLOR] = data.colors
				arrays[Mesh.ARRAY_INDEX] = data.indices
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				mesh.surface_set_material(surface, mat)
				surface += 1
			var mi := MeshInstance3D.new()
			mi.name = "%s_%d_%d_LOD%d" % [node_name, key.x, key.y, level]
			mi.mesh = mesh
			mi.position = center
			mi.visibility_range_begin = 0.0 if level == 0 else LOD_ENDS[level - 1]
			mi.visibility_range_end = LOD_ENDS[level]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if level >= 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			root.add_child(mi)

	for key: Vector2i in _details:
		var center := _square_center(key)
		var by_mat: Dictionary = _details[key]
		var idx := 0
		for mat: Material in by_mat:
			var by_mesh: Dictionary = by_mat[mat]
			for mesh: Mesh in by_mesh:
				var items: Array = by_mesh[mesh]
				if items.is_empty():
					continue
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_colors = true
				mm.mesh = mesh
				mm.instance_count = items.size()
				for i in items.size():
					var item: Dictionary = items[i]
					var xf: Transform3D = item.xform
					xf.origin -= center
					mm.set_instance_transform(i, xf)
					mm.set_instance_color(i, item.color)
				var mmi := MultiMeshInstance3D.new()
				mmi.name = "%s_Detail_%d_%d_%d" % [node_name, key.x, key.y, idx]
				idx += 1
				mmi.multimesh = mm
				mmi.material_override = mat
				mmi.position = center
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mmi.visibility_range_begin = 0.0
				mmi.visibility_range_end = DETAIL_SEEN
				root.add_child(mmi)
	return root


func _square_center(key: Vector2i) -> Vector3:
	if _lod_centers.has(key) and _lod_centers[key].count > 0:
		return _lod_centers[key].sum / float(_lod_centers[key].count)
	var sum := Vector3.ZERO
	var count := 0
	if _details.has(key):
		for mat: Material in _details[key]:
			for mesh: Mesh in _details[key][mat]:
				for item: Dictionary in _details[key][mat][mesh]:
					sum += (item.xform as Transform3D).origin
					count += 1
	if count > 0:
		return sum / float(count)
	return Vector3((key.x + 0.5) * CELL, 0.0, (key.y + 0.5) * CELL)
