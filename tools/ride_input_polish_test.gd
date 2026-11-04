extends SceneTree
## Переходы ввода без генерации мира; считывание — настоящий Trail Lab, движение перехвачено.
class InputLab extends "res://scripts/lab/trail_lab.gd":
	var command := Vector4.ZERO
	func step_simulation(_dt: float, throttle: float, turn: float, run: bool, jump: bool) -> void:
		command = Vector4(throttle, turn, float(run), float(jump))

var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func run() -> void:
	var c := Controls.new()
	for i in 60:
		c.bike_steer(1, 1.0 / 60, 10)
		c.bike_brake(-1, 1.0 / 60)
	c.joypad = true
	c.device = 7
	c.reset_motion()
	check(c.joypad and c.device == 7, "сброс движения сохраняет устройство и подписи")
	c.joypad = false
	check(c.bike_steer(0, 1.0 / 60) == 0, "после сброса нет остаточного поворота")
	check(absf(c.bike_brake(-1, 1.0 / 60)) < 0.4, "новое торможение начинается с лёгкого нажатия")
	for action in ["move_forward", "bike_pump", "bike_back", "bike_forward", "look_right", "jump"]:
		Input.action_press(action)
	c.release_motion()
	check(not Input.is_action_pressed("bike_pump") and not Input.is_action_pressed("bike_back") and not Input.is_action_pressed("bike_forward"), "потеря фокуса отпускает тело и памп")
	check(c.look_delta(1.0 / 60) == Vector2.ZERO and not Input.is_action_pressed("move_forward") and not Input.is_action_pressed("jump"), "потеря фокуса отпускает обзор и движение")
	var lab := InputLab.new()
	root.add_child(lab)
	lab.set_physics_process(false)
	lab.set_process(false)
	var controls: Controls = lab.services.controls
	controls.joypad = false
	lab.bike.riding = false
	Input.action_press("move_back")
	Input.action_press("move_right")
	lab._physics_process(1.0 / 60)
	check(lab.command.x == -1 and lab.command.y == 1, "пешком назад и вбок — полный прямой ввод")
	lab.bike.riding = true
	lab._physics_process(1.0 / 60)
	check(lab.command.x > -0.4 and lab.command.y > 0 and lab.command.y < 0.5, "на велосипеде сохранено плавное дозирование руля и тормоза")
	lab.editor.visible = true
	lab.autopilot = preload("res://scripts/lab/trail_autopilot.gd").new()
	lab.autopilot.reset(lab.routes[lab.lane], lab.heights, 0)
	lab._physics_process(1.0 / 60)
	check(lab.command == Vector4.ZERO, "редактор снимает накопленный поворот и блокирует автопилот")
	lab.editor.visible = false
	lab.overview = true
	lab._physics_process(1.0 / 60)
	check(lab.command == Vector4.ZERO, "обзор сверху не передаёт движение велосипеду")
	lab.autopilot = null
	controls.release_motion()
	lab.overview = false
	lab._physics_process(1.0 / 60)
	check(lab.command == Vector4.ZERO, "возврат управления не возобновляет старые команды")
	check(load("res://scripts/render/game_world.gd").can_instantiate(), "игровая сцена разбирается с общим сбросом ввода")
	lab.shutdown()
	lab.queue_free()
	await process_frame
	print("ride_input: ", failures, " failures")
	quit(1 if failures else 0)
