extends SceneTree
## Проверка маршрутов: проезжаемый рельеф 4.2, полезные связи, препятствия и реальные миры.
## -- --gdscript проверяет ту же логику без C#; -- --quick — только искусственный рельеф.

const SelfTest := preload("res://tools/selftest.gd")
const SEEDS := ["Север-1234", "Туман-4821", "Ущелье", "Янтарь-5150", "a1", "b2", "c3", "d4", "e5", "f6", "g7", "h8"]
var _fails := 0


func _check(ok: bool, what: String) -> void:
	print(("✓ " if ok else "✗ ") + what)
	if not ok:
		_fails += 1


func _effort(path: PackedInt32Array, heights: PackedFloat32Array, width: int) -> float:
	var total := 0.0
	for k in range(1, path.size()):
		var a := path[k - 1]
		var b := path[k]
		var length := Grid.hypot(b % width - a % width, b / width - a / width)
		var rise := heights[b] - heights[a]
		total += rise * rise / length
	return total


func _terrain_check() -> void:
	# Поперёк хребта можно пройти прямо, через более низкую седловину или обойти его конец.
	const W := 41
	const H := 25
	var heights := PackedFloat32Array()
	var cost := PackedFloat32Array()
	heights.resize(W * H)
	cost.resize(W * H)
	cost.fill(1.0)
	for y in H:
		for x in W:
			var pass_height := 1.1 if y < 8 else (0.8 if y < 15 else 0.0)
			heights[y * W + x] = maxf(0.0, 1.0 - absf(x - 20.0) / 3.0) * pass_height
	var finder := Pathfinder.new(W, H, heights)
	var paths: Array[PackedInt32Array] = []
	var efforts: Array[float] = []
	for weight in [StageTrails.ROAD_CLIMB, StageTrails.TRAIL_CLIMB, StageTrails.MOUNTAIN_CLIMB]:
		var p := finder.find_path(cost, 4 * W + 3, 4 * W + 37, weight)
		paths.append(p)
		efforts.append(_effort(p, heights, W))
		print("  вес %.0f: %d клеток, усилие %.3f" % [weight, p.size(), efforts[-1]])
	_check(not paths[0].is_empty() and efforts[0] < efforts[2], "спокойный путь выбирает более пологий проход, чем технический")
	_check(efforts[0] < efforts[1] and efforts[1] < efforts[2], "три характера находят разные подходящие проходы на одном рельефе")
	if Grid.allow_fast:
		Grid.allow_fast = false
		var gd := Pathfinder.new(W, H, heights)
		var k := 0
		for weight in [StageTrails.ROAD_CLIMB, StageTrails.TRAIL_CLIMB, StageTrails.MOUNTAIN_CLIMB]:
			_check(gd.find_path(cost, 4 * W + 3, 4 * W + 37, weight) == paths[k], "C# и GDScript выбирают одинаковый проход (вес %.0f)" % weight)
			k += 1
		Grid.allow_fast = true
	# INF остаётся запретом независимо от готовности к сложным подъёмам.
	for y in H:
		cost[y * W + 20] = INF
	for weight in [StageTrails.ROAD_CLIMB, StageTrails.TRAIL_CLIMB, StageTrails.MOUNTAIN_CLIMB]:
		_check(finder.find_path(cost, 4 * W + 3, 4 * W + 37, weight).is_empty(), "непроходимая полоса не пересекается (вес %.0f)" % weight)
	# Диагональ не должна протиснуться между двумя непроходимыми клетками.
	var corner := Pathfinder.new(2, 2, PackedFloat32Array([0, 0, 0, 0]))
	_check(corner.find_path(PackedFloat32Array([1, INF, INF, 1]), 0, 3, StageTrails.MOUNTAIN_CLIMB).is_empty(), "техническая тропа не срезает закрытый угол")


