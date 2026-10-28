class_name BikeRide
extends RefCounted
## Велосипед: где стоит, разгон и торможение, руль, подъёмы, полёт с горбов и прыжок, подвеска колёс.
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
const FACE_CRASH := 5.0   # приземление в подъём (крутизна 1 = 45°) роняет при ударе слабее BIKE_CRASH на столько, м/с
const WALL_CRASH := 9.0   # удар в стену в лоб быстрее этого (м/с) роняет седока; с 7.7 и в ствол, валун, бревно —
                          # по скорости поперёк их поверхности (вскользь не роняет)
## На пути колёса держатся полотна на мелких изломах, руль зависит от сцепления покрытия.
const SLOPE_GRAVITY := GameConfig.GRAVITY # та же тяжесть, что в полёте; склон не превращается в вязкий тормоз
const CLIFF_GRADE := 2.0 # около 63°: на такой стене колёса уже не удерживают седока
const CORNER_GRIP := GameConfig.BIKE_GRIP
const MOUNT_RISE := 1.5  # сесть можно, если велосипед не выше и не ниже ног на столько, м
const HOP_COYOTE := 0.1  # можно успеть прыгнуть сразу после схода с края, с
const HOP_BUFFER := 0.22 # 14.1: пробел ждёт касания столько, с (было 0,12, как пешком): короткий отрыв на гребне
                         # перед бревном длится 0,2–0,3 с и съедал нажатие, сделанное вовремя
## С 7.0 опора — середина между точками касания колёс, отрыв — по форме рельефа впереди.
const HUB := GameConfig.BIKE_WHEELBASE * 0.5 # оси колёс впереди и позади середины, м
const LIFT := 0.2        # отрыв, только если за LOOK секунд рельеф уйдёт из-под полёта глубже этого, м
const LOOK: Array[float] = [0.1, 0.2, 0.3]
const DROP_STEP := 0.12  # земля ушла вниз за один такт больше этого — это край, а не излом: падаем
## С 7.1 подвеска у каждого колеса своя: пружина-демпфер от профиля под этим колесом.
const KICK_MAX := 6.0    # больший скачок (ступенька, телепорт) ограничивается, м/с
const PITCH_LOAD := GameConfig.BIKE_PITCH_LOAD
const BUMP := 0.035      # высота мелких кочек под колесом на бездорожье (rough 1), м
const REVERSE_HOLD := GameConfig.BIKE_REVERSE_WAIT
const WHEEL_REACH := 0.16 # колесо — круг: земля меряется ещё на столько впереди и позади точки касания, м
const PROFILE_SPAN := 1.5 # база, на которой измеряется кривизна профиля (впадина, роллер), м
const BANK_SPAN := 0.7   # поперечная база, на которой измеряется наклон полотна (вираж), м
const BANK_ASSIST := 0.7 # какую долю тяжести виража видит сцепление
const PROFILE_SAG := 0.6 # сжатие подвески на 1 g нагрузки от профиля, доля SAG_MAX
const BOTTOM_OUT := 0.8  # вилка ударилась в упор SAG_MAX быстрее этого (м/с) — стук пробоя

var x := 0.0          # метры
var z := 0.0
var y := 0.0          # высота, где колёса касаются земли (в полёте — над землёй)
var vy := 0.0         # вертикальная скорость, м/с
var airborne := false
var heading := 0.0    # курс, как yaw камеры: 0 — на север (-Z)
var speed := 0.0      # м/с вдоль курса, назад — меньше нуля
var acceleration := 0.0 # фактический продольный разгон за последний такт, для ощущения скорости
var lateral_speed := 0.0 # боковая скорость относительно рамы
const Brakes = preload("res://scripts/game/bike_brakes.gd")
var brakes := Brakes.new()
var brake_pressure: float:
	get: return brakes.pressure
var brake_deceleration: float:
	get: return brakes.deceleration
var front_load: float:
	get: return brakes.front_load
