extends RefCounted
## 6.6+: подстилка и валежник. Только оформление готового мира.

const Plants := preload("res://scripts/render/understory_models.gd")
const Surface := preload("res://scripts/world/mountain_surface.gd")
enum { LEAVES, NEEDLES, TWIG, ROOTS, LOG, MOSS_LOG, SNAG, STONES, STUMP, BOULDER, BRANCH, ROOT_SPAN,
	ROOT_SPAN_B, ROOT_SPAN_C, STONE_SINGLE, STONES_PAIR, LOG_BROKEN, MOSS_LOG_BROKEN,
	NURSE_LOG, NURSE_LOG_SPLIT, ROOT_STUMP, ROOT_PLATE, ROOT_UPTURNED, MOSS_BOULDER, MOSS_BOULDER_LOW, NURSE_LOG_LONG, NURSE_LOG_HOLLOW, NURSE_LOG_PAIR,
	LOG_HOLLOW, MOSS_LOG_SPLIT, BRANCH_FORKED, BRANCH_PINE, TWIG_FORK, SNAG_FORK, STUMP_HOLLOW, BOULDER_CLUSTER, COUNT }
const FIRST := Plants.COUNT # смещение групп MultiMesh и запечённых far_forms, вне сохранений
const BARK := Color(0.28, 0.21, 0.145)
const WOOD := Color(0.56, 0.44, 0.27)
const MOSS_DARK := Color(0.11, 0.17, 0.06)
const MOSS_MID := Color(0.19, 0.29, 0.105)
const MOSS_TIP := Color(0.28, 0.39, 0.145)
const CAP_NONE := 0
const CAP_CUT := 1
const CAP_SPLINTER := 2
const CAP_HOLLOW := 3
## [ось A, ось B, радиус комля, радиус вершины]; тот же след у меша и физических капсул.
const LARGE_LOGS := {
	NURSE_LOG_LONG: [[Vector3(-5.25, 0.52, -0.05), Vector3(5.70, 0.27, 0.12), 0.61, 0.27]],
	NURSE_LOG_HOLLOW: [[Vector3(-4.33, 0.48, 0.02), Vector3(4.03, 0.22, -0.10), 0.56, 0.30]],
	NURSE_LOG_PAIR: [
		[Vector3(-4.55, 0.46, -0.30), Vector3(4.15, 0.22, 0.56), 0.51, 0.25],
		[Vector3(-2.65, 0.30, 0.94), Vector3(2.90, 0.17, 1.55), 0.34, 0.14],
	],
}
static var _shared_meshes: Array[Mesh] = []
static var _shared_far := {}
static var _stone_bounds := {}


static func is_expedition(form: int) -> bool:
	return form >= NURSE_LOG and form <= NURSE_LOG_PAIR


static func base_kind(kind: int) -> int:
	if kind in [ROOT_SPAN_B, ROOT_SPAN_C]: return ROOT_SPAN
	if kind in [STONE_SINGLE, STONES_PAIR]: return STONES
	if kind in [LOG_BROKEN, LOG_HOLLOW]: return LOG
	if kind in [MOSS_LOG_BROKEN, MOSS_LOG_SPLIT, NURSE_LOG, NURSE_LOG_SPLIT] or LARGE_LOGS.has(kind): return MOSS_LOG
	if kind in [ROOT_STUMP, ROOT_PLATE, ROOT_UPTURNED, STUMP_HOLLOW]: return STUMP
	if kind in [MOSS_BOULDER, MOSS_BOULDER_LOW, BOULDER_CLUSTER]: return BOULDER
	if kind in [BRANCH_FORKED, BRANCH_PINE]: return BRANCH
	if kind == TWIG_FORK: return TWIG
	if kind == SNAG_FORK: return SNAG
	return kind


static func variant_kind(kind: int, variant: int) -> int:
	if kind == ROOT_SPAN: return [ROOT_SPAN, ROOT_SPAN_B, ROOT_SPAN_C][posmod(variant, 3)]
	if kind == STONES: return [STONES, STONE_SINGLE, STONES_PAIR][posmod(variant, 3)]
	if kind == LOG: return [LOG, LOG_BROKEN, LOG_HOLLOW][posmod(variant, 3)]
	if kind == MOSS_LOG: return [MOSS_LOG, MOSS_LOG_BROKEN, MOSS_LOG_SPLIT][posmod(variant, 3)]
	if kind == BRANCH: return [BRANCH, BRANCH_FORKED, BRANCH_PINE][posmod(variant, 3)]
	if kind == TWIG: return [TWIG, TWIG_FORK][posmod(variant, 2)]
	if kind == SNAG: return [SNAG, SNAG_FORK][posmod(variant, 2)]
	if kind == STUMP: return [STUMP, STUMP_HOLLOW][posmod(variant, 2)]
	if kind == BOULDER: return [BOULDER, BOULDER_CLUSTER][posmod(variant, 2)]
	return kind


static func log_span(kind: int) -> Vector2:
	if LARGE_LOGS.has(kind):
		var seg: Array = LARGE_LOGS[kind][0]
		return Vector2((seg[0] as Vector3).x, (seg[1] as Vector3).x)
	if kind in [NURSE_LOG, NURSE_LOG_SPLIT]:
		return Vector2(-2.65, 1.63 if kind == NURSE_LOG_SPLIT else 2.87)
	if kind in [BRANCH, BRANCH_FORKED, BRANCH_PINE]:
		return Vector2(-1.1, 1.1)
	if kind in [LOG_BROKEN, MOSS_LOG_BROKEN]:
		return Vector2(-2.2, 0.9)
	if kind == LOG_HOLLOW:
		return Vector2(-2.15, 1.85)
	if kind == MOSS_LOG_SPLIT:
		return Vector2(-2.2, 1.35)
	return Vector2(-2.2, 2.1)


## Shared by near/far rendering and wheel contacts. No invisible central dome.
static func stone_specs(variant := 0) -> Array[Vector4]:
	match posmod(variant, 3):
		1: return [Vector4(0.0, 0.0, 0.31, 304)]
		2: return [Vector4(-0.23, 0.05, 0.28, 302), Vector4(0.26, -0.12, 0.19, 305)]
	return [Vector4(-0.34, 0.12, 0.21, 300), Vector4(0.23, -0.18, 0.30, 303), Vector4(0.43, 0.30, 0.13, 301)]


static func _append_mesh_clean(st: SurfaceTool, src: Mesh, xf: Transform3D, tint := Color.WHITE) -> void:
	if src == null or src.get_surface_count() == 0:
		return
	var arrays := src.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: Variant = arrays[Mesh.ARRAY_NORMAL]
	var cols: Variant = arrays[Mesh.ARRAY_COLOR]
	var idxs: Variant = arrays[Mesh.ARRAY_INDEX]
	var has_nrm := norms is PackedVector3Array and (norms as PackedVector3Array).size() == verts.size()
	var has_col := cols is PackedColorArray and (cols as PackedColorArray).size() == verts.size()
	var has_idx := idxs is PackedInt32Array and (idxs as PackedInt32Array).size() > 0
	var count: int = (idxs as PackedInt32Array).size() if has_idx else verts.size()
	var nmat := xf.basis.inverse().transposed()
	for i in count:
		var vi := (idxs as PackedInt32Array)[i] if has_idx else i
		var c := ((cols as PackedColorArray)[vi] if has_col else Color.WHITE) * tint
		var n := (nmat * (norms as PackedVector3Array)[vi]).normalized() if has_nrm else Vector3.UP
		st.set_color(c)
		st.set_normal(n)
		st.add_vertex(xf * verts[vi])


static func stone_mesh(variant := 0, far := false) -> Mesh:
	var v_mod := posmod(variant, 3)
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bounds: Array[AABB] = []
	var specs := stone_specs(v_mod)
	for si in specs.size():
		var spec: Vector4 = specs[si]
		var s_seed := int(spec.w) * 7 + 13
		var sz := Vector3(1.22, 0.56, 0.88) * spec.z
		var lod := 1 if (far or spec.z < 0.25) else 0
		var stone := RockModels.stone_block(sz, s_seed, 0.16, 0.56 + 0.06 * float(si % 2), lod, -0.04)
		var xf := Transform3D(Basis(Vector3.UP, (si - 0.5) * 0.65), Vector3(spec.x, 0.0, spec.y))
		bounds.append(xf * stone.get_aabb())
		_append_mesh_clean(tool, stone, xf)
		# На ближнем LOD россыпи добавляем мелкую щебёнку прямо в следе главного камня.
		if not far and v_mod == 0 and si < 2:
			var chip_sz := Vector3(0.10, 0.052, 0.085) * (0.9 + 0.2 * float(si))
			var chip := RockModels.stone_block(chip_sz, s_seed + 43, 0.06, 0.52, 1, -0.03)
			var off := Vector3(0.15 if si == 0 else -0.13, 0.0, -0.11 if si == 0 else 0.14)
			_append_mesh_clean(tool, chip, Transform3D(Basis(Vector3.UP, 1.1 + si * 2.1), Vector3(spec.x, 0.0, spec.y) + off))
	_stone_bounds[v_mod] = bounds
	tool.index()
	return tool.commit()


static func stone_bounds(variant: int) -> Array:
	if not _stone_bounds.has(posmod(variant, 3)): stone_mesh(variant)
	return _stone_bounds[posmod(variant, 3)]


static func ground_moisture(moist: float, dist_water: float) -> float:
	return clampf(moist + maxf(0.0, 1.0 - dist_water / 3.0) * 0.2, 0.0, 1.0)


static func rockiness(w: WorldData, k: int) -> float:
	return Surface.exposure(w.elev[k],w.slope[k],w.moist[k])


