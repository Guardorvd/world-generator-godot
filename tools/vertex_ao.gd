extends RefCounted
## Запекание затенения в вершины (COLOR.r) для сборщиков модели велосипеда и седока.
## Заслоняющие треугольники раскладываются по сетке ячеек (поверхность, не объём), из каждой вершины
## над поверхностью идут лучи по полусфере вокруг нормали; закрытая доля с весом по расстоянию — затенение.
## Один раз при сборке, в игре ничего не стоит.
const RAYS := 20


## Лучи по полусфере: косинусное распределение (спираль Фибоначчи), одинаковые для всех вершин.
static func _directions() -> PackedVector3Array:
	var dirs := PackedVector3Array()
	for i in RAYS:
		var u := (i + 0.5) / RAYS
		var r := sqrt(u)
		var a := i * 2.3999632
		dirs.append(Vector3(r * cos(a), sqrt(1.0 - u), r * sin(a)))
	return dirs


class AOGrid:
	var origin: Vector3
	var cell: float
	var size: Vector3i
	var cells: PackedByteArray

	func _init(bounds: AABB, cell_size: float) -> void:
		cell = cell_size
		origin = bounds.position - Vector3.ONE * cell * 2.0
		size = Vector3i((bounds.size / cell).ceil()) + Vector3i(5, 5, 5)
		cells.resize(size.x * size.y * size.z)

	func mark(p: Vector3) -> void:
		var c := Vector3i(((p - origin) / cell).floor())
		if c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x < size.x and c.y < size.y and c.z < size.z:
			cells[(c.z * size.y + c.y) * size.x + c.x] = 1

	func hit(p: Vector3) -> bool:
		var c := Vector3i(((p - origin) / cell).floor())
		if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= size.x or c.y >= size.y or c.z >= size.z:
			return false
		return cells[(c.z * size.y + c.y) * size.x + c.x] != 0

	## Поверхность треугольника — в ячейки, с шагом меньше половины ячейки.
	func add_triangle(a: Vector3, b: Vector3, c: Vector3) -> void:
		var nu := maxi(1, ceili(a.distance_to(b) / (cell * 0.5)))
		var nv := maxi(1, ceili(a.distance_to(c) / (cell * 0.5)))
		for i in nu + 1:
			var u := float(i) / nu
			for j in nv + 1:
				var v := float(j) / nv
				if u + v > 1.0001:
					break
				mark(a + (b - a) * u + (c - a) * v)


## Затенение для вершин verts (с нормалями normals) от треугольников occluders (по три точки).
## reach — дальность лучей (м), cell — размер ячейки (м). Возвращает 0..1 (1 — открыто).
static func bake(verts: PackedVector3Array, normals: PackedVector3Array, occluders: PackedVector3Array, reach: float, cell: float, strength := 1.0) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(verts.size())
	result.fill(1.0)
	if occluders.size() < 3:
		return result
	var bounds := AABB(occluders[0], Vector3.ZERO)
	for p in occluders:
		bounds = bounds.expand(p)
	var grid := AOGrid.new(bounds, cell)
	for t in range(0, occluders.size() - 2, 3):
		grid.add_triangle(occluders[t], occluders[t + 1], occluders[t + 2])
	var dirs := _directions()
	var steps := maxi(2, ceili(reach / cell))
	var cache := {}
	for i in verts.size():
		var key := verts[i].snapped(Vector3.ONE * 0.0005)
		var n := normals[i].normalized()
		var ck := [key, n.snapped(Vector3.ONE * 0.05)]
		if cache.has(ck):
			result[i] = cache[ck]
			continue
		var tangent := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
		var bitangent := n.cross(tangent)
		var start := verts[i] + n * cell * 1.6
		var blocked := 0.0
		for d in dirs:
			var dir := tangent * d.x + n * d.y + bitangent * d.z
			for s in range(1, steps + 1):
				if grid.hit(start + dir * (s * cell)):
					blocked += 1.0 - float(s - 1) / steps
					break
		var open := 1.0 - blocked / RAYS * strength
		result[i] = clampf(open, 0.0, 1.0)
		cache[ck] = result[i]
	return result


## Треугольники меша (все поверхности) в осях xf — для списка заслоняющих.
static func triangles(mesh: Mesh, xf := Transform3D.IDENTITY) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx != null and (idx as PackedInt32Array).size() > 0:
			for k in idx:
				out.append(xf * v[k])
		else:
			for p in v:
				out.append(xf * p)
	return out


## Записать затенение в COLOR.r всех поверхностей меша (G и B сохраняются). Возвращает новый меш.
static func apply(mesh: ArrayMesh, occluders: PackedVector3Array, reach: float, cell: float, strength := 1.0) -> ArrayMesh:
	var result := ArrayMesh.new()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var ao := bake(verts, arrays[Mesh.ARRAY_NORMAL], occluders, reach, cell, strength)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		if colors.size() != verts.size():
			colors.resize(verts.size())
			colors.fill(Color(1, 0, 0, 1))
		for i in verts.size():
			colors[i].r = ao[i]
		arrays[Mesh.ARRAY_COLOR] = colors
		var flags := mesh.surface_get_format(s) & ~Mesh.ARRAY_FORMAT_VERTEX & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
		result.surface_set_material(s, mesh.surface_get_material(s))
	return result
