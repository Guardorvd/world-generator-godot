class_name StageTrails
extends RefCounted
## Этап 7. Естественные тропы и дороги: поиск пути A* по стоимости местности.
## Пишет: w.cost (стоимость прохода), w.path_mask (1 — звериная тропа, 2 — тропа людей, 3 — дорога),
## w.trails (контракт в docs/ROAD_DATA_CONTRACT.md), w.bridges, w.tunnels;
## убирает дома поселений, которые оказались на мосту или в туннеле.
##
## Основная сеть связывает принятые поселения дорогами и местными тропами (остов), по стоимости, в которой вода
## проходима, но дорога (routing.bridge_cost за клетку): так поселения на разных берегах тоже связаны.
## Где дорога или тропа между поселениями пересекает воду, ставится мост,
## где переваливает через крутой хребет — туннель. Тропа переходит узкую речку вброд, без моста;
## сухие впадины дорога проходит по рельефу, без декоративных мостов.
## Хребет путь обходит понизу (_detour), если обход не длиннее DETOUR_PREFER длин туннеля, иначе строится туннель
## (с 16.11.2026; раньше туннели и обходы чередовались по очереди от чётности сида). Высоты здесь в единицах w.h (1 = 260 м).
## Путь, который пересекает воду или хребет там же, где уже построен мост или туннель (концы рядом,
## _same), проходит по нему: к его входу и от выхода — короткими путями по суше.
## Дополнительные тропы сокращают обход по сети или предлагают другой проход по рельефу;
## ответвления ведут к берегам и вершинам, без заданного количества связей (_second_ways).

const Topology := preload("res://scripts/world/road_topology.gd")
const RoadRecords := preload("res://scripts/world/road_records.gd")
const RoadRides := preload("res://scripts/world/road_rides.gd")
const RoadForks := preload("res://scripts/world/road_forks.gd")
## Линия пути по найденным клеткам: срезание лесенки, дуги, заходы, проверка участка и профиля
const RoadLine := preload("res://scripts/world/road_line.gd")

const PROGRESS := 0.55
const LABEL := "Прокладка звериных троп"

const EDGE_COST_BAND := 12  # ширина полосы у неподготовленного края, в клетках
const EDGE_COST_MAX := 6.0
const RISE := 0.1           # хребет выше этого (около 26 м) над входами — туннель
const RISE_LEN := 30        # самый длинный туннель, клеток
const SPAN := 60            # мост или туннель охватывает не больше стольких клеток пути
const GRADE := 0.0018       # наибольший уклон моста и туннеля на клетку (около 12 %)
## Въезд проверяется по всей ширине настила, м. Ревью дорожной сети 29.10, шаг 7: на Север-1234 почти все
## отказы мостов — въезд в 0,25–1 м от конца настила. Площадки въезда (выравнивание земли у концов в
## Heightfield.build_structures) проверены на стенде road_plan_test и отложены: в игре земля у концов другая
## (RoadBed идёт до сооружений), часть площадок там невыполнима, и у 2–3 мостов край въезда оставался
## на 0,3 м от настила. Нужен готовый проект работ, сохранённый в данных моста, а не пересчёт при загрузке.
const BRIDGE_LANDING_GAP := 0.25
const BRIDGE_APPROACH := 24 # search both banks before committing a river-following road to a long span
const TUNNEL_R := 2.3       # клетки ближе этого к оси туннеля — его выемка (без деревьев)
const BRIDGE_R := 0.8       # клетки ближе этого к оси моста — дорога
const HUT_CLEAR := 1.5      # дом ближе этого к оси моста или туннеля убирается, клеток
const FORD_LEN := 2         # тропа переходит вброд реку не шире стольких клеток пути
const FORD_SLOPE := 0.3     # на более крутом перепаде русла глубина между клетками ненадёжна для брода
const DETOUR := 4.5         # обход горы не длиннее стольких прямых расстояний между входами туннеля
const DETOUR_PREFER := 2.5  # обход не длиннее стольких длин туннеля выбирается вместо туннеля
const ALT_LEN := 2.0        # второй путь не длиннее стольких первых
const BRANCH_LEN := 3.0     # тропа к берегу не длиннее стольких прямых расстояний
const SHORTCUT := 1.25      # новая связь сокращает существующий обход хотя бы на пятую часть
const RELIEF_CHOICE := 0.02 # другой проход отличается высотой примерно на 5 м (единицы w.h)
const SHORE_MIN := 15       # береговой ориентир не ближе стольких клеток от поселения
const SHORE_MAX := 45       # и не дальше стольких
const AVOID_R := 3          # коридор вокруг прежнего пути, клеток: второй путь его избегает
const AVOID_SHARE := 0.4    # второй путь идёт по коридору не больше чем такой долей клеток
const REUSE_R := 5.0        # путь идёт по уже построенному мосту или туннелю, если оба его конца не дальше стольких клеток
const KEY_R := 1.5          # и проходит не дальше стольких клеток от того, что пересекает путь (_key_cell)
const CROSS_GAP := 8.0      # 10.4: вода ближе стольких клеток к мосту закрыта для следующих путей — они сходятся к одной переправе
## Три характера езды без отдельных режимов: дорога, извилистый обход, техническая горная тропа.
const Section := preload("res://scripts/world/road_section.gd")
## Стенды могут на время запуска заменить таблицы turn_costs, bend_costs, straighten и line_relax.
static var routing_overrides := {}
## 21.11.2026: дорожная сеть V2 (docs/ROAD_NETWORK_V2_PLAN_2026_11_21.md) — петли и ответвления после остова V1.
## Выключено по умолчанию; включается флагом запуска `-- --roads-v2` (в не-шаблонных сборках) и меняет ключ слоя places.
const ROADS_V2_FLAG := "--roads-v2"
const ROADS_V2_LABEL := "сеть V2"
static var network_v2 := not OS.has_feature("template") and OS.get_cmdline_user_args().has(ROADS_V2_FLAG)
const RoadNetworkV2 := preload("res://scripts/world/road_network_v2.gd")
const HEIGHT_SCALE := 65.0  # 260 м высоты / 4 м на клетку; единицы высоты и шага A* одинаковы
## Основная сеть сначала ищет удобный проход; у дополнительных и горных троп свои пределы.
## В пределах своего класса крутизна дополнительно оплачивается штрафом climb.
const ROAD_GRADE := 0.22 # удобный проход основной сети
const ROAD_LIMIT := 0.28 # короткий запасной подъём; дальше нужен обход
const TRAIL_GRADE := 0.4
const MOUNTAIN_GRADE := 0.55
const BENCH_CROSS := 0.65 # полка не должна превращаться в стену у поворота или берега


## Время частей этапа, мс (ревью дорожной сети 29.10, шаг 5: где тратится время). Заполняется всегда, дёшево;
## run сбрасывает его и кладёт в generation_profile.parts_ms.
static var parts := {}


static func _part(key: String, since_us: int) -> void:
	parts[key] = float(parts.get(key, 0.0)) + (Time.get_ticks_usec() - since_us) / 1000.0


static func run(w: WorldData, step: Callable) -> void:
	parts = {}
	var started_us := Time.get_ticks_usec()
	var widths := RoadTuning.current().section.widths
	_build_cost(w)
	var detail_us := Time.get_ticks_usec()
	w.generation_profile.cost_ms = (detail_us - started_us) / 1000.0
	w.path_mask = PackedByteArray()
	w.path_mask.resize(w.N)
	w.trails = []
	w.road_rides = {version = RoadRides.VERSION, routes = {}}
	w.generation_profile.road_width_decisions = {}
	w.generation_profile.road_line_grade_fallbacks = {}
	_net_reset(w)
	var surface := Heightfield.base_of(w)
	w.generation_profile.route_heightfield_ms = (Time.get_ticks_usec() - detail_us) / 1000.0
	detail_us = Time.get_ticks_usec()
	var heights := _route_heights(w, surface)
	var finder := Pathfinder.new(w.W, w.H, heights)
	w.generation_profile.finder_setup_ms = (Time.get_ticks_usec() - detail_us) / 1000.0
	detail_us = Time.get_ticks_usec()
	_animal_trails(w, finder)
	w.generation_profile.animal_trails_ms = (Time.get_ticks_usec() - detail_us) / 1000.0
	if network_v2:
		detail_us = Time.get_ticks_usec()
		RoadNetworkV2.prepare_character(w, finder, surface)
		_part("road_character_fields", detail_us)
	_route_surface(finder, surface, widths.road, "corridor_road_ms")
	step.call(0.66, "Прокладка троп между поселениями")
	var primary_end := _settlement_trails(w, finder, surface, step)
	_route_surface(finder, surface, widths.mountain, "corridor_mountain_ms")
	step.call(0.74, "Прокладка горных троп")
	detail_us = Time.get_ticks_usec()
	var on_axis := _mountain_trails(w, finder, surface)
	w.generation_profile.mountain_trails_ms = (Time.get_ticks_usec() - detail_us) / 1000.0
	if network_v2:
		RoadNetworkV2.plan_inland_connections(w, finder, surface, on_axis)
	# С 07.11.2026: природные велосипедные маршруты — спуски между точками готовой сети тем же поиском (RideRoutes)
	step.call(0.76, "Природные велосипедные маршруты")
	RideRoutes.run(w, finder, surface, on_axis)
	if network_v2:
		RoadNetworkV2.reshape_axes(w, surface, on_axis, primary_end)
	_fit_sections(w, surface, PackedByteArray(), Callable(), on_axis if network_v2 else PackedByteArray())
	detail_us = Time.get_ticks_usec()
	StageLandmarks.lay_out(w)
	w.generation_profile.homes_laid = StageLandmarks.count_homes(w.settlements)
	w.generation_profile.layout_ms = (Time.get_ticks_usec() - detail_us) / 1000.0
	_clear_huts(w)
	w.generation_profile.homes_kept = StageLandmarks.count_homes(w.settlements)
	# Исходы и раскрытия считаются всегда (дёшево); время вызовов и кэш — только с profile_searches.
	w.generation_profile.merge(finder.search_stats())
	w.generation_profile.stage_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	w.generation_profile.parts_ms = parts.duplicate()
	if network_v2:
		w.generation_profile.character_search = RoadNetworkV2.character_report(w, finder, on_axis)
	finder.release()
	var issue := RoadRecords.validation_error(w.trails, "StageTrails (%s)" % w.seed_text, RoadRecords.Phase.PUBLISHED)
	if issue.is_empty():
		issue = RoadRides.validation_error(w)
	if not issue.is_empty():
		push_error(issue)


## Keep inherited plan marks and protected structure footprints when the final tread replaces the search ribbon.
static func _fit_sections(w: WorldData, surface: Heightfield, inherited := PackedByteArray(), accept := Callable(),
		switchback_axis := PackedByteArray()) -> void:
	Section.fit(w, surface, accept)
	if not switchback_axis.is_empty():
		var started := Time.get_ticks_usec()
		RoadNetworkV2.reshape_climbs(w, surface, switchback_axis)
		_part("road_switchbacks", started)
	var mask := w.path_mask
	for i in mask.size():
		if mask[i] >= 2:
			mask[i] = inherited[i] if not inherited.is_empty() else 0
	for t: Dictionary in w.trails:
		var mark := 1 if t.kind == "animal" else (3 if t.kind == "road" else 2)
		Grid.stamp_path(mask, w.W, w.H, t.pts, mark)
	w.path_mask = mask
	for span: BridgeData in w.bridges:
		_mark_cut(w, span.a, span.b, BRIDGE_R)
	for span: TunnelData in w.tunnels:
		_mark_cut(w, span.a, span.b, TUNNEL_R)


## Wet cells use water level; dry cells use the carved ground.
static func _route_heights(w: WorldData, surface: Heightfield) -> PackedFloat32Array:
	var heights := PackedFloat32Array()
	heights.resize(w.N)
	var fast := Grid.fast_grid()
	if fast != null:
		heights = fast.RouteHeights(w.ocean, w.lake, w.river_cells(), w.filled, surface.hv, surface.water_level, HEIGHT_SCALE, GameConfig.TILE, GameConfig.LAKE_DROP)
	else:
		var river := w.river_cells()
		for i in w.N:
			# По воде ищется мост, поэтому учитывается уровень воды, а не морское дно.
			heights[i] = (0.0 if w.ocean[i] != 0 else ((w.filled[i] * GameConfig.HS - GameConfig.LAKE_DROP) / GameConfig.TILE if w.lake[i] != 0 else surface.hv[i] / GameConfig.TILE))
			if river[i] != 0 and w.ocean[i] == 0 and w.lake[i] == 0:
				heights[i] = maxf(surface.hv[i], surface.water_level[i]) / GameConfig.TILE
	return heights


## Поиск видит тот же прорезанный рельеф, что и полотно. Ширина в клетках, высоты / TILE.
static func _route_surface(finder: Pathfinder, surface: Heightfield, width: float, profile_key := "") -> void:
	var started := Time.get_ticks_usec()
	finder.max_cross_grade = BENCH_CROSS
	var w := surface.world
	finder.set_meta("route_width", width)
	finder.set_world_corridor(surface.hv, surface.water_level, w.ocean, w.lake, w.river_cells(), GameConfig.TILE, width * 0.5)
	if not profile_key.is_empty():
		surface.world.generation_profile[profile_key] = (Time.get_ticks_usec() - started) / 1000.0
		if finder.fast() != null:
			w.generation_profile[profile_key.trim_suffix("_ms") + "_details"] = finder.fast().CorridorStats()


## Река у самого устья в озеро или море (с 2.9): там она глубже брода, путь обходит её выше по течению
static func _at_mouth(w: WorldData, x: int, y: int) -> bool:
	for dy in range(maxi(0, y - 1), mini(w.H, y + 2)):
		for dx in range(maxi(0, x - 1), mini(w.W, x + 2)):
			var c := dy * w.W + dx
			if w.ocean[c] != 0 or w.lake[c] != 0:
				return true
	return false


## Стоимость прохода клетки: биом, крутизна, немного шума, реки дороже (брод), устья и крутые русла непроходимы
static func _build_cost(w: WorldData) -> void:
	var cost_n := w.noise_field("cost")
	var fast := Grid.fast_grid()
	if fast != null:
		var biome_cost := PackedFloat64Array()
		for biome: Dictionary in Biomes.LIST:
			biome_cost.append(float(biome.get("cost", 2.0)))
		w.cost = fast.PathCost(w.W, w.H, w.ocean, w.lake, w.river_cells(), w.slope, w.biome, cost_n, biome_cost, FORD_SLOPE)
	else:
		w.cost = cost_reference(w, cost_n)
	var cost := w.cost
	for y in w.H:
		var row_gap := mini(y, w.H - 1 - y)
		var band := EDGE_COST_BAND if row_gap >= EDGE_COST_BAND else w.W
		for x in mini(band, w.W):
			var i := y * w.W + x
			var gap := mini(row_gap, mini(x, w.W - 1 - x))
			cost[i] += edge_cost(gap)
		if row_gap >= EDGE_COST_BAND:
			for x in range(maxi(band, w.W - band), w.W):
				cost[y * w.W + x] += edge_cost(w.W - 1 - x)
	w.cost = cost


static func edge_cost(gap: float) -> float:
	return EDGE_COST_MAX * (1.0 - smoothstep(0.0, float(EDGE_COST_BAND), gap))


static func _plan_edge_gap(w: WorldData, i: int) -> int:
	var x := i % w.W
	var y := i / w.W
	return mini(mini(x, w.W - 1 - x), mini(y, w.H - 1 - y))


## Исходный цикл: запасной путь и эталон численных правил.
static func cost_reference(w: WorldData, cost_n: PackedFloat64Array) -> PackedFloat32Array:
	var W := w.W
	var H := w.H
	var cost := PackedFloat32Array()
	cost.resize(w.N)
	var river := w.river_cells()
	for y: int in H:
		for x: int in W:
			var i := y * W + x
			if w.ocean[i] != 0 or w.lake[i] != 0 or river[i] != 0 and (_at_mouth(w, x, y) or w.slope[i] > FORD_SLOPE):
				cost[i] = INF
				continue
			var bc: float = Biomes.LIST[w.biome[i]].get("cost", 2.0)
			cost[i] = bc + w.slope[i] * 7.0 + (cost_n[i] * 0.5 + 0.5) * 0.9 + (12.0 if river[i] != 0 else 0.0)
	return cost


## 11.11.2026: сеть путей людей — набор уникальных участков (docs/ROAD_NETWORK.md). Путь поиска делится по своим
## клеткам до сглаживания: клетки, которые уже принадлежат участку сети (generation.road_owner), — повторное
## использование, ничего не публикуется; остальные — новые участки. Их концы ложатся точно на ось участка-хозяина,
## и там же в линию хозяина вставляется общая точка — узел (перекрёсток, примыкание, развилка). Короткое касание
## (не длиннее CROSS_RUN клеток) — пересечение: новый участок проходит его насквозь. Так одна ось существует один раз,
## а скидка стоимости, маска и линия описывают одну и ту же дорогу (раньше — _shared_passage после сглаживания).
const CROSS_RUN := 2
const JITTER_RUN := 3   # свободных клеток между двумя касаниями одного участка — шаг в сторону, а не новый путь
const JOIN_R := 1.2     # конец нового участка ближе этого (клеток) к оси хозяина ложится на неё


static func _net_reset(w: WorldData) -> void:
	var g := w.generation
	g.road_owner = PackedInt32Array()
	g.road_owner.resize(w.N)
	g.road_owner.fill(-1)
	g.road_cells = []
	g.road_side = PackedByteArray()
	g.road_side.resize(w.N)
	g.road_protected = {}


## Мир областей (RegionRoads) и стенды начинают без сброса этапа: данные сети заводятся при первом пути.
static func _net_ready(w: WorldData) -> void:
	if w.generation.road_owner.size() != w.N:
		var cells: Array = w.generation.road_cells
		_net_reset(w)
		w.generation.road_cells = cells
	while w.generation.road_cells.size() < w.trails.size():
		w.generation.road_cells.append(PackedInt32Array())


