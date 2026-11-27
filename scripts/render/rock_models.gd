class_name RockModels
extends RefCounted
## Шесть семейств: валун, плита, клин, сколотый блок, галька и раздвоенный обломок.
## Три общих меша на модель; ни геометрии, ни материалов на отдельный камень.
const VARIANTS := 10
const _CREASE_COS := 0.905

static var _geo_cache := {}


static func mesh(size: Vector3, seed: int, moss: float, tone := 1.0) -> ArrayMesh:
	var near := _level(size, seed, moss, tone, 0)
	near.set_meta("lod_meshes", [_level(size, seed, moss, tone, 1), _level(size, seed, moss, tone, 2)])
	return near


## Одиночный или составной угловатый камень для подстилки и дорожных россыпей.
static func stone_block(size: Vector3, seed: int, moss: float, tone := 1.0, lod := 0, skirt := -0.05) -> ArrayMesh:
	var geo := _geo_unit(1 if lod == 0 else 0)
	var dirs: PackedVector3Array = geo.verts
	var tris: PackedInt32Array = geo.tris
	var positions := PackedVector3Array()
	var colors := PackedColorArray()
	positions.resize(dirs.size())
	colors.resize(dirs.size())
	var family := posmod(seed, 6)
	var variation := WGRandom.hash2(seed, 19, 13)
	var cuts := _family_cuts(family, seed)
	var min_y := skirt * size.y
	for i in dirs.size():
		var shaped := _shape_dir(dirs[i], seed, family, variation, cuts)
		var p: Vector3 = shaped.pos * size
		p.y = maxf(min_y, p.y)
		positions[i] = p
		colors[i] = _mineral_color(dirs[i], p, size, seed, moss, tone, shaped.ao)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_emit_creased(st, positions, colors, tris, min_y + 0.015, true, _CREASE_COS)
	st.index()
	return st.commit()


static func _geo_unit(detail: int) -> Dictionary:
	# detail: 0 = subdiv-3 icosahedron (~140 tris visible), 1 = subdiv-2 icosahedron (~62), 2 = subdiv-1 octahedron (~26)
	if _geo_cache.has(detail):
		return _geo_cache[detail]
	var base_v: Array[Vector3] = []
	var base_f: Array[Vector3i] = []
	var subdiv := 1
	if detail == 2:
		base_v = [Vector3.UP, Vector3.RIGHT, Vector3.BACK, Vector3.LEFT, Vector3.FORWARD, Vector3.DOWN]
		base_f = [
			Vector3i(0, 1, 2), Vector3i(0, 2, 3), Vector3i(0, 3, 4), Vector3i(0, 4, 1),
			Vector3i(5, 2, 1), Vector3i(5, 3, 2), Vector3i(5, 4, 3), Vector3i(5, 1, 4),
		]
		subdiv = 2
	else:
		var t := (1.0 + sqrt(5.0)) * 0.5
		for raw: Vector3 in [
			Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
			Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
			Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
		]:
			base_v.append(raw.normalized())
		base_f = [
			Vector3i(0, 11, 5), Vector3i(0, 5, 1), Vector3i(0, 1, 7), Vector3i(0, 7, 10), Vector3i(0, 10, 11),
			Vector3i(1, 5, 9), Vector3i(5, 11, 4), Vector3i(11, 10, 2), Vector3i(10, 7, 6), Vector3i(7, 1, 8),
			Vector3i(3, 9, 4), Vector3i(3, 4, 2), Vector3i(3, 2, 6), Vector3i(3, 6, 8), Vector3i(3, 8, 9),
			Vector3i(4, 9, 5), Vector3i(2, 4, 11), Vector3i(6, 2, 10), Vector3i(8, 6, 7), Vector3i(9, 8, 1),
		]
		subdiv = 3 if detail == 0 else 2
	var vert_map := {}
	var verts_arr: Array[Vector3] = []
	var tris_arr: Array[int] = []
	var add_v := func(v: Vector3) -> int:
		var n := v.normalized()
		var key := Vector3i(roundi(n.x * 100000.0), roundi(n.y * 100000.0), roundi(n.z * 100000.0))
		if vert_map.has(key):
			return vert_map[key]
		var idx := verts_arr.size()
		verts_arr.append(n)
		vert_map[key] = idx
		return idx
	for face: Vector3i in base_f:
		var va := base_v[face.x]
		var vb := base_v[face.y]
		var vc := base_v[face.z]
		var rows: Array = []
		for r in subdiv + 1:
			var row: Array[int] = []
			for c in subdiv + 1 - r:
				var u := float(r) / subdiv
				var w := float(c) / subdiv
				var s := 1.0 - u - w
				row.append(add_v.call(va * s + vb * u + vc * w))
			rows.append(row)
		for r in subdiv:
			var count := subdiv - r
			for c in count:
				var i0: int = rows[r][c]
				var i1: int = rows[r + 1][c]
				var i2: int = rows[r][c + 1]
				_append_outward_tri(verts_arr, tris_arr, i0, i1, i2)
				if c + 1 < count:
					var i3: int = rows[r + 1][c + 1]
					_append_outward_tri(verts_arr, tris_arr, i2, i1, i3)
	var out := {verts = PackedVector3Array(verts_arr), tris = PackedInt32Array(tris_arr)}
	_geo_cache[detail] = out
	return out


static func _append_outward_tri(verts: Array[Vector3], tris: Array[int], a: int, b: int, c: int) -> void:
	var centroid := verts[a] + verts[b] + verts[c]
	var outward := (verts[c] - verts[a]).cross(verts[b] - verts[a])
	if outward.dot(centroid) < 0.0:
		tris.append(a); tris.append(c); tris.append(b)
	else:
		tris.append(a); tris.append(b); tris.append(c)


static func _family_cuts(family: int, seed: int) -> Array:
	var yaw := (WGRandom.hash2(seed, 3, 29) - 0.5) * 0.9
	var rot := Basis(Vector3.UP, yaw)
	match family:
		0: # Скошенный гранитный блок с уступом
			return [
				[rot * Vector3(0.75, 0.55, 0.2).normalized(), 0.56],
				[rot * Vector3(-0.82, 0.45, -0.35).normalized(), 0.58],
				[rot * Vector3(0.15, 0.88, -0.42).normalized(), 0.54],
				[rot * Vector3(-0.2, 0.25, 0.92).normalized(), 0.62],
			]
		1: # Слоистая плита / сланец
			return [
				[rot * Vector3(0.08, 0.96, 0.24).normalized(), 0.42],
				[rot * Vector3(0.65, 0.3, 0.65).normalized(), 0.64],
				[rot * Vector3(-0.7, 0.25, -0.55).normalized(), 0.65],
			]
		2: # Острый гребень / скальный обломок
			return [
				[rot * Vector3(0.78, 0.62, 0.0).normalized(), 0.48],
				[rot * Vector3(-0.62, 0.52, 0.58).normalized(), 0.52],
				[rot * Vector3(0.1, 0.35, -0.9).normalized(), 0.58],
			]
		3: # Речной обкатанный валун со скошенным плечом
			return [
				[rot * Vector3(0.55, 0.72, 0.32).normalized(), 0.66],
				[rot * Vector3(-0.6, 0.4, -0.5).normalized(), 0.72],
			]
		4: # Расколотый валун с трещиной
			return [
				[rot * Vector3(0.75, 0.42, 0.35).normalized(), 0.62],
				[rot * Vector3(-0.72, 0.45, -0.32).normalized(), 0.62],
				[rot * Vector3(0.05, 0.85, 0.48).normalized(), 0.58],
			]
		5: # Низкая полка с плоской кровлей
			return [
				[rot * Vector3(-0.15, 0.97, 0.14).normalized(), 0.36],
				[rot * Vector3(0.82, 0.32, -0.4).normalized(), 0.64],
				[rot * Vector3(-0.52, 0.2, 0.82).normalized(), 0.64],
			]
		6, 7: # Двойной / тройной блок (главный камень + спутники)
			return [
				[rot * Vector3(0.74, 0.56, 0.3).normalized(), 0.55],
				[rot * Vector3(-0.65, 0.42, -0.6).normalized(), 0.58],
				[rot * Vector3(0.1, 0.88, -0.35).normalized(), 0.56],
			]
		8: # Крутой обрывчатый уступ
			return [
				[rot * Vector3(0.84, 0.52, 0.15).normalized(), 0.50],
				[rot * Vector3(-0.55, 0.75, -0.32).normalized(), 0.54],
				[rot * Vector3(-0.2, 0.28, 0.94).normalized(), 0.58],
			]
		_: # 9: Широкий замшелый эрратический валун с плоским седлом
			return [
				[rot * Vector3(0.25, 0.92, -0.25).normalized(), 0.50],
				[rot * Vector3(0.7, 0.35, 0.55).normalized(), 0.68],
				[rot * Vector3(-0.76, 0.28, -0.45).normalized(), 0.66],
			]


