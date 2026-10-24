extends SceneTree
## 5.4: покрытие, затихание шин в полёте, спокойная камера и согласованный руль.

class TestWorld extends WorldData:
	var surface := RoadSurface.PACKED
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = surface}

class TestGround extends Heightfield:
	var depth := 0.0
	var deck := 0.0
	func _init(w: WorldData) -> void:
		super(w, false)
	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 100.0
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return depth
	func deck_at(_x: float, _z: float, _feet := -INF) -> float:
		return 100.0 + deck

var fails := 0

func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	fails += int(not ok)

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var w := TestWorld.new()
	var h := TestGround.new(w)
	var audio := WorldAudio.new()
	root.add_child(audio)
	audio.world = w
	audio.heights = h
	audio._sample_t = 1000.0
	var pos := Vector3(0.0, 100.0, 0.0)
	audio._sample_rolling(pos)
	audio.update(pos, 11.0, true, 1.0)
	var packed_gain: float = audio._goal[audio._roll]
	var packed_pitch: float = audio._roll.pitch_scale
	w.surface = RoadSurface.STONE
	audio._sample_rolling(pos)
	audio.update(pos, 11.0, true, 1.0, 0.5)
	check(audio._goal[audio._roll] > packed_gain and audio._roll.pitch_scale > packed_pitch,
		"камень и поворот слышнее гладкой земли, тембр отличается")
	check(audio._roll_surface == "gravel", "камень даёт тихий хруст")
	h.deck = 1.0
	audio._sample_rolling(pos)
	check(audio._roll_surface == "wood", "настил даёт деревянный отклик")
	h.depth = 0.2
	audio._sample_rolling(pos)
	check(audio._roll_surface == "splash", "брод даёт брызги")
	audio.update(pos, 11.0, false, 1.0)
	check(audio._goal[audio._roll] == 0.0 and audio._roll.volume_db <= WorldAudio.SILENT and audio._contact_dist == 0.0,
		"в полёте шины и касания затихают")
	check(audio._goal.size() == 6, "в звуковом фоне вода, прибой и слои велосипеда (шины, покрытие, трещотка, цепь), без петли ветра")
	audio.free()
	h.depth = 0.0
	h.deck = 0.0
	var view: BikeView = load("res://scenes/bike.tscn").instantiate()
	root.add_child(view)
	var b := BikeRide.new()
	b.riding = true
	b.y = 100.0
	b.speed = 11.0
	b.steer = 1.0
	b.squash = 0.12
	b.squash_f = 0.14
	b.squash_r = 0.1
	var fork_len: float = view._front_struts[0][3]
	view.snap(b)
	view.draw(1.0)
	check(is_equal_approx(view._steering.rotation.y, view.front_wheel.rotation.y), "руль, вилка и колесо поворачиваются вместе")
	check(view.rider.skeleton.get_bone_global_pose(view.rider.skeleton.find_bone("Head")).origin.y < 1.59 and view.rear_wheel.position.y > BikeView.WHEEL_Y,
		"седок группируется, колёса компенсируют сжатие подвески")
	var fork: Node3D = view._front_struts[0][0]
	check(view.front_wheel.position.y > view.rear_wheel.position.y and fork.basis.y.length() * fork_len < fork_len - 0.1,
		"у каждого колеса свой ход, вилка укорачивается на сжатие")
	view.free()
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game.player = PlayerState.new()
	game.player.feet = 100.0
	game.bike = b
	game.heights = h
	game._prev = pos
	game._cam_y = 101.4
	game.pitch = -0.3
	var saved_bob := GameContext.scope.settings.head_bob
	GameContext.scope.settings.head_bob = false
	game._trauma = 1.0
	game._dip = -0.2
	game._update_camera(1.0, 1.0)
	var cam := game.camera.transform
	game.time += 0.5
	game._update_camera(1.0, 1.0)
	check(cam.is_equal_approx(game.camera.transform), "отключённое покачивание убирает удары и работу подвески камеры")
	check(absf(game.camera.rotation.z) < 0.001, "горизонт камеры не кренится вслед за велосипедом")
	GameContext.scope.settings.head_bob = saved_bob
	game.free()
	quit(1 if fails else 0)
