extends SceneTree
## 6.0: точная кромка озера и непрерывные параметры течения.

var fails := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func _init() -> void:
	var w := WorldData.new()
	w.W = 2
	w.H = 2
	w.N = 4
	w.h = PackedFloat32Array([0, 2.0 / GameConfig.HS, 2.0 / GameConfig.HS, 2.0 / GameConfig.HS])
	w.filled = PackedFloat32Array([1.1 / GameConfig.HS, 1.1 / GameConfig.HS, 1.1 / GameConfig.HS, 1.1 / GameConfig.HS])
	w.ocean = PackedByteArray([0, 0, 0, 0])
	w.lake = PackedByteArray([1, 0, 0, 0])
	w.river = PackedByteArray([0, 0, 0, 0])
	var h := Heightfield.new(w, false)
	var mesh := WaterBuilder._lake_arrays(w, h)
	var p: PackedVector3Array = mesh[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = mesh[Mesh.ARRAY_INDEX]
	var area := 0.0
	for k in range(0, indices.size(), 3):
		var a := p[indices[k]]
		var b := p[indices[k + 1]]
		var c := p[indices[k + 2]]
		area += (b - a).cross(c - a).length() * 0.5
		var mid := (a + b + c) / 3.0
		check(h.ground_at(mid.x, mid.z) < mid.y, "Озеро не рисует сухие треугольники")
		check(absf(h.lake_level(mid.x, mid.z) - mid.y) < 0.0001, "Уровень озера совпадает с игровой водой")
	check(absf(area - 2.0) < 0.0001, "Берег пересекает диагональ рельефа в точной отметке: площадь 2 м²")
	for v in p:
		check(absf(v.y - 1.0) < 0.0001, "Озеро остаётся горизонтальным")

	w.rivers = [[{x = 0.5, y = 0.5, w = 0.5, e = 0.1},
		{x = 1.5, y = 0.5, w = 0.8, e = 0.1}, {x = 2.5, y = 0.5, w = 1.0, e = 0.09},
		{x = 3.5, y = 0.5, w = 1.2, e = 0.08}]]
	var ribbons := h._river_ribbons()
	mesh = WaterBuilder._river_arrays(ribbons)
	var flow: PackedVector2Array = mesh[Mesh.ARRAY_TEX_UV]
	var conditions: PackedColorArray = mesh[Mesh.ARRAY_COLOR]
	check(flow.size() == 18 and conditions.size() == 18, "Все вершины имеют параметры течения")
	var tangent: PackedFloat32Array = mesh[Mesh.ARRAY_TANGENT]
	var normals: PackedVector3Array = mesh[Mesh.ARRAY_NORMAL]
	for k in range(0, flow.size(), 6):
		check(flow[k].x == 0.0 and flow[k + 1].x == 1.0, "U spans the river from left to right")
		check(flow[k].y == flow[k + 1].y and flow[k + 2].y == flow[k + 5].y, "Cross sections share metric V")
		check(flow[k + 2].y > flow[k].y, "Metric V grows downstream")
		var t := Vector3(tangent[k * 4], tangent[k * 4 + 1], tangent[k * 4 + 2])
		check(absf(t.dot(normals[k])) < 1e-5, "Spline frame is orthogonal")
	var total := 0.0
	for k in range(1, ribbons[0].size()):
		total += WaterBuilder._river_step(ribbons[0][k - 1], ribbons[0][k])
	check(absf(flow[0].y + total) < 1e-4 and absf(flow[-1].y) < 1e-5, "V measures arc length in metres to the outlet")
	check(conditions[0].g == 0 and conditions[-1].g > 0.9, "Плёс спокоен, крутой участок образует порог")
	check(conditions[-1].r > conditions[0].r, "Скорость растёт на уклоне")
	check(conditions[2] == conditions[6] and flow[2] == flow[6], "На стыке сегментов нет скачка материала")
	# Лента, уже вошедшая в озеро, не накладывает второй слой прозрачной воды.
	var mouth: Array = []
	for x in [2.2, 2.6]:
		mouth.append({x = x, z = 2.4, y = 1.0, w = 0.1,
			left = Vector3(x, 1, 2.5), right = Vector3(x, 1, 2.3)})
	mesh = WaterBuilder._river_arrays([mouth], h)
	check(mesh.is_empty(), "Coplanar mouth is removed geometrically, not hidden by alpha")
	print("Ошибок поверхности воды: %d" % fails)
	quit(1 if fails else 0)
