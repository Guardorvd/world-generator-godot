extends RefCounted
## 6.6+: подстилка и валежник. Только оформление готового мира.

const Plants := preload("res://scripts/render/understory_models.gd")
const Surface := preload("res://scripts/world/mountain_surface.gd")
enum { LEAVES, NEEDLES, TWIG, ROOTS, LOG, MOSS_LOG, SNAG, STONES, STUMP, BOULDER, BRANCH } # 9.4: пни и мшистые валуны; 11.6: ветка на дороге
const FIRST := Plants.COUNT # после форм подлеска (8.2: двенадцать)
const BARK := Color(0.29, 0.22, 0.15)
const WOOD := Color(0.49, 0.39, 0.25)


static func moisture_at(w: WorldData, k: int) -> float:
	return clampf(w.moist[k] + maxf(0.0, 1.0 - w.dist_water[k] / 3.0) * 0.2, 0.0, 1.0)


static func rockiness(w: WorldData, k: int) -> float:
	return Surface.exposure(w.elev[k],w.slope[k],w.moist[k])


## Линейные RGBA-данные: фактический полог, доля хвойных, влажность, каменистость.
## Один проход по деревьям вместо поиска соседей для каждой клетки всей карты.
static func surface_image(w: WorldData) -> Image:
	if w.generation.surface_rock.size()!=w.N:
		w.generation.surface_rock=Surface.field(w.elev,w.slope,w.moist)
	var rock := w.generation.surface_rock
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
				if kind == Biomes.T_PINE or kind == Biomes.T_SNOWPINE:
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
	])


static func _beam(a: Vector3, b: Vector3, radius: float, sides := 6, caps := false) -> Array:
	var delta := b - a
	var part := Models._cyl(radius * 0.72, radius, delta.length(), sides, caps)
	return [part[0], Transform3D(Basis(Quaternion(Vector3.UP, delta.normalized())), a) * part[1]]


static func _log(moss: bool) -> Mesh:
	var a := Vector3(-2.2, 0.22, -0.04)
	var mid := Vector3(-0.1, 0.20, 0.06)
	var b := Vector3(2.1, 0.16, -0.02)
	var parts: Array = [
		[_beam(a, mid, 0.24, 6, false), BARK],
		[_beam(mid, b, 0.18, 6, false), BARK],
		[_beam(a - Vector3(0.02, 0, 0), a, 0.20, 6, true), WOOD],
		[_beam(b, b + Vector3(0.02, 0, 0), 0.14, 6, true), WOOD],
	]
	for n in 4:
		var x := -1.25 + n * 0.82
		var side := 1.0 if n % 2 == 0 else -1.0
		var z_off := 0.04 if n in [1, 2] else -0.02
		parts.append([_beam(Vector3(x, 0.22, z_off), Vector3(x + 0.34, 0.36, side * 0.68), 0.055, 4, false), BARK])
	# Остатки корневой лапы на комлевом конце.
	for n in 3:
		parts.append([_beam(a, a + Vector3(-0.36, 0.16 + n * 0.14, (n - 1) * 0.36), 0.068, 4, false), BARK])
	if moss:
		for n in 4:
			var z_m := 0.04 if n in [1, 2] else -0.01
			parts.append([Models._moved(Plants._mound(0.32, 0.40, 1.45, 0.16, 0.56), Vector3(-1.35 + n * 0.82, 0, z_m)), Color(0.26 + n * 0.018, 0.38, 0.16)])
	return Plants._colored(parts)


static func meshes() -> Array[Mesh]:
	return preload("res://scripts/render/asset_catalog.gd").get_catalog().floor_meshes.duplicate()


## 15.0: упрощённые корни и камни для дальнего подлеска, ключ - номер формы Floor.FIRST + вид.
static func build_far_meshes() -> Dictionary:
	var roots: Array = []
	for n in 5:
		var a := n * TAU / 5.0 + 0.3 + sin(n * 1.9) * 0.12
		var f := Vector3(cos(a), 0, sin(a))
		roots.append([_beam(f * 0.10 + Vector3.UP * 0.20, f * 1.05, 0.042, 4, false), BARK])
	var stones := SurfaceTool.new()
	for n in 5:
		var a := n * 2.4
		var r := 0.18 + (n % 3) * 0.09
		var stone := Models.boulder(Vector3(1.2, 0.55, 0.85) * r, 300 + n, 0.35, 0.5)
		var far: Mesh = stone.get_meta("lod_meshes")[1]
		stones.append_from(far, 0, Transform3D(Basis(), Vector3(cos(a) * 0.45, 0.0, sin(a) * 0.45)))
	return {ROOTS: Plants._colored(roots), STONES: stones.commit()}


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
	# 9.4: россыпь из тех же бугристых камней, что валуны мира, а не из сплюснутых сфер
	var stones := SurfaceTool.new()
	for n in 5:
		var a := n * 2.4
		var r := 0.18 + (n % 3) * 0.09
		var stone := Models.boulder(Vector3(1.2, 0.55, 0.85) * r, 300 + n, 0.35, 0.5)
		stones.append_from(stone, 0, Transform3D(Basis(), Vector3(cos(a) * 0.45, 0.0, sin(a) * 0.45)))
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
		Plants._leaves(leaves, Color(0.47, 0.35, 0.18)),
		Plants._leaves(needles, Color(0.40, 0.33, 0.19)),
		twig,
		Plants._colored(roots),
		_log(false),
		_log(true),
		Plants._colored(snag),
		stones.commit(),
		Plants._colored(stump),
		Models.boulder(Vector3(0.85, 0.62, 0.72), 91, 0.9, 0.62),
		Plants._colored(branch),
	]
