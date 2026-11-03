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

func trace(start: int, seed_value: int) -> Dictionary:
	var kind := feature(start)
	var path := PackedVector2Array([point(start)])
	var visited := {start: true}
	var p := start
	var heading := -gradients[start].normalized()
	if heading.is_zero_approx(): heading = Vector2.from_angle(float(posmod(hash([seed_value, start]), 6283)) / 1000)
	var bounds := Rect2(path[0], Vector2.ZERO)
	var work := 0.0
	var peak := 0.0
	var slope := 0.0
	var gentle := 0
	for step in 24:
		var best := -1
		var best_cost := INF
		for q in neighbours(p):
			if not free[q] or visited.has(q): continue
			var at := point(q)
			if at.x < 36 or at.y < 36 or at.x > world_size * GameConfig.TILE - 36 or at.y > world_size * GameConfig.TILE - 36: continue
			var next_bounds := bounds.expand(at)
			if maxf(next_bounds.size.x, next_bounds.size.y) > 448: continue
			var delta := at - point(p)
			var direction := delta.normalized()
			if direction.dot(heading) < 0: continue
			# A diagonal cannot skip through a blocked corner.
			if q % size != p % size and q / size != p / size:
				if not free[(p / size) * size + q % size] or not free[(q / size) * size + p % size]: continue
			var grade := (heights[q] - heights[p]) / delta.length()
			var cross := absf(gradients[q].dot(direction.orthogonal()))
			var cost := absf(grade + 0.07) * 2 + maxf(grade, 0) * 8 + cross * 2 + (1 - direction.dot(heading)) * 0.5 + 0.3 / (clearance[q] + 1)
			if kind == "гребень": cost += forms[q] * 0.05
			elif kind == "ложбина": cost -= forms[q] * 0.05
			if cost < best_cost: best_cost = cost; best = q
		if best < 0: break
		var delta := point(best) - point(p)
		peak = maxf(peak, absf(heights[best] - heights[p]) / delta.length())
		work += best_cost * delta.length()
		slope += gradients[best].length(); gentle += int(gradients[best].length() < 0.10)
		heading = delta.normalized(); p = best
		visited[p] = true; path.append(point(p)); bounds = bounds.expand(point(p))
	if path.size() < 2: return {}
	var length := preload("res://scripts/trails/trail_route_contract.gd").length(path)
	var lo := Vector2i((bounds.position / GameConfig.TILE).floor()) - Vector2i.ONE * 8
	var hi := Vector2i((bounds.end / GameConfig.TILE).ceil()) + Vector2i.ONE * 8
	lo = lo.max(Vector2i.ZERO); hi = hi.min(Vector2i.ONE * world_size)
	var region_size := (hi - lo).max(Vector2i.ONE * 64).min(Vector2i.ONE * 128)
	lo = lo.min(Vector2i.ONE * world_size - region_size)
	return {region = Rect2i(lo, region_size), feature = kind, fall = heights[start] - heights[p], slope = slope / (path.size() - 1), gentle = float(gentle) / (path.size() - 1), water = 0.0,
		probe = {points = path, length = length, drop = heights[start] - heights[p], peak_grade = peak, straight_share = path[0].distance_to(path[-1]) / length, build_cost = work / length, expanded = path.size(), method = "coarse_corridor"}}
