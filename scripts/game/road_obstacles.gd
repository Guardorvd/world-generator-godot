class_name RoadObstacles
extends RefCounted
## 11.6: природные препятствия на дорогах и тропах — ветки, россыпь камней, упавшие брёвна, валуны, корни.
## Только оформление готового мира, как подстилка 9.4: мир, маршруты, хеши и ключи кэша (10.2) не меняются.
## Место — отрезок линии пути между соседними точками t.pts (4–6 м). Хеш отрезка решает, лежит ли на нём
## что-нибудь и что, поэтому раскладка одна при любом подъезде и ничего не хранит. Раскладывает VegetationLayer
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
const MAX_P := 0.18      # не чаще одного препятствия на пять-шесть отрезков (~25 м)
const CHUNK := 8         # клеток в стороне ячейки индекса линий
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


func _init(w: WorldData) -> void:
	world = w
	for route in w.trails.size():
		var t: Dictionary = w.trails[route]
		if not KIND_SCALE.has(t.kind):
			continue
		for n in t.pts.size():
			var key := Vector2i(floori(t.pts[n].x / CHUNK), floori(t.pts[n].y / CHUNK))
			var list: PackedInt32Array = _index.get(key, PackedInt32Array())
			list.append_array([route, n])
			_index[key] = list


