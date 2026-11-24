extends RefCounted
## 6.6+: подстилка и валежник. Только оформление готового мира.

const Plants := preload("res://scripts/render/understory_models.gd")
const Surface := preload("res://scripts/world/mountain_surface.gd")
enum { LEAVES, NEEDLES, TWIG, ROOTS, LOG, MOSS_LOG, SNAG, STONES, STUMP, BOULDER, BRANCH, ROOT_SPAN,
	ROOT_SPAN_B, ROOT_SPAN_C, STONE_SINGLE, STONES_PAIR, LOG_BROKEN, MOSS_LOG_BROKEN,
	NURSE_LOG, NURSE_LOG_SPLIT, ROOT_STUMP, ROOT_PLATE, ROOT_UPTURNED, MOSS_BOULDER, MOSS_BOULDER_LOW, NURSE_LOG_LONG, NURSE_LOG_HOLLOW, NURSE_LOG_PAIR, COUNT }
const FIRST := Plants.COUNT # смещение групп MultiMesh и запечённых far_forms, вне сохранений
const BARK := Color(0.29, 0.22, 0.15)
const WOOD := Color(0.49, 0.39, 0.25)
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


static func base_kind(kind: int) -> int:
	if kind in [ROOT_SPAN_B, ROOT_SPAN_C]: return ROOT_SPAN
	if kind in [STONE_SINGLE, STONES_PAIR]: return STONES
	if kind == LOG_BROKEN: return LOG
	if kind in [MOSS_LOG_BROKEN, NURSE_LOG, NURSE_LOG_SPLIT] or LARGE_LOGS.has(kind): return MOSS_LOG
	if kind in [ROOT_STUMP, ROOT_PLATE, ROOT_UPTURNED]: return STUMP
	if kind in [MOSS_BOULDER, MOSS_BOULDER_LOW]: return BOULDER
	return kind


static func variant_kind(kind: int, variant: int) -> int:
	if kind == ROOT_SPAN: return [ROOT_SPAN, ROOT_SPAN_B, ROOT_SPAN_C][posmod(variant, 3)]
	if kind == STONES: return [STONES, STONE_SINGLE, STONES_PAIR][posmod(variant, 3)]
	if kind == LOG and variant % 2: return LOG_BROKEN
	if kind == MOSS_LOG and variant % 2: return MOSS_LOG_BROKEN
	return kind


static func log_span(kind: int) -> Vector2:
	if kind in [NURSE_LOG, NURSE_LOG_SPLIT]:
		return Vector2(-2.65, 1.63 if kind == NURSE_LOG_SPLIT else 2.87)
	return Vector2(-2.2, 0.9 if kind in [LOG_BROKEN, MOSS_LOG_BROKEN] else 2.1)


## Shared by near/far rendering and wheel contacts. No invisible central dome.
static func stone_specs(variant := 0) -> Array[Vector4]:
	match posmod(variant, 3):
		1: return [Vector4(0.0, 0.0, 0.31, 304)]
		2: return [Vector4(-0.23, 0.05, 0.28, 302), Vector4(0.26, -0.12, 0.19, 305)]
	return [Vector4(-0.34, 0.12, 0.21, 300), Vector4(0.23, -0.18, 0.30, 303), Vector4(0.43, 0.30, 0.13, 301)]


static func stone_mesh(variant := 0, far := false) -> Mesh:
	var tool := SurfaceTool.new()
	var bounds: Array[AABB] = []
	for spec: Vector4 in stone_specs(variant):
		var stone := Models.boulder(Vector3(1.2, 0.55, 0.85) * spec.z, int(spec.w), 0.35, 0.5)
		var xf := Transform3D(Basis(), Vector3(spec.x, 0.0, spec.y))
		bounds.append(xf * stone.get_aabb())
		tool.append_from(stone.get_meta("lod_meshes")[1] if far else stone, 0, xf)
	_stone_bounds[posmod(variant, 3)] = bounds
	return tool.commit()


static func stone_bounds(variant: int) -> Array:
	if not _stone_bounds.has(posmod(variant, 3)): stone_mesh(variant)
	return _stone_bounds[posmod(variant, 3)]


static func moisture_at(w: WorldData, k: int) -> float:
	return ground_moisture(w.moist[k], w.dist_water[k])


