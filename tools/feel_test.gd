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
	if "--downhill" in OS.get_cmdline_user_args():
		_downhill_test.call_deferred()
		return
	if "--opening" in OS.get_cmdline_user_args():
		_opening_test.call_deferred()
		return
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
		var rise := 0.0   # с 4.3 по наибольшему перепаду на первых метрах, а не только в 3 м: у выровненного
		                  # полотна у костра несколько сторон ровные в 3 м, но одна из них сразу идёт в подъём
		for d in [1.0, 2.0, 3.0]:
			ok = ok and PlayerState.is_passable(w, heights, p.x - sin(a) * d, p.z - cos(a) * d, p.feet)
			rise = maxf(rise, absf(heights.ground_at(p.x - sin(a) * d, p.z - cos(a) * d) - p.feet) / d)
		if ok and rise < flattest:
			flattest = rise
			walk_yaw = a
	var t := 0.0
	# Как в PlayerState.step: скорость уточнённой ленты, а не бонус целой клетки пути.
	while p.ground_speed() < GameConfig.WALK * PlayerState.terrain_speed(w, p.x, p.z, heights) * 0.95 and t < 1.0:
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
	# С 3.7 в прежних пяти мирах нет туннелей; «Туман-4821»@512 сохраняет их проверку.
	for c: Array in [["abc", 128], ["Туман-4821", 192], ["Север-1234", 256], ["Ущелье", 512], ["Север-1234", 512], ["Туман-4821", 512]]:
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
	# Поиск 4.0 чаще обходит хребты; контрольные миры могут обходиться без туннелей.
	# Независимый стенд сохраняет проверку прохода и стен туннеля при любой географии.
	var tw := WorldGenerator.generate("abc", 128)
	tw.h.fill(0.1)
	tw.ocean.fill(0)
	tw.lake.fill(0)
	tw.river.fill(0)
	tw.biome.fill(Biomes.GRASS)
	tw.path_mask.fill(3)
	tw.rivers = []
	tw.settlements = []
	tw.bridges = []
	tw.tunnels = [{a = 64 * tw.W + 40, b = 64 * tw.W + 56}]
	for y in range(60, 69):
		for x in range(44, 53):
			tw.h[y * tw.W + x] = 0.3
	var th := Heightfield.new(tw)
	var tunnel: Dictionary = th.structures[0]
	_check(_cross(tw, th, tunnel, false) and _cross(tw, th, tunnel, true), "контрольный туннель пройден пешком и на велосипеде")
	var tunnel_leaks := 0
	for angle in [-PI / 2.0, -PI / 4.0, PI / 4.0, PI / 2.0]:
		for ride in [false, true]:
			tunnel_leaks += _into_wall(tw, th, tunnel, angle, ride, DT)
	_check(tunnel_leaks == 0 and kinds.has(false), "стены контрольного туннеля держат; мосты проверены в мирах")

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


## Пройти или проехать сооружение s по оси от точки за 2 м до начала до сухого берега за концом.
## true, если дошли и всё время держались на высоте настила или пола (не провалились, не взлетели)
func _cross(w: WorldData, heights: Heightfield, s: Dictionary, ride: bool) -> bool:
	# 1 м больше вылета колеса WHEEL_REACH: велосипед целиком вышел на берег.
	# Дальше оси дорога может повернуть: прямой выезд на 2 м иногда упирается в перила соседнего моста.
	const EXIT := 1.0
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
		if t > s.len + EXIT:
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
					# Тропа ниже настила больше чем на высоту шага проходит под мостом:
					# его перила не мешают ей, как и в Heightfield.wall_at
					var feet := heights.level(s, t)
					var g := heights.ground_at(q.x, q.y)
					# Высокий берег над перилами проходит отдельно от настила (как в wall_at).
					var wall_height := Heightfield.TUNNEL_HEIGHT if s.tunnel else 1.5
					var along := g > feet - Heightfield.STEP and g < feet + wall_height
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
			# Точки тела — Vector2 (float32): у дальних туннелей округление координат даёт доли мм
			if side > face - reach + 0.001 or p.feet < heights.level(s, t) - 0.6:
				print("  %s %.0f м %s под %d°%s: %.2f м от оси при стенке в %.2f м, ноги %.1f м над настилом" % ["туннель" if s.tunnel else "мост", s.len,
					"на велосипеде" if ride else "пешком", roundi(rad_to_deg(angle)), " (такт %.2f с)" % dt if dt > DT else "", side, face, p.feet - heights.level(s, t)])
				return 1
	return 0


