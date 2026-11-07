extends RefCounted
## 6.6: простые ближние растения. Цвета частей запечены в вершины.
## 8.2: мелкие цветы, высокая трава, молодые деревья и характеры леса.
## UV2.x — ранг удаления отдельного листа вдали; жилки, стебли и сплошные лапы имеют ранг 0.

enum { FERN, MOSS, MUSHROOM, HERB, GRASS, BUSH, SAPLING, PINE, FLOWERS, HIGH_GRASS, YOUNG, YOUNG_PINE }
const COUNT := 12
## Характер леса: светлый (просветы, трава и цветы), тёмный (сомкнутый, чаще хвойный: мох и грибы),
## чаща (молодой участок: кусты и подрост стеной), папоротниковый (влажная тень).
enum { LIGHT, DARK, THICKET, FERNY }
# Множитель веса каждой формы для каждого характера, порядок как в enum форм.
const TEMPLATE := [
	[0.6, 0.4, 0.3, 1.4, 2.2, 1.2, 0.6, 0.6, 1.0, 1.0, 0.5, 0.4],
	[1.0, 1.7, 1.9, 0.5, 0.12, 0.45, 0.3, 0.5, 0.0, 0.0, 0.0, 0.6],
	[0.7, 0.5, 0.4, 0.8, 0.5, 3.2, 3.0, 3.0, 0.2, 0.3, 1.0, 1.0],
	[3.2, 1.2, 0.8, 0.8, 0.5, 0.6, 0.6, 0.6, 0.2, 0.3, 0.3, 0.3],
]
const DENSITY := [1.0, 0.8, 1.6, 1.4] # доля занятых мест подлеска (9.4: гуще, как в лесах KCD и Valheim)
const LOW_GRASS := [1.5, 0.3, 0.55, 0.7] # множитель низкой травы
const DEADWOOD := [0.7, 1.5, 0.9, 1.1]   # множитель валежника и сухостоя: в тёмном старом лесу его больше


static func meshes() -> Array[Mesh]:
	return preload("res://scripts/render/asset_catalog.gd").get_catalog().understory.duplicate()


static func build_meshes() -> Array[Mesh]:
	var green := Color(0.29, 0.48, 0.22)
	var bark := Color(0.36, 0.26, 0.16)
	# 1. Папоротник: раскидистая розетка из 6 изогнутых перистых вай разной длины и наклона,
	# с видимым центральным черешком и густыми перекрывающимися долями листа.
	var fern_detail: Array = []
	var fern_core: Array = []
	for arm in 6:
		var a := arm * TAU / 6.0 + sin(arm * 1.9) * 0.16
		var scale_len := 0.88 + (arm % 3) * 0.10
		var arch_h := 0.86 + ((arm + 1) % 3) * 0.11
		var forward := Vector3(cos(a), 0, sin(a)) * scale_len
		var side := Vector3(-sin(a), 0, cos(a)) * scale_len
		for segment in 3:
			var s0 := _fern_point(segment / 3.0, forward, arch_h)
			var s1 := _fern_point((segment + 1) / 3.0, forward, arch_h)
			var w0 := 0.011 * (1.0 - segment * 0.22)
			var w1 := 0.011 * (1.0 - (segment + 1) * 0.22)
			fern_core.append([s0 - side * w0, s0 + side * w0, s1 + side * w1, s1 - side * w1])
		for step in 6:
			var t0 := (step + 0.15) / 6.4
			var t1 := (step + 1.45) / 6.4
			var p0 := _fern_point(t0, forward, arch_h)
			var p1 := _fern_point(t1, forward, arch_h)
			var pm := _fern_point((t0 + t1) * 0.46, forward, arch_h)
			var env := sin(clampf(t0 * 0.86 + 0.16, 0.18, 0.96) * PI)
			var w := 0.21 * env * (1.05 - t0 * 0.42)
			for sign_side: float in [-1.0, 1.0]:
				var wing_tip := pm + side * sign_side * w + forward * 0.085 + Vector3.UP * (0.018 * env)
				var blade := [p0, wing_tip, p1]
				if step in [1, 2, 3, 4]:
					fern_core.append(blade)
				else:
					fern_detail.append(blade)
	var persistent_from := fern_detail.size()
	fern_detail.append_array(fern_core)
	var fern := _leaves(fern_detail, green, persistent_from)

	# 2. Травянистый широколистный кустик (копытень / подорожник лесной): двухъярусная розетка желобчатых листьев.
	var parts: Array = []
	for arm in 8:
		var inner := arm >= 5
		var a := (arm * TAU / 5.0 + 0.2) if not inner else ((arm - 5) * TAU / 3.0 + 0.75)
		var reach := (0.28 + (arm % 2) * 0.06) if not inner else 0.20
		var lift := (0.14 + (arm % 3) * 0.04) if not inner else 0.25
		var p := Vector3(cos(a), 0.01, sin(a)) * 0.05
		var tip := Vector3(cos(a) * reach, lift, sin(a) * reach)
		var side := Vector3(-sin(a), 0.02, cos(a)) * (0.095 if not inner else 0.075)
		var middle := p.lerp(tip, 0.56) + Vector3.UP * 0.035
		parts.append([p, middle + side, tip, middle - side])
	var herb := _leaves(parts, Color(0.31, 0.47, 0.21))

	# 3. Лесная злаковая трава: изогнутые двухсегментные перья разной высоты вместо прямых пик.
	var tall_grass := _grass_tuft(6, 4, 0.58, 0.78, 0.24, 0.026, Color(0.45, 0.57, 0.24))

	# 4. Мох: три мягкие асимметричные подушки только с верхней полусферой (без подземных граней).
	var moss := _moss_patch()

	# 5. Грибы: семейка из 4 лесных грибов (боровики и подберёзовики) с полыми снизу ножками и выпуклыми шляпками.
	var mushrooms := _mushroom_cluster()

	# 6. Кустарник, подрост и молодые деревья: ветвистый каркас и ярусные чашевидные купола листвы.
	var bush := _crowned(0, bark, Vector3(0.05, 0.34, 0.03), Vector3(0.64, 0.38, 0.54), 54)
	var sapling := _crowned(1, bark, Vector3(0.04, 1.12, 0.0), Vector3(0.46, 0.56, 0.44), 44)
	var pine := _spruce(1.72, bark, 4, 0.56, 0.22, Color(0.28, 0.46, 0.28), 17)

	# 7. Лесные цветы: прикорневая розетка листьев, изогнутые стебли и наклонные пятилепестковые венчики.
	var flowers := _flower_clump()

	# 8. Высокая луговая/опушечная трава до 1.25 м: дугообразные поникающие листья и колосья.
	var high_grass := _grass_tuft(8, 5, 0.92, 1.22, 0.36, 0.030, Color(0.50, 0.58, 0.26))

	# 9. Молодые деревья второго яруса (3.0–3.3 м).
	var young := _crowned(2, Color(0.60, 0.58, 0.52), Vector3(0.0, 2.32, 0.0), Vector3(0.86, 1.06, 0.86), 78)
	var young_pine := _spruce(3.32, bark, 6, 0.76, 0.22, Color(0.24, 0.41, 0.26), 41)

	return [fern, moss, mushrooms, herb, tall_grass, bush, sapling, pine, flowers, high_grass, young, young_pine]


