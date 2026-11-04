extends RefCounted
## Shared read-only overview for the entire search. No per-window graphs or terrain bakes.
const STEP := 8
const GenerationInput := preload("res://scripts/trails/trail_generation_input.gd")
var size := 0
var heights := PackedFloat32Array()
var gradients := PackedVector2Array()
var free := PackedByteArray()
var clearance := PackedInt32Array()
var forms := PackedFloat32Array()
var world_size := 0

func prepare(n: int, ground: Callable, wet: PackedByteArray, input) -> void:
	world_size = n
	size = ceili(float(n) / STEP)
	var count := size * size
	heights.resize(count); gradients.resize(count); free.resize(count); clearance.resize(count); forms.resize(count)
	free.fill(1); clearance.fill(count)
	# Reduce every source cell once: thin rivers and infrastructure cannot vanish between samples.
	for z in n:
		for x in n:
			var cell := z * n + x
			var protected_cell: bool = input != null and (input.forbidden[cell] != 0 or (input.river_policy == GenerationInput.RiverPolicy.STRICT and input.rivers[cell] != 0))
			if wet[cell] != 0 or protected_cell: free[(z / STEP) * size + x / STEP] = 0
	var queue: Array[int] = []
	for z in size:
		for x in size:
			var i := z * size + x
			var p := point(i)
			heights[i] = ground.call(p)
			if input != null and input.blocked(p): free[i] = 0
			if not free[i] or x == 0 or z == 0 or x == size - 1 or z == size - 1:
				clearance[i] = 0; queue.append(i)
	var cursor := 0
	while cursor < queue.size():
		var i := queue[cursor]; cursor += 1
		for q in neighbours(i):
			if clearance[q] > clearance[i] + 1:
				clearance[q] = clearance[i] + 1; queue.append(q)
	var span := STEP * GameConfig.TILE
	for z in range(1, size - 1):
		for x in range(1, size - 1):
			var i := z * size + x
			gradients[i] = Vector2(heights[i + 1] - heights[i - 1], heights[i + size] - heights[i - size]) / (2 * span)
			forms[i] = (heights[i - 1] + heights[i + 1] + heights[i - size] + heights[i + size]) * 0.25 - heights[i]

func point(i: int) -> Vector2:
	return Vector2(mini(world_size - 1, (i % size) * STEP + STEP / 2), mini(world_size - 1, (i / size) * STEP + STEP / 2)) * GameConfig.TILE

func neighbours(i: int) -> Array[int]:
	var result: Array[int] = []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0: continue
			var x := i % size + dx
			var z := i / size + dz
			if x >= 0 and z >= 0 and x < size and z < size: result.append(z * size + x)
	return result

func feature(i: int) -> String:
	if gradients[i].length() < 0.04: return "площадка"
	if forms[i] < -1.0: return "гребень"
	if forms[i] > 1.0: return "ложбина"
	return "склон"

func anchors(seed_value: int) -> Array[int]:
	var result: Array[int] = []
	# A single spatial pass, not five sets of overlapping rectangular windows.
	for z in range(1, size - 1, 2):
		for x in range(1, size - 1, 2):
			var i := z * size + x
			if free[i]: result.append(i)
	result.sort_custom(func(a: int, b: int) -> bool:
		var sa := minf(clearance[a], 4) + minf(absf(forms[a]), 8) * 0.25 + minf(gradients[a].length(), 0.3)
		var sb := minf(clearance[b], 4) + minf(absf(forms[b]), 8) * 0.25 + minf(gradients[b].length(), 0.3)
		return sa > sb if sa != sb else posmod(hash([seed_value, a]), 999983) < posmod(hash([seed_value, b]), 999983))
	return result

