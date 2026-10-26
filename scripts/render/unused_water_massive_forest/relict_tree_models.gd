extends RefCounted
## Model-only backport from Water-Massive-Forest @ 9f5e66d54e83f9dcee3e30500394a6dbaf25602d.
## Dormant library: no class_name, registration, placement, or scene integration.
## Source: scripts/render/forest_models.gd. Oak: conifer=false; pine: conifer=true.
## _relict(variant, conifer) returns trunk/crown meshes, textures and original model metadata.
const VARIANTS := 3
static var _leaf_texture: Texture2D
static var _bark_texture: Texture2D
static var _needle_texture: Texture2D


static func _relict(variant: int, conifer: bool) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 15500 + variant * 331 + (97 if conifer else 0)
	var height: float = ([18.0, 23.0, 29.0] if conifer else [15.5, 20.5, 26.0])[variant]
	var reach: float = ([5.9, 6.4, 7.0] if conifer else [6.3, 7.0, 7.5])[variant]
	var radius := 0.56 if conifer else 0.76
	var bark := Color("74604c") if conifer else Color("74614d")
	var bend := Vector3(rng.randf_range(-0.55, 0.55), 0, rng.randf_range(-0.55, 0.55))
	var branches: Array = []
	var foliage: Array = []
	var path: Array[Vector3] = []
	var rings := ceili(height / 1.5)
	for i in rings + 1:
		var t := float(i) / rings
		path.append(bend * t * t + Vector3(sin(t * 5.0) * 0.09, height * 0.98 * t, 0))
	branches.append([path, radius, radius * 0.12, bark, false])
	_roots(branches, rng, 7, Vector2(1.2, 1.75) if not conifer else Vector2(1.1, 1.6), 1.4, 0.14, radius * 0.7, bark)
	if not conifer:
		# Oak limbs fork before the vault instead of making a pine-like central whorl.
		for limb in 5:
			var a := limb * TAU / 5.0
			var dir := Vector3(cos(a), 0, sin(a))
			branches.append([[Vector3(0, height * 0.49, 0), dir * reach * 0.15 + Vector3(0, height * 0.58, 0),
				dir * reach * 0.3 + Vector3(0, height * 0.66, 0)], 0.33, 0.17, bark, false])
	# Overlapping rings of horizontal, gently curved sprays. Lower rim starts above 2/3 height.
	for tier in 4:
		var t := 0.71 + tier * 0.078
		var extent: float = [0.88, 1.0, 0.78, 0.48][tier] * reach
		for ring in 2:
			var count := 10 if ring == 1 else 5
			for j in count:
				var a := j * TAU / count + tier * 1.13 + ring * 0.7 + rng.randf_range(-0.14, 0.14)
				var dir := Vector3(cos(a), 0, sin(a))
				var spread := extent * (0.76 if ring == 1 else 0.25) * rng.randf_range(0.93, 1.07)
				var top := height * t + (0.15 if ring == 1 else 0.55)
				var start := bend * t * t + Vector3(0, height * (t - 0.085), 0)
				if not conifer:
					var sector := roundf(a / (TAU / 5.0)) * TAU / 5.0
					start = Vector3(cos(sector), 0, sin(sector)) * reach * 0.3 + Vector3(0, height * 0.66, 0)
				var end := bend * t * t + dir * spread + Vector3(0, top, 0)
				var middle := start.lerp(end, 0.52) + Vector3(0, 0.6, 0)
				branches.append([[start, middle, end], (0.14 if conifer else 0.21) * (1.0 - tier * 0.15), 0.025, bark, false])
				var size := Vector3(extent * (0.32 if ring else 0.38), 0.45, extent * 0.32)
				var frame := Basis(Vector3.UP, -a) * Basis(Vector3.FORWARD, -0.1 if ring else 0.05)
				# Final flag selects a tessellated vault patch; metric size stays separate from UV coverage.
				foliage.append([end, size, a, rng.randf() * 10.0, frame, 0.11, true])
	var colors := [Color("63844d"), Color("799954"), Color("6b8f4d")]
	if conifer: colors = [Color("547d5b"), Color("628a62"), Color("4e7758")]
	return {trunk = _mesh(branches, [], false, true), crown = _mesh([], foliage, conifer, true),
		bark = Color.WHITE, leaves = colors, colored_bark = true, cutout = true,
		trunk_texture = _texture(false), crown_texture = _texture(true, conifer)}


