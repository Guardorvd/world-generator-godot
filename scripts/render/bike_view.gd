class_name BikeView
extends Node3D
## Велосипед с седоком, сцена scenes/bike.tscn: стилизованная модель со скелетным седоком, смотрит вдоль -Z.
## Повторяет состояние BikeRide: место, курс, наклон, крен, вращение колёс и педалей, ход подвески.
## С 7.1 колёса стоят на своих точках касания, а вилка и задние перья тянутся к осям: видно сжатие каждого колеса.
## Ноги седока ставятся на педали (два звена: бедро и голень). Езда считается тактами физики (60 в секунду),
## а кадров бывает и 800: между двумя последними тактами модель плавно переходит (draw), иначе дёргалась бы.

const WHEEL_Y := 0.34    # высота осей колёс над землёй
## Ось рулевой: проходит через STEERING_PIVOT с наклоном FORK_RAKE назад. Вокруг неё поворачиваются руль, вилка
## и переднее колесо; вдоль неё ходят штаны вилки. Ось колеса вынесена вперёд от этой оси на 35 мм.
const STEERING_PIVOT := Vector3(0.0, 0.9363, -0.3089)
const FORK_CROWN_Y := 0.87 # высота короны вилки до наклона (ось вилки вертикальна)
const MAX_FORK_VISUAL_TRAVEL := 0.12 # визуальный предел сжатия вилки, чтобы шина не задевала корону и раму
const FORK_RAKE := 0.30
const GRIP := Vector3(0.24, 1.0, -0.413) # середина правого грипса; левый — зеркально по X
const CRANK_REST := Vector3(0.0, 0.3, 0.0) # для сборщиков; в игре опоры читаются из узлов сцены
const RIGHT_PEDAL_REST := Vector3(0.14, -0.17, 0.0)
const STEER_VIEW := 0.6  # поворот переднего колеса в долях угла руля (30.10: было 0,35 — поворот читался как крен)
const Lamp = preload("res://scripts/render/bike_lamp.gd")
const BikePalette := preload("res://scripts/render/bike_palette.gd")
const Helmets := preload("res://scripts/render/helmet_models.gd")
const PACK_AT := Vector3(0.0, -0.08, 0.06) # сумка на кости Chest: у спины (+Z), низ — у поясницы
const PACK_SCALE := 0.8

# Каналы интерполяции между тактами физики.
enum {
	# Рама и механика
	S_X,
	S_BODY_Y,
	S_Z,
	S_TILT,
	S_HEADING,
	S_ROLL,
	S_SQUASH,
	S_STEER,
	S_CRANK,
	S_SQUASH_F,
	S_SQUASH_R,
	S_BRAKE,
	S_HEAT_F,     # нагрев переднего тормозного диска (0..1)
	S_HEAT_R,     # нагрев заднего тормозного диска (0..1)
	S_SHUDDER,    # дрожь тормозных рычагов при насыщении сцепления
	S_SPEED,
	S_WHEEL_F,
	S_WHEEL_R,
	S_PLACEMENT, # remaining fraction of the placement settle

	# Стоянка и точка опоры
	S_STOP,      # 11.11: стоянка — нога на земле (знак — сторона: − левая, + правая)
	S_TRACK,
	S_FOOT_X,
	S_FOOT_Y,
	S_FOOT_Z,
	S_FOOT_GRADE_X, # world-space surface gradient at the planted foot
	S_FOOT_GRADE_Z,

	# Поза и жесты
	S_TUCK,
	S_SHIFT, # корпус вперёд/назад
	S_SIDE,
	S_CROUCH,
	S_LOOK,
	S_TURN_SUPPORT, # знак и сила наружной опоры из переноса веса седока
	S_SWAY, # мягкое скручивание плеч в такт усилию
	S_BREATH, # небольшое движение грудной клетки
	S_BODY_LOOK, # поворот плеч при переносе веса седока
	S_STAND, # 12.3: привстал (подъём, рывок) +, «атака» на спуске −
	S_HEAD_NOD,
	S_PACK_PITCH,
	S_PACK_ROLL,
	S_EFFORT,
	S_FRONT_LOAD, # мгновенный приём переднего удара руками
	S_REAR_LOAD,  # мгновенный приём заднего удара и посадки ногами и тазом
	S_GAZE_YAW,  # взгляд по сторонам в спокойной езде и на стоянке (только голова)
	S_GAZE_PITCH,
	S_REST,      # 12.11: отдых на долгой стоянке — рука на бедре (знак — сторона руки)
	S_BRAKE_POSE, # 12.11: поза торможения корпуса — входит и выходит плавно, ручки (S_BRAKE) жмутся сразу
	S_WATCH,
	S_BALANCE, # signed side of the catch leg

	STATE_SIZE,
}

const WATCH_RAISE := 0.34
const WATCH_LOWER := 0.25
const WATCH_BRACE := 0.09

# Стойка и перенос веса. Амплитуды приседа в метрах, углы в радианах.
const SURGE_STAND := 0.85 # доля подъёма из седла в рывке
const LOAD_EFFORT := 0.95 # усилие на медленном подъёме
const SPEED_TUCK := 0.08 # группировка на крейсерской скорости
const BODY_SHIFT_RANGE := 0.17 # ход корпуса по Q/E, м
const TURN_SUPPORT_PER_RAD := 2.65
const GAZE_AHEAD_TIME := 0.30 # упреждение взгляда вдоль дуги, с (28.11: 0,24 + прежний вклад руля)
const STOP_LEAN := 0.085
const ROCK := 0.045 # крен рамы при педалировании стоя
const BRAKE_WEIGHT_SHIFT := 0.105 # перенос корпуса назад при полном торможении
const AIR_CROUCH := 0.055
const LAND_CROUCH := 0.085
const FRONT_HIT_CROUCH := 0.045
const REAR_HIT_CROUCH := 0.035

# Скорости реакции и затухания в 1/с. Отклик конечностей опережает корпус, затем следует голова.
const AXLE_LOAD_ATTACK := 55.0
const AXLE_LOAD_RELEASE := 22.0
const TORSO_RESPONSE := 15.0
const HEAD_NOD_RESPONSE := 9.5
const WHEEL_HIT_DECAY := 9.0
const LANDING_DECAY := 5.5
const BRAKE_POSE_ENGAGE := 9.0
const BRAKE_POSE_RELEASE := 4.5
const CRANK_FOLLOW := 15.0 # 28.11: как быстро видимый шатун набирает и теряет скорость (1/с)

# состояние на двух последних тактах (индексы S_*)
var _prev := PackedFloat64Array()
var _cur := PackedFloat64Array()
var _mix := PackedFloat64Array() # буфер для draw, чтобы не выделять память на каждый кадр
var _riding := false
var _fallen := false
var _fallen_transform := Transform3D.IDENTITY
var _has_state := false
var watch_requested := false
var _wheel_rates := Vector2.ZERO # rad/s, kept separately when a wheel leaves its support
var _bike_id := 0
var _last_crank := 0.0
var _last_wheel := 0.0
var _landing := 0.0
var _breath_phase := 0.0
var _effort := 0.0
var _hit_f := 0.0 # отклик седока на удар переднего и заднего колеса, затухает
var _hit_r := 0.0
var _rough_stance := 0.0 # off-saddle support held across closely spaced wheel strokes
var _bar_kick := Vector2.ZERO # steering deflection and angular velocity
var _landing_bias := 0.0 # positive for a nose-first touchdown
var _stand := 0.0
var _was_airborne := false
var _air_pose := 0.0
var _air_body_offset := 0.0
var _prev_ground_mid := 0.0
var _prev_lift_mid := 0.0
var _tilt_align := 0.0
var _takeoff := 0.0
var _jump_prep := 0.0
var _fatigue := 0.0
var _pack_swing := Vector2.ZERO
var _pack_velocity := Vector2.ZERO
var _reaction_shift := 0.0
var _reaction_shift_vel := 0.0
var _crouch_vel := 0.0
var _sway_vel := 0.0
var _head_nod_vel := 0.0
var _pack_bag: Node3D
var _fork_lowers: Array[Node3D] = []
var _fork_arch_rest := Vector3.ZERO
var _steering: Node3D
var _steer_limit := STEER_VIEW
var _levers: Array[Node3D] = []
var _lever_rest: Array[Transform3D] = []
var _view_ready := false
## Живые мелочи вида: нога на земле при остановке, ровные педали на накате, взгляд по сторонам.
## Выключается в проверках, которым нужна неподвижная посадка.
var idle_life := true
var _stop := 0.0
var _stop_side := -1.0
var _still_time := 0.0
var _coast_time := 0.0
var _coast_level := false
## 28.11: скорость видимого шатуна (рад/с) — педали разгоняются и останавливаются плавно, без скачка скорости ног.
var _crank_vel := 0.0
## 28.11: скорости плавных переходов позы (_ease): переход начинается и заканчивается с нулевой скоростью.
var _ease_vel := {}
var _calm_time := 0.0
var _gaze_amp := 0.0
var _gaze_phase := 0.0
var _rest := 0.0
# Перья подвески имеют именованные поля вместо позиционных массивов.
class Strut:
	var part: MeshInstance3D
	var fixed: Vector3
	var axle: Vector3
	var length: float

