extends SceneTree
## 11.6: изолированная проверка препятствий на дорогах, без генерации мира (секунды):
##   godot --headless --path . --script res://tools/road_obstacles_test.gd
## 1) Ступени на ровной площадке: ветка и камни — только кочка подвески, бревно — стоп, прыжок или падение,
##    валун у края — объезд или падение в лоб. Размеры — как кладёт VegetationLayer на полотно.
## 2) Раскладка RoadObstacles на искусственной тропе: частота и виды по местности и виду пути,
##    одинаковость при повторе, пустое место у старта. 15.0: корни только от настоящих стволов у кромки.

const DT := 1.0 / 60.0
const Floor := preload("res://scripts/render/forest_floor.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok:
		fails += 1


class TestWorld extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = RoadSurface.FOREST}


class TestGround extends Heightfield:
	var tilt := 0.0 # поперечный уклон по x
	func _init(w: WorldData) -> void:
		super()
		world = w
	func ground_at(x: float, _z: float, _raw := false) -> float:
		return 100.0 + tilt * x
	func surface_at(x: float, z: float, _feet := -INF) -> float:
		return ground_at(x, z)
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func immersion_at(_x: float, _z: float, _feet: float) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true


func flat() -> TestGround:
	var w := TestWorld.new()
	var g := TestGround.new(w)
	g.obstacles = ForestObstacles.new(w, g)
	return g


## Едем на север (−Z) от z = 0 со скоростью pace; препятствие на z = −10. Возвращает [велосипед, наибольший ход вилки]
func ride(g: TestGround, x: float, pace: float, seconds: float, hop_at := -1.0, pedal := true) -> Array:
	var b := BikeRide.new()
	b.x = x
	b.y = 100.0
	var p := PlayerState.new()
	b.mount(p)
	b.speed = pace
	var t := 0.0
	var squeeze := 0.0
	while t < seconds and not b.crashed:
		b.step(p, clampf((pace - b.speed) * 2.0, 0.0, 1.0) if pace < 9.0 and pedal else 0.0, 0.0, false, hop_at >= 0.0 and absf(t - hop_at) < DT * 0.5, DT, g.world, g)
		squeeze = maxf(squeeze, b.squash_f)
		t += DT
	return [b, squeeze]


## Можно ли перепрыгнуть: перебор времени прыжка
func jumpable(make: Callable, pace: float) -> bool:
	for n in 40:
		var r: Array = ride(make.call(), 0.0, pace, 3.0, 0.3 + n * 0.025)
		if not r[0].crashed and r[0].z < -12.0:
			return true
	return false


