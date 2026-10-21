class_name ForestModels
extends RefCounted
## Художественные модели умеренного леса. Общие меши, без узлов на каждую ветку.
## Три заранее построенных силуэта; RNG локальный, генерацию мира не затрагивает.

const VARIANTS := 3
const MODEL_STRIDE := 256
static var _leaf_texture: Texture2D
static var _bark_texture: Texture2D
static var _needle_texture: Texture2D


static func definition(kind: int, variant: int) -> Dictionary:
	var birch := kind == Biomes.T_BIRCH
	var conifer := kind == Biomes.T_PINE or kind == Biomes.T_SNOWPINE
	var rng := RandomNumberGenerator.new()
	rng.seed = 6500 + (1 if birch else (2 if conifer else 0)) * 97 + variant * 331
	var branches: Array = []
	var foliage: Array = []
	var height := (7.0 if birch else (7.4 if conifer else 6.0)) * (0.94 + variant * 0.06)
	var radius := 0.14 if birch else (0.23 if conifer else 0.32)
	var bend := Vector3(rng.randf_range(-0.3, 0.3), 0, rng.randf_range(-0.3, 0.3))
	var bark := Color("d5d0bd") if birch else (Color("78604b") if conifer else Color("655441"))
	# Непрерывный сужающийся ствол, раструб у земли и неровные корневые лапы.
	var path: Array[Vector3] = []
	for i in 7:
		var t := i / 6.0
		path.append(Vector3(bend.x * t * t + sin(t * 5.0) * 0.07, t * height, bend.z * t * t))
	branches.append([path, radius, radius * 0.07, bark, birch])
	for i in (5 if not birch else 3):
		var a := i * TAU / 5.0 + rng.randf()
		var foot := Vector3(cos(a), 0, sin(a)) * radius * rng.randf_range(2.4, 3.8)
		branches.append([[foot + Vector3(0, -0.04, 0), Vector3(0, radius * 1.9, 0)], radius * 0.22, radius * 0.65, bark, birch])
	if conifer:
		# Не конусы: отдельные неравные лапы с просветами и приподнятыми концами.
		for tier in 9:
			var t := tier / 9.0
			var y := 1.7 + t * (height - 1.9)
			var span := (2.05 * pow(1.0 - t, 0.8) + 0.12) * rng.randf_range(0.9, 1.1)
			for j in (5 if tier < 6 else 4):
				var a := j * TAU / 5.0 + tier * 2.399 + rng.randf_range(-0.25, 0.25)
				var dir := Vector3(cos(a), 0, sin(a))
				var start := Vector3(0, y, 0) + bend * t * t
				var end := start + dir * span + Vector3(0, -0.18 + t * 0.35, 0)
				branches.append([[start, start.lerp(end, 0.5) - Vector3(0, 0.12, 0), end], 0.045 * (1.0 - t) + 0.012, 0.008, bark, false])
				foliage.append([start.lerp(end, 0.72) + Vector3(0, 0.13, 0), Vector3(span * 0.65, 0.25 + (1.0 - t) * 0.2, span * 0.31), -a, rng.randf() * 10.0])
	else:
		# Дуб: широкая развилка. Берёза: узкая, ажурная, с поникающими концами.
		for i in (18 if birch else 22):
			var t := i / (18.0 if birch else 22.0)
			var a := i * 2.399 + rng.randf_range(-0.4, 0.4)
			var spread := (sin(t * PI) * (1.25 if birch else 1.85) + 0.25) * rng.randf_range(0.8, 1.2)
			var start := Vector3(0, height * (0.38 + t * 0.49), 0) + bend * t
			var dir := Vector3(cos(a), 0, sin(a))
			var end := start + dir * spread + Vector3(0, 0.55 if birch else 0.7, 0)
			var middle := start.lerp(end, 0.6) + Vector3(0, 0.3, 0)
			branches.append([[start, middle, end], (0.055 if birch else 0.105) * (1.0 - t * 0.65), 0.012, bark, birch])
			var size := Vector3(0.75, 0.65, 0.65) if birch else Vector3(1.0, 0.68, 0.88)
			foliage.append([end, size * rng.randf_range(0.85, 1.18), a, rng.randf() * 10.0])
			if i % 2 == 0:
				var twig := middle + Vector3(-dir.z, -0.4 if birch else 0.25, dir.x) * 0.65
				branches.append([[middle, twig], 0.025, 0.005, bark, birch])
				foliage.append([twig, size * 0.7, a + 0.8, rng.randf() * 10.0])
	var colors := [Color("708a48"), Color("809750"), Color("647e48")] if birch else [Color("526d40"), Color("607b43"), Color("49663e")]
	if conifer:
		colors = [Color("3e6252"), Color("486b51"), Color("395c50")]
	if kind == Biomes.T_SNOWPINE:
		colors = [Color("a7bbb3"), Color("94aaa0"), Color("bacac3")]
	return {trunk = _mesh(branches, [], false), crown = _mesh([], foliage, conifer), bark = Color.WHITE, leaves = colors, colored_bark = true, cutout = true, trunk_texture = _texture(false), crown_texture = _texture(true, conifer)}


