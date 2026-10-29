extends RefCounted
const Regions := preload("res://scripts/world/region_preparation.gd")
const Batch := preload("res://scripts/world/region_water_batch.gd")
const Places := preload("res://scripts/world/region_settlements.gd")
var fails := 0
var completed := false


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


## Результат без времени и счётчиков работы: они законно разные у одинаковых результатов.
func result_bytes(result: Dictionary) -> PackedByteArray:
	var copy := result.duplicate()
	copy.erase("profile")
	copy.erase("settlement_profiles")
	return var_to_bytes(EntityCodec.encode(copy))


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
	completed = false
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
	for s: SettlementData in all:
		valid = valid and not seen.has(s.id) and not s.has("i") and not s.huts.is_empty()
		seen[s.id] = true
		for other: SettlementData in all:
			if s.id != other.id:
				valid = valid and Vector2(s.x, s.y).distance_to(Vector2(other.x, other.y)) >= (s.spacing + other.spacing) * 0.5
		for hut: HutData in s.huts:
			valid = valid and Rect2i(s.region * 256, Vector2i(256, 256)).has_point(Vector2i(floori(hut.x), floori(hut.y)))
	check(valid, "мировые адреса, расстояния между соседями и дома внутри области")
	var q := Regions.finish_neighbors(source, [right, left], [no_water, no_water])
	check(var_to_bytes(EntityCodec.encode(p.settlements[0])) == var_to_bytes(EntityCodec.encode(q.settlements[1])), "поселения не зависят от порядка подготовки")
	var alone := Regions.finish_neighbors(source, [left], [no_water])
	check(var_to_bytes(EntityCodec.encode(alone.settlements[0])) == var_to_bytes(EntityCodec.encode(p.settlements[0])),
		"P0: поселения области не зависят от состава группы (сосед не загружен)")
	# Окончательный угол каждой постройки проходит ту же проверку фундамента, что и место.
	var local := Places.local_world(source, left, p.surfaces[0])
	var ground := Heightfield.base_of(local)
	var origin: Vector2i = left.sample_rect.position
	var footing := true
	for s: SettlementData in p.settlements[0]:
		for hut: HutData in s.huts:
			footing = footing and StageLandmarks._fits(local, ground, local.river_cells(), Vector2(hut.x - origin.x, hut.y - origin.y), hut.a, hut.t)
	check(footing, "P0: окончательный поворот домов проходит проверку фундамента")
	var pinned_ledger := {settlements = EntityCodec.encode(all)}
	check(Places.prepare(source, left, p.surfaces[0], pinned_ledger).settlements.is_empty(),
		"P0: поселения журнала закреплены и исключают новые рядом")
	if not OS.get_cmdline_user_args().has("--water-only"):
		# Дороги ищутся как в игре, через C# (без сборки .NET — тот же поиск на GDScript); с 13.8 выходов больше.
		var gdscript_only := not Grid.allow_fast
		Grid.allow_fast = true
		var before_roads := var_to_bytes(EntityCodec.encode(p))
		var roads := Regions.prepare_roads(source, [left, right], p)
		check(roads.ready and roads.connections.size() == all.size() - 1 and not roads.trails.is_empty(),
			"13.5: поселения соседних областей соединены без лишних дорог")
		var reverse_roads := Regions.prepare_roads(source, [right, left], q)
		print("ROADS PROFILE ", JSON.stringify(roads.profile), " PLACES ", JSON.stringify(p.settlement_profiles))
		check(roads.profile.homes_kept > 0 and roads.profile.has("budget_stops") and roads.profile.has("expanded"),
			"P0: дороги отчитываются о раскрытиях, исходах поиска и числе домов")
		check(result_bytes(roads) == result_bytes(reverse_roads) and before_roads == var_to_bytes(EntityCodec.encode(p)),
			"13.5: дороги независимы от порядка соседей и не меняют входные данные")
		var houses_clear := true
		for settlement: SettlementData in roads.settlements:
			for hut: HutData in settlement.huts:
				var i: int = (floori(hut.y) - roads.sample_rect.position.y) * roads.sample_rect.size.x + floori(hut.x) - roads.sample_rect.position.x
				houses_clear = houses_clear and roads.path_mask[i] < 2
		check(houses_clear, "13.5: дома перестроены вдоль улиц, полотно свободно")
		var divided: Dictionary = p.duplicate(true)
		for n in 2:
			var region: Dictionary = [left, right][n]
			for y in range(region.sample_rect.position.y, region.sample_rect.end.y):
				for x in range(252, 260):
					if not region.sample_rect.has_point(Vector2i(x, y)): continue
					var i := Batch.index(region, x, y)
					divided.surfaces[n].river[i] = 1
					divided.surfaces[n].water_level[i] = 0.16
		var broken := Regions.prepare_roads(source, [left, right], divided)
		# 13.8: выходы на свободные стороны остаются, но связи через реку и мосты — нет.
		# 14.4: поселений в области больше — связи внутри одного берега остаются, через реку — нет.
		var side_of := {}
		for settlement: SettlementData in broken.settlements:
			side_of[settlement.id] = settlement.x < 256.0
		var across: Array = broken.connections.filter(func(e: Dictionary) -> bool:
			return side_of.has(e.from) and side_of.has(e.to) and side_of[e.from] != side_of[e.to])
		check(not broken.ready and broken.components >= 2 and across.is_empty() and broken.bridges.is_empty(),
			"13.6: вода выше берегов — отказ без оставшихся мостов и дорог")
		for n in 2:
			var region: Dictionary = [left, right][n]
			for i in divided.surfaces[n].river.size():
				if divided.surfaces[n].river[i] == 0: continue
				divided.surfaces[n].h[i] = 0.14
				divided.surfaces[n].water_level[i] = 0.1475
		var before_bridge := var_to_bytes(EntityCodec.encode(divided))
		var crossed := Regions.prepare_roads(source, [left, right], divided)
		check(crossed.ready and not crossed.bridges.is_empty() and crossed.connections.size() == all.size() - 1,
			"13.6: река на стыке областей пересечена мостом, поселения связаны")
		var mirrored: Dictionary = divided.duplicate(true)
		mirrored.surfaces.reverse()
		mirrored.settlements.reverse()
		var reversed_bridge := Regions.prepare_roads(source, [right, left], mirrored)
		check(result_bytes(crossed) == result_bytes(reversed_bridge) and var_to_bytes(EntityCodec.encode(divided)) == before_bridge,
			"13.6: мосты детерминированы и не меняют принятую воду")
		var shores: bool = not crossed.bridges.is_empty()
		for bridge: Dictionary in crossed.bridges:
			shores = shores and minf(bridge.a.x, bridge.b.x) < 252.0 and maxf(bridge.a.x, bridge.b.x) >= 260.0
		check(shores, "13.6: мировые концы мостов лежат на противоположных сухих берегах")

		check(not Regions.prepare_roads(source, [left], {ready = false}).ready, "13.5: дороги ждут согласованную воду")
		pinning(no_water)
		Grid.allow_fast = not gdscript_only
	source.settlements = all.duplicate(true)
	var old := var_to_bytes(EntityCodec.encode(source.settlements))
	var excluded := Places.prepare(source, left, p.surfaces[0])
	check(excluded.settlements.is_empty() and old == var_to_bytes(EntityCodec.encode(source.settlements)), "старые деревни сохраняются и исключают новые рядом")
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
	completed = true
	return fails


