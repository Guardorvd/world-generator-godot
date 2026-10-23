class_name RoadObstacles
extends RefCounted
## 11.6: природные препятствия на дорогах и тропах — ветки, россыпь камней, упавшие брёвна, валуны.
## Только оформление готового мира, как подстилка 9.4: мир, маршруты, хеши и ключи кэша (10.2) не меняются.
## Место — отрезок линии пути между соседними точками t.pts (4–6 м). Хеш отрезка решает, лежит ли на нём
## что-нибудь и что, а вероятность задают местность (полог и каменистость из ForestFloor.surface_image),
## вид пути, покрытие и геометрия (уклон, косогор, поворот). Поэтому раскладка одна при любом подъезде
## и ничего не хранит. Раскладывает VegetationLayer в фоновой задаче подлеска (те же MultiMesh, дальность
## и проверки), столкновения и кочки уходят в ForestObstacles.
## Ступени: ветки и камни — кочка под колесом (подвеска); валун у края — объехать; бревно поперёк —
## перепрыгнуть (верх до 0,4 м); в бревно или валун в лоб быстрее BikeRide.WALL_CRASH — падение.

const TILE := GameConfig.TILE
enum { BRANCH, STONES, LOG, BOULDER }
const KIND_SCALE := {road = 0.45, trail = 1.0, mountain = 0.8} # дорогу расчищают, горную тропу засыпает камнем
const MAX_P := 0.16      # не чаще одного препятствия на шесть отрезков (~30 м)
const CHUNK := 8         # клеток в стороне ячейки индекса линий
const CLEAR_R := 45.0    # у старта (вступительный проезд 11.0) пусто, м
const VILLAGE := 9.0     # ближе к поселению или месту (клеток) дорогу расчистили
const STRUCTURE := 3     # клеток до моста или туннеля: у настила ничего не лежит
const JUNCTION := 8.0    # ближе к другому пути (м) — развилка, не загромождаем
const SEED := 11606
## Кочка под колесом: [радиус, высота] при масштабе 1, м
const BUMP := {BRANCH: Vector2(0.14, 0.07), STONES: Vector2(0.65, 0.11)}

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


## Препятствие на отрезке (точка n − 1 → n) маршрута route или {}: {kind, x, z, rot, scale, moss}.
## rot — поворот вокруг вертикали, как у подлеска (локальная X — вдоль бревна и ветки).
func pick(h: Heightfield, surface: Image, route: int, n: int) -> Dictionary:
	var t: Dictionary = world.trails[route]
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
	var organic := 1.3 if surf == RoadSurface.FOREST or surf == RoadSurface.MEADOW else (0.5 if surf == RoadSurface.GRAVEL or surf == RoadSurface.PACKED else 1.0)
	var weights := PackedFloat32Array([
		cover * 0.06 * organic,
		# камни скатываются на крутое и размытое полотно
		(rocky * 0.05 + smoothstep(0.08, 0.3, grade) * 0.03) * (1.6 if surf == RoadSurface.STONE else (0.3 if surf == RoadSurface.SAND else 1.0)),
		pow(cover, 1.5) * 0.035 * seen * (0.5 if t.kind == "road" else 1.0),
		# валун скатился с косогора
		rocky * smoothstep(0.1, 0.5, cross) * 0.06 * lerpf(0.5, 1.0, seen),
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
		for place: Dictionary in list:
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
	var half := (float(t.pts[n - 1].w) + float(t.pts[n].w)) * TILE * 0.25
	var at := a.lerp(b, 0.25 + 0.5 * _roll(route, n, 2))
	var lateral := _roll(route, n, 3) * 2.0 - 1.0
	var scale := _roll(route, n, 4)
	var rot := _roll(route, n, 5) * TAU
	match kind:
		BRANCH:
			at += side * lateral * half * 0.7
			scale = 0.8 + 0.4 * scale
		STONES:
			at += side * lateral * half * 0.6
			scale = 0.8 + 0.5 * scale
		LOG:
			# поперёк полотна, с перекосом до ±25°; толщина такая, что прыжок его берёт
			at += side * lateral * half * 0.2
			rot = atan2(-side.y, side.x) + (rot / TAU - 0.5) * 0.9
			scale = 0.7 + 0.25 * scale
		BOULDER:
			# у края, на стороне подъёма; другой край остаётся свободным для объезда
			var edge := signf(up) if cross > 0.12 else signf(lateral)
			at += side * (1.0 if edge >= 0.0 else -1.0) * half * (0.45 + 0.25 * absf(lateral))
			scale = 0.7 + 0.3 * scale
	return {kind = kind, x = at.x, z = at.y, rot = rot, scale = scale, moss = ground.b > 0.55}


## Кочка мелкого препятствия для ForestObstacles: отрезок a–b, радиус и высота (формат set_bumps)
static func bump(kind: int, xf: Transform3D, scale: float) -> PackedFloat32Array:
	var size: Vector2 = BUMP[kind] * scale
	var a := xf * (Vector3(-1.1, 0.0, 0.0) if kind == BRANCH else Vector3.ZERO)
	var b := xf * (Vector3(1.1, 0.0, 0.1) if kind == BRANCH else Vector3.ZERO)
	return PackedFloat32Array([a.x, a.z, b.x, b.z, size.x, size.y])
