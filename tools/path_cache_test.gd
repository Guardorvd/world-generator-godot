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
	quit(1 if fails else 0)
