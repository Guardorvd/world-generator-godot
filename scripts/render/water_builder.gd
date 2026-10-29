class_name WaterBuilder
extends RefCounted
## Общая поверхность воды; течение и пороги заданы атрибутами, без симуляции.

const TILE := GameConfig.TILE
const HS := GameConfig.HS
const LAKE_DROP := GameConfig.LAKE_DROP # м, см. _lake_arrays
const SHADER := preload("res://resources/water.gdshader")


static func _material(ocean := false, river := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("ocean", ocean)
	m.set_shader_parameter("river_surface", river)
	return m


## Тяжёлые циклы готовят только массивы, без узлов отображения и GPU-ресурсов.
static func prepare(w: WorldData, heights: Heightfield) -> Array[Array]:
	return [_lake_arrays(w, heights), _river_arrays(heights.ribbons, heights)]


## Preserve existing triangles and all flow/shore attributes; index non-indexed ribbons first.
static func partition_arrays(arrays: Array) -> Dictionary:
	if arrays.is_empty(): return {}
	var indexed := arrays.duplicate()
	if indexed[Mesh.ARRAY_INDEX] == null:
		var ids := PackedInt32Array()
		ids.resize(indexed[Mesh.ARRAY_VERTEX].size())
		for k in ids.size(): ids[k] = k
		indexed[Mesh.ARRAY_INDEX] = ids
	return PlanTerrain.partition(indexed)


## Создание узлов из готовых массивов — в главном потоке.
static func build(w: WorldData, prepared: Array[Array]) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var water_mat := _material()
	var ocean_mat := _material(true)
	var plane := PlaneMesh.new()
	plane.size = Vector2(w.W * TILE + 16000.0, w.H * TILE + 16000.0)
	plane.material = ocean_mat
	var ocean := MeshInstance3D.new()
	ocean.name = "Ocean"
	ocean.mesh = plane
	ocean.position = Vector3(w.W * TILE / 2.0, 0.0, w.H * TILE / 2.0)
	out.append(ocean)
	var lakes := flat_mesh(prepared[0], water_mat, "Lakes")
	if lakes:
		out.append(lakes)
	var rivers := flat_mesh(prepared[1], _material(false, true), "Rivers")
	if rivers:
		out.append(rivers)
	# полупрозрачная вода тень не отбрасывает: иначе дно и берег под ней темнели бы целиком (с 2.6)
	for mi in out:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return out


static func _arrays(pos: PackedVector3Array, idx: PackedInt32Array = PackedInt32Array()) -> Array:
	if pos.is_empty():
		return []
	var nor := PackedVector3Array()
	nor.resize(pos.size())
	nor.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	if not idx.is_empty():
		arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


static func flat_mesh(arrays: Array, mat: Material, node_name: String) -> MeshInstance3D:
	if arrays.is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	return mi


## Режем плоскость озера по той же диагонали и высотам, что у земли.
## LAKE_DROP убирает наложение на заполненные впадины у берега.
static func _lake_arrays(w: WorldData, heights: Heightfield) -> Array:
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
			var corners := [Vector3(x0, heights.hv[a], z0), Vector3(x1, heights.hv[a + 1], z0),
				Vector3(x0, heights.hv[a + W], z1), Vector3(x1, heights.hv[a + W + 1], z1)]
			_clip_lake([corners[0], corners[1], corners[2]], y, pos, idx)
			_clip_lake([corners[1], corners[3], corners[2]], y, pos, idx)
	return _arrays(pos, idx)


static func _clip_lake(tri: Array, level: float, pos: PackedVector3Array, idx: PackedInt32Array) -> void:
	var polygon: Array[Vector3] = []
	for k in 3:
		var a: Vector3 = tri[k]
		var b: Vector3 = tri[(k + 1) % 3]
		if a.y < level:
			polygon.append(Vector3(a.x, level, a.z))
		if (a.y < level) != (b.y < level):
			var edge := a.lerp(b, (level - a.y) / (b.y - a.y))
			polygon.append(Vector3(edge.x, level, edge.z))
	var start := pos.size()
	pos.append_array(polygon)
	for k in range(1, polygon.size() - 1):
		idx.append_array([start, start + k, start + k + 1])


## Реки: ленты вдоль средних линий из Heightfield.ribbons
static func _river_arrays(ribbons: Array, heights: Heightfield = null) -> Array:
	var pos := PackedVector3Array()
	var flow := PackedVector2Array()
	var normals := PackedVector3Array()
	var banks := PackedVector2Array()
	var character := PackedColorArray()
	for pts in ribbons:
		var n: int = pts.size()
		if n < 2:
			continue # одна точка ленты не даёт ни одной полосы
		var directions: Array[Vector2] = []
		var slopes: Array[Vector3] = []
		var conditions: Array[Color] = []
		for k in n:
			var a: Dictionary = pts[maxi(0, k - 1)]
			var b: Dictionary = pts[mini(n - 1, k + 1)]
			var delta := Vector2(b.x - a.x, b.z - a.z)
			var grade := maxf(0.0, a.y - b.y) / maxf(delta.length(), 0.01)
			var motion := Heightfield.river_motion(pts, k)
			var dir := Vector2(motion.x, motion.y)
			directions.append(dir)
			slopes.append(Vector3(dir.x * grade, 1.0, dir.y * grade).normalized())
			conditions.append(Color(motion.z, motion.w, 0.0, 1.0))
		# Берега уже посчитаны Heightfield: геометрия и проверка глубины совпадают.
		for k in n - 1:
			pos.append_array([pts[k].left, pts[k].right, pts[k + 1].left, pts[k + 1].left, pts[k].right, pts[k + 1].right])
			for v in [k, k, k + 1, k + 1, k, k + 1]:
				flow.append(directions[v])
				normals.append(slopes[v])
				var state := conditions[v]
				if heights != null:
					var vertex := pos[character.size()]
					var lake := heights.lake_level(vertex.x, vertex.z)
					# Устье растворяется в общей плоскости: две прозрачные
					# поверхности одного уровня не образуют мерцающих пятен.
					if (lake >= vertex.y - 0.001 and heights.ground_at(vertex.x, vertex.z) < lake) or vertex.y <= 0.001:
						state.b = 1.0
				character.append(state)
			banks.append_array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 0), Vector2(0, 0), Vector2(1, 0), Vector2(1, 0)])
	var arrays := _arrays(pos)
	if not arrays.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = flow
		arrays[Mesh.ARRAY_TEX_UV2] = banks
		arrays[Mesh.ARRAY_COLOR] = character
	return arrays
