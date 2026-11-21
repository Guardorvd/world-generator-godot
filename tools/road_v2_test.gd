extends SceneTree
## Стенд ядра дорожной сети V2 (docs/ROAD_NETWORK_V2_PLAN_2026_11_21.md, фаза 1) без генерации мира: синтетические
## сцены 96×96 — равнина, холм, крутой склон, вода поперёк долины (озеро — без брода, река — с бродом), сеть из
## шести мест. Проверки: земля и глубина C# = Heightfield; валидатор (вода, крен, уклон, радиус, зазор, брод);
## профиль C# = RoadLine.profile_ok; грубый граф = обход по клеткам и путь в окне; D_net = Дейкстра по осям;
## двойное пересечение; порты правил V1 = StageTrails; повтор планировщика даёт тот же результат.
##   godot --headless --path . --script res://tools/road_v2_test.gd
## Лимит 60 с (обычно несколько секунд). Нужен dotnet build после правки .cs.

const V2 := preload("res://scripts/world/road_network_v2.gd")
const S := 96
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var started := Time.get_ticks_msec()
	if Grid.native_grid() == null:
		print("FAIL нужен C# (dotnet build)")
		quit(1)
		return
	_ground_parity()
	_validator()
	_coarse()
	_graph()
	_ports()
	_refresh()
	_repeat()
	_line_port()
	_smooth_foreign_axis()
	_character_on_flat()
	_short_ride_turnback()
	_flag_check()
	print("ROAD V2 TEST %d failures, %d мс" % [fails, Time.get_ticks_msec() - started])
	quit(1 if fails else 0)


## Синтетический мир: water — "none" | "lake" | "river" (полоса x = 44..45 поперёк карты)
func _world(water: String) -> WorldData:
	var w := WorldData.new()
	w.W = S; w.H = S; w.N = S * S
	w.seed_text = "road v2 fixture"
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var value: Variant = owner.get(property.name)
			if value is GridBuffer2D.Float32 or value is GridBuffer2D.Byte or value is GridBuffer2D.Int32: value.resize()
	w.dist_water.fill(100)
	var cost := PackedFloat32Array()
	cost.resize(w.N)
	for y in S:
		for x in S:
			var i := y * S + x
			var h := 0.1 + x * 0.0002
			var d2 := float((x - 24) * (x - 24) + (y - 72) * (y - 72))
			if d2 < 100.0: h += 0.06 * (1.0 - d2 / 100.0)  # холм
			if x >= 64: h += minf(x - 64, 16) * 0.0123     # крутой склон 0,8
			w.h[i] = h
			w.filled[i] = h
			w.biome[i] = Biomes.FOREST if x < 20 else Biomes.GRASS
			cost[i] = 2.0
			if x in [44, 45]:
				if water == "lake":
					w.lake[i] = 1
					w.filled[i] = h + 0.004
					cost[i] = INF
				elif water == "river":
					w.river[i] = 1
					w.geology.river_area.data[i] = 1
					cost[i] = 14.0
	w.cost = cost
	w.path_mask = PackedByteArray()
	w.path_mask.resize(w.N)
	w.trails = []
	StageTrails._net_reset(w)
	return w


func _surface(w: WorldData) -> Heightfield:
	var h := Heightfield.new(w, false)
	# короткая лента реки у (82, 20) для глубины по треугольникам (как fast_water_test)
	h.ribbons = [[{left = Vector3(326, h.hv[20 * S + 81] + 0.6, 76), right = Vector3(334, h.hv[20 * S + 83] + 0.6, 76)},
		{left = Vector3(326, h.hv[24 * S + 81] + 0.6, 96), right = Vector3(334, h.hv[24 * S + 83] + 0.6, 96)}]]
	h.index_ribbons()
	h._fast_water = null # снимок воды C# — заново, с этой лентой
	return h


func _finder(w: WorldData, surface: Heightfield) -> Pathfinder:
	var finder := Pathfinder.new(w.W, w.H, StageTrails._route_heights(w, surface))
	finder.max_cross_grade = StageTrails.BENCH_CROSS
	finder.set_world_corridor(surface.hv, surface.water_level, w.ocean, w.lake, w.river_cells(), GameConfig.TILE,
		RoadTuning.current().section.widths.trail * 0.5)
	return finder


func _core(w: WorldData, surface: Heightfield, finder: Pathfinder, extra: Dictionary, unsafe := PackedByteArray()) -> Dictionary:
	if unsafe.is_empty(): unsafe.resize(w.N)
	var on_axis := PackedByteArray()
	on_axis.resize(w.N)
	var d := V2.params(w)
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var starts := PackedInt32Array()
	for t: Dictionary in w.trails:
		starts.append(xs.size())
		for p: Dictionary in t.pts:
			xs.append(p.x)
			ys.append(p.y)
	starts.append(xs.size())
	var noise := PackedFloat64Array()
	noise.resize(w.N)
	for i in w.N: noise[i] = sin(i % S * 0.21) * cos(i / S * 0.17)
	d.merge({cost = w.cost, heights = finder.heights, links = PackedByteArray(), hv = surface.hv, h = w.h, ocean = w.ocean,
		lake = w.lake, river = w.river_cells(), biome = w.biome, unsafe = unsafe, on_axis = on_axis, noise = noise,
		forest_biomes = PackedInt32Array([Biomes.FOREST]), owner = w.generation.road_owner, mask = w.path_mask,
		sections = w.trails.size(), sec_x = xs, sec_y = ys, sec_start = starts, settle = PackedInt32Array(), remote = PackedByteArray()})
	d.merge(extra, true)
	var out: Dictionary = finder.fast().PlanNetworkV2(d, surface.fast_water())
	if out.has("error"):
		print("FAIL ошибка ядра: ", out.error)
		fails += 1
		return {}
	return out


func _ground_parity() -> void:
	var w := _world("lake")
	var surface := _surface(w)
	var finder := _finder(w, surface)
	var pts := PackedFloat64Array()
	for k in 400:
		pts.append(4.0 + fmod(k * 37.7, 370.0))
		pts.append(4.0 + fmod(k * 53.3, 370.0))
	for k in 20: # над озером и лентой реки
		pts.append(176.0 + k * 0.3)
		pts.append(200.0)
		pts.append(330.0)
		pts.append(78.0 + k)
	var out := _core(w, surface, finder, {mode = "probe", probe = "ground", points = pts})
	if out.is_empty(): return
	var worst_g := 0.0
	var worst_d := 0.0
	var wet := 0
	for k in pts.size() / 2:
		worst_g = maxf(worst_g, absf(out.ground[k] - surface.ground_at(pts[2 * k], pts[2 * k + 1])))
		var d := surface.depth_at(pts[2 * k], pts[2 * k + 1])
		worst_d = maxf(worst_d, absf(out.depth[k] - d))
		if absf(out.depth[k] - d) > 1e-5 and OS.get_cmdline_user_args().has("--debug"): print("  глубина (%.2f, %.2f): C# %.3f, GDScript %.3f" % [pts[2 * k], pts[2 * k + 1], out.depth[k], d])
		if d > 0.0: wet += 1
	check(worst_g <= 1e-5 and worst_d <= 1e-5 and wet > 10, "земля и глубина C# = Heightfield (расхождение %s / %s м, точек в воде %d)" % [str(worst_g), str(worst_d), wet])