var grip_usage := 0.0 # фактически использованный общий запас, 0..1
var slip := 0.0 # подписанный угол сноса, радианы
var _corner_demand := 0.0
var riding := false
var lean := 0.0       # крен в повороте, радианы
var tilt := 0.0       # наклон вдоль склона или полёта, радианы
var wheel := 0.0      # угол поворота колёс
var crank := 0.0      # угол педалей
var steer := 0.0      # положение руля -1..1
var squash := 0.0     # средний ход подвески, м (меньше нуля — вытянулась при прыжке); для камеры и седока
var squash_f := 0.0   # ход вилки, м
var squash_r := 0.0   # ход заднего колеса, м
var squash_fv := 0.0  # скорость сжатия вилки, м/с
var squash_rv := 0.0
var ground_f := 0.0   # точка касания переднего колеса относительно y, м (в полёте — где колесо висит)
var ground_r := 0.0   # то же для заднего
var _g_f := 0.0       # высота земли под колёсами на прошлом такте и её вертикальная скорость
var _g_r := 0.0
var _gv_f := 0.0
var _gv_r := 0.0
var _fresh := true    # колёса только встали на землю: прошлых высот нет, толчка не считаем
var _dist := 0.0      # пройденный путь, для покачивания
var air_time := 0.0   # сколько секунд в воздухе
var _hop_wait := 0.0  # после приземления прыжок доступен не сразу
var _hop_buf := 0.0   # пробел, нажатый чуть раньше, чем прыжок стал доступен
var _yaw_rate := 0.0   # фактическая угловая скорость поворота, рад/с
var _coyote := 0.0     # запас прыжка после схода с края
var _brake_hold := 0.0 # сколько секунд держат тормоз у остановки
var crashed := false  # седок упал: жёстко приземлился или врезался в стену (GameWorld покажет падение и сбросит флаг)
enum CrashCause { FALL, COLLISION, BRAKING }
var crash_cause := CrashCause.FALL
var crash_normal := Vector3.UP # наружу от препятствия или опоры
var crash_velocity := Vector3() # скорость велосипеда перед падением, м/с (для ragdoll)
var vertical_g := 0.0  # нагрузка профиля земли вдоль пути в g: впадина сжимает (+), гребень разгружает (−)
var bank_slope := 0.0  # наклон полотна поперёк: рост высоты на метр вправо от курса, сглаженный
var land_impact := 0.0 # сила последнего приземления, м/с (для тряски камеры)
var bottom_out := 0.0  # 12.7: скорость удара вилки в упор, м/с (для звука; GameWorld сбрасывает)
var braking := 0.0     # 12.7: резкое торможение на скорости 0..1 (для хруста покрытия)
var fallen := false # рама остаётся в физической позе до ручной посадки
var fallen_transform := Transform3D.IDENTITY


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


## Можно ли сесть: велосипед рядом и на том же уровне (не на мосту над бредущим под ним игроком)
func can_mount(p: PlayerState) -> bool:
	return distance_to(p) <= GameConfig.BIKE_MOUNT and absf(y - p.feet) < MOUNT_RISE


## Поднимаем раму только рядом с игроком, на опору и без прохода сквозь стены.
## Отказ оставляет состояние велосипеда и игрока прежним.
func prepare_mount(p: PlayerState, w: WorldData, heights: Heightfield) -> bool:
	if not can_mount(p) or not p.on_ground:
		return false
	for radius: float in ([0.0, 0.5, 1.0, 1.5] if fallen else [0.0]):
		for i in (1 if radius == 0.0 else 8):
			var px := x + cos(i * TAU / 8.0) * radius
			var pz := z + sin(i * TAU / 8.0) * radius
			if Grid.hypot(px - p.x, pz - p.z) > GameConfig.BIKE_MOUNT:
				continue
			var floor_y := heights.surface_at(px, pz, y + 0.4)
			if absf(floor_y - p.feet) > 0.6 or heights.ceiling_at(px, pz, floor_y) < floor_y + 1.8:
				continue
			var destination := Vector3(px, floor_y, pz)
			if not BikeRecovery.clear_path(w, heights, Vector3(x, y, z), destination, true):
				continue
			if not BikeRecovery.clear_path(w, heights, Vector3(p.x, p.feet, p.z), destination):
				continue
			for direction: float in [heading, heading + PI * 0.5, heading - PI * 0.5]:
				if BikeRecovery.placement(w, heights, destination, direction).is_empty():
					continue
				x = px
				z = pz
				y = floor_y
				heading = direction
				return true
	return false


func mount(p: PlayerState) -> void:
	reset_motion()
	riding = true
	fallen = false
	speed = 0.0
	_yaw_rate = 0.0
	_coyote = 0.0
	_fresh = true
	p.x = x
	p.z = z
	p.vy = 0.0
	p.vx = 0.0
	p.vz = 0.0
	p.on_ground = true
	p.feet = y


## Обнулить движение, подвеску и отложенный ввод, не меняя местоположение.
func reset_motion() -> void:
	acceleration = 0.0
	vertical_g = 0.0
	bank_slope = 0.0
	lateral_speed = 0.0
	brakes.reset()
	grip_usage = 0.0
	slip = 0.0
	_corner_demand = 0.0
	braking = 0.0
	riding = false
	speed = 0.0
	lean = 0.0
	steer = 0.0
	squash = 0.0
	squash_f = 0.0
	squash_r = 0.0
	squash_fv = 0.0
	squash_rv = 0.0
	ground_f = 0.0
	ground_r = 0.0
	_fresh = true
	_hop_buf = 0.0
	_brake_hold = 0.0
	_yaw_rate = 0.0
	_coyote = 0.0
	vy = 0.0
	air_time = 0.0
	_hop_wait = 0.0
	airborne = false
	crashed = false
	land_impact = 0.0
	bottom_out = 0.0


