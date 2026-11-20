extends SceneTree
## Изолированная проверка дисковых сохранений и меню, без генерации мира.
const Saves = preload("res://scripts/game/save_game.gd")
const Quests = preload("res://scripts/game/quests.gd")
const Main = preload("res://scripts/ui/main.gd")
const ShopProgress = preload("res://scripts/game/shop_progress.gd")
var failed := 0

class SaveFixture extends Node:
	var quests := RefCounted.new()
	var state: Dictionary

	func save_state() -> Dictionary:
		return state.duplicate(true)


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	if not ok:
		failed += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300 if "--integration" in OS.get_cmdline_user_args() else 120)
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1280, 720)
	# Отдельный каталог запуска: не трогаем результаты предыдущих проверок.
	Saves.dir = "res://.godot/save_test_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
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
	var clock_state := state.duplicate(true)
	clock_state.player.clock_day = 7
	clock_state.player.sky_seconds = 432.5
	check(Saves.write_slot(clock_state, "manual") == OK and Saves.read_slot(state.seed, "manual").data == clock_state,
		"day number and sky animation time survive a disk round trip")
	clock_state.player.sky_seconds = INF
	check(not Saves.valid(clock_state), "nonfinite sky animation time rejected")
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
	var old_dir := GameContext.scope.cache.dir
	GameContext.scope.cache.dir = "res://.godot/save_test_cache"
	GameContext.scope.cache.keep_only([])
	GameContext.scope.cache.dir = old_dir
	check(not Saves.read_slot(state.seed).data.is_empty(), "cache clear preserves progress")
	var bad := state.duplicate(true)
	bad.player.x = NAN
	check(Saves.write_slot(bad) == ERR_INVALID_DATA, "nonfinite position rejected")
	bad = state.duplicate(true)
	bad.quest.active.step = 999
	check(Saves.write_slot(bad) == ERR_INVALID_DATA, "invalid quest step rejected")
	_test_marker_save(state)
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
	_test_auto_save_order(main, state)
	main._show_seed_tab("saved")
	main._pick_seed(state.seed)
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
	for seed_text: String in ["save-test", "another-world", "auto-order", "Север-1234"]:
		for slot: String in ["auto", "manual"]:
			var path := Saves.path_for(seed_text, slot)
			for suffix: String in ["", ".bak"]:
				if FileAccess.file_exists(path + suffix):
					DirAccess.remove_absolute(path + suffix)
	ShopProgress.Files.remove(Saves.dir.path_join("shop_progress.bin"))
	DirAccess.remove_absolute(Saves.dir)
	print("SAVE TEST failures: ", failed)
	quit(1 if failed else 0)


func _test_auto_save_order(main: Node, state: Dictionary) -> void:
	var fixture := SaveFixture.new()
	main.add_child(fixture)
	fixture.state = state.duplicate(true)
	fixture.state.seed = "auto-order"
	fixture.state.saved_at = 300
	main.game = fixture
	main._progress_enabled = true
	main._queue_auto_save()
	check(main._auto_save_task != -1, "autosave hands the snapshot to a worker")
	fixture.state.saved_at = 400
	check(main._save_current() and main._auto_save_task == -1 and Saves.read_slot("auto-order").data.saved_at == 400,
		"immediate save drains autosave before writing the newer snapshot")
	var backup := Saves._read_file(Saves.path_for("auto-order") + ".bak")
	check(backup.get("saved_at") == 300, "background save keeps the older snapshot as backup")
	main.game = null
	main._progress_enabled = false
	fixture.free()


