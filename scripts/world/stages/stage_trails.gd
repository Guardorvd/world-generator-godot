class_name StageTrails
extends RefCounted
## Этап 7. Естественные тропы и дороги: поиск пути A* по стоимости местности.
## Пишет: w.cost (стоимость прохода), w.path_mask (1 — звериная тропа, 2 — тропа людей, 3 — дорога),
## w.trails [{kind: "animal" | "trail" | "mountain" | "road", pts}], w.bridges, w.tunnels;
## убирает дома поселений, которые оказались на мосту или в туннеле.
##
## Основная сеть связывает принятые поселения дорогами и местными тропами (остов), по стоимости, в которой вода
## проходима, но дорога (BRIDGE_COST за клетку): так поселения на разных берегах тоже связаны.
## Где дорога или тропа между поселениями пересекает воду, ставится мост,
## где переваливает через крутой хребет — туннель. Тропа переходит узкую речку вброд, без моста;
## сухие впадины дорога проходит по рельефу, без декоративных мостов.
## Туннели и обходы горы чередуются: после туннеля следующий хребет путь по возможности обходит
## понизу (_detour), после обхода — снова туннель. Высоты здесь в единицах w.h (1 = 260 м).
## Путь, который пересекает воду или хребет там же, где уже построен мост или туннель (концы рядом,
## _same), проходит по нему: к его входу и от выхода — короткими путями по суше.
## Дополнительные тропы сокращают обход по сети или предлагают другой проход по рельефу;
## ответвления ведут к берегам и вершинам, без заданного количества связей (_second_ways).

const Topology := preload("res://scripts/world/road_topology.gd")

const PROGRESS := 0.55
const LABEL := "Прокладка звериных троп"

const BRIDGE_COST := 30.0   # стоимость клетки воды для дороги: дорога обходит воду, если обход не слишком длинный
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
const ALT_LEN := 2.0        # второй путь не длиннее стольких первых
const BRANCH_LEN := 3.0     # тропа к берегу не длиннее стольких прямых расстояний
const SHORTCUT := 1.25      # новая связь сокращает существующий обход хотя бы на пятую часть
const RELIEF_CHOICE := 0.02 # другой проход отличается высотой примерно на 5 м (единицы w.h)
const SHORE_MIN := 15       # береговой ориентир не ближе стольких клеток от поселения
const SHORE_MAX := 45       # и не дальше стольких
const AVOID_R := 3          # коридор вокруг прежнего пути, клеток: второй путь его избегает
const AVOID_MUL := 8.0      # во столько раз дороже клетки коридора
const AVOID_SHARE := 0.4    # второй путь идёт по коридору не больше чем такой долей клеток
const REUSE_R := 5.0        # путь идёт по уже построенному мосту или туннелю, если оба его конца не дальше стольких клеток
const KEY_R := 1.5          # и проходит не дальше стольких клеток от того, что пересекает путь (_key_cell)
const CROSS_GAP := 8.0      # 10.4: вода ближе стольких клеток к мосту закрыта для следующих путей — они сходятся к одной переправе
## Три характера езды без отдельных режимов: дорога, извилистый обход, техническая горная тропа.
const WIDTHS := {animal = 0.32, mountain = 0.42, trail = 0.55, road = 0.9}
const ROAD_CLIMB := 32.0
const TRAIL_CLIMB := 12.0
const MOUNTAIN_CLIMB := 4.0
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
	_build_cost(w)
	var detail_us := Time.get_ticks_usec()
	w.generation_profile.cost_ms = (detail_us - started_us) / 1000.0
	w.path_mask = PackedByteArray()
	w.path_mask.resize(w.N)
	w.trails = []
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
	_route_surface(finder, surface, WIDTHS.road, "corridor_road_ms")
	step.call(0.66, "Прокладка троп между поселениями")
	_settlement_trails(w, finder, surface, step)
	_route_surface(finder, surface, WIDTHS.mountain, "corridor_mountain_ms")
	step.call(0.74, "Прокладка горных троп")
	detail_us = Time.get_ticks_usec()
	var on_axis := _mountain_trails(w, finder, surface)
	w.generation_profile.mountain_trails_ms = (Time.get_ticks_usec() - detail_us) / 1000.0
	# С 07.11.2026: природные велосипедные маршруты — спуски между точками готовой сети тем же поиском (RideRoutes)
	step.call(0.76, "Природные велосипедные маршруты")
	RideRoutes.run(w, finder, surface, on_axis)
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
	finder.release()


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
const SIDE_MUL := 1.3   # клетка рядом с участком (не на нём) дороже свободной земли: поиск идёт по участку или уходит
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
static func _add_trail(w: WorldData, path: PackedInt32Array, kind: String, road_cost: PackedFloat32Array = PackedFloat32Array(),
		on_axis: PackedByteArray = PackedByteArray(), surface: Heightfield = null, smooth_kind := "", changed_lines: Variant = null, corridor := Callable()) -> Array:
	var part_us := Time.get_ticks_usec()
	_net_ready(w)
	path = _explicit(w, path, on_axis)
	var width: float = WIDTHS[kind]
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
		for piece: Dictionary in _pieces(path, owner, w.W):
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
			var line_kind := kind if smooth_kind.is_empty() else smooth_kind
			var line := _road_line(w, pts, on_axis, surface, line_kind, joins, corridor) if surface != null else Grid.chaikin(pts, 3)
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
		w.generation.road_owner = owner
	_trodden(w, path, kind, road_cost)
	var protect_us := Time.get_ticks_usec()
	_protect_structures(w, road_cost)
	_part("protect_structures", protect_us)
	_part("add_trail", part_us)
	return added


