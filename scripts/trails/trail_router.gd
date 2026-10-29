class_name TrailRouter
extends RefCounted
## Trail Lab: первый построитель линии велотрассы по природному рельефу сохранённой площадки (TrailSite) между двумя
## заданными точками. Без UI и сцены; результат — обычная TrailDefinition без элементов, собранная штатным
## TrailSite.prepare и проверенная TrailSurvey на готовой поверхности.
##
## Принцип (шаг 2, 28.10.2026): построитель ПРОКЛАДЫВАЕТ маршрут, а рельеф готовится под него. Уклон, радиус, угол
## поворота, перепад, глубина выемки и высота насыпи — не пороги пригодности и не причины отказа: уклон и поперечный
## склон земли входят в стоимость шага поиска, желаемый уклон (`grade`) — цель профиля TrailShaping, желаемый радиус
## (`min_radius`) — цель скругления. Отказ — только при нарушении корректности: вода, сооружения, чужие пути, граница,
## неизмеренная поверхность, а также при исчерпании технического бюджета (это не доказательство невозможности).
## 1. Поиск — штатный Pathfinder (A*, 8 направлений) на сетке GRID м по рабочему прямоугольнику, по исходной земле
##    площадки до новой трассы. Высоты для уклона усреднены на 4 м (как база требования); коридор ширины трассы —
##    его же set_corridor (продольный уклон по оси и краям, поперечный крен) — без предела, только в цене шага (climb).
##    Запрещено (стоимость INF): вода, мосты и туннели с защитной зоной PIN + PIN_FADE, существующие пути с зоной
##    метровой сетки (кроме точек примыкания joins), выход за рабочую зону. Демонстрационная линия площадки
##    не читается. Работа ограничена числом раскрытий (search_budget, общий на все поиски) и попыток исправления;
##    таймаут — дополнительная защита между этапами.
## 2. Геометрия — вытягивание ломаной (дальняя видимая вершина: коридор свободен и прямой отрезок по земле не круче
##    того, что обходил поиск), скругление углов дугами (желаемый радиус; где места меньше — меньший радиус, угол
##    формирует рельеф), выборка через 1 м и повторная проверка всего коридора после скругления.
## 3. Предварительная оценка без запекания земли — та же TrailShaping (profile + offset по оси): уклон на базе 4 м,
##    объём и глубина земляных работ. Это сведения для отчёта и ранжирования, не отказ.
## 4. Полная сборка только выбранного кандидата (TrailSite.prepare, не больше `builds` раз) и проверка готовой
##    поверхности (TrailSurvey): измерена целиком, коридор свободен. Уклон, радиус и земляные работы — фактические
##    значения в отчёте. Любой отказ — с причиной; вызывающий сохраняет прежнюю трассу.
## Одинаковые входные данные дают одинаковый результат: случайности нет, порядок обхода фиксирован.
## Этапы доступны по отдельности (setup → begin → candidate → complete): ими пользуется автоматический выбор места
## (TrailPicker), который выдаёт каждой паре только остаток общего бюджета.

const GRID := 2.0            # шаг сетки поиска, м
const SAMPLE := 1.0          # шаг точек готовой линии, м
const CHECK := 0.5           # шаг проверки коридора вдоль отрезка, м
const GRADE_BASE := 4.0      # база уклона, как у TrailSurvey и требования
const WATER_CLEAR := 1.0     # свободно от воды за краем полотна, м
const CLIMB := 10.0          # вес подъёма и крена в стоимости шага Pathfinder (предпочтение, не предел)
const PULL_SLACK := 0.02     # вытягивание: прямой отрезок по земле не круче обойдённого поиском участка + это (или цели)
const MIN_SPAN := 8.0        # технический минимум между стартом и финишем, м: короче концы полотна сливаются
const RADIUS_FLOOR := 0.5    # дуга меньше — острый угол без дуги (его формирует рельеф), м
const PENALTY := 8.0         # множитель стоимости клеток у места, которое не прошло проверку коридора
const PENALTY_REACH := 6.0   # радиус штрафа, м
const RADIUS_PREFER := 1.5   # желаемый радиус поворота — минимальный × это, если угол позволяет
const RELAX_LIMIT := 24      # правок тесных углов на одну найденную линию
const JOIN_CLEAR := 10.0     # подход к дороге: вокруг заданной точки примыкания запрет «существующий путь» снят, м
## grade — желаемый уклон полотна (цель профиля), min_radius — желаемый радиус: оба не пороги.
const DEFAULTS := {start = Vector2.ZERO, finish = Vector2.ZERO, width = 3.0, grade = 0.15,
	min_radius = 6.0, budget = 40000, repairs = 3, builds = 2, timeout_ms = 20000}
## Что построитель не проверяет: к этому списку добавляется TrailSurvey.UNCHECKED.
const UNCHECKED := ["поперечный уклон полотна и откосы", "растительность и камни (на площадке их нет)"]

## ok / fail / incomplete — проверки корректности; info — фактическое значение без порога.
const MARKS := {ok = "✓", fail = "✗", incomplete = "?", info = "·"}

enum Block { FREE, BOUNDS, WATER, STRUCTURE, PATH }
const BLOCK_NAMES := ["", "граница рабочей зоны", "вода", "мост или туннель с защитной зоной", "существующий путь"]

