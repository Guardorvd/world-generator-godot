extends SceneTree
## Снимок-эталон поиска пути (16.11.2026): хеши путей Pathfinder.find_path, остатка запаса раскрытий и ответа can_reach
## на синтетических сетках без генерации мира (секунды). Нужен, чтобы удалить GDScript-копию A* и дальше менять C#
## (FastGrid.FindPath, FastGrid.Path.cs), не меняя результат: любая правка, после которой хеши расходятся, меняет сеть путей.
##   godot --headless --path . --script res://tools/path_golden.gd -- [--save]
## Без ключа сверяет с tools/control/golden/paths.txt и печатает «PATH GOLDEN RESULT n failures»; код 1 при расхождении.
## Случаи: plain — без рельефа; terrain — подъём и предел уклона; corridor — ширина прохода у воды (две полуширины),
## предел поперечного крена; links — шаги по настилу через стену; window — окно поиска; world — метровые поля мира
## (set_world_corridor). У каждого — три пары концов в обе стороны, штрафы поворота и галсов (turn, bend), запас
## раскрытий (без предела, 300, 40) и can_reach; unreach — заведомо недостижимая цель.
## Эталон снят 16.11.2026 на C# и тем же скриптом совпал с прежней копией A* на GDScript (722 хеша, 0 расхождений),
## после чего копия удалена. Пересъёмка (--save) — только осознанно, когда пути менять и хотели.
## Лимит 120 с.
const FILE := "res://tools/control/golden/paths.txt"
const N := 64
const SHAPES: Array[Vector2] = [Vector2(0, 0), Vector2(2, 0), Vector2(8, 0), Vector2(8, 6), Vector2(0, 12)]
const BUDGETS: Array[int] = [-1, 300, 40]
var lines := {}
var heights := PackedFloat32Array()
var costs := PackedFloat32Array()
var water := PackedFloat32Array()
var wet := PackedByteArray()


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var save := "--save" in args
	if Grid.native_grid() == null:
		print("PATH GOLDEN: нужен C# (dotnet build), без него эталон не снять и не сверить")
		quit(1)
		return
	_fields()
	_case("plain", func(f: Pathfinder) -> void: f.use_corridor = false, 0.0, INF)
	_case("terrain", func(f: Pathfinder) -> void: f.use_corridor = false, 8.0, 0.6)
	_case("corridor", func(f: Pathfinder) -> void: f.set_corridor(heights, water, wet, 0.6), 8.0, 0.6)
	_case("corridor_narrow", func(f: Pathfinder) -> void: f.set_corridor(heights, water, wet, 0.45), 32.0, 0.35)
	_case("cross", func(f: Pathfinder) -> void:
		f.set_corridor(heights, water, wet, 0.6)
		f.max_cross_grade = 0.4, 8.0, 0.6)
	_case("links", _bridge_corridor, 8.0, 0.6)
	_case("window", func(f: Pathfinder) -> void:
		f.use_corridor = false
		f.window = Rect2i(2, 2, 58, 50), 8.0, 0.6)
	_case("world", func(f: Pathfinder) -> void:
		var meters := heights.duplicate()
		var level := water.duplicate()
		var ocean := PackedByteArray()
		ocean.resize(N * N)
		var lake := wet.duplicate()
		for i in N * N:
			meters[i] *= 4.0
			level[i] = level[i] * 4.0 if level[i] > -INF else -INF
		f.set_world_corridor(meters, level, ocean, lake, ocean, 4.0, 0.6), 8.0, 0.6)
	_unreach()
	if not _directional_grade():
		print("FAIL directional grade (A*, Reach or cached result)")
		quit(1)
		return
	_finish(save)


## Холмы, дешёвая «тропа», стена с проходом, озеро и замкнутая котловина.
func _fields() -> void:
	heights.resize(N * N)
	costs.resize(N * N)
	water.resize(N * N)
	wet.resize(N * N)
	for y in N:
		for x in N:
			var i := y * N + x
			heights[i] = 3.0 * sin(x * 0.21) * cos(y * 0.17) + 0.04 * x
			var c := 1.0 + 0.5 * absf(sin(x * 1.3 + y * 0.7))
			if y == 30 and x > 4 and x < 58: c = 0.3 # протоптанная тропа
			if x == 20 and y > 6 and y < 46: c = INF # стена
			if absi(x - 42) <= 1 and absi(y - 50) <= 1: c = 1.0 # внутри котловины
			elif maxi(absi(x - 42), absi(y - 50)) == 3: c = INF # кольцо котловины
			costs[i] = c
			water[i] = -INF
			if Vector2(x - 44, y - 14).length() < 5.0:
				water[i] = heights[i] + 0.3
				wet[i] = 1