## Записать найденный путь (road_cost — стоимость для дорог, она дешевеет вместе с w.cost; on_axis — клетки на осях
## мостов и туннелей: там точки линии лежат на прямой оси настила и портала). Возвращает номера новых записей
## w.trails (пусто — путь целиком прошёл по готовой сети). smooth_kind — пределы сглаживания другого вида
## (связи поселений ищутся с пределами дороги, даже если публикуются тропой: StageTrails._upgrade_roles).
## path_mask отмечается по нарисованной линии (Grid.stamp_path), дешевле становятся клетки пути.
## changed_lines — журнал прежних pts для отката. corridor проверяет, что дуга остаётся в готовой области.
## legs получает направленные интервалы, включая повторы по существующей сети.
static func _add_trail(w: WorldData, path: PackedInt32Array, kind: String, road_cost: PackedFloat32Array = PackedFloat32Array(),
		on_axis: PackedByteArray = PackedByteArray(), surface: Heightfield = null, smooth_kind := "", changed_lines: Variant = null,
		corridor := Callable(), legs: Variant = null) -> Array:
	var part_us := Time.get_ticks_usec()
	_net_ready(w)
	path = _explicit(w, path, on_axis)
	var width: float = RoadTuning.current().section.widths[kind]
	var mark := 1 if kind == "animal" else (3 if kind == "road" else 2)
	var added: Array = []
	if kind == "animal":
		var jitter_seed := WGRandom.derive(w.seed_num, "trail.jitter." + kind)
		var rng := WGRandom.new(0)
		var pts: Array = []
		var mask := w.path_mask
		for i: int in path:
			rng.reset(WGRandom.hash_cell(jitter_seed, i % w.W, i / w.W, 0))
			var px := (i % w.W) + 0.5 + (rng.next_float() - 0.5) * 0.5
			var py := (i / w.W) + 0.5 + (rng.next_float() - 0.5) * 0.5
			if _by_water(w, i):
				px = (i % w.W) + 0.5
				py = (i / w.W) + 0.5
			pts.append({x = px, y = py, w = width})
			if mask[i] < mark: mask[i] = mark
		w.path_mask = mask
		var line := Grid.chaikin(pts, 3)
		Grid.stamp_path(w.path_mask, w.W, w.H, line, mark, width * 0.5 - Grid.PATH_IN)
		added.append(w.trails.size())
		w.trails.append({kind = kind, pts = line})
		w.generation.road_cells.append(PackedInt32Array())
	else:
		var owner := w.generation.road_owner
		var pieces := _pieces(path, owner, w.W)
		var reused := PackedInt32Array()
		if legs != null:
			for cell: int in path: reused.append(owner[cell])
		for piece: Dictionary in pieces:
			var cells: PackedInt32Array = piece.cells
			var pts := _cell_points(w, cells, on_axis, width)
			var joins := {}
			for end in 2:
				var at := 0 if end == 0 else cells.size() - 1
				if not on_axis.is_empty() and on_axis[cells[at]] != 0:
					continue
				var join := _join_point(w, owner, cells[at], piece.anchored[end])
				if not join.is_empty():
					pts[at] = {x = join.point.x, y = join.point.y, w = width}
					joins[end] = join
			var line_us := Time.get_ticks_usec()
			var line: Array
			if surface == null:
				line = Grid.chaikin(pts, 3)
			elif network_v2 and not corridor.is_valid():
				# Сеть V2, фаза 3.1: та же линия на C# (LineBuilder, порт RoadLine.build один к одному)
				line = RoadNetworkV2.line(w, pts, on_axis, surface, kind, joins, smooth_kind)
			else:
				line = RoadLine.build(w, pts, on_axis, surface, kind, joins, corridor, smooth_kind)
			_part("road_line", line_us)
			var index := w.trails.size()
			Grid.stamp_path(w.path_mask, w.W, w.H, line, mark, width * 0.5 - Grid.PATH_IN)
			w.trails.append(Topology.section(kind, line, w.world_origin))
			w.generation.road_cells.append(cells)
			for c: int in cells:
				if owner[c] < 0: owner[c] = index
			for join: Dictionary in joins.values():
				Topology.attach(w, join.host, join.point, changed_lines)
			added.append(index)
			if legs != null:
				piece.section = index
				piece.joins = joins
		w.generation.road_owner = owner
		if legs != null:
			_trace_ride(w, path, reused, pieces, legs)
	_trodden(w, path, kind, road_cost)
	if network_v2 and RoadNetworkV2.audit_character:
		RoadNetworkV2.record_dry_publication(w, added)
	var protect_us := Time.get_ticks_usec()
	_protect_structures(w, road_cost)
	_part("protect_structures", protect_us)
	_part("add_trail", part_us)
	return added


static func _trace_ride(w: WorldData, path: PackedInt32Array, reused: PackedInt32Array, pieces: Array, legs: Array) -> void:
	var cursor := 0
	var entry := {}
	for piece: Dictionary in pieces:
		_trace_reuse(w, path, reused, cursor, piece.first, entry, piece.joins.get(0, {}), legs)
		var section: Dictionary = w.trails[piece.section]
		RoadRides.append_interval(legs, section.road_id, 0.0, Topology.length_m(section.pts))
		cursor = piece.last
		entry = piece.joins.get(1, {})
	_trace_reuse(w, path, reused, cursor, path.size() - 1, entry, {}, legs)


## Use the same owner decisions as physical publication. Locate stations only on those axes;
## a nearby parallel section is never a candidate for membership.
static func _trace_reuse(w: WorldData, path: PackedInt32Array, reused: PackedInt32Array, first: int, last: int,
		entry: Dictionary, exit: Dictionary, legs: Array) -> void:
	if first >= last:
		return
	var a: Vector2 = entry.get("point", _cell_centre(path[first], w.W))
	var host: int = entry.get("host", reused[first])
	var offset := _ride_station(w, host, a)
	for k in range(first + 1, last + 1):
		var next_host := reused[k]
		var b := _cell_centre(path[k], w.W)
		if k == last:
			next_host = exit.get("host", next_host)
			b = exit.get("point", b)
		if host != next_host:
			var boundary := a.lerp(b, 0.5)
			if host >= 0:
				RoadRides.append_interval(legs, w.trails[host].road_id, offset, _ride_station(w, host, boundary))
			offset = _ride_station(w, next_host, boundary)
		var end := _ride_station(w, next_host, b)
		if next_host >= 0:
			RoadRides.append_interval(legs, w.trails[next_host].road_id, offset, end)
		a = b
		host = next_host
		offset = end


static func _cell_centre(cell: int, width: int) -> Vector2:
	return Vector2(cell % width + 0.5, cell / width + 0.5)


static func _ride_station(w: WorldData, host: int, p: Vector2) -> float:
	return float(_locate(w.trails[host].pts, p)[2]) * GameConfig.TILE if host >= 0 else 0.0


## Протоптанный путь дешевле: следующие маршруты идут по нему. Клетки рядом с участком сети (не на нём) один раз
## дорожают в routing.side_cost раз: соседняя клетка больше не тянет поиск идти вплотную параллельно.
static func _trodden(w: WorldData, path: PackedInt32Array, kind: String, road_cost: PackedFloat32Array) -> void:
	var routing := RoadTuning.current().routing
	var cost := w.cost
	var cheaper := routing.animal_reuse if kind == "animal" else routing.human_reuse
	var both := road_cost.size() > 0
	for i: int in path:
		cost[i] = maxf(0.3, cost[i] * cheaper)
		if both:
			road_cost[i] = maxf(0.3, road_cost[i] * cheaper)
	if kind != "animal":
		var owner := w.generation.road_owner
		var side := w.generation.road_side
		for i: int in path:
			var cx := i % w.W
			var cy := i / w.W
			for k: int in 8:
				var nx: int = cx + Grid.DX[k]
				var ny: int = cy + Grid.DY[k]
				if nx < 0 or ny < 0 or nx >= w.W or ny >= w.H:
					continue
				var n := ny * w.W + nx
				if owner[n] >= 0 or side[n] != 0:
					continue
				side[n] = 1
				if cost[n] != INF:
					cost[n] *= routing.side_cost
				if both and road_cost[n] != INF:
					road_cost[n] *= routing.side_cost
		w.generation.road_side = side
	w.cost = cost


## Части пути, которые не лежат на готовой сети: {cells — клетки с опорными клетками сети по краям, anchored — [начало, конец]
## опираются на сеть}. Короткое касание сети внутри пути (не длиннее CROSS_RUN клеток) — пересечение, часть его проходит.
static func _pieces(path: PackedInt32Array, owner: PackedInt32Array, width: int) -> Array:
	var n := path.size()
	var free := PackedByteArray()
	free.resize(n)
	for k in n:
		free[k] = 1 if owner[path[k]] < 0 else 0
	var k := 0
	while k < n:
		if free[k] != 0:
			k += 1
			continue
		var e := k
		while e + 1 < n and free[e + 1] == 0:
			e += 1
		if k > 0 and e < n - 1 and e - k + 1 <= CROSS_RUN:
			for j in range(k, e + 1):
				free[j] = 2
		k = e + 1
	var out: Array = []
	k = 0
	while k < n:
		if free[k] == 0:
			k += 1
			continue
		var e := k
		while e + 1 < n and free[e + 1] != 0:
			e += 1
		var a := k - 1 if k > 0 else k
		var b := e + 1 if e < n - 1 else e
		# Шаг в сторону от участка и обратно на тот же участок (поиск обошёл клетку у сооружения или на крутом) —
		# не новый путь: без этого рядом с осью оставались огрызки в несколько метров (двойная ось на стенде).
		# Так же — обход вплотную вдоль того же участка (каждая клетка рядом с его клеткой): это его полотно, а не второе.
		var jitter := k > 0 and e < n - 1 and owner[path[a]] == owner[path[b]] \
			and (e - k + 1 <= JITTER_RUN or _hugs(path, k, e, owner, owner[path[a]], width))
		if b > a and not jitter:
			out.append({cells = path.slice(a, b + 1), first = a, last = b, anchored = [k > 0, e < n - 1]})
		elif jitter:
			for j in range(k, e + 1):
				owner[path[j]] = owner[path[a]]
		k = e + 1
	return out


## Каждая клетка пути k..e стоит вплотную (8 соседей) к клетке участка host
static func _hugs(path: PackedInt32Array, k: int, e: int, owner: PackedInt32Array, host: int, width: int) -> bool:
	for j in range(k, e + 1):
		var c := path[j]
		var near := false
		for d in 8:
			var x: int = c % width + Grid.DX[d]
			var y: int = c / width + Grid.DY[d]
			var n := y * width + x
			if x >= 0 and y >= 0 and x < width and n < owner.size() and owner[n] == host:
				near = true
				break
		if not near: return false
	return true


## Точки линии по клеткам: центры клеток; на осях мостов и туннелей — на прямой оси настила (центры клеток
## диагональной оси идут лесенкой, лента должна лежать на прямом настиле).
static func _cell_points(w: WorldData, cells: PackedInt32Array, on_axis: PackedByteArray, width: float) -> Array:
	var W := w.W
	var spans: Array = w.bridges + w.tunnels
	var pts: Array = []
	for i: int in cells:
		var px := (i % W) + 0.5
		var py := (i / W) + 0.5
		if not on_axis.is_empty() and on_axis[i] != 0:
			var best_dist := INF
			for span: EntityRecord in spans:
				var ax: float = span.a % W + 0.5
				var ay: float = span.a / W + 0.5
				var dx: float = span.b % W - span.a % W
				var dy: float = span.b / W - span.a / W
				var t := clampf(((i % W + 0.5 - ax) * dx + (i / W + 0.5 - ay) * dy) / maxf(dx * dx + dy * dy, 1.0), 0.0, 1.0)
				var d := Grid.hypot(i % W + 0.5 - ax - dx * t, i / W + 0.5 - ay - dy * t)
				if d < best_dist:
					best_dist = d
					px = ax + dx * t
					py = ay + dy * t
		pts.append({x = px, y = py, w = width})
	return pts


## Узел на конце нового участка: ближайшая точка оси участков сети в клетке cell и вокруг неё ({host, point} или пусто).
## Опорная клетка (anchored) лежит на сети; свободный конец (поселение, начало горной тропы у маски) — только
## если сеть вплотную.
static func _join_point(w: WorldData, owner: PackedInt32Array, cell: int, anchored: bool) -> Dictionary:
	var cx := cell % w.W
	var cy := cell / w.W
	var hosts := {}
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var x := cx + dx
			var y := cy + dy
			if x >= 0 and y >= 0 and x < w.W and y < w.H and owner[y * w.W + x] >= 0:
				hosts[owner[y * w.W + x]] = true
	if hosts.is_empty():
		return {}
	var c := Vector2(cx + 0.5, cy + 0.5)
	# Сеть V2 (21.11, шаг 5): примыкание ближе 1,5 клетки к развилке — в саму развилку, общий узел
	if not v2_junctions.is_empty():
		var shared := _v2_junction(w, c, hosts)
		if not shared.is_empty(): return shared
	var best := {}
	var best_d := JOIN_R if anchored or owner[cell] >= 0 else 1.0
	for host: int in hosts:
		var tangent: Array[Vector2] = [Vector2.ZERO]
		var q := _nearest_on(w.trails[host].pts, c, 2.0, tangent)
		var d := c.distance_to(q)
		if d <= best_d:
			best_d = d
			best = {host = host, point = q, tangent = tangent[0]}
	return best


## Развилки сети для публикации путей V2 (RoadNetworkV2 заполняет на время публикации): ячейка (Vector2i) → точки
## концов участков, лежащих на оси другого участка. Пусто — правило V1 без изменений.
static var v2_junctions := {}


## Развилка ближе RoadNetworkV2.JOIN_SAME к центру клетки c на оси одного из hosts: {host, point, tangent} или пусто.
static func _v2_junction(w: WorldData, c: Vector2, hosts: Dictionary) -> Dictionary:
	var best := {}
	var best_d: float = RoadNetworkV2.JOIN_SAME
	var keys := hosts.keys()
	keys.sort()
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for q: Vector2 in v2_junctions.get(Vector2i(floori(c.x) + dx, floori(c.y) + dy), []):
				var d := c.distance_to(q)
				if d > best_d: continue
				for host: int in keys:
					var tangent: Array[Vector2] = [Vector2.ZERO]
					if _nearest_on(w.trails[host].pts, q, 2.0, tangent).distance_to(q) < 0.05:
						best_d = d
						best = {host = host, point = q, tangent = tangent[0]}
						break
	return best


## reach — отрезки дальше этого (клеток) по осям не проверяются: у длинной дороги тысячи точек
static func _nearest_on(pts: Array, p: Vector2, reach := INF, tangent: Array[Vector2] = []) -> Vector2:
	var best := Vector2(pts[0].x, pts[0].y)
	var best_d := INF
	for j in range(1, pts.size()):
		var ax: float = pts[j - 1].x
		var bx: float = pts[j].x
		if minf(ax, bx) > p.x + reach or maxf(ax, bx) < p.x - reach: continue
		var ay: float = pts[j - 1].y
		var by: float = pts[j].y
		if minf(ay, by) > p.y + reach or maxf(ay, by) < p.y - reach: continue
		var a := Vector2(ax, ay)
		var b := Vector2(bx, by)
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := p.distance_squared_to(q)
		if d < best_d:
			best_d = d
			best = q
			if not tangent.is_empty():
				tangent[0] = (b - a).normalized()
	return best


## Следующие пути входят на сооружения с концов: боковые клетки у стен непроходимы,
## ось остаётся дешёвой. Под высокими мостами исходная стоимость прохода сохраняется.
static func _protect_structures(w: WorldData, road_cost: PackedFloat32Array) -> void:
	var cost := w.cost
	var both := not road_cost.is_empty()
	# 11.11.2026: запрет у сооружения не снимается следующими путями (INF и 0,3 протаптывание не меняет), поэтому каждое
	# сооружение закрывается один раз для каждой стоимости, а не заново после каждого пути (было ~0,5 с на мир).
	var done: Dictionary = w.generation.road_protected
	for span: EntityRecord in w.tunnels + w.bridges:
		var bits: int = done.get(span, 0)
		var need := 1 | (2 if both else 0)
		if bits & need == need:
			continue
		done[span] = bits | need
		var tunnel := span is TunnelData
		var radius := TUNNEL_R if tunnel else 1.4
		var ax: float = span.a % w.W + 0.5
		var ay: float = span.a / w.W + 0.5
		var bx: float = span.b % w.W + 0.5
		var by: float = span.b / w.W + 0.5
		var dx := bx - ax
		var dy := by - ay
		var length_sq := dx * dx + dy * dy
		for y in range(maxi(0, floori(minf(ay, by) - radius)), mini(w.H, ceili(maxf(ay, by) + radius))):
			for x in range(maxi(0, floori(minf(ax, bx) - radius)), mini(w.W, ceili(maxf(ax, bx) + radius))):
				var along := (x + 0.5 - ax) * dx + (y + 0.5 - ay) * dy
				if along <= 0.0 or along >= length_sq or Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) > radius:
					continue
				var i := y * w.W + x
				# Высоты нормированы: запас 0.015 (около 4 м) учитывает арку настила.
				# Земля значительно ниже или выше моста остаётся доступной отдельно от него.
				var deck: float = w.h[span.a] + (w.h[span.b] - w.h[span.a]) * along / length_sq
				if not tunnel and absf(w.h[i] - deck) > 0.015:
					continue
				cost[i] = INF
				if both:
					road_cost[i] = INF
		# С 10.4 у моста своя переправа: вода рядом для следующих дорог закрыта, и они подходят к этому
		# мосту, а не строят свой в паре клеток (раньше у дороги и тропы вдоль берега было по мосту).
		# Тропы ищут путь по w.cost, поэтому закрыто в обеих стоимостях
		if not tunnel:
			for y in range(maxi(0, floori(minf(ay, by) - CROSS_GAP)), mini(w.H, ceili(maxf(ay, by) + CROSS_GAP))):
				for x in range(maxi(0, floori(minf(ax, bx) - CROSS_GAP)), mini(w.W, ceili(maxf(ax, bx) + CROSS_GAP))):
					var i := y * w.W + x
					if _wet(w, i) and Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) <= CROSS_GAP:
						cost[i] = INF
						if both:
							road_cost[i] = INF
		for i: int in Grid.line_cells(span.a % w.W, span.a / w.W, span.b % w.W, span.b / w.W, w.W):
			cost[i] = 0.3
			if both:
				road_cost[i] = 0.3
	w.cost = cost


