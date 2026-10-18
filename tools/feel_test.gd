extends SceneTree
## Проверка движения без окна: разгон и остановка шага, прыжок с запасом (COYOTE, JUMP_BUFFER),
## начало разгона велосипеда, мягкое и жёсткое приземление, проход по мостам и туннелям, линии дорог и троп
## на их клетках и не в глубокой воде. Запуск из папки проекта:
##   godot --headless --path . --script res://tools/feel_test.gd

const DT := 1.0 / 60.0
const BODY_REACH := 0.1     # пешеход: запас до стены на центр и камеру, м
const WHEEL_REACH := 0.87   # край колеса от середины велосипеда: ось в 0,53 м, радиус колеса 0,34 м

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

	# Шаг: до полной скорости меньше чем за 0.2 с, остановка меньше чем за 0.3 с. Идём в самую ровную
	# из восьми сторон, где нет дома: в подъём шаг медленнее, и проверка была бы про рельеф, а не про разгон
	var walk_yaw := 0.0
	var flattest := INF
	for k in 8:
		var a := k * PI / 4.0
		var ok := true
		for d in [1.0, 2.0, 3.0]:
			ok = ok and PlayerState.is_passable(w, heights, p.x - sin(a) * d, p.z - cos(a) * d, p.feet)
		var rise := absf(heights.ground_at(p.x - sin(a) * 3.0, p.z - cos(a) * 3.0) - p.feet)
		if ok and rise < flattest:
			flattest = rise
			walk_yaw = a
	var t := 0.0
	while p.ground_speed() < GameConfig.WALK * PlayerState.terrain_speed(w, p.x, p.z) * 0.95 and t < 1.0:
		p.step(1.0, 0.0, false, false, walk_yaw, DT, w, heights)
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
	# С 3.1 дополнительно проверяем сооружения среди высоких гор среднего «Север-1234»
	for c: Array in [["abc", 128], ["Туман-4821", 192], ["Север-1234", 256], ["Ущелье", 512], ["Север-1234", 512]]:
		var w2 := WorldGenerator.generate(c[0], c[1])
		var h2 := Heightfield.new(w2)
		# как в игре: за краем карты есть земля (мост бывает и у самого края)
		w2.outer = OuterLand.new(w2)
		var ok := 0
		for st: Dictionary in h2.structures:
			kinds[st.tunnel] = true
			var name := "туннель" if st.tunnel else "мост"
			for ride: bool in [false, true]:
				if _cross(w2, h2, st, ride):
					ok += 1
				else:
					print("  %s %d м %s не пройден" % [name, roundi(st.len), "на велосипеде" if ride else "пешком"])
		_check(ok == h2.structures.size() * 2, "%s@%d: мостов %d, туннелей %d, пройдено пешком и на велосипеде %d из %d" % [c[0], c[1], w2.bridges.size(), w2.tunnels.size(), ok, h2.structures.size() * 2])
		# узкие препятствия: в перила и стены с середины сооружения под разными углами, на полной скорости
		var leaks := 0
		for st: Dictionary in h2.structures:
			if st.len < 12.0:
				continue
			for deg in [15.0, 45.0, 90.0]:
				for sd in [-1.0, 1.0]:
					for ride: bool in [false, true]:
						leaks += _into_wall(w2, h2, st, deg_to_rad(deg) * sd, ride, DT)
		# длинный такт (4 в секунду): тело всё равно не перепрыгивает перила и стены
		for st: Dictionary in h2.structures:
			if st.len >= 12.0:
				leaks += _into_wall(w2, h2, st, PI / 2.0, false, 0.25)
		_check(leaks == 0, "%s@%d: в перила и стены не входят ни пешеход, ни колёса велосипеда (нарушений %d)" % [c[0], c[1], leaks])
		var off := _off_structures(w2, h2)
		_check(off == 0, "%s@%d: дороги и тропы у мостов и туннелей идут по настилу и полу, а не рядом (мест вне их: %d)" % [c[0], c[1], off])
		var lines := _line_vs_cells(w2, h2)
		_check(lines[0] == 0, "%s@%d: нарисованные дороги и тропы лежат на их клетках (скорость, без деревьев; мест вне них: %d)" % [c[0], c[1], lines[0]])
		_check(lines[1] == 0, "%s@%d: дороги и тропы не уходят в глубокую воду мимо мостов (мест: %d)" % [c[0], c[1], lines[1]])
	_check(kinds.size() == 2, "есть и мосты, и туннели")

	# дома: идём и едем прямо в каждый дом поселения появления с восьми сторон
	var hut_hits := 0
	var huts := 0
	for u in PlayerState.home(w).huts:
		huts += 1
		for k in 8:
			for ride: bool in [false, true]:
				hut_hits += _into_hut(w, heights, PlayerState.home(w), u, k * PI / 4.0, ride)
	_check(huts > 0 and hut_hits == 0, "в стены %d домов не входят ни пешеход, ни колёса велосипеда (нарушений %d)" % [huts, hut_hits])

	# Быстрое перемещение (с 2.8): в каждое место карты (с 2.9 и на берег озера) игрок встаёт на свободную сушу рядом с ним,
	# место сразу считается открытым, а цель путешествия там снимается
	var hud := Hud.new()
	hud.world = w
	var arrived := 0
	var all := hud.places()
	for pl: Dictionary in all:
		var q := PlayerState.arrive(w, heights, pl)
		var visited := {}
		q.check_discoveries(w, visited)
		# у озера игрок встаёт на берег, а не к середине (с 2.9)
		var at := Vector2(pl.src.sx, pl.src.sy) if pl.kind == "lake" else Vector2(pl.x, pl.y)
		var near := Grid.hypot(q.x - at.x * GameConfig.TILE, q.z - at.y * GameConfig.TILE) < 60.0
		hud.goal = pl
		if near and visited.has(pl.key) and PlayerState.is_passable(w, heights, q.x, q.z, q.feet, PlayerState.BODY_R) and hud.check_goal(q.x, q.z) != "":
			arrived += 1
	hud.free()
	_check(all.size() > 0 and arrived == all.size(), "быстрое перемещение: в %d из %d мест игрок встаёт на сушу, место открыто, цель достигнута" % [arrived, all.size()])

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
	var b := _bike_for(p, yaw, ride)
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


