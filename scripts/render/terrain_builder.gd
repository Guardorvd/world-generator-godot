class_name TerrainBuilder
extends RefCounted
## Меш рельефа: сетка с вершиной в центре каждой клетки, раскрашенная запечённой картой биомов.
## Треугольники те же, что в JS-версии и в Heightfield.ground_at; порядок вершин обратный,
## потому что в Godot лицевая сторона — по часовой стрелке.

const TILE := GameConfig.TILE


static func build(w: WorldData, heights: Heightfield, base: Image) -> MeshInstance3D:
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
	base.generate_mipmaps()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(base)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 1.0
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Terrain"
	return mi