static func ground_moisture(moist: float, dist_water: float) -> float:
	return clampf(moist + maxf(0.0, 1.0 - dist_water / 3.0) * 0.2, 0.0, 1.0)


static func rockiness(w: WorldData, k: int) -> float:
	return Surface.exposure(w.elev[k],w.slope[k],w.moist[k])


## Линейные RGBA-данные: фактический полог, доля хвойных, влажность, каменистость.
## Один проход по деревьям вместо поиска соседей для каждой клетки всей карты.
static func surface_image(w: WorldData) -> Image:
	if w.generation.surface_rock.size()!=w.N:
		w.generation.surface_rock=Surface.field(w.elev,w.slope,w.moist)
	var rock := w.generation.surface_rock
	var native := Grid.fast_grid()
	if native != null:
		var trees := PackedByteArray()
		var water := PackedByteArray()
		for kind in Biomes.CROWN_RADIUS.size():
			trees.append(2 if Biomes.is_conifer(kind) else int(Biomes.is_tree(kind)))
		for biome: Dictionary in Biomes.LIST:
			water.append(int(biome.get("water", false)))
		var pixels: PackedByteArray = native.ForestSurface(w.W, w.H, w.obj_count, w.obj_x, w.obj_y, w.obj_k, w.obj_s,
			trees, PackedFloat64Array(Biomes.CROWN_RADIUS), w.biome, water, w.river, w.moist, w.dist_water, rock)
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
		bytes[k * 4 + 2] = roundi(moisture_at(w, k) * 255.0)
		bytes[k * 4 + 3] = rock[k] if dry_ground else 0
	return Image.create_from_data(w.W, w.H, false, Image.FORMAT_RGBA8, bytes)


static func weights(cover: float, conifer: float, wet: float, light: float, rocky: float) -> PackedFloat32Array:
	var sheltered := cover * (1.0 - rocky * 0.6)
	return PackedFloat32Array([
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
		0.0, 0.0, 0.0, 0.0, 0.0, 0.0, # variants share their parent's placement probability
	])


static func _beam(a: Vector3, b: Vector3, radius: float, sides := 6, caps := false) -> Array:
	var delta := b - a
	var part := Models._cyl(radius * 0.72, radius, delta.length(), sides, caps)
	return [part[0], Transform3D(Basis(Quaternion(Vector3.UP, delta.normalized())), a) * part[1]]


static func _log(moss: bool, broken := false) -> Mesh:
	var a := Vector3(-2.2, 0.22, -0.04)
	var mid := Vector3(-0.1, 0.20, 0.06)
	var b := Vector3(0.9 if broken else 2.1, 0.16, -0.02)
	var parts: Array = [
		[_beam(a, mid, 0.24, 6, false), BARK],
		[_beam(mid, b, 0.18, 6, false), BARK],
		[_beam(a - Vector3(0.02, 0, 0), a, 0.20, 6, true), WOOD],
		[_beam(b, b + Vector3(0.02, 0, 0), 0.14, 6, true), WOOD],
	]
	for n in 4:
		var x := -1.25 + n * 0.82
		if broken and x > 0.7: continue
		var side := 1.0 if n % 2 == 0 else -1.0
		var z_off := 0.04 if n in [1, 2] else -0.02
		parts.append([_beam(Vector3(x, 0.22, z_off), Vector3(x + 0.34, 0.36, side * 0.68), 0.055, 4, false), BARK])
	# Остатки корневой лапы на комлевом конце.
	for n in 3:
		parts.append([_beam(a, a + Vector3(-0.36, 0.16 + n * 0.14, (n - 1) * 0.36), 0.068, 4, false), BARK])
	if moss:
		for n in 4:
			if broken and n > 2: continue
			var z_m := 0.04 if n in [1, 2] else -0.01
			parts.append([Models._moved(Plants._mound(0.32, 0.40, 1.45, 0.16, 0.56), Vector3(-1.35 + n * 0.82, 0, z_m)), Color(0.26 + n * 0.018, 0.38, 0.16)])
	return Plants._colored(parts)