func _connection_check(blocked: bool) -> void:
	var w := WorldData.new()
	w.W = 128
	w.H = 64
	w.N = w.W * w.H
	w.rng = WGRandom.new(41)
	w.h.resize(w.N)
	w.h.fill(0.1)
	w.cost.resize(w.N)
	w.cost.fill(1.0)
	w.path_mask.resize(w.N)
	w.ocean.resize(w.N)
	w.lake.resize(w.N)
	w.river.resize(w.N)
	w.dist_water.resize(w.N)
	w.dist_water.fill(INF)
	w.settlements = [{i = 8 * w.W + 8, x = 8.5, y = 8.5}, {i = 8 * w.W + 48, x = 48.5, y = 8.5}, {i = 48 * w.W + 28, x = 28.5, y = 48.5}]
	var paths: Array = []
	for a in [0, 1]:
		var x := 8 if a == 0 else 48
		var p := Grid.line_cells(x, 8, x, 48, w.W)
		p.append_array(Grid.line_cells(x, 48, 28, 48, w.W).slice(1))
		for i in p:
			w.path_mask[i] = 3
		paths.append([a, 2, p, true, 45.0])
	if blocked:
		for y in range(0, 47):
			w.cost[y * w.W + 28] = INF
	var finder := Pathfinder.new(w.W, w.H, w.h)
	var a: int = w.settlements[0].i
	var b: int = w.settlements[1].i
	var before := StageTrails._length(w, finder.find_path(StageTrails._network_cost(w), a, b))
	var state := {detour = false, on_axis = PackedByteArray()}
	state.on_axis.resize(w.N)
	StageTrails._second_ways(w, finder, paths, w.cost.duplicate(), state)
	var after := StageTrails._length(w, finder.find_path(StageTrails._network_cost(w), a, b))
	if blocked:
		_check(w.trails.is_empty() and is_equal_approx(before, after), "закрытая местность не получает обязательную альтернативную дорогу")
	else:
		_check(after < before / StageTrails.SHORTCUT, "доступный проход сокращает обход по существующей сети")
	# На ровной земле параллельная линия не считается другим перевалом или долиной.
	_check(not StageTrails._different_relief(w, paths[0][2], paths[1][2]), "плоская копия пути не оправдывает петлю")
	if not blocked:
		# Та же пара направлений становится полезной, когда рядом с дорогой через гребень есть долина.
		w.cost.fill(1.0)
		w.path_mask.fill(0)
		w.trails = []
		w.settlements.resize(2)
		var ridge := Grid.line_cells(8, 8, 48, 8, w.W)
		for i in ridge:
			w.path_mask[i] = 3
		for y in range(5, 12):
			for x in range(20, 37):
				w.h[y * w.W + x] = 0.15
		var terrain := w.h.duplicate()
		for i in w.N:
			terrain[i] *= StageTrails.HEIGHT_SCALE
		var valley_finder := Pathfinder.new(w.W, w.H, terrain)
		StageTrails._second_ways(w, valley_finder, [[0, 1, ridge, true, 40.0]], w.cost.duplicate(), state)
		_check(not w.trails.is_empty(), "долина рядом с дорогой через гребень создаёт альтернативный проход")


