extends RefCounted
## Измеритель дорожной сети (11.11.2026, docs/ROAD_SYSTEM_AUDIT_2026_11_11.md, раздел 6): по готовым w.trails и
## path_mask, без генерации. Вызывается стендом road_plan_test.gd -- --metrics (там же картинка сети).
## Единицы — клетки мира (4 м), в отчёте метры. Пути людей — всё, кроме звериных троп; трассы парков (trail_id) не входят.
##   overlap_m   — длина, где ось одной записи лежит на оси другой (ближе 1 м, то же направление): дубль полотна
##   parallel_m  — длина, где другой путь идёт рядом в 2–40 м в том же направлении, дальше 30 м от узлов (концов путей)
##   double_cross — пар путей, пересекающихся дважды и больше на 80 м
##   kinks       — изломы > 35° между соседними хордами по 4 м, дальше 8 м от концов и сооружений (горные тропы отдельно)
##   ghost_cells — клетки с протоптанной скидкой стоимости дальше 1,5 клетки от любой линии
##   mask_orphan — клетки маски путей людей дальше 1,5 клетки от линий; line_unmasked — точки линий без маски
## 15.11.2026 (docs/ROAD_NETWORK.md, «поворот в поиске пути и петли»):
##   hairpins    — развороты > 110° на 16 м (хорды по 8 м до и после точки), один на 16 м; sharp — то же > 60°
##   grade       — по виду: доля длины круче 12 %, средний и наибольший продольный уклон на хордах 16 м
##                 по готовой поверхности (surface, вне сооружений); без surface не считается
##   Характер полотна группируется по kind. Использование участков веломаршрутами измеряется отдельно.
##   corners     — настоящие углы (с 15.11): вершина линии с поворотом > 20°, у которой оба соседних отрезка не короче
##                 0,3 клетки. Вписанная дуга (_road_curve) идёт точками через ≤ 0,25 клетки и углом не считается, даже
##                 тесная (kinks её считает); угол — место, где сглаживание оставило вершину ломаной. Один на 1 клетку.
##   raw_turns   — по виду: смены направления сырого пути A* (w.generation.road_cells) на 100 клеток, из них ≥ 90°

const BIN := 10        # клеток в ячейке индекса отрезков (40 м)
const SAMPLE := 1.0    # шаг выборки вдоль линии, клеток
const OVERLAP := 0.25  # 1 м
const NEAR_MIN := 0.5  # 2 м
const NEAR_MAX := 10.0 # 40 м
const NODE_R := 7.5    # 30 м
const PAR_COS := 0.9
const CROSS_R := 20.0  # 80 м
const KINK := 35.0
const HAIRPIN := 110.0
const SHARP := 60.0
const STEEP := 0.12
const CORNER := 20.0
const CORNER_SEG := 0.3
const Samples := preload("res://tools/road_surface_samples.gd")
const Topology := preload("res://scripts/world/road_topology.gd")
const RoadRides := preload("res://scripts/world/road_rides.gd")