func _tiers() -> void:
	# Ветка поперёк колеи и россыпь камней: проезд с толчком подвески, без остановки и падения
	var base: Array = ride(flat(), 0.0, 10.0, 2.0)
	for kind: int in [RoadObstacles.BRANCH, RoadObstacles.STONES]:
		var g := flat()
		var rot := 0.0 if kind == RoadObstacles.BRANCH else 0.7
		g.obstacles.set_bumps(RoadObstacles.bump(kind, Transform3D(Basis(Vector3.UP, rot), Vector3(0, 100, -10)), 1.1), 1)
		var r: Array = ride(g, 0.0, 10.0, 2.0)
		var label := "ветка" if kind == RoadObstacles.BRANCH else "камни"
		check(not r[0].crashed and r[0].z < -15.0 and r[0].speed > base[0].speed - 0.3, "%s на 10 м/с: проезд (скорость %.1f м/с, по ровному %.1f)" % [label, r[0].speed, base[0].speed])
		check(r[1] > base[1] + 0.01, "%s: вилка сжалась на %.1f см (ровно %.1f)" % [label, r[1] * 100.0, base[1] * 100.0])
	# 15.0: корень через полотно — самый толстый (масштаб 1,3), наискосок: кочка, проезд на 10 и на 4 м/с без падения
	for pace: float in [10.0, 4.0]:
		var g := flat()
		var xf := Transform3D(Basis(Vector3.UP, 0.5).scaled(Vector3.ONE * 1.3), Vector3(0, 100, -10))
		xf.basis.x *= 3.6 / 1.3
		xf.origin -= xf.basis * Vector3(-0.26, 0.0, 0.07) # под колесом — дуга корня над грунтом, а не его часть под землёй
		g.obstacles.set_bumps(RoadObstacles.bump(RoadObstacles.ROOT, xf, 1.3), 1)
		var r: Array = ride(g, 0.0, pace, 12.0 / pace + 1.0)
		var flat_ride: Array = ride(flat(), 0.0, pace, 12.0 / pace + 1.0)
		check(not r[0].crashed and r[0].z < -12.0, "корень на %.0f м/с: проезд без падения" % pace)
		check(r[1] > flat_ride[1] + 0.005 and r[1] < flat_ride[1] + 0.08, "корень на %.0f м/с: вилка сжалась на %.1f см (ровно %.1f) — заметно, но не удар" % [pace, r[1] * 100.0, flat_ride[1] * 100.0])
	# Бревно поперёк — самое толстое, что кладётся на полотно (масштаб 0,95)
	var s := 0.95
	var log_ground := func() -> TestGround:
		var g := flat()
		g.obstacles._add(-2.1 * s, -10.0, 2.1 * s, -10.0, 0.2 * s, 100.0, 100.0 + 0.42 * s)
		return g
	# (30.10: на 5 м/с бревно переваливается с потерей скорости, как в wheel_contact_test; встаёт — накатом на 3 м/с)
	var r: Array = ride(log_ground.call(), 0.0, 3.0, 6.0, -1.0, false)
	check(not r[0].crashed and r[0].z > -10.0, "бревно на 3 м/с накатом без прыжка: остановка (z %.2f%s)" % [r[0].z, (", упал: " + BikeRide.CrashCause.keys()[r[0].crash_cause]) if r[0].crashed else ""])
	r = ride(log_ground.call(), 0.0, 12.0, 2.0)
	check(r[0].crashed, "бревно на 12 м/с без прыжка: падение")
	check(jumpable(log_ground, 8.0), "бревно на 8 м/с перепрыгивается")
	# Валун у края полотна (масштаб 0,7 — самый низкий): объезд по свободной стороне, в лоб — падение, не перепрыгнуть
	s = 0.7
	var rock := func() -> TestGround:
		var g := flat()
		g.obstacles._add(0.0, -10.0, 0.0, -10.0, 0.75 * s, 100.0, 100.0 + 0.95 * s)
		return g
	r = ride(rock.call(), 0.0, 12.0, 2.0)
	check(r[0].crashed, "валун в лоб на 12 м/с: падение")
	r = ride(rock.call(), 0.0 + 0.75 * s + BikeRide.BODY_R + 0.1, 12.0, 2.0)
	check(not r[0].crashed and r[0].z < -14.0, "валун рядом: проезд мимо")
	check(not jumpable(rock, 10.0), "валун не перепрыгнуть — только объехать")
	# Удар считается по всему несделанному куску пути (11.6), а вскользь по-прежнему не роняет
	var trunk := flat()
	trunk.obstacles._add(0.0, -10.0, 0.0, -10.0, 0.3, 100.0, INF)
	r = ride(trunk, 0.5, 12.0, 2.0)
	check(not r[0].crashed and r[0].z < -14.0, "ствол вскользь на 12 м/с: проскользнул без падения%s" % ((" (упал: %s, z %.2f)" % [BikeRide.CrashCause.keys()[r[0].crash_cause], r[0].z]) if r[0].crashed else ""))
	# 30.10: после падения на бревне седок встаёт за ним, велосипед лежит перед ним — сесть можно (бревно
	# перешагивается и переносится через него, а не стена для посадки)
	for side: float in [1.0, -1.0]:
		var g: TestGround = log_ground.call()
		var b := BikeRide.new()
		b.x = 0.0
		b.z = -10.0 + 0.9 * side
		b.y = 100.0
		b.fallen = true
		var p := PlayerState.new()
		p.x = 0.4
		p.z = -10.0 - 1.4 * side
		p.feet = 100.0
		p.on_ground = true
		check(b.prepare_mount(p, g.world, g), "сесть на велосипед через бревно (%s)" % ("велосипед перед бревном" if side > 0.0 else "за бревном"))


