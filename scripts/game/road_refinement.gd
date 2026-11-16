class_name RoadRefinement
extends RefCounted
## 4.4: локальная метровая сетка Road Refinement Layer. Общая сетка мира не меняется.
## Патчи заменяют исходные треугольники, а ground_at читает те же вершины и диагонали.
## За зоной влияния дополнительные вершины лежат точно на прежних треугольниках.
## 16.11.2026: математика — индекс отрезков, подгонка профиля, формы коридора и вершины метровой сетки — только на C#
## (scripts/core/FastGrid.Road*.cs, scripts/core/roads/), здесь фасад: сбор столбцов, запись патчей и чтение готовой
## сетки (height_at, weight_at, edge_at, sample, from_patches, pin_coarse_edges). Эталон — tools/road_golden.gd,
## описание — docs/ROADS_CSHARP.md.

const Section := preload("res://scripts/world/road_section.gd")
const DIV := 4
const TILE := GameConfig.TILE
const STEP := TILE / DIV
const STRIDE := DIV + 1
const REACH := 3.0 # road fitting and authored trail earthworks
const NATURAL_REACH := 5.0
const FIT_FADE := 12.0   # 4.5: плавный переход у концов, развилок и защищённых мест, м
const FIT_LIMIT := 1.2   # обычное уточнение относительно сетки RoadBed, м
const BENCH_LIMIT := Heightfield.TUNNEL_HEIGHT # полка дороги в склоне: до высоты существующей выемки, м
const TRAIL_BENCH_LIMIT := 2.0 # более узкая полка обычной тропы; технические горные тропы не выравниваем
## 14.11: средние формы дорожного коридора (docs/ROAD_RELIEF.md) — одна система для дорог, троп и горных троп.
## По станциям пути через STEP метров считаются восемь величин (CORRIDOR_STRIDE): подъём оси, перекос, выпуклость
## или корыто, продавленное место (глубина и где поперёк), форма каждой обочины (вал > 0, канава < 0); вершина
## метровой сетки складывает из них поперечное сечение. Восьмая величина разрешает формы за обочиной.
## 16.11.2026: числа форм по виду пути (roll, bump, tilt, ..., grade), их выраженность и характер по покрытию RoadSurface
## (15.11, docs/ROAD_CHARACTER_2026_11_15.md), выравнивание спокойных участков (LEVEL_*), ритм участков, включение форм
## и зазоры — в файле параметров дорог RoadTuning (resources/road_tuning.tres, docs/ROADS_CSHARP.md), а не в коде.
## Ритм участков — то же медленное поле, что у кочек и препятствий (RoadBump.patch().x, 75–160 м); значение поля
## огрублено до 2^-20. Выравнивание спокойного участка: подъём оси минус доля отклонения оси (после подгонки профиля
## _fit_route, с 16.11) от среднего по ±level_r м; разбитый участок не выравнивается.
const CORRIDOR_KINDS := ["road", "trail", "mountain"]
## false — прежние характер и ритм (было/стало в стендах road_relief_test, road_corridor_probe)
static var landscape_character := true
const CORRIDOR_STRIDE := 8
const SHARED := 0.5            # (прежний порог дублей сети; с 11.11.2026 дублей нет, остаётся параметром C#)
static var natural_relief := true # false — без форм коридора (сравнение было/стало в стендах)

