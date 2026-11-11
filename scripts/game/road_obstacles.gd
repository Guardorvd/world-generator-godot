class_name RoadObstacles
extends RefCounted
## 11.6: природные препятствия на дорогах и тропах — ветки, россыпь камней, упавшие брёвна, валуны, корни.
## Только оформление готового мира, как подстилка 9.4: мир, маршруты, хеши и ключи кэша (10.2) не меняются.
## Места берутся примерно через 4 м по готовой линии. Хеш отрезка решает, лежит ли на нём
## что-нибудь и что; корни выбираются хешем положения дерева. Кандидаты сохраняются только в текущем окне подлеска.
## Раскладывает VegetationLayer
## в фоновой задаче подлеска (те же MultiMesh, дальность и проверки), столкновения и кочки уходят в ForestObstacles.
## 15.0: у каждого препятствия есть причина рядом, случай отвечает только за разнообразие:
##  - корни — от настоящего крупного ствола у кромки полотна (деревья мира, w.obj_*): один-три корня идут от него
##    наискосок через тропу, середина выступает, концы уходят в грунт; на открытой грунтовке корней нет;
##  - камни — порода (каменистость), скальные выходы и россыпи выше по склону, крутое размытое полотно; ложатся
##    к нижнему краю, частью в грунте; на равнинной дороге их почти нет;
##  - брёвна и ветки — только там, где рядом растут деревья; бревно чаще лежит вдоль кромки или наискосок,
##    поперёк всей тропы — редко, на дороге — почти никогда; длина и посадка в подстилку разные;
##  - валун — у края со стороны подъёма на косогоре под скалами.
## Ступени: ветки, камни и корни — кочка под колесом (подвеска); валун у края — объехать; бревно — перепрыгнуть
## (верх до 0,4 м); в бревно или валун в лоб быстрее BikeRide.WALL_CRASH — падение.

const TILE := GameConfig.TILE
enum { BRANCH, STONES, LOG, BOULDER, ROOT }
const KIND_SCALE := {road = 0.6, trail = 1.0, mountain = 0.8} # дорогу расчищают, горную тропу засыпает камнем
const MAX_P := 0.26      # верхний предел вероятности, прежде чем учесть местность
const CHUNK := 8         # клеток в стороне ячейки индекса линий
const SAMPLE_STEP := 3.8 # м: скругление пути может добавлять точки через полметра
const CLEAR_R := 45.0    # у старта (вступительный проезд 11.0) пусто, м
const VILLAGE := 9.0     # ближе к поселению или месту (клеток) дорогу расчистили
const STRUCTURE := 3     # клеток до моста или туннеля: у настила ничего не лежит
const JUNCTION := 8.0    # ближе к другому пути (м) — развилка, не загромождаем
const SEED := 11606
## Кочка мелкого препятствия под колесом: [радиус, высота] при масштабе 1, м
const BUMP := {BRANCH: Vector2(0.14, 0.07), STONES: Vector2(0.65, 0.11), ROOT: Vector2(0.08, 0.05)}
const ROOT_REACH := 3.5  # от кромки полотна до ствола, м: дальше корни на тропу не выходят
const ROOT_TREE := 0.85  # масштаб дерева, с которого у него крупные корни (как у корней у ствола в VegetationLayer)
const LOOK := 6.0        # радиус поиска причин вокруг отрезка за кромкой, м
## Сколько корней даёт тропе ствол по покрытию полотна: лесная подстилка и грунт — да, гравий и укатанная земля — редко
const ROOT_SURFACE := [0.0, 0.2, 0.8, 0.15, 0.5, 0.1, 1.0, 0.6]

var world: WorldData
var clear: Array[Vector2] = [] # места без препятствий (старт), м
var _index := {}               # Vector2i(ячейка) -> PackedInt32Array пар (маршрут, точка)
var _sampled: Array[PackedInt32Array] = [] # номер станции -> исходная точка пути
var _along: Array[PackedFloat32Array] = []
var _authored := {}
var _cache := {} # Only the current detail window, including rejected candidates.
var _cache_signature := []
var evaluations := 0
var _trails: Array = []
var _regions := {}
var placement: RefCounted
var _context_stamp := []
var _revision := 0


func _init(w: WorldData) -> void:
	world = w
	_trails = w.trails.duplicate()
	if w.trail_plan.get("state") == "found":
		for d: TrailDefinition in StageTrailPlan._kit(w.trail_plan):
			_authored[d.id] = d
	_build_index()