## Искусственная тропа: прямая на север через участок 256 × 256 клеток, полог cover, каменистость rocky
func _world(kind: String, cover: float, rocky: float, tilt := 0.0) -> Array:
	var w := TestWorld.new()
	w.W = 256
	w.H = 256
	w.N = w.W * w.H
	w.seed_num = 4821
	w.river.resize(w.N)
	w.dist_water.resize(w.N)
	w.dist_water.fill(50.0)
	var pts: Array = []
	var surf := PackedByteArray()
	for y in range(250, 5, -1):
		pts.append({x = 128.5 + 3.0 * sin(y * 0.05), y = y + 0.5, w = 1 if kind != "road" else 2})
		surf.append(RoadSurface.FOREST if kind != "road" else RoadSurface.GRAVEL)
	w.trails = [{kind = kind, pts = pts, surf = surf}]
	# 15.0: деревья мира — крупные стволы у кромки тропы через каждые ~12 м (в лесу), объекты по чанкам 16 клеток
	w.CS = 16
	w.CW = 16
	w.CH = 16
	w.chunks.resize(w.CW * w.CH)
	for c in w.chunks.size(): w.chunks[c] = PackedInt32Array()
	if cover > 0.5:
		for y in range(12, 250, 3):
			var side := 1.0 if (y / 3) % 2 == 0 else -1.0
			var x := 128.5 + 3.0 * sin(y * 0.05) + side * (0.5 + 0.25 + 0.3 * ((y * 7) % 5) / 4.0)
			w.obj_x.append(x)
			w.obj_y.append(y + 0.3)
			w.obj_k.append(Biomes.T_OAK if (y / 3) % 3 != 0 else Biomes.T_PINE)
			w.obj_v.append(0)
			w.obj_s.append(0.9 + 0.1 * ((y * 3) % 4))
			var chunk := floori(y / 16.0) * w.CW + floori(x / 16.0)
			w.chunks[chunk].append(w.obj_x.size() - 1)
	w.obj_count = w.obj_x.size()
	var g := TestGround.new(w)
	g.tilt = tilt
	var image := Image.create(w.W, w.H, false, Image.FORMAT_RGBA8)
	image.fill(Color(cover, 0.3, 0.4, rocky))
	return [w, g, image]


func _count(scene: Array) -> Dictionary:
	var road := RoadObstacles.new(scene[0])
	var kinds := [0, 0, 0, 0, 0]
	var list: Array = []
	var t: Dictionary = scene[0].trails[0]
	var samples := road._sampled[0]
	var length := 0.0
	for n in range(1, t.pts.size()):
		length += RoadObstacles._point(t, n).distance_to(RoadObstacles._point(t, n - 1))
	for n in range(1, samples.size()):
		var o := road.pick(scene[1], scene[2], 0, n)
		if not o.is_empty():
			o.mid = (RoadObstacles._point(t, samples[n]) + RoadObstacles._point(t, samples[n - 1])) * 0.5
			kinds[o.kind] += 1
			list.append(o)
			check(o.parts.size() >= 1 and o.parts.size() <= 3, "у препятствия от одной до трёх частей")
	return {kinds = kinds, per_km = list.size() * 1000.0 / length, list = list, road = road}


