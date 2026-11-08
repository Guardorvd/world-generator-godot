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
## 14.11: средние формы дорожного коридора (docs/ROAD_RELIEF.md) — одна система для дорог, троп и горных троп.
## По станциям пути через STEP метров считаются семь величин (CORRIDOR_STRIDE): подъём оси, перекос, выпуклость
## или корыто, продавленное место (глубина и где поперёк), форма каждой обочины (вал > 0, канава < 0); вершина
## метровой сетки складывает из них поперечное сечение. Мельче метра — RoadBump и шейдер, крупнее — RoadBed.
## Числа по виду пути, м: roll — пологие волны (~30 м), bump — бугры и впадины (~10 м), tilt — перекос от шума у края,
## tilt_keep — доля природного поперечного склона, tilt_max — предел перекоса (доля полуширины), dish/dish_var —
## выпуклость (+) или корыто (−) и разброс, hollow — продавленные места, ditch/lip — канава и вал у края,
## grade — предел добавленного продольного уклона.
const CORRIDOR := {
	#           roll  bump  tilt  keep  max   dish   var   hollow ditch lip   grade
	road =     [0.60, 0.26, 0.11, 0.30, 0.07, 0.03,  0.10, 0.20,  0.28, 0.09, 0.10],
	trail =    [0.48, 0.24, 0.12, 0.30, 0.09, -0.05, 0.07, 0.15,  0.18, 0.11, 0.14],
	mountain = [0.24, 0.18, 0.12, 0.20, 0.10, -0.03, 0.05, 0.10,  0.14, 0.13, 0.16],
}
const CORRIDOR_KINDS := ["road", "trail", "mountain"]
## Выраженность форм по покрытию RoadSurface: укатанная земля у поселений и песок спокойнее, грунт и лес — полностью
const CORRIDOR_SURFACE := [0.0, 0.85, 1.0, 0.55, 0.9, 0.7, 1.0, 0.9]
const CORRIDOR_STRIDE := 7
const CORRIDOR_FADE := 8.0     # формы включаются на столько метров от закреплённого места (вода, мост, развилка), м
const CORRIDOR_GAP := 4.5      # другой путь ближе суммы полуширин и этого, м: формы гаснут, чтобы зоны не встречались швом
const CORRIDOR_HOLLOW_W := 0.6 # полуширина продавленного места, доля полуширины полотна
const SHARED := 0.5            # путь того же вида и ширины вдоль оси ближе этого, м, — та же дорога (дубль сети): формы общие
const PREPARED_SCALE := 0.5    # путь трассы без земляных работ (trail_id, earthwork 0): формы слабее, без продавленных мест
static var natural_relief := true # false — без форм коридора (сравнение было/стало в стендах)
static var allow_fast_nearest := true # false — исходный цикл GDScript для сравнения
static var allow_fast_vertices := true # reference switch for complete vertex-channel parity
static var road_simd := true
static var restrict_local_index := true # reference switch for exact local-build comparisons
static var allow_fast_index := true # false — индекс отрезков на GDScript (эталон для tools/dod_verify.gd)
static var allow_fast_patches := true # false — сбор патчей в GDScript (эталон для tools/dod_verify.gd)

var patches := {}  # индекс исходного квадрата -> {h, color, uv, surface, road}; uv: поперечная координата, номер покрытия
var fit_routes := {} # маршрут -> метровые points, profile, strength, limit; горные тропы остаются прежними
var corridor := PackedFloat64Array() # формы коридора всех путей подряд, по CORRIDOR_STRIDE на станцию
var corridor_routes := {} # маршрут -> Vector2i(первая станция в corridor, число станций)
var build_timings := {}
var trail_shaping := {} # trail id -> cut/fill volumes, extremes, designed and natural grade, banking
var trail_elements_baked := false # A fresh refinement accepts one authored earthwork pass.
var _segments := {}
var _segment_list: Array[Dictionary] = []
var _structures := {}
var _heights: Heightfield
var _noise: FastNoiseLite
var _height := 0
var _base_cache := {} # одинаковые метровые выборки у соседних вершин, только на время запекания
var _points := PackedVector2Array() # точки уникальных вершин, только на время запекания (12.2)
var _dist_water := PackedFloat32Array() # w.dist_water; у копии потока — своя копия (12.2)
var _surf: Array = RoadSurface.LIST # у копии потока — своя копия таблицы покрытий (12.2)
var _origin := Vector2.ZERO # WorldData.world_origin в метрах: шум полотна в мировых координатах
var _only := {} # номера путей, у которых строятся патчи; пусто — у всех
var _wanted := {} # exact patch keys of the new routes; old neighbours are indexed only here
var _wanted_box := Rect2()
# Быстрый путь (DOD, ноябрь 2026): отрезки столбцами и индекс «клетка -> отрезки» от FastGrid.RoadIndex вместо словарей
var _cs_starts := PackedInt32Array() # CSR по клеткам мира: _cs_ids[_cs_starts[k] .. _cs_starts[k + 1]) — отрезки клетки k
var _cs_ids := PackedInt32Array()
var _sg_a := PackedVector2Array()
var _sg_delta := PackedVector2Array()
var _sg_len2 := PackedFloat64Array()
var _sg_half := PackedFloat64Array()
var _sg_route := PackedInt32Array()
var _sg_along := PackedFloat64Array()


