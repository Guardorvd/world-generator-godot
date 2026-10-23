extends SceneTree
## Изолированная проверка дисковых сохранений и меню, без генерации мира.
const Saves = preload("res://scripts/game/save_game.gd")
const Quests = preload("res://scripts/game/quests.gd")
const Main = preload("res://scripts/ui/main.gd")
var failed := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	if not ok:
		failed += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1280, 720)
	Saves.dir = "res://.godot/save_test"
	DirAccess.make_dir_recursive_absolute(Saves.dir)
	var a := {key = "settlement:1", kind = "settlement", name = "Дом", x = 1, y = 1, src = {}}
	var b := {key = "settlement:2", kind = "settlement", name = "Цель", x = 20, y = 20, src = {}}
	var places := {a.key: a, b.key: b}
	var q := Quests.new()
	q.accept(Quests._make("delivery", a, [b]))
	q.pick_up()
	var state := {format = 1, seed = "save-test", signature = "places", saved_at = 100,
		visited = {a.key: true}, goal = b.key, quest = q.save_state(),
		player = {x = 4.0, z = 4.0, feet = 0.0, yaw = 1.0, pitch = 0.0, hour = 9.0},
		bike = {x = 4.0, z = 4.0, y = 0.0, heading = 1.0, riding = true}}
	check(Saves.write_slot(state) == OK, "write auto")
	var r := Saves.read_slot(state.seed)
	check(r.data == state, "disk round trip including discoveries and cargo")
	var restored := Quests.new()
	check(restored.restore_state(r.data.quest, places) and restored.cargo and restored.step().do == "carry", "delivery resumes after pickup")
	restored.tick(func(_p: Dictionary) -> bool: return true)
	check(restored.done == 1 and restored._done.has(q.active.id), "restored delivery completes once")
	check(Quests.new().restore_state(restored.save_state(), places), "completed history restores")
	check(not Quests.new().restore_state(q.save_state(), {}), "missing quest place rejected")
	state.saved_at = 200
	check(Saves.write_slot(state) == OK, "rotate backup")
	var f := FileAccess.open(Saves.path_for(state.seed), FileAccess.WRITE)
	f.store_buffer(PackedByteArray([1, 2, 3, 4]))
	f.close()
	r = Saves.read_slot(state.seed)
	check(r.backup and r.data.saved_at == 100, "corrupt primary recovers previous backup")
	check(Saves.write_slot(state) == OK and not Saves.read_slot(state.seed).backup, "save after recovery repairs primary")
	check(Saves.write_slot(state, "manual") == OK, "manual slot independent")
	var other := state.duplicate(true)
	other.seed = "another-world"
	check(Saves.write_slot(other) == OK and Saves.read_slot(state.seed).data.seed == state.seed, "worlds isolated")
	var old_dir := WorldCache.dir
	WorldCache.dir = "res://.godot/save_test_cache"
	WorldCache.keep_only([])
	WorldCache.dir = old_dir
	check(not Saves.read_slot(state.seed).data.is_empty(), "cache clear preserves progress")
	var bad := state.duplicate(true)
	bad.player.x = NAN
	check(Saves.write_slot(bad) == ERR_INVALID_DATA, "nonfinite position rejected")
	bad = state.duplicate(true)
	bad.quest.active.step = 999
	check(Saves.write_slot(bad) == ERR_INVALID_DATA, "invalid quest step rejected")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.set_script(null)
	root.add_child(main)
	main.set_script(Main)
	main.set_process(false)
	main.hud = main.get_node("UI/Hud") if main.has_node("UI/Hud") else main.find_child("Hud", true, false)
	main.seed_edit = main.get_node("%SeedEdit")
	main.screens = {back = main.get_node("%Back"), menu = main.get_node("%Menu"),
		loading = main.get_node("%Loading"), pause = main.get_node("%Pause"), settings = main.get_node("%Settings")}
	main._setup_save_controls()
	check(main._load_manual != null and main._save_status != null, "menu save controls created")
	main.seed_edit.text = state.seed
	main._show_seed_tab("saved")
	main._show("menu")
	await process_frame
	await process_frame
	check(main.get_node("%Start").text.begins_with("Продолжить") and not main._load_manual.disabled, "menu reflects saved progress")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://.godot/save_test_menu.png")
	main._show("pause")
	await process_frame
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://.godot/save_test_pause.png")
	if "--integration" in OS.get_cmdline_user_args():
		await integration(main)
	main.queue_free()
	await process_frame
	for name: String in DirAccess.get_files_at(Saves.dir):
		DirAccess.remove_absolute(Saves.dir.path_join(name))
	print("SAVE TEST failures: ", failed)
	quit(1 if failed else 0)

func integration(main: Node) -> void:
	print("Integration: generating one world")
	WorldCache.enabled = false
	var loaded := WorldLoader.load_world("Север-1234", 256)
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	main.add_child(game)
	game.start(loaded, main.hud)
	game.set_paused(true)
	var places: Array = main.hud.all_places()
	var towns := places.filter(func(p: Dictionary) -> bool: return p.kind == "settlement")
	game.quests.accept(Quests._make("delivery", towns[0], [towns[1]]))
	game.quests.pick_up()
	main.hud.visited[towns[0].key] = true
	var snapshot := game.save_state()
	check(GameWorld.can_restore(snapshot, loaded.world), "live snapshot compatible")
	check(Saves.write_slot(snapshot) == OK, "live snapshot written")
	game.queue_free()
	await process_frame
	main.hud.clear_world()
	game = load("res://scenes/game_world.tscn").instantiate()
	main.add_child(game)
	game.start(loaded, main.hud, Saves.read_slot(snapshot.seed).data)
	game.set_paused(true)
	check(not game.opening_active(), "loading skips cinematic")
	check(main.hud.visited.has(towns[0].key) and game.quests.cargo and game.quests.step().do == "carry", "live discoveries and delivery restored")
	check(Vector2(game.player.x - snapshot.player.x, game.player.z - snapshot.player.z).length() < 0.1, "live player position restored")
	check(absf(game.hour - snapshot.player.hour) < 0.01, "world time restored")
	snapshot.signature = "outdated"
	check(not GameWorld.can_restore(snapshot, loaded.world), "changed world blocked")
	game.queue_free()
	await process_frame
