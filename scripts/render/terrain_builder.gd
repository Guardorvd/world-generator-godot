class_name TerrainBuilder
extends RefCounted
## Меш рельефа: сетка с вершиной в центре каждой клетки, раскрашенная запечённой картой биомов.
## Треугольники те же, что в JS-версии и в Heightfield.ground_at; порядок вершин обратный,
## потому что в Godot лицевая сторона — по часовой стрелке.
## С 4.4 квадраты у дорог заменяются метровой сеткой RoadRefinement, остальные остаются прежними.

const TILE := GameConfig.TILE
const SHADER := preload("res://resources/terrain.gdshader")
const DETAIL_SIZE := 256   # сторона бесшовной текстуры шума для мелкой детали

static var _detail: Array[ImageTexture] = []   # [шум, нормали из него]: одни на все миры


## Нормаль вершины клетки (i, j) по соседним высотам (на краю соседи берутся с края карты)
static func _normal(hv: PackedFloat32Array, W: int, H: int, i: int, j: int) -> Vector3:
	var l := hv[j * W + maxi(0, i - 1)]
	var r := hv[j * W + mini(W - 1, i + 1)]
	var u := hv[maxi(0, j - 1) * W + i]
	var d := hv[mini(H - 1, j + 1) * W + i]
	return Vector3(l - r, 2.0 * TILE, u - d).normalized()


## Только CPU-массивы: подготовка в фоне, загрузка на GPU — в GameWorld.start.
static func build_arrays(w: WorldData, heights: Heightfield) -> Array:
	var W := w.W
	var H := w.H
	var hv := heights.hv
	if W < 2 or H < 2:
		return []
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var uv := PackedVector2Array()
	pos.resize(w.N)
	nor.resize(w.N)
	uv.resize(w.N)
	for j in H:
		for i in W:
			var k := j * W + i
			pos[k] = Vector3((i + 0.5) * TILE, hv[k], (j + 0.5) * TILE)
			uv[k] = Vector2((i + 0.5) / W, (j + 0.5) / H)
			nor[k] = _normal(hv, W, H, i, j)
	var idx := PackedInt32Array()
	idx.resize((W - 1) * (H - 1) * 6)
	var p := 0
	for j in H - 1:
		for i in W - 1:
			var a := j * W + i
			var b := a + 1
			var c := a + W
			var d := c + 1
			idx[p] = a
			idx[p + 1] = b
			idx[p + 2] = c
			idx[p + 3] = b
			idx[p + 4] = d
			idx[p + 5] = c
			p += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	if heights.road_refinement != null:
		refine_arrays(arrays, w, heights)
	return arrays


## Поправить высоты меша в клетках changed (и нормали вокруг них) по heights.hv
static func patch(arrays: Array, w: WorldData, heights: Heightfield, changed: PackedInt32Array) -> void:
	var W := w.W
	var H := w.H
	var hv := heights.hv
	if changed.is_empty() or arrays.is_empty():
		return
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nor: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var touched := PackedByteArray()
	touched.resize(w.N)
	for k: int in changed:
		pos[k] = Vector3(pos[k].x, hv[k], pos[k].z)
		var ci := k % W
		var cj := k / W
		for j in range(maxi(0, cj - 1), mini(H, cj + 2)):
			for i in range(maxi(0, ci - 1), mini(W, ci + 2)):
				var n := j * W + i
				if touched[n] == 0:
					nor[n] = _normal(hv, W, H, i, j)
					touched[n] = 1
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor


