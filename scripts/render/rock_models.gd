class_name RockModels
extends RefCounted
## Шесть семейств: валун, плита, клин, сколотый блок, галька и раздвоенный обломок.
## Три общих меша на модель; ни геометрии, ни материалов на отдельный камень.
const VARIANTS := 6

static func mesh(size: Vector3, seed: int, moss: float, tone := 1.0) -> ArrayMesh:
	var near := _level(size, seed, moss, tone, 16, 8)
	near.set_meta("lod_meshes", [_level(size, seed, moss, tone, 10, 5), _level(size, seed, moss, tone, 6, 3)])
	return near


static func _point(d: Vector3, size: Vector3, seed: int, variation: float) -> Vector3:
	var family := posmod(seed, VARIANTS)
	var bump := 0.87 + 0.23 * Models._noise3(d * 1.8, seed)
	var p := d * bump
	# Сколы плоскостями и асимметрия формируют силуэт на всех LOD.
	p.x = clampf(p.x, -0.73, 0.84)
	p.z = clampf(p.z, -0.86, 0.72)
	p.x += p.y * (0.12 if seed % 2 == 0 else -0.15)
	if family == 1:
		p.y *= 0.58
		p.x *= 1.12
	elif family == 2:
		p.x = minf(p.x, 0.68 - p.y * 0.22)
		p.z += p.y * 0.18
	elif family == 3:
		p.x = clampf(p.x * 1.15, -0.75, 0.7)
		p.z = minf(p.z, 0.55 + p.x * 0.27)
		p.y = minf(p.y * 1.1, 0.6 - p.x * 0.2)
	elif family == 4:
		p.x *= 1.16
		p.z *= 0.72
		p.y *= 0.72
	elif family == 5:
		p.y *= 1.1
		p.y -= smoothstep(0.2, 0.8, d.y) * (1.0 - smoothstep(0.0, 0.38, absf(d.x + 0.12))) * 0.28
		p.z = minf(p.z, 0.65 - p.y * 0.2)
	if family == 2:
		p.y = minf(p.y * 1.18, 0.82 - p.x * 0.32 + p.z * 0.12)
	else:
		p.y = minf(p.y, 0.87 + p.x * 0.12)
	p.x *= lerpf(0.86, 1.18, variation)
	p.z *= lerpf(1.14, 0.82, variation)
	p.y = maxf(-0.37, p.y) + 0.25
	return p * size


static func _level(size: Vector3, seed: int, moss: float, tone: float, segments: int, rings: int) -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radial_segments = segments
	sphere.rings = rings
	var arrays := sphere.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var positions := PackedVector3Array()
	var colors := PackedColorArray()
	positions.resize(vertices.size())
	colors.resize(vertices.size())
	var variation := Models._noise3(Vector3(seed * 0.13, 2.0, 7.0), seed + 31)
	# Шум и цвет один раз на вершину, а не на каждое вхождение в треугольник.
	for i in vertices.size():
		var d := vertices[i].normalized()
		positions[i] = _point(d, size, seed, variation)
		var mineral := Models._noise3(d * 4.0, seed + 3)
		var green := smoothstep(0.12, 0.8, d.y + mineral * 0.25) * moss
		var stone := (0.78 + mineral * 0.2) * tone
		colors[i] = Color(stone * 1.03, stone, stone * 0.96).lerp(Color(0.43, 0.53, 0.29), green)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t in range(0, indices.size(), 3):
		var a := positions[indices[t]]
		var b := positions[indices[t + 1]]
		var c := positions[indices[t + 2]]
		var normal := (c - a).cross(b - a).normalized()
		if normal.length_squared() < 0.5:
			continue
		for j in 3:
			st.set_color(colors[indices[t + j]])
			st.set_normal(normal)
			st.add_vertex(positions[indices[t + j]])
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
			corners[c] = Heightfield.outer_meters(raw[k])
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
const MASSIF_REACH := 19.0 # 10,7 × 1,44 × 1,2, округлено вверх
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


## Модель выхода формы form с тремя LOD (около 430 / 190 / 110 треугольников у трёх частей).
static func outcrop_mesh(form: int) -> ArrayMesh:
	var near := _outcrop_level(form, 12, 6)
	near.set_meta("lod_meshes", [_outcrop_level(form, 8, 4), _outcrop_level(form, 6, 3)])
	return near