func _surface_check() -> void:
	# Равные концы диагонали не делают её ровной: между ними проходит ребро меша.
	var saddle := Pathfinder.new(2, 2, PackedFloat32Array([0, 2, 2, 0]))
	var cost := PackedFloat32Array([1, 1, 1, 1])
	_check(saddle.find_path(cost, 0, 3, StageTrails.ROAD_CLIMB, StageTrails.ROAD_GRADE).is_empty(), "дорога не перескакивает скрытый выступ между равными концами диагонали")
	saddle.links = PackedByteArray([1 << 4, 0, 0, 1 << 7])
	_check(saddle.find_path(PackedFloat32Array([1, INF, INF, 1]), 0, 3, StageTrails.ROAD_CLIMB, StageTrails.ROAD_GRADE) == PackedInt32Array([0, 3]), "готовый диагональный настил доступен вдоль оси между непроходимыми берегами")
	var w := WorldData.new()
	w.W = 16
	w.H = 16
	w.N = w.W * w.H
	w.h.resize(w.N)
	w.h.fill(0.1)
	w.filled.resize(w.N)
	w.ocean.resize(w.N)
	w.lake.resize(w.N)
	w.river.resize(w.N)
	w.cost.resize(w.N)
	w.cost.fill(1.0)
	# Обрыв с пологим обходом в конце: строгий поиск обязан найти этот проход.
	for y in 12:
		for x in range(8, 16):
			w.h[y * w.W + x] += 0.04 * minf(1.0, float(12 - y) / 12.0)
	var ground := Heightfield.new(w, false)
	var heights := ground.hv.duplicate()
	for i in w.N:
		heights[i] /= GameConfig.TILE
	var finder := Pathfinder.new(w.W, w.H, heights)
	var p := finder.find_path(w.cost, 4 * w.W + 3, 4 * w.W + 12, StageTrails.ROAD_CLIMB, StageTrails.ROAD_GRADE)
	var passed := false
	var drivable := not p.is_empty()
	for i in p:
		passed = passed or i / w.W >= 10
	for k in range(1, p.size()):
		var a := {x = p[k - 1] % w.W + 0.5, y = p[k - 1] / w.W + 0.5, w = 0.0}
		var b := {x = p[k] % w.W + 0.5, y = p[k] / w.W + 0.5, w = 0.0}
		drivable = drivable and StageTrails._road_segment(ground, a, b)
	_check(drivable and passed, "дорога обходит обрыв через проход с проезжаемым уклоном игрового меша")
	if Grid.allow_fast:
		Grid.allow_fast = false
		_check(Pathfinder.new(w.W, w.H, heights).find_path(w.cost, 4 * w.W + 3, 4 * w.W + 12, StageTrails.ROAD_CLIMB, StageTrails.ROAD_GRADE) == p, "C# и GDScript совпадают при ограничении реального уклона")
		Grid.allow_fast = true
	# Плоский берег разрешён. Вода и склон под краем ленты запрещают срезать угол.
	w.h.fill(0.1)
	w.lake[5 * w.W + 6] = 1
	w.filled[5 * w.W + 6] = 0.14
	ground = Heightfield.new(w, false)
	var a := {x = 5.0, y = 4.5, w = 0.9}
	var b := {x = 5.0, y = 5.5, w = 0.9}
	_check(StageTrails._road_segment(ground, a, b), "пологий подход непосредственно к воде разрешён")
	var q := {x = 5.8, y = 4.5, w = 0.9}
	var r := {x = 5.8, y = 6.5, w = 0.9}
	_check(not StageTrails._road_segment(ground, q, r), "сглаживание не уводит край дороги в глубокую воду")
	w.lake.fill(0)
	w.h[5 * w.W + 6] = 0.2
	ground = Heightfield.new(w, false)
	_check(not StageTrails._road_segment(ground, q, r), "сглаживание проверяет крутизну под всей шириной дороги")
	var axis := PackedByteArray()
	axis.resize(w.N)
	axis[5 * w.W + 5] = 1
	var corner := [a, b, {x = 6.5, y = 5.5, w = 0.9}]
	_check(StageTrails._road_line(w, corner, axis, ground) == corner, "скругление сохраняет точный вход на ось сооружения")
	# Непригодная переправа не должна превращаться в мост ради связи любой ценой.
	w.h.fill(0.1)
	w.h[4 * w.W + 8] = 0.2
	w.river[4 * w.W + 6] = 1
	w.river[4 * w.W + 7] = 1
	ground = Heightfield.new(w, false)
	var crossing := Grid.line_cells(5, 4, 8, 4, w.W)
	var closed := w.cost.duplicate()
	closed.fill(INF)
	for i in crossing:
		closed[i] = 1.0
	var state := {detour = false, on_axis = axis, surface = ground}
	_check(StageTrails._structures(w, crossing, true, finder, closed, state).is_empty() and w.bridges.is_empty(), "слишком крутая переправа без безопасного обхода отклоняется")
	w.river.fill(0)
	w.h.fill(0.1)
	ground = Heightfield.new(w, false)
	_check(StageTrails._bridge_clear(ground, crossing[0], crossing[-1]), "ровный свободный настил допускается")
	_check(StageTrails._bridge_site(ground, crossing, PackedByteArray([0, 1, 1, 0]), 0, 3,
		PackedInt32Array([crossing[0]]), axis) == Vector2i(-1, -1),
		"мокрая маска без настоящей воды не создаёт мост")
	# Мост не должен приземляться на узкий сухой выступ, если края настила остаются над водой.
	w.lake[3 * w.W + 5] = 1
	w.filled[3 * w.W + 5] = 0.14
	ground = Heightfield.new(w, false)
	_check(not StageTrails._bridge_clear(ground, crossing[0], crossing[-1]), "узкий береговой выступ не принимается как полноширинная опора моста")
	w.lake.fill(0)
	_check(not StageTrails._bridge_clear(Heightfield.new(w, false), 4 * w.W + 5, 4 * w.W + 5), "нулевой мост не создаётся")
	# Нельзя подменить отсутствующий сухой подход к мосту прямой через преграду.
	w.cost[4 * w.W + 4] = INF
	w.cost[3 * w.W + 4] = INF
	w.cost[5 * w.W + 4] = INF
	for y in w.H:
		w.cost[y * w.W + 4] = INF
	_check(StageTrails._link(w, finder, 4 * w.W + 3, 4 * w.W + 5).is_empty(), "отсутствующий подход к сооружению не заменяется опасной прямой")