## only — номера путей w.trails (ключи словаря): патчи и подгонка профиля только вокруг них, прочие пути
## участвуют как соседи (ближайший отрезок, развилки). Тогда у патча есть owner: 1 у вершин, где ближе всего
## путь из only. Trail Lab так добавляет новую трассу к готовому участку; пусто — все пути (игра).
static func build(heights: Heightfield, fit_road := true, only := {}) -> RoadRefinement:
	var r := RoadRefinement.new()
	r._heights = heights
	r._height = heights.world.H
	r._noise = FastNoiseLite.new()
	r._noise.seed = heights.world.seed_num
	r._noise.frequency = 1.0
	r._noise.fractal_octaves = 2
	r._dist_water = heights.world.dist_water
	r._origin = Vector2(heights.world.world_origin) * TILE
	r._only = only
	var started_us := Time.get_ticks_usec()
	if allow_fast_index and allow_fast_patches and allow_fast_nearest and allow_fast_vertices and only.is_empty() and heights.world.outer == null:
		var whole := Grid.fast_grid()
		if whole != null:
			return r._build_native(whole, fit_road)
	if not only.is_empty() and restrict_local_index:
		# Determine the exact output cells before indexing neighbours. Preserve the
		# original route/segment order in the final index, including nearest ties.
		for route: int in only:
			r._index(heights.world.trails[route], route)
		for key: int in r._segments:
			r._wanted[key] = true
			var point := Vector2(key % heights.world.W + 1, key / heights.world.W + 1) * TILE
			if r._wanted.size() == 1: r._wanted_box = Rect2(point, Vector2.ZERO)
			else: r._wanted_box = r._wanted_box.expand(point)
		r._wanted_box = r._wanted_box.grow(TILE)
		# A patch's last row/column is sampled through the adjacent cell's index.
		for key: int in r._wanted.keys():
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var x := key % heights.world.W + dx
					var z := key / heights.world.W + dz
					if x >= 0 and z >= 0 and x < heights.world.W and z < heights.world.H:
						r._wanted[z * heights.world.W + x] = true
		r._segments.clear()
		r._segment_list.clear()
	for route in heights.world.trails.size():
		var t: Dictionary = heights.world.trails[route]
		if RoadBed.KINDS.has(t.kind):
			r._index(t, route)
	r._index_structures()
	var keys: Array = r._segments.keys()
	if not only.is_empty():
		keys = keys.filter(func(key: int) -> bool:
			return (r._segments[key] as Array).any(func(s: Dictionary) -> bool: return only.has(s.route)))
	r.build_timings.index_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	started_us = Time.get_ticks_usec()
	if fit_road:
		r._fit_network()
	r.build_timings.fit_network_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	started_us = Time.get_ticks_usec()
	var cache := {}
	var fine_width := heights.world.W * DIV
	var nearest := PackedFloat64Array()
	var native := {}
	var fast := Grid.fast_grid() if allow_fast_nearest else null
	if fast != null:
		nearest = r._nearest_vertices(cache, fast, keys)
		r.build_timings.nearest_ms = (Time.get_ticks_usec() - started_us) / 1000.0
		var vertices_us := Time.get_ticks_usec()
		# С 12.2 уникальные вершины считаются на всех ядрах: каждая зависит только от своей точки
		# и уже готовых данных (рельеф, отрезки, профили), результат тот же, что подряд
		if allow_fast_vertices and heights.world.outer == null:
			native = r._native_vertices(fast, nearest)
		else:
			var points := r._points
			var job := func(a: int, b: int) -> Array:
				var own := r._thread_copy()
				var out := []
				for n in range(a, b): out.append(own._vertex(points[n].x, points[n].y, nearest, n * 4))
				return out
			var pieces := clampi(OS.get_processor_count(), 1, 8)
			var parts := Parallel.bands(points.size(), job, ceili(points.size() / float(pieces)))
			var done: Array = []
			for part: Array in parts: done.append_array(part)
			for vk: int in cache: cache[vk] = done[cache[vk]]
		r._points = PackedVector2Array()
		r.build_timings.vertex_math_ms = (Time.get_ticks_usec() - vertices_us) / 1000.0
	var native_h: PackedFloat32Array = native.get("h", PackedFloat32Array())
	var native_color: PackedColorArray = native.get("color", PackedColorArray())
	var native_uv: PackedVector2Array = native.get("uv", PackedVector2Array())
	var native_surface: PackedByteArray = native.get("surface", PackedByteArray())
	var native_road: PackedByteArray = native.get("road", PackedByteArray())
	var native_route: PackedInt32Array = native.get("route", PackedInt32Array())
	for key: int in keys:
		var cx := key % heights.world.W
		var cz := key / heights.world.W
		var hs := PackedFloat32Array()
		var colors := PackedColorArray()
		var uvs := PackedVector2Array()
		var surfaces := PackedByteArray()
		var roads := PackedByteArray()
		var owners := PackedByteArray()
		hs.resize(STRIDE * STRIDE)
		colors.resize(STRIDE * STRIDE)
		uvs.resize(STRIDE * STRIDE)
		surfaces.resize(STRIDE * STRIDE)
		roads.resize(STRIDE * STRIDE)
		if not only.is_empty():
			owners.resize(STRIDE * STRIDE)
		for z in STRIDE:
			for x in STRIDE:
				var ix := cx * DIV + x
				var iz := cz * DIV + z
				var vk := iz * fine_width + ix
				var idx := z * STRIDE + x
				if not native.is_empty():
					var request: int = cache[vk]
					hs[idx] = native_h[request]; colors[idx] = native_color[request]; uvs[idx] = native_uv[request]
					surfaces[idx] = native_surface[request]; roads[idx] = native_road[request]
					if not only.is_empty(): owners[idx] = 1 if only.has(native_route[request]) else 0
					continue
				if not cache.has(vk) or cache[vk] is int:
					var at: int = cache[vk] * 4 if cache.has(vk) else -1
					cache[vk] = r._vertex((ix * STEP) + TILE * 0.5, (iz * STEP) + TILE * 0.5, nearest, at)
				var v: Dictionary = cache[vk]
				hs[idx] = v.h
				colors[idx] = v.color
				uvs[idx] = v.uv
				surfaces[idx] = v.surface
				roads[idx] = 1 if v.road else 0
				if not only.is_empty():
					owners[idx] = 1 if only.has(v.route) else 0
		r.patches[key] = {h = hs, color = colors, uv = uvs, surface = surfaces, road = roads}
		if not only.is_empty():
			r.patches[key].owner = owners
	r.build_timings.vertices_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	# После запекания нет ссылок на Heightfield (цикл RefCounted) и временного пространственного индекса.
	r._heights = null
	r._segments.clear()
	r._wanted.clear()
	r._segment_list.clear()
	r._structures.clear()
	r._noise = null
	r._base_cache.clear()
	return r