static func _shape_dir(d: Vector3, seed: int, family: int, variation: float, cuts: Array) -> Dictionary:
	# Базовая суперквадрика даёт каменную блочность вместо мыльного шара на всех LOD.
	var p_pow := 2.45 if family == 3 else 3.15
	var denom := pow(pow(absf(d.x), p_pow) + pow(absf(d.y), p_pow) + pow(absf(d.z), p_pow), 1.0 / p_pow)
	var bump := 0.84 + 0.28 * Models._noise3(d * 2.1, seed)
	var p := (d / maxf(denom, 1e-4)) * bump
	p.x += p.y * (0.11 if seed % 2 == 0 else -0.14)
	if family == 1:
		p.y *= 0.60
		p.x *= 1.18
		p.z *= 0.92
		var layer := p.y * 4.4 + p.x * 1.1
		p += Vector3(-0.04, -0.05, 0.02) * (layer - floorf(layer) - 0.5)
	elif family == 2:
		p.y *= 1.18
		p.z *= 0.86
	elif family == 3:
		p.x *= 1.12
		p.z *= 0.88
		p.y *= 0.90
	elif family == 4:
		p.x *= 1.18
		p.z *= 0.80
		p.y *= 0.82
		var seam := 1.0 - smoothstep(0.0, 0.26, absf(p.x * 0.88 + p.z * 0.47 - 0.05))
		var top_mask := smoothstep(-0.05, 0.55, d.y)
		p.y -= seam * top_mask * 0.38
		p -= Vector3(0.08, 0.0, 0.04) * seam * top_mask
	elif family == 5:
		p.y *= 0.58
		p.x *= 1.16
		p.z *= 1.12
	elif family == 8:
		p.y *= 1.32
		p.x *= 0.88
		p.z *= 0.86
	elif family == 9:
		p.x *= 1.20
		p.z *= 1.10
		p.y *= 0.78
	var ao := 1.0
	for cut: Array in cuts:
		var cn: Vector3 = cut[0]
		var over: float = p.dot(cn) - float(cut[1])
		if over > 0.0:
			p -= cn * over * 0.92
			ao = minf(ao, lerpf(1.0, 0.84, clampf(over * 2.5, 0.0, 1.0)))
	if family == 4:
		var cleft := 1.0 - smoothstep(0.0, 0.24, absf(p.x * 0.88 + p.z * 0.47 - 0.05))
		ao *= 1.0 - cleft * smoothstep(0.0, 0.55, d.y) * 0.38
	p.x *= lerpf(0.86, 1.16, variation)
	p.z *= lerpf(1.14, 0.84, variation)
	p.y = maxf(-0.37, p.y) + 0.25
	return {pos = p, ao = ao}


static func _mineral_color(d: Vector3, p: Vector3, size: Vector3, seed: int, moss: float, tone: float, cut_ao: float) -> Color:
	var mineral := Models._noise3(d * 4.2, seed + 3)
	var strata := sin(p.y / maxf(size.y, 0.2) * 10.0 + p.x * 2.4 + mineral * 2.0) * 0.5 + 0.5
	var patch_n := Models._noise3(d * 3.1 + Vector3(2.3, 0.7, -1.5), seed + 17)
	var h_norm := clampf((p.y + 0.08 * size.y) / maxf(size.y, 0.2), 0.0, 1.0)
	var base_ao := lerpf(0.50, 1.06, smoothstep(0.0, 0.50, h_norm)) * cut_ao
	var cool := smoothstep(0.45, 0.85, mineral)
	var stone_lum := lerpf(0.56, 0.96, mineral * 0.65 + strata * 0.35) * base_ao * tone
	var col := Color(stone_lum * 1.03, stone_lum * lerpf(0.99, 0.96, cool), stone_lum * lerpf(0.93, 0.99, cool))
	var lichen := smoothstep(0.56, 0.82, Models._noise3(d * 6.5, seed + 29)) * smoothstep(0.18, 0.68, d.y) * 0.34
	col = col.lerp(Color(0.48 * base_ao, 0.49 * base_ao, 0.33 * base_ao), lichen)
	var moss_mask := smoothstep(0.14, 0.72, d.y + 0.22 * (patch_n - 0.5)) * smoothstep(0.32, 0.72, patch_n + moss * 0.24) * moss
	var moss_col := Color(0.13, 0.20, 0.075).lerp(Color(0.27, 0.37, 0.14), clampf(h_norm * 0.7 + mineral * 0.3, 0.0, 1.0)) * lerpf(0.75, 1.06, cut_ao)
	return col.lerp(moss_col, clampf(moss_mask, 0.0, 0.92))


static func _point(d: Vector3, size: Vector3, seed: int, variation: float) -> Vector3:
	var family := posmod(seed, VARIANTS)
	var shaped := _shape_dir(d, seed, family, variation, _family_cuts(family, seed))
	return shaped.pos * size


static func _emit_creased(st: SurfaceTool, positions: PackedVector3Array, colors: PackedColorArray, tris: PackedInt32Array, min_cut: float, strip_bottom: bool, crease_cos := _CREASE_COS) -> void:
	var kept: Array[Vector3i] = []
	var face_n: Array[Vector3] = []
	var face_w: Array[float] = []
	var vert_faces: Array = []
	vert_faces.resize(positions.size())
	for vi in positions.size():
		vert_faces[vi] = []
	for t in range(0, tris.size(), 3):
		var ia := tris[t]
		var ib := tris[t + 1]
		var ic := tris[t + 2]
		var a := positions[ia]
		var b := positions[ib]
		var c := positions[ic]
		if a.y <= min_cut and b.y <= min_cut and c.y <= min_cut:
			continue
		var cross_v := (c - a).cross(b - a)
		var lsq := cross_v.length_squared()
		if lsq < 1e-10:
			continue
		var area := sqrt(lsq)
		var n := cross_v / area
		if strip_bottom and n.y < -0.10 and maxf(a.y, maxf(b.y, c.y)) <= min_cut + 0.065:
			continue
		var kidx := kept.size()
		kept.append(Vector3i(ia, ib, ic))
		face_n.append(n)
		face_w.append(area)
		vert_faces[ia].append(kidx)
		vert_faces[ib].append(kidx)
		vert_faces[ic].append(kidx)
	var vert_group_norm: Array = []
	vert_group_norm.resize(kept.size() * 3)
	for vi in positions.size():
		var flist: Array = vert_faces[vi]
		if flist.is_empty():
			continue
		var comp_of := {}
		var comp_norms: Array[Vector3] = []
		for fi: int in flist:
			if comp_of.has(fi):
				continue
			var cid := comp_norms.size()
			var queue: Array[int] = [fi]
			comp_of[fi] = cid
			var sum := Vector3.ZERO
			var qi := 0
			while qi < queue.size():
				var cur: int = queue[qi]
				qi += 1
				sum += face_n[cur] * face_w[cur]
				for nb: int in flist:
					if not comp_of.has(nb) and face_n[cur].dot(face_n[nb]) >= crease_cos:
						comp_of[nb] = cid
						queue.append(nb)
			var candidate := sum.normalized() if sum.length_squared() > 1e-10 else face_n[fi]
			if strip_bottom and positions[vi].y <= min_cut + 0.065 and candidate.y < -0.45:
				candidate = Vector3(candidate.x, -0.35, candidate.z).normalized()
			# Если другая компонента почти совпадает по нормали (< 3°), объединяем её во избежание EXACT_DUP_V.
			var merged_cid := -1
			for prev_cid in comp_norms.size():
				if comp_norms[prev_cid].dot(candidate) > 0.998:
					merged_cid = prev_cid
					break
			if merged_cid >= 0:
				for fi2: int in flist:
					if comp_of.get(fi2, -1) == cid:
						comp_of[fi2] = merged_cid
			else:
				comp_norms.append(candidate)
		for fi: int in flist:
			var tri := kept[fi]
			var nrm: Vector3 = comp_norms[comp_of[fi]]
			for corner in 3:
				if tri[corner] == vi:
					vert_group_norm[fi * 3 + corner] = nrm
	for ki in kept.size():
		var tri := kept[ki]
		for corner in 3:
			var idx: int = tri[corner]
			st.set_color(colors[idx])
			st.set_normal(vert_group_norm[ki * 3 + corner])
			st.add_vertex(positions[idx])


