extends SceneTree
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const Scout := preload("res://scripts/lab/trail_lab_scout.gd")
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1
func map_data(n: int, gradient: float) -> void:
	Terrain.world_size = n
	Terrain.world_seed = 13
	Terrain.world_h.resize(n * n)
	Terrain.world_wet.resize(n * n)
	Terrain.world_wet.fill(0)
	for z in n:
		for x in n: Terrain.world_h[z * n + x] = z * GameConfig.TILE * gradient
func run() -> void:
	map_data(384, 0.06)
	var before := hash(Terrain.world_h)
	var sites := Scout.find(13).duplicate(true)
	print("Search stats: ", Scout.stats)
	check(sites.size() > 8, "suitable map yields more than eight sites: %d" % sites.size())
	check(before == hash(Terrain.world_h), "probes do not mutate terrain")
	var shapes := {}
	var valid := true
	var unique := true
	var multiple_pairs := false
	for i in sites.size():
		var site: Dictionary = sites[i]
		multiple_pairs = multiple_pairs or site.probe.pairs_tested > 1
		shapes[site.region.size] = true
		valid = valid and site.probe.length >= 140 and not site.styles.is_empty() and site.bounds.size == Vector2(site.region.size) * GameConfig.TILE
		for j in range(i + 1, sites.size()):
			if Scout.overlap(site.corridor, sites[j].corridor) >= Scout.OVERLAP: unique = false
	check(valid, "every site has a route probe, dimensions and supported styles")
	check(multiple_pairs, "search considers multiple endpoint pairs within its work budget")
	check(shapes.size() > 1, "accepted regions have different sizes/proportions: %s" % [shapes.keys()])
	check(unique, "accepted corridors are distinct while nearby independent lines remain")
	check(var_to_bytes(sites) == var_to_bytes(Scout.find(13)), "search is deterministic")
	var a := Scout.corridor(PackedVector2Array([Vector2(0, 0), Vector2(400, 0)]))
	var b := Scout.corridor(PackedVector2Array([Vector2(100, 0), Vector2(300, 0)]))
	var c := Scout.corridor(PackedVector2Array([Vector2(200, -200), Vector2(200, 200)]))
	check(Scout.overlap(a, b) >= Scout.OVERLAP and Scout.overlap(a, c) < Scout.OVERLAP, "shared corridor is duplicate; a crossing alone is not")
	map_data(128, 0.08)
	for z in 128: Terrain.world_wet[z * 128 + 64] = 1
	var split := Scout.probe(Rect2i(0, 0, 128, 128))
	var safe_component := true
	if not split.is_empty():
		var left: bool = split.points[0].x < 64 * GameConfig.TILE
		for p: Vector2 in split.points:
			if (p.x < 64 * GameConfig.TILE) != left: safe_component = false
	check(safe_component, "a bounded probe never crosses the wet barrier between dry components")
	map_data(128, 0.0)
	var region := Scout.measure(Rect2i(0, 0, 128, 128))
	var trial := Scout.probe(region.region)
	check(not trial.is_empty() and Scout.capabilities(region, trial)[0] == "park", "flat terrain recommends park first while allowing constructed alternatives")
	Terrain.world_wet.fill(1)
	check(Scout.find(13).is_empty() and Scout.stats.has("reason"), "unsuitable map returns zero sites with reason")
	print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