## Индекс и вершины двумя вызовами C# (FastGrid.RoadIndex и FastGrid.RoadPatches): столбцами, без
## словарей на отрезок и на вершину. Результат тот же, что у пути в build ниже (он остаётся эталоном для
## tools/dod_verify.gd). Только для всей сети (only пусто) и без земли за краем карты.
func _build_native(fast: Object, fit_road: bool) -> RoadRefinement:
	var w := _heights.world
	var started_us := Time.get_ticks_usec()
	var ids := PackedInt32Array()
	var smoothing := PackedFloat64Array()
	var is_road := PackedByteArray()
	var starts := PackedInt32Array()
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var ws := PackedFloat64Array()
	var surf := PackedInt32Array()
	for route in w.trails.size():
		var t: Dictionary = w.trails[route]
		if not RoadBed.KINDS.has(t.kind):
			continue
		ids.append(route)
		is_road.append(1 if t.kind == "road" else 0)
		smoothing.append(0.65 if t.kind == "road" else (0.25 if t.kind == "trail" else 0.0))
		starts.append(xs.size())
		var line: Array = t.pts
		var covering: Variant = t.surf
		for n in line.size():
			var p: Dictionary = line[n]
			xs.append(p.x)
			ys.append(p.y)
			ws.append(p.w)
			surf.append(covering[n])
	starts.append(xs.size())
	var index: Dictionary = fast.RoadIndex(w.W, w.H, TILE, REACH, _heights.hv, starts, xs, ys, ws, surf, smoothing, is_road, ids)
	_cs_starts = index.starts
	_cs_ids = index.candidates
	_sg_a = index.a
	_sg_delta = index.delta
	_sg_len2 = index.len2
	_sg_half = index.half
	_sg_route = index.route
	_sg_along = index.along
	_index_structures()
	build_timings.index_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	started_us = Time.get_ticks_usec()
	if fit_road:
		_fit_network()
	build_timings.fit_network_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	started_us = Time.get_ticks_usec()
	var fits := PackedFloat64Array()
	var fit_start := PackedInt32Array()
	var fit_count := PackedInt32Array()
	fit_start.resize(w.trails.size())
	fit_count.resize(w.trails.size())
	for route: int in fit_routes:
		var fit: Dictionary = fit_routes[route]
		fit_start[route] = fits.size()
		fit_count[route] = fit.profile.size()
		for j in fit.profile.size():
			fits.append(fit.profile[j])
			fits.append(fit.strength[j])
			fits.append(fit.limit[j])
	var corridor_start := PackedInt32Array()
	var corridor_count := PackedInt32Array()
	corridor_start.resize(w.trails.size())
	corridor_count.resize(w.trails.size())
	for route: int in corridor_routes:
		var span: Vector2i = corridor_routes[route]
		corridor_start[route] = span.x * CORRIDOR_STRIDE
		corridor_count[route] = span.y
	var axes := PackedFloat64Array()
	for s: Dictionary in _heights.structures:
		axes.append(s.ax)
		axes.append(s.az)
		axes.append(s.bx)
		axes.append(s.bz)
	var surfaces := PackedFloat64Array()
	for s: Dictionary in _surf:
		var color: Array = s.get("color", [0, 0, 0])
		surfaces.append_array(PackedFloat64Array([color[0] / 255.0, color[1] / 255.0, color[2] / 255.0, s.get("rough", 0.0), s.get("organic", 0.0)]))
	var out: Dictionary = fast.RoadPatches(PackedInt32Array(index.keys), w.W, w.H, TILE, DIV, _sg_a, _sg_delta, _sg_len2, _sg_half,
		index.road, index.surf, index.next, index.ha, index.hb, _sg_along, _sg_route, _cs_starts, _cs_ids, fit_start, fit_count, fits,
		corridor_start, corridor_count, corridor, surfaces, _heights.hv, _heights.water_level, _dist_water, _noise, _origin, axes,
		RoadBed.STEEP.x, RoadBed.STEEP.y, RoadBed.WATER_GAP, RoadBed.PIN, RoadBed.PIN_FADE, REACH)
	patches = out.patches
	build_timings.native_points_ms = out.ms_points
	build_timings.native_vertices_ms = out.ms_vertices
	build_timings.native_assemble_ms = out.ms_assemble
	build_timings.nearest_ms = 0.0
	build_timings.vertex_math_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	build_timings.vertices_ms = build_timings.vertex_math_ms
	_heights = null
	_segments.clear()
	_structures.clear()
	_noise = null
	_cs_starts = PackedInt32Array()
	_cs_ids = PackedInt32Array()
	_sg_a = PackedVector2Array()
	_sg_delta = PackedVector2Array()
	_sg_len2 = PackedFloat64Array()
	_sg_half = PackedFloat64Array()
	_sg_route = PackedInt32Array()
	_sg_along = PackedFloat64Array()
	return self


## Готовые патчи без пересчёта (сохранённый участок Trail Lab): height — число строк клеток мира.
static func from_patches(ready: Dictionary, height: int) -> RoadRefinement:
	var r := RoadRefinement.new()
	r.patches = ready
	r._height = height
	return r


## Копия для одного потока (12.2): свои массивы рельефа и воды и свои таблицы покрытий. Общие массивы,
## которые читают все потоки на каждой вершине, упираются в один счётчик ссылок и почти не ускоряются
func _thread_copy() -> RoadRefinement:
	var c := RoadRefinement.new()
	c.fit_routes = fit_routes.duplicate(true)
	c.corridor = corridor.duplicate()
	c.corridor_routes = corridor_routes.duplicate()
	c._segments = _segments
	c._segment_list = _segment_list
	c._structures = _structures
	c._noise = _noise.duplicate() # тот же шум (те же свойства), но свой объект
	c._height = _height
	c._origin = _origin
	var h := Heightfield.new()
	h.world = _heights.world
	h.hv = _heights.hv.duplicate()
	h.hv_raw = _heights.hv_raw.duplicate()
	h.water_level = _heights.water_level.duplicate()
	c._heights = h
	c._dist_water = _heights.world.dist_water.duplicate()
	c._surf = RoadSurface.LIST.duplicate(true)
	return c