static func _append_lobe(st: SurfaceTool, detail: int, size: Vector3, offset: Vector3, rot: float, seed: int, family: int, moss: float, tone: float, min_cut: float) -> void:
	var geo := _geo_unit(detail)
	var dirs: PackedVector3Array = geo.verts
	var tris: PackedInt32Array = geo.tris
	var variation := WGRandom.hash2(seed, family + 11, 13)
	var cuts := _family_cuts(family, seed)
	var basis := Basis(Vector3.UP, rot)
	var positions := PackedVector3Array()
	var colors := PackedColorArray()
	positions.resize(dirs.size())
	colors.resize(dirs.size())
	for i in dirs.size():
		var shaped := _shape_dir(dirs[i], seed, family, variation, cuts)
		var local_p: Vector3 = basis * (shaped.pos * size)
		var p := local_p + offset
		if p.y < min_cut:
			p.y = min_cut
		positions[i] = p
		colors[i] = _mineral_color(dirs[i], p, size, seed, moss, tone, shaped.ao)
	_emit_creased(st, positions, colors, tris, min_cut, true, _CREASE_COS)


static func _level(size: Vector3, seed: int, moss: float, tone: float, detail: int) -> ArrayMesh:
	var family := posmod(seed, VARIANTS)
	var min_plane := -0.095 * size.y + 1e-4
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if family == 6:
		# Пара угловатых валунов, притёртых друг к другу.
		if detail == 2:
			_append_lobe(st, 2, size * Vector3(1.06, 0.96, 1.02), Vector3(-0.08 * size.x, 0.0, 0.0), 0.15, seed, 0, moss, tone, min_plane)
		else:
			var d0 := 1 if detail == 0 else 2
			_append_lobe(st, d0, size * Vector3(0.86, 1.02, 0.88), Vector3(-0.24 * size.x, 0.0, -0.08 * size.z), 0.25, seed, 0, moss, tone, min_plane)
			_append_lobe(st, d0, size * Vector3(0.60, 0.64, 0.66), Vector3(0.42 * size.x, -0.02 * size.y, 0.20 * size.z), -0.85, seed + 19, 2, moss * 1.1, tone * 0.90, min_plane)
	elif family == 7:
		# Тройная группа камней-останцев на грунте.
		if detail == 2:
			_append_lobe(st, 2, size * Vector3(1.10, 0.84, 1.05), Vector3.ZERO, -0.2, seed, 9, moss, tone, min_plane)
		elif detail == 1:
			_append_lobe(st, 2, size * Vector3(0.84, 0.92, 0.82), Vector3(-0.22 * size.x, 0.0, -0.10 * size.z), 0.18, seed, 3, moss, tone, min_plane)
			_append_lobe(st, 2, size * Vector3(0.56, 0.58, 0.58), Vector3(0.40 * size.x, 0.0, 0.24 * size.z), 1.4, seed + 23, 5, moss, tone * 0.92, min_plane)
		else:
			_append_lobe(st, 1, size * Vector3(0.82, 0.94, 0.80), Vector3(-0.20 * size.x, 0.0, -0.10 * size.z), 0.18, seed, 3, moss, tone, min_plane)
			_append_lobe(st, 2, size * Vector3(0.54, 0.56, 0.55), Vector3(0.42 * size.x, -0.01 * size.y, 0.26 * size.z), 1.35, seed + 23, 5, moss, tone * 0.90, min_plane)
			_append_lobe(st, 2, size * Vector3(0.42, 0.44, 0.46), Vector3(0.24 * size.x, -0.02 * size.y, -0.40 * size.z), -1.1, seed + 41, 1, moss * 1.15, tone * 1.05, min_plane)
	else:
		_append_lobe(st, detail, size, Vector3.ZERO, 0.0, seed, family, moss, tone, min_plane)
	st.index()
	return st.commit()


## Реальный треугольник рельефа важнее усреднённой крутизны клетки генератора.
static func supported(normal: Vector3) -> bool:
	return normal.y >= 0.74


static func normal_at(heights: Heightfield, x: float, z: float) -> Vector3:
	return Vector3(heights.ground_at(x - 0.5, z) - heights.ground_at(x + 0.5, z), 1.0,
		heights.ground_at(x, z - 0.5) - heights.ground_at(x, z + 0.5)).normalized()


## Проверка опоры по пятну: не ставим валун мостиком через резкий излом или берег.
static func has_seat(heights: Heightfield, x: float, z: float, scale: float, normal := Vector3.ZERO, base := INF) -> bool:
	if normal == Vector3.ZERO: normal = normal_at(heights, x, z)
	if not supported(normal) or heights.depth_at(x, z) > 0.05:
		return false
	if base == INF: base = heights.ground_at(x, z)
	var radius := maxf(0.15, scale * 1.1)
	for offset: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var p := offset * radius
		var expected := base - (normal.x * p.x + normal.z * p.y) / normal.y
		if absf(heights.ground_at(x + p.x, z + p.y) - expected) > maxf(0.12, scale * 0.23):
			return false
		if heights.depth_at(x + p.x, z + p.y) > 0.05:
			return false
	return true


## Фоновый поток читает только переданные снимки. Никаких OuterLand.chunks/height/water.
## Возврат: высота и нормаль; INF вместо высоты — площадка не подходит.
static func seat_snapshot(f: Dictionary, hv: PackedFloat32Array, width: int, height: int, x: float, z: float, scale: float) -> Vector4:
	var center := _snapshot_surface(f, hv, width, height, x, z)
	if center.x == INF or center.y - center.x > 0.05: return Vector4(INF, 0, 1, 0)
	var left := _snapshot_surface(f, hv, width, height, x - 0.5, z).x
	var right := _snapshot_surface(f, hv, width, height, x + 0.5, z).x
	var back := _snapshot_surface(f, hv, width, height, x, z - 0.5).x
	var front := _snapshot_surface(f, hv, width, height, x, z + 0.5).x
	if left == INF or right == INF or back == INF or front == INF: return Vector4(INF, 0, 1, 0)
	var normal := Vector3(left - right, 1, back - front).normalized()
	if not supported(normal): return Vector4(INF, 0, 1, 0)
	var radius := maxf(0.15, scale * 1.1)
	for offset: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var p := offset * radius
		var sample := _snapshot_surface(f, hv, width, height, x + p.x, z + p.y)
		var expected := center.x - (normal.x * p.x + normal.z * p.y) / normal.y
		if sample.x == INF or sample.y - sample.x > 0.05 or absf(sample.x - expected) > maxf(0.12, scale * 0.23):
			return Vector4(INF, 0, 1, 0)
	return Vector4(center.x, normal.x, normal.y, normal.z)


