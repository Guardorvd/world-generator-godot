extends SceneTree
## Изолированный стенд: без генерации стартового мира, дискового кэша и игровой сцены.
const Regions := preload("res://scripts/world/region_preparation.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func fixture() -> WorldData:
	var w := WorldData.new()
	w.W = 8
	w.H = 8
	w.N = 64
	w.seed_num = WGRandom.hash_string("region-preparation")
	for name: String in WorldGenerator.NOISE_SLOTS:
		w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	for name in ["h", "filled", "temp", "moist", "elev", "slope", "dist_ocean", "dist_water"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		for i in w.N: values[i] = 0.1 + i * 0.001
		w.set(name, values)
	for name in ["biome", "ocean", "lake", "river"]:
		var values := PackedByteArray()
		values.resize(w.N)
		w.set(name, values)
	w.biome.fill(Biomes.GRASS)
	w.lake[7] = 1
	w.river[15] = 1
	w.river_exits = [
		{x = 8.0, y = 1.5, dx = 1, dy = 0, acc = 80.0, e = 0.12, w = 0.4},
		{x = 0.0, y = 2.5, dx = -1, dy = 0, acc = 90.0, e = 0.13, w = 0.5},
		{x = 3.5, y = 0.0, dx = 0, dy = -1, acc = 100.0, e = 0.14, w = 0.6},
		{x = 4.5, y = 8.0, dx = 0, dy = 1, acc = 110.0, e = 0.15, w = 0.7},
		{x = 8.0, y = 8.0, dx = 1, dy = 1, acc = 120.0, e = 0.16, w = 0.8}]
	return w


func same_overlap(a: Dictionary, b: Dictionary) -> bool:
	var overlap: Rect2i = a.sample_rect.intersection(b.sample_rect)
	for y in range(overlap.position.y, overlap.end.y):
		for x in range(overlap.position.x, overlap.end.x):
			var ai: int = (y - a.sample_rect.position.y) * a.sample_rect.size.x + x - a.sample_rect.position.x
			var bi: int = (y - b.sample_rect.position.y) * b.sample_rect.size.x + x - b.sample_rect.position.x
			for name: String in a.fields:
				if a.fields[name][ai] != b.fields[name][bi]: return false
	return overlap.has_area()


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	var w := fixture()
	var before := var_to_bytes([w.h, w.filled, w.biome, w.river_exits])
	var a := Regions.prepare_rect(w, Rect2i(8, 0, 8, 8))
	var b := Regions.prepare_rect(w, Rect2i(16, 0, 8, 8))
	check(same_overlap(a, b), "соседи имеют побайтно одинаковые поля в общей полосе")
	var larger := Regions.prepare_rect(w, Rect2i(5, -3, 22, 14))
	check(same_overlap(a, larger), "поля не зависят от размера и положения запроса")
	var repeat := Regions.prepare_rect(w, Rect2i(8, 0, 8, 8))
	check(var_to_bytes(a) == var_to_bytes(repeat), "повтор после другого соседа воспроизводит область")
	var valid := true
	for y in range(0, 8):
		for x in range(6, 8):
			var dst: int = (y - a.sample_rect.position.y) * a.sample_rect.size.x + x - a.sample_rect.position.x
			valid = valid and a.fields.fixed[dst] == 1
			for name in ["h", "biome", "temp", "moist", "elev", "slope", "ocean", "lake", "river"]:
				valid = valid and a.fields[name][dst] == w.get(name)[y * w.W + x]
	check(valid, "готовый край, озеро и река сохранены без пересчёта")
	check(a.fields.fixed[2 * a.sample_rect.size.x + 2] == 0, "внешняя география явно помечена как незавершённая")
	check(a.river_inputs.size() == 1 and a.river_inputs[0] == w.river_exits[0], "выход реки передаёт уровень, ширину и сток")
	var count := 0
	for y in range(-1, 2):
		for x in range(-1, 2):
			var inputs := Regions.river_inputs(w, Rect2i(x * 8, y * 8, 8, 8))
			count += inputs.size()
			if x == 0 and y == 0: check(inputs.is_empty(), "выходы не возвращаются в стартовую область")
	check(count == 5, "четыре направления и угол получают выходы ровно один раз")
	check(Regions.river_inputs(w, Rect2i(16, 0, 8, 8)).is_empty(), "без выхода реки нет выдуманного входа")
	var ordered := Regions.river_inputs(w, Rect2i(-8, -8, 32, 32))
	w.river_exits.reverse()
	check(ordered == Regions.river_inputs(w, Rect2i(-8, -8, 32, 32)), "входы не зависят от порядка списка выходов")
	w.river_exits.reverse()
	a.river_inputs[0].e = 999.0
	a.fields.h[0] = 999.0
	check(before == var_to_bytes([w.h, w.filled, w.biome, w.river_exits]), "редактирование заготовки не меняет стартовый мир")
	check(Regions.rect_for(Vector2i(-1, 3)) == Rect2i(-256, 768, 256, 256), "адреса областей существуют вне плана и в отрицательных координатах")
	# Реальный вызов из фонового потока: тот же результат, без узлов и GPU.
	var thread := Thread.new()
	thread.start(func() -> Dictionary: return Regions.prepare_rect(w, Rect2i(8, 0, 8, 8)))
	check(var_to_bytes(thread.wait_to_finish()) == var_to_bytes(repeat), "фоновая подготовка совпадает с синхронной")
	print("region_preparation_test: %d failures" % fails)
	quit(1 if fails else 0)