var request := {}
var found := false       ## линия найдена и прошла предварительную оценку
var accepted := false    ## построена и все проверяемые требования выполнены на готовой поверхности
var reason := ""         ## причина отказа (пусто при успехе)
var stage := ""          ## этап, на котором отказ: входные данные, поиск, геометрия, оценка, сборка, проверка
var definition: TrailDefinition
var prepared := {}       ## TrailSite.prepare выбранного кандидата: {heights, errors, timings}
var survey: TrailSurvey
var straight := {}       ## прямая между точками: {ok, length, problems}
var checks: Array[Dictionary] = [] ## {name, state: ok / fail / incomplete, detail}
var stats := {expansions = 0, searches = 0, repairs = 0, builds = 0, search_ms = 0.0, geometry_ms = 0.0, estimate_ms = 0.0,
	build_ms = 0.0, total_ms = 0.0, prepare_ms = 0.0, prepare_reused = false, prepare_cost_ms = 0.0}
var notes := PackedStringArray() ## ход построения: попытки, причины исправлений
## Определения, которые собираются вместе с этой линией (подходы к дороге): она проверяется на общей поверхности.
var extras: Array[TrailDefinition] = []
var _joins: Array = []            # request.joins: точки примыкания к существующему пути (локальные метры)

var _site: TrailSite
var _ground_h: Heightfield
var _origin := Vector2.ZERO   # локальные метры узла (0, 0)
var _w := 0
var _h := 0
var _raw := PackedFloat32Array()    # земля в узлах, м
var _mean := PackedFloat32Array()   # она же, усреднённая на 4 м
var _cost := PackedFloat32Array()
var _block := PackedByteArray()     # Block узла
var _paths: Array = []              # отрезки путей {a, b, reach}
var _path_cells := {}               # Vector2i (клетки 8 м) -> индексы отрезков
var _half := 0.0
var _lo := Vector2.ZERO             # допустимый прямоугольник оси, локальные метры
var _hi := Vector2.ZERO
var _deadline := 0
var _shape: TrailShaping
var _s := 0                         # узлы старта и финиша
var _t := 0
var _budget := 0                    # остаток раскрытий
var _attempts := 0                  # остаток попыток поиска (1 + исправления)
var _shaped := {}                   # геометрия текущего кандидата
## Данные пригодности последней площадки и ширины: сетка, запреты, высоты, области (см. setup).
static var _prepared := {}


## Отпустить данные последней площадки (выход из мира): иначе они живут до следующего построения
static func release() -> void:
	_prepared = {}


## Построить линию на площадке. request — DEFAULTS (start, finish — локальные метры площадки).
static func build(site: TrailSite, req := {}) -> TrailRouter:
	var r := TrailRouter.new()
	var started := Time.get_ticks_usec()
	r._run(site, req)
	r.stats.total_ms = (Time.get_ticks_usec() - started) / 1000.0
	return r


func _refuse(where: String, why: String) -> void:
	stage = where
	reason = why
	accepted = false
	notes.append("Отказ (%s): %s" % [where, why])


## Ручное построение между двумя точками: подготовка, кандидат, полная сборка.
func _run(site: TrailSite, req: Dictionary) -> void:
	if not setup(site, req) or not begin() or not candidate(): return
	if not complete() and reason.is_empty(): _refuse("проверка", _failed_checks())


## Этап 0: требования и данные пригодности площадки (запреты, высоты, области) — общие для любых точек.
## Данные пригодности считаются один раз на площадку и ширину (static _prepared) и затем переиспользуются:
## stats.prepare_ms — время, потраченное в этом вызове (0 при повторном использовании), prepare_reused, prepare_cost_ms —
## сколько их подготовка стоила, когда считалась.
func setup(site: TrailSite, req: Dictionary) -> bool:
	request = DEFAULTS.duplicate()
	request.merge(req, true)
	_deadline = Time.get_ticks_msec() + int(request.timeout_ms)
	if site == null:
		_refuse("входные данные", "площадка не открыта")
		return false
	var bad := _validate_request()
	if not bad.is_empty():
		_refuse("входные данные", bad)
		return false
	_site = site
	_ground_h = site.surface()
	_half = request.width * 0.5
	_shape = TrailShaping.preset("mountain")
	_shape.grade_limit = request.grade * 0.92 # цель профиля с запасом: сглаживание не выводит 4-метровый уклон за цель
	_shape.strength = 1.0                     # иначе полотно недотягивает до проектного уклона
	_shape.end_fade = 4.0                     # концы линии — заданные точки на естественной земле
	var started := Time.get_ticks_usec()
	var key := "%d|%.3f" % [site.get_instance_id(), request.width]
	stats.prepare_reused = _prepared.get("key", "") == key
	if not stats.prepare_reused:
		_setup_grid()
		_prepared = {key = key, w = _w, h = _h, origin = _origin, lo = _lo, hi = _hi, raw = _raw, mean = _mean, block = _block,
			cost = _cost.duplicate(), paths = _paths, path_cells = _path_cells, area = PackedInt32Array(), cost_ms = 0.0}
	else:
		for name: String in ["w", "h", "origin", "lo", "hi", "raw", "mean", "block", "paths", "path_cells"]: set("_" + name, _prepared[name])
		_cost = (_prepared.cost as PackedFloat32Array).duplicate() # штрафы и закрытые концы — только этого поиска
	stats.prepare_ms = (Time.get_ticks_usec() - started) / 1000.0
	if not stats.prepare_reused: _prepared.cost_ms = stats.prepare_ms
	stats.prepare_cost_ms = _prepared.cost_ms
	_budget = int(request.budget)
	_attempts = int(request.repairs) + 1
	# Примыкание к дороге: вокруг точки на оси существующего пути запрет «путь» снимается, чтобы линия дошла до оси
	# (вода, сооружения и граница остаются запретом); остальные пути запрещены по-прежнему
	_joins = request.get("joins", [])
	for join: Vector2 in _joins:
		var c := _node_at(join)
		var r := ceili(JOIN_CLEAR / GRID) + 1
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var x := c % _w + dx
				var z := c / _w + dz
				if x < 0 or z < 0 or x >= _w or z >= _h: continue
				var i := z * _w + x
				if _block[i] == Block.PATH and _node_point(i).distance_to(join) < JOIN_CLEAR and blocked(_node_point(i)) == Block.FREE:
					_cost[i] = 1.0
	return true