func _line(ax: float, ay: float, bx: float, by: float) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var n := maxi(1, ceili(Vector2(ax, ay).distance_to(Vector2(bx, by)) / 0.25))
	for k in n + 1:
		out.append(lerpf(ax, bx, float(k) / n))
		out.append(lerpf(ay, by, float(k) / n))
	return out


func _network(w: WorldData) -> Array:
	# Шесть мест: кольцо P0-P1-P2-P3-P5-P0 и ветка J-P4 (J на оси P1-P2)
	var p := [Vector2(8.5, 8.5), Vector2(30.5, 8.5), Vector2(30.5, 30.5), Vector2(8.5, 30.5), Vector2(40.5, 19.5), Vector2(8.5, 19.5)]
	var j := Vector2(30.5, 19.5)
	var lines := [[p[0], p[1]], [p[1], p[2]], [p[2], p[3]], [j, p[4]], [p[3], p[5]], [p[5], p[0]]]
	w.trails = []
	for k in lines.size():
		var a: Vector2 = lines[k][0]
		var b: Vector2 = lines[k][1]
		var pts: Array = []
		var n := ceili(a.distance_to(b))
		for s in n + 1:
			var q := a.lerp(b, float(s) / n)
			pts.append({x = q.x, y = q.y, w = 0.55})
			var c := floori(q.y) * S + floori(q.x)
			if w.generation.road_owner[c] < 0: w.generation.road_owner[c] = k
			w.path_mask[c] = 2
		w.trails.append({kind = "trail", pts = pts})
	return p


func _validator() -> void:
	var w := _world("lake")
	var surface := _surface(w)
	var finder := _finder(w, surface)
	_network(w)
	var tw: float = RoadTuning.current().section.widths.trail
	var cases := [
		{name = "ровная прямая", pts = _line(50.5, 50.5, 60.5, 50.5), width = tw, grade = 0.4, want = 0},
		{name = "через озеро", pts = _line(40.5, 50.5, 50.5, 50.5), width = tw, grade = 0.4, want = V2Flags.WATER},
		{name = "вдоль крутого склона (крен)", pts = _line(72.5, 40.5, 72.5, 50.5), width = 1.0, grade = 0.4, want = V2Flags.CROSS},
		{name = "в лоб на склон (уклон)", pts = _line(66.5, 45.5, 76.5, 45.5), width = tw, grade = 0.4, want = V2Flags.GRADE},
		{name = "острый угол (радиус)", pts = PackedFloat64Array([55.5, 60.5, 55.9, 60.5, 55.9, 60.9]), width = tw, grade = 0.4, want = V2Flags.RADIUS},
		{name = "вплотную вдоль дороги (зазор)", pts = _line(14.5, 9.5, 24.5, 9.5), width = tw, grade = 0.4, gap = true, want = V2Flags.GAP},
	]
	var data := []
	for c: Dictionary in cases: data.append({pts = c.pts, width = c.width, grade = c.grade, gap = c.get("gap", false)})
	var out := _core(w, surface, finder, {mode = "probe", probe = "validator", cases = data})
	if out.is_empty(): return
	for k in cases.size():
		var got: int = out.flags[k]
		var want: int = cases[k].want
		check(got == want if want == 0 else (got & want) != 0, "валидатор: %s (флаги %d)" % [cases[k].name, got])
	# профиль: C# = RoadLine.profile_ok на подъёме по склону и по холму
	var same := true
	for line: PackedFloat64Array in [_line(60.5, 45.5, 70.5, 45.5), _line(14.5, 72.5, 34.5, 72.5), _line(20.5, 60.5, 28.5, 84.5)]:
		for grade: float in [0.1, 0.3, 0.5, 0.9]:
			var pts: Array = []
			for k in line.size() / 2: pts.append(Vector2(line[2 * k], line[2 * k + 1]))
			var r := _core(w, surface, finder, {mode = "probe", probe = "profile", pts = line, grade = grade})
			same = same and not r.is_empty() and bool(r.ok) == StageTrails.RoadLine.profile_ok(surface, pts, grade)
	check(same, "профиль C# = RoadLine.profile_ok (3 линии × 4 предела)")
	# брод: две клетки реки — можно, три подряд или небезопасная — нет
	var rw := _world("river")
	var rs := _surface(rw)
	var rf := _finder(rw, rs)
	var across := PackedInt32Array([50 * S + 43, 50 * S + 44, 50 * S + 45, 50 * S + 46])
	var along := PackedInt32Array([50 * S + 44, 51 * S + 44, 52 * S + 44, 53 * S + 44])
	var unsafe := PackedByteArray()
	unsafe.resize(rw.N)
	unsafe[60 * S + 44] = 1
	var bad := PackedInt32Array([60 * S + 43, 60 * S + 44, 60 * S + 45, 60 * S + 46])
	var fords := [{pts = _line(43.5, 50.5, 46.5, 50.5), cells = across, width = tw, grade = 0.4},
		{pts = _line(44.5, 50.5, 44.5, 53.5), cells = along, width = tw, grade = 0.4},
		{pts = _line(43.5, 60.5, 46.5, 60.5), cells = bad, width = tw, grade = 0.4}]
	var fo := _core(rw, rs, rf, {mode = "probe", probe = "validator", cases = fords}, unsafe)
	if not fo.is_empty():
		check(fo.flags[0] & V2Flags.FORD == 0 and fo.flags[1] & V2Flags.FORD != 0 and fo.flags[2] & V2Flags.FORD != 0,
			"брод: поперёк 2 клетки — да, вдоль 3 — нет, небезопасный — нет (%s)" % str(fo.flags))


