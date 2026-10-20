extends SceneTree
## 4.5: слабая обработка удобной земли, сильная на локальных перепадах,
## отказ от чрезмерно крутого маршрута; сеть и переходы у берега/сооружений.

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr(what)


func _init() -> void:
	var flat := _compare(_world("flat"), "ровная земля", true)
	var bank := _compare(_world("bank"), "косой склон", true)
	var bumps := _compare(_world("bumps"), "короткий подъём и впадина", true)
	var steep := _compare(_world("steep"), "постоянный уклон 80 %", false)
	var shore := _compare(_world("shore"), "полка у озера на склоне 150 %", true)
	check(shore.cross < shore.raw_cross * 0.3, "полка дороги у озера осталась на стене")
	_shore_invariants()
	check(flat.power < bank.power * 0.7 and flat.power < bumps.power * 0.7, "удобная земля обрабатывается так же сильно, как трудная")
	check(bank.cross < bank.raw_cross * 0.5, "косой склон не получил удобного полотна")
	check(bumps.bumps < bumps.raw_bumps * 0.9 and bumps.height_range < bumps.raw_range * 0.85, "локальные перегибы и перепад высот не смягчились")
	check(steep.change < 0.005, "обработка пытается исправить непригодный крутой маршрут")
	_network()
	if not OS.get_cmdline_user_args().has("--synthetic-only"):
		for seed_text: String in ["Туман-4821", "Ущелье"]:
			_compare(WorldGenerator.generate(seed_text, 256), seed_text + "@256", false)
	print("Road fit 4.5: нарушений %d" % fails)
	quit(1 if fails else 0)


