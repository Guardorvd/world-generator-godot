extends SceneTree
## Проверка маршрутов: характер езды, полезные связи 4.1, препятствия и реальные миры.
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


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	Grid.allow_fast = not args.has("--gdscript")
	_terrain_check()
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
