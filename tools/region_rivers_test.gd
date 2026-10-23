extends SceneTree
const Regions := preload("res://scripts/world/region_preparation.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func fixture(x0 := 0, sea := false) -> Dictionary:
	var rect := Rect2i(x0, 0, 8, 5)
	var sample := rect.grow(2)
	var h := PackedFloat32Array()
	h.resize(sample.get_area())
	var fixed := PackedByteArray()
	fixed.resize(h.size())
	var ocean := fixed.duplicate()
	for y in sample.size.y:
		for x in sample.size.x:
			var wx := sample.position.x + x
			var wy := sample.position.y + y
			var i := y * sample.size.x + x
			h[i] = 0.2 - wx * 0.01 if wy >= 0 and wy < 5 else 1.0
			if sea and wx >= 12 and wy >= 0 and wy < 5:
				h[i] = -0.02
				ocean[i] = 1
	return {rect = rect, sample_rect = sample, fields = {h = h, fixed = fixed, ocean = ocean},
		river_inputs = [{x = float(x0), y = 2.5, dx = 1, dy = 0, e = 0.25, w = 0.4, acc = 90.0}]}


func index(r: Dictionary, x: int, y: int) -> int:
	return (y - r.sample_rect.position.y) * r.sample_rect.size.x + x - r.sample_rect.position.x


func descending(points: Array) -> bool:
	for i in range(1, points.size()):
		if points[i].e > points[i - 1].e: return false
	return true


func _init() -> void:
	Grid.allow_fast = false
	var r := fixture()
	var before := var_to_bytes(r)
	var a := Regions.prepare_rivers(r)
	check(a.rivers.size() == 1 and a.outlets.size() == 1 and a.unresolved.is_empty(), "спуск продолжается до следующего соседа")
	if a.rivers.is_empty() or a.outlets.is_empty():
		quit(1)
		return
	check(descending(a.rivers[0].points) and a.rivers[0].points[0].e == 0.25, "профиль не поднимается и сохраняет входной уровень")
	check(a.outlets[0].x == 8.0 and a.outlets[0].dx == 1 and a.outlets[0].w == 0.4 and a.outlets[0].acc == 90.0,
		"выход сохраняет координаты, направление, ширину и сток")
	var neighbor := fixture(8, true)
	neighbor.river_inputs = a.outlets.duplicate(true)
	var b := Regions.prepare_rivers(neighbor)
	check(b.rivers.size() == 1 and b.outlets.is_empty() and b.rivers[0].termination == "ocean", "сосед доводит реку до моря")
	check(a.rivers[0].points.back() == b.rivers[0].points[0] and descending(b.rivers[0].points), "стык двух областей совпадает точно")
	check(var_to_bytes(r) == before and var_to_bytes(a) == var_to_bytes(Regions.prepare_rivers(r)), "исходные данные неизменны, повтор детерминирован")
	var blocked := fixture()
	for y in range(-2, 7): blocked.fields.h[index(blocked, 4, y)] = 0.8
	var c := Regions.prepare_rivers(blocked)
	check(c.rivers.is_empty() and c.outlets.is_empty() and c.unresolved[0].reason == "basin_requires_resolution",
		"гора не прорезается, незавершённое русло не публикуется")
	blocked = fixture()
	blocked.fields.h[index(blocked, 0, 2)] = 0.8
	check(Regions.prepare_rivers(blocked).unresolved[0].reason == "blocked_entry", "не создаётся подъём воды сразу после входа")
	blocked = fixture()
	for y in range(0, 5): blocked.fields.fixed[index(blocked, 4, y)] = 1
	check(Regions.prepare_rivers(blocked).rivers.is_empty(), "новая река не проходит по зафиксированной территории")
	var empty := fixture()
	empty.river_inputs.clear()
	var e := Regions.prepare_rivers(empty)
	check(e.rivers.is_empty() and e.outlets.is_empty() and e.unresolved.is_empty(), "без входов не придумываются новые реки")
	var multi := fixture()
	var second: Dictionary = multi.river_inputs[0].duplicate()
	second.y = 3.5
	multi.river_inputs.append(second)
	var m := Regions.prepare_rivers(multi)
	multi.river_inputs.reverse()
	check(var_to_bytes(m) == var_to_bytes(Regions.prepare_rivers(multi)), "порядок входов не меняет трассировку")
	var thread := Thread.new()
	thread.start(func() -> Dictionary: return Regions.prepare_rivers(r))
	check(var_to_bytes(thread.wait_to_finish()) == var_to_bytes(a), "фоновая трассировка совпадает с синхронной")
	# 13.2: поперечная впадина не имеет обхода по старому монотонному рельефу.
	var pond := fixture()
	for y in range(0, 5): pond.fields.h[index(pond, 3, y)] = 0.15
	var pond_before := var_to_bytes(pond)
	var filled := Regions.prepare_water(pond)
	check(filled.rivers.size() == 1 and filled.unresolved.is_empty() and descending(filled.rivers[0].points),
		"мелкая впадина получает горизонтальный сток без подъёма по течению")
	check(filled.surface.ready and filled.surface.h[index(pond, 3, 2)] > pond.fields.h[index(pond, 3, 2)],
		"дно мелкой впадины заполняется наносами")
	var wet := 0
	var valid := true
	for i in filled.surface.river.size():
		if filled.surface.river[i] != 0:
			wet += 1
			valid = valid and filled.surface.h[i] < filled.surface.water_level[i]
	check(wet > 0 and valid, "вода расположена над дном на всех мокрых клетках")
	check(var_to_bytes(pond) == pond_before, "подготовка дна и берегов не меняет исходную географию")
	for y in range(0, 5): pond.fields.h[index(pond, 3, y)] = 0.02
	var deep := Regions.prepare_water(pond)
	check(deep.rivers.is_empty() and not deep.surface.ready, "глубокая котловина не засыпается")
	var merged := fixture()
	for y in range(3, 5):
		for x in range(0, 8): merged.fields.h[index(merged, x, y)] = 0.8
	merged.fields.h[index(merged, 0, 3)] = 0.2
	var tributary: Dictionary = merged.river_inputs[0].duplicate()
	tributary.y = 3.5
	merged.river_inputs.append(tributary)
	var joined := Regions.prepare_rivers(merged)
	check(joined.rivers.size() == 2 and joined.outlets.size() == 1 and joined.unresolved.is_empty(),
		"приток сливается с основным руслом без второго выхода")
	if joined.rivers.size() == 2:
		check(joined.outlets[0].acc == 180.0 and joined.outlets[0].w > 0.4,
			"сток суммируется, русло ниже слияния расширяется")
		var join: Vector2i = joined.rivers[1].join
		check(joined.rivers[1].points.back() == joined.rivers[join.x].points[join.y],
			"общая точка слияния имеет одинаковые координаты, высоту и ширину")
	merged.river_inputs.reverse()
	check(var_to_bytes(joined) == var_to_bytes(Regions.prepare_rivers(merged)), "слияния независимы от порядка входов")
	# Чрезмерно широкая входящая река задевает высокую землю именно дном, не берегом.
	for input: Dictionary in merged.river_inputs: input.w = 5.0
	var limited := Regions.prepare_water(merged)
	check(not limited.surface.ready and limited.surface.reason == "earthwork_limit"
		and limited.surface.h == merged.fields.h, "слишком большие земляные работы откатываются целиком")
	var fixed := fixture()
	fixed.fields.fixed[index(fixed, 2, 1)] = 1
	var preserved := Regions.prepare_water(fixed)
	check(preserved.surface.h[index(fixed, 2, 1)] == fixed.fields.h[index(fixed, 2, 1)],
		"формирование берега сохраняет зафиксированные клетки")
	if OS.get_cmdline_user_args().has("--neighbors"):
		var checks := preload("res://tools/region_neighbors_checks.gd").new()
		fails += checks.run()
		if fails == 0 and OS.get_cmdline_user_args().has("--real"):
			fails += checks.real_terrain()
		if fails == 0 and OS.get_cmdline_user_args().has("--recorded"):
			fails += checks.recorded_terrain()
	print("region_rivers_test: %d failures" % fails)
	quit(1 if fails else 0)
