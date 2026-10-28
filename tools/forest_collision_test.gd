extends SceneTree
## Стволы, валуны и валежник (7.7): godot --headless --path . --script res://tools/forest_collision_test.gd
## Ровная площадка с препятствиями, поставленными вручную, затем настоящий лес мира «abc».

class TestWorld extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 0}

class TestGround extends Heightfield:
	func _init(w: WorldData) -> void:
		super(w, false)
	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 100.0
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true

const DT := 1.0 / 60.0
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok:
		fails += 1


## Площадка с одним стволом радиуса 0,3 м в (0, -10) или бревном поперёк пути
func flat(log := false) -> TestGround:
	var w := TestWorld.new()
	var g := TestGround.new(w)
	g.obstacles = ForestObstacles.new(w, g)
	if log:
		g.obstacles._add(-2.0, -10.0, 2.0, -10.0, 0.2, 100.0, 100.42)
	else:
		g.obstacles._add(0.0, -10.0, 0.0, -10.0, 0.3, 100.0, INF)
	return g


func walk(g: TestGround, x: float, seconds: float, jump_at := -1.0) -> PlayerState:
	var p := PlayerState.new()
	p.x = x
	p.feet = 100.0
	var t := 0.0
	while t < seconds:
		p.step(1.0, 0.0, true, jump_at >= 0.0 and absf(t - jump_at) < DT * 0.5, 0.0, DT, g.world, g)
		t += DT
	return p


