extends RefCounted
## Ограниченный priority flood от допустимых выходов. Не меняет исходный рельеф.
const MAX_FILL := 0.012 # подъём уровня над исходной землёй, 3.12 м
const MAX_CUT := 0.02 # выемка входа и русла, 5.2 м
const DIRS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]


static func resolve(r: Dictionary, input: Dictionary) -> Dictionary:
	var rect: Rect2i = r.rect
	var sample: Rect2i = r.sample_rect
	var levels := {}
	var down := {}
	var exits := {}
	var heap := MinHeap.new(rect.get_area())
	# Адрес heap — локальный индекс, словари — мировые клетки.
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := Vector2i(x, y)
			if r.fields.fixed[idx(r, c)] != 0: continue
			var raw := height(r, c)
			if raw - input.e > MAX_CUT: continue
			var h := minf(raw, input.e)
			var best := INF
			var direction := Vector2i.ZERO
			if r.fields.ocean[idx(r, c)] != 0:
				best = 0.0
			else:
				for d: Vector2i in DIRS:
					var next := c + d
					if rect.has_point(next) or not sample.has_point(next): continue
					if d.x * input.dx + d.y * input.dy < 0 or r.fields.fixed[idx(r, next)] != 0: continue
					var beyond := height(r, next)
					if beyond - input.e > MAX_CUT: continue
					var level := maxf(h, minf(beyond, input.e))
					if level < best:
						best = level
						direction = d
			if best > input.e or best - raw > MAX_FILL: continue
			levels[c] = best
			exits[c] = direction
			heap.push((y - rect.position.y) * rect.size.x + x - rect.position.x, best)
	var settled := {}
	while heap.n > 0:
		var id := heap.pop()
		var c := rect.position + Vector2i(id % rect.size.x, id / rect.size.x)
		if settled.has(c): continue
		settled[c] = true
		for d: Vector2i in DIRS:
			var next := c + d
			if not rect.has_point(next) or settled.has(next) or r.fields.fixed[idx(r, next)] != 0: continue
			var raw := height(r, next)
			if raw - input.e > MAX_CUT: continue
			var h := minf(raw, input.e)
			var level := maxf(h, levels[c])
			if level > input.e or level - raw > MAX_FILL or level >= levels.get(next, INF): continue
			levels[next] = level
			down[next] = c
			exits.erase(next)
			heap.push((next.y - rect.position.y) * rect.size.x + next.x - rect.position.x, level)
	var start := Vector2i(floori(input.x + input.dx * 0.5), floori(input.y + input.dy * 0.5))
	if not levels.has(start): return {reason = "basin_requires_resolution"}
	var cells: Array[Vector2i] = []
	var points: Array[Dictionary] = [{x = input.x, y = input.y, e = input.e, w = input.w}]
	var c := start
	while true:
		cells.append(c)
		points.append({x = c.x + 0.5, y = c.y + 0.5, e = levels[c], w = input.w})
		if not down.has(c): break
		c = down[c]
	var d: Vector2i = exits[c]
	var result := {cells = cells, points = points, termination = "ocean" if d == Vector2i.ZERO else "neighbor"}
	if d != Vector2i.ZERO:
		var edge := Vector2(c) + Vector2.ONE * 0.5 + Vector2(d) * 0.5
		# Та же высота на выходе и у принимающего соседа; следующий рельеф не выше неё.
		points.append({x = edge.x, y = edge.y, e = levels[c], w = input.w})
		result.outlet = {x = edge.x, y = edge.y, dx = d.x, dy = d.y, e = levels[c], w = input.w, acc = input.acc}
	return result


static func idx(r: Dictionary, c: Vector2i) -> int:
	return (c.y - r.sample_rect.position.y) * r.sample_rect.size.x + c.x - r.sample_rect.position.x


static func height(r: Dictionary, c: Vector2i) -> float:
	return maxf(0.0, r.fields.h[idx(r, c)])
