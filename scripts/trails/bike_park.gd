class_name BikePark
extends RefCounted
## Велопарк стартовой области: простой дешёвый поиск самой большой пустой области (без дорог, поселений, воды и
## сооружений) и прокладка в ней сети длинных извилистых трасс с разворотами и элементами. Без перебора участков и
## без построителя линии по рельефу: линии ведёт простой «ходок», рельеф под них готовит общее формирование
## (TrailShaping при запекании), элементы ставит общий TrailComposer. Детерминирован по сиду.
##
## Поиск: сетка через STRIDE клеток, расстояние до ближайшей занятой клетки (дороги, поселения, море, озёра, реки, кручи) (двухпроходная фаска 1 / √2), центр — самая
## дальняя точка; радиус парка — это расстояние минус запас, не больше R_MAX.
## Прокладка: магистраль от верхней точки области, затем ветки из случайных мест уже проложенных линий. Ходок шагает по
## STEP м: плавные изгибы (сумма синусоид), уход к горизонтали на крутом склоне и лёгкий уклон вниз на пологом, разворот
## радиуса HAIRPIN у края области или перед чужой линией. Ветка в конце ищет ближайшую линию и примыкает к ней — сеть.

const STRIDE := 2            # шаг сетки поиска, клеток
const SETTLE_R := 14.0       # поселение занимает круг такого радиуса вокруг центра, клеток
const HUT_R := 4.0           # и вокруг каждого дома
const STEEP_LAND := 0.35     # круче (≈19°) земля для парка занята: на кручах полотно уходит в глубокие насыпи, а запекание
                             # рельефа под них (TrailBuilder.bake_elements при каждой загрузке) растёт с шириной зоны работ
const MARGIN := 24.0         # запас от края области до линий, м
const R_MIN := 50.0          # меньше — парка нет, м
const R_MAX := 450.0         # дальше от центра парк не уходит, м
const STEP := 4.0            # шаг линии, м
const HAIRPIN := 8.0         # радиус разворота, м
const SEP := 12.0            # линии не ближе друг к другу, м
const LOOK := 24.0           # взгляд вперёд, м
const OWN_SKIP := 70.0       # свою линию ближе этой станции назад не считаем препятствием, м
const CELL := 8.0            # клетка индекса занятости, м
const GRADE := 0.10          # круче вдоль линии — штраф: на склоне линия идёт серпантином
const TRUNK := 2400.0        # длина магистрали, м
const BRANCH := Vector2(500.0, 1300.0)
const TARGET := 3000.0       # общая длина парка, м (ориентир: запекание растёт с длиной)
const ATTEMPTS := 80
const DEAD_END := 300.0      # ветка без примыкания остаётся, если не короче, м
const SEEK := 220.0          # ветка ищет примыкание не дальше, м
const WIDTH := 3.5
const PROFILES := ["flow", "mountain", "mixed", "technical", "flow", "forest"]
const NAMES := ["Магистраль", "Горная", "Смешанная", "Техничная", "Флоу", "Лесная"]

var center := Vector2.ZERO   ## м
var radius := 0.0            ## м, до ближайшего занятого места от центра
var extent := 0.0            ## м, самая дальняя точка трасс от центра
var routes: Array[TrailDefinition] = []
var reason := ""
var stats := {find_ms = 0.0, layout_ms = 0.0, length = 0.0, attempts = 0, stops = {}}

var _h: Heightfield
var _rng := RandomNumberGenerator.new()
var _occ := {}
var _field := PackedFloat32Array() # расстояние до занятого, шагов сетки поиска
var _rect := Rect2i()
var _gw := 0
var _gh := 0
var _ground_fn := Callable()
var _inside_fn := Callable()


## Найти область в rect (клетки) и проложить парк. Пустой routes и reason — места нет.
static func build(w: WorldData, h: Heightfield, rect: Rect2i, prefix: String) -> BikePark:
	var park := BikePark.new()
	park._h = h
	park._rng.seed = hash(w.seed_text + "|bike_park")
	var t := Time.get_ticks_usec()
	park._find(w, rect)
	park.stats.find_ms = (Time.get_ticks_usec() - t) / 1000.0
	if park.radius < R_MIN:
		park.reason = "нет пустой области радиусом от %.0f м (самая большая %.0f м)" % [R_MIN, park.radius]
		return park
	t = Time.get_ticks_usec()
	park._layout(prefix)
	park.stats.layout_ms = (Time.get_ticks_usec() - t) / 1000.0
	if park.routes.is_empty(): park.reason = "линии парка не проложились"
	return park


