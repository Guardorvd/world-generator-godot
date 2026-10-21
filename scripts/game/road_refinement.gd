class_name RoadRefinement
extends RefCounted
## 4.4: локальная метровая сетка Road Refinement Layer. Общая сетка мира не меняется.
## Патчи заменяют исходные треугольники, а ground_at читает те же вершины и диагонали.
## За зоной влияния дополнительные вершины лежат точно на прежних треугольниках.

const DIV := 4
const TILE := GameConfig.TILE
const STEP := TILE / DIV
const STRIDE := DIV + 1
const REACH := 3.0
const FIT_FADE := 12.0   # 4.5: плавный переход у концов, развилок и защищённых мест, м
const FIT_LIMIT := 1.2   # обычное уточнение относительно сетки RoadBed, м
const BENCH_LIMIT := Heightfield.TUNNEL_HEIGHT # полка дороги в склоне: до высоты существующей выемки, м
const TRAIL_BENCH_LIMIT := 2.0 # более узкая полка обычной тропы; технические горные тропы не выравниваем
static var allow_fast_nearest := true # false — исходный цикл GDScript для сравнения

var patches := {}  # индекс исходного квадрата -> {h, color, uv, surface, road}; uv: поперечная координата, номер покрытия
var fit_routes := {} # маршрут -> метровые points, profile, strength, limit; горные тропы остаются прежними
var build_timings := {}
var _segments := {}
var _segment_list: Array[Dictionary] = []
var _structures := {}
var _heights: Heightfield
var _noise: FastNoiseLite
var _height := 0
var _base_cache := {} # одинаковые метровые выборки у соседних вершин, только на время запекания
var _wet_cache := {}  # уровень соседней воды одинаков для всех вершин одной клетки


static func build(heights: Heightfield, fit_road := true) -> RoadRefinement:
	var r := RoadRefinement.new()
	r._heights = heights
	r._height = heights.world.H
	r._noise = FastNoiseLite.new()
	r._noise.seed = heights.world.seed_num
	r._noise.frequency = 1.0
	r._noise.fractal_octaves = 2
	var started_us := Time.get_ticks_usec()
	for route in heights.world.trails.size():
		var t: Dictionary = heights.world.trails[route]
		if RoadBed.KINDS.has(t.kind):
			r._index(t, route)
	r._index_structures()
	r.build_timings.index_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	started_us = Time.get_ticks_usec()
	if fit_road:
		r._fit_network()
	r.build_timings.fit_network_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	started_us = Time.get_ticks_usec()
	var cache := {}
	var fine_width := heights.world.W * DIV
	var nearest := PackedFloat64Array()
	var fast := Grid.fast_grid() if allow_fast_nearest else null
	if fast != null:
		nearest = r._nearest_vertices(cache, fast)
	for key: int in r._segments:
		var cx := key % heights.world.W
		var cz := key / heights.world.W
		var hs := PackedFloat32Array()
		var colors := PackedColorArray()
		var uvs := PackedVector2Array()
		var surfaces := PackedByteArray()
		var roads := PackedByteArray()
		hs.resize(STRIDE * STRIDE)
		colors.resize(STRIDE * STRIDE)
		uvs.resize(STRIDE * STRIDE)
		surfaces.resize(STRIDE * STRIDE)
		roads.resize(STRIDE * STRIDE)
		for z in STRIDE:
			for x in STRIDE:
				var ix := cx * DIV + x
				var iz := cz * DIV + z
				var vk := iz * fine_width + ix
				if not cache.has(vk) or cache[vk] is int:
					var at: int = cache[vk] * 4 if cache.has(vk) else -1
					cache[vk] = r._vertex((ix * STEP) + TILE * 0.5, (iz * STEP) + TILE * 0.5, nearest, at)
				var v: Dictionary = cache[vk]
				var idx := z * STRIDE + x
				hs[idx] = v.h
				colors[idx] = v.color
				uvs[idx] = v.uv
				surfaces[idx] = v.surface
				roads[idx] = 1 if v.road else 0
		r.patches[key] = {h = hs, color = colors, uv = uvs, surface = surfaces, road = roads}
	r.build_timings.vertices_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	# После запекания нет ссылок на Heightfield (цикл RefCounted) и временного пространственного индекса.
	r._heights = null
	r._segments.clear()
	r._segment_list.clear()
	r._structures.clear()
	r._noise = null
	r._base_cache.clear()
	r._wet_cache.clear()
	return r