## Путь p, в котором каждый диагональный шаг между двумя сухими клетками, которые разделяет река (обе соседние
## по сторонам клетки мокрые), идёт через одну из этих клеток: так переход реки виден в клетках пути (мост, брод),
## а не проскакивает в угол. Готовые оси сооружений не меняются: вставка боковой клетки увела бы путь с настила.
static func _explicit(w: WorldData, p: PackedInt32Array, on_axis: PackedByteArray = PackedByteArray()) -> PackedInt32Array:
	var W := w.W
	var out := PackedInt32Array()
	for k: int in p.size():
		var b := p[k]
		if k > 0:
			var a := p[k - 1]
			var dx := b % W - a % W
			var dy := b / W - a / W
			if dx != 0 and dy != 0 and not _wet(w, a) and not _wet(w, b) \
					and not (not on_axis.is_empty() and on_axis[a] != 0 and on_axis[b] != 0):
				var c1 := a + dx
				var c2 := a + dy * W
				if _wet(w, c1) and _wet(w, c2):
					out.append(c1 if w.cost[c1] <= w.cost[c2] else c2)
		out.append(b)
	return out


## Есть ли вода (море, озеро, река) в клетке i или рядом с ней (w.dist_water считается по тем же клеткам, что _wet)
static func _by_water(w: WorldData, i: int) -> bool:
	return w.dist_water[i] < 1.5


## Звериные тропы: от лесов и лугов к ближайшему водопою
static func _animal_trails(w: WorldData, finder: Pathfinder) -> void:
	var W := w.W
	var H := w.H
	var rng := WGRandom.at(w.seed_num, "trail.animal.sources")
	var dist_water := w.dist_water
	var count := clampi(roundi(30.0 * w.scale), 8, 70)
	var k := 0
	var tries := 0
	while k < count and tries < count * 40:
		tries += 1
		var sx := 4 + floori(rng.next_float() * (W - 8))
		var sy := 4 + floori(rng.next_float() * (H - 8))
		var s := sy * W + sx
		if not Biomes.LIST[w.biome[s]].get("animals", false) or dist_water[s] < 8.0 or dist_water[s] > 35.0:
			continue
		var cost := w.cost
		var best := -1
		var R := 40
		var fast: Object = finder.fast()
		if fast != null:
			best = fast.FindNearestWater(cost, dist_water, W, H, sx, sy, R)
		else:
			best = _nearest_water(cost, dist_water, W, H, sx, sy, R)
		if best < 0:
			continue
		var p := finder.find_path(w.cost, s, best, RoadTuning.current().routing.climb_costs.trail)
		if p.size() > 6:
			_add_trail(w, p, "animal")
			k += 1


## R ограничивает квадрат поиска по каждой оси. Ближайшую клетку выбираем по евклидову расстоянию.
static func _nearest_water(cost: PackedFloat32Array, dist_water: PackedFloat32Array, W: int, H: int, sx: int, sy: int, R: int) -> int:
	var best := -1
	var bd := INF
	for y in range(maxi(0, sy - R), mini(H, sy + R + 1)):
		for x in range(maxi(0, sx - R), mini(W, sx + R + 1)):
			var i := y * W + x
			if cost[i] == INF or dist_water[i] > 1.5:
				continue
			var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
			if d < bd:
				bd = d
				best = i
	return best


## Сеть растёт только через уже построенные безопасные дороги. Недоступный кандидат
## не требует связи любой ценой: не больше трёх соседей и 2*N раскрытий A* суммарно.
## Так последний остров или закрытый склон не запускает квадратичный перебор всех пар.
const SETTLEMENT_NEIGHBORS := 3
const BRIDGE_RETRIES := 2

static func _settlement_trails(w: WorldData, finder: Pathfinder, surface: Heightfield, step: Callable = Callable()) -> int:
	var bridge_cost := RoadTuning.current().routing.bridge_cost
	var started := Time.get_ticks_msec()
	var st := w.settlements
	var n := st.size()
	w.bridges = []
	w.tunnels = []
	var road_cost := w.cost.duplicate()
	var state := {on_axis = PackedByteArray(), surface = surface}
	state.on_axis.resize(w.N)
	var forks := RoadForks.new(w, state.on_axis)
	finder.links.resize(w.N)
	var setup_us := Time.get_ticks_usec()
	var reach := _bridge_reach(w)
	var cost := w.cost
	var ocean := w.ocean
	var lake := w.lake
	var river := w.river_cells()
	for i in w.N:
		# Сначала дешёвое условие: результат тот же (_wet — без вызова на клетку).
		if cost[i] == INF and (ocean[i] != 0 or lake[i] != 0 or river[i] != 0):
			road_cost[i] = bridge_cost + edge_cost(_plan_edge_gap(w, i)) if reach[i] <= BRIDGE_REACH else INF
	_part("roads_setup", setup_us)
	var budgets := PackedInt32Array()
	budgets.resize(n)
	budgets.fill(w.N * 2)
	var granted := budgets.duplicate() # выданный запас, с пополнением: раскрыто = выдано − осталось
	var tried := {}
	var priorities := {} # a * n + b -> _direction_cost
	var paths: Array = []
	var failures := {} # причина -> число отвергнутых связей (_count_failure)
	var link_log: Array = []
	var connected := 0
	# Ревью дорожной сети 29.10, шаг 3: каркас сети — дерево по оценке направлений (Краскал), а не рост
	# одной сети от первого места. Пары идут от дешёвых к дорогим; пара внутри уже связанной группы
	# пропускается. Так сначала строятся местные связи, а переправа между группами пробуется не больше
	# SETTLEMENT_NEIGHBORS раз на пару групп. Раньше (с 9.8) первая сеть по очереди пробовала всех за большой
	# рекой (на Север-1234 16 дальних попыток по 0,5–1 млн раскрытий), и группы за ней уже не соединялись.
	# Запас A* — у места-цели, как раньше (2N); каждая связь пробуется один раз.
	var groups: Array = range(n)
	var candidates: Array = []
	for a in n:
		for b in n:
			if a == b:
				continue
			# Рельеф и вода на этом этапе не меняются: оценка ориентированной пары (a → b) одна
			# на весь перебор. Не симметрична — пробы округляются от своего конца; берётся лучшее направление.
			var priority := _direction_cost(w, st[a], st[b])
			priorities[a * n + b] = priority
	for a in n:
		for b in range(a + 1, n):
			var forward: float = priorities[a * n + b]
			var backward: float = priorities[b * n + a]
			if forward <= backward: candidates.append([a, b, forward])
			else: candidates.append([b, a, backward])
	candidates.sort_custom(func(p: Array, q: Array) -> bool:
		return p[2] < q[2] or p[2] == q[2] and (mini(p[0], p[1]) < mini(q[0], q[1]) or mini(p[0], p[1]) == mini(q[0], q[1]) and maxi(p[0], p[1]) < maxi(q[0], q[1])))
	var pair_tries := {} # группа × группа -> неудачных попыток
	var attempts := 0
	if n > 0:
		connected = 1
	for candidate: Array in candidates:
		if connected >= n or attempts >= n * SETTLEMENT_NEIGHBORS:
			break
		var a: int = candidate[0]
		var b: int = candidate[1]
		var ra := _group(groups, a)
		var rb := _group(groups, b)
		if ra == rb:
			continue
		if budgets[b] == 0:
			if budgets[a] == 0: continue
			var swap := a
			a = b
			b = swap
		var pair_key := mini(ra, rb) * n + maxi(ra, rb)
		if int(pair_tries.get(pair_key, 0)) >= SETTLEMENT_NEIGHBORS:
			continue
		attempts += 1
		tried[_key(a, b)] = true
		var distance := Grid.hypot(st[a].x - st[b].x, st[a].y - st[b].y)
		if step.is_valid():
			step.call(0.66 + 0.03 * (connected - 1) / maxi(1, n - 1), "Дороги между поселениями: %d/%d · проверка места %d" % [connected - 1, maxi(0, n - 1), attempts])
		finder.search_budget = budgets[b]
		var attempt_us := Time.get_ticks_usec()
		var search_ms: float = finder.search_stats().get("call_ms", 0.0)
		var q := _connect_settlement(w, finder, road_cost, st[a].i, st[b].i, state, forks)
		# Каждая попытка: пара, прямое расстояние, списанный запас, исход, время попытки и поиска в ней, мс
		# (поиск — только с Pathfinder.profile_searches; стенд road_plan_test).
		link_log.append([a, b, roundi(distance), budgets[b] - finder.search_budget, "ok" if not q.is_empty() else state.get("failure", ""),
			(Time.get_ticks_usec() - attempt_us) / 1000.0, float(finder.search_stats().get("call_ms", 0.0)) - search_ms])
		budgets[b] = finder.search_budget
		finder.search_budget = -1
		if q.is_empty():
			if state.get("failure", "") == "unreachable":
				attempts -= 1
			else:
				pair_tries[pair_key] = int(pair_tries.get(pair_key, 0)) + 1
			_count_failure(failures, state)
			continue
		# Магистраль между сильными центрами — дорога, местный подъезд — тропа; сквозной путь между сильными центрами
		# через малое поселение становится дорогой после остова (_upgrade_roles). Связь ищется с пределами дороги —
		# и сглаживается так же, чтобы её можно было повысить без новой линии.
		var kind := "road" if main_road(st[a], st[b]) else "trail"
		_add_trail(w, q, kind, road_cost, state.on_axis, surface, "road")
		paths.append([a, b, q, true, distance])
		groups[maxi(ra, rb)] = mini(ra, rb)
		connected += 1
	w.generation_profile.settlement_candidates = n
	w.generation_profile.settlement_attempts = tried.size()
	w.generation_profile.settlement_rejected = 0
	w.generation_profile.road_failures = failures
	w.generation_profile.road_links = link_log
	w.generation_profile.road_windows = state.get("windows", {}).duplicate() # уровень окна найденных путей
	w.generation_profile.no_bridge_cells = state.get("no_bridge", {}).size()
	w.generation_profile.site_failures = state.get("site_failures", []).duplicate()	# Списано с запасов поселений (в том числе готовыми результатами кэша и фонового поиска);
	# фактическая работа основного и фонового поиска — в search_stats.
	var expanded := 0
	for k in n:
		expanded += granted[k] - budgets[k]
	w.generation_profile.settlement_expanded = expanded
	w.generation_profile.main_roads_ms = Time.get_ticks_msec() - started
	# Нарастающий итог после основных связей: с ним сравнивается политика запасного поиска (prefetch).
	w.generation_profile.main_roads_search = finder.search_stats()
	w.generation_profile.upgraded_m = _upgrade_roles(w, paths)
	var primary_end := w.trails.size()
	finder.use_corridor = true
	_route_surface(finder, surface, RoadTuning.current().section.widths.trail, "corridor_trail_ms")
	# Необязательные петли тоже не могут бесконечно перебирать непригодный берег.
	finder.search_budget = w.N * maxi(1, n)
	var detail_us := Time.get_ticks_usec()
	_second_ways(w, finder, paths, road_cost, state, step)
	w.generation_profile.secondary_roads_ms = (Time.get_ticks_usec() - detail_us) / 1000.0
	finder.search_budget = -1
	# DSU describes only the primary skeleton. Secondary ways may join its
	# components: decide publication on the final confirmed connections,
	# after all those opportunities, without deleting any safe road or structure.
	_retain_connected_settlements(w, paths)
	w.generation_profile.settlement_rejected = n - w.settlements.size()
	w.generation_profile.journeys = _journeys(w, paths)
	for s: SettlementData in w.settlements:
		s.connections = []
	for e: Array in paths:
		var a: SettlementData = w.settlements[e[0]]
		var b: SettlementData = w.settlements[e[1]]
		if not a.connections.has(b.i): a.connections.append(b.i)
		if not b.connections.has(a.i): b.connections.append(a.i)
	w.generation_profile.checkpoints = state.get("checkpoints", 0)
	w.generation_profile.checkpoint_mb = state.get("checkpoint_bytes", 0) / 1048576.0
	w.generation_profile.restores = state.get("restores", 0)
	return primary_end


## Publish the largest confirmed component, not the component of candidate zero.
## Candidate order ranks sites, not connectivity; PlayerState.home chooses the
## actual start after publication. Ties prefer the earliest ranked component.
## A 2D mask contact alone cannot prove access at an overpass.
static func _retain_connected_settlements(w: WorldData, paths: Array) -> void:
	if w.settlements.is_empty(): return
	var groups: Array = range(w.settlements.size())
	for edge: Array in paths:
		var a := _group(groups, edge[0])
		var b := _group(groups, edge[1])
		groups[maxi(a, b)] = mini(a, b)
	var sizes := {}
	var root := 0
	var largest := 0
	for index in w.settlements.size():
		var r := _group(groups, index)
		sizes[r] = int(sizes.get(r, 0)) + 1
		if sizes[r] > largest or sizes[r] == largest and r < root:
			root = r
			largest = sizes[r]
	var keep: Array[SettlementData] = []
	var remap := {}
	for index in w.settlements.size():
		if _group(groups, index) == root:
			remap[index] = keep.size()
			keep.append(w.settlements[index])
	var kept_paths: Array = []
	for edge: Array in paths:
		if remap.has(edge[0]) and remap.has(edge[1]):
			edge[0] = remap[edge[0]]
			edge[1] = remap[edge[1]]
			kept_paths.append(edge)
	paths.assign(kept_paths)
	w.settlements = keep


## Ревью дорожной сети 29.10, шаг 1 (поиск не одобряет то, что построитель не сделает): мост охватывает не больше
## SPAN шагов пути, поэтому любая клетка под ним не дальше SPAN / 2 шагов (по Чебышёву) от сухого берега.
## Восьмисвязное расстояние Grid.distance_field не больше √2 Чебышёва: вода дальше BRIDGE_REACH от суши
## не перекрывается никаким мостом — для дорог она непроходима, а не дорогая. Ни один возможный мост не теряется.
## Раньше поиск вёл дороги через залив шириной 60–110 клеток, и мост там отвергался после каждого A*.
const BRIDGE_REACH := SPAN * 0.5 * Grid.SQRT2


## Расстояние от каждой клетки до ближайшей сухой (не _wet), клетки.
static func _bridge_reach(w: WorldData) -> PackedFloat32Array:
	var dry := PackedByteArray()
	dry.resize(w.N)
	var river := w.river_cells()
	var ocean := w.ocean
	var lake := w.lake
	for i in w.N:
		dry[i] = 0 if ocean[i] != 0 or lake[i] != 0 or river[i] != 0 else 1 # то же, что _wet
	return Grid.distance_field(w.W, w.H, dry)


## Корень группы связанных мест (меньший номер — корень, не зависит от порядка связей).
static func _group(groups: Array, k: int) -> int:
	while groups[k] != k:
		k = groups[k]
	return k


## Магистраль между сильными центрами — дорога, иначе местная тропа (тот же признак читает индекс мест).
static func main_road(a: SettlementData, b: SettlementData) -> bool:
	return minf(EntityCodec.value(a, "importance", 1.0), EntityCodec.value(b, "importance", 1.0)) >= 0.6


## Класс по роли в сети (11.11.2026): связь остова, которая лежит на пути между двумя сильными центрами, — дорога
## по всей длине, в том числе через малое поселение и по участкам, которые она делит с местной тропой (такой участок
## тропы делится узлами, и его средняя часть становится дорогой). Ширина постоянна вдоль участка и меняется в узле.
## Возвращает длину повышенных участков, м.
const FLOW_ROAD := 0.35 # доля наибольшего потока по связи остова, с которой связь — дорога (_upgrade_roles)


static func _upgrade_roles(w: WorldData, paths: Array) -> float:
	var st := w.settlements
	var links: Array = []
	for s in st.size():
		links.append([])
	for k in paths.size():
		var e: Array = paths[k]
		if e[3]:
			links[e[0]].append([e[1], k])
			links[e[1]].append([e[0], k])
	var strong := {}
	for s in st.size():
		if EntityCodec.value(st[s], "importance", 1.0) >= 0.6: strong[s] = true
	# 16.11.2026: кроме путей между сильными центрами, дорогой становится связь остова, по которой много ездят: поток
	# по связи — сумма по всем парам мест (дома одного × дома другого / длина пути по остову), путь которых идёт через
	# неё. Связь с потоком не меньше FLOW_ROAD от наибольшего — дорога. Так магистраль сама проходит через деревни
	# на пути между крупными местами, а тупиковая тропа к маленькой деревне остаётся тропой.
	var on_road := {}
	var flow := {}
	for s in st.size():
		var via := {s: -1}
		var far := {s: 0.0}
		var queue: Array = [s]
		var at := 0
		while at < queue.size():
			var c: int = queue[at]
			at += 1
			for l: Array in links[c]:
				if not via.has(l[0]):
					via[l[0]] = l[1]
					far[l[0]] = far[c] + float(paths[l[1]][4])
					queue.append(l[0])
		for t: int in via:
			if t <= s: continue
			var pull := float(EntityCodec.value(st[s], "homes", 6)) * float(EntityCodec.value(st[t], "homes", 6)) / maxf(1.0, far[t])
			var both := strong.has(s) and strong.has(t)
			var c := t
			while via[c] >= 0:
				var k: int = via[c]
				flow[k] = float(flow.get(k, 0.0)) + pull
				if both: on_road[k] = true
				c = paths[k][0] if paths[k][1] == c else paths[k][1]
	var most := 0.0
	for k: int in flow: most = maxf(most, flow[k])
	for k: int in flow:
		if flow[k] >= FLOW_ROAD * most: on_road[k] = true
	var before := _kind_length(w, "road")
	var keys := on_road.keys()
	keys.sort()
	for k: int in keys:
		_upgrade_path(w, paths[k][2])
	return (_kind_length(w, "road") - before) * GameConfig.TILE


static func _kind_length(w: WorldData, kind: String) -> float:
	var total := 0.0
	for t: Dictionary in w.trails:
		if t.kind == kind: total += _kind_length_of(t)
	return total


## Длина линии записи w.trails, клеток
static func _kind_length_of(t: Dictionary) -> float:
	var total := 0.0
	for j in range(1, t.pts.size()):
		total += Grid.hypot(t.pts[j].x - t.pts[j - 1].x, t.pts[j].y - t.pts[j - 1].y)
	return total


## Участки тропы, по которым идёт путь path, становятся дорогой (короткое касание — пересечение — нет).
static func _upgrade_path(w: WorldData, path: PackedInt32Array) -> void:
	var n := path.size()
	var k := 0
	while k < n:
		var owner := w.generation.road_owner
		var o := owner[path[k]]
		if o < 0 or w.trails[o].kind != "trail":
			k += 1
			continue
		var e := k
		while e + 1 < n and owner[path[e + 1]] == o:
			e += 1
		if e - k + 1 > CROSS_RUN + 1:
			_promote(w, o, path[k], path[e])
		k = e + 1


