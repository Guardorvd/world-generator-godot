class_name Heightfield
extends RefCounted
## Рельеф и вода в метрах: высоты в центрах клеток, русла рек, уровень воды. Копия js/game/heightfield.js.
## Чистые данные и математика: по ним строятся меши и считается движение игрока.
## С 4.4 ground_at также читает локальную метровую сетку дорог RoadRefinement.
## С 1.8 здесь же мосты и туннели в метрах (build_structures): настил моста — опора для ног и колёс,
## перила моста и стены туннеля не пускают вбок, а пол туннеля — выемка, прорезанная в рельефе.

const TILE := GameConfig.TILE
const HS := GameConfig.HS
const BRIDGE_HALF := 2.6    # настил шире основной дороги, чтобы опираться на берег по обе стороны въезда
const TUNNEL_HALF := 2.5    # полуширина туннеля, м
const TUNNEL_HEIGHT := 4.5  # высота туннеля, м
const TUNNEL_CUT := StageTrails.TUNNEL_R   # выемка под туннелем: клетки ближе этого к оси, в клетках
const ARCH := 0.04          # подъём середины моста на метр длины (не больше 3 м)
const STEP := 0.8           # на настил можно шагнуть или въехать, если ноги не ниже него на столько
const WALL := 0.6           # толщина перил моста, в которые упирается игрок, м
const TUNNEL_WALL := 1.0    # толщина стен туннеля, м (как у их модели в StructuresBuilder)

var world: WorldData
var hv := PackedFloat32Array()      # высоты с прорезанными руслами
var hv_raw := PackedFloat32Array()  # высоты как в генераторе
var water_level := PackedFloat32Array() # уровень воды в клетке (или -INF, если воды нет)
var ribbons: Array = []             # средние линии рек: массивы точек {x, z, w — полуширина, y — уровень воды}
var _river_cells := {}             # клетка -> сегменты ленты; одни треугольники для воды и depth_at
## мосты и туннели: {tunnel, ax, az, ay, bx, bz, by — концы оси в метрах (y — настил или пол), half, len, ux, uz — направление}.
## Концы настила и пола вровень с землёй, чтобы на них въезжать без ступеньки
var structures: Array = []
var _cells := {}                    # клетка -> номера сооружений, которые её задевают
var road_refinement: RoadRefinement # 4.4: метровая сетка только у дорог, общая для меша и опоры
var path_timings := {}


## with_structures — мир уже готов: сразу выровнять полотно путей (RoadBed, с 4.3) и посчитать мосты
## и туннели (build_structures). WorldLoader строит рельеф раньше, чем тропы готовы, и передаёт false:
## пути, мосты и туннели в это время ещё пишет генератор (его рельеф для поиска — без полотна)
func _init(w: WorldData, with_structures := true) -> void:
	world = w
	var N := w.N
	var W := w.W
	var H := w.H
	hv.resize(N)
	hv_raw.resize(N)
	for i in N:
		var h := w.h[i]
		hv_raw[i] = (maxf(-GameConfig.OCEAN_DEPTH, h * GameConfig.OCEAN_DEPTH) - 0.5) if w.ocean[i] != 0 else h * HS
		hv[i] = hv_raw[i]
	# Сначала полный профиль дна/берега, затем защита непрерывного стрежня.
	ribbons = _river_ribbons()
	_carve_rivers()
	for pts: Array in ribbons:
		for p: Dictionary in pts:
			var fx := clampf(p.x / TILE - 0.5, 0.0, W - 1.001)
			var fz := clampf(p.z / TILE - 0.5, 0.0, H - 1.001)
			var i := floori(fx)
			var j := floori(fz)
			var tri: Array[int]
			if (fx - i) + (fz - j) <= 1.0:
				tri = [j * W + i, j * W + i + 1, (j + 1) * W + i]
			else:
				tri = [(j + 1) * W + i + 1, (j + 1) * W + i, j * W + i + 1]
			var bed: float = p.y - p.depth
			var cut := ground_at(p.x, p.z) - bed
			if cut > 0.0:
				# Сдвиг треугольника сохраняет уже заданный поперечный профиль;
				# выравнивание всех вершин в одну отметку стирало отмели.
				for k: int in tri:
					hv[k] -= cut
	_fit_river_banks()
	water_level.resize(N)
	water_level.fill(-INF)
	for i in N:
		if w.ocean[i] != 0:
			water_level[i] = 0.0
		elif w.lake[i] != 0:
			water_level[i] = w.filled[i] * HS
		elif w.river_cells()[i] != 0:
			# Для коридора A* и закрепления берегов — верхняя оценка по ленте.
			# В точке depth_at проверяет её фактические треугольники.
			var level := river_level((i % W + 0.5) * TILE, (i / W + 0.5) * TILE)
			water_level[i] = maxf(level, w.filled[i] * HS - WaterBuilder.LAKE_DROP) if w.river[i] != 0 else level
	for cell: int in _river_cells:
		if w.ocean[cell] != 0 or w.lake[cell] != 0:
			continue
		for segment: Dictionary in _river_cells[cell]:
			water_level[cell] = maxf(water_level[cell], maxf(segment.a.y, segment.b.y))
	if with_structures:
		finish_paths()