## 15.0: упрощённые формы для дальнего подлеска (дальше FAR_FORM_R от игрока), ключ - номер формы.
## Тот же силуэт и цвет, втрое меньше мелких треугольников.
static func build_far_meshes() -> Dictionary:
	var green := Color(0.29, 0.48, 0.22)
	var parts: Array = []
	for arm in 6:
		var a := arm * TAU / 6.0 + sin(arm * 1.9) * 0.16
		var forward := Vector3(cos(a), 0, sin(a)) * 0.86
		var side := Vector3(-sin(a), 0, cos(a)) * 0.86
		var p0 := _fern_point(0.14, forward, 0.86)
		var pm := _fern_point(0.52, forward, 0.86)
		var p1 := _fern_point(0.92, forward, 0.86)
		parts.append([p0, pm + side * 0.20 + Vector3.UP * 0.02, p1, pm - side * 0.20 + Vector3.UP * 0.02])
	var fern := _leaves(parts, green, 0)
	var moss := _dome_mesh([[Vector3(0.02, 0.0, 0.04), Vector3(0.40, 0.085, 0.32), Color(0.38, 0.52, 0.21), 8]])
	return {FERN: fern, MOSS: moss}


## Маленькие объёмы не требуют сферы на сотню треугольников.
static func _mound(r: float, y: float, sx := 1.0, sy := 1.0, sz := 1.0) -> Array:
	var mesh := SphereMesh.new()
	mesh.radius = r
	mesh.height = r * 2.0
	mesh.radial_segments = 8
	mesh.rings = 1
	return [mesh, Transform3D(Basis().scaled(Vector3(sx, sy, sz)), Vector3(0, y, 0))]


static func _fern_point(t: float, forward: Vector3, arch_h := 1.0) -> Vector3:
	var path: Array[Vector3] = [
		Vector3.ZERO,
		forward * 0.28 + Vector3.UP * (0.48 * arch_h),
		forward * 0.62 + Vector3.UP * (0.64 * arch_h),
		forward * 0.92 + Vector3.UP * (0.22 * arch_h),
	]
	var at := clampf(t, 0, 1) * 3.0
	var segment := mini(2, floori(at))
	return path[segment].lerp(path[segment + 1], at - segment)