## Часть участка e между клетками c0 и c1 становится дорогой: участок делится в точках оси у этих клеток (узлы),
## концы короче трёх клеток остаются с дорогой. Вершины линии не двигаются.
static func _promote(w: WorldData, e: int, c0: int, c1: int) -> void:
	var cells: PackedInt32Array = w.generation.road_cells[e]
	var k0 := cells.find(c0)
	var k1 := cells.find(c1)
	if k0 < 0 or k1 < 0:
		return
	if k0 > k1:
		var swap := k0
		k0 = k1
		k1 = swap
	if k0 <= 2: k0 = 0
	if k1 >= cells.size() - 3: k1 = cells.size() - 1
	var pts: Array = w.trails[e].pts
	var cuts: Array = []
	for k: int in [k0, k1]:
		if k == 0:
			cuts.append([1, Vector2(pts[0].x, pts[0].y), 0.0])
		elif k == cells.size() - 1:
			cuts.append([pts.size() - 1, Vector2(pts[-1].x, pts[-1].y), INF])
		else:
			cuts.append(_locate(pts, Vector2(cells[k] % w.W + 0.5, cells[k] / w.W + 0.5)))
	if cuts[0][2] > cuts[1][2]:
		return # клетки и ось разошлись: не режем наугад
	var widths := RoadTuning.current().section.widths
	var road_pts: Array = [_point(cuts[0][1], widths.road)]
	for j in range(cuts[0][0], cuts[1][0]):
		road_pts.append(_point(Vector2(pts[j].x, pts[j].y), widths.road))
	road_pts.append(_point(cuts[1][1], widths.road))
	var parts: Array = []
	if k0 > 0:
		var head: Array = pts.slice(0, cuts[0][0])
		head.append(_point(cuts[0][1], widths.trail))
		parts.append([_dedupe(head), cells.slice(0, k0 + 1)])
	if k1 < cells.size() - 1:
		var tail: Array = [_point(cuts[1][1], widths.trail)]
		tail.append_array(pts.slice(cuts[1][0]))
		parts.append([_dedupe(tail), cells.slice(k1)])
	var record: Dictionary = w.trails[e]
	record.kind = "road"
	record.pts = _dedupe(road_pts)
	w.generation.road_cells[e] = cells.slice(k0, k1 + 1)
	var owner := w.generation.road_owner
	var on_road := {}   # клетки дороги: множество вместо PackedInt32Array.has на каждую клетку (было квадратично)
	for c: int in w.generation.road_cells[e]:
		on_road[c] = true
	for part: Array in parts:
		var index := w.trails.size()
		w.trails.append(Topology.section("trail", part[0], w.world_origin))
		w.generation.road_cells.append(part[1])
		for c: int in part[1]:
			if owner[c] == e and not on_road.has(c): owner[c] = index
	w.generation.road_owner = owner
	Grid.stamp_path(w.path_mask, w.W, w.H, record.pts, 3, widths.road * 0.5 - Grid.PATH_IN)


static func _point(p: Vector2, width: float) -> Dictionary:
	return {x = p.x, y = p.y, w = width}


static func _dedupe(pts: Array) -> Array:
	var out: Array = [pts[0]]
	for j in range(1, pts.size()):
		if Vector2(pts[j].x, pts[j].y).distance_squared_to(Vector2(out[-1].x, out[-1].y)) > 0.000001:
			out.append(pts[j])
	return out


## Ближайшая к p точка оси: [номер вершины конца отрезка, точка, расстояние вдоль оси]
static func _locate(pts: Array, p: Vector2) -> Array:
	var best: Array = [1, Vector2(pts[0].x, pts[0].y), 0.0]
	var best_d := INF
	var along := 0.0
	for j in range(1, pts.size()):
		var a := Vector2(pts[j - 1].x, pts[j - 1].y)
		var b := Vector2(pts[j].x, pts[j].y)
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := p.distance_squared_to(q)
		if d < best_d:
			best_d = d
			best = [j, q, along + a.distance_to(q)]
		along += a.distance_to(b)
	return best


## Дешёвая оценка направления до A*: ширина воды, крутизна и важность центров.
## Это приоритет попыток, а не разрешение строить сквозь препятствия.
static func _direction_cost(w: WorldData, a: SettlementData, b: SettlementData) -> float:
	var distance := Grid.hypot(a.x - b.x, a.y - b.y)
	var obstacle := 0.0
	var previous: int = a.i
	const SAMPLES := 16
	for k in range(1, SAMPLES + 1):
		var t := float(k) / SAMPLES
		var x := clampi(floori(lerpf(a.x, b.x, t)), 0, w.W - 1)
		var y := clampi(floori(lerpf(a.y, b.y, t)), 0, w.H - 1)
		var i := y * w.W + x
		obstacle += 4.0 if _wet(w, i) else minf(2.0, w.slope[i] * 4.0)
		obstacle += absf(w.h[i] - w.h[previous]) * HEIGHT_SCALE / maxf(1.0, distance / SAMPLES)
		previous = i
	var importance := (float(EntityCodec.value(a, "importance", 0.6)) + float(EntityCodec.value(b, "importance", 0.6))) * 0.5
	return distance * (1.0 + obstacle / SAMPLES) / (0.75 + importance * 0.5)


## Ревью дорожной сети 29.10, шаг 2: связь ищется сначала в окне вокруг концов, при неудаче окно расширяется.
## Окно — прямоугольник концов с полем не меньше WINDOW_MARGIN клеток и WINDOW_SHARE прямого расстояния,
## затем вдвое шире, затем вся карта. Путь в окне —
## лучший внутри окна: длинный обход за его краем найдётся только на следующем уровне.
const WINDOW_MARGIN := 32
const WINDOW_SHARE := 0.5


static func _windows(finder: Pathfinder, a: int, b: int) -> Array[Rect2i]:
	var pa := Vector2i(a % finder.W, a / finder.W)
	var pb := Vector2i(b % finder.W, b / finder.W)
	var box := Rect2i(Vector2i(mini(pa.x, pb.x), mini(pa.y, pb.y)), (pa - pb).abs() + Vector2i.ONE)
	var full := Rect2i(0, 0, finder.W, finder.H)
	var margin := maxi(WINDOW_MARGIN, ceili(Vector2(pa - pb).length() * WINDOW_SHARE))
	var out: Array[Rect2i] = []
	for level in 2:
		var rect := box.grow(margin).intersection(full)
		if rect == full:
			break
		out.append(rect)
		margin *= 2
	out.append(Rect2i())
	return out


static func _connect_settlement(w: WorldData, finder: Pathfinder, cost: PackedFloat32Array,
		a: int, b: int, state: Dictionary, forks: RefCounted = null) -> PackedInt32Array:
	finder.window = Rect2i()
	var structures := w.bridges.size() + w.tunnels.size()
	var q := _connect_in_windows(w, finder, cost, a, b, state)
	finder.window = Rect2i()
	if forks != null and not q.is_empty():
		var limit: float = state.get("v2_road_limit", ROAD_LIMIT)
		if structures == w.bridges.size() + w.tunnels.size():
			var preferred := _prefer_dry_connection(w, finder, forks, cost, q, state, structures)
			if preferred != q: limit = ROAD_GRADE
			q = preferred
		if network_v2:
			q = RoadNetworkV2.shape_land(w, finder, cost, q, state.on_axis, "road", limit)
	return q


static func _connect_in_windows(w: WorldData, finder: Pathfinder, cost: PackedFloat32Array,
		a: int, b: int, state: Dictionary) -> PackedInt32Array:
	var attempts: Array = []
	var source := cost
	cost = _known_crossings(source, state)
	var known: int = state.get("no_bridge", {}).size()
	# Стоимость не меняется внутри попытки связи: её правит _add_trail после возврата.
	# Следующая связь получает новый номер, в том числе после изменения стоимости.
	var cost_version := finder.next_cost_version()
	finder.use_corridor = true
	var routing := RoadTuning.current().routing
	var climb: float = routing.climb_costs.road
	# Ревью дорожной сети 29.10: связь, которой нет даже при ROAD_LIMIT, отвергается без A*. Раньше такой
	# поиск обходил всю доступную область и тратил запас места, и следующие пары того же места
	# останавливались по запасу. Причина отказа — в state.failure (_count_failure).
	if not finder.can_reach(cost, a, b, climb, ROAD_LIMIT):
		state.failure = "unreachable"
		return PackedInt32Array()
	var limits: Array = [ROAD_GRADE, ROAD_LIMIT] if finder.can_reach(cost, a, b, climb, ROAD_GRADE) else [ROAD_LIMIT]
	var windows := _windows(finder, a, b)
	# С 9.9 запасной поиск (ROAD_LIMIT) идёт в фоне, пока проверяется первый путь: после неудачи
	# состояние восстановлено, и он с теми же входами. Совпадение входов (и окна) проверяет сам поиск.
	if limits.size() > 1:
		finder.window = windows[0]
		var turns: Dictionary = routing_overrides.get("turn_costs", routing.turn_costs)
		var bends: Dictionary = routing_overrides.get("bend_costs", routing.bend_costs)
		finder.prefetch(cost, a, b, climb, ROAD_LIMIT, cost_version, turns.road, bends.road)
	for limit: float in limits:
		for level in windows.size():
			if state.get("no_bridge", {}).size() != known:
				known = state.no_bridge.size()
				cost = _known_crossings(source, state)
				cost_version = finder.next_cost_version()
			finder.window = windows[level]
			var p := _road_path(finder, cost, a, b, true, limit, cost_version)
			if p.is_empty():
				if state.get("failure", "").is_empty():
					state.failure = "budget" if finder.search_budget == 0 else "no_path"
				if finder.search_budget == 0: break
				continue
			var key := "%d" % level if windows[level].has_area() else "full"
			state.windows = state.get("windows", {})
			state.windows[key] = int(state.windows.get(key, 0)) + 1
			var previous_failure: String = state.get("failure", "")
			state.failure = ""
			var q := _try_road_structures(w, p, finder, cost, state, attempts, limit)
			if not q.is_empty():
				finder.cancel_prefetch()
				finder.use_corridor = true
				if network_v2: state.v2_road_limit = limit
				return q
			if state.failure == "repeat" and not previous_failure.is_empty():
				state.failure = previous_failure
			elif state.failure.is_empty():
				state.failure = "structures"
			if finder.search_budget == 0: break
	finder.cancel_prefetch()
	finder.use_corridor = true
	return PackedInt32Array()


## Ревью дорожной сети 29.10, шаг 3: переправы — места с известным статусом. Вода, где мост уже не нашёл
## места (state.no_bridge), закрыта для поиска следующих связей этапа: они не открывают ту же переправу заново,
## а идут к другой или сразу отвергаются can_reach. Оси построенных мостов не закрываются. Стоимость этапа
## (road_cost) не меняется — закрытие только в копии для поиска этой связи.
static func _known_crossings(cost: PackedFloat32Array, state: Dictionary) -> PackedFloat32Array:
	var banned: Dictionary = state.get("no_bridge", {})
	if banned.is_empty():
		return cost
	var out := cost.duplicate()
	var axis: PackedByteArray = state.get("on_axis", PackedByteArray())
	for i: int in banned:
		if axis.is_empty() or axis[i] == 0:
			out[i] = INF
	return out


## Счётчик причин отказа связей (ревью дорожной сети 29.10, шаг 0): unreachable — пути нет при любом
## допустимом уклоне (доказано без A*), no_path — A* исчерпал область, budget — кончился запас (путь мог быть),
## repeat — запасной поиск вернул уже отвергнутую ось, bridge_site — нет места для моста после объездов,
## tunnel — туннель не поддерживается и обхода нет, corridor — лента не легла на проходимые клетки.
static func _count_failure(failures: Dictionary, state: Dictionary) -> void:
	var reason: String = state.get("failure", "")
	if reason.is_empty(): reason = "unknown"
	failures[reason] = int(failures.get(reason, 0)) + 1
	state.failure = ""


## После неудачи _structures полностью восстанавливает состояние. Запасной поиск может
## вернуть ту же ось в том же режиме: повторная проверка мостов и объездов ничего не изменит.
## Разные режимы ширины проверяются отдельно: они влияют на поиск объездов внутри _structures.
static func _try_road_structures(w: WorldData, path: PackedInt32Array, finder: Pathfinder,
		cost: PackedFloat32Array, state: Dictionary, attempts: Array, limit := ROAD_GRADE) -> PackedInt32Array:
	for previous: Array in attempts:
		if previous[1] == finder.use_corridor and previous[2] == limit and previous[0] == path:
			state.failure = "repeat"
			return PackedInt32Array()
	attempts.append([path, finder.use_corridor, limit])
	return _structures(w, path, true, finder, cost, state, 0, limit)


## Новая связь полезна, если сокращает реальный обход по сети. Второй проход нужен,
## если идёт по другому уровню рельефа. Оба ищутся по суше, без обязательного числа петель.
## Соседи по пространству (Габриэль: внутри круга с диаметром a–b нет другого поселения), без связей остова и не дальше
## 0,45 карты: [a, b, расстояние], от близких к дальним. Общий отбор пар вторых путей V1 и петель V2.
static func _gabriel_pairs(w: WorldData, paths: Array) -> Array:
	var st := w.settlements
	var n := st.size()
	var have := {}
	for e in paths:
		have[_key(e[0], e[1])] = true
	var pairs: Array = []
	for a in n:
		for b in range(a + 1, n):
			var d := Grid.hypot(st[a].x - st[b].x, st[a].y - st[b].y)
			if have.has(_key(a, b)) or d >= w.W * 0.45:
				continue
			var neighbor := true
			for s in st:
				if (s.x - st[a].x) * (s.x - st[b].x) + (s.y - st[a].y) * (s.y - st[b].y) < 0.0:
					neighbor = false
					break
			if neighbor:
				pairs.append([a, b, d])
	pairs.sort_custom(func(p: Array, q: Array) -> bool: return p[2] < q[2] if p[2] != q[2] else _key(p[0], p[1]) < _key(q[0], q[1]))
	return pairs


static func _second_ways(w: WorldData, finder: Pathfinder, paths: Array, road_cost: PackedFloat32Array, state: Dictionary, step: Callable = Callable()) -> void:
	var st := w.settlements
	var pairs := _gabriel_pairs(w, paths)
	w.generation_profile.second_ways = []
	var forks := RoadForks.new(w, state.on_axis)
	var network := _network_cost(w)
	var near := _net_near(w)
	for index in pairs.size():
		if finder.search_budget == 0: break
		var e: Array = pairs[index]
		if step.is_valid():
			step.call(0.69 + 0.015 * index / maxi(1, pairs.size()), "Дополнительные тропы: %d/%d" % [index + 1, pairs.size()])
		var a: int = st[e[0]].i
		var b: int = st[e[1]].i
		# Сеть V2: путь по сети нужен только сокращениям V1 — здесь достаточно знать, связаны ли места сетью
		var reach_net := finder.can_reach(network, a, b)
		if network_v2 and reach_net:
			continue
		var old := finder.find_path(network, a, b) if reach_net else PackedInt32Array()
		if old.is_empty():
			# С 9.8: соседи из разных сетей дорог (между ними река без места для моста) —
			# тропа между сетями: вброд, по мосту для тропы или в обход.
			var link := _land_path(finder, w.cost, a, b, "trail")
			var joint := _structures(w, link, false, finder, w.cost, state) if not link.is_empty() else link
			if not joint.is_empty():
				if network_v2:
					joint = RoadNetworkV2.shape_land(w, finder, w.cost, joint, state.on_axis, "trail", TRAIL_GRADE)
				_note_way(w, "bridge_gap", _add_trail(w, joint, "trail", road_cost, state.on_axis, state.get("surface")))
				paths.append([e[0], e[1], joint, false, e[2]])
				network = _network_cost(w)
				near = _net_near(w)
			continue
		# 21.11.2026: в сети V2 из этого цикла остаётся только тропа между сетями (bridge_gap); петли — RoadNetworkV2
		if network_v2:
			continue
		var old_len := _length(w, old)
		if old.is_empty() or old_len <= e[2] * SHORTCUT:
			continue
		# 16.11.2026: у удалённого места (SettlementRoles, роль remote) один подъезд — сокращений к нему нет.
		# Тропа между сетями выше остаётся: без неё отрезанное место удалилось бы.
		if _single_access(st[e[0]]) or _single_access(st[e[1]]):
			continue
		var corr := _corridor(w, [old])
		var avoiding := _exit_cost(w, corr, a, b)
		# Совпадение с прежней связью и доля новой земли — по добавляемой части (_core): общий выезд не в счёт
		# Повторные касания сети в общем выезде (сход и возврат у поселения) не в счёт: _adds_network — за кругами EXIT_R
		var q := _secondary_path(w, finder, forks, avoiding, a, b, state,
			func(q: PackedInt32Array) -> bool: return _length(w, q) * SHORTCUT < old_len and _share(_core(w, q), corr) <= AVOID_SHARE and _new_ground(w, _core(w, q)) and _exit_clean(w, q, near))
		if q.is_empty():
			continue
		_note_way(w, "shortcut", _add_trail(w, q, "trail", road_cost, state.on_axis, state.get("surface")))
		paths.append([e[0], e[1], q, false, e[2]])
		network = _network_cost(w)
		near = _net_near(w)
	# Сеть V2: петли (t-спаннер) и ответвления к берегу и смотровым точкам вместо обходов, берега и смотровых V1
	if network_v2:
		finder.search_budget = -1
		RoadNetworkV2.plan_loops(w, finder, paths, road_cost, state)
		RoadNetworkV2.plan_spurs(w, finder, paths, road_cost, state.on_axis, state.get("surface"), false, state.get("v2_unsafe", PackedByteArray()))
		return
	# Проверяем каждую основную связь; плоская копия соседней дороги сама по себе не повод для петли.
	var primary_paths := paths.duplicate()
	for index in primary_paths.size():
		if finder.search_budget == 0: break
		var e: Array = primary_paths[index]
		if not e[3] or _single_access(st[e[0]]) or _single_access(st[e[1]]):
			continue
		if step.is_valid():
			step.call(0.705 + 0.015 * index / maxi(1, primary_paths.size()), "Обходные тропы: %d/%d" % [index + 1, primary_paths.size()])
		var corr := _corridor(w, [e[2]])
		var avoiding := _exit_cost(w, corr, st[e[0]].i, st[e[1]].i)
		# Совпадение, новая земля, другой рельеф и удаление от связи — по добавляемой части (_core): общий выезд не в счёт
		var q := _secondary_path(w, finder, forks, avoiding, st[e[0]].i, st[e[1]].i, state,
			func(q: PackedInt32Array) -> bool: return _length(w, q) <= _length(w, e[2]) * ALT_LEN and _share(_core(w, q), corr) <= AVOID_SHARE and _new_ground(w, _core(w, q)) and _different_relief(w, _core(w, q), e[2]) and _exit_clean(w, q, near) and _far_share(w, _core(w, q), e[2]) >= FAR_SHARE)
		if q.is_empty():
			continue
		_note_way(w, "alternative", _add_trail(w, q, "trail", road_cost, state.on_axis, state.get("surface")))
		paths.append([e[0], e[1], q, false, e[4]])
		near = _net_near(w)
	# Берег — самостоятельная цель исследования, даже у поселения с несколькими дорогами.
	var all_paths: Array = []
	for e in paths:
		all_paths.append(e[2])
	# Коридор зависит только от списка путей: пересчёт лишь после новой тропы.
	var corr := PackedByteArray()
	var corr_paths := -1
	# 17.11.2026: берег ищется от точек на перегонах основных связей (_shore_anchors), а не от центра поселения:
	# тропа к воде отходит там, где дорога проходит у берега, а не пятачком у деревни. Тропы к берегу не ближе
	# SHORE_GAP друг к другу и не больше, чем поселений (прежний предел — одна на поселение).
	var settle_d := _settle_dist(w)
	var water_d := _water_dist(w)
	var anchors := _shore_anchors(w, paths, settle_d, water_d)
	var targets: Array[Vector2i] = []
	var shores := 0
	for index in anchors.size():
		if finder.search_budget == 0 or shores >= st.size(): break
		if step.is_valid():
			step.call(0.72 + 0.02 * index / maxi(1, anchors.size()), "Тропы к берегам: %d/%d" % [index + 1, anchors.size()])
		if corr_paths != all_paths.size():
			corr = _corridor(w, all_paths)
			corr_paths = all_paths.size()
		var shore_us := Time.get_ticks_usec()
		var t := _shore(w, anchors[index], corr, water_d)
		_part("shore", shore_us)
		var tv := Vector2i(t % w.W, t / w.W)
		var spaced := true
		for o: Vector2i in targets:
			if (o - tv).length_squared() < SHORE_GAP * SHORE_GAP: spaced = false
		if t >= 0 and spaced:
			targets.append(tv) # и неудачная попытка: соседние точки перегона нашли бы тот же берег
			if _spur(w, finder, anchors[index], t, SHORE_MAX, "shore", road_cost, state, near, settle_d, all_paths, forks):
				shores += 1
				near = _net_near(w)
	# 17.11.2026: смотровые точки — вершины холмов над перегоном (_overlook): короткая тропа наверх, откуда видно долину.
	# Те же точки перегонов (без условия воды), не ближе VIEW_GAP друг к другу, не больше, чем поселений.
	var views := 0
	var view_targets: Array[Vector2i] = []
	var legs := _shore_anchors(w, paths, settle_d, PackedFloat32Array())
	for index in legs.size():
		if finder.search_budget == 0 or views >= st.size(): break
		if corr_paths != all_paths.size():
			corr = _corridor(w, all_paths)
			corr_paths = all_paths.size()
		var view_us := Time.get_ticks_usec()
		var t := _overlook(w, legs[index], corr)
		_part("overlook", view_us)
		if t < 0: continue
		var tv := Vector2i(t % w.W, t / w.W)
		var spaced := true
		for o: Vector2i in view_targets:
			if (o - tv).length_squared() < VIEW_GAP * VIEW_GAP: spaced = false
		if not spaced: continue
		view_targets.append(tv)
		if _spur(w, finder, legs[index], t, VIEW_MAX, "view", road_cost, state, near, settle_d, all_paths, forks):
			views += 1
			near = _net_near(w)


