class_name BikeRide
extends RefCounted
## Велосипед: где стоит, разгон и торможение, руль, подъёмы, полёт с горбов и прыжок, подвеска.
## Без узлов сцены, как PlayerState. Пока игрок едет, велосипед везёт его: положение игрока
## берётся отсюда. Проходимость та же, что у пешехода (PlayerState.is_passable): глубокая вода,
## дома, перила мостов и стены туннелей не пускают; по настилу моста велосипед едет, как по земле.
## С 2.2 велосипед для столкновений — три круга вдоль рамы (колёса и середина), а не точка:
## переднее колесо не въезжает в дом и не высовывается за перила.

const WHEEL_R := 0.34   # радиус колеса, м
const GEAR := 2.8       # оборотов колеса на один оборот педалей
const WALL_LOSS := 6.0  # 1/с: как быстро удар в стену в лоб гасит скорость (при скольжении вдоль стены почти не гасит)
const BODY_R := 0.3     # радиус кругов, которыми велосипед задевает препятствия, м (руль шириной 0,6 м)
const AXLE := 0.57      # круги колёс — на столько впереди и позади середины, м: вместе с BODY_R до края колеса (0,53 + 0,34)
const SPRING_K := 170.0   # жёсткость подвески, 1/с²
const SPRING_DAMP := 16.0 # затухание подвески, 1/с
const SAG_MAX := 0.16     # подвеска просаживается не больше этого, м
const STRETCH_MAX := 0.08 # и вытягивается при прыжке не больше этого, м
const SOFT_IMPACT := 7.0  # приземление жёстче этого (м/с) гасит скорость
## На пути колёса держатся полотна на мелких изломах, руль зависит от сцепления покрытия.
const SLOPE_GRAVITY := 7.5 # смягчённая сила склона: инерция ощутима, но подъёмы доступны
const CORNER_GRIP := 10.5 # допустимое боковое ускорение на плотной земле, м/с²
const HOP_COYOTE := 0.1  # можно успеть прыгнуть сразу после схода с края, с

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
var _yaw_rate := 0.0   # фактическая угловая скорость поворота, рад/с
var _coyote := 0.0     # запас прыжка после схода с края
var _brake_hold := 0.0 # сколько секунд держат тормоз у остановки
var crashed := false  # жёстко приземлились: седок упал (GameWorld ссадит его и сбросит флаг)
var land_impact := 0.0 # сила последнего приземления, м/с (для тряски камеры)


## Поставить велосипед справа от игрока, лицом туда же, куда смотрит игрок
static func park_near(p: PlayerState, yaw: float, w: WorldData, heights: Heightfield) -> BikeRide:
	var b := BikeRide.new()
	b.heading = yaw
	b.x = p.x
	b.z = p.z
	b.y = p.feet
	for side: float in [1.6, -1.6]:
		var bx: float = p.x + cos(yaw) * side
		var bz: float = p.z - sin(yaw) * side
		if b.fits(bx, bz, yaw, w, heights):
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
	_yaw_rate = 0.0
	_coyote = 0.0
	p.x = x
	p.z = z
	p.vy = 0.0
	p.vx = 0.0
	p.vz = 0.0
	p.on_ground = true
	p.feet = y


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
	_brake_hold = 0.0
	_yaw_rate = 0.0
	_coyote = 0.0
	y = heights.surface_at(x, z, y)
	p.vx = 0.0
	p.vy = 0.0
	p.vz = 0.0
	p.on_ground = true
	var spot := _dismount_spot(w, heights)
	p.x = spot.x
	p.z = spot.y
	p.feet = heights.surface_at(p.x, p.z, y)


## Место для седока у велосипеда: слева, справа, сзади или спереди, первое проходимое.
## Если рядом нигде не пройти, седок встаёт на место велосипеда
func _dismount_spot(w: WorldData, heights: Heightfield) -> Vector2:
	var fwd := Vector2(-sin(heading), -cos(heading))
	var dirs: Array[Vector2] = [Vector2(-cos(heading), sin(heading)), Vector2(cos(heading), -sin(heading)), -fwd, fwd]
	for dist: float in [0.9, 1.5]:
		for d: Vector2 in dirs:
			var q := Vector2(x, z) + d * dist
			if PlayerState.is_passable(w, heights, q.x, q.y, y, PlayerState.BODY_R):
				return q
	return Vector2(x, z)