## Идти или ехать в дом u поселения s с направления a (8 м от центра дома). Возвращает 1, если пешеход
## подошёл к стене ближе 0,1 м (камера) или колесо велосипеда вошло в стену
func _into_hut(w: WorldData, heights: Heightfield, s: Dictionary, u: Dictionary, a: float, ride: bool) -> int:
	var hx: float = u.x * GameConfig.TILE
	var hz: float = u.y * GameConfig.TILE
	# поворот и стены — как у столкновений и SettlementsBuilder (с 9.5 у каждой постройки свои)
	var rot := PlayerState.hut_angle(s, u)
	var half := PlayerState.hut_half(u)
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
			# в систему дома
			var gap := maxf(absf(dx * cos(rot) - dz * sin(rot)) - half.x, absf(dx * sin(rot) + dz * cos(rot)) - half.y)
			if gap < reach:
				print("  дом %s %s с %d°: %.2f м до стены" % [str(Vector2(u.x, u.y)), "на велосипеде" if ride else "пешком",
					roundi(rad_to_deg(a)), gap])
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


## Одна генерация и проверка всей заставки; --capture сохраняет два кадра и передачу управления.
func _opening_test() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	WorldCache.enabled = false
	# Малый план теми же стадиями: полный 768 без .NET слишком дорог для теста камеры.
	var loaded := WorldLoader.new()
	loaded.world = WorldGenerator._generate_plan("Север-1234", 384)
	loaded.world.expand_territory(384)
	print("План проверки: ", loaded.world.settlements.size(), " поселений, ", loaded.world.trails.size(), " путей, ", loaded.world.peaks.size(), " вершин")
	var painted := loaded._prepare(loaded.world, 2)
	var changed := loaded.heights.finish_paths()
	if not changed.is_empty():
		TerrainBuilder.patch(loaded.terrain_arrays, loaded.world, loaded.heights, changed)
	TerrainBuilder.refine_arrays(loaded.terrain_arrays, loaded.world, loaded.heights)
	loaded.terrain_chunks = PlanTerrain.partition(loaded.terrain_arrays)
	var terrain_bytes: Array[PackedByteArray] = [painted[0][0]]
	var map_bytes: Array[PackedByteArray] = [painted[-1][1]]
	loaded.terrain_image = MapBaker.finish(loaded.world, 2, terrain_bytes, false)[0]
	loaded.map_image = MapBaker.finish(loaded.world, 2, map_bytes)[0]
	loaded.forest_surface = preload("res://scripts/render/forest_floor.gd").surface_image(loaded.world)
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	main.game = game
	main.add_child(game)
	game.start(loaded, main.hud)
	game.hud.visible = not game.opening_active()
	main._show("")
	game.set_physics_process(false)
	game.set_process(false)
	_check(not game.opening_place.is_empty(), "старт у точки интереса: %s" % game.opening_place.get("name", "нет"))
	_check(game.opening_active() and game.bike.riding, "катсцена началась в седле")
	if not game.opening_active():
		quit(1)
		return
	var begin := Vector2(game.player.x, game.player.z)
	var heading := game.bike.heading
	var clock := game._opening_time
	game.set_paused(true)
	game._physics_process(DT)
	_check(game._opening_time == clock and not game._opening_caption.visible, "пауза останавливает заставку и скрывает подпись")
	game.set_paused(false)
	game.look(200, 100)
	game.toggle_map()
	_check(is_equal_approx(game.yaw, heading) and not game.show_map, "мышь и карта не вмешиваются в катсцену")
	var directory := "res://tools/control/runs/11.0-opening"
	DirAccess.make_dir_recursive_absolute(directory)
	Input.action_press("move_right")
	Input.action_press("run")
	for tick in 285:
		game._physics_process(DT)
		game._update_camera(1.0, DT)
		if game.opening_active():
			game._draw_opening(1.0)
		game.bike_view.draw(1.0)
		if tick in [60, 150, 275] and "--capture" in OS.get_cmdline_user_args():
			await process_frame
			await RenderingServer.frame_post_draw
			_check(preload("res://tools/shot_util.gd").save_png(root, directory, "frame_%d" % tick), "снимок заставки")
		if not game.opening_active():
			break
	Input.action_release("move_right")
	Input.action_release("run")
	_check(not game.opening_active() and game.hud.visible, "через 4,6 с управление и HUD включаются")
	_check(game.bike.riding and not game.crash.active() and not game.bike.airborne, "проезд завершён без падения")
	_check(Vector2(game.player.x, game.player.z).distance_to(begin) > 5.0, "велосипед проехал по готовой дороге")
	var final_camera := game.camera.transform
	game._update_camera(1.0, 0.0)
	_check(final_camera.is_equal_approx(game.camera.transform), "конец приближения совпадает с обычной камерой")
	game._opening = true
	game._opening_time = 0.5
	var before_skip := Vector3(game.bike.x, game.bike.y, game.bike.z)
	var skip := InputEventAction.new()
	skip.action = "jump"
	skip.pressed = true
	game._unhandled_input(skip)
	_check(not game.opening_active() and before_skip == Vector3(game.bike.x, game.bike.y, game.bike.z), "пропуск не переносит велосипед")
	var kinds := {}
	for seed_value in 4:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var chosen := game.OpeningRoute.choose(game.world, game.heights, rng)
		_check(not chosen.is_empty(), "найден старт для RNG %d" % seed_value)
		if not chosen.is_empty():
			kinds[chosen.place.kind] = true
	print("Виды стартов на одном мире: ", kinds.keys())
	_check(kinds.size() > 1, "выбор не привязан к деревне")
	main._free_game()
	main.queue_free()
	await process_frame
	quit(1 if _fails > 0 else 0)