## A single extra search can move where a through route leaves the existing road.
## Keep all original route and structure checks, and fall back if the detour is poor.
static func _secondary_path(w: WorldData, finder: Pathfinder, forks: RefCounted, cost: PackedFloat32Array,
		a: int, b: int, state: Dictionary, accept: Callable) -> PackedInt32Array:
	var path := _land_path(finder, cost, a, b, "trail")
	if path.is_empty() or not accept.call(path):
		return PackedInt32Array()
	forks.refresh(state.on_axis)
	var crowd: float = forks.pressure(path)
	if crowd > 0.0 and finder.search_budget != 0:
		var preferred: PackedFloat32Array = forks.preferred_cost(cost)
		var limit := _fork_length_limit(w, path)
		var better := func(q: PackedInt32Array) -> bool:
			return _length(w, q) <= limit and forks.pressure(q) + 0.05 < crowd and accept.call(q)
		var moved := _fork_search(finder, func() -> PackedInt32Array:
			var q := _land_path(finder, preferred, a, b, "trail")
			return _structures(w, q, false, finder, preferred, state, 0, ROAD_GRADE, better) if not q.is_empty() and better.call(q) else PackedInt32Array())
		if not moved.is_empty():
			return moved
	return _structures(w, path, false, finder, cost, state, 0, ROAD_GRADE, accept)


static func _fork_length_limit(w: WorldData, path: PackedInt32Array) -> float:
	var length := _length(w, path)
	return length + maxf(4.0, length * 0.20)


## Another alignment for an already established settlement link. Any search
## or structure failure leaves the confirmed connection available for publication.
static func _prefer_dry_connection(w: WorldData, finder: Pathfinder, forks: RefCounted, cost: PackedFloat32Array,
		path: PackedInt32Array, state: Dictionary, structures: int) -> PackedInt32Array:
	forks.refresh(state.on_axis)
	var crowd: float = forks.pressure(path)
	var axis: PackedByteArray = state.on_axis
	var dry := func(q: PackedInt32Array) -> bool:
		for c: int in q:
			if axis[c] != 0 or _wet(w, c): return false
		return true
	if crowd <= 0.0 or not dry.call(path):
		return path
	var preferred: PackedFloat32Array = forks.preferred_cost(cost)
	var limit := _fork_length_limit(w, path)
	var better := func(q: PackedInt32Array) -> bool:
		return w.bridges.size() + w.tunnels.size() == structures and _length(w, q) <= limit and forks.pressure(q) + 0.05 < crowd and dry.call(q)
	var available := finder.search_budget
	var moved := _fork_search(finder, func() -> PackedInt32Array:
		var q := _explicit(w, _road_path(finder, preferred, path[0], path[-1]), state.on_axis)
		return _structures(w, q, true, finder, preferred, state, 0, ROAD_GRADE, better) if not q.is_empty() and better.call(q) else PackedInt32Array())
	# This link already succeeded. The spare alignment trial cannot consume the
	# budget reserved for later settlement connections.
	finder.search_budget = available
	state.failure = ""
	return path if moved.is_empty() else moved


## Reserve the rest of the stage budget for the original route and later targets.
static func _fork_search(finder: Pathfinder, search: Callable) -> PackedInt32Array:
	var available := finder.search_budget
	var limit := mini(24000, available / 8) if available >= 0 else 24000
	if limit <= 0:
		return PackedInt32Array()
	finder.search_budget = limit
	var path: PackedInt32Array = search.call()
	finder.search_budget = available - (limit - finder.search_budget) if available >= 0 else available
	return path


## Короткая тропа от сети к цели t (берег, смотровая точка): от ближайшей к цели точки сети (не дальше reach), а если
## она у поселения или её нет — от точки перегона anchor. Не длиннее BRANCH_LEN прямых, не дубль сети. true — добавлена.
static func _spur(w: WorldData, finder: Pathfinder, anchor: int, t: int, reach: int, what: String, road_cost: PackedFloat32Array,
		state: Dictionary, near: PackedFloat32Array, settle_d: PackedFloat32Array, all_paths: Array, forks: RefCounted) -> bool:
	var source := _nearest_path(w, t, reach)
	if source < 0 or settle_d[source] < EXIT_R:
		source = anchor
	var direct := _land_path(finder, w.cost, source, t, "trail")
	var max_length := _cell_centre(source, w.W).distance_to(_cell_centre(t, w.W)) * BRANCH_LEN
	var accept := func(q: PackedInt32Array) -> bool:
		return _length(w, q) <= max_length and _new_ground(w, q) and _adds_network(w, q, near)
	var q := _from_quieter_fork(w, finder, forks, source, t, direct, "trail", TRAIL_GRADE, state.on_axis, settle_d,
		func(p: PackedInt32Array, better: Callable) -> PackedInt32Array:
			var valid := func(route: PackedInt32Array) -> bool: return accept.call(route) and better.call(route)
			return _structures(w, p, false, finder, w.cost, state, 0, ROAD_GRADE, valid) if valid.call(p) else PackedInt32Array())
	if q.is_empty() and not direct.is_empty() and accept.call(direct):
		q = _structures(w, direct, false, finder, w.cost, state, 0, ROAD_GRADE, accept)
	if q.is_empty():
		return false
	_note_way(w, what, _add_trail(w, q, "trail", road_cost, state.on_axis, state.get("surface")))
	all_paths.append(q)
	return true


static func _from_quieter_fork(w: WorldData, finder: Pathfinder, forks: RefCounted, source: int, target: int,
		direct: PackedInt32Array, kind: String, grade: float, on_axis: PackedByteArray,
		settle_d: PackedFloat32Array, finish: Callable) -> PackedInt32Array:
	forks.refresh(on_axis)
	var crowd: float = forks.pressure_at(source) if direct.is_empty() else forks.pressure(direct)
	if crowd <= 0.0:
		return PackedInt32Array()
	var limit := _fork_length_limit(w, direct) if not direct.is_empty() else _cell_centre(source, w.W).distance_to(_cell_centre(target, w.W)) * BRANCH_LEN
	var better := func(p: PackedInt32Array) -> bool: return _length(w, p) <= limit and forks.pressure(p) + 0.05 < crowd
	var takeoff: int = forks.crowded_takeoff(direct)
	for from: int in forks.sources(takeoff if takeoff >= 0 else source, settle_d, EXIT_R):
		if from == source: continue # already searched
		var path := _fork_search(finder, func() -> PackedInt32Array:
			var p := _land_path(finder, w.cost, from, target, kind, grade)
			return finish.call(p, better) if not p.is_empty() and better.call(p) else PackedInt32Array())
		if not path.is_empty():
			return path
	return PackedInt32Array()


const VIEW_MIN := 12     # смотровая точка не ближе стольких клеток (48 м) от точки перегона
const VIEW_MAX := 45     # и не дальше (180 м)
const VIEW_RISE := 15.0  # м: выше точки перегона хотя бы на столько
const VIEW_GAP := 60     # клеток (240 м) между смотровыми точками
const VIEW_STEP := 2     # шаг перебора клеток


## Смотровая точка у клетки сети s: самая высокая клетка суши в кольце VIEW_MIN..VIEW_MAX (перебор через VIEW_STEP),
## выше s на VIEW_RISE м, не в коридоре near прежних путей и не на краю кольца (там склон продолжается — это не вершина);
## -1, если такой нет
static func _overlook(w: WorldData, s: int, near: PackedByteArray) -> int:
	var sx := s % w.W
	var sy := s / w.W
	var best := -1
	var top := w.h[s] + VIEW_RISE / (HEIGHT_SCALE * GameConfig.TILE)
	var best_d := 0
	for y in range(maxi(0, sy - VIEW_MAX), mini(w.H, sy + VIEW_MAX + 1), VIEW_STEP):
		for x in range(maxi(0, sx - VIEW_MAX), mini(w.W, sx + VIEW_MAX + 1), VIEW_STEP):
			var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
			if d < VIEW_MIN * VIEW_MIN or d > VIEW_MAX * VIEW_MAX: continue
			var i := y * w.W + x
			if w.h[i] <= top or near[i] != 0 or w.cost[i] == INF or w.ocean[i] != 0 or w.lake[i] != 0: continue
			top = w.h[i]
			best = i
			best_d = d
	if best < 0 or best_d > (VIEW_MAX - 3) * (VIEW_MAX - 3):
		return -1
	return best


## 16.11.2026: замер поездок по основным связям (только отчёт, на мир не влияет; стенд settlement_look --roads).
## На связь: [длина, м; длина / прямая; природных зон по пути; подъём над высшим концом, м]. Зона — лес, открытое,
## берег, горы; участок зоны считается, если он не короче JOURNEY_RUN клеток подряд.
const JOURNEY_RUN := 25 # клеток (100 м)


static func _journeys(w: WorldData, paths: Array) -> Array:
	var out: Array = []
	# Заготовки тестов задают не все поля — без них замера нет
	if w.elev.size() != w.N or w.dist_water.size() != w.N or w.biome.size() != w.N or w.h.size() != w.N:
		return out
	for e: Array in paths:
		if not e[3]: continue
		var q: PackedInt32Array = e[2]
		if q.size() < 2: continue
		var zones := {}
		var zone := -1
		var run := 0
		var top := -INF
		for c: int in q:
			var z := _zone(w, c)
			run = run + 1 if z == zone else 1
			zone = z
			if run == JOURNEY_RUN: zones[z] = true
			top = maxf(top, w.h[c])
		var ends := maxf(w.h[q[0]], w.h[q[-1]])
		out.append([roundi(_length(w, q) * GameConfig.TILE), snappedf(_length(w, q) / maxf(1.0, e[4]), 0.01), zones.size(),
			roundi(maxf(0.0, top - ends) * HEIGHT_SCALE * GameConfig.TILE)])
	return out


## Природная зона клетки для замера поездок: 0 — открытое, 1 — лес, 2 — берег и вода, 3 — горы
static func _zone(w: WorldData, c: int) -> int:
	var b := w.biome[c]
	if w.elev[c] >= 0.5 or b in [Biomes.ROCK, Biomes.SNOW, Biomes.PEAK]: return 3
	if w.dist_water[c] < 3.0 or b in [Biomes.BEACH, Biomes.STONESHORE]: return 2
	if b in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.SWAMP]: return 1
	return 0


## Место с единственным подъездом: вторые пути (сокращения, обходы) к нему не прокладываются
static func _single_access(s: SettlementData) -> bool:
	return s.role == "remote"


## Какие записи w.trails добавил каждый вид вторых путей (стенд road_plan_test)
static func _note_way(w: WorldData, what: String, added: Array) -> void:
	var notes: Array = w.generation_profile.get("second_ways", [])
	notes.append([what, added])
	w.generation_profile.second_ways = notes


static func _nearest_path(w: WorldData, target: int, radius: int) -> int:
	var best := -1
	var distance := radius * radius + 1
	var tx := target % w.W
	var ty := target / w.W
	for y in range(maxi(0, ty - radius), mini(w.H, ty + radius + 1)):
		for x in range(maxi(0, tx - radius), mini(w.W, tx + radius + 1)):
			var i := y * w.W + x
			var d := (x - tx) * (x - tx) + (y - ty) * (y - ty)
			if w.path_mask[i] >= 2 and w.cost[i] != INF and d < distance:
				best = i
				distance = d
	return best


## Сеть уже нарисованных путей людей: реальный обход учитывает развилки вне поселений.
static func _network_cost(w: WorldData) -> PackedFloat32Array:
	var part_us := Time.get_ticks_usec()
	var fast := Grid.fast_grid()
	if fast != null:
		var quick: PackedFloat32Array = fast.MaskCost(w.path_mask, 2) # тот же цикл на C# (шаг 5 ревью)
		_part("network_cost", part_us)
		return quick
	var cost := PackedFloat32Array()
	cost.resize(w.N)
	for i in w.N:
		cost[i] = 1.0 if w.path_mask[i] >= 2 else INF
	_part("network_cost", part_us)
	return cost


## У троп свой предел: короткий технический подъём конкурирует с длинным обходом по цене A*.
static func _land_path(finder: Pathfinder, cost: PackedFloat32Array, a: int, b: int, kind: String, limit := TRAIL_GRADE) -> PackedInt32Array:
	var routing := RoadTuning.current().routing
	var climb: float = routing.climb_costs[kind]
	if finder.search_budget != 0 and not finder.can_reach(cost, a, b, climb, limit):
		return PackedInt32Array()
	var turns: Dictionary = routing_overrides.get("turn_costs", routing.turn_costs)
	var bends: Dictionary = routing_overrides.get("bend_costs", routing.bend_costs)
	return finder.find_path(cost, a, b, climb, limit, -1, turns[kind], bends[kind])


## Земляные работы могут исправить край полотна; продольный обрыв ими не исправить.
## Вода доступна для сооружений; на суше полная ширина проверяется во всех попытках.
static func _road_path(finder: Pathfinder, cost: PackedFloat32Array, a: int, b: int, wide := true, limit := ROAD_GRADE, cost_version: int = -1) -> PackedInt32Array:
	finder.use_corridor = wide
	var routing := RoadTuning.current().routing
	var turns: Dictionary = routing_overrides.get("turn_costs", routing.turn_costs)
	var bends: Dictionary = routing_overrides.get("bend_costs", routing.bend_costs)
	return finder.find_path(cost, a, b, routing.climb_costs.road, limit, cost_version, turns.road, bends.road)


static func _length(w: WorldData, p: PackedInt32Array) -> float:
	var length := 0.0
	for k in range(1, p.size()):
		length += Grid.hypot(p[k] % w.W - p[k - 1] % w.W, p[k] / w.W - p[k - 1] / w.W)
	return length


## Не дублировать маршрут, уже проходящий по другой части сети.
static func _new_ground(w: WorldData, p: PackedInt32Array) -> bool:
	var fresh := 0
	for i in p:
		if w.path_mask[i] < 2:
			fresh += 1
	return fresh > p.size() * 0.5


## 11.11.2026: второй путь не повторяет готовую сеть сбоку. Доля его новых клеток (не на сети), которые идут ближе
## NEAR_NET клеток к сети на той же высоте (разница меньше LEVEL_GAP м: полка выше по склону — другой уровень, это
## годится), кроме первых и последних NODE_CELLS клеток (подход к узлу всегда рядом с сетью).
## near — Grid.distance_field от клеток сети (_net_near).
const NODE_CELLS := 8
const NEAR_NET := 8.0       # 32 м
const LEVEL_GAP := 12.0     # м: склон 30 % в 30 м по горизонтали — ещё тот же склон
const PARALLEL_SHARE := 0.25
const PARALLEL_RUN := 15     # клеток (60 м) подряд вдоль сети — уже второе полотно
const REJOIN_GAP := 40      # клеток пути: второе касание того же участка ближе этого — путь петляет через дорогу
const FAR_R := 10.0         # обход уходит от своей связи дальше этого (клеток, 40 м)
const FAR_SHARE := 0.3      # хотя бы такой долей


