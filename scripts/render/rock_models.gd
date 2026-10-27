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
