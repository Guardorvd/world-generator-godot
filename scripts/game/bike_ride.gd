class_name BikeRide
extends RefCounted
## Велосипед: где стоит, разгон и торможение, руль, подъёмы, полёт с горбов и прыжок, подвеска.
## Без узлов сцены, как PlayerState. Пока игрок едет, велосипед везёт его: положение игрока
## берётся отсюда. Проходимость та же, что у пешехода (PlayerState.is_passable): глубокая вода,
## дома, перила мостов и стены туннелей не пускают; по настилу моста велосипед едет, как по земле.

const TILE := GameConfig.TILE
const WHEEL_R := 0.34   # радиус колеса, м
const GEAR := 2.8       # оборотов колеса на один оборот педалей

var x := 0.0          # метры
var z := 0.0
var y := 0.0          # высота, где колёса касаются земли (в полёте — над землёй)
var vy := 0.0         # вертикальная скорость, м/с
var airborne := false
var heading := 0.0    # курс, как yaw камеры: 0 — на север (-Z)
var speed := 0.0      # м/с вдоль курса, назад — меньше нуля
var riding := false
var lean := 0.0       # крен в повороте, радианы
var tilt := 0.0       # наклон вдоль склона или полёта, радианы
var wheel := 0.0      # угол поворота колёс
var crank := 0.0      # угол педалей
var steer := 0.0      # положение руля -1..1
var squash := 0.0     # насколько просела подвеска, м (меньше нуля — вытянулась при прыжке)
var squash_v := 0.0
var sway := 0.0       # покачивание на неровностях, радианы крена
var _dist := 0.0      # пройденный путь, для покачивания
var air_time := 0.0   # сколько секунд в воздухе
var _hop_wait := 0.0  # после приземления прыжок доступен не сразу
var _hop_buf := 0.0   # пробел, нажатый чуть раньше, чем прыжок стал доступен
var crashed := false  # жёстко приземлились: седок упал (GameWorld ссадит его и сбросит флаг)
var land_impact := 0.0 # сила последнего приземления, м/с (для тряски камеры)


## Поставить велосипед справа от игрока, лицом туда же, куда смотрит игрок
static func park_near(p: PlayerState, yaw: float, w: WorldData, heights: Heightfield) -> BikeRide:
	var b := BikeRide.new()
	b.heading = yaw
	b.x = p.x
	b.z = p.z
	for side in [1.6, -1.6]:
		var bx: float = p.x + cos(yaw) * side
		var bz: float = p.z - sin(yaw) * side
		if PlayerState.is_passable(w, heights, bx, bz, p.feet):
			b.x = bx
			b.z = bz
			break
	b.y = heights.surface_at(b.x, b.z, p.feet)
	return b


func distance_to(p: PlayerState) -> float:
	return Grid.hypot(x - p.x, z - p.z)


func mount(p: PlayerState) -> void:
	riding = true
	speed = 0.0
	p.x = x
	p.z = z
	p.vy = 0.0
	p.vx = 0.0
	p.vz = 0.0
	p.on_ground = true


## Слезть: велосипед остаётся на месте, игрок встаёт слева от него. В полёте слезть нельзя.
func dismount(p: PlayerState, w: WorldData, heights: Heightfield) -> void:
	riding = false
	speed = 0.0
	lean = 0.0
	steer = 0.0
	sway = 0.0
	squash = 0.0
	squash_v = 0.0
	_hop_buf = 0.0
	y = heights.surface_at(x, z, y)
	p.vx = 0.0
	p.vz = 0.0
	var px := x - cos(heading) * 0.9
	var pz := z + sin(heading) * 0.9
	if PlayerState.is_passable(w, heights, px, pz, y):
		p.x = px
		p.z = pz
	p.feet = heights.surface_at(p.x, p.z, y)


## Подъём земли на метр пути вдоль курса
func _slope(heights: Heightfield) -> float:
	var fx := -sin(heading)
	var fz := -cos(heading)
	return (heights.surface_at(x + fx, z + fz, y) - heights.surface_at(x - fx, z - fz, y)) * 0.5


