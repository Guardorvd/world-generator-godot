extends RefCounted
## 11.0: выбираем место отдельным RNG, затем ближайшую готовую дорогу/тропу.
## Используем уже проложенную линию, без нового поиска маршрутов и проверок коридора.
## 18.11.2026: старт — на дороге к удалённой деревне, примерно за 500 м по дороге до неё (APPROACH_M), лицом к ней и так,
## чтобы её было видно (склон не закрывает). Деревня — с ролью «удалённая» (SettlementRoles), а если такой нет —
## одна из самых обособленных (дальше всех от соседей). Не нашлось подхода — прежний выбор: случайное место
## и ближайшая к нему дорога.
const SPEED := 3.0
const APPROACH_M := [500.0, 380.0, 260.0]  # м по дороге от старта до деревни; меньше — если открытая земля не пускает дальше
const STRAIGHT_MIN := 0.56     # доля пути по дороге, не меньше которой — по прямой: иначе дорога петляет у самой деревни
const STRAIGHT_MAX_M := 650.0  # м по прямой: дальше деревню почти не разглядеть
const FACING := 35.0           # градусов: деревня не дальше этого от направления дороги на старте — видна прямо по ходу
const ENTRY_M := 120.0         # м: дорога должна проходить не дальше этого от центра деревни
const REMOTE_SHARE := 3        # без удалённых — выбор из каждой третьей самой обособленной деревни
## Инструменты проверки (tools/control/check.gd): не 0 — одно и то же место старта и вступления в каждом прогоне,
## иначе замер FPS «было/стало» снимается в разных местах мира. В игре 0 — случайное место.
static var fixed_seed := 0


static func make_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	if fixed_seed != 0: rng.seed = fixed_seed
	else: rng.randomize()
	return rng


static func choose(w: WorldData, h: Heightfield, rng: RandomNumberGenerator) -> Dictionary:
	var network := _network(w)
	var villages := _villages(w, rng)
	for approach: float in APPROACH_M:
		for village: Variant in villages:
			var spot := _approach(w, h, network, village, approach, rng)
			if not spot.is_empty():
				return spot
	return _near_place(w, h, rng)


## Деревни для старта по порядку: удалённые (в случайном порядке), иначе самые обособленные
static func _villages(w: WorldData, rng: RandomNumberGenerator) -> Array:
	var open: Array = w.settlements.filter(func(s: Variant) -> bool: return w.accessible(s.x, s.y, 2.0))
	var remote: Array = open.filter(func(s: Variant) -> bool: return str(EntityCodec.value(s, "role", "")) == "remote")
	if not remote.is_empty():
		_shuffle(remote, rng)
		return remote
	if open.size() < 2:
		return open
	var lonely: Array = []
	for s: Variant in open:
		var nearest := INF
		for o: Variant in w.settlements:
			if o != s:
				nearest = minf(nearest, Vector2(s.x, s.y).distance_squared_to(Vector2(o.x, o.y)))
		lonely.append([nearest, s])
	lonely.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var out: Array = lonely.slice(0, maxi(1, ceili(lonely.size() / float(REMOTE_SHARE)))).map(func(e: Array) -> Variant: return e[1])
	_shuffle(out, rng)
	return out


## Дороги и тропы (без звериных) в метрах и узлы на их концах: {lines: [PackedVector2Array], nodes: {Vector2i: [[линия, с конца]]}}
static func _network(w: WorldData) -> Dictionary:
	var lines: Array[PackedVector2Array] = []
	var nodes := {}
	for trail: Dictionary in w.trails:
		if trail.kind == "animal" or trail.pts.size() < 2:
			continue
		var line := PackedVector2Array()
		for p: Variant in trail.pts:
			line.append(Vector2(p.x, p.y) * GameConfig.TILE)
		var index := lines.size()
		lines.append(line)
		for end: bool in [false, true]:
			var key := _node(line[-1] if end else line[0])
			if not nodes.has(key):
				nodes[key] = []
			nodes[key].append([index, end])
	return {lines = lines, nodes = nodes}