func ride(g: TestGround, x: float, pace: float, seconds: float, hop_at := -1.0) -> BikeRide:
	var b := BikeRide.new()
	b.x = x
	b.y = 100.0
	b.speed = pace
	b.riding = true
	var p := PlayerState.new()
	var t := 0.0
	while t < seconds and not b.crashed:
		b.step(p, 1.0 if pace < 9.0 else 0.0, 0.0, false, hop_at >= 0.0 and absf(t - hop_at) < DT * 0.5, DT, g.world, g)
		t += DT
	return b


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	# Пешком: в лоб ствол держит, чуть сбоку — обходится по касательной, не застревая
	var g := flat()
	var p := walk(g, 0.0, 4.0)
	check(p.z > -10.0 and Vector2(p.x, p.z + 10.0).length() >= 0.6 - 1e-3, "пешком в лоб: стоит у ствола, не внутри (z %.2f)" % p.z)
	p = walk(g, 0.12, 4.0)
	check(p.z < -12.0, "пешком чуть сбоку: обошёл ствол по касательной (z %.2f, x %.2f)" % [p.z, p.x])
	# Велосипед: медленно в лоб — остановка без падения, быстро в лоб — падение, вскользь — объезд
	var b := ride(flat(), 0.0, 6.0, 4.0)
	check(not b.crashed and b.z > -10.0 and b.z < -8.0, "велосипед 6 м/с в лоб: остановился у ствола без падения (z %.2f)" % b.z)
	b = ride(flat(), 0.0, 12.0, 2.0)
	check(b.crashed and b.crash_velocity.length() > 9.0, "велосипед 12 м/с в лоб: падение (%.1f м/с)" % b.crash_velocity.length())
	b = ride(flat(), 0.5, 12.0, 2.0)
	check(not b.crashed and b.z < -14.0 and absf(b.speed) > 9.0, "велосипед 12 м/с вскользь: проскользнул мимо ствола, скорость %.1f м/с" % b.speed)
	b = ride(flat(), 0.12, 12.0, 2.0)
	check(b.crashed, "велосипед 12 м/с почти в лоб (12 см от оси): падение")
	# Бревно: не пускает, но перепрыгивается пешком и на велосипеде
	p = walk(flat(true), 0.0, 4.0)
	check(p.z > -10.0, "пешком в бревно: стоит перед ним (z %.2f)" % p.z)
	p = walk(flat(true), 0.0, 4.0, 1.4)
	check(p.z < -11.0, "пешком прыжок через бревно (z %.2f)" % p.z)
	b = ride(flat(true), 0.0, 6.0, 4.0)
	check(not b.crashed and b.z > -10.0, "велосипед 6 м/с в бревно: стоит перед ним (z %.2f)" % b.z)
	b = ride(flat(true), 0.0, 6.0, 4.0, 1.05)
	check(not b.crashed and b.z < -12.0, "велосипед прыжок через бревно (z %.2f)" % b.z)

	# Настоящий лес: стволы ограничивают, но лес остаётся проходимым
	var w := WorldGenerator.generate("abc", 128)
	var h := Heightfield.new(w)
	h.obstacles = ForestObstacles.new(w, h)
	var spots := forest_spots(w)
	check(spots.size() >= 5, "в мире есть густой лес: %d мест" % spots.size())
	var free_walk := 0
	var free_bike := 0
	var total := 0
	var obstacles := 0
	var dist: Array[float] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var spent := 0.0
	var queries := 0
	for spot: Vector2 in spots:
		h.obstacles.update(spot.x, spot.y, PackedFloat32Array(), 0, true)
		obstacles += h.obstacles.data.size() / ForestObstacles.STRIDE
		for k in 200:
			var x := spot.x + rng.randf_range(-12.0, 12.0)
			var z := spot.y + rng.randf_range(-12.0, 12.0)
			var feet := h.ground_at(x, z)
			if not PlayerState.is_passable(w, h, x, z, feet, 0.0):
				continue
			total += 1
			var t0 := Time.get_ticks_usec()
			h.obstacles.hits(x, z, feet, BikeRide.BODY_R)
			spent += Time.get_ticks_usec() - t0
			queries += 1
			free_walk += int(PlayerState.is_passable(w, h, x, z, feet, PlayerState.BODY_R))
			var bk := BikeRide.new()
			bk.y = feet
			free_bike += int(bk.fits(x, z, rng.randf() * TAU, w, h))
		# прямо через лес под педалями: сколько проезжает, пока не упрётся
		for k in 6:
			var bk := BikeRide.new()
			bk.heading = rng.randf() * TAU
			bk.x = spot.x
			bk.z = spot.y
			bk.y = h.surface_at(bk.x, bk.z, INF)
			if not bk.fits(bk.x, bk.z, bk.heading, w, h):
				continue
			bk.riding = true
			var pl := PlayerState.new()
			var stuck := 0.0
			var path := 0.0
			for i in 600:
				var x0 := bk.x
				var z0 := bk.z
				bk.step(pl, 1.0, 0.0, false, false, DT, w, h)
				var d := Vector2(bk.x - x0, bk.z - z0).length()
				path += d
				stuck = stuck + DT if d < 0.01 else 0.0
				if stuck > 0.5 or bk.crashed:
					break
			dist.append(path)
	spent /= maxi(1, queries)
	print("  препятствий у места: %.0f; свободно пешком %.0f%%, велосипеду %.0f%%; проверка %.1f мкс" % [float(obstacles) / spots.size(), 100.0 * free_walk / maxi(1, total), 100.0 * free_bike / maxi(1, total), spent])
	dist.sort()
	var median := dist[dist.size() / 2] if not dist.is_empty() else 0.0
	print("  езда по прямой без руля: медиана %.1f м до упора (из %d)" % [median, dist.size()])
	check(float(free_walk) / maxi(1, total) > 0.85, "пешком свободно больше 85% мест в лесу")
	check(float(free_bike) / maxi(1, total) > 0.7, "велосипед помещается в больше 70% мест в лесу")
	check(median > 15.0, "по прямой без руля в среднем проезжает больше 15 м")
	quit(1 if fails else 0)


## Центры клеток с самым густым лесом (по числу крупных деревьев в чанке)
func forest_spots(w: WorldData) -> Array[Vector2]:
	var counts: Array = []
	for c in w.chunks.size():
		var n := 0
		for o in w.chunks[c]:
			if Biomes.is_tree(w.obj_k[o]) and w.obj_s[o] >= ForestObstacles.MIN_SCALE:
				n += 1
		counts.append([n, c])
	counts.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var out: Array[Vector2] = []
	var side := w.CS * GameConfig.TILE
	for k in mini(8, counts.size()):
		var c: int = counts[k][1]
		out.append(Vector2((c % w.CW + 0.5) * side, (c / w.CW + 0.5) * side))
	return out
