class_name BikeView
extends Node3D
## Велосипед с седоком, сцена scenes/bike.tscn: стилизованная модель со скелетным седоком, смотрит вдоль -Z.
## Повторяет состояние BikeRide: место, курс, наклон, крен, вращение колёс и педалей, ход подвески.
## С 7.1 колёса стоят на своих точках касания, а вилка и задние перья тянутся к осям: видно сжатие каждого колеса.
## Ноги седока ставятся на педали (два звена: бедро и голень). Езда считается тактами физики (60 в секунду),
## а кадров бывает и 800: между двумя последними тактами модель плавно переходит (draw), иначе дёргалась бы.

const WHEEL_Y := 0.34    # высота осей колёс над землёй
const STEER_VIEW := 0.6  # поворот переднего колеса в долях угла руля (30.10: было 0,35 — поворот читался как крен)
const Lamp = preload("res://scripts/render/bike_lamp.gd")
const PACK_AT := Vector3(0.0, -0.08, 0.06) # сумка на кости Chest: у спины (+Z), низ — у поясницы
const PACK_SCALE := 0.8

# индексы состояния в tick: x, высота рамы, z, наклон, курс, крен, подвеска (средняя, вилка, зад), колёса, руль, педали
const S_X := 0
const S_BODY_Y := 1
const S_Z := 2
const S_TILT := 3
const S_HEADING := 4
const S_ROLL := 5
const S_SQUASH := 6
const S_WHEEL := 7
const S_STEER := 8
const S_CRANK := 9
const S_TUCK := 10
const S_SQUASH_F := 11
const S_SQUASH_R := 12
const S_SHIFT := 13 # корпус вперёд/назад
const S_SIDE := 14
const S_CROUCH := 15
const S_LOOK := 16
const S_SWAY := 17 # мягкое скручивание плеч в такт усилию
const S_BREATH := 18 # небольшое движение грудной клетки
const S_BODY_LOOK := 19 # плечи следуют за взглядом с небольшой задержкой
const S_STAND := 20 # 12.3: привстал (подъём, рывок) +, «атака» на спуске −
const S_HEAD_NOD := 21
const S_PACK_PITCH := 22
const S_PACK_ROLL := 23
const S_BRAKE := 24
const S_EFFORT := 25
const S_FRONT_LOAD := 26 # мгновенный приём переднего удара руками
const S_REAR_LOAD := 27  # мгновенный приём заднего удара и посадки ногами и тазом
const STATE_SIZE := 28
const ROCK := 0.09 # 12.3: раскачка велосипеда под седоком, который едет стоя, рад
const LOAD_EFFORT := 0.95 # медленная тяжёлая работа на подъёме, независимо от частоты
const AIR_CROUCH := 0.055
const LAND_CROUCH := 0.085

# состояние на двух последних тактах (индексы S_*)
var _prev := PackedFloat64Array()
var _cur := PackedFloat64Array()
var _mix := PackedFloat64Array() # буфер для draw, чтобы не выделять память на каждый кадр
var _riding := false
var _fallen := false
var _fallen_transform := Transform3D.IDENTITY
var _has_state := false
var _last_crank := 0.0
var _landing := 0.0
var _breath_phase := 0.0
var _effort := 0.0
var _hit_f := 0.0 # отклик седока на удар переднего и заднего колеса, затухает
var _hit_r := 0.0
var _recoil := 1.0 # сторона, в которую удар переднего колеса дёргает руль
var _stand := 0.0
var _was_airborne := false
var _takeoff := 0.0
var _jump_prep := 0.0
var _recovery := 0.0
var _fatigue := 0.0
var _prev_steer := 0.0
var _air_pedal_blend := 0.0
var _air_pedal_goal := PI * 0.5
var _corner_pedal_blend := 0.0
var _pack_swing := Vector2.ZERO
var _pack_velocity := Vector2.ZERO
var _shift_vel := 0.0
var _side_vel := 0.0
var _crouch_vel := 0.0
var _sway_vel := 0.0
var _head_nod_vel := 0.0
var _torso_shock := 0.0
var _torso_shock_vel := 0.0
var _pack_bag: Node3D
var _fork_lowers: Array[Node3D] = []
var _fork_parts: Array[Node3D] = []
var _fork_rest: Array[Vector3] = []
var _steering: Node3D
var _levers: Array[Node3D] = []
var _lever_rest: Array[Transform3D] = []
var _view_ready := false
# Перья подвески имеют именованные поля вместо позиционных массивов.
class Strut:
	var part: MeshInstance3D
	var fixed: Vector3
	var axle: Vector3
	var length: float

var _front_struts: Array[Strut] = []
var _rear_struts: Array[Strut] = []
var lamp: Lamp