static func measure(w: WorldData, base_cost := PackedFloat32Array(), surface: Heightfield = null, forest: Image = null) -> Dictionary:
	var routes: Array = []
	var excluded := {}
	for k in w.trails.size():
		var t: Dictionary = w.trails[k]
		var reason := "animal" if t.kind == "animal" else ("prepared" if t.has("trail_id") else "")
		if reason.is_empty() and t.pts.size() < 2: reason = "short_axis"
		if not reason.is_empty():
			var entry: Dictionary = excluded.get_or_add(reason, {sections = 0, axis_m = 0.0})
			entry.sections += 1
			entry.axis_m += Topology.length_m(t.pts)
			continue
		routes.append(k)
	for entry: Dictionary in excluded.values(): entry.axis_m = snappedf(entry.axis_m, 0.01)
	# индекс отрезков и концов
	var bins := {}
	var ends := {}
	var length_by_kind := {}
	for r: int in routes:
		var pts: Array = w.trails[r].pts
		var total := 0.0
		for j in range(1, pts.size()):
			var a := Vector2(pts[j - 1].x, pts[j - 1].y)
			var b := Vector2(pts[j].x, pts[j].y)
			total += a.distance_to(b)
			var box := Rect2(a, b - a).abs()
			for by in range(floori(box.position.y / BIN), floori(box.end.y / BIN) + 1):
				for bx in range(floori(box.position.x / BIN), floori(box.end.x / BIN) + 1):
					var key := Vector2i(bx, by)
					if not bins.has(key): bins[key] = []
					bins[key].append([r, a, b])
		var kind: String = String(w.trails[r].kind)
		length_by_kind[kind] = float(length_by_kind.get(kind, 0.0)) + total * GameConfig.TILE
		for p: Dictionary in [pts[0], pts[-1]]:
			var key := Vector2i(floori(p.x / BIN), floori(p.y / BIN))
			if not ends.has(key): ends[key] = []
			ends[key].append(Vector2(p.x, p.y))
	var structures: Array = []
	for s: EntityRecord in w.bridges + w.tunnels:
		structures.append([Vector2(s.a % w.W + 0.5, s.a / w.W + 0.5), Vector2(s.b % w.W + 0.5, s.b / w.W + 0.5)])
	var overlap := 0.0
	var parallel := 0.0
	var spots: Array = [] # [point, "overlap" | "parallel"]
	var pairs := {} # "r:other:вид" -> м
	var kinks := {road = 0, trail = 0, mountain = 0}
	var kink_spots: Array = []
	var corners := {road = 0, trail = 0, mountain = 0}
	var corner_spots: Array = []
	var hairpins := {road = 0, trail = 0, mountain = 0}
	var sharp := {road = 0, trail = 0, mountain = 0}
	var hairpin_spots: Array = []
	var grade_acc := {} # вид -> [длина, длина круче STEEP, сумма уклон×длина, наибольший]
	var grade_at := {} # вид -> [путь, x, y, рядом с концом пути (16 м)] — где наибольший уклон
	var crossings := {} # пара -> [точки]
	var line_cells := PackedByteArray()
	line_cells.resize(w.N)
	var unmasked := 0
	var samples := 0
	for r: int in routes:
		var t: Dictionary = w.trails[r]
		var pts: Array = t.pts
		# равномерная выборка
		var stations: Array[Vector2] = []
		var carry := 0.0
		for j in range(1, pts.size()):
			var a := Vector2(pts[j - 1].x, pts[j - 1].y)
			var b := Vector2(pts[j].x, pts[j].y)
			var seg := a.distance_to(b)
			var s := carry
			while s < seg:
				stations.append(a.lerp(b, s / seg))
				s += SAMPLE
			carry = s - seg
			# пересечения с отрезками других путей (каждая пара отрезков один раз: другой путь с большим номером)
			var box := Rect2(a, b - a).abs()
			var seen := {}
			for by in range(floori(box.position.y / BIN), floori(box.end.y / BIN) + 1):
				for bx in range(floori(box.position.x / BIN), floori(box.end.x / BIN) + 1):
					for o: Array in bins.get(Vector2i(bx, by), []):
						if o[0] <= r: continue
						var id := "%d:%s:%s" % [o[0], o[1], o[2]]
						if seen.has(id): continue
						seen[id] = true
						var hit: Variant = Geometry2D.segment_intersects_segment(a, b, o[1], o[2])
						if hit != null and not _near_end(ends, hit, 0.6):
							var pair := Vector2i(r, o[0])
							if not crossings.has(pair): crossings[pair] = []
							crossings[pair].append(hit)
		stations.append(Vector2(pts[-1].x, pts[-1].y))
		samples += stations.size()
		var last_corner := Vector2(INF, INF)
		for j in range(1, pts.size() - 1):
			var a := Vector2(pts[j - 1].x, pts[j - 1].y)
			var b := Vector2(pts[j].x, pts[j].y)
			var c := Vector2(pts[j + 1].x, pts[j + 1].y)
			if a.distance_to(b) < CORNER_SEG or b.distance_to(c) < CORNER_SEG: continue
			if absf(rad_to_deg((b - a).angle_to(c - b))) <= CORNER: continue
			if b.distance_to(last_corner) < 1.0 or _near_end(ends, b, 2.0) or _near_structure(structures, b, 3.0): continue
			last_corner = b
			corners[t.kind] = int(corners.get(t.kind, 0)) + 1
			if t.kind != "mountain": corner_spots.append(b)
		var hairpin_skip := 0
		var sharp_skip := 0
		for n in stations.size():
			var p := stations[n]
			var cell := clampi(floori(p.y), 0, w.H - 1) * w.W + clampi(floori(p.x), 0, w.W - 1)
			line_cells[cell] = 1
			if w.path_mask[cell] < 2: unmasked += 1
			var tangent := (stations[mini(n + 1, stations.size() - 1)] - stations[maxi(n - 1, 0)]).normalized()
			# изломы: хорды по 4 м
			if n >= 1 and n + 1 < stations.size() and not _near_end(ends, p, 2.0) and not _near_structure(structures, p, 3.0):
				var d0 := stations[n] - stations[n - 1]
				var d1 := stations[n + 1] - stations[n]
				if d0.length() > 0.01 and d1.length() > 0.01 and absf(rad_to_deg(d0.angle_to(d1))) > KINK:
					kinks[t.kind] = int(kinks.get(t.kind, 0)) + 1
					if t.kind != "mountain": kink_spots.append(p)
			# развороты: хорды по 8 м до и после точки
			if n >= 2 and n + 2 < stations.size() and not _near_end(ends, p, 2.0) and not _near_structure(structures, p, 3.0):
				var u0 := stations[n] - stations[n - 2]
				var u1 := stations[n + 2] - stations[n]
				if u0.length() > 0.01 and u1.length() > 0.01:
					var turn := absf(rad_to_deg(u0.angle_to(u1)))
					if turn > HAIRPIN and n >= hairpin_skip:
						hairpins[t.kind] = int(hairpins.get(t.kind, 0)) + 1
						hairpin_skip = n + 4
						if t.kind != "mountain": hairpin_spots.append(p)
					elif turn > SHARP and turn <= HAIRPIN and n >= sharp_skip:
						sharp[t.kind] = int(sharp.get(t.kind, 0)) + 1
						sharp_skip = n + 4
			# продольный уклон по готовой поверхности на хордах 16 м
			if surface != null and n % 2 == 0 and n + 4 < stations.size():
				var q := stations[n + 4]
				var mid := (p + q) * 0.5
				if not _near_structure(structures, mid, 4.0):
					var run := p.distance_to(q) * GameConfig.TILE
					if run > 8.0:
						var rise := absf(surface.ground_at(q.x * GameConfig.TILE, q.y * GameConfig.TILE) - surface.ground_at(p.x * GameConfig.TILE, p.y * GameConfig.TILE))
						var gr := rise / run
						if not grade_acc.has(t.kind): grade_acc[t.kind] = [0.0, 0.0, 0.0, 0.0, 0]
						var acc: Array = grade_acc[t.kind]
						var share := run * 0.5 # хорды через одну станцию перекрываются вдвое
						acc[0] += share
						acc[4] += 1
						if gr > STEEP: acc[1] += share
						acc[2] += gr * share
						if gr > acc[3]:
							acc[3] = gr
							grade_at[t.kind] = [r, snappedf(mid.x, 0.1), snappedf(mid.y, 0.1), _near_end(ends, mid, 4.0)]
			var near_node := _near_end(ends, p, NODE_R)
			var best := {}
			for by in range(floori((p.y - NEAR_MAX) / BIN), floori((p.y + NEAR_MAX) / BIN) + 1):
				for bx in range(floori((p.x - NEAR_MAX) / BIN), floori((p.x + NEAR_MAX) / BIN) + 1):
					for o: Array in bins.get(Vector2i(bx, by), []):
						if o[0] == r: continue
						var d := Grid.segment_dist(p.x, p.y, o[1].x, o[1].y, o[2].x, o[2].y)
						if d > NEAR_MAX: continue
						if not best.has(o[0]) or d < best[o[0]][0]:
							best[o[0]] = [d, (o[2] - o[1]).normalized()]
			for other: int in best:
				var d: float = best[other][0]
				var aligned := absf(tangent.dot(best[other][1])) > PAR_COS
				if not aligned: continue
				if d < OVERLAP:
					overlap += SAMPLE * GameConfig.TILE * 0.5
					_tally(pairs, r, other, "overlap", SAMPLE * GameConfig.TILE * 0.5)
					if spots.size() < 400 and n % 6 == 0: spots.append([p, "overlap"])
				elif d >= NEAR_MIN and not near_node:
					parallel += SAMPLE * GameConfig.TILE * 0.5
					_tally(pairs, r, other, "parallel", SAMPLE * GameConfig.TILE * 0.5)
					if spots.size() < 400 and n % 6 == 0: spots.append([p, "parallel"])
	var double_cross := 0
	var double_spots: Array = []
	for pair: Vector2i in crossings:
		var hits: Array = crossings[pair]
		var found := false
		for i in hits.size():
			for j in range(i + 1, hits.size()):
				if (hits[i] as Vector2).distance_to(hits[j]) <= CROSS_R and (hits[i] as Vector2).distance_to(hits[j]) > 1.0: found = true
		if found:
			double_cross += 1
			double_spots.append(hits[0])
	# маска и линии
	var dist := Grid.distance_field(w.W, w.H, line_cells)
	var orphan := 0
	var ghost := 0
	for i in w.N:
		if w.path_mask[i] >= 2 and dist[i] > 1.5: orphan += 1
		if not base_cost.is_empty() and base_cost[i] != INF and w.cost[i] < base_cost[i] * 0.5 and dist[i] > 1.5: ghost += 1
	var junctions := 0
	var junction_points: Array[Vector2] = []
	for r: int in routes:
		var pts: Array = w.trails[r].pts
		for p: Dictionary in [pts[0], pts[-1]]:
			var at := Vector2(p.x, p.y)
			var hit := false
			for by in range(floori((at.y - 1.0) / BIN), floori((at.y + 1.0) / BIN) + 1):
				for bx in range(floori((at.x - 1.0) / BIN), floori((at.x + 1.0) / BIN) + 1):
					for o: Array in bins.get(Vector2i(bx, by), []):
						if o[0] != r and Grid.segment_dist(at.x, at.y, o[1].x, o[1].y, o[2].x, o[2].y) < 0.05:
							junctions += 1
							hit = true
							break
			if hit: junction_points.append(at)
	var crowded := _crowded_nodes(w, junction_points, structures)
	var shore := _shore_m(w, routes, structures)
	var wiggle := _wiggle(w, routes)
	var lengths := {}
	for kind: String in length_by_kind: lengths[kind] = roundi(length_by_kind[kind])
	var grade := {}
	for kind: String in grade_acc:
		var acc: Array = grade_acc[kind]
		grade[kind] = {samples = acc[4], weighted_chord_m = snappedf(acc[0], 0.01), steep_share = snappedf(acc[1] / maxf(acc[0], 1.0), 0.001), mean = snappedf(acc[2] / maxf(acc[0], 1.0), 0.001), max = snappedf(acc[3], 0.001), max_at = grade_at.get(kind, [])}
	var raw_turns := {}
	var road_cells: Array = w.generation.road_cells if w.generation != null else []
	var raw_acc := {}
	for r: int in routes:
		if r >= road_cells.size(): continue
		var cells: PackedInt32Array = road_cells[r]
		var kind: String = String(w.trails[r].kind)
		if not raw_acc.has(kind): raw_acc[kind] = [0, 0, 0]
		var acc: Array = raw_acc[kind]
		acc[0] += maxi(0, cells.size() - 1)
		for j in range(2, cells.size()):
			var d0 := Vector2i(cells[j - 1] % w.W - cells[j - 2] % w.W, cells[j - 1] / w.W - cells[j - 2] / w.W)
			var d1 := Vector2i(cells[j] % w.W - cells[j - 1] % w.W, cells[j] / w.W - cells[j - 1] / w.W)
			if d0 == d1 or d0 == Vector2i.ZERO or d1 == Vector2i.ZERO: continue
			acc[1] += 1
			if Vector2(d0).dot(Vector2(d1)) <= 0.0: acc[2] += 1
	for kind: String in raw_acc:
		var acc: Array = raw_acc[kind]
		raw_turns[kind] = {per100 = snappedf(acc[1] * 100.0 / maxf(acc[0], 1.0), 0.1), right_or_more = acc[2], steps = acc[0]}
	return {seed = w.seed_text, grid_cells = [w.W, w.H], requested = _requested(), route_usage = _route_usage(w),
		sections = routes.size(), excluded = excluded, character_by_kind = Samples.measure(w, routes, surface, forest),
		decisions = {width = w.generation_profile.get("road_width_decisions"),
			line_grade_fallbacks = w.generation_profile.get("road_line_grade_fallbacks"),
			ride_rejections = w.generation_profile.get("rides", {}).get("rejected")},
		length_m = lengths, overlap_m = roundi(overlap), parallel_m = roundi(parallel),
		double_cross = double_cross, crossings = crossings.size(), kinks = kinks,
		corners = corners, corner_spots = corner_spots, hairpins = hairpins, sharp = sharp, grade = grade, raw_turns = raw_turns, hairpin_spots = hairpin_spots, ghost_cells = ghost if not base_cost.is_empty() else -1,
		mask_orphan = orphan, line_unmasked = unmasked, samples = samples, junction_ends = junctions,
		crowded_nodes = crowded.pairs, nodes = crowded.nodes, shore_m = shore, wiggle = wiggle,
		second_ways = _second_way_counts(w), rides = _ride_counts(w),
		spots = spots, kink_spots = kink_spots, double_spots = double_spots, crowded_spots = crowded.spots, pairs = _top(pairs, 8)}


