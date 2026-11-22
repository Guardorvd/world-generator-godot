extends SceneTree
## Сводка при удержании и появление шкалы сил на пороге рывка.

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
	var bike := BikeRide.new()
	bike.riding = true
	bike.speed = 7.5
	bike.brakes.pressure = 0.8
	bike.brakes.risk = 0.95
	hud.set_brakes(bike)
	hud.set_stamina(Stamina.DASH_COST, false, Stamina.State.DRAIN)
	hud.pulse_pump()
	check(not hud._ride.visible, "торможение, памп и трата сил выше порога не раскрывают HUD")
	hud.set_stamina(Stamina.DASH_COST - 0.01, true, Stamina.State.COAST)
	check(hud._ride.visible and hud._ride.details_alpha == 0.0, "ниже порога рывка видна только шкала сил, включая восстановление")
	hud.set_stamina(Stamina.RECOVERED, false, Stamina.State.COAST)
	check(not hud._ride.visible, "шкала скрывается, когда рывок снова доступен")

	hud._summary_held = true
	hud._process(Hud.SUMMARY_FADE * 0.25)
	check(not hud._ride.visible, "короткое нажатие оставляет интерфейс скрытым")
	hud._process(Hud.SUMMARY_FADE * 0.5)
	check(hud._ride.visible and hud._ride.modulate.a < 1.0, "прибор плавно проявляется")
	hud._process(Hud.SUMMARY_FADE)
	check(is_equal_approx(hud._ride.modulate.a, 1.0), "при удержании сводка остаётся видимой")
	hud._summary_held = false
	hud._process(Hud.SUMMARY_HIDE * 0.2)
	var fading := hud._ride.modulate.a
	check(fading > 0.0 and fading < 1.0, "отпускание сразу запускает затухание")
	hud._summary_held = true
	hud._process(Hud.SUMMARY_FADE * 0.1)
	check(hud._ride.modulate.a > fading, "повторное удержание разворачивает затухание")
	hud.set_summary_blocked(true)
	check(not hud._ride.visible and not hud._summary_held, "блокировка скрывает сводку и сбрасывает удержание")

	main.queue_free()
	await process_frame
	print("Ride peek failures: ", failures)
	quit(1 if failures else 0)
