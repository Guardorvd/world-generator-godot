class_name WaterBuilder
extends RefCounted
## Общая поверхность воды; течение и пороги заданы атрибутами, без симуляции.

const TILE := GameConfig.TILE
const HS := GameConfig.HS
const LAKE_DROP := 0.1   # м, см. _lake_arrays
const WaterJunction = preload("res://scripts/render/water_junction.gd")
const SHADER := preload("res://resources/water.gdshader")


static func _material(ocean := false, river := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("ocean", ocean)
	m.set_shader_parameter("river_surface", river)
	return m


## Тяжёлые циклы готовят только массивы, без узлов отображения и GPU-ресурсов.
static func prepare(w: WorldData, heights: Heightfield) -> Array[Array]:
	return WaterJunction.partition(_lake_arrays(w, heights), _river_arrays(heights.ribbons))


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
	var lakes := _flat_mesh(prepared[0], water_mat, "Lakes")
	if lakes:
		out.append(lakes)
	var rivers := _flat_mesh(prepared[1], _material(false, true), "Rivers")
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


static func _flat_mesh(arrays: Array, mat: Material, node_name: String) -> MeshInstance3D:
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


## Spline coordinates: U across the banks, V metric arc length downstream.
## Shared junctions have the same V, so ripple phase survives confluences.
static func _river_arrays(ribbons: Array, heights: Heightfield = null) -> Array:
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var widths := PackedVector2Array()
	var character := PackedColorArray()
	var distances := _river_distances(ribbons)
	for r in ribbons.size():
		var pts: Array = ribbons[r]
		var n := pts.size()
		if n < 2:
			continue
		var slopes: Array[Vector3] = []
		var across: Array[Vector3] = []
		var conditions: Array[Color] = []
		var lengths := PackedFloat64Array([0.0])
		for k in range(1, n):
			lengths.append(lengths[-1] + _river_step(pts[k - 1], pts[k]))
		for k in n:
			var a: Dictionary = pts[maxi(0, k - 1)]
			var b: Dictionary = pts[mini(n - 1, k + 1)]
			var delta := Vector2(b.x - a.x, b.z - a.z)
			var grade := maxf(0.0, a.y - b.y) / maxf(delta.length(), 0.01)
			var motion := Heightfield.river_motion(pts, k)
			var dir := Vector2(motion.x, motion.y)
			slopes.append(Vector3(dir.x * grade, 1.0, dir.y * grade).normalized())
			across.append((pts[k].right - pts[k].left).normalized())
			conditions.append(Color(motion.z, motion.w, 0.0, 1.0))
		for k in n - 1:
			# The ocean already owns the sea-level plane; no duplicate river layer.
			if pts[k].y <= 0.0 and pts[k + 1].y <= 0.0:
				continue
			pos.append_array([pts[k].left, pts[k].right, pts[k + 1].left, pts[k + 1].left, pts[k].right, pts[k + 1].right])
			var sides := [0.0, 1.0, 0.0, 0.0, 1.0, 1.0]
			var vertices := [k, k, k + 1, k + 1, k, k + 1]
			for j in 6:
				var v: int = vertices[j]
				uv.append(Vector2(sides[j], lengths[v] - distances[r]))
				normals.append(slopes[v])
				tangents.append_array([across[v].x, across[v].y, across[v].z, -1.0])
				widths.append(Vector2(pts[v].left.distance_to(pts[v].right), 0.0))
				character.append(conditions[v])
	var arrays := _arrays(pos)
	if not arrays.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TANGENT] = tangents
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = widths
		arrays[Mesh.ARRAY_COLOR] = character
	if heights != null:
		return WaterJunction.partition(_lake_arrays(heights.world, heights), arrays)[1]
	return arrays


static func _river_step(a: Dictionary, b: Dictionary) -> float:
	return Vector3(b.x - a.x, b.y - a.y, b.z - a.z).length()


## Remaining distance to the network outlet. Iterative DAG walk avoids recursion
## limits in long river networks; lakes terminate the running ripple coordinate.
static func _river_distances(ribbons: Array) -> PackedFloat64Array:
	var starts := {}
	var lengths := PackedFloat64Array()
	lengths.resize(ribbons.size())
	for r in ribbons.size():
		var pts: Array = ribbons[r]
		if pts.is_empty():
			continue
		starts[Vector2(pts[0].x, pts[0].z)] = r
		for k in range(1, pts.size()):
			lengths[r] += _river_step(pts[k - 1], pts[k])
	var remaining := PackedFloat64Array()
	remaining.resize(ribbons.size())
	remaining.fill(-1.0)
	for r in ribbons.size():
		var chain: Array[int] = []
		var seen := {}
		var at := r
		while at >= 0 and remaining[at] < 0.0 and not seen.has(at):
			seen[at] = true
			chain.append(at)
			var pts: Array = ribbons[at]
			var next: int = starts.get(Vector2(pts[-1].x, pts[-1].z), -1) if not pts.is_empty() else -1
			at = next if next != at else -1
		var tail := remaining[at] if at >= 0 and remaining[at] >= 0.0 else 0.0
		for k in range(chain.size() - 1, -1, -1):
			var id := chain[k]
			tail += lengths[id]
			remaining[id] = tail
	return remaining