## Протоптанный путь дешевле: следующие маршруты идут по нему. Клетки рядом с участком сети (не на нём) один раз
## дорожают в SIDE_MUL раз: соседняя клетка больше не тянет поиск идти вплотную параллельно (раньше она дешевела).
static func _trodden(w: WorldData, path: PackedInt32Array, kind: String, road_cost: PackedFloat32Array) -> void:
	var cost := w.cost
	var cheaper := 0.6 if kind == "animal" else 0.35
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
					cost[n] *= SIDE_MUL
				if both and road_cost[n] != INF:
					road_cost[n] *= SIDE_MUL
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
			out.append({cells = path.slice(a, b + 1), anchored = [k > 0, e < n - 1]})
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


## Подбор дуг в коридоре исходной оси. Прямые участки дают место для захода на поворот.
const TURN_CORRIDOR := 0.65 # клеток от исходной оси
const TURN_SPEED := {"road": 5.0, "trail": 4.0, "mountain": 3.2} # м/с
const TURN_ACCEL := {"road": 5.4, "trail": 6.0, "mountain": 6.8} # м/с², запас на поворот и торможение
const TURN_TRIMS := [Vector2(1, 1), Vector2(1, 0.72), Vector2(0.72, 1),
	Vector2(0.72, 0.72), Vector2(0.52, 0.72), Vector2(0.72, 0.52), Vector2(0.52, 0.52),
	Vector2(0.38, 0.52), Vector2(0.52, 0.38), Vector2(0.38, 0.38)]


static func _road_line(w: WorldData, pts: Array, on_axis: PackedByteArray, surface: Heightfield,
		kind := "road", joins := {}, corridor := Callable()) -> Array:
	if pts.size() < 2:
		return pts
	var fixed := PackedByteArray()
	fixed.resize(pts.size())
	if not on_axis.is_empty():
		for k in pts.size():
			var p: Dictionary = pts[k]
			if _road_axis(w, on_axis, Vector2(p.x, p.y)):
				for j in range(maxi(0, k - 2), mini(pts.size(), k + 3)):
					fixed[j] = 1
	var bends: Array = [pts[0]]
	var pins := PackedByteArray([fixed[0]])
	for k in range(1, pts.size() - 1):
		var a := Vector2(pts[k - 1].x, pts[k - 1].y)
		var b := Vector2(pts[k].x, pts[k].y)
		var c := Vector2(pts[k + 1].x, pts[k + 1].y)
		if fixed[k] != 0 or pts[k].w != pts[k - 1].w or pts[k].w != pts[k + 1].w \
				or absf((b - a).normalized().angle_to((c - b).normalized())) > 0.001:
			bends.append(pts[k])
			pins.append(fixed[k])
	bends.append(pts[-1])
	pins.append(fixed[-1])

	var rules := {
		grade = MOUNTAIN_GRADE if kind == "mountain" else (TRAIL_GRADE if kind == "trail" else ROAD_LIMIT),
		cross = MOUNTAIN_GRADE if kind == "mountain" else BENCH_CROSS,
		speed = TURN_SPEED[kind], accel = TURN_ACCEL[kind],
		probe = surface.fast_water(), axis = on_axis, corridor = corridor,
	}
	var start := _road_approach(surface, bends[0], bends[1], joins.get(0, {}), rules) if pins[0] == 0 else []
	var finish := _road_approach(surface, bends[-1], bends[-2], joins.get(1, {}), rules) if pins[-1] == 0 else []
	var out: Array = [bends[0]] if start.is_empty() else start
	var k := 1
	while k < bends.size() - 1:
		var curve: Array = []
		if pins[k] == 0 and bends[k - 1].w == bends[k].w and bends[k + 1].w == bends[k].w:
			var a := Vector2(bends[k - 1].x, bends[k - 1].y)
			var b := Vector2(bends[k].x, bends[k].y)
			var c := Vector2(bends[k + 1].x, bends[k + 1].y)
			var last := k
			while last + 2 < bends.size() and last < k + 3 and pins[last + 1] == 0 \
					and bends[last + 2].w == bends[k].w:
				var next := Vector2(bends[last + 1].x, bends[last + 1].y)
				var prev := Vector2(bends[last].x, bends[last].y)
				if next.distance_to(prev) > 2.5:
					break
				last += 1
			var consumed := 0
			for end in range(last, k, -1):
				var path: Array = []
				for j in range(k - 1, end + 2):
					path.append(Vector2(bends[j].x, bends[j].y))
				curve = _road_bend_group(surface, path, bends[k].w, rules)
				if not curve.is_empty():
					consumed = end - k + 1
					break
			if consumed > 0:
				out.append_array(curve)
				k += consumed
				continue
			curve = _road_bend(surface, a, b, c, bends[k].w, rules)
		if curve.is_empty():
			out.append(bends[k])
		else:
			out.append_array(curve)
		k += 1
	if finish.is_empty():
		out.append(bends[-1])
	else:
		finish.reverse()
		out.append_array(finish)
	return _road_stations(out)