## Один вызов C# для всех уникальных вершин, без межъязыкового вызова на каждую из них.
## В cache сначала номера запросов, затем они заменяются готовыми словарями вершин.
func _nearest_vertices(cache: Dictionary, fast: Object) -> PackedFloat64Array:
	var w := _heights.world
	var points := PackedVector2Array()
	for key: int in _segments:
		var cx := key % w.W
		var cz := key / w.W
		for z in STRIDE:
			for x in STRIDE:
				var ix := cx * DIV + x
				var iz := cz * DIV + z
				var vk := iz * (w.W * DIV) + ix
				if not cache.has(vk):
					cache[vk] = points.size()
					points.append(Vector2(ix * STEP + TILE * 0.5, iz * STEP + TILE * 0.5))
	var anchors := PackedVector2Array()
	var deltas := PackedVector2Array()
	var lengths := PackedFloat64Array()
	var halves := PackedFloat64Array()
	var roads := PackedByteArray()
	for s: Dictionary in _segment_list:
		anchors.append(s.a)
		deltas.append(s.delta)
		lengths.append(s.len2)
		halves.append(s.half)
		roads.append(1 if s.kind == "road" else 0)
	var starts := PackedInt32Array()
	starts.resize(w.N + 1)
	var candidates := PackedInt32Array()
	for key in w.N:
		starts[key] = candidates.size()
		for s: Dictionary in _segments.get(key, []):
			candidates.append(s.id)
	starts[w.N] = candidates.size()
	return fast.NearestRoadSegments(points, w.W, w.H, TILE, REACH, anchors, deltas, lengths, halves, roads, starts, candidates)


## Вершине нужны только близкие сооружения, а не перебор всех мостов мира.
func _index_structures() -> void:
	var w := _heights.world
	var reach := RoadBed.PIN + RoadBed.PIN_FADE
	for s: Dictionary in _heights.structures:
		for z in range(maxi(0, floori((minf(s.az, s.bz) - reach) / TILE - 0.5)), mini(w.H - 1, ceili((maxf(s.az, s.bz) + reach) / TILE - 0.5))):
			for x in range(maxi(0, floori((minf(s.ax, s.bx) - reach) / TILE - 0.5)), mini(w.W - 1, ceili((maxf(s.ax, s.bx) + reach) / TILE - 0.5))):
				var key := z * w.W + x
				if not _structures.has(key):
					_structures[key] = []
				_structures[key].append(s)