## 21.11.2026, план V2 (docs/ROAD_NETWORK_V2_PLAN_2026_11_21.md, фаза 0; определения плана 19.11, шаг 0.2).
## crowded_nodes — пары узлов сети ближе CROWD_R (40 м). Узел — конец участка на оси другого участка (junction_ends),
## точки ближе NODE_SAME (0,6 клетки) — один узел. Узлы у поселений (ближе EXIT_NODE клеток к центру) и у
## сооружений (ближе 3 клеток к оси моста или туннеля) не считаются: там узлы нужны.
const CROWD_R := 10.0     # 40 м
const NODE_SAME := 0.6
const EXIT_NODE := 35.0   # = StageTrails.EXIT_R
const SHORE_R := 3.0      # 12 м до моря или озера
const SHORE_RUN := 15     # станций (60 м) подряд — путь вдоль берега
const WIGGLE_WIN := 25    # станций (100 м)
const WIGGLE_STEP := 5
const WIGGLE_RATIO := 1.05


static func _crowded_nodes(w: WorldData, points: Array[Vector2], structures: Array) -> Dictionary:
	var nodes: Array[Vector2] = []
	for p: Vector2 in points:
		var same := false
		for q: Vector2 in nodes:
			if q.distance_to(p) < NODE_SAME:
				same = true
				break
		if not same: nodes.append(p)
	var kept: Array[Vector2] = []
	for p: Vector2 in nodes:
		var settled := false
		for s: SettlementData in w.settlements:
			if Vector2(s.i % w.W + 0.5, s.i / w.W + 0.5).distance_to(p) < EXIT_NODE:
				settled = true
				break
		if not settled and not _near_structure(structures, p, 3.0): kept.append(p)
	var pairs := 0
	var spots: Array = []
	for a in kept.size():
		for b in range(a + 1, kept.size()):
			if kept[a].distance_to(kept[b]) <= CROWD_R:
				pairs += 1
				spots.append((kept[a] + kept[b]) * 0.5)
	return {pairs = pairs, nodes = kept.size(), spots = spots}