## Сохраняем вершины дуг и якоря; длинные прямые делим для профиля и покрытия.
static func _road_stations(points: Array) -> Array:
	var out: Array = [points[0]]
	for k in range(1, points.size()):
		var a: Dictionary = points[k - 1]
		var b: Dictionary = points[k]
		var length := Grid.hypot(b.x - a.x, b.y - a.y) * GameConfig.TILE
		var steps := ceili(length / 2.0)
		for j in range(1, steps):
			var t := float(j) / steps
			out.append({x = lerpf(a.x, b.x, t), y = lerpf(a.y, b.y, t), w = lerpf(a.w, b.w, t)})
		out.append(b)
	return out


static func _road_axis(w: WorldData, axis: PackedByteArray, p: Vector2) -> bool:
	var x := floori(p.x)
	var y := floori(p.y)
	return x < 0 or y < 0 or x >= w.W or y >= w.H or (not axis.is_empty() and axis[y * w.W + x] != 0)


## Объединяем короткие ступени решётки, если одна кривая помещается в коридоре.
static func _road_bend_group(surface: Heightfield, path: Array, width: float, rules: Dictionary) -> Array:
	var a: Vector2 = path[0]
	var b: Vector2 = path[1]
	var c: Vector2 = path[-2]
	var d: Vector2 = path[-1]
	var incoming := (b - a).normalized()
	var outgoing := (d - c).normalized()
	var axis := (d - a).normalized()
	var angle := absf(incoming.angle_to(outgoing))
	if angle > PI * 0.75:
		return []
	for j in range(1, path.size()):
		var direction: Vector2 = (path[j] - path[j - 1]).normalized()
		if axis.dot(direction) < 0.25:
			return []
	var speed: float = rules.speed * (0.62 if angle >= deg_to_rad(105.0) else 1.0)
	var handle := 3.0 * pow(cos(angle * 0.25), 2.0)
	for trim: Vector2 in [Vector2(1, 1), Vector2(0.72, 1), Vector2(1, 0.72), Vector2(0.72, 0.72)]:
		var p := b - incoming * minf(a.distance_to(b) * 0.49, 3.5) * trim.x
		var q := c + outgoing * minf(c.distance_to(d) * 0.49, 3.5) * trim.y
		var lead := p.distance_to(q) / handle
		var curve := _road_curve(surface, [p, p + incoming * lead, q - outgoing * lead, q], path, width, speed, rules)
		if not curve.is_empty():
			return curve
	return []


static func _road_bend(surface: Heightfield, a: Vector2, b: Vector2, c: Vector2, width: float, rules: Dictionary) -> Array:
	var incoming := (b - a).normalized()
	var outgoing := (c - b).normalized()
	var angle := absf(incoming.angle_to(outgoing))
	if angle < 0.04 or angle > PI - 0.04:
		return []
	var hairpin := angle >= deg_to_rad(105.0)
	var speed: float = rules.speed * (0.62 if hairpin else 1.0)
	var left := minf(a.distance_to(b) * 0.49, 3.0)
	var right := minf(b.distance_to(c) * 0.49, 3.0)
	var handle := 4.0 / 3.0 * tan(angle * 0.25) / tan(angle * 0.5)
	# У стеснённого поворота допускаем более медленный проход, сохраняя запас на уклоне.
	for factor: float in [1.0, 0.72, 0.55]:
		for trim: Vector2 in TURN_TRIMS:
			var l := left * trim.x
			var r := right * trim.y
			var p := b - incoming * l
			var q := b + outgoing * r
			var curve := _road_curve(surface, [p, p + incoming * l * handle, q - outgoing * r * handle, q],
				[a, b, c], width, speed * factor, rules)
			if not curve.is_empty():
				return curve
	return []


