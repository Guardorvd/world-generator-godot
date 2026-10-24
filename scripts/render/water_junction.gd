extends RefCounted
## Disjoint upper envelope of lake and river surfaces. Convex differences keep
## interpolated spline attributes. At shared cuts vertices snap to the lake plane;
## transparent surfaces meet at edges instead of drawing a second layer.
const BIN := GameConfig.TILE * 2.0

static func partition(lakes: Array, rivers: Array) -> Array[Array]:
	if lakes.is_empty() or rivers.is_empty():
		return [lakes, rivers]
	var lake_faces := _faces(lakes)
	var river_faces := _faces(rivers)
	var lake_bins := _bins(lake_faces)
	var river_bins := _bins(river_faces)
	var river_out := _output(true)
	for face: Dictionary in river_faces:
		var pieces: Array = [_polygon(rivers, face)]
		for id: int in _candidates(face, lake_bins):
			var lake: Dictionary = lake_faces[id]
			if face.min_y > lake.max_y or not _overlap(face, lake):
				continue
			var planes := _sides(lake)
			planes.append({c = PackedFloat64Array([0.0, -1.0, 0.0, lake.max_y]), snap = lake.max_y})
			pieces = _subtract_all(pieces, planes)
			if pieces.is_empty(): break
		_emit(pieces, river_out)
	var lake_out := _output(false)
	for face: Dictionary in lake_faces:
		var pieces: Array = [_polygon(lakes, face)]
		for id: int in _candidates(face, river_bins):
			var river: Dictionary = river_faces[id]
			# Equality belongs to the lake, including a completely coplanar mouth.
			if river.max_y <= face.max_y or not _overlap(face, river):
				continue
			var plane := _height_plane(river, face.max_y)
			if plane.is_empty(): continue
			var planes := _sides(river)
			planes.append({c = plane})
			pieces = _subtract_all(pieces, planes)
			if pieces.is_empty(): break
		_emit(pieces, lake_out)
	return [_arrays(lake_out), _arrays(river_out)]

static func _faces(mesh: Array) -> Array:
	var pos: PackedVector3Array = mesh[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = mesh[Mesh.ARRAY_INDEX] if mesh[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var count := indices.size() if not indices.is_empty() else pos.size()
	var faces: Array = []
	for k in range(0, count, 3):
		var ids := Vector3i(indices[k], indices[k + 1], indices[k + 2]) if not indices.is_empty() else Vector3i(k, k + 1, k + 2)
		var a := pos[ids.x]
		var b := pos[ids.y]
		var c := pos[ids.z]
		if absf((float(b.x) - a.x) * (float(c.z) - a.z) - (float(b.z) - a.z) * (float(c.x) - a.x)) < 1e-8:
			continue
		faces.append({ids = ids, a = a, b = b, c = c,
			lo = Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z))),
			hi = Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z))),
			min_y = minf(a.y, minf(b.y, c.y)), max_y = maxf(a.y, maxf(b.y, c.y))})
	return faces

static func _bins(faces: Array) -> Dictionary:
	var bins := {}
	for id in faces.size():
		var f: Dictionary = faces[id]
		for z in range(floori(f.lo.y / BIN), floori(f.hi.y / BIN) + 1):
			for x in range(floori(f.lo.x / BIN), floori(f.hi.x / BIN) + 1):
				var key := Vector2i(x, z)
				if not bins.has(key): bins[key] = []
				bins[key].append(id)
	return bins

static func _candidates(f: Dictionary, bins: Dictionary) -> Array:
	var found := {}
	for z in range(floori(f.lo.y / BIN), floori(f.hi.y / BIN) + 1):
		for x in range(floori(f.lo.x / BIN), floori(f.hi.x / BIN) + 1):
			for id: int in bins.get(Vector2i(x, z), []):
				found[id] = true
	return found.keys()

static func _overlap(a: Dictionary, b: Dictionary) -> bool:
	return a.lo.x < b.hi.x and b.lo.x < a.hi.x and a.lo.y < b.hi.y and b.lo.y < a.hi.y

static func _polygon(mesh: Array, f: Dictionary) -> Array:
	var out: Array = []
	for i: int in [f.ids.x, f.ids.y, f.ids.z]:
		var tangent := Vector3.RIGHT
		if mesh[Mesh.ARRAY_TANGENT] != null:
			var t: PackedFloat32Array = mesh[Mesh.ARRAY_TANGENT]
			tangent = Vector3(t[i * 4], t[i * 4 + 1], t[i * 4 + 2])
		out.append({p = mesh[Mesh.ARRAY_VERTEX][i], n = mesh[Mesh.ARRAY_NORMAL][i], t = tangent,
			uv = mesh[Mesh.ARRAY_TEX_UV][i] if mesh[Mesh.ARRAY_TEX_UV] != null else Vector2.ZERO,
			uv2 = mesh[Mesh.ARRAY_TEX_UV2][i] if mesh[Mesh.ARRAY_TEX_UV2] != null else Vector2.ZERO,
			color = mesh[Mesh.ARRAY_COLOR][i] if mesh[Mesh.ARRAY_COLOR] != null else Color.WHITE})
	return out