## shore_m — длина путей, где станции через 1 клетку ближе SHORE_R к морю или озеру подряд не меньше SHORE_RUN
## (60 м): путь вдоль берега, а не подход к воде. Станции на мостах и у них (3 клетки) прерывают счёт. По видам
## пути и отдельно по ответвлениям shore (generation_profile.second_ways).
static func _shore_m(w: WorldData, routes: Array, structures: Array) -> Dictionary:
	var water := PackedByteArray()
	water.resize(w.N)
	for i in w.N:
		if w.ocean[i] != 0 or w.lake[i] != 0: water[i] = 1
	var dist := Grid.distance_field(w.W, w.H, water)
	var spur := {}
	for note: Array in w.generation_profile.get("second_ways", []):
		if note[0] == "shore":
			for k: int in note[1]: spur[k] = true
	var out := {road = 0.0, trail = 0.0, mountain = 0.0, shore_spurs = 0.0}
	for r: int in routes:
		var t: Dictionary = w.trails[r]
		var run := 0
		var total := 0
		for p: Vector2 in _stations(t.pts):
			var i := clampi(floori(p.y), 0, w.H - 1) * w.W + clampi(floori(p.x), 0, w.W - 1)
			if dist[i] <= SHORE_R and not _near_structure(structures, p, 3.0):
				run += 1
			else:
				if run >= SHORE_RUN: total += run
				run = 0
		if run >= SHORE_RUN: total += run
		var m := total * SAMPLE * GameConfig.TILE
		out[t.kind] = float(out.get(t.kind, 0.0)) + m
		if spur.has(r): out.shore_spurs += m
	for key: String in out: out[key] = roundi(out[key])
	return out