static func expedition_variant(kind: int, roll: float, wet: float, old: float, rocky: float) -> int:
	if kind == MOSS_LOG and roll < wet * (0.45 + old * 0.5):
		var large := wet * (0.10 + 0.28 * old)
		if roll < large:
			return [NURSE_LOG_LONG, NURSE_LOG_HOLLOW, NURSE_LOG_PAIR][mini(2, int(roll * 3.0 / large))]
		return NURSE_LOG_SPLIT if roll < 0.29 else NURSE_LOG
	if kind == STUMP and roll < old * (0.40 + wet * 0.55):
		return ROOT_STUMP if roll < 0.20 else (ROOT_PLATE if roll < 0.39 else ROOT_UPTURNED)
	if kind == BOULDER and roll < wet * (0.42 + rocky * 0.52):
		return MOSS_BOULDER_LOW if roll < 0.25 else MOSS_BOULDER
	return kind


static func _nurse_log(split: bool, far: bool) -> Mesh:
	var a := Vector3(-2.65, 0.25, -0.02)
	var b := Vector3(1.63 if split else 2.87, 0.16, -0.05)
	var axis: Array[Vector3] = [a, Vector3(-1.94, 0.29, 0.04), Vector3(-0.18, 0.26, 0.13), b]
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := [axis, 0.37, 0.21 if split else 0.14, BARK, false]
	ForestModels._tube(tool, trunk, 7 if far else 9, 0, 0)
	var parts: Array = [
		[[tool.commit(), Transform3D.IDENTITY], BARK.darkened(0.13)],
		[_beam(a - Vector3(0.035, 0, 0), a, 0.28, 7, true), WOOD.darkened(0.17)],
		[_beam(b - Vector3(0.18, 0.028, 0), b + Vector3(0.07, 0.014, 0), 0.16 if split else 0.10, 5, true), WOOD],
	]
	for n in (3 if far else 5):
		var t := (n + 0.65) / 5.7
		var at := a.lerp(b, t)
		at.z += 0.12
		var side := 1.0 if n % 2 == 0 else -1.0
		var tip := at + Vector3(-0.11 + n * 0.13, 0.28 - 0.025 * n, side * (0.53 + 0.09 * sin(n * 3.1)))
		parts.append([_beam(at, tip, 0.105 - 0.009 * n, 4), BARK])
	if split:
		for n in 3:
			var at := b + Vector3(-0.31, 0.11 * (n - 1), 0.12 * sin(n * 2.1))
			parts.append([_beam(at, at + Vector3(0.37 + 0.14 * n, 0.16, 0.035 * (n - 1)), 0.067 - 0.012 * n, 4), WOOD])
	var pads: Array = []
	for n in (3 if far else 6):
		var t := (n + 0.5) / (3.25 if far else 6.35)
		var p := a.lerp(b, t)
		p.y += lerpf(0.33, 0.14, t)
		p.z += 0.07 + sin(n * 2.6) * 0.09
		pads.append([p, Vector3(0.81 if far else 0.51, 0.085, lerpf(0.31, 0.16, t)), Color("536b2f"), 5 if far else 7])
	parts.append([[Plants._dome_mesh(pads), Transform3D.IDENTITY], Color("526a30")])
	return Plants._colored(parts)