func _index(t: Dictionary, route: int) -> void:
	var w := _heights.world
	var pts: Array = t.pts
	var profile := PackedFloat32Array()
	# У троп сохраняем естественные перегибы; поперечная полка считается отдельно.
	var smoothing := 0.65 if t.kind == "road" else (0.25 if t.kind == "trail" else 0.0)
	# Соседние окна используют одни и те же высоты; хранить в double, как результат выборки.
	var base_heights := PackedFloat64Array()
	if smoothing > 0.0:
		base_heights.resize(pts.size())
		for n in pts.size():
			base_heights[n] = _heights.base_ground_at(pts[n].x * TILE, pts[n].y * TILE)
	# Короткое симметричное окно по уже выровненному полотну; концы развилок закреплены.
	for n in pts.size():
		var p := Vector2(pts[n].x, pts[n].y) * TILE
		var h := _heights.base_ground_at(p.x, p.y)
		var sum_h := h
		var count := 1
		var radius := mini(3, mini(n, pts.size() - 1 - n)) if smoothing > 0.0 else 0
		for j in range(n - radius, n + radius + 1):
			if j != n:
				sum_h += base_heights[j]
				count += 1
		profile.append(lerpf(h, sum_h / count, smoothing))
	var along := 0.0
	for n in range(1, pts.size()):
		var a := Vector2(pts[n - 1].x, pts[n - 1].y) * TILE
		var b := Vector2(pts[n].x, pts[n].y) * TILE
		if a.distance_squared_to(b) < 0.0001:
			continue
		var half := (float(pts[n - 1].w) + float(pts[n].w)) * TILE * 0.25
		var surf: int = t.surf[n - 1]
		var next_surf: int = t.surf[n]
		var s := {a = a, delta = b - a, len2 = a.distance_squared_to(b), half = half,
			ha = profile[n - 1], hb = profile[n], surf = surf, next = next_surf, kind = t.kind, route = route, along = along}
		s.id = _segment_list.size()
		_segment_list.append(s)
		along += a.distance_to(b)
		var reach := half + REACH + TILE
		for z in range(maxi(0, floori((minf(a.y, b.y) - reach) / TILE - 0.5)), mini(w.H - 1, ceili((maxf(a.y, b.y) + reach) / TILE - 0.5))):
			for x in range(maxi(0, floori((minf(a.x, b.x) - reach) / TILE - 0.5)), mini(w.W - 1, ceili((maxf(a.x, b.x) + reach) / TILE - 0.5))):
				var center := Vector2(x + 1.0, z + 1.0) * TILE
				if Grid.segment_dist(center.x, center.y, a.x, a.y, b.x, b.y) > half + REACH + TILE * 0.71:
					continue
				var key := z * w.W + x
				if not _segments.has(key):
					_segments[key] = []
				_segments[key].append(s)