## Обход по клеткам (то же правило шага, что у грубого графа): достижима ли t из s
func _bfs(w: WorldData, heights: PackedFloat32Array, cost: PackedFloat32Array, s: int, t: int) -> bool:
	var seen := PackedByteArray()
	seen.resize(w.N)
	var queue := PackedInt32Array([s])
	seen[s] = 1
	var at := 0
	while at < queue.size():
		var c := queue[at]
		at += 1
		if c == t: return true
		for k in 8:
			var nx: int = c % S + Grid.DX[k]
			var ny: int = c / S + Grid.DY[k]
			if nx < 0 or ny < 0 or nx >= S or ny >= S: continue
			var n := ny * S + nx
			if seen[n] != 0 or cost[n] == INF: continue
			var diag := Grid.DX[k] != 0 and Grid.DY[k] != 0
			if absf(heights[n] - heights[c]) > 0.4 * (Grid.SQRT2 if diag else 1.0) + 1e-9: continue
			if diag and cost[(c / S) * S + nx] == INF and cost[ny * S + c % S] == INF: continue
			seen[n] = 1
			queue.append(n)
	return false


func _coarse() -> void:
	var pairs := PackedInt32Array([50 * S + 20, 50 * S + 60, 72 * S + 10, 72 * S + 36, 40 * S + 60, 40 * S + 90, 10 * S + 10, 90 * S + 40])
	var expect := {lake = [false, true, false, true], river = [true, true, false, true], none = [true, true, false, true]}
	for water: String in ["none", "lake", "river"]:
		var w := _world(water)
		var surface := _surface(w)
		var finder := _finder(w, surface)
		var out := _core(w, surface, finder, {mode = "probe", probe = "coarse", pairs = pairs})
		if out.is_empty(): continue
		var same := true
		var routed := true
		for k in pairs.size() / 2:
			var bfs := _bfs(w, finder.heights, w.cost, pairs[2 * k], pairs[2 * k + 1])
			same = same and bool(out.linked[k]) == bfs and bfs == expect[water][k]
			if out.linked[k]: routed = routed and bool(out.routed[k])
		check(same, "грубый граф (%s): связность = обход по клеткам %s, компонент %d" % [water, str(out.linked), out.components])
		check(routed, "грубый граф (%s): связано ⇒ путь FindPath в окне %s" % [water, str(out.routed)])


func _graph() -> void:
	var w := _world("none")
	var surface := _surface(w)
	var finder := _finder(w, surface)
	var p := _network(w)
	var settle := PackedInt32Array()
	for q: Vector2 in p: settle.append(floori(q.y) * S + floori(q.x))
	var u := PackedFloat64Array([14.5, 5.5, 14.5, 12.5, 20.5, 12.5, 20.5, 5.5])
	var once := PackedFloat64Array([14.5, 5.5, 14.5, 12.5, 14.5, 16.0])
	var out := _core(w, surface, finder, {mode = "probe", probe = "graph", settle = settle, remote = PackedByteArray([0, 0, 0, 0, 0, 0]),
		polylines = [u, once]})
	if out.is_empty(): return
	# Ожидание: Флойд по узлам P0..P5, J с длинами осей
	var j := Vector2(30.5, 19.5)
	var nodes: Array = p + [j]
	var edges := [[0, 1], [1, 6], [6, 2], [2, 3], [6, 4], [3, 5], [5, 0]]
	var n := nodes.size()
	var d := []
	for a in n:
		d.append([])
		for b in n: d[a].append(0.0 if a == b else INF)
	for e: Array in edges:
		var l: float = (nodes[e[0]] as Vector2).distance_to(nodes[e[1]])
		d[e[0]][e[1]] = l
		d[e[1]][e[0]] = l
	for k in n:
		for a in n:
			for b in n: d[a][b] = minf(d[a][b], d[a][k] + d[k][b])
	var worst := 0.0
	for a in 6:
		for b in 6: worst = maxf(worst, absf(out.dnet[a * 6 + b] - d[a][b]))
	check(worst < 1e-6, "D_net на 6 местах = Дейкстра по осям (расхождение %s), узлов %d, развилок %d" % [str(worst), out.nodes, out.junctions])
	check(out.junctions == 1, "одна развилка (J на оси P1–P2)")
	check(out.double_cross[0] and not out.double_cross[1], "двойное пересечение найдено, одиночное — нет (%s)" % str(out.double_cross))


func _ports() -> void:
	var w := _world("none")
	var surface := _surface(w)
	var finder := _finder(w, surface)
	_network(w)
	var paths := []
	# вдоль дороги P0–P1 через клетку (20 клеток), поперёк с двумя касаниями, от места и обратно, по новой земле
	var along := PackedInt32Array()
	along.append(8 * S + 8)
	for x in range(8, 32): along.append(10 * S + x)
	paths.append(along)
	var zig := PackedInt32Array()
	for y in range(4, 14): zig.append(y * S + 16)
	for x in range(17, 22): zig.append(13 * S + x)
	for y in range(12, 3, -1): zig.append(y * S + 22)
	paths.append(zig)
	var loop := PackedInt32Array()
	for x in range(8, 14): loop.append(8 * S + x)
	for x in range(14, 18): loop.append(12 * S + x)
	for x in range(18, 22): loop.append(8 * S + x)
	for y in range(9, 30): loop.append(y * S + 22)
	paths.append(loop)
	var fresh := PackedInt32Array()
	for k in 40: fresh.append((40 + k / 2) * S + 50 + k)
	paths.append(fresh)
	var out := _core(w, surface, finder, {mode = "probe", probe = "ports", paths = paths})
	if out.is_empty(): return
	var near := StageTrails._net_near(w)
	var net := StageTrails._net_cells(w)
	var same := true
	for k in paths.size():
		var r: Dictionary = out.ports[k]
		var q: PackedInt32Array = paths[k]
		var side := StageTrails._parallel_stats(w, q, near, net)
		var ok: bool = is_equal_approx(r.share, side.x) and int(r.longest) == int(side.y) and bool(r.rejoins) == StageTrails._rejoins(w, q) \
			and bool(r.exit_a) == StageTrails._exit_loop(w, q, false) and bool(r.exit_b) == StageTrails._exit_loop(w, q, true) \
			and PackedInt32Array(r.beyond) == StageTrails._beyond_exits(w, q) and PackedInt32Array(r.core) == StageTrails._core(w, q) \
			and bool(r.new_ground) == StageTrails._new_ground(w, q)
		if not ok: print("  путь %d: C# %s, GDScript %.3f/%d %s %s %s" % [k, str(r).left(200), side.x, side.y, StageTrails._rejoins(w, q),
			StageTrails._exit_loop(w, q, false), StageTrails._exit_loop(w, q, true)])
		same = same and ok
	var cells := PackedInt32Array()
	for q: PackedInt32Array in paths: cells.append_array(q)
	same = same and finder.fast().CorridorMask(w.W, w.H, cells, StageTrails.AVOID_R) == StageTrails._corridor(w, paths)
	var lw := _world("lake")
	same = same and finder.fast().WaterDistance(lw.W, lw.H, lw.ocean, lw.lake) == StageTrails._water_dist(lw)
	# берег и смотровые точки: точки вокруг озера и холма
	var water_d := StageTrails._water_dist(lw)
	var corr := StageTrails._corridor(lw, [PackedInt32Array([50 * S + 30, 51 * S + 30])])
	var anchors := PackedInt32Array()
	for k in 40: anchors.append((10 + (k * 7) % 76) * S + 8 + (k * 13) % 80)
	var shores: PackedInt32Array = finder.fast().ShoreTargets(lw.W, lw.H, anchors, corr, lw.cost, water_d, StageTrails.SHORE_MIN, StageTrails.SHORE_MAX)
	var views: PackedInt32Array = finder.fast().Overlooks(lw.W, lw.H, anchors, corr, lw.cost, lw.h, lw.ocean, lw.lake,
		StageTrails.VIEW_RISE / (StageTrails.HEIGHT_SCALE * GameConfig.TILE), StageTrails.VIEW_MIN, StageTrails.VIEW_MAX, StageTrails.VIEW_STEP)
	var found := [0, 0]
	for k in anchors.size():
		same = same and shores[k] == StageTrails._shore(lw, anchors[k], corr, water_d) and views[k] == StageTrails._overlook(lw, anchors[k], corr)
		found[0] += int(shores[k] >= 0)
		found[1] += int(views[k] >= 0)
	print("  берег найден у %d, смотровая у %d из %d точек" % [found[0], found[1], anchors.size()])
	same = same and found[0] > 0 and found[1] > 0
	var varied: bool = out.ports[0].longest > 0 and out.ports[1].rejoins
	check(same and varied, "порты правил V1 = StageTrails (_parallel_stats, _rejoins, _exit_loop, _beyond_exits, _core, _new_ground, _corridor, _water_dist, _shore, _overlook)")


