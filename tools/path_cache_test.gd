extends SceneTree
## Скалярные версии: повтор, мутации стоимости/рельефа/шагов, prefetch и старые вызовы без версии.
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var costs := PackedFloat32Array()
	costs.resize(64)
	costs.fill(1.0)
	var heights := PackedFloat32Array()
	heights.resize(64)
	var finder := Pathfinder.new(8, 8, heights)
	finder.use_corridor = false
	var revision := finder.next_cost_version()
	var first := finder.find_path(costs, 25, 30, 1.0, 0.5, revision)
	check(not first.is_empty(), "первый путь существует")
	var hits: int = finder.fast().SearchStats().cache_hits
	check(finder.find_path(costs.duplicate(), 25, 30, 1.0, 0.5, revision) == first
		and finder.fast().SearchStats().cache_hits == hits + 1, "копия того же снимка использует кэш по версии")
	finder.search_budget = 1
	check(finder.find_path(costs, 25, 30, 1.0, 0.5, revision).is_empty() and finder.search_budget == 0,
		"кэш сохраняет семантику ограниченного бюджета")
	finder.search_budget = -1
	for y in 8:
		costs[y * 8 + 4] = INF
	revision = finder.next_cost_version()
	check(finder.find_path(costs, 25, 30, 1.0, 0.5, revision).is_empty(), "новая версия стоимости исключает старый путь")
	costs.fill(1.0)
	revision = finder.next_cost_version()
	check(finder.find_path(costs, 25, 30, 1.0, 0.5, revision) == first, "восстановленная стоимость получает новую версию")
	finder.terrain_changed()
	for y in 8:
		finder.heights[y * 8 + 4] = 10.0
	check(finder.find_path(costs, 25, 30, 1.0, 0.5, revision).is_empty(), "поэлементная правка высот исключает старый путь")
	finder.heights = heights.duplicate()
	finder.heights.fill(0.0)
	check(finder.find_path(costs, 25, 30, 1.0, 0.5, revision) == first, "замена высот обновляет версию автоматически")
	finder.prefetch(costs, 8, 55, 1.0, 0.5, revision)
	var prefetched := finder.find_path(costs, 8, 55, 1.0, 0.5, revision)
	check(not prefetched.is_empty() and finder.fast().SearchStats().prefetch_hits == 1, "prefetch совпадает по скалярным версиям")
	finder.prefetch(costs, 25, 30, 1.0, 0.5, revision)
	for y in 8:
		costs[y * 8 + 4] = INF
	revision = finder.next_cost_version()
	check(finder.find_path(costs, 25, 30, 1.0, 0.5, revision).is_empty(), "смена версии не принимает устаревший prefetch")
	finder.cancel_prefetch()
	costs.fill(1.0)
	check(not finder.find_path(costs, 25, 30).is_empty(), "вызов без версии работает")
	for y in 8:
		costs[y * 8 + 4] = INF
	check(finder.find_path(costs, 25, 30).is_empty(), "вызов без версии безопасен при мутации без уведомления")
	finder.release()
	var diagonal := PackedFloat32Array([1.0, INF, INF, INF, 1.0, INF, INF, INF, 1.0])
	var steps := Pathfinder.new(3, 3)
	revision = steps.next_cost_version()
	check(steps.find_path(diagonal, 0, 8, 0.0, INF, revision).is_empty(), "без разрешённых шагов угол непроходим")
	steps.links = PackedByteArray([16, 0, 0, 0, 16, 0, 0, 0, 0])
	check(not steps.find_path(diagonal, 0, 8, 0.0, INF, revision).is_empty(), "замена links исключает старый кэш")
	steps.terrain_changed()
	steps.links[4] = 0
	check(steps.find_path(diagonal, 0, 8, 0.0, INF, revision).is_empty(), "поэлементная правка links исключает старый кэш")
	steps.release()
	_turn_checks()
	quit(1 if fails else 0)


## 15.11.2026: штраф поворота (аргумент turn): другой turn — другой запрос кэша; два поиска дают те же пути и тот же
## остаток запаса на холмистой сетке с коридором (turn 0 и turn > 0). Сверку с прежним GDScript заменил эталон path_golden.
func _turn_checks() -> void:
	const N := 48
	var heights := PackedFloat32Array()
	var costs := PackedFloat32Array()
	var water := PackedFloat32Array()
	var wet := PackedByteArray()
	heights.resize(N * N)
	costs.resize(N * N)
	water.resize(N * N)
	wet.resize(N * N)
	water.fill(-1000.0)
	for y in N:
		for x in N:
			var i := y * N + x
			heights[i] = 3.0 * sin(x * 0.21) * cos(y * 0.17) + 0.08 * x
			costs[i] = 1.0 + 0.5 * absf(sin(x * 1.3 + y * 0.7)) + (INF if (x == 20 and y > 6 and y < 40) else 0.0)
	var fast := Pathfinder.new(N, N, heights)
	if fast.fast() == null:
		check(false, "нужна сборка .NET (dotnet build)")
		return
	fast.set_corridor(heights, water, wet, 0.6)
	var revision := fast.next_cost_version()
	var plain := fast.find_path(costs, 5 * N + 3, 42 * N + 44, 8.0, 0.6, revision)
	var hits: int = fast.fast().SearchStats().cache_hits
	var turned := fast.find_path(costs, 5 * N + 3, 42 * N + 44, 8.0, 0.6, revision, 8.0)
	check(fast.fast().SearchStats().cache_hits == hits and not turned.is_empty(), "другой штраф поворота — другой запрос кэша")
	check(fast.find_path(costs, 5 * N + 3, 42 * N + 44, 8.0, 0.6, revision, 8.0) == turned
		and fast.fast().SearchStats().cache_hits == hits + 1, "тот же штраф поворота берётся из кэша")
	# 16.11.2026: копии на GDScript нет — пути со штрафами сверяет эталон tools/path_golden.gd; здесь повтор без кэша
	var same := true
	var changed := false
	var other := Pathfinder.new(N, N, heights)
	other.set_corridor(heights, water, wet, 0.6)
	for pair: Vector2i in [Vector2i(5 * N + 3, 42 * N + 44), Vector2i(40 * N + 2, 3 * N + 45), Vector2i(24 * N + 10, 24 * N + 40)]:
		for shape: Vector2 in [Vector2(0, 0), Vector2(2, 0), Vector2(8, 0), Vector2(8, 6), Vector2(0, 12)]:
			var turn := shape.x
			var bend := shape.y
			for budget: int in [-1, 300]:
				fast.search_budget = budget
				other.search_budget = budget
				var a := fast.find_path(costs, pair.x, pair.y, 8.0, 0.6, -1, turn, bend)
				var b := other.find_path(costs, pair.x, pair.y, 8.0, 0.6, -1, turn, bend)
				if a != b or fast.search_budget != other.search_budget:
					same = false
					print("  расхождение: %s turn %.1f bend %.1f запас %d: %d / %d клеток" % [pair, turn, bend, budget, a.size(), b.size()])
				if turn > 0.0 and budget < 0 and a != fast.find_path(costs, pair.x, pair.y, 8.0, 0.6, -1, 0.0): changed = true
	other.release()
	fast.search_budget = -1
	check(same, "два поиска со штрафом поворота и длинных галсов: те же пути и запас")
	check(changed, "штраф поворота меняет путь хотя бы в одной паре")
	check(plain != turned or changed, "штраф поворота действует")
	fast.release()