## Сколько раз линия дороги или тропы между поселениями, проходя вдоль моста или туннеля (в его полосе
## с перилами или стенами, дальше 3 м от концов), сходит с настила или пола: в глубокую воду рядом с мостом,
## в перила или в стену
func _off_structures(w: WorldData, heights: Heightfield) -> int:
	# у самых концов дорога, подходящая сбоку, срезает угол по краю настила: это стык, а не путь мимо
	const END := 3.0
	var count := 0
	for tr in w.trails:
		if tr.kind != "road" and tr.kind != "trail":
			continue
		var pts: Array = tr.pts
		var off := false
		for k in range(1, pts.size()):
			var a := Vector2(pts[k - 1].x, pts[k - 1].y) * GameConfig.TILE
			var b := Vector2(pts[k].x, pts[k].y) * GameConfig.TILE
			var n := maxi(1, ceili(a.distance_to(b) / 0.5))
			for m in n:
				var q := a.lerp(b, float(m) / n)
				var bad := false
				for s: Dictionary in heights.structures:
					var dx: float = q.x - s.ax
					var dz: float = q.y - s.az
					var t: float = dx * s.ux + dz * s.uz
					if t < END or t > s.len - END or absf(dx * s.uz - dz * s.ux) > s.half + Heightfield.WALL:
						continue
					# путь под мостом по дну оврага или над туннелем по горе — не по сооружению, ему перила не мешают
					var feet := heights.level(s, t)
					var g := heights.ground_at(q.x, q.y)
					var along := g > feet - 2.0 and g < feet + Heightfield.TUNNEL_HEIGHT
					bad = heights.depth_at(q.x, q.y, feet) >= GameConfig.FORD_DEPTH or (along and heights.wall_at(q.x, q.y, feet))
					if bad and not off:
						print("  %s у %s %.0f м сходит с него на (%.0f, %.0f)" % [tr.kind, "туннеля" if s.tunnel else "моста", s.len, q.x / GameConfig.TILE, q.y / GameConfig.TILE])
						count += 1
					break
				off = bad
	return count


