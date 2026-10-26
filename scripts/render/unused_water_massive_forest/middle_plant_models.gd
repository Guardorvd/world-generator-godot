extends RefCounted
## Model-only backport from Water-Massive-Forest @ 9f5e66d54e83f9dcee3e30500394a6dbaf25602d.
## Dormant library: no class_name, registration, placement, or scene integration.
## Source: scripts/render/understory_models.gd. Only the six added plant forms.
const BackportedForest = preload("res://scripts/render/unused_water_massive_forest/relict_tree_models.gd")
const BaseUnderstory = preload("res://scripts/render/understory_models.gd")


static func meshes() -> Array[Mesh]:
	return [_hazel(1.7, 15601), _hazel(4.1, 15602), _juniper(1.25), _juniper(3.1), _reed_grass(), _great_fern()]


static func _middle_mesh(source: ArrayMesh) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.create_from(source, 0)
	st.index()
	var arrays := st.commit_to_arrays()
	if arrays[Mesh.ARRAY_TEX_UV] == null:
		var uv := PackedVector2Array()
		for p: Vector3 in arrays[Mesh.ARRAY_VERTEX]: uv.append(Vector2(p.x * 0.5, p.y * 0.5))
		arrays[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return Models._with_lods(mesh)


static func _leaf(st: SurfaceTool, center: Vector3, along: Vector3, width: float, color: Color) -> void:
	var side := along.cross(Vector3.UP).normalized() * width
	if side.length_squared() < 0.00001: side = Vector3.RIGHT * width
	var points := [center - along * 0.45, center + side + Vector3.UP * width * 0.4, center + along * 0.55 + Vector3.UP * width * 0.25, center - side - Vector3.UP * width * 0.15]
	var normal := (side.cross(along).normalized() + Vector3.UP * 0.35).normalized()
	if normal.y < 0: normal = -normal
	var uv := [Vector2(0.5, 1), Vector2(0, 0.5), Vector2(0.5, 0), Vector2(1, 0.5)]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_color(color)
		st.set_normal(normal)
		st.set_uv(uv[i])
		st.add_vertex(points[i])


static func _hazel(height: float, seed_num: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_num
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bark := Color("796443")
	var rings := 6 if height < 2.0 else 8
	for stem in (4 if height < 2.0 else 6):
		var a := stem * 2.399 + rng.randf_range(-0.2, 0.2)
		var direction := Vector3(cos(a), 0, sin(a))
		var path: Array[Vector3] = []
		var top := height * rng.randf_range(0.82, 1.0)
		for i in rings + 1:
			var t := float(i) / rings
			path.append(direction * (0.08 + pow(t, 1.5) * height * 0.22) + Vector3.UP * top * t)
		BackportedForest._tube(st, [path, height * 0.012, 0.006, bark, false], 4, true)
		for i in range(3, rings + 1):
			var t := float(i) / rings
			var out := direction.rotated(Vector3.UP, -0.65 if i % 2 else 0.65)
			var end := path[i] + out * height * (0.14 - t * 0.065) + Vector3.UP * 0.08
			BackportedForest._tube(st, [[path[i], end], 0.014, 0.003, bark, false], 3, true)
			for leaf in 5:
				var p := path[i].lerp(end, 0.3 + leaf * 0.16)
				var axis := out.rotated(Vector3.UP, -0.8 if leaf % 2 else 0.8) * (0.18 + height * 0.035) + Vector3.UP * (0.1 + height * 0.025)
				_leaf(st, p, axis, 0.08 + height * 0.014, Color(0.4 + t * 0.08, 0.56 + t * 0.09, 0.23))
	return _middle_mesh(st.commit())


static func _juniper(height: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for shoot in 4:
		var a := shoot * 2.399
		var h := height * (0.7 + shoot * 0.1)
		var mesh := BaseUnderstory._spruce(h, Color("6e624b"), 5, height * 0.24, 0.08, Color("557449"))
		st.append_from(mesh, 0, Transform3D(Basis.IDENTITY, Vector3(cos(a), 0, sin(a)) * height * 0.12))
	return _middle_mesh(st.commit())


static func _reed_grass() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade in 16:
		var a := blade * 2.399
		var direction := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a))
		var height := 2.0 + (blade % 5) * 0.14
		for joint in 7:
			for corner: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 0), Vector2i(1, 1), Vector2i(0, 1)]:
				var t := (joint + corner.x) / 7.0
				var center := direction * (0.12 + 0.7 * t * t) + Vector3.UP * height * (t - 0.15 * pow(t, 4))
				var width := 0.06 * (1.0 - t * 0.93)
				st.set_normal((Vector3.UP * 0.35 - direction).normalized())
				st.set_color(Color(0.38 + t * 0.12, 0.5 + t * 0.1, 0.22))
				st.set_uv(Vector2(corner.y, t))
				st.add_vertex(center + side * (corner.y * 2.0 - 1.0) * width)
	return _middle_mesh(st.commit())


static func _great_fern() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for frond in 8:
		var a := frond * 2.399
		var forward := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a))
		var path: Array[Vector3] = []
		for step in 9:
			var t := step / 8.0
			path.append(forward * (0.05 + t * 1.35) + Vector3.UP * (0.02 + sin(t * PI * 0.85) * (2.05 + frond % 3 * 0.1)))
		BackportedForest._tube(st, [path, 0.015, 0.004, Color("617d36"), false], 3, true)
		for step in range(2, 9):
			var t := step / 8.0
			for sign_side: float in [-1.0, 1.0]:
				var reach := 0.5 * (1.0 - t * 0.8)
				_leaf(st, path[step] + side * sign_side * reach * 0.5, side * sign_side * reach + forward * 0.12 + Vector3.UP * 0.12 * (1.0 - t),
					0.1 * (1.0 - t * 0.5), Color(0.33 + t * 0.08, 0.52 + t * 0.09, 0.23))
	return _middle_mesh(st.commit())
