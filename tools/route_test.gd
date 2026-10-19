extends SceneTree
## Проверка маршрутов 4.0: выбор пологого прохода, препятствия и связность реальных миров.
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


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	Grid.allow_fast = not args.has("--gdscript")
	_terrain_check()
	if not args.has("--quick"):
		for seed_text in SEEDS:
			var t0 := Time.get_ticks_msec()
			var w := WorldGenerator.generate(seed_text, 512)
			_check(SelfTest.settlements_connected(w), "%s: все %d поселений связаны (%d мс)" % [seed_text, w.settlements.size(), Time.get_ticks_msec() - t0])
			var valid := true
			var kinds := {}
			for trail in w.trails:
				kinds[trail.kind] = kinds.get(trail.kind, 0) + 1
				for p in trail.pts:
					valid = valid and is_finite(p.x) and is_finite(p.y) and p.x >= 0 and p.y >= 0 and p.x < w.W and p.y < w.H
			_check(valid, "%s: линии конечны и внутри карты; %s" % [seed_text, str(kinds)])
	print("Не прошло проверок: %d" % _fails)
	quit(1 if _fails > 0 else 0)