func _build_index() -> void:
	_index.clear()
	_sampled.clear()
	_along.clear()
	_sampled.resize(_trails.size())
	_along.resize(_trails.size())
	for route in _trails.size():
		var t: Dictionary = _trails[route]
		if not KIND_SCALE.has(t.kind) or t.pts.size() < 2:
			continue
		var samples := PackedInt32Array([0])
		var previous := _point(t, 0)
		var distance := 0.0
		var along := PackedFloat32Array([0.0])
		var station := 0.0
		for n in range(1, t.pts.size()):
			var point := _point(t, n)
			var step := previous.distance_to(point)
			distance += step
			station += step
			previous = point
			if distance >= SAMPLE_STEP or n == t.pts.size() - 1:
				samples.append(n)
				along.append(station)
				distance = 0.0
		_sampled[route] = samples
		_along[route] = along
		for n in range(1, samples.size()):
			var mid := (_point(t, samples[n - 1]) + _point(t, samples[n])) * 0.5
			var key := Vector2i((mid / (CHUNK * TILE)).floor())
			var list: PackedInt32Array = _index.get(key, PackedInt32Array())
			list.append_array([route, n])
			_index[key] = list


## Published region records already contain the existing routes in world cells.
## Reuse them; no autonomous trail generation or regional copies of WorldData.
func sync_regions(regions: Dictionary, object_placement: RefCounted, batches: Array = [], revision := 0) -> void:
	placement = object_placement
	_context_stamp = []
	for b in range(1, batches.size()):
		var batch: Dictionary = batches[b]
		_context_stamp.append_array([batch.x.size(), batch.x[0] if not batch.x.is_empty() else 0.0,
			batch.y[0] if not batch.y.is_empty() else 0.0])
	var changed := revision != _revision
	_revision = revision
	if not changed and (is_same(regions, _regions) or (regions.is_empty() and _regions.is_empty())): return
	_regions = regions
	_trails = world.trails.duplicate()
	_authored.clear()
	if world.trail_plan.get("state") == "found":
		for d: TrailDefinition in StageTrailPlan._kit(world.trail_plan): _authored[d.id] = d
	var keys := regions.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	for key: Vector2i in keys:
		var region: Dictionary = regions[key]
		if region.has("fields"):
			_trails.append_array(region.get("decor", {}).get("trails", []))
			if region.get("trail_plan", {}).get("state") == "found":
				for d: TrailDefinition in StageTrailPlan._kit(region.trail_plan): _authored[d.id] = d
	_build_index()
	invalidate()