class DescentWorld extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = RoadSurface.PACKED}


class DescentGround extends Heightfield:
	var profile: Callable = func(d: float) -> float: return -0.2 * d
	func _init(w: WorldData) -> void:
		super()
		world = w
	func surface_at(_x: float, z: float, _feet := -INF) -> float:
		return 100.0 + float(profile.call(-z))
	func ground_at(x: float, z: float, _raw := false) -> float:
		return surface_at(x, z)
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func immersion_at(_x: float, _z: float, _feet: float) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true


func _descent_ride(ground: DescentGround, seconds: float, initial := 2.0, throttle := 0.0, hz := 60) -> BikeRide:
	var rider := PlayerState.new()
	var ride := BikeRide.new()
	ride.y = ground.surface_at(0, 0)
	ride.mount(rider)
	ride.speed = initial
	for tick in roundi(seconds * hz):
		ride.step(rider, throttle, 0.0, false, false, 1.0 / hz, ground.world, ground)
		if ride.crashed:
			break
	return ride


## Контролируемые спуски, обрыв, приземление и камера; генерация не нужна.
func _downhill_test() -> void:
	var w := DescentWorld.new()
	w.W = 64
	w.H = 64
	var h := DescentGround.new(w)
	var descent := _descent_ride(h, 2.0)
	_check(descent.speed > 6.0 and not descent.crashed, "20%% спуск без педалей: %.2f м/с через 2 с" % descent.speed)
	_check(not descent.airborne, "пологий ровный спуск держит колёса на земле")
	var braked := _descent_ride(h, 1.5, 8.0, -1.0)
	_check(absf(braked.speed) < 0.1, "тормоз останавливает на спуске")
	var slow_tick := _descent_ride(h, 3.0, 2.0, 0.0, 30)
	var fast_tick := _descent_ride(h, 3.0, 2.0, 0.0, 120)
	_check(absf(slow_tick.speed - fast_tick.speed) < 0.15, "разгон близок при 30 и 120 тактах/с")
	h.profile = func(d: float) -> float: return -0.4 * d
	var long_descent := _descent_ride(h, 60.0, 0.0)
	_check(long_descent.speed > 23.0 and long_descent.speed < 32.0, "длинный спуск: %.2f м/с, воздух сдерживает разгон" % long_descent.speed)
	var coast := BikeRide.new()
	coast.speed = 20.0
	coast._step_speed(0.0, false, -0.4, 0.4, DT)
	_check(coast.speed > 20.0, "камни не превращают воздух в вязкий тормоз на спуске")
	h.profile = func(d: float) -> float: return -3.0 * d
	var cliff := _descent_ride(h, 2.0, 0.5)
	_check(cliff.crashed and cliff.crash_cause == BikeRide.CrashCause.FALL, "медленный съезд на стену 72° запускает падение")
	_check(cliff.crash_velocity.is_finite() and cliff.crash_velocity.y < 0.0, "ragdoll получает скорость вниз по скале")
	h.profile = func(d: float) -> float: return 0.0 if d < 2.0 else -20.0
	var edge := _descent_ride(h, 4.0, 2.0)
	_check(edge.crashed and edge.land_impact > GameConfig.BIKE_CRASH, "съезд с обрыва 20 м заканчивается жёстким приземлением и падением")
	h.profile = func(_d: float) -> float: return 0.0
	var small_drop := BikeRide.new()
	var p := PlayerState.new()
	small_drop.y = 102.0
	small_drop.mount(p)
	small_drop.airborne = true
	for tick in 90:
		small_drop.step(p, 0.0, 0.0, false, false, DT, w, h)
	_check(not small_drop.crashed, "небольшое падение 2 м остаётся переносимым")
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game.world = w
	game.heights = h
	game.player = PlayerState.new()
	game.player.feet = 100.0
	game._prev = Vector3(0, 100, 0)
	game._cam_y = 101.4
	game.pitch = -0.3
	game.bike = BikeRide.new()
	game.bike.y = 100.0
	game.bike.riding = true
	game.bike_view = load("res://scenes/bike.tscn").instantiate()
	game.add_child(game.bike_view)
	game.bike_view.snap(game.bike)
	game.bike_view.draw(1.0)
	game.crash = BikeCrash.new()
	game.add_child(game.crash)
	for tick in 240:
		game._update_camera(1.0, DT)
	var ordinary_distance := game._cam_dist
	game.bike.speed = 26.0
	for tick in 240:
		game._update_camera(1.0, DT)
	_check(game._cam_dist > ordinary_distance + 0.6 and game._cam_dist <= GameConfig.BIKE_CAM + 0.71, "на скорости камера отдаляется максимум на 0,7 м")
	_check(game.camera.fov <= GameSettings.fov + GameConfig.BIKE_FOV * 1.3 + 0.01, "эффект не увеличивает прежний предел FOV")
	var wall_distance := 2.0
	h.profile = func(_d: float) -> float: return 3.0 if _d < -wall_distance else 0.0
	game._update_camera(1.0, DT)
	_check(game._cam_dist < 2.5, "скоростная камера уступает препятствию сзади")
	h.profile = func(_d: float) -> float: return 0.0
	var wind: Control = preload("res://scripts/render/speed_wind.gd").new()
	var canvas := CanvasLayer.new()
	game.add_child(canvas)
	canvas.add_child(wind)
	wind.update_effect(1.0, 0.5)
	if "--capture" in OS.get_cmdline_user_args():
		var mesh := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(300, 300)
		mesh.mesh = plane
		mesh.position.y = 100.0
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.28, 0.35, 0.21)
		mesh.material_override = material
		game.add_child(mesh)
		game._update_camera(1.0, 1.0)
		var directory := "res://tools/control/runs/11.1"
		DirAccess.make_dir_recursive_absolute(directory)
		await process_frame
		await RenderingServer.frame_post_draw
		_check(preload("res://tools/shot_util.gd").save_png(root, directory, "speed_wind"), "снимок эффекта скорости")
	wind.update_effect(0.0, DT)
	_check(wind.strength == 0.0, "полосы полностью исчезают при нулевом эффекте")
	game.queue_free()
	await process_frame
	quit(1 if _fails > 0 else 0)