var patches := {}  # uv: across, surface + 0.25 for singletrack (round gives the material). Physics uses surface separately.
var fit_routes := {} # маршрут -> метровые points, profile, strength, limit; горные тропы остаются прежними
var corridor := PackedFloat64Array() # формы коридора всех путей подряд, по CORRIDOR_STRIDE на станцию
var corridor_routes := {} # маршрут -> Vector2i(первая станция в corridor, число станций)
var build_timings := {}
var trail_shaping := {} # trail id -> cut/fill volumes, extremes, designed and natural grade, banking
var trail_elements_baked := false # A fresh refinement accepts one authored earthwork pass.
var _heights: Heightfield
var _noise: FastNoiseLite
var _height := 0
var _dist_water := PackedFloat32Array() # w.dist_water
var _surf: Array = RoadSurface.LIST
var _origin := Vector2.ZERO # WorldData.world_origin в метрах: шум полотна в мировых координатах
var _only := {} # номера путей, у которых строятся патчи; пусто — у всех
var _reach := NATURAL_REACH
# Отрезки столбцами и индекс «клетка -> отрезки» от FastGrid.RoadIndex; живут только на время сборки
var _cs_starts := PackedInt32Array() # CSR по клеткам мира: _cs_ids[_cs_starts[k] .. _cs_starts[k + 1]) — отрезки клетки k
var _cs_ids := PackedInt32Array()
var _sg_a := PackedVector2Array()
var _sg_delta := PackedVector2Array()
var _sg_len2 := PackedFloat64Array()
var _sg_half := PackedFloat64Array()
var _sg_route := PackedInt32Array()
var _sg_along := PackedFloat64Array()
var _route_identity := PackedInt32Array() # exact complete natural routes only; never aliases merely nearby axes


## only — номера путей w.trails (ключи словаря): патчи и подгонка профиля только вокруг них, прочие пути
## участвуют как соседи (ближайший отрезок, развилки). Тогда у патча есть owner: 1 у вершин, где ближе всего
## путь из only. Trail Lab так добавляет новую трассу к готовому участку; пусто — все пути (игра).
## 16.11.2026: индекс, подгонка, формы коридора и патчи — только на C# (FastGrid.RoadIndex, RoadFitNetwork, RoadPatches),
## в том числе при only. Без C# или при ошибке внутри него — сообщение и пустая сетка (патчей нет, дороги без метровой сетки).
## w.outer не учитывается (в игре сетка строится до подключения OuterLand, в Trail Lab его нет).
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
	# TrailSite rebuilds authored lines over the existing surface. Its patch
	# ownership must use the same reach as TrailBuilder and TrailShaping.
	if not only.is_empty() and only.keys().all(func(route: int) -> bool:
		var t: Dictionary = heights.world.trails[route]
		return t.has("trail_id") and (t.get("formation", Vector3.ZERO) as Vector3).x > 0.0):
		r._reach = REACH
	var fast := Grid.native_grid()
	if fast == null:
		push_error("RoadRefinement: метровая сетка дорог считается только на C#: нужна сборка Godot .NET и dotnet build")
		return from_patches({}, r._height)
	if not r._only_valid():
		return from_patches({}, r._height)
	var built := r._build_native(fast, fit_road)
	if built == null:
		push_error("RoadRefinement: C# не построил метровую сетку (исключение внутри расчёта)")
		return from_patches({}, r._height)
	if only.is_empty(): pin_coarse_edges(heights, built.patches, built.patches.keys())
	built._drop_mountain_fits(heights.world)
	return built


## Каждый путь only есть в мире, дорожного вида (RoadBed.KINDS) и с отрезками: так бывает у трасс Trail Lab
## (TrailDefinition: «trail», «mountain», «road», не меньше двух точек). Иначе ошибка, сетка не строится.
func _only_valid() -> bool:
	var w := _heights.world
	for route: int in _only:
		if route < 0 or route >= w.trails.size():
			push_error("RoadRefinement: пути %d нет в мире (путей %d)" % [route, w.trails.size()])
			return false
		var t: Dictionary = w.trails[route]
		if not RoadBed.KINDS.has(t.kind) or t.pts.size() < 2:
			push_error("RoadRefinement: путь %d не дорожный (вид %s, точек %d), частичная сборка невозможна" % [route, t.kind, t.pts.size()])
			return false
	return true


## Mountain entries carry temporary protection gates, not an engineered profile.
func _drop_mountain_fits(w: WorldData) -> void:
	for route: int in fit_routes.keys():
		if w.trails[route].kind == "mountain": fit_routes.erase(route)


