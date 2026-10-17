class_name Heightfield
extends RefCounted
## Рельеф и вода в метрах: высоты в центрах клеток, русла рек, уровень воды. Копия js/game/heightfield.js.
## Чистые данные и математика: по ним строятся меши и считается движение игрока.
## С 1.8 здесь же мосты и туннели в метрах (build_structures): настил моста — опора для ног и колёс,
## перила моста и стены туннеля не пускают вбок, а пол туннеля — выемка, прорезанная в рельефе.

const TILE := GameConfig.TILE
const HS := GameConfig.HS
const BRIDGE_HALF := 2.0    # полуширина настила моста, м
const TUNNEL_HALF := 2.5    # полуширина туннеля, м
const TUNNEL_HEIGHT := 4.5  # высота туннеля, м
const TUNNEL_CUT := 2.3     # выемка под туннелем: клетки ближе этого к оси, в клетках (как StageTrails.TUNNEL_R)
const ARCH := 0.04          # подъём середины моста на метр длины (не больше 3 м)
const STEP := 0.8           # на настил можно шагнуть или въехать, если ноги не ниже него на столько
const WALL := 0.6           # толщина перил и стен, в которые упирается игрок, м

var world: WorldData
var hv := PackedFloat32Array()      # высоты с прорезанными руслами
var hv_raw := PackedFloat32Array()  # высоты как в генераторе
var water_level := PackedFloat32Array() # уровень воды в клетке (или -INF, если воды нет)
var ribbons: Array = []             # средние линии рек: массивы точек {x, z, w — полуширина, y — уровень воды}
## мосты и туннели: {tunnel, ax, az, ay, bx, bz, by — концы оси в метрах (y — настил или пол), half, len, ux, uz — направление}.
## Концы настила и пола вровень с землёй, чтобы на них въезжать без ступеньки
var structures: Array = []
var _cells := {}                    # клетка -> номера сооружений, которые её задевают


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
	build_structures()


## Мосты и туннели из w.bridges и w.tunnels в метрах; под туннелями рельеф опускается до пола.
## Вызывается и повторно, когда тропы проложены позже рельефа (загрузка в WorldLoader).
## Возвращает клетки, высота которых изменилась
func build_structures() -> PackedInt32Array:
	var W := world.W
	structures = []
	_cells = {}
	var changed := PackedInt32Array()
	for b in world.bridges:
		var s := _axis(b.a, b.b, false)
		s.ay = ground_at(s.ax, s.az)
		s.by = ground_at(s.bx, s.bz)
		structures.append(s)
	var tunnels: Array = []
	for t in world.tunnels:
		var s := _axis(t.a, t.b, true)
		s.ay = ground_at(s.ax, s.az)
		s.by = ground_at(s.bx, s.bz)
		structures.append(s)
		tunnels.append(s)
	# сначала рельеф за входами опускается до пола, потом пол внутри выравнивается:
	# так соседний туннель не опустит пол уже прорезанного
	for inside in [false, true]:
		for t: Dictionary in tunnels:
			_cut(t, inside, changed)
	# какие клетки задевает каждое сооружение (с запасом на перила и стены)
	for k in structures.size():
		var s: Dictionary = structures[k]
		var r: float = (s.half + WALL) / TILE + 1.0
		var ax: float = s.ax / TILE
		var az: float = s.az / TILE
		var bx: float = s.bx / TILE
		var bz: float = s.bz / TILE
		for y in range(maxi(0, floori(minf(az, bz) - r)), mini(world.H, ceili(maxf(az, bz) + r))):
			for x in range(maxi(0, floori(minf(ax, bx) - r)), mini(W, ceili(maxf(ax, bx) + r))):
				if Grid.segment_dist(x + 0.5, y + 0.5, ax, az, bx, bz) <= r:
					var i := y * W + x
					if not _cells.has(i):
						_cells[i] = []
					_cells[i].append(k)
	return changed