## Слезть: велосипед остаётся на месте, игрок встаёт слева от него. В полёте слезть нельзя.
func dismount(p: PlayerState, w: WorldData, heights: Heightfield) -> void:
	reset_motion()
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
			var floor_y := heights.surface_at(q.x, q.y, y)
			if BikeRecovery.clear_path(w, heights, Vector3(x, y, z), Vector3(q.x, floor_y, q.y)) \
					and BikeRecovery.headroom(heights, q.x, q.y, floor_y):
				return q
	return Vector2(x, z)


## 14.0: подъём земли на метр пути вдоль курса (для выносливости): больше нуля — в гору по курсу
func grade(heights: Heightfield) -> float:
	return _slope(heights)


## Подъём земли на метр пути вдоль курса: от заднего колеса к переднему
func _slope(heights: Heightfield) -> float:
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	return (heights.surface_at(x + fx, z + fz, y) - heights.surface_at(x - fx, z - fz, y)) / (2.0 * HUB)


## Высота опоры в (px, pz): середина между точками касания колёс. Велосипед перекрывает
## мелкие изломы базой, а не повторяет каждый под одной точкой.
func _contact(px: float, pz: float, heights: Heightfield) -> float:
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	return (_wheel_ground(px + fx, pz + fz, heights) + _wheel_ground(px - fx, pz - fz, heights)) * 0.5


## Высота земли под ступицей колеса как круга: ребро ступеньки или резкий гребень поднимают колесо
## плавно по дуге, а не проваливают в излом метровой сетки. На гладком рельефе равна высоте точки.
func _wheel_ground(px: float, pz: float, heights: Heightfield) -> float:
	var best := heights.surface_at(px, pz, y)
	var dx := -sin(heading) * WHEEL_REACH
	var dz := -cos(heading) * WHEEL_REACH
	var arc := sqrt(WHEEL_R * WHEEL_R - WHEEL_REACH * WHEEL_REACH) - WHEEL_R
	best = maxf(best, heights.surface_at(px + dx, pz + dz, y) + arc)
	return maxf(best, heights.surface_at(px - dx, pz - dz, y) + arc)


## Нагрузка от кривизны профиля вдоль курса и поперечный наклон полотна; оба сглажены от шума сетки.
func _read_surface(heights: Heightfield, dt: float) -> void:
	if airborne:
		vertical_g = lerpf(vertical_g, 0.0, 1.0 - exp(-dt * 8.0))
		return
	var ahead := Vector2(-sin(heading), -cos(heading)) * PROFILE_SPAN
	var g0 := heights.surface_at(x, z, y)
	var curve := (heights.surface_at(x + ahead.x, z + ahead.y, y) + heights.surface_at(x - ahead.x, z - ahead.y, y) - 2.0 * g0) / (PROFILE_SPAN * PROFILE_SPAN)
	var goal := clampf(speed * speed * curve / GameConfig.GRAVITY, -1.0, 1.5)
	vertical_g = lerpf(vertical_g, goal, 1.0 - exp(-dt * 12.0))
	var right := Vector2(cos(heading), -sin(heading)) * BANK_SPAN
	var cross := (heights.surface_at(x + right.x, z + right.y, y) - heights.surface_at(x - right.x, z - right.y, y)) / (2.0 * BANK_SPAN)
	bank_slope = lerpf(bank_slope, clampf(cross, -0.8, 0.8), 1.0 - exp(-dt * 15.0))


## Уходит ли рельеф впереди из-под полёта: летим с нынешней вертикальной скоростью
## и смотрим, насколько ниже окажется земля через 0,1–0,3 с.
func _lifts(heights: Heightfield) -> bool:
	var velocity := horizontal_velocity()
	var fx := velocity.x
	var fz := velocity.y
	for t: float in LOOK:
		var fly := y + vy * t - GameConfig.GRAVITY * t * t * 0.5
		if fly - _contact(x + fx * t, z + fz * t, heights) > LIFT:
			return true
	return false


