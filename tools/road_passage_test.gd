extends SceneTree
## 11.11.2026: публикация сети участками (StageTrails._add_trail, docs/ROAD_NETWORK.md) на синтетическом мире без
## генерации: общий участок не копируется, развилка и примыкание — общая вершина на оси хозяина, пересечение проходит
## насквозь, повышение класса делит тропу узлами, рядом с участком нет «призрачной» дешёвой полосы, правило
## параллельных полотен. Секунды, без окна.
##   godot --headless --path . --script res://tools/road_passage_test.gd
const Fixture := preload("res://tools/road_relief_fixture.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	fails += int(not ok)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()


func cells(points: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for p: Vector2i in points: out.append(p.y * 96 + p.x)
	return out


func line(from: Vector2i, to: Vector2i) -> Array:
	var out: Array = []
	var at := from
	out.append(at)
	while at != to:
		at += Vector2i(signi(to.x - at.x), signi(to.y - at.y))
		out.append(at)
	return out


func on_polyline(pts: Array, p: Vector2) -> bool:
	for j in pts.size():
		if Vector2(pts[j].x, pts[j].y).distance_to(p) < 0.0001: return true
	return false


func overlap(w: WorldData, a: int, b: int) -> float:
	# длина оси a ближе 0,25 клетки к оси b (дубль полотна), клеток
	var total := 0.0
	var pts: Array = w.trails[a].pts
	for j in range(1, pts.size()):
		var p := (Vector2(pts[j - 1].x, pts[j - 1].y) + Vector2(pts[j].x, pts[j].y)) * 0.5
		var q := StageTrails._nearest_on(w.trails[b].pts, p)
		if p.distance_to(q) < 0.25: total += Vector2(pts[j - 1].x, pts[j - 1].y).distance_to(Vector2(pts[j].x, pts[j].y))
	return total


func run() -> void:
	var w := Fixture.world()
	w.trails = []
	w.cost.resize(w.N)
	w.cost.fill(1.0)
	StageTrails._net_reset(w)
	# Хозяин: дорога по ряду 48
	var host := StageTrails._add_trail(w, cells(line(Vector2i(8, 48), Vector2i(88, 48))), "road")
	check(host.size() == 1 and w.trails.size() == 1, "first route is one segment")
	# Сходится на дорогу, идёт по ней 20 клеток и уходит: два новых участка, общий участок не копируется
	var path: Array = line(Vector2i(14, 30), Vector2i(30, 46)) + line(Vector2i(30, 47), Vector2i(30, 48)).slice(1) \
		+ line(Vector2i(31, 48), Vector2i(50, 48)) + line(Vector2i(51, 49), Vector2i(66, 64))
	var added := StageTrails._add_trail(w, cells(path), "trail")
	check(added.size() == 2, "merge-and-leave makes two new segments (%d)" % added.size())
	var shared := 0.0
	for k: int in added: shared += overlap(w, k, 0)
	check(shared < 1.0, "no duplicated axis along the shared road (%.2f cells)" % shared)
	var nodes := 0
	for k: int in added:
		for end: Dictionary in [w.trails[k].pts[0], w.trails[k].pts[-1]]:
			if on_polyline(w.trails[0].pts, Vector2(end.x, end.y)): nodes += 1
	check(nodes == 2, "each branch ends on an exact vertex of the host axis (node)")
	# Пересечение: вертикальный путь через дорогу — один участок насквозь
	var before := w.trails.size()
	var cross := StageTrails._add_trail(w, cells(line(Vector2i(72, 30), Vector2i(72, 66))), "trail")
	check(cross.size() == 1 and w.trails.size() == before + 1, "a crossing passes through as one segment")
	# Путь целиком по готовой сети — ничего нового
	before = w.trails.size()
	check(StageTrails._add_trail(w, cells(line(Vector2i(12, 48), Vector2i(80, 48))), "trail").is_empty() and w.trails.size() == before,
		"a route that runs entirely on the network publishes nothing")
	# Стоимость: на участке дешевле, рядом — не дешевле свободной земли
	check(w.cost[48 * 96 + 40] < 0.5 and w.cost[47 * 96 + 40] >= 1.0, "trodden discount only on the segment, not a ghost strip beside it")
	# Повышение класса: часть тропы, по которой идёт дорога-связь, — дорога; тропа делится узлами
	StageTrails._net_reset(w)
	w.trails = []
	StageTrails._add_trail(w, cells(line(Vector2i(8, 20), Vector2i(88, 20))), "trail")
	var length := StageTrails._kind_length_of(w.trails[0])
	StageTrails._upgrade_path(w, cells(line(Vector2i(30, 20), Vector2i(60, 20))))
	var kinds := {}
	var total := 0.0
	for t: Dictionary in w.trails:
		kinds[t.kind] = int(kinds.get(t.kind, 0)) + 1
		total += StageTrails._kind_length_of(t)
	check(kinds.get("road", 0) == 1 and kinds.get("trail", 0) == 2, "promotion splits the trail into trail-road-trail (%s)" % str(kinds))
	check(absf(total - length) < 0.01, "promotion keeps the axis (%.3f / %.3f cells)" % [total, length])
	var road: Dictionary = w.trails[0]
	check(road.kind == "road" and road.pts.all(func(p: Dictionary) -> bool: return p.w == StageTrails.WIDTHS.road), "promoted part has one road width")
	# Параллельное полотно в 3 клетках вдоль сети на той же высоте — не новое; далеко — новое
	var near := StageTrails._net_near(w)
	var beside := cells(line(Vector2i(8, 23), Vector2i(88, 23)))
	var far := cells(line(Vector2i(8, 60), Vector2i(88, 60)))
	check(not StageTrails._adds_network(w, beside, near), "a parallel tread 12 m beside the network is rejected")
	check(StageTrails._adds_network(w, far, near), "a route 160 m away is a real addition")
	print("ROAD PASSAGE RESULT ", fails, " failures")
	quit(1 if fails else 0)
