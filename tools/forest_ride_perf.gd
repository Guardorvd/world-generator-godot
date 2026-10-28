extends SceneTree
## Езда на велосипеде через самый густой лес мира (7.7): FPS, столкновения со стволами, падения.
## Нужно окно: godot --path . --script res://tools/forest_ride_perf.gd -- [--seed Север-1234] [--size 512] [--off]
## --off — без препятствий леса, для сравнения.

const Dev := preload("res://tools/control/control.gd")
const RIDE_S := 15.0

var main: Node
var frames := 0
var phase := "menu"
var t := 0.0
var last_us := 0
var ms := PackedFloat32Array()
var path := 0.0
var crashes := 0
var blocked := 0.0
var last := Vector2()


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _process(delta: float) -> bool:
	frames += 1
	var game: GameWorld = main.game
	match phase:
		"menu":
			if frames == 1:
				DisplayServer.window_set_size(Dev.WINDOW_SIZE)
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
				Engine.max_fps = 0
			if frames == 30:
				main.start_game(Dev.arg("seed", "Север-1234"), int(Dev.arg("size", "512")))
				phase = "loading"
		"loading":
			if game == null or game.player == null:
				return false
			_enter_forest(game)
			if "--off" in OS.get_cmdline_user_args():
				game.heights.obstacles = _Off.new(game.world, game.heights)
			Input.action_press("move_forward")
			phase = "ride"
			last_us = Time.get_ticks_usec()
			last = Vector2(game.player.x, game.player.z)
		"ride":
			t += delta
			var now := Time.get_ticks_usec()
			if t > 1.5:
				ms.append((now - last_us) / 1000.0)
			last_us = now
			var p := Vector2(game.player.x, game.player.z)
			var d := p.distance_to(last)
			path += d
			last = p
			blocked = blocked + delta if d < 0.01 and not game.crash.active() else 0.0
			# упёрлись — поворачиваем, как игрок
			if blocked > 0.3 or fmod(t, 3.0) < 0.4:
				Input.action_press("move_right")
			else:
				Input.action_release("move_right")
			if _new_crash(game):
				crashes += 1
			if t > RIDE_S:
				_report(game)
				quit(0)
	return false


var _was_crash := false
func _new_crash(game: GameWorld) -> bool:
	var now: bool = game.crash.active()
	var fresh := now and not _was_crash
	_was_crash = now
	return fresh


class _Off extends ForestObstacles:
	func update(_px: float, _pz: float, _d: PackedFloat32Array, _v: int, _f := false) -> void:
		pass


## Игрок с велосипедом в середину самого густого лесного чанка
func _enter_forest(game: GameWorld) -> void:
	var w := game.world
	var best := 0
	var best_n := -1
	for c in w.chunks.size():
		var n := 0
		for o in w.chunks[c]:
			if Biomes.is_tree(w.obj_k[o]) and w.obj_s[o] >= ForestObstacles.MIN_SCALE:
				n += 1
		if n > best_n:
			best_n = n
			best = c
	var side := w.CS * GameConfig.TILE
	var p := game.player
	p.x = (best % w.CW + 0.5) * side
	p.z = (best / w.CW + 0.5) * side
	p.feet = game.heights.ground_at(p.x, p.z)
	game.heights.obstacles.update(p.x, p.z, PackedFloat32Array(), -1, true)
	game.vegetation.update(p.x, p.z, true)
	game.heights.obstacles.update(p.x, p.z, game.vegetation.obstacles, game.vegetation.obstacles_version, true)
	game.bike = BikeRide.park_near(p, game.yaw, w, game.heights)
	game.bike.mount(p)
	game.yaw = game.bike.heading
	game._snap()
	print("Лес: чанк %d, крупных деревьев %d, препятствий рядом %d" % [best, best_n, game.heights.obstacles.data.size() / ForestObstacles.STRIDE])


func _report(game: GameWorld) -> void:
	var sorted := ms.duplicate()
	sorted.sort()
	var sum := 0.0
	for v in ms:
		sum += v
	var avg := sum / maxi(1, ms.size())
	var low1: float = sorted[mini(sorted.size() - 1, int(sorted.size() * 0.99))]
	print("FPS %.0f, 1%% худших кадров %.1f мс, худший %.1f мс; путь %.0f м, падений %d" % [1000.0 / avg, low1, sorted[sorted.size() - 1], path, crashes])