## Этап 1: заданные старт и финиш — свободны, не ближе технического минимума и в одной области (не разделены водой или
## путём). Уклон земли у концов не проверяется: полотно у конца формирует рельеф.
func begin() -> bool:
	for end: Array in [["старт", request.start], ["финиш", request.finish]]:
		var cause := blocked(end[1])
		if cause != Block.FREE:
			_refuse("входные данные", "%s (%.0f, %.0f) — запрещённое место: %s" % [end[0], end[1].x, end[1].y, BLOCK_NAMES[cause]])
			return false
	_s = _free_node(request.start)
	_t = _free_node(request.finish)
	if request.start.distance_to(request.finish) < MIN_SPAN:
		_refuse("входные данные", "старт и финиш ближе %.0f м: концы полотна сливаются" % MIN_SPAN)
		return false
	straight = _judge_straight()
	notes.append("Прямая %.0f м: %s" % [straight.length, "пригодна" if straight.ok else "непригодна — " + "; ".join(straight.problems)])
	var area := areas()
	if _joins.is_empty() and (area[_s] < 0 or area[_s] != area[_t]):
		_refuse("поиск", "старт и финиш разделены водой, мостом с защитной зоной или существующим путём: переправы и примыкания в этой версии не строятся")
		return false
	return true


## Этап 2: поиск и предварительная оценка без запекания земли. true — кандидат в definition (found), иначе отказ.
## Тратит раскрытия и попытки исправления из request.budget / request.repairs. Исправление (штраф и новый поиск) —
## только когда скруглённая линия задела запретное место; оценка уклона и земли — сведения, не отказ.
func candidate() -> bool:
	while _attempts > 0:
		_attempts -= 1
		if _cancelled() or Time.get_ticks_msec() > _deadline:
			_refuse("поиск", "таймаут %.0f с" % (request.timeout_ms / 1000.0))
			return false
		var ground := _search_ground()
		var finder := Pathfinder.new(_w, _h, ground)
		finder.set_corridor(ground, _no_water(), _zeros(), _half / GRID)
		finder.search_budget = _budget
		var started := Time.get_ticks_usec()
		var path := finder.find_path(_cost, _s, _t, CLIMB) # уклон и крен — в цене шага, без предела
		stats.search_ms += (Time.get_ticks_usec() - started) / 1000.0
		stats.searches += 1
		stats.expansions += _budget - finder.search_budget
		_budget = finder.search_budget
		finder.release()
		if path.is_empty():
			if _budget == 0:
				_refuse("поиск", "исчерпан бюджет поиска: %d раскрытий" % request.budget)
			else:
				_refuse("поиск", "нет пути в обход запретных мест (вода, сооружения, чужие пути, граница зоны)")
			return false
		started = Time.get_ticks_usec()
		var shaped := _polish(path)
		stats.geometry_ms += (Time.get_ticks_usec() - started) / 1000.0
		if shaped.has("error"):
			notes.append("Поиск %d: %s" % [stats.searches, shaped.error])
			if not _repair(_attempts, [shaped.at], "геометрия", shaped.error): return false
			continue
		var d := _definition(shaped.points)
		started = Time.get_ticks_usec()
		var estimate := _estimate(d)
		stats.estimate_ms += (Time.get_ticks_usec() - started) / 1000.0
		stats.estimate = estimate
		stats.min_radius = shaped.min_radius
		notes.append("Поиск %d: оценка уклона полотна до %.0f%% (цель %.0f%%), земля до %.1f м, %.0f / %.0f м³" % [
			stats.searches, estimate.peak * 100.0, request.grade * 100.0, estimate.deepest, estimate.cut_m3, estimate.fill_m3])
		found = true
		definition = d
		_shaped = shaped
		return true
	_refuse("поиск", "исчерпаны попытки исправления (%d)" % request.repairs)
	return false


## Этап 3: полная сборка кандидата (TrailSite.prepare, не больше request.builds) и проверка готовой поверхности.
## true — все проверяемые требования выполнены (accepted).
func complete() -> bool:
	if stats.builds >= request.builds:
		_refuse("сборка", "исчерпан лимит полных сборок (%d)" % request.builds)
		return false
	var started := Time.get_ticks_usec()
	var kit: Array[TrailDefinition] = [definition]
	kit.append_array(extras)
	prepared = _site.prepare(kit, true, {deadline = _deadline, cancel = request.get("cancel", Callable())})
	stats.builds += 1
	if not prepared.errors.is_empty():
		stats.build_ms += (Time.get_ticks_usec() - started) / 1000.0
		_refuse("сборка", "; ".join(prepared.errors))
		return false
	survey = TrailSurvey.measure(prepared.heights, definition, request.grade)
	stats.build_ms += (Time.get_ticks_usec() - started) / 1000.0
	_judge(_shaped)
	return accepted


