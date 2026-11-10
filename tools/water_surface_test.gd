extends SceneTree
## 6.0: точная кромка озера и непрерывные параметры течения.

var fails := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
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
	check(absf(h.water_level[0] - h.lake_level(2, 2)) < 0.0001, "Растр уровня озера совпадает с зеркалом")
	Heightfield.allow_fast_water_levels = false
	var reference := Heightfield.new(w, false)
	Heightfield.allow_fast_water_levels = true
	check(reference.water_level == h.water_level, "Уровни воды C# и GDScript совпадают")
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
	for d in flow:
		check(d.distance_to(Vector2.RIGHT) < 0.0001, "Течение направлено вниз по руслу")
	check(conditions[0].g == 0 and conditions[-1].g > 0.9, "Плёс спокоен, крутой участок образует порог")
	check(conditions[-1].r > conditions[0].r, "Скорость растёт на уклоне")
	check(conditions[2] == conditions[6] and flow[2] == flow[6], "На стыке сегментов нет скачка материала")
	# Лента, уже вошедшая в озеро, не накладывает второй слой прозрачной воды.
	var mouth: Array = []
	for x in [2.2, 2.6]:
		mouth.append({x = x, z = 2.4, y = 1.0, w = 0.1,
			left = Vector3(x, 1, 2.5), right = Vector3(x, 1, 2.3)})
	mesh = WaterBuilder._river_arrays([mouth], h)
	conditions = mesh[Mesh.ARRAY_COLOR]
	for state in conditions:
		check(state.b == 1.0, "Устье использует единую поверхность озера")
	var sea := WorldData.new()
	sea.W = 3
	sea.H = 3
	sea.N = 9
	sea.h = PackedFloat32Array([1, 1, 1, 1, -0.2, 1, 1, 1, 1])
	StageOcean.run(sea)
	check(sea.ocean[4] == 1, "Замкнутая впадина под общей плоскостью моря имеет морскую маску")
	var fields := {h = PackedFloat32Array([-0.001, -0.001, -0.001, -0.001]),
		river = PackedByteArray([1, 1, 1, 1]), lake = PackedByteArray([0, 0, 0, 0]),
		ocean = PackedByteArray([0, 0, 0, 0]), water_level = PackedFloat32Array([0.01, 0.02, 0.015, 0.025])}
	var rect := Rect2i(256, 0, 2, 2)
	var region := {rect = rect, fields = fields}
	var outer := OuterLand.new()
	outer.set_ledger({regions = {Vector2i(1, 0): region}})
	var arrays := RegionStream.water_arrays(region)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for at in range(0, points.size(), 3):
		var center := (points[at] + points[at + 1] + points[at + 2]) / 3.0
		check(absf(outer.water_at(center.x, center.z) * GameConfig.HS - center.y) < 0.0001,
			"Физика региональной воды совпадает с треугольником меша")
	check(is_equal_approx(outer.ground(256, 0), -0.001 * GameConfig.HS),
		"Отрицательное речное дно сохраняет масштаб суши")
	var named := WorldData.new()
	named.W = 20
	named.H = 20
	named.N = 400
	named.scale = 1.0
	named.lake.resize(named.N)
	named.ocean.resize(named.N)
	named.river.resize(named.N)
	named.filled.resize(named.N)
	named.filled.fill(0.1)
	for y in range(1, 19):
		for x in range(1, 19):
			if (x <= 9 and y <= 9) or (x >= 10 and y >= 10):
				named.lake[y * named.W + x] = 1
	StageLakes.run(named)
	check(named.lakes.size() == 1 and named.lake_id[21] == named.lake_id[210],
		"Диагональная перемычка сохраняет единое именованное озеро площадью 162 клетки")
	print("Ошибок поверхности воды: %d" % fails)
	quit(1 if fails else 0)