## Шаг 3: локальное обновление полей после принятия путей = полный пересчёт (в радиусе, где их читают правила)
func _refresh() -> void:
	var w := _world("none")
	var surface := _surface(w)
	var finder := _finder(w, surface)
	var p := _network(w)
	var settle := PackedInt32Array()
	for q: Vector2 in p: settle.append(floori(q.y) * S + floori(q.x))
	# ветка от дороги P0–P1 на юг, вторая — от неё же через поле к P4, третья — тупик у холма
	var a := PackedInt32Array()
	for y in range(8, 40): a.append(y * S + 20)
	var b := PackedInt32Array()
	for x in range(20, 41): b.append(39 * S + x)
	for y in range(38, 19, -1): b.append(y * S + 40)
	var c := PackedInt32Array()
	for k in 20: c.append((60 + k) * S + 8 + k / 2)
	var out := _core(w, surface, finder, {mode = "probe", probe = "refresh", settle = settle, remote = PackedByteArray([0, 0, 0, 0, 0, 0]),
		accept = [a, b, c]})
	if out.is_empty(): return
	check(out.compared > 1000 and out.mismatch == 0 and out.mismatch_cost == 0 and out.worst[0] < 1e-5 and out.worst[1] < 1e-5,
		"локальное обновление = полному пересчёту: пороги правил и цена совпали, значения до округления float (сравнено %d, смен порога %d, цена %d, наибольшее отличие %s)" % [out.compared, out.mismatch, out.mismatch_cost, str(out.worst)])


func _repeat() -> void:
	var hashes := []
	for run in 2:
		var w := _world("river")
		var surface := _surface(w)
		var finder := _finder(w, surface)
		var p := _network(w)
		var settle := PackedInt32Array()
		for q: Vector2 in p: settle.append(floori(q.y) * S + floori(q.x))
		var pairs := PackedInt32Array()
		for a in 6:
			for b in range(a + 1, 6):
				pairs.append(a)
				pairs.append(b)
		var common := {settle = settle, remote = PackedByteArray([0, 0, 0, 0, 0, 0]), exit_r = 4.0, node_sep = 6.0}
		var loops := _core(w, surface, finder, common.merged({mode = "loops", pairs = pairs}))
		var spurs := _core(w, surface, finder, common.merged({mode = "spurs", targets = PackedInt32Array([72 * S + 24, 50 * S + 60]),
			target_kinds = PackedInt32Array([1, 1]), anchors = PackedInt32Array([-1, -1]), max_shores = 2, max_views = 6}))
		if loops.is_empty() or spurs.is_empty(): return
		var key := []
		for out: Dictionary in [loops, spurs]:
			key.append([out.paths, out.what, out.network_v2.counts, out.network_v2.rejects])
		if run == 0: print("  повтор: петли %s %s, ответвления %s %s" % [JSON.stringify(loops.network_v2.counts), JSON.stringify(loops.network_v2.rejects),
			JSON.stringify(spurs.network_v2.counts), JSON.stringify(spurs.network_v2.rejects)])
		hashes.append(var_to_bytes(key).hex_encode().sha256_text())
	check(hashes.size() == 2 and hashes[0] == hashes[1], "повтор: два прогона планировщика — один результат")


## Фаза 3.1: линия на C# (LineBuilder) = RoadLine.build на синтетике: пути поиска по холму, крутому склону и равнине,
## виды road/trail/mountain, расчёт другого вида (smooth_kind), примыкания, оси сооружений; точки до 1e-6 клетки.
func _line_port() -> void:
	V2.smooth_lines = false # 3.1: линия ровно как RoadLine.build
	var total := [0, 0, 0.0, [0, 0]]
	for bumpy in [false, true]:
		var r := _line_world(bumpy)
		total[0] += r[0]
		total[1] += r[1]
		total[2] = maxf(total[2], r[2])
		total[3][0] += r[3][0]
		total[3][1] += r[3][1]
	# откат поблажки (профиль 12 м) на синтетике редок; на мире он есть (Ущелье) — там его сверяет --compare
	check(total[0] >= 40 and total[1] == 0 and total[2] <= 1e-6 and total[3][0] == total[3][1],
		"линия C# = RoadLine.build: случаев %d, разное число точек %d, наибольшее расхождение %s, откатов поблажки %s" % total)
	V2.smooth_lines = true
	_smooth_check()