var _front_struts: Array[Strut] = []
var _rear_struts: Array[Strut] = []
var _rotor_mat_f: ShaderMaterial
var _rotor_mat_r: ShaderMaterial
var _heat_f := 0.0
var _heat_r := 0.0
var heat_source: BrakeEffects = null # GameWorld и Trail Lab: один расчёт нагрева дисков на такт
var _shudder_phase := 0.0
var lamp: Lamp
var _skin_mats: Array[ShaderMaterial] = []
var _rear_mechanics: Node3D
var _wind := 0.0
var _placement_lift := 0.0
var _placement_meshes: Array[GeometryInstance3D] = []
var _rider_pose := CyclistRig.PoseInput.new()
var _rig_from_bike := Transform3D.IDENTITY

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
	if rider.skeleton != null:
		_rig_from_bike = (rider.transform * rider.skeleton.transform).affine_inverse()
	# Вилка, вынос и руль поворачиваются вместе; колесо отдельно вращается вокруг оси.
	_steering = Node3D.new()
	add_child(_steering)
	_steering.position = STEERING_PIVOT
	for part: String in ["ForkL", "ForkR", "Stem", "Handlebar", "ForkCrown", "ForkArch", "GripL", "GripR", "LeverL", "LeverR", "BrakeClampL", "BrakeClampR", "CableL", "CableR", "CableReturnL", "CableReturnR"]:
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
		elif fork is MeshInstance3D:
			_front_struts.append(_strut(fork, front_axle))
	if _steering.has_node("ForkArch"):
		_fork_lowers.append(_steering.get_node("ForkArch"))
		_fork_arch_rest = _steering.get_node("ForkArch").position
	for part: String in ["ChainStayL", "ChainStayR", "SeatStayL", "SeatStayR"]:
		_rear_struts.append(_strut(get_node(part) as MeshInstance3D, Vector3(0.0, WHEEL_Y, BikeRide.HUB)))
	for part: String in ["ChainTop", "ChainBottom"]:
		if has_node(part):
			_rear_struts.append(_strut(get_node(part), Vector3(0.085, WHEEL_Y, BikeRide.HUB)))
	var rotor_shader := preload("res://resources/brake_rotor.gdshader")
	var f_rotor := front_wheel.get_node_or_null("BrakeRotor") as MeshInstance3D
	if f_rotor != null:
		_rotor_mat_f = ShaderMaterial.new()
		_rotor_mat_f.shader = rotor_shader
		_rotor_mat_f.set_shader_parameter("caliper_angle", 2.35)
		f_rotor.material_override = _rotor_mat_f
	var r_rotor := rear_wheel.get_node_or_null("BrakeRotor") as MeshInstance3D
	if r_rotor != null:
		_rotor_mat_r = ShaderMaterial.new()
		_rotor_mat_r.shader = rotor_shader
		_rotor_mat_r.set_shader_parameter("caliper_angle", 0.78)
		r_rotor.material_override = _rotor_mat_r
	lamp = Lamp.new()
	lamp.name = "Lamp"
	lamp.position = Vector3(0.0, GRIP.y - 0.05, GRIP.z - 0.057) - STEERING_PIVOT # под зажимом руля
	_steering.add_child(lamp)
	_own_materials()
	_rear_mechanics = get_node_or_null("RearMechanics") as Node3D
	_view_ready = true


## 17.11: у каждого велосипеда свой экземпляр общего материала (bike_rider.gdshader): палитра и ветер
## меняются у него, а не у всех копий сцены. Часы на руке седока — часть его меша (build_cyclist.gd).
func _own_materials() -> void:
	var copies := {}
	for item: Node in find_children("*", "GeometryInstance3D", true, false):
		var geo := item as GeometryInstance3D
		var mat := geo.material_override as ShaderMaterial
		if mat == null or mat.shader != BikePalette.SHADER:
			continue
		if not copies.has(mat):
			copies[mat] = mat.duplicate()
		geo.material_override = copies[mat]
	_skin_mats.assign(copies.values())


## Расцветка велосипеда и формы (BikePalette.SCHEMES)
func set_scheme(scheme: String) -> void:
	var colors: PackedColorArray = BikePalette.colors(scheme)
	var finish: Dictionary = BikePalette.FINISHES.get(scheme, BikePalette.FINISH_NONE)
	for mat in _skin_mats:
		mat.set_shader_parameter("palette", colors)
		for key: String in finish:
			mat.set_shader_parameter("finish_" + key, finish[key])


func set_tires(id: String) -> void:
	var colors: Array = BikePalette.TIRE_COLORS.get(id, [Color.TRANSPARENT, Color.TRANSPARENT])
	for mat in _skin_mats:
		mat.set_shader_parameter("tire_tread", colors[0])
		mat.set_shader_parameter("tire_sidewall", colors[1])


func set_grips(id: String) -> void:
	var colors := BikePalette.grip_colors(id)
	for mat in _skin_mats:
		mat.set_shader_parameter("grip_body", colors[0])
		mat.set_shader_parameter("grip_rib", colors[1])


func set_pedals(id: String) -> void:
	var colors := BikePalette.pedal_colors(id)
	for mat in _skin_mats:
		mat.set_shader_parameter("pedal_body", colors[0])
		mat.set_shader_parameter("pedal_trim", colors[1])


## 27.11: форма шлема (HelmetModels): виден один меш на кости головы, неизвестный id — штатный шлем
func set_helmet(id: String) -> void:
	if rider == null or rider.skeleton == null:
		return
	var mount := rider.skeleton.get_node_or_null(Helmets.MOUNT)
	if mount == null:
		return
	var shown := id if mount.has_node(id) else Helmets.STOCK
	for item: Node in mount.get_children():
		(item as Node3D).visible = item.name == shown