func _validate_request() -> String:
	var r := request
	for key: String in ["width", "grade", "min_radius"]:
		if not (typeof(r[key]) in [TYPE_FLOAT, TYPE_INT]) or not is_finite(float(r[key])): return "нечисловое значение " + key
	if not (r.start is Vector2 and r.finish is Vector2): return "старт и финиш — координаты Vector2"
	if r.width < 2.0 or r.width > 8.0: return "ширина от 2 до 8 м"
	if r.grade < 0.03 or r.grade > 0.5: return "желаемый уклон от 3 до 50 %"
	if r.min_radius < 2.0 or r.min_radius > 40.0: return "желаемый радиус от 2 до 40 м"
	if int(r.budget) < 1 or int(r.repairs) < 0 or int(r.builds) < 1: return "бюджет поиска, попытки и сборки должны быть положительными"
	return ""


## Сетка узлов через GRID м по рабочему прямоугольнику; запреты — по точному blocked() в узле.
func _setup_grid() -> void:
	var work := _site.work
	_origin = Vector2(work.position) * GameConfig.TILE
	_w = int(work.size.x * GameConfig.TILE / GRID) + 1
	_h = int(work.size.y * GameConfig.TILE / GRID) + 1
	var margin := _half + RoadRefinement.REACH + GameConfig.TILE # как TrailSite.inside_errors
	_lo = _origin + Vector2.ONE * (margin + 0.01)
	_hi = Vector2(work.end) * GameConfig.TILE - Vector2.ONE * (margin + 0.01)
	_paths.clear()
	_path_cells.clear()
	for t: Dictionary in _site.trails:
		for n in range(1, t.pts.size()):
			var a := Vector2(t.pts[n - 1].x, t.pts[n - 1].y) * GameConfig.TILE
			var b := Vector2(t.pts[n].x, t.pts[n].y) * GameConfig.TILE
			var reach := maxf(t.pts[n - 1].w, t.pts[n].w) * GameConfig.TILE * 0.5 + RoadRefinement.REACH + _half
			var k := _paths.size()
			_paths.append({a = a, b = b, reach = reach})
			var lo := (a.min(b) - Vector2.ONE * reach) / 8.0
			var hi := (a.max(b) + Vector2.ONE * reach) / 8.0
			for gz in range(floori(lo.y), floori(hi.y) + 1):
				for gx in range(floori(lo.x), floori(hi.x) + 1):
					var key := Vector2i(gx, gz)
					if not _path_cells.has(key): _path_cells[key] = []
					(_path_cells[key] as Array).append(k)
	_raw.resize(_w * _h)
	_cost.resize(_w * _h)
	_block.resize(_w * _h)
	for z in _h:
		for x in _w:
			var i := z * _w + x
			var p := _node_point(i)
			_raw[i] = _ground_h.ground_at(p.x, p.y)
			_block[i] = blocked(p)
			_cost[i] = 1.0 if _block[i] == Block.FREE else INF
	_average_ground()


func _node_point(i: int) -> Vector2:
	return _origin + Vector2(i % _w, i / _w) * GRID


func _node_at(p: Vector2) -> int:
	var c := ((p - _origin) / GRID).round()
	return clampi(int(c.y), 0, _h - 1) * _w + clampi(int(c.x), 0, _w - 1)


## Ближайший разрешённый узел к свободной точке p (точка свободна, а ближайший узел может задеть запрет).
func _free_node(p: Vector2) -> int:
	var best := _node_at(p)
	var best_d := INF
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var x := best % _w + dx
			var z := best / _w + dz
			if x < 0 or z < 0 or x >= _w or z >= _h or _cost[z * _w + x] == INF: continue
			var d := _node_point(z * _w + x).distance_to(p)
			if d < best_d - 0.001:
				best_d = d
				best = z * _w + x
	return best


## Почему ось трассы не может пройти через точку p (локальные метры): граница, вода, сооружение, путь или FREE.
## Полотно (полуширина) и защитные зоны учитываются здесь, поэтому достаточно проверять ось.
func blocked(p: Vector2) -> int:
	if p.x < _lo.x or p.y < _lo.y or p.x > _hi.x or p.y > _hi.y: return Block.BOUNDS
	var w := _ground_h.world
	var tile := GameConfig.TILE
	var reach := _half + WATER_CLEAR
	var cx := floori(p.x / tile)
	var cz := floori(p.y / tile)
	# dist_water — клеток до воды: дальний узел не просматривает соседние клетки
	if w.dist_water[clampi(cz, 0, w.H - 1) * w.W + clampi(cx, 0, w.W - 1)] < reach / tile + 2.0:
		var r := ceili(reach / tile) + 1
		for z in range(maxi(0, cz - r), mini(w.H, cz + r + 1)):
			for x in range(maxi(0, cx - r), mini(w.W, cx + r + 1)):
				if _ground_h.water_level[z * w.W + x] == -INF: continue
				var near := Vector2(clampf(p.x, x * tile, (x + 1) * tile), clampf(p.y, z * tile, (z + 1) * tile))
				if near.distance_to(p) < reach: return Block.WATER
	for s: Dictionary in _site.structures:
		if Grid.segment_dist(p.x, p.y, s.ax, s.az, s.bx, s.bz) < s.half + RoadBed.PIN + RoadBed.PIN_FADE + _half: return Block.STRUCTURE
	for k: int in _path_cells.get(Vector2i((p / 8.0).floor()), []):
		var seg: Dictionary = _paths[k]
		if Grid.segment_dist(p.x, p.y, seg.a.x, seg.a.y, seg.b.x, seg.b.y) < seg.reach:
			if _near_join(p): break
			return Block.PATH
	return Block.FREE


func _near_join(p: Vector2) -> bool:
	for join: Vector2 in _joins:
		if join.distance_to(p) < JOIN_CLEAR: return true
	return false