## 4.5: три линейных прохода по пути — оценка, расстояние до защищённых мест, профиль.
## Резкий локальный перегиб требует обработки, постоянный чрезмерный уклон — другого маршрута.
func _fit_network() -> void:
	var w := _heights.world
	for route in w.trails.size():
		var t: Dictionary = w.trails[route]
		if t.kind != "road" and t.kind != "trail":
			continue
		var points := PackedVector2Array()
		var along := 0.0
		var next := 0.0
		for n in range(1, t.pts.size()):
			var a := Vector2(t.pts[n - 1].x, t.pts[n - 1].y) * TILE
			var b := Vector2(t.pts[n].x, t.pts[n].y) * TILE
			var length := a.distance_to(b)
			if length < 0.01:
				continue
			while next <= along + length:
				points.append(a.lerp(b, (next - along) / length))
				next += STEP
			along += length
		var count := points.size()
		if count < 3:
			continue
		var ground := PackedFloat32Array()
		ground.resize(count)
		for j in count:
			ground[j] = _heights.base_ground_at(points[j].x, points[j].y)
		var need := PackedFloat32Array()
		var cross_slopes := PackedFloat32Array()
		var allowed := PackedFloat32Array()
		var distance := PackedFloat32Array()
		need.resize(count)
		cross_slopes.resize(count)
		allowed.resize(count)
		distance.resize(count)
		for j in count:
			var p := points[j]
			var lo := maxi(0, j - 2)
			var hi := mini(count - 1, j + 2)
			var tangent := (points[hi] - points[lo]).normalized()
			var normal := Vector2(-tangent.y, tangent.x) * 1.5
			var cross_grade := absf(_heights.base_ground_at(p.x + normal.x, p.y + normal.y) - _heights.base_ground_at(p.x - normal.x, p.y - normal.y)) / 3.0
			cross_slopes[j] = cross_grade
			var grade := absf(ground[hi] - ground[lo]) / maxf((hi - lo) * STEP, STEP)
			var ripple := absf(ground[maxi(0, j - 4)] - 2.0 * ground[j] + ground[mini(count - 1, j + 4)]) / (8.0 * STEP)
			need[j] = maxf(smoothstep(0.02, 0.10, cross_grade), maxf(smoothstep(0.08, 0.30, grade), smoothstep(0.004, 0.035, ripple)))
			lo = maxi(0, j - 12)
			hi = mini(count - 1, j + 12)
			var sustained := absf(ground[hi] - ground[lo]) / maxf((hi - lo) * STEP, STEP)
			# Косой склон требует полки и у обычной тропы. Непригодный продольный подъём остаётся защищён.
			allowed[j] = 1.0 - smoothstep(0.45, 0.7, sustained)
			if not _fit_safe(p, tangent, route, j * STEP, t.kind == "road"):
				allowed[j] = 0.0
			distance[j] = 0.0 if allowed[j] <= 0.0 else (distance[j - 1] + STEP if j > 0 else 0.0)
		# Симметричное окно не пересекает берег, сооружение, развилку или конец пути.
		var back := 0.0
		for j in range(count - 1, -1, -1):
			back = 0.0 if j == count - 1 or allowed[j] <= 0.0 else back + STEP
			distance[j] = minf(distance[j], back)
		var profile := PackedFloat32Array()
		var strength := PackedFloat32Array()
		var limits := PackedFloat32Array()
		for j in count:
			var amount := 0.0
			var cross_slope := 0.0
			var lo := maxi(0, j - 4)
			var hi := mini(count - 1, j + 4)
			for k in range(lo, hi + 1):
				amount += need[k]
				cross_slope += cross_slopes[k]
			amount /= hi - lo + 1
			cross_slope /= hi - lo + 1
			var radius := mini(12, maxi(0, floori(distance[j] / STEP) - 1))
			var small := mini(4, radius)
			var sum_h := 0.0
			var sum_small := 0.0
			for k in range(j - radius, j + radius + 1):
				sum_h += ground[k]
				if absi(k - j) <= small:
					sum_small += ground[k]
			var average := lerpf(sum_small / (2 * small + 1), sum_h / (2 * radius + 1), amount)
			var axial_limit := lerpf(0.15, 0.9, amount) * (0.35 if t.kind == "trail" else 1.0)
			var target := ground[j] + clampf((average - ground[j]) * lerpf(0.35, 0.95, amount), -axial_limit, axial_limit)
			profile.append(target)
			var power := lerpf(0.25, 1.0, amount) * allowed[j] * smoothstep(0.0, FIT_FADE, distance[j])
			var trail_power := lerpf(0.55, 0.85, smoothstep(0.5, 0.9, cross_slope)) if t.kind == "trail" else 1.0
			strength.append(power * trail_power)
			var cap := lerpf(0.2, FIT_LIMIT, amount) * (0.5 if t.kind == "trail" else 1.0)
			var bench_limit := BENCH_LIMIT if t.kind == "road" else TRAIL_BENCH_LIMIT
			cap = maxf(cap, minf(bench_limit, cross_slope * float(t.pts[0].w) * TILE * 0.5))
			limits.append(cap)
		fit_routes[route] = {points = points, profile = profile, strength = strength, limit = limits}


func _fit_safe(p: Vector2, tangent: Vector2, route: int, along: float, shore_ok := false) -> bool:
	var w := _heights.world
	var cell := floori(p.y / TILE) * w.W + floori(p.x / TILE)
	if cell < 0 or cell >= w.N or (not shore_ok and w.dist_water[cell] < RoadBed.SHORE.y) or _heights.water_level[cell] != -INF:
		return false
	var key := floori(p.y / TILE - 0.5) * w.W + floori(p.x / TILE - 0.5)
	for s: Dictionary in _structures.get(key, []):
		if Grid.segment_dist(p.x, p.y, s.ax, s.az, s.bx, s.bz) < RoadBed.PIN + RoadBed.PIN_FADE:
			return false
	for s: Dictionary in _segments.get(key, []):
		var b: Vector2 = s.a + s.delta
		var crossing: bool = s.route != route and absf(tangent.dot(s.delta.normalized())) < 0.9
		var hairpin := false
		if s.route == route and absf(s.along - along) > 20.0:
			var u := clampf((p - s.a).dot(s.delta) / s.len2, 0.0, 1.0)
			hairpin = absf(s.along + u * sqrt(s.len2) - along) > 20.0
		if (crossing or hairpin) and Grid.segment_dist(p.x, p.y, s.a.x, s.a.y, b.x, b.y) < s.half + REACH + 0.5:
			return false
	for village: Dictionary in w.settlements:
		if p.distance_to(Vector2(village.x, village.y) * TILE) < 10.0:
			return false
	return true


