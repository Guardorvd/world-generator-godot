class_name Heightfield
extends RefCounted
## Рельеф и вода в метрах: высоты в центрах клеток, русла рек, уровень воды. Копия js/game/heightfield.js.
## Чистые данные и математика: по ним строятся меши и считается движение игрока.

const TILE := GameConfig.TILE
const HS := GameConfig.HS

var world: WorldData
var hv := PackedFloat32Array()      # высоты с прорезанными руслами
var hv_raw := PackedFloat32Array()  # высоты как в генераторе
var water_level := PackedFloat32Array() # уровень воды в клетке (или -INF, если воды нет)
var ribbons: Array = []             # средние линии рек: массивы точек {x, z, w — полуширина, y — уровень воды}


func _init(w: WorldData) -> void:
	world = w
	var N := w.N
	var W := w.W
	var H := w.H
	hv.resize(N)
	hv_raw.resize(N)
	for i in N:
		var h := w.h[i]
		hv_raw[i] = (maxf(-GameConfig.OCEAN_DEPTH, h * GameConfig.OCEAN_DEPTH) - 0.5) if w.ocean[i] != 0 else h * HS
		hv[i] = hv_raw[i] - (1.4 if w.river[i] != 0 else 0.0)
	# Реки: где лента срезает угол или идёт по диагонали между клетками берега,
	# рельеф под ней опускается чуть ниже воды, чтобы русло не уходило под землю
	ribbons = _river_ribbons()
	for pts in ribbons:
		for p in pts:
			var fx := clampf(p.x / TILE - 0.5, 0.0, W - 1.001)
			var fz := clampf(p.z / TILE - 0.5, 0.0, H - 1.001)
			var i := floori(fx)
			var j := floori(fz)
			var tri: Array
			if (fx - i) + (fz - j) <= 1.0:
				tri = [j * W + i, j * W + i + 1, (j + 1) * W + i]
			else:
				tri = [(j + 1) * W + i + 1, (j + 1) * W + i, j * W + i + 1]
			var bed: float = p.y - 0.3
			if ground_at(p.x, p.z) > bed:
				for k in tri:
					if hv[k] > bed:
						hv[k] = bed
	water_level.resize(N)
	water_level.fill(-INF)
	for i in N:
		if w.ocean[i] != 0:
			water_level[i] = 0.0
		elif w.lake[i] != 0:
			water_level[i] = w.filled[i] * HS
		elif w.river[i] != 0:
			water_level[i] = minf(hv_raw[i] - 0.45, hv[i] + 0.95) # брод: не глубже метра


## Средние линии рек в метрах: вода не выше берега и вниз по течению только убывает
func _river_ribbons() -> Array:
	var out: Array = []
	for r in world.rivers:
		var pts: Array = []
		for p in r:
			var x: float = p.x * TILE
			var z: float = p.y * TILE
			pts.append({x = x, z = z, w = p.w * TILE * 0.55 + 0.6, y = minf(p.e * HS, ground_at(x, z, true)) - 0.45})
		for k in range(1, pts.size()):
			pts[k].y = minf(pts[k].y, pts[k - 1].y)
		out.append(pts)
	return out


## Высота земли в точке (метры), по центрам клеток той же триангуляцией, что у сетки рельефа;
## raw — без прорезанных русел
func ground_at(x: float, z: float, raw: bool = false) -> float:
	var W := world.W
	var arr := hv_raw if raw else hv
	var fx := clampf(x / TILE - 0.5, 0.0, W - 1.001)
	var fz := clampf(z / TILE - 0.5, 0.0, world.H - 1.001)
	var i := floori(fx)
	var j := floori(fz)
	var tx := fx - i
	var tz := fz - j
	var a := arr[j * W + i]
	var b := arr[j * W + i + 1]
	var c := arr[(j + 1) * W + i]
	var d := arr[(j + 1) * W + i + 1]
	if tx + tz <= 1.0:
		return a + (b - a) * tx + (c - a) * tz
	return d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz)


## Глубина воды в точке (0, если сухо)
func depth_at(x: float, z: float) -> float:
	var tx := floori(x / TILE)
	var tz := floori(z / TILE)
	if tx < 0 or tz < 0 or tx >= world.W or tz >= world.H:
		return 0.0
	var l := water_level[tz * world.W + tx]
	if l == -INF:
		return 0.0
	return maxf(0.0, l - ground_at(x, z))