func _set_wind(value: float) -> void:
	if value == _wind:
		return
	_wind = value
	for mat in _skin_mats:
		mat.set_shader_parameter("wind", value)


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
	if pack != null and pack.visible != on:
		pack.visible = on
		if not on:
			_pack_swing = Vector2.ZERO
			_pack_velocity = Vector2.ZERO
			if is_instance_valid(_pack_bag):
				_pack_bag.position = PACK_AT
				_pack_bag.rotation = Vector3.ZERO
			if _has_state:
				_prev[S_PACK_PITCH] = 0.0
				_prev[S_PACK_ROLL] = 0.0
				_cur[S_PACK_PITCH] = 0.0
				_cur[S_PACK_ROLL] = 0.0


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
	var continuous := _has_state and _riding and b.riding
	_cur[S_PLACEMENT] = maxf(0.0, _prev[S_PLACEMENT] - dt / 0.15)
	_cur[S_X] = b.x
	_cur[S_SPEED] = absf(b.speed)
	if b.airborne:
		if _has_state and not _was_airborne:
			_air_body_offset += _prev_ground_mid - (_prev_lift_mid if b.hop_used else 0.0)
		_air_body_offset = lerpf(_air_body_offset, 0.0, Util.damp(12.0, dt)) if _has_state else 0.0
	else:
		_air_body_offset = lerpf(_air_body_offset, 0.0, Util.damp(16.0, dt)) if _has_state else 0.0
		_prev_ground_mid = (b.ground_f + b.ground_r) * 0.5 + b.ground_extension
		_prev_lift_mid = (b.lift_f + b.lift_r) * 0.5
	# рама — посередине между концами подвесок, каждый на своём ходе над точкой касания колеса
	_cur[S_BODY_Y] = b.y + (b.ground_f + b.ground_r - b.squash_f - b.squash_r) * 0.5 + b.ground_extension + _air_body_offset
	_cur[S_Z] = b.z
	_cur[S_TILT] = b.tilt
	var cfg := b.config if b.config != null else BikePhysicsConfig.current()
	_steer_limit = cfg.max_steer_angle
	var braking := clampf(b.brake_applied / cfg.brake_decel, 0.0, 1.0) if not b.airborne else 0.0
	# Ручки жмутся сразу; отпускание — коротким плавным ходом, без щелчка за один такт.
	_cur[S_BRAKE] = b.brake_pressure if not continuous or b.brake_pressure >= _prev[S_BRAKE] 		else _ease("lever", _prev[S_BRAKE], b.brake_pressure, 30.0, dt)
	# Pitch about the front contact point while the rear wheel unloads.
	var lift := b.nose_lift if not b.airborne else 0.0
	_cur[S_TILT] -= lift
	_cur[S_BODY_Y] += sin(lift) * BikeRide.HUB
	_cur[S_X] += sin(b.heading) * BikeRide.HUB * (cos(lift) - 1.0)
	_cur[S_Z] += cos(b.heading) * BikeRide.HUB * (cos(lift) - 1.0)
	_cur[S_HEADING] = b.heading
	_cur[S_ROLL] = b.lean
	_cur[S_SQUASH] = b.squash - b.ground_extension
	var sq_f := b.squash_f - b.ground_extension
	var sq_r := b.squash_r - b.ground_extension
	var grounded_both := not b.airborne and b.tick_time > 0.0 and b.contact_f() and b.contact_r()
	var target_align := 0.0
	if grounded_both:
		var terrain_tilt := atan2((b.ground_f - sq_f) - (b.ground_r - sq_r), 2.0 * BikeRide.HUB)
		target_align = clampf(clampf(terrain_tilt - b.tilt, -0.09, 0.09) * BikeRide.HUB, -0.05, 0.05)
	_tilt_align = lerpf(_tilt_align, target_align, Util.damp(24.0 if grounded_both else 14.0, dt)) if _has_state else target_align
	sq_f += _tilt_align
	sq_r -= _tilt_align
	_cur[S_SQUASH_F] = sq_f
	_cur[S_SQUASH_R] = sq_r
	_update_wheel_spin(b, dt)
	_last_wheel = b.wheel
	# 28.11: руль на виде — пружина с быстрым откликом поверх физики: курс тот же, но руль и кисти не получают
	# скачка скорости, когда на малой скорости отпускают большой угол (возврат руля в физике — первого порядка).
	_cur[S_STEER] = _ease("steer", _prev[S_STEER], b.steer_visual(), 45.0, dt) if continuous else b.steer_visual()
	_update_foot_support(b, dt, continuous, cfg.stop_settle_time)
	_cur[S_CRANK] = wrapf(_pedal_angle(b, dt), -PI, PI) if _has_state else b.crank
	_last_crank = b.crank
	_bike_id = b.get_instance_id()
	_cur[S_TUCK] = clampf(absf(b.speed) / cfg.cruise_speed, 0.0, 1.0) * SPEED_TUCK
	_update_rider(b, dt, boost, cfg, braking)
	var safe := absf(_cur[S_BALANCE]) < 0.18 and b.instability < 0.25 and b.speed > -0.1 and not b.airborne and not boost and absf(b.speed) <= 11.0 \
		and absf(b.steer) < 0.33 and absf(b.lean) < 0.22 and absf(b.slip) < 0.12 \
		and throttle > -0.15 and _cur[S_BRAKE] < 0.16 and absf(_stand) < 0.42 \
		and b.land_impact < 1.0 and _jump_prep < 0.1 and maxf(_cur[S_FRONT_LOAD], _cur[S_REAR_LOAD]) < 0.25
	var raising := watch_requested and safe
	var duration := WATCH_RAISE if raising else (WATCH_LOWER if safe else WATCH_BRACE)
	_cur[S_WATCH] = move_toward(_prev[S_WATCH], float(raising), dt / duration) if _has_state and b.riding and not b.fallen else 0.0
	# Передняя ось получает отдачу от кромки, а восстановление равновесия остаётся в позе седока.
	_cur[S_STEER] = clampf(_cur[S_STEER] + _bar_kick.x, -1.0, 1.0)
	# Нагрев тормозных дисков от мощности трения колодок и охлаждение встречным потоком воздуха
	var spd := absf(b.speed)
	# 20.11: нагрев считает BrakeEffects (искры у диска); вид берёт его значение, свой расчёт — только на стендах без эффектов
	if heat_source != null:
		_heat_f = heat_source.heat_f
		_heat_r = heat_source.heat_r
	else:
		var next_heat := BrakeEffects.step_rotor_heat(b, dt, _heat_f, _heat_r)
		_heat_f = next_heat.x
		_heat_r = next_heat.y
	_cur[S_HEAT_F] = _heat_f
	_cur[S_HEAT_R] = _heat_r
	# Дрожь рычагов берётся из торможения, без вклада боковой загрузки шины в повороте.
	var shudder_amp := b.brake_skid * _cur[S_BRAKE] * smoothstep(0.6, 2.5, spd)
	_shudder_phase = fmod(_shudder_phase + dt * (42.0 + spd * 3.5), TAU) if shudder_amp > 0.0 else 0.0
	_cur[S_SHUDDER] = sin(_shudder_phase) * shudder_amp
	_riding = b.riding
	_fallen = b.fallen
	_fallen_transform = b.fallen_transform
	if not _has_state:
		_prev = _cur.duplicate()
		_has_state = true


## A tyre can follow the road speed only through contact. In flight keep its release spin.
func _update_wheel_spin(b: BikeRide, dt: float) -> void:
	var road_step := angle_difference(_last_wheel, b.wheel)
	var expected := b.speed * dt / BikeRide.WHEEL_R
	road_step += TAU * roundf((expected - road_step) / TAU)
	var road_rate := road_step / dt if dt > 0.0 else 0.0
	const GRIP_RESPONSE := 36.0
	var grip_blend := Util.damp(GRIP_RESPONSE, dt)
	for i in 2:
		var channel := S_WHEEL_F if i == 0 else S_WHEEL_R
		if not _has_state:
			_wheel_rates[i] = b.speed / BikeRide.WHEEL_R
			_cur[channel] = b.wheel
			continue
		var old_rate := _wheel_rates[i]
		var travel := old_rate * dt
		var contact := b.contact_f() if i == 0 else b.contact_r()
		if contact:
			var use := b.use_f if i == 0 else b.use_r
			var drag := b.brake_skid * smoothstep(0.60, 1.0, use)
			var target_rate := road_rate * (1.0 - drag)
			_wheel_rates[i] = lerpf(old_rate, target_rate, grip_blend)
			travel = target_rate * dt + (old_rate - target_rate) * grip_blend / GRIP_RESPONSE
		# Keep signed travel through the tick, even beyond half a revolution.
		_cur[channel] = _prev[channel] + travel


