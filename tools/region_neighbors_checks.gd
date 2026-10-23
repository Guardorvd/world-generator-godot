extends RefCounted
const Regions := preload("res://scripts/world/region_preparation.gd")
const Batch := preload("res://scripts/world/region_water_batch.gd")
const Places := preload("res://scripts/world/region_settlements.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func plain(rect: Rect2i) -> Dictionary:
	var sample := rect.grow(2)
	var f := {}
	for name in ["h", "temp", "moist", "elev", "slope", "dist", "dw", "water_level"]:
		var a := PackedFloat32Array()
		a.resize(sample.get_area())
		f[name] = a
	f.h.fill(0.15)
	f.elev.fill(0.15)
	f.temp.fill(0.6)
	f.moist.fill(0.4)
	f.dist.fill(50.0)
	f.dw.fill(50.0)
	f.water_level.fill(-INF)
	for name in ["fixed", "ocean", "lake", "river", "biome"]:
		var a := PackedByteArray()
		a.resize(sample.get_area())
		f[name] = a
	f.biome.fill(Biomes.GRASS)
	return {rect = rect, sample_rect = sample, fields = f, river_inputs = []}


func run() -> int:
	var source := WorldData.new()
	source.seed_num = 734
	var a := plain(Rect2i(0, 0, 32, 32))
	var b := plain(Rect2i(32, 0, 32, 32))
	a.river_inputs = [{x = 0.0, y = 16.5, dx = 1, dy = 0, e = 0.15, w = 0.6, acc = 90.0}]
	# Точное float32-значение земли требуется для входа без подъёма.
	a.river_inputs[0].e = a.fields.h[0]
	# Боковые границы не должны стать более коротким выходом.
	for region: Dictionary in [a, b]:
		for y in range(region.sample_rect.position.y, region.sample_rect.end.y):
			for x in range(region.sample_rect.position.x, region.sample_rect.end.x):
				if y < 0 or y >= 32: region.fields.fixed[Batch.index(region, x, y)] = 1
	var an := Regions.prepare_rivers(a)
	# На ровной земле ближайший выход — боковой; зафиксировать боковые полосы внутри тоже.
	# Достаточно проверять фактическую передачу там, где она попала в b.
	for region: Dictionary in [a, b]:
		for y in [0, 31]:
			for x in range(region.sample_rect.position.x, region.sample_rect.end.x):
				region.fields.fixed[Batch.index(region, x, y)] = 1
	an = Regions.prepare_rivers(a)
	b.river_inputs = an.outlets.duplicate(true)
	var bn := Regions.prepare_rivers(b)
	var ready := Batch.finish([a, b], [an, bn])
	check(ready.ready and an.outlets.size() == 1 and bn.outlets.size() == 1, "две области согласуют воду и береговую полосу")
	if ready.ready:
		var reverse := Batch.finish([b, a], [bn, an])
		check(reverse.ready and var_to_bytes(ready.surfaces[0]) == var_to_bytes(reverse.surfaces[1]), "порядок соседей не меняет поверхность")
		var seam := true
		for y in range(-2, 34):
			for x in range(30, 34):
				for key in ["h", "river", "water_level"]:
					seam = seam and ready.surfaces[0][key][Batch.index(a, x, y)] == ready.surfaces[1][key][Batch.index(b, x, y)]
		check(seam, "все клетки общей полосы побайтно совпадают")
	check(not Batch.finish([a, b], [an, {rivers = [], outlets = [], unresolved = []}]).ready,
		"пустой сосед не скрывает пропавшее продолжение реки")
	b.fields.h[Batch.index(b, 32, 10)] += 0.001
	check(not Batch.finish([a, b], [an, bn]).ready, "разные исходные высоты запрещают публикацию стыка")
	var left := plain(Rect2i(0, 0, 256, 256))
	var right := plain(Rect2i(256, 0, 256, 256))
	var no_water := {rivers = [], outlets = [], unresolved = []}
	var p := Regions.finish_neighbors(source, [left, right], [no_water, no_water])
	check(p.ready and not p.settlements[0].is_empty() and not p.settlements[1].is_empty(), "пригодные соседи получают поселения с домами")
	var valid := true
	var seen := {}
	var all: Array = p.settlements[0] + p.settlements[1]
	for s: Dictionary in all:
		valid = valid and not seen.has(s.id) and not s.has("i") and not s.huts.is_empty()
		seen[s.id] = true
		for other: Dictionary in all:
			if s.id != other.id:
				valid = valid and Vector2(s.x, s.y).distance_to(Vector2(other.x, other.y)) >= (s.spacing + other.spacing) * 0.5
		for hut: Dictionary in s.huts:
			valid = valid and Rect2i(s.region * 256, Vector2i(256, 256)).has_point(Vector2i(floori(hut.x), floori(hut.y)))
	check(valid, "мировые адреса, расстояния между соседями и дома внутри области")
	var q := Regions.finish_neighbors(source, [right, left], [no_water, no_water])
	check(var_to_bytes(p.settlements[0]) == var_to_bytes(q.settlements[1]), "поселения не зависят от порядка подготовки")
	source.settlements = all.duplicate(true)
	var old := var_to_bytes(source.settlements)
	var excluded := Places.prepare(source, left, p.surfaces[0])
	check(excluded.settlements.is_empty() and old == var_to_bytes(source.settlements), "старые деревни сохраняются и исключают новые рядом")
	check(not Places.prepare(source, left, {ready = false}).ready, "поселения ждут готовую воду")
	source.settlements.clear()
	var ocean := plain(Rect2i(-256, 0, 256, 256))
	ocean.fields.ocean.fill(1)
	ocean.fields.h.fill(-0.2)
	var empty := Regions.finish_neighbors(source, [ocean], [no_water])
	check(empty.ready and empty.settlements[0].is_empty(), "море не получает обязательную деревню")
	var west := plain(Rect2i(-256, 0, 256, 256))
	var western := Regions.finish_neighbors(source, [west], [no_water])
	check(western.ready and not western.settlements[0].is_empty() and western.settlements[0][0].x < 0,
		"поселения и дома получают отрицательные мировые координаты")
	check(absf(Places.density_at(source.seed_num, -1, 30) - Places.density_at(source.seed_num, 0, 30)) < 0.01,
		"плотность поселений непрерывна при переходе через ноль")
	var entrance := plain(Rect2i(0, 0, 16, 16))
	entrance.river_inputs = [{x = 0.0, y = 8.5, dx = 1, dy = 0, e = 0.145, w = 0.3, acc = 90.0}]
	var entry_before := var_to_bytes(entrance)
	var carved := Regions.prepare_rivers(entrance)
	check(carved.unresolved.is_empty() and carved.rivers.size() == 1 and var_to_bytes(entrance) == entry_before,
		"небольшой подъём за входом допускает ограниченную выемку без изменения источника")
	return fails


## Один настоящий план географии; без домов/дорог стартового мира и повторной генерации.
func real_terrain() -> int:
	Grid.allow_fast = true
	var started := Time.get_ticks_msec()
	var w := WorldGenerator.geography("Север-1234")
	var hash_before := hash(w.h)
	var keys := {}
	for outlet: Dictionary in w.river_exits:
		var cell := Vector2i(floori(outlet.x + outlet.dx * 0.5), floori(outlet.y + outlet.dy * 0.5))
		var key := w.region_at(cell)
		keys[key] = int(keys.get(key, 0)) + 1
	var sorted: Array = keys.keys()
	sorted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return keys[a] < keys[b] or keys[a] == keys[b] and (a.y < b.y or a.y == b.y and a.x < b.x))
	check(not sorted.is_empty(), "настоящий план содержит выходы рек")
	var report := []
	for key: Vector2i in sorted.slice(0, 2):
		var r := Regions.prepare(w, key)
		var network := Regions.prepare_rivers(r)
		var result := Regions.finish_neighbors(w, [r], [network])
		report.append({region = str(key), inputs = r.river_inputs.size(), rivers = network.rivers.size(),
			unresolved = network.unresolved, ready = result.ready, reason = result.reason,
			settlements = result.settlements[0].size() if result.ready else 0})
		check(result.ready or result.surfaces.is_empty(), "настоящий рельеф: готовый результат либо полный отказ")
	check(hash_before == hash(w.h), "настоящая стартовая география не изменилась")
	var text := JSON.stringify({results = report, elapsed_ms = Time.get_ticks_msec() - started}, "\t")
	print(text)
	var file := FileAccess.open("res://tools/control/runs/region_13_3.json", FileAccess.WRITE)
	if file: file.store_string(text)
	return fails