## Подъём земли на метр пути вдоль курса
func _slope(heights: Heightfield) -> float:
	var fx := -sin(heading)
	var fz := -cos(heading)
	return (heights.surface_at(x + fx, z + fz, y) - heights.surface_at(x - fx, z - fz, y)) * 0.5


## Шаг езды за dt секунд (в игре — один такт физики, 1/60 с). throttle — газ (+) и тормоз (-),
## turn — руль вправо (+) и влево (-), hop — пробел нажат в этом такте (срабатывает, как только прыжок
## доступен, если ждать недолго).
func step(p: PlayerState, throttle: float, turn: float, boost: bool, hop: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	var slope := _slope(heights)
	var surf := PlayerState.surface(w.tile_info(x / GameConfig.TILE, z / GameConfig.TILE))
	var path_weight := 1.0 if surf != RoadSurface.NONE else 0.0
	if heights.road_refinement != null:
		var contact := heights.road_refinement.sample(x, z, w.W)
		surf = contact.surface if not contact.is_empty() else RoadSurface.NONE
		path_weight = smoothstep(0.05, 0.9, contact.weight) if not contact.is_empty() else 0.0
	var on_path := surf != RoadSurface.NONE
	var speed0 := speed
	if not airborne:
		var terrain := maxf(0.15, PlayerState.terrain_speed(w, x, z, heights))
		if heights.depth_at(x, z, y) > 0.3:
			terrain *= 0.4
		_step_speed(throttle, boost, slope, terrain, dt)
	else:
		# В воздухе педали и тормоз не меняют скорость и не готовят задний ход.
		_brake_hold = 0.0
		speed *= exp(-0.03 * dt)

	var grip := 0.85
	if on_path:
		grip = lerpf(grip, RoadSurface.LIST[surf].grip, path_weight)
	var free_now := fits(x, z, heading, w, heights)
	var h0 := heading
	heading += _step_turn(turn, grip, dt)
	# Вплотную к стене колесо не поворачивается в неё, накопленного рывка тоже нет.
	if free_now and not fits(x, z, heading, w, heights):
		heading = h0
		_yaw_rate = 0.0
	var lateral := speed * (heading - h0) / maxf(dt, 0.0001)

	var x0 := x
	var z0 := z
	var full := absf(speed) * dt
	if full > 0.0:
		# если велосипед уже задевает препятствие (поставлен вплотную), выехать можно: проверяется середина
		var hd := heading
		var free := func(px: float, pz: float) -> bool:
			if free_now:
				return fits(px, pz, hd, w, heights)
			return PlayerState.is_passable(w, heights, px, pz, y)
		var to := PlayerState.slide(free, x, z, -sin(heading) * speed * dt, -cos(heading) * speed * dt)
		x = to[0]
		z = to[1]
		var moved := Grid.hypot(x - x0, z - z0)
		if moved < full - 1e-5:
			# в лоб скорость гаснет, при скольжении вдоль стены почти нет
			speed = 0.0 if moved < 1e-5 else speed * _slide_keep(dt, moved, full)
	_dist += Grid.hypot(x - x0, z - z0)

	_step_vertical(heights.surface_at(x, z, y), path_weight, hop, dt, heights)
	_step_suspension(dt, minf(absf(lateral) * 0.001, 0.015))

	# Рама следует рельефу; разгон приподнимает нос, торможение слегка загружает передок.
	var acceleration := clampf((speed - speed0) / maxf(dt, 0.0001), -9.0, 7.0)
	var tilt_goal := atan(_slope(heights)) + acceleration * 0.008
	if airborne:
		tilt_goal = clampf(atan2(vy, maxf(absf(speed), 4.0)), -0.55, 0.55)
		if speed < 0.0:
			tilt_goal = -tilt_goal
	tilt = lerpf(tilt, tilt_goal, 1.0 - exp(-dt * (5.0 if airborne else 12.0)))
	# Крен от реального поворота, а не от кнопки: на месте не заваливаемся.
	var lean_goal := 0.0 if airborne else clampf(atan(lateral / GameConfig.GRAVITY), -0.55, 0.55)
	lean = lerpf(lean, lean_goal, 1.0 - exp(-dt * (2.5 if airborne else 9.0)))
	# на неровной местности (лес, кусты, бездорожье) качает сильнее, чем на тропе
	var rough := clampf(1.3 - PlayerState.terrain_speed(w, x, z, heights), 0.15, 1.0)
	if on_path:
		rough = lerpf(rough, RoadSurface.LIST[surf].rough, path_weight)
	var sway_goal := 0.0
	if not airborne:
		sway_goal = (sin(_dist * 1.9) * 0.6 + sin(_dist * 4.7 + 1.3) * 0.4) * 0.03 * rough * minf(1.0, absf(speed) / 5.0)
	sway = lerpf(sway, sway_goal, minf(1.0, dt * 8.0))

	# углы держим в пределах оборота, чтобы за долгую езду они не теряли точность
	wheel = fmod(wheel + speed * dt / WHEEL_R, TAU)
	# педали крутятся, только пока их жмут на земле: накатом и в полёте свободный ход
	if throttle > 0.0 and speed > 0.3 and not airborne:
		crank = fmod(crank + speed * dt / WHEEL_R / GEAR, TAU)
	p.x = x
	p.z = z
	p.feet = y
	p.vy = vy
	p.on_ground = not airborne


## Руль отзывчив на малой скорости; на большой сцепление расширяет дугу и чуть съедает ход.
## Отдельного заноса и балансирования нет: поворот всегда идёт в сторону управления.
func _step_turn(turn: float, grip: float, dt: float) -> float:
	steer = move_toward(steer, turn, dt * (7.0 if is_zero_approx(turn) else 5.0))
	var pace := absf(speed)
	var rate := GameConfig.BIKE_TURN * clampf(pace / 3.0, 0.0, 1.0) / (1.0 + pace * 0.04)
	var wanted := -steer * rate * (1.0 if speed >= 0.0 else -1.0)
	if airborne:
		wanted *= 0.25
	else:
		var limit := CORNER_GRIP * grip / maxf(pace, 3.0)
		var excess := maxf(0.0, absf(wanted) * pace - CORNER_GRIP * grip)
		wanted = clampf(wanted, -limit, limit)
		speed = move_toward(speed, 0.0, excess * 0.08 * dt)
	_yaw_rate = move_toward(_yaw_rate, wanted, (3.0 if airborne else 7.0) * dt)
	return _yaw_rate * dt


## Опора держит мелкие неровности; с выпуклого гребня велосипед уходит по касательной.
func _step_vertical(g: float, path_weight: float, hop: bool, dt: float, heights: Heightfield) -> void:
	_hop_wait = maxf(0.0, _hop_wait - dt)
	_hop_buf = GameConfig.JUMP_BUFFER if hop else maxf(0.0, _hop_buf - dt)
	_coyote = maxf(0.0, _coyote - dt) if airborne else HOP_COYOTE
	if _hop_buf > 0.0 and _hop_wait <= 0.0 and (not airborne or _coyote > 0.0):
		_hop_buf = 0.0
		_coyote = 0.0
		airborne = true
		air_time = 0.0
		# Наследуем подъём, но крутой излом не превращается в катапульту.
		vy = clampf(vy, 0.0, 3.0) + GameConfig.BIKE_HOP
		squash_v -= 0.9
	if airborne:
		air_time += dt
		y += (vy - GameConfig.GRAVITY * dt * 0.5) * dt
		vy -= GameConfig.GRAVITY * dt
		if y <= g:
			_land(g, heights)
	else:
		var fly := y + (vy - GameConfig.GRAVITY * dt * 0.5) * dt
		# Допуск по ускорению, а не сантиметрам за кадр: одинаковый гребень при разных dt.
		var release := GameConfig.GRAVITY * lerpf(0.35, 1.0, path_weight) * dt * dt
		if fly > g + (release if absf(speed) > 3.0 else 0.18):
			airborne = true
			air_time = dt
			vy -= GameConfig.GRAVITY * dt
			y = fly
		else:
			var gv := (g - y) / maxf(dt, 0.0001)
			squash_v += clampf(gv - vy, -4.0, 6.0) * 0.18
			vy = gv
			y = g


## Пружина с короткими подшагами не раскачивается от длинного такта.
func _step_suspension(dt: float, load := 0.0) -> void:
	var target := -0.035 if airborne else load
	var ticks := maxi(1, ceili(dt * 120.0))
	var h := dt / ticks
	for i in ticks:
		squash_v += (SPRING_K * (target - squash) - SPRING_DAMP * squash_v) * h
		squash += squash_v * h
		if squash > SAG_MAX:
			squash = SAG_MAX
			squash_v = minf(squash_v, 0.0)
		elif squash < -STRETCH_MAX:
			squash = -STRETCH_MAX
			squash_v = maxf(squash_v, 0.0)


## Продольное движение: тяга педалей, склон, качение и сопротивление на скорости.
## speed — скорость по горизонтали, поэтому проекция тяжести — slope / (1 + slope²).
func _step_speed(throttle: float, boost: bool, slope: float, terrain: float, dt: float) -> void:
	var top := GameConfig.BIKE_SPEED * terrain
	var rolling := GameConfig.BIKE_ROLL / maxf(terrain, 0.25)
	var drag := GameConfig.BIKE_DRAG / (terrain * terrain)
	var gravity := -SLOPE_GRAVITY * slope / (1.0 + slope * slope)
	# Пауза заднего хода отсчитывается у остановки, а не во время торможения с разгона.
	if throttle < 0.0 and absf(speed) < 0.05:
		_brake_hold += dt
	elif throttle >= 0.0 or speed > 0.05:
		_brake_hold = 0.0
	var reversing := throttle < 0.0 and (speed < -0.05 or _brake_hold >= 0.4)
	if reversing:
		# Медленный манёвр назад остаётся предсказуемым и на склоне.
		speed = move_toward(speed, -GameConfig.BIKE_REVERSE * absf(throttle), GameConfig.BIKE_ACCEL * dt)
		return
	if speed < 0.0:
		var stop := GameConfig.BIKE_ACCEL if throttle > 0.0 else rolling + drag * speed * speed
		speed = move_toward(speed, 0.0, stop * dt)
		return
	var drive := 0.0
	if throttle > 0.0:
		top *= (GameConfig.BIKE_BOOST if boost else 1.0) * throttle
		var ratio := maxf(speed, 0.0) / maxf(top, 0.1)
		# Уверенный старт и плавное ослабление тяги; скорость спуска не срезается до top.
		var push := GameConfig.BIKE_ACCEL * 1.75
		var taper := maxf(0.1, push / (rolling + drag * top * top) - 1.0)
		drive = push / (1.0 + taper * ratio * ratio) * throttle
	var resistance := rolling + drag * speed * speed
	if throttle < 0.0:
		# Тормоз удерживает остановку даже на спуске; сила нарастает с нажатием стика.
		speed += gravity * dt
		speed = move_toward(speed, 0.0, (GameConfig.BIKE_BRAKE * absf(throttle) + resistance) * dt)
	else:
		speed += (drive + gravity) * dt
		speed = move_toward(speed, 0.0, resistance * dt)
		# Не заставляем новичка балансировать и ловить самопроизвольный откат в подъём.
		speed = maxf(0.0, speed)


## Помещается ли велосипед серединой в (px, pz) с курсом hd: все три круга вдоль рамы свободны
func fits(px: float, pz: float, hd: float, w: WorldData, heights: Heightfield) -> bool:
	var fx := -sin(hd) * AXLE
	var fz := -cos(hd) * AXLE
	return (PlayerState.is_passable(w, heights, px, pz, y, BODY_R)
		and PlayerState.is_passable(w, heights, px + fx, pz + fz, y, BODY_R)
		and PlayerState.is_passable(w, heights, px - fx, pz - fz, y, BODY_R))


## Доля скорости, которая остаётся после касания стены: moved — путь, который всё же прошли, full — весь путь за кадр
func _slide_keep(dt: float, moved: float, full: float) -> float:
	if full <= 0.0:
		return 1.0
	return 1.0 - minf(1.0, dt * WALL_LOSS * (1.0 - moved / full))


## Приземление: подвеска проседает тем сильнее, чем жёстче удар; жёсткий удар гасит скорость,
## а слишком жёсткий (с высоты больше 5 м на ровное) сбрасывает седока
func _land(g: float, heights: Heightfield) -> void:
	var slope := _slope(heights)
	# Удар поперёк поверхности: приземляться вдоль спуска мягче, чем в подъём.
	var impact := maxf(0.0, slope * speed - vy) / sqrt(1.0 + slope * slope)
	airborne = false
	y = g
	land_impact = maxf(land_impact, impact)
	squash_v = clampf(squash_v + impact * 0.4, -2.0, 4.0)
	if impact > GameConfig.BIKE_CRASH:
		crashed = true
		speed = 0.0
	elif impact > SOFT_IMPACT:
		speed *= 1.0 - clampf((impact - SOFT_IMPACT) * 0.05, 0.0, 0.5)
	vy = slope * speed
	_coyote = HOP_COYOTE
	# Короткие подскоки и заранее нажатый прыжок не блокируют управление.
	if air_time > 0.2:
		_hop_wait = 0.0 if _hop_buf > 0.0 else 0.08
	air_time = 0.0
