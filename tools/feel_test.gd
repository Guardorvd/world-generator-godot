extends SceneTree
## Проверка движения без окна: разгон и остановка шага, прыжок с запасом (COYOTE, JUMP_BUFFER),
## начало разгона велосипеда, мягкое и жёсткое приземление, проход по мостам и туннелям. Запуск из папки проекта:
##   godot --headless --path . --script res://tools/feel_test.gd

const DT := 1.0 / 60.0

var _fails := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		print("✓ " + what)
	else:
		printerr("✗ " + what)
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

	# Мосты и туннели: каждый пешком и на велосипеде по оси от начала до конца, не падая с настила
	var kinds := {}
	for c in [["abc", 128], ["Туман-4821", 192], ["Север-1234", 256]]:
		var w2 := WorldGenerator.generate(c[0], c[1])
		var h2 := Heightfield.new(w2)
		var ok := 0
		for st: Dictionary in h2.structures:
			kinds[st.tunnel] = true
			var name := "туннель" if st.tunnel else "мост"
			for ride in [false, true]:
				if _cross(w2, h2, st, ride):
					ok += 1
				else:
					print("  %s %d м %s не пройден" % [name, roundi(st.len), "на велосипеде" if ride else "пешком"])
		_check(ok == h2.structures.size() * 2, "%s@%d: мостов %d, туннелей %d, пройдено пешком и на велосипеде %d из %d" % [c[0], c[1], w2.bridges.size(), w2.tunnels.size(), ok, h2.structures.size() * 2])
	_check(kinds.size() == 2, "есть и мосты, и туннели")

	if _fails == 0:
		print("Все проверки прошли.")
	else:
		printerr("Не прошло проверок: %d" % _fails)
	quit(1 if _fails > 0 else 0)


## Пройти или проехать сооружение s по оси от точки за 2 м до начала до точки за 2 м после конца.
## true, если дошли и всё время держались на высоте настила или пола (не провалились, не взлетели)
func _cross(w: WorldData, heights: Heightfield, s: Dictionary, ride: bool) -> bool:
	var yaw := atan2(-s.ux, -s.uz)
	var p := PlayerState.new()
	p.x = s.ax - s.ux * 2.0
	p.z = s.az - s.uz * 2.0
	p.feet = heights.surface_at(p.x, p.z, s.ay)
	var b := BikeRide.new()
	if ride:
		b.x = p.x
		b.z = p.z
		b.y = p.feet
		b.heading = yaw
		b.mount(p)
	for k in 60 * 120:
		if ride:
			b.step(p, 0.5, 0.0, false, false, DT, w, heights)
		else:
			p.step(1.0, 0.0, false, false, yaw, DT, w, heights)
		var t: float = (p.x - s.ax) * s.ux + (p.z - s.az) * s.uz
		if t > s.len + 2.0:
			return true
		# у концов настил может уходить под берег, а пол туннеля — под землю у входа
		if t > 3.0 and t < s.len - 3.0:
			var level := heights.level(s, t)
			if p.feet < level - 0.6 or (s.tunnel and p.feet > level + 0.6):
				print("  на %.0f м из %.0f: ноги на %.1f м, настил или пол на %.1f м" % [t, s.len, p.feet, level])
				return false
	var t: float = (p.x - s.ax) * s.ux + (p.z - s.az) * s.uz
	print("  не дошли: застряли на %.1f м из %.0f, ноги на %.1f м, вода %.1f м, стена %s" % [t, s.len, p.feet, heights.depth_at(p.x, p.z, p.feet), heights.wall_at(p.x, p.z, p.feet)])
	return false