## Линейные RGBA-данные: фактический полог, доля хвойных, влажность, каменистость.
## Один проход по деревьям вместо поиска соседей для каждой клетки всей карты.
## moist — влажность мира после эрозии (Heightfield.ground_moisture); без неё — w.moist (Тип 1, инструменты).
## Каменистость (rock) по-прежнему от полей мира: её считает и генерация, и карта.
static func surface_image(w: WorldData, moist := PackedFloat32Array()) -> Image:
	if w.generation.surface_rock.size()!=w.N:
		w.generation.surface_rock=Surface.field(w.elev,w.slope,w.moist)
	var rock := w.generation.surface_rock
	var wet := moist if moist.size() == w.N else w.moist
	var native := Grid.fast_grid()
	if native != null:
		var trees := PackedByteArray()
		var water := PackedByteArray()
		for kind in Biomes.CROWN_RADIUS.size():
			trees.append(2 if Biomes.is_conifer(kind) else int(Biomes.is_tree(kind)))
		for biome: Dictionary in Biomes.LIST:
			water.append(int(biome.get("water", false)))
		var pixels: PackedByteArray = native.ForestSurface(w.W, w.H, w.obj_count, w.obj_x, w.obj_y, w.obj_k, w.obj_s,
			trees, PackedFloat64Array(Biomes.CROWN_RADIUS), w.biome, water, w.river, wet, w.dist_water, rock)
		return Image.create_from_data(w.W, w.H, false, Image.FORMAT_RGBA8, pixels)
	var cover := PackedFloat32Array()
	var needles := PackedFloat32Array()
	cover.resize(w.N)
	needles.resize(w.N)
	for o in w.obj_count:
		var kind := w.obj_k[o]
		if not Biomes.is_tree(kind):
			continue
		var r: float = Biomes.CROWN_RADIUS[kind] * w.obj_s[o] + 0.5
		var ox := w.obj_x[o]
		var oy := w.obj_y[o]
		for j in range(maxi(0, floori(oy - r)), mini(w.H, ceili(oy + r))):
			for i in range(maxi(0, floori(ox - r)), mini(w.W, ceili(ox + r))):
				var k := j * w.W + i
				var weight := maxf(0.0, 1.0 - Vector2(i + 0.5 - ox, j + 0.5 - oy).length() / r)
				cover[k] += weight
				if Biomes.is_conifer(kind):
					needles[k] += weight
	var bytes := PackedByteArray()
	bytes.resize(w.N * 4)
	for k in w.N:
		var dry_ground: bool = not Biomes.LIST[w.biome[k]].get("water", false) and w.river[k] == 0
		bytes[k * 4] = roundi(minf(1.0, cover[k]) * 255.0) if dry_ground else 0
		bytes[k * 4 + 1] = roundi(needles[k] / maxf(cover[k], 0.001) * 255.0)
		bytes[k * 4 + 2] = roundi(ground_moisture(wet[k], w.dist_water[k]) * 255.0)
		bytes[k * 4 + 3] = rock[k] if dry_ground else 0
	return Image.create_from_data(w.W, w.H, false, Image.FORMAT_RGBA8, bytes)


static func weights(cover: float, conifer: float, wet: float, light: float, rocky: float) -> PackedFloat32Array:
	var sheltered := cover * (1.0 - rocky * 0.6)
	var out := PackedFloat32Array([
		sheltered * (1.0 - conifer) * 0.65,
		sheltered * conifer * 0.65,
		cover * 0.13,
		0.0, # корни привязаны к настоящим стволам
		sheltered * (1.0 - wet) * 0.035,
		sheltered * wet * 0.035,
		cover * (0.012 + light * 0.02 + (1.0 - wet) * 0.015),
		rocky * (0.25 + cover * 0.2),
		cover * (0.012 + (1.0 - wet) * 0.01),
		cover * (0.008 + rocky * 0.05),
		0.0, # ветки кладёт только RoadObstacles на полотно
		0.0, # корень через тропу — тоже RoadObstacles, от настоящего ствола
	])
	out.resize(COUNT)
	return out


static func _beam(a: Vector3, b: Vector3, radius: float, sides := 6, caps := false) -> Array:
	var delta := b - a
	var part := Models._cyl(radius * 0.72, radius, delta.length(), sides, caps)
	return [part[0], Transform3D(Basis(Quaternion(Vector3.UP, delta.normalized())), a) * part[1]]


## Исправляет порядок обхода треугольника, чтобы лицевая сторона всегда смотрела по outward_dir (CW для Godot).
static func _push_tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, c0: Color, c1: Color, c2: Color, n0: Vector3, n1: Vector3, n2: Vector3, outward_dir: Vector3) -> void:
	var cross_v := (p2 - p0).cross(p1 - p0)
	if cross_v.length_squared() < 1e-11:
		return
	var flip := cross_v.dot(outward_dir) < 0.0
	st.set_color(c0); st.set_normal(n0); st.add_vertex(p0)
	if flip:
		st.set_color(c2); st.set_normal(n2); st.add_vertex(p2)
		st.set_color(c1); st.set_normal(n1); st.add_vertex(p1)
	else:
		st.set_color(c1); st.set_normal(n1); st.add_vertex(p1)
		st.set_color(c2); st.set_normal(n2); st.add_vertex(p2)


static func _frame_step(prev_dir: Vector3, dir: Vector3, side: Vector3) -> Array[Vector3]:
	var q := Quaternion(prev_dir, dir)
	var new_side := (q * side).normalized()
	new_side = (new_side - dir * new_side.dot(dir))
	if new_side.length_squared() < 1e-6:
		var ref := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.9 else Vector3.FORWARD
		new_side = dir.cross(ref).normalized()
	else:
		new_side = new_side.normalized()
	var new_up := new_side.cross(dir).normalized()
	return [new_side, new_up]


## Органический ствол/ветка/корень по кривой path без дубликатов шва и без донных крышек.
static func _add_wood_tube(st: SurfaceTool, path: Array, radii: Array, sides: int, base_col: Color, opts := {}) -> void:
	var n_pts := path.size()
	if n_pts < 2:
		return
	var seed := int(opts.get("seed", 17))
	var flare0 := float(opts.get("flare0", 1.0))
	var flare1 := float(opts.get("flare1", 1.0))
	var flutes := int(opts.get("flutes", 4))
	var flute_amp := float(opts.get("flute_amp", 0.07))
	var ao_ground := bool(opts.get("ao_ground", true))
	var sun_bleach := float(opts.get("sun_bleach", 0.14))
	var moss_str := float(opts.get("moss", 0.0))
	var cap0 := int(opts.get("cap0", CAP_CUT))
	var cap1 := int(opts.get("cap1", CAP_CUT))
	var min_y_clamp := float(opts.get("min_y", -999.0))
	var far := bool(opts.get("far", false))
	var horizontal := bool(opts.get("horizontal", true))

	var dirs: Array[Vector3] = []
	var sides_v: Array[Vector3] = []
	var ups_v: Array[Vector3] = []
	var dir0: Vector3 = (path[1] - path[0]).normalized()
	var ref0 := Vector3.UP if absf(dir0.dot(Vector3.UP)) < 0.9 else Vector3.FORWARD
	var s0 := dir0.cross(ref0).normalized()
	var u0 := s0.cross(dir0).normalized()
	for k in n_pts:
		var d: Vector3 = (path[mini(k + 1, n_pts - 1)] - path[maxi(k - 1, 0)]).normalized()
		if k > 0:
			var step := _frame_step(dirs[k - 1], d, sides_v[k - 1])
			s0 = step[0]
			u0 = step[1]
		dirs.append(d)
		sides_v.append(s0)
		ups_v.append(u0)

	var ring_pos: Array = []
	var ring_col: Array = []
	var ring_nrm: Array = []
	var ring_rad: Array[float] = []
	for k in n_pts:
		var t := float(k) / float(n_pts - 1)
		var r_base := lerpf(float(radii[0]), float(radii[-1]), t)
		if radii.size() == n_pts:
			r_base = float(radii[k])
		if t < 0.25:
			r_base *= lerpf(flare0, 1.0, smoothstep(0.0, 0.25, t))
		if t > 0.78:
			r_base *= lerpf(1.0, flare1, smoothstep(0.78, 1.0, t))
		ring_rad.append(r_base)
		var pos_row: Array[Vector3] = []
		var col_row: Array[Color] = []
		var nrm_row: Array[Vector3] = []
		var c: Vector3 = path[k]
		var sv: Vector3 = sides_v[k]
		var uv: Vector3 = ups_v[k]
		for j in sides:
			var a := j * TAU / float(sides)
			var rad := (sv * cos(a) + uv * sin(a)).normalized()
			var twist := t * float(opts.get("twist", 0.5))
			var flute_wave := sin(a * float(flutes) + twist + float(seed) * 0.7)
			var flute_w := flute_amp * (1.8 if (k == 0 and flare0 > 1.1) else 1.0)
			var noise_r := (Models._noise3(c * 2.1 + rad * 1.4, seed + 5) - 0.5) * 0.14
			var rr := maxf(0.004, r_base * (1.0 + flute_wave * flute_w + noise_r))
			var p := c + rad * rr
			var nrm := rad
			if min_y_clamp > -100.0 and p.y <= min_y_clamp + 0.035:
				p.y = maxf(p.y, min_y_clamp)
				if nrm.y < -0.35:
					nrm = Vector3(nrm.x, -0.35, nrm.z).normalized()
			pos_row.append(p)
			nrm_row.append(nrm)
			var shade := 0.86 + 0.16 * flute_wave + 0.10 * sin(a * 2.0 + t * 5.0)
			if ao_ground:
				var g_t := smoothstep(-0.02, 0.18 if horizontal else 0.28, p.y)
				shade *= lerpf(0.56, 1.04, g_t)
			var up_dot := rad.y
			if up_dot < -0.25:
				shade *= lerpf(1.0, 0.68, smoothstep(-0.25, -0.85, up_dot))
			var vc := base_col * shade
			if sun_bleach > 0.0 and up_dot > 0.2:
				var bleach_n := smoothstep(0.38, 0.78, Models._noise3(p * 2.7, seed + 23))
				vc = vc.lerp(Color(0.52, 0.49, 0.44) * shade, sun_bleach * smoothstep(0.2, 0.75, up_dot) * bleach_n)
			if moss_str > 0.0 and up_dot > 0.08:
				var mp := smoothstep(0.32, 0.76, Models._noise3(p * 1.9, seed + 41)) * smoothstep(0.08, 0.72, up_dot) * moss_str
				vc = vc.lerp(MOSS_DARK.lerp(MOSS_MID, clampf(up_dot, 0.0, 1.0)), clampf(mp, 0.0, 0.85))
			col_row.append(vc)
		ring_pos.append(pos_row)
		ring_col.append(col_row)
		ring_nrm.append(nrm_row)

	for k in n_pts - 1:
		var c_mid: Vector3 = (path[k] + path[k + 1]) * 0.5
		for j in sides:
			var jn := (j + 1) % sides
			var p00: Vector3 = ring_pos[k][j]
			var p01: Vector3 = ring_pos[k][jn]
			var p10: Vector3 = ring_pos[k + 1][j]
			var p11: Vector3 = ring_pos[k + 1][jn]
			var out_d := ((p00 + p01 + p10 + p11) * 0.25 - c_mid)
			for tri_i in 2:
				var va := p00 if tri_i == 0 else p10
				var vb := p10 if tri_i == 0 else p11
				var vc := p01
				if min_y_clamp > -100.0 and maxf(va.y, maxf(vb.y, vc.y)) <= min_y_clamp + 0.042:
					var fn := (vc - va).cross(vb - va)
					if fn.length_squared() < 1e-11:
						continue
					var fn_dir := fn.normalized()
					if fn_dir.dot(out_d) < 0.0:
						fn_dir = -fn_dir
					if fn_dir.y < -0.22:
						continue
				if tri_i == 0:
					_push_tri(st, p00, p10, p01, ring_col[k][j], ring_col[k + 1][j], ring_col[k][jn], ring_nrm[k][j], ring_nrm[k + 1][j], ring_nrm[k][jn], out_d)
				else:
					_push_tri(st, p10, p11, p01, ring_col[k + 1][j], ring_col[k + 1][jn], ring_col[k][jn], ring_nrm[k + 1][j], ring_nrm[k + 1][jn], ring_nrm[k][jn], out_d)

	if cap0 == CAP_CUT:
		_add_wood_cap(st, path[0], -dirs[0], ring_pos[0], base_col)
	elif cap0 == CAP_SPLINTER:
		_add_splinter_cap(st, path[0], -dirs[0], ring_pos[0], ring_rad[0], seed + 7, far)
	elif cap0 == CAP_HOLLOW:
		_add_hollow_cavity(st, path[0], dirs[0], ring_pos[0], ring_rad[0], seed + 13, far)

	if cap1 == CAP_CUT:
		_add_wood_cap(st, path[-1], dirs[-1], ring_pos[-1], base_col)
	elif cap1 == CAP_SPLINTER:
		_add_splinter_cap(st, path[-1], dirs[-1], ring_pos[-1], ring_rad[-1], seed + 31, far)
	elif cap1 == CAP_HOLLOW:
		_add_hollow_cavity(st, path[-1], -dirs[-1], ring_pos[-1], ring_rad[-1], seed + 47, far)


