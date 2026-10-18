class_name Pathfinder
extends RefCounted
## Поиск пути A* по сетке со стоимостью прохода клеток (8 направлений). Копия js/core/pathfinding.js.
## Стоимость прохода передаётся в каждый поиск, поэтому её можно менять между вызовами
## (так протоптанные тропы становятся дешевле). INF — непроходимо. Знает только размер сетки, не мир.
## Куча из MinHeap развёрнута прямо в цикле поиска: в GDScript вызовы методов дороги, а алгоритм тот же.
## В сборке Godot .NET поиск ведёт FastGrid.FindPath: тот же алгоритм на C#, в десятки раз быстрее.

var W := 0
var H := 0
var g := PackedFloat32Array()
var from := PackedInt32Array()
var seen := PackedInt32Array()
var done := PackedInt32Array()
var heap_ids := PackedInt32Array()
var heap_keys := PackedFloat64Array()
var gen := 0
var _fast: Object = null


func _init(width: int, height: int) -> void:
	W = width
	H = height
	_fast = Grid.fast_grid()
	if _fast != null:
		_fast.Setup(W, H)
		return
	g.resize(W * H)
	from.resize(W * H)
	seen.resize(W * H)
	done.resize(W * H)
	heap_ids.resize(1 << 16)
	heap_keys.resize(1 << 16)


## Путь от клетки s до клетки t (индексы клеток) по стоимости прохода cost или пустой массив, если пути нет
func find_path(cost: PackedFloat32Array, s: int, t: int) -> PackedInt32Array:
	if _fast != null:
		return _fast.FindPath(cost, s, t)
	var W := self.W
	var H := self.H
	var g := self.g
	var from := self.from
	var seen := self.seen
	var done := self.done
	var ids := heap_ids
	var keys := heap_keys
	var DX := PackedInt32Array(Grid.DX)
	var DY := PackedInt32Array(Grid.DY)
	var DL := PackedFloat64Array(Grid.DL)
	var OFF := PackedInt32Array()
	for k in 8:
		OFF.append(DY[k] * W + DX[k])
	var W1 := W - 1
	var H1 := H - 1
	gen += 1
	var gn := gen
	var tx := t % W
	var ty := t / W
	g[s] = 0.0
	seen[s] = gn
	from[s] = -1
	ids[0] = s
	keys[0] = 0.0
	var hn := 1
	while hn > 0:
		# извлечь минимум из кучи
		var c := ids[0]
		hn -= 1
		if hn > 0:
			var id := ids[hn]
			var kk := keys[hn]
			var i := 0
			while true:
				var l := 2 * i + 1
				if l >= hn:
					break
				var r := l + 1
				if r < hn and keys[r] < keys[l]:
					l = r
				if keys[l] >= kk:
					break
				ids[i] = ids[l]
				keys[i] = keys[l]
				i = l
			ids[i] = id
			keys[i] = kk
		if c == t:
			break
		if done[c] == gn:
			continue
		done[c] = gn
		var cx := c % W
		var cy := c / W
		var gc := g[c]
		var cc := cost[c]
		# у клеток не на краю все 8 соседей внутри карты: проверка границ не нужна
		var inner := cx > 0 and cy > 0 and cx < W1 and cy < H1
		for k in 8:
			var nx := cx + DX[k]
			var ny := cy + DY[k]
			var n := c + OFF[k]
			if not inner and (nx < 0 or ny < 0 or nx >= W or ny >= H):
				continue
			var cn := cost[n]
			if cn == INF or done[n] == gn:
				continue
			var ng := gc + DL[k] * (cc + cn) * 0.5
			if seen[n] != gn or ng < g[n]:
				seen[n] = gn
				g[n] = ng
				from[n] = c
				var ax := absi(nx - tx)
				var ay := absi(ny - ty)
				var key: float = ng + (maxi(ax, ay) + 0.414 * mini(ax, ay)) * 0.6
				# добавить в кучу
				if hn >= ids.size():
					ids.resize(ids.size() * 2)
					keys.resize(keys.size() * 2)
				var i := hn
				hn += 1
				while i > 0:
					var p := (i - 1) >> 1
					if keys[p] <= key:
						break
					ids[i] = ids[p]
					keys[i] = keys[p]
					i = p
				ids[i] = n
				keys[i] = key
	heap_ids = ids
	heap_keys = keys
	var path := PackedInt32Array()
	if seen[t] != gn:
		return path
	var c := t
	while c != -1:
		path.append(c)
		c = from[c]
	path.reverse()
	return path