static func _roots(branches: Array, rng: RandomNumberGenerator, count: int, reach: Vector2, top: float, r0: float, r1: float, bark: Color) -> void:
	for i in count:
		var a := i * TAU / count + rng.randf_range(0.0, 0.9)
		var foot := Vector3(cos(a), 0, sin(a)) * rng.randf_range(reach.x, reach.y)
		branches.append([[foot + Vector3(0, -0.04, 0), Vector3(0, top, 0)], r0, r1, bark, false])


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
		for i in (240 if needles else 150):
			var a := rng.randf() * TAU
			var r := sqrt(rng.randf()) * 50.0
			var center := Vector2(64, 64) + Vector2(cos(a), sin(a)) * r
			var angle := rng.randf() * TAU
			var length := rng.randf_range(5, 11) if needles else rng.randf_range(6, 12)
			var width := length * (0.15 if needles else 0.5) # 9.4: круглее и мягче
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


static func _mesh(branches: Array, foliage: Array, conifer: bool, relict := false) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices: Array[PackedInt32Array] = []
	# 9.4: эллипсоид кроны. Нормали листвы смотрят от его центра: крона освещается как мягкий
	# цельный объём (приём стилизованных деревьев), а не как стопка плоских веток.
	var crown := [Vector3.ZERO, Vector3.ONE]
	if not foliage.is_empty():
		var center := Vector3.ZERO
		for spray: Array in foliage:
			center += spray[0]
		center /= foliage.size()
		var extent := Vector3.ONE * 0.5
		for spray: Array in foliage:
			extent = extent.max((spray[0] - center).abs() + Vector3.ONE * 0.4)
		crown = [center, extent]
	for level in 3:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for branch_index in branches.size():
			var branch: Array = branches[branch_index]
			if relict and level == 2 and branch_index > 0 and branch[1] < 0.25 and branch_index % 3 != 0:
				continue # Keep large structural forks; crown layers carry the distant silhouette.
			# Первая ветвь (ствол, у куста главный стебель) остаётся на всех уровнях: поверхность не пустеет.
			if level == 2 and branch[1] < 0.06 and branch != branches[0]:
				continue # Тонкие веточки уже меньше пикселя; силуэт остаётся в листве.
			if level == 1 and branch[1] < 0.035 and branch != branches[0]:
				continue
			_tube(st, branch, ((12 - level * 3) if relict else (6 - level)) if branch[1] > 0.12 else 3, relict)
		for i in foliage.size():
			if level == 2 and i % 2 == 1 and not relict:
				continue
			var spray: Array = foliage[i].duplicate()
			if level == 2:
				spray[1] *= 1.12 # Сохраняем заполнение дальней кроны меньшим числом побегов.
			_spray(st, spray, level, conifer, crown)
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
	# 9.9+: те же уровни отдельными мешами — VegetationLayer сменяет их по расстоянию растворением,
	# а не скачком автоматического LOD (meta "levels").
	var levels: Array[ArrayMesh] = []
	for level in 3:
		var part := arrays.duplicate()
		part[Mesh.ARRAY_INDEX] = indices[level]
		var level_mesh := ArrayMesh.new()
		level_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, part)
		levels.append(level_mesh)
	mesh.set_meta("levels", levels)
	return mesh


static func _vertex(st: SurfaceTool, p: Vector3, normal: Vector3, color: Color) -> void:
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(p)


