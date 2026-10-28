extends SceneTree
## 14.9: service isolation, legacy entity import, persistence and component contracts.
var failures := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	failures += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	var first := ServiceScope.new()
	var second := ServiceScope.new()
	first.settings.mouse = 2.5
	first.settings.recent_seeds.append("independent")
	first.controls.joypad = true
	first.cache.dir = "res://.godot/architecture-cache"
	first.cache.enabled = true
	check(second.settings.mouse == GameSettings.DEFAULT_MOUSE and second.settings.recent_seeds.is_empty()
		and not second.controls.joypad and not second.cache.enabled, "service scopes do not share mutable state")
	first.reset()
	check(first.settings.mouse == second.settings.mouse and first.settings.recent_seeds.is_empty()
		and not first.controls.joypad and first.cache.dir == second.cache.dir, "reset restores a clean scope without profile I/O")
	var old := {x = 10.5, y = 12.5, i = 22, name = "Legacy", huts = [{x = 11.0, y = 12.0, v = 2}], connections = [33]}
	var town := SettlementData.from_dict(old)
	check(town.huts[0] is HutData and not town.huts[0].has("a"), "legacy huts retain inferred facing")
	var roundtrip := SettlementData.from_dict(bytes_to_var(var_to_bytes(town.to_dict())))
	check(roundtrip.name == town.name and roundtrip.huts[0].v == 2 and roundtrip.connections == [33], "entity roundtrip uses only safe Variants")
	var copied: SettlementData = town.duplicate()
	copied.huts[0].x += 5.0
	check(town.huts[0].x == 11.0, "entity copies do not share mutable huts")
	var quest := QuestData.new("sample", "visit", "giver", {key = "town", src = town})
	var quest_copy: QuestData = quest.duplicate()
	check(quest_copy.target.src is SettlementData and not is_same(quest_copy.target.src, town)
		and not quest_copy.target.src.huts[0].has("a"), "quest copies preserve nested entity types and optional fields")
	var ledger := {settlements = [town]}
	var snapshot: Dictionary = EntityCodec.copy(ledger)
	snapshot.settlements[0].net = "changed"
	check(town.net.is_empty(), "region snapshots do not mutate committed entities")
	var world := WorldData.new()
	world.settlements = [old]
	world.bridges = [{a = 1, b = 2}]
	world.tunnels = [{a = 3, b = 4}]
	check(world.settlements[0] is SettlementData and world.bridges[0] is BridgeData
		and world.tunnels[0] is TunnelData, "legacy world arrays import into typed storage")
	var both: Array = world.bridges + world.tunnels
	check(both.size() == 2, "bridge and tunnel consumers can traverse a mixed list")
	var interaction := InteractionService.new()
	var items := [{kind = "board", at = Transform3D(Basis.IDENTITY, Vector3(0, 0, -2)), half = Vector3.ONE * 0.3},
		{kind = "bike", at = Transform3D(Basis.IDENTITY, Vector3(0, 0, -4)), half = Vector3.ONE}]
	check(interaction.select(items, Vector3.ZERO, Vector3.FORWARD).kind == "board", "nearest direct interaction wins")
	check(interaction.select(items, Vector3.ZERO, Vector3.BACK).is_empty(), "targets behind the player are excluded")
	var calls: Array[String] = []
	var stream := WorldStreamCoordinator.new()
	stream.vegetation_update = func(_x: float, _z: float, _force: bool) -> bool:
		calls.append("vegetation")
		return true
	stream.terrain_update = func(_x: float, _z: float, _force: bool, upload: bool) -> bool:
		check(not upload, "terrain yields upload budget to vegetation")
		calls.append("terrain")
		return false
	stream.region_update = func(_x: float, _z: float) -> bool:
		calls.append("region")
		return true
	stream.update(Vector3.ZERO)
	check(calls == ["vegetation", "terrain"], "regional builds yield to an existing frame upload")
	var bike_a := BikeController.new()
	var bike_b := BikeController.new()
	bike_a.stamina.value = 0.1
	check(bike_b.stamina.value == 1.0, "bike controllers own separate rider stamina")
	var camera_a := PlayerCameraController.new()
	var camera_b := PlayerCameraController.new()
	camera_a.shake_on_landing(20.0, 6.0)
	check(camera_a._trauma > 0.0 and camera_b._trauma == 0.0, "camera effects are isolated per player")
	# Exercise the complete pipeline on a small plan, including threaded vegetation.
	var generated := WorldGenerator._generate_plan("architecture-14.9", 96)
	check(not generated.settlements.is_empty() and generated.obj_count > 0, "generation completes with typed entities")
	var heights := Heightfield.new(generated)
	var parent := Node3D.new()
	SettlementsBuilder.build(parent, generated, heights)
	check(parent.get_child_count() > 0, "typed entities feed settlement rendering")
	parent.free()
	call_deferred("scene_integration", generated, heights)

func scene_integration(generated: WorldData, heights: Heightfield) -> void:
	# Reuse the small generated plan; no menu/background or full-size world generation.
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	var hud: Hud = shell.get_node("UI/Root/Hud")
	hud.get_parent().remove_child(hud)
	shell.free()
	root.add_child(hud)
	var loaded := WorldLoader.new()
	loaded.world = generated
	loaded.heights = heights
	loaded.service_scope = ServiceScope.new()
	loaded.service_scope.settings.mouse = 2.0
	loaded.terrain_chunks = PlanTerrain.partition(TerrainBuilder.build_arrays(generated, heights))
	loaded.water_arrays = WaterBuilder.prepare(generated, heights)
	loaded.terrain_image = Image.create(96, 96, false, Image.FORMAT_RGBA8)
	loaded.terrain_image.fill(Color.DARK_GREEN)
	loaded.map_image = loaded.terrain_image.duplicate()
	var spawn := PlayerState.spawn(generated, heights)
	var saved := {player = {x = spawn.x, z = spawn.z, feet = spawn.feet, yaw = 0.0, pitch = 0.0, hour = 9.0},
		bike = {x = spawn.x, z = spawn.z, y = spawn.feet, heading = 0.0, riding = false},
		visited = {}, quest = preload("res://scripts/game/quests.gd").new().save_state(), goal = ""}
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	root.add_child(game)
	game.start(loaded, hud, saved)
	check(is_same(game.services, loaded.service_scope) and is_same(game.camera_controller.settings, game.services.settings)
		and is_same(game.vegetation.settings, game.services.settings), "scene inherits the loader's isolated scope")
	var before := game.yaw
	game.look(10.0, 0.0)
	check(is_equal_approx(game.yaw - before, -10.0 * GameConfig.MOUSE * 2.0), "camera uses the injected sensitivity")
	await process_frame
	await process_frame
	game.set_paused(true)
	check(preload("res://scripts/game/save_game.gd").valid(game.save_state()), "composed scene produces a compatible save")
	game.free()
	hud.free()
	# Flush queued child deletions and renderer cleanup before stopping the SceneTree.
	await process_frame
	await process_frame
	print("architecture_test: %d failures" % failures)
	quit(1 if failures else 0)
