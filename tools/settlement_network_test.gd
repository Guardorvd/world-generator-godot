extends SceneTree
## Без подбора сида: берега рядом, но высоты не позволяют безопасный мост.
const Check := preload("res://tools/selftest.gd")
var fails := 0

func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	fails += int(not ok)

func world() -> WorldData:
	var w := WorldData.new()
	w.W = 128
	w.H = 96
	w.N = w.W * w.H
	w.seed_num = 55
	w.rng = WGRandom.new(w.seed_num)
	w.scale = float(w.N) / (512 * 512)
	for key in ["h", "filled", "slope", "acc", "dist_water", "dist_ocean", "cost"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		w.set(key, values)
	w.cost.fill(1.0)
	w.dist_water.fill(3.0)
	w.dist_ocean.fill(100.0)
	for key in ["ocean", "lake", "river", "biome", "path_mask"]:
		var values := PackedByteArray()
		values.resize(w.N)
		w.set(key, values)
	w.biome.fill(Biomes.GRASS)
	for y in w.H:
		for x in w.W:
			var i := y * w.W + x
			w.h[i] = 0.1 if x < 56 else 0.3
			if x >= 56 and x < 74:
				w.ocean[i] = 1
				w.h[i] = -0.05
				w.cost[i] = INF
	for at: Vector2i in [Vector2i(20, 16), Vector2i(20, 45), Vector2i(20, 75), Vector2i(44, 45),
			Vector2i(92, 16), Vector2i(92, 45), Vector2i(92, 75), Vector2i(110, 45)]:
		w.settlements.append({x = at.x + 0.5, y = at.y + 0.5, i = at.y * w.W + at.x, name = str(at), huts = []})
	return w

func budget_check(fast: bool) -> void:
	Grid.allow_fast = fast
	var finder := Pathfinder.new(24, 16)
	var cost := PackedFloat32Array()
	cost.resize(24 * 16)
	cost.fill(1.0)
	finder.search_budget = 2
	check(finder.find_path(cost, 0, 24 * 16 - 1).is_empty() and finder.search_budget == 0,
		"%s: исчерпание общего бюджета завершает поиск без частичного пути" % ("C#" if fast else "GDScript"))
	check(finder.find_path(cost, 0, 1).is_empty(), "бюджет не возобновляется при следующем соседе")
	finder.search_budget = -1
	check(not finder.find_path(cost, 0, 24 * 16 - 1).is_empty(), "новый поиск после ограничения работает")

func _init() -> void:
	budget_check(true)
	budget_check(false)
	Grid.allow_fast = true
	Pathfinder.profile_searches = true
	var w := world()
	var surface := Heightfield.new(w, false)
	var heights := surface.hv.duplicate()
	for i in w.N: heights[i] /= GameConfig.TILE
	var finder := Pathfinder.new(w.W, w.H, heights)
	StageTrails._route_surface(finder, surface, StageTrails.WIDTHS.road)
	var wet := w.ocean.duplicate()
	check(Grid.bridge_region(w.W, w.H, wet, StageTrails.SPAN)[45 * w.W + 92] == 1,
		"прежний фильтр по ширине пролива допускает недоступный берег")
	var start := Time.get_ticks_msec()
	StageTrails._settlement_trails(w, finder, surface)
	print("NETWORK ", JSON.stringify({ms = Time.get_ticks_msec() - start, settlements = w.settlements.size(), connected = Check.settlements_connected(w), searches = finder.search_stats(), network = w.generation_profile}))
	check(w.settlements.size() == 4 and Check.settlements_connected(w), "остаются четыре связанных поселения, непригодный берег не заселяется")
	check(w.bridges.is_empty(), "небезопасный мост не создаётся даже ради полной численности")
	check(w.generation_profile.settlement_attempts <= 7 * StageTrails.SETTLEMENT_NEIGHBORS,
		"число соседей ограничено линейно числом кандидатов")
	check(w.generation_profile.settlement_expanded <= 7 * w.N * 2,
		"все повторные маршруты укладываются в общий детерминированный бюджет")
	var valid := true
	for s in w.settlements:
		for other in s.connections:
			valid = valid and w.settlements.any(func(t: Dictionary) -> bool: return t.i == other and t.connections.has(s.i))
	check(valid, "доски маршрутов ссылаются только на существующие взаимные связи")
	var counts := {}
	for seed_num in range(8):
		var sample := world()
		sample.seed_num = seed_num
		sample.rng = WGRandom.new(seed_num)
		StageLandmarks._place_settlements(sample)
		counts[sample.settlements.size()] = true
		check(sample.settlements.size() >= 2 and sample.settlements.size() <= 4, "численность малого мира в пределах 2–4, сид %d" % seed_num)
	check(counts.size() > 1, "число поселений действительно меняется между сидами")
	quit(1 if fails else 0)
