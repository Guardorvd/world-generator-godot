extends RefCounted
## 13.1: консервативная трассировка входящих рек на неизменном рельефе.
## Результат — проект осей и профилей, не готовая вода для рендера/физики.
## 13.2: мелкие впадины получают профиль стока; глубокие остаются unresolved.
## Выход за край — передача следующему соседу, а не доказательство выхода к морю.

const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]


static func trace(region: Dictionary) -> Dictionary:
	var rivers: Array[Dictionary] = []
	var outlets: Array[Dictionary] = []
	var unresolved: Array[Dictionary] = []
	var inputs: Array = region.river_inputs.duplicate(true)
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.y < b.y or a.y == b.y and a.x < b.x)
	var occupied := {}
	for input: Dictionary in inputs:
		var result := _trace_one(region, input)
		if not result.has("points"):
			unresolved.append({input = input, reason = result.reason})
			continue
		var join := Vector2i(-1, -1) # номер старшего русла и индекс его точки
		var collision := -1
		for i in result.cells.size():
			if occupied.has(result.cells[i]):
				join = occupied[result.cells[i]]
				collision = i
				break
		if collision >= 0:
			var target: Dictionary = rivers[join.x].points[join.y]
			if result.points[collision].e < target.e:
				unresolved.append({input = input, reason = "confluence_level_conflict"})
				continue
			result.cells.resize(collision + 1)
			result.points.resize(collision + 2)
			result.points.back().e = target.e
			result.termination = "confluence"
			result.erase("outlet")
		for point: Dictionary in result.points: point.acc = input.acc
		for i in result.cells.size():
			if not occupied.has(result.cells[i]):
				occupied[result.cells[i]] = Vector2i(rivers.size(), i + 1)
		result.acc = input.acc
		result.join = join
		rivers.append(result)
		if collision >= 0: _add_flow(rivers, join, input.acc)
	# Все притоки уже учтены: синхронизировать ширину общей точки и конечные выходы.
	for river: Dictionary in rivers:
		if river.join.x >= 0:
			var target: Dictionary = rivers[river.join.x].points[river.join.y]
			river.points.back().w = target.w
			river.points.back().acc = target.acc
		if river.has("outlet"):
			river.outlet.acc = river.points.back().acc
			river.outlet.w = river.points.back().w
			outlets.append(river.outlet)
	return {rivers = rivers, outlets = outlets, unresolved = unresolved}


## Связи идут только к ранее принятым руслам, поэтому цикла и повторного стока нет.
static func _add_flow(rivers: Array[Dictionary], join: Vector2i, amount: float) -> void:
	while join.x >= 0:
		var river: Dictionary = rivers[join.x]
		for i in range(join.y, river.points.size()):
			var point: Dictionary = river.points[i]
			point.w *= sqrt((point.acc + amount) / point.acc)
			point.acc += amount
		join = river.join


static func _index(region: Dictionary, cell: Vector2i) -> int:
	var sample: Rect2i = region.sample_rect
	return (cell.y - sample.position.y) * sample.size.x + cell.x - sample.position.x


static func _level(region: Dictionary, cell: Vector2i) -> float:
	return maxf(0.0, region.fields.h[_index(region, cell)])


static func _trace_one(region: Dictionary, input: Dictionary) -> Dictionary:
	var rect: Rect2i = region.rect
	var sample: Rect2i = region.sample_rect
	var start := Vector2i(floori(input.x + input.dx * 0.5), floori(input.y + input.dy * 0.5))
	if not rect.has_point(start) or not is_finite(input.e) or input.e < 0.0 \
			or not is_finite(input.acc) or input.acc <= 0.0 or not is_finite(input.w) or input.w <= 0.0:
		return {reason = "invalid_input"}
	var fields: Dictionary = region.fields
	if fields.fixed[_index(region, start)] != 0 or _level(region, start) - input.e > 0.02:
		return {reason = "blocked_entry"}
	if _level(region, start) > input.e:
		return preload("res://scripts/world/region_drainage.gd").resolve(region, input)
	var queue: Array[Vector2i] = [start]
	var parent := {start: start}
	var head := 0
	var end := start
	var exit_direction := Vector2i.ZERO
	var found := false
	var sea := false
	# BFS выбирает кратчайший допустимый спуск; порядок соседей постоянный.
	# Уровень каждой клетки фиксирован исходным рельефом, поэтому одного посещения достаточно.
	while head < queue.size():
		var cell := queue[head]
		head += 1
		var level := _level(region, cell)
		if fields.ocean[_index(region, cell)] != 0:
			end = cell
			found = true
			sea = true
			break
		for direction: Vector2i in DIRECTIONS:
			var next := cell + direction
			if not sample.has_point(next): continue
			var idx := _index(region, next)
			if fields.fixed[idx] != 0 or _level(region, next) > level: continue
			if not rect.has_point(next):
				# Не возвращать реку через сторону, откуда она только что пришла.
				if direction.x * input.dx + direction.y * input.dy < 0: continue
				end = cell
				exit_direction = direction
				found = true
				break
			if not parent.has(next):
				parent[next] = cell
				queue.append(next)
		if found: break
	if not found: return preload("res://scripts/world/region_drainage.gd").resolve(region, input)
	var cells: Array[Vector2i] = [end]
	while cells.back() != start: cells.append(parent[cells.back()])
	cells.reverse()
	var points: Array[Dictionary] = [{x = input.x, y = input.y, e = input.e, w = input.w}]
	for cell: Vector2i in cells:
		points.append({x = cell.x + 0.5, y = cell.y + 0.5, e = _level(region, cell), w = input.w})
	var result := {points = points, cells = cells, termination = "ocean" if sea else "neighbor"}
	if not sea:
		var edge := Vector2(end) + Vector2.ONE * 0.5 + Vector2(exit_direction) * 0.5
		# На границе промежуточный уровень: сосед начнёт с той же точки, затем продолжит спуск.
		var level := (_level(region, end) + _level(region, end + exit_direction)) * 0.5
		points.append({x = edge.x, y = edge.y, e = level, w = input.w})
		result.outlet = {x = edge.x, y = edge.y, dx = exit_direction.x, dy = exit_direction.y,
			e = level, w = input.w, acc = input.acc}
	return result

