class_name PlayerState
extends RefCounted
## Игрок: появление, движение по местности, прыжок, проходимость. Копия js/game/player.js, без узлов сцены.

const TILE := GameConfig.TILE
const SPAWN_DIST := 3.5          # м от костра поселения до точки появления
const HOME_EDGE := 0.2           # поселение появления не ближе такой доли стороны карты к её краю (home)
const BODY_R := 0.3     # радиус тела пешехода, м: стены, перила и дома не подпускают центр ближе (и камеру в них)
const HUT_HALF := 1.6   # полуширина стен дома, м (квадрат 3,2 × 3,2, повёрнут дверью к костру, как в SettlementsBuilder)
## Полуширина построек мест (StageSites) по местным осям x и z, м
const SITE_HALF := {house = Vector2(1.6, 1.6), barn = Vector2(2.0, 1.5), shelter = Vector2(1.5, 1.5),
	tower = Vector2(1.3, 1.3), obelisk = Vector2(0.75, 0.75), ruin = Vector2(1.7, 1.7), keep = Vector2(1.6, 1.6),
	stone = Vector2(0.35, 0.25), hay = Vector2(0.9, 0.9)}
const PIECE := 0.2      # движение проверяется кусками не длиннее этого, м: тонкую стену не перепрыгнуть
                        # даже при длинном такте (в игре такт 1/60 с, это 0,1–0,35 м)
const LAKE_REACH := 3   # клеток от воды озера: игрок на берегу (открытие озера и цель у него, с 2.9)
const LAKE_STEP_BACK := 2.0  # на сколько клеток от воды встаёт игрок при быстром перемещении к озеру

var x := 0.0          # метры
var z := 0.0
var feet := 0.0       # высота ног
var vy := 0.0
var on_ground := true
var bob := 0.0        # фаза покачивания
var vx := 0.0         # скорость по земле, м/с
var vz := 0.0
var land_impact := 0.0 # скорость удара о землю при последнем приземлении (камера забирает и обнуляет)
var _air := 0.0       # сколько секунд без опоры
var _jump_buf := 0.0  # сколько ещё ждать земли, чтобы прыгнуть по уже нажатому пробелу


## Поселение, где игрок появляется: первое (лучшее место) не ближе HOME_EDGE стороны карты к её краю.
## С 1.9.9: карта — лишь стартовая область, за краем нет дорог, леса и поселений, и появляться у самого
## края нельзя. Если таких нет — ближайшее к середине карты
static func home(w: WorldData) -> Dictionary:
	if w.settlements.is_empty():
		return {}
	var best: Dictionary = w.settlements[0]
	var best_d := INF
	var margin := w.W * HOME_EDGE
	for s in w.settlements:
		if minf(minf(s.x, s.y), minf(w.W - s.x, w.H - s.y)) >= margin:
			return s
		var d := Vector2(s.x - w.W / 2.0, s.y - w.H / 2.0).length()
		if d < best_d:
			best_d = d
			best = s
	return best


## Точка появления: в 3,5 м от костра поселения (по умолчанию home), внутри кольца домов (дома стоят
## не ближе 6 м от центра). Из восьми сторон света берётся та, где до ближайшего дома дальше всего,
## чтобы не стоять носом в стену. При равенстве — юг, как в JS-версии.
static func spawn(w: WorldData, heights: Heightfield, at: Dictionary = {}) -> PlayerState:
	var p := PlayerState.new()
	p.x = (w.W / 2.0) * TILE
	p.z = (w.H / 2.0) * TILE
	if w.settlements.size() > 0:
		var s := at if not at.is_empty() else home(w)
		var fx: float = s.x * TILE
		var fz: float = s.y * TILE
		var best := -1.0
		for k in 8:
			var a := k * PI / 4.0
			var x := fx + sin(a) * SPAWN_DIST
			var z := fz + cos(a) * SPAWN_DIST
			if heights.depth_at(x, z) >= GameConfig.FORD_DEPTH:
				continue
			var clear := INF
			for u in s.huts:
				clear = minf(clear, Grid.hypot(u.x * TILE - x, u.y * TILE - z))
			if clear > best:
				best = clear
				p.x = x
				p.z = z
		if best < 0.0:
			p.x = fx
			p.z = fz + SPAWN_DIST
	p.feet = heights.ground_at(p.x, p.z)
	return p


