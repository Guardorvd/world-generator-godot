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


## Ось выхода: между вертикалью и нормалью склона.
static func outcrop_up(normal: Vector3) -> Vector3:
	return Vector3.UP.lerp(normal, OUTCROP_TILT).normalized()


## Опора выхода масштаба scale: Vector4(высота основания, ось x, y, z); x = INF — места нет.
## sample(x, z) -> Vector2(земля, глубина воды над ней; INF — нет данных).
## Основание опускается до самой низкой точки кольца опоры: край выхода не висит над склоном,
## а нижняя часть модели уходит в землю. Слишком неровное кольцо (кромка выемки дороги,
## излом гребня) похоронило бы выход — такое место отклоняется.
static func outcrop_seat(sample: Callable, x: float, z: float, scale: float, origin := Vector2.ZERO) -> Vector4:
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


static func outcrop_transform(x: float, z: float, scale: float, up: Vector3, base: float, origin := Vector2.ZERO) -> Transform3D:
	var ox := (x + origin.x) / GameConfig.TILE
	var oy := (z + origin.y) / GameConfig.TILE
	var rot := WGRandom.hash2(floori(ox * 97), floori(oy * 89), 7) * TAU
	var shape := WGRandom.hash2(floori(ox * 127), floori(oy * 131), 15632)
	var basis := Basis(Quaternion(Vector3.UP, up)) * Basis(Vector3.UP, rot)
	basis = basis.scaled_local(Vector3(scale, scale * lerpf(0.85, 1.15, shape), scale * lerpf(0.85, 1.05, shape)))
	return Transform3D(basis, Vector3(x, base, z))


## Small solid cores of the visible blocks, in ForestObstacles' existing capsule format.
## No extra nodes or mesh collision: unlike a single upright cylinder, these follow the tilt.
static func outcrop_solids(xf: Transform3D, form: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
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
		return outcrop_seat(func(px: float, pz: float) -> Vector2:
			var cell := Vector2i(floori(px / GameConfig.TILE), floori(pz / GameConfig.TILE))
			if cell.x >= 0 and cell.y >= 0 and cell.x < heights.world.W and cell.y < heights.world.H:
				var index := cell.y * heights.world.W + cell.x
				if index < heights.world.path_mask.size() and heights.world.path_mask[index] > 0: return Vector2(INF, INF)
			if heights.road_refinement != null and heights.road_refinement.weight_at(px, pz, heights.world.W) > 0.08: return Vector2(INF, INF)
			return Vector2(heights.ground_at(px, pz), heights.depth_at(px, pz)), x, z, scale, Vector2(heights.world.world_origin) * GameConfig.TILE)
	var normal := normal_at(heights, x, z)
	var ground := heights.ground_at(x, z)
	if not has_seat(heights, x, z, scale, normal, ground):
		return Vector4(INF, 0, 1, 0)
	return Vector4(ground, normal.x, normal.y, normal.z)


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
		return Vector2(s.x, INF if s.x == INF else s.y - s.x), x, z, scale, f.get("world_origin", Vector2.ZERO))