func _find(w: WorldData, rect: Rect2i) -> void:
	var gw := maxi(1, rect.size.x / STRIDE)
	var gh := maxi(1, rect.size.y / STRIDE)
	var d := PackedFloat32Array()
	d.resize(gw * gh)
	d.fill(1e9)
	# занято: дороги (path_mask 3; тропы и звериные тропы пересекать можно), море, озёра и настоящие реки (ручьи — нет)
	var mask := w.path_mask
	var has_mask := mask.size() == w.N
	var ocean := w.ocean
	var lake := w.lake
	var river := w.river
	var acc := w.acc
	var hv := _h.hv
	for gz in gh:
		for gx in gw:
			if gx == 0 or gz == 0 or gx == gw - 1 or gz == gh - 1:
				d[gz * gw + gx] = 0.0
				continue
			var cx := rect.position.x + gx * STRIDE
			var cz := rect.position.y + gz * STRIDE
			var busy := false
			for oz in STRIDE:
				for ox in STRIDE:
					var i := (cz + oz) * w.W + cx + ox
					if (has_mask and mask[i] >= 3) or ocean[i] != 0 or lake[i] != 0 or (river[i] != 0 and acc[i] >= WorldData.RIVER_ACC): busy = true
					var sx := (hv[mini(i + 1, w.N - 1)] - hv[maxi(i - 1, 0)]) / (2.0 * GameConfig.TILE)
					var sz := (hv[mini(i + w.W, w.N - 1)] - hv[maxi(i - w.W, 0)]) / (2.0 * GameConfig.TILE)
					if sx * sx + sz * sz > STEEP_LAND * STEEP_LAND: busy = true
			if busy: d[gz * gw + gx] = 0.0
	var discs: Array[Vector3] = []
	for v: SettlementData in w.settlements:
		discs.append(Vector3(v.x, v.y, SETTLE_R))
		for hut in v.huts: discs.append(Vector3(hut.x, hut.y, HUT_R))
	for s: Dictionary in _h.structures:
		var foot := TrailSite.structure_foot(s)
		var c := foot.get_center() / GameConfig.TILE
		discs.append(Vector3(c.x, c.y, foot.size.length() * 0.5 / GameConfig.TILE + 2.0))
	for disc in discs:
		var r := disc.z / STRIDE
		var c := (Vector2(disc.x, disc.y) - Vector2(rect.position)) / STRIDE
		for gz in range(maxi(0, floori(c.y - r)), mini(gh, ceili(c.y + r) + 1)):
			for gx in range(maxi(0, floori(c.x - r)), mini(gw, ceili(c.x + r) + 1)):
				if Vector2(gx, gz).distance_to(c) <= r: d[gz * gw + gx] = 0.0
	# двухпроходная фаска: вперёд и назад
	var diag := sqrt(2.0)
	for gz in range(1, gh):
		for gx in range(1, gw - 1):
			var i := gz * gw + gx
			d[i] = minf(d[i], minf(minf(d[i - 1] + 1.0, d[i - gw] + 1.0), minf(d[i - gw - 1] + diag, d[i - gw + 1] + diag)))
	var best := 0
	for gz in range(gh - 2, -1, -1):
		for gx in range(gw - 2, 0, -1):
			var i := gz * gw + gx
			d[i] = minf(d[i], minf(minf(d[i + 1] + 1.0, d[i + gw] + 1.0), minf(d[i + gw + 1] + diag, d[i + gw - 1] + diag)))
			if d[i] > d[best]: best = i
	center = (Vector2(rect.position) + Vector2(best % gw, best / gw) * STRIDE + Vector2.ONE * STRIDE * 0.5) * GameConfig.TILE
	radius = minf(R_MAX, d[best] * STRIDE * GameConfig.TILE - MARGIN)
	_field = d
	_rect = rect
	_gw = gw
	_gh = gh


func _ground(p: Vector2) -> float:
	return _h.ground_at(p.x, p.y) if _h != null else float(_ground_fn.call(p))


## Только прокладка на заданном рельефе и области (изолированная проверка tools/bike_park_look.gd, без мира).
static func lay_out(ground: Callable, inside: Callable, at: Vector2, r: float, seed_text: String, prefix: String) -> BikePark:
	var park := BikePark.new()
	park._ground_fn = ground
	park._inside_fn = inside
	park.center = at
	park.radius = r
	park._rng.seed = hash(seed_text + "|bike_park")
	var t := Time.get_ticks_usec()
	park._layout(prefix)
	park.stats.layout_ms = (Time.get_ticks_usec() - t) / 1000.0
	return park