## wiggle — окна по 100 м (25 станций, шаг 5): длина / хорда; доля окон с отношением ≥ 1,05 и медиана суммы
## поворотов хорд по 4 м на 100 м, градусов. По видам пути.
static func _wiggle(w: WorldData, routes: Array) -> Dictionary:
	var acc := {}
	for r: int in routes:
		var t: Dictionary = w.trails[r]
		var st := _stations(t.pts)
		if st.size() <= WIGGLE_WIN: continue
		var a: Dictionary = acc.get_or_add(String(t.kind), {windows = 0, wavy = 0, turns = []})
		for s in range(0, st.size() - WIGGLE_WIN, WIGGLE_STEP):
			var length := 0.0
			var turn := 0.0
			for k in range(s + 1, s + WIGGLE_WIN + 1):
				length += st[k].distance_to(st[k - 1])
			for k in range(s + 4, s + WIGGLE_WIN + 1, 4):
				if k + 4 > s + WIGGLE_WIN: break
				var d0 := st[k] - st[k - 4]
				var d1 := st[k + 4] - st[k]
				if d0.length() > 0.01 and d1.length() > 0.01: turn += absf(rad_to_deg(d0.angle_to(d1)))
			var chord := st[s + WIGGLE_WIN].distance_to(st[s])
			a.windows += 1
			if length >= chord * WIGGLE_RATIO: a.wavy += 1
			a.turns.append(turn * 100.0 / (WIGGLE_WIN * SAMPLE * GameConfig.TILE))
	var out := {}
	for kind: String in acc:
		var a: Dictionary = acc[kind]
		a.turns.sort()
		out[kind] = {windows = a.windows, wavy_share = snappedf(float(a.wavy) / maxi(1, a.windows), 0.001),
			turn_per_100m = snappedf(a.turns[a.turns.size() / 2], 0.1)}
	return out