@onready var rider: CyclistRig = get_node_or_null("Rider") as CyclistRig
@onready var rear_wheel: Node3D = get_node_or_null("RearWheel") as Node3D
@onready var front_wheel: Node3D = get_node_or_null("FrontWheel") as Node3D
@onready var crank: Node3D = get_node_or_null("Crank") as Node3D
@onready var pedal_l: Node3D = get_node_or_null("Crank/PedalL") as Node3D
@onready var pedal_r: Node3D = get_node_or_null("Crank/PedalR") as Node3D


func _ready() -> void:
	_prev.resize(STATE_SIZE)
	_cur.resize(STATE_SIZE)
	# Проверяем обязательные узлы до переподчинения деталей.
	for path: String in ["Rider", "RearWheel", "FrontWheel", "Crank", "Crank/PedalL", "Crank/PedalR", "ForkL", "ForkR", "Stem", "Handlebar", "ChainStayL", "ChainStayR", "SeatStayL", "SeatStayR"]:
		if not get_node_or_null(path) is Node3D:
			push_warning("BikeView: отсутствует узел Node3D %s; анимация отключена" % path)
			return
	if rider == null:
		push_warning("BikeView: Rider должен использовать CyclistRig; анимация отключена")
		return
	# Вилка, вынос и руль поворачиваются вместе; колесо отдельно вращается вокруг оси.
	_steering = Node3D.new()
	add_child(_steering)
	_steering.position = Vector3(0.0, 0.76, -0.415)
	for part: String in ["ForkL", "ForkR", "Stem", "Handlebar", "ForkCrown", "ForkCrownStem", "ForkArch", "GripL", "GripR", "LeverL", "LeverR", "BrakeClampL", "BrakeClampR", "CableL", "CableR", "CableReturnL", "CableReturnR"]:
		if not has_node(part):
			continue
		get_node(part).reparent(_steering)
	var front_axle := Vector3(0.0, WHEEL_Y, -BikeRide.HUB) - _steering.position
	for part: String in ["LeverL", "LeverR"]:
		if _steering.has_node(part):
			var lever := _steering.get_node(part) as Node3D
			_levers.append(lever)
			_lever_rest.append(lever.transform)
	for part: String in ["ForkL", "ForkR"]:
		var fork := _steering.get_node(part)
		if fork.has_node("Lower"):
			_fork_lowers.append(fork.get_node("Lower"))
			_fork_parts.append(fork)
			_fork_rest.append(fork.position)
		elif fork is MeshInstance3D:
			_front_struts.append(_strut(fork, front_axle))
	if _steering.has_node("ForkArch"):
		_fork_lowers.append(_steering.get_node("ForkArch"))
	if _steering.has_node("ForkCrown"):
		_fork_parts.append(_steering.get_node("ForkCrown"))
		_fork_rest.append(_steering.get_node("ForkCrown").position)
	for part: String in ["ChainStayL", "ChainStayR", "SeatStayL", "SeatStayR"]:
		_rear_struts.append(_strut(get_node(part) as MeshInstance3D, Vector3(0.0, WHEEL_Y, BikeRide.HUB)))
	for part: String in ["ChainTop", "ChainBottom"]:
		if has_node(part):
			_rear_struts.append(_strut(get_node(part), Vector3(0.085, WHEEL_Y, BikeRide.HUB)))
	lamp = Lamp.new()
	lamp.name = "Lamp"
	lamp.position = Vector3(0.0, 0.17, -0.1)
	_steering.add_child(lamp)
	_view_ready = true


## Совместимый интерфейс управления фарой из игры.
func set_lamp(on: bool) -> void:
	if is_instance_valid(lamp):
		lamp.set_enabled(on)


func lamp_on() -> bool:
	return is_instance_valid(lamp) and lamp.is_enabled()


## 11.9: сумка доставки за спиной седока (CargoBag) — на кости Chest, поэтому едет и падает вместе с ним
func set_pack(on: bool) -> void:
	if rider == null or not rider.is_rig_valid():
		return
	var pack := rider.skeleton.get_node_or_null("Pack") as BoneAttachment3D
	if pack == null and on:
		pack = BoneAttachment3D.new()
		pack.name = "Pack"
		pack.bone_name = "Chest"
		rider.skeleton.add_child(pack)
		var bag := preload("res://scripts/render/cargo_bag.gd").build()
		_pack_bag = bag
		bag.position = PACK_AT
		bag.scale = Vector3.ONE * PACK_SCALE
		pack.add_child(bag)
	if pack != null:
		pack.visible = on