## Один вызов C# для всех уникальных вершин, без межъязыкового вызова на каждую из них.
## В cache сначала номера запросов, затем они заменяются готовыми словарями вершин.
func _nearest_vertices(cache: Dictionary, fast: Object, keys: Array) -> PackedFloat64Array:
	var w := _heights.world
	var points := PackedVector2Array()
	for key: int in keys:
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
	_points = points
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
func _native_vertices(fast: Object, nearest: PackedFloat64Array) -> Dictionary:
	var segments := PackedFloat64Array()
	var fits := PackedFloat64Array()
	var offsets := {}
	for route: int in fit_routes:
		var fit: Dictionary = fit_routes[route]
		offsets[route] = Vector2i(fits.size(), fit.profile.size())
		for j in fit.profile.size(): fits.append_array(PackedFloat64Array([fit.profile[j], fit.strength[j], fit.limit[j]]))
	for s: Dictionary in _segment_list:
		var fit: Vector2i = offsets.get(s.route, Vector2i.ZERO)
		var span: Vector2i = corridor_routes.get(s.route, Vector2i.ZERO)
		segments.append_array(PackedFloat64Array([s.a.x, s.a.y, s.delta.x, s.delta.y, s.len2, s.half,
			1 if s.kind == "road" else 0, s.surf, s.next, s.ha, s.hb, s.along, s.route, fit.x, fit.y, span.x * CORRIDOR_STRIDE, span.y]))
	var starts := PackedInt32Array()
	starts.resize(_heights.world.N + 1)
	var axes := PackedFloat64Array()
	if not _structures.is_empty():
		for key in _heights.world.N:
			starts[key] = axes.size() / 4
			for s: Dictionary in _structures.get(key, []): axes.append_array(PackedFloat64Array([s.ax, s.az, s.bx, s.bz]))
		starts[_heights.world.N] = axes.size() / 4
	var surfaces := PackedFloat64Array()
	for s: Dictionary in _surf:
		var color: Array = s.get("color", [0, 0, 0])
		surfaces.append_array(PackedFloat64Array([color[0] / 255.0, color[1] / 255.0, color[2] / 255.0, s.get("rough", 0.0), s.get("organic", 0.0)]))
	return fast.RoadVertices(_points, nearest, _heights.world.W, _height, TILE, _heights.hv, _heights.water_level,
		_dist_water, _noise, _origin, segments, fits, corridor, surfaces, starts, axes, RoadBed.STEEP.x, RoadBed.STEEP.y, RoadBed.WATER_GAP, road_simd)


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
	var needed := PackedByteArray()
	if not _wanted.is_empty():
		needed.resize(pts.size())
		for n in range(1, pts.size()):
			var a := Vector2(pts[n - 1].x, pts[n - 1].y) * TILE
			var b := Vector2(pts[n].x, pts[n].y) * TILE
			var reach := (float(pts[n - 1].w) + float(pts[n].w)) * TILE * 0.25 + REACH + TILE
			if Rect2(a, b - a).abs().grow(reach).intersects(_wanted_box, true):
				needed[n - 1] = 1
				needed[n] = 1
		if not needed.has(1): return
	var profile := PackedFloat32Array()
	# У троп сохраняем естественные перегибы; поперечная полка считается отдельно.
	var smoothing := 0.65 if t.kind == "road" else (0.25 if t.kind == "trail" else 0.0)
	# Соседние окна используют одни и те же высоты; хранить в double, как результат выборки.
	var base_heights := PackedFloat64Array()
	if smoothing > 0.0:
		base_heights.resize(pts.size())
		var samples := needed.duplicate()
		if not needed.is_empty():
			for n in pts.size():
				if needed[n] != 0:
					for j in range(maxi(0, n - 3), mini(pts.size(), n + 4)): samples[j] = 1
		for n in pts.size():
			if not samples.is_empty() and samples[n] == 0: continue
			base_heights[n] = _heights.base_ground_at(pts[n].x * TILE, pts[n].y * TILE)
	# Короткое симметричное окно по уже выровненному полотну; концы развилок закреплены.
	for n in pts.size():
		if not needed.is_empty() and needed[n] == 0:
			profile.append(0.0)
			continue
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
		if not needed.is_empty() and (needed[n - 1] == 0 or needed[n] == 0):
			along += a.distance_to(b)
			continue
		var half := (float(pts[n - 1].w) + float(pts[n].w)) * TILE * 0.25
		var surf: int = t.surf[n - 1]
		var next_surf: int = t.surf[n]
		var s := {a = a, delta = b - a, len2 = a.distance_squared_to(b), half = half,
			ha = profile[n - 1], hb = profile[n], surf = surf, next = next_surf, kind = t.kind, route = route, along = along}
		s.id = -1
		along += a.distance_to(b)
		var reach := half + REACH + TILE
		for z in range(maxi(0, floori((minf(a.y, b.y) - reach) / TILE - 0.5)), mini(w.H - 1, ceili((maxf(a.y, b.y) + reach) / TILE - 0.5))):
			for x in range(maxi(0, floori((minf(a.x, b.x) - reach) / TILE - 0.5)), mini(w.W - 1, ceili((maxf(a.x, b.x) + reach) / TILE - 0.5))):
				var key := z * w.W + x
				if not _wanted.is_empty() and not _wanted.has(key): continue
				var center := Vector2(x + 1.0, z + 1.0) * TILE
				if Grid.segment_dist(center.x, center.y, a.x, a.y, b.x, b.y) > half + REACH + TILE * 0.71:
					continue
				if s.id < 0:
					s.id = _segment_list.size()
					_segment_list.append(s)
				if not _segments.has(key):
					_segments[key] = []
				_segments[key].append(s)


## 4.5: три линейных прохода по пути — оценка, расстояние до защищённых мест, профиль.
## Резкий локальный перегиб требует обработки, постоянный чрезмерный уклон — другого маршрута.
## 14.11: тот же проход по станциям собирает входы форм коридора для всех видов путей (горные тропы — без подгонки
## профиля); формы всех путей считаются потом одним пакетом (_build_corridor).
func _fit_network() -> void:
	var w := _heights.world
	if allow_fast_vertices and not _cs_starts.is_empty() and w.outer == null:
		var fast := Grid.fast_grid()
		if fast != null:
			_fit_network_native(fast)
			return
	var batch := {points = PackedVector2Array(), half = PackedFloat32Array(), surface = PackedInt32Array(), gate = PackedFloat32Array(),
		starts = PackedInt32Array(), kinds = PackedInt32Array(), scales = PackedFloat32Array(), routes = PackedInt32Array()}
	for route in w.trails.size():
		var t: Dictionary = w.trails[route]
		var kind := CORRIDOR_KINDS.find(t.kind)
		if kind < 0 or not (_only.is_empty() or _only.has(route)):
			continue
		var fitted: bool = t.kind != "mountain"
		# Трасса с земляными работами (trail_id, earthwork > 0) — авторская геометрия TrailShaping: форм коридора под ней нет.
		# Путь трассы без земляных работ — природная тропа: формы слабее и без продавленных мест.
		var scale := 1.0
		if t.has("trail_id"):
			scale = PREPARED_SCALE if (t.get("formation", Vector3.ZERO) as Vector3).x <= 0.0 else 0.0
		var shaped := natural_relief and scale > 0.0
		if not fitted and not shaped:
			continue
		var points := PackedVector2Array()
		var halves := PackedFloat32Array()
		var surfs := PackedInt32Array()
		var along := 0.0
		var next := 0.0
		for n in range(1, t.pts.size()):
			var a := Vector2(t.pts[n - 1].x, t.pts[n - 1].y) * TILE
			var b := Vector2(t.pts[n].x, t.pts[n].y) * TILE
			var length := a.distance_to(b)
			if length < 0.01:
				continue
			while next <= along + length:
				var f := (next - along) / length
				points.append(a.lerp(b, f))
				halves.append(lerpf(float(t.pts[n - 1].w), float(t.pts[n].w), f) * TILE * 0.5)
				surfs.append(t.surf[n - 1] if f < 0.5 else t.surf[n])
				next += STEP
			along += length
		var count := points.size()
		if count < 3:
			continue
		var gate := PackedFloat32Array()
		gate.resize(count)
		if not fitted:
			for j in count:
				var tangent := (points[mini(count - 1, j + 2)] - points[maxi(0, j - 2)]).normalized()
				gate[j] = 1.0 if (_fit_safe(points[j], tangent, route, j * STEP, false, halves[j]) & 2) != 0 else 0.0
		else:
			_fit_route(t, route, points, halves, gate)
		if shaped:
			var batch_points: PackedVector2Array = batch.points
			batch.starts.append(batch_points.size())
			batch.kinds.append(kind)
			batch.scales.append(scale)
			batch.routes.append(route)
			batch.points.append_array(points)
			batch.half.append_array(halves)
			batch.surface.append_array(surfs)
			batch.gate.append_array(gate)
	_build_corridor(batch)


