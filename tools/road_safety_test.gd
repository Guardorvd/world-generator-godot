extends SceneTree
## Измеряет готовую поверхность, включая метровое полотно: ось и оба края через 1 м.
## -- --out res://tools/control/runs/roads.json --seeds 6 --size 512
const Connectivity := preload("res://tools/selftest.gd")
const SEEDS := ["Север-1234", "Туман-4821", "Ущелье", "Янтарь-5150", "Озёра-5", "Гряда-310", "a1", "b2", "c3", "d4", "e5", "f6"]
var fails := 0

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	Grid.allow_fast = not args.has("--gdscript")
	_route_grade_check()
	_dry_river_bank_check()
	if args.has("--route-only"):
		print("Предел уклона основной дороги проверен; нарушений: %d" % fails)
		quit(1 if fails > 0 else 0)
		return
	var count := 6
	var size := 512
	var output := ""
	var only_seed := ""
	for k in args.size() - 1:
		if args[k] == "--seeds": count = int(args[k + 1])
		if args[k] == "--size": size = int(args[k + 1])
		if args[k] == "--out": output = args[k + 1]
		if args[k] == "--seed": only_seed = args[k + 1]
	var results := {}
	for seed_text in ([only_seed] if not only_seed.is_empty() else SEEDS.slice(0, count)):
		var start := Time.get_ticks_msec()
		var trace := func(_p: float, label: String) -> void:
			if args.has("--trace"): print("  ", Time.get_ticks_msec() - start, " ", label)
		var w := WorldGenerator.generate(seed_text, size, trace)
		var heights := Heightfield.new(w)
		var row := {connected = Connectivity.settlements_connected(w), settlements = w.settlements.size(), routes = w.trails.size(), bridges = w.bridges.size(), tunnels = w.tunnels.size()}
		row.bridge_landing = _bridge_landing_measure(heights)
		if row.bridge_landing.wet > 0 or row.bridge_landing.max_gap > StageTrails.BRIDGE_LANDING_GAP + 0.01:
			printerr("Небезопасный стык моста: ", seed_text, " ", JSON.stringify(row.bridge_landing))
			fails += 1
		for kind in ["road", "trail", "mountain"]:
			row[kind] = measure(w, heights, kind)
			if row[kind].lake_wet > 0.0 or not is_finite(row[kind].max_grade):
				printerr("Небезопасный путь: ", seed_text, " ", kind)
				fails += 1
		if row.road.wet > 0.0 or row.road.edge_wet > 0.0:
			printerr("Основная дорога или её край в воде: ", seed_text)
			fails += 1
		if row.road.max_grade > 0.4 or row.road.tilted50 > 0.0:
			printerr("Основная дорога слишком крутая или наклонена вбок: ", seed_text)
			fails += 1
		if args.has("--raw"):
			var raw := Heightfield.new(w, false)
			raw.build_structures()
			row.raw_road = measure(w, raw, "road")
		row.ms = Time.get_ticks_msec() - start
		results["%s@%d" % [seed_text, size]] = row
		print(seed_text, "@", size, " ", JSON.stringify(row))
		if not row.connected: fails += 1
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		file.store_string(JSON.stringify(results, "\t"))
	quit(1 if fails > 0 else 0)


func _route_grade_check() -> void:
	# На карте из двух клеток нет обхода: дорога не должна принимать крутой
	# перепад только из-за запасного поиска без ограничения уклона.
	var finder := Pathfinder.new(2, 1, PackedFloat32Array([0.0, 0.8]))
	var cost := PackedFloat32Array([1.0, 1.0])
	var path := StageTrails._road_path(finder, cost, 0, 1)
	if not path.is_empty():
		fails += 1
		printerr("Основная дорога приняла участок с уклоном 80 % без обхода")


func _bridge_landing_measure(heights: Heightfield) -> Dictionary:
	var max_gap := 0.0
	var wet := 0
	for s: Dictionary in heights.structures:
		if s.tunnel:
			continue
		for end in 2:
			var t: float = 0.0 if end == 0 else s.len
			var deck: float = s.ay if end == 0 else s.by
			for side in [-1.0, 0.0, 1.0]:
				var x: float = s.ax + s.ux * t - s.uz * side * s.half
				var z: float = s.az + s.uz * t + s.ux * side * s.half
				max_gap = maxf(max_gap, absf(heights.ground_at(x, z) - deck))
				wet += 1 if heights.depth_at(x, z) > 0.3 else 0
	return {max_gap = max_gap, wet = wet}