static func _snapshot_surface(f: Dictionary, hv: PackedFloat32Array, width: int, height: int, x: float, z: float) -> Vector2:
	var gx := x / GameConfig.TILE - 0.5
	var gz := z / GameConfig.TILE - 0.5
	var i := floori(gx)
	var j := floori(gz)
	var side: int = f.side
	var si: int = i - f.x0
	var sj: int = j - f.y0
	if si < 0 or sj < 0 or si + 1 >= side or sj + 1 >= side: return Vector2(INF, INF)
	var corners := Vector4.ZERO
	var level := 0.0
	var raw: PackedFloat32Array = f.h
	var water: PackedFloat32Array = f.get("water", PackedFloat32Array())
	var plan_water: PackedFloat32Array = f.get("plan_water", PackedFloat32Array())
	for c in 4:
		var ci := i + (c & 1)
		var cj := j + (c >> 1)
		var k := (sj + (c >> 1)) * side + si + (c & 1)
		if ci >= 0 and cj >= 0 and ci < width and cj < height:
			corners[c] = hv[cj * width + ci]
			if plan_water.size() == hv.size(): level = maxf(level, plan_water[cj * width + ci])
		else:
			corners[c] = Heightfield.outer_meters(raw[k], not water.is_empty() and is_finite(water[k]) and water[k] > 0.0)
			if not water.is_empty(): level = maxf(level, water[k] * GameConfig.HS)
	var tx := gx - i
	var tz := gz - j
	var ground := corners.x + (corners.y - corners.x) * tx + (corners.z - corners.x) * tz if tx + tz <= 1.0 else corners.w + (corners.z - corners.w) * (1.0 - tx) + (corners.y - corners.w) * (1.0 - tz)
	return Vector2(ground, level)


## Скальные выходы (07.11.2026): крупные формы коренной породы, утопленные в склон, — уступы,
## рёбра и развалы глыб. Хранятся как камни T_ROCK с obj_v >= OUTCROP_V (оттенок v - OUTCROP_V),
## модели — T_ROCK + (VARIANTS + форма) * MODEL_STRIDE: те же MultiMesh, LOD, материал и стриминг,
## что у валунов. Размеры — в метрах при масштабе отрисовки 1 (obj_s * 1.2, как у валунов).
const OUTCROP_V := 3
const OUTCROPS := 3
const OUTCROP_R := 2.1      # conservative local footprint of every baked form, before instance scaling
const PLAN_ROCK_SCALE := 1.2
const OUTCROP_ANCHOR_Y := -0.4 # lower block contact plane; the model origin is above its buried foot
const OUTCROP_TOP := 2.0    # верх над основанием
const OUTCROP_TILT := 0.8   # доля наклона по склону: плиты следуют падению, но не ложатся на него
## Части форм: центр, полуоси, поворот вокруг Y, наклон вокруг X. Нижняя часть уходит в склон.
const _OUTCROP_PARTS := [
	# Уступы: плиты лестницей.
	[[Vector3(0.0, -0.45, 0.0), Vector3(1.75, 1.0, 1.45), 0.0, 0.0],
	 [Vector3(0.3, 0.45, -0.2), Vector3(1.5, 0.36, 1.2), 0.2, 0.06],
	 [Vector3(-0.15, 0.95, 0.15), Vector3(1.2, 0.3, 0.95), -0.25, -0.08],
	 [Vector3(-0.45, 1.38, 0.3), Vector3(0.7, 0.26, 0.6), 0.5, 0.1]],
	# Ребро: высокий блок с наклонной гранью и плечо сбоку.
	[[Vector3(0.0, -0.3, 0.0), Vector3(1.6, 1.1, 1.3), 0.0, 0.0],
	 [Vector3(-0.35, 0.9, 0.0), Vector3(0.75, 1.1, 1.0), 0.15, 0.12],
	 [Vector3(0.75, 0.55, 0.3), Vector3(0.7, 0.6, 0.75), -0.3, 0.0]],
	# Развал глыб по трещинам отдельности.
	[[Vector3(0.0, -0.35, 0.0), Vector3(1.7, 0.95, 1.5), 0.0, 0.0],
	 [Vector3(-0.6, 0.6, 0.35), Vector3(0.85, 0.7, 0.8), 0.4, 0.1],
	 [Vector3(0.65, 0.5, -0.3), Vector3(0.8, 0.6, 0.7), -0.2, -0.15],
	 [Vector3(0.1, 1.15, -0.05), Vector3(0.55, 0.45, 0.5), 0.7, 0.2]],
]


static func is_outcrop(v: int) -> bool:
	return v >= OUTCROP_V


## Скальные массивы (09.11.2026): крупные образования среднего масштаба, 8–16 м, которые читаются с сотен
## метров и меняют форму склона, а не его цвет: уступ-стена со ступенями пластов, ребро вдоль линии падения,
## останцы на пологих вершинах и развалы глыб. Те же камни T_ROCK: obj_v = MASSIF_V +
## модель * 3 + оттенок. Модели массивов идут после трёх выходов.
## Локальные оси формы: X — вдоль горизонтали склона, +Z — вниз по склону (лицо стены), Y — вверх; начало —
## подошва лица. Нижняя часть тела уходит в склон на bury метров, поэтому край не висит на неровном склоне.
const MASSIF_V := 6
const MASSIFS := 4
const MASSIF_VARIANTS := 2 # два рисунка каждой формы: соседние стены пояса не повторяют друг друга
const M_WALL := 0
const M_RIB := 1
const M_TOR := 2
const M_BLOCKS := 3
## tilt — доля наклона оси по склону; r — радиус пятна с запасом на пропорции и наклон (м при масштабе 1);
## core — центр плотного тела в локальных осях и его радиус (просвет для травы и подлеска);
## foot — точки, по которым садится основание (лицо стены, кольцо опоры).
const MASSIF_SPEC := [
	{tilt = 0.12, r = 10.3, even = 4.5, core = Vector3(0.0, 0.0, -2.4), core_r = 6.3,
		foot = [Vector2(-7.4, 0.5), Vector2(-3.7, 0.5), Vector2(0.0, 0.5), Vector2(3.7, 0.5), Vector2(7.4, 0.5)]},
	{tilt = 0.95, r = 10.7, even = 6.0, core = Vector3(0.0, 0.0, -1.4), core_r = 5.3,
		foot = [Vector2(-2.6, -8.0), Vector2(2.6, -8.0), Vector2(-2.9, -3.0), Vector2(2.9, -3.0), Vector2(-2.6, 2.0), Vector2(2.6, 2.0), Vector2(0.0, 6.2), Vector2(0.0, -9.6)]},
	{tilt = 0.15, r = 5.6, even = 3.0, core = Vector3.ZERO, core_r = 3.5,
		foot = [Vector2(-4.3, 0.0), Vector2(4.3, 0.0), Vector2(0.0, -3.9), Vector2(0.0, 3.9), Vector2(-3.0, -2.7), Vector2(3.0, -2.7), Vector2(-3.0, 2.7), Vector2(3.0, 2.7)]},
	{tilt = 0.95, r = 7.2, even = 4.5, core = Vector3.ZERO, core_r = 3.0,
		foot = [Vector2(-5.5, 0.0), Vector2(5.5, 0.0), Vector2(0.0, -4.6), Vector2(0.0, 4.6), Vector2(-3.9, -3.3), Vector2(3.9, -3.3), Vector2(-3.9, 3.3), Vector2(3.9, 3.3)]},
]
const MASSIF_REACH := 20.0 # 10,7 × 1,5 × 1,2, округлено вверх
## Строятся один раз при загрузке класса: опору и коллизию читают фоновые потоки.
static var _massif_parts: Array = _all_massif_parts()


static func _all_massif_parts() -> Array:
	var models: Array = []
	for model in MASSIFS * MASSIF_VARIANTS:
		var lobes := _build_massif_parts(model)
		for n in lobes.size():
			var lobe: Array = lobes[n]
			lobe.append(_massif_profile(lobe, 900 + model * 37 + n * 11))
		models.append(lobes)
	return models


static func is_massif(v: int) -> bool:
	return v >= MASSIF_V


static func massif_v(form: int, variant: int, tint: int) -> int:
	return MASSIF_V + (form * MASSIF_VARIANTS + variant) * 3 + clampi(tint, 0, 2)


static func massif_form(v: int) -> int:
	return clampi((v - MASSIF_V) / 3 / MASSIF_VARIANTS, 0, MASSIFS - 1)


## Номер модели массива (форма и рисунок) среди MASSIFS * MASSIF_VARIANTS.
static func massif_model(v: int) -> int:
	return clampi((v - MASSIF_V) / 3, 0, MASSIFS * MASSIF_VARIANTS - 1)


