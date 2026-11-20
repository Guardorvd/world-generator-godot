extends SceneTree
## Временный показ прибора в лёгком режиме и прерывание затухания.

var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	print(("OK " if ok else "FAIL ") + message)
	if not ok:
		failures += 1


func _run() -> void:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	var hud: Hud = main.get_node("%Hud")
	main.get_node("%Menu").hide()
	hud.show()
	hud.set_process(false)
	hud.view_mode = Hud.View.LIGHT
	hud._summary_progress = 0.0
	hud._ride.state = Stamina.State.IDLE
	hud._ride.risk = 0.0
	hud._ride.skid = 0.0
	hud._tick_ride_peek(0.1)
	hud._show_ride()
	check(not hud._ride.visible, "без действия прибор скрыт")

	hud.set_ride_activity(true)
	hud._tick_ride_peek(Hud.RIDE_PEEK_IN * 0.5)
	hud._show_ride()
	check(hud._ride.visible and hud._ride.modulate.a > 0.0 and hud._ride.modulate.a < 1.0, "прибор плавно появляется")
	hud._tick_ride_peek(Hud.RIDE_PEEK_HOLD * 2.0)
	check(is_equal_approx(hud._ride_peek, 1.0) and is_equal_approx(hud._ride_peek_left, Hud.RIDE_PEEK_HOLD), "удержание не даёт прибору погаснуть")
	hud.set_ride_activity(false)
	hud._tick_ride_peek(Hud.RIDE_PEEK_HOLD * 0.5)
	check(is_equal_approx(hud._ride_peek, 1.0), "после отпускания прибор остаётся видимым")
	hud._tick_ride_peek(Hud.RIDE_PEEK_HOLD * 0.5 + Hud.RIDE_PEEK_OUT * 0.4)
	var fading: float = hud._ride_peek
	check(fading > 0.0 and fading < 1.0, "после задержки прибор плавно гаснет")
	hud.set_ride_activity(true)
	hud._tick_ride_peek(Hud.RIDE_PEEK_IN * 0.2)
	check(hud._ride_peek > fading and hud._ride_peek <= 1.0 and is_equal_approx(hud._ride_peek_left, Hud.RIDE_PEEK_HOLD), "повторное нажатие разворачивает затухание без скачка")
	hud.set_ride_activity(false)
	hud._tick_ride_peek(Hud.RIDE_PEEK_HOLD + Hud.RIDE_PEEK_OUT)
	hud._show_ride()
	check(not hud._ride.visible, "после задержки и затухания прибор скрыт")

	hud.set_ride_activity(true)
	hud._tick_ride_peek(Hud.RIDE_PEEK_IN)
	hud.set_summary_blocked(true)
	hud._tick_ride_peek(0.1)
	hud._show_ride()
	check(not hud._ride.visible and hud._ride_peek == 0.0 and hud._ride_peek_left == 0.0, "блокировка сразу скрывает и сбрасывает временный показ")
	hud.set_summary_blocked(false)
	hud.view_mode = Hud.View.HIDDEN
	hud.set_ride_activity(true)
	hud._tick_ride_peek(1.0)
	hud._show_ride()
	check(not hud._ride.visible and hud._ride_peek == 0.0, "скрытый режим не включает временный показ")
	hud.view_mode = Hud.View.FULL
	hud._summary_progress = 1.0
	hud._tick_ride_peek(1.0)
	hud._show_ride()
	check(hud._ride.visible and is_equal_approx(hud._ride.modulate.a, 1.0), "в полной сводке прибор виден постоянно")
	main.queue_free()
	await process_frame
	print("Ride peek failures: ", failures)
	quit(1 if failures else 0)