## Настил через стену: шаги вдоль y = 20 разрешены в обе стороны (ширину прохода над водой проверяют только без настила).
func _bridge() -> PackedByteArray:
	var links := PackedByteArray()
	links.resize(N * N)
	for x in range(17, 24):
		links[20 * N + x] |= 1 # +x (Grid.DX[0])
		links[20 * N + x + 1] |= 2 # −x
	return links


## Вода под настилом: без него шаг через (19..21, 20) непроходим по ширине прохода.
func _bridge_corridor(f: Pathfinder) -> void:
	var level := water.duplicate()
	var under := wet.duplicate()
	for x in range(18, 23):
		level[20 * N + x] = heights[20 * N + x] + 0.5
		under[20 * N + x] = 1
	f.set_corridor(heights, level, under, 0.6)
	f.links = _bridge()


func _case(name: String, setup: Callable, climb: float, max_grade: float) -> void:
	var pairs: Array[Vector2i] = [Vector2i(5 * N + 3, 42 * N + 44), Vector2i(40 * N + 2, 3 * N + 45), Vector2i(24 * N + 10, 24 * N + 40)]
	var found := 0
	var total := 0
	var shapes := {}
	for pair: Vector2i in pairs:
		for ends: Vector2i in [pair, Vector2i(pair.y, pair.x)]:
			var f := Pathfinder.new(N, N, heights)
			setup.call(f)
			var cost := costs.duplicate()
			if name == "links": cost[20 * N + 20] = 1.0
			var reach := f.can_reach(cost, ends.x, ends.y, climb, max_grade)
			for shape: Vector2 in SHAPES:
				for budget: int in BUDGETS:
					f.search_budget = budget
					var path := f.find_path(cost, ends.x, ends.y, climb, max_grade, -1, shape.x, shape.y)
					var key := "%s.%d_%d.t%d_b%d.q%d" % [name, ends.x, ends.y, int(shape.x), int(shape.y), budget]
					lines[key] = var_to_bytes([path, f.search_budget, reach]).hex_encode().sha256_text()
					total += 1
					found += int(not path.is_empty())
					if budget < 0: shapes[path] = true
			f.release()
	print("  %s: путей %d из %d, разных полных путей %d" % [name, found, total, shapes.size()])


func _unreach() -> void:
	var f := Pathfinder.new(N, N, heights)
	f.use_corridor = false
	var inside := 50 * N + 42
	for from: int in [5 * N + 3, 40 * N + 60]:
		var reach := f.can_reach(costs, from, inside, 8.0, 0.6)
		f.search_budget = -1
		var path := f.find_path(costs, from, inside, 8.0, 0.6)
		lines["unreach.%d" % from] = var_to_bytes([path, f.search_budget, reach]).hex_encode().sha256_text()
	f.release()


func _directional_grade() -> bool:
	var hs := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 2.8, 2.1, 1.4, 0.7, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var cost := PackedFloat32Array()
	cost.resize(hs.size())
	cost.fill(INF)
	for i in range(5, 10):
		cost[i] = 1.0
	var f := Pathfinder.new(5, 3, hs)
	f.use_corridor = false
	var v := f.next_cost_version()
	f.fast().DownhillGrade = 0.85
	var descends := f.find_path(cost, 5, 9, 0.0, 0.53, v).size() == 5 and f.can_reach(cost, 5, 9, 0.0, 0.53)
	var rejects_climb := f.find_path(cost, 9, 5, 0.0, 0.53, v).is_empty() and not f.can_reach(cost, 9, 5, 0.0, 0.53)
	f.fast().DownhillGrade = 0.6
	var rejects_descent := f.find_path(cost, 5, 9, 0.0, 0.53, v).is_empty() and not f.can_reach(cost, 5, 9, 0.0, 0.53)
	f.release()
	return descends and rejects_climb and rejects_descent


func _finish(save: bool) -> void:
	var keys: Array = lines.keys()
	keys.sort()
	if save:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FILE.get_base_dir()))
		var out := FileAccess.open(FILE, FileAccess.WRITE)
		for key: String in keys:
			out.store_line("%s %s" % [key, lines[key]])
		out.close()
		print("PATH GOLDEN: записано %d хешей в %s" % [lines.size(), FILE])
		quit(0)
		return
	var saved := {}
	if FileAccess.file_exists(FILE):
		for row in FileAccess.get_file_as_string(FILE).split("\n", false):
			var pair := row.split(" ")
			if pair.size() == 2: saved[pair[0]] = pair[1]
	var failures := 0
	if saved.is_empty():
		print("FAIL эталона нет: %s (снять: -- --save)" % FILE)
		failures += 1
	for key: String in keys:
		if saved.get(key, "") != lines[key]:
			print("FAIL ", key)
			failures += 1
	for key: String in saved:
		if not lines.has(key):
			print("FAIL в эталоне лишний ключ ", key)
			failures += 1
	print("PATH GOLDEN: %d хешей" % lines.size())
	print("PATH GOLDEN RESULT %d failures" % failures)
	quit(1 if failures > 0 else 0)
