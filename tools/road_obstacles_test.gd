extends SceneTree
## 11.6: изолированная проверка препятствий на дорогах, без генерации мира (секунды):
##   godot --headless --path . --script res://tools/road_obstacles_test.gd
## 1) Ступени на ровной площадке: ветка и камни — только кочка подвески, бревно — стоп, прыжок или падение,
##    валун у края — объезд или падение в лоб. Размеры — как кладёт VegetationLayer на полотно.
## 2) Раскладка RoadObstacles на искусственной тропе: частота и виды по местности и виду пути,
##    одинаковость при повторе, пустое место у старта.

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
func ride(g: TestGround, x: float, pace: float, seconds: float, hop_at := -1.0) -> Array:
	var b := BikeRide.new()
	b.x = x
	b.y = 100.0
	var p := PlayerState.new()
	b.mount(p)
	b.speed = pace
	var t := 0.0
	var squeeze := 0.0
	while t < seconds and not b.crashed:
		b.step(p, 1.0 if pace < 9.0 else 0.0, 0.0, false, hop_at >= 0.0 and absf(t - hop_at) < DT * 0.5, DT, g.world, g)
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
	# Бревно поперёк — самое толстое, что кладётся на полотно (масштаб 0,95)
	var s := 0.95
	var log_ground := func() -> TestGround:
		var g := flat()
		g.obstacles._add(-2.1 * s, -10.0, 2.1 * s, -10.0, 0.2 * s, 100.0, 100.0 + 0.42 * s)
		return g
	var r: Array = ride(log_ground.call(), 0.0, 5.0, 4.0)
	check(not r[0].crashed and r[0].z > -10.0, "бревно на 5 м/с без прыжка: остановка (z %.2f)" % r[0].z)
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
	check(not r[0].crashed and r[0].z < -14.0, "ствол вскользь на 12 м/с: проскользнул без падения")


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
	var g := TestGround.new(w)
	g.tilt = tilt
	var image := Image.create(w.W, w.H, false, Image.FORMAT_RGBA8)
	image.fill(Color(cover, 0.3, 0.4, rocky))
	return [w, g, image]


func _count(scene: Array) -> Dictionary:
	var road := RoadObstacles.new(scene[0])
	var kinds := [0, 0, 0, 0]
	var list: Array = []
	var t: Dictionary = scene[0].trails[0]
	var length := 0.0
	for n in range(1, t.pts.size()):
		length += RoadObstacles._point(t, n).distance_to(RoadObstacles._point(t, n - 1))
		var o := road.pick(scene[1], scene[2], 0, n)
		if not o.is_empty():
			o.mid = (RoadObstacles._point(t, n) + RoadObstacles._point(t, n - 1)) * 0.5
			kinds[o.kind] += 1
			list.append(o)
	return {kinds = kinds, per_km = list.size() * 1000.0 / length, list = list, road = road}


func _placement() -> void:
	var forest := _count(_world("trail", 0.9, 0.1))
	print("  лесная тропа: %.0f на км, ветки/камни/брёвна/валуны %s" % [forest.per_km, forest.kinds])
	check(forest.per_km > 8.0 and forest.per_km < 40.0, "лесная тропа: препятствия есть, но не завал")
	check(forest.kinds[RoadObstacles.BRANCH] > 0 and forest.kinds[RoadObstacles.LOG] > 0, "в лесу ветки и брёвна")
	var road := _count(_world("road", 0.9, 0.1))
	print("  лесная дорога: %.0f на км, %s" % [road.per_km, road.kinds])
	check(road.per_km < forest.per_km * 0.7, "дорога чище тропы")
	var open := _count(_world("trail", 0.0, 0.05))
	print("  тропа в поле: %.0f на км, %s" % [open.per_km, open.kinds])
	check(open.kinds[RoadObstacles.LOG] == 0 and open.per_km < forest.per_km * 0.5, "в поле без брёвен и реже")
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
	# мешы на месте: новая ветка в списке подстилки, веса подстилки не сдвинулись
	check(Floor.meshes().size() == Floor.BRANCH + 1 and Floor.weights(0.5, 0.5, 0.5, 0.5, 0.5).size() == Floor.BRANCH + 1, "ветка — последняя деталь подстилки")


func _initialize() -> void:
	_tiers()
	_placement()
	print("Итого: ", "всё прошло" if fails == 0 else "%d не прошло" % fails)
	quit(1 if fails > 0 else 0)
