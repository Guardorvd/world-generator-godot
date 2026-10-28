class_name TrailScout
extends RefCounted
## Автоматический выбор рабочего участка внутри подготовленной области мира и запуск существующей цепочки на нём:
## TrailPicker (старт и финиш) → TrailRouter → TrailFlow. Координат, прямоугольника и файла .tsite не требует: работает
## с WorldData и Heightfield в памяти (после finish_paths, как в игре); участок вырезает тот же TrailSite.cut.
##
## 1. Дешёвая оценка — один проход по клеткам области (уклон по рельефу, вода, пути, высота по блокам) в интегральные
##    таблицы; окно SIDE × SIDE клеток оценивается за O(1). Подробных данных (метровой сетки, поиска) здесь нет.
## 2. Запреты окна: вода больше WATER_MAX, пути больше PATH_MAX, поселение рядом, мост или туннель в участке с запасом,
##    мало клеток с пригодным уклоном, перепад блоков меньше требуемого. Остальное — очки: доля пригодных клеток минус
##    крутые, вода и пути, небольшая добавка за перепад и за дорогу рядом (предпочтение для будущего доступа; соединений
##    здесь не строится).
## 3. Кандидаты — не больше CANDIDATES не пересекающихся окон по очкам; подробный поиск — только в первых `windows`.
## 4. Для каждого: TrailSite.cut → TrailPicker.find. Бюджеты (пары, раскрытия, исправления, сборки, таймаут) общие на всю
##    область: окну достаётся равная доля остатка, сборки — весь остаток. Первая найденная трасса принимается (одна),
##    затем TrailFlow.dress. Требования и бюджеты не ослабляются; случайности нет.
## Отсутствие подходящего места — обычный итог (verdict), а не ошибка.

const SIDE := 48            # рабочий прямоугольник окна, клеток
const MARGIN := 12          # запас данных вокруг, клеток (TrailSite.cut)
const STEP := 24            # шаг окон при оценке, клеток
const BLOCK := 4            # блок для высоты, клеток
const CANDIDATES := 12
const WINDOWS := 3          # окон с подробным поиском
const WATER_MAX := 0.25
const PATH_MAX := 0.12
const USABLE_MIN := 0.5
const CLIFF := 0.30         # клетка круче — обрыв
const ROAD_RING := 24       # дорога в этом кольце вокруг окна — предпочтение, клеток
const SETTLEMENT_CLEAR := 8.0 # поселение ближе к участку с запасом на столько клеток — запрет
const SEED := 1             # seed композиции TrailFlow

const VERDICTS := {found = "трасса найдена", no_window = "места нет: ни одно окно области не прошло дешёвую оценку",
	refused_all = "испробованные окна отклонены по требованиям", budget = "остановлено бюджетом: невозможность не доказана",
	input = "ошибка запроса или области"}

var request := {}
var accepted := false
var verdict := ""
var reason := ""
var area := Rect2i()          ## область, по которой искали (мировые клетки)
var window := Rect2i()        ## принятое окно (рабочий прямоугольник, мировые клетки)
var site: TrailSite           ## участок принятого окна
var picker: TrailPicker
var flow: TrailFlow
var start := Vector2.ZERO     ## мировые метры
var finish := Vector2.ZERO
var windows: Array[Dictionary] = [] ## кандидаты по очкам: {rect, score, ..., searched, outcome}
var stats := {cells = 0, windows_total = 0, windows_allowed = 0, candidates = 0, searched = 0, cut_refused = 0,
	pairs = 0, searches = 0, expansions = 0, repairs = 0, builds = 0, eval_ms = 0.0, cut_ms = 0.0, picker_ms = 0.0,
	flow_ms = 0.0, total_ms = 0.0}
var rejected := {}            ## причина запрета окна -> число


static func find(w: WorldData, h: Heightfield, req := {}) -> TrailScout:
	var s := TrailScout.new()
	var started := Time.get_ticks_usec()
	s._run(w, h, req)
	s.stats.total_ms = (Time.get_ticks_usec() - started) / 1000.0
	return s


func _refuse(kind: String, why: String) -> void:
	verdict = kind
	reason = why


func _reject(why: String) -> void:
	rejected[why] = rejected.get(why, 0) + 1