## Клетки сети (участки путей людей) и расстояние до них
static func _net_cells(w: WorldData) -> PackedByteArray:
	var net := PackedByteArray()
	net.resize(w.N)
	var owner := w.generation.road_owner
	for i in w.N:
		if owner[i] >= 0: net[i] = 1
	return net


static func _net_near(w: WorldData) -> PackedFloat32Array:
	return Grid.distance_field(w.W, w.H, _net_cells(w))


## Вдоль сети: Vector2(доля, самый длинный подряд участок в клетках) новых клеток пути (net[i] == 0), которые идут
## ближе NEAR_NET клеток к сети на той же высоте. near — Grid.distance_field от net. Общий для вторых путей и RideRoutes.
static func _parallel_stats(w: WorldData, p: PackedInt32Array, near: PackedFloat32Array, net: PackedByteArray) -> Vector2:
	var fresh := 0
	var side := 0
	var run := 0
	var longest := 0
	var r := ceili(NEAR_NET)
	for k in range(NODE_CELLS, p.size() - NODE_CELLS):
		var i := p[k]
		if net[i] != 0:
			run = 0
			continue
		fresh += 1
		var level := INF
		if near[i] <= NEAR_NET:
			var x := i % w.W
			var y := i / w.W
			var reach := near[i] + 0.75
			for dy in range(-r, r + 1):
				for dx in range(-r, r + 1):
					var nx := x + dx
					var ny := y + dy
					if nx < 0 or ny < 0 or nx >= w.W or ny >= w.H or dx * dx + dy * dy > reach * reach: continue
					var j := ny * w.W + nx
					if net[j] != 0: level = minf(level, absf(w.h[j] - w.h[i]) * HEIGHT_SCALE * GameConfig.TILE)
		if level < LEVEL_GAP:
			side += 1
			run += 1
			longest = maxi(longest, run)
		else:
			run = 0
	return Vector2(float(side) / fresh if fresh > 0 else 0.0, longest)


## Путь дважды касается одного участка сети (пересекает или примыкает) ближе REJOIN_GAP клеток друг от друга:
## повторное пересечение, Z-образный заход на дорогу и обратно. Касания на концах пути (узлы) не считаются.
static func _rejoins(w: WorldData, p: PackedInt32Array) -> bool:
	var owner := w.generation.road_owner
	var n := p.size()
	var first := 0
	while first < n and owner[p[first]] >= 0: first += 1
	var last := n - 1
	while last >= 0 and owner[p[last]] >= 0: last -= 1
	var seen := {}
	var previous := -1
	for k in range(first, last + 1):
		var o := owner[p[k]]
		if o >= 0 and o != previous:
			if seen.has(o) and k - int(seen[o]) < REJOIN_GAP: return true
		# выход с участка записывается при любой смене участка, в том числе без свободной клетки между участками
		if o != previous and previous >= 0: seen[previous] = k
		previous = o
	return false


## Доля клеток пути p дальше FAR_R от клеток пути from
static func _far_share(w: WorldData, p: PackedInt32Array, from: PackedInt32Array) -> float:
	var src := PackedByteArray()
	src.resize(w.N)
	for i: int in from: src[i] = 1
	var dist := Grid.distance_field(w.W, w.H, src)
	var far := 0
	for i: int in p:
		if dist[i] > FAR_R: far += 1
	return float(far) / maxi(1, p.size())


## Годится ли новый путь как дополнение сети: не вдоль неё и без повторных пересечений
static func _adds_network(w: WorldData, p: PackedInt32Array, near: PackedFloat32Array) -> bool:
	var side := _parallel_stats(w, p, near, _net_cells(w))
	return side.x <= PARALLEL_SHARE and side.y <= PARALLEL_RUN and not _rejoins(w, p)


## Более низкий перевал или другой уровень долины/склона дают осмысленный выбор направления.
static func _different_relief(w: WorldData, a: PackedInt32Array, b: PackedInt32Array) -> bool:
	var top_a := -INF
	var top_b := -INF
	var mean_a := 0.0
	var mean_b := 0.0
	for i in a:
		top_a = maxf(top_a, w.h[i])
		mean_a += w.h[i]
	for i in b:
		top_b = maxf(top_b, w.h[i])
		mean_b += w.h[i]
	return top_a < top_b - RELIEF_CHOICE or absf(mean_a / a.size() - mean_b / b.size()) > RELIEF_CHOICE


const MOUNTAIN_DETOUR := 1.15 # горная тропа: вход на перегоне не дальше от вершины, чем во столько раз (+4 клетки)
const SHORE_STEP := 20.0 # клеток (80 м) между точками поиска берега на перегоне
const SHORE_GAP := 50    # клеток (200 м): тропы к берегу не ближе друг к другу


## Расстояние (клеток) до ближайшего центра поселения
static func _settle_dist(w: WorldData) -> PackedFloat32Array:
	var src := PackedByteArray()
	src.resize(w.N)
	for s: SettlementData in w.settlements: src[s.i] = 1
	return Grid.distance_field(w.W, w.H, src)


