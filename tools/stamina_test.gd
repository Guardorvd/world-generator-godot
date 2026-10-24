extends SceneTree
## 14.0: изолированная проверка выносливости (Stamina) и подписей геймпада (Controls) без мира:
## за сколько секунд пустеет полоска с Shift и без него на ровном, в подъём и под уклон, за сколько
## восстанавливается накатом и пешком. Запуск из папки проекта:
##   godot --headless --path . --script res://tools/stamina_test.gd

const DT := 1.0 / 60.0

var _fails := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		print("✓ " + what)
	else:
		printerr("✗ " + what)
		_fails += 1


## Сколько секунд от полной до пустой при постоянной езде
func _drain_time(boost: bool, speed: float, grade: float) -> float:
	var s := Stamina.new()
	var t := 0.0
	while not s.exhausted and t < 600.0:
		s.tick_ride(DT, 1.0, s.can_boost(boost, 1.0), speed, grade, false)
		t += DT
	return t


## Сколько секунд от пустой до полной
func _rest_time(foot: bool) -> float:
	var s := Stamina.new()
	s._spend(1.0)
	var t := 0.0
	while s.value < 1.0 and t < 600.0:
		if foot:
			s.tick_foot(DT, false)
		else:
			s.tick_ride(DT, 0.0, false, 9.0, 0.0, false)
		t += DT
	return t


func _init() -> void:
	var cruise := GameConfig.BIKE_SPEED
	var cases := [
		["Shift по ровному", true, cruise * 1.3, 0.0, 22.5],
		["Shift под уклон", true, cruise * 1.3, -0.15, 30.0],
		["Shift в подъём", true, 5.0, 0.15, 28.8],
		["педали без Shift, крейсерская", false, cruise, 0.0, 90.0],
		["педали без Shift, подъём", false, 5.0, 0.15, 72.0],
	]
	for c in cases:
		var t := _drain_time(c[1], c[2], c[3])
		_check(absf(t - c[4]) < 0.5, "%s: пусто за %.1f с (ждём %.0f)" % [c[0], t, c[4]])
	_check(_drain_time(false, 4.0, 0.0) >= 600.0, "медленно по ровному без Shift — не тратится")
	var coast := _rest_time(false)
	var foot := _rest_time(true)
	_check(absf(coast - 12.0 - Stamina.REST_DELAY) < 0.5, "накатом полная за %.1f с" % coast)
	_check(absf(foot - 8.0 - Stamina.REST_DELAY) < 0.5, "пешком полная за %.1f с" % foot)
	var s := Stamina.new()
	s._spend(1.0)
	_check(not s.can_boost(true, 1.0) and s.pedal_scale() < 1.0, "пустая: Shift выключен, педали слабее")
	for i in int((Stamina.REST_DELAY + Stamina.RECOVERED / Stamina.COAST) / DT) + 2:
		s.tick_ride(DT, 0.0, false, 5.0, 0.0, false)
	_check(s.can_boost(true, 1.0), "после восстановления до %.0f %% Shift снова работает" % (Stamina.RECOVERED * 100.0))
	# подписи: позиционная нижняя кнопка — A у Xbox, B у Nintendo
	Controls.joypad = true
	_check(Controls.label("jump") == "A", "геймпад: прыжок — %s" % Controls.label("jump"))
	_check(Controls.trigger(true) == "RT", "геймпад: педали — %s" % Controls.trigger(true))
	_check(Controls.BUTTONS[Controls.Family.NINTENDO][JOY_BUTTON_A] == "B", "Nintendo: нижняя кнопка — B")
	Controls.joypad = false
	_check(Controls.label("run") == "Shift" and Controls.label("jump") == "Пробел", "клавиатура: Shift, Пробел")
	# сцена игры собирается с новыми вызовами
	_check(load("res://scripts/render/game_world.gd").can_instantiate(), "game_world.gd загружается")
	_check(load("res://scripts/ui/hud.gd").can_instantiate(), "hud.gd загружается")
	print("Итог: %s" % ("всё в порядке" if _fails == 0 else "%d ошибок" % _fails))
	quit(1 if _fails > 0 else 0)