## An edge bordering a coarse cell uses the same straight segment as its coarse mesh and physics.
## At a corner the diagonally adjacent coarse cell also shares that vertex.
static func pin_coarse_edges(h: Heightfield, patches: Dictionary, keys: Array) -> void:
	var w := h.world.W
	var rows := h.world.H
	var hv := h.hv
	for key: int in keys:
		var cx := key % w
		var cz := key / w
		var left := cx == 0 or not patches.has(key - 1)
		var right := cx == w - 2 or not patches.has(key + 1)
		var top := cz == 0 or not patches.has(key - w)
		var bottom := cz == rows - 2 or not patches.has(key + w)
		var nw := left or top or not patches.has(key - w - 1)
		var ne := right or top or not patches.has(key - w + 1)
		var sw := left or bottom or not patches.has(key + w - 1)
		var se := right or bottom or not patches.has(key + w + 1)
		if not (nw or ne or sw or se): continue
		var patch: Dictionary = patches[key]
		var original: PackedFloat32Array = patch.h
		var hs := original.duplicate()
		for i in STRIDE:
			var f := float(i) / DIV
			if left: hs[i * STRIDE] = lerpf(hv[key], hv[key + w], f)
			if right: hs[i * STRIDE + DIV] = lerpf(hv[key + 1], hv[key + w + 1], f)
			if top: hs[i] = lerpf(hv[key], hv[key + 1], f)
			if bottom: hs[DIV * STRIDE + i] = lerpf(hv[key + w], hv[key + w + 1], f)
		if nw: hs[0] = hv[key]
		if ne: hs[DIV] = hv[key + 1]
		if sw: hs[DIV * STRIDE] = hv[key + w]
		if se: hs[STRIDE * STRIDE - 1] = hv[key + w + 1]
		if hs != original:
			var pinned := patch.duplicate()
			pinned.h = hs
			patches[key] = pinned


## Индекс отрезков, подгонка профиля, формы коридора и патчи тремя вызовами C# (FastGrid.RoadIndex, RoadFitNetwork и RoadPatches):
## столбцами, без словарей на отрезок и на вершину. null — C# вернул не словарь (исключение внутри).
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
	var local_routes := PackedByteArray()
	if not _only.is_empty():
		local_routes.resize(w.trails.size())
		for route: int in _only: local_routes[route] = 1
	var index: Variant = fast.RoadIndex(w.W, w.H, TILE, _reach, _heights.hv, starts, xs, ys, ws, surf, smoothing, is_road, ids, local_routes)
	if not index is Dictionary:
		return null
	_cs_starts = index.starts
	_cs_ids = index.candidates
	_sg_a = index.a
	_sg_delta = index.delta
	_sg_len2 = index.len2
	_sg_half = index.half
	_sg_route = index.route
	_sg_along = index.along
	build_timings.index_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	started_us = Time.get_ticks_usec()
	if fit_road and not _fit_network(fast):
		return null
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
	var out: Variant = fast.RoadPatches(PackedInt32Array(index.keys), w.W, w.H, TILE, DIV, _sg_a, _sg_delta, _sg_len2, _sg_half,
		index.road, index.surf, index.next, index.ha, index.hb, _sg_along, _sg_route, _cs_starts, _cs_ids, fit_start, fit_count, fits,
		corridor_start, corridor_count, corridor, surfaces, _heights.hv, _heights.water_level, _dist_water, _noise, _origin, axes,
		RoadBed.STEEP.x, RoadBed.STEEP.y, RoadBed.WATER_GAP, RoadBed.PIN, RoadBed.PIN_FADE, _reach, _authored_routes(), PackedFloat64Array(Section.NATIVE_TREAD),
		local_routes)
	if not out is Dictionary:
		return null
	patches = out.patches
	build_timings.native_points_ms = out.ms_points
	build_timings.native_vertices_ms = out.ms_vertices
	build_timings.native_assemble_ms = out.ms_assemble
	build_timings.nearest_ms = 0.0
	build_timings.vertex_math_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	build_timings.vertices_ms = build_timings.vertex_math_ms
	_heights = null
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


