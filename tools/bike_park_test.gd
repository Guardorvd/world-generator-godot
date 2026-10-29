extends SceneTree
## Велопарк стартовой области (BikePark через StageTrailPlan) в настоящем мире: одна новая генерация через WorldLoader
## (кэш выключен), сводка парка, проверки (парк найден, трассы в мире, запеклись без ошибок, длина) и картинка сверху
## tools/control/runs/bike_park/<сид>.png (рельеф и трассы парка, 2 м на пиксель).
## `-- --cache` — кэш во временной папке и вторая загрузка из него: объекты технических элементов (TrailTechnical)
## те же, что на холодной загрузке, и обновление подлеска в ForestObstacles их не стирает.
##   godot --headless --path . --script res://tools/bike_park_test.gd -- --seed Полынь-1312
const OUT := "res://tools/control/runs/bike_park"
const CACHE := "user://bike_park_test_cache"
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 420)
	run.call_deferred()


func check(ok: bool, label: String) -> void:
	print("bike_park: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1


func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var args := OS.get_cmdline_user_args()
	var seed: String = args[args.find("--seed") + 1] if "--seed" in args else "Полынь-1312"
	var cached := "--cache" in args
	var cache := GameContext.scope.cache
	if cached:
		cache.dir = CACHE
		cache.enabled = true
		cache.remove_seed(seed)
	var t0 := Time.get_ticks_msec()
	var r := WorldLoader.load_world(seed, WorldGenerator.START_SIZE)
	print("Мир «%s»: %d мс (finish_paths %.0f, запекание парка %.0f)" % [seed, Time.get_ticks_msec() - t0, r.timings.get("finish_paths_ms", 0.0), r.timings.get("trail_ms", 0.0)])
	check(r.error.is_empty(), "мир загружен: %s" % r.error)
	if not r.error.is_empty():
		quit(1)
		return
	var plan: Dictionary = r.world.trail_plan
	print("План: ", plan.state, " · ", plan.get("reason", ""), " · ", plan.get("stats", {}), " · ", plan.get("park", {}))
	check(plan.state == "found", "парк найден")
	if plan.state != "found":
		quit(1)
		return
	var kit: Array[TrailDefinition] = []
	var total := 0.0
	for data: Dictionary in plan.routes:
		var d := StageTrailPlan.unpack(data)
		kit.append(d)
		total += d.route_length()
		print("  %s: %.0f м, элементов %d" % [d.title, d.route_length(), d.elements.size()])
	var bt: Dictionary = r.heights.road_refinement.build_timings
	print("Запекание: профили %.0f мс, зона %.0f мс, всего %.0f мс, клеток зоны %d" % [bt.get("trail_profile_ms", 0.0), bt.get("trail_zone_ms", 0.0), bt.get("trail_elements_ms", 0.0), bt.get("trail_zone_patches", 0)])
	for id: String in r.trail.get("earthworks", {}):
		var e: Variant = r.trail.earthworks[id]
		if e is Dictionary: print("  %s: зона %.0f м, выемка до %.1f м, насыпь до %.1f м, уклон %s" % [id, e.get("reach", 0.0), e.get("max_cut", 0.0), e.get("max_fill", 0.0), e.get("grade_used", 0.0)])
	print("Всего трасс %d, %.0f м; запекание: %s, %s" % [kit.size(), total, r.trail.variant, r.trail.errors])
	check(kit.size() >= 3 and total >= 1000.0, "сеть трасс от километра (%d, %.0f м)" % [kit.size(), total])
	check(r.trail.applied and r.trail.errors.is_empty(), "запечено без ошибок (%s)" % r.trail.variant)
	var listed := 0
	for route: Dictionary in r.world.trails:
		if str(route.get("trail_id", "")).begins_with(StageTrailPlan.ID + "/"): listed += 1
	check(listed == kit.size(), "все трассы в мире ровно по разу (%d)" % listed)
	print("Объекты трассы: ", r.trail.get("technical", {}))
	check(r.trail.has("technical") and r.heights.trail_technical.props.size() == r.trail.technical.props, "объекты технических элементов собраны")
	obstacles(r.heights)
	if cached:
		cache.wait_writes()
		t0 = Time.get_ticks_msec()
		var b := WorldLoader.load_world(seed, WorldGenerator.START_SIZE)
		print("Из кэша: %d мс, объекты трассы: %s" % [Time.get_ticks_msec() - t0, b.trail.get("technical", {})])
		check(b.from_cache and b.surface_hit, "вторая загрузка — из кэша поверхности")
		var ta: Dictionary = r.heights.trail_technical
		var tb: Dictionary = b.heights.trail_technical
		check(not tb.is_empty() and tb.collide == ta.collide and tb.bumps == ta.bumps and var_to_str(tb.props) == var_to_str(ta.props), "из кэша — тот же комплект объектов трассы")
		var decks := 0
		for s: Dictionary in b.heights.structures: decks += int(s.get("deck", false))
		check(decks == ta.decks.size(), "настилы не задвоились при загрузке из кэша (%d)" % decks)
		cache.wait_writes()
		cache.remove_seed(seed)
		cache.enabled = false
	picture(r.heights, plan.park, kit, OUT + "/" + seed + ".png")
	print("bike_park: ", failures, " failures")
	quit(1 if failures else 0)


## Слой трассы в ForestObstacles: препятствие держит, кочка поднимает колесо — и после обновления подлеска тоже.
func obstacles(h: Heightfield) -> void:
	var t: Dictionary = h.trail_technical
	var fo := ForestObstacles.new(h.world, h)
	var veg_bump := PackedFloat32Array([-1000.0, -1000.0, -1000.0, -1000.0, 0.3, 0.1])
	for version in [1, 2]:
		fo.set_bumps(veg_bump if version == 2 else PackedFloat32Array(), version)
		if t.collide.size() > 0:
			var x: float = t.collide[0]
			var z: float = t.collide[1]
			fo.update(x, z, PackedFloat32Array(), version, true)
			check(fo.hits(x, z, t.collide[5], 0.3), "препятствие трассы держит (обновление подлеска %d)" % version)
		if t.bumps.size() > 0:
			fo.update(t.bumps[0], t.bumps[1], PackedFloat32Array(), version, true)
			check(fo.bump_at(t.bumps[0], t.bumps[1]) > 0.0, "кочка трассы поднимает колесо (обновление подлеска %d)" % version)


func picture(h: Heightfield, park: Dictionary, kit: Array[TrailDefinition], path: String) -> void:
	var c: Vector2 = park.center
	var rad: float = park.extent + 40.0
	var px := 2.0
	var n := int(rad * 2.0 / px)
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	var lo := INF
	var hi := -INF
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	for y in n:
		for x in n:
			var v := h.surface_at(c.x - rad + x * px, c.y - rad + y * px, INF)
			hs[y * n + x] = v
			lo = minf(lo, v)
			hi = maxf(hi, v)
	for y in range(1, n):
		for x in range(1, n):
			var shade := clampf(0.55 + (hs[y * n + x] - hs[y * n + x - 1] + hs[y * n + x] - hs[(y - 1) * n + x]) * 0.6, 0.0, 1.0)
			var t := (hs[y * n + x] - lo) / maxf(1.0, hi - lo)
			img.set_pixel(x, y, Color(0.35 + 0.4 * t, 0.45 + 0.3 * t, 0.3, 1.0) * shade)
	var colors := [Color.RED, Color.YELLOW, Color.CYAN, Color.MAGENTA, Color.ORANGE, Color.WHITE, Color.GREEN, Color.BLUE]
	for k in kit.size():
		var d := kit[k]
		var s := 0.0
		while s < d.route_length():
			var p := (d.point_at(s) - c + Vector2.ONE * rad) / px
			for oy in range(-1, 2):
				for ox in range(-1, 2):
					var q := Vector2i(p) + Vector2i(ox, oy)
					if q.x >= 0 and q.y >= 0 and q.x < n and q.y < n: img.set_pixelv(q, colors[k % colors.size()])
			s += 1.0
	img.save_png(ProjectSettings.globalize_path(path))
	print("Картинка: ", ProjectSettings.globalize_path(path))