## Пучок лесной или высокой травы из двухсегментных изогнутых травинок и внутренних побегов.
static func _grass_tuft(arched_count: int, spear_count: int, h_min: float, h_max: float, reach_max: float, width: float, color: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var total := arched_count + spear_count
	for n in total:
		var a := n * 2.39996 + 0.35 * sin(n * 1.7)
		var dir := Vector3(sin(a), 0, cos(a))
		var side := Vector3(cos(a), 0, -sin(a)) * width * (1.05 if n < arched_count else 0.85)
		var foot := dir * (0.04 + fposmod(n * 0.381966, 1.0) * 0.11)
		var h := lerpf(h_min, h_max, fposmod(n * 0.618034, 1.0))
		var reach := reach_max * (0.68 + 0.48 * fposmod(n * 0.754878, 1.0))
		var rank := 0.0 if n < ceili(total * 0.45) else fposmod(0.25 + n * 0.618034, 0.95)
		st.set_uv2(Vector2(rank, 0))
		var base_c := Color(color.r * 0.76, color.g * 0.78, color.b * 0.72)
		var mid_c := Color(color.r * 0.96, color.g * 0.98, color.b * 0.92)
		var tip_c := Color(minf(1.0, color.r * 1.12), minf(1.0, color.g * 1.10), minf(1.0, color.b * 0.96))
		if n < arched_count:
			var knee := foot + dir * (reach * 0.42) + Vector3.UP * (h * 0.58)
			var tip := foot + dir * reach + Vector3.UP * h
			var side_mid := side * 0.62
			var n_low := (-dir * 0.35 + Vector3.UP * 0.94).normalized()
			var n_high := (dir * 0.15 + Vector3.UP * 0.98).normalized()
			for tri: Array in [
				[[foot - side, 0.0, base_c, n_low], [foot + side, 0.0, base_c, n_low], [knee + side_mid, 0.55, mid_c, n_low]],
				[[foot - side, 0.0, base_c, n_low], [knee + side_mid, 0.55, mid_c, n_low], [knee - side_mid, 0.55, mid_c, n_low]],
				[[knee - side_mid, 0.55, mid_c, n_high], [knee + side_mid, 0.55, mid_c, n_high], [tip, 1.0, tip_c, n_high]],
			]:
				for v: Array in tri:
					st.set_normal(v[3])
					st.set_color(v[2])
					st.set_uv(Vector2(float(n) / total, v[1]))
					st.add_vertex(v[0])
		else:
			var tip := foot + dir * (reach * 0.75) + Vector3.UP * (h * 0.88)
			var n_up := (-dir * 0.25 + Vector3.UP * 0.96).normalized()
			for v: Array in [[foot - side, 0.0, base_c], [foot + side, 0.0, base_c], [tip, 1.0, tip_c]]:
				st.set_normal(n_up)
				st.set_color(v[2])
				st.set_uv(Vector2(float(n) / total, v[1]))
				st.add_vertex(v[0])
	st.index()
	return st.commit()


## Верхние купола мха без невидимого подземного дна.
static func _dome_mesh(domes: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for d_idx in domes.size():
		var d: Array = domes[d_idx]
		var center: Vector3 = d[0]
		var scale: Vector3 = d[1]
		var col: Color = d[2]
		var segs: int = d[3]
		var apex := center + Vector3(0, scale.y, 0)
		var ring_mid: Array[Vector3] = []
		var ring_low: Array[Vector3] = []
		for i in segs:
			var a := i * TAU / segs + d_idx * 0.55
			var lobe := 1.0 + 0.12 * sin(a * 3.0 + d_idx * 1.7)
			var dir := Vector3(cos(a) * scale.x * lobe, 0, sin(a) * scale.z * lobe)
			ring_mid.append(center + dir * 0.62 + Vector3(0, scale.y * 0.68, 0))
			ring_low.append(center + dir + Vector3(0, -0.01, 0))
		for i in segs:
			var next := (i + 1) % segs
			for tri: Array in [[apex, ring_mid[i], ring_mid[next]], [ring_mid[i], ring_low[i], ring_low[next]], [ring_mid[i], ring_low[next], ring_mid[next]]]:
				for p: Vector3 in tri:
					var local := (p - center) / scale
					var normal := (Vector3(local.x, maxf(0.25, local.y), local.z)).normalized()
					var h_t := clampf((p.y - center.y) / maxf(0.01, scale.y), 0.0, 1.0)
					var shade := lerpf(0.76, 1.10, h_t)
					st.set_normal(normal)
					st.set_color(Color(col.r * shade, col.g * shade, col.b * shade))
					st.add_vertex(p)
	st.index()
	return st.commit()


static func _moss_patch() -> ArrayMesh:
	return _dome_mesh([
		[Vector3(-0.04, 0.0, -0.02), Vector3(0.48, 0.10, 0.40), Color(0.35, 0.50, 0.20), 7],
		[Vector3(0.32, 0.0, 0.18), Vector3(0.34, 0.085, 0.30), Color(0.42, 0.56, 0.23), 6],
		[Vector3(-0.26, 0.0, 0.22), Vector3(0.26, 0.07, 0.24), Color(0.32, 0.47, 0.19), 5],
	])


## Семейка лесных грибов без закрытых торцов цилиндров и подземных половин сфер.
static func _mushroom_cluster() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var specs := [
		[Vector3(-0.02, 0.0, -0.02), 0.16, 0.034, 0.024, 0.115, 0.065, Color(0.48, 0.25, 0.12), Vector3(0.015, 0, -0.01)],
		[Vector3(0.15, 0.0, 0.11), 0.20, 0.038, 0.026, 0.130, 0.075, Color(0.54, 0.29, 0.14), Vector3(-0.018, 0, 0.015)],
		[Vector3(0.26, 0.0, -0.10), 0.12, 0.025, 0.018, 0.085, 0.048, Color(0.58, 0.33, 0.15), Vector3(0.012, 0, -0.012)],
	]
	var stem_col := Color(0.80, 0.74, 0.58)
	for s_idx in specs.size():
		var sp: Array = specs[s_idx]
		var base: Vector3 = sp[0]
		var h: float = sp[1]
		var r_bot: float = sp[2]
		var r_top: float = sp[3]
		var cap_r: float = sp[4]
		var cap_h: float = sp[5]
		var cap_col: Color = sp[6]
		var lean: Vector3 = sp[7]
		var segs := 5
		var top_center := base + lean + Vector3(0, h, 0)
		for i in segs:
			var a0 := i * TAU / segs
			var a1 := (i + 1) % segs * TAU / segs
			var n0 := Vector3(cos(a0), 0.1, sin(a0)).normalized()
			var n1 := Vector3(cos(a1), 0.1, sin(a1)).normalized()
			var b0 := base + Vector3(cos(a0) * r_bot, 0, sin(a0) * r_bot)
			var b1 := base + Vector3(cos(a1) * r_bot, 0, sin(a1) * r_bot)
			var t0 := top_center + Vector3(cos(a0) * r_top, 0, sin(a0) * r_top)
			var t1 := top_center + Vector3(cos(a1) * r_top, 0, sin(a1) * r_top)
			for v: Array in [[b0, n0, 0.85], [b1, n1, 0.85], [t1, n1, 1.02], [b0, n0, 0.85], [t1, n1, 1.02], [t0, n0, 1.02]]:
				st.set_normal(v[1])
				st.set_color(stem_col * v[2])
				st.add_vertex(v[0])
		var cap_segs := 6
		var apex := top_center + Vector3(0, cap_h * 0.85, 0)
		var mid_ring: Array[Vector3] = []
		var rim_ring: Array[Vector3] = []
		for i in cap_segs:
			var a := i * TAU / cap_segs + s_idx * 0.4
			var dir := Vector3(cos(a), 0, sin(a))
			mid_ring.append(top_center + dir * (cap_r * 0.62) + Vector3(0, cap_h * 0.52, 0))
			rim_ring.append(top_center + dir * cap_r - Vector3(0, cap_h * 0.12, 0))
		for i in cap_segs:
			var next := (i + 1) % cap_segs
			for tri: Array in [[apex, mid_ring[i], mid_ring[next]], [mid_ring[i], rim_ring[i], rim_ring[next]], [mid_ring[i], rim_ring[next], mid_ring[next]]]:
				for p: Vector3 in tri:
					var d := p - top_center
					var n := Vector3(d.x / cap_r, 0.65, d.z / cap_r).normalized()
					var rim_t := clampf(Vector2(d.x, d.z).length() / cap_r, 0.0, 1.0)
					var shade := lerpf(0.84, 1.10, 1.0 - rim_t * 0.65)
					st.set_normal(n)
					st.set_color(Color(cap_col.r * shade, cap_col.g * shade, cap_col.b * shade))
					st.add_vertex(p)
	st.index()
	return st.commit()


## Кустик лесных цветов: прикорневая розетка листьев, изогнутые стебли без заглушек и чашевидные венчики.
static func _flower_clump() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stem_col := Color(0.29, 0.49, 0.20)
	# Прикорневая розетка из 6 дугообразных листьев.
	for l in 6:
		var a := l * TAU / 6.0 + 0.25
		var f := Vector3(cos(a), 0, sin(a))
		var s := Vector3(-sin(a), 0, cos(a)) * 0.038
		var p0 := f * 0.02 + Vector3.UP * 0.01
		var pm := f * 0.10 + Vector3.UP * 0.055
		var p1 := f * 0.18 + Vector3.UP * 0.025
		var n := (Vector3.UP * 0.85 + f * 0.25).normalized()
		for tri: Array in [[p0, pm + s, p1], [p0, p1, pm - s]]:
			for p: Vector3 in tri:
				var shade := lerpf(0.82, 1.06, clampf(p.length() / 0.18, 0.0, 1.0))
				st.set_normal(n)
				st.set_color(stem_col * shade)
				st.add_vertex(p)
	# 5 цветоносов с чашевидными пятилепестковыми цветками.
	var palette := [Color(0.94, 0.89, 0.58), Color(0.78, 0.58, 0.88), Color(0.96, 0.95, 0.90)]
	for k in 5:
		var a := k * 2.39996 + 0.4
		var dir := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a))
		var foot := dir * (0.03 + k * 0.018)
		var reach := 0.06 + k * 0.028
		var h := 0.21 + (k % 3) * 0.065
		var head := foot + dir * reach + Vector3(0, h, 0)
		var r_stem := 0.008
		for s_i in 3:
			var sa0 := s_i * TAU / 3.0
			var sa1 := (s_i + 1) % 3 * TAU / 3.0
			var n0 := Vector3(cos(sa0), 0.1, sin(sa0)).normalized()
			var n1 := Vector3(cos(sa1), 0.1, sin(sa1)).normalized()
			var b0 := foot + Vector3(cos(sa0), 0, sin(sa0)) * r_stem
			var b1 := foot + Vector3(cos(sa1), 0, sin(sa1)) * r_stem
			var t0 := head + Vector3(cos(sa0), 0, sin(sa0)) * (r_stem * 0.75)
			var t1 := head + Vector3(cos(sa1), 0, sin(sa1)) * (r_stem * 0.75)
			for v: Array in [[b0, n0], [b1, n1], [t1, n1], [b0, n0], [t1, n1], [t0, n0]]:
				st.set_normal(v[1])
				st.set_color(stem_col)
				st.add_vertex(v[0])
		var petal_col: Color = palette[k % 3]
		var center_col := Color(0.95, 0.76, 0.22)
		var tilt_up := (Vector3.UP * 0.90 + dir * 0.42).normalized()
		var f_x := side
		var f_z := tilt_up.cross(f_x).normalized()
		var radius := 0.054
		var center_pt := head - tilt_up * 0.005
		for p_i in 5:
			var pa := p_i * TAU / 5.0 + k * 0.5
			var pa_l := pa - 0.34
			var pa_r := pa + 0.34
			var tip_l := head + (f_x * cos(pa_l) + f_z * sin(pa_l)) * radius + tilt_up * 0.012
			var tip_r := head + (f_x * cos(pa_r) + f_z * sin(pa_r)) * radius + tilt_up * 0.012
			for v: Array in [[center_pt, center_col], [tip_l, petal_col], [tip_r, petal_col * 0.95]]:
				st.set_normal(tilt_up)
				st.set_color(v[1])
				st.add_vertex(v[0])
	st.index()
	return st.commit()