func _ravine_landing_check() -> void:
	const W := 24
	var w := WorldData.new()
	w.W = W
	w.H = W
	w.N = W * W
	w.h.resize(w.N)
	w.h.fill(0.1)
	for name: String in ["filled", "ocean", "lake", "river", "path_mask", "cost"]:
		var values: Variant = PackedFloat32Array() if name == "filled" or name == "cost" else PackedByteArray()
		values.resize(w.N)
		if name == "cost": values.fill(1.0)
		w.set(name, values)
	# Сухая впадина больше не заменяется декоративным мостом.
	for x in range(9, 12): w.h[12 * W + x] = 0.06
	var path := Grid.line_cells(2, 12, 21, 12, W)
	var ground := Heightfield.new(w, false)
	var heights := ground.hv.duplicate()
	for i in W * W: heights[i] /= GameConfig.TILE
	var finder := Pathfinder.new(W, W, heights)
	var on_axis := PackedByteArray()
	on_axis.resize(w.N)
	var state := {detour = false, on_axis = on_axis, surface = ground}
	var normal := StageTrails._structures(w, path, true, finder, w.cost, state)
	var keeps_ground_route := normal == path and w.bridges.is_empty()
	_check(keeps_ground_route, "сухой овраг сохраняет наземную дорогу без лишнего моста")
	# Понижение бокового рельефа тоже не должно создавать мост над сушей.
	w.bridges.clear()
	w.path_mask.fill(0)
	w.h[11 * W + 8] -= 20.0 / GameConfig.HS
	w.h[11 * W + 12] -= 20.0 / GameConfig.HS
	ground = Heightfield.new(w, false)
	heights = ground.hv.duplicate()
	for i in W * W: heights[i] /= GameConfig.TILE
	finder = Pathfinder.new(W, W, heights)
	on_axis = PackedByteArray()
	on_axis.resize(w.N)
	state = {detour = false, on_axis = on_axis, surface = ground}
	_check(not StageTrails._bridge_clear(ground, path[6], path[10]), "ухудшение берега выключает полноширинную опору")
	var no_bridge := StageTrails._structures(w, path, true, finder, w.cost, state)
	_check(not no_bridge.is_empty() and w.bridges.is_empty(), "сухой овраг без полноширинной опоры оставляет путь без моста")