static func _add_wood_cap(st: SurfaceTool, center: Vector3, out_dir: Vector3, rim: Array[Vector3], bark_col: Color) -> void:
	var sides := rim.size()
	var heart_center := center + out_dir * 0.014
	var rim_in := WOOD * 1.02
	var heart := WOOD.darkened(0.18)
	var bevel_col := bark_col.lerp(WOOD, 0.45)
	var inner_pts: Array[Vector3] = []
	for j in sides:
		inner_pts.append(center.lerp(rim[j], 0.78) + out_dir * 0.012)
	for j in sides:
		var jn := (j + 1) % sides
		var n_bevel := ((rim[j] - center).normalized() * 0.55 + out_dir).normalized()
		var n_bevel2 := ((rim[jn] - center).normalized() * 0.55 + out_dir).normalized()
		_push_tri(st, rim[j], inner_pts[j], rim[jn], bevel_col, rim_in, bevel_col, n_bevel, out_dir, n_bevel2, out_dir)
		_push_tri(st, inner_pts[j], inner_pts[jn], rim[jn], rim_in, rim_in, bevel_col, out_dir, out_dir, n_bevel2, out_dir)
		_push_tri(st, inner_pts[j], heart_center, inner_pts[jn], rim_in, heart, rim_in, out_dir, out_dir, out_dir, out_dir)


## Несимметричные зубчатые щепки на обломе ствола/сухостоя/пня (один треугольник-клин на ребро, не веер кубиков).
static func _add_splinter_cap(st: SurfaceTool, center: Vector3, out_dir: Vector3, rim: Array[Vector3], radius: float, seed: int, far: bool) -> void:
	var sides := rim.size()
	var recess := center - out_dir * (radius * 0.35)
	var dark_core := WOOD.darkened(0.38)
	var mid_wood := WOOD.darkened(0.18)
	var tip_wood := WOOD.lerp(BARK, 0.22)
	for j in sides:
		var jn := (j + 1) % sides
		var h1 := WGRandom.hash2(seed, j, 5)
		var h2 := WGRandom.hash2(seed, jn, 7)
		if far or (j % 2 == 1 and h1 < 0.45):
			# Неглубокий ступенчатый скол по волокнам
			var p_in := center.lerp(rim[j], 0.55) + out_dir * (radius * (0.15 + 0.45 * h1))
			var n_s := ((rim[j] + rim[jn]) * 0.5 - center + out_dir * 1.4).normalized()
			_push_tri(st, rim[j], p_in, rim[jn], mid_wood, tip_wood, mid_wood, n_s, n_s, n_s, out_dir)
			_push_tri(st, p_in, recess, rim[jn], tip_wood, dark_core, mid_wood, out_dir, out_dir, out_dir, out_dir)
		else:
			# Вырванный щеповый язык древесины (трёхгранный клин без висячих палок)
			var mid_rim := rim[j].lerp(rim[jn], 0.5)
			var radial_in := (center - mid_rim).normalized()
			var tip_len := radius * (0.65 + 1.05 * h1)
			var tip := mid_rim.lerp(center, 0.25 + 0.22 * h2) + out_dir * tip_len + radial_in * (radius * 0.08)
			var base_in := center.lerp(mid_rim, 0.45) - out_dir * (radius * 0.18)
			var n_out := (mid_rim - center + out_dir * 0.45).normalized()
			var n_side1 := (rim[j] - rim[jn]).cross(tip - rim[j]).normalized()
			if n_side1.dot(mid_rim - center + out_dir) < 0.0: n_side1 = -n_side1
			_push_tri(st, rim[j], tip, rim[jn], BARK.lerp(WOOD, 0.45), tip_wood, BARK.lerp(WOOD, 0.45), n_out, n_out, n_out, n_out)
			_push_tri(st, rim[j], base_in, tip, mid_wood, dark_core, tip_wood, n_side1, radial_in, n_side1, radial_in + out_dir * 0.3)
			_push_tri(st, base_in, rim[jn], tip, dark_core, mid_wood, tip_wood, radial_in, -n_side1, -n_side1, radial_in + out_dir * 0.3)
			_push_tri(st, base_in, recess, rim[jn], dark_core, dark_core, mid_wood, out_dir, out_dir, out_dir, out_dir)
			_push_tri(st, rim[j], recess, base_in, mid_wood, dark_core, dark_core, out_dir, out_dir, out_dir, out_dir)


## Настоящее потемневшее дупло внутри поваленного бревна: конусная труба вглубь + неровная обломанная кромка.
static func _add_hollow_cavity(st: SurfaceTool, origin: Vector3, inward_dir: Vector3, outer_rim: Array[Vector3], radius: float, seed: int, far: bool) -> void:
	var sides := outer_rim.size()
	var depth := radius * (1.85 if far else 2.25)
	var r1 := origin + inward_dir * (depth * 0.42)
	var r2 := origin + inward_dir * depth
	var inner_rim: Array[Vector3] = []
	var inner_mid: Array[Vector3] = []
	var tooth_rim: Array[Vector3] = []
	for j in sides:
		var h := WGRandom.hash2(seed, j, 19)
		var p_out: Vector3 = outer_rim[j]
		var in_p := origin.lerp(p_out, 0.68 + 0.12 * sin(float(j) * 2.1)) + inward_dir * (radius * 0.14 * h)
		inner_rim.append(in_p)
		inner_mid.append(r1.lerp(r1 + (p_out - origin), 0.56))
		# Рваная корончатая кромка вокруг зева дупла
		var tooth := p_out.lerp(in_p, 0.35) - inward_dir * (radius * (0.12 + 0.36 * h) if (j % 2 == 0 or h > 0.6) else -radius * 0.08)
		tooth_rim.append(tooth)
	var col_lip := BARK.lerp(WOOD, 0.52)
	var col_in := Color(0.24, 0.17, 0.11)
	var col_deep := Color(0.11, 0.08, 0.055)
	var col_back := Color(0.08, 0.06, 0.04)
	for j in sides:
		var jn := (j + 1) % sides
		var rad_out := ((outer_rim[j] + outer_rim[jn]) * 0.5 - origin).normalized()
		var n_front := -inward_dir
		_push_tri(st, outer_rim[j], tooth_rim[j], outer_rim[jn], BARK, col_lip, BARK, rad_out, n_front, rad_out, rad_out - inward_dir)
		_push_tri(st, tooth_rim[j], tooth_rim[jn], outer_rim[jn], col_lip, col_lip, BARK, n_front, n_front, rad_out, -inward_dir)
		_push_tri(st, tooth_rim[j], inner_rim[j], tooth_rim[jn], col_lip, col_in, col_lip, -rad_out + n_front, -rad_out, -rad_out + n_front, -inward_dir - rad_out * 0.4)
		_push_tri(st, inner_rim[j], inner_rim[jn], tooth_rim[jn], col_in, col_in, col_lip, -rad_out, -rad_out, -rad_out + n_front, -inward_dir - rad_out * 0.4)
		# Внутренняя стенка полости (смотрит внутрь оси бревна: -rad_out)
		_push_tri(st, inner_rim[j], inner_mid[j], inner_rim[jn], col_in, col_deep, col_in, -rad_out, -rad_out, -rad_out, -rad_out)
		_push_tri(st, inner_mid[j], inner_mid[jn], inner_rim[jn], col_deep, col_deep, col_in, -rad_out, -rad_out, -rad_out, -rad_out)
		_push_tri(st, inner_mid[j], r2, inner_mid[jn], col_deep, col_back, col_deep, -rad_out, n_front, -rad_out, -inward_dir)


