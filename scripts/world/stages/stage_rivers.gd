class_name StageRivers
extends RefCounted
## Этап 4. Трассировка рек в ломаные: от истока до устья, слияния или озера.
## Пишет: w.rivers — массив ломаных из точек {x, y, w — ширина в клетках, e — высота воды}.

const PROGRESS := 0.3
const LABEL := "Русла рек и озёра"


static func _width_of(w: WorldData, i: int) -> float:
	return 0.22 + minf(1.5, sqrt(w.acc[i] / WorldData.RIVER_ACC) * 0.2)


## e — высота воды (0 — уровень моря): вдоль стока она только убывает
static func _pt(w: WorldData, i: int) -> Dictionary:
	return {
		x = (i % w.W) + 0.5, y = (i / w.W) + 0.5, w = _width_of(w, i),
		e = 0.0 if w.ocean[i] != 0 else maxf(0.0, w.filled[i]),
	}


static func run(w: WorldData) -> void:
	var N := w.N
	var ocean := w.ocean
	var lake := w.lake
	var river := w.river
	var down := w.down
	var acc := w.acc
	var rivers: Array = []
	var has_donor := PackedByteArray()
	has_donor.resize(N)
	var lake_donor := PackedInt32Array()
	lake_donor.resize(N)
	lake_donor.fill(-1)
	for i in N:
		var d := down[i]
		if d < 0 or river[d] == 0:
			continue
		if river[i] != 0:
			has_donor[d] = 1
		elif lake[i] != 0 and (lake_donor[d] < 0 or acc[i] > acc[lake_donor[d]]):
			lake_donor[d] = i
	var visited := PackedByteArray()
	visited.resize(N)
	for s in N:
		if river[s] == 0 or has_donor[s] != 0:
			continue
		var pts: Array = []
		if lake_donor[s] >= 0:
			var p := _pt(w, lake_donor[s])
			p.w = _width_of(w, s)
			pts.append(p)
		var c := s
		while true:
			pts.append(_pt(w, c))
			visited[c] = 1
			var d := down[c]
			if d < 0:
				break
			if ocean[d] != 0 or lake[d] != 0:
				var p := _pt(w, d)
				p.w = _width_of(w, c) * 1.3
				pts.append(p)
				break
			if river[d] == 0:
				break
			if visited[d] != 0:
				pts.append(_pt(w, d))
				break
			c = d
		if pts.size() >= 3:
			rivers.append(Grid.chaikin(pts, 2))
	w.rivers = rivers