## Форма для отрисовки, опоры и коллизии: у выходов — одна на чанк, у массива — из obj_v.
static func form_of(v: int, x: float, z: float, origin := Vector2.ZERO) -> int:
	return OUTCROPS + massif_model(v) if is_massif(v) else outcrop_form(x, z, origin)


## Части формы: центр, полуоси, азимут, наклон. У массивов также профиль и его запечённые вершины.
static func parts(form: int) -> Array:
	if form < OUTCROPS: return _OUTCROP_PARTS[form]
	return _massif_parts[form - OUTCROPS]


## Радиус плотного тела (м) и его центр для травы, подлеска и отступов: точнее круга всего пятна.
static func footprint(v: int, scale: float) -> float:
	if is_massif(v): return MASSIF_SPEC[massif_form(v)].core_r * scale
	return OUTCROP_R * scale


## Центр, полуоси, азимут, наклон и профиль вершины (ширина, глубина, сдвиг X/Z).
## Широкие лопасти дают непрерывную породу, меньшие продолжают разломы или отходят от неё.
static func _build_massif_parts(model: int) -> Array:
	match model:
		0: # длинный уступ, пологая кровля и косая нижняя плита
			return [
				[Vector3(-1.4, 0.1, -2.4), Vector3(6.7, 4.3, 3.5), -0.08, -0.18, Vector4(0.83, 0.61, 0.12, -0.3)],
				[Vector3(4.4, -0.7, -1.3), Vector3(3.6, 3.4, 2.9), 0.27, -0.12, Vector4(0.53, 0.64, -0.24, -0.3)],
				[Vector3(-4.1, -1.1, 0.8), Vector3(3.3, 2.6, 2.2), -0.19, 0.07, Vector4(0.81, 0.38, 0.18, -0.24)]]
		1: # высокая стена с косым разломом и выступающим плечом
			return [
				[Vector3(0.6, 1.6, -2.7), Vector3(5.6, 6.2, 3.6), 0.05, -0.15, Vector4(0.61, 0.73, 0.27, -0.14)],
				[Vector3(-4.3, -0.1, -1.3), Vector3(3.4, 4.8, 2.8), -0.32, -0.22, Vector4(0.48, 0.63, -0.21, -0.18)],
				[Vector3(3.0, -0.7, 0.8), Vector3(3.3, 3.8, 2.4), 0.16, 0.03, Vector4(0.65, 0.43, 0.3, 0.18)]]
		2: # узкое ребро с длинной острой спинкой
			return [
				[Vector3(-0.4, 0.5, -1.5), Vector3(2.8, 4.4, 7.5), -0.13, -0.17, Vector4(0.24, 0.75, -0.2, -0.21)],
				[Vector3(1.2, -0.7, 2.0), Vector3(2.5, 2.9, 4.1), 0.25, -0.09, Vector4(0.40, 0.54, -0.19, -0.32)]]
		3: # широкое раздвоенное ребро, одна ветвь заканчивается уступом
			return [
				[Vector3(0.6, 0.35, -1.2), Vector3(3.3, 4.2, 6.7), 0.17, -0.10, Vector4(0.37, 0.66, 0.16, -0.17)],
				[Vector3(-1.9, -0.45, -0.1), Vector3(2.5, 3.3, 5.7), -0.29, -0.12, Vector4(0.36, 0.68, -0.30, -0.17)],
				[Vector3(1.5, -0.65, 3.9), Vector3(2.7, 2.8, 3.1), -0.13, 0.04, Vector4(0.69, 0.47, 0.17, 0.12)]]
		4: # один наклонный останец с расколотой подошвой
			return [
				[Vector3(-0.8, 1.3, -0.4), Vector3(3.0, 5.0, 2.6), 0.22, 0.13, Vector4(0.44, 0.60, -0.32, 0.14)],
				[Vector3(1.4, -0.55, 0.5), Vector3(2.7, 2.9, 2.7), -0.48, -0.07, Vector4(0.54, 0.69, -0.22, -0.28)]]
		5: # две башни разной высоты с общей перемычкой у основания
			return [
				[Vector3(-1.4, 0.9, -0.2), Vector3(2.1, 4.4, 2.7), -0.40, -0.11, Vector4(0.58, 0.44, -0.24, -0.25)],
				[Vector3(1.4, 0.2, 0.25), Vector3(2.0, 3.8, 2.4), 0.35, 0.17, Vector4(0.56, 0.72, 0.30, 0.13)],
				[Vector3(0.4, -1.1, 1.2), Vector3(3.2, 2.3, 2.3), 0.20, -0.13, Vector4(0.61, 0.57, -0.12, -0.23)]]
		6: # тяжёлая плита и редкие угловатые обломки по косой
			return [
				[Vector3(-1.8, -0.25, -1.1), Vector3(3.1, 2.7, 2.4), 0.31, -0.22, Vector4(0.76, 0.53, -0.28, 0.16)],
				[Vector3(1.8, -0.55, 0.7), Vector3(2.3, 2.2, 1.7), -0.46, 0.36, Vector4(0.39, 0.53, 0.37, -0.25)],
				[Vector3(3.8, -0.6, 2.3), Vector3(1.4, 1.6, 1.2), 0.89, -0.29, Vector4(0.44, 0.57, -0.21, 0.38)],
				[Vector3(-1.0, -0.65, 3.3), Vector3(1.3, 1.7, 1.5), 0.56, 0.21, Vector4(0.69, 0.41, 0.26, 0.31)]]
		_: # вторая россыпь раскрывается веером, среди плит лежат отдельные глыбы
			return [
				[Vector3(0.8, -0.55, -1.6), Vector3(2.8, 3.0, 2.6), -0.55, 0.27, Vector4(0.53, 0.37, -0.35, -0.23)],
				[Vector3(-2.4, -0.75, -0.6), Vector3(2.4, 2.2, 1.4), 0.48, -0.36, Vector4(0.74, 0.68, 0.11, 0.34)],
				[Vector3(2.9, -0.85, 1.5), Vector3(1.8, 2.1, 1.2), 0.27, 0.31, Vector4(0.28, 0.58, 0.31, 0.25)],
				[Vector3(-1.9, -0.65, 2.7), Vector3(1.5, 1.8, 1.7), -0.36, 0.17, Vector4(0.67, 0.51, 0.36, -0.18)],
				[Vector3(0.8, -0.7, 3.7), Vector3(1.0, 1.4, 0.9), 0.84, -0.28, Vector4(0.48, 0.53, -0.37, -0.24)]]


const PROFILE_SIDES := 8
const PROFILE_BASE := 0
const PROFILE_WAIST := 1
const PROFILE_SHOULDER := 2
const PROFILE_CROWN := 3


## Четыре общих сечения для мешей и опоры. Изломы горизонтали образуют полки и грани,
## а смещение и сужение верхнего сечения задаёт крупный силуэт.
static func _massif_profile(lobe: Array, seed: int) -> PackedVector3Array:
	var center: Vector3 = lobe[0]
	var half: Vector3 = lobe[1]
	var basis := Basis(Vector3.UP, lobe[2]) * Basis(Vector3.RIGHT, lobe[3])
	var crest: Vector4 = lobe[4]
	var rings := [Vector4(0.73, -1.0, 0.75, 0.0), Vector4(1.0, -0.27, 1.0, 0.0),
		Vector4(0.86, 0.32, 0.83, 0.46), Vector4(crest.x, 0.88, crest.y, 1.0)]
	var vertices := PackedVector3Array()
	for ring: Vector4 in rings:
		for i in PROFILE_SIDES:
			var angle := (i + 0.21 + (WGRandom.hash2(seed, i, 21) - 0.5) * 0.38) * TAU / PROFILE_SIDES
			var radius := lerpf(0.88, 1.1, WGRandom.hash2(seed, i, 37))
			var x := cos(angle) * radius
			var z := sin(angle) * radius
			var seam := (WGRandom.hash2(seed, i, 49) - 0.5) * ring.w
			var point := Vector3(x * ring.x + crest.z * ring.w,
				ring.y + ring.w * (0.19 * x - 0.11 * z) + 0.27 * seam,
				z * ring.z + crest.w * ring.w)
			vertices.append(center + basis * (point * half))
	return vertices