## Фаза 3.4: сглаживание по прорежённой линии не ухудшает линию (уклон/крен/профиль, концы побитно, плотность станций
## как у V1), выпрямляет лесенку 4–8 м, сглаживает разворот без зубца, не делает угол на хорде 4 м острее, не двигает
## концы, подходы к сооружениям и смены ширины.
func _smooth_check() -> void:
	var w := _world("river")
	var surface := _surface(w)
	var finder := _finder(w, surface)
	var axis := PackedByteArray()
	axis.resize(w.N)
	var widths: Dictionary = RoadTuning.current().section.widths
	var worse := 0
	var angle_worse := 0
	var moved := 0
	var lines := 0
	var ends_ok := true
	var density_ok := true
	for e: Array in [[8 * S + 8, 70 * S + 30], [30 * S + 10, 85 * S + 60], [60 * S + 30, 20 * S + 90], [90 * S + 8, 10 * S + 70], [12 * S + 50, 88 * S + 50]]:
		for kind: String in ["road", "trail", "mountain"]:
			var grade: float = StageTrails.MOUNTAIN_GRADE if kind == "mountain" else (StageTrails.TRAIL_GRADE if kind == "trail" else StageTrails.ROAD_LIMIT)
			var cells := finder.find_path(w.cost, e[0], e[1], 1.0, grade, -1, 4.0, 0.0)
			if cells.size() < 4: continue
			var pts: Array = []
			for c: int in cells: pts.append({x = c % S + 0.5, y = c / S + 0.5, w = widths[kind]})
			V2.smooth_lines = false
			var plain := V2.line(w, pts.duplicate(true), axis, surface, kind)
			V2.smooth_lines = true
			var smooth := V2.line(w, pts.duplicate(true), axis, surface, kind)
			lines += 1
			ends_ok = ends_ok and plain[0].x == smooth[0].x and plain[0].y == smooth[0].y \
				and plain[-1].x == smooth[-1].x and plain[-1].y == smooth[-1].y
			density_ok = density_ok and smooth.size() >= int(plain.size() * 0.5) and smooth.size() <= int(plain.size() * 1.8) + 2
			var relax: float = RoadTuning.current().routing.line_relax[kind]
			if _bad(surface, plain, grade, relax) < _bad(surface, smooth, grade, relax): worse += 1
			var sp := _chord_stats(plain)
			var ss := _chord_stats(smooth)
			if ss.dense_max_ang > sp.dense_max_ang + 0.5:
				angle_worse += 1
				print("  угол острее на %s %s: %.1f° -> %.1f°" % [str(e), kind, sp.dense_max_ang, ss.dense_max_ang])
			var line_moved := smooth.size() != plain.size()
			if not line_moved:
				for k in plain.size():
					if plain[k].x != smooth[k].x or plain[k].y != smooth[k].y:
						line_moved = true
						break
			if line_moved: moved += 1
	check(lines >= 4 and ends_ok and density_ok and worse == 0 and moved > 0,
		"сглаживание: линий %d, сдвинуто %d, ухудшений %d, плотность в норме %s, концы побитно %s" % [lines, moved, worse, density_ok, ends_ok])

	# Случай 1: лесенка 4–8 м выпрямляется (плоский участок)
	var fw := _world("none")
	var fs := _surface(fw)
	var faxis := PackedByteArray()
	faxis.resize(fw.N)
	var stair4: Array = []
	for k in 10:
		stair4.append({x = 10.5 + k, y = 20.5 + k, w = widths.trail})
		stair4.append({x = 11.5 + k, y = 20.5 + k, w = widths.trail})
	stair4.append({x = 20.5, y = 30.5, w = widths.trail})
	var stair8: Array = [{x = 9.0, y = 20.5, w = widths.trail}]
	for k in 7:
		stair8.append({x = 10.5 + 2 * k, y = 20.5 + 2 * k, w = widths.trail})
		stair8.append({x = 12.5 + 2 * k, y = 20.5 + 2 * k, w = widths.trail})
	stair8.append({x = 24.5, y = 34.5, w = widths.trail})
	StageTrails.routing_overrides.straighten = {road = 0.0, trail = 0.0, mountain = 0.0}
	V2.smooth_lines = false
	var p4 := V2.line(fw, stair4.duplicate(true), faxis, fs, "trail")
	var p8 := V2.line(fw, stair8.duplicate(true), faxis, fs, "trail")
	V2.smooth_lines = true
	var s4 := V2.line(fw, stair4.duplicate(true), faxis, fs, "trail")
	var s8 := V2.line(fw, stair8.duplicate(true), faxis, fs, "trail")
	StageTrails.routing_overrides.erase("straighten")
	var st_p4 := _chord_stats(p4)
	var st_s4 := _chord_stats(s4)
	var st_p8 := _chord_stats(p8)
	var st_s8 := _chord_stats(s8)
	check(st_p4.kinks > 0 and st_s4.kinks == 0 and st_s4.corners <= st_p4.corners \
		and st_p8.dense_max_ang > 35.0 and st_s8.kinks == 0 and st_s8.corners <= st_p8.corners \
		and st_s4.dense_max_ang < st_p4.dense_max_ang * 0.65 and st_s8.dense_max_ang < st_p8.dense_max_ang * 0.65 \
		and st_s4.dense_max_ang < 35.0 and st_s8.dense_max_ang < 35.0,
		"лесенка 4–8 м выпрямляется: 4м kinks %d→%d corners %d→%d max %.1f°→%.1f°, 8м kinks %d→%d corners %d→%d max %.1f°→%.1f°" % [
			st_p4.kinks, st_s4.kinks, st_p4.corners, st_s4.corners, st_p4.dense_max_ang, st_s4.dense_max_ang,
			st_p8.kinks, st_s8.kinks, st_p8.corners, st_s8.corners, st_p8.dense_max_ang, st_s8.dense_max_ang])

	# Случай 2: разворот > 105° без зубца (нет роста hairpins и острых зубцов)
	var upts: Array = []
	for q: Vector2 in [Vector2(14.5, 18.5), Vector2(16.5, 18.5), Vector2(18.5, 18.5), Vector2(20.5, 18.5), Vector2(22.5, 18.5),
			Vector2(23.3, 19.3), Vector2(22.7, 20.1), Vector2(21.0, 20.7), Vector2(18.5, 21.3), Vector2(16.0, 21.7), Vector2(14.5, 22.0)]:
		upts.append({x = q.x, y = q.y, w = widths.trail})
	StageTrails.routing_overrides.straighten = {road = 0.0, trail = 0.0, mountain = 0.0}
	V2.smooth_lines = false
	var pu := V2.line(fw, upts.duplicate(true), faxis, fs, "trail")
	V2.smooth_lines = true
	var su := V2.line(fw, upts.duplicate(true), faxis, fs, "trail")
	StageTrails.routing_overrides.erase("straighten")
	var st_pu := _chord_stats(pu)
	var st_su := _chord_stats(su)
	check(st_su.hairpins <= st_pu.hairpins and st_su.kinks <= st_pu.kinks and st_su.corners <= st_pu.corners \
		and st_su.dense_max_ang <= st_pu.dense_max_ang + 0.5,
		"разворот без зубца: hairpins %d→%d, kinks %d→%d, corners %d→%d, max %.1f°→%.1f°" % [
			st_pu.hairpins, st_su.hairpins, st_pu.kinks, st_su.kinks, st_pu.corners, st_su.corners, st_pu.dense_max_ang, st_su.dense_max_ang])

	# Случай 3: угол на хорде 4 м нигде не стал острее
	if st_s4.dense_max_ang > st_p4.dense_max_ang + 0.5 or st_s8.dense_max_ang > st_p8.dense_max_ang + 0.5 or st_su.dense_max_ang > st_pu.dense_max_ang + 0.5:
		angle_worse += 1
	check(angle_worse == 0, "угол на хорде 4 м не острее (ухудшений %d)" % angle_worse)

	# Случай 4: концы, подходы к сооружениям (on_axis ± 2 кл) и смена ширины не сдвинуты (trail и road)
	var rw := _world("river")
	var rs := _surface(rw)
	var raxis := PackedByteArray()
	raxis.resize(rw.N)
	raxis[50 * S + 44] = 1
	raxis[50 * S + 45] = 1
	for bkind: String in ["trail", "road"]:
		var bpts: Array = []
		for q: Vector2 in [Vector2(33.5, 45.5), Vector2(35.5, 45.5), Vector2(36.5, 47.5), Vector2(38.5, 47.5), Vector2(40.5, 49.5),
				Vector2(42.5, 50.5), Vector2(43.5, 50.5), Vector2(44.5, 50.5), Vector2(45.5, 50.5), Vector2(46.5, 50.5),
				Vector2(47.5, 50.5), Vector2(49.5, 51.5), Vector2(51.5, 51.5), Vector2(52.5, 53.5), Vector2(54.5, 53.5), Vector2(56.5, 55.5)]:
			bpts.append({x = q.x, y = q.y, w = widths[bkind]})
		bpts[13].w = widths[bkind] * 0.8
		bpts[14].w = widths[bkind] * 0.8
		bpts[15].w = widths[bkind] * 0.8
		StageTrails.routing_overrides.straighten = {road = 0.0, trail = 0.0, mountain = 0.0}
		V2.smooth_lines = false
		var pb := V2.line(rw, bpts.duplicate(true), raxis, rs, bkind)
		V2.smooth_lines = true
		var sb := V2.line(rw, bpts.duplicate(true), raxis, rs, bkind)
		StageTrails.routing_overrides.erase("straighten")
		var pinned_ok: bool = pb[0].x == sb[0].x and pb[0].y == sb[0].y and pb[-1].x == sb[-1].x and pb[-1].y == sb[-1].y
		for p: Dictionary in [bpts[6], bpts[7], bpts[8], bpts[9], bpts[10], bpts[12], bpts[13]]:
			var found := false
			for q: Dictionary in sb:
				if absf(p.x - q.x) < 1e-6 and absf(p.y - q.y) < 1e-6:
					found = true
					break
			if not found: pinned_ok = false
		var free_moved := false
		for p: Dictionary in [bpts[2], bpts[3]]:
			var exact := false
			for q: Dictionary in sb:
				if absf(p.x - q.x) < 1e-4 and absf(p.y - q.y) < 1e-4: exact = true
			if not exact: free_moved = true
		check(pinned_ok and free_moved, "%s: концы, подходы к сооружениям и смена ширины не сдвинуты (закреплены %s, свободные сдвинуты %s)" % [bkind, pinned_ok, free_moved])

	# Случай 5: бугристый склон с relax = 1.4 — сглаживание двигает вершины, не откатывает линию и не ухудшает _bad / corners
	var bw := _world("none")
	for i in bw.N:
		var bx := i % S
		var by := i / S
		if bx >= 16 and bx <= 56:
			bw.h[i] += 0.0046 * float(bx - 16) + 0.0022 * sin(float(bx) * 1.35) * cos(float(by) * 1.15)
	var bs := _surface(bw)
	var baxis := PackedByteArray()
	baxis.resize(bw.N)
	var spts: Array = []
	for k in 13:
		spts.append({x = 18.5 + 2.0 * k, y = 42.5 + (0.0 if k % 2 == 0 else 1.5), w = widths.trail})
	StageTrails.routing_overrides.line_relax = {road = 1.4, trail = 1.4, mountain = 1.4}
	V2.smooth_lines = false
	var pbump := V2.line(bw, spts.duplicate(true), baxis, bs, "trail")
	V2.smooth_lines = true
	var sbump := V2.line(bw, spts.duplicate(true), baxis, bs, "trail")
	StageTrails.routing_overrides.erase("line_relax")
	var bump_moved := sbump.size() != pbump.size()
	if not bump_moved:
		for k in pbump.size():
			if absf(pbump[k].x - sbump[k].x) > 1e-4 or absf(pbump[k].y - sbump[k].y) > 1e-4:
				bump_moved = true
				break
	var st_pb := _chord_stats(pbump)
	var st_sb := _chord_stats(sbump)
	check(bump_moved and _bad(bs, sbump, StageTrails.TRAIL_GRADE, 1.4) <= _bad(bs, pbump, StageTrails.TRAIL_GRADE, 1.4) \
		and st_sb.corners <= st_pb.corners,
		"бугристый склон (relax=1.4): сдвинуто %s, bad %d→%d, corners %d→%d" % [
			bump_moved, _bad(bs, pbump, StageTrails.TRAIL_GRADE, 1.4), _bad(bs, sbump, StageTrails.TRAIL_GRADE, 1.4), st_pb.corners, st_sb.corners])


