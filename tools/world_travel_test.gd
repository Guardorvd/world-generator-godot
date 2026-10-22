extends SceneTree
## 8.7: размещение и единая сеть не зависят от границ областей.
const Check := preload("res://tools/selftest.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	fails += int(not ok)


func world() -> WorldData:
	var w := WorldData.new()
	w.W = 768
	w.H = 128
	w.N = w.W * w.H
	w.scale = float(w.N) / (512 * 512)
	w.seed_num = 55
	w.rng = WGRandom.new(w.seed_num)
	for key in ["h", "filled", "elev", "slope", "acc", "dist_water", "dist_ocean", "cost", "rain", "temp", "moist"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		w.set(key, values)
	w.h.fill(0.1)
	w.cost.fill(1.0)
	w.dist_water.fill(3.0)
	w.dist_ocean.fill(100.0)
	for key in ["ocean", "lake", "river", "biome", "path_mask", "road_surface"]:
		var values := PackedByteArray()
		values.resize(w.N)
		w.set(key, values)
	w.biome.fill(Biomes.GRASS)
	w.down.resize(w.N)
	w.down.fill(-1)
	w.watershed.resize(w.N)
	return w


func placement() -> void:
	var w := world()
	# Правая половина — скалы и вода: нельзя заселить ровную клетку в обрыве.
	for y in w.H:
		for x in range(384, w.W):
			w.slope[y * w.W + x] = 0.7
	w.slope[64 * w.W + 500] = 0.0
	StageLandmarks._place_settlements(w)
	check(w.settlements.size() >= 2, "пригодная часть мира получает несколько поселений")
	var valid := true
	var radii := {}
	for s: Dictionary in w.settlements:
		valid = valid and s.x < 384 and s.importance >= 0.0 and s.importance <= 1.0
		radii[roundi(s.spacing)] = true
		for other: Dictionary in w.settlements:
			if s.i == other.i:
				continue
			var d := Vector2(s.x, s.y).distance_to(Vector2(other.x, other.y))
			valid = valid and d >= (s.spacing + other.spacing) * 0.5
	check(valid, "окрестности и взаимные расстояния учитываются для всего мира")
	check(radii.size() > 1, "плотность различается между местами, нет равномерной решётки")
	var before := var_to_bytes(w.settlements)
	for k in 100: w.rng.next_float()
	StageLandmarks._place_settlements(w)
	check(var_to_bytes(w.settlements) == before, "повторное размещение независимо от общего RNG")
	check(absf(StageLandmarks._settlement_density(w, 255, 64) - StageLandmarks._settlement_density(w, 256, 64)) < 0.02,
		"плотность плавно проходит через границу областей")
	var a := {x = 20.5, y = 30.5, i = 30 * w.W + 20, importance = 1.0}
	var b := {x = 80.5, y = 30.5, i = 30 * w.W + 80, importance = 1.0}
	var easy := StageTrails._direction_cost(w, a, b)
	b.importance = 0.2
	check(StageTrails._direction_cost(w, a, b) > easy, "основное направление между центрами приоритетнее местного")
	b.importance = 1.0
	for x in range(40, 61): w.ocean[30 * w.W + x] = 1
	check(StageTrails._direction_cost(w, a, b) > easy * 1.5, "пролив снижает приоритет геометрически близкой связи")


func network() -> void:
	var w := world()
	for x in [230, 280, 530]:
		w.settlements.append({x = x + 0.5, y = 64.5, i = 64 * w.W + x,
			name = str(x), importance = 0.4 if x == 530 else 1.0, huts = []})
	w.peaks = [{x = 650.5, y = 90.5, i = 90 * w.W + 650}]
	var surface := Heightfield.new(w, false)
	var heights := surface.hv.duplicate()
	for i in w.N: heights[i] /= GameConfig.TILE
	var finder := Pathfinder.new(w.W, w.H, heights)
	StageTrails._route_surface(finder, surface, StageTrails.WIDTHS.road)
	StageTrails._settlement_trails(w, finder, surface)
	StageTrails._route_surface(finder, surface, StageTrails.WIDTHS.mountain)
	StageTrails._mountain_trails(w, finder, surface)
	check(w.settlements.size() == 3 and Check.settlements_connected(w), "поселения трёх областей образуют единую сеть")
	check(w.trails.any(func(t: Dictionary) -> bool: return t.kind == "road")
		and w.trails.any(func(t: Dictionary) -> bool: return t.kind == "trail"), "магистраль и местный подъезд имеют разную важность")
	check(w.settlements[0].connections.size() + w.settlements[1].connections.size() + w.settlements[2].connections.size() == 4,
		"три возможные пары не превращаются в три обязательные дороги")
	check(w.path_mask[w.peaks[0].i] >= 2, "значимое место получает ответвление от общей сети")
	var crossings := {}
	var valid := true
	for x in 3:
		var region := w.read_region(Vector2i(x, 0), 0)
		check(not region.trails.is_empty() and not region.settlements.is_empty(), "область %d читает места и пути общего плана" % x)
		check(region.path_mask.size() == region.core.get_area(), "область %d читает готовую маску пути" % x)
		for link: Dictionary in region.travel_links:
			if crossings.has(link.id):
				valid = valid and crossings[link.id][0] == link
				crossings[link.id][1] += 1
			else:
				crossings[link.id] = [link, 1]
		region.settlements[0].name = "копия"
		region.trails[0].pts[0].x = -999.0
	for entry: Array in crossings.values(): valid = valid and entry[1] == 2
	check(valid and crossings.size() >= 2, "оба соседа получают одинаковые переходы сети на каждой границе")
	check(w.settlements[0].name == "230" and w.trails[0].pts[0].x >= 0.0, "чтение и изменение области не меняет сеть мира")
	var before := var_to_bytes([w.settlements, w.trails, w.bridges, w.tunnels])
	w.expand_territory(256)
	w.expand_territory(768)
	check(var_to_bytes([w.settlements, w.trails, w.bridges, w.tunnels]) == before, "расширение территории сохраняет места и маршруты")


func lone_shore() -> void:
	var w := world()
	w.settlements = [{x = 280.5, y = 64.5, i = 64 * w.W + 280}]
	for y in w.H:
		for x in range(310, w.W):
			w.ocean[y * w.W + x] = 1
			w.cost[y * w.W + x] = INF
	var finder := Pathfinder.new(w.W, w.H)
	var on_axis := PackedByteArray()
	on_axis.resize(w.N)
	StageTrails._second_ways(w, finder, [], w.cost.duplicate(), {detour = false, on_axis = on_axis})
	check(not w.trails.is_empty() and w.path_mask[w.settlements[0].i] >= 2,
		"единственная деревня может основать первую тропу к берегу")


func _init() -> void:
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	if OS.get_cmdline_user_args().has("--generated"):
		# Полный конвейер на небольшом тестовом плане, без четырёх дорогих миров 768².
		Grid.allow_fast = true
		var native := WorldGenerator._generate_plan("Север-1234", 192)
		var fingerprint := Check.fingerprint(native)
		Grid.allow_fast = false
		var fallback := WorldGenerator._generate_plan("Север-1234", 192)
		check(Check.settlements_connected(native) and Check.settlements_connected(fallback), "оба конвейера сохраняют связность поселений")
		check(fingerprint == Check.fingerprint(fallback), "весь тестовый мир, дома и геометрия путей совпадают в C# и GDScript")
	else:
		placement()
		network()
		lone_shore()
	print("world_travel_test: %s" % ("OK" if fails == 0 else str(fails)))
	quit(1 if fails else 0)
