class_name TerrainBuilder
extends RefCounted
## Меш рельефа: сетка с вершиной в центре каждой клетки, раскрашенная запечённой картой биомов.
## Треугольники те же, что в JS-версии и в Heightfield.ground_at; порядок вершин обратный,
## потому что в Godot лицевая сторона — по часовой стрелке.
## С 4.4 квадраты у дорог заменяются метровой сеткой RoadRefinement, остальные остаются прежними.

const TILE := GameConfig.TILE
const SHADER := preload("res://resources/terrain.gdshader")
const DETAIL_SIZE := 256   # сторона бесшовной текстуры шума для мелкой детали

var _detail: Array[ImageTexture] = []   # [шум, нормали из него]: одни на ServiceScope


## Нормаль вершины клетки (i, j) по соседним высотам (на краю соседи берутся с края карты)
static func _normal(hv: PackedFloat32Array, W: int, H: int, i: int, j: int) -> Vector3:
	var l := hv[j * W + maxi(0, i - 1)]
	var r := hv[j * W + mini(W - 1, i + 1)]
	var u := hv[maxi(0, j - 1) * W + i]
	var d := hv[mini(H - 1, j + 1) * W + i]
	return Vector3(l - r, 2.0 * TILE, u - d).normalized()


## Только CPU-массивы: подготовка в фоне, загрузка на GPU — в GameWorld.start.
static func build_arrays(w: WorldData, heights: Heightfield, cells := Rect2i()) -> Array:
	var W := w.W
	var H := w.H
	var hv := heights.hv
	if W < 2 or H < 2:
		return []
	var area := Rect2i(0, 0, W - 1, H - 1) if not cells.has_area() else cells.intersection(Rect2i(0, 0, W - 1, H - 1))
	if not area.has_area(): return []
	var columns := area.size.x + 1
	var rows := area.size.y + 1
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var uv := PackedVector2Array()
	pos.resize(columns * rows)
	nor.resize(pos.size())
	uv.resize(pos.size())
	for j in range(area.position.y, area.end.y + 1):
		for i in range(area.position.x, area.end.x + 1):
			var k := (j - area.position.y) * columns + i - area.position.x
			pos[k] = Vector3((i + 0.5) * TILE, hv[j * W + i], (j + 0.5) * TILE)
			uv[k] = Vector2((i + 0.5) / W, (j + 0.5) / H)
			nor[k] = _normal(hv, W, H, i, j)
	var idx := PackedInt32Array()
	idx.resize(area.get_area() * 6)
	var p := 0
	for j in area.size.y:
		for i in area.size.x:
			var a := j * columns + i
			var b := a + 1
			var c := a + columns
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
		refine_arrays(arrays, w, heights, area)
	return arrays


## One requested chunk plus a cell halo. Global normals, patch ordering and UVs are unchanged.
static func build_chunk(w: WorldData, heights: Heightfield, key: Vector2i) -> Array:
	var area := Rect2i(key * PlanTerrain.CELLS, Vector2i.ONE * PlanTerrain.CELLS).grow(1)
	return PlanTerrain.partition(build_arrays(w, heights, area)).get(key, [])


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
static func refine_arrays(arrays: Array, w: WorldData, heights: Heightfield, cells := Rect2i()) -> void:
	var refinement := heights.road_refinement
	if arrays.is_empty() or refinement == null:
		return
	var area := Rect2i(0, 0, w.W - 1, w.H - 1) if not cells.has_area() else cells
	var patches := {}
	for key: int in refinement.patches:
		if area.has_point(Vector2i(key % w.W, key / w.W)): patches[key] = refinement.patches[key]
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
	idx.resize(old.size() + patches.size() * (RoadRefinement.DIV * RoadRefinement.DIV - 1) * 6)
	var write := 0
	var vertex_ids := {} # общие метровые вершины соседних патчей не дублируются
	for j in range(area.position.y, area.end.y):
		for i in range(area.position.x, area.end.x):
			if not refinement.patches.has(j * w.W + i):
				var at := ((j - area.position.y) * area.size.x + i - area.position.x) * 6
				for k in 6:
					idx[write] = old[at + k]
					write += 1
	var grid := PackedInt32Array()
	grid.resize(RoadRefinement.STRIDE * RoadRefinement.STRIDE)
	for key: int in patches:
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
					id = (cz + z / RoadRefinement.DIV - area.position.y) * (area.size.x + 1) + cx + x / RoadRefinement.DIV - area.position.x
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
func material(base: Image, forest: Image = null) -> ShaderMaterial:
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
func outer_material() -> ShaderMaterial:
	var mat := _detail_material()
	mat.set_shader_parameter("use_vertex_color", true)
	return mat


func _detail_material() -> ShaderMaterial:
	if _detail.is_empty():
		var catalog := preload("res://scripts/render/asset_catalog.gd").get_catalog()
		_detail.assign([catalog.textures[3], catalog.textures[4]])
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("detail_tex", _detail[0])
	mat.set_shader_parameter("detail_normal", _detail[1])
	var surfaces := PackedVector3Array([Vector3.ZERO])
	for s: Dictionary in RoadSurface.LIST.slice(1):
		surfaces.append(Vector3(s.grain, s.organic, s.rough))
	mat.set_shader_parameter("surface_detail", surfaces)
	mat.set_shader_parameter("surface_bump", PackedVector4Array(RoadBump.LIST))
	mat.set_shader_parameter("surface_crack", PackedFloat32Array(RoadBump.CRACKS))
	return mat


func reset() -> void:
	_detail.clear()