func _chord_stats(line: Array) -> Dictionary:
	var stations: Array[Vector2] = []
	var carry := 0.0
	for j in range(1, line.size()):
		var a := Vector2(line[j - 1].x, line[j - 1].y)
		var b := Vector2(line[j].x, line[j].y)
		var seg := a.distance_to(b)
		var s := carry
		while s < seg:
			stations.append(a.lerp(b, s / seg))
			s += 1.0
		carry = s - seg
	stations.append(Vector2(line[-1].x, line[-1].y))
	var e0 := Vector2(line[0].x, line[0].y)
	var e1 := Vector2(line[-1].x, line[-1].y)
	var near_end := func(p: Vector2) -> bool: return p.distance_squared_to(e0) <= 4.0 or p.distance_squared_to(e1) <= 4.0
	var kinks := 0
	for n in range(1, stations.size() - 1):
		if near_end.call(stations[n]): continue
		var d0 := stations[n] - stations[n - 1]
		var d1 := stations[n + 1] - stations[n]
		if d0.length() > 0.01 and d1.length() > 0.01 and absf(rad_to_deg(d0.angle_to(d1))) > 35.0:
			kinks += 1
	var corners := 0
	var last_c := Vector2(INF, INF)
	for j in range(1, line.size() - 1):
		var a := Vector2(line[j - 1].x, line[j - 1].y)
		var b := Vector2(line[j].x, line[j].y)
		var c := Vector2(line[j + 1].x, line[j + 1].y)
		if a.distance_to(b) < 0.3 or b.distance_to(c) < 0.3: continue
		if absf(rad_to_deg((b - a).angle_to(c - b))) <= 20.0: continue
		if b.distance_to(last_c) < 1.0 or near_end.call(b): continue
		last_c = b
		corners += 1
	var hairpins := 0
	var hskip := 0
	for n in range(2, stations.size() - 2):
		if near_end.call(stations[n]): continue
		var u0 := stations[n] - stations[n - 2]
		var u1 := stations[n + 2] - stations[n]
		if u0.length() > 0.01 and u1.length() > 0.01 and absf(rad_to_deg(u0.angle_to(u1))) > 110.0 and n >= hskip:
			hairpins += 1
			hskip = n + 4
	# Плотное измерение угла на хордах 4 м (каждые 0,25 кл)
	var cum := PackedFloat64Array([0.0])
	for j in range(1, line.size()):
		cum.append(cum[-1] + Vector2(line[j - 1].x, line[j - 1].y).distance_to(Vector2(line[j].x, line[j].y)))
	var total := cum[-1]
	var sample_at := func(dist: float) -> Vector2:
		var lo := 0
		var hi := cum.size() - 2
		while lo < hi:
			var mid := (lo + hi + 1) / 2
			if cum[mid] <= dist: lo = mid
			else: hi = mid - 1
		var seg := cum[lo + 1] - cum[lo]
		var t := clampf((dist - cum[lo]) / seg, 0.0, 1.0) if seg > 1e-9 else 0.0
		return Vector2(line[lo].x, line[lo].y).lerp(Vector2(line[lo + 1].x, line[lo + 1].y), t)
	var dense_max := 0.0
	var s := 1.0
	while s <= total - 1.0:
		var a: Vector2 = sample_at.call(s - 1.0)
		var p: Vector2 = sample_at.call(s)
		var b: Vector2 = sample_at.call(s + 1.0)
		if (p - a).length() > 0.01 and (b - p).length() > 0.01:
			dense_max = maxf(dense_max, absf(rad_to_deg((p - a).angle_to(b - p))))
		s += 0.25
	return {kinks = kinks, corners = corners, hairpins = hairpins, dense_max_ang = dense_max}