func _test_marker_save(state: Dictionary) -> void:
	var marker := state.duplicate(true)
	marker.goal = "marker"
	marker.goal_marker = Vector2(-32.5, 412.25) # клеточные координаты, в том числе вне стартового плана
	check(Saves.write_slot(marker, "manual") == OK, "free map target writes through the existing save container")
	var loaded: Dictionary = Saves.read_slot(marker.seed, "manual").data
	var hud := Hud.new()
	hud.restore_goal(loaded.goal, loaded.get("goal_marker", Vector2.INF))
	check(hud.goal == Hud.marker_goal(marker.goal_marker), "free map target restores its exact coordinates after a disk round trip")
	hud.restore_goal("marker")
	check(hud.goal.is_empty(), "legacy marker without stored coordinates clears without inventing a destination")
	hud.restore_goal("")
	check(hud.goal.is_empty() and Saves.valid(state), "empty goal and legacy named-place save remain valid")
	for invalid: Variant in [Vector2(NAN, 1), Vector2(1, INF), "32,64"]:
		var bad := marker.duplicate(true)
		bad.goal_marker = invalid
		check(Saves.write_slot(bad, "manual") == ERR_INVALID_DATA, "invalid map-target coordinates are rejected: %s" % str(invalid))
	var orphan := state.duplicate(true)
	orphan.goal_marker = marker.goal_marker
	check(not Saves.valid(orphan), "coordinates cannot silently attach to a different named target")
	hud.free()

func _arrive_for_quest(game: GameWorld) -> String:
	var step := game.quests.step()
	if step.is_empty():
		return ""
	var previous := Vector2(game.player.x, game.player.z)
	game.player.x = step.place.x * GameConfig.TILE
	game.player.z = step.place.y * GameConfig.TILE
	var message := game.quests.tick(game._quest_arrived)
	game._quest_progress(message)
	game.player.x = previous.x
	game.player.z = previous.y
	return message


