extends RefCounted
## 6.6+: подстилка и валежник. Только оформление готового мира.

const Plants := preload("res://scripts/render/understory_models.gd")
enum { LEAVES, NEEDLES, TWIG, ROOTS, LOG, MOSS_LOG, SNAG, STONES, STUMP, BOULDER, BRANCH } # 9.4: пни и мшистые валуны; 11.6: ветка на дороге
const FIRST := Plants.COUNT # после форм подлеска (8.2: двенадцать)
const BARK := Color(0.29, 0.22, 0.15)
const WOOD := Color(0.49, 0.39, 0.25)


static func moisture_at(w: WorldData, k: int) -> float:
	return clampf(w.moist[k] + maxf(0.0, 1.0 - w.dist_water[k] / 3.0) * 0.2, 0.0, 1.0)


static func rockiness(w: WorldData, k: int) -> float:
	var patch := WGRandom.hash2((k % w.W) / 3, (k / w.W) / 3, w.seed_num ^ 6673)
	return clampf((maxf(0.0, w.slope[k] - 0.15) * 0.8
		+ smoothstep(0.12, 0.35, w.elev[k]) * 0.3 + (1.0 - w.moist[k]) * 0.12) * (0.4 + patch * 0.6), 0.0, 1.0)


## Линейные RGBA-данные: фактический полог, доля хвойных, влажность, каменистость.
## Один проход по деревьям вместо поиска соседей для каждой клетки всей карты.
static func surface_image(w: WorldData) -> Image:
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
		bytes[k * 4 + 3] = roundi(rockiness(w, k) * 255.0)
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


static func _beam(a: Vector3, b: Vector3, radius: float) -> Array:
	var delta := b - a
	var part := Models._cyl(radius * 0.7, radius, delta.length(), 6)
	return [part[0], Transform3D(Basis(Quaternion(Vector3.UP, delta.normalized())), a) * part[1]]


static func _log(moss: bool) -> Mesh:
	var a := Vector3(-2.2, 0.22, 0)
	var b := Vector3(2.1, 0.17, 0.07)
	var parts: Array = [[_beam(a, b, 0.23), BARK],
		[_beam(a - Vector3(0.01, 0, 0), a, 0.21), WOOD],
		[_beam(b, b + Vector3(0.01, 0, 0), 0.15), WOOD]]
	for n in 4:
		var x := -1.2 + n * 0.8
		var side := 1.0 if n % 2 == 0 else -1.0
		parts.append([_beam(Vector3(x, 0.23, 0), Vector3(x + 0.35, 0.35, side * 0.7), 0.055), BARK])
	# Остатки корневой лапы на комлевом конце.
	for n in 3:
		parts.append([_beam(a, a + Vector3(-0.35, 0.18 + n * 0.14, (n - 1) * 0.35), 0.065), BARK])
	if moss:
		for n in 4:
			parts.append([Models._moved(Plants._mound(0.33, 0.41, 1.4, 0.17, 0.55), Vector3(-1.4 + n * 0.8, 0, 0)), Color(0.25 + n * 0.015, 0.36, 0.15)])
	return Plants._colored(parts)


static func meshes() -> Array[Mesh]:
	return preload("res://scripts/render/asset_catalog.gd").get_catalog().floor_meshes.duplicate()