## У слияния держим различимый угол к основной дороге, у Т-образного узла выпрямляем въезд.
## Касание осей остаётся в закреплённой точке. Подход не выходит за половину первого отрезка.
static func _road_approach(surface: Heightfield, end: Dictionary, next: Dictionary, join: Dictionary, rules: Dictionary) -> Array:
	if join.is_empty() or end.w != next.w:
		return []
	var a := Vector2(end.x, end.y)
	var b := Vector2(next.x, next.y)
	var direction := (b - a).normalized()
	var host: Vector2 = join.tangent
	var side := signf(host.cross(direction))
	if side == 0.0:
		return []
	if host.dot(direction) < 0.0:
		host = -host
		side = -side
	var angle := absf(host.angle_to(direction))
	var target := deg_to_rad(30.0) if angle < deg_to_rad(30.0) else angle
	if angle >= deg_to_rad(60.0):
		target = PI * 0.5
	if absf(target - angle) < 0.04:
		return []
	var heading := host.rotated(side * target)
	for scale: float in [1.0, 0.8, 0.6]:
		var lead := minf(a.distance_to(b) * 0.49, 3.0) * scale
		var q := a + direction * lead
		var curve := _road_curve(surface, [a, a + heading * lead / 3.0, q - direction * lead / 3.0, q],
			[a, b], end.w, rules.speed * 0.72, rules)
		if not curve.is_empty():
			curve[0] = end
			return curve
	return []


static func _road_curve(surface: Heightfield, control: Array, corridor: Array, width: float, speed: float, rules: Dictionary) -> Array:
	var a: Vector2 = control[0]
	var b: Vector2 = control[1]
	var c: Vector2 = control[2]
	var d: Vector2 = control[3]
	var steps := maxi(8, ceili((a.distance_to(b) + b.distance_to(c) + c.distance_to(d)) / 0.25))
	var curve: Array = []
	var grade: float = rules.grade
	for k in steps + 1:
		var t := float(k) / steps
		var ab := a.lerp(b, t)
		var bc := b.lerp(c, t)
		var cd := c.lerp(d, t)
		var left := ab.lerp(bc, t)
		var right := bc.lerp(cd, t)
		var p := left.lerp(right, t)
		var tangent := (right - left) * 3.0
		var second := (cd - 2.0 * bc + ab) * 6.0
		var length := tangent.length()
		if length < 0.001:
			return []
		var curvature := absf(tangent.cross(second)) / (length * length * length * GameConfig.TILE)
		var lateral := speed * speed * curvature
		var brake_sq: float = rules.accel * rules.accel - lateral * lateral
		if brake_sq <= 0.0 or curvature * (width * GameConfig.TILE * 0.5 + 0.15) >= 1.0:
			return []
		grade = minf(grade, sqrt(brake_sq) / GameConfig.GRAVITY)
		var deviation := INF
		for j in range(1, corridor.size()):
			var closest := Geometry2D.get_closest_point_to_segment(p, corridor[j - 1], corridor[j])
			deviation = minf(deviation, p.distance_squared_to(closest))
		if deviation > TURN_CORRIDOR * TURN_CORRIDOR:
			return []
		var normal := tangent.orthogonal() * (width * 0.5 / length)
		for side: float in [-1.0, 0.0, 1.0]:
			if _road_axis(surface.world, rules.axis, p + normal * side):
				return []
		curve.append(_point(p, width))
	if rules.corridor.is_valid() and not rules.corridor.call(curve):
		return []
	for k in range(1, curve.size()):
		if not _road_segment(surface, curve[k - 1], curve[k], grade, rules.cross, rules.probe):
			return []
	return curve


