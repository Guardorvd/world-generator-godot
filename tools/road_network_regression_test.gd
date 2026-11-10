extends SceneTree
const Roads := preload("res://scripts/world/region_roads.gd")
var fails := 0

class ProbeFinder extends Pathfinder:
	var last_grade := -1.0
	var result := PackedInt32Array()
	func can_reach(_cost: PackedFloat32Array, _s: int, _t: int, _climb := 0.0, _max_grade := INF) -> bool:
		return true
	func find_path(_cost: PackedFloat32Array, _s: int, _t: int, _climb := 0.0, max_grade := INF, _cost_version := -1) -> PackedInt32Array:
		last_grade = max_grade
		return result

class ExhaustingFinder extends Pathfinder:
	var first := true
	func can_reach(_cost: PackedFloat32Array, _s: int, _t: int, _climb := 0.0, _max_grade := INF) -> bool:
		return true
	func find_path(_cost: PackedFloat32Array, s: int, t: int, _climb := 0.0, _max_grade := INF, _cost_version := -1) -> PackedInt32Array:
		if search_budget == 0: return PackedInt32Array()
		if first:
			first = false
			search_budget = 0
			return PackedInt32Array()
		return Grid.line_cells(s % W, s / W, t % W, t / W, W)

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func world(width := 128, height := 96) -> WorldData:
	var w := WorldData.new()
	w.W = width
	w.H = height
	w.N = width * height
	w.seed_num = 42
	w.rng = WGRandom.new(42)
	w.scale = 0.1
	for key: String in ["h", "filled", "slope", "acc", "dist_water", "dist_ocean", "cost"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		w.set(key, values)
	w.h.fill(0.1)
	w.cost.fill(1.0)
	w.dist_water.fill(100.0)
	w.dist_ocean.fill(100.0)
	for key: String in ["ocean", "lake", "river", "biome", "path_mask"]:
		var values := PackedByteArray()
		values.resize(w.N)
		w.set(key, values)
	w.biome.fill(Biomes.GRASS)
	return w

func setup(w: WorldData) -> Dictionary:
	var surface := Heightfield.new(w, false)
	var heights := surface.hv.duplicate()
	for i in w.N: heights[i] /= GameConfig.TILE
	var finder := Pathfinder.new(w.W, w.H, heights)
	var axis := PackedByteArray()
	axis.resize(w.N)
	return {surface = surface, finder = finder, state = {surface = surface, on_axis = axis, detour = false}}

func reuse_check() -> void:
	var w := world(64, 32)
	for y in w.H:
		for x in range(20, 41):
			w.ocean[y * w.W + x] = 1
			w.h[y * w.W + x] = -0.05
	# Dry but steep banks require an approach well before the shoreline.
	for y in w.H:
		w.h[y * w.W + 19] = 0.08
		w.h[y * w.W + 41] = 0.08
	var a := 16 * w.W + 10
	var b := 16 * w.W + 50
	w.bridges.append(BridgeData.new(a, b))
	var c := setup(w)
	var finder: Pathfinder = c.finder
	finder.links.resize(w.N)
	for x in range(10, 51):
		var i := 16 * w.W + x
		c.state.on_axis[i] = 1
		finder.heights[i] = 6.5
		if x < 50: finder.links[i] |= 1
		if x > 10: finder.links[i] |= 2
	var path := Grid.line_cells(15, 16, 55, 16, w.W)
	var q := StageTrails._structures(w, path, true, finder, w.cost, c.state)
	check(q == path and w.bridges.size() == 1 and c.state.get("no_bridge", {}).is_empty(),
		"RN-01: joining midway along a dry approach reuses the deck without bridge-site rejection")
	finder.release()

func window_check() -> void:
	var w := world(160, 160)
	# The mask reaches beyond the first window. No physical water span can be built
	# here (conservative river-bank mask); the safe dry route is outside that window.
	for y in range(15, 145):
		for x in range(76, 84):
			w.river[y * w.W + x] = 1
			w.cost[y * w.W + x] = 30.0
	var c := setup(w)
	var q := StageTrails._connect_settlement(w, c.finder, w.cost, 80 * w.W + 60, 80 * w.W + 100, c.state)
	check(not q.is_empty() and c.state.get("windows", {}).has("full") and not c.state.get("site_failures", []).is_empty(),
		"RN-02: structural refusal in narrow windows still allows a full-map dry detour")
	c.finder.release()

func isolated_check() -> void:
	var w := world()
	for y in w.H:
		for x in w.W: w.h[y * w.W + x] = 0.1 + x * 0.45 / StageTrails.HEIGHT_SCALE
	w.slope.fill(0.45)
	for x: int in [50, 70]:
		w.settlements.append(SettlementData.from_dict({x = x + 0.5, y = 48.5, i = 48 * w.W + x, huts = []}))
	var c := setup(w)
	StageTrails._route_surface(c.finder, c.surface, StageTrails.WIDTHS.road)
	StageTrails._settlement_trails(w, c.finder, c.surface)
	check(w.settlements.size() == 2 and w.settlements[0].connections.has(w.settlements[1].i),
		"RN-03: a 45 percent axis slope (32 percent diagonal) connects isolated settlements by a secondary trail")
	check(w.generation_profile.road_failures.get("unreachable", 0) >= 1,
		"RN-03: the same slope really rejected the primary road")
	c.finder.release()

func budget_orientation_check() -> void:
	var w := world()
	for x: int in [30, 15, 20]:
		w.settlements.append(SettlementData.from_dict({x = x + 0.5, y = 48.5, i = 48 * w.W + x, huts = []}))
	var c := setup(w)
	var finder := ExhaustingFinder.new(w.W, w.H, c.finder.heights)
	c.finder.release()
	StageTrails._settlement_trails(w, finder, c.surface)
	check(w.generation_profile.road_links.any(func(e: Array) -> bool: return e[0] == 2 and e[1] == 0 and e[4] == "ok"),
		"RN-03: an exhausted destination budget reverses the pair and uses the remaining endpoint budget")
	finder.release()

func graph_check() -> void:
	var edges := Roads._contract_edges([{from = "A", to = "U"}, {from = "U", to = "V"},
		{from = "V", to = "B"}, {from = "V", to = "C"}], ["U", "V"])
	check(edges.has({from = "A", to = "B"}) and edges.has({from = "A", to = "C"})
		and not str(edges).contains('"U"') and not str(edges).contains('"V"'),
		"RN-04: chains of unpublished transit settlements preserve published connectivity")
	var old := SettlementData.from_dict({id = "a", x = 260.0, y = 10.0, net = "a", connections = []})
	var new_place := SettlementData.from_dict({id = "z", x = 520.0, y = 10.0, net = "a", connections = ["a"]})
	var ledger := {settlements = [old, new_place]}
	check(Roads._network_place(ledger, "a") == "a", "RN-04: incoming exits resolve to a real member of the old network")
	var w := world()
	w.outer = OuterLand.new()
	w.outer.set_ledger(ledger)
	check(w.routes("z").size() == 1 and w.routes("a").size() == 1 and not w.far_destination("a").is_empty(),
		"RN-04: one-sided cross-region links work in either ID order and in far_destination")
	old.connections = ["z"]
	w.outer.set_ledger({settlements = [old, new_place]})
	check(w.region_places().routes.size() == 1, "RN-04: reciprocal records do not duplicate routes")
	var targets := PackedInt32Array([10, 11, 12, 30, 50, 70])
	check(Roads._plan_targets(w, targets, 0).size() == 4, "RN-04: PLAN has multiple spatially separate landing candidates")

func join_check() -> void:
	var w := world(8, 8)
	var a := PackedInt32Array([6, 7, 15, 23, 31])
	var b := PackedInt32Array([31, 30, 22, 14, 13, 12, 11, 10, 9, 8])
	var joined := RideRoutes._join(w, a, b)
	var original_edges := {}
	for path: PackedInt32Array in [a, b]:
		for k in range(1, path.size()): original_edges[Vector2i(path[k - 1], path[k])] = true
	var valid := true
	for k in range(1, joined.size()): valid = valid and original_edges.has(Vector2i(joined[k - 1], joined[k]))
	check(valid, "RN-08: nearby cells and row boundaries cannot introduce an unvalidated splice edge")
	check(RideRoutes._join(w, PackedInt32Array([0, 1, 2, 3, 4]), PackedInt32Array([4, 3, 2, 10, 18])) == PackedInt32Array([0, 1, 2, 10, 18]),
		"RN-08: true shared vertices still remove backtracking")

func acceptance_check() -> void:
	var w := world(32, 16)
	for y in w.H:
		for x in range(12, 17):
			w.ocean[y * w.W + x] = 1
			w.h[y * w.W + x] = -0.05
	var c := setup(w)
	var before := var_to_bytes([c.finder.heights, c.finder.links, c.state.on_axis, w.path_mask, c.surface.hv])
	var path := Grid.line_cells(4, 8, 26, 8, w.W)
	var accepted := StageTrails._structures(w, path, true, c.finder, w.cost, c.state)
	check(not accepted.is_empty() and w.bridges.size() == 1, "RN-05: the control crossing really builds a bridge")
	c.finder.release()
	w = world(32, 16)
	for y in w.H:
		for x in range(12, 17):
			w.ocean[y * w.W + x] = 1
			w.h[y * w.W + x] = -0.05
	c = setup(w)
	var rejected := StageTrails._structures(w, path, true, c.finder, w.cost, c.state, 0, StageTrails.ROAD_GRADE,
		func(_q: PackedInt32Array) -> bool: return false)
	check(rejected.is_empty() and w.bridges.is_empty() and before == var_to_bytes([
		c.finder.heights, c.finder.links, c.state.on_axis, w.path_mask, c.surface.hv]),
		"RN-05: final route rejection rolls back structures, terrain, links and masks")
	c.finder.release()

func limits_and_cuts_check() -> void:
	var w := world(64, 32)
	for y in w.H:
		for x in range(20, 28): w.h[y * w.W + x] = 0.25
	w.h[15 * w.W + 18] = 0.2
	var c := setup(w)
	var finder := ProbeFinder.new(w.W, w.H, c.finder.heights)
	c.finder.release()
	c.state.detour = true
	var before: PackedFloat32Array = c.surface.hv.duplicate()
	var q := StageTrails._structures(w, Grid.line_cells(10, 16, 40, 16, w.W), true, finder, w.cost, c.state)
	check(not q.is_empty() and not w.tunnels.is_empty() and finder.last_grade == StageTrails.ROAD_LIMIT,
		"RN-06: alternating road detours use the road limit, not the trail limit")
	var changed := 0
	var outside_portals := 0
	var consistent := true
	for i in w.N:
		if before[i] != c.surface.hv[i] and c.state.on_axis[i] == 0:
			changed += 1
			for tunnel: TunnelData in w.tunnels:
				var dx := tunnel.b % w.W - tunnel.a % w.W
				var dy := tunnel.b / w.W - tunnel.a / w.W
				var along: float = (i % w.W - tunnel.a % w.W) * dx + (i / w.W - tunnel.a / w.W) * dy
				if along <= 0.0 or along >= dx * dx + dy * dy: outside_portals += 1
			consistent = consistent and is_equal_approx(finder.heights[i], c.surface.hv[i] / GameConfig.TILE)
	check(changed > 0 and outside_portals > 0 and consistent, "RN-07: all off-axis portal cuts update search heights as well")
	finder.release()
	w = world(48, 48)
	finder = ProbeFinder.new(w.W, w.H)
	finder.result = Grid.line_cells(20, 20, 27, 27, w.W)
	finder.result.append_array(Grid.line_cells(27, 27, 24, 20, w.W).slice(1))
	check(finder.result.size() < 4 * StageTrails.DETOUR and StageTrails._length(w, finder.result) > 4 * StageTrails.DETOUR
		and StageTrails._detour(w, finder, w.cost, 20 * w.W + 20, 20 * w.W + 24).is_empty(),
		"RN-06: diagonal detours are limited by physical length, not vertex count")
	finder.release()
	w = world(64, 32)
	for y in w.H:
		for x in range(24, 30): w.river[y * w.W + x] = 1
	c = setup(w)
	finder = ProbeFinder.new(w.W, w.H, c.finder.heights)
	c.finder.release()
	StageTrails._structures(w, Grid.line_cells(10, 16, 45, 16, w.W), true, finder, w.cost, c.state, 0, StageTrails.ROAD_LIMIT)
	check(finder.last_grade == StageTrails.ROAD_LIMIT, "RN-02: bridge replanning keeps the active road grade limit")
	finder.release()

func water_check() -> void:
	var w := world(8, 8)
	w.river[27] = 1
	var surface := Heightfield.new(w, false)
	surface.hv[27] = 10.0
	surface.water_level[27] = 12.0
	Grid.allow_fast = false
	var reference := StageTrails._route_heights(w, surface)
	Grid.allow_fast = true
	var native := StageTrails._route_heights(w, surface)
	check(reference == native and reference[27] == 12.0 / GameConfig.TILE,
		"RN-09: native and reference heights use the river surface instead of its bed")
	surface.hv[27] = 13.0
	check(StageTrails._route_heights(w, surface)[27] == 13.0 / GameConfig.TILE,
		"RN-09: a conservative river mask does not lower dry banks to water level")

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	for fast: bool in [false, true]:
		Grid.allow_fast = fast
		print("BACKEND ", "C#" if fast else "GDScript")
		if fast: check(Grid.fast_grid() != null, "C# backend is actually available; no silent fallback")
		reuse_check()
		window_check()
		isolated_check()
		acceptance_check()
	budget_orientation_check()
	limits_and_cuts_check()
	water_check()
	graph_check()
	join_check()
	print("FAILURES ", fails)
	quit(1 if fails else 0)
