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
		w.settlements.append(SettlementData.from_dict({x = at.x + 0.5, y = at.y + 0.5, i = at.y * w.W + at.x, name = str(at), huts = []}))
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
	finder.release()


func component_checks() -> void:
	var w := world()
	var original := w.settlements.duplicate()
	w.path_mask.fill(3) # A projected mask alone must not turn separate edges into a connection.
	var paths: Array = [[4, 6, PackedInt32Array(), true, 1.0], [0, 2, PackedInt32Array(), true, 1.0],
		[2, 6, PackedInt32Array(), false, 1.0]]
	var before := var_to_bytes([w.h, w.trails, w.bridges, w.tunnels, w.path_mask])
	StageTrails._retain_connected_settlements(w, paths)
	check(w.settlements == [original[0], original[2], original[4], original[6]], "вторичная тропа сохраняет обе группы, изолированные кандидаты исключаются")
	check(paths.map(func(e: Array) -> Vector2i: return Vector2i(e[0], e[1])) == [Vector2i(2, 3), Vector2i(0, 1), Vector2i(1, 3)], "индексы всех сохранённых основных и вторичных связей перенумерованы")
	check(before == var_to_bytes([w.h, w.trails, w.bridges, w.tunnels, w.path_mask]), "отбор поселений не удаляет маршруты, сооружения или географию")
	var groups: Array = [0, 0, 1, 2, 4, 4]
	check(StageTrails._group(groups, 3) == 0 and StageTrails._group(groups, 5) == 4, "DSU находит корни через цепочки родителей и различает компоненты")
	var isolated := world()
	var sites := isolated.settlements.duplicate()
	var disconnected: Array = [[2, 4, PackedInt32Array(), true, 1.0], [4, 6, PackedInt32Array(), false, 1.0]]
	StageTrails._retain_connected_settlements(isolated, disconnected)
	check(isolated.settlements == [sites[2],sites[4],sites[6]], "изолированный лучший кандидат не уничтожает готовую сеть остальных поселений")
	check(disconnected.map(func(e:Array)->Vector2i:return Vector2i(e[0],e[1]))==[Vector2i(0,1),Vector2i(1,2)],"связи выбранной компоненты перенумерованы")
	var snapshot := var_to_bytes([isolated.settlements.map(func(s:SettlementData)->int:return s.i),disconnected])
	StageTrails._retain_connected_settlements(isolated,disconnected)
	check(snapshot==var_to_bytes([isolated.settlements.map(func(s:SettlementData)->int:return s.i),disconnected]),"повторная публикация идемпотентна")
	var tied := world()
	var tied_sites := tied.settlements.duplicate()
	var tied_paths: Array = [[4,6,PackedInt32Array(),false,1.0],[0,2,PackedInt32Array(),true,1.0]]
	StageTrails._retain_connected_settlements(tied,tied_paths)
	check(tied.settlements==[tied_sites[0],tied_sites[2]],"равные компоненты: стабильный выбор по рангу кандидатов, не порядку рёбер")
	var empty := world()
	var first: SettlementData = empty.settlements[0]
	var no_paths: Array=[]
	StageTrails._retain_connected_settlements(empty,no_paths)
	check(empty.settlements==[first],"если подтверждённых дорог нет, остаётся один запасной кандидат")

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	budget_check(true)
	budget_check(false)
	component_checks()
	Grid.allow_fast = true
	Pathfinder.profile_searches = true
	var w := world()
	var unreachable: SettlementData = w.settlements[4]
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
	check(w.settlements.size() == 4 and Check.settlements_connected(w) and Check.settlement_network_valid(w),
		"итоговые поселения доступны от старта, непроходимый берег не объявляется доступным")
	check(w.bridges.is_empty(), "небезопасный мост не создаётся даже ради полной численности")
	check(w.generation_profile.settlement_attempts <= 7 * StageTrails.SETTLEMENT_NEIGHBORS,
		"число соседей ограничено линейно числом кандидатов")
	check(w.generation_profile.settlement_expanded <= 7 * w.N * 2,
		"все повторные маршруты укладываются в общий детерминированный бюджет")
	var valid := true
	for s in w.settlements:
		for other in s.connections:
			valid = valid and w.settlements.any(func(t: SettlementData) -> bool: return t.i == other and t.connections.has(s.i))
	check(valid, "доски маршрутов ссылаются только на существующие взаимные связи")
	# Put the same graph in distinct map regions, so far_destination is exercised
	# with nonempty answers rather than only one-region empty results.
	var destinations := WorldData.new()
	for s: SettlementData in w.settlements:
		var copy := SettlementData.from_dict(s.to_dict())
		copy.x *= 16
		copy.y *= 16
		destinations.settlements.append(copy)
	var far_count := 0
	for s: SettlementData in destinations.settlements:
		var far := destinations.far_destination(WorldData.place_id("settlement", s.x, s.y))
		far_count += int(not far.is_empty())
		check(far.is_empty() or (far.x < 56 * 16) == (s.x < 56 * 16), "дальний путь остаётся в достижимой сети")
	check(far_count == w.settlements.size(), "достижимая сеть действительно предлагает дальние цели")
	var first: SettlementData = w.settlements[0]
	var saved := first.connections.duplicate()
	first.connections.append(unreachable.i)
	check(not Check.settlement_network_valid(w), "проверка отвергает выдуманную связь через непроходимый пролив")
	unreachable.connections.append(first.i)
	w.settlements.append(unreachable)
	check(not Check.settlement_network_valid(w), "взаимная запись без физического пути тоже отвергается")
	w.settlements.pop_back()
	unreachable.connections.erase(first.i)
	first.connections = saved
	finder.release()
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