## Шаг езды за dt секунд. throttle — газ (+) и тормоз (-), turn — руль вправо (+) и влево (-),
## hop — пробел нажат в этом кадре (срабатывает, как только прыжок доступен, если ждать недолго).
func step(p: PlayerState, throttle: float, turn: float, boost: bool, hop: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	var slope := _slope(heights)
	var climb := slope if speed >= 0.0 else -slope
	if not airborne:
		var top := GameConfig.BIKE_SPEED * (GameConfig.BIKE_BOOST if boost else 1.0) * PlayerState.terrain_speed(w, x, z)
		if heights.depth_at(x, z, y) > 0.3:
			top *= 0.4
		# в подъём заметно медленнее, с горы чуть быстрее
		top *= 1.0 / (1.0 + climb * 6.0) if climb > 0.0 else 1.0 + minf(-climb, 0.3)

		var goal := 0.0
		var rate := GameConfig.BIKE_ROLL
		if throttle > 0.0:
			goal = top * throttle
			# с места разгон резвее, у предельной скорости — мягче
			rate = GameConfig.BIKE_ACCEL * clampf(1.6 - speed / maxf(top, 1.0), 0.5, 1.6) if speed < goal else GameConfig.BIKE_ROLL
		elif throttle < 0.0:
			goal = -GameConfig.BIKE_REVERSE if speed < 0.5 else 0.0
			rate = GameConfig.BIKE_BRAKE
		speed = move_toward(speed, goal, rate * dt)
	else:
		# в воздухе педали и тормоз скорость не меняют, только сопротивление воздуха
		speed -= speed * 0.03 * dt

	steer = move_toward(steer, turn, dt * 4.0)
	# на месте руль почти не поворачивает велосипед, на скорости — быстрее, но не резко; в воздухе слабо
	var turn_rate := GameConfig.BIKE_TURN * clampf(absf(speed) / 3.0, 0.15, 1.0) / (1.0 + absf(speed) * 0.04)
	if airborne:
		turn_rate *= 0.3
	heading -= steer * turn_rate * dt * (1.0 if speed >= 0.0 else -1.0)

	var nx := x - sin(heading) * speed * dt
	var nz := z - cos(heading) * speed * dt
	var x0 := x
	var z0 := z
	if PlayerState.is_passable(w, heights, nx, nz, y):
		x = nx
		z = nz
	elif PlayerState.is_passable(w, heights, nx, z, y):
		x = nx
		speed *= 1.0 - minf(1.0, dt * 3.0)
	elif PlayerState.is_passable(w, heights, x, nz, y):
		z = nz
		speed *= 1.0 - minf(1.0, dt * 3.0)
	else:
		speed = 0.0
	var moved := Grid.hypot(x - x0, z - z0)
	_dist += moved

	_hop_wait -= dt
	_hop_buf = GameConfig.JUMP_BUFFER if hop else _hop_buf - dt
	var g := heights.surface_at(x, z, y)
	if not airborne and _hop_buf > 0.0 and _hop_wait <= 0.0:
		_hop_buf = 0.0
		# прыжок: подвеска сначала распрямляется
		airborne = true
		air_time = 0.0
		vy = maxf(vy, 0.0) + GameConfig.BIKE_HOP
		squash_v -= 0.9
	if airborne:
		air_time += dt
		vy -= GameConfig.GRAVITY * dt
		y += vy * dt
		if y <= g:
			_land(g, heights)
	else:
		# куда унесло бы велосипед без опоры: если земля уходит вниз быстрее — он летит
		var fly := y + (vy - GameConfig.GRAVITY * dt) * dt
		if fly > g + 0.01:
			airborne = true
			air_time = 0.0
			vy -= GameConfig.GRAVITY * dt
			y = fly
		else:
			var gv := (g - y) / dt if dt > 0.0 else 0.0
			# резкая смена наклона земли толкает подвеску
			squash_v += clampf(gv - vy, -3.0, 3.0) * 0.12
			vy = gv
			y = g

	# подвеска — пружина с затуханием, упирается в ход 0.16 м
	squash_v += (-170.0 * squash - 14.0 * squash_v) * dt
	squash += squash_v * dt
	if squash > 0.16:
		squash = 0.16
		squash_v = minf(squash_v, 0.0)
	elif squash < -0.08:
		squash = -0.08
		squash_v = maxf(squash_v, 0.0)

	var tilt_goal := atan(climb)
	if airborne:
		# в полёте нос смотрит по направлению движения
		tilt_goal = atan2(vy, maxf(absf(speed), 2.0))
		if speed < 0.0:
			tilt_goal = -tilt_goal
	tilt = lerpf(tilt, tilt_goal, minf(1.0, dt * (5.0 if airborne else 12.0)))
	var lean_goal := 0.0 if airborne else -steer * minf(1.0, absf(speed) / 6.0) * 0.35
	lean = lerpf(lean, lean_goal, minf(1.0, dt * 6.0))
	# на неровной местности (лес, кусты, бездорожье) качает сильнее, чем на тропе
	var rough := clampf(1.3 - PlayerState.terrain_speed(w, x, z), 0.15, 1.0)
	var sway_goal := 0.0
	if not airborne:
		sway_goal = (sin(_dist * 1.9) * 0.6 + sin(_dist * 4.7 + 1.3) * 0.4) * 0.03 * rough * minf(1.0, absf(speed) / 5.0)
		squash_v += sin(_dist * 6.1) * sin(_dist * 2.3) * rough * absf(speed) * dt * 0.5
	sway = lerpf(sway, sway_goal, minf(1.0, dt * 8.0))

	wheel += speed * dt / WHEEL_R
	# педали крутятся, только пока их жмут: накатом и в полёте свободный ход
	if throttle > 0.0 and speed > 0.3:
		crank += speed * dt / WHEEL_R / GEAR
	p.x = x
	p.z = z
	p.feet = y
	p.vy = vy
	p.on_ground = not airborne


## Приземление: подвеска проседает тем сильнее, чем жёстче удар; жёсткий удар гасит скорость,
## а слишком жёсткий (с высоты больше 5 м на ровное) сбрасывает седока
func _land(g: float, heights: Heightfield) -> void:
	var gv := _slope(heights) * speed
	var impact := maxf(0.0, gv - vy)
	airborne = false
	y = g
	vy = gv
	land_impact = maxf(land_impact, impact)
	squash_v += impact * 0.28
	if impact > GameConfig.BIKE_CRASH:
		crashed = true
		speed = 0.0
	elif impact > 7.0:
		speed *= 1.0 - clampf((impact - 7.0) * 0.05, 0.0, 0.5)
	# короткие подскоки на неровностях не мешают прыгать
	if air_time > 0.2:
		_hop_wait = 0.25
	air_time = 0.0