## Земля, усреднённая на 4 м (±2 м по узлам), м: уклон поиска и вытягивания на той же базе, что требование.
func _average_ground() -> void:
	_mean.resize(_w * _h)
	var r := int(GRADE_BASE * 0.5 / GRID)
	for z in _h:
		for x in _w:
			var sum := 0.0
			var n := 0
			for dz in range(-r, r + 1):
				for dx in range(-r, r + 1):
					sum += _raw[clampi(z + dz, 0, _h - 1) * _w + clampi(x + dx, 0, _w - 1)]
					n += 1
			_mean[z * _w + x] = sum / n


## Высоты поиска в единицах шага сетки, как требует Pathfinder.
func _search_ground() -> PackedFloat32Array:
	var out := _mean.duplicate()
	for i in out.size(): out[i] /= GRID
	return out


## Усреднённая земля в точке (билинейно по узлам), м.
func mean_at(p: Vector2) -> float:
	var f := ((p - _origin) / GRID).clamp(Vector2.ZERO, Vector2(_w - 1.001, _h - 1.001))
	var x := floori(f.x)
	var z := floori(f.y)
	var tx := f.x - x
	var tz := f.y - z
	var i := z * _w + x
	return lerpf(lerpf(_mean[i], _mean[i + 1], tx), lerpf(_mean[i + _w], _mean[i + _w + 1], tx), tz)


func _no_water() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_w * _h)
	out.fill(-1.0e9) # вода уже запрещена стоимостью; коридор проверяет только уклон и крен
	return out


func _zeros() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(_w * _h)
	return out


## Связные области разрешённых узлов (без уклона): номер области узла, -1 — запрещён. Отличает «разделены водой/путём»
## от «слишком круто»; считается один раз вместе с данными пригодности.
func areas() -> PackedInt32Array:
	var area: PackedInt32Array = _prepared.area
	if not area.is_empty(): return area
	var base: PackedFloat32Array = _prepared.cost
	area.resize(_w * _h)
	area.fill(-1)
	var label := 0
	var queue := PackedInt32Array()
	for start in _w * _h:
		if area[start] >= 0 or base[start] == INF: continue
		queue.clear()
		queue.append(start)
		area[start] = label
		var head := 0
		while head < queue.size():
			var c := queue[head]
			head += 1
			var cx := c % _w
			var cz := c / _w
			for k in 8:
				var nx := cx + Grid.DX[k]
				var nz := cz + Grid.DY[k]
				if nx < 0 or nz < 0 or nx >= _w or nz >= _h: continue
				var n := nz * _w + nx
				if area[n] >= 0 or base[n] == INF: continue
				if k >= 4 and (base[cz * _w + nx] == INF or base[nz * _w + cx] == INF): continue
				area[n] = label
				queue.append(n)
		label += 1
	_prepared.area = area
	return area


## Штраф стоимости у мест, не прошедших оценку, и следующая попытка; false — попыток не осталось (отказ записан).
func _repair(attempts_left: int, points: Array, where: String, why: String) -> bool:
	if attempts_left <= 0:
		_refuse(where, why + " · попытки исправления исчерпаны (%d)" % request.repairs)
		return false
	stats.repairs += 1
	var r := int(ceil(PENALTY_REACH / GRID))
	var hit := {}
	for p: Vector2 in points:
		var c := _node_at(p)
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var x := c % _w + dx
				var z := c / _w + dz
				if x < 0 or z < 0 or x >= _w or z >= _h: continue
				var i := z * _w + x
				if hit.has(i) or _cost[i] == INF or _node_point(i).distance_to(p) > PENALTY_REACH: continue
				hit[i] = true
				_cost[i] *= PENALTY
	return true


## Ломаная узлов A* → вытянутая ломаная → дуги (желаемый радиус, где места меньше — меньший) → точки через SAMPLE м;
## весь коридор проверяется повторно. {points, min_radius} или {error, at} — только если линия задевает запретное место.
func _polish(path: PackedInt32Array) -> Dictionary:
	var raw := PackedVector2Array([request.start])
	for n in range(1, path.size() - 1): raw.append(_node_point(path[n]))
	raw.append(request.finish)
	# Вытягивание: от каждой вершины — к самой дальней, до которой прямой отрезок свободен и по земле не круче участка
	# поиска, который он заменяет (поиск обходил крутое ценой шага; вытягивание не срезает этот обход)
	var pulled := PackedVector2Array([raw[0]])
	var i := 0
	while i < raw.size() - 1:
		var best := i + 1
		var j := i + 2
		while j < raw.size() and j - best <= 8:
			if segment_ok(raw[i], raw[j], _peak_along(raw.slice(i, j + 1))): best = j
			j += 1
		pulled.append(raw[best])
		i = best
	# Тесные углы (лесенка A* по склону): убрать угол или слить два соседних в один, если это не делает линию круче;
	# угол, который так не убрать, остаётся с тем радиусом, на который хватает места
	var radii := _fillet_radii(pulled)
	var stuck := {}
	for fix in RELAX_LIMIT:
		var k := -1
		for c in range(1, pulled.size() - 1):
			if radii[c] < request.min_radius - 0.01 and not stuck.has(pulled[c]) and (k < 0 or radii[c] < radii[k]): k = c
		if k < 0: break
		if not _relax(pulled, k):
			stuck[pulled[k]] = true
			continue
		stats.corner_fixes = stats.get("corner_fixes", 0) + 1
		radii = _fillet_radii(pulled)
	# Дуга срезает угол: если она задела запретное, радиус этого угла уменьшается (вдвое, до острого угла)
	for tries in 12:
		var pts := _sample(pulled, radii)
		var bad := -1
		for p in pts:
			if blocked(p) != Block.FREE:
				bad = _nearest_corner(pulled, p)
				if radii[bad] >= RADIUS_FLOOR:
					radii[bad] = minf(radii[bad], request.min_radius) * (0.5 if radii[bad] <= request.min_radius else 1.0)
				else:
					return {error = "после скругления линия задевает запретное место (%s) у (%.0f, %.0f)" % [BLOCK_NAMES[blocked(p)], p.x, p.y], at = p}
				break
		if bad < 0:
			var smallest := INF
			for k in range(1, pulled.size() - 1): smallest = minf(smallest, radii[k])
			return {points = pts, min_radius = smallest, corners = pulled.size() - 2}
	return {error = "скругление не сошлось", at = pulled[0]}