func _bad(surface: Heightfield, line: Array, grade: float, relax: float) -> int:
	var bad := 0
	for k in range(1, line.size()):
		if not StageTrails.RoadLine.segment_ok(surface, line[k - 1], line[k], grade * relax, StageTrails.MOUNTAIN_GRADE if grade == StageTrails.MOUNTAIN_GRADE else StageTrails.BENCH_CROSS, surface.fast_water()):
			bad += 1
	var profile: Array = []
	for p: Dictionary in line: profile.append(Vector2(p.x, p.y))
	if not StageTrails.RoadLine.profile_ok(surface, profile, grade): bad += 1
	return bad


func _line_world(bumpy: bool) -> Array:
	var w := _world("river")
	# бугры: прямая с поблажкой проходит отрезки, но окно 12 м круче — проверка отката
	if bumpy:
		for i in w.N:
			var x := i % S
			if x < 60: w.h[i] += 0.0045 * sin(x * 1.7) * sin(i / S * 1.3) + 0.0012 * x
	var surface := _surface(w)
	var finder := _finder(w, surface)
	var axis := PackedByteArray()
	axis.resize(w.N)
	for y in range(48, 53): axis[y * S + 44] = 1 # «мост» поперёк реки
	var widths: Dictionary = RoadTuning.current().section.widths
	var cases := 0
	var worst := 0.0
	var mismatch := 0
	var fallbacks := [0, 0]
	var ends := [[8 * S + 8, 70 * S + 30], [30 * S + 10, 85 * S + 60], [60 * S + 30, 20 * S + 90], [90 * S + 8, 10 * S + 70],
		[50 * S + 20, 50 * S + 70], [75 * S + 15, 40 * S + 78], [12 * S + 50, 88 * S + 50], [66 * S + 60, 30 * S + 30]]
	for e: Array in ends:
		for kind: String in ["road", "trail", "mountain"]:
			var grade: float = StageTrails.MOUNTAIN_GRADE if kind == "mountain" else (StageTrails.TRAIL_GRADE if kind == "trail" else StageTrails.ROAD_LIMIT)
			var cells := finder.find_path(w.cost, e[0], e[1], 1.0, grade, -1, 4.0, 0.0)
			if cells.size() < 4: continue
			for variant in 4:
				# вариант 3 — большая поблажка на бугры (2,5): профиль чаще круче предела, линия строится заново без неё
				if variant == 3: StageTrails.routing_overrides.line_relax = {road = 2.5, trail = 2.5, mountain = 2.5}
				var pts: Array = []
				for c: int in cells: pts.append({x = c % S + 0.5, y = c / S + 0.5, w = widths[kind]})
				var smooth := "road" if variant == 1 and kind == "trail" else ""
				var joins := {}
				if variant == 2:
					joins[0] = {tangent = Vector2(1, 0.3).normalized()}
					joins[1] = {tangent = Vector2(-0.2, 1).normalized()}
					pts[pts.size() / 2].w = widths[kind] * 0.9 # смена ширины — вершина остаётся
				var before := StageTrails.RoadLine.fallbacks
				var gd := StageTrails.RoadLine.build(w, pts.duplicate(true), axis, surface, kind, joins, Callable(), smooth)
				fallbacks[0] += StageTrails.RoadLine.fallbacks - before
				before = StageTrails.RoadLine.fallbacks
				var cs := V2.line(w, pts.duplicate(true), axis, surface, kind, joins, smooth)
				fallbacks[1] += StageTrails.RoadLine.fallbacks - before
				StageTrails.routing_overrides.erase("line_relax")
				cases += 1
				if gd.size() != cs.size():
					mismatch += 1
					print("  линия %s %s вариант %d: точек GDScript %d, C# %d" % [str(e), kind, variant, gd.size(), cs.size()])
					continue
				for k in gd.size():
					worst = maxf(worst, maxf(absf(gd[k].x - cs[k].x), maxf(absf(gd[k].y - cs[k].y), absf(gd[k].w - cs[k].w))))
	return [cases, mismatch, worst, fallbacks]


