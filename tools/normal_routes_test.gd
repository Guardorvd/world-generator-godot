extends SceneTree
## Real WORLD pipeline, isolated cache, actual loader and save restoration.
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	failures += int(not ok)
	print("OK " if ok else "FAIL ", label)

func run() -> void:
	var services := ServiceScope.new()
	services.cache.dir = "res://.godot/normal_routes_%d" % OS.get_process_id()
	services.cache.enabled = true
	services.settings.settings_path = services.cache.dir.path_join("settings.cfg")
	var searches := TrailScout.runs
	var loaded := WorldLoader.load_world("Север-1234", 192, Callable(), services)
	var w := loaded.world
	services.cache.wait_writes()
	check(TrailScout.runs == searches, "cold WORLD generation performs no prepared-trail search")
	check(w.trail_plan.state == "none" and not w.trail_plan.has("definition"), "no prepared definitions")
	check(w.generation.trail_surface == null, "no park earthworks handoff")
	check(RideRoutes.enabled() and w.generation_profile.has("rides"), "RideRoutes ran")
	var kinds := {}
	var rides := 0
	for route: Dictionary in w.trails:
		kinds[route.kind] = kinds.get(route.kind, 0) + 1
		rides += int(route.has("ride"))
	print("Natural routes: ", kinds, " rides=", rides)
	check(kinds.get("road", 0) > 0 and w.road_surface.size() > 0, "ordinary roads have road surfaces")
	check(rides > 0, "natural bicycle routes present")
	check(loaded.error.is_empty() and not loaded.from_cache, "normal loader accepts cold world")
	check(not loaded.trail.applied and loaded.heights.trail_technical.is_empty(), "no park technical objects or earthworks on load")
	services.cache.wait_writes()
	var again := WorldLoader.load_world(w.seed_text, 192, Callable(), services)
	check(again.error.is_empty() and again.from_cache and again.surface_hit, "world and final surface cache reload work")
	check(again.world.trails == loaded.world.trails and again.heights.hv == loaded.heights.hv, "routes and road heights survive cache reload")
	check(TrailScout.runs == searches, "cache reload performs no prepared-trail search")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	root.add_child(game)
	game.start(again, main.hud, {}, services)
	check(game.player != null and again.error.is_empty(), "normal game starts")
	if game.player != null:
		var saved := game.save_state()
		# A former elevated park deck is gone: restore feet to the current surface.
		saved.player.feet += 20.0
		game.free()
		game = load("res://scenes/game_world.tscn").instantiate()
		root.add_child(game)
		game.start(again, main.hud, saved, services)
		check(game.player != null and game.safe_position(game.player.x, game.player.z, game.player.feet), "save restores a safe player position")
		check(absf(game.player.feet - again.heights.surface_at(game.player.x, game.player.z, game.player.feet)) < 0.1, "saved feet snap to current ground")
	game.free()
	main.free()
	services.cache.wait_writes()
	print("normal_routes_test: %d failures" % failures)
	quit(1 if failures else 0)