## Carry cadence from the *visible* crank. Coasting, cornering and stopping can
## reposition it while the drivetrain is idle, so its absolute phase can differ.
func _pedal_angle(b: BikeRide, dt: float) -> float:
	var angle := _prev[S_CRANK]
	var step := angle_difference(_last_crank, b.crank)
	if not b.riding:
		_crank_vel = step / dt if dt > 0.0 else 0.0
		return angle + step
	var driving := not b.airborne and (absf(step) > 0.00001 or b.effort > 0.08)
	_coast_time = _coast_time + dt if idle_life and not driving and not b.airborne else 0.0
	# 28.11: шатун ведётся по скорости, а не по углу: при переходе педали ↔ накат, в полёте и при остановке
	# скорость ног меняется плавно (за ~0,07 с), а не скачком от каденса к нулю и обратно.
	var follow := Util.damp(CRANK_FOLLOW, dt)
	if b.reversing and not b.airborne:
		_coast_level = sin(angle) < 0.0
		_crank_vel = lerpf(_crank_vel, minf(0.0, b.speed) / (BikeRide.WHEEL_R * maxf(1.0, b.gear)), follow)
		return angle + _crank_vel * dt
	if driving:
		_coast_level = sin(angle) < 0.0
		_crank_vel = lerpf(_crank_vel, step / dt if dt > 0.0 else 0.0, follow)
		return angle + _crank_vel * dt
	if _coast_level and sin(angle) > 0.18:
		_coast_level = false
	elif not _coast_level and sin(angle) < -0.18:
		_coast_level = true
	var level := -PI * 0.5 if _coast_level else PI * 0.5
	var target := lerp_angle(angle, level, smoothstep(0.22, 0.40, _coast_time))
	if b.airborne:
		target = level
	else:
		var corner := smoothstep(0.15, 0.34, absf(b.rider_lean))
		target = lerp_angle(target, PI if b.rider_lean < 0.0 else 0.0, corner)
		var ready := -0.9 if _stop_side < 0.0 else PI - 0.9
		target = lerp_angle(target, ready, smoothstep(0.0, 1.0, _stop))
	var want := clampf(angle_difference(angle, target) * (12.0 if b.airborne else 8.0), -5.5, 5.5)
	_crank_vel = lerpf(_crank_vel, want, follow)
	return angle + _crank_vel * dt