static func _outcrop_level(form: int, segments: int, rings: int) -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radial_segments = segments
	sphere.rings = rings
	var arrays := sphere.get_mesh_arrays()
	var dirs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var parts: Array = _OUTCROP_PARTS[form]
	for n in parts.size():
		var part: Array = parts[n]
		var seed := 500 + form * 17 + n * 5
		var basis := Basis(Vector3.UP, part[2]) * Basis(Vector3.RIGHT, part[3])
		# Соседние отдельности светлее и темнее: плиты читаются и без теней.
		var tone := 0.88 + 0.22 * WGRandom.hash2(form, n, 71)
		var cuts: Array = []
		for c in 3:
			var a := (c + WGRandom.hash2(seed, c, 3) * 0.8) * TAU / 3.0
			cuts.append([Vector3(cos(a), 0.15 + 0.6 * WGRandom.hash2(seed, c, 5), sin(a)).normalized(), 0.52 + 0.2 * WGRandom.hash2(seed, c, 7)])
		var positions := PackedVector3Array()
		var colors := PackedColorArray()
		positions.resize(dirs.size())
		colors.resize(dirs.size())
		for i in dirs.size():
			var d := dirs[i].normalized()
			# Скруглённый параллелепипед вместо шара: грани плит и блоков, а не валунов.
			var p := d / pow(pow(absf(d.x), 3.0) + pow(absf(d.y), 3.0) + pow(absf(d.z), 3.0), 1.0 / 3.0)
			p *= 0.86 + 0.24 * Models._noise3(d * 1.7, seed)
			for cut: Array in cuts:
				var over: float = p.dot(cut[0]) - cut[1]
				if over > 0.0:
					p -= cut[0] * over
			positions[i] = part[0] + basis * (p * part[1])
			var mineral := Models._noise3(d * 5.0, seed + 3)
			var stone := (0.8 + mineral * 0.2) * tone * (0.82 + 0.18 * smoothstep(-0.6, 0.4, d.y))
			var lichen := smoothstep(0.64, 0.82, Models._noise3(d * 7.0, seed + 9)) * 0.45
			var green := smoothstep(0.35, 0.9, d.y) * smoothstep(0.5, 0.78, mineral) * 0.3
			colors[i] = Color(stone * 1.02, stone, stone * 0.97).lerp(Color(0.6, 0.6, 0.47), lichen).lerp(Color(0.38, 0.47, 0.26), green)
		for t in range(0, indices.size(), 3):
			var a := positions[indices[t]]
			var b := positions[indices[t + 1]]
			var c := positions[indices[t + 2]]
			var normal := (c - a).cross(b - a).normalized()
			if normal.length_squared() < 0.5:
				continue
			for j in 3:
				st.set_color(colors[indices[t + j]])
				st.set_normal(normal)
				st.add_vertex(positions[indices[t + j]])
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
		var seed := 900 + model * 37 + n * 11
		var tone := lerpf(0.88, 1.07, WGRandom.hash2(model, n, 71))
		for p in vertices:
			var mineral := Models._noise3(p * 0.46, seed + 3)
			var stone := tone * lerpf(0.80, 0.99, mineral)
			var lichen := smoothstep(0.64, 0.81, Models._noise3(p * 1.3, seed + 9)) * 0.25
			colors.append(Color(stone * 1.02, stone, stone * 0.96).lerp(Color(0.62, 0.61, 0.47), lichen))
		for row in rings.size() - 1:
			var low: int = rings[row] * PROFILE_SIDES
			var high: int = rings[row + 1] * PROFILE_SIDES
			for i in sides.size():
				var a: int = sides[i]
				var b: int = sides[(i + 1) % sides.size()]
				_massif_triangle(st, vertices, colors, low + a, low + b, high + b)
				_massif_triangle(st, vertices, colors, low + a, high + b, high + a)
		var top := PROFILE_CROWN * PROFILE_SIDES
		for i in range(1, sides.size() - 1):
			_massif_triangle(st, vertices, colors, top + sides[0], top + sides[i], top + sides[i + 1])
	st.index()
	return st.commit()


static func _massif_triangle(st: SurfaceTool, vertices: PackedVector3Array, colors: PackedColorArray, a: int, b: int, c: int) -> void:
	var normal := (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a]).normalized()
	for i: int in [a, b, c]:
		st.set_color(colors[i])
		st.set_normal(normal)
		st.add_vertex(vertices[i])


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
		for i in PROFILE_SIDES:
			var a: Vector3 = xf * vertices[i]
			var next: Vector3 = xf * vertices[(i + 1) % PROFILE_SIDES]
			for bottom: Vector3 in [a, a.lerp(next, 0.5)]:
				var g: Vector2 = sample.call(bottom.x, bottom.z)
				if g.x == INF or g.y > 0.05: return _reject("bottom_path_water")
				clearance = maxf(clearance, bottom.y - g.x)
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
static func seat(heights: Heightfield, x: float, z: float, scale: float, v: int) -> Vector4:
	if is_outcrop(v):
		var key := Vector4(x, z, scale, v)
		heights.rock_seats_lock.lock()
		var known: Variant = heights.rock_seats.get(key)
		heights.rock_seats_lock.unlock()
		if known != null: return known
		var found := _outcrop_seat_live(heights, x, z, scale, v)
		heights.rock_seats_lock.lock()
		heights.rock_seats[key] = found
		heights.rock_seats_lock.unlock()
		return found
	var normal := normal_at(heights, x, z)
	var ground := heights.ground_at(x, z)
	if not has_seat(heights, x, z, scale, normal, ground):
		return Vector4(INF, 0, 1, 0)
	return Vector4(ground, normal.x, normal.y, normal.z)


static func _outcrop_seat_live(heights: Heightfield, x: float, z: float, scale: float, v: int) -> Vector4:
	return outcrop_seat(func(px: float, pz: float) -> Vector2:
		var cell := Vector2i(floori(px / GameConfig.TILE), floori(pz / GameConfig.TILE))
		if cell.x >= 0 and cell.y >= 0 and cell.x < heights.world.W and cell.y < heights.world.H:
			var index := cell.y * heights.world.W + cell.x
			if index < heights.world.path_mask.size() and heights.world.path_mask[index] > 0: return Vector2(INF, INF)
		if heights.road_refinement != null and heights.road_refinement.weight_at(px, pz, heights.world.W) > 0.08: return Vector2(INF, INF)
		return Vector2(heights.ground_at(px, pz), heights.depth_at(px, pz)), x, z, scale, Vector2(heights.world.world_origin) * GameConfig.TILE, v)


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