## Повтор только внешнего шума по записанным выходам: без гидрологии/генерации плана.
func recorded_terrain() -> int:
	Grid.allow_fast = true
	var recorded: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/control/runs/region_13_3.json"))
	var w := WorldData.new()
	w.seed_num = WGRandom.hash_string("Север-1234")
	w.W = 1
	w.H = 1
	w.N = 1
	for name: String in WorldGenerator.NOISE_SLOTS:
		w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	StageRelief.run(w) # выбор тех же глобальных параметров; всего одна клетка
	w.W = 768
	w.H = 768
	w.N = 0 # без наложения готового плана, только неизменный внешний рельеф
	var report := []
	for item: Dictionary in recorded.results:
		var inputs: Array = item.unresolved.map(func(entry: Dictionary) -> Dictionary: return entry.input)
		if inputs.is_empty(): continue
		var entry: Dictionary = inputs[0]
		var cell := Vector2i(floori(entry.x + entry.dx * 0.5), floori(entry.y + entry.dy * 0.5))
		var rect := Regions.rect_for(w.region_at(cell))
		var sample := rect.grow(2)
		var f := OuterLand.compute(w, sample.position.x, sample.position.y, sample.size.x, sample.size.y)
		for name in ["fixed", "ocean", "lake"]:
			var values := PackedByteArray()
			values.resize(sample.get_area())
			f[name] = values
		f.water_level = PackedFloat32Array()
		f.water_level.resize(sample.get_area())
		f.water_level.fill(-INF) # как в prepare_rect: снаружи суша без готовой воды, море — 0
		for y in sample.size.y:
			for x in sample.size.x:
				var i := y * sample.size.x + x
				f.fixed[i] = int(Rect2i(0, 0, 768, 768).has_point(sample.position + Vector2i(x, y)))
				f.ocean[i] = int(f.h[i] < 0.0)
				if f.ocean[i] != 0: f.water_level[i] = 0.0
		var r := {rect = rect, sample_rect = sample, fields = f, river_inputs = inputs}
		var network := Regions.prepare_rivers(r)
		var result := Regions.finish_neighbors(w, [r], [network])
		report.append({region = item.region, rivers = network.rivers.size(), unresolved = network.unresolved,
			ready = result.ready, reason = result.reason, settlements = result.settlements[0].size() if result.ready else 0})
		check(result.ready or result.surfaces.is_empty(), "повтор записанного участка: нет частичной публикации")
	var text := JSON.stringify(report, "\t")
	print(text)
	var file := FileAccess.open("res://tools/control/runs/region_13_3_recorded.json", FileAccess.WRITE)
	if file: file.store_string(text)
	return fails