## Шаг езды за dt секунд (в игре — один такт физики, 1/60 с). throttle — газ (+) и тормоз (-),
## turn — руль вправо (+) и влево (-), hop — пробел нажат в этом такте (срабатывает, как только прыжок
## доступен, если ждать недолго).
func step(p: PlayerState, throttle: float, turn: float, boost: bool, hop: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	# Один и тот же короткий шаг при 30/60/120 Гц; hop передаётся только первому подшагу.
	# Существующие рельеф, вода и подвеска остаются в том же цикле, без новой вертикальной модели.
	if dt > 1.0 / 120.0 + 0.000001:
		var ticks := ceili(dt * 120.0)
		for i in ticks:
			step(p, throttle, turn, boost, hop and i == 0, dt / ticks, w, heights)
			if crashed:
				break
		return
	if dt <= 0.0:
		return
	_corner_demand = absf(turn) * smoothstep(3.0, 10.0, absf(speed))
	var slope := _slope(heights)
	var contact := RideSurface.sample(w, heights, x, z)
	var surf: int = contact.surface
	var path_weight: float = contact.weight
	var across: float = contact.across
	var on_path := surf != RoadSurface.NONE
	var terrain := maxf(0.15, PlayerState.terrain_speed(w, x, z, heights))
	var rough := clampf(1.3 - terrain, 0.15, 1.0)
	var grip := 0.85
	if on_path:
		grip = lerpf(grip, RoadSurface.LIST[surf].grip, path_weight)
		rough = lerpf(rough, RoadSurface.LIST[surf].rough, path_weight)
	# На корнях и камнях медленный проезд точный; быстрый требует более широкой дуги.
	var technical := smoothstep(0.25, 0.8, rough) * smoothstep(6.0, 15.0, absf(speed))
	grip *= 1.0 - technical * 0.2
	var speed0 := speed
	if not airborne:
		terrain *= lerpf(1.0, 0.4, smoothstep(0.05, 0.8, heights.immersion_at(x, z, y)))
		_step_speed(throttle, boost, slope, terrain, dt, grip, technical)
		if brakes.tipped:
			_crash(vy, Vector3.UP, CrashCause.BRAKING)
			return
	else:
		# В воздухе педали и тормоз не меняют скорость и не готовят задний ход.
		_brake_hold = 0.0
		brakes.step(dt, 0.0, speed, slope, grip, 0.0, false)
		braking = 0.0
		speed *= exp(-0.03 * dt)
		lateral_speed *= exp(-0.03 * dt)

	_read_surface(heights, dt)
	var free_now := fits(x, z, heading, w, heights)
	var h0 := heading
	heading += _step_turn(turn, grip, dt, brake_deceleration / maxf(CORNER_GRIP * grip, 0.1))
	# Вплотную к стене колесо не поворачивается в неё, накопленного рывка тоже нет.
	if free_now and not fits(x, z, heading, w, heights):
		heading = h0
		_yaw_rate = 0.0
	var lateral := _step_traction(h0, grip, dt)

	var x0 := x
	var z0 := z
	var velocity := horizontal_velocity()
	var dx := velocity.x * dt
	var dz := velocity.y * dt
	var wanted := Vector3(dx, 0, dz)
	var full := velocity.length() * dt
	if full > 0.0:
		# если велосипед уже задевает препятствие (поставлен вплотную), выехать можно: проверяется середина
		var hd := heading
		var free := func(px: float, pz: float) -> bool:
			if free_now:
				return fits(px, pz, hd, w, heights)
			if PlayerState.is_passable(w, heights, px, pz, y):
				return true
			# 11.7: после прыжка середина внутри валуна или бревна: наружу выехать можно, иначе застрял бы
			# (прыжок ниже верха валуна), а вглубь и в сторону — нет
			if heights.obstacles == null or not w.accessible(px / GameConfig.TILE, pz / GameConfig.TILE) or not heights.known(px, pz) \
					or heights.depth_at(px, pz, y) >= GameConfig.FORD_DEPTH:
				return false
			return heights.obstacles.normal(x, z, y, 0.0).dot(Vector2(px - x, pz - z)) > 0.0
		# 7.7: вдоль ствола и бревна велосипед скользит по касательной
		var around := Callable()
		if heights.obstacles != null:
			around = func(px: float, pz: float) -> Vector2: return _obstacle_normal(px, pz, hd, heights)
		var to := PlayerState.slide(free, x, z, dx, dz, around)
		x = to[0]
		z = to[1]
		var moved := Grid.hypot(x - x0, z - z0)
		if moved < full - 1e-5:
			# в лоб скорость гаснет, при скольжении вдоль стены почти нет
			var blocked := Vector3(x - x0, 0.0, z - z0) - wanted
			var normal := blocked.normalized()
			var impact := maxf(0.0, -Vector3(velocity.x, 0, velocity.y).dot(normal))
			# 11.6: щуп на весь несделанный кусок пути: тонкое бревно, на котором встали за 0,1–0,2 м, тоже удар
			# 11.7: не дальше куска шага: то, что остановило, лежит в его пределах, а не за ним
			var ahead := wanted.normalized() * maxf(PlayerState.PIECE * 0.5, minf(full - moved, PlayerState.PIECE) + 0.01)
			var solid := false
			for axle: float in [-AXLE, 0.0, AXLE]:
				if not PlayerState.is_passable(w, heights, x + ahead.x - sin(heading) * axle, z + ahead.z - cos(heading) * axle, y, BODY_R, true):
					solid = true
					break
			# Удар о предмет опасен и в прыжке; вода и граница открытой земли не являются стеной.
			if solid and impact > WALL_CRASH:
				_crash(vy, normal, CrashCause.COLLISION)
			var keep := 0.0 if moved < 1e-5 else _slide_keep(dt, moved, full)
			speed *= keep
			lateral_speed *= keep
	_dist += Grid.hypot(x - x0, z - z0)

	_step_vertical(_contact(x, z, heights), hop, dt, heights)
	# Непрерывный крутой склон раньше подменял падение покадровой привязкой к земле.
	# Даже медленный съезд по почти отвесной стене теперь теряет равновесие и запускает ragdoll.
	if not airborne and absf(speed) > 0.25 and slope * signf(speed) < -CLIFF_GRADE:
		_crash(vy, Vector3(sin(heading) * slope, 1.0, cos(heading) * slope).normalized())
	_step_wheels(heights, rough, dt, surf, path_weight, slope, across)
	acceleration = clampf((speed - speed0) / maxf(dt, 0.0001), -9.0, 12.0)
	_step_suspension(dt, minf(absf(lateral) * 0.001, 0.015) + clampf(vertical_g, -1.0, 1.5) * SAG_MAX * PROFILE_SAG, acceleration)

	# Рама лежит на концах подвесок: колёса на точках касания, рама — выше на свой ход у каждого.
	# Разгон и торможение наклоняют её через подвеску (PITCH_LOAD), отдельного покачивания нет.
	var tilt_goal := atan2((ground_f - squash_f) - (ground_r - squash_r), 2.0 * HUB)
	if airborne:
		tilt_goal = clampf(atan2(vy, maxf(absf(speed), 4.0)), -0.55, 0.55)
		if speed < 0.0:
			tilt_goal = -tilt_goal
	tilt = lerpf(tilt, tilt_goal, 1.0 - exp(-dt * (5.0 if airborne else 25.0)))
	# Крен от реального поворота, а не от кнопки: на месте не заваливаемся.
	# Умеренный визуальный крен (до 16°), без изменения радиуса поворота и сцепления.
	var lean_goal := 0.0 if airborne else clampf(atan(lateral / GameConfig.GRAVITY) * 0.5, -0.28, 0.28)
	lean = lerpf(lean, lean_goal, 1.0 - exp(-dt * (2.5 if airborne else 9.0)))

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


## Полная горизонтальная скорость для движения, полёта и передачи импульса падению.
func horizontal_velocity() -> Vector2:
	var forward := Vector2(-sin(heading), -cos(heading))
	return forward * speed + Vector2(-forward.y, forward.x) * lateral_speed


## Рама доворачивается раньше траектории. В воздухе только меняем систему координат.
func _step_traction(old_heading: float, grip: float, dt: float) -> float:
	var old_forward := Vector2(-sin(old_heading), -cos(old_heading))
	var velocity := old_forward * speed + Vector2(-old_forward.y, old_forward.x) * lateral_speed
	var forward := Vector2(-sin(heading), -cos(heading))
	var side := Vector2(-forward.y, forward.x)
	speed = velocity.dot(forward)
	lateral_speed = velocity.dot(side)
	var lateral := 0.0
	if not airborne:
		var capacity := CORNER_GRIP * grip
		var available := sqrt(maxf(0.0, capacity * capacity - brake_deceleration * brake_deceleration))
		var correction := lateral_speed * (1.0 - exp(-GameConfig.BIKE_SIDE_RESPONSE * dt))
		correction = clampf(correction, -available * dt, available * dt)
		lateral_speed -= correction
		lateral = correction / dt
		grip_usage = clampf(Vector2(brake_deceleration, lateral).length() / maxf(capacity, 0.1), 0.0, 1.0)
	else:
		grip_usage = 0.0
	slip = atan2(lateral_speed, maxf(absf(speed), 2.0))
	return lateral


## Руль отзывчив на малой скорости; на большой сцепление расширяет дугу и чуть съедает ход.
## Боковая инерция и торможение делят общий запас сцепления.
func _step_turn(turn: float, grip: float, dt: float, brake := 0.0) -> float:
	steer = move_toward(steer, turn, dt * (7.0 if is_zero_approx(turn) else 5.0))
	var pace := absf(speed)
	# На малой скорости манёвр лёгкий; на большой у перекладки появляется вес.
	var response := lerpf(10.0, 4.5, smoothstep(3.0, 16.0, pace)) * grip
	var rate := GameConfig.BIKE_TURN * clampf(pace / 3.0, 0.0, 1.0) / (1.0 + pace * 0.04)
	var wanted := -steer * rate * (1.0 if speed >= 0.0 else -1.0)
	var limit := rate
	if airborne:
		wanted *= 0.25
		limit *= 0.25
		response = 3.0
	else:
		# Торможение расходует часть сцепления: дуга шире, но управление сохраняется.
		var corner_grip := CORNER_GRIP * grip * sqrt(maxf(0.0, 1.0 - brake * brake))
		# Накопленный снос расширяет дугу до восстановления, вместо бесконечного дрифта.
		var slip_yaw := lerpf(GameConfig.BIKE_SLIP_YAW, 0.92, smoothstep(0.04, GameConfig.BIKE_SLIP_RECOVER, absf(slip)))
		corner_grip *= lerpf(1.0, slip_yaw, smoothstep(5.0, 12.0, pace))
		# Вираж: полотно, поднятое снаружи поворота, прижимает колёса и добавляет сцепления; уклон внутрь отнимает.
		var assist := clampf(-bank_slope * signf(steer), -0.3, 0.5) * GameConfig.GRAVITY * BANK_ASSIST * smoothstep(2.0, 6.0, pace)
		corner_grip = maxf(corner_grip + assist * grip, corner_grip * 0.6)
		limit = minf(rate, corner_grip / maxf(pace, 3.0))
		var excess := maxf(0.0, absf(wanted) * pace - corner_grip)
		wanted = clampf(wanted, -limit, limit)
		speed = move_toward(speed, 0.0, excess * 0.08 * dt)
	_yaw_rate = move_toward(_yaw_rate, wanted, response * dt)
	# Остаточная инерция не вращает стоящий велосипед и не превышает сцепление.
	_yaw_rate = clampf(_yaw_rate, -limit, limit)
	return _yaw_rate * dt


## Опора держит мелкие неровности и изломы; отрыв — только с края или когда рельеф впереди
## уходит вниз быстрее, чем позволяет тяжесть на этой скорости (гребень, трамплин).
func _step_vertical(g: float, hop: bool, dt: float, heights: Heightfield) -> void:
	_hop_wait = maxf(0.0, _hop_wait - dt)
	_hop_buf = HOP_BUFFER if hop else maxf(0.0, _hop_buf - dt)
	_coyote = maxf(0.0, _coyote - dt) if airborne else HOP_COYOTE
	if _hop_buf > 0.0 and _hop_wait <= 0.0 and (not airborne or _coyote > 0.0):
		_hop_buf = 0.0
		_coyote = 0.0
		airborne = true
		air_time = 0.0
		# Наследуем подъём, но крутой излом не превращается в катапульту.
		vy = clampf(vy, 0.0, 3.0) + GameConfig.BIKE_HOP
		squash_fv -= 0.9
		squash_rv -= 0.9
	if airborne:
		air_time += dt
		y += (vy - GameConfig.GRAVITY * dt * 0.5) * dt
		vy -= GameConfig.GRAVITY * dt
		if y <= g:
			_land(g, heights)
	else:
		var fly := y + (vy - GameConfig.GRAVITY * dt * 0.5) * dt
		# Земля уходит вниз быстрее падения: отрываемся с края сразу, с излома — только если
		# впереди рельеф действительно уходит из-под колёс; иначе прижимаемся к земле.
		if fly > g and (fly - g > DROP_STEP or _lifts(heights)):
			airborne = true
			air_time = dt
			vy -= GameConfig.GRAVITY * dt
			y = fly
		else:
			var gv := (g - y) / maxf(dt, 0.0001)
			# ступенька (въезд на настил, шов полотна) — не склон: её подъём не становится скоростью взлёта
			# При 120 Гц шов даёт вдвое больший скачок (g-y)/dt, чем при 60 Гц.
			# Ограничиваем подъём уклоном на базе колёс, сохраняя импульс настоящего склона.
			var gradient := Vector2(
				(heights.surface_at(x + HUB, z, g) - heights.surface_at(x - HUB, z, g)) / (2.0 * HUB),
				(heights.surface_at(x, z + HUB, g) - heights.surface_at(x, z - HUB, g)) / (2.0 * HUB))
			gv = minf(gv, maxf(0.0, gradient.dot(horizontal_velocity())))
			vy = gv
			y = g


## Колёса на точках касания. Подвеска колеса получает толчок, когда вертикальная скорость земли
## под ним меняется (излом, ступенька, кочка): переднее колесо встречает излом раньше заднего.
## 11.5: на полотне кочки — поле RoadBump в точке касания (то же, что видно в шейдере), вне пути — прежние.
## 11.6: поверх — кочки веток и камней на полотне (ForestObstacles.bump_at).
## 12.3: across — поперечная координата полотна у середины велосипеда (колеи RoadBump); колёса идут
## вдоль курса, поперёк они почти не расходятся.
func _step_wheels(heights: Heightfield, rough: float, dt: float, surf := RoadSurface.NONE, path_weight := 0.0, grade := 0.0, across := 0.0) -> void:
	if airborne:
		# в полёте колёса висят на подвеске под рамой
		ground_f = sin(tilt) * HUB
		ground_r = -ground_f
		_fresh = true
		return
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	var gf := _wheel_ground(x + fx, z + fz, heights)
	var gr := _wheel_ground(x - fx, z - fz, heights)
	# мелкие кочки (только вверх, колесо не тонет в земле): заднее колесо проходит ту же кочку на базу позже
	var wild := BUMP * rough * (1.0 - path_weight)
	gf += wild * _bump(_dist + HUB) + RoadBump.height(x + fx, z + fz, surf, grade, across) * path_weight
	gr += wild * _bump(_dist - HUB) + RoadBump.height(x - fx, z - fz, surf, grade, across) * path_weight
	# 11.6: ветки и камни на полотне (RoadObstacles) — та же кочка, только с места препятствия
	if heights.obstacles != null:
		gf += heights.obstacles.bump_at(x + fx, z + fz)
		gr += heights.obstacles.bump_at(x - fx, z - fz)
	ground_f = gf - y
	ground_r = gr - y
	if _fresh:
		_fresh = false
		_g_f = gf
		_g_r = gr
		_gv_f = vy
		_gv_r = vy
		return
	var vf := (gf - _g_f) / maxf(dt, 0.0001)
	var vr := (gr - _g_r) / maxf(dt, 0.0001)
	# колесо поднимается вместе с землёй сразу, рама — через пружину: разница и есть сжатие
	squash_fv += clampf(vf - _gv_f, -KICK_MAX, KICK_MAX)
	squash_rv += clampf(vr - _gv_r, -KICK_MAX, KICK_MAX)
	_g_f = gf
	_g_r = gr
	_gv_f = vf
	_gv_r = vr


## Кочка под колесом на отметке пути d, 0..1
static func _bump(d: float) -> float:
	var n := sin(d * 2.3) * 0.6 + sin(d * 5.9 + 1.3) * 0.4
	return maxf(0.0, n) ** 2


## Две пружины-демпфера, вилка и задний ход. Короткие подшаги не дают раскачки от длинного такта.
## load — сжатие от поворота, acceleration — разгон (+) и торможение (-), м/с².
func _step_suspension(dt: float, load := 0.0, acceleration := 0.0) -> void:
	var target := -0.035 if airborne else load
	var shift := 0.0 if airborne else acceleration * PITCH_LOAD
	var ticks := maxi(1, ceili(dt * 120.0))
	var h := dt / ticks
	var f := Vector2(squash_f, squash_fv)
	var r := Vector2(squash_r, squash_rv)
	for i in ticks:
		var hit := f.y
		f = _spring(f, target - shift, h)
		if f.x >= SAG_MAX and hit > BOTTOM_OUT:
			bottom_out = maxf(bottom_out, hit)
		r = _spring(r, target + shift, h)
	squash_f = f.x
	squash_fv = f.y
	squash_r = r.x
	squash_rv = r.y
	squash = (squash_f + squash_r) * 0.5


## Подшаг одной пружины: s — ход и скорость сжатия; упоры на SAG_MAX и STRETCH_MAX
static func _spring(s: Vector2, target: float, h: float) -> Vector2:
	s.y += (SPRING_K * (target - s.x) - SPRING_DAMP * s.y) * h
	s.x += s.y * h
	if s.x > SAG_MAX:
		s = Vector2(SAG_MAX, minf(s.y, 0.0))
	elif s.x < -STRETCH_MAX:
		s = Vector2(-STRETCH_MAX, maxf(s.y, 0.0))
	return s


## Продольное движение: тяга педалей, склон, качение и сопротивление на скорости.
## speed — скорость по горизонтали, поэтому проекция тяжести — slope / (1 + slope²).
func _step_speed(throttle: float, boost: bool, slope: float, terrain: float, dt: float, grip := 1.0, technical := 0.0) -> void:
	if dt > 1.0 / 120.0 + 0.000001:
		var ticks := ceili(dt * 120.0)
		for i in ticks:
			_step_speed(throttle, boost, slope, terrain, dt / ticks, grip, technical)
		return
	var top := GameConfig.BIKE_SPEED * terrain
	var rolling := GameConfig.BIKE_ROLL / maxf(terrain, 0.25)
	# Воздух не становится плотнее над камнями или травой; покрытие влияет на качение.
	var drag := GameConfig.BIKE_DRAG
	var gravity := -SLOPE_GRAVITY * slope / (1.0 + slope * slope)
	brakes.step(dt, maxf(0.0, -throttle), speed, slope, grip, _corner_demand)
	braking = 0.0
	# Пауза заднего хода отсчитывается у остановки, а не во время торможения с разгона.
	if throttle <= -GameConfig.BIKE_REVERSE_INPUT and absf(speed) < 0.05:
		_brake_hold += dt
	elif throttle > -GameConfig.BIKE_REVERSE_INPUT or speed > 0.05:
		_brake_hold = 0.0
	var reversing := throttle < 0.0 and (speed < -0.05 or _brake_hold >= REVERSE_HOLD)
	if reversing:
		# Медленный манёвр назад остаётся предсказуемым и на склоне.
		speed = move_toward(speed, -GameConfig.BIKE_REVERSE * absf(throttle), GameConfig.BIKE_ACCEL * dt)
		brakes.deceleration = 0.0
		return
	# Автобаланс и статический тормоз: не сползаем, пока игрок обдумывает задний ход.
	if throttle < 0.0 and absf(speed) < 0.05:
		speed = 0.0
		brakes.deceleration = 0.0
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
		# Shift помогает дожать крутой подъём на малой скорости, без переключения передач.
		if boost:
			drive += 1.5 * smoothstep(0.08, 0.35, slope) * (1.0 - smoothstep(3.0, 9.0, speed)) * throttle * grip
	# Кочки съедают ход только при быстром проезде. На длинном спуске воздух мягко
	# сдерживает разгон выше 18 м/с, не обрезая накопленную скорость на пороге.
	var resistance := rolling + drag * speed * speed + technical * 0.8 + 0.04 * pow(maxf(speed - 18.0, 0.0), 2.0)
	if brake_pressure > 0.001:
		var force := brakes.deceleration
		var before_brake := maxf(0.0, speed + (drive + gravity) * dt)
		speed = move_toward(before_brake, 0.0, (force + resistance) * dt)
		brakes.deceleration = minf(force, maxf(0.0, before_brake / dt - resistance))
		braking = clampf(brake_deceleration / GameConfig.BIKE_BRAKE, 0.0, 1.0) * smoothstep(0.3, 3.0, before_brake)
	else:
		speed += (drive + gravity) * dt
		speed = move_toward(speed, 0.0, resistance * dt)
		# Не заставляем новичка балансировать и ловить самопроизвольный откат в подъём.
		speed = maxf(0.0, speed)


## Седок падает: запомнить, с какой скоростью летел велосипед
func _crash(v_up: float, normal := Vector3.UP, cause := CrashCause.FALL) -> void:
	crashed = true
	crash_cause = cause
	crash_normal = normal.normalized() if normal.length_squared() > 0.000001 else Vector3.UP
	var velocity := horizontal_velocity()
	crash_velocity = Vector3(velocity.x, v_up, velocity.y)


## Нормаль препятствия леса (ствол, валун, бревно), которое задевает один из трёх кругов велосипеда
## с серединой в (px, pz) и курсом hd; ноль, если не задевает
func _obstacle_normal(px: float, pz: float, hd: float, heights: Heightfield) -> Vector2:
	for side: float in [1.0, 0.0, -1.0]:
		var n := heights.obstacles.normal(px - sin(hd) * AXLE * side, pz - cos(hd) * AXLE * side, y, BODY_R)
		if n != Vector2.ZERO:
			return n
	return Vector2.ZERO


## Скорость удара в препятствие леса поперёк его поверхности, м/с: в лоб — вся скорость, вскользь — малая доля
func _tree_impact(heights: Heightfield) -> float:
	if heights.obstacles == null:
		return 0.0
	var v := horizontal_velocity()
	var ahead := v.normalized() * PlayerState.PIECE * 0.5
	return -v.dot(_obstacle_normal(x + ahead.x, z + ahead.y, heading, heights))


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
	# Центральная разность в мировых X/Z: боком к склону важна траектория, а не курс рамы.
	var gradient := Vector2(
		(heights.surface_at(x + HUB, z, g) - heights.surface_at(x - HUB, z, g)) / (2.0 * HUB),
		(heights.surface_at(x, z + HUB, g) - heights.surface_at(x, z - HUB, g)) / (2.0 * HUB))
	var normal := Vector3(-gradient.x, 1.0, -gradient.y).normalized()
	var horizontal := horizontal_velocity()
	var incoming := Vector3(horizontal.x, vy, horizontal.y)
	var impact := maxf(0.0, -incoming.dot(normal))
	var approach_grade := gradient.dot(horizontal.normalized()) if horizontal.length_squared() > 0.0001 else 0.0
	airborne = false
	y = g
	land_impact = maxf(land_impact, impact)
	squash_fv = clampf(squash_fv + impact * 0.4, -2.0, 4.0)
	squash_rv = clampf(squash_rv + impact * 0.4, -2.0, 4.0)
	# В подъём (нос в склон) удар опаснее, чем на ровное: порог падения ниже.
	if impact > GameConfig.BIKE_CRASH - FACE_CRASH * clampf(approach_grade, 0.0, 1.0):
		_crash(vy, normal)
		speed = 0.0
		lateral_speed = 0.0
	elif impact > SOFT_IMPACT:
		var keep := 1.0 - clampf((impact - SOFT_IMPACT) * 0.05, 0.0, 0.5)
		speed *= keep
		lateral_speed *= keep
	vy = gradient.dot(horizontal_velocity())
	_coyote = HOP_COYOTE
	# Короткие подскоки и заранее нажатый прыжок не блокируют управление.
	if air_time > 0.2:
		_hop_wait = 0.0 if _hop_buf > 0.0 else 0.08
	air_time = 0.0