## Естественные обволакивающие подушки мха с прогалинами голой коры и утопленными краями.
static func _add_moss_drape(st: SurfaceTool, path: Array, radii: Array, seed: int, far: bool, bias_side := 0.25) -> void:
	var n_pts := path.size()
	if n_pts < 2:
		return
	var segs := 5 if far else 9
	var arcs := 3 if far else 4
	var grid_p: Array = []
	var grid_c: Array = []
	var grid_n: Array = []
	var grid_e: Array = []
	var spine_c: Array[Vector3] = []
	for s_i in segs + 1:
		var u := float(s_i) / float(segs)
		var fidx := u * float(n_pts - 1)
		var k0 := mini(int(floor(fidx)), n_pts - 2)
		var lt := fidx - float(k0)
		var center: Vector3 = (path[k0] as Vector3).lerp(path[k0 + 1], lt)
		var tang: Vector3 = ((path[k0 + 1] as Vector3) - (path[k0] as Vector3)).normalized()
		var base_r := lerpf(float(radii[k0]), float(radii[k0 + 1]), lt)
		spine_c.append(center)
		var side_x := Vector3.UP.cross(tang).normalized()
		if side_x.length_squared() < 1e-4:
			side_x = Vector3.RIGHT
		var up_v := tang.cross(side_x).normalized()
		if up_v.y < 0.0:
			up_v = -up_v
			side_x = -side_x
		var end_fade := sin(u * PI)
		var cushion_n := Models._noise3(center * 1.45 + Vector3(0.4, 0.0, -0.3), seed + 11)
		var ripple := smoothstep(0.32, 0.68, cushion_n)
		var lobe_h := clampf(end_fade * (0.24 + 1.05 * ripple), 0.0, 1.0)
		var arc_span := lerpf(0.36, 1.10, lobe_h)
		var p_row: Array[Vector3] = []
		var c_row: Array[Color] = []
		var n_row: Array[Vector3] = []
		var e_row: Array[float] = []
		for a_i in arcs + 1:
			var v := float(a_i) / float(arcs) * 2.0 - 1.0
			var theta := (v + bias_side * (1.0 - absf(v))) * arc_span
			var radial := (up_v * cos(theta) + side_x * sin(theta)).normalized()
			var puff := Models._noise3(center * 3.1 + radial * 2.2, seed + 29)
			var local_gap := smoothstep(0.24, 0.66, cushion_n * 0.72 + puff * 0.32)
			var edge := (1.0 - v * v) * end_fade * local_gap
			# В сухих разрывах и по кромке край уходит чуть внутрь коры (edge <= 0 -> -0.020).
			var thick := lerpf(-0.020, base_r * (0.16 + 0.15 * puff) + 0.036, clampf(edge * 1.25, 0.0, 1.0))
			var vp := center + radial * (base_r + thick)
			p_row.append(vp)
			n_row.append((radial + Vector3.UP * 0.25).normalized())
			e_row.append(edge)
			var crest := clampf(edge * 0.80 + puff * 0.34, 0.0, 1.0)
			var mc := MOSS_DARK.lerp(MOSS_MID, smoothstep(0.06, 0.58, crest)).lerp(MOSS_TIP, smoothstep(0.55, 0.94, crest))
			c_row.append(mc)
		grid_p.append(p_row)
		grid_c.append(c_row)
		grid_n.append(n_row)
		grid_e.append(e_row)
	for s_i in segs:
		var c_mid := (spine_c[s_i] + spine_c[s_i + 1]) * 0.5
		for a_i in arcs:
			var max_e := maxf(maxf(float(grid_e[s_i][a_i]), float(grid_e[s_i + 1][a_i])), maxf(float(grid_e[s_i][a_i + 1]), float(grid_e[s_i + 1][a_i + 1])))
			if max_e <= 0.03:
				continue
			var p00: Vector3 = grid_p[s_i][a_i]
			var p01: Vector3 = grid_p[s_i][a_i + 1]
			var p10: Vector3 = grid_p[s_i + 1][a_i]
			var p11: Vector3 = grid_p[s_i + 1][a_i + 1]
			var out_d := (p00 + p01 + p10 + p11) * 0.25 - c_mid
			_push_tri(st, p00, p10, p01, grid_c[s_i][a_i], grid_c[s_i + 1][a_i], grid_c[s_i][a_i + 1], grid_n[s_i][a_i], grid_n[s_i + 1][a_i], grid_n[s_i][a_i + 1], out_d)
			_push_tri(st, p10, p11, p01, grid_c[s_i + 1][a_i], grid_c[s_i + 1][a_i + 1], grid_c[s_i][a_i + 1], grid_n[s_i + 1][a_i], grid_n[s_i + 1][a_i + 1], grid_n[s_i][a_i + 1], out_d)


## Трутовики-полки на старой древесине (2-3 полукруга без закрытого донца).
static func _add_fungi_shelf(st: SurfaceTool, at: Vector3, out_dir: Vector3, radius: float, seed: int) -> void:
	var shelf_top := Color(0.46, 0.34, 0.22)
	var shelf_rim := Color(0.76, 0.68, 0.50)
	var side := Vector3.UP.cross(out_dir).normalized()
	if side.length_squared() < 1e-4:
		side = Vector3.RIGHT
	for k in 2:
		var o := at + Vector3.UP * (k * 0.042) + side * ((k - 0.5) * 0.045)
		var r := radius * (1.0 - k * 0.22)
		var p_l := o - side * r + out_dir * (r * 0.25)
		var p_m1 := o - side * (r * 0.45) + out_dir * (r * 0.92) + Vector3.UP * 0.008
		var p_m2 := o + side * (r * 0.45) + out_dir * (r * 0.92) + Vector3.UP * 0.006
		var p_r := o + side * r + out_dir * (r * 0.25)
		var root := o - out_dir * (r * 0.15)
		for tri: Array in [[root, p_l, p_m1], [root, p_m1, p_m2], [root, p_m2, p_r]]:
			var cols := [shelf_top.darkened(0.2 + 0.05 * float(seed % 3)), shelf_rim, shelf_rim]
			_push_tri(st, tri[0], tri[1], tri[2], cols[0], cols[1], cols[2], Vector3.UP, (out_dir * 0.4 + Vector3.UP).normalized(), (out_dir * 0.4 + Vector3.UP).normalized(), Vector3.UP)


## Крошечные пучки сухих осенних листьев или хвоинок на ветке (вместо круглого шара).
static func _add_leaf_spray(st: SurfaceTool, at: Vector3, dir: Vector3, seed: int, pine: bool, far: bool) -> void:
	var count := 2 if far else (6 if pine else 4)
	var side := dir.cross(Vector3.UP).normalized()
	if side.length_squared() < 1e-4:
		side = Vector3.RIGHT
	var up := side.cross(dir).normalized()
	var c0 := Color(0.36, 0.24, 0.12) if not pine else Color(0.42, 0.29, 0.14)
	var c1 := Color(0.56, 0.39, 0.19) if not pine else Color(0.54, 0.37, 0.18)
	for i in count:
		var a := (i - count * 0.5 + 0.5) * (0.45 if pine else 0.72) + (WGRandom.hash2(seed, i, 7) - 0.5) * 0.3
		var d := (dir * cos(a * 0.4) + side * sin(a) * 0.75 + up * (0.28 + 0.25 * float(i % 2))).normalized()
		var sw := side * cos(a) - dir * sin(a) * 0.3
		if pine:
			var l := 0.15 + 0.06 * float(i % 2)
			var w := 0.022 if far else 0.015
			var tip := at + d * l + Vector3.UP * 0.025
			_push_tri(st, at - sw * w, tip, at + sw * w, c0, c1, c0, (up + Vector3.UP).normalized(), Vector3.UP, (up + Vector3.UP).normalized(), Vector3.UP)
		else:
			var l := 0.14 + 0.05 * WGRandom.hash2(seed, i, 13)
			var w := 0.048
			var mid := at + d * (l * 0.52) + Vector3.UP * 0.018
			var tip := at + d * l
			var n_l := (up + Vector3.UP).normalized()
			_push_tri(st, at, mid - sw * w, mid + sw * w, c0, c1, c1 * 0.92, n_l, n_l, n_l, Vector3.UP)
			_push_tri(st, mid - sw * w, tip, mid + sw * w, c1, c1 * 1.05, c1 * 0.92, n_l, n_l, n_l, Vector3.UP)


static func _log_variant(variant: int, moss: bool, far: bool) -> Mesh:
	# variant: 0 = цельный, 1 = сломанный короткий, 2 = дуплистый / расщеплённый
	var broken := variant == 1
	var hollow := variant == 2 and not moss
	var split := variant == 2 and moss
	var b_x := 0.9 if broken else (1.85 if hollow else (1.35 if split else 2.1))
	var start_x := -2.15 if hollow else -2.2
	var a := Vector3(start_x, 0.20, -0.05)
	var b := Vector3(b_x, 0.15, -0.03)
	var span := b_x - start_x
	var segs := 4 if far else 5
	var path: Array[Vector3] = []
	var radii: Array[float] = []
	for k in segs:
		var t := float(k) / float(segs - 1)
		var bow_z := sin(t * PI) * (0.12 if not broken else 0.07)
		var dip_y := sin(t * PI) * 0.035 - t * 0.04
		var p := Vector3(lerpf(start_x, b_x, t), 0.20 + dip_y, lerpf(a.z, b.z, t) + bow_z)
		path.append(p)
		radii.append(lerpf(0.24, 0.155 if broken else 0.145, t))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides := 5 if far else 7
	var bark := BARK.darkened(0.08 if moss else 0.02)
	_add_wood_tube(st, path, radii, sides, bark, {
		seed = 101 + variant * 17 + (50 if moss else 0),
		flare0 = 1.32,
		flutes = 4,
		flute_amp = 0.09,
		moss = 0.48 if moss else 0.10,
		sun_bleach = 0.08 if moss else 0.24,
		cap0 = CAP_HOLLOW if hollow else CAP_CUT,
		cap1 = CAP_SPLINTER if (broken or split) else CAP_CUT,
		min_y = -0.015,
		far = far,
	})
	# Утолщённые при корнях сучья (воротник плавно вливается в ствол).
	var stub_count := 2 if far else 3
	for n in stub_count:
		var u := clampf(0.18 + float(n) * (0.24 if broken else 0.20), 0.12, 0.86)
		var fidx := u * float(segs - 1)
		var k0 := mini(int(floor(fidx)), segs - 2)
		var root_c: Vector3 = path[k0].lerp(path[k0 + 1], fidx - k0)
		var side := 1.0 if (n % 2 == 0) else -1.0
		var r_trunk := lerpf(radii[0], radii[-1], u) * 0.55
		var s_mid := root_c + Vector3(0.14, 0.10, side * 0.22)
		var s_tip := root_c + Vector3(0.32, 0.21 + 0.04 * float(n % 2), side * (0.48 + 0.12 * sin(n * 2.1)))
		_add_wood_tube(st, [root_c, s_mid, s_tip], [0.068, 0.042, 0.022], 4 if far else 5, bark.darkened(0.06), {
			seed = 211 + n * 19 + variant,
			flare0 = 1.45, flutes = 3, flute_amp = 0.05,
			cap0 = CAP_NONE, cap1 = CAP_SPLINTER if not far else CAP_CUT, far = far,
		})
	# Пара обломанных корневых лап у комля (только на крупном бревне, уходят к земле).
	for n in (2 if far else 3):
		var angle := (n - 1) * 0.72 + (0.15 if variant == 1 else -0.1)
		var rc := path[0] + Vector3(0.06, -0.02, 0.0)
		var rk := rc + Vector3(-0.22, 0.02 + 0.06 * float(n == 1), sin(angle) * 0.24)
		var rt := rc + Vector3(-0.40, -0.18, sin(angle) * 0.42)
		rt.y = maxf(rt.y, -0.015)
		_add_wood_tube(st, [rc, rk, rt], [0.088, 0.055, 0.028], 4 if far else 5, bark.darkened(0.12), {
			seed = 313 + n * 7, flare0 = 1.25, cap0 = CAP_NONE, cap1 = CAP_NONE, min_y = -0.015, far = far,
		})
	if moss:
		_add_moss_drape(st, path, radii, 401 + variant * 23, far, 0.28 if not split else -0.30)
		if not far and span > 2.5:
			_add_fungi_shelf(st, path[1] + Vector3(0.15, 0.04, radii[1] * 0.9), Vector3(0.1, 0.08, 0.99).normalized(), 0.095, 517 + variant)
	st.index()
	return st.commit()