static func _stations(pts: Array) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var carry := 0.0
	for j in range(1, pts.size()):
		var a := Vector2(pts[j - 1].x, pts[j - 1].y)
		var b := Vector2(pts[j].x, pts[j].y)
		var seg := a.distance_to(b)
		var s := carry
		while s < seg:
			out.append(a.lerp(b, s / seg))
			s += SAMPLE
		carry = s - seg
	if not pts.is_empty(): out.append(Vector2(pts[-1].x, pts[-1].y))
	return out


## Вторые пути по видам (generation_profile.second_ways): записей w.trails
static func _second_way_counts(w: WorldData) -> Dictionary:
	var out := {shortcut = 0, alternative = 0, shore = 0, view = 0, bridge_gap = 0}
	for note: Array in w.generation_profile.get("second_ways", []):
		out[note[0]] = int(out.get(note[0], 0)) + (note[1] as Array).size()
	var mountain := 0
	for t: Dictionary in w.trails:
		if t.kind == "mountain" and not t.has("ride"): mountain += 1
	out.mountain = mountain
	return out


static func _ride_counts(w: WorldData) -> Dictionary:
	var stats: Dictionary = w.generation_profile.get("rides", {})
	return {accepted = stats.get("accepted", 0), climbs = stats.get("climbs", 0), styles = stats.get("styles", {})}


static func _requested() -> Dictionary:
	var tuning := RoadTuning.current()
	var settings := _exported(tuning)
	for kind: String in ["road", "trail", "mountain"]:
		settings[kind] = _exported(tuning.kind(kind))
	settings.routing = _exported(tuning.routing)
	settings.section = _exported(tuning.section)
	settings.obstacles = _exported(tuning.obstacles)
	return {road_tuning = settings, bed_digest = tuning.digest(), routing_overrides = StageTrails.routing_overrides.duplicate(true),
		landscape_character = RoadRefinement.landscape_character, rides_enabled = RideRoutes.enabled(), ride_search_styles = RideRoutes.STYLES}