func _corridor_check() -> void:
	# Плоская ось вдоль стены: точечный поиск не видит, что край полотна уже на скале.
	var w := WorldData.new()
	w.W = 24
	w.H = 24
	w.N = w.W * w.H
	w.h.resize(w.N)
	w.h.fill(0.1)
	w.filled.resize(w.N)
	w.ocean.resize(w.N)
	w.lake.resize(w.N)
	w.river.resize(w.N)
	for y in range(4, 8):
		for x in range(6, 17):
			w.h[y * w.W + x] = 0.2
	var surface := Heightfield.new(w, false)
	var heights := surface.hv.duplicate()
	for i in w.N: heights[i] /= GameConfig.TILE
	var cost := PackedFloat32Array()
	cost.resize(w.N)
	cost.fill(1.0)
	var start := 8 * w.W + 2
	var finish := 8 * w.W + 20
	var finder := Pathfinder.new(w.W, w.H, heights)
	var axis := finder.find_path(cost, start, finish, StageTrails.ROAD_CLIMB, StageTrails.ROAD_GRADE)
	StageTrails._route_surface(finder, surface, 0.9)
	var wide := finder.find_path(cost, start, finish, StageTrails.ROAD_CLIMB, StageTrails.ROAD_GRADE)
	var safe := not wide.is_empty()
	for k in range(1, wide.size()):
		var a := {x = wide[k - 1] % w.W + 0.5, y = wide[k - 1] / w.W + 0.5, w = 0.9}
		var b := {x = wide[k] % w.W + 0.5, y = wide[k] / w.W + 0.5, w = 0.9}
		safe = safe and StageTrails._road_segment(surface, a, b)
	_check(wide != axis and safe, "поиск по ширине уводит горизонтальную дорогу со стены на пологую землю")
	var narrow := cost.duplicate()
	narrow.fill(INF)
	for x in range(2, 21): narrow[8 * w.W + x] = 1.0
	var fallback := StageTrails._road_path(finder, narrow, start, finish)
	_check(fallback.is_empty() and finder.use_corridor, "запасной поиск не принимает горизонтальную ось на стене без ширины")
	finder.use_corridor = true
	if Grid.allow_fast:
		Grid.allow_fast = false
		var gd := Pathfinder.new(w.W, w.H, heights)
		StageTrails._route_surface(gd, surface, 0.9)
		_check(gd.find_path(cost, start, finish, StageTrails.ROAD_CLIMB, StageTrails.ROAD_GRADE) == wide, "C# и GDScript совпадают при проверке ширины прохода")
		Grid.allow_fast = true
	# Обычная тропа проходит той же проверкой углов и сохраняет вход на ось.
	w.rng = WGRandom.new(41)
	w.cost = cost
	w.path_mask.resize(w.N)
	var on_axis := PackedByteArray()
	w.dist_water.resize(w.N)
	w.dist_water.fill(INF)
	on_axis.resize(w.N)
	on_axis[wide[0]] = 1
	StageTrails._add_trail(w, wide, "trail", PackedFloat32Array(), on_axis, surface)
	var points: Array = w.trails[0].pts
	safe = Vector2(points[0].x, points[0].y) == Vector2(2.5, 8.5)
	for k in range(1, points.size()):
		safe = safe and StageTrails._road_segment(surface, points[k - 1], points[k])
	_check(safe, "обычная тропа после скругления сохраняет безопасный проход и точный вход")


func _rollback_check() -> void:
	# Первый мост пригоден, вторая переправа закрыта. Отброшенная связь не должна менять мир.
	var w := WorldData.new()
	w.W = 32
	w.H = 16
	w.N = w.W * w.H
	w.h.resize(w.N)
	w.h.fill(0.1)
	w.filled.resize(w.N)
	w.ocean.resize(w.N)
	w.lake.resize(w.N)
	w.river.resize(w.N)
	w.path_mask.resize(w.N)
	w.cost.resize(w.N)
	w.cost.fill(INF)
	for y in w.H:
		w.river[y * w.W + 8] = 1
		w.river[y * w.W + 16] = 1
		for x in range(17, w.W): w.h[y * w.W + x] = 0.2
	var path := Grid.line_cells(2, 8, 23, 8, w.W)
	for i in path: w.cost[i] = 1.0
	var surface := Heightfield.new(w, false)
	var heights := surface.hv.duplicate()
	for i in w.N: heights[i] /= GameConfig.TILE
	var finder := Pathfinder.new(w.W, w.H, heights)
	var on_axis := PackedByteArray()
	on_axis.resize(w.N)
	var state := {surface = surface, on_axis = on_axis, detour = false}
	var mask := w.path_mask.duplicate()
	var before := surface.hv.duplicate()
	var heights_before := heights.duplicate()
	var axis_before := on_axis.duplicate()
	_check(StageTrails._bridge_clear(surface, 8 * w.W + 7, 8 * w.W + 9), "первая переправа контрольной связи действительно пригодна")
	var result := StageTrails._structures(w, path, true, finder, w.cost, state)
	_check(result.is_empty() and w.bridges.is_empty() and w.tunnels.is_empty(), "отказ от второй переправы убирает мост от отброшенной связи")
	_check(w.path_mask == mask and surface.hv == before and finder.heights == heights_before and finder.links.is_empty() and state.on_axis == axis_before, "после отказа восстановлены земля, маска пути и шаги поиска")
	# Повторно используемый мост тоже пишет оси и шаги, даже если нового сооружения нет.
	w.bridges = [{a = 8 * w.W + 7, b = 8 * w.W + 9}]
	surface.build_structures()
	var bridges_before := w.bridges.duplicate(true)
	result = StageTrails._structures(w, path, true, finder, w.cost, state)
	_check(result.is_empty() and w.bridges == bridges_before and w.tunnels.is_empty()
		and finder.links.is_empty() and finder.heights == heights_before and state.on_axis == axis_before
		and surface.hv == before and not state.detour,
		"отказ после повторного использования моста восстанавливает оси, высоты, шаги и очередь обходов")
	# Отказ до первого сооружения не должен оставлять даже пустой рабочий массив links.
	result = StageTrails._structures(w, Grid.line_cells(14, 8, 23, 8, w.W), true, finder, w.cost, state)
	_check(result.is_empty() and finder.links.is_empty() and state.on_axis == axis_before,
		"ранний отказ без снимка сохраняет исходное пустое состояние поиска")