func _placement() -> void:
	var forest := _count(_world("trail", 0.9, 0.1))
	print("  лесная тропа: %.0f на км, ветки/камни/брёвна/валуны/корни %s" % [forest.per_km, forest.kinds])
	check(forest.per_km > 8.0 and forest.per_km < 45.0, "лесная тропа: препятствия есть, но не завал")
	check(forest.kinds[RoadObstacles.BRANCH] > 0 and forest.kinds[RoadObstacles.LOG] > 0, "в лесу ветки и брёвна")
	check(forest.kinds[RoadObstacles.ROOT] > 0, "у стволов у кромки корни выходят на тропу")
	# корень идёт от своего ствола: начало у ствола, наискосок через полотно
	var crossing := true
	for o: Dictionary in forest.list:
		if o.kind != RoadObstacles.ROOT: continue
		for part: Dictionary in o.parts:
			var along := Vector2.from_angle(-part.rot)
			if absf(along.dot(Vector2(0.0, 1.0))) > 0.95: crossing = false
	check(crossing, "корни пересекают тропу, а не лежат вдоль неё")
	var road := _count(_world("road", 0.9, 0.1))
	print("  лесная дорога: %.0f на км, %s" % [road.per_km, road.kinds])
	check(road.per_km < forest.per_km * 0.7, "дорога чище тропы")
	var open := _count(_world("trail", 0.0, 0.05))
	print("  тропа в поле: %.0f на км, %s" % [open.per_km, open.kinds])
	check(open.kinds[RoadObstacles.LOG] == 0 and open.kinds[RoadObstacles.ROOT] == 0 and open.per_km < forest.per_km * 0.5, "в поле без брёвен и корней и реже")
	var plain := _count(_world("road", 0.0, 0.0))
	print("  равнинная дорога: %.0f на км, %s" % [plain.per_km, plain.kinds])
	check(plain.per_km < 3.0, "на открытой равнинной дороге почти ничего не лежит")
	var scree := _count(_world("mountain", 0.0, 0.9, 0.35))
	print("  горная тропа на косогоре: %.0f на км, %s" % [scree.per_km, scree.kinds])
	check(scree.kinds[RoadObstacles.BOULDER] > 0 and scree.kinds[RoadObstacles.STONES] > 0, "на косогоре камни и валуны")
	# у валуна на косогоре — сторона подъёма (уклон по +x), а не середина
	var uphill := true
	for o: Dictionary in scree.list:
		if o.kind == RoadObstacles.BOULDER and o.x < o.mid.x + 0.5:
			uphill = false
	check(uphill, "валун лежит у края со стороны подъёма")
	var again := _count(_world("trail", 0.9, 0.1))
	check(str(again.list) == str(forest.list), "повтор раскладки даёт то же самое")
	var dense := _world("trail", 0.9, 0.1)
	var trail: Dictionary = dense[0].trails[0]
	var fine: Array = [trail.pts[0]]
	for j in range(1, trail.pts.size()):
		var a: Dictionary = trail.pts[j - 1]
		var b: Dictionary = trail.pts[j]
		for k in range(1, 8):
			fine.append({x = lerpf(a.x, b.x, k / 8.0), y = lerpf(a.y, b.y, k / 8.0), w = a.w})
		fine.append(b)
	trail.pts = fine
	trail.surf.resize(fine.size())
	trail.surf.fill(RoadSurface.FOREST)
	check(str(_count(dense).list) == str(forest.list), "подразбиение линии на отрезки короче метра сохраняет препятствия")
	var overlap := _world("trail", 0.9, 0.1)
	overlap[0].trails.append(overlap[0].trails[0].duplicate(true))
	check(str(_count(overlap).list) == str(forest.list), "дубль маршрута сохраняет препятствия общего полотна")
	overlap[0].trails[1].trail_id = "authored"
	check(_count(overlap).list.is_empty(), "у авторской трассы нет случайных дорожных препятствий")
	var scene := _world("trail", 0.9, 0.1)
	var cleared := RoadObstacles.new(scene[0])
	var start := RoadObstacles._point(scene[0].trails[0], 120)
	cleared.clear.append(start)
	var near := 0
	for n in range(100, 140):
		var o := cleared.pick(scene[1], scene[2], 0, n)
		if not o.is_empty() and Vector2(o.x, o.z).distance_to(start) < RoadObstacles.CLEAR_R - 6.0:
			near += 1
	check(near == 0, "у старта пусто")
	# мешы на месте: корень через тропу — последняя деталь подстилки, веса подстилки не сдвинулись
	check(Floor.meshes().size() == Floor.COUNT and Floor.weights(0.5, 0.5, 0.5, 0.5, 0.5).size() == Floor.COUNT, "варианты мешей и веса имеют одинаковый размер")


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	_tiers()
	_placement()
	_contracts()
	print("Итого: ", "всё прошло" if fails == 0 else "%d не прошло" % fails)
	quit(1 if fails > 0 else 0)