## 9.4: ёлочка из асимметричных звёздчатых ярусов с поникшими лапами и верхними гребнями хвои.
static func _spruce(height: float, bark: Color, tiers: int, r0: float, r1: float, needles: Color, seed_offset := 0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_uv2(Vector2.ZERO)
	var lean_dir := Vector3(cos(seed_offset * 1.3), 0, sin(seed_offset * 1.3)) * (0.04 * height / 1.7)
	# Ствол без невидимых торцевых крышек (4 грани).
	var r_base := 0.055 * height / 1.7
	var r_top := 0.016
	for i in 4:
		var a0 := i * TAU / 4.0
		var a1 := (i + 1) % 4 * TAU / 4.0
		var n0 := Vector3(cos(a0), 0.08, sin(a0)).normalized()
		var n1 := Vector3(cos(a1), 0.08, sin(a1)).normalized()
		var b0 := Vector3(cos(a0) * r_base, 0, sin(a0) * r_base)
		var b1 := Vector3(cos(a1) * r_base, 0, sin(a1) * r_base)
		var t0 := lean_dir + Vector3(cos(a0) * r_top, height, sin(a0) * r_top)
		var t1 := lean_dir + Vector3(cos(a1) * r_top, height, sin(a1) * r_top)
		for v: Array in [[b0, n0], [b1, n1], [t1, n1], [b0, n0], [t1, n1], [t0, n0]]:
			st.set_color(bark)
			st.set_normal(v[1])
			st.add_vertex(v[0])
	var step := (height - 0.30) / tiers
	for n in tiers:
		var t := n / maxf(1.0, tiers - 1.0)
		var y := 0.28 + n * step
		var r := lerpf(r0, r1, pow(t, 0.92))
		var trunk_pos := lean_dir * (y / height)
		var apex := trunk_pos + Vector3(0, y + step * 1.48, 0)
		var points := 10
		var rim: Array[Vector3] = []
		for k in points:
			var a := k * TAU / points + n * 1.15 + 0.12 * sin(k * 2.7 + n)
			var jitter := 0.90 + 0.22 * fposmod((n * 7 + k * 3 + seed_offset) * 0.618034, 1.0)
			var reach := r * jitter * (1.04 if k % 2 == 0 else 0.52)
			var droop := reach * (0.28 if k % 2 == 0 else 0.18)
			rim.append(trunk_pos + Vector3(cos(a) * reach, y - droop, sin(a) * reach))
		for k in points:
			st.set_uv2(Vector2.ZERO)
			for p: Vector3 in [apex, rim[k], rim[(k + 1) % points]]:
				var out := Vector3(p.x - trunk_pos.x, 0, p.z - trunk_pos.z)
				st.set_normal((out.normalized() * 0.78 + Vector3.UP * 0.62).normalized() if out.length() > 0.01 else Vector3.UP)
				var light := clampf(0.76 + 0.36 * out.length() / maxf(0.1, r) + 0.08 * t, 0.72, 1.14)
				st.set_color(Color(needles.r * light, needles.g * light, needles.b * light))
				st.add_vertex(p)
		# Вторичные верхние лапки для пышности вблизи (плавно прореживаются вдали через UV2.x).
		for f in 3:
			var idx := (f * 3 + n) % points
			if idx % 2 != 0:
				idx = (idx + 1) % points
			var tip_p := rim[idx]
			var side_dir := Vector3(-(tip_p.z - trunk_pos.z), 0, tip_p.x - trunk_pos.x).normalized() * (r * 0.18)
			var fin_base := apex.lerp(tip_p, 0.35) + Vector3.UP * (step * 0.16)
			var fin_tip := apex.lerp(tip_p, 0.88) + Vector3.UP * (step * 0.12)
			var rank := clampf(0.54 + 0.07 * n + 0.08 * f, 0.52, 0.96)
			st.set_uv2(Vector2(rank, 0))
			var fin_n := ((tip_p - trunk_pos).normalized() * 0.65 + Vector3.UP * 0.76).normalized()
			for p: Vector3 in [fin_base - side_dir, fin_tip, fin_base + side_dir]:
				var light := 0.96 + 0.12 * t
				st.set_normal(fin_n)
				st.set_color(Color(needles.r * light, needles.g * light, needles.b * light))
				st.add_vertex(p)
	st.index()
	return st.commit()


static func _colored(parts: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for entry: Array in parts:
		var part: Array = entry[0]
		var arrays: Array = part[0].surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var xf: Transform3D = part[1]
		var normal_basis := xf.basis.inverse().transposed()
		for i in indices:
			st.set_color(entry[1])
			st.set_normal((normal_basis * normals[i]).normalized())
			st.add_vertex(xf * vertices[i])
	st.index()
	return st.commit()


static func _add_open_branch(st: SurfaceTool, a: Vector3, b: Vector3, r0: float, r1: float, sides: int, col: Color) -> void:
	var delta := b - a
	var dir := delta.normalized()
	var ref := Vector3.RIGHT if absf(dir.dot(Vector3.UP)) > 0.92 else Vector3.UP
	var x := dir.cross(ref).normalized()
	var z := x.cross(dir).normalized()
	st.set_uv2(Vector2.ZERO)
	for i in sides:
		var a0 := i * TAU / sides
		var a1 := (i + 1) % sides * TAU / sides
		var n0 := (x * cos(a0) + z * sin(a0)).normalized()
		var n1 := (x * cos(a1) + z * sin(a1)).normalized()
		var p00 := a + n0 * r0
		var p01 := a + n1 * r0
		var p10 := b + n0 * r1
		var p11 := b + n1 * r1
		for v: Array in [[p00, n0, 0.88], [p01, n1, 0.88], [p11, n1, 1.0], [p00, n0, 0.88], [p11, n1, 1.0], [p10, n0, 1.0]]:
			st.set_color(col * v[2])
			st.set_normal(v[1])
			st.add_vertex(v[0])


## Кустарники, саженцы и молодые деревья: разветвлённый деревянистый скелет без торцевых крышек
## и ярусные чашевидные пластины листвы, сохраняющие цельный силуэт и вблизи, и при поредении вдали.
static func _crowned(kind_mode: int, bark: Color, center: Vector3, size: Vector3, count: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_uv2(Vector2.ZERO)
	var lobe_Anchor: Array[Vector3] = []
	if kind_mode == 0:
		# Куст: 4 раскидистых побега и плотные купола от самой земли.
		for s in 4:
			var a := s * TAU / 4.0 + 0.45 + (0.18 if s % 2 == 0 else -0.14)
			var dir := Vector3(cos(a), 0, sin(a))
			var foot := dir * 0.03
			var mid := center * 0.35 + dir * (size.x * 0.22) + Vector3(0, size.y * 0.32, 0)
			var tip := center + Vector3(dir.x * size.x * 0.42, size.y * (0.04 + (s % 2) * 0.18), dir.z * size.z * 0.42)
			_add_open_branch(st, foot, mid, 0.020, 0.013, 3, bark)
			_add_open_branch(st, mid, tip, 0.013, 0.007, 3, bark)
			lobe_Anchor.append(tip)
		lobe_Anchor.append(center + Vector3(0, size.y * 0.24, 0))
		lobe_Anchor.append(center + Vector3(-size.x * 0.20, -size.y * 0.14, size.z * 0.22))
		lobe_Anchor.append(center + Vector3(size.x * 0.22, -size.y * 0.12, -size.z * 0.20))
	else:
		# Саженец (kind_mode=1) или молодое деревце (kind_mode=2): плавно изогнутый ствол и развилка ветвей.
		var h := 1.48 if kind_mode == 1 else 2.95
		var r_base := 0.036 if kind_mode == 1 else 0.068
		var r_mid := 0.024 if kind_mode == 1 else 0.044
		var r_top := 0.012 if kind_mode == 1 else 0.022
		var p0 := Vector3.ZERO
		var p1 := Vector3(0.03, h * 0.46, -0.02)
		var p2 := Vector3(center.x * 0.6, h * 0.88, center.z * 0.6)
		var sides := 4 if kind_mode == 1 else 5
		_add_open_branch(st, p0, p1, r_base, r_mid, sides, bark)
		_add_open_branch(st, p1, p2, r_mid, r_top, sides, bark)
		var branch_count := 3 if kind_mode == 1 else 4
		for b in branch_count:
			var a := b * 2.39996 + 0.65
			var start := p1.lerp(p2, 0.25 + b * 0.22)
			var end := center + Vector3(cos(a) * size.x * 0.44, size.y * (-0.10 + b * 0.15), sin(a) * size.z * 0.44)
			_add_open_branch(st, start, end, r_mid * 0.65, r_top * 0.55, 3, bark)
			lobe_Anchor.append(end)
		lobe_Anchor.append(center + Vector3(0, size.y * 0.30, 0))
		lobe_Anchor.append(center + Vector3(-size.x * 0.24, size.y * 0.05, -size.z * 0.22))
		lobe_Anchor.append(center + Vector3(size.x * 0.20, -size.y * 0.16, size.z * 0.20))

	var lobe_count := lobe_Anchor.size()
	for n in count:
		var clump := n % lobe_count
		var anchor := lobe_Anchor[clump]
		var u := fmod(n * 0.618034, 1.0)
		var v := fmod(n * 0.754878, 1.0)
		# Первые пластины каждого купола образуют несущий каркас (UV2.x <= 0.45) на всю ширину и высоту кроны.
		var is_structural := n < lobe_count * 2 or n % 3 == 0
		var r := (0.34 + 0.14 * fmod(n * 0.381966, 1.0)) if is_structural else (pow(fmod(n * 0.569840, 1.0), 0.55) * 0.40)
		var theta := u * TAU + clump * 1.1
		var y_bias := lerpf(-0.65, 0.78, v)
		var xy_r := sqrt(maxf(0.0, 1.0 - y_bias * y_bias))
		var dir := Vector3(xy_r * cos(theta), y_bias, xy_r * sin(theta))
		var p := anchor + dir * size * r
		var rel := (p - center) / size
		var normal := (rel + Vector3.UP * 0.48).normalized()
		var tangent := normal.cross(Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT).normalized()
		var bitangent := tangent.cross(normal).normalized()
		var roll := (n * 1.618034) * TAU
		var card_scale := (1.18 if is_structural else 0.95) * (0.90 + 0.24 * fposmod(n * 0.569840, 1.0))
		var base_span := (0.18 if kind_mode == 0 else (0.17 if kind_mode == 1 else 0.24)) * card_scale
		var side := (tangent * cos(roll) + bitangent * sin(roll) * 0.45).normalized() * base_span
		var up := (bitangent * cos(roll) - tangent * sin(roll) * 0.35 + Vector3.UP * 0.38).normalized() * (base_span * 0.88)
		var camber := normal * (base_span * 0.16)
		var height_shade := clampf(rel.y * 0.35 + 0.55, 0.0, 1.0)
		var shell_shade := clampf(rel.length() * 0.65, 0.0, 1.0)
		var shade := lerpf(0.76, 1.14, height_shade * 0.65 + shell_shade * 0.35) * (0.92 + 0.14 * fmod(n * 0.381966, 1.0))
		st.set_color(Color(0.29 * shade, 0.47 * shade, 0.18 * shade))
		st.set_normal(normal)
		var rank := fposmod(n * 0.173, 0.46) if is_structural else clampf(0.52 + 0.46 * fposmod(n * 0.754878, 1.0), 0.52, 0.98)
		st.set_uv2(Vector2(rank, 0))
		var p_left := p - side - camber
		var p_right := p + side - camber
		var p_top := p + up + camber
		var p_bot := p - up * 0.85 - camber * 0.4
		for q: Vector3 in [p_left, p_top, p_right, p_left, p_right, p_bot]:
			st.add_vertex(q)
	st.index()
	return st.commit()


static func _leaves(leaves: Array, color: Color, persistent_from := -1) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for n in leaves.size():
		var leaf: Array = leaves[n]
		var low := INF
		var high := -INF
		for p: Vector3 in leaf:
			low = minf(low, p.y)
			high = maxf(high, p.y)
		var normal: Vector3 = (leaf[1] - leaf[0]).cross(leaf[2] - leaf[0]).normalized()
		if normal.y < 0.0:
			normal = -normal
		st.set_normal((normal * 0.38 + Vector3.UP * 0.62).normalized())
		st.set_uv2(Vector2(0.0 if persistent_from >= 0 and n >= persistent_from else fposmod(n * 0.754878, 1.0), 0))
		for i in range(1, leaf.size() - 1):
			for v: Vector3 in [leaf[0], leaf[i], leaf[i + 1]]:
				var progress := (v.y - low) / maxf(0.001, high - low)
				var shade := lerpf(0.80, 1.08, progress) + 0.04 * sin(n * 2.4)
				st.set_color(Color(color.r * shade, color.g * shade, color.b * shade))
				st.set_uv(Vector2(float(n) / maxf(1, leaves.size()), progress))
				st.add_vertex(v)
	st.index()
	return st.commit()


## Доли четырёх характеров (сумма 1). canopy — полог, conifer — доля хвои, sun — освещённость склона,
## age — возраст участка (тот же шум, что у размеров деревьев): молодые участки зарастают чащей.
static func character(canopy: float, conifer: float, moisture: float, sun: float, age: float) -> PackedFloat32Array:
	var wet := smoothstep(0.3, 0.85, moisture)
	var shade := 1.0 - sun * (1.0 - canopy * 0.85)
	var out := PackedFloat32Array([
		sun * (1.25 - canopy) * (1.0 - 0.6 * conifer) * (0.5 + 0.5 * age),
		canopy * canopy * (0.3 + 0.7 * conifer) * (0.4 + 0.6 * age) * (1.2 - 0.5 * sun),
		smoothstep(0.35, 0.05, age) * (0.4 + canopy) * (0.6 + 0.4 * moisture),
		wet * shade * (1.0 - 0.6 * conifer),
	])
	# Квадрат делает господствующий характер заметным, переходы остаются плавными.
	var total := 0.0
	for c in 4:
		out[c] = out[c] * out[c] + 0.002
		total += out[c]
	for c in 4:
		out[c] /= total
	return out


static func mix(table: Array, ch: PackedFloat32Array) -> float:
	var v := 0.0
	for c in 4:
		v += ch[c] * table[c]
	return v


## Накопленные веса: влажная тень — мох/грибы, просветы — трава/кусты/молодняк.
## ch — доли характеров; без них лес смешанный.
static func weights(biome: int, moisture: float, light: float, canopy: float, ch := PackedFloat32Array([0.25, 0.25, 0.25, 0.25])) -> PackedFloat32Array:
	var shade := 1.0 - light
	var wet := smoothstep(0.25, 0.8, moisture)
	var conifer := biome == Biomes.TAIGA
	var out := PackedFloat32Array([
		wet * shade * (0.7 if conifer else 1.2),
		wet * shade * (1.6 if conifer else 1.0),
		wet * shade * canopy * 0.28,
		0.18 + wet * 0.45,
		0.15 + light * 0.8,
		light * 0.22,
		light * canopy * (0.035 if conifer else 0.14),
		light * canopy * (0.16 if conifer else 0.025),
		light * (1.0 - canopy) * 0.35,
		light * (1.0 - canopy * 0.7) * 0.3,
		canopy * (0.02 if conifer else 0.07),
		canopy * (0.07 if conifer else 0.015),
	])
	# Характер меняет состав, а не долю растений рядом с подстилкой: её задаёт DENSITY.
	var before := 0.0
	var after := 0.0
	for k in COUNT:
		before += out[k]
		out[k] *= TEMPLATE[0][k] * ch[0] + TEMPLATE[1][k] * ch[1] + TEMPLATE[2][k] * ch[2] + TEMPLATE[3][k] * ch[3]
		after += out[k]
	for k in COUNT:
		out[k] *= before / maxf(after, 0.0001)
	# Чаща не ждёт просветов: подрост и кусты стоят стеной и под пологом.
	var thicket := ch[THICKET]
	out[BUSH] += thicket * 0.45
	out[SAPLING] += thicket * (0.08 if conifer else 0.3)
	out[PINE] += thicket * (0.3 if conifer else 0.08)
	out[YOUNG] += thicket * (0.04 if conifer else 0.14)
	out[YOUNG_PINE] += thicket * (0.14 if conifer else 0.04)
	return out