func _run(w: WorldData, h: Heightfield, req: Dictionary) -> void:
	request = TrailPicker.DEFAULTS.duplicate()
	request.merge(req, true)
	request.windows = int(request.get("windows", WINDOWS))
	area = w.available_rect if w.available_rect.has_area() else Rect2i(0, 0, w.W, w.H)
	var deadline := Time.get_ticks_msec() + int(request.timeout_ms)
	if h.hv.size() != w.N or h.water_level.size() != w.N or h.road_refinement == null:
		_refuse("input", "мир не подготовлен: нужна поверхность после finish_paths")
		return
	if area.size.x < SIDE + 2 * MARGIN + 2 or area.size.y < SIDE + 2 * MARGIN + 2:
		_refuse("input", "область %s меньше окна с запасом" % area)
		return
	var started := Time.get_ticks_usec()
	var found := _evaluate(w, h)
	stats.eval_ms = (Time.get_ticks_usec() - started) / 1000.0
	var picks: Array[Dictionary] = _spread(found)
	stats.candidates = picks.size()
	picks = picks.slice(0, request.windows)
	if picks.is_empty():
		_refuse("no_window", "в области %s нет окна %d × %d клеток без воды, сооружений, поселений и занятых путей с пригодным уклоном и перепадом: %s" % [
			area, SIDE, SIDE, _rejections()])
		return
	var budget_hit := false
	for n in picks.size():
		var pick: Dictionary = picks[n]
		windows.append(pick)
		var left := picks.size() - n
		var time_left := deadline - Time.get_ticks_msec()
		var expansions_left: int = request.budget - stats.expansions
		if time_left <= 0 or expansions_left <= 0:
			pick.outcome = "не искалось: общий бюджет области исчерпан"
			budget_hit = true
			continue
		started = Time.get_ticks_usec()
		var cut := TrailSite.cut(w, h, pick.rect, MARGIN)
		stats.cut_ms += (Time.get_ticks_usec() - started) / 1000.0
		if not cut.errors.is_empty():
			stats.cut_refused += 1
			pick.outcome = "участок не вырезан: " + "; ".join(cut.errors)
			continue
		var cand: TrailSite = cut.site
		var rq := request.duplicate()
		rq.merge({pairs = ceili(float(request.pairs - stats.pairs) / left), budget = expansions_left / left,
			repairs = ceili(float(request.repairs - stats.repairs) / left), builds = request.builds - stats.builds,
			timeout_ms = time_left / left}, true)
		stats.searched += 1
		var p := TrailPicker.find(cand, rq)
		pick.outcome = "найдена" if p.accepted else "%s: %s" % [p.verdict, p.reason]
		pick.verdict = p.verdict
		stats.pairs += p.stats.pairs_searched
		stats.searches += p.stats.searches
		stats.expansions += p.stats.expansions
		stats.repairs += p.stats.repairs
		stats.builds += p.stats.builds
		stats.picker_ms += p.stats.total_ms
		if p.accepted:
			accepted = true
			window = pick.rect
			site = cand
			picker = p
			start = p.start + cand.origin_m()
			finish = p.finish + cand.origin_m()
			break
		if p.verdict == "budget":
			budget_hit = true
	if accepted:
		started = Time.get_ticks_usec()
		flow = TrailFlow.dress(site, picker.router, SEED)
		stats.flow_ms = (Time.get_ticks_usec() - started) / 1000.0
		stats.builds += flow.stats.builds
		verdict = "found"
		return
	_refuse("budget" if budget_hit else "refused_all", "искалось окон: %d из %d кандидатов" % [stats.searched, stats.candidates])


