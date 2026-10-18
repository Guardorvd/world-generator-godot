class_name PlayerState
extends RefCounted
## Игрок: появление, движение по местности, прыжок, проходимость. Копия js/game/player.js, без узлов сцены.

const TILE := GameConfig.TILE
const HOME_EDGE := 0.2           # поселение появления не ближе такой доли стороны карты к её краю (home)

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


## Точка появления: в 3,5 м от костра поселения home, внутри кольца домов (дома стоят не ближе 6 м
## от центра). Из восьми сторон света берётся та, где до ближайшего дома дальше всего, чтобы не стоять
## носом в стену. При равенстве — юг, как в JS-версии.
static func spawn(w: WorldData, heights: Heightfield) -> PlayerState:
	var p := PlayerState.new()
	p.x = (w.W / 2.0) * TILE
	p.z = (w.H / 2.0) * TILE
	if w.settlements.size() > 0:
		var s := home(w)
		var fx: float = s.x * TILE
		var fz: float = s.y * TILE
		var best := -1.0
		for k in 8:
			var a := k * PI / 4.0
			var x := fx + sin(a) * 3.5
			var z := fz + cos(a) * 3.5
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
			p.z = fz + 3.5
	p.feet = heights.ground_at(p.x, p.z)
	return p


## Множитель скорости по местности
static func terrain_speed(w: WorldData, x: float, z: float) -> float:
	var info := w.tile_info(x / TILE, z / TILE)
	if info.is_empty():
		return 0.0
	var sp: float = Biomes.LIST[info.biome].speed
	if sp == 0.0:
		sp = 0.4
	if info.path == 3:
		sp = maxf(sp, 1.0) * 1.4
	elif info.path == 2:
		sp = maxf(sp, 0.9) * 1.3
	elif info.path == 1:
		sp = maxf(sp, 0.8) * 1.12
	return sp


## feet — высота ног: от неё зависит, стоит ли игрок на мосту (тогда вода под ним не мешает)
## и упирается ли в перила моста или стену туннеля
static func is_passable(w: WorldData, heights: Heightfield, x: float, z: float, feet: float = -INF) -> bool:
	if not heights.known(x, z):
		return false
	# сквозь дома не пройти
	for s in w.settlements:
		if absf(s.x * TILE - x) > 30.0 or absf(s.y * TILE - z) > 30.0:
			continue
		for u in s.huts:
			if Grid.hypot(u.x * TILE - x, u.y * TILE - z) < 2.1:
				return false
	if heights.wall_at(x, z, feet):
		return false
	return heights.depth_at(x, z, feet) < GameConfig.FORD_DEPTH


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
		var sp := GameConfig.WALK * (GameConfig.RUN if running else 1.0) * terrain_speed(w, x, z)
		if heights.depth_at(x, z, feet) > 0.3:
			sp *= 0.5
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

	var ax := x + vx * dt
	var az := z + vz * dt
	if is_passable(w, heights, ax, az, feet):
		x = ax
		z = az
	elif is_passable(w, heights, ax, z, feet):
		x = ax
		vz = 0.0
	elif is_passable(w, heights, x, az, feet):
		z = az
		vx = 0.0
	else:
		vx = 0.0
		vz = 0.0
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


## Открытия: поселения и вершины рядом с игроком. Возвращает тексты новых открытий
func check_discoveries(w: WorldData, visited: Dictionary) -> PackedStringArray:
	var found := PackedStringArray()
	var tx := x / TILE
	var tz := z / TILE
	for s in w.settlements:
		if not visited.has("s%d" % s.i) and Grid.hypot(s.x - tx, s.y - tz) < 6.0:
			visited["s%d" % s.i] = true
			found.append("Поселение «%s»" % s.name)
	for pk in w.peaks:
		if not visited.has("p%d" % pk.i) and Grid.hypot(pk.x - tx, pk.y - tz) < 2.5:
			visited["p%d" % pk.i] = true
			found.append("Вы покорили вершину «%s»!" % pk.name)
	return found
