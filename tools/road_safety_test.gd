extends SceneTree
## Измеряет готовую поверхность, включая метровое полотно: ось и оба края через 1 м.
## -- --out res://tools/control/runs/roads.json --seeds 6 --size 512
const Connectivity := preload("res://tools/selftest.gd")
const SEEDS := ["Север-1234", "Туман-4821", "Ущелье", "Янтарь-5150", "Озёра-5", "Гряда-310", "a1", "b2", "c3", "d4", "e5", "f6"]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var count := 6
	var size := 512
	var output := ""
	var only_seed := ""
	for k in args.size() - 1:
		if args[k] == "--seeds": count = int(args[k + 1])
		if args[k] == "--size": size = int(args[k + 1])
		if args[k] == "--out": output = args[k + 1]
		if args[k] == "--seed": only_seed = args[k + 1]
	Grid.allow_fast = not args.has("--gdscript")
	var results := {}
	var fails := 0
	for seed_text in ([only_seed] if not only_seed.is_empty() else SEEDS.slice(0, count)):
		var start := Time.get_ticks_msec()
		var trace := func(_p: float, label: String) -> void:
			if args.has("--trace"): print("  ", Time.get_ticks_msec() - start, " ", label)
		var w := WorldGenerator.generate(seed_text, size, trace)
		var heights := Heightfield.new(w)
		var row := {connected = Connectivity.settlements_connected(w), settlements = w.settlements.size(), routes = w.trails.size(), bridges = w.bridges.size(), tunnels = w.tunnels.size()}
		for kind in ["road", "trail", "mountain"]:
			row[kind] = measure(w, heights, kind)
			if row[kind].lake_wet > 0.0 or not is_finite(row[kind].max_grade):
				printerr("Небезопасный путь: ", seed_text, " ", kind)
				fails += 1
		if row.road.wet > 0.0:
			printerr("Основная дорога в воде: ", seed_text)
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