func _layout(prefix: String) -> void:
	# магистраль — от самой высокой точки внутри области
	var top := center
	for k in 48:
		var p := center + Vector2.from_angle(TAU * k / 48.0) * radius * 0.8
		if _inside(p) and _ground(p) > _ground(top): top = p
	var heading := (center - top).angle() if top != center else _rng.randf() * TAU
	_mark(top, 0, 0.0)
	var trunk := _walk(top, heading, TRUNK, 0, false)
	if trunk.size() < 20: return
	_add(trunk, prefix)
	var total := routes[0].route_length()
	while total < TARGET and stats.attempts < ATTEMPTS:
		stats.attempts += 1
		# начало ветки — лучшее из нескольких случайных мест: туда, где впереди больше свободной земли
		var at := Vector2.ZERO
		var dir := Vector2.ZERO
		var room := -1
		for k in 12:
			var parent := routes[_rng.randi() % routes.size()]
			var s := _rng.randf_range(0.05, 0.95) * parent.route_length()
			var side := 1.0 if _rng.randf() < 0.5 else -1.0
			var c_dir := parent.tangent_at(s).rotated(side * _rng.randf_range(0.9, 1.4))
			var c_at := parent.point_at(s)
			var free := 0
			for j in range(1, 13):
				var q := c_at + c_dir * (20.0 + j * 15.0)
				if not _inside(q): break
				if _blocked(q, -1, 0.0, Vector2.INF): continue
				free += 1
			if free > room:
				room = free
				at = c_at
				dir = c_dir
		if room < 3: continue
		var line := _walk(at, dir.angle(), _rng.randf_range(BRANCH.x, BRANCH.y), routes.size(), true)
		if line.size() < 50: # короче ~200 м ветка не нужна
			_purge(routes.size())
			continue
		_add(line, prefix)
		total += routes[-1].route_length()
	stats.length = total
	for d in routes:
		for q in d.points: extent = maxf(extent, q.distance_to(center))


## Линия от start: точки через STEP. route — номер линии в индексе занятости, seek — в конце искать примыкание
## к другой линии (не нашла — остаётся тупиком, если не короче DEAD_END). Каждый шаг — лучшее из направлений веером
## вокруг желаемого, поворот за шаг не круче радиуса HAIRPIN: свободно и внутри области, уклон не круче GRADE (иначе
## штраф), лёгкий спуск, поменьше поворот, и впереди свободно (взгляд на LOOK: чем ближе тупик, тем больше штраф).
## Упёрлась впереди — поворачивает до упора в одну сторону, так и получаются развороты и серпантины.
func _walk(start: Vector2, heading: float, length: float, route: int, seek: bool) -> PackedVector2Array:
	var pts := PackedVector2Array([start])
	var p := start
	var a := heading
	var s := 0.0
	var ph := Vector2(_rng.randf() * TAU, _rng.randf() * TAU)
	var limit := length + (SEEK if seek else 0.0)
	var target := Vector2.INF
	var bend := 0.0 # поворот прошлого шага
	var max_turn := STEP / HAIRPIN
	while s < limit:
		var seeking := seek and s >= length
		if seeking:
			var join := _nearest_other(p, route, SEEK)
			if join.z < INF:
				target = Vector2(join.x, join.y)
				if target.distance_to(p) < STEP * 1.5:
					if target.distance_to(pts[-1]) > 0.5: pts.append(target)
					return pts
		var want := (0.05 * sin(s / 43.0 + ph.x) + 0.035 * sin(s / 17.0 + ph.y)) * STEP
		if seeking and target != Vector2.INF:
			want = clampf(Vector2.from_angle(a).angle_to(target - p), -max_turn, max_turn)
		var best := INF
		var best_o := 0.0
		for k in 11:
			var o := -max_turn + max_turn * 0.2 * k
			var dir := Vector2.from_angle(a + o)
			var next := p + dir * STEP
			if not _free(next, route, s, start, target): continue
			var g := (_ground(next) - _ground(p)) / STEP
			var cost := absf(o - want) + maxf(0.0, absf(g) - GRADE) * 40.0 + absf(g + 0.04) * 2.0
			for j in range(1, 5):
				if not _free(p + dir * (STEP + LOOK * j / 4.0), route, s, start, target):
					cost += 40.0 / j - (1.0 if signf(o) == signf(bend) else 0.0)
					break
			if cost < best:
				best = cost
				best_o = o
		if best == INF:
			_stop("некуда шагнуть")
			if not seek or seeking: break
			length = s # ветка дальше ищет примыкание
			continue
		a += best_o
		bend = best_o
		p += Vector2.from_angle(a) * STEP
		s += STEP
		pts.append(p)
		_mark(p, route, s)
	if s >= limit: _stop("длина")
	if seek and s < DEAD_END: return PackedVector2Array()
	return pts