## 13.8: ровный стартовый план 256 с дорогой x = 220; восточный сосед подходит к ней,
## закрепляется, затем юго-восточный продолжает его выход, не трогая готовых клеток.
func pinning(no_water: Dictionary) -> void:
	var plan := WorldData.new()
	plan.seed_num = 734
	plan.W = 256
	plan.H = 256
	plan.N = plan.W * plan.H
	for name: String in ["h", "filled", "dist_ocean"]:
		var values := PackedFloat32Array()
		values.resize(plan.N)
		plan.set(name, values)
	for name: String in ["ocean", "lake", "river", "biome", "path_mask"]:
		var values := PackedByteArray()
		values.resize(plan.N)
		plan.set(name, values)
	plan.h.fill(0.15)
	plan.filled.fill(0.15)
	plan.dist_ocean.fill(50.0)
	plan.biome.fill(Biomes.GRASS)
	for y in plan.H: plan.path_mask[y * plan.W + 220] = 3
	var plan_before := var_to_bytes(EntityCodec.encode([plan.h, plan.path_mask, plan.settlements]))
	var east := Regions.pin(plain(Rect2i(256, 0, 256, 256)), plan, {})
	check(east.fields.fixed[Batch.index(east, 255, 10)] == 1 and east.fields.path[Batch.index(east, 255, 10)] == 0,
		"13.8: ореол на стороне плана закреплён его клетками")
	var p := Regions.finish_neighbors(plan, [east], [no_water])
	var roads := Regions.prepare_roads(plan, [east], p, {})
	var linked: bool = roads.ready and not roads.settlements.is_empty() and not roads.plan_paths.is_empty()
	for s: SettlementData in roads.settlements: linked = linked and s.net == "plan"
	var approach := false
	for trail: Dictionary in roads.trails: approach = approach or trail.approach
	check(linked and approach and var_to_bytes(EntityCodec.encode([plan.h, plan.path_mask, plan.settlements])) == plan_before,
		"13.8: поселения соседа связаны подходом со старой дорогой, план не изменён")
	var down: Array = roads.exits.filter(func(e: Dictionary) -> bool: return e.dy == 1)
	check(down.size() == 1 and down[0].y == 256.0 and down[0].net == "plan" and roads.exits.all(func(e: Dictionary) -> bool: return e.dx >= 0),
		"13.8: выходы дорог только на свободные стороны, на самой границе области")
	var done := Regions.commit({}, [east], [no_water], p, roads)
	var ledger: Dictionary = done.ledger
	check(done.ready and ledger.regions.has(Vector2i(1, 0)) and not Regions.commit(ledger, [east], [no_water], p, roads).ready,
		"13.8: принятая область закрепляется один раз")
	var ledger_before := var_to_bytes(EntityCodec.encode(ledger))
	var south := Regions.pin(plain(Rect2i(256, 256, 256, 256)), plan, ledger)
	var seam := true
	for x in range(256, 512):
		seam = seam and south.fields.fixed[Batch.index(south, x, 255)] == 1 \
			and south.fields.h[Batch.index(south, x, 255)] == ledger.regions[Vector2i(1, 0)].fields.h[255 * 256 + x - 256]
	check(seam, "13.8: следующий сосед видит закреплённые клетки как готовые")
	var p2 := Regions.finish_neighbors(plan, [south], [no_water])
	var next := Regions.prepare_roads(plan, [south], p2, ledger)
	var outside := true
	var continued := false
	for trail: Dictionary in next.trails:
		for point: Dictionary in trail.pts: outside = outside and point.y >= 256.0
		if not down.is_empty():
			continued = continued or trail.pts[0].x == down[0].x and trail.pts[0].y == down[0].y \
				or trail.pts[-1].x == down[0].x and trail.pts[-1].y == down[0].y
	var joined: bool = next.ready and not next.settlements.is_empty()
	for s: SettlementData in next.settlements: joined = joined and s.net == "plan"
	check(joined and continued and outside, "13.8: сосед продолжает выход закреплённой дороги, не заходя в готовые клетки")
	var later := Regions.commit(ledger, [south], [no_water], p2, next)
	check(later.ready and var_to_bytes(EntityCodec.encode(ledger)) == ledger_before and later.ledger.exits.all(func(e: Dictionary) -> bool:
		return not Rect2i(256, 256, 256, 256).has_point(Vector2i(floori(e.x + e.dx * 0.5), floori(e.y + e.dy * 0.5)))),
		"13.8: продолженный выход снят, прежний журнал не изменён")


## Один настоящий план географии; без домов/дорог стартового мира и повторной генерации.
func real_terrain() -> int:
	completed = false
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
	completed = true
	return fails


## Повтор только внешнего шума по записанным выходам: без гидрологии/генерации плана.
func recorded_terrain() -> int:
	completed = false
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
			ready = result.ready, reason = result.reason, failure = result.get("failure", {}), settlements = result.settlements[0].size() if result.ready else 0})
		check(result.ready or result.surfaces.is_empty(), "повтор записанного участка: нет частичной публикации")
	var text := JSON.stringify(report, "\t")
	print(text)
	var file := FileAccess.open("res://tools/control/runs/region_13_3_recorded.json", FileAccess.WRITE)
	if file: file.store_string(text)
	completed = true
	return fails