## Пары (маршрут, точка) линий в радиусе r (м) от (x, z), по ячейкам индекса
func around(x: float, z: float, r: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var side := CHUNK * TILE
	for cy in range(floori((z - r) / side), floori((z + r) / side) + 1):
		for cx in range(floori((x - r) / side), floori((x + r) / side) + 1):
			var list: Variant = _index.get(Vector2i(cx, cy))
			if list != null:
				for p in range(0, list.size(), 2):
					var route: int = list[p]
					var end: int = list[p + 1]
					var samples := _sampled[route]
					var mid := (_point(_trails[route], samples[end - 1]) + _point(_trails[route], samples[end])) * 0.5
					# The placement index has a 12 m context halo around this exact
					# window. Caching whole corner buckets could remember a false
					# empty result before its trees entered that halo.
					if mid.distance_squared_to(Vector2(x, z)) <= r * r:
						out.append_array([route, end])
	return out


func _roll(route: int, n: int, salt: int) -> float:
	var samples := _sampled[route]
	var p := (_point(_trails[route], samples[maxi(0, n - 1)]) + _point(_trails[route], samples[mini(n, samples.size() - 1)])) * 0.5 / TILE + Vector2(world.world_origin)
	return WGRandom.hash2(roundi(p.x * 97.0), roundi(p.y * 89.0), world.seed_num ^ (SEED + salt * 31))


static func _point(t: Dictionary, n: int) -> Vector2:
	return Vector2(t.pts[n].x, t.pts[n].y) * TILE


## Что растёт и лежит у отрезка: число деревьев, ближайший крупный ствол у кромки (x, z, масштаб; x = INF — нет) и его
## зазор до кромки, сколько камня выше по склону. Только объекты мира в чанках вокруг, без новых карт.
func _context(mid: Vector2, dir: Vector2, side: Vector2, half: float, length: float, uphill: float) -> Dictionary:
	var out := {trees = 0, root = Vector3(INF, 0.0, 0.0), owner = -1, gap = INF, rocks = 0.0}
	if placement != null:
		var records: Array = placement.nature_around(mid, half + LOOK)
		for at in range(0, records.size(), 6):
			_consider(out, Vector2(records[at], records[at + 1]), int(records[at + 4]), records[at + 5], int(records[at + 3]), mid, dir, side, half, length, uphill)
		return out
	if world.CS <= 0 or world.chunks.is_empty():
		return out
	var r := half + LOOK
	var span := world.CS * TILE
	for cy in range(maxi(0, floori((mid.y - r) / span)), mini(world.CH, floori((mid.y + r) / span) + 1)):
		for cx in range(maxi(0, floori((mid.x - r) / span)), mini(world.CW, floori((mid.x + r) / span) + 1)):
			for o: int in world.chunks[cy * world.CW + cx]:
				var p := Vector2(world.obj_x[o], world.obj_y[o]) * TILE
				_consider(out, p, world.obj_k[o], world.obj_s[o], o, mid, dir, side, half, length, uphill)
	return out


func _consider(out: Dictionary, p: Vector2, kind: int, s: float, owner: int, mid: Vector2, dir: Vector2, side: Vector2, half: float, length: float, uphill: float) -> void:
	var off := p - mid
	if absf(off.x) > half + LOOK or absf(off.y) > half + LOOK: return
	var lateral := off.dot(side)
	if kind == Biomes.T_ROCK:
		if uphill != 0.0 and lateral * uphill > half: out.rocks += minf(s, 1.5)
		return
	if not Biomes.is_tree(kind) or s < 0.6: return
	out.trees += 1
	var along := off.dot(dir)
	if s < ROOT_TREE or not StageVegetation.TRUNK.has(kind) or along < -length * 0.5 or along >= length * 0.5: return
	var gap := absf(lateral) - half
	var previous: Vector3 = out.root
	var first := p.x < previous.x or (p.x == previous.x and p.y < previous.y)
	if gap >= 0.0 and gap < ROOT_REACH and (gap < out.gap or (is_equal_approx(gap, out.gap) and first)):
		out.gap = gap
		out.root = Vector3(p.x, p.y, s)
		out.owner = owner


## Препятствие на отрезке между станциями n − 1 и n маршрута route или {}.
## parts — все экземпляры (у корней их до трёх), у каждого kind, x, z, rot, scale, stretch (длина вдоль локальной X),
## sink (насколько утоплен в грунт, м). rot — поворот вокруг вертикали, как у подлеска (локальная X — вдоль бревна,
## ветки и корня).
func invalidate() -> void:
	_cache.clear()
	_cache_signature.clear()


## The caller owns the worker; no global cache, locks or persistent world data.
func begin_fill(h: Heightfield, surface: Image, pairs: PackedInt32Array) -> void:
	var signature := [h.get_instance_id(), h.road_refinement, surface.get_instance_id(), clear.hash(), world.obj_count, _context_stamp]
	if signature != _cache_signature:
		_cache.clear()
		_cache_signature = signature
	var wanted := {}
	for p in range(0, pairs.size(), 2): wanted[Vector2i(pairs[p], pairs[p + 1])] = true
	for key: Vector2i in _cache.keys():
		if not wanted.has(key): _cache.erase(key)


func pick(h: Heightfield, surface: Image, route: int, n: int) -> Dictionary:
	var key := Vector2i(route, n)
	if not _cache_signature.is_empty() and _cache.has(key): return _cache[key]
	evaluations += 1
	var result := _pick(h, surface, route, n)
	if not _cache_signature.is_empty(): _cache[key] = result
	return result


## Read existing authored definitions; missing metadata remains protected.
func protected(route: int, station: float, extent := 5.0) -> bool:
	var t: Dictionary = _trails[route]
	if not t.has("trail_id"): return false
	var d: TrailDefinition = _authored.get(t.trail_id)
	if d == null: return true
	if station < extent + 8.0 or station > d.route_length() - extent - 8.0: return true
	for e: TrailElement in d.elements:
		var margin := 10.0 if e.profile in [TrailElement.Profile.TABLETOP, TrailElement.Profile.GAP, TrailElement.Profile.DROP] else 6.0
		if absf(station - e.station) <= e.length * 0.5 + extent + margin: return true
	return false


func _pick(h: Heightfield, surface: Image, route: int, n: int) -> Dictionary:
	var t: Dictionary = _trails[route]
	var samples := _sampled[route]
	if n < 3 or n > samples.size() - 3:
		return {}
	if protected(route, (_along[route][n - 1] + _along[route][n]) * 0.5): return {}
	var roll := _roll(route, n, 0)
	# соседние отрезки не заняты вместе: бревно и камни не ложатся друг на друга
	var debris := roll < MAX_P and _roll(route, n - 1, 0) >= MAX_P
	var a := _point(t, samples[n - 1])
	var b := _point(t, samples[n])
	var length := a.distance_to(b)
	if length < 1.0:
		return {}
	var dir := (b - a) / length
	var side := Vector2(-dir.y, dir.x)
	var mid := (a + b) * 0.5
	var i := floori(mid.x / TILE)
	var j := floori(mid.y / TILE)
	var inside := i >= 0 and j >= 0 and i < world.W and j < world.H
	var k := j * world.W + i
	var regional := {}
	var ground: Color
	if inside:
		ground = surface.get_pixel(i, j)
	else:
		var key := Vector2i(floori(float(i) / WorldData.REGION_SIZE), floori(float(j) / WorldData.REGION_SIZE))
		var region: Dictionary = _regions.get(key, {})
		if not region.has("fields") or placement == null: return {}
		var rect: Rect2i = region.rect
		if not rect.has_point(Vector2i(i, j)): return {}
		regional = region.fields
		k = (j - rect.position.y) * rect.size.x + i - rect.position.x
		if regional.ocean[k] != 0 or regional.lake[k] != 0 or (regional.has("village") and regional.village[k] != 0): return {}
		var wet: float = regional.moist[k] if regional.has("moist") else 0.45 + 0.4 * exp(-regional.dw[k] / 3.0)
		var exposed := StageVegetation.Surface.exposure(OuterLand._saved_elev(regional, k), regional.slope[k], wet)
		ground = Color(placement.cover_at(mid.x, mid.y), 0.5, wet, exposed)
	var cover := ground.r
	var rocky := ground.a
	var sample := (samples[n - 1] + samples[n]) / 2
	var surf: int = t.surf[sample] if t.has("surf") and t.surf.size() > sample else RoadSurface.NONE
	# Геометрия: за крутым поворотом бревно и валун не видны заранее — там их реже.
	var turn := absf((a - _point(t, samples[n - 2])).angle_to(_point(t, samples[n + 1]) - b))
	var seen := 1.0 - smoothstep(0.35, 1.0, turn)
	var support: RefCounted = placement if placement != null else h
	var grade: float = absf(support.ground_at(b.x, b.y) - support.ground_at(a.x, a.y)) / length
	var up: float = support.ground_at(mid.x + side.x * 4.0, mid.y + side.y * 4.0) - support.ground_at(mid.x - side.x * 4.0, mid.y - side.y * 4.0)
	var cross := absf(up) / 8.0
	var uphill := signf(up) if cross > 0.05 else 0.0
	var half := (float(t.pts[samples[n - 1]].w) + float(t.pts[samples[n]].w)) * TILE * 0.25
	var around_me := _context(mid, dir, side, half, length, uphill)
	var trees: int = around_me.trees
	var organic := 1.3 if surf == RoadSurface.FOREST or surf == RoadSurface.MEADOW else (0.5 if surf == RoadSurface.GRAVEL or surf == RoadSurface.PACKED else 1.0)
	organic *= lerpf(0.35, 1.15, RoadBump.patch(mid.x + world.world_origin.x * TILE, mid.y + world.world_origin.y * TILE).x)
	var falls := minf(float(around_me.rocks), 2.0) # обломки выше по склону
	var root_gap: float = around_me.gap
	var root_tree: Vector3 = around_me.root
	var rooted := false
	if root_tree.x != INF:
		var root_chance: float = 0.32 * (1.0 - smoothstep(0.4, ROOT_REACH, root_gap)) * ROOT_SURFACE[surf]
		root_chance *= 0.25 if t.kind == "road" else 1.0
		rooted = _tree_roll(root_tree, 0) < root_chance
	if not debris and not rooted: return {}
	var weights := PackedFloat32Array([
		# ветки — под деревьями: полог клетки и деревья у отрезка
		(cover * 0.065 + minf(trees, 6) * 0.016) * organic,
		# камни — порода, обломки сверху, крутое размытое полотно; без причины почти нет
		(0.002 + rocky * 0.075 + falls * 0.03 + smoothstep(0.08, 0.3, grade) * 0.04 * maxf(rocky, 0.3))
			* (1.6 if surf == RoadSurface.STONE else (0.3 if surf == RoadSurface.SAND else 1.0)),
		# бревно — упавшее дерево: нужны деревья рядом
		((pow(cover, 1.5) * 0.035 + minf(trees, 5) * 0.012) if trees >= 2 else 0.0) * seen * (0.3 if t.kind == "road" else 1.0),
		# валун скатился с косогора под скалой
		(rocky * 0.06 + falls * 0.02) * smoothstep(0.1, 0.5, cross) * lerpf(0.5, 1.0, seen),
		# корни — только от настоящего ствола у кромки
		0.0, # Roots are selected by their tree, independently of the debris lottery.
	])
	var total := 0.0
	for weight in weights:
		total += weight
	total *= KIND_SCALE[t.kind]
	if not rooted and roll >= minf(total, MAX_P):
		return {}
	# Расчищенные и опасные для раскладки места: старт, поселения, сооружения, вода, развилки.
	for spot in clear:
		if spot.distance_to(mid) < CLEAR_R:
			return {}
	for list: Array in [world.settlements, world.sites]:
		for place: EntityRecord in list:
			if absf(place.x - mid.x / TILE) < VILLAGE and absf(place.y - mid.y / TILE) < VILLAGE:
				return {}
	if (inside and (world.river[k] != 0 or world.dist_water[k] < 1.5 or h.depth_at(mid.x, mid.y) > 0.0)) or (not inside and (regional.river[k] != 0 or regional.dw[k] < 1.5)):
		return {}
	for dj in range(-STRUCTURE, STRUCTURE + 1):
		for di in range(-STRUCTURE, STRUCTURE + 1):
			if h._cell_list(mid.x + di * TILE, mid.y + dj * TILE) != null:
				return {}
	var pairs := around(mid.x, mid.y, JUNCTION + SAMPLE_STEP)
	for p in range(0, pairs.size(), 2):
		var other := pairs[p]
		var end := pairs[p + 1]
		if other == route:
			continue
		var nearby: Dictionary = _trails[other]
		var other_samples := _sampled[other]
		var from := _point(nearby, other_samples[end - 1])
		var to := _point(nearby, other_samples[end])
		var segment := to - from
		if segment.length_squared() < 0.01:
			continue
		var gap := mid.distance_to(Geometry2D.get_closest_point_to_segment(mid, from, to))
		var heading := segment.normalized()
		var same_direction := absf(dir.dot(heading)) > 0.94
		if gap < JUNCTION and protected(other, (_along[other][end - 1] + _along[other][end]) * 0.5):
			return {}
		if same_direction and absf((mid - from).cross(heading)) < 0.6:
			# A coincident route should not forbid debris on the shared tread.
			# The first route owns the overlap, regardless of direction.
			if gap < 0.6 and other < route:
				return {}
			continue
		var other_half := (float(nearby.pts[other_samples[end - 1]].w) + float(nearby.pts[other_samples[end]].w)) * TILE * 0.25
		if gap < (half + other_half + 0.5 if same_direction else JUNCTION):
			return {}
	if rooted:
		return _roots(route, n, a, dir, side, length, half, root_tree, around_me.owner, ground.b > 0.55)
	var pick_at: float = _roll(route, n, 1) * total / KIND_SCALE[t.kind]
	var kind := 0
	while kind < weights.size() - 1 and pick_at >= weights[kind]:
		pick_at -= weights[kind]
		kind += 1
	var at := a.lerp(b, 0.25 + 0.5 * _roll(route, n, 2))
	var lateral := _roll(route, n, 3) * 2.0 - 1.0
	var scale := _roll(route, n, 4)
	var rot := _roll(route, n, 5) * TAU
	var shape := _roll(route, n, 6)
	var stretch := 1.0
	var sink := 0.0
	match kind:
		BRANCH:
			at += side * lateral * half * 0.7
			scale = 0.8 + 0.65 * scale
			stretch = 0.75 + 0.5 * shape
			sink = 0.01
		STONES:
			# обломки скатываются к нижнему краю полотна; часть их в грунте
			var low := -uphill if uphill != 0.0 else signf(lateral)
			at += side * low * half * (0.25 + 0.45 * absf(lateral))
			scale = 0.6 + 0.8 * scale
			sink = 0.03 * scale
		LOG:
			at += side * lateral * half * 0.2
			if t.kind == "trail" and shape < 0.15:
				# поперёк всей тропы, с перекосом до ±25°; толщина такая, что прыжок его берёт
				rot = atan2(-side.y, side.x) + (rot / TAU - 0.5) * 0.9
			else:
				# у кромки вдоль тропы или наискосок, концом на полотне: объехать по свободной стороне
				var edge := signf(lateral) if lateral != 0.0 else 1.0
				var skew := lerpf(0.05, 0.75, smoothstep(0.15, 1.0, shape)) * edge
				var along := dir.rotated(skew)
				at = a.lerp(b, 0.5) + side * edge * (half + 0.5 - 0.6 * smoothstep(0.5, 1.0, shape))
				rot = atan2(-along.y, along.x)
			scale = 0.7 + 0.25 * scale
			stretch = 0.6 + 0.55 * _roll(route, n, 7)
			sink = 0.05 * scale
		BOULDER:
			# у края, на стороне подъёма; другой край остаётся свободным для объезда
			var edge := uphill if uphill != 0.0 else signf(lateral)
			scale = 0.7 + 0.3 * scale
			var lane := TrailTechnical.CORRIDOR + 0.17 + 0.25 * (1.0 - seen) + 0.25 * smoothstep(0.08, 0.25, grade)
			at += side * (1.0 if edge >= 0.0 else -1.0) * maxf(half * (0.45 + 0.25 * absf(lateral)), lane + 0.85 * scale)
			sink = 0.12 * scale
		ROOT:
			return _roots(route, n, a, dir, side, length, half, root_tree, around_me.owner, ground.b > 0.55)
	var part := {kind = kind, x = at.x, z = at.y, rot = rot, scale = scale, stretch = stretch, sink = sink}
	# Keep one continuous central handlebar corridor, including the neighbouring
	# approach and departure. A bypass on a steep shoulder is not rideable tread.
	if kind in [LOG, BOULDER] and not _solid_clear(part, t, samples, n, seen, grade): return {}
	var out := part.duplicate()
	out.owner = -1
	out.moss = ground.b > 0.55
	out.parts = [part]
	return out


func _solid_clear(part: Dictionary, t: Dictionary, samples: PackedInt32Array, n: int, seen: float, grade: float) -> bool:
	var center := Vector2(part.x, part.z)
	var axis := Vector2.from_angle(-part.rot)
	var a: Vector2 = center - axis * 2.2 * part.scale * part.stretch if part.kind == LOG else center
	var b: Vector2 = center + axis * 2.1 * part.scale * part.stretch if part.kind == LOG else center
	var radius: float = (0.24 if part.kind == LOG else 0.85) * part.scale
	var lane := TrailTechnical.CORRIDOR + 0.15 + 0.25 * (1.0 - seen) + 0.25 * smoothstep(0.08, 0.25, grade)
	for j in range(maxi(0, n - 3), mini(samples.size(), n + 3)):
		var p := _point(t, samples[j])
		var q := _point(t, samples[j + 1]) if j + 1 < samples.size() else p
		if Geometry2D.segment_intersects_segment(a, b, p, q) != null: return false
		var gap := minf(minf(a.distance_to(Geometry2D.get_closest_point_to_segment(a, p, q)), b.distance_to(Geometry2D.get_closest_point_to_segment(b, p, q))),
			minf(p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)), q.distance_to(Geometry2D.get_closest_point_to_segment(q, a, b))))
		if gap < radius + lane: return false
	return true