func _stop(why: String) -> void:
	stats.stops[why] = stats.stops.get(why, 0) + 1


## Внутри пустой области и не на чужой линии; у цели примыкания линии не мешают.
func _free(p: Vector2, route: int, s: float, start: Vector2, target: Vector2) -> bool:
	if not _inside(p): return false
	if target != Vector2.INF and p.distance_to(target) < SEP + STEP: return true
	return not _blocked(p, route, s, start)


func _inside(p: Vector2) -> bool:
	if _inside_fn.is_valid(): return _inside_fn.call(p)
	# воду (и ручьи) линии пока обходят: у воды рельеф не формируется, и переход через ручей выходит крутым
	var cell := Vector2i((p / GameConfig.TILE).floor())
	for oz in range(-1, 2):
		for ox in range(-1, 2):
			var q := cell + Vector2i(ox, oz)
			if q.x < 0 or q.y < 0 or q.x >= _h.world.W or q.y >= _h.world.H or _h.water_level[q.y * _h.world.W + q.x] != -INF: return false
	if p.distance_to(center) > R_MAX: return false
	var c := Vector2i(((p / GameConfig.TILE - Vector2(_rect.position)) / STRIDE).floor())
	if c.x < 0 or c.y < 0 or c.x >= _gw or c.y >= _gh: return false
	return _field[c.y * _gw + c.x] * STRIDE * GameConfig.TILE >= MARGIN


## Убрать из индекса линию, которую не приняли.
func _purge(route: int) -> void:
	for k: Vector2i in _occ:
		_occ[k] = (_occ[k] as Array).filter(func(e: Vector4) -> bool: return int(e.z) != route)


func _key(p: Vector2) -> Vector2i:
	return Vector2i((p / CELL).floor())


func _mark(p: Vector2, route: int, s: float) -> void:
	var k := _key(p)
	if not _occ.has(k): _occ[k] = []
	(_occ[k] as Array).append(Vector4(p.x, p.y, route, s))


## Занято чужой линией (или своей далеко назад). Начало ветки у родительской линии не считается.
func _blocked(p: Vector2, route: int, s: float, start: Vector2) -> bool:
	if s < 40.0 and p.distance_to(start) < 30.0: return false
	var k := _key(p)
	for oz in range(-2, 3):
		for ox in range(-2, 3):
			for e: Vector4 in _occ.get(k + Vector2i(ox, oz), []):
				if Vector2(e.x, e.y).distance_to(p) >= SEP: continue
				if int(e.z) == route and e.w > s - OWN_SKIP: continue
				return true
	return false


## Ближайшая точка другой линии (x, y, расстояние) не дальше reach, иначе z = INF.
func _nearest_other(p: Vector2, route: int, reach: float) -> Vector3:
	var best := Vector3(0, 0, INF)
	var n := ceili(reach / CELL)
	var k := _key(p)
	for oz in range(-n, n + 1):
		for ox in range(-n, n + 1):
			for e: Vector4 in _occ.get(k + Vector2i(ox, oz), []):
				if int(e.z) == route: continue
				var dist := Vector2(e.x, e.y).distance_to(p)
				if dist < best.z and dist <= reach: best = Vector3(e.x, e.y, dist)
	return best


func _add(points: PackedVector2Array, prefix: String) -> void:
	var n := routes.size()
	var d := TrailDefinition.new()
	d.id = "%s/%d" % [prefix, n]
	d.title = "Велопарк · %s" % (NAMES[n] if n < NAMES.size() else "Ветка %d" % n)
	d.kind = "mountain"
	d.width = WIDTH
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	d.points = points
	var profile: Dictionary = TrailComposer.PROFILES[PROFILES[n % PROFILES.size()]]
	d.elements.assign(TrailComposer.compose(d, profile, _rng.randi(), _ground).elements)
	routes.append(d)