## Технический участок разрешён по своему классу, отвесная геометрия — нет.
func _technical_check() -> void:
	const W := 41
	var terrain := PackedFloat32Array()
	var cost := PackedFloat32Array()
	terrain.resize(W * W)
	cost.resize(W * W)
	cost.fill(1.0)
	for y in W:
		for x in W:
			terrain[y * W + x] = maxf(0.0, 2.0 - absf(x - 20.0)) * (0.38 if y < 35 else 0.0)
	var finder := Pathfinder.new(W, W, terrain)
	var start := 4 * W + 14
	var finish := 4 * W + 26
	var gentle := finder.find_path(cost, start, finish, StageTrails.TRAIL_CLIMB, StageTrails.ROAD_GRADE)
	var technical := StageTrails._land_path(finder, cost, start, finish, StageTrails.TRAIL_CLIMB)
	_check(not technical.is_empty() and technical.size() < gentle.size(),
		"тропа выбирает короткий технический проход при существующем длинном пологом обходе")
	if Grid.allow_fast:
		Grid.allow_fast = false
		_check(StageTrails._land_path(Pathfinder.new(W, W, terrain), cost, start, finish, StageTrails.TRAIL_CLIMB) == technical,
			"C# и GDScript совпадают на техническом проходе")
		Grid.allow_fast = true
	# Единственный коридор с подъёмом 38 %: тропа проходит, дорожный предел его запрещает.
	cost.fill(INF)
	for x in range(14, 27): cost[4 * W + x] = 1.0
	_check(not StageTrails._land_path(finder, cost, start, finish, StageTrails.TRAIL_CLIMB).is_empty()
		and finder.find_path(cost, start, finish, StageTrails.ROAD_CLIMB, StageTrails.ROAD_LIMIT).is_empty(),
		"пределы дороги и технической тропы различаются")
	var road_terrain := terrain.duplicate()
	for i in road_terrain.size(): road_terrain[i] *= 0.65
	var road_finder := Pathfinder.new(W, W, road_terrain)
	_check(not StageTrails._road_path(road_finder, cost, start, finish, true, StageTrails.ROAD_LIMIT).is_empty() and road_finder.use_corridor,
		"дорога допускает короткий подъём 25 % и сохраняет проверку ширины")
	for i in terrain.size(): terrain[i] *= 2.0
	finder = Pathfinder.new(W, W, terrain)
	_check(StageTrails._land_path(finder, cost, start, finish, StageTrails.TRAIL_CLIMB).is_empty(),
		"тропа не принимает подъём 76 %")
	var w := WorldData.new()
	w.W = 16
	w.H = 16
	w.N = 256
	w.h.resize(w.N)
	w.ocean.resize(w.N)
	w.lake.resize(w.N)
	w.river.resize(w.N)
	w.filled.resize(w.N)
	for y in w.H:
		for x in w.W:
			w.h[y * w.W + x] = (20.0 + x * GameConfig.TILE * 0.5) / GameConfig.HS
	var surface := Heightfield.new(w, false)
	var corner: Array = [{x = 4.5, y = 4.5, w = 0.42}, {x = 6.5, y = 4.5, w = 0.42}, {x = 8.5, y = 6.5, w = 0.42}]
	var mountain := StageTrails._road_line(w, corner, PackedByteArray(), surface, "mountain")
	_check(mountain.size() > corner.size() and StageTrails._road_line(w, corner, PackedByteArray(), surface) == corner,
		"горная тропа скругляется на своём допустимом уклоне, дорога такой угол не срезает")
	for i in w.N: w.h[i] *= 1.5
	_check(StageTrails._road_line(w, corner, PackedByteArray(), Heightfield.new(w, false), "mountain") == corner,
		"скругление горной тропы не срезает угол через обрыв")