func _base_at(x: float, z: float) -> float:
	return _heights.base_ground_at(x, z)


func _wet_near(i: int) -> float:
	if not _wet_cache.has(i):
		_wet_cache[i] = RoadBed._wet_near(_heights, i)
	return _wet_cache[i]


func _vertex(x: float, z: float, nearest := PackedFloat64Array(), nearest_at := -1) -> Dictionary:
	var w := _heights.world
	var base := _base_at(x, z)
	var key := clampi(floori(z / TILE - 0.5), 0, w.H - 2) * w.W + clampi(floori(x / TILE - 0.5), 0, w.W - 2)
	var best := INF
	var road: Dictionary = {}
	var u := 0.0
	var side := 0.0
	var distance := 0.0
	if nearest_at >= 0:
		if nearest[nearest_at] >= 0.0:
			road = _segment_list[int(nearest[nearest_at])]
			u = nearest[nearest_at + 1]
			distance = nearest[nearest_at + 2]
			side = nearest[nearest_at + 3]
	for s: Dictionary in (_segments.get(key, []) if nearest_at < 0 else []):
		var delta: Vector2 = s.delta
		var f := clampf((Vector2(x, z) - s.a).dot(delta) / s.len2, 0.0, 1.0)
		var offset: Vector2 = Vector2(x, z) - (s.a + delta * f)
		var d := offset.length()
		var rank: float = d / s.half - (0.08 if s.kind == "road" else 0.0)
		if d < s.half + REACH and rank < best:
			best = rank
			road = s
			u = f
			side = offset.cross(delta.normalized())
			distance = d
	if road.is_empty():
		return {h = base, color = Color(0, 0, 0, 0), uv = Vector2.ZERO, surface = 0, road = false}
	var half: float = road.half
	var d := distance
	# Несимметричные края и разная ширина обочины, плавные метровые неровности.
	var slow := _noise.get_noise_2d(x * 0.13, z * 0.13)
	var grain := _noise.get_noise_2d(x * 0.8 + 71.0, z * 0.8)
	var edge := half + slow * 0.24 + grain * 0.10
	var shoulder := 0.7 + (slow + 1.0) * 0.3
	var mask := 1.0 - smoothstep(edge * 0.55, edge + shoulder, d)
	var surf: int = road.surf if u < 0.5 else road.next
	var ca: Array = RoadSurface.LIST[road.surf].color
	var cb: Array = RoadSurface.LIST[road.next].color
	var color := Color8(ca[0], ca[1], ca[2]).lerp(Color8(cb[0], cb[1], cb[2]), smoothstep(0.0, 1.0, u)).srgb_to_linear()
	if surf == RoadSurface.MEADOW:
		mask *= 0.65
	# Меняется только вид края. Прежняя маска остаётся для геометрической микронеровности.
	var ground_mask := mask
	var blend := smoothstep(0.0, 1.0, u)
	var organic := lerpf(RoadSurface.LIST[road.surf].organic, RoadSurface.LIST[road.next].organic, blend)
	var visual_edge := edge * (1.0 - organic * 0.12)
	var visual_shoulder := shoulder * (1.0 + organic * 0.5)
	color.a = (1.0 - smoothstep(visual_edge * 0.55, visual_edge + visual_shoulder, d)) * (1.0 - organic * 0.35)
	var influence := 1.0 - smoothstep(half + 0.3, half + REACH, d)
	var cx := clampi(floori(x / TILE), 0, w.W - 1)
	var cz := clampi(floori(z / TILE), 0, w.H - 1)
	var i := cz * w.W + cx
	var pin := smoothstep(RoadBed.SHORE.x, RoadBed.SHORE.y, w.dist_water[i])
	# Базовое уточнение затухает у берега; земляная полка дороги обрабатывается отдельно ниже.
	if _heights.water_level[i] != -INF:
		pin = 0.0
	var structure_pin := 1.0
	for s: Dictionary in _structures.get(key, []):
		var dist := Grid.segment_dist(x, z, s.ax, s.az, s.bx, s.bz)
		structure_pin = minf(structure_pin, smoothstep(RoadBed.PIN, RoadBed.PIN + RoadBed.PIN_FADE, dist))
	pin = minf(pin, structure_pin)
	var gx := _base_at(x + 1.0, z) - _base_at(x - 1.0, z)
	var gz := _base_at(x, z + 1.0) - _base_at(x, z - 1.0)
	pin *= 1.0 - smoothstep(RoadBed.STEEP.x, RoadBed.STEEP.y, Vector2(gx, gz).length() * 0.5)
	var rough: float = RoadSurface.LIST[surf].rough
	var crown := 0.035 * (1.0 - smoothstep(0.0, half, d))
	var rut := -0.045 * exp(-pow((d - half * 0.48) / 0.3, 2.0))
	var detail := crown + rut + grain * (0.025 + rough * 0.12) + slow * 0.06 * (1.0 - ground_mask)
	var limit := 0.65 if road.kind == "road" else 0.3
	var target := lerpf(road.ha, road.hb, u) + detail
	var h := base + clampf(target - base, -limit, limit) * influence * pin
	if fit_routes.has(road.route):
		var fit: Dictionary = fit_routes[road.route]
		var at := clampf((road.along + u * sqrt(road.len2)) / STEP, 0.0, fit.profile.size() - 1.0)
		var j := mini(fit.profile.size() - 2, floori(at))
		var f := at - j
		var level := lerpf(fit.profile[j], fit.profile[j + 1], f)
		var power := lerpf(fit.strength[j], fit.strength[j + 1], f)
		var cap := lerpf(fit.limit[j], fit.limit[j + 1], f)
		h = base + clampf(level + detail - base, -cap, cap) * influence * pin * power
		# Ограниченная земляная полка дороги или обычной тропы на косом склоне.
		# Полотно остаётся частью того же меша и поверхности движения; вода закреплена.
		if _heights.water_level[i] == -INF and power > 0.0:
			var normal := Vector2(-road.delta.y, road.delta.x).normalized() * half
			var on_axis: Vector2 = road.a + road.delta * u
			var cross_grade := absf(_heights.base_ground_at(on_axis.x + normal.x, on_axis.y + normal.y) - _heights.base_ground_at(on_axis.x - normal.x, on_axis.y - normal.y)) / (2.0 * half)
			var bench := smoothstep(RoadBed.STEEP.x, RoadBed.STEEP.y, cross_grade)
			if bench > 0.0:
				# Узкая тропа следует высоте своей оси: сильная полка не усиливает продольное сглаживание у поворота.
				var axis_level := level if road.kind == "road" else _heights.base_ground_at(on_axis.x, on_axis.y)
				var dry_level := maxf(axis_level + detail, _wet_near(i) + RoadBed.WATER_GAP)
				var shelf := base + clampf(dry_level - base, -cap, cap)
				h = lerpf(h, shelf, influence * structure_pin * power * bench)
	if _heights.water_level[i] == -INF and h < base:
		h = maxf(h, minf(base, _wet_near(i) + RoadBed.WATER_GAP))
	return {h = h, color = color, uv = Vector2(side / half, float(surf)), surface = surf, road = road.kind == "road"}


