extends SceneTree
## Проверка движения без окна: разгон и остановка шага, прыжок с запасом (COYOTE, JUMP_BUFFER),
## начало разгона велосипеда, мягкое и жёсткое приземление. Запуск из папки проекта:
##   godot --headless --path . --script res://tools/feel_test.gd

const DT := 1.0 / 60.0

var _fails := 0


func _check(ok: bool, what: String) -> void:
	print(("✓ " if ok else "✗ ") + what)
	if not ok:
		_fails += 1


func _init() -> void:
	var w := WorldGenerator.generate("Север-1234", 256)
	var heights := Heightfield.new(w)
	var p := PlayerState.spawn(w, heights)

	# Шаг: до полной скорости меньше чем за 0.2 с, остановка меньше чем за 0.3 с
	var t := 0.0
	while p.ground_speed() < GameConfig.WALK * PlayerState.terrain_speed(w, p.x, p.z) * 0.95 and t < 1.0:
		p.step(1.0, 0.0, false, false, 0.0, DT, w, heights)
		t += DT
	_check(t < 0.2, "разгон шага за %.2f с" % t)
	t = 0.0
	while p.ground_speed() > 0.0 and t < 1.0:
		p.step(0.0, 0.0, false, false, 0.0, DT, w, heights)
		t += DT
	_check(t < 0.3, "остановка за %.2f с" % t)

	# Пробел за 0.1 с до касания земли — прыжок при касании
	p.step(0.0, 0.0, false, true, 0.0, DT, w, heights)
	var jumps := 1 if p.vy > 0.0 else 0
	var pressed := false
	for k in 240:
		var falling := not p.on_ground and p.vy < 0.0 and p.feet - heights.ground_at(p.x, p.z) < 0.6
		var press := falling and not pressed
		pressed = pressed or press
		var vy0 := p.vy
		p.step(0.0, 0.0, false, press, 0.0, DT, w, heights)
		if p.vy > 0.0 and vy0 <= 0.0:
			jumps += 1
	_check(jumps == 2, "пробел перед приземлением срабатывает (прыжков: %d из 2)" % jumps)

	# Велосипед: с места за полсекунды больше 2,5 м/с, в 1.6 было 2 (рельеф у поселения холмистый, поэтому только начало разгона)
	var b := BikeRide.park_near(p, 0.0, w, heights)
	b.mount(p)
	for k in 30:
		b.step(p, 1.0, 0.0, false, false, DT, w, heights)
	_check(b.speed > 2.5, "велосипед за 0.5 с разгоняется до %.1f м/с" % b.speed)
	# Падение с 2 м и с 20 м
	for drop in [2.0, 20.0]:
		b.speed = 0.0
		b.crashed = false
		b.airborne = true
		b.vy = 0.0
		b.y = heights.ground_at(b.x, b.z) + drop
		for k in 300:
			b.step(p, 0.0, 0.0, false, false, DT, w, heights)
			if not b.airborne:
				break
		_check(b.crashed == (drop > 5.0), "падение с %d м: %s" % [drop, "упал" if b.crashed else "удержался"])

	print("Все проверки прошли." if _fails == 0 else "Не прошло проверок: %d" % _fails)
	quit(1 if _fails > 0 else 0)