func _tree_roll(tree: Vector3, salt: int) -> float:
	return WGRandom.hash2(roundi((tree.x / TILE + world.world_origin.x) * 97.0), roundi((tree.y / TILE + world.world_origin.y) * 89.0), world.seed_num ^ (6677 + salt))


## Один-три корня от ствола tree (x, z, масштаб дерева) через полотно отрезка: от ствола к тропе, наискосок, с разбросом.
## Корень — единичный меш вдоль X (концы под грунтом), растянутый на ширину полотна с запасом.
func _roots(route: int, n: int, a: Vector2, dir: Vector2, side: Vector2, length: float, half: float,
		tree: Vector3, owner: int, moss: bool) -> Dictionary:
	var trunk := Vector2(tree.x, tree.y)
	var u := clampf((trunk - a).dot(dir) / length, 0.15, 0.85)
	var center := a + dir * u * length
	var far_edge := side * signf((center - trunk).dot(side)) * (half + 0.25)
	var count := 1 + int(_tree_roll(tree, 8) < 0.45) + int(_tree_roll(tree, 9) < 0.12)
	var parts: Array = []
	for c in count:
		var fan := (c - (count - 1) * 0.5) * 1.45
		var start := trunk + dir * fan * 0.18
		var end := center + far_edge * lerpf(0.45, 1.0, _tree_roll(tree, 30 + c)) + dir * (fan + (_tree_roll(tree, 10 + c) - 0.5))
		var span := end - start
		var at := (start + end) * 0.5
		var thick := clampf(1.0 + 0.6 * (tree.z - ROOT_TREE) + 0.35 * _tree_roll(tree, 20 + c), 1.0, 1.6)
		parts.append({kind = ROOT, x = at.x, z = at.y, rot = atan2(-span.y, span.x), scale = thick,
			stretch = span.length() / thick, sink = -0.005 + 0.025 * _tree_roll(tree, 40 + c), variant = int(_tree_roll(tree, 50 + c) * 3.0)})
	var out: Dictionary = parts[0].duplicate()
	out.moss = moss
	out.owner = owner
	out.parts = parts
	return out