## limits: box — сторона квадрата коридора, м; two_way — вести и вверх от начальной клетки (клетка посреди склона
## иначе даёт только нижнюю половину своего коридора). Без limits — прежние 448 м и только вниз.
func trace(start: int, seed_value: int, limits := {}) -> Dictionary:
	var kind := feature(start)
	var heading := -gradients[start].normalized()
	if heading.is_zero_approx(): heading = Vector2.from_angle(float(posmod(hash([seed_value, start]), 6283)) / 1000)
	var run := {path = PackedVector2Array([point(start)]), visited = {start: 0}, counter = 0, edge = float(limits.get("edge", 36.0)), steps = int(limits.get("steps", 24)), spaced = limits.get("two_way", false), bounds = Rect2(point(start), Vector2.ZERO), box = float(limits.get("box", 448.0)),
		work = 0.0, peak = 0.0, slope = 0.0, gentle = 0, end = start}
	_extend(run, start, heading, 1.0, kind)
	var last: int = run.end
	var first := start
	if limits.get("two_way", false):
		var tail: PackedVector2Array = run.path
		run.path = PackedVector2Array([point(start)])
		_extend(run, start, -heading, -1.0, kind)
		first = run.end
		var line: PackedVector2Array = run.path
		line.reverse()
		line.append_array(tail.slice(1))
		run.path = line
	var path: PackedVector2Array = run.path
	if path.size() < 2: return {}
	var bounds: Rect2 = run.bounds
	var length := preload("res://scripts/trails/trail_route_contract.gd").length(path)
	var pad := int(limits.get("pad", 8)) # запас рабочей области вокруг коридора, клеток: ходку есть где вилять
	var lo := Vector2i((bounds.position / GameConfig.TILE).floor()) - Vector2i.ONE * pad
	var hi := Vector2i((bounds.end / GameConfig.TILE).ceil()) + Vector2i.ONE * pad
	lo = lo.max(Vector2i.ZERO); hi = hi.min(Vector2i.ONE * world_size)
	var region_size := (hi - lo).max(Vector2i.ONE * 64).min(Vector2i.ONE * (ceili(float(run.box) / GameConfig.TILE) + pad * 2))
	lo = lo.min(Vector2i.ONE * world_size - region_size)
	var drop := heights[first] - heights[last]
	return {region = Rect2i(lo, region_size), feature = kind, fall = drop, slope = float(run.slope) / (path.size() - 1), gentle = float(run.gentle) / (path.size() - 1), water = 0.0,
		probe = {points = path, length = length, drop = drop, peak_grade = run.peak, straight_share = path[0].distance_to(path[-1]) / length, build_cost = float(run.work) / length, expanded = path.size(), method = "coarse_corridor"}}

## Клетка q рядом с уже пройденной, кроме последних: коридор не сворачивается клубком, в котором линии негде проехать.
func _crowded(run: Dictionary, q: int, p: int) -> bool:
	for n in neighbours(q):
		if n == p or not run.visited.has(n): continue
		if int(run.visited[n]) < int(run.visited[p]) - 1 or int(run.visited[n]) > int(run.visited[p]): return true
	return false

## Рост коридора от клетки p. Уклон считается по ходу седока: down = 1 — шаг идёт вниз по трассе, -1 — вверх, к её началу.
func _extend(run: Dictionary, p: int, heading: Vector2, down: float, kind: String) -> void:
	for step in int(run.steps):
		var best := -1
		var best_cost := INF
		for q in neighbours(p):
			if not free[q] or run.visited.has(q): continue
			if run.spaced and _crowded(run, q, p): continue
			var at := point(q)
			if at.x < run.edge or at.y < run.edge or at.x > world_size * GameConfig.TILE - run.edge or at.y > world_size * GameConfig.TILE - run.edge: continue
			var next_bounds: Rect2 = run.bounds.expand(at)
			if maxf(next_bounds.size.x, next_bounds.size.y) > run.box: continue
			var delta := at - point(p)
			var direction := delta.normalized()
			if direction.dot(heading) < 0: continue
			# A diagonal cannot skip through a blocked corner.
			if q % size != p % size and q / size != p / size:
				if not free[(p / size) * size + q % size] or not free[(q / size) * size + p % size]: continue
			var grade := (heights[q] - heights[p]) / delta.length() * down
			var cross := absf(gradients[q].dot(direction.orthogonal()))
			# Длинный коридор идёт траверсом и зигзагами, а не в лоб по склону: так у линии мало земляных работ.
			var cost := absf(grade + 0.07) * (8.0 if run.spaced else 2.0) + maxf(grade, 0) * 8 + cross * (0.5 if run.spaced else 2.0) + (1 - direction.dot(heading)) * 0.5 + 0.3 / (clearance[q] + 1)
			if kind == "гребень": cost += forms[q] * 0.05
			elif kind == "ложбина": cost -= forms[q] * 0.05
			if cost < best_cost: best_cost = cost; best = q
		if best < 0: break
		var delta := point(best) - point(p)
		run.peak = maxf(run.peak, absf(heights[best] - heights[p]) / delta.length())
		run.work += best_cost * delta.length()
		run.slope += gradients[best].length(); run.gentle += int(gradients[best].length() < 0.10)
		heading = delta.normalized(); p = best
		run.counter += 1
		run.visited[p] = run.counter; run.path.append(point(p)); run.bounds = run.bounds.expand(point(p))
	run.end = p