## Та же треугольная интерполяция, что у TerrainBuilder (без билинейного расхождения с мешем).
## Горячий путь опоры без выделения словаря на каждую выборку высоты.
func height_at(x: float, z: float, width: int) -> float:
	var fx := x / TILE - 0.5
	var fz := z / TILE - 0.5
	if fx < 0.0 or fz < 0.0 or fx >= width - 1 or fz >= _height - 1:
		return INF
	var patch: Variant = patches.get(floori(fz) * width + floori(fx)) # один поиск вместо has + []
	if patch == null:
		return INF
	var sx := (fx - floorf(fx)) * DIV
	var sz := (fz - floorf(fz)) * DIV
	var ix := mini(DIV - 1, floori(sx))
	var iz := mini(DIV - 1, floori(sz))
	var tx := sx - ix
	var tz := sz - iz
	var a := iz * STRIDE + ix
	var hs: PackedFloat32Array = patch.h
	if tx + tz <= 1.0:
		return hs[a] + (hs[a + 1] - hs[a]) * tx + (hs[a + STRIDE] - hs[a]) * tz
	var d := a + STRIDE + 1
	return hs[d] + (hs[a + STRIDE] - hs[d]) * (1.0 - tx) + (hs[a + 1] - hs[d]) * (1.0 - tz)