## Реакции считаются только на тактах физики; draw лишь интерполирует готовую позу.
func _update_rider(b: BikeRide, dt: float, boost: bool, cfg: BikePhysicsConfig, brake_amount: float) -> void:
	var continuous := _has_state and _riding and b.riding
	_air_pose = _ease("air", _air_pose, 1.0 if b.airborne else 0.0, 22.0 if b.airborne else 28.0, dt) if continuous else (1.0 if b.airborne else 0.0)
	var air_keep := 1.0 - _air_pose
	# продольное ускорение по мировой скорости за тот же такт, что и у камеры (BikeRide.feel_acceleration)
	var acceleration := clampf(b.feel_acceleration, -9.0, 7.0) if continuous else 0.0
	# Уклон земли, а не наклон рамы: подвеска и движение тела не выдают себя за подъём.
	var slope := clampf(b.grade_now, -0.5, 0.5) * air_keep
	# Усилие — то же состояние, что даёт тягу (BikeRide.effort), тяжесть — реализованная тяга и подъём.
	var drive := b.effort * air_keep
	var work := clampf(b.drive_force / (cfg.pedal_accel * cfg.start_push_mult), 0.0, 1.0)
	var load := smoothstep(0.04, 0.25, slope) * drive
	var effort_target := maxf(drive * 0.6 + work * 0.4, load * LOAD_EFFORT) * (1.25 if boost else 1.0)
	# Набирается быстро вместе с тягой без резкого скачка за один кадр; отпускание педалей не обрывает дыхание и плечи.
	_effort = lerpf(_effort, effort_target, Util.damp(14.0 if effort_target > _effort else 5.0, dt)) if continuous else 0.0
	var effort := _effort
	# Рычаги следуют давлению, корпус — реализованному тормозному усилию в пятнах контакта.
	var brake_response := BRAKE_POSE_ENGAGE if brake_amount > _prev[S_BRAKE_POSE] else BRAKE_POSE_RELEASE
	var braking := _ease("brake_pose", _prev[S_BRAKE_POSE], brake_amount, brake_response * 1.6, dt) if continuous else brake_amount
	_cur[S_BRAKE_POSE] = braking
	# 12.3: на крутом подъёме под нагрузкой и в рывок с места седок встаёт с седла;
	# на быстром спуске без педалей и на тряске — приподнимается и принимает удары ногами.
	var climb := smoothstep(0.07, 0.16, slope) * smoothstep(0.45, 0.85, effort) * (1.0 - smoothstep(7.0, 11.0, absf(b.speed)))
	var sprint := smoothstep(1.5, 3.5, acceleration) * (1.0 - smoothstep(6.0, 10.0, absf(b.speed))) if boost else 0.0
	# 12.11: рывок на Shift (BikeRide.surge) — седок встаёт на педали и раскачивает велосипед на любой скорости,
	# пока длится прилив и он давит на педали; раньше стойка была только при разгоне до 10 м/с
	if b.surge > 0.0 and not b.airborne:
		sprint = maxf(sprint, smoothstep(0.0, 0.5, b.surge) * smoothstep(0.3, 0.7, effort) * SURGE_STAND)
	var descent := smoothstep(0.06, 0.16, -slope) * (1.0 - effort) * smoothstep(4.0, 8.0, absf(b.speed))
	# Возврат тела к нейтрали после E может иметь положительную скорость. Подготовку задаёт намерение.
	var body := clampf(b.body_x, -1.0, 1.0) if continuous else 0.0
	var manual_prep := smoothstep(0.04, 0.60, body) if b.body_back and not b.body_forward else 0.0
	var prep_goal := maxf(manual_prep, 0.85 if b.hop_preparing else 0.0) if continuous and not b.airborne else 0.0
	_jump_prep = lerpf(_jump_prep, prep_goal, Util.damp(22.0 if prep_goal > _jump_prep else 10.0, dt)) if continuous else 0.0
	var ground_stand := maxf(climb, sprint) - descent
	var stand_target := lerpf(ground_stand, -0.65, _air_pose) if continuous else 0.0
	var brake_risk := b.brake_risk if not b.airborne else 0.0
	var track := float(b.stance_driven and b.stance == BikeRide.Stance.TRACKSTAND and not b.airborne)
	_cur[S_TRACK] = _ease("track", _prev[S_TRACK], track, 12.0, dt) if continuous else 0.0
	stand_target = lerpf(stand_target, 0.32, _cur[S_TRACK])
	if brake_risk > 0.0:
		stand_target = lerpf(stand_target, -1.0, brake_risk)
	# Legs carry the rider between closely spaced bumps; isolated contacts still read at the limbs.
	var fv := maxf(b.squash_fv_avg, absf(b.squash_fv)) if b.tick_time > 0.0 else b.squash_fv
	var rv := maxf(b.squash_rv_avg, absf(b.squash_rv)) if b.tick_time > 0.0 else b.squash_rv
	var fork_rate := fv if b.contact_f() else 0.0
	var rear_rate := rv if b.contact_r() else 0.0
	var stroke_rate := maxf(fork_rate, rear_rate)
	var activity := maxf(smoothstep(1.3, 3.0, stroke_rate), maxf(_hit_f, _hit_r))
	activity *= smoothstep(0.6, 3.2, absf(b.speed)) if not b.airborne else 0.0
	_rough_stance = lerpf(_rough_stance, activity, Util.damp(5.0 if activity > _rough_stance else 3.0, dt)) if continuous else 0.0
	stand_target = lerpf(stand_target, -0.72, _rough_stance)
	_stand = lerpf(_stand, stand_target, 1.0 - exp(-dt * (4.0 if absf(stand_target) > absf(_stand) else 2.5))) if continuous else 0.0
	var up := maxf(_stand, 0.0)
	# Перенос от тяги уступает переносу назад по мере роста фактического тормозного усилия.
	var drive_shift := clampf(-b.drive_force * 0.009, -0.06, 0.0) if continuous and not b.airborne else 0.0
	var inertia_shift := lerpf(drive_shift, BRAKE_WEIGHT_SHIFT, braking)
	# Удар колеса о кромку — своё событие (не приземление): переднее принимают руки — плечи коротко уходят назад,
	# заднее — ноги, таз приподнимается над седлом. Сила — по скорости удара колеса.
	var hit_decay := exp(-dt * WHEEL_HIT_DECAY)
	_hit_f *= hit_decay
	_hit_r *= hit_decay
	if continuous:
		_bar_kick.y = clampf(_bar_kick.y + b.fork_side_impulse * 3.5, -6.0, 6.0)
		_bar_kick = _spring_step(_bar_kick.x, _bar_kick.y, 0.0, 18.0, dt)
		var fork_stop := smoothstep(cfg.bottom_out_speed, cfg.bottom_out_speed + 2.2, b.bottom_out)
		var front_strike := maxf(clampf(b.wheel_impact.x / 1.5, 0.0, 1.0), fork_stop)
		var rear_strike := clampf(b.wheel_impact.y / 1.5, 0.0, 1.0)
		# Each new contact uses the remaining range, even during recovery from the last.
		_hit_f += (1.0 - _hit_f) * front_strike
		_hit_r += (1.0 - _hit_r) * rear_strike
	var moving := smoothstep(0.5, 3.0, absf(b.speed)) if not b.airborne else 0.0
	# Отрыв и касание дают импульсы позе. Корпус возвращается через общий затухающий переход.
	_takeoff *= exp(-dt * 9.5)
	if continuous and b.airborne and not _was_airborne:
		var air_pop := 1.0 if b.hop_used else smoothstep(0.3, 1.5, b.vy)
		_takeoff = (1.0 if b.hop_used else lerpf(0.18, 0.90, _jump_prep)) * air_pop
	_was_airborne = b.airborne
	_landing *= exp(-dt * LANDING_DECAY)
	if continuous and b.land_impact > 0.0:
		var impact := clampf(b.land_impact / 9.0, 0.0, 1.0)
		var angle := float(b.landing_info.get("pitch_error", b.tilt - atan(b.grade_now)))
		var bias := -clampf(angle / 0.32, -1.0, 1.0)
		_landing_bias = lerpf(_landing_bias, bias, impact / maxf(impact + _landing, 0.0001))
		_landing += (1.0 - _landing) * impact
	# Последовательный приём нагрузки:
	# Ход подвески, удар о кромку и приземление могут описывать одно нагружение колеса за такт.
	# Руки и ноги принимают нагрузку своей оси, сохраняя мгновенный отклик на удар.
	var front_landing := _landing * (0.53 + 0.38 * _landing_bias)
	var rear_landing := _landing * (0.67 - 0.30 * _landing_bias)
	var front_hit := maxf(front_landing, _hit_f * 0.90)
	var rear_hit := maxf(rear_landing, _hit_r * 0.90)
	var front_stroke := maxf(smoothstep(0.55, 1.35, b.load_f) * 0.32, clampf(fork_rate * 0.14, 0.0, 0.42)) * moving
	var rear_stroke := maxf(smoothstep(0.55, 1.35, b.load_r) * 0.32, clampf(rear_rate * 0.14, 0.0, 0.42)) * moving
	var front_goal := maxf(front_hit, maxf(front_stroke, _jump_prep * 0.25))
	var rear_goal := maxf(rear_hit, maxf(rear_stroke, _jump_prep * 0.35))
	var front_blend := Util.damp(AXLE_LOAD_ATTACK if front_goal > _prev[S_FRONT_LOAD] else AXLE_LOAD_RELEASE, dt)
	var rear_blend := Util.damp(AXLE_LOAD_ATTACK if rear_goal > _prev[S_REAR_LOAD] else AXLE_LOAD_RELEASE, dt)
	var front_load := lerpf(_prev[S_FRONT_LOAD], front_goal, front_blend) if continuous else front_goal
	var rear_load := lerpf(_prev[S_REAR_LOAD], rear_goal, rear_blend) if continuous else rear_goal
	# Приоритеты смешивания: торможение и удар подавляют раскачку педалирования, чтобы реакции не складывались в случайную позу.
	var impact_priority := clampf(front_load * 0.65 + rear_load * 0.75, 0.0, 1.0)
	var pedal_priority := (1.0 - braking) * (1.0 - impact_priority * 0.65) * (1.0 - 0.8 * b.instability)
	var active_effort := effort * pedal_priority * air_keep
	var air_pitch_shift := clampf(b.pitch_vel * 0.055 - b.vy * 0.004, -0.07, 0.07) * _air_pose
	var shift_goal := inertia_shift - slope * 0.16 - active_effort * 0.015 + _hit_f * 0.038 - _hit_r * 0.018
	shift_goal += _jump_prep * 0.022 + _takeoff * 0.038 + air_pitch_shift + _landing * _landing_bias * 0.060
	var backwards := smoothstep(0.04, 0.8, -b.speed)
	var reverse_look := backwards if b.reversing else 0.0
	shift_goal -= backwards * (1.0 - reverse_look) * 0.07
	shift_goal = clampf(shift_goal + brake_risk * 0.055, -0.17, 0.2)
	var distress := maxf(smoothstep(0.18, 0.85, b.instability), smoothstep(0.18, 0.45, absf(b.slip)))
	var fall_side := clampf(b.lateral_speed * 2.0, -1.0, 1.0)
	var catch_goal := distress * fall_side * (1.0 - _stop) if not b.airborne else 0.0
	_cur[S_BALANCE] = lerpf(_prev[S_BALANCE], catch_goal, Util.damp(9.0, dt)) if continuous else 0.0
	var turn_lean := -b.rider_lean * smoothstep(0.02, 0.26, absf(b.rider_lean))
	_cur[S_TURN_SUPPORT] = clampf(turn_lean * TURN_SUPPORT_PER_RAD, -1.0, 1.0)
	var side := -b.rider_lean * 0.13 + sin(_cur[S_CRANK]) * active_effort * (0.012 + up * 0.02)
	_cur[S_SIDE] = clampf(side, -0.068, 0.068) - _cur[S_BALANCE] * 0.10
	_cur[S_BODY_LOOK] = b.rider_lean * 0.58
	var pedal_bob := (1.0 - cos(_cur[S_CRANK] * 2.0)) * active_effort * lerpf(0.0045, 0.008, up)
	# Корпус принимает общую компрессию. Два колеса, ход подвески и пробой на одном приземлении делят этот ход.
	var stroke_crouch := clampf(stroke_rate * 0.012, 0.0, 0.035) * moving
	var edge_crouch := maxf(_hit_f * FRONT_HIT_CROUCH, _hit_r * REAR_HIT_CROUCH)
	var impact_goal := maxf(edge_crouch, _landing * LAND_CROUCH)
	var support_goal := maxf(stroke_crouch, impact_goal)
	var air_crouch := (AIR_CROUCH * (1.0 - _takeoff * 0.85) - _takeoff * 0.022) * _air_pose
	# Extend from the flight tuck as the measured gap closes. A rising lip can
	# approach the wheels even when vertical world speed is still positive.
	if b.airborne and b.clearance_closing_speed > 0.0:
		var seconds_to_contact := b.air_clearance / b.clearance_closing_speed
		var prepare := (1.0 - smoothstep(0.04, 0.20, seconds_to_contact)) * smoothstep(0.4, 2.0, b.clearance_closing_speed)
		air_crouch -= 0.050 * prepare * smoothstep(0.04, 0.14, b.air_time)
	var jump_crouch := maxf(maxf(body, 0.0) * 0.07, _jump_prep * (1.0 - _takeoff) * 0.058)
	var effort_crouch := pedal_bob + active_effort * smoothstep(0.0, 0.12, slope) * 0.02
	var crouch := air_crouch + jump_crouch + effort_crouch
	crouch += b.instability * 0.032 * air_keep
	# 28.11: взгляд вдоль дуги — по накопленной нагрузке (сглаженная угловая скорость курса), без мгновенного руля:
	# лёгкая поправка — только руки и руль, голова почти не двигается; в удерживаемой дуге взгляд выходит
	# на полную долю раньше корпуса (при половине нагрузки, у корпуса — к пределу) и ведёт плечи.
	var arc_load := b.turn_load()
	var gaze_share := minf(1.0, absf(arc_load) / maxf(cfg.turn_pose_knee, 0.01))
	var turn_look := arc_load / maxf(absf(b.speed), 3.0) * GAZE_AHEAD_TIME * gaze_share
	var look := clampf((turn_look - b.slip * 0.22) * smoothstep(0.2, 3.0, absf(b.speed)) + reverse_look * 0.58, -0.60, 0.60)
	# 11.11: взгляд. После нескольких секунд спокойной езды голова время от времени поворачивается к обочине и
	# возвращается; на стоянке седок осматривается шире. Поворот, тормоз, удар и тяжёлая работа сразу возвращают взгляд.
	var calm := distress < 0.15 and backwards < 0.05 and continuous and idle_life and not b.airborne and braking < 0.1 and impact_priority < 0.1 and absf(look) < 0.08 and absf(_cur[S_TURN_SUPPORT]) < 0.12 and effort < 0.6
	_update_idle_gestures(b, dt, continuous, calm)
	# Плечи чуть сопровождают нажатие на педаль, таз отвечает встречным движением.
	var sway := sin(_cur[S_CRANK]) * active_effort * (0.055 + up * 0.06)
	# Дыхание подчинено накопленной нагрузке (_fatigue): учащается и углубляется под нагрузкой, с активным вдохом,
	# и кратковременно задерживается при жёстком торможении, отрыве и приёме удара.
	var prev_fatigue := _fatigue
	var exertion := clampf(effort * 0.75 + smoothstep(0.03, 0.22, slope) * effort * 0.45 + (0.25 if boost and effort > 0.1 else 0.0) + _landing * 0.25, 0.0, 1.0)
	_fatigue = lerpf(_fatigue, exertion, Util.damp(2.2 if exertion > _fatigue else 0.85, dt)) if continuous else 0.0
	var avg_fatigue := 0.5 * (prev_fatigue + _fatigue)
	_breath_phase = fmod(_breath_phase + dt * (1.7 + avg_fatigue * 1.4), TAU) if continuous else 0.0
	var breath_wave := sin(_breath_phase) + 0.20 * _fatigue * sin(_breath_phase * 2.0 - 0.6)
	var breath_brace := 1.0 - clampf(braking * 0.35 + impact_priority * 0.50 + _takeoff * 0.45, 0.0, 0.65)
	var breath := breath_wave * (0.002 + _fatigue * 0.004) * breath_brace if b.riding else 0.0
	# Корпус принимает продольную нагрузку и сжатие через затухающий переход.
	if continuous:
		var shift_step := _spring_step(_reaction_shift, _reaction_shift_vel, shift_goal, TORSO_RESPONSE, dt)
		_reaction_shift = shift_step.x
		_reaction_shift_vel = shift_step.y
		var crouch_step := _spring_step(_prev[S_CROUCH], _crouch_vel, crouch + support_goal, TORSO_RESPONSE, dt)
		_cur[S_CROUCH] = crouch_step.x
		_crouch_vel = crouch_step.y
		var sway_step := _spring_step(_prev[S_SWAY], _sway_vel, sway, 16.0, dt)
		_cur[S_SWAY] = sway_step.x
		_sway_vel = sway_step.y
	else:
		_cur[S_CROUCH] = crouch
		_cur[S_SWAY] = sway
		_reaction_shift = shift_goal
		_reaction_shift_vel = 0.0
		_crouch_vel = 0.0
		_sway_vel = 0.0
	# Физика уже ограничивает ход и скорость Q/E. Пружина выше отвечает за внешнюю нагрузку.
	_cur[S_SHIFT] = clampf(_reaction_shift + body * BODY_SHIFT_RANGE, -0.17, 0.2)
	var look_blend := Util.damp(10.0, dt)
	_cur[S_LOOK] = lerpf(_prev[S_LOOK], look, look_blend) if continuous else look
	_cur[S_BREATH] = breath
	# назад — таз ниже седла сзади («атака»), вперёд — привстал над рамой
	_cur[S_STAND] = clampf(_stand - body * 0.55, -1.0, 1.0)
	# Шея принимает уже прошедший через корпус удар. Обычный ход колёс остаётся в работе рук и ног.
	var air_look_pitch := clampf(b.vy * 0.003, -0.02, 0.02) * _air_pose
	# 12.11: уставший седок опускает голову (после подъёма, рывка), отдышавшись — поднимает
	var head_nod_goal := clampf(-_fatigue * 0.03 * (1.0 - _landing) - impact_goal * 0.65 - _jump_prep * 0.018 + _takeoff * 0.042 + air_look_pitch, -0.08, 0.06)
	if continuous:
		var nod_step := _spring_step(_prev[S_HEAD_NOD], _head_nod_vel, head_nod_goal, HEAD_NOD_RESPONSE, dt)
		_cur[S_HEAD_NOD] = nod_step.x
		_head_nod_vel = nod_step.y
	else:
		_cur[S_HEAD_NOD] = 0.0
		_head_nod_vel = 0.0
	# Пружины экипировки работают, пока сумка видна на седоке.
	if continuous and is_instance_valid(_pack_bag) and _pack_bag.is_visible_in_tree():
		var pack_pitch_goal := clampf(acceleration * 0.007 + _landing * 0.13 - _takeoff * 0.05 + (_hit_f * 0.05 - _hit_r * 0.04) + (fork_rate + rear_rate) * 0.008 * moving + absf(sway) * 0.18, -0.09, 0.14)
		var pack_roll_goal := clampf(b.lean * 0.12 + b.slip * 0.20 - sway * 0.35, -0.07, 0.07)
		var pack_x := _spring_step(_pack_swing.x, _pack_velocity.x, pack_pitch_goal, 12.0, dt)
		var pack_y := _spring_step(_pack_swing.y, _pack_velocity.y, pack_roll_goal, 12.0, dt)
		_pack_swing = Vector2(pack_x.x, pack_y.x)
		_pack_velocity = Vector2(pack_x.y, pack_y.y)
	else:
		_pack_swing = Vector2.ZERO
		_pack_velocity = Vector2.ZERO
	_cur[S_PACK_PITCH] = _pack_swing.x
	_cur[S_PACK_ROLL] = _pack_swing.y
	_cur[S_EFFORT] = lerpf(_prev[S_EFFORT], active_effort, Util.damp(12.0, dt)) if continuous else active_effort
	_cur[S_FRONT_LOAD] = front_load
	_cur[S_REAR_LOAD] = rear_load