## Один проход по клеткам области и оценка всех окон. Возвращает разрешённые окна с очками.
func _evaluate(w: WorldData, h: Heightfield) -> Array[Dictionary]:
	var grid := area.grow(-1) # у границы нет соседей для уклона
	var gw := grid.size.x
	var gh := grid.size.y
	var tile := GameConfig.TILE
	var cap: float = request.grade * TrailRouter.SEARCH_SLACK
	var stride := gw + 1
	# интегральные таблицы (gw+1) × (gh+1): пригодные по уклону, обрывы, вода, занятые пути
	var usable := PackedInt32Array()
	var cliff := PackedInt32Array()
	var wet := PackedInt32Array()
	var path := PackedInt32Array()
	usable.resize(stride * (gh + 1))
	cliff.resize(stride * (gh + 1))
	wet.resize(stride * (gh + 1))
	path.resize(stride * (gh + 1))
	var bw := ceili(float(gw) / BLOCK)
	var bh := ceili(float(gh) / BLOCK)
	var block_sum := PackedFloat32Array()
	block_sum.resize(bw * bh)
	var block_n := PackedInt32Array()
	block_n.resize(bw * bh)
	var hv := h.hv
	var water := h.water_level
	var mask := w.path_mask
	var has_mask := mask.size() == w.N
	for z in gh:
		var row_u := 0
		var row_c := 0
		var row_w := 0
		var row_p := 0
		var base := (grid.position.y + z) * w.W + grid.position.x
		for x in gw:
			var i := base + x
			var gx := (hv[i + 1] - hv[i - 1]) / (2.0 * tile)
			var gz := (hv[i + w.W] - hv[i - w.W]) / (2.0 * tile)
			var slope := sqrt(gx * gx + gz * gz)
			row_u += int(slope <= cap)
			row_c += int(slope > CLIFF)
			row_w += int(water[i] != -INF)
			row_p += int(has_mask and mask[i] != 0)
			var at := (z + 1) * stride + x + 1
			usable[at] = usable[at - stride] + row_u
			cliff[at] = cliff[at - stride] + row_c
			wet[at] = wet[at - stride] + row_w
			path[at] = path[at - stride] + row_p
			var b := (z / BLOCK) * bw + x / BLOCK
			block_sum[b] += hv[i]
			block_n[b] += 1
	stats.cells = gw * gh
	var out: Array[Dictionary] = []
	var struct_feet: Array[Rect2] = []
	for s: Dictionary in h.structures:
		struct_feet.append(TrailSite.structure_foot(s))
	var settle_box := SETTLEMENT_CLEAR + MARGIN
	var cells := float(SIDE * SIDE)
	var z0 := area.position.y + MARGIN
	while z0 + SIDE + MARGIN <= area.end.y:
		var x0 := area.position.x + MARGIN
		while x0 + SIDE + MARGIN <= area.end.x:
			stats.windows_total += 1
			var rect := Rect2i(x0, z0, SIDE, SIDE)
			x0 += STEP
			var local := Rect2i(rect.position - grid.position, rect.size)
			var wet_f := _sum(wet, stride, local) / cells
			var path_f := _sum(path, stride, local) / cells
			var usable_f := _sum(usable, stride, local) / cells
			var cliff_f := _sum(cliff, stride, local) / cells
			if wet_f > WATER_MAX:
				_reject("окно: много воды")
				continue
			if path_f > PATH_MAX:
				_reject("окно: занято путями")
				continue
			if usable_f < USABLE_MIN:
				_reject("окно: мало клеток с пригодным уклоном")
				continue
			if _structures(struct_feet, rect):
				_reject("окно: мост или туннель в участке с запасом")
				continue
			if _settlement(w, rect.grow(int(settle_box))):
				_reject("окно: поселение рядом")
				continue
			var relief := _relief(block_sum, block_n, bw, local)
			if relief < request.min_drop:
				_reject("окно: перепад блоков меньше требуемого")
				continue
			var around := rect.grow(ROAD_RING).intersection(grid)
			var ring := Rect2i(around.position - grid.position, around.size)
			var road_near := maxf(0.0, _sum(path, stride, ring) - _sum(path, stride, local))
			var score: float = usable_f - cliff_f - 1.5 * wet_f - 2.0 * path_f + 0.2 * minf(1.0, relief / (3.0 * maxf(request.min_drop, 1.0))) \
				+ 0.1 * minf(1.0, road_near / 40.0)
			out.append({rect = rect, score = score, usable = usable_f, cliff = cliff_f, wet = wet_f, path = path_f, relief = relief,
				road_near = road_near, index = out.size(), outcome = "не искалось"})
		z0 += STEP
	stats.windows_allowed = out.size()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score > b.score or (a.score == b.score and a.index < b.index))
	return out


## Сумма по прямоугольнику local (координаты сетки) из интегральной таблицы.
static func _sum(table: PackedInt32Array, stride: int, local: Rect2i) -> float:
	var a := local.position.y * stride + local.position.x
	var b := local.position.y * stride + local.end.x
	var c := local.end.y * stride + local.position.x
	var d := local.end.y * stride + local.end.x
	return float(table[d] - table[b] - table[c] + table[a])