static func _large_nurse_log(kind: int, far: bool) -> Mesh:
	var parts: Array = []
	var moss: Array = []
	for trunk: Array in LARGE_LOGS[kind]:
		var a: Vector3 = trunk[0]
		var b: Vector3 = trunk[1]
		var r0: float = trunk[2]
		var r1: float = trunk[3]
		var hollow := kind == NURSE_LOG_HOLLOW
		var path := [a, a.lerp(b, 0.09) + Vector3.UP * 0.04, a.lerp(b, 0.57) + Vector3(0, 0.06, -0.07), b]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		ForestModels._tube(st, [path, r0, r1, BARK, false], 6 if far else 10, 0, 0)
		parts.append([[st.commit(), Transform3D.IDENTITY], BARK.darkened(0.14)])
		if hollow:
			var inward := (b - a).normalized()
			for n in (7 if far else 10):
				var angle := n * TAU / (7 if far else 10)
				var side := Vector3(0, cos(angle), sin(angle))
				var mouth := a + side * r0 * (0.88 + 0.22 * sin(n * 2.21)) - inward * (0.08 + 0.18 * absf(cos(n * 2.16)))
				var deep := a + side * (r0 * 0.62) + inward * (0.46 + 0.19 * sin(angle * 3.0))
				parts.append([_beam(mouth, deep, r0 * 0.16, 4, true), WOOD.darkened(0.12 + 0.15 * absf(sin(angle)))])
			parts.append([_beam(a + inward * 0.71, a + inward * 0.74, r0 * 0.72, 7, true), Color("30251c")])
		else:
			parts.append([_beam(a - Vector3(0.04, 0, 0), a, r0 * 0.94, 8, true), WOOD.darkened(0.19)])
		parts.append([_beam(b - Vector3(0.13, 0, 0), b + Vector3(0.05, 0, 0), r1 * 0.88, 6, true), WOOD])
		for n in (3 if far else 6):
			var t := (n + 0.75) / (3.85 if far else 6.8)
			var p := a.lerp(b, t)
			var r := lerpf(r0, r1, t)
			var side := 1.0 if n % 2 == 0 else -1.0
			var tip := p + Vector3(0.37 + 0.10 * n, r * (0.75 + 0.4 * sin(n * 1.3)), side * r * 1.45)
			parts.append([_beam(p, tip, r * 0.27, 4), BARK])
			moss.append([p + Vector3(0, r * 0.95, sin(n * 1.9) * r * 0.29),
				Vector3(1.13 if far else 0.78, 0.13, r * 0.84), Color("5b7134"), 5 if far else 7])
		if not far:
			var fern := Plants._sword_fern(true, false)
			var at := a.lerp(b, 0.31) + Vector3.UP * (r0 * 0.83)
			parts.append([[fern, Transform3D(Basis.from_scale(Vector3.ONE * 0.43), at)], Color("58783f")])
	parts.append([[Plants._dome_mesh(moss, true), Transform3D.IDENTITY], Color("587031")])
	return Plants._colored(parts)


static func _root_stump(variant: int, far: bool) -> Mesh:
	var upright := variant == 0
	var base := Vector3(0, -0.045, 0)
	var head := Vector3(0.15, 0.98, -0.045) if upright else Vector3(0.55 if variant == 1 else 0.9, 0.43, 0.12)
	var center := Vector3(0, 0.31 if upright else (0.71 if variant == 1 else 0.59), 0)
	var parts: Array = [
		[_beam(base if upright else center, head, 0.48 if upright else 0.43, 7), BARK],
		[_beam(head - Vector3(0.018, 0.07, 0), head + Vector3(0.03, 0.02, 0), 0.29, 6, true), WOOD.darkened(0.16)],
	]
	var count := 6 if far else 8
	if not upright:
		# Тёмная масса грунта за корнями читается как плита даже на дальнем LOD.
		var plate := Models.boulder(Vector3(0.30, 0.86, 0.94), 516 + variant, 0.83)
		var plate_mesh: Mesh = plate.get_meta("lod_meshes")[1] if far else plate
		parts.append([[plate_mesh, Transform3D(Basis(Vector3.UP, 0.22), center - Vector3(0.18, 0.19, 0))], Color("544537")])
	for n in count:
		var a := n * TAU / count + 0.24 * cos(n * 2.3)
		var span := (0.65 + 0.36 * sin(n * 2.6) ** 2.0) * (1.0 if upright else (1.67 if variant == 1 else 1.39))
		var dir := Vector3(cos(a), 0.0, sin(a)) if upright else Vector3(0.19 * sin(a + 0.6), 0.74 * cos(a), sin(a))
		var end := center + dir * span
		end.y = maxf(end.y, -0.045)
		var knee := center.lerp(end, 0.56) + Vector3(-0.13 if not upright else 0.0, 0.13, 0.06)
		var thick := 0.17 - (n % 4) * 0.018
		parts.append([_beam(center, knee, thick, 5), BARK])
		parts.append([_beam(knee, end, thick * 0.57, 4), BARK.darkened(0.15)])
		if not far and n % 2 == 0:
			parts.append([_beam(knee, knee.lerp(end, 0.58) + Vector3(-0.25, -0.11, 0.23), thick * 0.44, 4), BARK])
	var soil: Mesh = Models.boulder(Vector3(0.32, 0.38 if upright else 0.62, 0.57), 709 + variant, 0.42)
	if far:
		soil = soil.get_meta("lod_meshes")[1]
	parts.append([[soil, Transform3D(Basis(), center + Vector3(-0.10, -0.16, 0.02))], Color("504a34")])
	var moss := Plants._dome_mesh([[center + Vector3(-0.21, 0.12 if upright else 0.34, 0.09),
		Vector3(0.32, 0.08, 0.44), Color("536731"), 5 if far else 9]])
	parts.append([[moss, Transform3D.IDENTITY], Color("536731")])
	return Plants._colored(parts)