## Пары (маршрут, точка) линий в радиусе r (м) от (x, z), по ячейкам индекса
func around(x: float, z: float, r: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var side := CHUNK * TILE
	for cy in range(floori((z - r) / side), floori((z + r) / side) + 1):
		for cx in range(floori((x - r) / side), floori((x + r) / side) + 1):
			var list: Variant = _index.get(Vector2i(cx, cy))
			if list != null:
				out.append_array(list)
	return out


func _roll(route: int, n: int, salt: int) -> float:
	return WGRandom.hash2(n, route * 31 + salt, world.seed_num ^ SEED)


static func _point(t: Dictionary, n: int) -> Vector2:
	return Vector2(t.pts[n].x, t.pts[n].y) * TILE


## Что растёт и лежит у отрезка: число деревьев, ближайший крупный ствол у кромки (x, z, масштаб; x = INF — нет) и его
## зазор до кромки, сколько камня выше по склону. Только объекты мира в чанках вокруг, без новых карт.
func _context(mid: Vector2, dir: Vector2, side: Vector2, half: float, length: float, uphill: float) -> Dictionary:
	var out := {trees = 0, root = Vector3(INF, 0.0, 0.0), gap = INF, rocks = 0.0}
	if world.CS <= 0 or world.chunks.is_empty():
		return out
	var r := half + LOOK
	var span := world.CS * TILE
	for cy in range(maxi(0, floori((mid.y - r) / span)), mini(world.CH, floori((mid.y + r) / span) + 1)):
		for cx in range(maxi(0, floori((mid.x - r) / span)), mini(world.CW, floori((mid.x + r) / span) + 1)):
			for o: int in world.chunks[cy * world.CW + cx]:
				var p := Vector2(world.obj_x[o], world.obj_y[o]) * TILE
				var off := p - mid
				if absf(off.x) > r or absf(off.y) > r:
					continue
				var kind := world.obj_k[o]
				var s := world.obj_s[o]
				var lateral := off.dot(side)
				if kind == Biomes.T_ROCK:
					# камень выше по склону от полотна: россыпь или скальный выход, откуда скатываются обломки
					if uphill != 0.0 and lateral * uphill > half:
						out.rocks += minf(s, 1.5)
					continue
				if not Biomes.is_tree(kind) or s < 0.6:
					continue
				out.trees += 1
				if s < ROOT_TREE or not StageVegetation.TRUNK.has(kind) or absf(off.dot(dir)) > length * 0.5 + 1.5:
					continue
				var gap := absf(lateral) - half
				if gap < ROOT_REACH and gap < out.gap:
					out.gap = gap
					out.root = Vector3(p.x, p.y, s)
	return out


## Препятствие на отрезке (точка n − 1 → n) маршрута route или {}: {kind, x, z, rot, scale, moss, parts}.
## parts — все экземпляры (у корней их до трёх), у каждого kind, x, z, rot, scale, stretch (длина вдоль локальной X),
## sink (насколько утоплен в грунт, м). rot — поворот вокруг вертикали, как у подлеска (локальная X — вдоль бревна,
## ветки и корня).
func pick(h: Heightfield, surface: Image, route: int, n: int) -> Dictionary:
	var t: Dictionary = world.trails[route]
	# Authored routes own their obstacles through TrailTechnical. Streaming decoration must not
	# insert random logs into a designed line, takeoff or landing on any authored route.
	if t.has("trail_id"):
		return {}
	if n < 3 or n > t.pts.size() - 3:
		return {}
	var roll := _roll(route, n, 0)
	# соседние отрезки не заняты вместе: бревно и камни не ложатся друг на друга
	if roll >= MAX_P or _roll(route, n - 1, 0) < MAX_P:
		return {}
	var a := _point(t, n - 1)
	var b := _point(t, n)
	var length := a.distance_to(b)
	if length < 1.0:
		return {}
	var dir := (b - a) / length
	var side := Vector2(-dir.y, dir.x)
	var mid := (a + b) * 0.5
	var i := floori(mid.x / TILE)
	var j := floori(mid.y / TILE)
	if i < 1 or j < 1 or i >= world.W - 1 or j >= world.H - 1:
		return {}
	var k := j * world.W + i
	var ground := surface.get_pixel(i, j) # полог, хвоя, влага, каменистость
	var cover := ground.r
	var rocky := ground.a
	var surf: int = t.surf[n - 1] if t.has("surf") and t.surf.size() > n - 1 else RoadSurface.NONE
	# Геометрия: за крутым поворотом бревно и валун не видны заранее — там их реже.
	var turn := absf((a - _point(t, n - 2)).angle_to(_point(t, n + 1) - b))
	var seen := 1.0 - smoothstep(0.35, 1.0, turn)
	var grade := absf(h.ground_at(b.x, b.y) - h.ground_at(a.x, a.y)) / length
	var up := h.ground_at(mid.x + side.x * 4.0, mid.y + side.y * 4.0) - h.ground_at(mid.x - side.x * 4.0, mid.y - side.y * 4.0)
	var cross := absf(up) / 8.0
	var uphill := signf(up) if cross > 0.05 else 0.0
	var half := (float(t.pts[n - 1].w) + float(t.pts[n].w)) * TILE * 0.25
	var around_me := _context(mid, dir, side, half, length, uphill)
	var trees: int = around_me.trees
	var organic := 1.3 if surf == RoadSurface.FOREST or surf == RoadSurface.MEADOW else (0.5 if surf == RoadSurface.GRAVEL or surf == RoadSurface.PACKED else 1.0)
	var falls := minf(float(around_me.rocks), 2.0) # обломки выше по склону
	var root_gap: float = around_me.gap
	var root_tree: Vector3 = around_me.root
	var weights := PackedFloat32Array([
		# ветки — под деревьями: полог клетки и деревья у отрезка
		(cover * 0.045 + minf(trees, 6) * 0.005) * organic,
		# камни — порода, обломки сверху, крутое размытое полотно; без причины почти нет
		(0.002 + rocky * 0.05 + falls * 0.03 + smoothstep(0.08, 0.3, grade) * 0.025 * maxf(rocky, 0.3))
			* (1.6 if surf == RoadSurface.STONE else (0.3 if surf == RoadSurface.SAND else 1.0)),
		# бревно — упавшее дерево: нужны деревья рядом
		(pow(cover, 1.5) * 0.035 if trees >= 2 else 0.0) * seen * (0.3 if t.kind == "road" else 1.0),
		# валун скатился с косогора под скалой
		(rocky * 0.06 + falls * 0.02) * smoothstep(0.1, 0.5, cross) * lerpf(0.5, 1.0, seen),
		# корни — только от настоящего ствола у кромки
		(0.0 if root_tree.x == INF else 0.14 * (1.0 - smoothstep(0.5, ROOT_REACH + 0.5, root_gap))
			* smoothstep(0.75, 1.3, root_tree.z) * ROOT_SURFACE[surf] * (0.4 if t.kind == "road" else 1.0)),
	])
	var total := 0.0
	for weight in weights:
		total += weight
	total *= KIND_SCALE[t.kind]
	if roll >= minf(total, MAX_P):
		return {}
	# Расчищенные и опасные для раскладки места: старт, поселения, сооружения, вода, развилки.
	for spot in clear:
		if spot.distance_to(mid) < CLEAR_R:
			return {}
	for list: Array in [world.settlements, world.sites]:
		for place: EntityRecord in list:
			if absf(place.x - mid.x / TILE) < VILLAGE and absf(place.y - mid.y / TILE) < VILLAGE:
				return {}
	if world.river[k] != 0 or world.dist_water[k] < 1.5 or h.depth_at(mid.x, mid.y) > 0.0:
		return {}
	for dj in range(-STRUCTURE, STRUCTURE + 1):
		for di in range(-STRUCTURE, STRUCTURE + 1):
			if h._cell_list(mid.x + di * TILE, mid.y + dj * TILE) != null:
				return {}
	var pairs := around(mid.x, mid.y, JUNCTION)
	for p in range(0, pairs.size(), 2):
		if pairs[p] != route and _point(world.trails[pairs[p]], pairs[p + 1]).distance_to(mid) < JUNCTION:
			return {}
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
			scale = 0.6 + 0.6 * scale
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
			at += side * (1.0 if edge >= 0.0 else -1.0) * half * (0.45 + 0.25 * absf(lateral))
			scale = 0.7 + 0.3 * scale
			sink = 0.12 * scale
		ROOT:
			return _roots(t, route, n, a, dir, side, length, half, root_tree, ground.b > 0.55)
	var part := {kind = kind, x = at.x, z = at.y, rot = rot, scale = scale, stretch = stretch, sink = sink}
	var out := part.duplicate()
	out.moss = ground.b > 0.55
	out.parts = [part]
	return out


## Один-три корня от ствола tree (x, z, масштаб дерева) через полотно отрезка: от ствола к тропе, наискосок, с разбросом.
## Корень — единичный меш вдоль X (концы под грунтом), растянутый на ширину полотна с запасом.
func _roots(t: Dictionary, route: int, n: int, a: Vector2, dir: Vector2, side: Vector2, length: float, half: float,
		tree: Vector3, moss: bool) -> Dictionary:
	var trunk := Vector2(tree.x, tree.y)
	var u := clampf((trunk - a).dot(dir) / length, 0.15, 0.85)
	var center := a + dir * u * length
	var away := (center - trunk).normalized()
	var count := 1 + int(_roll(route, n, 8) < 0.45) + int(_roll(route, n, 9) < 0.18)
	var reach := clampf(2.0 * half + 1.4, 2.2, 5.5)
	var parts: Array = []
	for c in count:
		var turn := (_roll(route, n, 10 + c) - 0.5) * 0.7 + (c - (count - 1) * 0.5) * 0.3
		var heading := away.rotated(turn)
		# не вдоль тропы: корень пересекает её хотя бы под 25°
		if absf(heading.dot(dir)) > 0.9:
			heading = (heading + side * signf(heading.dot(side) if heading.dot(side) != 0.0 else 1.0) * 0.6).normalized()
		var at := center + dir * (c - (count - 1) * 0.5) * (0.45 + 0.4 * _roll(route, n, 14 + c)) \
			+ side * (_roll(route, n, 17 + c) - 0.5) * half * 0.4
		var thick := clampf(0.65 + 0.45 * (tree.z - ROOT_TREE) + 0.35 * _roll(route, n, 20 + c), 0.6, 1.3)
		# stretch — длина меша вдоль X в долях масштаба: корень длиной reach при толщине thick
		parts.append({kind = ROOT, x = at.x, z = at.y, rot = atan2(-heading.y, heading.x), scale = thick,
			stretch = reach * (0.85 + 0.3 * _roll(route, n, 23 + c)) / thick, sink = 0.0})
	var out: Dictionary = parts[0].duplicate()
	out.moss = moss
	out.parts = parts
	return out


## Кочка мелкого препятствия для ForestObstacles: отрезок a–b, радиус и высота (формат set_bumps). xf — тот же
## поворот, масштаб и растяжение, что у меша (у корня — две кочки по его дугам над грунтом, концы в грунте).
static func bump(kind: int, xf: Transform3D, scale: float) -> PackedFloat32Array:
	var size: Vector2 = BUMP[kind] * scale
	# 11.7: колесо обкатывает ветку дугой, а не проваливается за неё: радиус не меньше этой дуги,
	# иначе на 10 м/с купол попадает в одну-две точки за такт и подвеска получает случайный удар
	size.x = maxf(size.x, sqrt(2.0 * BikeRide.WHEEL_R * size.y))
	var a := Vector3.ZERO
	var b := Vector3.ZERO
	if kind == BRANCH:
		a = xf * Vector3(-1.1, 0.0, 0.0)
		b = xf * Vector3(1.1, 0.0, 0.1)
	elif kind == ROOT:
		# две дуги корня над грунтом (Floor.root_span): у ствола и ближе к концу; между ними он под землёй
		var near := xf * Vector3(-0.36, 0.0, 0.08)
		var mid := xf * Vector3(-0.16, 0.0, 0.06)
		var c := xf * Vector3(0.06, 0.0, -0.08)
		var far := xf * Vector3(0.32, 0.0, -0.01)
		return PackedFloat32Array([near.x, near.z, mid.x, mid.z, size.x, size.y, c.x, c.z, far.x, far.z, size.x, size.y])
	else:
		a = xf.origin
		b = xf.origin
	return PackedFloat32Array([a.x, a.z, b.x, b.z, size.x, size.y])
