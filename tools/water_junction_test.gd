extends SceneTree
const Junction = preload("res://scripts/render/water_junction.gd")
var fails := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func lake_rect(left: float, right: float) -> Array:
	return WaterBuilder._arrays(PackedVector3Array([Vector3(left, 1, -2), Vector3(right, 1, -2), Vector3(left, 1, 2),
		Vector3(right, 1, -2), Vector3(right, 1, 2), Vector3(left, 1, 2)]))

func river_strip(left: float, right: float, high: float, low: float) -> Array:
	return [{x = left, z = 0.0, y = high, w = 1.0, left = Vector3(left, high, 1), right = Vector3(left, high, -1)},
		{x = right, z = 0.0, y = low, w = 1.0, left = Vector3(right, low, 1), right = Vector3(right, low, -1)}]

func area(mesh: Array) -> float:
	if mesh.is_empty(): return 0.0
	var p: PackedVector3Array = mesh[Mesh.ARRAY_VERTEX]
	var total := 0.0
	for k in range(0, p.size(), 3):
		total += absf((p[k + 1].x - p[k].x) * (p[k + 2].z - p[k].z) - (p[k + 1].z - p[k].z) * (p[k + 2].x - p[k].x)) * 0.5
	return total

func intersections(lake: Array, river: Array) -> void:
	if lake.is_empty() or river.is_empty(): return
	var lp: PackedVector3Array = lake[Mesh.ARRAY_VERTEX]
	var rp: PackedVector3Array = river[Mesh.ARRAY_VERTEX]
	var overlap := 0.0
	for i in range(0, lp.size(), 3):
		var a := PackedVector2Array([Vector2(lp[i].x, lp[i].z), Vector2(lp[i + 1].x, lp[i + 1].z), Vector2(lp[i + 2].x, lp[i + 2].z)])
		for j in range(0, rp.size(), 3):
			var b := PackedVector2Array([Vector2(rp[j].x, rp[j].z), Vector2(rp[j + 1].x, rp[j + 1].z), Vector2(rp[j + 2].x, rp[j + 2].z)])
			for polygon: PackedVector2Array in Geometry2D.intersect_polygons(a, b):
				var sum := 0.0
				for k in polygon.size():
					sum += (polygon[k] - polygon[0]).cross(polygon[(k + 1) % polygon.size()] - polygon[0])
				overlap += absf(sum) * 0.5
	check(overlap < 1e-5, "River and lake triangles never overlap in plan")

func partition_case(left: float, right: float, high: float, low: float, lake_left: float, expected_lake: float, expected_river: float, offset := Vector3.ZERO) -> Array:
	var raw := WaterBuilder._river_arrays([river_strip(left, right, high, low)])
	var lake := lake_rect(lake_left, 4.0)
	for mesh: Array in [lake, raw]:
		var vertices: PackedVector3Array = mesh[Mesh.ARRAY_VERTEX]
		for k in vertices.size(): vertices[k] += offset
		mesh[Mesh.ARRAY_VERTEX] = vertices
	var result := Junction.partition(lake, raw)
	check(absf(area(result[0]) - expected_lake) < 1e-4, "Lake area preserves the exposed upper surface")
	check(absf(area(result[1]) - expected_river) < 1e-4, "River mouth trims exactly at the shared contour")
	intersections(result[0], result[1])
	if not result[1].is_empty():
		var uv: PackedVector2Array = result[1][Mesh.ARRAY_TEX_UV]
		var states: PackedColorArray = result[1][Mesh.ARRAY_COLOR]
		for k in uv.size():
			check(uv[k].x >= -1e-6 and uv[k].x <= 1.0 + 1e-6, "Clipping preserves cross-stream U")
			check(uv[k].y <= 1e-5 and uv[k].y >= raw[Mesh.ARRAY_TEX_UV][0].y - 1e-5, "Clipping interpolates metric V")
			check(states[k].b == 0.0 and states[k].a == 1.0, "Geometry has no mouth alpha flag")
	return result

func phases() -> void:
	var branches := [river_strip(-4, 0, 2, 1), river_strip(-2, 0, 2, 1), river_strip(0, 4, 1, 0)]
	var d := WaterBuilder._river_distances(branches)
	check(absf(d[0] - WaterBuilder._river_step(branches[0][0], branches[0][1]) - d[2]) < 1e-6, "Main branch V meets the downstream spline")
	check(absf(d[1] - WaterBuilder._river_step(branches[1][0], branches[1][1]) - d[2]) < 1e-6, "Tributary V shares the same confluence phase")

func _init() -> void:
	partition_case(-4, 2, 1, 1, 0, 16, 8) # coplanar inlet
	partition_case(2, 6, 2, 2, 0, 12, 8) # river above lake: remove the hidden lower surface
	partition_case(-4, 2, 1, 1, 0, 16, 8, Vector3(2400, 0, 2000))
	partition_case(2, 6, 2, 2, 0, 12, 8, Vector3(2400, 0, 2000))
	var sloping := partition_case(-2, 2, 2, 0, -1, 18, 4)
	var p: PackedVector3Array = sloping[1][Mesh.ARRAY_VERTEX]
	var snapped := 0
	for v in p:
		if absf(v.x) < 1e-5:
			snapped += 1
			check(absf(v.y - 1.0) < 1e-6, "Terminal vertices snap to the exact lake plane")
	check(snapped >= 2, "The whole mouth reaches the common water edge")
	check(WaterBuilder._river_arrays([river_strip(-4, 2, 0, 0)]).is_empty(), "Ocean mouth has no coplanar second layer")
	phases()
	print("Water junction/UV regression failures: %d" % fails)
	quit(1 if fails else 0)