func _authored_routes() -> PackedByteArray:
	var result := PackedByteArray()
	for t: Dictionary in _heights.world.trails:
		result.append(1 if t.has("trail_id") else 0)
	return result


## 4.5, 14.11: весь проход одним вызовом C# (FastGrid.RoadFitNetwork): станции через STEP метров, подгонка профиля пути
## (оценка, расстояние до защищённых мест, профиль), защита и формы коридора всех видов путей (горные тропы — без подгонки
## профиля). Резкий локальный перегиб требует обработки, постоянный чрезмерный уклон — другого маршрута.
## false — C# вернул не словарь (исключение внутри).
func _fit_network(fast: Object) -> bool:
	_index_route_identity()
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
		if kind < 0 or not (_only.is_empty() or _only.has(route)):
			continue
		var scale := 1.0
		if t.has("trail_id"):
			scale = RoadTuning.current().prepared_scale if (t.get("formation", Vector3.ZERO) as Vector3).x <= 0.0 else 0.0
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
	var out: Variant = fast.RoadFitNetwork(starts, xs, ys, ws, surf, kinds, scales, ids, w.W, w.H, TILE, STEP, _heights.hv,
		_heights.hv_raw, _heights.water_level, _dist_water, axes, villages, _sg_a, _sg_delta, _sg_len2, _sg_half, _sg_route, _sg_along,
		_cs_starts, _cs_ids, _route_identity, _noise, _origin, corridor_params(), _authored_routes())
	if not out is Dictionary:
		push_error("RoadRefinement: C# не выполнил подгонку профиля и формы коридора (исключение внутри расчёта)")
		return false
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
	return true


static var _code_version := -1


## Версия дорожного кода на C# (Roads.RoadCode.Version) — часть ключа кэша поверхности; 0 без .NET (дороги тогда не строятся).
static func code_version() -> int:
	if _code_version < 0:
		var fast := Grid.native_grid()
		_code_version = int(fast.RoadCodeVersion()) if fast != null else 0
	return _code_version


## Все числа подгонки и форм коридора одним словарём с именованными ключами — единственное место, где они собираются:
## C# (Roads.CorridorParams, FastGrid.RoadFitNetwork) разбирает его один раз на вызов.
## kinds — по виду пути в порядке CORRIDOR_KINDS (roll, bump, tilt, keep, max, dish, var, hollow, ditch, lip, grade); surface_gain —
## по покрытию RoadSurface; character — по покрытию × (roll, bump, wobble); rhythm — ритм участков по RoadBump.patch (1 — да);
## level_kind — выравнивание спокойных участков по виду, level_surface — по покрытию; fit — подгонка профиля и пределы полки;
## fade, gap — включение форм и зазор между полотнами; stride — чисел на станцию; level_r — радиус выравнивания, rhythm_span —
## размах ритма. Без landscape_character — прежние характер и ритм (множители 1, ритм по шуму, выравнивания нет).
## 16.11.2026: числа форм, характера, выравнивания и зазоров — из файла параметров RoadTuning.
static func corridor_params() -> Dictionary:
	var tuning := RoadTuning.current()
	var kinds: Array = []
	var level_kind := PackedFloat64Array()
	for name: String in CORRIDOR_KINDS:
		var k := tuning.kind(name)
		kinds.append(k.corridor())
		level_kind.append(k.level if landscape_character else 0.0)
	var character := PackedFloat64Array()
	for v: float in tuning.character:
		character.append(v if landscape_character else 1.0)
	var level_surface := PackedFloat64Array()
	for v: float in tuning.level_surface:
		level_surface.append(v if landscape_character else 0.0)
	return {
		"kinds": kinds, "surface_gain": PackedFloat64Array(tuning.surface_gain), "character": character,
		"rhythm": landscape_character, "level_kind": level_kind, "level_surface": level_surface,
		"fit": {"shore": RoadBed.SHORE.y, "pin": RoadBed.PIN, "pin_fade": RoadBed.PIN_FADE, "reach": REACH, "shared": SHARED,
			"fit_fade": FIT_FADE, "fit_limit": FIT_LIMIT, "road_bench": BENCH_LIMIT, "trail_bench": TRAIL_BENCH_LIMIT, "land_gap": tuning.land_gap},
		"fade": tuning.corridor_fade, "gap": tuning.corridor_gap, "stride": CORRIDOR_STRIDE, "level_r": tuning.level_r,
		"rhythm_span": tuning.rhythm_span,
	}