func _contracts() -> void:
	var scene := _world("trail", 0.9, 0.1)
	var w: WorldData = scene[0]
	var g: Heightfield = scene[1]
	var road := RoadObstacles.new(w)
	var pairs := road.around(512, 512, 700)
	road.begin_fill(g, scene[2], pairs)
	var began := Time.get_ticks_usec()
	for p in range(0, pairs.size(), 2): road.pick(g, scene[2], pairs[p], pairs[p + 1])
	var cold := Time.get_ticks_usec() - began
	var count := road.evaluations
	began = Time.get_ticks_usec()
	road.begin_fill(g, scene[2], pairs)
	for p in range(0, pairs.size(), 2): road.pick(g, scene[2], pairs[p], pairs[p + 1])
	print("candidate cache cold/warm us ", cold, "/", Time.get_ticks_usec() - began, "; entries ", road._cache.size())
	check(road.evaluations == count, "тёплое обновление не повторяет поиск причин и проверки кандидатов")
	road.clear.append(Vector2(512, 512))
	road.begin_fill(g, scene[2], pairs)
	check(road._cache.is_empty(), "новая защищённая зона инвалидирует в том числе пустые результаты")
	road.begin_fill(g, scene[2], PackedInt32Array())
	check(road._cache.is_empty(), "кэш не держит выгруженные участки")
	var d := TrailDefinition.new()
	d.id = "prepared"
	d.kind = "trail"
	for p: Dictionary in w.trails[0].pts: d.points.append(Vector2(p.x, p.y) * GameConfig.TILE)
	var e := TrailElement.new()
	e.profile = TrailElement.Profile.TABLETOP
	e.station = 450.0
	e.length = 24.0
	d.elements = [e]
	w.trails[0].trail_id = d.id
	w.trail_plan = {state = "found", routes = [StageTrailPlan.pack(d)]}
	road = RoadObstacles.new(w)
	check(road.protected(0, 430) and road.protected(0, 470), "защищены заход и приземление трамплина")
	check(not road.protected(0, 250), "обычный участок подготовленной трассы открыт природе")
	var natural := 0
	for n in range(3, road._sampled[0].size() - 3):
		var o := road.pick(g, scene[2], 0, n)
		if not o.is_empty():
			natural += 1
			check(absf(road._along[0][n] - 450.0) > 24.0, "природный объект вне защищённой секции")
	check(natural > 0, "на природных отрезках подготовленной трассы действительно есть объекты")
	for v in 3:
		var xf := Transform3D(Basis(), Vector3(0, 100, 0))
		var bumps := RoadObstacles.bump(RoadObstacles.STONES, xf, 1.0, g, v)
		var boxes := Floor.stone_bounds(v)
		check(bumps.size() / 6 == boxes.size(), "камни %d: контакт у каждого видимого камня" % v)
		for i in boxes.size():
			var center: Vector3 = boxes[i].get_center()
			check(Vector2(bumps[i * 6], bumps[i * 6 + 1]).distance_to(Vector2(center.x, center.z)) < 0.001, "камни: контакт в центре камня, не россыпи")
		var roots := RoadObstacles.bump(RoadObstacles.ROOT, xf, 1.0, g, v)
		check(not roots.is_empty(), "корень %d имеет выступающие участки" % v)
		var obstacles := ForestObstacles.new(w, g)
		obstacles.set_bumps(roots, 1)
		var rise := obstacles.bump_at(-0.2, 0.05)
		obstacles.set_bumps(roots + roots, 2)
		check(is_equal_approx(rise, obstacles.bump_at(-0.2, 0.05)), "перекрытие частей корня не удваивает удар")