func _flag_check() -> void:
	var tuning := RoadTuning.current()
	var def_flag := StageTrails.network_v2
	var s_off: String = WorldCache._road_layer_suffixes(tuning, false).places
	var saves_off := QuickTrails.saves_dir()
	var cache_off := QuickTrails.cache_dir()
	StageTrails.network_v2 = true
	var s_on: String = WorldCache._road_layer_suffixes(tuning, false).places
	var saves_on := QuickTrails.saves_dir()
	var cache_on := QuickTrails.cache_dir()
	StageTrails.network_v2 = def_flag
	var expected := V2.cache_suffix(true)
	check(not def_flag and s_off != s_on and s_on.contains(expected)
		and saves_off == "user://saves" and cache_off == "user://world_cache"
		and saves_on == "user://saves_roads_v2" and cache_on == "user://world_cache_roads_v2",
		"флаг --roads-v2: по умолчанию выключен (%s), папки %s / %s -> %s / %s, ключ кэша (%s -> %s)" % [
			def_flag, saves_off, cache_off, saves_on, cache_on, s_off, s_on])


func _smooth_foreign_axis() -> void:
	var w := _world("none")
	var surface := _surface(w)
	var axis := PackedByteArray()
	axis.resize(w.N)
	var pts: Array = []
	var host: Array = []
	var owner := w.generation.road_owner
	for x in range(12, 41):
		host.append({x = x + 0.5, y = 20.5, w = 0.55})
		owner[20 * S + x] = 0
		pts.append({x = x + 0.5, y = 23.1 + sin((x - 12) * 0.35) * 0.65, w = 0.55})
	w.trails = [{kind = "trail", pts = host}]
	w.generation.road_owner = owner
	V2.smooth_lines = false
	var original := V2.line(w, pts, axis, surface, "trail")
	V2.smooth_lines = true
	var smoothed := V2.line(w, pts, axis, surface, "trail")
	var before := INF
	var after := INF
	for p: Dictionary in original: before = minf(before, p.y - 20.5)
	for p: Dictionary in smoothed: after = minf(after, p.y - 20.5)
	check(after >= before - 0.05 and original[0] == smoothed[0] and original[-1] == smoothed[-1],
		"сглаживание сохраняет зазор и концы рядом с чужой осью (%.2f → %.2f м)" % [before * GameConfig.TILE, after * GameConfig.TILE])


func _character_on_flat() -> void:
	var w := _world("none")
	w.h.fill(0.1)
	w.filled.fill(0.1)
	w.biome.fill(Biomes.GRASS)
	w.cost.fill(1.0)
	var noise := PackedFloat64Array()
	var axis := PackedByteArray()
	noise.resize(w.N)
	axis.resize(w.N)
	var bridge := 8 * S + 8
	axis[bridge] = 1
	w.cost[bridge] = 0.3
	const ROW := 26
	for i in w.N:
		var center := 49.0 + 5.0 * sin(PI * (i % S - 8) / 80.0)
		var distance := (i / S - center) / 13.0
		noise[i] = -exp(-0.5 * distance * distance)
	var surface := _surface(w)
	var finder := _finder(w, surface)
	_core(w, surface, finder, {mode = "character", noise = noise})
	var routing := RoadTuning.current().routing
	var start := ROW * S + 8
	var finish := ROW * S + 88
	var plain := finder.find_path(w.cost, start, finish, routing.climb_costs.road, StageTrails.ROAD_GRADE,
		-1, routing.turn_costs.road, routing.bend_costs.road)
	var revised: PackedInt32Array = finder.fast().ShapeDryRoute(plain, w.cost, axis, finder.heights, finder.links, "road",
		routing.climb_costs.road, StageTrails.ROAD_GRADE, routing.turn_costs.road, routing.bend_costs.road, finder.max_cross_grade)
	if plain.size() < 2 or revised.size() < 2:
		check(false, "равнина: оба пути построены")
		return
	var before := 0.0
	var after := 0.0
	for i: int in plain: before = maxf(before, absf(i / S - ROW) * GameConfig.TILE)
	var points := StageTrails._cell_points(w, revised, axis, RoadTuning.current().section.widths.road)
	for p: Dictionary in V2.line(w, points, axis, surface, "road"):
		after = maxf(after, absf(p.y - (ROW + 0.5)) * GameConfig.TILE)
	check(before == 0.0 and after >= 8.0 and revised[0] == start and revised[-1] == finish,
		"равнина: путь с полем не прямой (отклонение %.1f → %.1f м)" % [before, after])
	var fields: Dictionary = finder.fast().CharacterCosts(w.cost, axis, "road")
	var cost: PackedFloat32Array = fields.cost
	var minimum := 1.0
	var maximum := 1.0
	for i in w.N:
		if i == bridge: continue
		minimum = minf(minimum, cost[i])
		maximum = maxf(maximum, cost[i])
	check(minimum >= float(routing.character_field.mul_min) - 1e-6 and minimum < 1.0
		and maximum <= float(routing.character_field.mul_max) + 1e-6 and cost[bridge] == w.cost[bridge]
		and fields.heuristic_scale * 0.6 <= w.cost[bridge],
		"скидка ниже исходной цены (%.3f), пределы множителя и цена моста сохранены" % minimum)


func _short_ride_turnback() -> void:
	var w := _world("none")
	var ascent := PackedInt32Array([S + 10, S + 11, S + 12, S + 13])
	var descent := PackedInt32Array([S + 13, S + 12, S + 11, 2 * S + 11, 3 * S + 12])
	var cut := RideRoutes._short_turnback(w, ascent, descent)
	check(cut == 2 and descent[cut] == ascent[ascent.size() - 1 - cut]
		and RideRoutes._short_turnback(w, ascent, PackedInt32Array([S + 13, 2 * S + 13])) == 0,
		"короткий возврат убирается до развилки, отдельный спуск остаётся")


class V2Flags:
	const WATER := 1
	const GRADE := 2
	const CROSS := 4
	const PROFILE := 8
	const FORD := 16
	const RADIUS := 32
	const GAP := 64
