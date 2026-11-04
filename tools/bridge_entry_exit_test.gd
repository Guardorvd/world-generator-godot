extends SceneTree
## Reproduce only reported bridge failures on preserved geography. Derived fixtures
## retain the complete world and surface, including houses and adjacent bridges.
const Bridges := preload("res://tools/bridge_test.gd")
const Surface := preload("res://scripts/game/surface_snapshot.gd")
const CASES := [["Ущелье", Vector2(1446, 914)], ["Заря-4787", Vector2(706, 1854)]]

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()

func fixture(seed: String) -> Heightfield:
	var cache := WorldCache.new()
	var file := "res://.godot/bridge_failure_%d.bin" % WGRandom.hash_string(seed)
	if FileAccess.file_exists(file):
		var saved: Dictionary = FileAccess.open_compressed(file, FileAccess.READ).get_var()
		var restored := cache._restore(saved.world, true)
		if restored != null:
			var h: Heightfield = Surface.restore(restored, saved.surface, "final")
			if h != null:
				restored.outer = OuterLand.new(restored)
				h.obstacles = ForestObstacles.new(restored, h)
				return h
	cache.dir = "res://tools/control/runs/settlement_bridge_cache"
	var data: Variant = cache._read(cache.path_for(seed, WorldGenerator.START_SIZE, 0), cache._key(seed, WorldGenerator.START_SIZE, 0))
	if not data is Dictionary: return null
	var w := cache._restore(data, false)
	if w == null: return null
	w.base_heights = Heightfield.new(w, false)
	w.start_noise_fields()
	StageLandmarks.run(w)
	StageTrails.run(w, func(_p: float, _label: String) -> void: pass)
	RoadSurface.run(w)
	var h := w.base_heights.copy()
	h.finish_paths()
	w.base_heights = null
	w.clear_noise_fields()
	w.available_rect = Rect2i(0, 0, w.W, w.H)
	var world := {}
	for key: String in WorldData.CACHE_FIELDS: world[key] = EntityCodec.encode(w.get(key))
	FileAccess.open_compressed(file, FileAccess.WRITE).store_var({world = world, surface = Surface.capture(h, "final")})
	w.outer = OuterLand.new(w)
	h.obstacles = ForestObstacles.new(w, h)
	return h

func run() -> void:
	var results := []
	var failures := 0
	for item: Array in CASES:
		var h := fixture(item[0])
		if h == null: printerr("Missing geographic fixture: ", item[0]); quit(1); return
		var w := h.world
		for s: Dictionary in h.structures:
			if s.tunnel or Vector2(s.ax, s.az).distance_to(item[1]) > 0.01: continue
			var at := Vector2(s.ax, s.az) - Vector2(s.ux, s.uz) * 2
			var p := PlayerState.new()
			p.x = at.x; p.z = at.y; p.feet = h.surface_at(p.x, p.z, s.ay); p.on_ground = true
			var b := Bridges._bike_for(p, atan2(-s.ux, -s.uz), true)
			var placement := BikeRecovery.placement(w, h, Vector3(p.x, p.feet, p.z), b.heading)
			var mount := b.prepare_mount(p, w, h)
			var before := var_to_bytes([h.hv, h.hv_raw, h.road_refinement.patches, h.structures])
			var crossings := []
			var passed := true
			for reverse in [false, true]:
				var span := s.duplicate()
				if reverse:
					span.ax = s.bx; span.az = s.bz; span.ay = s.by
					span.bx = s.ax; span.bz = s.az; span.by = s.ay
					span.ux = -s.ux; span.uz = -s.uz
				for ride in [false, true]:
					var ok := Bridges._cross(w, h, span, ride)
					passed = passed and ok
					crossings.append({reverse = reverse, ride = ride, passed = ok, detail = Bridges.last_cross.duplicate(true)})
			var unchanged := before == var_to_bytes([h.hv, h.hv_raw, h.road_refinement.patches, h.structures])
			failures += int(not passed or not unchanged)
			var routes := []
			for route: Dictionary in w.trails:
				if route.kind == "animal": continue
				var ai := -1; var bi := -1
				for k in route.pts.size():
					var point := Vector2(route.pts[k].x, route.pts[k].y) * GameConfig.TILE
					if point.distance_to(Vector2(s.ax, s.az)) < 0.1: ai = k
					if point.distance_to(Vector2(s.bx, s.bz)) < 0.1: bi = k
				if ai >= 0 and bi >= 0:
					routes.append({kind = route.kind, entry = route.pts.slice(maxi(0, ai - 2), mini(route.pts.size(), ai + 3)),
						exit = route.pts.slice(maxi(0, bi - 2), mini(route.pts.size(), bi + 3))})
			var report := {seed = item[0], span = s, placement = placement, mount_allowed = mount, mount_heading = b.heading,
				passed = passed, unchanged_geometry = unchanged, crossings = crossings, routes = routes}
			print("FOCUSED BRIDGE ", JSON.stringify(report))
			results.append(report)
	FileAccess.open("res://tools/control/runs/bridge_entry_exit_results.json", FileAccess.WRITE).store_string(JSON.stringify(results, "  "))
	quit(0 if results.size() == CASES.size() and failures == 0 else 1)