static func _branch_variant(variant: int, far: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bark := BARK.lerp(Color(0.24, 0.19, 0.14), 0.35)
	var sides := 4 if far else 5
	if variant == 1:
		# Раздвоенная сухая корявая ветка (Y-форма).
		var main_p := [Vector3(-1.05, 0.05, -0.04), Vector3(-0.45, 0.07, 0.02), Vector3(0.18, 0.085, 0.06), Vector3(0.98, 0.06, 0.28)]
		_add_wood_tube(st, main_p, [0.054, 0.044, 0.036, 0.018], sides, bark, {seed = 611, cap0 = CAP_SPLINTER, cap1 = CAP_CUT, far = far, flutes = 3})
		var fork_p := [Vector3(-0.35, 0.072, 0.03), Vector3(0.28, 0.09, -0.22), Vector3(1.02, 0.05, -0.44)]
		_add_wood_tube(st, fork_p, [0.036, 0.026, 0.014], 4, bark.darkened(0.06), {seed = 617, flare0 = 1.35, cap0 = CAP_NONE, cap1 = CAP_CUT, far = far})
		for s in (1 if far else 3):
			var sp := Vector3(-0.15 + s * 0.42, 0.075, 0.04 if s != 1 else -0.18)
			var sd := Vector3(0.24, 0.06, -0.26 if s % 2 == 0 else 0.30)
			_add_wood_tube(st, [sp, sp + sd], [0.020, 0.008], 3 if far else 4, bark, {seed = 623 + s, flare0 = 1.3, cap0 = CAP_NONE, cap1 = CAP_NONE, far = far})
	elif variant == 2:
		# Сосновая лапа-ветка с сухими хвойными кистями на концах.
		var pine_p := [Vector3(-1.04, 0.055, 0.0), Vector3(-0.32, 0.072, 0.04), Vector3(0.38, 0.065, -0.03), Vector3(1.04, 0.045, 0.06)]
		_add_wood_tube(st, pine_p, [0.050, 0.038, 0.026, 0.014], sides, bark.darkened(0.08), {seed = 641, cap0 = CAP_SPLINTER, cap1 = CAP_NONE, far = far})
		for n in (3 if far else 5):
			var x := -0.70 + n * 0.38
			var side := 1.0 if n % 2 == 0 else -1.0
			var root_p := Vector3(x, 0.062, sin(float(n) * 1.3) * 0.03)
			var tip_p := root_p + Vector3(0.32, 0.04 + float(n % 2) * 0.025, side * (0.28 + 0.06 * float(n % 2)))
			_add_wood_tube(st, [root_p, root_p.lerp(tip_p, 0.55) + Vector3(0, 0.02, 0), tip_p], [0.022, 0.015, 0.008], 3 if far else 4, bark, {seed = 653 + n, flare0 = 1.3, cap0 = CAP_NONE, cap1 = CAP_NONE, far = far})
			if not far or n >= 2:
				_add_leaf_spray(st, tip_p - Vector3(0.06, 0, side * 0.04), (tip_p - root_p).normalized(), 671 + n, true, far)
	else:
		# Классическая изогнутая сухая ветка с сучьями и сухими листьями вместо круглого яйца.
		var branch_p := [Vector3(-1.06, 0.05, -0.02), Vector3(-0.42, 0.068, 0.05), Vector3(0.32, 0.062, 0.08), Vector3(1.06, 0.04, 0.02)]
		_add_wood_tube(st, branch_p, [0.052, 0.040, 0.028, 0.013], sides, bark, {seed = 683, cap0 = CAP_SPLINTER, cap1 = CAP_NONE, far = far, flutes = 3})
		for n in (3 if far else 5):
			var x := -0.78 + n * 0.39
			var side := 1.0 if n % 2 == 0 else -1.0
			var rp := Vector3(x, 0.058, 0.04)
			var mid_p := rp + Vector3(0.18, 0.035, side * 0.16)
			var tp := rp + Vector3(0.42, 0.025 + float(n % 3) * 0.018, side * (0.36 + 0.06 * cos(n)))
			_add_wood_tube(st, [rp, mid_p, tp], [0.024, 0.016, 0.008], 3 if far else 4, bark.darkened(0.05), {seed = 691 + n, flare0 = 1.35, cap0 = CAP_NONE, cap1 = CAP_NONE, far = far})
			if n >= 2 and (not far or n == 3):
				_add_leaf_spray(st, tp - Vector3(0.08, 0.0, side * 0.06), (tp - mid_p).normalized(), 701 + n, false, far)
	st.index()
	return st.commit()


static func _twig_variant(variant: int, far: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bark := BARK.lerp(Color(0.36, 0.30, 0.24), 0.28)
	var sides := 3 if far else 4
	var spine := [Vector3(-0.48, 0.028, -0.04), Vector3(-0.08, 0.048, 0.03), Vector3(0.28, 0.036, -0.02), Vector3(0.56, 0.024, 0.08)]
	if variant == 1:
		spine = [Vector3(-0.42, 0.024, 0.06), Vector3(-0.04, 0.046, -0.02), Vector3(0.30, 0.052, 0.05), Vector3(0.54, 0.026, -0.04)]
	_add_wood_tube(st, spine, [0.030, 0.024, 0.017, 0.009], sides, bark, {seed = 731 + variant * 13, cap0 = CAP_NONE, cap1 = CAP_NONE, far = far, flutes = 3})
	var spurs := 2 if far else 3
	for s in spurs:
		var u := 0.25 + float(s) * 0.28
		var fidx := u * float(spine.size() - 1)
		var k := mini(int(floor(fidx)), spine.size() - 2)
		var rp: Vector3 = spine[k].lerp(spine[k + 1], fidx - k)
		var side := -1.0 if (s + variant) % 2 == 0 else 1.0
		var ep := rp + Vector3(0.18 + 0.08 * float(s % 2), 0.018, side * (0.24 + 0.10 * float(s % 2)))
		_add_wood_tube(st, [rp, rp.lerp(ep, 0.5) + Vector3(0, 0.016, 0), ep], [0.016, 0.011, 0.006], 3, bark.darkened(0.08), {seed = 751 + s, cap0 = CAP_NONE, cap1 = CAP_NONE, far = far})
	st.index()
	return st.commit()


static func _snag_variant(variant: int, far: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var split := variant == 1
	var bark := Color(0.31, 0.26, 0.20)
	var sides := 5 if far else 7
	var spine := [
		Vector3(0.0, -0.02, 0.0),
		Vector3(0.02, 0.55, -0.01),
		Vector3(0.06, 1.45, -0.03),
		Vector3(0.08, 2.35 if split else 2.55, 0.02),
		Vector3(0.12 if not split else -0.08, 3.05 if split else 3.30, 0.05),
	]
	_add_wood_tube(st, spine, [0.22, 0.18, 0.145, 0.115, 0.075], sides, bark, {
		seed = 809 + variant * 19, flare0 = 1.42, flutes = 5, flute_amp = 0.11,
		sun_bleach = 0.42, moss = 0.22, horizontal = false, cap0 = CAP_NONE, cap1 = CAP_SPLINTER, min_y = -0.02, far = far,
	})
	if split:
		var limb := [Vector3(0.06, 1.85, 0.0), Vector3(0.28, 2.48, 0.14), Vector3(0.42, 3.02, 0.22)]
		_add_wood_tube(st, limb, [0.095, 0.072, 0.045], 4 if far else 5, bark.lightened(0.08), {
			seed = 827, flare0 = 1.28, sun_bleach = 0.48, horizontal = false, cap0 = CAP_NONE, cap1 = CAP_SPLINTER, far = far,
		})
	for n in (2 if far else 4):
		var a := n * 2.15 + 0.5 + float(variant) * 0.9
		var h := 0.95 + n * 0.48
		var rp := Vector3(0.05, h, 0.0)
		var mp := rp + Vector3(cos(a) * 0.28, 0.22, sin(a) * 0.28)
		var ep := rp + Vector3(cos(a) * 0.58, 0.34 + 0.12 * sin(n * 1.7), sin(a) * 0.58)
		_add_wood_tube(st, [rp, mp, ep], [0.052, 0.034, 0.018], 4, bark.darkened(0.05), {
			seed = 841 + n, flare0 = 1.4, sun_bleach = 0.35, horizontal = false, cap0 = CAP_NONE, cap1 = CAP_NONE, far = far,
		})
	st.index()
	return st.commit()


static func _stump_variant(variant: int, far: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hollow := variant == 1
	var sides := 5 if far else 8
	var trunk_pts := [Vector3(0, -0.02, 0), Vector3(0.015, 0.17, 0.01), Vector3(0.025, 0.41 if hollow else 0.44, -0.01)]
	_add_wood_tube(st, trunk_pts, [0.35, 0.26, 0.22], sides, BARK, {
		seed = 863 + variant * 17, flare0 = 1.40, flutes = 5, flute_amp = 0.14,
		moss = 0.46, horizontal = false, cap0 = CAP_NONE, cap1 = CAP_HOLLOW if hollow else CAP_CUT, min_y = -0.02, far = far,
	})
	# Плавные корневые лапы-контрфорсы (5 шт.), уходящие в землю.
	var r_count := 4 if far else 5
	for n in r_count:
		var a := n * TAU / float(r_count) + 0.32 + sin(float(n) * 1.9) * 0.18
		var f := Vector3(cos(a), 0, sin(a))
		var perp := Vector3(-f.z, 0, f.x) * (0.06 if n % 2 == 0 else -0.06)
		var r0 := f * 0.12 + Vector3.UP * 0.24
		var r1 := f * 0.36 + perp * 0.5 + Vector3.UP * 0.11
		var r2 := f * (0.68 + 0.14 * float(n % 2)) + perp + Vector3(0, -0.02, 0)
		_add_wood_tube(st, [r0, r1, r2], [0.115, 0.068, 0.026], 4 if far else 5, BARK.darkened(0.08), {
			seed = 901 + n * 11, flare0 = 1.25, flutes = 3, flute_amp = 0.08, moss = 0.35, cap0 = CAP_NONE, cap1 = CAP_NONE, min_y = -0.02, far = far,
		})
	# Органический мох, стекающий по северному боку и в пазухи корней.
	var moss_path := [Vector3(-0.14, 0.18, 0.16), Vector3(-0.04, 0.41, 0.04), Vector3(0.11, 0.40, -0.06)]
	_add_moss_drape(st, moss_path, [0.11, 0.14, 0.08], 919 + variant, far, -0.22)
	if not far:
		_add_fungi_shelf(st, Vector3(0.21, 0.24, 0.08), Vector3(0.92, 0.1, 0.38).normalized(), 0.075, 929 + variant)
	st.index()
	return st.commit()


static func _roots_mesh(far: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 4 if far else 5
	for n in count:
		var a := n * TAU / float(count) + 0.28 + sin(float(n) * 1.9) * 0.15
		var f := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-f.z, 0, f.x)
		var s0 := side * (0.07 if n % 2 == 0 else -0.07)
		var p0 := f * 0.08 + Vector3.UP * 0.24
		var p1 := f * 0.42 + s0 * 0.7 + Vector3.UP * 0.11
		var p2 := f * 0.76 - s0 * 0.4 + Vector3.UP * 0.065
		var p3 := f * 1.18 + s0 * 0.3 + Vector3(0, -0.015, 0)
		_add_wood_tube(st, [p0, p1, p2, p3], [0.115, 0.078, 0.048, 0.020], 4 if far else 5, BARK.darkened(0.05), {
			seed = 947 + n * 13, flare0 = 1.24, flutes = 3, flute_amp = 0.09,
			moss = 0.25, cap0 = CAP_NONE, cap1 = CAP_NONE, min_y = -0.02, far = far,
		})
		if not far and n % 2 == 0:
			var sub := [p1, p1 + f * 0.28 + side * 0.22 + Vector3(0, -0.03, 0), p1 + f * 0.48 + side * 0.34 + Vector3(0, -0.10, 0)]
			sub[2].y = maxf(sub[2].y, -0.018)
			_add_wood_tube(st, sub, [0.048, 0.030, 0.014], 4, BARK.darkened(0.12), {seed = 967 + n, cap0 = CAP_NONE, cap1 = CAP_NONE, min_y = -0.02, far = far})
	st.index()
	return st.commit()


static func _log(moss: bool, broken := false) -> Mesh:
	return _log_variant(1 if broken else 0, moss, false)


static func expedition_variant(kind: int, roll: float, wet: float, old: float, rocky: float, cfg: WorldVegetationConfig = null) -> int:
	if cfg != null:
		var moss := cfg.mossy_boulder_share
		if kind == MOSS_LOG and roll < maxf(wet * (0.45 + old * 0.5), moss * (0.55 + 0.45 * wet)):
			var large := wet * (0.10 + 0.28 * old)
			if roll < large:
				return [NURSE_LOG_LONG, NURSE_LOG_HOLLOW, NURSE_LOG_PAIR][mini(2, int(roll * 3.0 / large))]
			return NURSE_LOG_SPLIT if roll < large + (1.0 - large) * 0.34 * moss else NURSE_LOG
		if kind == STUMP and roll < maxf(old * (0.40 + wet * 0.55), moss * (0.50 + 0.50 * old)):
			return ROOT_STUMP if roll < 0.28 * moss else (ROOT_PLATE if roll < 0.54 * moss else ROOT_UPTURNED)
		if kind == BOULDER and roll < maxf(wet * (0.42 + rocky * 0.52), moss * (0.45 + 0.55 * wet)):
			return MOSS_BOULDER_LOW if roll < 0.35 * moss else MOSS_BOULDER
		return kind
	if kind == MOSS_LOG and roll < wet * (0.45 + old * 0.5):
		var large := wet * (0.10 + 0.28 * old)
		if roll < large:
			return [NURSE_LOG_LONG, NURSE_LOG_HOLLOW, NURSE_LOG_PAIR][mini(2, int(roll * 3.0 / large))]
		return NURSE_LOG_SPLIT if roll < large + (1.0 - large) * 0.29 else NURSE_LOG
	if kind == STUMP and roll < old * (0.40 + wet * 0.55):
		return ROOT_STUMP if roll < 0.20 else (ROOT_PLATE if roll < 0.39 else ROOT_UPTURNED)
	if kind == BOULDER and roll < wet * (0.42 + rocky * 0.52):
		return MOSS_BOULDER_LOW if roll < 0.25 else MOSS_BOULDER
	return kind


static func _nurse_log(split: bool, far: bool) -> Mesh:
	var a := Vector3(-2.65, 0.25, -0.02)
	var b := Vector3(1.63 if split else 2.87, 0.16, -0.05)
	var mid1 := Vector3(-1.90, 0.29, 0.05)
	var mid2 := Vector3(-0.18, 0.26, 0.13)
	var path: Array[Vector3] = [a, mid1, mid2, a.lerp(b, 0.72) + Vector3(0, 0.03, 0.04), b]
	var r0 := 0.37
	var r1 := 0.21 if split else 0.14
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_wood_tube(st, path, [r0, r0 * 0.86, lerpf(r0, r1, 0.48), lerpf(r0, r1, 0.74), r1], 6 if far else 9, BARK.darkened(0.11), {
		seed = 1101 + (13 if split else 0), flare0 = 1.38, flutes = 5, flute_amp = 0.12,
		moss = 0.56, sun_bleach = 0.10, cap0 = CAP_CUT, cap1 = CAP_SPLINTER if split else CAP_CUT, min_y = -0.03, far = far,
	})
	for n in (3 if far else 5):
		var t := (n + 0.65) / 5.7
		var at := a.lerp(b, t) + Vector3(0, 0.02, 0.11)
		var side := 1.0 if n % 2 == 0 else -1.0
		var s_mid := at + Vector3(0.05, 0.14, side * 0.26)
		var tip := at + Vector3(-0.08 + n * 0.12, 0.26 - 0.02 * n, side * (0.50 + 0.08 * sin(n * 3.1)))
		_add_wood_tube(st, [at, s_mid, tip], [0.10 - 0.008 * n, 0.062 - 0.005 * n, 0.025], 4, BARK.darkened(0.06), {
			seed = 1129 + n, flare0 = 1.4, cap0 = CAP_NONE, cap1 = CAP_SPLINTER if not far else CAP_CUT, far = far,
		})
	var moss_radii := [r0 * 1.06, r0 * 0.86, lerpf(r0, r1, 0.48), lerpf(r0, r1, 0.74), r1]
	_add_moss_drape(st, path, moss_radii, 1151 + (19 if split else 0), far, 0.22 if not split else -0.24)
	if not far:
		_add_fungi_shelf(st, mid1 + Vector3(0.18, 0.04, r0 * 0.78), Vector3(0.08, 0.06, 0.99).normalized(), 0.105, 1171)
	st.index()
	return st.commit()


static func _large_nurse_log(kind: int, far: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hollow := kind == NURSE_LOG_HOLLOW
	for ti in LARGE_LOGS[kind].size():
		var trunk: Array = LARGE_LOGS[kind][ti]
		var a: Vector3 = trunk[0]
		var b: Vector3 = trunk[1]
		var r0: float = trunk[2]
		var r1: float = trunk[3]
		var p1 := a.lerp(b, 0.11) + Vector3(0.0, 0.05, 0.02)
		var p2 := a.lerp(b, 0.38) + Vector3(0.0, 0.06, -0.05)
		var p3 := a.lerp(b, 0.68) + Vector3(0.0, 0.04, 0.04)
		var path: Array[Vector3] = [a, p1, p2, p3, b]
		var rads := [r0, r0 * 0.88, lerpf(r0, r1, 0.38), lerpf(r0, r1, 0.70), r1]
		_add_wood_tube(st, path, rads, 6 if far else 10, BARK.darkened(0.13), {
			seed = 1201 + kind * 23 + ti * 7, flare0 = 1.40, flutes = 5, flute_amp = 0.13,
			moss = 0.60, sun_bleach = 0.08, cap0 = CAP_HOLLOW if hollow else CAP_CUT,
			cap1 = CAP_SPLINTER if (ti == 0 and kind == NURSE_LOG_LONG) else CAP_CUT, min_y = -0.04, far = far,
		})
		for n in (3 if far else 5):
			var t := (n + 0.75) / 6.2
			var p := a.lerp(b, t)
			var r := lerpf(r0, r1, t)
			var side := 1.0 if n % 2 == 0 else -1.0
			var mp := p + Vector3(0.18, r * 0.45, side * r * 0.75)
			var tip := p + Vector3(0.38 + 0.08 * n, r * (0.72 + 0.35 * sin(n * 1.3)), side * r * 1.38)
			_add_wood_tube(st, [p, mp, tip], [r * 0.25, r * 0.15, r * 0.06], 4, BARK.darkened(0.06), {
				seed = 1249 + n + ti * 13, flare0 = 1.42, cap0 = CAP_NONE, cap1 = CAP_SPLINTER if not far else CAP_CUT, far = far,
			})
		_add_moss_drape(st, path, [r0 * 1.04, r0 * 0.88, lerpf(r0, r1, 0.38), lerpf(r0, r1, 0.70), r1], 1283 + kind * 11 + ti * 17, far, 0.25 if ti % 2 == 0 else -0.25)
		if not far:
			var fern := Plants._sword_fern(true, false)
			var at := a.lerp(b, 0.31) + Vector3.UP * (r0 * 0.78)
			_append_mesh_clean(st, fern, Transform3D(Basis(Vector3.UP, 0.7 * float(ti)).scaled(Vector3.ONE * 0.43), at), Color("708f54"))
			_add_fungi_shelf(st, p2 + Vector3(0.0, -r0 * 0.10, lerpf(r0, r1, 0.38) * 0.82), Vector3(0.05, 0.10, 0.99).normalized(), 0.12, 1307 + kind + ti)
	st.index()
	return st.commit()


static func _sculpt_soil_disk(st: SurfaceTool, center: Vector3, radii: Vector3, rot_y: float, seed: int, far: bool) -> void:
	var geo := RockModels._geo_unit(2 if far else 1)
	var dirs: PackedVector3Array = geo.verts
	var tris: PackedInt32Array = geo.tris
	var basis := Basis(Vector3.UP, rot_y) * Basis(Vector3.FORWARD, 0.14)
	var positions := PackedVector3Array()
	var colors := PackedColorArray()
	positions.resize(dirs.size())
	colors.resize(dirs.size())
	var min_y := -0.025
	var loam := Color(0.15, 0.11, 0.075)
	var peat := Color(0.24, 0.175, 0.115)
	for i in dirs.size():
		var d := dirs[i]
		var clump := 0.72 + 0.34 * Models._noise3(d * 3.1, seed) + 0.22 * (Models._noise3(d * 6.8, seed + 13) - 0.5)
		var q := Vector3(d.x * 0.62, d.y * 1.04, d.z * 1.08) * clump
		if d.x > 0.10:
			q.x *= 0.56
		var p := center + basis * (q * radii)
		if p.y < min_y:
			p.y = min_y
		positions[i] = p
		var h_t := clampf((p.y - min_y) / maxf(radii.y * 1.4, 0.3), 0.0, 1.0)
		var n_tex := Models._noise3(d * 5.2, seed + 7)
		var ao := lerpf(0.50, 1.00, smoothstep(0.0, 0.45, h_t))
		var sc := loam.lerp(peat, n_tex) * ao
		var turf := smoothstep(0.38, 0.86, h_t) * smoothstep(-0.35, 0.45, -d.x) * smoothstep(0.36, 0.72, n_tex)
		sc = sc.lerp(MOSS_DARK.lerp(MOSS_MID, h_t), turf * 0.82)
		colors[i] = sc
	RockModels._emit_creased(st, positions, colors, tris, min_y + 0.035, true, 0.91)


static func _root_stump(variant: int, far: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var upright := variant == 0
	var sides := 5 if far else 7
	if upright:
		var trunk := [Vector3(0, -0.025, 0), Vector3(0.04, 0.45, -0.01), Vector3(0.14, 0.98, -0.04)]
		_add_wood_tube(st, trunk, [0.46, 0.36, 0.28], sides, BARK.darkened(0.08), {
			seed = 1409, flare0 = 1.42, flutes = 6, flute_amp = 0.14,
			moss = 0.52, horizontal = false, cap0 = CAP_NONE, cap1 = CAP_SPLINTER, min_y = -0.025, far = far,
		})
		for n in (4 if far else 6):
			var a := n * TAU / float(4 if far else 6) + 0.24 * cos(n * 2.3)
			var f := Vector3(cos(a), 0, sin(a))
			var perp := Vector3(-f.z, 0, f.x) * (0.09 if n % 2 == 0 else -0.09)
			var span := 0.85 + 0.32 * sin(n * 2.6)
			var p0 := f * 0.18 + Vector3.UP * 0.36
			var p1 := f * (span * 0.55) + perp * 0.6 + Vector3.UP * 0.15
			var p2 := f * span + perp + Vector3(0, -0.025, 0)
			_add_wood_tube(st, [p0, p1, p2], [0.16, 0.09, 0.034], 4 if far else 5, BARK.darkened(0.10), {
				seed = 1423 + n, flare0 = 1.25, flutes = 3, flute_amp = 0.09, moss = 0.38, cap0 = CAP_NONE, cap1 = CAP_NONE, min_y = -0.025, far = far,
			})
		_add_moss_drape(st, [Vector3(-0.24, 0.24, 0.18), Vector3(-0.08, 0.62, 0.06), Vector3(0.12, 0.88, -0.04)], [0.18, 0.22, 0.12], 1447, far, -0.3)
		if not far:
			_add_fungi_shelf(st, Vector3(0.32, 0.42, 0.14), Vector3(0.9, 0.1, 0.42).normalized(), 0.11, 1459)
	else:
		# ROOT_PLATE (1) и ROOT_UPTURNED (2): рваный земляной выворотень + поваленный комель + корни поверх щита.
		var center := Vector3(0.0, 0.70 if variant == 1 else 0.58, 0.0)
		var head := Vector3(0.62 if variant == 1 else 0.96, 0.42, 0.10)
		_sculpt_soil_disk(st, center + Vector3(-0.18, -0.14, 0.02), Vector3(0.32, 0.78, 0.92), 0.16, 1516 + variant * 31, far)
		_add_wood_tube(st, [center + Vector3(-0.08, -0.02, 0.0), center.lerp(head, 0.5), head], [0.40, 0.34, 0.27], sides, BARK.darkened(0.06), {
			seed = 1543 + variant * 11, flare0 = 1.28, flutes = 5, flute_amp = 0.12, moss = 0.34,
			cap0 = CAP_NONE, cap1 = CAP_SPLINTER, min_y = -0.025, far = far,
		})
		var rc := 4 if far else 6
		for n in rc:
			var a := n * TAU / float(rc) + 0.22 * cos(n * 2.1)
			var span := (1.55 if variant == 1 else 1.38) * (0.76 + 0.24 * sin(n * 2.4))
			var dir := Vector3(-0.14 + 0.34 * sin(a + 0.35), 0.76 * cos(a), 1.02 * sin(a))
			var start := center + Vector3(-0.02, 0.09 * cos(a), 0.11 * sin(a))
			var end := center + dir * span
			end.y = maxf(end.y, -0.025)
			var mid_off := Vector3(-0.02, 0.13 * sin(a * 2.0 + 0.5), 0.09 * cos(a))
			var knee := center.lerp(end, 0.48) + mid_off
			knee.y = maxf(knee.y, -0.015)
			var r_root := 0.15 - float(n % 4) * 0.014
			var is_air := end.y > 0.15
			_add_wood_tube(st, [start, knee, end], [r_root, r_root * 0.56, r_root * 0.22], 4, BARK.darkened(0.09), {
				seed = 1567 + n * 13 + variant, flare0 = 1.28, flutes = 3, flute_amp = 0.08,
				moss = 0.16, cap0 = CAP_NONE, cap1 = CAP_SPLINTER if (is_air and not far) else CAP_NONE, min_y = -0.025, far = far,
			})
			if not far and n % 2 == 0:
				var tip2 := knee + Vector3(-0.22, -0.14 + 0.08 * sin(n), 0.24 * signf(sin(a) + 0.1))
				tip2.y = maxf(tip2.y, -0.025)
				_add_wood_tube(st, [knee, knee.lerp(tip2, 0.55) + Vector3(-0.03, 0.03, 0), tip2], [r_root * 0.44, r_root * 0.26, r_root * 0.12], 4, BARK.darkened(0.13), {
					seed = 1597 + n, cap0 = CAP_NONE, cap1 = CAP_NONE, min_y = -0.025, far = far,
				})
	st.index()
	return st.commit()


static func meshes() -> Array[Mesh]:
	if not _shared_meshes.is_empty(): return _shared_meshes.duplicate()
	var list: Array[Mesh] = preload("res://scripts/render/asset_catalog.gd").get_catalog().floor_meshes.duplicate()
	if list.size() != COUNT:
		list = build_meshes()
	_shared_meshes = list
	return list.duplicate()


static func road_far_meshes() -> Dictionary:
	if _shared_far.is_empty():
		for v in 3:
			_shared_far[FIRST + variant_kind(STONES, v)] = stone_mesh(v, true)
			_shared_far[FIRST + variant_kind(ROOT_SPAN, v)] = root_span(v, true)
			_shared_far[FIRST + variant_kind(LOG, v)] = _log_variant(v, false, true)
			_shared_far[FIRST + variant_kind(MOSS_LOG, v)] = _log_variant(v, true, true)
			_shared_far[FIRST + variant_kind(BRANCH, v)] = _branch_variant(v, true)
		_shared_far[FIRST + BOULDER] = _boulder_variant(0, true)
		_shared_far[FIRST + BOULDER_CLUSTER] = _boulder_variant(1, true)
	return _shared_far


## 15.0: корень, пересекающий тропу (RoadObstacles.ROOT): единичная длина вдоль X (−0,5…0,5, от ствола к концу),
## растягивается по X на ширину полотна; толщина и изгибы поперёк (Z, м) при этом прежние. Корень то выходит из
## грунта нерегулярными участками, то уходит под него, у ствола толще. Три общих силуэта;
## их root_path/root_radius читают и меш, и контакты колёс (RoadObstacles.bump).
static func root_path(variant := 0) -> PackedVector3Array:
	var xs := [-0.5, -0.4, -0.3, -0.2, -0.1, 0.0, 0.1, 0.2, 0.3, 0.4, 0.5]
	var ys: Array = [[-0.065, -0.012, 0.018, 0.012, -0.03, -0.045, -0.005, 0.02, 0.008, -0.035, -0.075],
		[-0.04, 0.005, 0.025, 0.008, -0.025, -0.065, -0.055, -0.03, -0.012, -0.035, -0.07],
		[-0.06, -0.035, -0.02, -0.045, -0.025, 0.015, 0.028, -0.02, -0.035, -0.015, -0.06]][posmod(variant, 3)]
	var zs: Array = [[0.0, 0.06, 0.12, 0.1, 0.03, -0.05, -0.1, -0.08, -0.02, 0.05, 0.08],
		[0.0, -0.025, -0.06, -0.08, -0.04, 0.01, 0.07, 0.12, 0.15, 0.12, 0.10],
		[0.0, 0.05, 0.11, 0.10, 0.06, 0.02, -0.02, -0.07, -0.11, -0.14, -0.13]][posmod(variant, 3)]
	var path := PackedVector3Array()
	for i in xs.size(): path.append(Vector3(xs[i], ys[i], zs[i]))
	return path


static func root_radius(segment: int) -> float:
	return lerpf(0.062, 0.028, segment / 9.0)


static func root_span(variant := 0, far := false) -> Mesh:
	var path := root_path(variant)
	var pts: Array[Vector3] = []
	var rads: Array[float] = []
	for i in path.size():
		if far and i % 2 == 1 and i < path.size() - 1:
			continue
		pts.append(path[i])
		rads.append(root_radius(mini(i, 9)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bark := Color(0.22, 0.165, 0.115)
	_add_wood_tube(st, pts, rads, 4 if far else 6, bark, {
		seed = 1601 + variant * 19, flutes = 4, flute_amp = 0.11,
		moss = 0.22, cap0 = CAP_NONE, cap1 = CAP_NONE, min_y = -0.13, far = far,
	})
	var side_dir := Vector3(0.14, -0.068, 0.25 if variant % 2 == 0 else -0.25)
	_add_wood_tube(st, [path[3], path[3] + side_dir * 0.48 + Vector3(0, 0.015, 0), path[3] + side_dir], [0.028, 0.018, 0.008], 3 if far else 4, bark.darkened(0.08), {
		seed = 1637 + variant, flare0 = 1.3, cap0 = CAP_NONE, cap1 = CAP_NONE, min_y = -0.13, far = far,
	})
	if not far:
		var side_dir2 := Vector3(-0.12, -0.06, -0.21 if variant % 2 == 0 else 0.21)
		_add_wood_tube(st, [path[7], path[7] + side_dir2 * 0.55 + Vector3(0, 0.01, 0), path[7] + side_dir2], [0.022, 0.014, 0.006], 4, bark.darkened(0.10), {
			seed = 1657 + variant, flare0 = 1.25, cap0 = CAP_NONE, cap1 = CAP_NONE, min_y = -0.13, far = far,
		})
	st.index()
	return st.commit()


## Authored roots/logs keep their exact capsule endpoints and height. Reuse the
## same bark/beam construction, with small bends inside that physical envelope.
static func technical_wood(root: bool, variant := 0) -> Mesh:
	var parts: Array = []
	var radius := 0.05
	var bend := -1.0 if variant % 2 else 1.0
	var path := [Vector3(-0.5, radius, 0), Vector3(-0.16, radius * 1.05, bend * 0.008), Vector3(0.19, radius * 0.96, -bend * 0.006), Vector3(0.5, radius, 0)]
	for i in range(1, path.size()):
		parts.append([_beam(path[i - 1], path[i], radius * (0.95 if root else 1.0), 7, false), BARK])
	parts.append([_beam(path[0], path[0] + Vector3(0.002, 0, 0), radius * 0.82, 7, true), WOOD])
	parts.append([_beam(path[-1], path[-1] + Vector3(0.002, 0, 0), radius * 0.70, 6, true), WOOD])
	return Plants._colored(parts)


## 15.0: упрощённые модели для дальнего подлеска, ключ — индекс формы Floor (в catalog.far_forms: Floor.FIRST + вид).
static func build_far_meshes() -> Dictionary:
	return {
		TWIG: _twig_variant(0, true),
		TWIG_FORK: _twig_variant(1, true),
		ROOTS: _roots_mesh(true),
		LOG: _log_variant(0, false, true),
		LOG_BROKEN: _log_variant(1, false, true),
		LOG_HOLLOW: _log_variant(2, false, true),
		MOSS_LOG: _log_variant(0, true, true),
		MOSS_LOG_BROKEN: _log_variant(1, true, true),
		MOSS_LOG_SPLIT: _log_variant(2, true, true),
		SNAG: _snag_variant(0, true),
		SNAG_FORK: _snag_variant(1, true),
		STONES: stone_mesh(0, true),
		STONE_SINGLE: stone_mesh(1, true),
		STONES_PAIR: stone_mesh(2, true),
		STUMP: _stump_variant(0, true),
		STUMP_HOLLOW: _stump_variant(1, true),
		BOULDER: _boulder_variant(0, true),
		BOULDER_CLUSTER: _boulder_variant(1, true),
		BRANCH: _branch_variant(0, true),
		BRANCH_FORKED: _branch_variant(1, true),
		BRANCH_PINE: _branch_variant(2, true),
		ROOT_SPAN: root_span(0, true),
		ROOT_SPAN_B: root_span(1, true),
		ROOT_SPAN_C: root_span(2, true),
		NURSE_LOG: _nurse_log(false, true),
		NURSE_LOG_SPLIT: _nurse_log(true, true),
		ROOT_STUMP: _root_stump(0, true),
		ROOT_PLATE: _root_stump(1, true),
		ROOT_UPTURNED: _root_stump(2, true),
		MOSS_BOULDER: _moss_boulder(false, true),
		MOSS_BOULDER_LOW: _moss_boulder(true, true),
		NURSE_LOG_LONG: _large_nurse_log(NURSE_LOG_LONG, true),
		NURSE_LOG_HOLLOW: _large_nurse_log(NURSE_LOG_HOLLOW, true),
		NURSE_LOG_PAIR: _large_nurse_log(NURSE_LOG_PAIR, true),
	}


static func _boulder_variant(variant: int, far := false) -> Mesh:
	var m := RockModels.mesh(Vector3(1.04, 0.64, 0.88) if variant == 1 else Vector3(0.90, 0.64, 0.76),
		97 if variant == 1 else 90, 0.40 if variant == 1 else 0.45, 0.63)
	return m.get_meta("lod_meshes")[1] if far else m


static func _moss_boulder(low: bool, far := false) -> Mesh:
	var base := RockModels.mesh(Vector3(1.44, 0.72, 1.13) if low else Vector3(1.06, 1.20, 0.91),
		69 if low else 63, 0.80 if low else 0.72, 0.62)
	return base.get_meta("lod_meshes")[1] if far else base


static func build_meshes() -> Array[Mesh]:
	var leaves: Array = []
	var needles: Array = []
	# Несколько приподнятых желобчатых листьев и хвойных веточек поверх шейдерной подстилки.
	for n in 11:
		var a := n * 2.39996
		var p := Vector3(cos(a), 0.024, sin(a)) * (0.11 + n * 0.044)
		p.y = 0.022 + (n % 3) * 0.008
		var rot_a := a + sin(n * 1.7) * 0.6
		var f := Vector3(cos(rot_a), 0, sin(rot_a)) * (0.11 + (n % 2) * 0.025)
		var s := Vector3(-sin(rot_a), 0.014, cos(rot_a)) * 0.058
		leaves.append([p - f, p + s, p + f + Vector3.UP * 0.028, p - s])
		var thin := Vector3(-sin(rot_a), 0.004, cos(rot_a)) * 0.011
		needles.append([p - thin, p + thin, p + f * 1.35 + Vector3.UP * 0.012])
	return [
		Plants._leaves(leaves, Color(0.47, 0.35, 0.18), -1, false),
		Plants._leaves(needles, Color(0.40, 0.33, 0.19), -1, false),
		_twig_variant(0, false),
		_roots_mesh(false),
		_log_variant(0, false, false),
		_log_variant(0, true, false),
		_snag_variant(0, false),
		stone_mesh(0, false),
		_stump_variant(0, false),
		_boulder_variant(0, false),
		_branch_variant(0, false),
		root_span(0, false),
		root_span(1, false), root_span(2, false), stone_mesh(1, false), stone_mesh(2, false),
		_log_variant(1, false, false), _log_variant(1, true, false),
		_nurse_log(false, false), _nurse_log(true, false), _root_stump(0, false), _root_stump(1, false), _root_stump(2, false),
		_moss_boulder(false, false), _moss_boulder(true, false),
		_large_nurse_log(NURSE_LOG_LONG, false), _large_nurse_log(NURSE_LOG_HOLLOW, false), _large_nurse_log(NURSE_LOG_PAIR, false),
		_log_variant(2, false, false), _log_variant(2, true, false),
		_branch_variant(1, false), _branch_variant(2, false),
		_twig_variant(1, false), _snag_variant(1, false), _stump_variant(1, false), _boulder_variant(1, false),
	]


## Тот же радиальный полог, что у surface_image, для снимка реальных деревьев за краем плана.
static func canopy_image(rect: Rect2i, batches: Array) -> Image:
	var cover := PackedFloat32Array()
	var needles := PackedFloat32Array()
	cover.resize(rect.get_area())
	needles.resize(rect.get_area())
	for batch: Dictionary in batches:
		for o in batch.x.size():
			var kind: int = batch.k[o]
			if not Biomes.is_tree(kind): continue
			var r: float = Biomes.CROWN_RADIUS[kind] * batch.s[o] + 0.5
			var ox: float = batch.x[o]
			var oy: float = batch.y[o]
			for y in range(maxi(rect.position.y, floori(oy - r)), mini(rect.end.y, ceili(oy + r))):
				for x in range(maxi(rect.position.x, floori(ox - r)), mini(rect.end.x, ceili(ox + r))):
					var k := (y - rect.position.y) * rect.size.x + x - rect.position.x
					var weight := maxf(0.0, 1.0 - Vector2(x + 0.5 - ox, y + 0.5 - oy).length() / r)
					cover[k] += weight
					if Biomes.is_conifer(kind): needles[k] += weight
	var bytes := PackedByteArray()
	bytes.resize(rect.get_area() * 4)
	for k in cover.size():
		bytes[k * 4] = roundi(minf(1.0, cover[k]) * 255.0)
		bytes[k * 4 + 1] = roundi(needles[k] / maxf(cover[k], 0.001) * 255.0)
	return Image.create_from_data(rect.size.x, rect.size.y, false, Image.FORMAT_RGBA8, bytes)