## Наибольший уклон усреднённой земли на базе 4 м вдоль ломаной, м/м.
func _peak_along(pts: PackedVector2Array) -> float:
	var heights := PackedFloat32Array()
	var stations := PackedFloat32Array()
	var along := 0.0
	for n in range(1, pts.size()):
		var length := pts[n - 1].distance_to(pts[n])
		var count := maxi(1, ceili(length / CHECK))
		for k in count:
			heights.append(mean_at(pts[n - 1].lerp(pts[n], float(k) / count)))
			stations.append(along + length * k / count)
		along += length
	heights.append(mean_at(pts[-1]))
	stations.append(along)
	var peak := 0.0
	var b := 0
	for a in heights.size():
		while b < heights.size() - 1 and stations[b] - stations[a] < GRADE_BASE: b += 1
		if b > a: peak = maxf(peak, absf(heights[b] - heights[a]) / (stations[b] - stations[a]))
	return peak


## Убрать тесный угол k: прямо к соседу или пересечением внешних отрезков вместо двух соседних углов.
func _relax(pts: PackedVector2Array, k: int) -> bool:
	if segment_ok(pts[k - 1], pts[k + 1], _peak_along(pts.slice(k - 1, k + 2))):
		pts.remove_at(k)
		return true
	for m in [k + 1, k - 1]:
		if m < 1 or m > pts.size() - 2: continue
		var a := mini(k, m)
		var b := maxi(k, m)
		var cross: Variant = Geometry2D.line_intersects_line(pts[a - 1], pts[a] - pts[a - 1], pts[b + 1], pts[b] - pts[b + 1])
		if cross == null: continue
		var x: Vector2 = cross
		# пересечение должно лежать впереди обоих внешних отрезков и недалеко
		if (x - pts[a - 1]).dot(pts[a] - pts[a - 1]) <= 0.0 or (x - pts[b + 1]).dot(pts[b] - pts[b + 1]) <= 0.0: continue
		if x.distance_to(pts[a]) > 30.0 or x.distance_to(pts[b]) > 30.0: continue
		var near := _peak_along(pts.slice(a - 1, b + 2))
		if segment_ok(pts[a - 1], x, near) and segment_ok(x, pts[b + 1], near):
			pts[a] = x
			pts.remove_at(b)
			return true
	return false


## Прямой отрезок годится для линии: коридор свободен, а земля по нему не круче `along` — того, что он заменяет
## (или цели уклона, если она выше). INF — только коридор.
func segment_ok(a: Vector2, b: Vector2, along := INF) -> bool:
	return segment_problems(a, b, true, maxf(request.grade, along) + PULL_SLACK).is_empty()


## Что мешает прямому отрезку a–b (пусто — ничего): запретные места на оси; при конечном `steepest` — земля на базе 4 м
## круче него (предпочтение формы линии при вытягивании, не порог пригодности). first_only — до первой проблемы.
func segment_problems(a: Vector2, b: Vector2, first_only := false, steepest := INF) -> PackedStringArray:
	var out := PackedStringArray()
	var length := a.distance_to(b)
	var count := maxi(1, ceili(length / CHECK))
	var causes := {}
	var heights := PackedFloat32Array()
	for k in count + 1:
		var p := a.lerp(b, float(k) / count)
		var cause := blocked(p)
		if cause != Block.FREE and not causes.has(cause):
			causes[cause] = true
			out.append("%s у (%.0f, %.0f)" % [BLOCK_NAMES[cause], p.x, p.y])
			if first_only: return out
		heights.append(mean_at(p))
	if not is_finite(steepest): return out
	var span := maxi(1, roundi(GRADE_BASE / (length / count)))
	var peak := 0.0
	for k in range(0, maxi(1, heights.size() - span)):
		var e := mini(k + span, heights.size() - 1)
		peak = maxf(peak, absf(heights[e] - heights[k]) / ((e - k) * length / count))
	if peak > steepest: out.append("земля на базе 4 м до %.0f%% — круче обходного участка (%.0f%%)" % [peak * 100.0, steepest * 100.0])
	return out


## Наибольший радиус каждого угла (0 и последний — концы), не больше желаемого. Отрезок между двумя углами делится
## между их касательными пропорционально tan(угол/2) — при одном радиусе обоим хватает поровну; крайний отрезок
## отдаётся углу целиком.
func _fillet_radii(pts: PackedVector2Array) -> PackedFloat32Array:
	var radii := PackedFloat32Array()
	radii.resize(pts.size())
	radii.fill(INF)
	var want: float = request.min_radius * RADIUS_PREFER
	var need := PackedFloat32Array() # tan(угол/2) каждой вершины, у концов 0
	need.resize(pts.size())
	for k in range(1, pts.size() - 1):
		var turn := absf((pts[k] - pts[k - 1]).angle_to(pts[k + 1] - pts[k]))
		need[k] = tan(turn * 0.5) if turn < PI - 0.01 else INF
	for k in range(1, pts.size() - 1):
		if need[k] < 0.01:
			radii[k] = want
			continue
		if need[k] == INF:
			radii[k] = 0.0
			continue
		var before := pts[k].distance_to(pts[k - 1]) * need[k] / (need[k] + need[k - 1])
		var after := pts[k].distance_to(pts[k + 1]) * need[k] / (need[k] + need[k + 1])
		radii[k] = minf(want, minf(before, after) * 0.98 / need[k])
	return radii