## Быстрое перемещение (с 2.8): к костру поселения, на свободное место рядом с вершиной или (с 2.9)
## на берег озера. place — место из Hud.places(): {kind, x, y, src, ...}, x и y в клетках
static func arrive(w: WorldData, heights: Heightfield, place: Dictionary) -> PlayerState:
	if place.kind == "settlement":
		return spawn(w, heights, place.src)
	var p := PlayerState.new()
	var cx: float = place.x * TILE
	var cz: float = place.y * TILE
	if place.kind == "lake":
		# на пару клеток от воды: у самой кромки озеро закрыло бы весь вид
		var back := Vector2(place.src.sx - place.x, place.src.sy - place.y).normalized() * LAKE_STEP_BACK
		cx = (place.src.sx + back.x) * TILE
		cz = (place.src.sy + back.y) * TILE
	p.x = cx
	p.z = cz
	# по кольцам наружу: первое место, где можно стоять посуху (не в реке или заливе рядом с озером)
	var found := false
	for ring in range(0, 40):
		var r := ring * 1.5
		var n := maxi(1, ring * 6)
		for k in n:
			var a := k * TAU / n
			var x := cx + sin(a) * r
			var z := cz + cos(a) * r
			if heights.depth_at(x, z) <= 0.0 and is_passable(w, heights, x, z, -INF, BODY_R):
				p.x = x
				p.z = z
				found = true
				break
		if found:
			break
	if not found and not w.accessible(p.x / TILE, p.z / TILE, BODY_R / TILE):
		return spawn(w, heights)
	p.feet = heights.ground_at(p.x, p.z)
	return p


## Множитель скорости по местности
static func terrain_speed(w: WorldData, x: float, z: float, heights: Heightfield = null) -> float:
	var info := w.tile_info(x / TILE, z / TILE)
	if info.is_empty():
		return 0.0
	var sp: float = Biomes.LIST[info.biome].speed
	if sp == 0.0:
		sp = 0.4
	if heights != null and heights.road_refinement != null:
		var contact := heights.road_refinement.sample(x, z, w.W)
		if not contact.is_empty() and contact.surface != RoadSurface.NONE:
			var path_speed: float = maxf(sp, 1.0 if contact.road else 0.9) * RoadSurface.LIST[contact.surface].speed
			return lerpf(sp, path_speed, smoothstep(0.05, 0.9, contact.weight))
		# Уточнённая лента заменяет клеточный бонус даже там, где она уже закончилась.
		if info.path >= 2:
			return sp
	var surf := surface(info)
	if surf != RoadSurface.NONE:
		# с 4.3 скорость пути зависит от покрытия: гравий как прежняя дорога, тропа по лесу или камню медленнее
		sp = maxf(sp, 1.0 if info.path == 3 else 0.9) * RoadSurface.LIST[surf].speed
	elif info.path == 1:
		sp = maxf(sp, 0.8) * 1.12
	return sp


## Покрытие пути людей в клетке из tile_info (RoadSurface.*, NONE — не путь людей). Клетка дороги
## без своего покрытия (угол диагонали) — гравий, тропы — грунт
static func surface(info: Dictionary) -> int:
	if info.is_empty() or info.path < 2:
		return RoadSurface.NONE
	var s: int = info.get("surface", RoadSurface.NONE)
	if s != RoadSurface.NONE:
		return s
	return RoadSurface.GRAVEL if info.path == 3 else RoadSurface.DIRT


## Свободна ли точка (x, z) для тела радиуса r с ногами на высоте feet. feet решает, стоит ли тело
## на мосту (тогда вода под ним не мешает) и упирается ли в перила моста или стену туннеля.
## Дома, стены и (с 7.7) крупные стволы, валуны и валежник держат тело на расстоянии r,
## вода и край известной земли проверяются по центру
static func is_passable(w: WorldData, heights: Heightfield, x: float, z: float, feet: float = -INF, r: float = 0.0) -> bool:
	if not w.accessible(x / TILE, z / TILE, r / TILE) or not heights.known(x, z):
		return false
	# сквозь дома не пройти: стены — квадрат, тело не ближе r к нему. Дом поселения повёрнут дверью к костру
	for s in w.settlements:
		if absf(s.x * TILE - x) > 30.0 or absf(s.y * TILE - z) > 30.0:
			continue
		for u in s.huts:
			if _box_hits(x - u.x * TILE, z - u.y * TILE, atan2(s.x - u.x, s.y - u.y), Vector2(HUT_HALF, HUT_HALF), r):
				return false
	# Постройки мест вне поселений (с 9.3): прямоугольник по виду, повёрнут на a, как в SettlementsBuilder
	for s in w.sites:
		if absf(s.x * TILE - x) > 30.0 or absf(s.y * TILE - z) > 30.0:
			continue
		for u in s.huts:
			if _box_hits(x - u.x * TILE, z - u.y * TILE, u.a, SITE_HALF[u.t], r):
				return false
	if heights.wall_at(x, z, feet, r):
		return false
	if heights.obstacles != null and heights.obstacles.hits(x, z, feet, r):
		return false
	return heights.depth_at(x, z, feet) < GameConfig.FORD_DEPTH