## Точки поиска берега: клетки основных связей через SHORE_STEP, дальше EXIT_R от поселений и не дальше SHORE_MAX
## от моря или озера. Поселение без основных связей — само точка поиска (как раньше). Пустой water_d — все точки
## перегонов без условия воды и без поселений (смотровые точки).
static func _shore_anchors(w: WorldData, paths: Array, settle_d: PackedFloat32Array, water_d: PackedFloat32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var seen := {}
	var linked := {}
	for e: Array in paths:
		if not e[3]: continue
		linked[e[0]] = true
		linked[e[1]] = true
		var p: PackedInt32Array = e[2]
		var run := 0.0
		for k in range(1, p.size()):
			run += Grid.hypot(p[k] % w.W - p[k - 1] % w.W, p[k] / w.W - p[k - 1] / w.W)
			var c := p[k]
			if run < SHORE_STEP or settle_d[c] < EXIT_R or not water_d.is_empty() and water_d[c] > SHORE_MAX or seen.has(c): continue
			run = 0.0
			seen[c] = true
			out.append(c)
	for k in w.settlements.size():
		if not linked.has(k) and not water_d.is_empty(): out.append(w.settlements[k].i)
	return out


## Расстояние (клеток) до моря или озера; не дальше 1,5 — то же, что _at_mouth (вода в восьми соседях или сама клетка)
static func _water_dist(w: WorldData) -> PackedFloat32Array:
	var water := PackedByteArray()
	water.resize(w.N)
	for i: int in w.N:
		if w.ocean[i] != 0 or w.lake[i] != 0: water[i] = 1
	return Grid.distance_field(w.W, w.H, water)


## Ближайшая к клетке s клетка морского или озёрного берега от SHORE_MIN до SHORE_MAX клеток,
## не в коридоре near прежних путей; -1, если такой нет
static func _shore(w: WorldData, s: int, near: PackedByteArray, water_d: PackedFloat32Array) -> int:
	var W := w.W
	var sx := s % W
	var sy := s / W
	var best := -1
	var bd := INF
	for y in range(maxi(0, sy - SHORE_MAX), mini(w.H, sy + SHORE_MAX + 1)):
		for x in range(maxi(0, sx - SHORE_MAX), mini(W, sx + SHORE_MAX + 1)):
			var i := y * W + x
			var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
			if d < SHORE_MIN * SHORE_MIN or d >= bd or near[i] != 0 or w.cost[i] == INF or water_d[i] > 1.5:
				continue
			bd = d
			best = i
	return best


## 11.11.2026: у концов второй путь может идти по готовой сети — развилка в стороне от поселения, а не второе полотно
## рядом с первым от самого поселения (коридор избегания раньше отталкивал его сразу от общего конца).
## 17.11.2026: общий выезд длиннее (было 12 клеток, 48 м — развилки всё равно оставались у самого поселения), а новая
## земля в этом круге в EXIT_MUL раз дороже: путь выходит из поселения по готовой дороге и отделяется на перегоне.
## Мягко: если подходящего выезда нет, путь платит за новую землю, а не пропадает.
const EXIT_R := 35.0   # клеток (140 м): предпочтение общему выезду из поселения
const EXIT_MUL := 3.5


## Коридор near без клеток в круге EXIT_R вокруг концов a и b (в нём путь идёт по прежней связи свободно)
static func _open_ends(w: WorldData, near: PackedByteArray, a: int, b: int) -> PackedByteArray:
	var out := near.duplicate()
	for i: int in _exit_cells(w, [a, b]): out[i] = 0
	return out


## Клетки не на сети в круге EXIT_R вокруг поселений a и b — дорогая новая земля у выезда
static func _exit_ring(w: WorldData, a: int, b: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(w.N)
	for i: int in _exit_cells(w, [a, b]):
		if w.path_mask[i] < 2: out[i] = 1
	return out


static func _exit_cells(w: WorldData, centres: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var r := ceili(EXIT_R)
	for c: int in centres:
		var cx := c % w.W
		var cy := c / w.W
		for y in range(maxi(0, cy - r), mini(w.H, cy + r + 1)):
			for x in range(maxi(0, cx - r), mini(w.W, cx + r + 1)):
				if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= EXIT_R * EXIT_R: out.append(y * w.W + x)
	return out


## Стоимость второго пути между поселениями a и b: коридор прежней связи near дорогой (_avoiding), кроме общего
## выезда; новая земля у самих поселений — в EXIT_MUL раз дороже (_exit_ring)
static func _exit_cost(w: WorldData, near: PackedByteArray, a: int, b: int) -> PackedFloat32Array:
	var cost := _avoiding(w, _open_ends(w, near, a, b))
	var ring := _exit_ring(w, a, b)
	var fast := Grid.fast_grid()
	if fast != null:
		return fast.ScaledCost(cost, ring, EXIT_MUL)
	for i: int in w.N:
		if ring[i] != 0 and cost[i] != INF: cost[i] *= EXIT_MUL
	return cost


## Второй путь между поселениями годится как дополнение сети: за выездами не вдоль сети и без повторных касаний
## (_adds_network по _beyond_exits), а в самих выездах — без петель (_exit_loop)
static func _exit_clean(w: WorldData, p: PackedInt32Array, near: PackedFloat32Array) -> bool:
	return not _exit_loop(w, p, false) and not _exit_loop(w, p, true) and _adds_network(w, _beyond_exits(w, p), near)


## 17.11.2026: петля в выезде — в круге EXIT_R вокруг конца пути он уже отошёл от сети (больше JITTER_RUN свободных
## клеток подряд), а потом снова идёт по ней дольше CROSS_RUN клеток: «сошёл — вернулся — снова сошёл» у поселения.
## Общий выезд по дороге и короткое пересечение другой дороги после схода — не петля. reverse — со стороны конца.
static func _exit_loop(w: WorldData, p: PackedInt32Array, reverse: bool) -> bool:
	var n := p.size()
	if n < 2: return false
	var o := p[n - 1] if reverse else p[0]
	var ox := o % w.W
	var oy := o / w.W
	var left := false
	var fresh := 0
	var touch := 0
	for k in n:
		var c := p[n - 1 - k] if reverse else p[k]
		var dx := c % w.W - ox
		var dy := c / w.W - oy
		if dx * dx + dy * dy > EXIT_R * EXIT_R: break
		if w.path_mask[c] >= 2:
			fresh = 0
			if left:
				touch += 1
				if touch > CROSS_RUN: return true
		else:
			touch = 0
			fresh += 1
			if fresh > JITTER_RUN: left = true
	return false


## Путь между поселениями без концов внутри кругов EXIT_R вокруг его первой и последней клетки (общие выезды)
static func _beyond_exits(w: WorldData, p: PackedInt32Array) -> PackedInt32Array:
	var n := p.size()
	if n < 2: return p
	var a := Vector2(p[0] % w.W, p[0] / w.W)
	var b := Vector2(p[-1] % w.W, p[-1] / w.W)
	var first := 0
	var last := n - 1
	while first < n - 1 and Vector2(p[first] % w.W, p[first] / w.W).distance_to(a) <= EXIT_R: first += 1
	while last > first and Vector2(p[last] % w.W, p[last] / w.W).distance_to(b) <= EXIT_R: last -= 1
	return p.slice(first, last + 1)


## Путь без начальных и конечных клеток готовой сети: та часть, которую он добавит (общий выезд не в счёт)
static func _core(w: WorldData, p: PackedInt32Array) -> PackedInt32Array:
	var first := 0
	var last := p.size() - 1
	while first < last and w.path_mask[p[first]] >= 2: first += 1
	while last > first and w.path_mask[p[last]] >= 2: last -= 1
	return p.slice(first, last + 1)


## Стоимость по суше (w.cost), в которой клетки коридора near (_corridor) в routing.avoid_cost раз дороже
static func _avoiding(w: WorldData, near: PackedByteArray) -> PackedFloat32Array:
	var part_us := Time.get_ticks_usec()
	var avoid_cost := RoadTuning.current().routing.avoid_cost
	var fast := Grid.fast_grid()
	if fast != null:
		var quick: PackedFloat32Array = fast.ScaledCost(w.cost, near, avoid_cost) # тот же цикл на C# (шаг 5 ревью)
		_part("avoiding", part_us)
		return quick
	var c := w.cost.duplicate()
	for i: int in w.N:
		if near[i] != 0 and c[i] != INF:
			c[i] *= avoid_cost
	_part("avoiding", part_us)
	return c


## Клетки ближе AVOID_R к путям avoid (квадрат вокруг каждой клетки пути)
static func _corridor(w: WorldData, avoid: Array) -> PackedByteArray:
	var part_us := Time.get_ticks_usec()
	var W := w.W
	var near := PackedByteArray()
	near.resize(w.N)
	for path in avoid:
		for i in (path as PackedInt32Array):
			var cx := i % W
			var cy := i / W
			for y in range(maxi(0, cy - AVOID_R), mini(w.H, cy + AVOID_R + 1)):
				for x in range(maxi(0, cx - AVOID_R), mini(W, cx + AVOID_R + 1)):
					near[y * W + x] = 1
	_part("corridor", part_us)
	return near


## Доля клеток пути p в коридоре near (_corridor) прежних путей; 0, если путь пуст
static func _share(p: PackedInt32Array, near: PackedByteArray) -> float:
	if p.is_empty():
		return 0.0
	var k := 0
	for i: int in p:
		if near[i] != 0:
			k += 1
	return float(k) / p.size()


## Дома, которые стоят на мосту, в туннеле или вплотную к ним, убираются: иначе в них упрётся дорога
static func _clear_huts(w: WorldData) -> void:
	var W := w.W
	for st in w.settlements:
		var keep: Array[HutData] = []
		for u in st.huts:
			var free := StageLandmarks.structure_clear(w, Vector2(u.x, u.y), u.a, u.t)
			# Полоса дороги должна оставаться свободной и внутри деревни, не только на мостах.
			var half := SettlementSets.half_of(u.t) + Vector2(0.4, 0.4)
			var basis := Basis(Vector3.UP, u.a)
			for dz: float in [-1.0, 0.0, 1.0]:
				for dx: float in [-1.0, 0.0, 1.0]:
					var offset := basis * Vector3(dx * half.x, 0, dz * half.y) / GameConfig.TILE
					var x := clampi(floori(u.x + offset.x), 0, w.W - 1)
					var y := clampi(floori(u.y + offset.z), 0, w.H - 1)
					if w.path_mask[y * W + x] >= 2:
						free = false
			if free:
				keep.append(u)
		st.huts = keep


## Мокрая клетка: море, озеро или река
static func _wet(w: WorldData, i: int) -> bool:
	return w.ocean[i] != 0 or w.lake[i] != 0 or w.river_cells()[i] != 0


## Мосты и туннели на пути между поселениями: заносит их в w.bridges и w.tunnels и возвращает путь,
## в котором участки под ними заменены прямыми. Мост — только через воду между берегами;
## туннель — сквозь хребет выше RISE. У обоих уклон не круче GRADE.
## Тропа (road = false) переходит реку не шире FORD_LEN вброд. Новый туннель заменяется обходом горы, если обход
## не длиннее DETOUR_PREFER длин туннеля (cost — стоимость, по которой ищется обход).
## Клетки осей мостов и туннелей отмечаются в state.on_axis.
static func _make_checkpoint(w: WorldData, finder: Pathfinder, state: Dictionary) -> Dictionary:
	var part_us := Time.get_ticks_usec()
	var surface: Heightfield = state.get("surface")
	var checkpoint := {bridges = w.bridges.duplicate(), tunnels = w.tunnels.duplicate(), mask = w.path_mask.duplicate(),
		heights = finder.heights.duplicate(), links = finder.links.duplicate(), on_axis = state.on_axis.duplicate(),
		hv = surface.hv.duplicate() if surface != null else PackedFloat32Array()}
	# Число и объём снимков (P0 аудита 29.10): основа решения о журнале изменений вместо копий.
	state.checkpoints = int(state.get("checkpoints", 0)) + 1
	state.checkpoint_bytes = int(state.get("checkpoint_bytes", 0)) + checkpoint.mask.size() + checkpoint.links.size() \
		+ checkpoint.on_axis.size() + (checkpoint.heights.size() + checkpoint.hv.size()) * 4
	_part("checkpoint", part_us)
	return checkpoint


static func _structures(w: WorldData, p: PackedInt32Array, road: bool, finder: Pathfinder, cost: PackedFloat32Array, state: Dictionary, retries: int = 0, limit := ROAD_GRADE, accept := Callable()) -> PackedInt32Array:
	var part_us := Time.get_ticks_usec()
	# Неудачная связь не оставляет за собой мосты, выемки и разрешённые шаги по их осям.
	var ctx := {checkpoint = null, initial_links_empty = finder.links.is_empty()}
	var result := _build_structures(w, p, road, finder, cost, state, retries, ctx, limit)
	if not result.is_empty() and accept.is_valid() and not accept.call(result):
		result = PackedInt32Array()
	if result.is_empty():
		_restore_structures(w, finder, state, ctx)
	if retries == 0:
		_part("structures", part_us)
	return result


static func _restore_structures(w: WorldData, finder: Pathfinder, state: Dictionary, ctx: Dictionary) -> void:
	if ctx.checkpoint == null:
		if ctx.initial_links_empty:
			finder.links = PackedByteArray()
		return
	var part_us := Time.get_ticks_usec()
	var checkpoint: Dictionary = ctx.checkpoint
	ctx.checkpoint = null
	state.restores = int(state.get("restores", 0)) + 1
	w.bridges = checkpoint.bridges.duplicate()
	w.tunnels = checkpoint.tunnels.duplicate()
	w.path_mask = checkpoint.mask.duplicate()
	finder.heights = checkpoint.heights.duplicate()
	finder.links = PackedByteArray() if ctx.initial_links_empty else checkpoint.links.duplicate()
	state.on_axis = checkpoint.on_axis.duplicate()
	if state.has("surface"):
		var changed_ground: bool = state.surface.hv != checkpoint.hv
		state.surface.hv = checkpoint.hv.duplicate()
		var build_us := Time.get_ticks_usec()
		state.surface.build_structures()
		if changed_ground:
			_route_surface(finder, state.surface, finder.get_meta("route_width", RoadTuning.current().section.widths.road))
		_part("build_structures", build_us)
	_part("restore", part_us)


static func _build_structures(w: WorldData, p: PackedInt32Array, road: bool, finder: Pathfinder, cost: PackedFloat32Array, state: Dictionary, retries: int, ctx: Dictionary, limit := ROAD_GRADE) -> PackedInt32Array:
	if finder.links.is_empty():
		finder.links.resize(w.N)
	p = _explicit(w, p, state.on_axis)
	var W := w.W
	var n := p.size()
	# высоты, мокрые клетки и координаты вдоль пути в плоских массивах: в цикле так быстрее
	var hp := PackedFloat32Array()
	var wet := PackedByteArray()
	var xs := PackedInt32Array()
	var ys := PackedInt32Array()
	hp.resize(n)
	wet.resize(n)
	xs.resize(n)
	ys.resize(n)
	for k in n:
		var c := p[k]
		hp[k] = w.h[c]
		wet[k] = 1 if _wet(w, c) else 0
		if state.has("surface"):
			var surface: Heightfield = state.surface
			hp[k] = (surface.water_level[c] if wet[k] != 0 and surface.water_level[c] > -INF else surface.hv[c]) / GameConfig.HS
		xs[k] = c % W
		ys[k] = c / W
	# Наибольшая высота впереди: без хребта конец туннеля не ищется.
	var ahead_max := _window(hp, SPAN, true)
	var out := PackedInt32Array([p[0]])
	var i := 0
	while i < n - 1:
		# A built axis already has validated directional links. Consume those steps
		# before new-site tests, including when joining halfway along a dry approach.
		if state.on_axis[p[i]] != 0 and state.on_axis[p[i + 1]] != 0:
			var linked := false
			for direction in 8:
				if xs[i + 1] - xs[i] == Grid.DX[direction] and ys[i + 1] - ys[i] == Grid.DY[direction]:
					linked = (finder.links[p[i]] & (1 << direction)) != 0
					break
			if linked:
				out.append(p[i + 1])
				i += 1
				continue
		var j := -1
		var kind := "bridge"
		if wet[i + 1] != 0:
			j = i + 1
			# Не ставим опору на низкой отмели между двумя рукавами прямого перехода.
			while j < n and (wet[j] != 0 or j + 1 < n and wet[j + 1] != 0 and hp[j] <= hp[i] + GRADE \
					and Grid.segment_dist(xs[j], ys[j], xs[i], ys[i], xs[j + 1], ys[j + 1]) < 0.1):
				j += 1
			if j >= n or not road and j - i - 1 <= FORD_LEN and _river_only(w, p, i + 1, j, state.get("surface")):
				j = -1
			elif state.has("surface"):
				var shore := j
				# Короткая переправа между устойчивыми берегами; не вытягиваем мост
				# вдоль дороги до случайной далёкой клетки с подходящей высотой.
				var why := {}
				var site_us := Time.get_ticks_usec()
				var site := _bridge_site(state.surface, p, wet, i, shore, out, state.on_axis, why)
				_part("bridge_site", site_us)
				j = site.y
				if site.x >= 0:
					out.resize(out.size() - (i - site.x))
					i = site.x
				if j < 0:
					# Отчёт неудачных переправ: где (клетки берегов пути), ширина воды по пути и причины пар.
					why.at = [p[i], p[shore], shore - i - 1]
					state.site_failures = state.get("site_failures", [])
					state.site_failures.append(why)
					# Ревью дорожной сети 29.10, шаг 3: переправа — место с известным статусом. Вода, где мост не нашёл
					# места, закрыта до конца этапа (state.no_bridge) — та же, что закрывает объезд ниже. Следующие
					# связи её не ищут заново (_known_crossings). Поиск соседнего места на той же воде проверен
					# на стенде road_plan_test и отклонён: найденные пары берегов не принимались _bridge_site
					# из-за подхода пути, а широкое закрытие воды обрывало удачные связи.
					var closed := {}
					for k in range(i + 1, shore):
						for y in range(maxi(0, ys[k] - 3), mini(w.H, ys[k] + 4)):
							for x in range(maxi(0, xs[k] - 3), mini(W, xs[k] + 4)):
								if _wet(w, y * W + x) and state.on_axis[y * W + x] == 0:
									closed[y * W + x] = true
					var banned: Dictionary = state.get("no_bridge", {})
					banned.merge(closed)
					state.no_bridge = banned
					# Последняя неудача уже исчерпала запас объездов: ещё один A* не используется.
					if retries >= BRIDGE_RETRIES:
						state.failure = "bridge_site"
						return PackedInt32Array()
					var bypass := cost.duplicate()
					for c: int in closed:
						bypass[c] = INF
					# Новый переход ищется от начала связи: фиксированный крутой берег
					# не должен заставлять объезд карабкаться вверх сразу от воды.
					_restore_structures(w, finder, state, ctx)
					var q := _road_path(finder, bypass, p[0], p[-1], finder.use_corridor, limit) if road else _land_path(finder, bypass, p[0], p[-1], "trail")
					if not q.is_empty():
						return _build_structures(w, q, road, finder, bypass, state, retries + 1, ctx, limit)
					state.failure = "budget" if finder.search_budget == 0 else "bridge_site"
					return PackedInt32Array()
		elif hp[i + 1] > hp[i] and ahead_max[i] >= hp[i] + RISE:
			j = _span_end(hp, wet, xs, ys, i)
			while j > 0 and i + 1 < j - 2 and _span_end(hp, wet, xs, ys, i + 1) == j:
				out.append(p[i + 1])
				i += 1
			kind = "tunnel"
			if j > 0 and _same(w, w.tunnels, p[i], p[j], _key_cell(p, hp, wet, i, j)).is_empty():
				if _near_tunnel(w, p[i], p[j]) or _wet_near(w, p[i], p[j], TUNNEL_R) or _path_at_portal(w, p[i], p[j]):
					j = -1
		if j < 0:
			out.append(p[i + 1])
			i += 1
			continue
		var a := p[i]
		var b := p[j]
		var list: Array = w.tunnels if kind == "tunnel" else w.bridges
		var ends := _same(w, list, a, b, _key_cell(p, hp, wet, i, j))
		# к входу и от выхода уже построенного — по суше: если так не дойти, строится своё
		var to_a := PackedInt32Array()
		var from_b := PackedInt32Array()
		if not ends.is_empty():
			to_a = _link(w, finder, a, ends[0])
			from_b = _link(w, finder, ends[1], b)
			if a != ends[0] and to_a.is_empty() or ends[1] != b and from_b.is_empty() or _has_wet(w, to_a) or _has_wet(w, from_b):
				ends = []
				to_a = PackedInt32Array()
				from_b = PackedInt32Array()
		# Возможности дороги известны до сооружений (ревью дорожной сети 29.10, шаг 1): где туннели не
		# умеют сохранять и воспроизводить (области за краем плана), хребет только обходится. Без обхода
		# связь отвергается здесь, а не после целого пути с туннелем. Обход ничего не меняет — снимок не нужен.
		if kind == "tunnel" and ends.is_empty() and not state.get("tunnels", true):
			# Обход дороги — с пределами дороги: построитель не выравнивает подъём круче ROAD_LIMIT.
			var around := _detour(w, finder, cost, a, b, "road" if road else "trail", ROAD_LIMIT if road else TRAIL_GRADE)
			if around.is_empty():
				state.failure = "budget" if finder.search_budget == 0 else "tunnel"
				return PackedInt32Array()
			for k in range(1, around.size()):
				out.append(around[k])
			i = j
			continue
		# 16.11.2026: туннель или обход решает рельеф — обход, если он есть и не длиннее DETOUR_PREFER длин туннеля
		# (раньше они чередовались по очереди). Обход ничего не строит — снимок для него не нужен.
		if kind == "tunnel" and ends.is_empty():
			var q := _detour(w, finder, cost, a, b, "road" if road else "trail", ROAD_LIMIT if road else TRAIL_GRADE)
			if q.size() > 0 and _length(w, q) <= Grid.hypot(b % w.W - a % w.W, b / w.W - a / w.W) * DETOUR_PREFER:
				for k in range(1, q.size()):
					out.append(q[k])
				i = j
				continue
		# Повторно используемый мост тоже записывает on_axis, heights и links ниже.
		if ctx.checkpoint == null:
			ctx.checkpoint = _make_checkpoint(w, finder, state)
		if ends.is_empty():
			list.append(TunnelData.new(a, b) if kind == "tunnel" else BridgeData.new(a, b))
			_mark_cut(w, a, b, TUNNEL_R if kind == "tunnel" else BRIDGE_R)
			if state.has("surface"):
				var build_us := Time.get_ticks_usec()
				var changed: PackedInt32Array = state.surface.build_structures()
				if not changed.is_empty():
					# Cuts include the ground outside both portals. Update search and width caches together.
					finder.terrain_changed()
					for c: int in changed:
						if state.on_axis[c] == 0: finder.heights[c] = state.surface.hv[c] / GameConfig.TILE
					_route_surface(finder, state.surface, finder.get_meta("route_width", RoadTuning.current().section.widths.road))
				_part("build_structures", build_us)
			ends = [a, b]
		# дорога, слившаяся с прежней, проходит по уже построенному
		out.append_array(to_a)
		var line := Grid.line_cells(ends[0] % W, ends[0] / W, ends[1] % W, ends[1] / W, W)
		var dx: int = ends[1] % W - ends[0] % W
		var dy: int = ends[1] / W - ends[0] / W
		var length_sq := maxf(dx * dx + dy * dy, 1.0)
		finder.terrain_changed()
		for k in line.size():
			state.on_axis[line[k]] = 1
			# Следующие пути оценивают настил/пол, а не скрытое под сооружением дно или хребет.
			var along: float = (line[k] % W - ends[0] % W) * dx + (line[k] / W - ends[0] / W) * dy
			finder.heights[line[k]] = lerpf(w.h[ends[0]], w.h[ends[1]], along / length_sq) * HEIGHT_SCALE
			if k > 0:
				# У диагонального настила боковые клетки могут быть водой или стеной.
				# Разрешается только фактический шаг вдоль оси, без боковых входов.
				for direction in 8:
					if line[k] % W - line[k - 1] % W == Grid.DX[direction] and line[k] / W - line[k - 1] / W == Grid.DY[direction]:
						finder.links[line[k - 1]] |= 1 << direction
					if line[k - 1] % W - line[k] % W == Grid.DX[direction] and line[k - 1] / W - line[k] / W == Grid.DY[direction]:
						finder.links[line[k]] |= 1 << direction
				out.append(line[k])
		out.append_array(from_b)
		i = j
	return _no_backtrack(out)


## Ищем ближайшую пару берегов, а не первый подходящий дальний конец.
## Не меняем уже принятую ось или путь до текущего подхода.
## why (необязательно) получает число отвергнутых пар по причинам _bridge_problem и "dry" (не над водой).
static func _bridge_site(surface: Heightfield, p: PackedInt32Array, wet: PackedByteArray,
		start: int, shore: int, out: PackedInt32Array, on_axis: PackedByteArray, why: Variant = null) -> Vector2i:
	var starts := PackedInt32Array()
	for back in range(BRIDGE_APPROACH + 1):
		var a := start - back
		if a < 0 or out.size() <= back or out[-1 - back] != p[a] or wet[a] != 0:
			break
		if back > 0 and on_axis[p[a]] != 0:
			break
		starts.append(a)
	# Шаг 5 ревью (замер на стенде): из 8 тыс. пар 7,2 тыс. отвергают концы (перепад, въезд) — несколько точек,
	# а проверка воды под пролётом шла первой и стоила 5,4 из 8 с. Порядок проверок — от дешёвых: концы, вода,
	# пролёт; все проверки — чистые функции, поэтому ответ тот же. С рельефом генерации концы и вода для всех пар
	# считаются на C# (FastGrid.BridgeCandidates — копии), пролёт с чужими настилами и стенами — здесь,
	# от коротких пар к длинным: первая годная — та же самая короткая, что выбирал полный перебор.
	var probe: Object = surface.fast_water()
	if probe != null:
		var found: PackedInt32Array = probe.BridgeCandidates(p, starts, shore, SPAN, BRIDGE_APPROACH, wet, surface.world.W,
			GameConfig.TILE, GRADE * HEIGHT_SCALE, BRIDGE_LANDING_GAP, Heightfield.BRIDGE_HALF)
		if why is Dictionary:
			for k in 4:
				if found[k] > 0: why[["grade", "landing_water", "landing_gap", "dry"][k]] = found[k]
		var order: Array = []
		for k in range(4, found.size(), 2):
			var a := found[k]
			var b := found[k + 1]
			order.append([Grid.hypot(p[b] % surface.world.W - p[a] % surface.world.W, p[b] / surface.world.W - p[a] / surface.world.W), k, a, b])
		order.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0] or x[0] == y[0] and x[1] < y[1])
		for pair: Array in order:
			var s := _bridge_axis(surface, p[pair[2]], p[pair[3]])
			# Земля и вода пролёта — сначала на C# (с запасом на последний знак): явно негодный пролёт отвергается там.
			var problem := "ground" if not probe.BridgeSpanGround(s.ax, s.az, s.ay, s.bx, s.bz, s.by, s.ux, s.uz, s.len, s.half,
				s.arch, Heightfield.BRIDGE_SECTION) else _bridge_span(surface, s)
			if problem.is_empty():
				return Vector2i(pair[2], pair[3])
			if why is Dictionary: why[problem] = int(why.get(problem, 0)) + 1
		return Vector2i(-1, -1)
	var best := Vector2i(-1, -1)
	var score := INF
	for a: int in starts:
		for b in range(shore, mini(p.size(), mini(shore + BRIDGE_APPROACH + 1, a + SPAN))):
			if wet[b] != 0:
				continue
			var length := Grid.hypot(p[b] % surface.world.W - p[a] % surface.world.W,
				p[b] / surface.world.W - p[a] / surface.world.W)
			if length >= score:
				continue
			var problem := "same"
			if p[a] != p[b]:
				var s := _bridge_axis(surface, p[a], p[b])
				problem = _bridge_ends(surface, s)
				if problem.is_empty():
					problem = "dry" if not _crosses_water(surface, p[a], p[b]) else _bridge_span(surface, s)
			if not problem.is_empty():
				if why is Dictionary: why[problem] = int(why.get(problem, 0)) + 1
				continue
			best = Vector2i(a, b)
			score = length
	return best


## Маска реки включает сухой берег; мост нужен над самой водой, а не над маской.
static func _crosses_water(surface: Heightfield, a: int, b: int) -> bool:
	var s := surface._axis(a, b, false)
	for k in range(1, ceili(s.len)):
		if surface.depth_at(s.ax + s.ux * k, s.az + s.uz * k) > 0.3:
			return true
	return false


## Тот же настил, что в игре: пологий, выше воды и земли, с доступными подходами.
static func _bridge_clear(surface: Heightfield, a: int, b: int) -> bool:
	return _bridge_problem(surface, a, b).is_empty()


## Почему настил a–b не встаёт ("" — встаёт): same, grade (перепад концов), landing (край въезда над водой
## или не на уровне настила), ground (земля выше настила в пролёте), deck (чужой настил рядом),
## wall (стена на оси), water (вода выше настила). Причины нужны отчёту неудачных переправ (шаг 3 ревью).
static func _bridge_problem(surface: Heightfield, a: int, b: int) -> String:
	if a == b:
		return "same"
	var s := _bridge_axis(surface, a, b)
	var problem := _bridge_ends(surface, s)
	return problem if not problem.is_empty() else _bridge_span(surface, s)


## Ось настила a–b с высотами концов (земля у концов).
static func _bridge_axis(surface: Heightfield, a: int, b: int) -> Dictionary:
	var s := surface._axis(a, b, false)
	s.ay = surface.ground_at(s.ax, s.az)
	s.by = surface.ground_at(s.bx, s.bz)
	return s


## Концы настила: перепад и въезды (несколько точек — дешёвая часть _bridge_problem).
static func _bridge_ends(surface: Heightfield, s: Dictionary) -> String:
	if absf(s.by - s.ay) > GRADE * HEIGHT_SCALE * s.len:
		return "grade"
	# Концы моста не должны попадать на узкий мыс: проверяем сушу под обоими краями
	# настила. Иначе центр касается берега, а большая часть въезда нависает над водой.
	for end in 2:
		var t: float = 0.0 if end == 0 else s.len
		var deck: float = s.ay if end == 0 else s.by
		for side in [-1.0, 0.0, 1.0]:
			var x: float = s.ax + s.ux * t - s.uz * side * s.half
			var z: float = s.az + s.uz * t + s.ux * side * s.half
			if surface.depth_at(x, z) > 0.3:
				return "landing_water"
			var gap := absf(surface.ground_at(x, z) - deck)
			if gap > BRIDGE_LANDING_GAP:
				return "landing_gap_%s" % ("0.5" if gap <= 0.5 else ("1" if gap <= 1.0 else ("2" if gap <= 2.0 else "more")))
	return ""


## Пролёт: земля, чужие настилы, стены и вода вдоль оси (дорогая часть _bridge_problem).
static func _bridge_span(surface: Heightfield, s: Dictionary) -> String:
	for k in range(-2, ceili(s.len) + 3):
		var t := clampf(float(k), -2.0, s.len + 2.0)
		var deck := surface.level(s, t)
		for side in [-1.0, 0.0, 1.0]:
			var x: float = s.ax + s.ux * t - s.uz * side * (s.half + 0.8)
			var z: float = s.az + s.uz * t + s.ux * side * (s.half + 0.8)
			var ground := surface.ground_at(x, z)
			if t > 1.0 and t < s.len - 1.0 and ground > deck + 0.3:
				return "ground"
			var other := surface.deck_at(x, z, INF)
			if other > -INF and absf(other - deck) > 0.3 and absf(other - deck) < Heightfield.TUNNEL_HEIGHT:
				return "deck"
			if side == 0.0:
				if surface.wall_at(x, z, maxf(deck, ground), 0.5):
					return "wall"
				var depth := surface.depth_at(x, z)
				if depth > 0.3 and ground + depth > deck - 0.1:
					return "water"
	return ""


## Путь p без возвратов на шаг назад (A, B, A -> A): они остаются, когда вход уже построенного моста
## или туннеля лежит позади точки, где путь к нему свернул
static func _no_backtrack(p: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for c: int in p:
		var n := out.size()
		if n >= 2 and out[n - 2] == c:
			out.resize(n - 1)
		else:
			out.append(c)
	return out


## Безопасный подход по суше к готовому сооружению (без a); пустой, если подхода нет.
static func _link(w: WorldData, finder: Pathfinder, a: int, b: int) -> PackedInt32Array:
	if a == b:
		return PackedInt32Array()
	var q := finder.find_path(w.cost, a, b, RoadTuning.current().routing.climb_costs.road, ROAD_GRADE)
	if q.size() == 0 or q.size() > REUSE_R * 3.0:
		return PackedInt32Array()
	return q.slice(1)


## Есть ли в клетках p вода (море, озеро, река)
static func _has_wet(w: WorldData, p: PackedInt32Array) -> bool:
	for c: int in p:
		if _wet(w, c):
			return true
	return false


## Клетка, которую пересекает участок пути p[i..j] под мостом или туннелем: середина воды, дно оврага
## или верх хребта. Уже построенное подходит этому участку, только если проходит над ней (_same)
static func _key_cell(p: PackedInt32Array, hp: PackedFloat32Array, wet: PackedByteArray, i: int, j: int) -> int:
	if wet[i + 1] != 0:
		return p[(i + j) / 2]
	var up := hp[i + 1] > hp[i]
	var best := i + 1
	for k in range(i + 1, j):
		if hp[k] > hp[best] if up else hp[k] < hp[best]:
			best = k
	return p[best]


## Обход горы от a до b вместо туннеля: путь в окрестности отрезка a–b, не выше входов больше чем
## на 0.7 RISE (около 18 м), без воды и не длиннее DETOUR прямых расстояний; пустой, если такого нет
static func _detour(w: WorldData, finder: Pathfinder, cost: PackedFloat32Array, a: int, b: int,
		kind := "trail", limit := TRAIL_GRADE) -> PackedInt32Array:
	var W := w.W
	var ax := a % W
	var ay := a / W
	var bx := b % W
	var by := b / W
	var d := Grid.hypot(bx - ax, by - ay)
	var m := ceili(d * 2.0)   # обход ищется не дальше двух длин туннеля от входов
	var top := maxf(w.h[a], w.h[b]) + RISE * 0.7
	var c := PackedFloat32Array()
	c.resize(w.N)
	c.fill(INF)
	for y in range(maxi(0, mini(ay, by) - m), mini(w.H, maxi(ay, by) + m + 1)):
		for x in range(maxi(0, mini(ax, bx) - m), mini(W, maxi(ax, bx) + m + 1)):
			var k := y * W + x
			if w.h[k] <= top and not _wet(w, k):
				c[k] = cost[k]
	var q := _land_path(finder, c, a, b, kind, limit)
	if _length(w, q) > d * DETOUR:
		return PackedInt32Array()
	return q


## Проходит ли прежний путь (path_mask) поперёк выемки будущего туннеля a–b (с 3.0 — у входов, с 6.9 — по всей
## длине): выемка опускает рельеф до пола, и путь упирался бы в стену у портала или в провал над туннелем
static func _path_at_portal(w: WorldData, a: int, b: int) -> bool:
	var W := w.W
	var ax := a % W + 0.5
	var ay := a / W + 0.5
	var bx := b % W + 0.5
	var by := b / W + 0.5
	for y in range(maxi(0, floori(minf(ay, by) - TUNNEL_R)), mini(w.H, ceili(maxf(ay, by) + TUNNEL_R))):
		for x in range(maxi(0, floori(minf(ax, bx) - TUNNEL_R)), mini(W, ceili(maxf(ax, bx) + TUNNEL_R))):
			var da := Grid.hypot(x + 0.5 - ax, y + 0.5 - ay)
			var db := Grid.hypot(x + 0.5 - bx, y + 0.5 - by)
			if w.path_mask[y * W + x] >= 2 and minf(da, db) > 0.5 and Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) <= TUNNEL_R:
				return true
	return false


## Есть ли вода (море, озеро, река) в клетках ближе r к отрезку между центрами клеток a и b
## (у туннеля это его выемка: вода в ней стояла бы у портала и на полу)
static func _wet_near(w: WorldData, a: int, b: int, r: float) -> bool:
	var W := w.W
	var ax := a % W + 0.5
	var ay := a / W + 0.5
	var bx := b % W + 0.5
	var by := b / W + 0.5
	for y in range(maxi(0, floori(minf(ay, by) - r)), mini(w.H, ceili(maxf(ay, by) + r))):
		for x in range(maxi(0, floori(minf(ax, bx) - r)), mini(W, ceili(maxf(ax, bx) + r))):
			if Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) <= r and _wet(w, y * W + x):
				return true
	return false


