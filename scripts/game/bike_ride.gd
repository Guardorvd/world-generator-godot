class_name BikeRide
extends RefCounted
## Велосипед: где стоит, разгон и торможение, руль, подъёмы, полёт с горбов и прыжок, подвеска колёс.
## Без узлов сцены, как PlayerState. Пока игрок едет, велосипед везёт его: положение игрока
## берётся отсюда. Проходимость та же, что у пешехода (PlayerState.is_passable): глубокая вода,
## дома, перила мостов и стены туннелей не пускают; по настилу моста велосипед едет, как по земле.
## С 2.2 велосипед для столкновений — три круга вдоль рамы (колёса и середина), а не точка:
## переднее колесо не въезжает в дом и не высовывается за перила.

const WHEEL_R := 0.34   # радиус колеса, м
const BODY_R := 0.3     # радиус кругов, которыми велосипед задевает препятствия, м (руль шириной 0,6 м)
const AXLE := 0.57      # круги колёс — на столько впереди и позади середины, м: вместе с BODY_R до края колеса
const HUB := GameConfig.BIKE_WHEELBASE * 0.5 # оси колёс впереди и позади середины, м
const WHEEL_REACH := 0.16 # колесо — круг: земля меряется ещё на столько впереди и позади точки касания, м
const SUB_HZ := 120.0   # частота подшагов движения и подвески, Гц
const MOUNT_RISE := 1.5 # сесть можно, если велосипед не выше и не ниже ног на столько, м
const BODY_LEAD := 0.1  # с от нажатия до пика рывка (для сценариев замеров)
const STOP_FOOT_FORWARD := 0.06 # вынос опорной стопы перед серединой рамы, м

var config: BikePhysicsConfig = BikePhysicsConfig.current()

var pump_pressed := false  # удержание ЛКМ; без него нет сил пампа, поглощение гребня — только pump_passive
var pump_enabled := true    # общий механизм и в мире, и в Lab; выключатель для сравнительных прогонов
var effort := 0.0           # усилие седока на педалях 0..1: от него тяга и поза (BikeView)
var effort_ramp := true     # false — прежняя мгновенная тяга, для сравнительных прогонов
var surge := -1.0           # 15.0: сила рывка 0..1 от Stamina (BikeController); меньше нуля — прежний boost (Lab, тесты)
var gear := 1.4             # виртуальная передача: оборотов колеса на оборот педалей (только каденс и вид, не тяга)


func _init(cfg: BikePhysicsConfig = null) -> void:
	if cfg != null:
		config = cfg
	gear = config.gear_min
	brakes.config = config


func set_config(cfg: BikePhysicsConfig) -> void:
	config = cfg
	brakes.config = cfg
var pump_motion := 0.0       # -1..1: вытянуться / согнуться; поза, не ручное body_x
var pump_load := 0.0         # добавка нагрузки, доля веса
var pump_accel := 0.0        # помощь ходу на обратной стороне волны, м/с² (с ручным пампом — и торможение при ошибке)
var pump_wave := 0.0         # местный уклон волны под велосипедом по ходу (больше нуля — подъём на гребень)
var pump_active := 0.0       # 0..1: велосипед на волне, где работает памп (0 — ровно, ровный склон, отрыв)
var pump_body := 0.0         # доля веса, которую тело сейчас добавляет к опоре (+, E) или снимает с неё (−, Q)
var _pump_reach := 0.0
var _pump_absorb_v := 0.0   # вертикальная скорость, которую седок сейчас гасит на гребне, м/с
var _pump_wait := 0.0

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
var _side_use := 0.0   # доля бокового запаса шин, занятая на прошлом подшаге (модель двух контактов)
var body_back := false    # вход: тело назад (руль на себя)
var body_forward := false # вход: тело вперёд (на руль)
var body_x := 0.0         # положение тела: + назад, − вперёд
var body_v := 0.0
var unweight := 0.0       # доля веса, снятая с переднего колеса на заднее сейчас (меньше нуля — с заднего на переднее)
var lift_f := 0.0         # переднее колесо над опорой, м (0 — на земле)
var lift_fv := 0.0
var lift_r := 0.0
var lift_rv := 0.0
var hop_height := 0.0     # высота последнего банни-хопа от точки отрыва, м (для замеров и метрик)
var _hop_from := 0.0
var _auto_hop := -1.0     # с от начала автоматического Q→E (пробел), -1 — нет
var _hop_link := 0.0
var _hop_front := 0.0
var _hop_front_v := 0.0
var _hop_used := false
var load_f := 0.5     # нагрузка переднего колеса, доли веса велосипеда с седоком (на ровном стоя — 0,5)
var load_r := 0.5
var tire_f := 0.5     # нагрузка, которую «чувствует» шина (сглажена по пути, TIRE_RELAX): от неё запас сцепления
var tire_r := 0.5
var side_f := 0.5     # нагрузка для бокового запаса (tire_* с инерцией SIDE_RELAX)
var side_r := 0.5
var slick_f := 1.0    # доля сцепления колеса на скользком (корень, камень), 1 — земля
var slick_r := 1.0
var force_f := Vector2() # фактически приложенная сила колеса на массу велосипеда, м/с²: x — тормоз (у заднего минус тяга), y — поперёк
var force_r := Vector2()
var use_f := 0.0      # использованный запас сцепления колеса (тормоз и поворот), 0..1; 1 — колесо скользит
var use_r := 0.0
var _share := 0.5     # доля нагрузки на переднем колесе после переноса (PITCH_TRANSFER)
var _landing_grip := 0.0 # сколько ещё запас шин идёт вслед за нагрузкой после касания (LANDING_GRIP), с
var _rest_f := 0.0    # цель пружин на прошлом такте: отклонение от неё — сила подвески сверх равновесия
var _rest_r := 0.0
var _on_f := -1          # препятствие, на котором стоит колесо (ForestObstacles.wheel_contact id; -1 — на земле)
var _on_r := -1
var impacts := Vector2i() # сколько раз колесо встретило кромку препятствия (перед, зад), для замеров
var hit_dv := Vector2()   # потеря скорости рамы при последней встрече переднего и заднего колеса с кромкой, м/с
var landing_info := {} # snapshot before landing resets velocities and flight time
var crash_info := {} # snapshot at the first crash substep
var last_hit := {}        # подробности последней встречи с кромкой (угол, подход, доля нагрузки, доля порога), для стендов
var _sup_f := 0.0        # опора колеса на прошлом такте: от этой высоты колесо встречает следующую кромку
var _sup_r := 0.0
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
var _o_f := 0.0       # высота корня или камня под колёсами на прошлом такте
var _o_r := 0.0
var _fresh := true    # колёса только встали на землю: прошлых высот нет, толчка не считаем
var _dist := 0.0      # пройденный путь, для покачивания
var air_clearance := 0.0 # vertical separation from the support used by _step_vertical
var clearance_closing_speed := 0.0 # positive when that separation shrinks, m/s
var air_time := 0.0   # сколько секунд в воздухе
var _hop_wait := 0.0  # после приземления прыжок доступен не сразу
var _hop_buf := 0.0   # пробел, нажатый чуть раньше, чем прыжок стал доступен
var _yaw_rate := 0.0   # фактическая угловая скорость поворота, рад/с
var _coyote := 0.0     # запас прыжка после схода с края
var _brake_hold := 0.0 # сколько секунд держат тормоз у остановки
var _reverse_armed := true # тормоз отпускали после движения вперёд: удержание у остановки включит задний ход
var crashed := false  # седок упал: жёстко приземлился или врезался в стену (GameWorld покажет падение и сбросит флаг)
enum CrashCause { FALL, COLLISION, BRAKING, OBSTACLE }
var crash_cause := CrashCause.FALL
var crash_normal := Vector3.UP # наружу от препятствия или опоры
var crash_velocity := Vector3() # скорость велосипеда перед падением, м/с (для ragdoll)
enum Stance { RIDING, TRACKSTAND, FOOT_DOWN }
var stance := Stance.RIDING
var foot_side := -1.0    # сторона опорной ноги на стоянке: -1 левая, +1 правая
var foot_support := Vector3.ZERO # измеренная точка опоры в мировых координатах
var _stop_timer := 0.0
var _manual_reverse := false
var _stance_driven := false
var pitch_vel := 0.0     # угловая скорость тангажа рамы в полёте, рад/с
var instability := 0.0   # потеря равновесия от сноса, удара, стоппи или косогора, 0..1
var _offcamber_time := 0.0 # время непрерывной езды по критическому косогору до срыва, с
var _land_settle := 0.0    # окно усадки подвески после касания земли, с
var vertical_g := 0.0  # нагрузка профиля земли вдоль пути в g: впадина сжимает (+), гребень разгружает (−)
var bank_slope := 0.0  # наклон полотна поперёк: рост высоты на метр вправо от курса, сглаженный
var _crest_curve := 0.0 # кривизна профиля на базе осей (HUB), 1/м (для отрыва на гребне)
var _ground_cross := 0.0 # несглаженный поперечный уклон полотна (для 2D-нормали и косогоров)
var land_impact := 0.0 # сила последнего приземления, м/с (для тряски камеры); только приземления
var fork_side_impulse := 0.0 # signed local-right change of front wheel speed on edges this tick
var wheel_impact := Vector2() # удар переднего и заднего колеса о кромку за такт, м/с скорости колеса (GameWorld сбрасывает)
var bottom_out := 0.0  # 12.7: скорость удара вилки в упор, м/с (для звука; GameWorld сбрасывает)
var braking := 0.0     # 12.7: резкое торможение на скорости 0..1 (для хруста покрытия)
var fallen := false # рама остаётся в физической позе до ручной посадки
var fallen_transform := Transform3D.IDENTITY
## 20.11: для вида и записи заездов — состояние прыжка и поворота без доступа к внутренним полям.
## Пробел нажат и ждёт или идёт фаза «тело назад» авто-Q→E (подготовка видна у седока).
var hop_preparing: bool:
	get: return _hop_buf > 0.0 or (_auto_hop >= 0.0 and _auto_hop < config.auto_back)
## Отрыв этого полёта — банни-хоп (Q→E или пробел), а не сход с кромки.
var hop_used: bool:
	get: return _hop_used
## 20.11: доля пассивного поглощения гребня ногами (без зажатого пампа) 0..pump_passive — для позы седока.
var crest_absorb: float:
	get: return 0.0 if pump_pressed else clampf(_pump_absorb_v / config.pump_absorb_v, 0.0, 1.0)
## Угловая скорость курса, рад/с.
var yaw_rate: float:
	get: return _yaw_rate


## 20.11: одноразовые события такта (приземление, удары колёс, пробой) — читатели такта (вид, звук, камера, запись)
## их уже получили; один сброс для игры и Trail Lab вместо двух ручных копий.
func clear_tick_events() -> void:
	landing_info = {}
	land_impact = 0.0
	wheel_impact = Vector2()
	fork_side_impulse = 0.0
	bottom_out = 0.0


## Найти место рядом с игроком, начиная справа. null, если рама нигде не помещается.
static func park_near(p: PlayerState, yaw: float, w: WorldData, heights: Heightfield) -> BikeRide:
	var b := BikeRide.new()
	for offset: Vector2 in [Vector2(1.6, 0), Vector2(-1.6, 0), Vector2(0, 1.6), Vector2(0, -1.6),
			Vector2(1.6, 1.6), Vector2(-1.6, 1.6), Vector2(1.6, -1.6), Vector2(-1.6, -1.6), Vector2.ZERO]:
		var b_x := p.x + cos(yaw) * offset.x - sin(yaw) * offset.y
		var b_z := p.z - sin(yaw) * offset.x - cos(yaw) * offset.y
		b.y = heights.surface_at(b_x, b_z, p.feet)
		if not is_finite(b.y) or absf(b.y - p.feet) >= MOUNT_RISE:
			continue
		for hd: float in [yaw, yaw + PI * 0.5]:
			if b.fits(b_x, b_z, hd, w, heights, false):
				b.x = b_x
				b.z = b_z
				b.heading = hd
				return b
	return null


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