## Вес покрытия для травы: та же интерполяция, без словаря и выборки высоты/вида пути.
func weight_at(x: float, z: float, width: int) -> float:
	var fx := x / TILE - 0.5
	var fz := z / TILE - 0.5
	if fx < 0.0 or fz < 0.0 or fx >= width - 1 or fz >= _height - 1:
		return 0.0
	var key := floori(fz) * width + floori(fx)
	if not patches.has(key):
		return 0.0
	var sx := (fx - floorf(fx)) * DIV
	var sz := (fz - floorf(fz)) * DIV
	var ix := mini(DIV - 1, floori(sx))
	var iz := mini(DIV - 1, floori(sz))
	var tx := sx - ix
	var tz := sz - iz
	var a := iz * STRIDE + ix
	var b := a + 1
	var c := a + STRIDE
	var wa := 1.0 - tx - tz
	var wb := tx
	var wc := tz
	if tx + tz > 1.0:
		a = c + 1
		wa = tx + tz - 1.0
		wb = 1.0 - tz
		wc = 1.0 - tx
	var colors: PackedColorArray = patches[key].color
	return colors[a].a * wa + colors[b].a * wb + colors[c].a * wc


func sample(x: float, z: float, width: int) -> Dictionary:
	var fx := x / TILE - 0.5
	var fz := z / TILE - 0.5
	var key := floori(fz) * width + floori(fx)
	if fx < 0.0 or fz < 0.0 or fx >= width - 1 or fz >= _height - 1 or not patches.has(key):
		return {}
	var p: Dictionary = patches[key]
	var sx := (fx - floorf(fx)) * DIV
	var sz := (fz - floorf(fz)) * DIV
	var ix := mini(DIV - 1, floori(sx))
	var iz := mini(DIV - 1, floori(sz))
	var tx := sx - ix
	var tz := sz - iz
	var a := iz * STRIDE + ix
	var b := a + 1
	var c := a + STRIDE
	var wa := 1.0 - tx - tz
	var wb := tx
	var wc := tz
	if tx + tz > 1.0:
		a = c + 1
		wa = tx + tz - 1.0
		wb = 1.0 - tz
		wc = 1.0 - tx
	var hs: PackedFloat32Array = p.h
	var colors: PackedColorArray = p.color
	var closest := a if wa >= wb and wa >= wc else (b if wb >= wc else c)
	return {h = hs[a] * wa + hs[b] * wb + hs[c] * wc,
		weight = colors[a].a * wa + colors[b].a * wb + colors[c].a * wc, surface = p.surface[closest], road = p.road[closest] != 0}