func _update_foot_support(b: BikeRide, dt: float, continuous: bool, settle_time: float) -> void:
	# Для статичных стендов, где нет BikeRide.step(), оставляем таймер по скорости.
	var foot_down := false
	if b.stance_driven:
		foot_down = continuous and idle_life and not b.airborne and b.stance == BikeRide.Stance.FOOT_DOWN
		_still_time = _still_time + dt if foot_down else 0.0
		if foot_down and _stop_side != b.foot_side:
			if _stop <= 0.001:
				_stop_side = b.foot_side
				_prev[S_STOP] = 0.0
			else:
				foot_down = false
	else:
		var still := continuous and idle_life and not b.airborne and absf(b.speed) < 0.35 and b.effort < 0.05 and absf(b.lean) < 0.1
		_still_time = _still_time + dt if still else 0.0
		if _stop <= 0.001 and still:
			_stop_side = 1.0 if b.lean < -0.01 else -1.0
			_prev[S_STOP] = 0.0
		foot_down = _still_time > settle_time
	var stop_goal := 1.0 if foot_down else 0.0
	_stop = clampf(_ease("stop", _stop, stop_goal, 8.0 if stop_goal > _stop else 13.0, dt), 0.0, 1.0) if continuous else 0.0
	_cur[S_STOP] = _stop * _stop_side
	# При смене ноги или старте удерживаем прежнюю опору, пока стопа уходит с земли.
	if foot_down or _stop < 0.02:
		var sampled := b.stance_driven and b.stance != BikeRide.Stance.RIDING and _stop_side == b.foot_side
		var support := b.foot_support if sampled else b.foot_probe(_stop_side)
		_cur[S_FOOT_X] = support.x
		_cur[S_FOOT_Y] = support.y
		_cur[S_FOOT_Z] = support.z
		var gradient := Basis(Vector3.UP, b.heading) * Vector3(b.bank_slope, 0.0, -b.grade_now)
		_cur[S_FOOT_GRADE_X] = gradient.x
		_cur[S_FOOT_GRADE_Z] = gradient.z
	else:
		_cur[S_FOOT_X] = _prev[S_FOOT_X]
		_cur[S_FOOT_Y] = _prev[S_FOOT_Y]
		_cur[S_FOOT_Z] = _prev[S_FOOT_Z]
		_cur[S_FOOT_GRADE_X] = _prev[S_FOOT_GRADE_X]
		_cur[S_FOOT_GRADE_Z] = _prev[S_FOOT_GRADE_Z]