## Модель выхода формы form с тремя LOD (геодезические колотые блоки без донных крышек и полюсов).
static func outcrop_mesh(form: int) -> ArrayMesh:
	var near := _outcrop_level(form, 0)
	near.set_meta("lod_meshes", [_outcrop_level(form, 1), _outcrop_level(form, 2)])
	return near


static func _geo_coarse() -> Dictionary:
	if _geo_cache.has(3):
		return _geo_cache[3]
	var t := (1.0 + sqrt(5.0)) * 0.5
	var verts_arr: Array[Vector3] = []
	for raw: Vector3 in [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]:
		verts_arr.append(raw.normalized())
	var base_f: Array[Vector3i] = [
		Vector3i(0, 11, 5), Vector3i(0, 5, 1), Vector3i(0, 1, 7), Vector3i(0, 7, 10), Vector3i(0, 10, 11),
		Vector3i(1, 5, 9), Vector3i(5, 11, 4), Vector3i(11, 10, 2), Vector3i(10, 7, 6), Vector3i(7, 1, 8),
		Vector3i(3, 9, 4), Vector3i(3, 4, 2), Vector3i(3, 2, 6), Vector3i(3, 6, 8), Vector3i(3, 8, 9),
		Vector3i(4, 9, 5), Vector3i(2, 4, 11), Vector3i(6, 2, 10), Vector3i(8, 6, 7), Vector3i(9, 8, 1),
	]
	var tris_arr: Array[int] = []
	for f: Vector3i in base_f:
		_append_outward_tri(verts_arr, tris_arr, f.x, f.y, f.z)
	var out := {verts = PackedVector3Array(verts_arr), tris = PackedInt32Array(tris_arr)}
	_geo_cache[3] = out
	return out