## 14.11: весь проход одним вызовом C# (FastGrid.RoadFitNetwork) — станции, подгонка профиля, защита, формы коридора.
## Результат тот же, что у GDScript-пути выше (он остаётся эталоном): прежде этот проход был самым долгим этапом полотна.
func _fit_network_native(fast: Object) -> void:
	var w := _heights.world
	var starts := PackedInt32Array()
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var ws := PackedFloat64Array()
	var surf := PackedInt32Array()
	var kinds := PackedInt32Array()
	var scales := PackedFloat32Array()
	var ids := PackedInt32Array()
	for route in w.trails.size():
		var t: Dictionary = w.trails[route]
		var kind := CORRIDOR_KINDS.find(t.kind)
		if kind < 0:
			continue
		var scale := 1.0
		if t.has("trail_id"):
			scale = PREPARED_SCALE if (t.get("formation", Vector3.ZERO) as Vector3).x <= 0.0 else 0.0
		ids.append(route)
		kinds.append(kind)
		scales.append(scale if natural_relief else 0.0)
		starts.append(xs.size())
		var covering: Variant = t.surf
		for n in t.pts.size():
			var p: Dictionary = t.pts[n]
			xs.append(p.x)
			ys.append(p.y)
			ws.append(p.w)
			surf.append(covering[n])
	starts.append(xs.size())
	var axes := PackedFloat64Array()
	for s: Dictionary in _heights.structures:
		axes.append_array(PackedFloat64Array([s.ax, s.az, s.bx, s.bz]))
	var villages := PackedFloat64Array()
	for village: SettlementData in w.settlements:
		villages.append_array(PackedFloat64Array([village.x, village.y]))
	var table := PackedFloat64Array()
	for name: String in CORRIDOR_KINDS:
		table.append_array(PackedFloat64Array(CORRIDOR[name]))
	table.append_array(PackedFloat64Array(CORRIDOR_SURFACE))
	var limits := PackedFloat64Array([RoadBed.SHORE.y, RoadBed.PIN, RoadBed.PIN_FADE, REACH, SHARED, FIT_FADE, FIT_LIMIT, BENCH_LIMIT, TRAIL_BENCH_LIMIT])
	var route_kinds := PackedInt32Array()
	for t: Dictionary in w.trails:
		route_kinds.append(CORRIDOR_KINDS.find(t.kind) if t.kind != "animal" else -1)
	var out: Dictionary = fast.RoadFitNetwork(starts, xs, ys, ws, surf, kinds, scales, ids, w.W, w.H, TILE, STEP, _heights.hv,
		_heights.hv_raw, _heights.water_level, _dist_water, axes, villages, _sg_a, _sg_delta, _sg_len2, _sg_half, _sg_route, _sg_along,
		_cs_starts, _cs_ids, route_kinds, _noise, _origin, limits, CORRIDOR_FADE, CORRIDOR_GAP, CORRIDOR_STRIDE, table)
	var routes: PackedInt32Array = out.routes
	var at: PackedInt32Array = out.starts
	var fitted: PackedByteArray = out.fitted
	var shaped: PackedFloat32Array = out.scales
	var points: PackedVector2Array = out.points
	var profile: PackedFloat32Array = out.profile
	var strength: PackedFloat32Array = out.strength
	var limit: PackedFloat32Array = out.limit
	corridor = out.corridor
	corridor_routes = {}
	for r in routes.size():
		var from := at[r]
		var to := at[r + 1]
		if fitted[r] != 0:
			fit_routes[routes[r]] = {points = points.slice(from, to), profile = profile.slice(from, to),
				strength = strength.slice(from, to), limit = limit.slice(from, to)}
		if shaped[r] > 0.0:
			corridor_routes[routes[r]] = Vector2i(from, to - from)


## Подгонка профиля одной дороги или тропы (4.5). gate получает долю станции, где разрешены формы коридора.
func _fit_route(t: Dictionary, route: int, points: PackedVector2Array, halves: PackedFloat32Array, gate: PackedFloat32Array) -> void:
	var count := points.size()
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
		var safe := _fit_safe(p, tangent, route, j * STEP, t.kind == "road", halves[j])
		if safe == 0:
			allowed[j] = 0.0
		gate[j] = allowed[j] if (safe & 2) != 0 else 0.0
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


## Формы коридора пакета на GDScript (эталон; весь мир в игре считает FastGrid.RoadFitNetwork, см. _fit_network_native).
func _build_corridor(batch: Dictionary) -> void:
	corridor = PackedFloat64Array()
	corridor_routes = {}
	var starts: PackedInt32Array = batch.starts
	if starts.is_empty():
		return
	var points: PackedVector2Array = batch.points
	starts.append(points.size())
	var table := PackedFloat64Array()
	for name: String in CORRIDOR_KINDS:
		table.append_array(PackedFloat64Array(CORRIDOR[name]))
	table.append_array(PackedFloat64Array(CORRIDOR_SURFACE))
	corridor = _corridor_reference(points, batch.half, batch.surface, batch.gate, starts, batch.kinds, batch.scales, batch.routes, table)
	var routes: PackedInt32Array = batch.routes
	for k in routes.size():
		corridor_routes[routes[k]] = Vector2i(starts[k], starts[k + 1] - starts[k])