static func meshes() -> Array[Mesh]:
	if not _shared_meshes.is_empty(): return _shared_meshes.duplicate()
	var list: Array[Mesh] = preload("res://scripts/render/asset_catalog.gd").get_catalog().floor_meshes.duplicate()
	# каталог, запечённый до 15.0, корня через тропу не знает: маленький меш строится на месте
	if list.size() == ROOT_SPAN:
		list.append(root_span())
	list[ROOT_SPAN] = root_span()
	list[STONES] = stone_mesh()
	list.resize(COUNT)
	list[ROOT_SPAN_B] = root_span(1)
	list[ROOT_SPAN_C] = root_span(2)
	list[STONE_SINGLE] = stone_mesh(1)
	list[STONES_PAIR] = stone_mesh(2)
	list[LOG_BROKEN] = _log(false, true)
	list[MOSS_LOG_BROKEN] = _log(true, true)
	_shared_meshes = list
	return list.duplicate()


static func road_far_meshes() -> Dictionary:
	if _shared_far.is_empty():
		for v in 3: _shared_far[FIRST + variant_kind(STONES, v)] = stone_mesh(v, true)
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


static func root_span(variant := 0) -> Mesh:
	var path := root_path(variant)
	var parts: Array = []
	var bark := Color(0.21, 0.16, 0.11)
	for n in range(1, path.size()):
		parts.append([_beam(path[n - 1], path[n], root_radius(n - 1), 5, false), bark])
	parts.append([_beam(path[3], path[3] + Vector3(0.13, -0.065, 0.23 if variant % 2 == 0 else -0.23), 0.024, 4, false), bark])
	return Plants._colored(parts)


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


## 15.0: упрощённые корни и камни для дальнего подлеска, ключ - номер формы Floor.FIRST + вид.
static func build_far_meshes() -> Dictionary:
	var roots: Array = []
	for n in 5:
		var a := n * TAU / 5.0 + 0.3 + sin(n * 1.9) * 0.12
		var f := Vector3(cos(a), 0, sin(a))
		roots.append([_beam(f * 0.10 + Vector3.UP * 0.20, f * 1.05, 0.042, 4, false), BARK])
	return {ROOTS: Plants._colored(roots), STONES: stone_mesh(0, true), STONE_SINGLE: stone_mesh(1, true), STONES_PAIR: stone_mesh(2, true),
		NURSE_LOG: _nurse_log(false, true), NURSE_LOG_SPLIT: _nurse_log(true, true),
		ROOT_STUMP: _root_stump(0, true), ROOT_PLATE: _root_stump(1, true), ROOT_UPTURNED: _root_stump(2, true),
		MOSS_BOULDER: _moss_boulder(false).get_meta("lod_meshes")[1],
		MOSS_BOULDER_LOW: _moss_boulder(true).get_meta("lod_meshes")[1],
		NURSE_LOG_LONG: _large_nurse_log(NURSE_LOG_LONG, true), NURSE_LOG_HOLLOW: _large_nurse_log(NURSE_LOG_HOLLOW, true),
		NURSE_LOG_PAIR: _large_nurse_log(NURSE_LOG_PAIR, true)}


