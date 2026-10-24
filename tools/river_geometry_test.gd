extends SceneTree
## 5.9: совпадение нарисованной воды, глубины, берегов и дорожной поверхности.

var fails := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func inspect(w: WorldData, heights: Heightfield) -> void:
	var mesh := WaterBuilder._river_arrays(heights.ribbons, heights)
	var vertices: PackedVector3Array = mesh[Mesh.ARRAY_VERTEX] if not mesh.is_empty() else PackedVector3Array()
	var mismatch := 0
	var missing := 0
	var dry_axis := 0
	var wet_objects := 0
	for n in w.obj_count:
		var x := w.obj_x[n] * GameConfig.TILE
		var z := w.obj_y[n] * GameConfig.TILE
		if heights.river_level(x, z) > heights.ground_at(x, z) + 0.001:
			wet_objects += 1
	check(wet_objects == 0, "%s: vegetation objects inside river water (%d)" % [w.seed_text, wet_objects])
	if w.river_area.size() == w.N:
		for cell: int in heights._river_cells:
			var cx := cell % w.W
			var cy := cell / w.W
			for y in range(maxi(0, cy - 1), mini(w.H, cy + 2)):
				for x in range(maxi(0, cx - 1), mini(w.W, cx + 2)):
					check(w.river_area[y * w.W + x] != 0, "Final ribbon index has a one-cell mask margin")
	# Центры реально нарисованных треугольников: в глубине учитываем верхнюю
	# из перекрывающихся водных поверхностей и ту же игровую землю.
	for k in range(0, vertices.size(), 3):
		# Scalar doubles avoid rounding the centroid in Vector3 (float32).
		# On thin sloping triangles that rounding changes the sampled height.
		var px: float = (float(vertices[k].x) + vertices[k + 1].x + vertices[k + 2].x) / 3.0
		var py: float = (float(vertices[k].y) + vertices[k + 1].y + vertices[k + 2].y) / 3.0
		var pz: float = (float(vertices[k].z) + vertices[k + 1].z + vertices[k + 2].z) / 3.0
		if px < 2.0 or pz < 2.0 or px >= w.W * 4.0 - 2.0 or pz >= w.H * 4.0 - 2.0:
			continue
		var level := heights.river_level(px, pz)
		if level < py - 0.001:
			missing += 1
		var top := maxf(0.0, maxf(level, heights.lake_level(px, pz)))
		var expected := maxf(0.0, top - heights.ground_at(px, pz))
		if absf(heights.depth_at(px, pz) - expected) > 0.001:
			mismatch += 1
		var i := floori(pz / 4.0) * w.W + floori(px / 4.0)
		if w.river_area.size() == w.N and w.river_area[i] == 0 and w.ocean[i] == 0 and w.lake[i] == 0:
			missing += 1
	for r: Array in heights.ribbons:
		for p: Dictionary in r:
			if p.x < 2.0 or p.z < 2.0 or p.x >= w.W * 4.0 - 2.0 or p.z >= w.H * 4.0 - 2.0:
				continue
			if heights.ground_at(p.x, p.z) > p.y - 0.05:
				dry_axis += 1
	check(mismatch == 0, "%s: глубина отличается от видимой воды (%d)" % [w.seed_text, mismatch])
	check(missing == 0, "%s: вода вне геометрического индекса/коридора (%d)" % [w.seed_text, missing])
	check(dry_axis == 0, "%s: земля перекрывает стрежень (%d)" % [w.seed_text, dry_axis])
	print("%s: треугольников воды %d; ошибок глубины %d, коридора %d, стрежня %d" % [w.seed_text, vertices.size() / 3, mismatch, missing, dry_axis])

func synthetic() -> void:
	var w := WorldData.new()
	w.W = 16
	w.H = 16
	w.N = 256
	w.seed_text = "изгиб и озеро"
	for key in ["h", "filled", "acc"]:
		var a := PackedFloat32Array()
		a.resize(w.N)
		a.fill(0.1)
		w.set(key, a)
	for key in ["ocean", "lake", "river"]:
		var a := PackedByteArray()
		a.resize(w.N)
		w.set(key, a)
	w.rivers = [Grid.chaikin([{x = 3.5, y = 3.5, w = 0.6, e = 0.1}, {x = 5.5, y = 3.5, w = 1.6, e = 0.1},
		{x = 7.5, y = 5.5, w = 1.6, e = 0.1}, {x = 9.5, y = 5.5, w = 1.4, e = 0.1}], 2)]
	w.lake[5 * 16 + 9] = 1
	w.h[5 * 16 + 9] = 0.07
	var h := Heightfield.new(w, false)
	inspect(w, h)
	var end: Dictionary = h.ribbons[0][-1]
	check(absf(end.y - h.lake_level(end.x, end.z)) < 0.001, "Река соединяется с озером без ступеньки воды")
	# Сухая часть той же клетки рядом с узким ручьём: не квадратная вода.
	var gap := Vector2(14.0, 12.05)
	check(h.depth_at(gap.x, gap.y) > 0.0, "Вода заполняет подрезанное дно за прежним краем ленты")
	check(h.current_at(gap.x, gap.y).x > 0.0, "Течение в заполненном русле направлено вниз по реке")
	var dry := Vector2(14.0, 6.0)
	check(h.river_level(dry.x, dry.y) == -INF and h.depth_at(dry.x, dry.y) == 0.0, "На сухом берегу нет клеточной воды")
	check(h.current_at(dry.x, dry.y) == Vector2.ZERO, "На суше течения нет")
	check(h.current_at(end.x, end.z) == Vector2.ZERO, "В озере речной след успокаивается")
	var shoal := 0.0
	for p: Dictionary in h.ribbons[0]:
		if p.bend < 0.05:
			continue
		var n := Vector2(p.left.x - p.x, p.left.z - p.z).normalized()
		var bar: Vector2 = Vector2(p.x, p.z) + n * p.w * 0.8
		var pool: Vector2 = Vector2(p.x, p.z) - n * p.w * 0.8
		shoal = maxf(shoal, h.ground_at(bar.x, bar.y) - h.ground_at(pool.x, pool.y))
	check(shoal > 0.05, "На внутреннем берегу изгиба есть отмель")

func _init() -> void:
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	synthetic()
	if OS.get_cmdline_user_args().has("--synthetic-only"):
		quit(1 if fails > 0 else 0)
		return
	for seed_text in ["Север-1234", "Туман-4821", "Ущелье"]:
		var w := WorldGenerator._generate_plan(seed_text, 256) if OS.get_cmdline_user_args().has("--small-plan") else WorldGenerator.generate(seed_text, 256)
		var h := Heightfield.new(w, false)
		var water := h.water_level.duplicate()
		var bed := h.hv.duplicate()
		h.finish_paths()
		var changed := 0
		for i in w.N:
			if water[i] > -INF and absf(h.hv[i] - bed[i]) > 0.001:
				# Туннель может прорезать землю, но не водное русло.
				changed += 1
		check(changed == 0, "%s: дорожное полотно изменило русло/берег (%d)" % [seed_text, changed])
		inspect(w, h)
	print("Ошибок геометрии рек: %d" % fails)
	quit(1 if fails > 0 else 0)