static func build_meshes() -> Array[Mesh]:
	var leaves: Array = []
	var needles: Array = []
	# Несколько приподнятых листьев и иголок поверх шейдерной подстилки.
	for n in 11:
		var a := n * 2.4
		var p := Vector3(cos(a), 0.025, sin(a)) * (0.12 + n * 0.045)
		p.y = 0.025
		var f := Vector3(cos(a), 0, sin(a)) * 0.12
		var s := Vector3(-sin(a), 0.012, cos(a)) * 0.055
		leaves.append([p - f, p + s, p + f + Vector3.UP * 0.025, p - s])
		var thin := Vector3(-sin(a), 0, cos(a)) * 0.009
		needles.append([p - thin, p + thin, p + f * 1.3])
	var twig := Plants._colored([[_beam(Vector3(-0.5, 0.045, 0), Vector3(0.55, 0.07, 0.1), 0.035), BARK],
		[_beam(Vector3(0, 0.06, 0.05), Vector3(0.25, 0.06, 0.4), 0.02), BARK]])
	var roots: Array = []
	for n in 5:
		var a := n * TAU / 5.0 + 0.3
		var f := Vector3(cos(a), 0, sin(a))
		roots.append([_beam(f * 0.08 + Vector3.UP * 0.22, f * 0.65 + Vector3.UP * 0.07, 0.11), BARK])
		roots.append([_beam(f * 0.65 + Vector3.UP * 0.07, f * 1.15, 0.04), BARK])
	var snag: Array = [[_beam(Vector3.ZERO, Vector3(0.08, 3.1, 0), 0.18), BARK],
		[_beam(Vector3(0.08, 3.1, 0), Vector3(0.17, 3.35, 0.04), 0.085), WOOD]]
	for n in 3:
		var a := n * 2.4
		var p := Vector3(0.05, 1.3 + n * 0.5, 0)
		snag.append([_beam(p, p + Vector3(cos(a) * 0.65, 0.45, sin(a) * 0.65), 0.045), BARK])
	# 9.4: россыпь из тех же бугристых камней, что валуны мира, а не из сплюснутых сфер
	var stones := SurfaceTool.new()
	for n in 5:
		var a := n * 2.4
		var r := 0.18 + (n % 3) * 0.09
		var stone := Models.boulder(Vector3(1.2, 0.55, 0.85) * r, 300 + n, 0.35, 0.5)
		stones.append_from(stone, 0, Transform3D(Basis(), Vector3(cos(a) * 0.45, 0.0, sin(a) * 0.45)))
	# Пень: срез светлой древесины, корневые лапы и шапка мха.
	var stump: Array = [[_beam(Vector3(0, -0.05, 0), Vector3(0.02, 0.45, 0), 0.3), BARK],
		[_beam(Vector3(0.02, 0.45, 0), Vector3(0.02, 0.47, 0), 0.22), WOOD],
		[Models._moved(Plants._mound(0.2, 0.47, 1.0, 0.25, 0.8), Vector3(-0.06, 0, 0.05)), Color(0.36, 0.5, 0.2)]]
	for n in 4:
		var a := n * TAU / 4.0 + 0.4
		var f := Vector3(cos(a), 0, sin(a))
		stump.append([_beam(f * 0.15 + Vector3.UP * 0.25, f * 0.62, 0.09), BARK])
	# 11.6: упавшая сухая ветка поперёк колеи — 2,2 м, развилки и пучок сухой листвы (кочка RoadObstacles.BUMP)
	var branch: Array = [[_beam(Vector3(-1.1, 0.05, 0), Vector3(1.1, 0.04, 0.1), 0.05), BARK]]
	for n in 5:
		var x := -0.8 + n * 0.4
		var side := 1.0 if n % 2 == 0 else -1.0
		branch.append([_beam(Vector3(x, 0.05, 0.02), Vector3(x + 0.45, 0.07 + n * 0.015, side * 0.42), 0.022), BARK])
	branch.append([Models._moved(Plants._mound(0.16, 0.05, 1.6, 0.45, 0.4), Vector3(0.95, 0.0, 0.05)), Color(0.42, 0.31, 0.16)])
	return [Plants._leaves(leaves, Color(0.46, 0.35, 0.18)), Plants._leaves(needles, Color(0.4, 0.33, 0.19)),
		twig, Plants._colored(roots), _log(false), _log(true), Plants._colored(snag), stones.commit(),
		Plants._colored(stump), Models.boulder(Vector3(0.85, 0.62, 0.72), 91, 0.9, 0.62), Plants._colored(branch)]