## Только река (не море и не озеро), без крутого перепада русла: возможен брод p[from..to)
static func _river_only(w: WorldData, p: PackedInt32Array, from: int, to: int, surface: Heightfield = null) -> bool:
	for k in range(from, to):
		if w.ocean[p[k]] != 0 or w.lake[p[k]] != 0 or w.slope[p[k]] > FORD_SLOPE:
			return false
	if surface != null:
		for k in range(maxi(1, from), mini(p.size(), to + 1)):
			var a := Vector2(p[k - 1] % w.W + 0.5, p[k - 1] / w.W + 0.5) * GameConfig.TILE
			var b := Vector2(p[k] % w.W + 0.5, p[k] / w.W + 0.5) * GameConfig.TILE
			var steps := maxi(1, ceili(a.distance_to(b) / 0.5))
			for step in steps + 1:
				var q := a.lerp(b, float(step) / steps)
				if surface.depth_at(q.x, q.y) > GameConfig.FORD_DEPTH - 0.15:
					return false
	return true


## Наибольшее (big) или наименьшее значение v[i..i+span] для каждого i (очередь с монотонными значениями)
static func _window(v: PackedFloat32Array, span: int, big: bool) -> PackedFloat32Array:
	var n := v.size()
	var out := PackedFloat32Array()
	out.resize(n)
	var q := PackedInt32Array()
	q.resize(n)
	var head := 0
	var tail := 0
	for i in range(n - 1, -1, -1):
		while tail > head and (v[q[tail - 1]] <= v[i] if big else v[q[tail - 1]] >= v[i]):
			tail -= 1
		q[tail] = i
		tail += 1
		while q[head] > i + span:
			head += 1
		out[i] = v[q[head]]
	return out


## Уже построенный мост или туннель из list с концами у клеток a и b (каждый не дальше REUSE_R, в любом
## порядке) и осью над клеткой key, которую пересекает путь (_key_cell): [его конец у a, его конец у b] или
## пустой массив. Сооружение, которое лишь проходит рядом (например, мост через соседнюю петлю реки),
## не годится: путь по нему пересекал бы воду или гору не там, где построено
static func _same(w: WorldData, list: Array, a: int, b: int, key: int) -> Array:
	var W := w.W
	for s: EntityRecord in list:
		if Grid.segment_dist(key % W + 0.5, key / W + 0.5, s.a % W + 0.5, s.a / W + 0.5, s.b % W + 0.5, s.b / W + 0.5) > KEY_R:
			continue
		# у короткого моста оба порядка концов проходят REUSE_R: берётся тот, где концы ближе к a и b.
		# До 6.9 брался первый, путь шёл к дальнему концу через воду, и рядом строился второй такой же мост
		var best: Array = []
		var best_d := INF
		for e in [[s.a, s.b], [s.b, s.a]]:
			var ea: int = e[0]
			var eb: int = e[1]
			var da := Grid.hypot(ea % W - a % W, ea / W - a / W)
			var db := Grid.hypot(eb % W - b % W, eb / W - b / W)
			if da <= REUSE_R and db <= REUSE_R and da + db < best_d:
				best = e
				best_d = da + db
		if not best.is_empty():
			return best
	return []


## Проходит ли отрезок a–b ближе 2 * TUNNEL_R + 1 клеток к уже прорезанному туннелю или пересекает его
static func _near_tunnel(w: WorldData, a: int, b: int) -> bool:
	var W := w.W
	var ax: float = a % W
	var ay: float = a / W
	var bx: float = b % W
	var by: float = b / W
	for t: TunnelData in w.tunnels:
		var cx: float = t.a % W
		var cy: float = t.a / W
		var dx: float = t.b % W
		var dy: float = t.b / W
		# отрезки пересекаются, если концы каждого лежат по разные стороны от другого
		var s1 := (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
		var s2 := (bx - ax) * (dy - ay) - (by - ay) * (dx - ax)
		var s3 := (dx - cx) * (ay - cy) - (dy - cy) * (ax - cx)
		var s4 := (dx - cx) * (by - cy) - (dy - cy) * (bx - cx)
		if s1 * s2 < 0.0 and s3 * s4 < 0.0:
			return true
		var d := minf(minf(Grid.segment_dist(ax, ay, cx, cy, dx, dy), Grid.segment_dist(bx, by, cx, cy, dx, dy)),
			minf(Grid.segment_dist(cx, cy, ax, ay, bx, by), Grid.segment_dist(dx, dy, ax, ay, bx, by)))
		if d < TUNNEL_R * 2.0 + 1.0:
			return true
	return false


## Конец туннеля, который начинается в p[i]:
## первая клетка, после которой путь уже перевалил через хребет, или -1
static func _span_end(hp: PackedFloat32Array, wet: PackedByteArray, xs: PackedInt32Array, ys: PackedInt32Array, i: int) -> int:
	var ha := hp[i]
	var ax := xs[i]
	var ay := ys[i]
	var lim := RISE_LEN
	var lim2 := lim * lim
	var top := -INF
	for j in range(i + 1, mini(hp.size(), i + SPAN + 1)):
		if wet[j] != 0:
			return -1
		var hb := hp[j]
		var dx := xs[j] - ax
		var dy := ys[j] - ay
		var d2 := dx * dx + dy * dy
		if d2 > lim2:
			return -1
		if j >= i + 3 and (hb - ha) * (hb - ha) <= GRADE * GRADE * d2:
			if top - maxf(ha, hb) >= RISE:
				return j
		top = maxf(top, hb)
	return -1


## Клетки у оси моста или туннеля (ближе r) — дорога: по ней идут быстро, деревья в выемке туннеля не растут
static func _mark_cut(w: WorldData, a: int, b: int, r: float) -> void:
	var W := w.W
	var mask := w.path_mask
	var ax := a % W + 0.5
	var ay := a / W + 0.5
	var bx := b % W + 0.5
	var by := b / W + 0.5
	for y in range(maxi(0, floori(minf(ay, by) - r)), mini(w.H, ceili(maxf(ay, by) + r))):
		for x in range(maxi(0, floori(minf(ax, bx) - r)), mini(W, ceili(maxf(ax, bx) + r))):
			if Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) <= r:
				mask[y * W + x] = 3   # дорога (как road в _add_trail)
	w.path_mask = mask


static func _key(a: int, b: int) -> String:
	return "%d:%d" % [a, b] if a < b else "%d:%d" % [b, a]


## Горные тропы ответвляются от ближайшего доступного пути людей, а не обязательно от поселения.
## Возвращает клетки осей мостов и туннелей (их же берут природные маршруты, RideRoutes).
static func _mountain_trails(w: WorldData, finder: Pathfinder, surface: Heightfield = null) -> PackedByteArray:
	var started_us := Time.get_ticks_usec()
	var nearest_us := 0
	var search_us := 0
	var add_us := 0
	var on_axis := PackedByteArray()
	on_axis.resize(w.N)
	for span: EntityRecord in w.bridges + w.tunnels:
		for c: int in Grid.line_cells(span.a % w.W, span.a / w.W, span.b % w.W, span.b / w.W, w.W):
			on_axis[c] = 1
	# С 3.1 горная тропа обходит крутые участки реки: на перепаде русла такой «брод» глубже,
	# чем кажется по одной клетке. Это последний поиск путей, дороги уже проложены по мостам
	for i: int in _unsafe_fords(w, surface, on_axis):
		w.cost[i] = INF
	w.generation_profile.mountain_fords_ms = (Time.get_ticks_usec() - started_us) / 1000.0
	# Сеть V2: горные тропы — ответвления к вершинам по правилам узлов (RoadNetworkV2.plan_spurs)
	if network_v2:
		var spur_us := Time.get_ticks_usec()
		RoadNetworkV2.plan_spurs(w, finder, [], PackedFloat32Array(), on_axis, surface, true)
		w.generation_profile.mountain_search_ms = (Time.get_ticks_usec() - spur_us) / 1000.0
		return on_axis
	var fast := finder.fast() # 9.7: ближайший путь к вершине ищет C# (FastGrid.NearestPath), тот же перебор
	var settle_d := _settle_dist(w)
	var forks := RoadForks.new(w, on_axis)
	for pk in w.peaks:
		var detail_us := Time.get_ticks_usec()
		var best := -1
		var bd := INF
		if w.path_mask[pk.i] >= 2:
			continue
		if fast != null:
			var found: PackedFloat64Array = fast.NearestPath(w.path_mask, w.cost, w.W, pk.x, pk.y)
			best = int(found[0])
			bd = found[1]
		else:
			for i in w.N:
				if w.path_mask[i] < 2 or w.cost[i] == INF:
					continue
				var d := Grid.hypot(i % w.W + 0.5 - pk.x, i / w.W + 0.5 - pk.y)
				if d < bd:
					bd = d
					best = i
		# 17.11.2026: ближайшая точка сети у самого поселения — тропа к вершине отходит от перегона, если там есть
		# точка не намного дальше (MOUNTAIN_DETOUR): без крюка ради этого
		if best >= 0 and settle_d[best] < EXIT_R:
			var limit := bd * MOUNTAIN_DETOUR + 4.0
			var alt := -1
			var ad := INF
			var r := ceili(limit)
			for y in range(maxi(0, int(pk.y) - r), mini(w.H, int(pk.y) + r + 1)):
				for x in range(maxi(0, int(pk.x) - r), mini(w.W, int(pk.x) + r + 1)):
					var i := y * w.W + x
					if w.path_mask[i] < 2 or w.cost[i] == INF or settle_d[i] < EXIT_R: continue
					var d := Grid.hypot(x + 0.5 - pk.x, y + 0.5 - pk.y)
					if d <= limit and d < ad:
						ad = d
						alt = i
			if alt >= 0:
				best = alt
				bd = ad
		nearest_us += Time.get_ticks_usec() - detail_us
		if best >= 0 and bd < w.W * 0.4:
			# Технический подъём остаётся крутым, но отвесная вершина не получает фиктивную тропу.
			detail_us = Time.get_ticks_usec()
			var p := _land_path(finder, w.cost, best, pk.i, "mountain", MOUNTAIN_GRADE)
			var moved := _from_quieter_fork(w, finder, forks, best, pk.i, p, "mountain", MOUNTAIN_GRADE, on_axis, settle_d,
				func(q: PackedInt32Array, _better: Callable) -> PackedInt32Array: return q)
			if not moved.is_empty(): p = moved
			search_us += Time.get_ticks_usec() - detail_us
			detail_us = Time.get_ticks_usec()
			if p.size() > 0:
				_add_trail(w, p, "mountain", PackedFloat32Array(), on_axis, surface)
			add_us += Time.get_ticks_usec() - detail_us
	w.generation_profile.mountain_nearest_ms = nearest_us / 1000.0
	w.generation_profile.mountain_search_ms = search_us / 1000.0
	w.generation_profile.mountain_add_ms = add_us / 1000.0
	return on_axis


## Клетки рек (не на осях сооружений), где брод небезопасен (_unsafe_ford). С 9.7 в сборке .NET полная
## проверка идёт только там, где C# нашёл воду глубже порога хотя бы в одной точке без учёта мостов
## (с мостами глубина только меньше): решения те же, проверка дешевле в десятки раз
static func _unsafe_fords(w: WorldData, surface: Heightfield, on_axis: PackedByteArray) -> PackedInt32Array:
	var river := w.river_cells()
	var cells := PackedInt32Array()
	for i in w.N:
		if river[i] != 0 and on_axis[i] == 0:
			cells.append(i)
	var probe: Object = surface.fast_water() if surface != null else null
	var deep := {}
	var sure := {}
	if probe != null:
		for i: int in probe.DeepFords(cells, GameConfig.FORD_DEPTH - 0.15 - 0.000001):
			deep[i] = true
		# Шаг 5 ревью: вода глубже порога с запасом в клетке без сооружений — тот же ответ, что у полной проверки
		# (depth_at с ногами отличается только на настилах), без девяти вызовов depth_at в GDScript.
		for i: int in probe.DeepFords(PackedInt32Array(deep.keys()), GameConfig.FORD_DEPTH - 0.15 + 0.000001):
			sure[i] = true
	var out := PackedInt32Array()
	for i in cells:
		if w.slope[i] > FORD_SLOPE or sure.has(i) and not surface._cells.has(i) \
				or (probe == null or deep.has(i)) and _unsafe_ford(w, surface, i):
			out.append(i)
	return out


## Глубина только читается: одного нарушения достаточно, чтобы закрыть клетку.
## Проверяем и точки между центрами клеток — там может проходить узкое глубокое русло.
static func _unsafe_ford(w: WorldData, surface: Heightfield, i: int) -> bool:
	if w.slope[i] > FORD_SLOPE:
		return true
	if surface != null:
		for dz in [-0.4, 0.0, 0.4]:
			for dx in [-0.4, 0.0, 0.4]:
				if surface.depth_at((i % w.W + 0.5 + dx) * GameConfig.TILE, (i / w.W + 0.5 + dz) * GameConfig.TILE, INF) > GameConfig.FORD_DEPTH - 0.15:
					return true
	return false
