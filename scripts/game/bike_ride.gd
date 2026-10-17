class_name BikeRide
extends RefCounted
## Велосипед: где стоит, разгон и торможение, руль, подъёмы. Без узлов сцены, как PlayerState.
## Пока игрок едет, велосипед везёт его: положение игрока берётся отсюда. Проходимость та же, что
## у пешехода (PlayerState.is_passable): глубокая вода и дома не пускают.

const TILE := GameConfig.TILE

var x := 0.0          # метры
var z := 0.0
var heading := 0.0    # курс, как yaw камеры: 0 — на север (-Z)
var speed := 0.0      # м/с вдоль курса, назад — меньше нуля
var riding := false
var lean := 0.0       # крен в повороте, радианы
var tilt := 0.0       # наклон вдоль склона, радианы
var wheel := 0.0      # угол поворота колёс
var steer := 0.0      # положение руля -1..1


## Поставить велосипед справа от игрока, лицом туда же, куда смотрит игрок
static func park_near(p: PlayerState, yaw: float, w: WorldData, heights: Heightfield) -> BikeRide:
	var b := BikeRide.new()
	b.heading = yaw
	b.x = p.x
	b.z = p.z
	for side in [1.6, -1.6]:
		var bx: float = p.x + cos(yaw) * side
		var bz: float = p.z - sin(yaw) * side
		if PlayerState.is_passable(w, heights, bx, bz):
			b.x = bx
			b.z = bz
			break
	return b


func distance_to(p: PlayerState) -> float:
	return Grid.hypot(x - p.x, z - p.z)


func mount(p: PlayerState) -> void:
	riding = true
	speed = 0.0
	p.x = x
	p.z = z
	p.vy = 0.0
	p.on_ground = true


## Слезть: велосипед остаётся на месте, игрок встаёт слева от него
func dismount(p: PlayerState, w: WorldData, heights: Heightfield) -> void:
	riding = false
	speed = 0.0
	lean = 0.0
	steer = 0.0
	var px := x - cos(heading) * 0.9
	var pz := z + sin(heading) * 0.9
	if PlayerState.is_passable(w, heights, px, pz):
		p.x = px
		p.z = pz
	p.feet = heights.ground_at(p.x, p.z)


## Шаг езды за dt секунд. throttle — газ (+) и тормоз (-), turn — руль вправо (+) и влево (-).
func step(p: PlayerState, throttle: float, turn: float, boost: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	var fx := -sin(heading)
	var fz := -cos(heading)
	# подъём на метр пути вдоль курса
	var slope := (heights.ground_at(x + fx, z + fz) - heights.ground_at(x - fx, z - fz)) * 0.5
	if speed < 0.0:
		slope = -slope
	var top := GameConfig.BIKE_SPEED * (GameConfig.BIKE_BOOST if boost else 1.0) * PlayerState.terrain_speed(w, x, z)
	if heights.depth_at(x, z) > 0.3:
		top *= 0.4
	# в подъём заметно медленнее, с горы чуть быстрее
	top *= 1.0 / (1.0 + slope * 6.0) if slope > 0.0 else 1.0 + minf(-slope, 0.3)

	var goal := 0.0
	var rate := GameConfig.BIKE_ROLL
	if throttle > 0.0:
		goal = top * throttle
		rate = GameConfig.BIKE_ACCEL if speed < goal else GameConfig.BIKE_ROLL
	elif throttle < 0.0:
		goal = -GameConfig.BIKE_REVERSE if speed < 0.5 else 0.0
		rate = GameConfig.BIKE_BRAKE
	speed = move_toward(speed, goal, rate * dt)

	steer = move_toward(steer, turn, dt * 4.0)
	# на месте руль почти не поворачивает велосипед, на скорости — быстрее, но не резко
	var turn_rate := GameConfig.BIKE_TURN * clampf(absf(speed) / 3.0, 0.15, 1.0) / (1.0 + absf(speed) * 0.04)
	heading -= steer * turn_rate * dt * (1.0 if speed >= 0.0 else -1.0)

	var nx := x - sin(heading) * speed * dt
	var nz := z - cos(heading) * speed * dt
	if PlayerState.is_passable(w, heights, nx, nz):
		x = nx
		z = nz
	elif PlayerState.is_passable(w, heights, nx, z):
		x = nx
		speed *= 1.0 - minf(1.0, dt * 3.0)
	elif PlayerState.is_passable(w, heights, x, nz):
		z = nz
		speed *= 1.0 - minf(1.0, dt * 3.0)
	else:
		speed = 0.0

	tilt = atan(slope if speed >= 0.0 else -slope)
	lean = lerpf(lean, -steer * minf(1.0, absf(speed) / 6.0) * 0.35, minf(1.0, dt * 6.0))
	wheel += speed * dt / 0.34
	p.x = x
	p.z = z
	p.feet = heights.ground_at(x, z)
	p.vy = 0.0
	p.on_ground = true