## Кочка мелкого препятствия для ForestObstacles: отрезок a–b, радиус и высота (формат set_bumps). xf — тот же
## поворот, масштаб и растяжение, что у меша (у корня — две кочки по его дугам над грунтом, концы в грунте).
static func bump(kind: int, xf: Transform3D, scale: float, heights: RefCounted = null, variant := 0) -> PackedFloat32Array:
	var floor_script := preload("res://scripts/render/forest_floor.gd")
	if kind == STONES:
		var result := PackedFloat32Array()
		for box: AABB in floor_script.stone_bounds(variant):
			var p := box.get_center()
			p.y = box.end.y
			var crest := xf * p
			var rise: float = crest.y - (heights.ground_at(crest.x, crest.z) if heights != null else xf.origin.y)
			if rise < 0.015: continue
			var radius := maxf(minf(box.size.x, box.size.z) * scale * 0.5, sqrt(2.0 * BikeRide.WHEEL_R * rise))
			result.append_array([crest.x, crest.z, crest.x, crest.z, radius, rise])
		return result
	if kind == ROOT:
		var path := floor_script.root_path(variant)
		var result := PackedFloat32Array()
		for i in range(1, path.size()):
			var a := xf * path[i - 1]
			var b := xf * path[i]
			var radius := floor_script.root_radius(i - 1) * absf(xf.basis.y.y)
			var crest := (a + b) * 0.5 + Vector3.UP * radius
			var ground: float = heights.ground_at(crest.x, crest.z) if heights != null else xf.origin.y
			var rise := crest.y - ground
			if rise < 0.015: continue
			result.append_array([a.x, a.z, b.x, b.z, maxf(radius, sqrt(2.0 * BikeRide.WHEEL_R * rise)), rise])
		return result
	var size: Vector2 = BUMP[kind] * scale
	# 11.7: колесо обкатывает ветку дугой, а не проваливается за неё: радиус не меньше этой дуги,
	# иначе на 10 м/с купол попадает в одну-две точки за такт и подвеска получает случайный удар
	size.x = maxf(size.x, sqrt(2.0 * BikeRide.WHEEL_R * size.y))
	var a := Vector3.ZERO
	var b := Vector3.ZERO
	if kind == BRANCH:
		a = xf * Vector3(-1.1, 0.0, 0.0)
		b = xf * Vector3(1.1, 0.0, 0.1)
	else:
		a = xf.origin
		b = xf.origin
	if heights != null:
		var peak := xf.origin + Vector3.UP * size.y
		size.y = peak.y - heights.ground_at(peak.x, peak.z)
		if size.y < 0.015:
			return PackedFloat32Array()
	return PackedFloat32Array([a.x, a.z, b.x, b.z, size.x, size.y])