static func _node(at: Vector2) -> Vector2i:
	return Vector2i((at / GameConfig.TILE).round())


## Точка на дороге к деревне village в APPROACH_M по сети: поиск по дорогам от въезда (Дейкстра по узлам на концах линий)
static func _approach(w: WorldData, h: Heightfield, network: Dictionary, village: Variant, approach: float, rng: RandomNumberGenerator) -> Dictionary:
	var center := Vector2(village.x, village.y) * GameConfig.TILE
	var lines: Array[PackedVector2Array] = network.lines
	# въезд — ближайшая к центру точка дорог
	var entry := Vector2i(-1, -1)
	var best := ENTRY_M * ENTRY_M
	for li in lines.size():
		var line := lines[li]
		for i in line.size():
			var d := line[i].distance_squared_to(center)
			if d < best:
				best = d
				entry = Vector2i(li, i)
	if entry.x < 0:
		return {}
	var found: Array[Dictionary] = []
	var done := {}
	var frontier: Array = []  # [путь до узла, узел]
	var used := {entry.x: true}
	var start := lines[entry.x]
	# от въезда в обе стороны по его линии
	for outward: PackedVector2Array in [start.slice(entry.y), _reversed(start.slice(0, entry.y + 1))]:
		var reach := _walk(outward, 0.0, approach, found)
		if reach >= 0.0:
			frontier.append([reach, _node(outward[-1])])
	var guard := 0
	while not frontier.is_empty() and guard < 4000:
		guard += 1
		frontier.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		var item: Array = frontier.pop_front()
		var key: Vector2i = item[1]
		if done.has(key):
			continue
		done[key] = true
		for link: Array in network.nodes.get(key, []):
			if used.has(link[0]):
				continue
			used[link[0]] = true
			var line := lines[link[0]]
			var outward := _reversed(line) if link[1] else line
			var reach := _walk(outward, item[0], approach, found)
			if reach >= 0.0 and not done.has(_node(outward[-1])):
				frontier.append([reach, _node(outward[-1])])
	# годные точки: по прямой не у самой деревни и не слишком далеко, на открытой земле; видна ли деревня и прямо ли по ходу
	var ahead: Array[Dictionary] = []
	var seen: Array[Dictionary] = []
	var hidden: Array[Dictionary] = []
	var top := Vector3(center.x, h.ground_at(center.x, center.y) + 6.0, center.y)
	for spot: Dictionary in found:
		var at: Vector2 = spot.points[0]
		var straight := at.distance_to(center)
		if straight < approach * STRAIGHT_MIN or straight > STRAIGHT_MAX_M or not w.accessible(at.x / GameConfig.TILE, at.y / GameConfig.TILE, 2.0):
			continue
		var eye := Vector3(at.x, h.ground_at(at.x, at.y) + 1.7, at.y)
		if _occluded(h, eye, top):
			hidden.append(spot)
			continue
		var road: Vector2 = spot.points[1] - at
		spot.facing = absf(rad_to_deg(road.angle_to(center - at)))
		(ahead if spot.facing <= FACING else seen).append(spot)
	var pick: Dictionary = {}
	if not ahead.is_empty():
		pick = ahead[rng.randi() % ahead.size()]
	elif not seen.is_empty():
		seen.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.facing < b.facing)
		pick = seen[0]
	elif not hidden.is_empty():
		pick = hidden[rng.randi() % hidden.size()]
	if pick.is_empty():
		return {}
	var points: Array[Vector2] = pick.points
	var forward := points[1] - points[0]
	var at3 := Vector3(points[0].x, h.surface_at(points[0].x, points[0].y, INF), points[0].y)
	return {position = at3, heading = atan2(-forward.x, -forward.y), points = points,
		place = w.place(WorldData.place_id("settlement", village.x, village.y)), cinematic = pick.length >= 18.0}