## Сверка нарисованных линий путей (w.trails, как их рисует MapBaker) с тем, что видит игра: [сколько мест,
## где средняя линия сходит с клеток своего пути в path_mask, сколько мест, где она в воде глубже FORD_DEPTH
## (не на мосту)]. Место — участок подряд идущих точек через 0,5 м
func _line_vs_cells(w: WorldData, heights: Heightfield) -> Array:
	const EDGE := 0.05
	var cells := 0
	var deep := 0
	for tr in w.trails:
		var mark := 1 if tr.kind == "animal" else (3 if tr.kind == "road" else 2)
		var pts: Array = tr.pts
		var was_off := false
		var was_deep := false
		for k in range(1, pts.size()):
			# в клетках и в double: Vector2 хранит float32, и точка на границе клеток попадала бы в соседнюю
			var ax: float = pts[k - 1].x
			var ay: float = pts[k - 1].y
			var bx: float = pts[k].x
			var by: float = pts[k].y
			var n := maxi(1, ceili(Grid.hypot(bx - ax, by - ay) * GameConfig.TILE / 0.5))
			for m in n:
				var f := float(m) / n
				var x := ax + (bx - ax) * f
				var y := ay + (by - ay) * f
				# у самой границы клеток (ближе 0,05 клетки, 20 см) годится и соседняя
				var off := true
				for e in [Vector2(0, 0), Vector2(EDGE, 0), Vector2(-EDGE, 0), Vector2(0, EDGE), Vector2(0, -EDGE)]:
					var info := w.tile_info(x + e.x, y + e.y)
					if info.is_empty() or info.path >= mark:
						off = false
						break
				var dp := heights.depth_at(x * GameConfig.TILE, y * GameConfig.TILE, INF) >= GameConfig.FORD_DEPTH
				if off and not was_off:
					cells += 1
					print("  %s вне своих клеток на (%.0f, %.0f)" % [tr.kind, x, y])
				if dp and not was_deep:
					deep += 1
					print("  %s в воде на (%.0f, %.0f)" % [tr.kind, x, y])
				was_off = off
				was_deep = dp
	return [cells, deep]


## Упереться в перила или стену сооружения s: с середины оси повернуть на angle от неё и 1,5 с идти бегом
## (ride — ехать на велосипеде с разгона 20 м/с) с тактом dt. Возвращает 1, если тело зашло за внутреннюю
## сторону перил или стены (пешеход с запасом 0,1 м на камеру; велосипед — краем колеса) или упало с настила
func _into_wall(w: WorldData, heights: Heightfield, s: Dictionary, angle: float, ride: bool, dt: float) -> int:
	var t0: float = s.len * 0.5
	var yaw: float = atan2(-s.ux, -s.uz) + angle
	var p := PlayerState.new()
	p.x = s.ax + s.ux * t0
	p.z = s.az + s.uz * t0
	p.feet = heights.level(s, t0)
	var b := _bike_for(p, yaw, ride)
	if ride:
		b.speed = 20.0
	# внутренняя сторона модели: перила — брус в 0,1 м за краем настила, стена туннеля — сразу за краем пола
	var face: float = s.half + (0.04 if not s.tunnel else 0.0)
	for k in roundi(1.5 / dt):
		if ride:
			b.step(p, 1.0, 0.0, true, false, dt, w, heights)
		else:
			p.step(1.0, 0.0, true, false, yaw, dt, w, heights)
		var reach := 0.0 if ride else BODY_REACH
		for q in _body_points(p, b, ride):
			var dx: float = q.x - s.ax
			var dz: float = q.y - s.az
			var t: float = dx * s.ux + dz * s.uz
			if t < 1.0 or t > s.len - 1.0:
				continue
			var side := absf(dx * s.uz - dz * s.ux)
			if side > face - reach or p.feet < heights.level(s, t) - 0.6:
				print("  %s %.0f м %s под %d°%s: %.2f м от оси при стенке в %.2f м, ноги %.1f м над настилом" % ["туннель" if s.tunnel else "мост", s.len,
					"на велосипеде" if ride else "пешком", roundi(rad_to_deg(angle)), " (такт %.2f с)" % dt if dt > DT else "", side, face, p.feet - heights.level(s, t)])
				return 1
	return 0