## Запомнить состояние после такта физики
func tick(b: BikeRide, dt := 1.0 / 60.0, throttle := 0.0, boost := false) -> void:
	if not _view_ready:
		return
	dt = maxf(dt, 0.0) if is_finite(dt) else 0.0
	# Переиспользуем два буфера: состояние приходит 60 раз в секунду.
	if _has_state:
		var spare := _prev
		_prev = _cur
		_cur = spare
	_cur[S_X] = b.x
	# рама — посередине между концами подвесок, каждый на своём ходе над точкой касания колеса
	_cur[S_BODY_Y] = b.y + (b.ground_f + b.ground_r) * 0.5 - (b.squash_f + b.squash_r) * 0.5
	_cur[S_Z] = b.z
	_cur[S_TILT] = b.tilt
	var brake_decel := maxf(b.brake_deceleration, b.brake_force.x + b.brake_force.y)
	_cur[S_BRAKE] = maxf(b.brakes.pressure, clampf(brake_decel / GameConfig.BIKE_BRAKE, 0.0, 1.0)) if not b.airborne else 0.0
	# Pitch about the front contact point while the rear wheel unloads.
	var lift := b.brakes.lift if not b.airborne else 0.0
	_cur[S_TILT] -= lift
	_cur[S_BODY_Y] += sin(lift) * BikeRide.HUB
	_cur[S_X] += sin(b.heading) * BikeRide.HUB * (cos(lift) - 1.0)
	_cur[S_Z] += cos(b.heading) * BikeRide.HUB * (cos(lift) - 1.0)
	_cur[S_HEADING] = b.heading
	_cur[S_ROLL] = b.lean
	_cur[S_SQUASH] = b.squash
	_cur[S_SQUASH_F] = b.squash_f
	_cur[S_SQUASH_R] = b.squash_r
	_cur[S_WHEEL] = b.wheel
	_cur[S_STEER] = b.steer
	_cur[S_CRANK] = b.crank
	# В полёте педали быстро приходят к горизонтали, а в повороте накатом наружная нога опускается вниз для упора.
	# Физический crank не меняется: это стойка седока, тягу и частоту усилия не подделываем.
	if _has_state:
		if b.airborne and (not _was_airborne or _air_pedal_blend < 0.001):
			_air_pedal_goal = PI * 0.5 + roundf((b.crank - PI * 0.5) / PI) * PI
		_air_pedal_blend = lerpf(_air_pedal_blend, 1.0 if b.airborne else 0.0, Util.damp(12.0, dt))
		var crank_turning := absf(angle_difference(b.crank, _last_crank)) > 0.0005 or b.effort > 0.08
		var corner_coasting := smoothstep(0.08, 0.22, absf(b.lean)) * (0.0 if b.airborne or crank_turning else 0.78)
		_corner_pedal_blend = lerpf(_corner_pedal_blend, corner_coasting, Util.damp(8.5, dt))
		var view_crank := lerp_angle(b.crank, _air_pedal_goal, _air_pedal_blend)
		if _corner_pedal_blend > 0.0001:
			var outer_down_goal := (PI if b.lean < 0.0 else 0.0) + roundf(b.crank / TAU) * TAU
			view_crank = lerp_angle(view_crank, outer_down_goal, _corner_pedal_blend * (1.0 - _air_pedal_blend))
		_cur[S_CRANK] = view_crank
	_cur[S_TUCK] = clampf(absf(b.speed) / GameConfig.BIKE_SPEED, 0.0, 1.0) * 0.08
	_update_rider(b, dt, throttle, boost)
	# Отдача руля от удара переднего колеса — только вид: руль дёргается в сторону, курс не меняется.
	_cur[S_STEER] += _hit_f * 0.15 * _recoil
	_riding = b.riding
	_fallen = b.fallen
	_fallen_transform = b.fallen_transform
	if not _has_state:
		_prev = _cur.duplicate()
		_has_state = true