## Отрезки и дуги через SAMPLE м.
func _sample(pts: PackedVector2Array, radii: PackedFloat32Array) -> PackedVector2Array:
	var path := PackedVector2Array([pts[0]])
	var from := pts[0]
	for k in range(1, pts.size()):
		if k == pts.size() - 1:
			_line(path, from, pts[k])
			break
		var a := (pts[k] - pts[k - 1]).normalized()
		var b := (pts[k + 1] - pts[k]).normalized()
		var turn := a.angle_to(b)
		if absf(turn) < 0.01:
			continue
		if radii[k] < RADIUS_FLOOR: # острый угол: места на дугу нет, поворот формирует рельеф
			_line(path, from, pts[k])
			from = pts[k]
			continue
		var t := radii[k] * tan(absf(turn) * 0.5)
		var enter := pts[k] - a * t
		var leave := pts[k] + b * t
		_line(path, from, enter)
		var normal := Vector2(-a.y, a.x) * signf(turn)
		var center := enter + normal * radii[k]
		var arc := radii[k] * absf(turn)
		var steps := maxi(2, ceili(arc / SAMPLE))
		var r0 := enter - center
		for s in range(1, steps + 1):
			path.append(center + r0.rotated(turn * s / steps))
		from = leave
	return path


func _line(path: PackedVector2Array, a: Vector2, b: Vector2) -> void:
	var length := a.distance_to(b)
	var steps := ceili(length / SAMPLE)
	for s in range(1, steps + 1):
		var p := a.lerp(b, float(s) / steps)
		if p.distance_to(path[-1]) > 0.05: path.append(p)


func _nearest_corner(pts: PackedVector2Array, p: Vector2) -> int:
	var best := 1
	for k in range(1, pts.size() - 1):
		if pts[k].distance_to(p) < pts[best].distance_to(p): best = k
	return best


func _definition(points: PackedVector2Array) -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = "site_route"
	d.title = "Линия по рельефу"
	d.kind = "mountain"
	d.width = request.width
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	d.shaping = _shape.duplicate()
	d.points = points
	return d


## Дешёвая оценка без запекания: высота оси = земля + смещение TrailShaping (с теми же защитами воды, берега,
## сооружений и чужих путей — TrailBuilder.pins, что у bake_elements), уклон на базе 4 м, глубина и объём земли полотна (без откосов).
## Сведения для отчёта и ранжирования: превышение цели — не отказ.
func _estimate(d: TrailDefinition) -> Dictionary:
	var h := _ground_h
	var pin_at := TrailBuilder.pins(h, [d] as Array[TrailDefinition])
	var p := _shape.profile(h, d, pin_at)
	var total := d.route_length()
	var count := maxi(2, ceili(total / CHECK))
	var step := total / count
	var ys := PackedFloat32Array()
	var cut := 0.0
	var fill := 0.0
	var deepest := 0.0
	for j in count + 1:
		var station := step * j
		var at := d.point_at(station)
		var offset := _shape.offset(h, d, Vector3(station, 0.0, 0.0), at, p) * float(pin_at.call(at))
		deepest = maxf(deepest, absf(offset))
		ys.append(h.ground_at(at.x, at.y) + offset)
		cut += maxf(0.0, -offset) * d.width * step
		fill += maxf(0.0, offset) * d.width * step
	var k := maxi(1, roundi(GRADE_BASE * 0.5 / step))
	var peak := 0.0
	var over: Array[Dictionary] = []
	for j in count + 1:
		var a := maxi(0, j - k)
		var b := mini(count, j + k)
		var grade := absf(ys[b] - ys[a]) / ((b - a) * step)
		peak = maxf(peak, grade)
		if grade > request.grade:
			var station := step * j
			if not over.is_empty() and station - over[-1].to <= 2.0:
				over[-1].to = station
				if (over[-1].points as Array).size() < 6: over[-1].points.append(d.point_at(station))
			else:
				over.append({from = station, to = station, points = [d.point_at(station)]})
	return {peak = peak, over = over, cut_m3 = cut, fill_m3 = fill, deepest = deepest, reach = p.reach, length = total, drop = ys[0] - ys[-1],
		grade_natural = p.grade_natural, grade_designed = p.grade_designed}


## Прямая между точками: свободен ли её коридор (вода, сооружения, пути, граница) — для объяснения обхода.
func _judge_straight() -> Dictionary:
	var problems := segment_problems(request.start, request.finish)
	return {ok = problems.is_empty(), length = request.start.distance_to(request.finish), problems = problems}