## probe — Heightfield.fast_water(): та же проверка на C# (FastGrid.RoadSegment)
static func _road_segment(surface: Heightfield, a: Dictionary, b: Dictionary, max_grade := ROAD_LIMIT, max_cross := BENCH_CROSS, probe: Object = null) -> bool:
	if probe != null:
		return probe.RoadSegment(a.x, a.y, b.x, b.y, a.w, max_grade, max_cross)
	var dx: float = b.x - a.x
	var dy: float = b.y - a.y
	var length := Grid.hypot(dx, dy)
	if length < 0.00001:
		return true
	var steps := maxi(1, ceili(length / 0.1))
	var nx := -dy / length * float(a.w) * 0.5
	var ny := dx / length * float(a.w) * 0.5
	for side in [-1.0, 0.0, 1.0]:
		var previous := 0.0
		for k in steps + 1:
			var t := float(k) / steps
			var x: float = (a.x + dx * t + nx * side) * GameConfig.TILE
			var z: float = (a.y + dy * t + ny * side) * GameConfig.TILE
			var h := surface.ground_at(x, z)
			if surface.depth_at(x, z) > 0.3 or k > 0 and absf(h - previous) > max_grade * length * GameConfig.TILE / steps + 0.00001:
				return false
			previous = h
	# Поперёк стены ось может быть горизонтальной. Не срезаем туда безопасный поворот.
	for k in steps + 1:
		var t := float(k) / steps
		var x: float = (a.x + dx * t) * GameConfig.TILE
		var z: float = (a.y + dy * t) * GameConfig.TILE
		var across := absf(surface.ground_at(x + nx * GameConfig.TILE, z + ny * GameConfig.TILE) - surface.ground_at(x - nx * GameConfig.TILE, z - ny * GameConfig.TILE))
		if across > max_cross * float(a.w) * GameConfig.TILE + 0.00001:
			return false
	return true


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
		var p := finder.find_path(w.cost, s, best, TRAIL_CLIMB)
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