static func _exported(resource: Resource) -> Dictionary:
	var values := {}
	for property: Dictionary in resource.get_property_list():
		if (property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0 or (property.usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var value: Variant = resource.get(property.name)
		if value is Resource: continue
		values[String(property.name)] = Array(value) if value is PackedFloat64Array else value
	return values


static func _route_usage(w: WorldData) -> Dictionary:
	if w.road_rides.is_empty():
		var tags := {}
		for t: Dictionary in w.trails:
			if not t.has("ride"): continue
			var label: Dictionary = tags.get_or_add(t.ride, {style = t.ride_style, tagged_sections = 0, tagged_m = 0.0})
			label.tagged_sections += 1
			label.tagged_m += Topology.length_m(t.pts)
		for label: Dictionary in tags.values(): label.tagged_m = snappedf(label.tagged_m, 0.01)
		return {status = "legacy_tags_only" if not tags.is_empty() else "unavailable", tags = tags}
	var issue := RoadRides.validation_error(w)
	if not issue.is_empty(): return {status = "invalid", error = issue}
	var sections := Topology.sections(w)
	var result := {status = "recorded", routes = {}, by_style = {}, by_kind = {}}
	var events := {}
	for id: String in w.road_rides.routes:
		var route: Dictionary = w.road_rides.routes[id]
		var length := 0.0
		var ascent := 0.0
		var reverse := 0.0
		for i in route.legs.size():
			var leg: Dictionary = route.legs[i]
			var distance := absf(leg.to_m - leg.from_m)
			length += distance
			if i < route.ascent_legs: ascent += distance
			if leg.to_m < leg.from_m: reverse += distance
			var cuts: Array = events.get_or_add(leg.section, [])
			cuts.append([minf(leg.from_m, leg.to_m), id, 1])
			cuts.append([maxf(leg.from_m, leg.to_m), id, -1])
			var group: Dictionary = result.by_kind.get_or_add(sections[leg.section].kind, {sections = 0, traversed_m = 0.0,
				covered_m = 0.0, shared_between_routes_m = 0.0})
			group.traversed_m += distance
		var style: Dictionary = result.by_style.get_or_add(route.style, {routes = 0, traversed_m = 0.0, ascent_m = 0.0})
		style.routes += 1
		style.traversed_m += length
		style.ascent_m += ascent
		result.routes[id] = {style = route.style, legs = route.legs.duplicate(true), ascent_legs = route.ascent_legs,
			traversed_m = snappedf(length, 0.01), ascent_m = snappedf(ascent, 0.01), reverse_m = snappedf(reverse, 0.01)}
	for id: String in events:
		var group: Dictionary = result.by_kind[sections[id].kind]
		group.sections += 1
		_count_coverage(events[id], group)
	for group: Dictionary in result.by_kind.values():
		group.repeated_m = snappedf(group.traversed_m - group.covered_m, 0.01)
		for field: String in ["traversed_m", "covered_m", "shared_between_routes_m"]: group[field] = snappedf(group[field], 0.01)
	for style: Dictionary in result.by_style.values():
		style.traversed_m = snappedf(style.traversed_m, 0.01)
		style.ascent_m = snappedf(style.ascent_m, 0.01)
	return result


static func _count_coverage(events: Array, group: Dictionary) -> void:
	events.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var active := {}
	var previous: float = events[0][0]
	for event: Array in events:
		var distance: float = event[0] - previous
		if not active.is_empty(): group.covered_m += distance
		if active.size() > 1: group.shared_between_routes_m += distance
		var count := int(active.get(event[1], 0)) + int(event[2])
		if count == 0:
			active.erase(event[1])
		else:
			active[event[1]] = count
		previous = event[0]


static func _tally(pairs: Dictionary, a: int, b: int, what: String, length: float) -> void:
	var key := "%d:%d:%s" % [mini(a, b), maxi(a, b), what]
	pairs[key] = float(pairs.get(key, 0.0)) + length


static func _top(pairs: Dictionary, count: int) -> Array:
	var keys := pairs.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return pairs[a] > pairs[b])
	var out: Array = []
	for key: String in keys.slice(0, count): out.append("%s=%dм" % [key, roundi(pairs[key])])
	return out


static func _near_end(ends: Dictionary, p: Vector2, r: float) -> bool:
	for by in range(floori((p.y - r) / BIN), floori((p.y + r) / BIN) + 1):
		for bx in range(floori((p.x - r) / BIN), floori((p.x + r) / BIN) + 1):
			for e: Vector2 in ends.get(Vector2i(bx, by), []):
				if e.distance_squared_to(p) <= r * r: return true
	return false


static func _near_structure(structures: Array, p: Vector2, r: float) -> bool:
	for s: Array in structures:
		if Grid.segment_dist(p.x, p.y, s[0].x, s[0].y, s[1].x, s[1].y) < r: return true
	return false


## Картинка полотна: дороги белые, тропы светло-серые, горные коричневые;
## красные точки — совпадающие оси, жёлтые — параллельные полотна, малиновые — углы (corners, с 15.11; раньше изломы
## kinks), голубые — двойные пересечения,
## зелёные — развороты > 110° на 16 м, оранжевые квадраты — тесные пары узлов (crowded_nodes, с 21.11).
static func draw(w: WorldData, m: Dictionary, file: String) -> void:
	var S := 2
	var img := Image.create(w.W * S, w.H * S, false, Image.FORMAT_RGB8)
	var river := w.river_cells()
	for y in w.H:
		for x in w.W:
			var i := y * w.W + x
			var v := clampf(0.2 + w.h[i] * 0.8, 0.0, 1.0) * (1.0 - clampf(w.slope[i] * 1.5, 0.0, 0.5)) * 0.7
			var c := Color(v, v, v * 0.95)
			if w.ocean[i] != 0 or w.lake[i] != 0 or river[i] != 0: c = Color(0.2, 0.35, 0.6)
			img.fill_rect(Rect2i(x * S, y * S, S, S), c)
	var colors := {road = Color(1, 1, 0.92), trail = Color(0.7, 0.7, 0.66), mountain = Color(0.65, 0.42, 0.25)}
	for t: Dictionary in w.trails:
		if t.kind == "animal": continue
		var color: Color = colors.get(t.kind, Color.MAGENTA)
		for k in range(1, t.pts.size()):
			var a := Vector2(t.pts[k - 1].x, t.pts[k - 1].y) * S
			var b := Vector2(t.pts[k].x, t.pts[k].y) * S
			var n := maxi(1, ceili(a.distance_to(b) * 2.0))
			for j in n + 1:
				var p := a.lerp(b, float(j) / n)
				img.set_pixel(clampi(int(p.x), 0, w.W * S - 1), clampi(int(p.y), 0, w.H * S - 1), color)
	for s: Array in m.spots:
		_dot(img, s[0] * S, Color(1, 0.1, 0.1) if s[1] == "overlap" else Color(1, 0.9, 0.1), 1)
	for p: Vector2 in m.get("corner_spots", m.kink_spots): _dot(img, p * S, Color(1, 0.2, 0.9), 1)
	for p: Vector2 in m.get("hairpin_spots", []): _dot(img, p * S, Color(0.1, 1.0, 0.3), 2)
	for p: Vector2 in m.double_spots: _dot(img, p * S, Color(0.2, 0.9, 1), 2)
	for p: Vector2 in m.get("crowded_spots", []): _dot(img, p * S, Color(1.0, 0.5, 0.0), 3)
	DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	img.save_png(file)


static func _dot(img: Image, p: Vector2, c: Color, r: int) -> void:
	img.fill_rect(Rect2i(int(p.x) - r, int(p.y) - r, 2 * r + 1, 2 * r + 1).intersection(Rect2i(Vector2i.ZERO, img.get_size())), c)


## Без точек для картинки — для печати
static func summary(m: Dictionary) -> Dictionary:
	var out := m.duplicate()
	var metadata := {version = 2}
	for key: String in ["seed", "grid_cells", "requested", "route_usage", "decisions"]:
		metadata[key] = out[key]
		out.erase(key)
	for key: String in ["spots", "kink_spots", "double_spots", "hairpin_spots", "corner_spots", "crowded_spots"]:
		out.erase(key)
	metadata.physical = out
	return metadata