## Проверки выбранного кандидата на готовой поверхности. Корректность (поверхность измерена целиком, коридор свободен)
## решает accepted; уклон, радиус и земляные работы — фактические значения (info) рядом с целью, не пороги.
func _judge(shaped: Dictionary) -> void:
	checks.clear()
	var level := survey.level()
	var measured := survey.complete()
	checks.append({name = "Готовая поверхность измерена по всей оси", state = "ok" if measured else ("fail" if level == "error" else "incomplete"),
		detail = "%d точек через %.1f м" % [survey.stations.size(), TrailSurvey.SAMPLE] if measured else "; ".join(survey.errors) + (" · проверка НЕПОЛНАЯ: часть линии не измерена" if not survey.unmeasured.is_empty() else "")})
	var grade_detail := "до %.1f%% на базе 4 м (цель %.0f%%)" % [survey.peak_grade * 100.0, request.grade * 100.0]
	if level == "exceeded":
		var runs := PackedStringArray()
		for run: Dictionary in survey.exceeded.slice(0, 3): runs.append("%+.0f%% на %.0f–%.0f м" % [run.peak * 100.0, run.from, run.to])
		grade_detail += " · круче цели: " + ", ".join(runs)
	checks.append({name = "Уклон готовой поверхности", state = "info", detail = grade_detail})
	checks.append({name = "Радиус поворотов", state = "info",
		detail = "по дугам линии от %s (желаемый %.0f м) · по оси готовой поверхности (окно 6 м) от %s" % [
			"%.1f м" % shaped.min_radius if is_finite(shaped.min_radius) else "— (без поворотов)", request.min_radius,
			"%.1f м" % survey.min_radius if is_finite(survey.min_radius) else "—"]})
	var clear := 0
	for p in definition.points:
		if blocked(p) != Block.FREE: clear += 1
	checks.append({name = "Коридор: вода, мосты с защитой, пути, граница зоны", state = "ok" if clear == 0 else "fail",
		detail = "проверено %d точек оси через 1 м с полушириной %.1f м%s" % [definition.points.size(), _half, "" if clear == 0 else " · задето %d" % clear]})
	var shaping: Dictionary = prepared.heights.road_refinement.trail_shaping.get(definition.id, {})
	checks.append({name = "Земляные работы", state = "ok" if not shaping.is_empty() else "fail",
		detail = "выемка до %.2f м, насыпь до %.2f м · объём %.0f / %.0f м³ (с откосами) · зона %.1f м от оси" % [shaping.get("max_cut", 0.0),
			shaping.get("max_fill", 0.0), shaping.get("cut_m3", 0.0), shaping.get("fill_m3", 0.0), shaping.get("reach", 0.0)]})
	accepted = true
	for c: Dictionary in checks: accepted = accepted and c.state in ["ok", "info"]
	stats.length = definition.route_length()
	stats.drop = survey.support[0] - survey.support[-1] if not survey.support.is_empty() else 0.0
	stats.climb = survey.climb
	stats.descent = survey.descent
	stats.peak_grade = survey.peak_grade
	stats.cut_m3 = shaping.get("cut_m3", 0.0)
	stats.fill_m3 = shaping.get("fill_m3", 0.0)
	stats.max_cut = shaping.get("max_cut", 0.0)
	stats.max_fill = shaping.get("max_fill", 0.0)
	stats.reach = shaping.get("reach", 0.0)
	if accepted: notes.append("Сборка %d: поверхность подготовлена и измерена" % stats.builds)


func _failed_checks() -> String:
	var out := PackedStringArray()
	for c: Dictionary in checks:
		if c.state in ["fail", "incomplete"]: out.append("%s — %s (%s)" % [c.name, "НЕПОЛНАЯ проверка" if c.state == "incomplete" else "не выполнено", c.detail])
	return "; ".join(out)


## Подготовка данных пригодности: посчитана сейчас (входит во «всего») или взята из памяти (не входит, указана цена).
static func prepare_text(s: Dictionary) -> String:
	if s.get("prepare_reused", false): return "данные площадки из памяти (готовились %.0f мс ранее)" % s.get("prepare_cost_ms", 0.0)
	return "подготовка площадки %.0f мс" % s.get("prepare_ms", 0.0)


## Отчёт для лаборатории: найден ли путь, выполнены ли требования, что не проверяется, цифры.
func summary() -> String:
	var lines := PackedStringArray()
	lines.append("Путь найден: %s · поверхность: %s" % ["да" if found else "нет",
		"подготовлена и проверена" if accepted else ("не прошла проверку" if not checks.is_empty() else "не собиралась")])
	if not reason.is_empty(): lines.append("Отказ (%s): %s" % [stage, reason])
	for c: Dictionary in checks:
		lines.append("%s %s · %s" % [MARKS[c.state], c.name, c.detail])
	if not straight.is_empty():
		lines.append("Прямая %.0f м: %s" % [straight.length, "коридор свободен" if straight.ok else "коридор задевает запретное (" + "; ".join(straight.problems) + ")"])
	if stats.has("length"):
		lines.append("Длина %.0f м · перепад %.1f м · набор %.1f / сброс %.1f м · уклон до %.1f%% · земля %.0f / %.0f м³" % [
			stats.length, stats.drop, stats.climb, stats.descent, stats.peak_grade * 100.0, stats.cut_m3, stats.fill_m3])
	lines.append("Раскрытий %d из %d · поисков %d · исправлений %d · сборок %d" % [stats.expansions, request.get("budget", 0), stats.searches, stats.repairs, stats.builds])
	lines.append("Время: %s · поиск %.0f мс · геометрия %.0f · оценка %.0f · полная сборка %.0f · всего %.0f мс" % [
		prepare_text(stats), stats.search_ms, stats.geometry_ms, stats.estimate_ms, stats.build_ms, stats.total_ms])
	var unchecked := PackedStringArray(TrailSurvey.UNCHECKED)
	unchecked.append_array(UNCHECKED)
	lines.append("Не проверяется: " + ", ".join(unchecked))
	return "\n".join(lines)


func _cancelled() -> bool:
	var cancel: Callable = request.get("cancel", Callable())
	return cancel.is_valid() and cancel.call()
