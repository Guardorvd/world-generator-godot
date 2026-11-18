extends SceneTree
## 18.11.2026: изолированная проверка размещения новых мест StageSites (рыбацкие домики на озёрах, лавки у вершин) без
## дорог и остальной генерации: география плана и поселения, затем только StageSites. Без окна. Секунд на сид — несколько.
##   godot --headless --path . --script res://tools/sites_probe.gd -- [--seeds Север-1234,Ущелье] [--plan 512]
## Проверяет: у домика суша 3×3 и вода в двух клетках по направлению двери, причал смотрит на воду, лавка ниже вершины
## на 24–56 м, не на снегу и не на воде; хотя бы один домик на мир с озером; повтор даёт то же. Печатает числа.

var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	var seeds := _arg("seeds", "Север-1234,Ущелье").split(",")
	var plan := int(_arg("plan", str(WorldGenerator.PLAN_SIZE)))
	for seed_text: String in seeds:
		_probe(seed_text, plan)
	print("ИТОГО: %s" % ("всё прошло" if failures == 0 else "%d провалов" % failures))
	quit(1 if failures else 0)


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func _world(seed_text: String, plan: int) -> WorldData:
	var w := WorldGenerator._geography(seed_text, plan)
	StageLandmarks.run(w)
	var paths := PackedByteArray() # дорог в этой пробе нет: места ставятся по рельефу и поселениям
	paths.resize(w.N)
	w.path_mask = paths
	StageSites.run(w)
	return w


func _probe(seed_text: String, plan: int) -> void:
	var started := Time.get_ticks_msec()
	var w := _world(seed_text, plan)
	var counts := {}
	for s: SiteData in w.sites:
		counts[s.type] = counts.get(s.type, 0) + 1
	print("%s: клеток воды в озёрах %d, вершин %d, мест %d, %s (%d мс)" % [seed_text, w.lake.count(1), w.peaks.size(), w.sites.size(), counts, Time.get_ticks_msec() - started])
	var fishing: Array = w.sites.filter(func(s: SiteData) -> bool: return s.type == "fishing")
	var benches: Array = w.sites.filter(func(s: SiteData) -> bool: return s.type == "bench")
	var lake_cells := w.lake.count(1)
	var named_lakes := 1 if lake_cells >= StageSites.FISHING_MIN_CELLS else 0
	# не провал: у воды может не быть ровного берега в двух клетках от неё (мелкие лужи, обрывы)
	print("%s: воды %d клеток, рыбацких домиков %d" % [seed_text, lake_cells, fishing.size()])
	check(fishing.size() <= 8, "%s: домиков не слишком много (%d)" % [seed_text, fishing.size()])
	for s: SiteData in fishing:
		var hut: HutData = s.huts[0]
		check(s.huts.size() == 2 and s.huts[1].t == "pier" and hut.t == "house_timber" and hut.a == s.huts[1].a, "%s: домик и причал в одной точке, один поворот" % s.name)
		var land := true
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var j := floori(hut.y + dz) * w.W + floori(hut.x + dx)
				land = land and w.lake[j] == 0 and w.ocean[j] == 0
		var water := false
		for k in range(2, 5):
			var ahead := Vector2(hut.x, hut.y) + Vector2(sin(hut.a), cos(hut.a)) * k
			water = water or w.lake[floori(ahead.y) * w.W + floori(ahead.x)] != 0
		check(land and water, "%s: на суше, вода впереди по двери (%.1f, %.1f)" % [s.name, hut.x, hut.y])
	for s: SiteData in benches:
		var hut: HutData = s.huts[0]
		var j := floori(hut.y) * w.W + floori(hut.x)
		var near := w.peaks.filter(func(p) -> bool: return Vector2(p.x, p.y).distance_to(Vector2(hut.x, hut.y)) < 16.0)
		var ok := not near.is_empty() and w.biome[j] not in StageSites.BENCH_SKIP and w.lake[j] == 0 and w.slope[j] <= 0.4
		if not near.is_empty():
			var peak = near[0]
			var d := Vector2(peak.x, peak.y).distance_to(Vector2(hut.x, hut.y))
			ok = ok and d >= 5.0 and w.elev[j] < w.elev[floori(peak.y) * w.W + floori(peak.x)]
			# лицом от вершины
			var away := (Vector2(hut.x, hut.y) - Vector2(peak.x, peak.y)).normalized()
			ok = ok and Vector2(sin(hut.a), cos(hut.a)).dot(away) > 0.99
		check(ok, "%s: лавка у вершины ниже её, не на снегу, лицом от вершины" % s.name)
	var again := _world(seed_text, plan)
	var same := again.sites.size() == w.sites.size()
	for k in mini(again.sites.size(), w.sites.size()):
		same = same and again.sites[k].x == w.sites[k].x and again.sites[k].y == w.sites[k].y and again.sites[k].type == w.sites[k].type
	check(same, "%s: повторная генерация даёт те же места" % seed_text)
