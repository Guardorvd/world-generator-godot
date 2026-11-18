extends SceneTree
## Изолированный стенд размещения на перекрёстке и на узком берегу. Без генерации мира.
## godot --headless --path . --script res://tools/settlement_courtyard_test.gd

const Courtyard := SettlementsBuilder.Courtyard
const TILE := GameConfig.TILE
const CENTER := Vector2(128.0, 128.0)
var failures := 0


class Ground extends Heightfield:
	var wet_side := false
	var narrow_shore := false

	func _init(w: WorldData) -> void:
		super()
		world = w

	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 12.0

	func depth_at(x: float, z: float, _feet := -INF) -> float:
		if narrow_shore:
			return 0.0 if absf(z - 136.0) <= 2.7 else 1.0
		return 1.0 if wet_side and x > 128.0 else 0.0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 20)
	_run.call_deferred()


func _check(value: bool, msg: String) -> void:
	print("ok   " if value else "FAIL ", msg)
	if not value:
		failures += 1


func _route(a: Vector2, b: Vector2, width_m: float, kind := "road") -> Dictionary:
	return {kind = kind, pts = [
		{x = a.x / TILE, y = a.y / TILE, w = width_m / TILE},
		{x = b.x / TILE, y = b.y / TILE, w = width_m / TILE},
	]}


func _world() -> WorldData:
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = w.W * w.H
	for field in ["temp", "moist", "elev", "slope", "dist_ocean", "dist_water"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		values.fill(200.0 if field.begins_with("dist_") else 0.0)
		w.set(field, values)
	var biomes := PackedByteArray()
	biomes.resize(w.N)
	biomes.fill(Biomes.GRASS)
	w.biome = biomes
	var water := PackedByteArray()
	water.resize(w.N)
	w.river = water
	w.lake = water
	w.ocean = water
	w.settlements = [SettlementData.new(32, 32, 32 * w.W + 32, "Перекрёсток")]
	return w


func _run() -> void:
	var w := _world()
	var ground := Ground.new(w)
	var settlement: SettlementData = w.settlements[0]
	var main := _route(Vector2(45, 128), Vector2(210, 128), 5.0)
	var turn := _route(Vector2(128, 128), Vector2(143, 215), 3.0, "trail")
	w.trails = [main, turn]
	var old := Courtyard.new(w, ground)
	_check(not old.road_clear(CENTER, 0.0), "центр поселения лежит на пересечении путей")
	var yard := old.choose(settlement)
	_check(not yard.is_empty() and yard.benches.size() == 2, "у перекрёстка найден цельный дворик")
	if yard.is_empty():
		quit(1)
		return
	var fire := Vector2(yard.fire.x, yard.fire.z)
	_check(old.road_clear(fire, Courtyard.COMPACT_R), "костёр и запас под весь дворик свободны от дорожного полотна")
	_check(old.choose(settlement) == yard, "размещение повторяется при повторной загрузке")

	ground.wet_side = true
	settlement.huts.append(HutData.new(29, 34.3, 0, "house", PI * 0.25))
	var dry := old.choose(settlement)
	_check(not dry.is_empty() and dry.fire.is_finite() and dry.fire.x < CENTER.x, "учтены берег, тропа и повёрнутый дом")
	settlement.huts.clear()
	ground.wet_side = false

	_check_integration(w, ground, settlement, yard)
	w.trails = [main]
	ground.narrow_shore = true
	var shore := Courtyard.new(w, ground).choose(settlement)
	_check(not shore.is_empty() and shore.benches.is_empty() and not shore.fire.is_finite(), "в тесноте сохраняется доступная доска")
	print("settlement_courtyard: ", failures, " failures")
	quit(0 if failures == 0 else 1)


func _check_integration(w: WorldData, ground: Heightfield, settlement: SettlementData, yard: Dictionary) -> void:
	var game: GameWorld = preload("res://scenes/game_world.tscn").instantiate()
	root.add_child(game)
	game.world = w
	game.heights = ground
	var buildings := game.get_node("Settlements") as Node3D
	var built := SettlementsBuilder.build(buildings, w, ground)
	if built.boards.size() != 1 or built.fires.size() != 1:
		_check(false, "сборщик вернул одну доску и один костёр")
		game.free()
		return
	game._boards = built.boards
	var board: Transform3D = built.boards[0].at
	var board_foot: Transform3D = yard.board
	_check(board.is_equal_approx(board_foot.translated_local(Vector3.UP * Courtyard.BOARD_HEIGHT))
		and built.fires[0].pos.is_equal_approx(yard.fire), "сборщик отдаёт координаты построенных объектов")
	game.player = PlayerState.new()
	game.bike = BikeRide.new()
	game.crash = BikeCrash.new()
	game.photo = GameWorld.PhotoCamera.new()
	var eye := board.origin + board.basis.z * 2.4
	eye.y = yard.fire.y + GameConfig.EYE
	game.player.x = eye.x
	game.player.z = eye.z
	game.player.feet = yard.fire.y
	game.camera.look_at_from_position(eye, board.origin)
	_check(game._aim().get("place") == settlement, "наведение с площадки попадает в новую доску")

	var key := WorldData.place_id("settlement", settlement.x, settlement.y)
	game.quests = preload("res://scripts/game/quests.gd").new()
	var quest := QuestData.new("test", "delivery", key)
	quest.steps.append({do = "pickup", place = {key = key}})
	game.quests.active = quest
	game._sync_delivery_bag()
	var bag := board * Courtyard.BAG_OFFSET
	_check(game._bag != null and Vector2(game._bag.position.x, game._bag.position.z).is_equal_approx(Vector2(bag.x, bag.z)),
		"сумка появляется у правой стойки новой доски")
	game.audio.setup(w, ground)
	game.audio.fires = built.fires
	game.audio._sample(yard.fire)
	_check(game.audio._fire.position.is_equal_approx(yard.fire + Vector3.UP * 0.5), "звук привязан к перенесённому костру")
	game.audio._fire.stop()
	game.photo.free()
	game.crash.free()
	game.free()