## Заменить только квадраты у путей сеткой 1 м. Это часть земли, отдельной накладной ленты нет.
static func refine_arrays(arrays: Array, w: WorldData, heights: Heightfield) -> void:
	var refinement := heights.road_refinement
	if arrays.is_empty() or refinement == null:
		return
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nor: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var colors := PackedColorArray()
	colors.resize(pos.size())
	colors.fill(Color(0, 0, 0, 0))
	var uv2 := PackedVector2Array()
	uv2.resize(pos.size())
	var idx := PackedInt32Array()
	var old: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	# Число индексов известно заранее: каждый дорожный квадрат заменяется DIV² квадратами.
	idx.resize(old.size() + refinement.patches.size() * (RoadRefinement.DIV * RoadRefinement.DIV - 1) * 6)
	var write := 0
	var vertex_ids := {} # общие метровые вершины соседних патчей не дублируются
	for j in w.H - 1:
		for i in w.W - 1:
			if not refinement.patches.has(j * w.W + i):
				var at := (j * (w.W - 1) + i) * 6
				for k in 6:
					idx[write] = old[at + k]
					write += 1
	var grid := PackedInt32Array()
	grid.resize(RoadRefinement.STRIDE * RoadRefinement.STRIDE)
	for key: int in refinement.patches:
		var p: Dictionary = refinement.patches[key]
		var cx := key % w.W
		var cz := key / w.W
		var right_patch := refinement.patches.has(key + 1)
		var lower_patch := refinement.patches.has(key + w.W)
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				var n := z * RoadRefinement.STRIDE + x
				var vk := (cz * RoadRefinement.DIV + z) * (w.W * RoadRefinement.DIV) + cx * RoadRefinement.DIV + x
				if vertex_ids.has(vk):
					grid[n] = vertex_ids[vk]
					continue
				var px := (cx + 0.5) * TILE + x * RoadRefinement.STEP
				var pz := (cz + 0.5) * TILE + z * RoadRefinement.STEP
				var id := pos.size()
				var normal: Vector3
				# При выборке на правой/нижней границе height_at читает соседний патч.
				# Если его нет, нужна прежняя выборка исходного рельефа в double.
				if x > 0 and x < RoadRefinement.DIV and z > 0 and z < RoadRefinement.DIV \
						and (x < RoadRefinement.DIV - 1 or right_patch) \
						and (z < RoadRefinement.DIV - 1 or lower_patch):
					normal = Vector3(p.h[n - 1] - p.h[n + 1], 2.0, p.h[n - RoadRefinement.STRIDE] - p.h[n + RoadRefinement.STRIDE]).normalized()
				else:
					normal = _local_normal(heights, px, pz)
				if x % RoadRefinement.DIV == 0 and z % RoadRefinement.DIV == 0:
					id = (cz + z / RoadRefinement.DIV) * w.W + cx + x / RoadRefinement.DIV
					pos[id].y = p.h[n]
					nor[id] = normal
					colors[id] = p.color[n]
					uv2[id] = p.uv[n]
				else:
					pos.append(Vector3(px, p.h[n], pz))
					nor.append(normal)
					uv.append(Vector2(px / (w.W * TILE), pz / (w.H * TILE)))
					colors.append(p.color[n])
					uv2.append(p.uv[n])
				vertex_ids[vk] = id
				grid[n] = id
		for z in RoadRefinement.DIV:
			for x in RoadRefinement.DIV:
				var a := z * RoadRefinement.STRIDE + x
				idx[write] = grid[a]
				idx[write + 1] = grid[a + 1]
				idx[write + 2] = grid[a + RoadRefinement.STRIDE]
				idx[write + 3] = grid[a + 1]
				idx[write + 4] = grid[a + RoadRefinement.STRIDE + 1]
				idx[write + 5] = grid[a + RoadRefinement.STRIDE]
				write += 6
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx


static func _local_normal(heights: Heightfield, x: float, z: float) -> Vector3:
	return Vector3(heights.ground_at(x - 1.0, z) - heights.ground_at(x + 1.0, z), 2.0,
		heights.ground_at(x, z - 1.0) - heights.ground_at(x, z + 1.0)).normalized()


## Материал рельефа с запечённой картой биомов (картинка получает мип-уровни).
## С 2.5 это шейдер resources/terrain.gdshader: вблизи поверх карты мелкая деталь, см. комментарий в нём
static func material(base: Image, forest: Image = null) -> ShaderMaterial:
	base.generate_mipmaps()
	var mat := _detail_material()
	mat.set_shader_parameter("base_tex", ImageTexture.create_from_image(base))
	mat.set_shader_parameter("base_texel", Vector2(1.0 / base.get_width(), 1.0 / base.get_height()))
	if forest != null:
		var masks := forest.duplicate() as Image
		masks.generate_mipmaps()
		mat.set_shader_parameter("forest_tex", ImageTexture.create_from_image(masks))
		mat.set_shader_parameter("forest_enabled", true)
	return mat


## Тот же материал для рельефа за краем карты: цвет из вершин
static func outer_material() -> ShaderMaterial:
	var mat := _detail_material()
	mat.set_shader_parameter("use_vertex_color", true)
	return mat


static func _detail_material() -> ShaderMaterial:
	if _detail.is_empty():
		# бесшовный шум один раз за запуск игры; не зависит от сида, это фактура, а не мир
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.frequency = 0.035
		noise.fractal_octaves = 4
		noise.seed = 2025
		var img := noise.get_seamless_image(DETAIL_SIZE, DETAIL_SIZE)
		var nrm := img.duplicate() as Image
		nrm.convert(Image.FORMAT_RGBA8)
		nrm.bump_map_to_normal_map(6.0)
		img.generate_mipmaps()
		nrm.generate_mipmaps()
		_detail = [ImageTexture.create_from_image(img), ImageTexture.create_from_image(nrm)]
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("detail_tex", _detail[0])
	mat.set_shader_parameter("detail_normal", _detail[1])
	var surfaces := PackedVector3Array([Vector3.ZERO])
	for s: Dictionary in RoadSurface.LIST.slice(1):
		surfaces.append(Vector3(s.grain, s.organic, s.rough))
	mat.set_shader_parameter("surface_detail", surfaces)
	mat.set_shader_parameter("surface_bump", PackedVector2Array(RoadBump.LIST))
	return mat