static func _settlement_trails(w: WorldData, finder: Pathfinder, surface: Heightfield, step: Callable = Callable()) -> void:
	var started := Time.get_ticks_msec()
	var st := w.settlements
	var n := st.size()
	w.bridges = []
	w.tunnels = []
	var road_cost := w.cost.duplicate()
	var state := {detour = w.seed_num % 2 == 1, on_axis = PackedByteArray(), surface = surface}
	state.on_axis.resize(w.N)
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
			road_cost[i] = BRIDGE_COST + edge_cost(_plan_edge_gap(w, i)) if reach[i] <= BRIDGE_REACH else INF
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
		var q := _connect_settlement(w, finder, road_cost, st[a].i, st[b].i, state)
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
	finder.use_corridor = true
	_route_surface(finder, surface, WIDTHS.trail, "corridor_trail_ms")
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
	var strong: Array = []
	for s in st.size():
		if EntityCodec.value(st[s], "importance", 1.0) >= 0.6: strong.append(s)
	var on_road := {}
	for s: int in strong:
		var via := {s: -1}
		var queue: Array = [s]
		var at := 0
		while at < queue.size():
			var c: int = queue[at]
			at += 1
			for l: Array in links[c]:
				if not via.has(l[0]):
					via[l[0]] = l[1]
					queue.append(l[0])
		for t: int in strong:
			if t <= s or not via.has(t): continue
			var c := t
			while via[c] >= 0:
				var k: int = via[c]
				on_road[k] = true
				c = paths[k][0] if paths[k][1] == c else paths[k][1]
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
	var road_pts: Array = [_point(cuts[0][1], WIDTHS.road)]
	for j in range(cuts[0][0], cuts[1][0]):
		road_pts.append(_point(Vector2(pts[j].x, pts[j].y), WIDTHS.road))
	road_pts.append(_point(cuts[1][1], WIDTHS.road))
	var parts: Array = []
	if k0 > 0:
		var head: Array = pts.slice(0, cuts[0][0])
		head.append(_point(cuts[0][1], WIDTHS.trail))
		parts.append([_dedupe(head), cells.slice(0, k0 + 1)])
	if k1 < cells.size() - 1:
		var tail: Array = [_point(cuts[1][1], WIDTHS.trail)]
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
	Grid.stamp_path(w.path_mask, w.W, w.H, record.pts, 3, WIDTHS.road * 0.5 - Grid.PATH_IN)


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
		a: int, b: int, state: Dictionary) -> PackedInt32Array:
	finder.window = Rect2i()
	var q := _connect_in_windows(w, finder, cost, a, b, state)
	finder.window = Rect2i()
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
	# Ревью дорожной сети 29.10: связь, которой нет даже при ROAD_LIMIT, отвергается без A*. Раньше такой
	# поиск обходил всю доступную область и тратил запас места, и следующие пары того же места
	# останавливались по запасу. Причина отказа — в state.failure (_count_failure).
	if not finder.can_reach(cost, a, b, ROAD_CLIMB, ROAD_LIMIT):
		state.failure = "unreachable"
		return PackedInt32Array()
	var limits: Array = [ROAD_GRADE, ROAD_LIMIT] if finder.can_reach(cost, a, b, ROAD_CLIMB, ROAD_GRADE) else [ROAD_LIMIT]
	var windows := _windows(finder, a, b)
	# С 9.9 запасной поиск (ROAD_LIMIT) идёт в фоне, пока проверяется первый путь: после неудачи
	# состояние восстановлено, и он с теми же входами. Совпадение входов (и окна) проверяет сам поиск.
	if limits.size() > 1:
		finder.window = windows[0]
		finder.prefetch(cost, a, b, ROAD_CLIMB, ROAD_LIMIT, cost_version)
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
static func _second_ways(w: WorldData, finder: Pathfinder, paths: Array, road_cost: PackedFloat32Array, state: Dictionary, step: Callable = Callable()) -> void:
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
			# Соседи по пространству: внутри круга с диаметром a–b нет другого поселения.
			var neighbor := true
			for s in st:
				if (s.x - st[a].x) * (s.x - st[b].x) + (s.y - st[a].y) * (s.y - st[b].y) < 0.0:
					neighbor = false
					break
			if neighbor:
				pairs.append([a, b, d])
	pairs.sort_custom(func(p: Array, q: Array) -> bool: return p[2] < q[2] if p[2] != q[2] else _key(p[0], p[1]) < _key(q[0], q[1]))
	w.generation_profile.second_ways = []
	var network := _network_cost(w)
	var near := _net_near(w)
	for index in pairs.size():
		if finder.search_budget == 0: break
		var e: Array = pairs[index]
		if step.is_valid():
			step.call(0.69 + 0.015 * index / maxi(1, pairs.size()), "Дополнительные тропы: %d/%d" % [index + 1, pairs.size()])
		var a: int = st[e[0]].i
		var b: int = st[e[1]].i
		var old := finder.find_path(network, a, b) if finder.can_reach(network, a, b) else PackedInt32Array()
		if old.is_empty():
			# С 9.8: соседи из разных сетей дорог (между ними река без места для моста) —
			# тропа между сетями: вброд, по мосту для тропы или в обход.
			var link := _land_path(finder, w.cost, a, b, TRAIL_CLIMB)
			var joint := _structures(w, link, false, finder, w.cost, state) if not link.is_empty() else link
			if not joint.is_empty():
				_note_way(w, "bridge_gap", _add_trail(w, joint, "trail", road_cost, state.on_axis, state.get("surface")))
				paths.append([e[0], e[1], joint, false, e[2]])
				network = _network_cost(w)
				near = _net_near(w)
			continue
		var old_len := _length(w, old)
		if old.is_empty() or old_len <= e[2] * SHORTCUT:
			continue
		var corr := _corridor(w, [old])
		var avoiding := _avoiding(w, _open_ends(w, corr, a, b))
		var p := _land_path(finder, avoiding, a, b, TRAIL_CLIMB)
		if p.is_empty() or _length(w, p) * SHORTCUT >= old_len or _share(p, corr) > AVOID_SHARE or not _new_ground(w, p) or not _adds_network(w, p, near):
			continue
		var q := _structures(w, p, false, finder, avoiding, state, 0, ROAD_GRADE,
			func(q: PackedInt32Array) -> bool: return _length(w, q) * SHORTCUT < old_len and _share(q, corr) <= AVOID_SHARE and _new_ground(w, q) and _adds_network(w, q, near))
		if q.is_empty():
			continue
		_note_way(w, "shortcut", _add_trail(w, q, "trail", road_cost, state.on_axis, state.get("surface")))
		paths.append([e[0], e[1], q, false, e[2]])
		network = _network_cost(w)
		near = _net_near(w)
	# Проверяем каждую основную связь; плоская копия соседней дороги сама по себе не повод для петли.
	var primary_paths := paths.duplicate()
	for index in primary_paths.size():
		if finder.search_budget == 0: break
		var e: Array = primary_paths[index]
		if not e[3]:
			continue
		if step.is_valid():
			step.call(0.705 + 0.015 * index / maxi(1, primary_paths.size()), "Обходные тропы: %d/%d" % [index + 1, primary_paths.size()])
		var corr := _corridor(w, [e[2]])
		var avoiding := _avoiding(w, _open_ends(w, corr, st[e[0]].i, st[e[1]].i))
		var p := _land_path(finder, avoiding, st[e[0]].i, st[e[1]].i, TRAIL_CLIMB)
		if p.is_empty() or _length(w, p) > _length(w, e[2]) * ALT_LEN or _share(p, corr) > AVOID_SHARE \
				or not _new_ground(w, p) or not _different_relief(w, p, e[2]) or not _adds_network(w, p, near) or _far_share(w, p, e[2]) < FAR_SHARE:
			continue
		var q := _structures(w, p, false, finder, avoiding, state, 0, ROAD_GRADE,
			func(q: PackedInt32Array) -> bool: return _length(w, q) <= _length(w, e[2]) * ALT_LEN and _share(q, corr) <= AVOID_SHARE and _new_ground(w, q) and _different_relief(w, q, e[2]) and _adds_network(w, q, near) and _far_share(w, q, e[2]) >= FAR_SHARE)
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
	for index in st.size():
		if finder.search_budget == 0: break
		var s: SettlementData = st[index]
		if step.is_valid():
			step.call(0.72 + 0.02 * index / maxi(1, st.size()), "Тропы к берегам: %d/%d" % [index + 1, st.size()])
		if corr_paths != all_paths.size():
			corr = _corridor(w, all_paths)
			corr_paths = all_paths.size()
		var shore_us := Time.get_ticks_usec()
		var t := _shore(w, s.i, corr)
		_part("shore", shore_us)
		if t >= 0:
			# Ответвление от общей сети: не строим отдельный длинный подход от каждого дома.
			var source := _nearest_path(w, t, SHORE_MAX)
			if source < 0:
				source = s.i # У единственного поселения ещё нет общей линии пути.
			var p := _land_path(finder, w.cost, source, t, TRAIL_CLIMB)
			var d := Grid.hypot(t % w.W - source % w.W, t / w.W - source / w.W)
			if not p.is_empty() and _length(w, p) <= d * BRANCH_LEN and _new_ground(w, p) and _adds_network(w, p, near):
				var q := _structures(w, p, false, finder, w.cost, state, 0, ROAD_GRADE,
					func(q: PackedInt32Array) -> bool: return _length(w, q) <= d * BRANCH_LEN and _new_ground(w, q) and _adds_network(w, q, near))
				if q.is_empty():
					continue
				_note_way(w, "shore", _add_trail(w, q, "trail", road_cost, state.on_axis, state.get("surface")))
				all_paths.append(q)
				near = _net_near(w)


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
static func _land_path(finder: Pathfinder, cost: PackedFloat32Array, a: int, b: int, climb: float, limit: float = TRAIL_GRADE) -> PackedInt32Array:
	if finder.search_budget == 0:
		return finder.find_path(cost, a, b, climb, limit)
	if not finder.can_reach(cost, a, b, climb, limit):
		return PackedInt32Array()
	return finder.find_path(cost, a, b, climb, limit)