## Реакции считаются только на тактах физики; draw лишь интерполирует готовую позу.
func _update_rider(b: BikeRide, dt: float, _throttle: float, boost: bool) -> void:
	var continuous := _has_state and _riding and b.riding
	# продольное ускорение по мировой скорости за тот же такт, что и у камеры (BikeRide.feel_acceleration)
	var acceleration := clampf(b.feel_acceleration, -9.0, 7.0) if continuous else 0.0
	_last_crank = b.crank
	# Уклон земли, а не наклон рамы: подвеска и движение тела не выдают себя за подъём.
	var slope := clampf(b.grade_now, -0.5, 0.5) if not b.airborne else 0.0
	# Усилие — то же состояние, что даёт тягу (BikeRide.effort), тяжесть — реализованная тяга и подъём.
	var drive := b.effort if not b.airborne else 0.0
	var work := clampf(b.drive_force / (GameConfig.BIKE_ACCEL * 1.75), 0.0, 1.0)
	var load := smoothstep(0.04, 0.25, slope) * drive
	var effort_target := maxf(drive * 0.6 + work * 0.4, load * LOAD_EFFORT) * (1.25 if boost else 1.0)
	# Набирается вместе с тягой, без своего запаздывания; отпускание педалей не обрывает дыхание и плечи.
	if effort_target > _effort:
		_effort = effort_target if continuous else 0.0
	else:
		_effort = lerpf(_effort, effort_target, Util.damp(5.0, dt)) if continuous else 0.0
	var effort := _effort
	var braking := clampf(maxf(b.brake_deceleration, b.brake_force.x + b.brake_force.y) / GameConfig.BIKE_BRAKE, 0.0, 1.0) if not b.airborne else 0.0
	# 12.3: на крутом подъёме под нагрузкой и в рывок с места седок встаёт с седла;
	# на быстром спуске без педалей и на тряске — приподнимается и принимает удары ногами.
	var climb := smoothstep(0.07, 0.16, slope) * smoothstep(0.45, 0.85, effort) * (1.0 - smoothstep(7.0, 11.0, absf(b.speed)))
	var sprint := smoothstep(1.5, 3.5, acceleration) * (1.0 - smoothstep(6.0, 10.0, absf(b.speed))) if boost else 0.0
	var descent := smoothstep(0.06, 0.16, -slope) * (1.0 - effort) * smoothstep(4.0, 8.0, absf(b.speed))
	# Фаза 1 прыжка — подготовка (preload): сжатие перед отрывом (буфер прыжка, авто-хоп, рывок Q или волна).
	var prep_raw := (0.85 if b._hop_buf > 0.0 or b.body_back or (b._auto_hop >= 0.0 and b._auto_hop < BikeRide.AUTO_BACK) else 0.0) + maxf(0.0, b.body_v) * 0.22 + clampf(b.lift_f / 0.12, 0.0, 0.65)
	var prep_goal := clampf(prep_raw, 0.0, 1.0) if continuous and not b.airborne else 0.0
	_jump_prep = lerpf(_jump_prep, prep_goal, Util.damp(22.0 if prep_goal > _jump_prep else 10.0, dt)) if continuous else 0.0
	var stand_target := (maxf(climb, sprint) - descent if not b.airborne else -0.65) if continuous else 0.0
	if not b.airborne and b.riding and absf(b.pump_motion) > 0.01:
		stand_target = minf(stand_target, -absf(b.pump_motion) * 0.5)
	_stand = lerpf(_stand, stand_target, 1.0 - exp(-dt * (4.0 if absf(stand_target) > absf(_stand) else 2.5))) if continuous else 0.0
	var up := maxf(_stand, 0.0)
	# Передний толчок подаёт плечи назад, задний — вперёд. В воздухе и на месте реакции нет.
	var road_shift := clampf((b.squash_fv - b.squash_rv) * 0.004, -0.012, 0.012)
	road_shift *= smoothstep(0.5, 3.0, absf(b.speed)) if not b.airborne else 0.0
	# Под нагрузкой подаёмся вперёд; при торможении и спуске уходим назад.
	# 12.3: заметнее — разгон, подъём и тормоз двигают корпус до 9 см (было 5,5).
	# Тормоз заменяет обычную инерционную компенсацию, а не складывается с ней.
	# Инерцию сначала принимают руки и ноги — по силе в пятнах контакта (тяга, тормоз), а не по итоговому изменению
	# скорости: тормоз, держащий скорость на спуске, виден, а потеря хода в подъём не выглядит торможением.
	# Затем таз компенсирует перенос (brace, с запаздыванием).
	var contact := clampf(b.contact_acceleration, -9.0, 7.0) if continuous and not b.airborne else 0.0
	var arms := clampf(-contact * 0.009, -0.06, 0.08)
	var inertia_shift := arms * (1.0 - b.brakes.brace * braking) + b.brakes.brace * GameConfig.BIKE_BRAKE_SHIFT * braking
	# Удар колеса о кромку — своё событие (не приземление): переднее принимают руки — плечи коротко уходят назад,
	# заднее — ноги, таз приподнимается над седлом. Сила — по скорости удара колеса.
	_hit_f *= exp(-dt * 9.0)
	_hit_r *= exp(-dt * 9.0)
	if continuous and not b.airborne:
		if b.wheel_impact.x > 0.0:
			_recoil = 1.0 if sin((b.x + b.z) * 3.1) >= 0.0 else -1.0
		_hit_f = maxf(_hit_f, clampf(b.wheel_impact.x / 1.5, 0.0, 1.0))
		_hit_r = maxf(_hit_r, clampf(b.wheel_impact.y / 1.5, 0.0, 1.0))
	# Q/E — то же положение тела, что в физике (body_x: + назад): назад — таз к заднему колесу, руки выпрямлены и тянут
	# руль; вперёд — плечи над рулём, ноги подтягивают раму. Без своего сглаживания: окно рывка — доли секунды.
	var body := clampf(b.body_x, -1.0, 1.0) if continuous else 0.0
	var moving := smoothstep(0.5, 3.0, absf(b.speed)) if not b.airborne else 0.0
	# Фазы прыжка: 2) отрыв (_takeoff), 3) полёт (airborne), 4) приземление (_landing), 5) восстановление (_recovery).
	_takeoff *= exp(-dt * 9.5)
	if continuous and b.airborne and not _was_airborne:
		_takeoff = 1.0 if (b.vy > 0.0 or _jump_prep > 0.1 or b._hop_used) else 0.65
		_jump_prep = 0.0
	_was_airborne = b.airborne
	_landing *= exp(-dt * 5.5)
	if continuous and b.land_impact > 0.0:
		_landing = maxf(_landing, clampf(b.land_impact / 9.0, 0.0, 1.0))
		_recovery = 0.0
	var recovery_goal := _landing * 0.85 if _landing > 0.02 else 0.0
	_recovery = lerpf(_recovery, recovery_goal, Util.damp(3.5 if recovery_goal > _recovery else 6.0, dt)) if continuous else 0.0
	var rebound := maxf(0.0, _recovery - _landing * 0.72)
	# Последовательный приём нагрузки:
	# 1) Передний удар и сжатие вилки сразу принимают руки (front_load), задний удар, подготовка и приземление — ноги и таз (rear_load).
	var front_goal := clampf(_hit_f * 0.90 + maxf(0.0, b.squash_fv) * 0.14 * moving + _jump_prep * 0.25, 0.0, 1.0)
	var rear_goal := clampf(_hit_r * 0.90 + _landing * 0.85 + maxf(0.0, b.squash_rv) * 0.14 * moving + _jump_prep * 0.35, 0.0, 1.0)
	var limb_blend := Util.damp(28.0, dt)
	var front_load := maxf(_hit_f * 0.85, lerpf(_prev[S_FRONT_LOAD], front_goal, limb_blend)) if continuous else front_goal
	var rear_load := maxf(maxf(_hit_r * 0.85, _landing * 0.75), lerpf(_prev[S_REAR_LOAD], rear_goal, limb_blend)) if continuous else rear_goal
	# Приоритеты смешивания: торможение и удар подавляют раскачку педалирования, чтобы реакции не складывались в случайную позу.
	var impact_priority := clampf(front_load * 0.65 + rear_load * 0.75, 0.0, 1.0)
	var pedal_priority := (1.0 - braking * 0.85) * (1.0 - impact_priority * 0.65)
	var active_effort := effort * pedal_priority
	var air_pitch_shift := clampf(-b.vy * 0.004, -0.018, 0.018) if b.airborne else 0.0
	# 30.10: ход тела заметнее (было body · 0,1 в пределах −0,1…0,14): Q и E читаются на фоне реакций подвески
	var shift := clampf(inertia_shift - slope * 0.16 - active_effort * 0.015 + road_shift + _hit_f * 0.038 - _hit_r * 0.018 + body * 0.17 + _jump_prep * 0.022 + _takeoff * 0.038 + air_pitch_shift - rebound * 0.038, -0.17, 0.2)
	var side := clampf(-b.lean * 0.13 - b.slip * 0.10 + b.steer * 0.012 * moving + sin(b.crank) * active_effort * (0.012 + up * 0.02), -0.068, 0.068)
	# В полёте компактная стойка; на отрыве (_takeoff) седок сначала разгибается вверх из подготовки и вытягивает руль,
	# затем группируется в полёте, на приземлении глубоко гасит удар и в фазе восстановления (rebound) возвращается в стойку.
	var pedal_bob := (1.0 - cos(b.crank * 2.0)) * active_effort * 0.0045
	var rough := clampf((absf(b.squash_fv) + absf(b.squash_rv)) * 0.009, 0.0, 0.022) * moving
	var shock_crouch := _landing * (LAND_CROUCH + 0.025) + _hit_f * 0.045 + _hit_r * 0.035
	var air_crouch := (AIR_CROUCH * (1.0 - _takeoff * 0.85) - _takeoff * 0.022) if b.airborne else 0.0
	var base_crouch := rough + air_crouch + _jump_prep * 0.058 + braking * 0.04 * (1.0 - _landing * 0.5) + pedal_bob + active_effort * smoothstep(0.0, 0.12, slope) * 0.02 - rebound * 0.020
	var crouch := base_crouch + shock_crouch + maxf(body, 0.0) * 0.07
	crouch += b.pump_motion * 0.065 if not b.airborne else 0.0
	# ручной памп: поглощение (Q на волне) сгибает руки и ноги, продавливание (E) выпрямляет их в велосипед
	crouch -= b.pump_body * 0.15 if not b.airborne else 0.0
	# Опережение взглядом: учитываем руль, скорость поворота руля, угловую скорость дуги (_yaw_rate), крен и угол сноса (slip).
	var steer_vel := clampf((b.steer - _prev_steer) / maxf(dt, 0.001), -6.0, 6.0) if continuous else 0.0
	_prev_steer = b.steer
	var turn_pace := maxf(smoothstep(0.2, 3.0, absf(b.speed)), smoothstep(0.05, 0.25, absf(b.steer)))
	var dir_signal := -b.steer * 0.27 - steer_vel * 0.018 + b._yaw_rate * 0.11 + b.lean * 0.16 - b.slip * 0.32
	var look := clampf(dir_signal * turn_pace, -0.46, 0.46)
	# Плечи чуть сопровождают нажатие на педаль, таз отвечает встречным движением.
	var sway := sin(b.crank) * active_effort * (0.055 + up * 0.06)
	# Дыхание подчинено накопленной нагрузке (_fatigue): учащается и углубляется под нагрузкой, с активным вдохом,
	# и кратковременно задерживается при жёстком торможении, отрыве и приёме удара.
	var prev_fatigue := _fatigue
	var exertion := clampf(effort * 0.75 + smoothstep(0.03, 0.22, slope) * effort * 0.45 + (0.25 if boost and effort > 0.1 else 0.0) + _landing * 0.25, 0.0, 1.0)
	_fatigue = lerpf(_fatigue, exertion, Util.damp(2.2 if exertion > _fatigue else 0.85, dt)) if continuous else 0.0
	var avg_fatigue := 0.5 * (prev_fatigue + _fatigue)
	_breath_phase = fmod(_breath_phase + dt * (1.7 + avg_fatigue * 1.4), TAU) if continuous else 0.0
	var breath_wave := sin(_breath_phase) + 0.20 * _fatigue * sin(_breath_phase * 2.0 - 0.6)
	var breath_brace := 1.0 - clampf(braking * 0.35 + impact_priority * 0.50 + _takeoff * 0.45, 0.0, 0.65)
	var breath := breath_wave * (0.002 + _fatigue * 0.0016) * breath_brace if b.riding else 0.0
	# 2) Корпус реагирует с контролируемой упругостью и критическим затуханием (без резинового раскачивания),
	# отставая от мгновенной реакции рук и ног.
	if continuous:
		var shift_step := _spring_step(_prev[S_SHIFT], _shift_vel, shift, 15.0, dt)
		_cur[S_SHIFT] = shift_step.x
		_shift_vel = shift_step.y
		var side_step := _spring_step(_prev[S_SIDE], _side_vel, side, 15.0, dt)
		_cur[S_SIDE] = side_step.x
		_side_vel = side_step.y
		var crouch_step := _spring_step(_prev[S_CROUCH], _crouch_vel, crouch, 15.0, dt)
		_cur[S_CROUCH] = crouch_step.x
		_crouch_vel = crouch_step.y
		var sway_step := _spring_step(_prev[S_SWAY], _sway_vel, sway, 16.0, dt)
		_cur[S_SWAY] = sway_step.x
		_sway_vel = sway_step.y
		var shock_step := _spring_step(_torso_shock, _torso_shock_vel, _landing * 0.065 + _hit_f * 0.042 + _hit_r * 0.032, 14.0, dt)
		_torso_shock = shock_step.x
		_torso_shock_vel = shock_step.y
	else:
		_cur[S_SHIFT] = shift
		_cur[S_SIDE] = side
		_cur[S_CROUCH] = crouch
		_cur[S_SWAY] = sway
		_torso_shock = 0.0
		_shift_vel = 0.0
		_side_vel = 0.0
		_crouch_vel = 0.0
		_sway_vel = 0.0
		_torso_shock_vel = 0.0
	var look_blend := Util.damp(16.0, dt)
	_cur[S_LOOK] = lerpf(_prev[S_LOOK], look, look_blend) if continuous else look
	_cur[S_BREATH] = breath
	_cur[S_BODY_LOOK] = lerpf(_prev[S_BODY_LOOK], look, Util.damp(5.0, dt)) if continuous else look
	# назад — таз ниже седла сзади («атака»), вперёд — привстал над рамой
	_cur[S_STAND] = clampf(_stand - body * 0.55, -1.0, 1.0)
	# 3) Голова реагирует последней, принимая уже прошедшую через корпус волну удара (_torso_shock) и фазы прыжка.
	var air_look_pitch := clampf(b.vy * 0.003, -0.02, 0.02) if b.airborne else 0.0
	var head_nod_goal := clampf(-_torso_shock - _jump_prep * 0.018 + _takeoff * 0.042 + air_look_pitch + rebound * 0.015 + sin(b.crank * 2.0) * active_effort * 0.012, -0.08, 0.06)
	if continuous:
		var nod_step := _spring_step(_prev[S_HEAD_NOD], _head_nod_vel, head_nod_goal, 9.5, dt)
		_cur[S_HEAD_NOD] = nod_step.x
		_head_nod_vel = nod_step.y
	else:
		_cur[S_HEAD_NOD] = 0.0
		_head_nod_vel = 0.0
	# Движение экипировки (сумки) подчинено реальной нагрузке (разгон, удары, прыжок, приземление, крен и работа стоя)
	# и затухает без постоянного одинакового покачивания.
	var pack_pitch_goal := clampf(acceleration * 0.007 + _landing * 0.13 - _takeoff * 0.05 + (_hit_f * 0.05 - _hit_r * 0.04) + (b.squash_fv + b.squash_rv) * 0.008 * moving + absf(sway) * 0.18, -0.09, 0.14)
	var pack_roll_goal := clampf(b.lean * 0.12 + b.slip * 0.20 - sway * 0.35, -0.07, 0.07)
	if continuous:
		var pack_x := _spring_step(_pack_swing.x, _pack_velocity.x, pack_pitch_goal, 12.0, dt)
		var pack_y := _spring_step(_pack_swing.y, _pack_velocity.y, pack_roll_goal, 12.0, dt)
		_pack_swing = Vector2(pack_x.x, pack_y.x)
		_pack_velocity = Vector2(pack_x.y, pack_y.y)
	else:
		_pack_swing = Vector2.ZERO
		_pack_velocity = Vector2.ZERO
	_cur[S_PACK_PITCH] = _pack_swing.x
	_cur[S_PACK_ROLL] = _pack_swing.y
	_cur[S_EFFORT] = effort
	_cur[S_FRONT_LOAD] = front_load
	_cur[S_REAR_LOAD] = rear_load