## Разность наибольшей и наименьшей средней высоты блоков, целиком лежащих в окне.
static func _relief(sum: PackedFloat32Array, count: PackedInt32Array, bw: int, local: Rect2i) -> float:
	var lo := INF
	var hi := -INF
	for bz in range(ceili(float(local.position.y) / BLOCK), local.end.y / BLOCK):
		for bx in range(ceili(float(local.position.x) / BLOCK), local.end.x / BLOCK):
			var b := bz * bw + bx
			if count[b] == 0:
				continue
			var m := sum[b] / count[b]
			lo = minf(lo, m)
			hi = maxf(hi, m)
	return hi - lo if hi >= lo else 0.0


## Задевает ли мост или туннель участок с запасом (в том числе целиком внутри: проход запрещён).
static func _structures(feet: Array[Rect2], rect: Rect2i) -> bool:
	var box := Rect2(Vector2(rect.grow(MARGIN).position) * GameConfig.TILE, Vector2(rect.grow(MARGIN).size) * GameConfig.TILE)
	for f in feet:
		if f.intersects(box):
			return true
	return false


static func _settlement(w: WorldData, box: Rect2i) -> bool:
	for v: SettlementData in w.settlements:
		if box.has_point(Vector2i(floori(v.x), floori(v.y))):
			return true
	return false


## Не пересекающиеся окна по убыванию очков, не больше CANDIDATES.
func _spread(ranked: Array[Dictionary]) -> Array[Dictionary]:
	var chosen: Array[Dictionary] = []
	for c: Dictionary in ranked:
		if chosen.size() >= CANDIDATES:
			break
		var apart := true
		for o: Dictionary in chosen:
			if (c.rect as Rect2i).intersects(o.rect):
				apart = false
				break
		if apart:
			chosen.append(c)
	return chosen


func _rejections() -> String:
	var keys := rejected.keys()
	keys.sort_custom(func(x: String, y: String) -> bool: return rejected[x] > rejected[y] or (rejected[x] == rejected[y] and x < y))
	var out := PackedStringArray()
	for k: String in keys:
		out.append("%s — %d" % [k, rejected[k]])
	return "; ".join(out)


## Отчёт: что нашли или почему нет, и общие затраты.
func summary() -> String:
	var lines := PackedStringArray()
	if accepted:
		lines.append("Трасса найдена в окне %s (клетки), старт (%.0f, %.0f) → финиш (%.0f, %.0f) м мира" % [window, start.x, start.y, finish.x, finish.y])
		var r := picker.router
		lines.append("Длина %.0f м · перепад вниз %.1f м · уклон до %.1f%% · элементы: %d (%s)" % [r.stats.length, r.stats.drop,
			r.stats.peak_grade * 100.0, flow.definition.elements.size(), flow.variant])
	else:
		lines.append("Трасса не найдена (%s): %s" % [VERDICTS.get(verdict, verdict), reason])
	lines.append("Область %s · клеток оценено %d · окон %d, допущено %d, кандидатов %d, искалось %d (вырезка отклонена %d)" % [
		area, stats.cells, stats.windows_total, stats.windows_allowed, stats.candidates, stats.searched, stats.cut_refused])
	for c in windows:
		lines.append("  окно %s: очки %.2f (пригодных %.2f, обрывов %.2f, воды %.2f, путей %.2f, перепад %.1f м, дорога рядом %d) → %s" % [
			c.rect, c.score, c.usable, c.cliff, c.wet, c.path, c.relief, int(c.road_near), c.outcome])
	lines.append("Работа: пар %d из %d · поисков %d · раскрытий %d из %d · исправлений %d из %d · сборок %d из %d (+ элементы)" % [
		stats.pairs, request.pairs, stats.searches, stats.expansions, request.budget, stats.repairs, request.repairs, stats.builds,
		request.builds])
	lines.append("Время: оценка области %.0f мс · вырезка %.0f · выбор места и поиск %.0f · элементы %.0f · всего %.0f мс" % [
		stats.eval_ms, stats.cut_ms, stats.picker_ms, stats.flow_ms, stats.total_ms])
	if not rejected.is_empty():
		lines.append("Запрещено окон: " + _rejections())
	return "\n".join(lines)
