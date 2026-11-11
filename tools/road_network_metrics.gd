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

const BIN := 10        # клеток в ячейке индекса отрезков (40 м)
const SAMPLE := 1.0    # шаг выборки вдоль линии, клеток
const OVERLAP := 0.25  # 1 м
const NEAR_MIN := 0.5  # 2 м
const NEAR_MAX := 10.0 # 40 м
const NODE_R := 7.5    # 30 м
const PAR_COS := 0.9
const CROSS_R := 20.0  # 80 м
const KINK := 35.0


static func measure(w: WorldData, base_cost := PackedFloat32Array()) -> Dictionary:
	var routes: Array = []
	for k in w.trails.size():
		var t: Dictionary = w.trails[k]
		if t.kind == "animal" or t.has("trail_id") or t.pts.size() < 2: continue
		routes.append(k)
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
		var kind: String = w.trails[r].kind
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
	for r: int in routes:
		var pts: Array = w.trails[r].pts
		for p: Dictionary in [pts[0], pts[-1]]:
			var at := Vector2(p.x, p.y)
			for by in range(floori((at.y - 1.0) / BIN), floori((at.y + 1.0) / BIN) + 1):
				for bx in range(floori((at.x - 1.0) / BIN), floori((at.x + 1.0) / BIN) + 1):
					for o: Array in bins.get(Vector2i(bx, by), []):
						if o[0] != r and Grid.segment_dist(at.x, at.y, o[1].x, o[1].y, o[2].x, o[2].y) < 0.05:
							junctions += 1
							break
	var lengths := {}
	for kind: String in length_by_kind: lengths[kind] = roundi(length_by_kind[kind])
	return {routes = routes.size(), length_m = lengths, overlap_m = roundi(overlap), parallel_m = roundi(parallel),
		double_cross = double_cross, crossings = crossings.size(), kinks = kinks, ghost_cells = ghost if not base_cost.is_empty() else -1,
		mask_orphan = orphan, line_unmasked = unmasked, samples = samples, junction_ends = junctions,
		spots = spots, kink_spots = kink_spots, double_spots = double_spots, pairs = _top(pairs, 8)}


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


## Картинка сети: дороги белые, тропы светло-серые, горные коричневые, природные маршруты оранжевые;
## красные точки — совпадающие оси, жёлтые — параллельные полотна, малиновые — изломы, голубые — двойные пересечения.
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
		var color: Color = Color(1.0, 0.55, 0.1) if t.has("ride") else colors.get(t.kind, Color.MAGENTA)
		for k in range(1, t.pts.size()):
			var a := Vector2(t.pts[k - 1].x, t.pts[k - 1].y) * S
			var b := Vector2(t.pts[k].x, t.pts[k].y) * S
			var n := maxi(1, ceili(a.distance_to(b) * 2.0))
			for j in n + 1:
				var p := a.lerp(b, float(j) / n)
				img.set_pixel(clampi(int(p.x), 0, w.W * S - 1), clampi(int(p.y), 0, w.H * S - 1), color)
	for s: Array in m.spots:
		_dot(img, s[0] * S, Color(1, 0.1, 0.1) if s[1] == "overlap" else Color(1, 0.9, 0.1), 1)
	for p: Vector2 in m.kink_spots: _dot(img, p * S, Color(1, 0.2, 0.9), 1)
	for p: Vector2 in m.double_spots: _dot(img, p * S, Color(0.2, 0.9, 1), 2)
	DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	img.save_png(file)


static func _dot(img: Image, p: Vector2, c: Color, r: int) -> void:
	img.fill_rect(Rect2i(int(p.x) - r, int(p.y) - r, 2 * r + 1, 2 * r + 1).intersection(Rect2i(Vector2i.ZERO, img.get_size())), c)


## Без точек для картинки — для печати
static func summary(m: Dictionary) -> Dictionary:
	var out := m.duplicate()
	for key: String in ["spots", "kink_spots", "double_spots"]: out.erase(key)
	return out
