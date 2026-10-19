class_name TerrainBuilder
extends RefCounted
## Меш рельефа: сетка с вершиной в центре каждой клетки, раскрашенная запечённой картой биомов.
## Треугольники те же, что в JS-версии и в Heightfield.ground_at; порядок вершин обратный,
## потому что в Godot лицевая сторона — по часовой стрелке.

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
	for k: int in changed:
		pos[k] = Vector3(pos[k].x, hv[k], pos[k].z)
		var ci := k % W
		var cj := k / W
		for j in range(maxi(0, cj - 1), mini(H, cj + 2)):
			for i in range(maxi(0, ci - 1), mini(W, ci + 2)):
				nor[j * W + i] = _normal(hv, W, H, i, j)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor


## Материал рельефа с запечённой картой биомов (картинка получает мип-уровни).
## С 2.5 это шейдер resources/terrain.gdshader: вблизи поверх карты мелкая деталь, см. комментарий в нём
static func material(base: Image) -> ShaderMaterial:
	base.generate_mipmaps()
	var mat := _detail_material()
	mat.set_shader_parameter("base_tex", ImageTexture.create_from_image(base))
	mat.set_shader_parameter("base_texel", Vector2(1.0 / base.get_width(), 1.0 / base.get_height()))
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
	return mat