## Задевает ли тело радиуса r стены прямоугольника half (м), повёрнутого на angle вокруг вертикали,
## если тело смещено от его середины на (dx, dz) м. Поворот — как Basis(Vector3.UP, angle) у мешей
static func _box_hits(dx: float, dz: float, angle: float, half: Vector2, r: float) -> bool:
	var reach := maxf(half.x, half.y) * 1.5 + r
	if absf(dx) > reach or absf(dz) > reach:
		return false
	var ox := absf(dx * cos(angle) - dz * sin(angle)) - half.x
	var oz := absf(dx * sin(angle) + dz * cos(angle)) - half.y
	return ox < r and oz < r and (ox <= 0.0 or oz <= 0.0 or ox * ox + oz * oz < r * r)


## Сдвиг из (x, z) на (dx, dz) кусками не длиннее PIECE: free(x, z) -> bool говорит, свободно ли тело
## в точке. Где путь закрыт, тело скользит вдоль препятствия по одной из осей, а где закрыто всё —
## останавливается. around(x, z) -> Vector2 (с 7.7, необязательно) — нормаль круглого препятствия
## (ствол, бревно) в закрытой точке: вдоль него тело скользит по касательной, а не по осям.
## Возвращает, куда удалось дойти: [x, z] в двойной точности (Vector2 округлил бы
## до float и мог сдвинуть тело за проверенную границу)
static func slide(free: Callable, x: float, z: float, dx: float, dz: float, around := Callable()) -> PackedFloat64Array:
	var n := maxi(1, ceili(Grid.hypot(dx, dz) / PIECE))
	var sx := dx / n
	var sz := dz / n
	for k in n:
		if free.call(x + sx, z + sz):
			x += sx
			z += sz
			continue
		var t := _tangent(around, x + sx, z + sz, sx, sz) if around.is_valid() else Vector2.ZERO
		if t != Vector2.ZERO and free.call(x + t.x, z + t.y):
			x += t.x
			z += t.y
		elif sx != 0.0 and free.call(x + sx, z):
			x += sx
			sz = 0.0
		elif sz != 0.0 and free.call(x, z + sz):
			z += sz
			sx = 0.0
		else:
			break
	return PackedFloat64Array([x, z])


## Касательный кусок пути вдоль препятствия с нормалью around(px, pz); ноль, если не к чему прижиматься
static func _tangent(around: Callable, px: float, pz: float, sx: float, sz: float) -> Vector2:
	var nrm: Vector2 = around.call(px, pz)
	var d := Vector2(sx, sz)
	var into := d.dot(nrm)
	if nrm == Vector2.ZERO or into >= 0.0:
		return Vector2.ZERO
	var t := d - nrm * into
	return t if t.length_squared() > 1e-10 else Vector2.ZERO