static func _outcrop_level(form: int, lod: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var parts_list: Array = _OUTCROP_PARTS[form]
	for n in parts_list.size():
		var part: Array = parts_list[n]
		var seed := 500 + form * 17 + n * 5
		var geo := _geo_unit(1) if lod == 0 else (_geo_unit(2) if lod == 1 else _geo_coarse())
		var dirs: PackedVector3Array = geo.verts
		var tris: PackedInt32Array = geo.tris
		var basis := Basis(Vector3.UP, part[2]) * Basis(Vector3.RIGHT, part[3])
		var tone := 0.84 + 0.24 * WGRandom.hash2(form, n, 71)
		var cuts: Array = []
		for c in 4:
			var a := (c + WGRandom.hash2(seed, c, 3) * 0.72) * TAU / 4.0
			var cy := 0.78 if c == 3 else (0.14 + 0.56 * WGRandom.hash2(seed, c, 5))
			cuts.append([Vector3(cos(a), cy, sin(a)).normalized(), 0.48 + 0.22 * WGRandom.hash2(seed, c, 7)])
		var positions := PackedVector3Array()
		var colors := PackedColorArray()
		positions.resize(dirs.size())
		colors.resize(dirs.size())
		var p_min_y := INF
		for i in dirs.size():
			var d := dirs[i]
			var p := d / pow(pow(absf(d.x), 3.3) + pow(absf(d.y), 3.3) + pow(absf(d.z), 3.3), 1.0 / 3.3)
			p *= 0.84 + 0.26 * Models._noise3(d * 1.9, seed)
			# Слоистая ступенька пластов на выходах.
			var strata_step := p.y * 2.8 + p.x * 0.65
			p.x += (strata_step - floorf(strata_step) - 0.5) * 0.055
			var cut_ao := 1.0
			for cut: Array in cuts:
				var cn: Vector3 = cut[0]
				var over: float = p.dot(cn) - float(cut[1])
				if over > 0.0:
					p -= cn * over
					cut_ao = minf(cut_ao, lerpf(1.0, 0.82, clampf(over * 2.2, 0.0, 1.0)))
			var p_part0: Vector3 = part[0]
			var p_part1: Vector3 = part[1]
			var world_p := p_part0 + basis * (p * p_part1)
			positions[i] = world_p
			p_min_y = minf(p_min_y, world_p.y)
			var mineral := Models._noise3(d * 5.2, seed + 3)
			var strata := sin(world_p.y * 4.5 + world_p.x * 1.8 + mineral * 2.0) * 0.5 + 0.5
			var h_shade := lerpf(0.58, 1.06, smoothstep(-0.65, 0.55, d.y)) * cut_ao
			var stone := (0.62 + 0.34 * (mineral * 0.65 + strata * 0.35)) * tone * h_shade
			var lichen := smoothstep(0.58, 0.82, Models._noise3(d * 6.5, seed + 9)) * smoothstep(0.15, 0.75, d.y) * 0.42
			var green := smoothstep(0.32, 0.88, d.y) * smoothstep(0.52, 0.80, mineral) * 0.24
			colors[i] = Color(stone * 1.03, stone * 0.99, stone * 0.95).lerp(Color(0.50 * h_shade, 0.51 * h_shade, 0.36 * h_shade), lichen).lerp(Color(0.19, 0.28, 0.105), green)
		# На цокольной плите (n == 0) отсекаем подземный купол подошвы; на верхних карнизах оставляем нависания.
		_emit_creased(st, positions, colors, tris, p_min_y + (0.20 if n == 0 else 0.025), n == 0, _CREASE_COS)
	st.index()
	return st.commit()


## Общие вершины держат силуэт при смене LOD. На дальнем остаются подошва, кровля
## и главные грани. Самые мелкие обломки развала исчезают вместе с остальными деталями.
static func massif_mesh(model: int) -> ArrayMesh:
	var near := _massif_level(model, [PROFILE_BASE, PROFILE_WAIST, PROFILE_SHOULDER, PROFILE_CROWN], [0, 1, 2, 3, 4, 5, 6, 7], false)
	near.set_meta("lod_meshes", [
		_massif_level(model, [PROFILE_BASE, PROFILE_WAIST, PROFILE_CROWN], [0, 1, 3, 4, 5, 7], false),
		_massif_level(model, [PROFILE_BASE, PROFILE_SHOULDER, PROFILE_CROWN], [0, 2, 4, 6], true)])
	return near


static func _massif_level(model: int, rings: Array, sides: Array, distant: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lobes := parts(OUTCROPS + model)
	var count := mini(lobes.size(), 3) if distant and model / MASSIF_VARIANTS == M_BLOCKS else lobes.size()
	for n in count:
		var vertices: PackedVector3Array = lobes[n][5]
		var colors := PackedColorArray()
		colors.resize(vertices.size())
		var seed := 900 + model * 37 + n * 11
		var tone := lerpf(0.84, 1.06, WGRandom.hash2(model, n, 71))
		var v_min_y := INF
		var v_max_y := -INF
		for p in vertices:
			v_min_y = minf(v_min_y, p.y)
			v_max_y = maxf(v_max_y, p.y)
		var h_span := maxf(0.5, v_max_y - v_min_y)
		for vi in vertices.size():
			var p := vertices[vi]
			var h_t := clampf((p.y - v_min_y) / h_span, 0.0, 1.0)
			var mineral := Models._noise3(p * 0.46, seed + 3)
			var strata := sin(p.y * 1.45 + p.x * 0.25 + mineral * 2.2) * 0.5 + 0.5
			var height_ao := lerpf(0.60, 1.05, smoothstep(0.05, 0.72, h_t))
			var stone := tone * height_ao * lerpf(0.76, 0.99, mineral * 0.7 + strata * 0.3)
			var lichen := smoothstep(0.60, 0.80, Models._noise3(p * 1.3, seed + 9)) * smoothstep(0.35, 0.85, h_t) * 0.28
			var crest_moss := smoothstep(0.68, 0.95, h_t) * smoothstep(0.58, 0.85, mineral) * 0.16
			colors[vi] = Color(stone * 1.02, stone * 0.99, stone * 0.95).lerp(Color(0.56 * height_ao, 0.56 * height_ao, 0.41 * height_ao), lichen).lerp(Color(0.24, 0.33, 0.15), crest_moss)
		var tris := PackedInt32Array()
		for row in rings.size() - 1:
			var low: int = rings[row] * PROFILE_SIDES
			var high: int = rings[row + 1] * PROFILE_SIDES
			for i in sides.size():
				var a: int = sides[i]
				var b: int = sides[(i + 1) % sides.size()]
				tris.append(low + a); tris.append(low + b); tris.append(high + b)
				tris.append(low + a); tris.append(high + b); tris.append(high + a)
		var top := PROFILE_CROWN * PROFILE_SIDES
		for i in range(1, sides.size() - 1):
			tris.append(top + sides[0]); tris.append(top + sides[i]); tris.append(top + sides[i + 1])
		_emit_creased(st, vertices, colors, tris, v_min_y - 1.0, false, _CREASE_COS)
	st.index()
	return st.commit()


## Ось выхода: между вертикалью и нормалью склона.
static func outcrop_up(normal: Vector3) -> Vector3:
	return Vector3.UP.lerp(normal, OUTCROP_TILT).normalized()


## Опора выхода масштаба scale: Vector4(высота основания, ось x, y, z); x = INF — места нет.
## sample(x, z) -> Vector2(земля, глубина воды над ней; INF — нет данных).
## Основание опускается до самой низкой точки кольца опоры: край выхода не висит над склоном,
## а нижняя часть модели уходит в землю. Слишком неровное кольцо (кромка выемки дороги,
## излом гребня) похоронило бы выход — такое место отклоняется.
static func outcrop_seat(sample: Callable, x: float, z: float, scale: float, origin := Vector2.ZERO, v := OUTCROP_V) -> Vector4:
	if is_massif(v): return _massif_seat(sample, x, z, scale, origin, v)
	var r := OUTCROP_R * scale
	var l: Vector2 = sample.call(x - r, z)
	var rr: Vector2 = sample.call(x + r, z)
	var b: Vector2 = sample.call(x, z - r)
	var f: Vector2 = sample.call(x, z + r)
	if l.x == INF or rr.x == INF or b.x == INF or f.x == INF:
		return Vector4(INF, 0, 1, 0)
	var up := outcrop_up(Vector3(l.x - rr.x, 2.0 * r, b.x - f.x).normalized())
	var basis := outcrop_transform(x, z, scale, up, 0.0, origin).basis
	var lo := INF
	var hi := -INF
	# 16 точек кольца: на выпуклом гребне между редкими точками край повис бы над землёй.
	for n in 17:
		var foot := Vector3(0.0, OUTCROP_ANCHOR_Y, 0.0)
		if n < 16: foot += Vector3(cos(n * TAU / 16.0), 0.0, sin(n * TAU / 16.0)) * OUTCROP_R
		var off := basis * foot
		var s: Vector2 = sample.call(x + off.x, z + off.z)
		if s.x == INF or s.y > 0.05:
			return Vector4(INF, 0, 1, 0)
		lo = minf(lo, s.x - off.y)
		hi = maxf(hi, s.x - off.y)
	var sink := 0.12 * scale
	if hi - lo > OUTCROP_TOP * scale * 0.8 - sink:
		return Vector4(INF, 0, 1, 0)
	# A numerically seated model may still be completely buried in a convex slope.
	# Probe upper interior points of its existing blocks, without loading mesh data on workers.
	var xf := outcrop_transform(x, z, scale, up, lo - sink, origin)
	var exposed := false
	for part: Array in _OUTCROP_PARTS[outcrop_form(x, z, origin)]:
		var local_basis := Basis(Vector3.UP, part[2]) * Basis(Vector3.RIGHT, part[3])
		var peak: Vector3 = xf * (part[0] + local_basis * Vector3(0.0, part[1].y * 0.7, 0.0))
		var surface: Vector2 = sample.call(peak.x, peak.z)
		if surface.x == INF or surface.y > 0.05: return Vector4(INF, 0, 1, 0)
		if peak.y - surface.x > 0.2 * scale: exposed = true
	if not exposed: return Vector4(INF, 0, 1, 0)
	return Vector4(lo - sink, up.x, up.y, up.z)


## One pose for rendering, footprint tests and collision, including saved sites' world origin.
static func outcrop_form(x: float, z: float, origin := Vector2.ZERO) -> int:
	var cell := (Vector2(x, z) + origin) / (GameConfig.TILE * WorldData.CHUNK_SIZE)
	return mini(OUTCROPS - 1, int(WGRandom.hash2(floori(cell.x), floori(cell.y), 65) * OUTCROPS))


## Массив садится по точкам своей подошвы (лицо стены, кольцо опоры), а не по кругу: стена врезается
## в склон тылом, её лицо стоит на земле. Тело уходит под основание, поэтому на неровном
## склоне край не висит; место отклоняется, если под нижней частью тела земля ниже его дна,
## если подошва слишком неровна или если над склоном не остаётся видимой скалы.
## Только для стендов (один поток): причины отказов опоры массивов.
static var debug_rejects: Dictionary = {}
static var debug_on := false


static func _reject(reason: String) -> Vector4:
	if debug_on: debug_rejects[reason] = debug_rejects.get(reason, 0) + 1
	return Vector4(INF, 0, 1, 0)


static func _massif_seat(sample: Callable, x: float, z: float, scale: float, origin: Vector2, v: int) -> Vector4:
	var spec: Dictionary = MASSIF_SPEC[massif_form(v)]
	var r: float = spec.r * scale * 0.6
	var l: Vector2 = sample.call(x - r, z)
	var rr: Vector2 = sample.call(x + r, z)
	var b: Vector2 = sample.call(x, z - r)
	var f: Vector2 = sample.call(x, z + r)
	if l.x == INF or rr.x == INF or b.x == INF or f.x == INF:
		return _reject("probe")
	var normal := Vector3(l.x - rr.x, 2.0 * r, b.x - f.x).normalized()
	var up := Vector3.UP.lerp(normal, spec.tilt).normalized()
	var xf := outcrop_transform(x, z, scale, up, 0.0, origin, v)
	var lo := INF
	var hi := -INF
	for foot: Vector2 in spec.foot:
		var off := xf.basis * Vector3(foot.x, 0.0, foot.y)
		var s: Vector2 = sample.call(x + off.x, z + off.z)
		if s.x == INF or s.y > 0.05: return _reject("foot_path_water")
		lo = minf(lo, s.x - off.y)
		hi = maxf(hi, s.x - off.y)
	# Неровная подошва — один край глубже в склоне; висеть не даёт проверка дна ниже.
	if hi - lo > spec.even * scale: return _reject("uneven_foot")
	xf.origin.y = lo - 0.25 * scale
	var lobes := parts(form_of(v, x, z, origin))
	var clearance := 0.0
	for lobe: Array in lobes:
		var vertices: PackedVector3Array = lobe[5]
		# Учитываем настоящую подошву, включая середины длинных граней.
		var a := xf * vertices[0]
		for i in PROFILE_SIDES:
			var next: Vector3 = xf * vertices[(i + 1) % PROFILE_SIDES]
			var middle := a.lerp(next, 0.5)
			for probe in 2:
				var bottom := a if probe == 0 else middle
				var g: Vector2 = sample.call(bottom.x, bottom.z)
				if g.x == INF or g.y > 0.05: return _reject("bottom_path_water")
				clearance = maxf(clearance, bottom.y - g.x)
			a = next
	if clearance > 1.4 * scale: return _reject("floating")
	xf.origin.y -= clearance
	# На резком выпуклом склоне валидная подошва может скрыть всю кровлю.
	var visible := 0
	for lobe: Array in lobes:
		var vertices: PackedVector3Array = lobe[5]
		var exposed := false
		for i in PROFILE_SIDES:
			var peak: Vector3 = xf * vertices[PROFILE_CROWN * PROFILE_SIDES + i]
			var surface: Vector2 = sample.call(peak.x, peak.z)
			if surface.x == INF or surface.y > 0.05: return _reject("face_path_water")
			exposed = exposed or peak.y - surface.x > 0.75 * scale
		visible += int(exposed)
	if visible == 0: return _reject("buried")
	return Vector4(xf.origin.y, up.x, up.y, up.z)


static func outcrop_transform(x: float, z: float, scale: float, up: Vector3, base: float, origin := Vector2.ZERO, v := OUTCROP_V) -> Transform3D:
	if is_massif(v): return _massif_transform(x, z, scale, up, base, origin)
	var ox := (x + origin.x) / GameConfig.TILE
	var oy := (z + origin.y) / GameConfig.TILE
	var rot := WGRandom.hash2(floori(ox * 97), floori(oy * 89), 7) * TAU
	var shape := WGRandom.hash2(floori(ox * 127), floori(oy * 131), 15632)
	var basis := Basis(Quaternion(Vector3.UP, up)) * Basis(Vector3.UP, rot)
	basis = basis.scaled_local(Vector3(scale, scale * lerpf(0.85, 1.15, shape), scale * lerpf(0.85, 1.05, shape)))
	return Transform3D(basis, Vector3(x, base, z))


## Лицо массива — вниз по склону (локальная +Z к понижению), вдоль горизонтали — его длина.
## На ровном месте (останец на плоской вершине) поворот случайный по месту.
static func _massif_transform(x: float, z: float, scale: float, up: Vector3, base: float, origin: Vector2) -> Transform3D:
	var ox := (x + origin.x) / GameConfig.TILE
	var oy := (z + origin.y) / GameConfig.TILE
	var jitter := WGRandom.hash2(floori(ox * 97), floori(oy * 89), 7)
	var shape := WGRandom.hash2(floori(ox * 127), floori(oy * 131), 15632)
	var down := Vector2(up.x, up.z)
	var rot := jitter * TAU
	if down.length() > 0.004: rot = atan2(down.x, down.y) + (jitter - 0.5) * 0.12
	var basis := Basis(Quaternion(Vector3.UP, up)) * Basis(Vector3.UP, rot)
	basis = basis.scaled_local(Vector3(scale * lerpf(0.85, 1.2, shape), scale * lerpf(1.15, 0.85, shape), scale * lerpf(0.92, 1.08, jitter)))
	return Transform3D(basis, Vector3(x, base, z))


## Small solid cores of the visible blocks, in ForestObstacles' existing capsule format.
## No extra nodes or mesh collision: unlike a single upright cylinder, these follow the tilt.
## Массивы: капсула вдоль длинной горизонтальной оси каждого блока, иначе стена из столбов
## пропускала бы велосипед между кругами в центрах.
static func outcrop_solids(xf: Transform3D, form: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if form >= OUTCROPS:
		for lobe: Array in parts(form):
			var axes: Vector3 = lobe[1]
			var b := xf.basis * Basis(Vector3.UP, lobe[2]) * Basis(Vector3.RIGHT, lobe[3])
			var center: Vector3 = xf * lobe[0] - b.y * axes.y * 0.14
			var hx := Vector2(b.x.x, b.x.z) * axes.x
			var hz := Vector2(b.z.x, b.z.z) * axes.z
			var major := hx if hx.length_squared() >= hz.length_squared() else hz
			var minor := hz if hx.length_squared() >= hz.length_squared() else hx
			# Внутреннее ядро сечения. Узкая кровля и выступающие углы капсулу не расширяют.
			var radius := minor.length() * 0.66
			var dir := major.normalized() * maxf(0.0, major.length() * 0.82 - radius)
			var vertices: PackedVector3Array = lobe[5]
			var roof := Vector3.ZERO
			for i in PROFILE_SIDES:
				roof += vertices[PROFILE_CROWN * PROFILE_SIDES + i]
			var top := (xf * (roof / PROFILE_SIDES)).y
			var bottom := minf(center.y - absf(b.y.y) * axes.y, xf.origin.y)
			out.append_array(PackedFloat32Array([center.x - dir.x, center.z - dir.y, center.x + dir.x, center.z + dir.y, radius, bottom, top]))
		return out
	for part: Array in _OUTCROP_PARTS[form]:
		var axes: Vector3 = part[1]
		var b := xf.basis * Basis(Vector3.UP, part[2]) * Basis(Vector3.RIGHT, part[3])
		var center: Vector3 = xf * part[0]
		var vertical := b.y * axes.y * 0.55
		var a := center - vertical
		var c := center + vertical
		var radius := minf(b.x.length() * axes.x, b.z.length() * axes.z) * 0.72
		var height := (absf(b.x.y) * axes.x + absf(b.y.y) * axes.y + absf(b.z.y) * axes.z) * 0.9
		# Upper plates belong to the same anchored rock. Measuring climbability from
		# their own thin bottom would let wheel_support teleport a wheel onto a high ledge.
		out.append_array(PackedFloat32Array([a.x, a.z, c.x, c.z, radius, minf(center.y - height, xf.origin.y), center.y + height]))
	return out


## Опора любого камня мира на Heightfield: Vector4(земля или основание выхода, нормаль/ось);
## x = INF — камень не ставится. Общая для отрисовки, препятствий и раскладки подлеска.
## ride — снимок опоры C# этого рельефа (Heightfield.ride_snapshot) для потоков генерации: те же пробы в разы быстрее
static func seat(heights: Heightfield, x: float, z: float, scale: float, v: int, ride: Object = null) -> Vector4:
	if is_outcrop(v):
		var key := Vector4(x, z, scale, v)
		heights.rock_seats_lock.lock()
		var known: Variant = heights.rock_seats.get(key)
		heights.rock_seats_lock.unlock()
		if known != null: return known
		var found := _outcrop_seat_live(heights, x, z, scale, v, ride)
		heights.rock_seats_lock.lock()
		# Evict a batch of old results: bounded memory without copying all keys
		# on every new rock. Recalculation is deterministic and safe after eviction.
		if not heights.rock_seats.has(key) and heights.rock_seats.size() >= Heightfield.ROCK_SEAT_LIMIT:
			var oldest := heights.rock_seats.keys()
			for i in Heightfield.ROCK_SEAT_LIMIT / 4:
				heights.rock_seats.erase(oldest[i])
		heights.rock_seats[key] = found
		heights.rock_seats_lock.unlock()
		return found
	var normal := normal_at(heights, x, z)
	var ground := heights.ground_at(x, z)
	if not has_seat(heights, x, z, scale, normal, ground):
		return Vector4(INF, 0, 1, 0)
	return Vector4(ground, normal.x, normal.y, normal.z)


static func _outcrop_seat_live(heights: Heightfield, x: float, z: float, scale: float, v: int, ride: Object = null) -> Vector4:
	var world := heights.world
	var width := world.W
	var height := world.H
	return outcrop_seat(func(px: float, pz: float) -> Vector2:
		var cell := Vector2i(floori(px / GameConfig.TILE), floori(pz / GameConfig.TILE))
		if cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height:
			var index := cell.y * width + cell.x
			var path := world.path_mask
			if index < path.size() and path[index] > 0: return Vector2(INF, INF)
		var refinement := heights.road_refinement
		if refinement != null and refinement.weight_at(px, pz, width) > 0.08: return Vector2(INF, INF)
		if ride != null:
			var fast: Vector2 = ride.GroundDepth(px, pz)
			if not is_nan(fast.x): return fast
		if heights.fine_relief != null:
			return Vector2(heights.ground_at(px, pz), heights.depth_at(px, pz))
		return heights.ground_depth_at(px, pz), x, z, scale, Vector2(world.world_origin) * GameConfig.TILE, v)


## То же по снимку области за краем (фоновый поток, без живого мира).
static func seat_snapshot_any(f: Dictionary, hv: PackedFloat32Array, width: int, height: int, x: float, z: float, scale: float, v: int) -> Vector4:
	if not is_outcrop(v):
		return seat_snapshot(f, hv, width, height, x, z, scale)
	return outcrop_seat(func(px: float, pz: float) -> Vector2:
		var cell := Vector2i(floori(px / GameConfig.TILE), floori(pz / GameConfig.TILE))
		var paths: PackedByteArray = f.get("plan_path", PackedByteArray()) if cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height else f.get("path", PackedByteArray())
		var index := cell.y * width + cell.x if cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height else (cell.y - int(f.y0)) * int(f.side) + cell.x - int(f.x0)
		if index >= 0 and index < paths.size() and paths[index] > 0: return Vector2(INF, INF)
		var s := _snapshot_surface(f, hv, width, height, px, pz)
		return Vector2(s.x, INF if s.x == INF else s.y - s.x), x, z, scale, f.get("world_origin", Vector2.ZERO), v)