## Земляные работы могут исправить край полотна; продольный обрыв ими не исправить.
## Вода доступна для сооружений; на суше полная ширина проверяется во всех попытках.
static func _road_path(finder: Pathfinder, cost: PackedFloat32Array, a: int, b: int, wide := true, limit := ROAD_GRADE, cost_version: int = -1) -> PackedInt32Array:
	finder.use_corridor = wide
	return finder.find_path(cost, a, b, ROAD_CLIMB, limit, cost_version)


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


## Ближайшая к клетке s клетка морского или озёрного берега от SHORE_MIN до SHORE_MAX клеток,
## не в коридоре near прежних путей; -1, если такой нет
static func _shore(w: WorldData, s: int, near: PackedByteArray) -> int:
	var W := w.W
	var sx := s % W
	var sy := s / W
	var best := -1
	var bd := INF
	for y in range(maxi(0, sy - SHORE_MAX), mini(w.H, sy + SHORE_MAX + 1)):
		for x in range(maxi(0, sx - SHORE_MAX), mini(W, sx + SHORE_MAX + 1)):
			var i := y * W + x
			var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
			if d < SHORE_MIN * SHORE_MIN or d >= bd or near[i] != 0 or w.cost[i] == INF or not _at_mouth(w, x, y):
				continue
			bd = d
			best = i
	return best


## 11.11.2026: у концов второй путь может идти по готовой сети — развилка в стороне от поселения, а не второе полотно
## рядом с первым от самого поселения (коридор избегания раньше отталкивал его сразу от общего конца).
const OPEN_END := 12.0 # клеток (48 м)


static func _open_ends(w: WorldData, near: PackedByteArray, a: int, b: int) -> PackedByteArray:
	var out := near.duplicate()
	var r := ceili(OPEN_END)
	for c: int in [a, b]:
		var cx := c % w.W
		var cy := c / w.W
		for y in range(maxi(0, cy - r), mini(w.H, cy + r + 1)):
			for x in range(maxi(0, cx - r), mini(w.W, cx + r + 1)):
				if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= OPEN_END * OPEN_END: out[y * w.W + x] = 0
	return out