## Критически затухающая пружина (zeta = 1): даёт инерцию массы и задержку пика без резиновых колебаний.
static func _spring_step(pos: float, vel: float, goal: float, omega: float, dt: float) -> Vector2:
	var err := pos - goal
	var k := omega * maxf(dt, 0.0)
	var d := exp(-k)
	var b := vel + omega * err
	return Vector2(goal + (err + b * dt) * d, (vel - omega * b * dt) * d)


## Перенестись в текущее состояние без перехода (поставили велосипед, сели или слезли)
func snap(b: BikeRide) -> void:
	if not _view_ready:
		return
	# Не переносим ускорение и удар через посадку, спешивание или телепорт.
	_has_state = false
	_landing = 0.0
	_breath_phase = 0.0
	_effort = 0.0
	_fatigue = 0.0
	_hit_f = 0.0
	_hit_r = 0.0
	_stand = 0.0
	_takeoff = 0.0
	_jump_prep = 0.0
	_recovery = 0.0
	_prev_steer = b.steer
	_air_pedal_blend = 0.0
	_corner_pedal_blend = 0.0
	_was_airborne = b.airborne
	_pack_swing = Vector2.ZERO
	_pack_velocity = Vector2.ZERO
	_shift_vel = 0.0
	_side_vel = 0.0
	_crouch_vel = 0.0
	_sway_vel = 0.0
	_head_nod_vel = 0.0
	_torso_shock = 0.0
	_torso_shock_vel = 0.0
	tick(b)
	for i in STATE_SIZE:
		_prev[i] = _cur[i]