func integration(main: Node) -> void:
	print("Integration: generating one world")
	GameContext.scope.cache.enabled = false
	var loaded := WorldLoader.load_world("Север-1234", 256)
	var profile := ShopProgress.new()
	var profile_path := Saves.dir.path_join("shop_progress.bin")
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	game.shop_progress = profile
	main.add_child(game)
	game.start(loaded, main.hud)
	game.set_paused(true)
	check(game.quests.active.id.begins_with("start:") and game.quests.reward_points(game.quests.active.id) == 20,
		"real world advertises the opening reward")
	profile.set_purchase_goal("moss")
	check(_arrive_for_quest(game).contains("«Мох» — 30") and profile.balance == 20,
		"real world credits the opening reward and shows the remaining cost")
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
	profile = ShopProgress.new()
	profile.load_profile(profile_path)
	profile.set_purchase_goal("moss")
	main.hud.journal_panel.enable_shop(profile)
	game = load("res://scenes/game_world.tscn").instantiate()
	game.shop_progress = profile
	main.add_child(game)
	game.start(loaded, main.hud, Saves.read_slot(snapshot.seed).data)
	game.set_paused(true)
	check(not game.opening_active(), "loading skips cinematic")
	check(profile.balance == 20, "old world slot grants its completed opening reward to a fresh profile")
	check(main.hud.visited.has(towns[0].key) and game.quests.cargo and game.quests.step().do == "carry", "live discoveries and delivery restored")
	check(Vector2(game.player.x - snapshot.player.x, game.player.z - snapshot.player.z).length() < 0.1, "live player position restored")
	check(absf(game.hour - snapshot.player.hour) < 0.01, "world time restored")
	check(not game.bike.riding or (game.bike.can_mount(game.player) and not BikeRecovery.placement(game.world, game.heights,
		Vector3(game.bike.x, game.bike.y, game.bike.z), game.bike.heading).is_empty()), "restored rider has a safe bicycle placement")
	game.set_paused(false)
	main.hud.show()
	game.bike.speed = 0.0
	game._open_settlement(towns[0].src)
	check(game._settlement_open(), "settlement board opens after restore")
	var before := Vector3(game.player.x, game.player.feet, game.player.z)
	Input.action_press("move_forward")
	game._physics_process(1.0 / 60.0)
	Input.action_release("move_forward")
	check(before == Vector3(game.player.x, game.player.feet, game.player.z), "settlement board blocks movement")
	check(main.hud.map_journal.read.has(towns[0].key), "reading a board opens its place on the personal map")
	game.toggle_map()
	check(game.show_map and not game._settlement_open(), "map closes settlement board")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	game._unhandled_input(click)
	check(not game._dragging, "unhandled map click cannot start camera dragging")
	var old_yaw := game.yaw
	game._captured_at = -1000
	game._dragging = true
	var motion := InputEventMouseMotion.new()
	motion.screen_relative = Vector2(100, 50)
	game._unhandled_input(motion)
	check(game.yaw == old_yaw, "map mouse motion cannot rotate camera")
	game.set_paused(true)
	check(game.paused and not game._settlement_open(), "pause closes modal gameplay states")
	game.set_paused(false)
	check(game.show_map, "resume preserves open map")
	game.toggle_map()
	before = Vector3(game.player.x, game.player.feet, game.player.z)
	game.travel_to(towns[1])
	check(before == Vector3(game.player.x, game.player.feet, game.player.z), "restored cargo still blocks fast travel")
	check(_arrive_for_quest(game).contains("«Мох» теперь можно купить") and profile.balance == 50 and not game.quests.cargo,
		"restored delivery completes and announces that the goal is affordable")
	game.toggle_map()
	var tablet: Hud.Tablet = main.hud.journal_panel
	var atlas: Hud.Atlas = tablet.map_view
	await process_frame
	atlas._scale *= 1.25
	var scale_before := atlas._scale
	var center_before := atlas._center
	tablet.cycle_tab(-1)
	check(tablet.active_tab == Hud.Tablet.Tab.SHOP and not atlas.is_processing() and root.disable_3d,
		"shop uses the tablet and suspends atlas and world drawing")
	var shop := tablet.shop_panel
	check(shop._selection == "moss", "journal opens on the tracked goal")
	shop._action.pressed.emit()
	var back := InputEventAction.new()
	back.action = &"back"
	back.pressed = true
	check(game._tablet_shortcut(back) and tablet.active_tab == Hud.Tablet.Tab.SHOP and profile.balance == 50
		and not shop._review_actions.visible, "controller back cancels the purchase without closing the journal")
	shop._action.pressed.emit()
	tablet.cycle_tab(1)
	tablet.cycle_tab(-1)
	check(not shop._review_actions.visible and profile.balance == 50, "switching tabs cancels a pending purchase")
	shop._action.pressed.emit()
	shop._confirm_buy.pressed.emit()
	var old_palette: PackedColorArray = game.bike_view._skin_mats[0].get_shader_parameter("palette")
	check(profile.owns("moss") and profile.balance == 0 and old_palette == ShopProgress.Palette.colors("ember"),
		"first purchase commits its cost and leaves the equipped skin alone")
	shop._action.pressed.emit()
	check(profile.equipped == "moss" and game.bike_view._skin_mats[0].get_shader_parameter("palette") == ShopProgress.Palette.colors("moss"),
		"equipping in the journal updates the real bike and rider shader")
	tablet.cycle_tab(1)
	await process_frame
	check(atlas.is_processing() and is_equal_approx(atlas._scale, scale_before) and atlas._center == center_before,
		"returning from the shop preserves map zoom and position (processing=%s, scale=%f/%f, center=%s/%s)" % [
			atlas.is_processing(), atlas._scale, scale_before, atlas._center, center_before])
	game.toggle_map()
	check(not root.disable_3d, "closing the tablet resumes world drawing")
	var completed_snapshot := game.save_state()
	check(Saves.write_slot(completed_snapshot, "manual") == OK, "save completed journey to manual slot")
	game.set_paused(true)
	snapshot.signature = "outdated"
	check(not GameWorld.can_restore(snapshot, loaded.world), "changed world blocked")
	game.queue_free()
	await process_frame
	main.hud.clear_world()
	var reopened := ShopProgress.new()
	reopened.load_profile(profile_path)
	game = load("res://scenes/game_world.tscn").instantiate()
	game.shop_progress = reopened
	main.add_child(game)
	game.start(loaded, main.hud, Saves.read_slot(completed_snapshot.seed, "manual").data)
	game.set_paused(true)
	check(reopened.balance == 0 and reopened.equipped == "moss" and reopened.purchase_goal == ""
		and game.bike_view._skin_mats[0].get_shader_parameter("palette") == ShopProgress.Palette.colors("moss"),
		"manual slot reload keeps the purchase, equipment and spent balance")
	game.queue_free()
	await process_frame