## Идти или ехать в дом u поселения s с направления a (8 м от центра дома). Возвращает 1, если пешеход
## подошёл к стене ближе 0,1 м (камера) или колесо велосипеда вошло в стену
func _into_hut(w: WorldData, heights: Heightfield, s: Dictionary, u: Dictionary, a: float, ride: bool) -> int:
	var hx: float = u.x * GameConfig.TILE
	var hz: float = u.y * GameConfig.TILE
	# дом повёрнут дверью к костру, как в SettlementsBuilder
	var rot := atan2(s.x * GameConfig.TILE - hx, s.y * GameConfig.TILE - hz)
	var p := PlayerState.new()
	p.x = hx + sin(a) * 8.0
	p.z = hz + cos(a) * 8.0
	p.feet = heights.ground_at(p.x, p.z)
	if not PlayerState.is_passable(w, heights, p.x, p.z, p.feet, BikeRide.BODY_R + BikeRide.AXLE):
		return 0   # подойти отсюда не к чему: вода или другой дом
	var yaw := atan2(sin(a), cos(a))   # лицом к дому: вперёд — это -Z, т.е. от (sin, cos) к центру
	var b := _bike_for(p, yaw, ride)
	for k in 120:
		if ride:
			b.step(p, 1.0, 0.0, true, false, DT, w, heights)
		else:
			p.step(1.0, 0.0, true, false, yaw, DT, w, heights)
		var reach := 0.0 if ride else BODY_REACH
		for q in _body_points(p, b, ride):
			var dx := q.x - hx
			var dz := q.y - hz
			# в систему дома: стены — квадрат 3,2 × 3,2 м
			var lx := dx * cos(rot) - dz * sin(rot)
			var lz := dx * sin(rot) + dz * cos(rot)
			if maxf(absf(lx), absf(lz)) - 1.6 < reach:
				print("  дом %s %s с %d°: %.2f м до стены" % [str(Vector2(u.x, u.y)), "на велосипеде" if ride else "пешком",
					roundi(rad_to_deg(a)), maxf(absf(lx), absf(lz)) - 1.6])
				return 1
	return 0


## Велосипед игрока p в его месте и с курсом yaw; если ride — игрок уже сидит на нём
func _bike_for(p: PlayerState, yaw: float, ride: bool) -> BikeRide:
	var b := BikeRide.new()
	if ride:
		b.x = p.x
		b.z = p.z
		b.y = p.feet
		b.heading = yaw
		b.mount(p)
	return b


## Точки тела, которые не должны входить в стены: центр пешехода или края обоих колёс велосипеда
func _body_points(p: PlayerState, b: BikeRide, ride: bool) -> Array[Vector2]:
	if not ride:
		return [Vector2(p.x, p.z)]
	var f := Vector2(-sin(b.heading), -cos(b.heading)) * WHEEL_REACH
	return [Vector2(b.x, b.z) + f, Vector2(b.x, b.z) - f]
