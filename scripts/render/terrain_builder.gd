class_name TerrainBuilder
extends RefCounted
## Меш рельефа: сетка с вершиной в центре каждой клетки, раскрашенная запечённой картой биомов.
## Треугольники те же, что в JS-версии и в Heightfield.ground_at; порядок вершин обратный,
## потому что в Godot лицевая сторона — по часовой стрелке.

const TILE := GameConfig.TILE


## Меш без материала: его можно строить в фоновом потоке, пока запекается текстура
static func build_mesh(w: WorldData, heights: Heightfield) -> ArrayMesh:
	var W := w.W
	var H := w.H
	var hv := heights.hv
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
			var l := hv[j * W + maxi(0, i - 1)]
			var r := hv[j * W + mini(W - 1, i + 1)]
			var u := hv[maxi(0, j - 1) * W + i]
			var d := hv[mini(H - 1, j + 1) * W + i]
			nor[k] = Vector3(l - r, 2.0 * TILE, u - d).normalized()
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
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Поправить высоты меша в клетках changed (и нормали вокруг них) по heights.hv
static func patch(mesh: ArrayMesh, w: WorldData, heights: Heightfield, changed: PackedInt32Array) -> void:
	var W := w.W
	var H := w.H
	var hv := heights.hv
	var arrays := mesh.surface_get_arrays(0)
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nor: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for k in changed:
		pos[k] = Vector3(pos[k].x, hv[k], pos[k].z)
		var ci := k % W
		var cj := k / W
		for j in range(maxi(0, cj - 1), mini(H, cj + 2)):
			for i in range(maxi(0, ci - 1), mini(W, ci + 2)):
				var l := hv[j * W + maxi(0, i - 1)]
				var r := hv[j * W + mini(W - 1, i + 1)]
				var u := hv[maxi(0, j - 1) * W + i]
				var d := hv[mini(H - 1, j + 1) * W + i]
				nor[j * W + i] = Vector3(l - r, 2.0 * TILE, u - d).normalized()
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


## Материал рельефа с запечённой картой биомов (картинка получает мип-уровни)
static func material(base: Image) -> StandardMaterial3D:
	base.generate_mipmaps()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(base)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 1.0
	return mat