## Речная маска включает сухую ось, но один край дороги касается воды.
## Такой берег обязан проверять ширину в обоих вариантах поиска.
func _dry_river_bank_check() -> void:
	var original := Grid.allow_fast
	for fast in ([true, false] if original else [false]):
		Grid.allow_fast = fast
		var ground := PackedFloat32Array()
		ground.resize(15)
		var water := ground.duplicate()
		water.fill(-INF)
		water[2] = 1.0
		var wet := PackedByteArray()
		wet.resize(15)
		wet.fill(1)
		var cost := ground.duplicate()
		cost.fill(INF)
		for x in range(1, 4): cost[5 + x] = 1.0
		var finder := Pathfinder.new(5, 3, ground)
		finder.set_corridor(ground, water, wet, 0.6)
		if not StageTrails._road_path(finder, cost, 6, 8).is_empty():
			fails += 1
			printerr("Сухой берег внутри маски реки пропустил мокрый край дороги")
		# Морская плоскость есть везде, в том числе в низком углу сухой клетки.
		var w := WorldData.new()
		w.W = 5
		w.H = 3
		w.N = 15
		w.h.resize(15)
		w.h.fill(0.1 / GameConfig.HS)
		for x in 5: w.h[x] = -0.6 / GameConfig.HS
		for key in ["ocean", "lake", "river"]:
			var field := PackedByteArray()
			field.resize(15)
			w.set(key, field)
		w.filled.resize(15)
		var surface := Heightfield.new(w, false)
		finder = Pathfinder.new(5, 3, surface.hv)
		StageTrails._route_surface(finder, surface, 0.9)
		if not StageTrails._road_path(finder, cost, 6, 8).is_empty():
			fails += 1
			printerr("Дорога не учла море в низком углу сухой клетки")
	Grid.allow_fast = original

static func measure(w: WorldData, h: Heightfield, kind: String) -> Dictionary:
	var r := {length = 0.0, steep35 = 0.0, steep60 = 0.0, wet = 0.0, edge_wet = 0.0, lake_wet = 0.0, deep_wet = 0.0, tilted50 = 0.0, max_grade = 0.0, worst = Vector2.ZERO}
	for trail: Dictionary in w.trails:
		if trail.kind != kind: continue
		for n in range(1, trail.pts.size()):
			var a := Vector2(trail.pts[n - 1].x, trail.pts[n - 1].y) * GameConfig.TILE
			var b := Vector2(trail.pts[n].x, trail.pts[n].y) * GameConfig.TILE
			var length := a.distance_to(b)
			if length < 0.001: continue
			var steps := maxi(1, ceili(length))
			var normal := (b - a).orthogonal().normalized() * float(trail.pts[n].w) * GameConfig.TILE * 0.5
			for j in steps:
				var p := a.lerp(b, float(j) / steps)
				var q := a.lerp(b, float(j + 1) / steps)
				var mid := (p + q) * 0.5
				var ground := h.ground_at(mid.x, mid.y)
				# Настилы и пол туннеля измеряются отдельно в feel_test.
				var structure := false
				for s: Dictionary in h.structures:
					if Grid.segment_dist(mid.x, mid.y, s.ax, s.az, s.bx, s.bz) < s.half + 1.0:
						structure = true
				if structure: continue
				var ds := length / steps
				var grade := absf(h.ground_at(q.x, q.y) - h.ground_at(p.x, p.y)) / ds
				r.length += ds
				if grade > 0.35: r.steep35 += ds
				if grade > 0.60: r.steep60 += ds
				if grade > r.max_grade:
					r.max_grade = grade
					r.worst = mid
				if h.depth_at(mid.x, mid.y) > 0.3: r.wet += ds
				if h.depth_at(mid.x, mid.y) > 1.0: r.deep_wet += ds
				var cell := clampi(floori(mid.y / GameConfig.TILE), 0, w.H - 1) * w.W + clampi(floori(mid.x / GameConfig.TILE), 0, w.W - 1)
				if h.depth_at(mid.x, mid.y) > 0.3 and (w.ocean[cell] != 0 or w.lake[cell] != 0): r.lake_wet += ds
				var left := mid + normal
				var right := mid - normal
				if h.depth_at(left.x, left.y) > 0.3 or h.depth_at(right.x, right.y) > 0.3: r.edge_wet += ds
				if absf(h.ground_at(left.x, left.y) - h.ground_at(right.x, right.y)) / (2.0 * normal.length()) > 0.5: r.tilted50 += ds
	return r