## Шаг движения за dt секунд (в игре — один такт физики, 1/60 с, см. GameWorld._physics_process).
## fw/st — вперёд и вбок (-1..1), yaw — курс взгляда, jump — пробел нажат в этом такте.
## Скорость набирается и гасится быстро, но не мгновенно; в прыжке управление слабее.
## Прыжок срабатывает и чуть после схода с края (COYOTE), и если пробел нажат чуть раньше приземления
## (JUMP_BUFFER). Возвращает true, если игрок пытался идти.
func step(fw: float, st: float, running: bool, jump: bool, yaw: float, dt: float, w: WorldData, heights: Heightfield) -> bool:
	var sy := sin(yaw)
	var cy := cos(yaw)
	var mx := -sy * fw + cy * st
	var mz := -cy * fw - sy * st
	var ln := Grid.hypot(mx, mz)
	var moving := ln > 0.0
	var gx := 0.0   # скорость, к которой стремимся
	var gz := 0.0
	if moving:
		mx /= ln
		mz /= ln
		var sp := GameConfig.WALK * (GameConfig.RUN if running else 1.0) * terrain_speed(w, x, z, heights)
		sp *= lerpf(1.0, 0.5, smoothstep(0.05, 0.8, heights.immersion_at(x, z, feet)))
		# в крутой подъём идти тяжелее
		var rise := (heights.surface_at(x + mx, z + mz, feet) - heights.surface_at(x, z, feet))
		var slow := 1.0 / (1.0 + rise * 1.2) if rise > 0.0 else 1.0
		gx = mx * sp * slow
		gz = mz * sp * slow
	var rate := GameConfig.WALK_ACCEL if moving else GameConfig.WALK_STOP
	if not on_ground:
		rate *= GameConfig.AIR_CONTROL
	var dvx := gx - vx
	var dvz := gz - vz
	var dl := Grid.hypot(dvx, dvz)
	if dl <= rate * dt:
		vx = gx
		vz = gz
	else:
		vx += dvx / dl * rate * dt
		vz += dvz / dl * rate * dt

	if vx != 0.0 or vz != 0.0:
		# если тело уже задевает препятствие (появилось вплотную к дому), выйти можно: проверяется центр
		var r := BODY_R if is_passable(w, heights, x, z, feet, BODY_R) else 0.0
		var f := feet
		var around := Callable()
		if heights.obstacles != null:
			var obs := heights.obstacles
			around = func(px: float, pz: float) -> Vector2: return obs.normal(px, pz, f, r)
		var to := slide(func(px: float, pz: float) -> bool: return is_passable(w, heights, px, pz, f, r), x, z, vx * dt, vz * dt, around)
		# упёрлись: скорость — та, с которой действительно сдвинулись
		if absf(to[0] - x - vx * dt) > 1e-5:
			vx = (to[0] - x) / dt
		if absf(to[1] - z - vz * dt) > 1e-5:
			vz = (to[1] - z) / dt
		x = to[0]
		z = to[1]
	if on_ground:
		bob += dt * Grid.hypot(vx, vz) * 1.6

	_air = 0.0 if on_ground else _air + dt
	_jump_buf = GameConfig.JUMP_BUFFER if jump else _jump_buf - dt
	if _jump_buf > 0.0 and vy <= 0.0 and (on_ground or _air < GameConfig.COYOTE):
		vy = GameConfig.JUMP
		on_ground = false
		_jump_buf = 0.0
		_air = GameConfig.COYOTE
	# путь за такт по средней скорости такта: высота прыжка точно та же, что при бесконечно частых тактах
	var g := heights.surface_at(x, z, feet)
	feet += (vy - GameConfig.GRAVITY * dt * 0.5) * dt
	vy -= GameConfig.GRAVITY * dt
	if feet <= g:
		if not on_ground:
			land_impact = maxf(land_impact, -vy)
		feet = g
		vy = 0.0
		on_ground = true
	elif feet - g > 0.05:
		on_ground = false
	# на склоне вниз держимся у земли, а не «летим»
	if not on_ground and vy <= 0.0 and feet - g < 0.4:
		feet = g
		vy = 0.0
		on_ground = true
	return moving


## Скорость по земле, м/с
func ground_speed() -> float:
	return Grid.hypot(vx, vz)


## Открытия: поселения, вершины и озёра (на берегу) рядом с игроком. Возвращает тексты новых открытий
func check_discoveries(w: WorldData, visited: Dictionary) -> PackedStringArray:
	var found := PackedStringArray()
	var tx := x / TILE
	var tz := z / TILE
	# сначала расстояние, потом ключ: строки не собираются 60 раз в секунду для каждого места
	# ключи visited — устойчивые адреса мест (WorldData.place_id)
	for s in w.settlements:
		if Grid.hypot(s.x - tx, s.y - tz) < 6.0:
			var key := WorldData.place_id("settlement", s.x, s.y)
			if not visited.has(key):
				visited[key] = true
				found.append("Поселение «%s»" % s.name)
	for pk in w.peaks:
		if Grid.hypot(pk.x - tx, pk.y - tz) < 2.5:
			var key := WorldData.place_id("peak", pk.x, pk.y)
			if not visited.has(key):
				visited[key] = true
				found.append("Вы покорили вершину «%s»!" % pk.name)
	for st in w.sites:
		if Grid.hypot(st.x - tx, st.y - tz) < 4.0:
			var key := WorldData.place_id("site", st.x, st.y)
			if not visited.has(key):
				visited[key] = true
				found.append("Новое место: «%s», %s" % [st.name, StageSites.TYPES[st.type].title])
	var lk := w.lake_near(tx, tz, LAKE_REACH)
	if lk >= 0:
		var key := WorldData.place_id("lake", w.lakes[lk].x, w.lakes[lk].y)
		if not visited.has(key):
			visited[key] = true
			found.append("Вы вышли к озеру: «%s»" % w.lakes[lk].name)
	return found
