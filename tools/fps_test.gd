extends SceneTree
## Проверка независимости от частоты кадров: запускает игру как игрок и при разных ограничениях FPS
## (Engine.max_fps) из одной и той же точки идёт, едет на велосипеде и прыгает, держа клавиши одно и то же
## реальное время. Пройденный путь, скорость, высота прыжка и ход игрового времени должны совпадать,
## а камера на ходу — двигаться в каждом кадре, а не рывками раз в такт физики.
## Запуск из папки проекта (с окном или без):
##   godot --headless --path . --script res://tools/fps_test.gd -- [--fps 10,30,60,144,0]

const HOLD := 2.0          # сколько секунд держать «вперёд»
const TOLERANCE := 0.06    # допустимое отличие от прогона без ограничения FPS (доля)

enum { LOADING, SETTLE, WALK, BIKE, JUMP, DONE }

var main: Node
var game: GameWorld
var fps_list: Array[int] = [10, 30, 60, 144, 0]
var k := 0
var phase := LOADING
var t0 := 0
var frames := 0
var game_t0 := 0.0
var start := {}           # точка, откуда начинается каждый прогон
var res := {}             # fps -> {walk, bike, jump, clock, frames}
var cur := {}
var apex := 0.0
var cam_last := Vector3()
var still := 0            # кадров на ходу, в которых камера не сдвинулась
var walked := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	var args := OS.get_cmdline_user_args()
	for a in args.size() - 1:
		if args[a] == "--fps":
			fps_list.clear()
			for s in args[a + 1].split(","):
				fps_list.append(int(s))
	# с окном частоту кадров ограничивает только Engine.max_fps, а не частота монитора
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _now() -> float:
	return (Time.get_ticks_usec() - t0) / 1e6


## Поставить игрока в начальную точку пешком, лицом от костра
func _reset() -> void:
	if game.bike.riding:
		game.toggle_bike()
	var p := game.player
	p.x = start.x
	p.z = start.z
	p.feet = start.feet
	p.vx = 0.0
	p.vz = 0.0
	p.vy = 0.0
	p.on_ground = true
	game.yaw = start.yaw
	game.pitch = 0.0


func _begin(next: int) -> void:
	phase = next
	t0 = Time.get_ticks_usec()
	frames = 0
	game_t0 = game.time


func _process(_delta: float) -> bool:
	if phase == DONE:
		return false
	if phase == LOADING:
		# меню готово только после первого кадра
		if not start.has("asked"):
			start.asked = true
			main.start_game("Север-1234", 256)
		game = main.game
		if game == null or game.player == null:
			return false
		start = {x = game.player.x, z = game.player.z, feet = game.player.feet, yaw = game.yaw + PI}
		Engine.max_fps = fps_list[0]
		_reset()
		_begin(SETTLE)
		return false
	frames += 1
	var p := game.player
	match phase:
		SETTLE:
			# полсекунды на новом ограничении FPS, чтобы кадры выровнялись
			if _now() > 0.5:
				_reset()
				cur = {}
				Input.action_press("move_forward")
				_begin(WALK)
		WALK:
			# после разгона камера должна сдвигаться каждый кадр
			var cam := game.camera.global_position
			if _now() > 0.5:
				walked += 1
				if cam.distance_to(cam_last) < 1e-5:
					still += 1
			cam_last = cam
			if _now() >= HOLD:
				Input.action_release("move_forward")
				cur.walk = Vector2(p.x - start.x, p.z - start.z).length() / _now()
				cur.clock = (game.time - game_t0) / _now()
				cur.frames = frames / _now()
				cur.still = float(still) / maxi(walked, 1)
				still = 0
				walked = 0
				_reset()
				game.bike.x = start.x
				game.bike.z = start.z
				game.bike.y = start.feet
				game.bike.heading = start.yaw
				game.toggle_bike()
				Input.action_press("move_forward")
				_begin(BIKE)
		BIKE:
			if _now() >= HOLD:
				Input.action_release("move_forward")
				cur.bike = Vector2(p.x - start.x, p.z - start.z).length() / _now()
				_reset()
				apex = 0.0
				Input.action_press("jump")
				_begin(JUMP)
		JUMP:
			if _now() > 0.15:
				Input.action_release("jump")
			apex = maxf(apex, p.feet - start.feet)
			if _now() >= 1.2:
				cur.jump = apex
				res[fps_list[k]] = cur
				print("FPS %4s: кадров в секунду %5.0f, шаг %.2f м/с, велосипед %.2f м/с, прыжок %.2f м, игровое время %.3f с за секунду, камера стоит в %.0f %% кадров" % [
					str(fps_list[k]) if fps_list[k] > 0 else "без", cur.frames, cur.walk, cur.bike, cur.jump, cur.clock, cur.still * 100.0])
				k += 1
				if k == fps_list.size():
					return _finish()
				Engine.max_fps = fps_list[k]
				_reset()
				_begin(SETTLE)
	return false


func _finish() -> bool:
	var base: Dictionary = res[fps_list[-1]]
	var fails := 0
	for f in fps_list:
		var r: Dictionary = res[f]
		for key in ["walk", "bike", "jump", "clock"]:
			var d := absf(r[key] - base[key]) / maxf(absf(base[key]), 0.001)
			if d > TOLERANCE:
				printerr("✗ FPS %d: %s отличается на %.0f %%" % [f, key, d * 100.0])
				fails += 1
		if r.still > 0.05:
			printerr("✗ FPS %d: на ходу камера стоит в %.0f %% кадров (рывки)" % [f, r.still * 100.0])
			fails += 1
	if fails == 0:
		print("✓ Движение, прыжок и игровое время одинаковы при всех FPS (в пределах %.0f %%), камера движется плавно" % (TOLERANCE * 100.0))
	Engine.max_fps = 0
	phase = DONE
	_cleanup_and_quit.call_deferred(1 if fails > 0 else 0)
	return false


func _cleanup_and_quit(code: int) -> void:
	# Выгружаем мир как игрок: фоновые задачи завершаются до остановки дерева.
	main._back_to_menu()
	game = null
	await process_frame
	main.queue_free()
	main = null
	await process_frame
	quit(code)