## Выемка под туннелем t: клетки ближе TUNNEL_CUT к оси. inside — ровнять пол внутри туннеля (иначе только
## опускать рельеф до пола у входов)
func _cut(t: Dictionary, inside: bool, changed: PackedInt32Array) -> void:
	var W := world.W
	var ax: float = t.ax / TILE
	var az: float = t.az / TILE
	var bx: float = t.bx / TILE
	var bz: float = t.bz / TILE
	for y in range(maxi(0, floori(minf(az, bz) - TUNNEL_CUT)), mini(world.H, ceili(maxf(az, bz) + TUNNEL_CUT))):
		for x in range(maxi(0, floori(minf(ax, bx) - TUNNEL_CUT)), mini(W, ceili(maxf(ax, bx) + TUNNEL_CUT))):
			if Grid.segment_dist(x + 0.5, y + 0.5, ax, az, bx, bz) > TUNNEL_CUT:
				continue
			var px := (x + 0.5) * TILE
			var pz := (y + 0.5) * TILE
			var along: float = (px - t.ax) * t.ux + (pz - t.az) * t.uz
			var floor_y := level(t, along)
			var i := y * W + x
			if (not inside and hv[i] > floor_y) or (inside and along > 0.0 and along < t.len and hv[i] != floor_y):
				hv[i] = floor_y
				changed.append(i)


## Ось сооружения между центрами клеток a и b
func _axis(a: int, b: int, tunnel: bool) -> Dictionary:
	var W := world.W
	var s := {tunnel = tunnel, half = TUNNEL_HALF if tunnel else BRIDGE_HALF,
		ax = (a % W + 0.5) * TILE, az = (a / W + 0.5) * TILE, bx = (b % W + 0.5) * TILE, bz = (b / W + 0.5) * TILE}
	s.len = Grid.hypot(s.bx - s.ax, s.bz - s.az)
	s.arch = 0.0 if tunnel else minf(s.len * ARCH, 3.0)
	s.ux = (s.bx - s.ax) / s.len
	s.uz = (s.bz - s.az) / s.len
	return s


## Высота настила или пола сооружения s в t метрах от начала оси. Мост выгнут дугой
## (s.arch — подъём середины), чтобы длинный настил не лежал на воде
func level(s: Dictionary, t: float) -> float:
	var u := clampf(t / s.len, 0.0, 1.0)
	return lerpf(s.ay, s.by, u) + s.arch * sin(PI * u)


## Высота настила моста под точкой (x, z), если ноги на высоте feet могут на нём стоять, иначе -INF
func deck_at(x: float, z: float, feet: float) -> float:
	var list = _cells.get(floori(z / TILE) * world.W + floori(x / TILE))
	if list == null:
		return -INF
	var best := -INF   # где мосты пересекаются, ноги на верхнем из тех, до которых достают
	for k in list:
		var s: Dictionary = structures[k]
		if s.tunnel:
			continue
		var dx: float = x - s.ax
		var dz: float = z - s.az
		var t: float = dx * s.ux + dz * s.uz
		if t < 0.0 or t > s.len or absf(dx * s.uz - dz * s.ux) > s.half:
			continue
		var d := level(s, t)
		if feet >= d - STEP:
			best = maxf(best, d)
	return best


## Опора в точке (x, z) для ног на высоте feet: настил моста, если он под ногами, иначе земля
func surface_at(x: float, z: float, feet: float) -> float:
	return maxf(ground_at(x, z), deck_at(x, z, feet))


## Перила моста или стена туннеля в точке (x, z) на высоте ног feet. Там, где сооружения сходятся,
## настил или пол одного не перегораживается перилами или стеной другого
func wall_at(x: float, z: float, feet: float) -> bool:
	var list = _cells.get(floori(z / TILE) * world.W + floori(x / TILE))
	if list == null:
		return false
	var wall := false
	for k in list:
		var s: Dictionary = structures[k]
		var dx: float = x - s.ax
		var dz: float = z - s.az
		var t: float = dx * s.ux + dz * s.uz
		var side := absf(dx * s.uz - dz * s.ux)
		if t < 0.0 or t > s.len or side > s.half + WALL:
			continue
		var d := level(s, t)
		var level: bool = feet < d + TUNNEL_HEIGHT if s.tunnel else (feet >= d - STEP and feet < d + 1.5)
		if not level:
			continue
		if side <= s.half:
			return false
		wall = true
	return wall


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


## Глубина воды в точке (0, если сухо или ноги на высоте feet стоят на мосту)
func depth_at(x: float, z: float, feet: float = -INF) -> float:
	if feet > -INF and deck_at(x, z, feet) > -INF:
		return 0.0
	var tx := floori(x / TILE)
	var tz := floori(z / TILE)
	if tx < 0 or tz < 0 or tx >= world.W or tz >= world.H:
		return 0.0
	var l := water_level[tz * world.W + tx]
	if l == -INF:
		return 0.0
	return maxf(0.0, l - ground_at(x, z))
