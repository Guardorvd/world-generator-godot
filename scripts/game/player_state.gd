class_name PlayerState
extends RefCounted
## Игрок: появление, движение по местности, прыжок, проходимость. Копия js/game/player.js, без узлов сцены.

const TILE := GameConfig.TILE

var x := 0.0          # метры
var z := 0.0
var feet := 0.0       # высота ног
var vy := 0.0
var on_ground := true
var bob := 0.0        # фаза покачивания


## Точка появления: в 3,5 м от костра первого поселения, внутри кольца домов (дома стоят не ближе 6 м
## от центра). Из восьми сторон света берётся та, где до ближайшего дома дальше всего, чтобы не стоять
## носом в стену. При равенстве — юг, как в JS-версии.
static func spawn(w: WorldData, heights: Heightfield) -> PlayerState:
	var p := PlayerState.new()
	p.x = (w.W / 2.0) * TILE
	p.z = (w.H / 2.0) * TILE
	if w.settlements.size() > 0:
		var s: Dictionary = w.settlements[0]
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
	if info.path == 2:
		sp = maxf(sp, 0.9) * 1.3
	elif info.path == 1:
		sp = maxf(sp, 0.8) * 1.12
	return sp


static func is_passable(w: WorldData, heights: Heightfield, x: float, z: float) -> bool:
	if x < TILE or z < TILE or x > (w.W - 1) * TILE or z > (w.H - 1) * TILE:
		return false
	# сквозь дома не пройти
	for s in w.settlements:
		if absf(s.x * TILE - x) > 30.0 or absf(s.y * TILE - z) > 30.0:
			continue
		for u in s.huts:
			if Grid.hypot(u.x * TILE - x, u.y * TILE - z) < 2.1:
				return false
	return heights.depth_at(x, z) < GameConfig.FORD_DEPTH


## Шаг движения за dt секунд. fw/st — вперёд и вбок (-1..1), yaw — курс взгляда.
## Возвращает true, если игрок пытался идти.
func step(fw: float, st: float, running: bool, jump: bool, yaw: float, dt: float, w: WorldData, heights: Heightfield) -> bool:
	var sy := sin(yaw)
	var cy := cos(yaw)
	var mx := -sy * fw + cy * st
	var mz := -cy * fw - sy * st
	var ln := Grid.hypot(mx, mz)
	var moving := ln > 0.0
	if moving:
		mx /= ln
		mz /= ln
		var sp := GameConfig.WALK * (GameConfig.RUN if running else 1.0) * terrain_speed(w, x, z)
		if heights.depth_at(x, z) > 0.3:
			sp *= 0.5
		var nx := x + mx * sp * dt
		var nz := z + mz * sp * dt
		# в крутой подъём идти тяжелее
		var rise := (heights.ground_at(nx, nz) - heights.ground_at(x, z)) / maxf(1e-3, sp * dt)
		var slow := 1.0 / (1.0 + rise * 1.2) if rise > 0.0 else 1.0
		var ax := x + mx * sp * slow * dt
		var az := z + mz * sp * slow * dt
		if is_passable(w, heights, ax, az):
			x = ax
			z = az
		elif is_passable(w, heights, ax, z):
			x = ax
		elif is_passable(w, heights, x, az):
			z = az
		if on_ground:
			bob += dt * sp * 1.6
	if jump and on_ground:
		vy = GameConfig.JUMP
		on_ground = false
	vy -= GameConfig.GRAVITY * dt
	feet += vy * dt
	var g := heights.ground_at(x, z)
	if feet <= g:
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