func _world(mode: String) -> WorldData:
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = w.W * w.H
	w.seed_num = 44
	for name: String in ["h", "filled", "elev", "slope", "temp", "moist", "dist_water"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		values.fill(20.0 if name == "dist_water" else 0.0)
		w.set(name, values)
	for j in w.H:
		for i in w.W:
			var x := (i + 0.5) * GameConfig.TILE
			var z := (j + 0.5) * GameConfig.TILE
			var value := 60.0
			if mode == "bank":
				value += (z - 130.0) * 0.5 + sin(x * 0.3) * 0.65
			elif mode == "bumps":
				value += 3.5 * exp(-pow((x - 90.0) / 5.0, 2.0)) - 3.0 * exp(-pow((x - 155.0) / 6.0, 2.0))
			elif mode == "steep":
				value += (x - 100.0) * 0.8
			elif mode == "shore":
				value += (z - 130.0) * 1.5
			w.h[j * w.W + i] = value / GameConfig.HS
	for name: String in ["ocean", "lake", "river", "biome", "path_mask", "road_surface"]:
		var values := PackedByteArray()
		values.resize(w.N)
		values.fill(Biomes.GRASS if name == "biome" else 0)
		w.set(name, values)
	if mode == "shore":
		for z in w.H:
			for x in w.W:
				var cell := z * w.W + x
				w.dist_water[cell] = maxf(0.0, z - 31.0)
				if z <= 31:
					w.lake[cell] = 1
					w.h[cell] = minf(w.h[cell], 52.0 / GameConfig.HS)
					w.filled[cell] = 56.0 / GameConfig.HS
	var points: Array = []
	var surfaces := PackedByteArray()
	for x in range(8, 57):
		points.append({x = float(x), y = 32.5, w = 0.9})
		surfaces.append(RoadSurface.DIRT)
		w.path_mask[32 * w.W + x] = 3
		w.road_surface[32 * w.W + x] = RoadSurface.DIRT
	w.trails = [{kind = "road", pts = points, surf = surfaces}]
	return w


func _shore_invariants() -> void:
	var h := Heightfield.new(_world("shore"))
	var changed := 0.0
	for key: int in h.road_refinement.patches:
		var patch: Dictionary = h.road_refinement.patches[key]
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				var px := (key % h.world.W + 0.5) * GameConfig.TILE + x * RoadRefinement.STEP
				var pz := (key / h.world.W + 0.5) * GameConfig.TILE + z * RoadRefinement.STEP
				var base := h.base_ground_at(px, pz)
				var value: float = patch.h[z * RoadRefinement.STRIDE + x]
				var cell := floori(pz / GameConfig.TILE) * h.world.W + floori(px / GameConfig.TILE)
				changed = maxf(changed, absf(value - base))
				if h.water_level[cell] != -INF:
					check(absf(value - base) < 0.001, "полка изменила дно озера")
				elif value < base:
					check(value >= minf(base, RoadBed._wet_near(h, cell) + RoadBed.WATER_GAP) - 0.001, "полка затопила сухой берег")
	check(changed > 1.2 and changed <= RoadRefinement.BENCH_LIMIT + 0.001, "полка не использовала ограниченную выемку в склоне")


func _compare(w: WorldData, label: String, ride: bool) -> Dictionary:
	var h := Heightfield.new(w)
	var after := h.road_refinement
	var power := 0.0
	var samples := 0
	var cross := 0.0
	var raw_cross := 0.0
	var bumps := 0.0
	var raw_bumps := 0.0
	var change := 0.0
	var low := INF
	var high := -INF
	var raw_low := INF
	var raw_high := -INF
	for route: int in after.fit_routes:
		var fit: Dictionary = after.fit_routes[route]
		var points: PackedVector2Array = fit.points
		check(w.trails[route].kind != "mountain", "горная тропа стала обычным полотном")
		for j in range(16, points.size() - 16):
			var p := points[j]
			var t := (points[j + 1] - points[j - 1]).normalized()
			var n := Vector2(-t.y, t.x) * 1.2
			power += fit.strength[j]
			samples += 1
			cross += absf(h.ground_at(p.x + n.x, p.y + n.y) - h.ground_at(p.x - n.x, p.y - n.y)) / 2.4
			raw_cross += absf(h.base_ground_at(p.x + n.x, p.y + n.y) - h.base_ground_at(p.x - n.x, p.y - n.y)) / 2.4
			bumps += absf(h.ground_at(points[j - 4].x, points[j - 4].y) - 2.0 * h.ground_at(p.x, p.y) + h.ground_at(points[j + 4].x, points[j + 4].y))
			raw_bumps += absf(h.base_ground_at(points[j - 4].x, points[j - 4].y) - 2.0 * h.base_ground_at(p.x, p.y) + h.base_ground_at(points[j + 4].x, points[j + 4].y))
			change = maxf(change, absf(h.ground_at(p.x, p.y) - h.base_ground_at(p.x, p.y)))
			low = minf(low, h.ground_at(p.x, p.y))
			high = maxf(high, h.ground_at(p.x, p.y))
			raw_low = minf(raw_low, h.base_ground_at(p.x, p.y))
			raw_high = maxf(raw_high, h.base_ground_at(p.x, p.y))
		for endpoint: int in [0, points.size() - 1]:
			var p := points[endpoint]
			check(absf(h.ground_at(p.x, p.y) - h.base_ground_at(p.x, p.y)) < 0.02, "ступенька у конца маршрута")
	if ride:
		var p := PlayerState.new()
		var b := BikeRide.new()
		b.x = 48.0
		b.z = 130.0
		b.y = h.ground_at(b.x, b.z)
		b.heading = -PI * 0.5
		b.mount(p)
		for j in 600:
			b.step(p, 1.0, 0.0, true, false, 1.0 / 60.0, w, h)
			check(not b.crashed and is_finite(b.y), "велосипед не проехал контрольное полотно")
		check(b.x > 165.0, "велосипед не прошёл подъём и впадину")
	var divisor := maxi(1, samples)
	var result := {power = power / divisor, cross = cross / divisor, raw_cross = raw_cross / divisor,
		bumps = bumps / divisor, raw_bumps = raw_bumps / divisor, change = change,
		height_range = high - low, raw_range = raw_high - raw_low}
	print("%s: путей %d, сила %.2f, крен %.2f → %.2f %%, перегибы %.3f → %.3f м, изменение оси до %.3f м" % [label,
		after.fit_routes.size(), result.power, result.raw_cross * 100.0, result.cross * 100.0, result.raw_bumps, result.bumps, change])
	if label == "короткий подъём и впадина":
		print("  перепад высот: %.2f → %.2f м" % [result.raw_range, result.height_range])
	return result


func _network() -> void:
	var straight := _world("bank")
	straight.trails[0].pts = [straight.trails[0].pts[0], straight.trails[0].pts[-1]]
	straight.trails[0].surf = PackedByteArray([RoadSurface.DIRT, RoadSurface.DIRT])
	var long_road := Heightfield.new(straight)
	check(long_road.road_refinement.fit_routes[0].strength[80] > 0.5, "длинный прямой сегмент ошибочно принят за серпантин")
	var w := _world("bank")
	for row: float in [20.5, 44.5]:
		var t: Dictionary = w.trails[0].duplicate(true)
		for p: Dictionary in t.pts:
			p.y = row
		t.kind = "trail" if row < 32.0 else "road"
		w.trails.append(t)
	var h := Heightfield.new(w)
	check(h.road_refinement.fit_routes.size() == 3, "обработана только одна дорога сети")
	var roads := h.road_refinement.fit_routes
	check(roads[1].strength[80] < roads[0].strength[80], "тропа обработана так же сильно, как основная дорога")
	for z: float in [130.0, 178.0]:
		var change := 0.0
		for x: float in [80.0, 100.0, 140.0, 170.0]:
			change = maxf(change, absf(h.ground_at(x, z) - h.base_ground_at(x, z)))
		check(change > 0.02, "вторая дорога сети фактически не обработана")
	# Берег и сооружения на прямой: ни одно окно профиля не должно их перескакивать.
	for x in w.W:
		w.dist_water[32 * w.W + x] = maxf(0.0, (absf((x + 0.5) * 4.0 - 130.0) - 4.0) / 4.0)
	w.bridges = [{a = 32 * w.W + 30, b = 32 * w.W + 34}]
	var protected := Heightfield.new(w)
	for s: Dictionary in protected.structures:
		for n in 41:
			var x := lerpf(s.ax - 5.0, s.bx + 5.0, n / 40.0)
			var z: float = s.az
			check(absf(protected.ground_at(x, z) - protected.base_ground_at(x, z)) < 0.001, "сдвинут настил или подход к мосту")
	var fit: Dictionary = protected.road_refinement.fit_routes[0]
	for j in fit.points.size() - 1:
		check(absf(fit.strength[j + 1] - fit.strength[j]) < 0.18, "резкое включение обработки у берега/сооружения")
	w.bridges.clear()
	w.tunnels = [{a = 32 * w.W + 30, b = 32 * w.W + 34}]
	var tunnel := Heightfield.new(w)
	var axis: Dictionary = tunnel.structures[0]
	check(absf(tunnel.ground_at(axis.ax, axis.az) - axis.ay) < 0.001 and absf(tunnel.ground_at(axis.bx, axis.bz) - axis.by) < 0.001, "ступенька на входе в туннель")
	w.tunnels.clear()
	w.trails[0].kind = "mountain"
	check(not Heightfield.new(w).road_refinement.fit_routes.has(0), "горная тропа получила сильное выравнивание")