## Показать модель в доле alpha (0..1) пути от предпоследнего такта к последнему
func draw(alpha: float) -> void:
	if not _has_state:
		return
	if _fallen:
		global_transform = _fallen_transform
		rider.visible = false
		return
	alpha = clampf(alpha, 0.0, 1.0) if is_finite(alpha) else 0.0
	_mix.resize(_cur.size())
	for i in _cur.size():
		# курс и углы колёс и педалей идут через полный оборот: переход по короткой дуге
		var angular := i == S_HEADING or i == S_WHEEL or i == S_CRANK
		_mix[i] = lerp_angle(_prev[i], _cur[i], alpha) if angular else lerpf(_prev[i], _cur[i], alpha)
	# рама и седок опускаются на ход подвески, колёса остаются на земле
	position = Vector3(_mix[S_X], _mix[S_BODY_Y], _mix[S_Z])
	# 12.3: стоя седок раскачивает велосипед под собой в такт педалям (только вид)
	rotation = Vector3(_mix[S_TILT], _mix[S_HEADING], _mix[S_ROLL] + sin(_mix[S_CRANK]) * maxf(_mix[S_STAND], 0.0) * ROCK)
	rear_wheel.position.y = WHEEL_Y + _mix[S_SQUASH_R]
	front_wheel.position.y = WHEEL_Y + _mix[S_SQUASH_F]
	for st: Strut in _front_struts:
		_stretch(st, _mix[S_SQUASH_F])
	for st: Strut in _rear_struts:
		_stretch(st, _mix[S_SQUASH_R])
	for lower in _fork_lowers:
		# ForkArch был переподчинён с сохранением мирового положения; его исходная позиция — -pivot.
		lower.position = Vector3(0, _mix[S_SQUASH_F], 0) if lower.name == "Lower" else -_steering.position + Vector3(0, _mix[S_SQUASH_F], 0)
	if has_node("RearMechanics"):
		get_node("RearMechanics").position.y = _mix[S_SQUASH_R]
	rear_wheel.rotation.x = -_mix[S_WHEEL]
	front_wheel.rotation.x = -_mix[S_WHEEL]
	front_wheel.rotation.y = -_mix[S_STEER] * STEER_VIEW
	for i in _levers.size():
		_levers[i].transform = _lever_rest[i] * Transform3D(Basis(Vector3.UP, _mix[S_BRAKE] * (0.28 if i == 0 else -0.28)), Vector3.ZERO)
	_steering.rotation.y = front_wheel.rotation.y
	# Рейк не должен отрывать штаны вилки от оси при рулении: сохраняем прежний центр колеса.
	var axle := Vector3(0, WHEEL_Y, -BikeRide.HUB) - _steering.position
	var fork_offset := _steering.basis.inverse() * axle - axle
	for i in _fork_parts.size():
		_fork_parts[i].position = _fork_rest[i] + fork_offset
	if _steering.has_node("ForkArch"):
		_steering.get_node("ForkArch").position += fork_offset
	if _steering.has_node("ForkCrownStem"):
		var link := _steering.get_node("ForkCrownStem") as MeshInstance3D
		var start := Vector3(0, 0.70, -BikeRide.HUB) - _steering.position + fork_offset
		var along := -start
		link.transform = Transform3D(Basis(Quaternion(Vector3.UP, along.normalized())) * Basis.from_scale(Vector3(1, along.length() / (link.mesh as CylinderMesh).height, 1)), start * 0.5)
	crank.rotation.x = -_mix[S_CRANK]
	# педали держатся горизонтально
	pedal_l.rotation.x = _mix[S_CRANK]
	pedal_r.rotation.x = _mix[S_CRANK]
	rider.visible = _riding
	if _riding:
		# Небольшая группировка на скорости и работа корпусом при сжатии подвески.
		var tuck := _mix[S_TUCK] + clampf(_mix[S_SQUASH], 0.0, 0.12) * 0.4
		var grip_l := _steering.position + _steering.basis * Vector3(-0.24, 0.22, -0.015)
		var grip_r := _steering.position + _steering.basis * Vector3(0.24, 0.22, -0.015)
		var motion := Vector3(_mix[S_SHIFT], _mix[S_SIDE], _mix[S_CROUCH])
		rider.pose(_mix[S_CRANK], tuck, grip_l, grip_r, motion, _mix[S_LOOK], _mix[S_TILT], _mix[S_ROLL], _mix[S_SWAY], _mix[S_BREATH], _mix[S_BODY_LOOK] - _mix[S_LOOK], _mix[S_STAND], _mix[S_HEAD_NOD], _mix[S_EFFORT], _mix[S_BRAKE], _mix[S_FRONT_LOAD], _mix[S_REAR_LOAD])
		if is_instance_valid(_pack_bag):
			_pack_bag.position = PACK_AT + Vector3(_mix[S_PACK_ROLL] * 0.04, -clampf(_mix[S_PACK_PITCH], -0.06, 0.12) * 0.08, maxf(0.0, _mix[S_BREATH]) * 0.4)
			_pack_bag.rotation = Vector3(_mix[S_PACK_PITCH], 0, _mix[S_PACK_ROLL])


