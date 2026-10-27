extends RefCounted
## Проверки пакетных полей, запускаемые внутри check.gd -- --verify-generation.


static func _cost(fast: Object, w: WorldData, noise: PackedFloat64Array) -> Dictionary:
	var table := PackedFloat64Array()
	for b: Dictionary in Biomes.LIST:
		table.append(float(b.get("cost", 2.0)))
	var started := Time.get_ticks_usec()
	var reference := StageTrails.cost_reference(w, noise)
	var gd_ms := (Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var actual: PackedFloat32Array = fast.PathCost(w.W, w.H, w.ocean, w.lake, w.river_cells(), w.slope, w.biome, noise, table, StageTrails.FORD_SLOPE)
	return {ok = var_to_bytes(reference) == var_to_bytes(actual), gd_ms = gd_ms, fast_ms = (Time.get_ticks_usec() - started) / 1000.0}


static func _climate(fast: Object, w: WorldData, noise: PackedFloat64Array) -> Dictionary:
	var started := Time.get_ticks_usec()
	var reference := StageClimate.fields_reference(w, noise)
	var gd_ms := (Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var actual: Dictionary = fast.ClimateFields(w.W, w.H, w.h, w.ocean, w.lake, w.rain,
		w.dist_ocean, w.dist_water, w.elev, w.slope, noise, StageClimate.LAT_CELLS, StageClimate.biome_ids())
	var fast_ms := (Time.get_ticks_usec() - started) / 1000.0
	var different: Array[String] = []
	for key: String in reference:
		if var_to_bytes(reference[key]) != var_to_bytes(actual[key]):
			different.append(key)
	return {ok = different.is_empty(), different = different, gd_ms = gd_ms, fast_ms = fast_ms}


static func synthetic() -> Dictionary:
	var fast := Grid.fast_grid()
	if fast == null:
		return {ok = false, reason = "FastGrid недоступен"}
	var failures: Array = []
	for shape: Vector2i in [Vector2i(1, 1), Vector2i(13, 19), Vector2i(17, 769)]:
		var w := WorldData.new()
		w.W = shape.x
		w.H = shape.y
		w.N = w.W * w.H
		w.h.resize(w.N)
		w.ocean.resize(w.N)
		w.lake.resize(w.N)
		w.river.resize(w.N)
		w.elev.resize(w.N)
		w.slope.resize(w.N)
		w.rain.resize(w.N)
		w.dist_ocean.resize(w.N)
		w.dist_water.resize(w.N)
		w.biome.resize(w.N)
		var noise := PackedFloat64Array()
		noise.resize(w.N)
		for i in w.N:
			w.h[i] = [-0.35, -0.07, -0.01, 0.1][i % 4]
			w.elev[i] = [0.03, 0.1, 0.12, 0.4, 0.42, 0.62, 0.7, 0.0][i % 8]
			w.slope[i] = [0.0, 0.3, 0.55, 1.3, 1.5][i % 5]
			w.rain[i] = float((i * 19) % 101) / 100.0
			w.dist_ocean[i] = [0.0, 2.5, 3.0, 40.0][i % 4]
			w.dist_water[i] = [0.0, 1.0, 2.5, 30.0][i % 4]
			w.ocean[i] = int(i % 17 == 0)
			w.lake[i] = int(i % 23 == 0)
			w.river[i] = int(i % 3 == 0)
			w.biome[i] = i % Biomes.LIST.size()
			noise[i] = float((i * 7) % 29) / 14.0 - 1.0
		var cost := _cost(fast, w, noise)
		var climate := _climate(fast, w, noise)
		if not cost.ok or not climate.ok:
			failures.append({shape = str(shape), cost = cost, climate = climate})
	# Внешние прямоугольники, включая отрицательные координаты: меняется только планирование строк.
	var perm := Simplex.new(WGRandom.new(123)).perm
	for params: Array in [[78.0, 2, 91.0, -47.0], [420.0, 4, -133.0, 271.0], [56.0, 2, 17.0, -83.0], [20.0, 2, -61.0, 39.0]]:
		var a: PackedFloat64Array = fast.FbmRect(perm, -17, -31, 53, 29, params[0], params[1], params[2], params[3], false)
		var b: PackedFloat64Array = fast.FbmRect(perm, -17, -31, 53, 29, params[0], params[1], params[2], params[3], true)
		if var_to_bytes(a) != var_to_bytes(b):
			failures.append("parallel noise differs")
	# Настоящие запросы A*: новый ранний отказ коридора против исходного ленивого GDScript.
	var corridor := _corridor()
	if not corridor:
		failures.append("corridor paths differ")
	if not _world_corridor():
		failures.append("world corridor conversion, buffer reuse or cancellation differs")
	var result := {ok = failures.is_empty(), failures = failures}
	print("FIELD SYNTHETIC ", JSON.stringify(result))
	return result


static func _corridor() -> bool:
	const W := 17
	const H := 13
	var heights := PackedFloat32Array()
	var water := PackedFloat32Array()
	var wet := PackedByteArray()
	var cost := PackedFloat32Array()
	heights.resize(W * H)
	water.resize(W * H)
	wet.resize(W * H)
	cost.resize(W * H)
	for i in W * H:
		heights[i] = float((i * 13) % 17) / 100.0
		water[i] = 0.2 if i % W in [7, 8] and i / W >= 3 and i / W <= 9 else -0.1
		wet[i] = int(i % 11 == 0)
		cost[i] = INF if i % 31 == 0 else 1.0
	var ok := true
	var found := 0
	var saved_fast := Grid.allow_fast
	for half in [0.21, 0.275, 0.45]:
		Grid.allow_fast = true
		var native := Pathfinder.new(W, H, heights)
		native.set_corridor(heights, water, wet, half)
		Grid.allow_fast = false
		var reference := Pathfinder.new(W, H, heights)
		reference.set_corridor(heights, water, wet, half)
		for pair: Vector2i in [Vector2i(1, 219), Vector2i(20, 200), Vector2i(110, 119), Vector2i(51, 160)]:
			for grade in [0.22, 0.4, 0.55]:
				native.search_budget = 500
				reference.search_budget = 500
				var a := native.find_path(cost, pair.x, pair.y, 12.0, grade)
				var b := reference.find_path(cost, pair.x, pair.y, 12.0, grade)
				if not a.is_empty():
					found += 1
				ok = (a == b and native.search_budget == reference.search_budget) and ok
		native.release()
		reference.release()
	Grid.allow_fast = saved_fast
	return ok and found > 0


static func real_world(w: WorldData) -> Dictionary:
	var fast := Grid.fast_grid()
	var n := Simplex.new(WorldGenerator.noise_rng(w.seed_num, "temp"))
	var temp_noise := Parallel.fbm_field(w.W, w.H, n, 200.0, 3)
	var climate := _climate(fast, w, temp_noise)
	n = Simplex.new(WorldGenerator.noise_rng(w.seed_num, "cost"))
	var cost_noise := Parallel.fbm_field(w.W, w.H, n, 14.0, 2)
	var cost := _cost(fast, w, cost_noise)
	var result := {ok = climate.ok and cost.ok, climate = climate, cost = cost}
	print("FIELD REAL PARITY ", JSON.stringify(result))
	return result


## Три преобразования одних буферов с разными данными: старые значения не должны выжить.
## Перед сменой входов намеренно запущен prefetch: SetWorldCorridor обязан дождаться читателя.
static func _world_corridor() -> bool:
	const W := 19
	const H := 15
	var ground := PackedFloat32Array()
	var water := PackedFloat32Array()
	var ocean := PackedByteArray()
	var lake := PackedByteArray()
	var river := PackedByteArray()
	var cost := PackedFloat32Array()
	ground.resize(W * H)
	water.resize(W * H)
	ocean.resize(W * H)
	lake.resize(W * H)
	river.resize(W * H)
	cost.resize(W * H)
	cost.fill(1.0)
	var saved_fast := Grid.allow_fast
	Grid.allow_fast = true
	var native := Pathfinder.new(W, H, ground)
	Grid.allow_fast = false
	var reference := Pathfinder.new(W, H, ground)
	Grid.allow_fast = saved_fast
	var ok := true
	var found := 0
	for phase in 3:
		for i in W * H:
			ground[i] = float((i * 13) % 17) / 100.0
			water[i] = 0.6 if phase == 1 and i % W in [7, 8] and i / W >= 3 and i / W <= 10 else -INF
			ocean[i] = int(phase == 1 and i % 29 == 0)
			lake[i] = int(phase == 1 and i % 31 == 0)
			river[i] = int(phase == 1 and i % 23 == 0)
		var before := var_to_bytes([ground, water, ocean, lake, river])
		var half: float = [0.45, 0.275, 0.21][phase]
		native.set_world_corridor(ground, water, ocean, lake, river, GameConfig.TILE, half)
		reference.set_world_corridor(ground, water, ocean, lake, river, GameConfig.TILE, half)
		ok = (before == var_to_bytes([ground, water, ocean, lake, river])) and ok
		for pair: Vector2i in [Vector2i(1, 281), Vector2i(20, 260), Vector2i(110, 119), Vector2i(51, 160)]:
			for grade in [0.22, 0.4, 0.55]:
				native.search_budget = 500
				reference.search_budget = 500
				var a := native.find_path(cost, pair.x, pair.y, 12.0, grade)
				var b := reference.find_path(cost, pair.x, pair.y, 12.0, grade)
				found += int(not a.is_empty())
				ok = (a == b and native.search_budget == reference.search_budget) and ok
		native.search_budget = 500
		native.prefetch(cost, 1, 281, 12.0, 0.22, native.next_cost_version())
	native.release()
	native.release() # повторное освобождение не возвращает буфер дважды
	reference.release()
	return ok and found > 0