static func _sides(f: Dictionary) -> Array:
	var points: Array[Vector3] = [f.a, f.b, f.c]
	var orientation := signf((float(f.b.x) - f.a.x) * (float(f.c.z) - f.a.z) - (float(f.b.z) - f.a.z) * (float(f.c.x) - f.a.x))
	var planes: Array = []
	for k in 3:
		var a := points[k]
		var b := points[(k + 1) % 3]
		var nx := -(float(b.z) - a.z) * orientation
		var nz := (float(b.x) - a.x) * orientation
		planes.append({c = PackedFloat64Array([nx, 0.0, nz, -nx * a.x - nz * a.z])})
	return planes

static func _height_plane(f: Dictionary, level: float) -> PackedFloat64Array:
	var bx: float = float(f.b.x) - f.a.x
	var bz: float = float(f.b.z) - f.a.z
	var cx: float = float(f.c.x) - f.a.x
	var cz: float = float(f.c.z) - f.a.z
	var by: float = float(f.b.y) - f.a.y
	var cy: float = float(f.c.y) - f.a.y
	var det := bx * cz - bz * cx
	if absf(det) < 1e-8: return PackedFloat64Array()
	var x := (by * cz - bz * cy) / det
	var z := (bx * cy - by * cx) / det
	return PackedFloat64Array([x, 0.0, z, f.a.y - x * f.a.x - z * f.a.z - level])

static func _subtract_all(subjects: Array, planes: Array) -> Array:
	var result: Array = []
	for polygon: Array in subjects:
		var remaining := polygon
		for plane: Dictionary in planes:
			if remaining.size() < 3: break
			var outside := _clip(remaining, plane, false)
			if outside.size() >= 3: result.append(outside)
			remaining = _clip(remaining, plane, true)
	return result

static func _distance(v: Dictionary, c: PackedFloat64Array) -> float:
	return c[0] * v.p.x + c[1] * v.p.y + c[2] * v.p.z + c[3]

static func _clip(polygon: Array, plane: Dictionary, inside: bool) -> Array:
	var out: Array = []
	for k in polygon.size():
		var a: Dictionary = polygon[k]
		var b: Dictionary = polygon[(k + 1) % polygon.size()]
		var da := _distance(a, plane.c)
		var db := _distance(b, plane.c)
		var keep_a := da >= 0.0 if inside else da < 0.0
		var keep_b := db >= 0.0 if inside else db < 0.0
		if keep_a: out.append(a)
		if keep_a != keep_b:
			var t := clampf(da / (da - db), 0.0, 1.0)
			var p: Vector3 = a.p.lerp(b.p, t)
			if plane.has("snap"): p.y = plane.snap
			out.append({p = p, n = a.n.lerp(b.n, t), t = a.t.lerp(b.t, t),
				uv = a.uv.lerp(b.uv, t), uv2 = a.uv2.lerp(b.uv2, t), color = a.color.lerp(b.color, t)})
	return out

static func _output(river: bool) -> Dictionary:
	return {river = river, pos = PackedVector3Array(), normal = PackedVector3Array(), tangent = PackedFloat32Array(),
		uv = PackedVector2Array(), uv2 = PackedVector2Array(), color = PackedColorArray()}

static func _emit(pieces: Array, out: Dictionary) -> void:
	for polygon: Array in pieces:
		for k in range(1, polygon.size() - 1):
			var a: Vector3 = polygon[0].p
			var b: Vector3 = polygon[k].p
			var c: Vector3 = polygon[k + 1].p
			if absf((float(b.x) - a.x) * (float(c.z) - a.z) - (float(b.z) - a.z) * (float(c.x) - a.x)) < 1e-8:
				continue
			for v: Dictionary in [polygon[0], polygon[k], polygon[k + 1]]:
				out.pos.append(v.p)
				out.normal.append(v.n.normalized())
				if out.river:
					var t: Vector3 = v.t.normalized()
					out.tangent.append_array([t.x, t.y, t.z, -1.0])
					out.uv.append(v.uv)
					out.uv2.append(v.uv2)
					out.color.append(v.color)

static func _arrays(out: Dictionary) -> Array:
	if out.pos.is_empty(): return []
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out.pos
	arrays[Mesh.ARRAY_NORMAL] = out.normal
	if out.river:
		arrays[Mesh.ARRAY_TANGENT] = out.tangent
		arrays[Mesh.ARRAY_TEX_UV] = out.uv
		arrays[Mesh.ARRAY_TEX_UV2] = out.uv2
		arrays[Mesh.ARRAY_COLOR] = out.color
	return arrays