## Ход подвески в последнем кадре draw (для камеры, без ступенек 60 Гц)
func view_squash() -> float:
	return _mix[S_SQUASH] if _mix.size() > S_SQUASH else 0.0


## Перо рамы (цилиндр вдоль местной Y): какой конец у оси колеса, какой неподвижен, и длина
func _strut(part: MeshInstance3D, axle: Vector3) -> Strut:
	if part == null:
		push_warning("BikeView: перо должно быть MeshInstance3D")
		return null
	var cylinder := part.mesh as CylinderMesh
	if cylinder == null or cylinder.height <= 0.0001 or part.basis.y.length_squared() < 0.00000001:
		push_warning("BikeView: перо %s должно быть непустым CylinderMesh" % part.name)
		return null
	var half := part.basis.y.normalized() * cylinder.height * 0.5
	var a := part.position + half
	var b := part.position - half
	var strut := Strut.new()
	strut.part = part
	strut.fixed = a
	strut.axle = b
	strut.length = half.length() * 2.0
	if absf(a.z - axle.z) + absf(a.y - axle.y) < absf(b.z - axle.z) + absf(b.y - axle.y):
		strut.fixed = b
		strut.axle = a
	return strut


## Растянуть перо между неподвижной точкой и осью колеса.
func _stretch(st: Strut, travel: float) -> void:
	if st == null:
		return
	var axle := st.axle + Vector3(0.0, travel, 0.0)
	var along := axle - st.fixed
	if along.length_squared() < 0.00000001:
		return
	var basis := Basis(Quaternion(Vector3.UP, along.normalized())) * Basis.from_scale(Vector3(1.0, along.length() / st.length, 1.0))
	st.part.transform = Transform3D(basis, (st.fixed + axle) * 0.5)