## Завершить игровой рельеф после генерации путей. Один раз на исходном Heightfield:
## сначала базовое полотно, затем сооружения и метровая сетка для меша и движения.
## Возвращает изменённые вершины базовой сетки для уже подготовленного меша загрузчика.
func finish_paths() -> PackedInt32Array:
	var t := Time.get_ticks_usec()
	var changed := RoadBed.refine(self)
	path_timings.road_bed_ms = (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	changed.append_array(build_structures())
	path_timings.structures_ms = (Time.get_ticks_usec() - t) / 1000.0
	road_refinement = RoadRefinement.build(self)
	path_timings.merge(road_refinement.build_timings)
	return changed


## Мосты и туннели из w.bridges и w.tunnels в метрах; под туннелями рельеф опускается до пола.
## Вызывается один раз: из _init или, когда тропы проложены позже рельефа, из WorldLoader.
## Возвращает клетки, высота которых изменилась
func build_structures() -> PackedInt32Array:
	var W := world.W
	structures = []
	_cells = {}
	var changed := PackedInt32Array()
	for b: Dictionary in world.bridges:
		var s := _axis(b.a, b.b, false)
		s.ay = ground_at(s.ax, s.az)
		s.by = ground_at(s.bx, s.bz)
		structures.append(s)
	var tunnels: Array = []
	for t: Dictionary in world.tunnels:
		var s := _axis(t.a, t.b, true)
		s.ay = ground_at(s.ax, s.az)
		s.by = ground_at(s.bx, s.bz)
		structures.append(s)
		tunnels.append(s)
	# сначала рельеф за входами опускается до пола, потом пол внутри выравнивается:
	# так соседний туннель не опустит пол уже прорезанного
	for inside: bool in [false, true]:
		for t: Dictionary in tunnels:
			_cut(t, inside, changed)
	# какие клетки задевает каждое сооружение (с запасом на перила и стены)
	for k in structures.size():
		var s: Dictionary = structures[k]
		var r: float = (s.half + TUNNEL_WALL) / TILE + 1.0
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
	# концы не могут совпасть (иначе направление оси не считается), длина не ниже сантиметра
	s.len = maxf(Grid.hypot(s.bx - s.ax, s.bz - s.az), 0.01)
	s.arch = 0.0 if tunnel else minf(s.len * ARCH, 3.0)
	s.ux = (s.bx - s.ax) / s.len
	s.uz = (s.bz - s.az) / s.len
	return s


## Высота настила или пола сооружения s в t метрах от начала оси. Мост выгнут дугой
## (s.arch — подъём середины), чтобы длинный настил не лежал на воде
func level(s: Dictionary, t: float) -> float:
	var u := clampf(t / s.len, 0.0, 1.0)
	return lerpf(s.ay, s.by, u) + s.arch * sin(PI * u)


## Сооружения, которые задевает клетка с точкой (x, z); null, если точка за картой (сооружений там нет)
func _cell_list(x: float, z: float) -> Variant:
	var cx := floori(x / TILE)
	var cz := floori(z / TILE)
	if cx < 0 or cz < 0 or cx >= world.W or cz >= world.H:
		return null
	return _cells.get(cz * world.W + cx)


## Высота настила моста под точкой (x, z), если ноги на высоте feet могут на нём стоять, иначе -INF
func deck_at(x: float, z: float, feet: float) -> float:
	var list: Variant = _cell_list(x, z)
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


## Перила моста или стена туннеля ближе r к точке (x, z) на высоте ног feet: r — радиус тела, которое
## проверяется (игрок, колесо велосипеда, камера). Там, где сооружения сходятся, настил или пол одного
## не перегораживается перилами или стеной другого
func wall_at(x: float, z: float, feet: float, r: float = 0.0) -> bool:
	var list: Variant = _cell_list(x, z)
	if list == null:
		return false
	var wall := false
	for k in list:
		var s: Dictionary = structures[k]
		var dx: float = x - s.ax
		var dz: float = z - s.az
		var t: float = dx * s.ux + dz * s.uz
		var side := absf(dx * s.uz - dz * s.ux)
		if t < 0.0 or t > s.len or side > s.half + (TUNNEL_WALL if s.tunnel else WALL) + r:
			continue
		var d := level(s, t)
		var on_level: bool = feet < d + TUNNEL_HEIGHT if s.tunnel else (feet >= d - STEP and feet < d + 1.5)
		if not on_level:
			continue
		if side <= s.half - r:
			return false
		wall = true
	return wall


## Средние линии рек в метрах: вода не выше берега и вниз по течению только убывает
func _river_ribbons() -> Array:
	var out: Array = []
	for r: Array in world.rivers:
		var pts: Array = []
		for p: Dictionary in r:
			var x: float = p.x * TILE
			var z: float = p.y * TILE
			pts.append({x = x, z = z, w = StageRivers.half_width(p.w), y = maxf(0.0, p.e * HS - WaterBuilder.LAKE_DROP),
				depth = clampf(0.3 + p.w * 0.6, 0.45, 1.2)})
		for k in range(1, pts.size()):
			pts[k].y = minf(pts[k].y, pts[k - 1].y)
		for k in pts.size():
			var p: Dictionary = pts[k]
			var a: Dictionary = pts[maxi(0, k - 1)]
			var b: Dictionary = pts[mini(pts.size() - 1, k + 1)]
			var dir := Vector2(b.x - a.x, b.z - a.z).normalized()
			if dir.length_squared() < 0.1:
				dir = Vector2.RIGHT
			p.left = Vector3(p.x - dir.y * p.w, p.y, p.z + dir.x * p.w)
			p.right = Vector3(p.x + dir.y * p.w, p.y, p.z - dir.x * p.w)
			# Внутренний берег изгиба — мельче, внешний — глубже.
			var incoming := Vector2(p.x - a.x, p.z - a.z).normalized()
			var outgoing := Vector2(b.x - p.x, b.z - p.z).normalized()
			p.bend = clampf(incoming.cross(outgoing) * 3.0, -1.0, 1.0)
			p.motion = river_motion(pts, k)
		out.append(pts)
	return out


## Направление, скорость (0..1) и пороги: общие для поверхности и следа.
static func river_motion(pts: Array, k: int) -> Vector4:
	var a: Dictionary = pts[maxi(0, k - 1)]
	var b: Dictionary = pts[mini(pts.size() - 1, k + 1)]
	var delta := Vector2(b.x - a.x, b.z - a.z)
	var grade := maxf(0.0, a.y - b.y) / maxf(delta.length(), 0.01)
	var dir := delta.normalized()
	var speed := clampf(0.22 + sqrt(grade) * 1.8 + 0.12 / maxf(pts[k].w, 0.01), 0.22, 1.0)
	return Vector4(dir.x, dir.y, speed, smoothstep(0.025, 0.24, grade))


## Локальное течение на видимой реке. Озеро и море сохраняют спокойный след.
func current_at(x: float, z: float) -> Vector2:
	var level_here := river_level(x, z)
	if level_here <= maxf(0.0, lake_level(x, z)) + 0.001:
		return Vector2.ZERO
	var cell := floori(z / TILE) * world.W + floori(x / TILE)
	for s: Dictionary in _river_cells.get(cell, []):
		var top := maxf(_water_triangle(x, z, s.a.left, s.a.right, s.b.left),
			_water_triangle(x, z, s.b.left, s.a.right, s.b.right))
		if absf(top - level_here) > 0.001:
			continue
		var delta := Vector2(s.b.x - s.a.x, s.b.z - s.a.z)
		var u := clampf(Vector2(x - s.a.x, z - s.a.z).dot(delta) / maxf(delta.length_squared(), 0.0001), 0.0, 1.0)
		var motion: Vector4 = s.a.motion.lerp(s.b.motion, u)
		return Vector2(motion.x, motion.y).normalized() * lerpf(0.3, 2.8, motion.z)
	return Vector2.ZERO


## Малая локальная подрезка базовой сетки: стрежень, отмель внутри изгиба,
## пологая кромка. В озере сохраняем его дно. Никакой отдельной симуляции.
func _carve_rivers() -> void:
	var W := world.W
	for pts: Array in ribbons:
		for k in range(1, pts.size()):
			var a: Dictionary = pts[k - 1]
			var b: Dictionary = pts[k]
			var delta := Vector2(b.x - a.x, b.z - a.z)
			var len2 := delta.length_squared()
			if len2 < 1e-8:
				continue
			var reach := maxf(a.w, b.w) * 1.8 + TILE
			for y in range(maxi(0, floori((minf(a.z, b.z) - reach) / TILE)), mini(world.H, ceili((maxf(a.z, b.z) + reach) / TILE))):
				for x in range(maxi(0, floori((minf(a.x, b.x) - reach) / TILE)), mini(W, ceili((maxf(a.x, b.x) + reach) / TILE))):
					var i := y * W + x
					var offset := Vector2((x + 0.5) * TILE - a.x, (y + 0.5) * TILE - a.z)
					var u := clampf(offset.dot(delta) / len2, 0.0, 1.0)
					var width := lerpf(a.w, b.w, u)
					var distance := (offset - delta * u).length()
					if world.ocean[i] != 0 or world.lake[i] != 0 or distance >= width * 1.8:
						continue
					var t := distance / width
					var level := lerpf(a.y, b.y, u)
					var depth := lerpf(a.depth, b.depth, u)
					var bend := lerpf(a.bend, b.bend, u)
					var inside := maxf(0.0, -signf(offset.cross(delta)) * bend)
					var bed := level - depth * (1.0 - 0.85 * smoothstep(0.15, 1.0, t))
					bed += inside * depth * 0.55 * smoothstep(0.1, 0.7, t)
					if t > 1.0:
						bed = lerpf(level + 0.06, hv_raw[i], smoothstep(1.0, 1.8, t))
					hv[i] = minf(hv[i], bed)


## Сетка дна грубее ленты: после подрезки вода должна доходить до реального
## берега, а не обрываться на исходной расчётной ширине посреди впадины.
func _fit_river_banks() -> void:
	for pts: Array in ribbons:
		for p: Dictionary in pts:
			var normal := Vector2(p.left.x - p.x, p.left.z - p.z).normalized()
			for side in [1.0, -1.0]:
				var reach: float = p.w
				if p.y > maxf(0.0, lake_level(p.x, p.z)) + 0.001:
					reach = 0.0
					var limit: float = p.w + TILE
					while reach < limit:
						reach += 0.5
						var q: Vector2 = Vector2(p.x, p.z) + normal * side * reach
						if ground_at(q.x, q.y) >= p.y + 0.02:
							break
					# У обрыва нет бокового берега: не растягиваем поток
					# в висящую над соседней долиной широкую плоскость.
					if reach >= limit:
						reach = p.w
				var bank := Vector3(p.x + normal.x * side * reach, p.y, p.z + normal.y * side * reach)
				if side > 0.0:
					p.left = bank
				else:
					p.right = bank
		# Индекс строится по окончательным берегам, как и видимые треугольники.
		for k in range(1, pts.size()):
			var a: Dictionary = pts[k - 1]
			var b: Dictionary = pts[k]
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for v: Vector3 in [a.left, a.right, b.left, b.right]:
				lo = lo.min(Vector2(v.x, v.z))
				hi = hi.max(Vector2(v.x, v.z))
			var segment := {a = a, b = b}
			for z in range(maxi(0, floori(lo.y / TILE)), mini(world.H, floori(hi.y / TILE) + 1)):
				for x in range(maxi(0, floori(lo.x / TILE)), mini(world.W, floori(hi.x / TILE) + 1)):
					var cell := z * world.W + x
					if not _river_cells.has(cell):
						_river_cells[cell] = []
					_river_cells[cell].append(segment)


## Уровень на тех же треугольниках, которые WaterBuilder отдаёт GPU.
## -INF снаружи ленты, даже в клетке исходного стока.
func river_level(x: float, z: float) -> float:
	if x < 0.0 or z < 0.0 or x >= world.W * TILE or z >= world.H * TILE:
		return -INF
	var cell := floori(z / TILE) * world.W + floori(x / TILE)
	var top := -INF
	for s: Dictionary in _river_cells.get(cell, []):
		top = maxf(top, _water_triangle(x, z, s.a.left, s.a.right, s.b.left))
		top = maxf(top, _water_triangle(x, z, s.b.left, s.a.right, s.b.right))
	return top


func lake_level(x: float, z: float) -> float:
	var cx := floori(x / TILE - 0.5)
	var cy := floori(z / TILE - 0.5)
	if cx < 0 or cy < 0 or cx >= world.W - 1 or cy >= world.H - 1:
		return -INF
	var a := cy * world.W + cx
	var top := -INF
	for i in [a, a + 1, a + world.W, a + world.W + 1]:
		if world.lake[i] != 0:
			top = maxf(top, world.filled[i] * HS - WaterBuilder.LAKE_DROP)
	return top


static func _water_triangle(x: float, z: float, a: Vector3, b: Vector3, c: Vector3) -> float:
	var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(denominator) < 1e-8:
		return -INF
	var u := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / denominator
	var v := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / denominator
	if u < -1e-5 or v < -1e-5 or u + v > 1.00001:
		return -INF
	return u * a.y + v * b.y + (1.0 - u - v) * c.y


## Высота земли в точке (метры), по центрам клеток той же триангуляцией, что у сетки рельефа;
## raw — без прорезанных русел. За краем карты — рельеф OuterLand, если он подключён (иначе высота края)
func ground_at(x: float, z: float, raw: bool = false) -> float:
	if not raw and road_refinement != null:
		var local := road_refinement.height_at(x, z, world.W)
		if local != INF:
			return local
	return base_ground_at(x, z, raw)


## Сетка 4 м без локальной детализации, также используется при её подготовке.
func base_ground_at(x: float, z: float, raw: bool = false) -> float:
	var W := world.W
	var arr := hv_raw if raw else hv
	var fx := x / TILE - 0.5
	var fz := z / TILE - 0.5
	var a: float
	var b: float
	var c: float
	var d: float
	var i: int
	var j: int
	if world.outer == null or (fx >= 0.0 and fz >= 0.0 and fx <= W - 1.001 and fz <= world.H - 1.001):
		fx = clampf(fx, 0.0, W - 1.001)
		fz = clampf(fz, 0.0, world.H - 1.001)
		i = floori(fx)
		j = floori(fz)
		a = arr[j * W + i]
		b = arr[j * W + i + 1]
		c = arr[(j + 1) * W + i]
		d = arr[(j + 1) * W + i + 1]
	else:
		i = floori(fx)
		j = floori(fz)
		a = _cell_height(arr, i, j)
		b = _cell_height(arr, i + 1, j)
		c = _cell_height(arr, i, j + 1)
		d = _cell_height(arr, i + 1, j + 1)
	var tx := fx - i
	var tz := fz - j
	if tx + tz <= 1.0:
		return a + (b - a) * tx + (c - a) * tz
	return d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz)