## Пройти линию outward (от деревни наружу), начиная с пути along м. Если на ней путь достигает approach м — в found
## точка старта и до 26 м пути назад к деревне (кадр вступления); возвращает путь до конца линии или -1, если дальше не идти
static func _walk(outward: PackedVector2Array, along: float, approach: float, found: Array[Dictionary]) -> float:
	for i in range(1, outward.size()):
		var step := outward[i - 1].distance_to(outward[i])
		if along + step >= approach and step > 0.0:
			var at := outward[i - 1].lerp(outward[i], (approach - along) / step)
			var points: Array[Vector2] = [at]
			var length := 0.0
			var k := i - 1
			while k >= 0 and length < 26.0:
				length += points[-1].distance_to(outward[k])
				if outward[k].distance_squared_to(points[-1]) > 0.01:
					points.append(outward[k])
				k -= 1
			if points.size() >= 2:
				found.append({points = points, length = length})
			return -1.0
		along += step
	return along


static func _reversed(line: PackedVector2Array) -> PackedVector2Array:
	var out := line.duplicate()
	out.reverse()
	return out


## Склон между глазами и деревней (как GameWorld._occluded: последние 8 % пути не проверяются)
static func _occluded(h: Heightfield, from: Vector3, to: Vector3) -> bool:
	var steps := clampi(int(from.distance_to(to) / 25.0), 8, 48)
	for i in range(1, steps):
		var t := float(i) / steps
		if t > 0.92:
			break
		var p := from.lerp(to, t)
		if h.ground_at(p.x, p.z) > p.y + 1.0:
			return true
	return false


## Прежний выбор (до 18.11.2026): случайное место и ближайшая к нему дорога
static func _near_place(w: WorldData, h: Heightfield, rng: RandomNumberGenerator) -> Dictionary:
	var kinds: Array = WorldData.PLACE_KINDS.duplicate()
	_shuffle(kinds, rng)
	for kind: String in kinds:
		var places: Array = w.get(kind + "s").duplicate()
		_shuffle(places, rng)
		for src: Variant in places:
			var center := Vector2(src.sx, src.sy) if kind == "lake" else Vector2(src.x, src.y)
			center *= GameConfig.TILE
			if not w.accessible(center.x / GameConfig.TILE, center.y / GameConfig.TILE):
				continue
			var best := INF
			var route: Array = []
			var index := 0
			for trail: Dictionary in w.trails:
				if trail.kind == "animal":
					continue
				for i in range(1, trail.pts.size() - 1):
					var p := Vector2(trail.pts[i].x, trail.pts[i].y) * GameConfig.TILE
					var distance := p.distance_squared_to(center)
					if distance < best and w.accessible(p.x / GameConfig.TILE, p.y / GameConfig.TILE, 2.0):
						best = distance
						route = trail.pts
						index = i
			# Старт действительно рядом с выбранным местом, а не на другом конце карты.
			if route.is_empty() or best > 160.0 * 160.0:
				continue
			var direction := 1 if index < route.size() / 2 else -1
			var points: Array[Vector2] = []
			var length := 0.0
			var cursor := index
			while cursor >= 0 and cursor < route.size():
				var point := Vector2(route[cursor].x, route[cursor].y) * GameConfig.TILE
				if not points.is_empty():
					length += point.distance_to(points[-1])
				points.append(point)
				if length >= 26.0:
					break
				cursor += direction
			if points.size() < 2:
				continue
			var forward := points[1] - points[0]
			var at := Vector3(points[0].x, h.surface_at(points[0].x, points[0].y, INF), points[0].y)
			return {position = at, heading = atan2(-forward.x, -forward.y), points = points,
				place = w.place(WorldData.place_id(kind, src.x, src.y)), cinematic = length >= 18.0}
	return {}


static func _shuffle(items: Array, rng: RandomNumberGenerator) -> void:
	for i in range(items.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var item: Variant = items[i]
		items[i] = items[j]
		items[j] = item