## 11.11.2026: каждая ось сети существует один раз (StageTrails._add_trail: участки и узлы), поэтому «тот же путь» —
## только сам путь. Прежний поиск полных дублей по хешу линий (sha256 каждой записи при каждой сборке) больше не нужен;
## массив остаётся входом FastGrid.RoadFitNetwork.
func _index_route_identity() -> void:
	_route_identity.resize(_heights.world.trails.size())
	for route in _route_identity.size():
		_route_identity[route] = route


static func _bell(t: float) -> float:
	var q := 1.0 - t * t
	return q * q if q > 0.0 else 0.0


## Visible wear lies inside the rideable/cleared corridor. This same alpha places grass,
## understory and obstacles; the shader adds texture, not another displaced boundary.
static func tread_mask(half: float, d: float, slow: float, organic: float, _road: bool, authored := false, grain := 0.0) -> float:
	if authored:
		var original_edge := (half + slow * 0.24 + grain * 0.10) * (1.0 - organic * 0.12)
		var original_shoulder := (0.7 + (slow + 1.0) * 0.3) * (1.0 + organic * 0.5)
		return (1.0 - smoothstep(original_edge * 0.55, original_edge + original_shoulder, d)) * (1.0 - organic * 0.35)
	return Section.tread_alpha(half, d, slow, organic)


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


## 15.11.2026: маска кромки для травяного ковра — как кромка в шейдере (terrain.gdshader, edge_lin): маска вершин падает
## на ~0,9 м при шаге вершин 1 м, и на дороге наискосок к сетке её граница идёт одинаковыми ступеньками. Поперечная
## координата (uv.x) на прямом отрезке интерполируется точно: по ней та же формула tread_alpha; где она расходится с маской
## (развилка, сужение, мост) — маска вершин. Без извива шейдера: дернина у края и так редеет случайно.
func edge_at(x: float, z: float, width: int) -> float:
	var at := sample(x, z, width)
	if at.is_empty():
		return 0.0
	var mask: float = at.weight
	var organic: float = RoadSurface.LIST[at.surface].organic if at.surface > 0 else 0.0
	var linear := clampf(0.5 + (0.84 - organic * 0.04 - absf(at.across)) * 1.25, 0.0, 1.0)
	return lerpf(mask, linear, 1.0 - smoothstep(0.2, 0.4, absf(linear - mask)))


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
	var gradient := Vector2(hs[b] - hs[a], hs[c] - hs[a]) / STEP if tx + tz <= 1.0 else Vector2(hs[a] - hs[c], hs[a] - hs[b]) / STEP
	var bumps: Vector4 = RoadBump.LIST[p.surface[a]] * wa + RoadBump.LIST[p.surface[b]] * wb + RoadBump.LIST[p.surface[c]] * wc
	var bump_weight: float = (wa if p.surface[a] != 0 else 0.0) + (wb if p.surface[b] != 0 else 0.0) + (wc if p.surface[c] != 0 else 0.0)
	if bump_weight > 0.0: bumps.y = maxf(0.1, bumps.y / bump_weight)
	var closest := a if wa >= wb and wa >= wc else (b if wb >= wc else c)
	# 12.3: across — поперечная координата полотна (UV2.x меша): колеи RoadBump у колёс там же, где в шейдере
	return {h = hs[a] * wa + hs[b] * wb + hs[c] * wc,
		weight = colors[a].a * wa + colors[b].a * wb + colors[c].a * wc, surface = p.surface[closest], road = p.road[closest] != 0,
		across = uvs[a].x * wa + uvs[b].x * wb + uvs[c].x * wc, grade = gradient.length(), bump = bumps}