func _update_idle_gestures(b: BikeRide, dt: float, continuous: bool, calm: bool) -> void:
	_calm_time = _calm_time + dt if calm else 0.0
	_gaze_amp = lerpf(_gaze_amp, smoothstep(3.0, 5.0, _calm_time), Util.damp(1.5 if calm else 9.0, dt)) if continuous else 0.0
	_gaze_phase = fmod(_gaze_phase + dt, 1000.0) if continuous else 0.0
	var wander := sin(_gaze_phase * 0.43) + 0.6 * sin(_gaze_phase * 0.17 + 1.9)
	var glance := signf(wander) * smoothstep(0.55, 1.1, absf(wander))
	var gaze_wide := lerpf(0.17, 0.42, _stop) * (1.0 - 0.5 * smoothstep(6.0, 12.0, absf(b.speed)))
	var gaze_blend := Util.damp(3.5, dt)
	_cur[S_GAZE_YAW] = lerpf(_prev[S_GAZE_YAW], glance * gaze_wide * _gaze_amp, gaze_blend) if continuous else 0.0
	_cur[S_GAZE_PITCH] = lerpf(_prev[S_GAZE_PITCH], sin(_gaze_phase * 0.29 + 0.7) * 0.035 * _gaze_amp, gaze_blend) if continuous else 0.0
	# 12.11: отдых. Через несколько секунд стоянки седок выпрямляется и кладёт на бедро руку со стороны ноги,
	# оставшейся на педали; тяга или ход сразу возвращают руку на руль.
	var rest_goal := 1.0 if _stop > 0.9 and _still_time > 2.5 else 0.0
	_rest = lerpf(_rest, rest_goal, Util.damp(2.4 if rest_goal > _rest else 10.0, dt)) if continuous else 0.0
	_cur[S_REST] = -_rest * _stop_side


## Критически затухающая пружина (zeta = 1): даёт инерцию массы и задержку пика без резиновых колебаний.
static func _spring_step(pos: float, vel: float, goal: float, omega: float, dt: float) -> Vector2:
	var err := pos - goal
	var k := omega * maxf(dt, 0.0)
	var d := exp(-k)
	var b := vel + omega * err
	return Vector2(goal + (err + b * dt) * d, (vel - omega * b * dt) * d)


## 28.11: плавный переход позы к цели — критически задемпфированная пружина (omega, 1/с) вместо сглаживания
## первого порядка: у того скорость скачком прыгает с нуля при смене цели, и поза «дёргается» в начале перехода.
func _ease(key: String, pos: float, goal: float, omega: float, dt: float) -> float:
	var step := _spring_step(pos, float(_ease_vel.get(key, 0.0)), goal, omega, dt)
	_ease_vel[key] = step.y
	return step.x


## Перенестись в текущее состояние без перехода (поставили велосипед, сели или слезли)
func snap(b: BikeRide) -> void:
	if not _view_ready:
		return
	_ease_vel.clear()
	_crank_vel = 0.0
	_prev[S_PLACEMENT] = 0.0
	_cur[S_PLACEMENT] = 0.0
	_set_placement_appearance(1.0)
	# A rider change on the same bicycle preserves the physical position of the pedals.
	var keep_crank := _has_state and _bike_id == b.get_instance_id() and _riding != b.riding and not b.fallen
	var parked_crank := _cur[S_CRANK]
	# Не переносим ускорение и удар через посадку, спешивание или телепорт.
	_has_state = false
	_landing = 0.0
	_breath_phase = 0.0
	_effort = 0.0
	_fatigue = 0.0
	_hit_f = 0.0
	_hit_r = 0.0
	_bar_kick = Vector2.ZERO
	_landing_bias = 0.0
	_rough_stance = 0.0
	_stand = 0.0
	_takeoff = 0.0
	_jump_prep = 0.0
	_stop = 0.0
	_still_time = 0.0
	_coast_time = 0.0
	_coast_level = false
	_calm_time = 0.0
	_gaze_amp = 0.0
	_gaze_phase = 0.0
	_rest = 0.0
	_was_airborne = b.airborne
	_air_pose = 1.0 if b.airborne else 0.0
	_air_body_offset = 0.0
	_prev_ground_mid = 0.0
	_prev_lift_mid = 0.0
	_tilt_align = 0.0
	_pack_swing = Vector2.ZERO
	_pack_velocity = Vector2.ZERO
	_reaction_shift = 0.0
	_reaction_shift_vel = 0.0
	_crouch_vel = 0.0
	_sway_vel = 0.0
	_head_nod_vel = 0.0
	_heat_f = 0.0
	_heat_r = 0.0
	_shudder_phase = 0.0
	tick(b)
	if keep_crank:
		_cur[S_CRANK] = parked_crank
	for i in STATE_SIZE:
		_prev[i] = _cur[i]


func play_placement_appearance() -> void:
	if not _view_ready:
		return
	# Прозрачность мешей поддерживает Forward+. Небольшая посадка рамы видна на любом рендерере.
	if _placement_meshes.is_empty() and RenderingServer.get_current_rendering_method() == "forward_plus":
		for mesh: GeometryInstance3D in find_children("*", "MeshInstance3D", true, false):
			if not rider.is_ancestor_of(mesh) and is_zero_approx(mesh.transparency):
				_placement_meshes.append(mesh)
	_set_placement_appearance(0.0)
	_prev[S_PLACEMENT] = 1.0
	_cur[S_PLACEMENT] = 1.0



func _set_placement_appearance(amount: float) -> void:
	_placement_lift = 0.065 * (1.0 - amount)
	for mesh: GeometryInstance3D in _placement_meshes:
		if is_instance_valid(mesh):
			mesh.transparency = 0.55 * (1.0 - amount)


func cancel_watch() -> void:
	watch_requested = false
	_prev[S_WATCH] = 0.0
	_cur[S_WATCH] = 0.0