## Высота клетки (i, j): на карте из arr (hv или hv_raw), за краем — из OuterLand
func _cell_height(arr: PackedFloat32Array, i: int, j: int) -> float:
	if i >= 0 and j >= 0 and i < world.W and j < world.H:
		return arr[j * world.W + i]
	return outer_meters(world.outer.height(i, j))


## Высота клетки за краем карты (OuterLand, единицы WorldData.h) в метрах: ниже 0 — дно моря, как у
## клеток океана на карте. Копия развёрнута в OuterTerrain._build
static func outer_meters(h: float) -> float:
	return h * HS if h >= 0.0 else maxf(-GameConfig.OCEAN_DEPTH, h * GameConfig.OCEAN_DEPTH) - 0.5


## Известна ли земля в точке (x, z): на карте всегда, за краем — если OuterLand уже посчитал клетки вокруг.
## Без OuterLand (самопроверки) мир кончается в клетке от края карты, как до 1.9.5
func known(x: float, z: float) -> bool:
	var outer := world.outer
	if outer == null:
		return x >= TILE and z >= TILE and x <= (world.W - 1) * TILE and z <= (world.H - 1) * TILE
	if x >= 0.0 and z >= 0.0 and x <= world.W * TILE and z <= world.H * TILE:
		return true # клетки сразу за краем — в кольце OuterLand, оно есть всегда
	var i := floori(x / TILE - 0.5)
	var j := floori(z / TILE - 0.5)
	return outer.has(i, j) and outer.has(i + 1, j) and outer.has(i, j + 1) and outer.has(i + 1, j + 1)


## Глубина воды в точке (0, если сухо или ноги на высоте feet стоят на мосту)
func depth_at(x: float, z: float, feet: float = -INF) -> float:
	if feet > -INF and deck_at(x, z, feet) > -INF:
		return 0.0
	var tx := floori(x / TILE)
	var tz := floori(z / TILE)
	if tx < 0 or tz < 0 or tx >= world.W or tz >= world.H:
		# за краем карты вода только морская: клетка ниже уровня моря
		if world.outer == null or world.outer.height(tx, tz) >= 0.0:
			return 0.0
		return maxf(0.0, -ground_at(x, z))
	# Плоскость моря рисуется во всём мире; в углублениях ниже нуля она
	# также видима, даже если центр клетки относится к речному берегу.
	var l := maxf(0.0, maxf(river_level(x, z), lake_level(x, z)))
	return maxf(0.0, l - ground_at(x, z))


## Погружение ног/низа колеса, в отличие от полной глубины под ними.
## На мосту и в прыжке над поверхностью — ноль.
func immersion_at(x: float, z: float, feet: float) -> float:
	var depth := depth_at(x, z, feet)
	if depth <= 0.0:
		return 0.0
	return clampf(ground_at(x, z) + depth - feet, 0.0, depth)