## Ось пересекает угол между выборками: покрытие обязано включить ту же клетку, что маска.
func _raster_check() -> void:
	var pts: Array = [{x = 0.9, y = 0.95, w = 0.55}, {x = 2.1, y = 1.55, w = 0.55}]
	var mask := PackedByteArray()
	mask.resize(16)
	Grid.stamp_path(mask, 4, 4, pts, 2, 0.175)
	var w := WorldData.new()
	w.W = 4
	w.H = 4
	w.N = 16
	w.path_mask = mask
	w.road_surface.resize(16)
	var trail := {pts = pts, surf = PackedByteArray([RoadSurface.FOREST, RoadSurface.DIRT])}
	RoadSurface._stamp(w, trail)
	var same := true
	for i in 16:
		same = same and ((mask[i] >= 2) == (w.road_surface[i] != RoadSurface.NONE))
	_check(same and mask[1] == 2, "маска и покрытие включают одни и те же клетки, в том числе угол диагонали")
	_check(w.road_surface[0] == RoadSurface.FOREST and w.road_surface[6] == RoadSurface.DIRT,
		"покрытие меняется между концами сегмента")
	Grid.stamp_path(mask, 4, 4, pts, 3, 0.175)
	Grid.stamp_path(mask, 4, 4, pts, 1, 0.175)
	_check(mask[1] == 3, "звериная тропа не понижает маску дороги")
	# Выход за границы и нулевой сегмент не должны ни ломать обход, ни оставлять ложные клетки.
	var clipped: Array = [{x = -0.5, y = 2.5, w = 0.55}, {x = -0.5, y = 2.5, w = 0.55}, {x = 4.5, y = 2.5, w = 0.55}]
	var edge := PackedByteArray()
	edge.resize(16)
	Grid.stamp_path(edge, 4, 4, clipped, 2, 0.175)
	_check(edge.slice(8, 12) == PackedByteArray([2, 2, 2, 2]) and edge.count(2) == 4,
		"разметка обрезается границами карты и пропускает нулевые сегменты")


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120 if "--quick" in OS.get_cmdline_user_args() else 600)
	var args := OS.get_cmdline_user_args()
	Grid.allow_fast = not args.has("--gdscript")
	_technical_check()
	_raster_check()
	_terrain_check()
	_surface_check()
	_ravine_landing_check()
	_corridor_check()
	_rollback_check()
	_connection_check(false)
	_connection_check(true)
	if not args.has("--quick"):
		for seed_text in SEEDS:
			var t0 := Time.get_ticks_msec()
			var w := WorldGenerator.generate(seed_text, 512)
			_check(SelfTest.settlements_connected(w), "%s: все %d поселений связаны (%d мс)" % [seed_text, w.settlements.size(), Time.get_ticks_msec() - t0])
			var valid := true
			var kinds := {}
			var mountain_forks := 0
			for trail in w.trails:
				kinds[trail.kind] = kinds.get(trail.kind, 0) + 1
				if trail.kind == "mountain":
					var nearest := INF
					for s in w.settlements:
						nearest = minf(nearest, Grid.hypot(trail.pts[0].x - s.x, trail.pts[0].y - s.y))
					if nearest > 8.0:
						mountain_forks += 1
				for p in trail.pts:
					valid = valid and is_finite(p.x) and is_finite(p.y) and p.x >= 0 and p.y >= 0 and p.x < w.W and p.y < w.H
			_check(valid, "%s: линии конечны и внутри карты; %s" % [seed_text, str(kinds)])
			print("  горных ответвлений вне поселений: %d" % mountain_forks)
	print("Не прошло проверок: %d" % _fails)
	quit(1 if _fails > 0 else 0)