## Показать модель в доле alpha (0..1) пути от предпоследнего такта к последнему
func draw(alpha: float, allow_watch := true) -> void:
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
		var angular := i == S_HEADING or i == S_CRANK
		_mix[i] = lerp_angle(_prev[i], _cur[i], alpha) if angular else lerpf(_prev[i], _cur[i], alpha)
	_mix[S_WHEEL_F] = wrapf(_mix[S_WHEEL_F], -PI, PI)
	_mix[S_WHEEL_R] = wrapf(_mix[S_WHEEL_R], -PI, PI)
	# рама и седок опускаются на ход подвески, колёса остаются на земле
	if _placement_lift > 0.0 or _mix[S_PLACEMENT] > 0.0:
		_set_placement_appearance(1.0 - pow(_mix[S_PLACEMENT], 3))
	position = Vector3(_mix[S_X], _mix[S_BODY_Y] + _placement_lift, _mix[S_Z])
	# 12.3: стоя седок раскачивает велосипед под собой в такт педалям (только вид)
	var stop_amount := smoothstep(0.0, 1.0, absf(_mix[S_STOP]))
	var stop_side := -1.0 if _mix[S_STOP] < 0.0 else 1.0
	var ground_height := _mix[S_FOOT_Y] - _mix[S_BODY_Y] - _mix[S_SQUASH]
	var stop_lean := STOP_LEAN * clampf(1.0 - ground_height * 1.5, 0.3, 1.4)
	var pedal_rock := sin(_mix[S_CRANK]) * maxf(_mix[S_STAND], 0.0) * smoothstep(0.0, 0.8, _mix[S_EFFORT]) * ROCK
	rotation = Vector3(_mix[S_TILT], _mix[S_HEADING], _mix[S_ROLL] + pedal_rock - stop_side * stop_amount * stop_lean)
	rear_wheel.position.y = WHEEL_Y + _mix[S_SQUASH_R]
	# Перёд — одно целое на оси рулевой: руль, вилка и колесо поворачиваются вокруг наклонной оси, штаны с колесом
	# ходят вдоль неё. Ход вдоль оси взят таким, чтобы колесо поднялось ровно на ход подвески и осталось на земле.
	var steer_axis := Basis(Vector3.RIGHT, FORK_RAKE).y
	var turn := Basis(steer_axis, -_mix[S_STEER] * _steer_limit)
	var visual_squash_f := minf(_mix[S_SQUASH_F], MAX_FORK_VISUAL_TRAVEL)
	var fork_travel := visual_squash_f / steer_axis.y
	_steering.basis = turn
	front_wheel.position = STEERING_PIVOT + turn * (Vector3(0, WHEEL_Y, -BikeRide.HUB) + steer_axis * fork_travel - STEERING_PIVOT)
	front_wheel.basis = turn * Basis(Vector3.RIGHT, -_mix[S_WHEEL_F])
	for st: Strut in _front_struts:
		_stretch(st, visual_squash_f)
	for st: Strut in _rear_struts:
		_stretch(st, _mix[S_SQUASH_R])
	for lower in _fork_lowers:
		# Штаны идут вдоль ног вилки (их узел уже наклонён), детали оси — на тот же ход вдоль оси рулевой.
		lower.position = Vector3(0, fork_travel, 0) if lower.name == "Lower" else _fork_arch_rest + steer_axis * fork_travel
	if _rear_mechanics != null:
		_rear_mechanics.position.y = _mix[S_SQUASH_R]
	rear_wheel.rotation.x = -_mix[S_WHEEL_R]
	if _rotor_mat_f != null:
		_rotor_mat_f.set_shader_parameter("heat", _mix[S_HEAT_F])
		_rotor_mat_f.set_shader_parameter("wheel_angle", _mix[S_WHEEL_F])
	if _rotor_mat_r != null:
		_rotor_mat_r.set_shader_parameter("heat", _mix[S_HEAT_R])
		_rotor_mat_r.set_shader_parameter("wheel_angle", _mix[S_WHEEL_R])
	for i in _levers.size():
		var lever_pull := smoothstep(0.0, 1.0, _mix[S_BRAKE]) + _mix[S_SHUDDER] * 0.025
		_levers[i].transform = _lever_rest[i] * Transform3D(Basis(Vector3.UP, lever_pull * (0.38 if i == 0 else -0.38)), Vector3.ZERO)
	crank.rotation.x = -_mix[S_CRANK]
	# педали держатся горизонтально
	pedal_l.rotation.x = _mix[S_CRANK]
	pedal_r.rotation.x = _mix[S_CRANK]
	rider.visible = _riding
	# ткань формы треплется на скорости (шейдер, без костей): заметно с 3 м/с, в полную силу к 14 м/с
	_set_wind(smoothstep(3.0, 14.0, _mix[S_SPEED]) if _riding else 0.0)
	if _riding:
		_draw_rider(allow_watch, stop_side, pedal_rock)
		if rider.procedural_pose:
			pedal_l.rotation.x += rider.pedal_pitch.x
			pedal_r.rotation.x += rider.pedal_pitch.y
		if is_instance_valid(_pack_bag) and _pack_bag.is_visible_in_tree():
			_pack_bag.position = PACK_AT + Vector3(_mix[S_PACK_ROLL] * 0.04, -clampf(_mix[S_PACK_PITCH], -0.06, 0.12) * 0.08, maxf(0.0, _mix[S_BREATH]) * 0.4)
			_pack_bag.rotation = Vector3(_mix[S_PACK_PITCH], 0, _mix[S_PACK_ROLL])


func _draw_rider(allow_watch: bool, stop_side: float, pedal_rock := 0.0) -> void:
	var pose := _rider_pose
	var steering_to_rig := _rig_from_bike * _steering.transform
	var crank_to_rig := _rig_from_bike * crank.transform
	pose.left_grip = steering_to_rig * (GRIP * Vector3(-1, 1, 1) - STEERING_PIVOT)
	pose.right_grip = steering_to_rig * (GRIP - STEERING_PIVOT)
	pose.left_pedal = crank_to_rig * pedal_l.position
	pose.right_pedal = crank_to_rig * pedal_r.position
	pose.foot_down = _mix[S_STOP]
	if not is_zero_approx(pose.foot_down):
		pose.ground_point = _rig_from_bike * to_local(Vector3(_mix[S_FOOT_X], _mix[S_FOOT_Y], _mix[S_FOOT_Z]))
		var ground_up := Vector3(-_mix[S_FOOT_GRADE_X], 1.0, -_mix[S_FOOT_GRADE_Z])
		pose.ground_up = (_rig_from_bike.basis * (global_basis.inverse() * ground_up)).normalized()
	else:
		pose.ground_point = Vector3.ZERO
		pose.ground_up = Vector3.UP
	pose.ground_lean = -rotation.z * stop_side
	pose.crank_angle = _mix[S_CRANK]
	pose.tuck = _mix[S_TUCK]
	pose.motion = Vector3(_mix[S_SHIFT], _mix[S_SIDE], _mix[S_CROUCH])
	pose.pitch = _mix[S_TILT]
	pose.roll = _mix[S_ROLL] + pedal_rock
	pose.sway = _mix[S_SWAY]
	pose.breath = _mix[S_BREATH]
	pose.look = _mix[S_LOOK]
	pose.turn_support = _mix[S_TURN_SUPPORT]
	pose.body_look = _mix[S_BODY_LOOK]
	pose.head_nod = _mix[S_HEAD_NOD]
	pose.gaze = Vector2(_mix[S_GAZE_YAW], _mix[S_GAZE_PITCH])
	pose.stand = _mix[S_STAND]
	pose.effort = _mix[S_EFFORT]
	pose.brake = _mix[S_BRAKE_POSE]
	pose.front_load = _mix[S_FRONT_LOAD]
	pose.rear_load = _mix[S_REAR_LOAD]
	pose.balance = _mix[S_BALANCE]
	pose.watch = _mix[S_WATCH] if allow_watch else 0.0
	pose.hand_rest = _mix[S_REST] * (1.0 - pose.watch)
	rider.pose(pose)


## Ход подвески в последнем кадре draw (для камеры, без ступенек 60 Гц)
func view_squash() -> float:
	return _mix[S_SQUASH] if _mix.size() > S_SQUASH else 0.0


func view_roll() -> float:
	return _mix[S_ROLL] if _mix.size() > S_ROLL else 0.0


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