## Маленькие общие бесшовные текстуры: прожилки листьев и продольная кора.
## Создаются один раз; в кадре работают штатные материалы без процедурного шейдера.
static func _texture(leaves: bool, needles: bool = false) -> Texture2D:
	var cached := _needle_texture if needles else (_leaf_texture if leaves else _bark_texture)
	if cached != null:
		return cached
	var image := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var grain := WGRandom.hash2(x, y, 65)
			var value := 0.77 + grain * 0.12 if leaves else 0.86 + 0.06 * sin(x * 0.9 + sin(y * TAU / 128.0) * 1.5) + grain * 0.04
			image.set_pixel(x, y, Color(value, value, value, 0.0 if leaves else 1.0))
	if leaves:
		var rng := RandomNumberGenerator.new()
		rng.seed = 651
		for i in (240 if needles else 110):
			var a := rng.randf() * TAU
			var r := sqrt(rng.randf()) * 50.0
			var center := Vector2(64, 64) + Vector2(cos(a), sin(a)) * r
			var angle := rng.randf() * TAU
			var length := rng.randf_range(5, 11)
			var width := length * (0.15 if needles else 0.4)
			for dy in range(-12, 13):
				for dx in range(-12, 13):
					var p := Vector2(dx, dy).rotated(angle)
					if absf(p.y) / length + pow(absf(p.x) / width, 1.5) > 1.0:
						continue
					var shade := 0.82 + 0.16 * (1.0 - absf(p.x) / width) + (0.04 if p.x < 0 else -0.04)
					if absf(p.x) < 0.45:
						shade *= 0.85
					image.set_pixel(posmod(int(center.x) + dx, 128), posmod(int(center.y) + dy, 128), Color(shade, shade, shade * 0.97, 1))
	image.generate_mipmaps()
	cached = ImageTexture.create_from_image(image)
	if needles:
		_needle_texture = cached
	elif leaves:
		_leaf_texture = cached
	else:
		_bark_texture = cached
	return cached


## Три согласованных LOD: сохраняют характер кроны и её просветы.
## Вершины уровней общие в одной поверхности, переключаются только индексы.
static func _mesh(branches: Array, foliage: Array, conifer: bool) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices: Array[PackedInt32Array] = []
	for level in 3:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for branch: Array in branches:
			if level == 2 and branch[1] < 0.06:
				continue # Тонкие веточки уже меньше пикселя; силуэт остаётся в листве.
			if level == 1 and branch[1] < 0.035:
				continue
			_tube(st, branch, (6 - level) if branch[1] > 0.12 else 3)
		for i in foliage.size():
			if level == 2 and i % 2 == 1:
				continue
			var spray: Array = foliage[i].duplicate()
			if level == 2:
				spray[1] *= 1.12 # Сохраняем заполнение дальней кроны меньшим числом побегов.
			_spray(st, spray, level, conifer)
		st.index()
		var arrays := st.commit_to_arrays()
		var offset := vertices.size()
		vertices.append_array(arrays[Mesh.ARRAY_VERTEX])
		normals.append_array(arrays[Mesh.ARRAY_NORMAL])
		colors.append_array(arrays[Mesh.ARRAY_COLOR])
		uvs.append_array(arrays[Mesh.ARRAY_TEX_UV])
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in idx.size():
			idx[i] += offset
		indices.append(idx)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices[0]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {0.012: indices[1], 0.045: indices[2]})
	return mesh


static func _vertex(st: SurfaceTool, p: Vector3, normal: Vector3, color: Color) -> void:
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(p)


static func _tube(st: SurfaceTool, data: Array, segments: int) -> void:
	var path: Array = data[0]
	for k in path.size() - 1:
		var direction: Vector3 = (path[k + 1] - path[k]).normalized()
		var side := direction.cross(Vector3.FORWARD).normalized()
		var front := side.cross(direction).normalized()
		for j in segments:
			for corner: Vector2i in [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(0, 0), Vector2i(1, 1), Vector2i(1, 0)]:
				var ring := k + corner.x
				direction = (path[mini(ring + 1, path.size() - 1)] - path[maxi(ring - 1, 0)]).normalized()
				side = direction.cross(Vector3.FORWARD).normalized()
				front = side.cross(direction).normalized()
				var t := (k + corner.x) / float(path.size() - 1)
				var a := (j + corner.y) * TAU / segments
				var normal := side * cos(a) + front * sin(a)
				var radius: float = lerpf(data[1], data[2], t)
				if k == 0 and corner.x == 0 and path.size() > 3:
					radius *= 1.3
				var p: Vector3 = path[ring] + normal * radius * (1.0 + 0.08 * sin(a * 3.0 + ring))
				var color: Color = data[3] * (0.88 + 0.12 * sin(a * 3.0 + ring * 0.8))
				if data[4] and sin(p.y * 21.0 + j * 4.7) > 0.72:
					color = Color("514d45")
				color.a = 1.0
				st.set_uv(Vector2(a / TAU * 2.0, p.y * 0.65))
				_vertex(st, p, normal, color)


static func _spray(st: SurfaceTool, data: Array, level: int, conifer: bool) -> void:
	var center: Vector3 = data[0]
	var size: Vector3 = data[1]
	var rotation := Basis(Vector3.UP, data[2])
	var phase: float = data[3]
	# Пространственные веера с вырезанными листьями вместо гладких оболочек.
	var planes := 4 if level == 0 else (3 if level == 1 else 2)
	for i in planes:
		var a := phase + i * 2.399
		var axis := rotation * Vector3(cos(a), 0, sin(a))
		var up := Vector3.UP if not conifer else (Vector3.UP * 0.45 + axis * 0.55).normalized()
		var side := up.cross(axis).normalized()
		var c := center + Vector3(0, (i - (planes - 1) * 0.5) * size.y * 0.25, 0)
		var w := maxf(size.x, size.z) * 1.12
		var h := size.y * 1.2
		var points := [c - side * w - up * h, c + side * w - up * h, c + side * w + up * h, c - side * w + up * h]
		var uv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
		for index in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uv[index])
			var shade := 0.85 + i * 0.025
			_vertex(st, points[index], (axis * 0.35 + Vector3.UP).normalized(), Color(shade, shade, shade, 1))