## Обнулить движение, подвеску и отложенный ввод, не меняя местоположение: новая поездка, посадка, восстановление.
## Сбрасывается всё временное состояние, от которого зависят следующие подшаги и телеметрия, — контакт колёс
## (скользкость, силы, опоры), последнее событие падения, путь для фазы кочек. Накопительная статистика
## замеров (impacts, hop_height) остаётся: её сбрасывает reset_stats(). Положение и визуальные углы колёс
## и педалей (wheel, crank) тоже остаются.
func reset_motion() -> void:
	last_hit = {}
	tick_time = 0.0
	landing_info = {}
	crash_info = {}
	slick_f = 1.0
	slick_r = 1.0
	force_f = Vector2()
	force_r = Vector2()
	hit_dv = Vector2()
	_sup_f = 0.0
	_sup_r = 0.0
	_g_f = 0.0
	_g_r = 0.0
	_gv_f = 0.0
	_gv_r = 0.0
	_o_f = 0.0
	_o_r = 0.0
	_hop_from = 0.0
	_dist = 0.0
	tilt = 0.0
	crash_cause = CrashCause.FALL
	crash_normal = Vector3.UP
	crash_velocity = Vector3()
	_sub.fill(0.0)
	_side_use = 0.0
	_reverse_armed = true
	_share = 0.5
	effort = 0.0
	gear = config.gear_min
	drive_request = 0.0
	drive_force = 0.0
	brake_force = Vector2()
	roll_loss = 0.0
	air_loss = 0.0
	rough_loss = 0.0
	slope_force = 0.0
	pump_force = 0.0
	grade_now = 0.0
	feel_acceleration = 0.0
	pump_motion = 0.0
	pump_load = 0.0
	pump_accel = 0.0
	pump_wave = 0.0
	pump_pressed = false
	pump_active = 0.0
	pump_body = 0.0
	_pump_reach = 0.0
	_pump_absorb_v = 0.0
	_pump_wait = config.pump_pause
	acceleration = 0.0
	vertical_g = 0.0
	bank_slope = 0.0
	_crest_curve = 0.0
	_ground_cross = 0.0
	stance = Stance.RIDING
	foot_side = -1.0
	foot_support = Vector3(x, y, z)
	_stop_timer = 0.0
	_manual_reverse = false
	_stance_driven = false
	pitch_vel = 0.0
	instability = 0.0
	_offcamber_time = 0.0
	_land_settle = 0.0
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
	air_clearance = 0.0
	clearance_closing_speed = 0.0
	air_time = 0.0
	_hop_wait = 0.0
	airborne = false
	crashed = false
	land_impact = 0.0
	wheel_impact = Vector2()
	fork_side_impulse = 0.0
	bottom_out = 0.0
	body_back = false
	body_forward = false
	body_x = 0.0
	body_v = 0.0
	unweight = 0.0
	lift_f = 0.0
	lift_fv = 0.0
	lift_r = 0.0
	lift_rv = 0.0
	_auto_hop = -1.0
	_hop_link = 0.0
	_hop_front = 0.0
	_hop_front_v = 0.0
	_hop_used = false
	load_f = 0.5
	load_r = 0.5
	tire_f = 0.5
	tire_r = 0.5
	side_f = 0.5
	side_r = 0.5
	_landing_grip = 0.0
	use_f = 0.0
	use_r = 0.0
	_rest_f = 0.0
	_rest_r = 0.0
	_on_f = -1
	_on_r = -1


## Накопительная статистика замеров: встречи колёс с кромками и высота последнего банни-хопа.
func reset_stats() -> void:
	impacts = Vector2i()
	hop_height = 0.0


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
	# по опорам колёс: на бревне и валуне тоже подъём, который надо одолеть
	return (_wheel_ground(x + fx, z + fz, heights, lift_f) - _wheel_ground(x - fx, z - fz, heights, lift_r)) / (2.0 * HUB)


## Уклон самой земли вдоль курса, без препятствий
func _ground_slope(heights: Heightfield) -> float:
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	return (_surface(heights, x + fx, z + fz, y) - _surface(heights, x - fx, z - fz, y)) / (2.0 * HUB)


## Высота опоры в (px, pz): середина между точками касания колёс. Велосипед перекрывает
## мелкие изломы базой, а не повторяет каждый под одной точкой.
func _contact(px: float, pz: float, heights: Heightfield) -> float:
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	return (_wheel_ground(px + fx, pz + fz, heights, lift_f) + _wheel_ground(px - fx, pz - fz, heights, lift_r)) * 0.5


## Высота земли под ступицей колеса как круга: ребро ступеньки или резкий гребень поднимают колесо
## плавно по дуге, а не проваливают в излом метровой сетки. На гладком рельефе равна высоте точки.
func _wheel_ground(px: float, pz: float, heights: Heightfield, lift := 0.0) -> float:
	var best := _surface(heights, px, pz, y)
	var dx := -sin(heading) * WHEEL_REACH
	var dz := -cos(heading) * WHEEL_REACH
	var arc := sqrt(WHEEL_R * WHEEL_R - WHEEL_REACH * WHEEL_REACH) - WHEEL_R
	best = maxf(best, _surface(heights, px + dx, pz + dz, y) + arc)
	best = maxf(best, _surface(heights, px - dx, pz - dz, y) + arc)
	if heights.obstacles != null:
		best += maxf(0.0, heights.obstacles.wheel_support(px, pz, WHEEL_R, ForestObstacles.CLIMB_MAX) - best - lift)
	return best


## Низкие препятствия встречает колесо, а не рама
func _climb() -> float:
	return ForestObstacles.CLIMB_MAX


## Нагрузка от кривизны профиля вдоль курса и поперечный наклон полотна; оба сглажены от шума сетки.
func _read_surface(heights: Heightfield, dt: float) -> void:
	if airborne:
		vertical_g = lerpf(vertical_g, 0.0, Util.damp(config.g_relax_air, dt))
		_crest_curve = 0.0
		_ground_cross = 0.0
		return
	var ahead := Vector2(-sin(heading), -cos(heading)) * config.profile_span
	var g0 := _surface(heights, x, z, y)
	var curve := (_surface(heights, x + ahead.x, z + ahead.y, y) + _surface(heights, x - ahead.x, z - ahead.y, y) - 2.0 * g0) / (config.profile_span * config.profile_span)
	var wheel_ahead := Vector2(-sin(heading), -cos(heading)) * HUB
	var c_f := (_surface(heights, x + wheel_ahead.x * 2.0, z + wheel_ahead.y * 2.0, y) + g0) * 0.5
	var c_r := (_surface(heights, x - wheel_ahead.x * 2.0, z - wheel_ahead.y * 2.0, y) + g0) * 0.5
	var c_0 := (_surface(heights, x + wheel_ahead.x, z + wheel_ahead.y, y) + _surface(heights, x - wheel_ahead.x, z - wheel_ahead.y, y)) * 0.5
	_crest_curve = (c_f + c_r - 2.0 * c_0) / (HUB * HUB)
	var goal := clampf(speed * speed * curve / config.ground_gravity, config.g_min, config.g_max)
	vertical_g = lerpf(vertical_g, goal, Util.damp(config.g_response, dt))
	var right := Vector2(cos(heading), -sin(heading)) * config.bank_span
	var g_r := _surface(heights, x + right.x, z + right.y, y)
	var g_l := _surface(heights, x - right.x, z - right.y, y)
	var cross_r := (g_r - g0) / config.bank_span
	var cross_l := (g0 - g_l) / config.bank_span
	var cross := (cross_l + cross_r) * 0.5
	# Крутая вогнутая выемка у склона слева/справа не должна превращать полотно в ложный контруклон.
	if g_l + g_r - 2.0 * g0 > 0.08 * config.bank_span and maxf(absf(cross_l), absf(cross_r)) > 0.50:
		cross = cross_r if absf(cross_r) < absf(cross_l) else cross_l
	_ground_cross = cross
	bank_slope = lerpf(bank_slope, clampf(cross, -config.bank_slope_max, config.bank_slope_max), Util.damp(config.bank_response, dt))


## Уходит ли рельеф впереди из-под полёта: летим с нынешней вертикальной скоростью
## и смотрим, насколько ниже окажется земля через look_times секунд.
func _lifts(heights: Heightfield) -> bool:
	if _on_f >= 0 and _on_r < 0:
		return false
	var velocity := horizontal_velocity()
	var fx := velocity.x
	var fz := velocity.y
	# 30.10: на волне седок гасит ногами часть вертикальной скорости, набранной на подъёме гребня (pump_absorb_v):
	# без этого на 12+ м/с каждый подъём волны 5–6 м выбрасывал велосипед в полёт
	var lift_v := vy - _pump_absorb_v
	var settle_margin := config.stretch_max * 0.75 * clampf(_land_settle / maxf(config.landing_settle, 0.01), 0.0, 1.0)
	for t: float in config.look_times:
		var fly := y + lift_v * t - config.air_gravity * t * t * 0.5
		if fly - _contact(x + fx * t, z + fz * t, heights) > config.lift_threshold + _pump_reach + settle_margin:
			return true
	return false


## Короткий профиль по направлению движения. Длинный уклон вычитается: ровная гора не становится пампом.
## Вызывается до сил/вертикали, поэтому ручной ввод выключает помощь в том же подшаге.
func _step_pump(dt: float, throttle: float, turn: float, hop: bool, heights: Heightfield) -> void:
	pump_accel = 0.0
	pump_load = 0.0
	_pump_reach = 0.0
	_pump_absorb_v = 0.0
	pump_wave = 0.0
	var held := pump_active
	# короткий отрыв не стирает «на волне»: посадка на следующий подъём тоже поглощается
	pump_active = held * exp(-dt / config.pump_hold)
	pump_body = 0.0
	_pump_wait = maxf(0.0, _pump_wait - dt)
	if not pump_enabled:
		pump_active = 0.0
		pump_motion = lerpf(pump_motion, 0.0, Util.damp(12.0, dt))
		return
	var manual := pump_pressed
	if not manual:
		pump_active = 0.0
	# 30.10: ручная работа телом больше не выключает памп — она и есть памп (ниже). Автоматика уступает ей место
	# плавно; целиком памп снимают только прыжок, тормоз, занос и отрыв.
	var jumping := hop or _auto_hop >= 0.0 or _hop_buf > 0.0 or _hop_used
	var blocked := jumping or throttle < -0.05 or brake_pressure > 0.1 or absf(slip) > 0.12
	var body_work := clampf(absf(body_x) / 0.3 + absf(body_v) / 1.2, 0.0, 1.0)
	if blocked or airborne or _fresh:
		_pump_wait = config.pump_pause
	# пауза после приземления и ручного действия — только для толчка автоматики: гребень сразу после посадки тоже
	# поглощается, иначе на скорости велосипед не возвращался на волны до конца серии
	# 20.11: пассивное поглощение ногами снимает только прыжок — с тормозом и в заносе гребень гасится так же
	var ready := pump_enabled and riding and not crashed and not airborne and not (blocked if manual else jumping)
	ready = ready and speed > 2.0 and _on_f < 0 and _on_r < 0
	ready = ready and heights.immersion_at(x, z, y) < 0.03
	var motion := 0.0
	if ready:
		var direction := horizontal_velocity().normalized()
		# 30.10: не длиннее 1 м — раньше до 1,6 м, и на 12+ м/с волна 5–6 м уже выглядела ступенькой: памп выключался
		var span := clampf(absf(speed) * 0.12, 0.8, 1.0)
		var levels := PackedFloat32Array()
		var clear := true
		for i in range(-2, 3):
			var at := Vector2(x, z) + direction * span * i
			# Одна и та же доступная земля: не качаемся через край настила, неизвестную область или воду.
			if not heights.known(at.x, at.y) or is_finite(heights.deck_at(at.x, at.y, INF)) or heights.immersion_at(at.x, at.y, y) > 0.03:
				clear = false
				break
			levels.append(_surface(heights, at.x, at.y, y))
		if clear:
			var previous := 0.0
			for i in 4:
				var grade := (levels[i + 1] - levels[i]) / span
				# Ступень/стена/гэп и очень крутой кикер остаются штатными препятствиями и вылетами.
				if absf(grade) > 0.65 or (i > 0 and absf(grade - previous) > config.pump_kink * span): clear = false
				previous = grade
		var local_grade := 0.0
		if clear:
			local_grade = (levels[3] - levels[1]) / (2.0 * span)
		if clear and not manual:
			# 20.11: пассивный седок гасит гребни на пологих холмах, с плавным спадом на крутом уклоне
			var grade_keep := 1.0 - smoothstep(config.pump_passive_max_grade, config.pump_passive_max_grade + 0.25, absf(local_grade))
			if grade_keep > 0.001 and absf(levels[2] - levels[4]) < 0.45 * span:
				var crest := smoothstep(0.01, 0.07, absf((levels[1] + levels[3]) * 0.5 - levels[2])) * smoothstep(2.0, 5.0, speed) * grade_keep
				crest *= smoothstep(0.03, 0.12, maxf(levels[2], levels[3]) - levels[4])
				_pump_reach = config.pump_reach * config.pump_passive * crest
				_pump_absorb_v = config.pump_absorb_v * config.pump_passive * crest
			clear = false
		if clear:
			var long_grade := (levels[4] - levels[0]) / (4.0 * span)
			var wave := local_grade - long_grade
			var hollow := (levels[1] + levels[3]) * 0.5 - levels[2]
			var activity := smoothstep(0.01, 0.07, absf(hollow)) * smoothstep(2.0, 5.0, speed)
			# для ручного пампа — настоящий местный уклон: на ровной горе нажатие и возврат тела взаимно гасятся
			pump_wave = local_grade
			# кривизна (hollow) проходит через ноль на середине склона волны, где уклон наибольший: «на волне» держится
			# pump_hold секунд после последнего заметного изгиба, а не мигает дважды за волну
			pump_active = maxf(activity, held * exp(-dt / config.pump_hold)) * smoothstep(2.0, 5.0, speed)
			# Автоматика — спокойный седок: слегка сгибается на гребне и давит на обратный склон. Уступает
			# ручной работе телом и заметному рулю плавно, без паузы возврата.
			var auto := (1.0 if _pump_wait <= 0.0 else 0.0) * (1.0 - body_work) * (1.0 - smoothstep(config.pump_steer_limit, 0.8, absf(turn))) * (1.0 if lift_f <= 0.0 and lift_r <= 0.0 else 0.0)
			motion = clampf(wave * 1.8 - hollow * 3.0, -1.0, 1.0) * activity * auto
			var pace := 1.0 - smoothstep(config.pump_top - 4.0, config.pump_top, speed)
			pump_accel = minf(1.0, maxf(0.0, -wave) * config.pump_accel) * activity * pace * auto
			pump_load = clampf(-wave * 0.65, -0.12, 0.2) * activity * auto
			# 30.10: гребень поглощают ноги и руки на любой скорости (раньше ход тела исчезал к 14 м/с, и с 12 м/с велосипед
			# летел с каждой волны 5–6 м); исчезает только толчок автоматики, ход тела остаётся и при ручной работе
			# гасим только волну — впереди или под нами гребень, за которым спуск; кромка кикера перед ровным столом
			# подбрасывает, как прежде
			var backside := smoothstep(0.03, 0.12, maxf(levels[2], levels[3]) - levels[4])
			_pump_reach = config.pump_reach * pump_active * backside
			_pump_absorb_v = config.pump_absorb_v * pump_active * backside
			# Ручной памп — один закон для обеих фаз: сколько веса тело добавило к опоре (E — продавить, рывок вперёд-
			# вниз) или сняло с неё (Q — поглотить, рывок назад-вверх), столько этой нагрузки работает на уклоне волны,
			# a = −g · Δнагрузки · уклон. Продавить обратный склон или поглотить подъём — разгон; наоборот — торможение.
			# Поглощение ещё и держит колёса на гребне (ход тела), продавливание прижимает их к земле.
			pump_body = clampf(-body_v / config.body_rate, -1.0, 1.0) * config.pump_body
			var manual_pace := 1.0 - smoothstep(config.pump_top, config.pump_top + 6.0, speed)
			pump_load += pump_body * pump_active
			pump_accel += clampf(-config.ground_gravity * pump_body * local_grade, -config.pump_body_accel, config.pump_body_accel) * pump_active * manual_pace
			_pump_reach += config.pump_reach * 1.5 * maxf(0.0, -pump_body / config.pump_body) * pump_active
			_pump_absorb_v += config.pump_absorb_v * 0.5 * maxf(0.0, -pump_body / config.pump_body) * pump_active
	pump_motion = lerpf(pump_motion, motion, Util.damp(12.0, dt))