static func _moss_boulder(low: bool) -> Mesh:
	return Models.boulder(Vector3(1.44, 0.72, 1.13) if low else Vector3(1.06, 1.20, 0.91),
		824 if low else 1163, 0.83 if low else 0.69, 0.54)


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
	var twig := Plants._colored([
		[_beam(Vector3(-0.52, 0.04, -0.04), Vector3(0.05, 0.065, 0.04), 0.036, 4, false), BARK],
		[_beam(Vector3(0.05, 0.065, 0.04), Vector3(0.56, 0.05, 0.12), 0.024, 4, false), BARK],
		[_beam(Vector3(-0.02, 0.06, 0.03), Vector3(0.28, 0.07, 0.42), 0.018, 3, false), BARK],
	])
	var roots: Array = []
	for n in 5:
		var a := n * TAU / 5.0 + 0.3 + sin(n * 1.9) * 0.12
		var f := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a)) * (0.05 if n % 2 == 0 else -0.05)
		var knee := f * 0.58 + side + Vector3.UP * 0.085
		roots.append([_beam(f * 0.08 + Vector3.UP * 0.24, knee, 0.11, 5, false), BARK])
		roots.append([_beam(knee, f * 1.16, 0.045, 4, false), BARK])
	var snag: Array = [
		[_beam(Vector3.ZERO, Vector3(0.05, 1.65, -0.02), 0.19, 6, false), BARK],
		[_beam(Vector3(0.05, 1.65, -0.02), Vector3(0.09, 3.10, 0.01), 0.14, 5, false), BARK],
		[_beam(Vector3(0.09, 3.10, 0.01), Vector3(0.17, 3.36, 0.04), 0.085, 5, true), WOOD],
	]
	for n in 3:
		var a := n * 2.39996 + 0.4
		var p := Vector3(0.06, 1.32 + n * 0.52, 0)
		snag.append([_beam(p, p + Vector3(cos(a) * 0.66, 0.44, sin(a) * 0.66), 0.045, 4, false), BARK])
	# Пень: срез светлой древесины, корневые лапы и шапка мха.
	var stump: Array = [
		[_beam(Vector3(0, -0.05, 0), Vector3(0.02, 0.45, 0), 0.30, 6, false), BARK],
		[_beam(Vector3(0.02, 0.44, 0), Vector3(0.02, 0.47, 0), 0.22, 6, true), WOOD],
		[Models._moved(Plants._mound(0.20, 0.47, 1.05, 0.24, 0.82), Vector3(-0.06, 0, 0.05)), Color(0.35, 0.50, 0.20)],
	]
	for n in 5:
		var a := n * TAU / 5.0 + 0.35
		var f := Vector3(cos(a), 0, sin(a))
		stump.append([_beam(f * 0.14 + Vector3.UP * 0.26, f * 0.64, 0.088, 4, false), BARK])
	# 11.6: упавшая сухая ветка поперёк колеи — 2,2 м, развилки и пучок сухой листвы (кочка RoadObstacles.BUMP)
	var branch: Array = [
		[_beam(Vector3(-1.1, 0.05, -0.02), Vector3(0.0, 0.06, 0.05), 0.052, 5, false), BARK],
		[_beam(Vector3(0.0, 0.06, 0.05), Vector3(1.1, 0.04, 0.10), 0.038, 4, false), BARK],
	]
	for n in 5:
		var x := -0.8 + n * 0.4
		var side := 1.0 if n % 2 == 0 else -1.0
		branch.append([_beam(Vector3(x, 0.05, 0.02), Vector3(x + 0.45, 0.07 + n * 0.015, side * 0.42), 0.022, 3, false), BARK])
	branch.append([Models._moved(Plants._mound(0.16, 0.05, 1.6, 0.45, 0.4), Vector3(0.95, 0.0, 0.05)), Color(0.42, 0.31, 0.16)])
	return [
		Plants._leaves(leaves, Color(0.47, 0.35, 0.18), -1, false),
		Plants._leaves(needles, Color(0.40, 0.33, 0.19), -1, false),
		twig,
		Plants._colored(roots),
		_log(false),
		_log(true),
		Plants._colored(snag),
		stone_mesh(),
		Plants._colored(stump),
		Models.boulder(Vector3(0.85, 0.62, 0.72), 91, 0.9, 0.62),
		Plants._colored(branch),
		root_span(),
		root_span(1), root_span(2), stone_mesh(1), stone_mesh(2), _log(false, true), _log(true, true),
		_nurse_log(false, false), _nurse_log(true, false), _root_stump(0, false), _root_stump(1, false), _root_stump(2, false),
		_moss_boulder(false), _moss_boulder(true),
		_large_nurse_log(NURSE_LOG_LONG, false), _large_nurse_log(NURSE_LOG_HOLLOW, false), _large_nurse_log(NURSE_LOG_PAIR, false),
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