static func _tube(st: SurfaceTool, data: Array, segments: int, metric_uv := false) -> void:
	var path: Array = data[0]
	var arc := PackedFloat64Array([0.0])
	if metric_uv:
		for i in range(1, path.size()): arc.append(arc[-1] + path[i - 1].distance_to(path[i]))
	var repeats := maxf(2.0, roundf(TAU * float(data[1]) * 0.85))
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
				st.set_uv(Vector2(a / TAU * repeats, arc[ring] * 0.65) if metric_uv else Vector2(a / TAU * 2.0, p.y * 0.65))
				_vertex(st, p, normal, color)


static func _crown_light(p: Vector3, crown: Array) -> Array:
	var d: Vector3 = (p - crown[0]) / crown[1]
	var normal := (d + Vector3.UP * 0.6).normalized() if d.length() > 0.05 else Vector3.UP
	var shade := 0.8 + 0.24 * clampf(d.length(), 0.0, 1.0)
	return [normal, Color(shade, shade, shade, 1)]


static func _spray(st: SurfaceTool, data: Array, level: int, conifer: bool, crown: Array) -> void:
	var center: Vector3 = data[0]
	var size: Vector3 = data[1]
	var rotation := Basis(Vector3.UP, data[2])
	var phase: float = data[3]
	# Пространственные веера с вырезанными листьями вместо гладких оболочек.
	var planes := 4 if level == 0 else (3 if level == 1 else 2)
	if data.size() > 6 and data[6]:
		_vault_spray(st, data, level, crown)
		return
	if data.size() > 4:
		_flat_spray(st, data, planes, crown)
		return
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
			var lit := _crown_light(points[index], crown)
			_vertex(st, points[index], lit[0], lit[1])


static func _flat_spray(st: SurfaceTool, data: Array, planes: int, crown: Array) -> void:
	var center: Vector3 = data[0]
	var size: Vector3 = data[1]
	var phase: float = data[3]
	var frame: Basis = data[4]
	var fold: float = data[5] if data.size() > 5 else 0.4
	var uv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	for i in planes:
		var k := i - (planes - 1) * 0.5
		var b := frame * Basis(Vector3.RIGHT, k * fold + sin(phase + i * 1.7) * fold * 0.3)
		var x := b.x * size.x * 1.12
		var z := b.z * size.z * 1.12
		var c := center + frame.y * k * size.y * 0.25
		var points := [c - x - z, c + x - z, c + x + z, c - x + z]
		var normal := b.y if b.y.y >= 0.0 else -b.y
		normal = (normal * 0.6 + Vector3.UP * 0.4).normalized()
		for index in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uv[index])
			var lit := _crown_light(points[index], crown)
			_vertex(st, points[index], (normal + lit[0]).normalized(), lit[1])


static func _vault_spray(st: SurfaceTool, data: Array, level: int, crown: Array) -> void:
	var planes := 3 - level
	var size: Vector3 = data[1]
	var coordinates: Array[Vector2] = []
	if level == 0:
		for z in 2:
			for x in 2:
				for corner: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 0), Vector2i(1, 1), Vector2i(0, 1)]:
					coordinates.append(Vector2(x + corner.x, z + corner.y) * 0.5)
	else:
		# A centre fan retains the arch at distant LODs; a single flat quad would collapse it.
		var corners := [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]
		for side in 4: coordinates.append_array([corners[side], corners[(side + 1) % 4], Vector2(0.5, 0.5)])
	for sheet in planes:
		var frame: Basis = data[4] * Basis(Vector3.RIGHT, (sheet - (planes - 1) * 0.5) * 0.13)
		var center: Vector3 = data[0] + Vector3.UP * (sheet - (planes - 1) * 0.5) * 0.18
		for uv: Vector2 in coordinates:
			var px := uv.x * 2.0 - 1.0
			var pz := uv.y * 2.0 - 1.0
			var p := center + frame * Vector3(px * size.x * 1.12,
				0.7 * (1.0 - px * px) * (1.0 - pz * pz), pz * size.z * 1.12)
			st.set_uv(uv)
			var lit := _crown_light(p, crown)
			_vertex(st, p, (frame.y + lit[0]).normalized(), lit[1])