## Стоимость по суше (w.cost), в которой клетки коридора near (_corridor) в AVOID_MUL раз дороже
static func _avoiding(w: WorldData, near: PackedByteArray) -> PackedFloat32Array:
	var part_us := Time.get_ticks_usec()
	var fast := Grid.fast_grid()
	if fast != null:
		var quick: PackedFloat32Array = fast.ScaledCost(w.cost, near, AVOID_MUL) # тот же цикл на C# (шаг 5 ревью)
		_part("avoiding", part_us)
		return quick
	var c := w.cost.duplicate()
	for i: int in w.N:
		if near[i] != 0 and c[i] != INF:
			c[i] *= AVOID_MUL
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
			var half: Vector2 = PlayerState.SITE_HALF[u.t] + Vector2(0.4, 0.4)
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
## Тропа (road = false) переходит реку не шире FORD_LEN вброд. Новый туннель через раз заменяется
## обходом горы, если он есть (state.detour — очередь обхода; cost — стоимость, по которой ищется обход).
## Клетки осей мостов и туннелей отмечаются в state.on_axis.
static func _make_checkpoint(w: WorldData, finder: Pathfinder, state: Dictionary) -> Dictionary:
	var part_us := Time.get_ticks_usec()
	var surface: Heightfield = state.get("surface")
	var checkpoint := {bridges = w.bridges.duplicate(), tunnels = w.tunnels.duplicate(), mask = w.path_mask.duplicate(),
		heights = finder.heights.duplicate(), links = finder.links.duplicate(), on_axis = state.on_axis.duplicate(),
		detour = state.detour, hv = surface.hv.duplicate() if surface != null else PackedFloat32Array()}
	# Число и объём снимков (P0 аудита 29.10): основа решения о журнале изменений вместо копий.
	state.checkpoints = int(state.get("checkpoints", 0)) + 1
	state.checkpoint_bytes = int(state.get("checkpoint_bytes", 0)) + checkpoint.mask.size() + checkpoint.links.size() \
		+ checkpoint.on_axis.size() + (checkpoint.heights.size() + checkpoint.hv.size()) * 4
	_part("checkpoint", part_us)
	return checkpoint


static func _structures(w: WorldData, p: PackedInt32Array, road: bool, finder: Pathfinder, cost: PackedFloat32Array, state: Dictionary, retries: int = 0, limit := ROAD_GRADE, accept := Callable()) -> PackedInt32Array:
	var part_us := Time.get_ticks_usec()
	# Неудачная связь не оставляет за собой мосты, выемки и разрешённые шаги по их осям.
	var ctx := {checkpoint = null, initial_detour = state.detour, initial_links_empty = finder.links.is_empty()}
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
		state.detour = ctx.initial_detour
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
	state.detour = ctx.initial_detour
	if state.has("surface"):
		var changed_ground: bool = state.surface.hv != checkpoint.hv
		state.surface.hv = checkpoint.hv.duplicate()
		var build_us := Time.get_ticks_usec()
		state.surface.build_structures()
		if changed_ground:
			_route_surface(finder, state.surface, finder.get_meta("route_width", WIDTHS.road))
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
					var q := _road_path(finder, bypass, p[0], p[-1], finder.use_corridor, limit) if road else _land_path(finder, bypass, p[0], p[-1], TRAIL_CLIMB)
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
			var around := _detour(w, finder, cost, a, b, ROAD_CLIMB if road else TRAIL_CLIMB, ROAD_LIMIT if road else TRAIL_GRADE)
			if around.is_empty():
				state.failure = "budget" if finder.search_budget == 0 else "tunnel"
				return PackedInt32Array()
			for k in range(1, around.size()):
				out.append(around[k])
			i = j
			continue
		# Повторно используемый мост тоже записывает on_axis, heights и links ниже.
		if ctx.checkpoint == null:
			ctx.checkpoint = _make_checkpoint(w, finder, state)
		if kind == "tunnel" and ends.is_empty():
			if state.detour:
				var q := _detour(w, finder, cost, a, b, ROAD_CLIMB if road else TRAIL_CLIMB, ROAD_LIMIT if road else TRAIL_GRADE)
				if q.size() > 0:
					state.detour = false
					for k in range(1, q.size()):
						out.append(q[k])
					i = j
					continue
			state.detour = true
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
					_route_surface(finder, state.surface, finder.get_meta("route_width", WIDTHS.road))
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
	var q := finder.find_path(w.cost, a, b, ROAD_CLIMB, ROAD_GRADE)
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
		climb := TRAIL_CLIMB, limit := TRAIL_GRADE) -> PackedInt32Array:
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
	var q := _land_path(finder, c, a, b, climb, limit)
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
	var fast := finder.fast() # 9.7: ближайший путь к вершине ищет C# (FastGrid.NearestPath), тот же перебор
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
		nearest_us += Time.get_ticks_usec() - detail_us
		if best >= 0 and bd < w.W * 0.4:
			# Технический подъём остаётся крутым, но отвесная вершина не получает фиктивную тропу.
			detail_us = Time.get_ticks_usec()
			var p := _land_path(finder, w.cost, best, pk.i, MOUNTAIN_CLIMB, MOUNTAIN_GRADE)
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