## Эталон FastGrid.CorridorRoute: те же операции в том же порядке. Природный поперечный склон и уклон — по рельефу
## до полотна (hv_raw), характер участка (спокойный, волнистый, разбитый) — медленный шум в мировых метрах.
func _corridor_reference(points: PackedVector2Array, halves: PackedFloat32Array, surfaces: PackedInt32Array, gates: PackedFloat32Array,
		starts: PackedInt32Array, kinds: PackedInt32Array, scales: PackedFloat32Array, routes: PackedInt32Array, table: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(points.size() * CORRIDOR_STRIDE)
	var kind_size: int = CORRIDOR.road.size()
	var surface_at := kind_size * CORRIDOR_KINDS.size()
	for r in kinds.size():
		var from := starts[r]
		var to := starts[r + 1]
		var n := to - from
		var k := kinds[r] * kind_size
		var scale: float = scales[r]
		var holes := 1.0 if scale >= 1.0 else 0.0
		# другой путь (или петля этого) ближе суммы полуширин и CORRIDOR_GAP — формы гаснут: зоны не встречаются швом
		var open := PackedFloat64Array()
		open.resize(n)
		for j in n:
			open[j] = gates[from + j]
			var tangent := (points[mini(to - 1, from + j + 2)] - points[maxi(from, from + j - 2)]).normalized()
			if open[j] > 0.0 and _corridor_crowded(points[from + j], tangent, routes[r], j * STEP, halves[from + j]):
				open[j] = 0.0
		# расстояние до закреплённой станции в обе стороны; концы пути закреплены
		var dist := PackedFloat64Array()
		dist.resize(n)
		for j in n:
			dist[j] = 0.0 if open[j] <= 0.0 or j == 0 else dist[j - 1] + STEP
		var back := 0.0
		for j in range(n - 1, -1, -1):
			back = 0.0 if open[j] <= 0.0 or j == n - 1 else back + STEP
			dist[j] = minf(dist[j], back)
		var lift := PackedFloat64Array()
		lift.resize(n)
		for j in n:
			var i := from + j
			var gate: float = open[j] * smoothstep(0.0, CORRIDOR_FADE, dist[j])
			if gate <= 0.0:
				continue
			var tangent := (points[mini(to - 1, i + 2)] - points[maxi(from, i - 2)]).normalized()
			var across := Vector2(tangent.y, -tangent.x)
			var half: float = halves[i]
			var reach := half + 3.0
			var a := points[i] + across * reach
			var b := points[i] - across * reach
			var cross := (_heights.base_ground_at(a.x, a.y, true) - _heights.base_ground_at(b.x, b.y, true)) / (2.0 * reach)
			var g0 := maxi(from, i - 5)
			var g1 := mini(to - 1, i + 5)
			var grade := absf(_heights.base_ground_at(points[g1].x, points[g1].y, true) - _heights.base_ground_at(points[g0].x, points[g0].y, true)) / maxf(1.0, g1 - g0) / STEP
			var p := points[i] + _origin
			var character := _noise.get_noise_2d(p.x * 0.005 + 311.0, p.y * 0.005 - 97.0)
			var roll := _noise.get_noise_2d(p.x * 0.033 + 17.0, p.y * 0.033 + 53.0)
			var bump := _noise.get_noise_2d(p.x * 0.1 - 41.0, p.y * 0.1 + 9.0)
			# односторонние величины берутся по обе стороны полотна: у пути в обратную сторону или у второго пути той же
			# линии перекос, продавленное место и обочины лежат там же
			var wide := across * 6.0
			var wobble := (_noise.get_noise_2d((p.x + wide.x) * 0.045 + 88.0, (p.y + wide.y) * 0.045 - 14.0)
				- _noise.get_noise_2d((p.x - wide.x) * 0.045 + 88.0, (p.y - wide.y) * 0.045 - 14.0)) * 0.9
			var bowl := _noise.get_noise_2d(p.x * 0.022 - 201.0, p.y * 0.022 + 77.0)
			var hole := _noise.get_noise_2d(p.x * 0.12 + 57.0, p.y * 0.12 + 211.0)
			var near := across * 4.0
			var spot := _noise.get_noise_2d((p.x + near.x) * 0.04 - 140.0, (p.y + near.y) * 0.04 + 33.0) \
				- _noise.get_noise_2d((p.x - near.x) * 0.04 - 140.0, (p.y - near.y) * 0.04 + 33.0)
			var out_r := p + across * (half + 1.5)
			var out_l := p - across * (half + 1.5)
			var left := _noise.get_noise_2d(out_l.x * 0.028 + 400.0, out_l.y * 0.028 + 12.0)
			var right := _noise.get_noise_2d(out_r.x * 0.028 + 400.0, out_r.y * 0.028 + 12.0)
			var energy := lerpf(0.3, 1.0, smoothstep(-0.3, 0.0, character)) + 0.5 * smoothstep(0.15, 0.4, character)
			energy *= 1.0 + 0.5 * smoothstep(0.05, 0.15, grade)
			var broken := smoothstep(0.12, 0.35, character)
			var mul: float = table[surface_at + surfaces[i]] * scale
			var at := i * CORRIDOR_STRIDE
			lift[j] = (table[k] * roll * (0.6 + 0.4 * energy) + table[k + 1] * bump * energy) * mul * gate
			var natural := cross * table[k + 3] * (1.0 - smoothstep(0.25, 0.5, absf(cross))) * half
			var limit := table[k + 4] * half
			out[at + 1] = clampf(natural + table[k + 2] * wobble * (0.5 + 0.5 * energy), -limit, limit) * scale * gate
			out[at + 2] = (table[k + 5] + table[k + 6] * bowl) * (0.5 + 0.5 * energy) * scale * gate
			out[at + 3] = table[k + 7] * smoothstep(0.2, 0.55, hole) * lerpf(0.3, 1.0, broken) * mul * holes * gate
			out[at + 4] = clampf(spot * 1.6, -0.7, 0.7)
			var slope := smoothstep(0.04, 0.15, absf(cross)) * (1.0 - smoothstep(0.35, 0.6, absf(cross)))
			var gain := (0.6 + 0.4 * energy) * scale * gate
			out[at + 5] = _shoulder(-1.0, cross, left, slope, table[k + 8], table[k + 9]) * gain
			out[at + 6] = _shoulder(1.0, cross, right, slope, table[k + 8], table[k + 9]) * gain
		# добавленный продольный уклон не круче grade: от закреплённых нулей формы поднимаются плавно
		var cap := table[k + 10] * STEP
		# Сначала ограничиваем высоту расстоянием до закреплённых нулей: проходы уклона
		# должны уменьшать соседние пики, а не сдвигать сами закреплённые станции.
		for j in n:
			lift[j] = clampf(lift[j], -cap * dist[j] / STEP, cap * dist[j] / STEP)
		for j in range(1, n):
			lift[j] = clampf(lift[j], lift[j - 1] - cap, lift[j - 1] + cap)
		for j in range(n - 2, -1, -1):
			lift[j] = clampf(lift[j], lift[j + 1] - cap, lift[j + 1] + cap)
		for j in n:
			out[(from + j) * CORRIDOR_STRIDE] = 0.0 if dist[j] == 0.0 else lift[j]
	return out


## Обочина с одной стороны: на косом склоне выше по склону канава (сток), ниже — земляной вал (отвал); на ровном —
## по шуму то канава, то вал. side — сторона полотна (−1/+1), cross — природный поперечный уклон (+: выше сторона +1).
## Есть ли рядом другой путь или петля этого (отрезки клеток 3 × 3 вокруг точки; порядок не важен)
func _corridor_crowded(p: Vector2, tangent: Vector2, route: int, along: float, own_half: float) -> bool:
	var w := _heights.world
	var cx := floori(p.x / TILE - 0.5)
	var cz := floori(p.y / TILE - 0.5)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var x := cx + dx
			var z := cz + dz
			if x < 0 or z < 0 or x >= w.W or z >= w.H:
				continue
			var key := z * w.W + x
			if not _cs_starts.is_empty():
				for k in range(_cs_starts[key], _cs_starts[key + 1]):
					var id := _cs_ids[k]
					if _corridor_near(p, tangent, route, along, own_half, _sg_a[id], _sg_delta[id], _sg_len2[id], _sg_half[id], _sg_route[id], _sg_along[id]):
						return true
			else:
				for s: Dictionary in _segments.get(key, []):
					if _corridor_near(p, tangent, route, along, own_half, s.a, s.delta, s.len2, s.half, s.route, s.along):
						return true
	return false


func _corridor_near(p: Vector2, tangent: Vector2, route: int, along: float, own_half: float, a: Vector2, delta: Vector2, len2: float,
		half: float, seg_route: int, seg_along: float) -> bool:
	if seg_route == route:
		if absf(seg_along - along) <= 20.0:
			return false
		var u := clampf((p - a).dot(delta) / len2, 0.0, 1.0)
		if absf(seg_along + u * sqrt(len2) - along) <= 20.0:
			return false
	var b := a + delta
	var gap := Grid.segment_dist(p.x, p.y, a.x, a.y, b.x, b.y)
	if seg_route != route and _shared(gap, absf(tangent.dot(delta.normalized())) < 0.9, route, seg_route, own_half, half):
		return false
	return gap < half + own_half + CORRIDOR_GAP


## Другой путь — то же полотно: вдоль (не поперёк), ось ближе SHARED, тот же вид и та же полуширина
func _shared(gap: float, crossing: bool, route: int, other: int, own_half: float, half: float) -> bool:
	var trails := _heights.world.trails
	return not crossing and gap < SHARED and own_half >= 0.0 and absf(half - own_half) < 0.05 \
		and trails[route].kind == trails[other].kind


static func _shoulder(side: float, cross: float, n: float, slope: float, ditch: float, lip: float) -> float:
	var flat := lip * minf(1.0, n * 2.5) if n >= 0.0 else -ditch * minf(1.0, -n * 2.5)
	var sloped := -ditch * (0.7 + 0.3 * n) if side * cross > 0.0 else lip * (0.6 + 0.4 * n)
	return lerpf(flat, sloped, slope)


static func _bell(t: float) -> float:
	var q := 1.0 - t * t
	return q * q if q > 0.0 else 0.0


## Bit 0: existing profile fit allowed; bit 1: corridor forms allowed as well.
## Shallow forks pin only the corridor forms, preserving the established fitted profile.
func _fit_safe(p: Vector2, tangent: Vector2, route: int, along: float, shore_ok := false, own_half := -1.0) -> int:
	var w := _heights.world
	var safe := 3
	var cell := floori(p.y / TILE) * w.W + floori(p.x / TILE)
	if cell < 0 or cell >= w.N or (not shore_ok and w.dist_water[cell] < RoadBed.SHORE.y) or _heights.water_level[cell] != -INF:
		return 0
	var key := floori(p.y / TILE - 0.5) * w.W + floori(p.x / TILE - 0.5)
	for s: Dictionary in _structures.get(key, []):
		if Grid.segment_dist(p.x, p.y, s.ax, s.az, s.bx, s.bz) < RoadBed.PIN + RoadBed.PIN_FADE:
			return 0
	if not _cs_starts.is_empty():
		# Быстрый путь: те же отрезки клетки столбцами (FastGrid.RoadIndex), те же вычисления
		if key >= 0 and key < w.N:
			for k in range(_cs_starts[key], _cs_starts[key + 1]):
				var id := _cs_ids[k]
				var a := _sg_a[id]
				var delta := _sg_delta[id]
				var b := a + delta
				var seg_route := _sg_route[id]
				var other := seg_route != route
				var crossing: bool = other and absf(tangent.dot(delta.normalized())) < 0.9
				var hairpin := false
				if seg_route == route and absf(_sg_along[id] - along) > 20.0:
					var u := clampf((p - a).dot(delta) / _sg_len2[id], 0.0, 1.0)
					hairpin = absf(_sg_along[id] + u * sqrt(_sg_len2[id]) - along) > 20.0
				if other or hairpin:
					var gap := Grid.segment_dist(p.x, p.y, a.x, a.y, b.x, b.y)
					if gap < _sg_half[id] + REACH + 0.5:
						if crossing or hairpin: return 0
						# 14.11: путь того же вида и ширины, идущий той же линией (дубль сети), — одно полотно: формы коридора
						# у обоих одинаковы (шум по месту), закреплять всю общую часть не нужно. Развилка закреплена, как раньше
						if not _shared(gap, crossing, route, seg_route, own_half, _sg_half[id]): safe = 1
	else:
		for s: Dictionary in _segments.get(key, []):
			var b: Vector2 = s.a + s.delta
			var other: bool = s.route != route
			var crossing: bool = other and absf(tangent.dot(s.delta.normalized())) < 0.9
			var hairpin := false
			if s.route == route and absf(s.along - along) > 20.0:
				var u := clampf((p - s.a).dot(s.delta) / s.len2, 0.0, 1.0)
				hairpin = absf(s.along + u * sqrt(s.len2) - along) > 20.0
			if other or hairpin:
				var gap := Grid.segment_dist(p.x, p.y, s.a.x, s.a.y, b.x, b.y)
				if gap < s.half + REACH + 0.5:
					if crossing or hairpin: return 0
					if not _shared(gap, crossing, route, s.route, own_half, s.half): safe = 1
	for village: SettlementData in w.settlements:
		if p.distance_to(Vector2(village.x, village.y) * TILE) < 10.0:
			return 0
	return safe


func _base_at(x: float, z: float) -> float:
	return _heights.base_ground_at(x, z)


## Без кэша (с 12.2): вершины считаются в нескольких потоках, а это всего восемь чтений
func _wet_near(i: int) -> float:
	return RoadBed.wet_near(_heights, i)


func _vertex(x: float, z: float, nearest := PackedFloat64Array(), nearest_at := -1) -> Dictionary:
	var W := _heights.world.W
	var H := _height
	var base := _base_at(x, z)
	var key := clampi(floori(z / TILE - 0.5), 0, H - 2) * W + clampi(floori(x / TILE - 0.5), 0, W - 2)
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
		return {h = base, color = Color(0, 0, 0, 0), uv = Vector2.ZERO, surface = 0, road = false, route = -1}
	var half: float = road.half
	var d := distance
	# Несимметричные края и разная ширина обочины, плавные метровые неровности (шум — в мировых метрах).
	var slow := _noise.get_noise_2d((x + _origin.x) * 0.13, (z + _origin.y) * 0.13)
	var grain := _noise.get_noise_2d((x + _origin.x) * 0.8 + 71.0, (z + _origin.y) * 0.8)
	var edge := half + slow * 0.24 + grain * 0.10
	var shoulder := 0.7 + (slow + 1.0) * 0.3
	var mask := 1.0 - smoothstep(edge * 0.55, edge + shoulder, d)
	var surf: int = road.surf if u < 0.5 else road.next
	var ca: Array = _surf[road.surf].color
	var cb: Array = _surf[road.next].color
	var color := Color8(ca[0], ca[1], ca[2]).lerp(Color8(cb[0], cb[1], cb[2]), smoothstep(0.0, 1.0, u)).srgb_to_linear()
	if surf == RoadSurface.MEADOW:
		mask *= 0.65
	# Меняется только вид края. Прежняя маска остаётся для геометрической микронеровности.
	var ground_mask := mask
	var blend := smoothstep(0.0, 1.0, u)
	var organic := lerpf(_surf[road.surf].organic, _surf[road.next].organic, blend)
	var visual_edge := edge * (1.0 - organic * 0.12)
	var visual_shoulder := shoulder * (1.0 + organic * 0.5)
	color.a = (1.0 - smoothstep(visual_edge * 0.55, visual_edge + visual_shoulder, d)) * (1.0 - organic * 0.35)
	var influence := 1.0 - smoothstep(half + 0.3, half + REACH, d)
	var cx := clampi(floori(x / TILE), 0, W - 1)
	var cz := clampi(floori(z / TILE), 0, H - 1)
	var i := cz * W + cx
	var pin := smoothstep(RoadBed.SHORE.x, RoadBed.SHORE.y, _dist_water[i])
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
	var crown := 0.035 * (1.0 - smoothstep(0.0, half, d))
	# Sub-metre ruts, stones and grain belong to RoadBump + its shader field. Baking 0.8 m noise or a 30 cm rut
	# into a metre grid only aliases it (14.11: the grain term is gone from the height for that reason).
	var detail: float = crown + slow * 0.06 * (1.0 - ground_mask)
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
	# 14.11: формы коридора — одна настоящая поверхность для меша и колёс (дороги, тропы, горные тропы)
	if corridor_routes.has(road.route):
		var span: Vector2i = corridor_routes[road.route]
		var at := clampf((road.along + u * sqrt(road.len2)) / STEP, 0.0, span.y - 1.0)
		var j := mini(span.y - 2, floori(at))
		var f := at - j
		var o := (span.x + j) * CORRIDOR_STRIDE
		var c := corridor
		var lift := lerpf(c[o], c[o + CORRIDOR_STRIDE], f)
		var tilt := lerpf(c[o + 1], c[o + CORRIDOR_STRIDE + 1], f)
		var dish := lerpf(c[o + 2], c[o + CORRIDOR_STRIDE + 2], f)
		var hollow := lerpf(c[o + 3], c[o + CORRIDOR_STRIDE + 3], f)
		var hollow_at := lerpf(c[o + 4], c[o + CORRIDOR_STRIDE + 4], f)
		var side_neg := lerpf(c[o + 5], c[o + CORRIDOR_STRIDE + 5], f)
		var side_pos := lerpf(c[o + 6], c[o + CORRIDOR_STRIDE + 6], f)
		var across := side / half
		var s := clampf(across, -1.0, 1.0)
		var section := tilt * s + dish * (1.0 - s * s) - hollow * _bell((across - hollow_at) / CORRIDOR_HOLLOW_W)
		var core := (lift + section) * (1.0 - smoothstep(half + 0.3, half + 2.2, d))
		var e := d - half
		var v := side_neg if across < 0.0 else side_pos
		var bank := v * _bell((e - 0.35) / 0.8) if v > 0.0 else v * _bell((e - 1.3) / 0.75)
		var edge_pin := smoothstep(0.0, FIT_FADE, minf(minf(x - TILE * 0.5, (W - 0.5) * TILE - x), minf(z - TILE * 0.5, (H - 0.5) * TILE - z)))
		var gain := pin * edge_pin
		h += (core + bank) * gain
		# низкие места сечения (корыто, нижний край, продавленное место) темнее и сырее, выпуклые — светлее и суше;
		# на земляном валу проступает трава. Так формы читаются и при ровном свете
		var shade := clampf(section * gain * 2.5, -0.22, 0.12)
		color.r *= 1.0 + shade
		color.g *= 1.0 + shade
		color.b *= 1.0 + shade
		color.a *= 1.0 - clampf(maxf(0.0, bank) * gain * 4.0, 0.0, 0.5)
	if _heights.water_level[i] == -INF and h < base:
		h = maxf(h, minf(base, _wet_near(i) + RoadBed.WATER_GAP))
	return {h = h, color = color, uv = Vector2(side / half, float(surf)), surface = surf, road = road.kind == "road", route = road.route}


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
	var uvs: PackedVector2Array = p.uv
	var closest := a if wa >= wb and wa >= wc else (b if wb >= wc else c)
	# 12.3: across — поперечная координата полотна (UV2.x меша): колеи RoadBump у колёс там же, где в шейдере
	return {h = hs[a] * wa + hs[b] * wb + hs[c] * wc,
		weight = colors[a].a * wa + colors[b].a * wb + colors[c].a * wc, surface = p.surface[closest], road = p.road[closest] != 0,
		across = uvs[a].x * wa + uvs[b].x * wb + uvs[c].x * wc}

