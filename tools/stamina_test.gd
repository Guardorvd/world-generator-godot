extends SceneTree
## 14.0: изолированная проверка выносливости (Stamina) и подписей геймпада (Controls) без мира.
## 15.0: рывок Shift (треть полоски по нажатию), восстановление, скорость в подъём (BikeRide._step_speed). Запуск из папки проекта:
##   godot --headless --path . --script res://tools/stamina_test.gd

const DT := 1.0 / 60.0

var _fails := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		print("✓ " + what)
	else:
		printerr("✗ " + what)
		_fails += 1


## Сколько секунд от пустой до полной: pedal — на педалях, foot — пешком, иначе накатом
func _rest_time(mode: String) -> float:
	var s := Stamina.new()
	s.value = 0.0
	var t := 0.0
	while s.value < 1.0 and t < 600.0:
		if mode == "foot":
			s.tick_foot(DT, false)
		else:
			s.tick_ride(DT, false, 1.0 if mode == "pedal" else 0.0, false)
		t += DT
	return t


## Установившаяся скорость велосипеда (м/с) на уклоне без мира: только продольная модель _step_speed
func _steady(slope: float, surge := 0.0) -> float:
	var b := BikeRide.new()
	b.contact_model = false
	b.surge = surge
	for i in int(60.0 / DT):
		b._step_speed(1.0, surge > 0.0, slope, 1.0, DT)
	return b.speed


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	# 15.0: рывок по нажатию — треть полоски, прилив SURGE_TIME, удержание Shift больше ничего не берёт
	var s := Stamina.new()
	s.tick_ride(DT, true, 1.0, false)
	_check(absf(s.value - 2.0 / 3.0) < 0.001 and s.surge() > 0.99, "нажатие Shift: треть полоски, прилив в полную силу")
	for i in int((Stamina.SURGE_TIME + 1.0) / DT):
		s.tick_ride(DT, true, 1.0, false)
	_check(s.surge_left == 0.0 and s.value > 2.0 / 3.0 - 0.001, "удержание Shift: прилив кончился за %.0f с, полоска не тратится" % Stamina.SURGE_TIME)
	var d := Stamina.new()
	var dashes := 0
	for k in 4:
		var before := d.value
		d.tick_ride(DT, false, 1.0, false)
		d.tick_ride(DT, true, 1.0, false)
		if d.value < before - 0.3:
			dashes += 1
		d.surge_left = 0.0
	_check(dashes == 3 and d.exhausted, "подряд три рывка, четвёртого нет (рывков: %d)" % dashes)
	var idle := Stamina.new()
	idle.tick_ride(DT, true, 0.0, false)
	_check(idle.value == 1.0 and idle.surge_left == 0.0, "Shift без педалей полоску не берёт")
	var keep := Stamina.new()
	keep.value = 0.5
	for i in int(60.0 / DT):
		keep.tick_ride(DT, false, 1.0, false)
	_check(keep.value >= 1.0, "без Shift на педалях полоска только копится")
	var pedal := _rest_time("pedal")
	var coast := _rest_time("coast")
	var foot := _rest_time("foot")
	_check(absf(pedal - 1.0 / Stamina.PEDAL) < 0.5, "на педалях полная за %.1f с" % pedal)
	_check(absf(coast - 1.0 / Stamina.COAST) < 0.5, "накатом полная за %.1f с" % coast)
	_check(absf(foot - 1.0 / Stamina.REST) < 0.5, "пешком полная за %.1f с" % foot)
	# 15.0: подъём легче — установившаяся скорость в гору на педалях (гравий, без пампа и кочек)
	var flat := _steady(0.0)
	_check(absf(flat - GameConfig.BIKE_SPEED) < 0.6, "по ровному крейсерская прежняя: %.1f км/ч" % (flat * 3.6))
	for slope in [0.1, 0.2, 0.3]:
		var v := _steady(slope)
		print("  подъём %d %%: %.1f км/ч, с рывком %.1f км/ч" % [roundi(slope * 100.0), v * 3.6, _steady(slope, 1.0) * 3.6])
	_check(_steady(0.2) * 3.6 > 22.0, "подъём 20 %% идёт бодро: %.1f км/ч" % (_steady(0.2) * 3.6))
	# подписи: позиционная нижняя кнопка — A у Xbox, B у Nintendo
	GameContext.scope.controls.joypad = true
	_check(GameContext.scope.controls.label("jump") == "A", "геймпад: прыжок — %s" % GameContext.scope.controls.label("jump"))
	_check(GameContext.scope.controls.trigger(true) == "RT", "геймпад: педали — %s" % GameContext.scope.controls.trigger(true))
	_check(Controls.BUTTONS[Controls.Family.NINTENDO][JOY_BUTTON_A] == "B", "Nintendo: нижняя кнопка — B")
	GameContext.scope.controls.joypad = false
	_check(GameContext.scope.controls.label("run") == "Shift" and GameContext.scope.controls.label("jump") == "Пробел", "клавиатура: Shift, Пробел")
	# сцена игры собирается с новыми вызовами
	_check(load("res://scripts/render/game_world.gd").can_instantiate(), "game_world.gd загружается")
	_check(load("res://scripts/ui/hud.gd").can_instantiate(), "hud.gd загружается")
	print("Итог: %s" % ("всё в порядке" if _fails == 0 else "%d ошибок" % _fails))
	quit(1 if _fails > 0 else 0)