## Шаг езды за dt секунд (в игре — один такт физики, 1/60 с). throttle — газ (+) и тормоз (-),
## turn — руль вправо (+) и влево (-), hop — пробел нажат в этом такте (срабатывает, как только прыжок
## доступен, если ждать недолго).
func step(p: PlayerState, throttle: float, turn: float, boost: bool, hop: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	# Один и тот же короткий шаг при 30/60/120 Гц; hop передаётся только первому подшагу.
	# Существующие рельеф, вода и подвеска остаются в том же цикле, без новой вертикальной модели.
	# Упавший велосипед ждёт BikeController (ragdoll); новых импульсов и событий у него нет.
	landing_info = {}
	if dt <= 0.0 or crashed:
		return
	var ticks := ceili(dt * SUB_HZ) if dt > 1.0 / SUB_HZ + 0.000001 else 1
	var start := horizontal_velocity()
	var sums := PackedFloat32Array()
	sums.resize(TELEMETRY)
	var done := 0.0
	_surf_memo.clear()
	_surf_at.clear()
	_surf_val.clear()
	_surf_plain = heights.get_script() == _HEIGHTFIELD
	for i in ticks:
		_fit_memo_on = true
		_fit_memo[0] = NAN # новый подшаг: препятствия и рельеф могли смениться между тактами
		_substep(p, throttle, turn, boost, hop and i == 0, dt / ticks, w, heights)
		_fit_memo_on = false
		done += dt / ticks
		for k in TELEMETRY:
			sums[k] += _sub[k] * dt / ticks
		if crashed:
			break
	_end_tick(sums, done, start)


## Силы и сигналы за последний внешний шаг (средние по подшагам), м/с² на массу велосипеда с седоком.
## Дают седоку, камере и звуку одни и те же данные за тот же интервал, а не значение последнего подшага.
enum { T_DRIVE_REQUEST, T_DRIVE, T_BRAKE_F, T_BRAKE_R, T_ROLL, T_AIR, T_ROUGH, T_SLOPE, T_PUMP, T_GRADE, TELEMETRY }
var _sub := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var drive_request := 0.0   # запрос педалей до ограничения контактом и сцеплением
var drive_force := 0.0     # реализованная тяга заднего колеса
var brake_force := Vector2() # фактически приложенный тормоз переднего и заднего колеса
var roll_loss := 0.0       # качение по покрытию
var air_loss := 0.0        # воздух (на земле и в полёте один закон)
var rough_loss := 0.0      # неровности и потери на большой скорости
var slope_force := 0.0     # тяжесть вдоль пути: больше нуля — разгоняет
var pump_force := 0.0      # помощь автопампа
var grade_now := 0.0       # геометрический уклон земли вдоль курса (без подвески и тела), м на м
var feel_acceleration := 0.0 # продольное ускорение по мировой скорости за внешний шаг: перепроекция рамы его не даёт
var tick_time := 0.0       # длительность последнего внешнего шага, с
## Фактически приложенный тормоз за внешний шаг (обе оси, среднее по подшагам): единый сигнал для седока и камер.
## brake_deceleration — значение последнего подшага, для замеров.
var brake_applied: float:
	get: return brake_force.x + brake_force.y


func _end_tick(sums: PackedFloat32Array, done: float, start: Vector2) -> void:
	tick_time = done
	var inv := 1.0 / maxf(done, 0.000001)
	drive_request = sums[T_DRIVE_REQUEST] * inv
	drive_force = sums[T_DRIVE] * inv
	brake_force = Vector2(sums[T_BRAKE_F], sums[T_BRAKE_R]) * inv
	roll_loss = sums[T_ROLL] * inv
	air_loss = sums[T_AIR] * inv
	rough_loss = sums[T_ROUGH] * inv
	slope_force = sums[T_SLOPE] * inv
	pump_force = sums[T_PUMP] * inv
	grade_now = sums[T_GRADE] * inv
	var forward := Vector2(-sin(heading), -cos(heading))
	feel_acceleration = (horizontal_velocity() - start).dot(forward) * inv


## Подшаг езды; step() делит внешний шаг на них и собирает сигналы.
func _substep(p: PlayerState, throttle: float, turn: float, boost: bool, hop: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	_sub.fill(0.0)
	# Порядок подшага и возраст данных (контракт; переставлять фазы нельзя — от него зависят задержки):
	# 1. покрытие читается один раз в начале (Footing);
	# 2. продольная сила: педали и тормоз берут нагрузки, скользкость и боковую силу шин с прошлого подшага;
	# 3. курс и боковая сила: руль, доворот из заноса, снос — запас шин тоже с прошлого подшага;
	# 4. перемещение со столкновениями; 5. вертикаль: опора, прыжок, полёт, свод;
	# 6. колёса на опоре: кромки, кочки, скользкость — для следующего подшага;
	# 7. подвеска и нагрузки колёс, тело седока и Q/E — для следующего подшага; 8. поза рамы для вида.
	# Любое падение завершает подшаг сразу (_sync) и сохраняет первое событие.
	var f := _read_footing(turn, w, heights)
	var speed0 := speed
	_step_longitudinal(f, throttle, turn, boost, hop, dt, heights)
	if crashed:
		_sync(p)
		return
	_read_surface(heights, dt)
	var free_now := fits(x, z, heading, w, heights)
	var lateral := _step_heading(f, free_now, turn, dt, w, heights)
	if crashed:
		_sync(p)
		return
	_step_move(free_now, dt, w, heights)
	if crashed:
		_sync(p)
		return
	_step_vertical(_contact(x, z, heights), hop, dt, heights)
	if not crashed:
		_update_stance(dt, f.slope, heights)
	# Непрерывный крутой склон раньше подменял падение покадровой привязкой к земле.
	# Даже медленный съезд по почти отвесной стене теперь теряет равновесие и запускает ragdoll.
	if not crashed and not airborne and absf(speed) > 0.25 and f.slope * signf(speed) < -config.cliff_grade:
		_crash(vy, Vector3(sin(heading) * f.slope, 1.0, cos(heading) * f.slope).normalized())
	if crashed:
		_sync(p)
		return
	var h_wheels := heading
	_step_wheels(heights, f.rough, dt, f.surf, f.path_weight, f.slope, f.across)
	# Камень под передним колесом выбивает курс; как руль и доворот, это проходит проверку габарита (у стены — нет)
	if heading != h_wheels and not fits(x, z, heading, w, heights):
		var velocity := horizontal_velocity()
		heading = h_wheels
		speed = velocity.dot(Vector2(-sin(heading), -cos(heading)))
		lateral_speed = velocity.dot(Vector2(cos(heading), -sin(heading)))
	if crashed:
		_sync(p)
		return
	acceleration = clampf((speed - speed0) / maxf(dt, 0.0001), -9.0, 12.0)
	_step_suspension(dt, minf(absf(lateral) * 0.001, 0.015) + clampf(vertical_g, config.g_min, config.g_max) * config.sag_max * config.profile_sag, _sub[T_DRIVE] - _sub[T_BRAKE_F] - _sub[T_BRAKE_R])
	var before_hop := y
	_step_contacts(f.slope, dt)
	if airborne and y > before_hop:
		var roof := _roof_over(x, z, heading, before_hop, heights) - BikeRecovery.CLEARANCE
		if y > roof:
			var correction := y - maxf(before_hop, roof)
			y -= correction
			ground_f += correction
			ground_r += correction
			vy = minf(vy, 0.0)
	_step_pose(throttle, lateral, dt)
	_sync(p)


## Покрытие под велосипедом на один подшаг: уклон по опорам колёс, путь, сцепление и неровность.
class Footing:
	var slope := 0.0
	var ground_slope := 0.0
	var surf := RoadSurface.NONE
	var path_weight := 0.0
	var across := 0.0
	var terrain := 1.0   # общая скорость передвижения по покрытию (PlayerState.terrain_speed), как у пешехода
	var pace := 1.0      # велосипед: доля крейсерской скорости, к которой тянут педали
	var rolling := 1.0   # велосипед: лёгкость качения (сопротивление BIKE_ROLL / rolling)
	var rough := 0.0
	var grip := 0.85
	var technical := 0.0


var _footing := Footing.new() # 20.11: один на велосипед, живёт только внутри подшага (не выделяется 120 раз в секунду)


func _read_footing(turn: float, w: WorldData, heights: Heightfield) -> Footing:
	var f := _footing
	f.grip = 0.85 # остальные поля ниже пишутся всегда
	# Резерв поворота в тормозе — по фактическому положению руля (оно догоняет ввод с той же скоростью, что и курс)
	# и по боковой силе, которую шины держат сейчас: на выходе из дуги руль уже прямо, а снос ещё гасится.
	# Раньше — по сырому вводу: на входе резерв появлялся раньше поворота, на выходе исчезал раньше сноса.
	_corner_demand = maxf(absf(steer) * smoothstep(3.0, 10.0, absf(speed)), _side_use)
	f.slope = _slope(heights)
	f.ground_slope = _ground_slope(heights)
	_sub[T_GRADE] = f.ground_slope
	var contact := RideSurface.sample(w, heights, x, z)
	f.surf = contact.surface
	f.path_weight = contact.weight
	f.across = contact.across
	f.terrain = maxf(0.15, PlayerState.terrain_speed(w, x, z, heights))
	# Параметры велосипеда отдельно от пешей скорости: пока те же числа, настраиваются здесь независимо.
	f.pace = f.terrain
	f.rolling = f.terrain
	f.rough = clampf(1.3 - f.terrain, 0.15, 1.0)
	if f.surf != RoadSurface.NONE:
		f.grip = lerpf(f.grip, RoadSurface.LIST[f.surf].grip, f.path_weight)
		f.rough = lerpf(f.rough, RoadSurface.LIST[f.surf].rough, f.path_weight)
	# На корнях и камнях медленный проезд точный; быстрый требует более широкой дуги.
	f.technical = smoothstep(0.25, 0.8, f.rough) * smoothstep(6.0, 15.0, absf(speed))
	f.grip *= 1.0 - f.technical * 0.2
	return f


## Продольное движение подшага: педали, тормоз и автопамп на земле, накат в воздухе. Может уронить (перелёт).
func _step_longitudinal(f: Footing, throttle: float, turn: float, boost: bool, hop: bool, dt: float, heights: Heightfield) -> void:
	# При постановке на склон велосипед уже движется вдоль опоры. vy=0 здесь создавал
	# ложный отрыв на спуске ещё до Q, после чего подготовка баннихопа пропадала.
	if _fresh and not airborne:
		y = _contact(x, z, heights)
		vy = _ground_slope(heights) * speed
	_step_pump(dt, throttle, turn, hop, heights)
	if not airborne:
		var water := lerpf(1.0, 0.4, smoothstep(0.05, 0.8, heights.immersion_at(x, z, y)))
		_step_speed(throttle, boost, f.slope, f.pace * water, dt, f.grip, f.technical, f.rolling * water, f.ground_slope)
		if brakes.tipped:
			_crash(vy, Vector3.UP, CrashCause.BRAKING)
	else:
		# В воздухе педали и тормоз не меняют скорость и не готовят задний ход; ноги перестают давить.
		_step_effort(0.0, dt)
		_brake_hold = 0.0
		brakes.step(dt, 0.0, speed, f.slope, f.grip, 0.0, false)
		braking = 0.0
		# Тот же воздух, что на земле, по полной горизонтальной скорости: отрыв не меняет закон сопротивления.
		var v := Vector2(speed, lateral_speed)
		var keep := 1.0 / (1.0 + config.air_drag * v.length() * dt)
		_sub[T_AIR] = speed * (1.0 - keep) / dt
		speed *= keep
		lateral_speed *= keep


func _step_effort(want: float, dt: float) -> void:
	if not effort_ramp:
		effort = want
		return
	effort = lerpf(effort, want, 1.0 - exp(-dt / (config.effort_rise if want > effort else config.effort_fall)))


## Курс и боковая сила: руль и доворот из заноса в пределах габарита, затем перепроекция скорости и снос.
## Возвращает боковое ускорение (для крена и подвески). Большой снос на скорости роняет набок.
func _step_heading(f: Footing, free_now: bool, turn: float, dt: float, w: WorldData, heights: Heightfield) -> float:
	var grip := f.grip
	var h0 := heading
	heading += _step_turn(turn, grip, dt)
	# Вплотную к стене колесо не поворачивается в неё, накопленного рывка тоже нет.
	if free_now and not fits(x, z, heading, w, heights):
		heading = h0
		_yaw_rate = 0.0
	if not airborne:
		# Доворот из заноса проходит ту же проверку габарита, что и руль: у стены рама остаётся на принятом курсе,
		# а снос гасит боковая сила. Скорость перепроецируется ниже от h0 на итоговый курс.
		var turned := heading
		heading += _align(dt)
		if free_now and not fits(x, z, heading, w, heights):
			heading = turned
		if absf(slip) > config.slide_crash and Vector2(speed, lateral_speed).length() > config.slide_crash_speed:
			var side := Vector2(cos(heading), -sin(heading)) * signf(lateral_speed)
			_crash(vy, Vector3(-side.x, 0.4, -side.y), CrashCause.FALL)
			return 0.0
	return _step_traction(h0, grip, dt)


## Перемещение подшага со столкновениями: скольжение вдоль стен и препятствий, потеря скорости, удар в лоб.
## free_now — велосипед до шага помещался; иначе выехать можно, проверяется середина.
func _step_move(free_now: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
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
			if PlayerState.is_passable(w, heights, px, pz, y, 0.0, false, _climb()):
				return true
			# 11.7: после прыжка середина внутри валуна или бревна: наружу выехать можно, иначе застрял бы
			# (прыжок ниже верха валуна), а вглубь и в сторону — нет
			if heights.obstacles == null or not w.accessible(px / GameConfig.TILE, pz / GameConfig.TILE) or not heights.known(px, pz) \
					or heights.depth_at(px, pz, y) >= GameConfig.FORD_DEPTH:
				return false
			return heights.obstacles.normal(x, z, y, 0.0, _climb()).dot(Vector2(px - x, pz - z)) > 0.0
		# 7.7: вдоль ствола и бревна велосипед скользит по касательной
		var around := Callable()
		if heights.obstacles != null:
			around = func(px: float, pz: float) -> Vector2: return obstacle_normal(px, pz, hd, heights)
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
				if not PlayerState.is_passable(w, heights, x + ahead.x - sin(heading) * axle, z + ahead.z - cos(heading) * axle, y, BODY_R, true, _climb()):
					solid = true
					break
			# Удар о предмет опасен и в прыжке; вода и граница открытой земли не являются стеной.
			if solid and impact > config.wall_crash:
				_crash(vy, normal, CrashCause.COLLISION)
			var keep := 0.0 if moved < 1e-5 else _slide_keep(dt, moved, full)
			speed *= keep
			lateral_speed *= keep
	_dist += Grid.hypot(x - x0, z - z0)


## Поза рамы для вида: наклон по подвескам или траектории, крен от поворота, углы колёс и педалей.
func _step_pose(throttle: float, lateral: float, dt: float) -> void:
	# Рама лежит на концах подвесок: колёса на точках касания, рама — выше на свой ход у каждого.
	# В полёте тангажом управляют Q/E (pitch_vel), в отсутствие ввода рама мягко тянется к траектории.
	if airborne:
		var traj := clampf(atan2(vy, maxf(absf(speed), config.air_tilt_speed)), -config.air_tilt_max, config.air_tilt_max)
		if speed < 0.0:
			traj = -traj
		var trim := (1.0 if body_back else 0.0) - (1.0 if body_forward else 0.0)
		var align := (traj - tilt) * config.air_pitch_align * (1.0 - absf(trim))
		pitch_vel = clampf(pitch_vel + (trim * config.air_pitch_accel + align - pitch_vel * config.air_pitch_damp) * dt, -config.air_pitch_max_vel, config.air_pitch_max_vel)
		tilt = clampf(tilt + pitch_vel * dt, -config.air_pitch_limit, config.air_pitch_limit)
	else:
		pitch_vel = 0.0
		var tilt_goal := atan2((ground_f - squash_f) - (ground_r - squash_r), 2.0 * HUB) + unweight * config.pull_pitch
		tilt = lerpf(tilt, tilt_goal, Util.damp(config.tilt_response, dt))
	var slip_stress := smoothstep(config.instab_slip_from, config.slide_crash * 0.85, absf(slip)) * 0.85
	var hit_stress := smoothstep(config.instab_impact_from, config.instab_impact_from + 2.8, wheel_impact.length()) * 0.65
	var camber_warn := clampf(_offcamber_time / maxf(config.offcamber_crash_grace, 0.05), 0.0, 1.0) * 0.45
	var instab_goal := 0.0 if airborne else clampf(slip_stress + brakes.risk * 0.65 + _offcamber_slide() * 0.55 + hit_stress + camber_warn, 0.0, 1.0)
	var instab_rate := config.instability_rise if instab_goal > instability else config.instability_decay
	instability = lerpf(instability, instab_goal, Util.damp(instab_rate, dt))
	# Крен от реального поворота, а не от кнопки: на месте не заваливаемся.
	# На лёгкой коррекции курс задаёт руль почти без завала рамы; по мере роста бокового ускорения
	# и на настоящих контруклонах/виражах крен плавно раскрывается до полного карвинга.
	var cross := clampf(bank_slope, -config.bank_slope_max, config.bank_slope_max)
	var bank_accel := config.ground_gravity * cross / sqrt(1.0 + cross * cross) * smoothstep(config.side_hold_speed * 0.5, config.side_hold_speed * 2.0, absf(speed))
	var lat_net := lateral + bank_accel
	var banked := smoothstep(config.lean_bank_from, config.lean_bank_full, absf(cross))
	var carve := smoothstep(config.lean_carve_from, config.lean_carve_full, absf(lat_net))
	var target_share := lerpf(config.lean_gentle_share, lerpf(config.lean_share_flat, config.lean_share, banked), carve)
	var lean_max := lerpf(config.lean_max_flat, config.lean_max, banked)
	var lean_goal := 0.0 if airborne else clampf(atan(lat_net / config.ground_gravity) * target_share, -lean_max, lean_max)
	lean = lerpf(lean, lean_goal, Util.damp(config.lean_response_air if airborne else config.lean_response, dt))

	# углы держим в пределах оборота, чтобы за долгую езду они не теряли точность
	wheel = fmod(wheel + speed * dt / WHEEL_R, TAU)
	# Виртуальная автоматическая передача: каденс растёт с темпом от 60 до 90 об/мин, а не вместе со скоростью
	# через одну передачу. Подбирается плавно и накатом, чтобы повторный газ начинался с подходящей передачи.
	var wheel_rate := maxf(speed, 0.0) / WHEEL_R
	var wanted_gear := clampf(wheel_rate / lerpf(config.cadence_low, config.cadence_high, smoothstep(2.0, 9.0, speed)), config.gear_min, config.gear_max)
	gear = lerpf(gear, wanted_gear, Util.damp(config.gear_response, dt))
	# педали крутятся, только пока их жмут на земле: накатом и в полёте свободный ход; на старте видно нажатие
	if throttle > 0.0 and not airborne and (speed > 0.3 or effort > 0.05):
		crank = fmod(crank + maxf(wheel_rate / gear, effort * config.start_crank) * dt, TAU)


## Игрока везёт велосипед: положение и опора — отсюда, в конце подшага или при падении.
func _sync(p: PlayerState) -> void:
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
		# Тяжесть поперёк полотна: на контруклоне тянет вниз, на вираже — внутрь поворота. Шины держат её вместе
		# со сносом из своего запаса; стоящий седок упирается ногой. На крутом косогоре боковой зацеп срывается.
		var s := clampf(bank_slope, -config.bank_slope_max, config.bank_slope_max)
		var slide_camber := _offcamber_slide()
		if absf(s) > config.offcamber_crash_grade and absf(speed) > 1.5 and _bank_press() < absf(s) * 0.5:
			_offcamber_time += dt
			if _offcamber_time >= config.offcamber_crash_grace:
				_crash(vy, Vector3(-cos(heading) * s, 1.0, sin(heading) * s).normalized(), CrashCause.FALL)
				return 0.0
		else:
			_offcamber_time = maxf(0.0, _offcamber_time - dt * 2.5)
		var hold := smoothstep(config.side_hold_speed * 0.5, config.side_hold_speed * 2.0, absf(speed))
		if slide_camber > 0.0:
			hold = maxf(hold, smoothstep(0.25, 1.2, absf(speed)))
		lateral_speed -= config.ground_gravity * s / sqrt(1.0 + s * s) * hold * dt
		var bite := 1.0 - config.offcamber_grip_loss * slide_camber
		var caps := _side_caps(grip)
		var base := config.base_grip() * config.rider_grip * grip * bite
		var cap_f := base * side_f * slick_f
		var cap_r := base * side_r * slick_r
		var free_f := caps.x
		var free_r := caps.y
		# Седок балансирует нагрузку: второе колесо использует свободный запас первого.
		# Руль ограничен теми же силами с резервом, поэтому обычная дуга не порождает вечный снос.
		var need := lateral_speed * Util.damp(config.side_response, dt) / dt
		var total := maxf(free_f + free_r, 0.0001)
		var side_force_f := clampf(need * free_f / total, -free_f, free_f)
		var side_force_r := clampf(need * free_r / total, -free_r, free_r)
		lateral = side_force_f + side_force_r
		_side_use = clampf(absf(lateral) / maxf(cap_f + cap_r, 0.1), 0.0, 1.0)
		lateral_speed -= lateral * dt
		force_f = Vector2(brakes.front_force, side_force_f)
		force_r = Vector2(_rear_long(), side_force_r)
		use_f = clampf(force_f.length() / maxf(cap_f, 0.01), 0.0, 1.0) if cap_f > 0.001 else (1.0 if absf(need) > 0.01 else 0.0)
		use_r = clampf(force_r.length() / maxf(cap_r, 0.01), 0.0, 1.0) if cap_r > 0.001 else (1.0 if absf(need) > 0.01 else 0.0)
		grip_usage = clampf(Vector2(brake_deceleration, lateral).length() / maxf(cap_f + cap_r, 0.1), 0.0, 1.0)
	else:
		_offcamber_time = maxf(0.0, _offcamber_time - dt * 4.0)
		grip_usage = 0.0
		_side_use = 0.0
		use_f = 0.0
		use_r = 0.0
		force_f = Vector2()
		force_r = Vector2()
	slip = atan2(lateral_speed, maxf(absf(speed), 2.0))
	return lateral


func _bank_press() -> float:
	var bank := clampf(bank_slope * signf(_yaw_rate), -config.bank_slope_max, config.bank_slope_max)
	return absf(speed * _yaw_rate) / config.ground_gravity * bank / sqrt(1.0 + bank * bank)


func _offcamber_slide() -> float:
	var raw := smoothstep(config.offcamber_slide_grade, config.offcamber_crash_grade, absf(bank_slope))
	return raw * (1.0 - clampf(_bank_press() * 2.5, 0.0, 1.0))


## Продольная сила заднего колеса в этом подшаге: тормоз минус реализованная тяга педалей (один круг сцепления).
func _rear_long() -> float:
	return brakes.rear_force - _sub[T_DRIVE]


## Один запас для запроса руля и удержания траектории; тормоз и тяга уже заняли свою часть.
func _side_caps(grip: float) -> Vector2:
	var bite := 1.0 - config.offcamber_grip_loss * _offcamber_slide()
	var base := config.base_grip() * config.rider_grip * grip * bite
	var cap_f := base * side_f * slick_f if contact_f() else 0.0
	var cap_r := base * side_r * slick_r if contact_r() else 0.0
	return Vector2(sqrt(maxf(0.0, cap_f * cap_f - brakes.front_force * brakes.front_force)),
		sqrt(maxf(0.0, cap_r * cap_r - _rear_long() * _rear_long())))


## Снос больше align_slip доворачивает раму к направлению движения (на шаге dt, рад).
## Курс уменьшается — поворот вправо (как у _step_turn), а снос вправо (lateral_speed > 0) — движение правее рамы.
func _align(dt: float) -> float:
	var excess := absf(slip) - config.align_slip
	if excess <= 0.0 or absf(speed) < 0.5:
		return 0.0
	return -signf(slip) * minf(excess, config.align_rate * dt)


## Руль отзывчив на малой скорости; на большой сцепление расширяет дугу и чуть съедает ход.
## Боковая инерция и торможение делят общий запас сцепления.
func _step_turn(turn: float, grip: float, dt: float) -> float:
	var steer_rate := config.steer_center if is_zero_approx(turn) else config.steer_rate
	steer = move_toward(steer, turn, dt * steer_rate)
	var pace := absf(speed)
	var response := lerpf(config.turn_response_slow, config.turn_response_fast, smoothstep(config.turn_pace_low, config.turn_pace_high, pace))
	var rate := config.max_turn_rate * clampf(pace / 1.8, 0.0, 1.0) / (1.0 + pace * 0.035)
	var dir := 1.0 if speed >= 0.0 else -1.0
	var wanted := -steer * rate * dir
	var limit := rate
	var slide := 0.0 # рад/с: на столько рама доворачивает сверх того, что держат шины (снос)
	if airborne:
		wanted *= 0.25
		limit *= 0.25
		response = 3.0
	else:
		var caps := _side_caps(grip)
		# Переднее по-прежнему задаёт курс, но рама не требует больше, чем держат обе шины.
		var corner_grip := minf(2.0 * caps.x, caps.x + caps.y) * config.turn_reserve
		limit = minf(rate, corner_grip / maxf(pace, 2.5))
		var reference := config.base_grip() * config.rider_grip * grip * config.turn_reserve * config.steer_nominal / maxf(pace, 2.5)
		wanted = -steer * minf(rate, maxf(limit, reference)) * dir
		if contact_f():
			slide = maxf(0.0, absf(wanted) - limit) * config.slide_yaw * (1.0 - smoothstep(config.slide_slip.x, config.slide_slip.y, slip * signf(wanted)))
		wanted = clampf(wanted, -limit - slide, limit + slide)
	var straightening := absf(wanted) < absf(_yaw_rate) or wanted * _yaw_rate < 0.0
	var yaw_resp := response * (config.turn_release_boost if straightening and not airborne else 1.0)
	_yaw_rate = lerpf(_yaw_rate, wanted, Util.damp(yaw_resp, dt))
	if not airborne and pace > 1.0:
		_yaw_rate = move_toward(_yaw_rate, clampf(_yaw_rate, -limit - slide, limit + slide), config.yaw_drop * dt)
	else:
		_yaw_rate = clampf(_yaw_rate, -limit, limit)
	return _yaw_rate * dt


## Руль, как его видно на модели: на месте — команда, на ходу — в основном то, что велосипед действительно делает
func steer_shown() -> float:
	var pace := absf(speed)
	var rate := config.max_turn_rate * clampf(pace / 1.8, 0.0, 1.0) / (1.0 + pace * 0.035)
	var actual := clampf(-_yaw_rate * (1.0 if speed >= 0.0 else -1.0) / maxf(rate, 0.2), -1.0, 1.0)
	var moving := smoothstep(0.5, 3.0, pace) * (0.0 if airborne else 1.0)
	var shown := lerpf(steer, lerpf(actual, steer, config.steer_shown_input), moving)
	shown = signf(shown) * pow(clampf(absf(shown), 0.0, 1.0), config.steer_shown_exp)
	return shown * lerpf(1.0, config.steer_shown_fast, smoothstep(config.steer_shown_pace.x, config.steer_shown_pace.y, pace))


## Опора держит мелкие неровности и изломы; отрыв — только с края или когда рельеф впереди
## уходит вниз быстрее, чем позволяет тяжесть на этой скорости (гребень, трамплин).
func _step_vertical(g: float, hop: bool, dt: float, heights: Heightfield) -> void:
	# Перекрытие ищется от высоты до шага: подъём сквозь настил не переносит седока на мост.
	var feet0 := y
	var was_flying := airborne
	var previous_gap := air_clearance
	_step_height(g, hop, dt, heights)
	if airborne:
		var top := _roof_over(x, z, heading, feet0, heights) - BikeRecovery.CLEARANCE
		if y > top:
			# Седок упёрся в свод: подъём гаснет, дальше обычное падение до опоры.
			y = maxf(top, g)
			vy = minf(vy, 0.0)
	air_clearance = maxf(0.0, y - g) if airborne else 0.0
	clearance_closing_speed = (previous_gap - air_clearance) / dt if airborne and was_flying else 0.0


func _update_stance(dt: float, slope: float, heights: Heightfield) -> void:
	_stance_driven = true
	if airborne or not riding or crashed:
		stance = Stance.RIDING
		_stop_timer = 0.0
		return
	if absf(speed) < config.stop_enter_speed and effort < 0.05 and not _manual_reverse and absf(lean) < 0.15 and absf(slope) <= config.stop_hold_grade and absf(_ground_cross) < config.stop_dismount_cross:
		_stop_timer += dt
		if stance != Stance.FOOT_DOWN:
			foot_side = (1.0 if _ground_cross > 0.0 else -1.0) if absf(_ground_cross) > 0.03 else (1.0 if lean < -0.01 else -1.0)
		var support := foot_probe(foot_side)
		support.y = clampf(_surface(heights, support.x, support.z, y), y - config.stop_foot_max_reach, y + 0.22)
		foot_support = support
		stance = Stance.FOOT_DOWN if _stop_timer >= config.stop_settle_time else Stance.TRACKSTAND
	elif absf(speed) > config.stop_exit_speed or effort >= 0.05 or _manual_reverse or absf(slope) > config.stop_hold_grade or absf(_ground_cross) >= config.stop_dismount_cross:
		_stop_timer = 0.0
		stance = Stance.RIDING


## Горизонтальная цель опорной стопы до замера поверхности.
func foot_probe(side: float) -> Vector3:
	var lateral := side * config.stop_foot_offset
	var sin_heading := sin(heading)
	var cos_heading := cos(heading)
	return Vector3(x + cos_heading * lateral - sin_heading * STOP_FOOT_FORWARD, y,
		z - sin_heading * lateral - cos_heading * STOP_FOOT_FORWARD)


func _step_height(g: float, hop: bool, dt: float, heights: Heightfield) -> void:
	_hop_wait = maxf(0.0, _hop_wait - dt)
	# На коротком естественном отрыве ранний Space не должен ждать далёкую посадку.
	var accept_hop := hop and (not airborne or _coyote > 0.0 or (vy < 0.0 and y - g < 0.2))
	_hop_buf = config.hop_buffer if accept_hop else maxf(0.0, _hop_buf - dt)
	_coyote = maxf(0.0, _coyote - dt) if airborne else config.hop_coyote
	# На земле пробел запускает Q→E телом.
	if _hop_buf > 0.0 and _hop_wait <= 0.0 and not airborne and _auto_hop < 0.0:
		_auto_hop = 0.0
		# 20.11: буфер нарочно живёт до конца фазы «тело назад»: если колёса сойдут с гребня раньше E, ветка
		# ниже даст прыжок с запасом схода (иначе пробел перед кромкой пропадал — 14.1). Взлёт его обнуляет.
		_hop_buf = config.hop_buffer
		# Новый пробел — новый прыжок: защёлка прошлого (_hop_used ждёт возврата тела в середину) его не съедает.
		# Иначе пробел, нажатый перед приземлением после прыжка, давал только подъём переднего.
		_hop_used = false
	elif airborne and _hop_buf > 0.0 and _coyote > 0.0 and (_auto_hop < 0.0 or _auto_hop < config.auto_back) and not _hop_used:
		# Малый запас после кромки: игрок нажал вовремя, хотя колёса уже потеряли опору.
		_hop_buf = 0.0
		# 20.11: подготовка, уже набранная на земле (переднее поднято в окне hop_link), не теряется.
		var armed := _hop_link > 0.0
		_hop_front = maxf(_hop_front if armed else 0.0, config.hop_front * 0.5)
		_hop_front_v = _hop_front_v if armed else 0.0
		_takeoff_hop()
	if airborne:
		_land_settle = 0.0
		air_time += dt
		y += (vy - config.air_gravity * dt * 0.5) * dt
		vy -= config.air_gravity * dt
		if y <= g:
			_land(g, heights)
	else:
		_land_settle = maxf(0.0, _land_settle - dt)
		var fly := y + (vy - config.air_gravity * dt * 0.5) * dt
		var s0 := clampf(vy / maxf(absf(speed), 0.1), -config.cliff_grade, config.cliff_grade)
		var crest_n := 1.0 / sqrt(1.0 + s0 * s0 + _ground_cross * _ground_cross) + speed * speed * _crest_curve / config.ground_gravity
		var crest_unload := _land_settle <= 0.0 and not (_on_f >= 0 and _on_r < 0) and _pump_absorb_v <= 0.01 and absf(speed) >= config.detach_min_speed and crest_n < config.detach_normal_min
		# Земля уходит вниз быстрее падения: отрываемся с края сразу, при разгрузке на гребне или когда
		# впереди рельеф уходит из-под колёс; иначе прижимаемся к земле.
		if fly > g and (fly - g > config.drop_step or crest_unload or _lifts(heights)):
			if _pump_absorb_v > 0.0 and vy > 0.0:
				vy = maxf(0.0, vy - _pump_absorb_v * 0.45)
				fly = maxf(g + 0.001, y + (vy - config.air_gravity * dt * 0.5) * dt)
			airborne = true
			air_time = dt
			pitch_vel = clampf((vy - _gv_r) * 0.15, -1.0, 1.2)
			vy -= config.air_gravity * dt
			y = fly
		else:
			var gv := (g - y) / maxf(dt, 0.0001)
			# ступенька (въезд на настил, шов полотна) — не склон: её подъём не становится скоростью взлёта
			# При 120 Гц шов даёт вдвое больший скачок (g-y)/dt, чем при 60 Гц.
			# Ограничиваем подъём уклоном на базе колёс, сохраняя импульс настоящего склона.
			var gradient := Vector2(
				(_surface(heights, x + HUB, z, g) - _surface(heights, x - HUB, z, g)) / (2.0 * HUB),
				(_surface(heights, x, z + HUB, g) - _surface(heights, x, z - HUB, g)) / (2.0 * HUB))
			gv = minf(gv, maxf(0.0, gradient.dot(horizontal_velocity())))
			vy = gv
			y = g


## x: weighted road microheight, y: local tread weight. Obstacles are added separately.
func _wheel_road(heights: Heightfield, px: float, pz: float, surf: int, weight: float, grade: float, across: float) -> Vector2:
	var template_id := heights.world.template_id
	var bump: Vector4 = RoadBump.surface_at(surf, template_id)
	if heights.road_refinement != null:
		var contact := heights.path_contact(px, pz)
		surf = int(contact.get("surface", RoadSurface.NONE))
		weight = smoothstep(0.05, 0.9, float(contact.get("weight", 0.0)))
		across = float(contact.get("across", 0.0))
		bump = contact.get("bump", RoadBump.surface_at(surf, template_id))
		if contact.has("grade"):
			grade = contact.grade
		else:
			# Older streamed patches have the same ground but no gradient in their contact record.
			grade = Vector2(_surface(heights, px + 0.5, pz, y) - _surface(heights, px - 0.5, pz, y),
				_surface(heights, px, pz + 0.5, y) - _surface(heights, px, pz - 0.5, y)).length()
	var origin := Vector2(heights.world.world_origin) * GameConfig.TILE
	return Vector2(RoadBump.height_params(px + origin.x, pz + origin.y, bump, grade, across, RoadBump.rut_params(template_id)) * weight, weight)


## Колёса на точках касания. Подвеска колеса получает толчок, когда вертикальная скорость земли
## под ним меняется (излом, ступенька, кочка): переднее колесо встречает излом раньше заднего.
## 11.5: на полотне кочки — поле RoadBump в точке касания (то же, что видно в шейдере), вне пути — прежние.
## 11.6: поверх — кочки веток и камней на полотне (ForestObstacles.bump_at).
## Each wheel samples its own tread, rut coordinate and full terrain grade.
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
	if heights.obstacles != null:
		var clear_f := lift_f > 0.0 and gf <= _surface(heights, x + fx, z + fz, y) + lift_f + 0.01
		var clear_r := lift_r > 0.0 and gr <= _surface(heights, x - fx, z - fz, y) + lift_r + 0.01
		var was_f := _on_f
		_on_f = _wheel_hit(heights, x + fx, z + fz, gf, _sup_f, _on_f, tire_f, true, clear_f)
		if crashed:
			return
		if lift_f > 0.0 and not clear_f and _on_f != was_f:
			lift_f = 0.0 # поднято ниже препятствия — колесо встретило кромку
			lift_fv = 0.0
		var was_r := _on_r
		_on_r = _wheel_hit(heights, x - fx, z - fz, gr, _sup_r, _on_r, tire_r, false, clear_r)
		if lift_r > 0.0 and not clear_r and _on_r != was_r:
			lift_r = 0.0
			lift_rv = 0.0
	_sup_f = gf
	_sup_r = gr
	gf -= minf(lift_f, maxf(0.0, gf - _surface(heights, x + fx, z + fz, y)))
	gr -= minf(lift_r, maxf(0.0, gr - _surface(heights, x - fx, z - fz, y)))
	# мелкие кочки (только вверх, колесо не тонет в земле): заднее колесо проходит ту же кочку на базу позже
	var front := _wheel_road(heights, x + fx, z + fz, surf, path_weight, grade, across)
	var rear := _wheel_road(heights, x - fx, z - fz, surf, path_weight, grade, across)
	var bump_f := config.bump_height * rough * (1.0 - front.y) * _bump(_dist + HUB) + front.x
	var bump_r := config.bump_height * rough * (1.0 - rear.y) * _bump(_dist - HUB) + rear.x
	# 11.6: ветки и камни на полотне (RoadObstacles) — та же кочка, только с места препятствия
	var of := 0.0
	var orr := 0.0
	if heights.obstacles != null:
		of = heights.obstacles.bump_at(x + fx, z + fz)
		orr = heights.obstacles.bump_at(x - fx, z - fz)
	bump_f += of
	bump_r += orr
	# Поднятое колесо касается кочки, только если она выше подъёма: удар, сопротивление, скользкость
	# и толчок подвески — от той части кочки, что выше колеса. Колесо видно на подъёме или на кочке.
	var touch_f := lift_f <= 0.0 or bump_f > lift_f
	var touch_r := lift_r <= 0.0 or bump_r > lift_r
	# (колея RoadBump бывает ниже нуля: колесо на земле повторяет её, как прежде)
	var feel_f := bump_f if lift_f <= 0.0 else maxf(0.0, bump_f - lift_f)
	var feel_r := bump_r if lift_r <= 0.0 else maxf(0.0, bump_r - lift_r)
	ground_f = gf + lift_f + feel_f - y
	ground_r = gr + lift_r + feel_r - y
	gf += feel_f
	gr += feel_r
	# колесо на корне или камне скользкое: держит хуже, тормоз и поворот на нём — риск
	slick_f = config.root_grip if touch_f and of > config.slick_bump else 1.0
	slick_r = config.root_grip if touch_r and orr > config.slick_bump else 1.0
	if _fresh:
		_fresh = false
		_g_f = gf
		_g_r = gr
		_gv_f = vy
		_gv_r = vy
		_o_f = of
		_o_r = orr
		return
	# Колесо, которое взбирается на корень или камень, тормозит велосипед: энергию подъёма забирает
	# подвеска (как демпфер, ∝ скорости подъёма²).
	var rise_f := maxf(0.0, of - _o_f) / maxf(dt, 0.0001) if touch_f else 0.0
	var rise_r := maxf(0.0, orr - _o_r) / maxf(dt, 0.0001) if touch_r else 0.0
	_o_f = of
	_o_r = orr
	if rise_f + rise_r > 0.0:
		speed = signf(speed) * sqrt(maxf(0.0, speed * speed - 2.0 * config.bump_drag * (rise_f * rise_f + rise_r * rise_r) * dt))
	var vf := (gf - _g_f) / maxf(dt, 0.0001)
	var vr := (gr - _g_r) / maxf(dt, 0.0001)
	# колесо поднимается вместе с землёй сразу, рама — через пружину: разница и есть сжатие
	squash_fv += clampf(vf - _gv_f, -config.kick_max, config.kick_max)
	squash_rv += clampf(vr - _gv_r, -config.kick_max, config.kick_max)
	# камень или корень, на который колесо взбирается боком, толкает его в сторону от своей вершины
	if heights.obstacles != null and (of > config.slick_bump or orr > config.slick_bump):
		var velocity_before := horizontal_velocity()
		var right := Vector2(cos(heading), -sin(heading)) * config.rock_probe
		var push := 0.0
		if touch_f and of > config.rock_steer_min_bump:
			var rock_f := (heights.obstacles.bump_at(x + fx + right.x, z + fz + right.y) - heights.obstacles.bump_at(x + fx - right.x, z + fz - right.y)) / (2.0 * config.rock_probe)
			var up_f := clampf(vf - _gv_f, 0.0, config.kick_max)
			var bump_scale := smoothstep(config.rock_steer_min_bump, config.rock_steer_min_bump + 0.05, of)
			push += rock_f * up_f * bump_scale
			var yaw_kick := clampf(rock_f * up_f * config.rock_steer * bump_scale / maxf(absf(speed), 3.0) * signf(speed) * 4.0, -config.rock_yaw_kick_max, config.rock_yaw_kick_max)
			_yaw_rate += yaw_kick
			fork_side_impulse += clampf(-yaw_kick * 0.45, -1.2, 1.2)
		if touch_r and orr > config.slick_bump:
			var rock_r := (heights.obstacles.bump_at(x - fx + right.x, z - fz + right.y) - heights.obstacles.bump_at(x - fx - right.x, z - fz - right.y)) / (2.0 * config.rock_probe)
			push += rock_r * clampf(vr - _gv_r, 0.0, config.kick_max)
		speed = velocity_before.dot(Vector2(-sin(heading), -cos(heading)))
		lateral_speed = velocity_before.dot(Vector2(cos(heading), -sin(heading))) - push * config.rock_deflect
	_g_f = gf
	_g_r = gr
	_gv_f = vf
	_gv_r = vr


## Колесо и препятствие: в такт, когда колесо встало на новое препятствие (другой id — и соседний камень без
## промежутка), удар о кромку отнимает у колеса скорость, с которой оно шло на препятствие (проекция скорости на
## направление к нему: косой заход бьёт слабее и сдвигает вдоль бревна), 1 − cos(угла встречи) — угол дуги колеса над
## кромкой в точке касания (ForestObstacles.wheel_contact) от высоты, на которой колесо ехало, за вычетом уклона
## земли. Раму тормозит на долю массы этого колеса (нагрузка шины). Угол — из геометрии, не из шага движения: не
## зависит от скорости и частоты тактов. Переднее колесо, потерявшее вдоль рамы больше ENDO_DV (лёгкое — меньше),
## бросает седока через руль. Возвращает id препятствия под колесом (-1 — на земле).
func _wheel_hit(heights: Heightfield, px: float, pz: float, support: float, before: float, on_id: int, load: float, front: bool, clear := false) -> int:
	var ground := _surface(heights, px, pz, y)
	if support <= ground + 0.005:
		return -1
	var hit := heights.obstacles.wheel_contact(px, pz, WHEEL_R, ForestObstacles.CLIMB_MAX, minf(before, support) if on_id >= 0 else ground)
	if hit.is_empty():
		return -1
	if clear: return -1
	if hit.id == on_id or _fresh:
		return hit.id # то же препятствие, колесо опустилось на него сверху (приземление) или прошло над ним поднятым
	var angle: float = hit.angle - atan(maxf(0.0, _ground_slope(heights) * signf(speed)))
	if angle < config.impact_angle:
		return hit.id
	if front: impacts.x += 1
	else: impacts.y += 1
	var velocity := horizontal_velocity()
	var into: Vector2 = -hit.normal if hit.normal != Vector2.ZERO else velocity.normalized()
	var approach := maxf(0.0, velocity.dot(into))
	var share := clampf(load, 0.05, 1.0)
	var strike := into * approach * (1.0 - cos(minf(angle, PI * 0.5))) * share
	var travel := clampf(config.sag_max - (squash_f if front else squash_r), 0.0, config.sag_max + config.stretch_max)
	var soak := config.edge_soak * pow(minf(1.0, travel / maxf(float(hit.get("rise", 0.0)), 0.02)), 1.5)
	var forward := Vector2(-sin(heading), -cos(heading))
	var side := Vector2(-forward.y, forward.x)
	var dv := strike - forward * strike.dot(forward) * soak
	var endo := dv.dot(forward) / (config.endo_reference_load * config.endo_dv)
	# Диагностика последней встречи с кромкой (стенды): что именно ударило и насколько близко к порогу
	last_hit = {front = front, angle = angle, approach = approach, share = share, dv = dv.length(), soak = soak, rise = hit.get("rise", 0.0),
		endo = endo, ground = ground, support = support, vy = vy, lift = lift_f if front else lift_r}
	if front and endo > 1.0:
		_crash(vy, Vector3(-sin(heading), 0.6, -cos(heading)), CrashCause.OBSTACLE)
		return hit.id
	# импульс вычитается из вектора скорости (и при заднем ходе), но не разворачивает движение через препятствие
	var after := velocity - dv
	if after.dot(into) < 0.0: after -= into * after.dot(into)
	speed = after.dot(forward)
	lateral_speed = after.dot(side)
	# принятая ходом часть удара сжимает подвеску сильнее: быстрый наезд на кромку бьёт вилку в упор (стук пробоя)
	var kick := strike.length() / share * (0.3 + 0.4 * soak)
	if front: hit_dv.x = dv.length()
	else: hit_dv.y = dv.length()
	# событие удара колеса — отдельно от приземления и пробоя: у переднего и заднего своя реакция
	if front:
		wheel_impact.x = maxf(wheel_impact.x, strike.length() / share)
		fork_side_impulse -= dv.dot(side) / share
	else: wheel_impact.y = maxf(wheel_impact.y, strike.length() / share)
	if front:
		squash_fv += kick
	else:
		squash_rv += kick
	return hit.id


## Кочка под колесом на отметке пути d, 0..1
static func _bump(d: float) -> float:
	var n := sin(d * 2.3) * 0.6 + sin(d * 5.9 + 1.3) * 0.4
	return maxf(0.0, n) ** 2


## Две пружины-демпфера, вилка и задний ход. Короткие подшаги не дают раскачки от длинного такта.
## load — сжатие от поворота, contact_accel — продольная сила в пятнах контакта (тяга минус тормоз), м/с²: перенос
## нагрузки между осями. Не итоговое изменение скорости: тормоз, держащий скорость на спуске, всё так же сжимает
## вилку, а потеря хода в подъём без тормоза её не сжимает (тяжесть приложена к центру масс, не к колёсам).
func _step_suspension(dt: float, load := 0.0, contact_accel := 0.0) -> void:
	var target := config.air_sag_target if airborne else load
	var shift := 0.0 if airborne else contact_accel * config.pitch_load
	# step() уже дробит шаг до 1/SUB_HZ; допуск тот же, что там, — погрешность деления не даёт лишнего витка
	var ticks := ceili(dt * SUB_HZ) if dt > 1.0 / SUB_HZ + 0.000001 else 1
	var h := dt / ticks
	var f := Vector2(squash_f, squash_fv)
	var r := Vector2(squash_r, squash_rv)
	for i in ticks:
		var hit := f.y
		f = _spring(f, target - shift, h)
		if f.x >= config.sag_max and hit > config.bottom_out_speed:
			bottom_out = maxf(bottom_out, hit)
		r = _spring(r, target + shift, h)
	_rest_f = target - shift
	_rest_r = target + shift
	squash_f = f.x
	squash_fv = f.y
	squash_r = r.x
	squash_rv = r.y
	squash = (squash_f + squash_r) * 0.5


## Подшаг одной пружины: s — ход и скорость сжатия; упоры на sag_max и stretch_max
func _spring(s: Vector2, target: float, h: float) -> Vector2:
	var damp := config.spring_damp_comp if s.y >= 0.0 else config.spring_damp_rebound
	s.y += (config.spring_k * (target - s.x) - damp * s.y) * h
	s.x += s.y * h
	if s.x > config.sag_max:
		s = Vector2(config.sag_max, minf(s.y, 0.0))
	elif s.x < -config.stretch_max:
		s = Vector2(-config.stretch_max, maxf(s.y, 0.0))
	return s


## Нагрузка колёс после подвески (модель двух контактов): вес по нормали с кривизной профиля (vertical_g),
## перенос между осями от тормоза, уклона и корпуса (Brakes.front_load) и сила пружины сверх равновесия —
## удар о корень прижимает колесо, отскок разгружает. В полёте нагрузки нет.
func _step_contacts(grade: float, dt: float) -> void:
	# E завершает движение даже если Q ещё не успели отпустить.
	var target := -1.0 if body_forward else (1.0 if body_back else 0.0)
	if _auto_hop >= 0.0:
		_auto_hop += dt
		target = config.auto_strength if _auto_hop < config.auto_back else (-config.auto_strength if _auto_hop < config.auto_back + config.auto_forward else 0.0)
		if _auto_hop > config.auto_back + config.auto_forward + 0.2: _auto_hop = -1.0
	body_v = clampf(body_v + (config.body_k * (target - body_x) - config.body_d * body_v) * dt, -config.body_rate, config.body_rate)
	body_x += body_v * dt
	if absf(body_x) > 1.0:
		body_x = signf(body_x)
		body_v = 0.0
	unweight = config.body_hold * body_x + config.body_push * body_v
	_hop_link = maxf(0.0, _hop_link - dt)
	if absf(body_x) < 0.2 and absf(body_v) < 0.8 and is_zero_approx(target):
		_hop_used = false
	if not _hop_used:
		if not airborne and lift_f >= config.hop_arm_height and target > 0.0:
			if _hop_link <= 0.0:
				_hop_front = 0.0
				_hop_front_v = 0.0
			_hop_link = config.hop_link
			_hop_front = maxf(_hop_front, lift_f)
			_hop_front_v = maxf(_hop_front_v, lift_fv)
		# Сохраняем подготовку на коротком отрыве у гребня. В затяжном полёте второго прыжка нет.
		var pressing := not airborne and lift_f <= 0.0 and pump_active > 0.15
		if target < 0.0 and body_v < -1.2 and _hop_link > 0.0 and (not airborne or _coyote > 0.0) and not pressing:
			_takeoff_hop()
	if airborne:
		pump_accel = 0.0
		pump_load = 0.0
		_pump_reach = 0.0
		_pump_absorb_v = 0.0
		load_f = 0.0
		load_r = 0.0
		tire_f = 0.0
		tire_r = 0.0
		side_f = 0.0
		side_r = 0.0
		_landing_grip = config.landing_grip
		lift_f = 0.0
		lift_fv = 0.0
		lift_r = 0.0
		lift_rv = 0.0
		if _hop_used: hop_height = maxf(hop_height, y - _hop_from)
		return
	# Вираж прижимает: в повороте по наклонному полотну часть центростремительного ускорения давит в склон,
	# a·sinθ (контруклон — наоборот, разгружает). Тяжесть вдоль склона учтена в _step_turn и _step_traction.
	var press := _bank_press()
	var normal := maxf(0.0, 1.0 / sqrt(1.0 + grade * grade + _ground_cross * _ground_cross) + vertical_g + press + pump_load)
	# Перенос нагрузки между осями идёт через наклон рамы и ход вилки, а не мгновенно
	var share_goal := 0.0 if lift_f > 0.0 else (1.0 if lift_r > 0.0 else clampf(brakes.front_load, 0.0, 1.0))
	_share = lerpf(_share, share_goal, 1.0 - exp(-dt / config.pitch_transfer))
	var share := _share
	var spring_f := (config.spring_k * (squash_f - _rest_f) + config.spring_damp_comp * config.contact_damp * squash_fv) / config.ground_gravity
	var spring_r := (config.spring_k * (squash_r - _rest_r) + config.spring_damp_comp * config.contact_damp * squash_rv) / config.ground_gravity
	var raw_f := clampf(share * normal + config.contact_spring * spring_f, 0.0, config.load_max)
	var raw_r := clampf((1.0 - share) * normal + config.contact_spring * spring_r, 0.0, config.load_max)
	# Седок компенсирует перенос веса, готовя рывок: одинаковый Q/E работает и вверх, и вниз.
	_step_lift(normal * 0.5, normal * 0.5, unweight * normal, dt)
	if lift_f > 0.0:
		raw_r = minf(raw_r + raw_f, config.load_max)
		raw_f = 0.0
	elif lift_r > 0.0:
		raw_f = minf(raw_f + raw_r, config.load_max)
		raw_r = 0.0
	else:
		# седок переносит вес: сколько снято с одного колеса, столько легло на другое
		var moved := clampf(unweight * normal, -raw_r, raw_f)
		raw_f = minf(raw_f - moved, config.load_max)
		raw_r = minf(raw_r + moved, config.load_max)
	var kc := 1.0 - exp(-dt / config.tire_comply)
	load_f = lerpf(load_f, raw_f, kc)
	load_r = lerpf(load_r, raw_r, kc)
	var k := 1.0 - exp(-dt / maxf(config.tire_relax_min, config.tire_relax / maxf(absf(speed), 0.5)))
	# сила шины набирается по пути, но не больше того, что колесо сейчас несёт: разгруженное колесо силы не даёт
	tire_f = minf(lerpf(tire_f, load_f, k), load_f)
	tire_r = minf(lerpf(tire_r, load_r, k), load_r)
	var ks := 1.0 - exp(-dt / config.side_relax)
	side_f = minf(lerpf(side_f, tire_f, ks), tire_f)
	side_r = minf(lerpf(side_r, tire_r, ks), tire_r)
	if _landing_grip > 0.0:
		# колесо встало на землю: шину прижало, она держит столько, сколько несёт (нагрузка — через tire_comply)
		_landing_grip = maxf(0.0, _landing_grip - dt)
		tire_f = load_f
		tire_r = load_r
		side_f = load_f
		side_r = load_r


## Подъём колёс рывком тела: pull — доля веса, которую тело снимает с переднего колеса (меньше нуля — с заднего),
## weight_f / weight_r — веса, которые колёса несут. Сверх веса колесо идёт вверх, иначе опускается обратно.
## Последовательность Q→E собирается в _step_contacts; сам подъём одного колеса не запускает прыжок.
func _step_lift(weight_f: float, weight_r: float, pull: float, dt: float) -> void:
	var g := config.ground_gravity
	# 30.10: на подъёме волны и на гребне Q — поглощение: руки сгибаются навстречу земле, переднее не отрывается (памп,
	# а не подготовка прыжка). На обратном склоне и ровном Q поднимает переднее, как прежде; пробел (авто Q→E) — всегда.
	if _auto_hop < 0.0 and pull > 0.0:
		pull *= 1.0 - minf(1.0, pump_active * 2.0) * smoothstep(-config.pump_wave_press * 0.5, config.pump_wave_press * 0.5, pump_wave)
	# рывок поднимает колесо, пока сильнее его веса; дальше оно летит и падает обратно с ускорением свободного падения
	if pull > weight_f: lift_fv = minf(config.lift_rate_f, lift_fv + (pull - weight_f) * g * config.lift_gain_f * dt)
	elif lift_f > 0.0: lift_fv -= g * dt
	# на волне рывок вперёд при опущенном переднем продавливает велосипед (памп), а не отрывает заднее
	var rear_gain := config.lift_gain_r * (1.0 - minf(1.0, pump_active * 2.0) if lift_f <= 0.0 else 1.0)
	if -pull > weight_r and rear_gain > 0.0: lift_rv += (-pull - weight_r) * g * rear_gain * dt
	elif lift_r > 0.0: lift_rv -= g * dt
	lift_f += lift_fv * dt
	lift_r += lift_rv * dt
	if lift_f <= 0.0:
		if lift_fv < -0.5: squash_fv += -lift_fv * 0.4 # колесо опустилось — подвеска принимает
		lift_f = 0.0
		lift_fv = maxf(lift_fv, 0.0) if pull > weight_f else 0.0
	if lift_r <= 0.0:
		if lift_rv < -0.5: squash_rv += -lift_rv * 0.4
		lift_r = 0.0
		lift_rv = maxf(lift_rv, 0.0) if -pull > weight_r else 0.0
	# На скорости в дуге седок ограничивает ручной подъём, сохраняя запас для Q→E.
	var turning := smoothstep(0.15, 0.45, absf(steer)) * smoothstep(6.0, 12.0, absf(speed))
	var front_limit := lerpf(config.lift_max, config.lift_turn_max, turning)
	if lift_f >= front_limit:
		lift_f = front_limit
		lift_fv = minf(lift_fv, 0.0)
	if lift_r >= config.lift_max:
		lift_r = config.lift_max
		lift_rv = minf(lift_rv, 0.0)
	if lift_f > 0.0 and lift_r > 0.0 and _hop_link <= 0.0:
		lift_r = 0.0
		lift_rv = 0.0


## Q поднял переднее, E подтягивает заднее. Высота зависит от подготовки, окно не требует точности до кадра.
func _takeoff_hop() -> void:
	_auto_hop = -1.0
	_hop_buf = 0.0
	_hop_wait = config.hop_buffer
	_land_settle = 0.0
	airborne = true
	air_time = 0.0
	pitch_vel = 0.5
	_coyote = 0.0
	_hop_from = y
	hop_height = 0.0
	var quality := clampf(_hop_front / config.hop_front, 0.0, 1.0)
	var rise := minf((lift_f + lift_r) * 0.5, 0.12 if vy > 0.5 else config.lift_max)
	y += rise
	ground_f -= rise
	ground_r -= rise
	# Сохраняем движение вдоль спуска: прыжок считается относительно полотна, без катапульты вниз по склону.
	var carry := lerpf(config.hop_carry, config.hop_carry * 0.5, smoothstep(0.1, 0.5, absf(vertical_g)))
	vy = minf(vy, carry) + config.hop_pop * lerpf(0.8, 1.0, quality) + maxf(0.0, _hop_front_v) * 0.35
	lift_f = 0.0
	lift_fv = 0.0
	lift_r = 0.0
	lift_rv = 0.0
	_hop_link = 0.0
	_hop_used = true


## Колесо держит: стоит на земле и нагружено
func contact_f() -> bool:
	return not airborne and lift_f <= 0.0 and load_f > config.contact_min


func contact_r() -> bool:
	return not airborne and lift_r <= 0.0 and load_r > config.contact_min


## Продольное движение: тяга педалей, склон, качение и сопротивление на скорости.
func _step_speed(throttle: float, boost: bool, slope: float, terrain: float, dt: float, grip := 1.0, technical := 0.0, roll_terrain := -1.0, ground_slope := NAN) -> void:
	if dt > 1.0 / SUB_HZ + 0.000001:
		var ticks := ceili(dt * SUB_HZ)
		for i in ticks:
			_step_speed(throttle, boost, slope, terrain, dt / ticks, grip, technical, roll_terrain, ground_slope)
		return
	_step_effort(maxf(throttle, 0.0), dt)
	var top := config.cruise_speed * terrain
	var rolling := config.roll_resistance / maxf(terrain if roll_terrain < 0.0 else roll_terrain, 0.25)
	# Воздух не становится плотнее над камнями или травой; покрытие влияет на качение.
	var drag := config.air_drag + config.speed_loss
	var gravity := -config.ground_gravity * slope / (1.0 + slope * slope) + pump_accel
	var loads := Vector2(tire_f * slick_f if contact_f() else 0.0, tire_r * slick_r if contact_r() else 0.0)
	brakes.step(dt, maxf(0.0, -throttle), speed, slope, grip, _corner_demand, true, loads, body_x, _ground_cross)
	braking = 0.0
	# Пауза заднего хода отсчитывается у остановки, а не во время торможения с разгона. Тормоз, зажатый на ходу,
	# так и заканчивается стоянкой: задний ход — повторным нажатием (отпустить и снова держать).
	if throttle > -config.reverse_input:
		_reverse_armed = true
	elif speed > 0.05:
		_reverse_armed = false
	if throttle <= -config.reverse_input and absf(speed) < 0.05 and _reverse_armed:
		_brake_hold += dt
	elif throttle > -config.reverse_input or speed > 0.05:
		_brake_hold = 0.0
	_manual_reverse = throttle < 0.0 and ((_manual_reverse and speed < -0.05) or _brake_hold >= config.reverse_wait)
	if _manual_reverse:
		# Медленный манёвр назад остаётся предсказуемым и на склоне.
		speed = move_toward(speed, -config.reverse_speed * absf(throttle), config.pedal_accel * dt)
		brakes.limit(0.0)
		return
	# Автобаланс и статический тормоз: не сползаем, пока игрок обдумывает задний ход.
	if throttle < 0.0 and absf(speed) < 0.05:
		speed = 0.0
		brakes.limit(0.0)
		return
	if speed < 0.0:
		if throttle > 0.0:
			speed = move_toward(speed, 0.0, config.pedal_accel * dt)
		elif throttle < 0.0:
			speed = move_toward(speed, 0.0, (brakes.deceleration + rolling + drag * speed * speed) * dt)
		elif slope > config.stop_hold_grade:
			speed += gravity * dt
			speed = move_toward(speed, 0.0, (rolling + drag * speed * speed) * dt)
		else:
			speed = move_toward(speed, 0.0, (rolling + drag * speed * speed) * dt)
		return
	var drive := 0.0
	var request := 0.0
	if throttle > 0.0:
		var power := surge if surge >= 0.0 else (1.0 if boost else 0.0)
		var hill := slope if is_nan(ground_slope) else ground_slope
		var surge_hill := 1.0 - smoothstep(0.10, 0.35, maxf(hill, 0.0)) * config.surge_climb_taper
		var cruise := top * throttle
		top *= lerpf(1.0, config.boost_mult, power * surge_hill) * throttle
		var ratio := maxf(speed, 0.0) / maxf(top, 0.1)
		# Уверенный старт и плавное ослабление тяги; скорость спуска не срезается до top.
		var push := config.pedal_accel * config.pedal_push_mult
		var taper := maxf(0.1, push / (rolling + drag * top * top) - 1.0)
		drive = push / (1.0 + taper * ratio * ratio) * effort
		# 15.0: в гору педали тянут сильнее — по истинному уклону земли, а не корням/камням.
		var uphill := config.ground_gravity * maxf(hill, 0.0) / (1.0 + hill * hill)
		drive += config.climb_assist * uphill * effort * (1.0 - smoothstep(0.8, 1.0, maxf(speed, 0.0) / maxf(cruise, 0.1)))
		if surge > 0.0:
			# 15.0: прилив сил — заметный толчок, на крутом подъёме ослабевает, чтобы не выстреливать с вершины.
			drive += config.surge_push * surge * effort * surge_hill * (1.0 - smoothstep(0.85, 1.0, ratio))
		if power > 0.0:
			# Shift помогает дожать крутой подъём на малой скорости, без переключения передач.
			drive += config.boost_climb_push * power * smoothstep(0.08, 0.35, slope) * (1.0 - smoothstep(3.0, 9.0, speed)) * effort * grip
		request = drive
		drive = _rear_drive(drive, grip)
	# Кочки съедают ход только при быстром проезде. На длинном спуске воздух мягко
	# сдерживает разгон выше high_speed_drag_from, не обрезая накопленную скорость на пороге.
	var rough_loss_now := config.speed_loss * speed * speed + technical * config.technical_loss_k + config.high_speed_drag_k * pow(maxf(speed - config.high_speed_drag_from, 0.0), 2.0)
	var resistance := rolling + config.air_drag * speed * speed + rough_loss_now
	_sub[T_DRIVE_REQUEST] = request
	_sub[T_DRIVE] = drive
	_sub[T_ROLL] = rolling
	_sub[T_AIR] = config.air_drag * speed * speed
	_sub[T_ROUGH] = rough_loss_now
	_sub[T_SLOPE] = gravity - pump_accel
	_sub[T_PUMP] = pump_accel
	if brake_pressure > 0.001:
		var force := brakes.deceleration
		var before_brake := maxf(0.0, speed + (drive + gravity) * dt)
		speed = move_toward(before_brake, 0.0, (force + resistance) * dt)
		brakes.limit(minf(force, maxf(0.0, before_brake / dt - resistance)))
		braking = clampf(brake_deceleration / config.brake_decel, 0.0, 1.0) * smoothstep(0.3, 3.0, before_brake)
		_sub[T_BRAKE_F] = brakes.front_force
		_sub[T_BRAKE_R] = brakes.rear_force
	elif stance == Stance.FOOT_DOWN and throttle <= 0.0 and absf(slope) <= config.stop_hold_grade and absf(_ground_cross) < config.stop_dismount_cross:
		speed = move_toward(speed, 0.0, config.ground_gravity * 0.8 * dt)
	else:
		speed += (drive + gravity) * dt
		speed = move_toward(speed, 0.0, resistance * dt)
		# На пологих склонах новичок не ловит самопроизвольный откат; на крутом (>30%) без тормоза катится назад.
		if absf(slope) <= config.stop_hold_grade:
			speed = maxf(0.0, speed)


## Реализованная тяга педалей: только через заднее колесо на земле и в пределах его запаса сцепления.
func _rear_drive(wanted: float, grip: float) -> float:
	if wanted <= 0.0 or not contact_r():
		return 0.0
	var cap := config.base_grip() * config.rider_grip * grip * tire_r * slick_r
	var free := sqrt(maxf(0.0, cap * cap - force_r.y * force_r.y))
	var start := wanted * (1.0 - smoothstep(config.start_pace * 0.5, config.start_pace, speed))
	return minf(wanted, maxf(free, start))


## Седок падает: запомнить, с какой скоростью летел велосипед
## Первое событие падения в подшаге главное: следующие не переписывают причину, нормаль и скорость удара.
func _crash(v_up: float, normal := Vector3.UP, cause := CrashCause.FALL) -> void:
	if crashed:
		return
	crash_info = {speed = speed, lateral_speed = lateral_speed, vy = v_up, load_f = load_f, load_r = load_r, unweight = unweight}
	crashed = true
	crash_cause = cause
	crash_normal = normal.normalized() if normal.length_squared() > 0.000001 else Vector3.UP
	var velocity := horizontal_velocity()
	crash_velocity = Vector3(velocity.x, v_up, velocity.y)


## Нормаль препятствия леса (ствол, валун, бревно), которое задевает один из трёх кругов велосипеда
## с серединой в (px, pz) и курсом hd; ноль, если не задевает
func obstacle_normal(px: float, pz: float, hd: float, heights: Heightfield) -> Vector2:
	for side: float in [1.0, 0.0, -1.0]:
		var n := heights.obstacles.normal(px - sin(hd) * AXLE * side, pz - cos(hd) * AXLE * side, y, BODY_R, _climb())
		if n != Vector2.ZERO:
			return n
	return Vector2.ZERO


## Помещается ли велосипед серединой в (px, pz) с курсом hd: все три круга вдоль рамы свободны
func fits(px: float, pz: float, hd: float, w: WorldData, heights: Heightfield, allow_climb := true) -> bool:
	var climb := _climb() if allow_climb else 0.0
	# 15.1: внутри подшага мир не меняется — та же примерка (руль не повернул, доворота нет) берётся из прошлой.
	# Проверка габарита — самое дорогое в такте физики (около 40 мкс на точку в отладочной сборке).
	if _fit_memo_on and _fit_memo_w == w and px == _fit_memo[0] and pz == _fit_memo[1] and hd == _fit_memo[2] \
			and y == _fit_memo[3] and climb == _fit_memo[4] and airborne == _fit_memo_air:
		return _fit_memo_result
	var fx := -sin(hd) * AXLE
	var fz := -cos(hd) * AXLE
	var result := (PlayerState.is_passable(w, heights, px, pz, y, BODY_R, false, climb, airborne)
		and PlayerState.is_passable(w, heights, px + fx, pz + fz, y, BODY_R, false, climb, airborne)
		and PlayerState.is_passable(w, heights, px - fx, pz - fz, y, BODY_R, false, climb, airborne)
		and _roof_over(px, pz, hd, y, heights) >= y + BikeRecovery.CLEARANCE)
	if _fit_memo_on:
		_fit_memo[0] = px
		_fit_memo[1] = pz
		_fit_memo[2] = hd
		_fit_memo[3] = y
		_fit_memo[4] = climb
		_fit_memo_air = airborne
		_fit_memo_w = w
		_fit_memo_result = result
	return result


## Высота опоры (Heightfield.surface_at) внутри одного внешнего шага: подшаги и фазы зовут её в одних и тех же
## точках (опоры колёс до и после вертикали, края колёс, профиль), а мир между подшагами не меняется. 14.11: около
## 40 % выборок такта — повторы. Ключ — точные координаты; высота ног (feet) влияет только через настил моста, поэтому
## без мостов в клетке (и только у самого Heightfield, не у подменённых стендов) ответ годится для любых ног.
const _HEIGHTFIELD := preload("res://scripts/game/heightfield.gd")
var _surf_memo := {}                       # Vector2(x, z) -> номер записи (Vector2 — float32: точность сверяется ниже)
var _surf_at := PackedFloat64Array()       # x, z, feet (NAN — для любых ног)
var _surf_val := PackedFloat64Array()
var _surf_plain := false


func _surface(heights: Heightfield, px: float, pz: float, feet: float) -> float:
	if not _fit_memo_on:
		return heights.surface_at(px, pz, feet)
	var key := Vector2(px, pz)
	var at: Variant = _surf_memo.get(key)
	if at != null:
		var k: int = at
		if _surf_at[k * 3] == px and _surf_at[k * 3 + 1] == pz and (is_nan(_surf_at[k * 3 + 2]) or _surf_at[k * 3 + 2] == feet):
			return _surf_val[k]
	var value := heights.surface_at(px, pz, feet)
	var any_feet := _surf_plain and heights._cell_list(px, pz) == null
	_surf_memo[key] = _surf_val.size()
	_surf_at.append(px)
	_surf_at.append(pz)
	_surf_at.append(NAN if any_feet else feet)
	_surf_val.append(value)
	return value


# Последняя примерка габарита внутри текущего подшага (см. fits); вне подшага не используется
var _fit_memo_on := false
var _fit_memo := PackedFloat64Array([NAN, NAN, NAN, NAN, NAN])
var _fit_memo_air := false
var _fit_memo_w: WorldData = null
var _fit_memo_result := false


## Самое низкое перекрытие над рамой (середина и оси) для ног на высоте feet: свод туннеля или низ моста.
## Габарит седока — BikeRecovery.CLEARANCE, тот же, что при посадке и восстановлении.
func _roof_over(px: float, pz: float, hd: float, feet: float, heights: Heightfield) -> float:
	var fx := -sin(hd) * AXLE
	var fz := -cos(hd) * AXLE
	return minf(BikeRecovery.roof(heights, px, pz, feet),
		minf(BikeRecovery.roof(heights, px + fx, pz + fz, feet), BikeRecovery.roof(heights, px - fx, pz - fz, feet)))


## Доля скорости, которая остаётся после касания стены: moved — путь, который всё же прошли, full — весь путь за кадр
func _slide_keep(dt: float, moved: float, full: float) -> float:
	if full <= 0.0:
		return 1.0
	return 1.0 - minf(1.0, dt * config.wall_loss * (1.0 - moved / full))


## Приземление: подвеска проседает тем сильнее, чем жёстче удар; жёсткий удар гасит скорость,
## а слишком жёсткий (с высоты больше 5 м на ровное) сбрасывает седока
func _land(g: float, heights: Heightfield) -> void:
	# Нормаль — от той же опоры, что и высота g: вдоль рамы по опорам колёс (бревно, камень, настил),
	# поперёк по земле. Вектор в мировых X/Z: боком к склону важна траектория, а не курс рамы.
	var forward := Vector2(-sin(heading), -cos(heading))
	var right := Vector2(-forward.y, forward.x)
	var support_grade := _slope(heights)
	var gradient := forward * support_grade + right * (_surface(heights, x + right.x * HUB, z + right.y * HUB, g)
		- _surface(heights, x - right.x * HUB, z - right.y * HUB, g)) / (2.0 * HUB)
	var normal := Vector3(-gradient.x, 1.0, -gradient.y).normalized()
	var horizontal := horizontal_velocity()
	var incoming := Vector3(horizontal.x, vy, horizontal.y)
	var impact := maxf(0.0, -incoming.dot(normal))
	var approach_grade := gradient.dot(horizontal.normalized()) if horizontal.length_squared() > 0.0001 else 0.0
	landing_info = {air = air_time, impact = impact, speed = speed, vy = vy, pitch_error = tilt - atan(support_grade), hop = _hop_used, hop_height = hop_height if _hop_used else 0.0}
	airborne = false
	y = g
	# Седок автоматически принимает умеренную посадку ногами. Сильный удар
	# проверяется по исходной скорости: помощь не спасает от опасного недолёта.
	var absorbed := minf(1.2, impact * 0.18) * (1.0 - smoothstep(9.0, 13.0, impact))
	var felt := impact - absorbed
	land_impact = maxf(land_impact, felt)
	squash_fv = clampf(squash_fv + felt * config.landing_kick, config.squash_v_min, config.squash_v_max)
	squash_rv = clampf(squash_rv + felt * config.landing_kick, config.squash_v_min, config.squash_v_max)
	# В подъём (нос в склон) удар опаснее, чем на ровное: порог падения ниже.
	if impact > config.crash_impact - config.face_crash * clampf(approach_grade, 0.0, 1.0):
		_crash(vy, normal)
		speed = 0.0
		lateral_speed = 0.0
	elif felt > config.soft_impact:
		var keep := 1.0 - clampf((felt - config.soft_impact) * 0.05, 0.0, 0.5)
		speed *= keep
		lateral_speed *= keep
	instability = maxf(instability, clampf((felt - config.soft_impact * 0.45) / maxf(config.crash_impact - config.soft_impact * 0.45, 1.0) + absf(tilt - atan(support_grade)) * 0.35, 0.0, 1.0))
	pitch_vel = 0.0
	_land_settle = config.landing_settle * smoothstep(1.2, 4.5, impact)
	vy = gradient.dot(horizontal_velocity())
	if vy > 0.0 and impact > 1.2:
		vy *= lerpf(1.0, 0.35, smoothstep(1.2, 4.5, impact))
	_coyote = config.hop_coyote
	# Короткие подскоки и заранее нажатый прыжок не блокируют управление.
	if air_time > config.hop_wait_air:
		_hop_wait = 0.0 if _hop_buf > 0.0 else config.hop_wait
	air_time = 0.0
