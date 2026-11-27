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
const FORK_RAKE := 0.30
const GRIP := Vector3(0.24, 1.0, -0.413) # середина правого грипса; левый — зеркально по X
const STEER_VIEW := 0.6  # поворот переднего колеса в долях угла руля (30.10: было 0,35 — поворот читался как крен)
const Lamp = preload("res://scripts/render/bike_lamp.gd")
const BikePalette := preload("res://scripts/render/bike_palette.gd")
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
const S_HEAT_F := 28     # нагрев переднего тормозного диска (0..1)
const S_HEAT_R := 29     # нагрев заднего тормозного диска (0..1)
const S_SHUDDER := 30    # мелкая дрожь вилки и руля при торможении на грани юза
const S_STOP := 31      # 11.11: стоянка — нога на земле (знак — сторона: − левая, + правая)
const S_GAZE_YAW := 32  # взгляд по сторонам в спокойной езде и на стоянке (только голова)
const S_GAZE_PITCH := 33
const S_REST := 34      # 12.11: отдых на долгой стоянке — рука на бедре (знак — сторона руки)
const S_SHAKE := 35     # 12.11: встряхнуть кисть в спокойной езде (знак — сторона руки)
const S_SHAKE_WIG := 36 # взмах кисти
const S_BRAKE_POSE := 37 # 12.11: поза торможения корпуса — входит и выходит плавно, ручки (S_BRAKE) жмутся сразу
const S_WATCH := 38
const S_FOOT_GROUND := 39
const S_SPEED := 40
const WATCH_RAISE := 0.34
const WATCH_LOWER := 0.25
const WATCH_BRACE := 0.09
const S_BALANCE := 41 # signed side of the catch leg
const S_TRACK := 42
const S_WHEEL_F := 43
const S_WHEEL_R := 44
const S_PLACEMENT := 45 # remaining fraction of the placement settle
const S_FOOT_GRADE_X := 46 # world-space surface gradient at the planted foot
const S_FOOT_GRADE_Z := 47
const STATE_SIZE := 48
const SURGE_STAND := 0.85 # насколько седок встаёт в рывке (1 — как на крутом подъёме)
const TURN_IN_SWAY := 0.007 # плечи доворачиваются в поворот на резком движении руля, рад на долю хода руля в секунду
const STOP_LEAN := 0.085 # наклон велосипеда к опорной ноге на стоянке, рад (только вид)
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
var watch_requested := false
var _wheel_rates := Vector2.ZERO # rad/s, kept separately when a wheel leaves its support
var _bike_id := 0
var _last_crank := 0.0
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
var _takeoff := 0.0
var _jump_prep := 0.0
var _recovery := 0.0
var _fatigue := 0.0
var _prev_steer := 0.0
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
var _fork_arch_rest := Vector3.ZERO
var _steering: Node3D
var _levers: Array[Node3D] = []
var _lever_rest: Array[Transform3D] = []
var _view_ready := false
## Живые мелочи вида: нога на земле при остановке, ровные педали на накате, взгляд по сторонам.
## Выключается в проверках, которым нужна неподвижная посадка.
var idle_life := true
var _stop := 0.0
var _foot_support_y := 0.0
var _stop_side := -1.0
var _still_time := 0.0
var _coast_time := 0.0
var _calm_time := 0.0
var _gaze_amp := 0.0
var _gaze_phase := 0.0
var _rest := 0.0
var _shake := 0.0
var _shake_side := 1.0
var _shake_flip := false
var _shake_time := 0.0
var _shake_next := 14.0
var _wobble_phase := 0.0
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
var _absorb := 0.0 # 20.11: сглаженное пассивное поглощение гребня (BikeRide.crest_absorb)
const ABSORB_CROUCH := 0.06 # м приседа на полном поглощении (ручной памп — до 0,065 по pump_motion)
const ABSORB_STAND := 0.4   # насколько седок уходит ниже обычной стойки (ручной памп — 0,5)
var heat_source: BrakeEffects = null # GameWorld и Trail Lab: один расчёт нагрева дисков на такт
var _shudder_phase := 0.0
var lamp: Lamp
var _skin_mats: Array[ShaderMaterial] = []
var _rear_mechanics: Node3D
var _wind := 0.0
var _placement_lift := 0.0
var _placement_meshes: Array[GeometryInstance3D] = []

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
	for mat in _skin_mats:
		mat.set_shader_parameter("palette", colors)


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
	_cur[S_PLACEMENT] = maxf(0.0, _prev[S_PLACEMENT] - dt / 0.15)
	_cur[S_X] = b.x
	_cur[S_SPEED] = absf(b.speed) if b.riding and not b.airborne else absf(b.speed) * 0.8
	# рама — посередине между концами подвесок, каждый на своём ходе над точкой касания колеса
	_cur[S_BODY_Y] = b.y + (b.ground_f + b.ground_r) * 0.5 - (b.squash_f + b.squash_r) * 0.5
	_cur[S_Z] = b.z
	_cur[S_TILT] = b.tilt
	var cfg := b.config if b.config != null else BikePhysicsConfig.current()
	_cur[S_BRAKE] = maxf(b.brakes.pressure, clampf(b.brake_applied / cfg.brake_decel, 0.0, 1.0)) if not b.airborne else 0.0
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
	_update_wheel_spin(b, dt)
	_cur[S_STEER] = b.steer_shown() # 13.11: руль на модели — фактический поворот, а не команда (BikeRide.steer_shown)
	_cur[S_CRANK] = wrapf(_pedal_angle(b, dt), -PI, PI) if _has_state else b.crank
	_last_crank = b.crank
	_bike_id = b.get_instance_id()
	_cur[S_TUCK] = clampf(absf(b.speed) / cfg.cruise_speed, 0.0, 1.0) * 0.08
	_update_rider(b, dt, throttle, boost)
	var safe := absf(_cur[S_BALANCE]) < 0.18 and b.instability < 0.25 and b.speed > -0.1 and not b.airborne and not boost and not b.pump_pressed and absf(b.speed) <= 11.0 \
		and absf(b.steer) < 0.33 and absf(b.lean) < 0.22 and absf(b.slip) < 0.12 \
		and throttle > -0.15 and _cur[S_BRAKE] < 0.16 and absf(_stand) < 0.42 \
		and b.land_impact < 1.0 and _jump_prep < 0.1
	var raising := watch_requested and safe
	var duration := WATCH_RAISE if raising else (WATCH_LOWER if safe else WATCH_BRACE)
	_cur[S_WATCH] = move_toward(_prev[S_WATCH], float(raising), dt / duration) if b.riding and not b.fallen else 0.0
	# Отдача руля от удара переднего колеса — только вид: руль дёргается в сторону, курс не меняется.
	_cur[S_STEER] += _bar_kick.x
	# 11.11: стоя на педалях седок тянет руль в такт: колесо чуть виляет навстречу раскачке рамы (только вид)
	_cur[S_STEER] -= sin(_cur[S_CRANK]) * maxf(_stand, 0.0) * 0.07 * (1.0 - smoothstep(4.0, 9.0, absf(b.speed)))
	_cur[S_STEER] += _cur[S_BALANCE] * 0.22 + sin(_wobble_phase) * _cur[S_TRACK] * 0.20
	_cur[S_ROLL] += (-_cur[S_BALANCE] * 0.05 + sin(_wobble_phase) * _cur[S_TRACK] * 0.025) * (1.0 - smoothstep(0.0, 1.0, absf(_cur[S_STOP])))
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
	# Мелкая высокочастотная вибрация вилки и ручек тормоза при насыщении сцепления (skid)
	_shudder_phase = fmod(_shudder_phase + dt * (42.0 + spd * 3.5), TAU)
	var shudder_amp := clampf(b.brakes.skid * 0.8 + maxf(0.0, b.use_f - 0.78) * 1.6, 0.0, 1.0) * _cur[S_BRAKE] * smoothstep(0.6, 2.5, spd)
	_cur[S_SHUDDER] = sin(_shudder_phase) * shudder_amp
	_riding = b.riding
	_fallen = b.fallen
	_fallen_transform = b.fallen_transform
	if not _has_state:
		_prev = _cur.duplicate()
		_has_state = true


## A tyre can follow the road speed only through contact. In flight keep its release spin.
func _update_wheel_spin(b: BikeRide, dt: float) -> void:
	var road_step := angle_difference(_prev[S_WHEEL], b.wheel)
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
			var drag := b.brakes.skid * smoothstep(0.60, 1.0, use)
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
		return angle + step
	var driving := not b.airborne and (absf(step) > 0.00001 or b.effort > 0.08)
	_coast_time = _coast_time + dt if idle_life and not driving and not b.airborne else 0.0
	if b._manual_reverse and not b.airborne:
		return angle + minf(0.0, b.speed) * dt / (BikeRide.WHEEL_R * maxf(1.0, b.gear))
	if driving:
		return angle + step
	var level := PI * 0.5 + roundf((angle - PI * 0.5) / PI) * PI
	var target := lerp_angle(angle, level, smoothstep(0.22, 0.40, _coast_time))
	if b.airborne:
		target = level
	else:
		var corner := smoothstep(0.15, 0.34, absf(b.lean))
		target = lerp_angle(target, PI if b.lean < 0.0 else 0.0, corner)
		var ready := -0.9 if _stop_side < 0.0 else PI - 0.9
		target = lerp_angle(target, ready, smoothstep(0.0, 1.0, _stop))
	var response := Util.damp(12.0 if b.airborne else 8.0, dt)
	return rotate_toward(angle, target, minf(5.5 * dt, absf(angle_difference(angle, target)) * response))


## Реакции считаются только на тактах физики; draw лишь интерполирует готовую позу.
func _update_rider(b: BikeRide, dt: float, _throttle: float, boost: bool) -> void:
	var continuous := _has_state and _riding and b.riding
	# продольное ускорение по мировой скорости за тот же такт, что и у камеры (BikeRide.feel_acceleration)
	var acceleration := clampf(b.feel_acceleration, -9.0, 7.0) if continuous else 0.0
	# Уклон земли, а не наклон рамы: подвеска и движение тела не выдают себя за подъём.
	var slope := clampf(b.grade_now, -0.5, 0.5) if not b.airborne else 0.0
	# Усилие — то же состояние, что даёт тягу (BikeRide.effort), тяжесть — реализованная тяга и подъём.
	var cfg := b.config if b.config != null else BikePhysicsConfig.current()
	var drive := b.effort if not b.airborne else 0.0
	var work := clampf(b.drive_force / (cfg.pedal_accel * cfg.pedal_push_mult), 0.0, 1.0)
	var load := smoothstep(0.04, 0.25, slope) * drive
	var effort_target := maxf(drive * 0.6 + work * 0.4, load * LOAD_EFFORT) * (1.25 if boost else 1.0)
	# Набирается вместе с тягой, без своего запаздывания; отпускание педалей не обрывает дыхание и плечи.
	if effort_target > _effort:
		_effort = effort_target if continuous else 0.0
	else:
		_effort = lerpf(_effort, effort_target, Util.damp(5.0, dt)) if continuous else 0.0
	var effort := _effort
	var braking := clampf(b.brake_applied / cfg.brake_decel, 0.0, 1.0) if not b.airborne else 0.0
	# корпус входит в позу торможения за ~0,12 с и выходит за ~0,25 с: раньше поза повторяла ручку такт в такт
	_cur[S_BRAKE_POSE] = lerpf(_prev[S_BRAKE_POSE], _cur[S_BRAKE], Util.damp(9.0 if _cur[S_BRAKE] > _prev[S_BRAKE_POSE] else 4.5, dt)) if continuous else _cur[S_BRAKE]
	# 12.3: на крутом подъёме под нагрузкой и в рывок с места седок встаёт с седла;
	# на быстром спуске без педалей и на тряске — приподнимается и принимает удары ногами.
	var climb := smoothstep(0.07, 0.16, slope) * smoothstep(0.45, 0.85, effort) * (1.0 - smoothstep(7.0, 11.0, absf(b.speed)))
	var sprint := smoothstep(1.5, 3.5, acceleration) * (1.0 - smoothstep(6.0, 10.0, absf(b.speed))) if boost else 0.0
	# 12.11: рывок на Shift (BikeRide.surge) — седок встаёт на педали и раскачивает велосипед на любой скорости,
	# пока длится прилив и он давит на педали; раньше стойка была только при разгоне до 10 м/с
	if b.surge > 0.0 and not b.airborne:
		sprint = maxf(sprint, smoothstep(0.0, 0.5, b.surge) * smoothstep(0.3, 0.7, effort) * SURGE_STAND)
	var descent := smoothstep(0.06, 0.16, -slope) * (1.0 - effort) * smoothstep(4.0, 8.0, absf(b.speed))
	# Фаза 1 прыжка — подготовка (preload): сжатие перед отрывом (буфер прыжка, авто-хоп, рывок Q или волна).
	var prep_raw := (0.85 if b.hop_preparing else 0.0) + maxf(0.0, b.body_v) * 0.22
	var prep_goal := clampf(prep_raw, 0.0, 1.0) if continuous and not b.airborne else 0.0
	_jump_prep = lerpf(_jump_prep, prep_goal, Util.damp(22.0 if prep_goal > _jump_prep else 10.0, dt)) if continuous else 0.0
	var stand_target := (maxf(climb, sprint) - descent if not b.airborne else -0.65) if continuous else 0.0
	var brace := maxf(b.brakes.risk, b.brakes.brace * smoothstep(0.54, 0.95, b.brakes.front_load)) if not b.airborne else 0.0
	var track := float(b._stance_driven and b.stance == BikeRide.Stance.TRACKSTAND and not b.airborne)
	_cur[S_TRACK] = lerpf(_prev[S_TRACK], track, Util.damp(8.0, dt)) if continuous else 0.0
	stand_target = lerpf(stand_target, 0.32, _cur[S_TRACK])
	if brace > 0.0:
		stand_target = lerpf(stand_target, -1.0, brace)
	if not b.airborne and b.riding and absf(b.pump_motion) > 0.01:
		stand_target = minf(stand_target, -absf(b.pump_motion) * 0.5)
	# 20.11: пассивное поглощение гребня (памп не зажат): ноги и руки сгибаются навстречу гребню, слабее ручного пампа.
	# Набирается быстро (гребень короткий), отпускается мягче — без щелчка позы на каждой волне.
	var absorb_goal := b.crest_absorb if continuous and not b.airborne else 0.0
	_absorb = lerpf(_absorb, absorb_goal, Util.damp(18.0 if absorb_goal > _absorb else 6.0, dt)) if continuous else 0.0
	# Legs carry the rider between closely spaced bumps; isolated contacts still read at the limbs.
	var fork_rate := b.squash_fv if b.contact_f() else 0.0
	var rear_rate := b.squash_rv if b.contact_r() else 0.0
	var stroke_rate := maxf(fork_rate, rear_rate)
	var activity := maxf(smoothstep(0.65, 2.2, stroke_rate), maxf(_hit_f, _hit_r))
	activity *= smoothstep(0.6, 3.2, absf(b.speed)) if not b.airborne else 0.0
	_rough_stance = lerpf(_rough_stance, activity, Util.damp(5.0 if activity > _rough_stance else 3.0, dt)) if continuous else 0.0
	stand_target = lerpf(stand_target, -0.72, _rough_stance)
	if _absorb > 0.01:
		stand_target = minf(stand_target, -_absorb * ABSORB_STAND)
	_stand = lerpf(_stand, stand_target, 1.0 - exp(-dt * (4.0 if absf(stand_target) > absf(_stand) else 2.5))) if continuous else 0.0
	var up := maxf(_stand, 0.0)
	# Передний толчок подаёт плечи назад, задний — вперёд. В воздухе и на месте реакции нет.
	var road_shift := clampf((fork_rate - rear_rate) * 0.004, -0.012, 0.012)
	road_shift *= smoothstep(0.5, 3.0, absf(b.speed)) if not b.airborne else 0.0
	# Под нагрузкой подаёмся вперёд; при торможении и спуске уходим назад.
	# 12.3: заметнее — разгон, подъём и тормоз двигают корпус до 9 см (было 5,5).
	# Тормоз заменяет обычную инерционную компенсацию, а не складывается с ней.
	# Инерцию сначала принимают руки и ноги — по силе в пятнах контакта (тяга, тормоз), а не по итоговому изменению
	# скорости: тормоз, держащий скорость на спуске, виден, а потеря хода в подъём не выглядит торможением.
	# Затем таз компенсирует перенос (brace, с запаздыванием).
	var contact := clampf(b.contact_acceleration, -9.0, 7.0) if continuous and not b.airborne else 0.0
	var arms := clampf(-contact * 0.009, -0.06, 0.08)
	var inertia_shift := arms * (1.0 - b.brakes.brace * braking) + b.brakes.brace * cfg.brake_shift * braking
	# Удар колеса о кромку — своё событие (не приземление): переднее принимают руки — плечи коротко уходят назад,
	# заднее — ноги, таз приподнимается над седлом. Сила — по скорости удара колеса.
	_hit_f *= exp(-dt * 9.0)
	_hit_r *= exp(-dt * 9.0)
	if continuous:
		_bar_kick.y = clampf(_bar_kick.y + b.fork_side_impulse * 3.5, -6.0, 6.0)
		_bar_kick = _spring_step(_bar_kick.x, _bar_kick.y, 0.0, 18.0, dt)
		var fork_stop := smoothstep(cfg.bottom_out_speed, cfg.bottom_out_speed + 2.2, b.bottom_out)
		var front_hit := maxf(clampf(b.wheel_impact.x / 1.5, 0.0, 1.0), fork_stop)
		var rear_hit := clampf(b.wheel_impact.y / 1.5, 0.0, 1.0)
		# Each new contact uses the remaining range, even during recovery from the last.
		_hit_f += (1.0 - _hit_f) * front_hit
		_hit_r += (1.0 - _hit_r) * rear_hit
	# Q/E — то же положение тела, что в физике (body_x: + назад): назад — таз к заднему колесу, руки выпрямлены и тянут
	# руль; вперёд — плечи над рулём, ноги подтягивают раму. Без своего сглаживания: окно рывка — доли секунды.
	var body := clampf(b.body_x, -1.0, 1.0) if continuous else 0.0
	var moving := smoothstep(0.5, 3.0, absf(b.speed)) if not b.airborne else 0.0
	# Фазы прыжка: 2) отрыв (_takeoff), 3) полёт (airborne), 4) приземление (_landing), 5) восстановление (_recovery).
	_takeoff *= exp(-dt * 9.5)
	if continuous and b.airborne and not _was_airborne:
		_takeoff = 1.0 if b.hop_used else lerpf(0.18, 0.90, _jump_prep)
	_was_airborne = b.airborne
	_landing *= exp(-dt * 5.5)
	if continuous and b.land_impact > 0.0:
		var impact := clampf(b.land_impact / 9.0, 0.0, 1.0)
		var angle := float(b.landing_info.get("pitch_error", b.tilt - atan(b.grade_now)))
		var bias := -clampf(angle / 0.32, -1.0, 1.0)
		_landing_bias = lerpf(_landing_bias, bias, impact / maxf(impact + _landing, 0.0001))
		_landing += (1.0 - _landing) * impact
	var recovery_goal := _landing * 0.85 if _landing > 0.02 else 0.0
	_recovery = lerpf(_recovery, recovery_goal, Util.damp(3.5 if recovery_goal > _recovery else 6.0, dt)) if continuous else 0.0
	var rebound := maxf(0.0, _recovery - _landing * 0.72)
	# Последовательный приём нагрузки:
	# 1) Передний удар и сжатие вилки сразу принимают руки (front_load), задний удар, подготовка и приземление — ноги и таз (rear_load).
	var front_landing := _landing * (0.53 + 0.38 * _landing_bias)
	var rear_landing := _landing * (0.67 - 0.30 * _landing_bias)
	var front_goal := clampf(front_landing + smoothstep(0.55, 1.35, b.load_f) * 0.32 + _hit_f * 0.90 + maxf(0.0, fork_rate) * 0.14 * moving + _jump_prep * 0.25, 0.0, 1.0)
	var rear_goal := clampf(smoothstep(0.55, 1.35, b.load_r) * 0.32 + _hit_r * 0.90 + rear_landing + maxf(0.0, rear_rate) * 0.14 * moving + _jump_prep * 0.35, 0.0, 1.0)
	var limb_blend := Util.damp(28.0, dt)
	var front_load := maxf(maxf(_hit_f * 0.85, front_landing * 0.85), lerpf(_prev[S_FRONT_LOAD], front_goal, limb_blend)) if continuous else front_goal
	var rear_load := maxf(maxf(_hit_r * 0.85, rear_landing * 0.85), lerpf(_prev[S_REAR_LOAD], rear_goal, limb_blend)) if continuous else rear_goal
	# Приоритеты смешивания: торможение и удар подавляют раскачку педалирования, чтобы реакции не складывались в случайную позу.
	var impact_priority := clampf(front_load * 0.65 + rear_load * 0.75, 0.0, 1.0)
	var pedal_priority := (1.0 - braking * 0.85) * (1.0 - impact_priority * 0.65) * (1.0 - 0.8 * b.instability)
	var active_effort := effort * pedal_priority
	var air_pitch_shift := clampf(b.pitch_vel * 0.055 - b.vy * 0.004, -0.07, 0.07) if b.airborne else 0.0
	# 30.10: ход тела заметнее (было body · 0,1 в пределах −0,1…0,14): Q и E читаются на фоне реакций подвески
	var shift := clampf(inertia_shift - slope * 0.16 - active_effort * 0.015 + road_shift + _hit_f * 0.038 - _hit_r * 0.018 + body * 0.17 + _jump_prep * 0.022 + _takeoff * 0.038 + air_pitch_shift + _landing * _landing_bias * 0.060 - rebound * 0.038, -0.17, 0.2)
	# 12.11: на стоянке седок не замирает — медленно переносит вес (фаза и доля стоянки — с прошлого такта)
	shift = clampf(shift + sin(_gaze_phase * 0.23 + 1.0) * 0.006 * _stop, -0.17, 0.2)
	var backwards := smoothstep(0.04, 0.8, -b.speed)
	var reverse_look := backwards if b._manual_reverse else 0.0
	shift -= backwards * (1.0 - reverse_look) * 0.07
	shift += brace * 0.055
	_wobble_phase = fmod(_wobble_phase + dt * 3.4, TAU) if continuous else 0.0
	var distress := maxf(smoothstep(0.18, 0.85, b.instability), maxf(b.brakes.skid * smoothstep(0.12, 0.35, absf(b.slip)), smoothstep(0.18, 0.45, absf(b.slip))))
	var fall_side := clampf(b.lateral_speed * 1.8 + b.slip * 1.5 - b.bank_slope * 2.0 - b.lean, -1.0, 1.0)
	var catch_goal := distress * fall_side * (1.0 - _stop) if not b.airborne else 0.0
	_cur[S_BALANCE] = lerpf(_prev[S_BALANCE], catch_goal, Util.damp(9.0, dt)) if continuous else 0.0
	var carve_side := smoothstep(0.05, 0.22, absf(b.lean))
	var side := clampf(sin(_gaze_phase * 0.37) * 0.007 * _stop - b.lean * 0.13 * carve_side - b.slip * 0.10 + sin(_cur[S_CRANK]) * active_effort * (0.012 + up * 0.02), -0.068, 0.068)
	side -= _cur[S_BALANCE] * 0.10 + sin(_wobble_phase) * _cur[S_TRACK] * 0.035
	# В полёте компактная стойка; на отрыве (_takeoff) седок сначала разгибается вверх из подготовки и вытягивает руль,
	# затем группируется в полёте, на приземлении глубоко гасит удар и в фазе восстановления (rebound) возвращается в стойку.
	var pedal_bob := (1.0 - cos(_cur[S_CRANK] * 2.0)) * active_effort * 0.0045
	var compression := maxf(fork_rate, 0.0) + maxf(rear_rate, 0.0)
	var extension := maxf(-fork_rate, 0.0) + maxf(-rear_rate, 0.0)
	var rough := clampf(compression * 0.012 - extension * 0.004, -0.012, 0.035) * moving
	# A landing that also bottoms the fork is one compression of the body.
	var edge_crouch := _hit_f * 0.045 + _hit_r * 0.035
	var shock_crouch := _landing * (LAND_CROUCH + 0.025) + edge_crouch * (1.0 - 0.8 * _landing)
	var air_crouch := (AIR_CROUCH * (1.0 - _takeoff * 0.85) - _takeoff * 0.022) if b.airborne else 0.0
	# Extend from the flight tuck as the measured gap closes. A rising lip can
	# approach the wheels even when vertical world speed is still positive.
	if b.airborne and b.clearance_closing_speed > 0.0:
		var seconds_to_contact := b.air_clearance / b.clearance_closing_speed
		var prepare := (1.0 - smoothstep(0.04, 0.20, seconds_to_contact)) * smoothstep(0.4, 2.0, b.clearance_closing_speed)
		air_crouch -= 0.050 * prepare * smoothstep(0.04, 0.14, b.air_time)
	var base_crouch := rough + air_crouch + _jump_prep * (1.0 - _takeoff) * 0.058 + braking * 0.04 * (1.0 - _landing * 0.5) + pedal_bob + active_effort * smoothstep(0.0, 0.12, slope) * 0.02 - rebound * 0.020
	var crouch := base_crouch + shock_crouch + maxf(body, 0.0) * 0.07
	crouch += b.pump_motion * 0.065 if not b.airborne else 0.0
	crouch += _absorb * ABSORB_CROUCH
	# ручной памп: поглощение (Q на волне) сгибает руки и ноги, продавливание (E) выпрямляет их в велосипед
	crouch -= b.pump_body * 0.15 if not b.airborne else 0.0
	crouch += b.instability * 0.032 if not b.airborne else 0.0
	# Опережение взглядом: учитываем руль, скорость поворота руля, угловую скорость дуги (_yaw_rate), крен и угол сноса (slip).
	var steer_vel := clampf((b.steer - _prev_steer) / maxf(dt, 0.001), -6.0, 6.0) if continuous else 0.0
	_prev_steer = b.steer
	var turn_pace := maxf(smoothstep(0.2, 3.0, absf(b.speed)), smoothstep(0.05, 0.25, absf(b.steer)))
	var dir_signal := -b.steer * 0.27 - steer_vel * 0.018 + b.yaw_rate * 0.11 + b.lean * 0.16 - b.slip * 0.32
	var look := clampf(dir_signal * turn_pace + reverse_look * 0.58, -0.60, 0.60)
	# 11.11 / Stage 5: стоянка управляется физикой (BikeRide.stance), с резервом для стендов без step().
	var foot_down := false
	if b._stance_driven:
		foot_down = continuous and idle_life and not b.airborne and b.stance == BikeRide.Stance.FOOT_DOWN
		_still_time = _still_time + dt if foot_down else 0.0
		if foot_down and _stop_side != b.foot_side:
			if _stop < 0.02:
				_stop_side = b.foot_side
			else:
				foot_down = false
	else:
		var still := continuous and idle_life and not b.airborne and absf(b.speed) < 0.35 and b.effort < 0.05 and absf(b.lean) < 0.1
		_still_time = _still_time + dt if still else 0.0
		if _stop < 0.01 and still:
			_stop_side = 1.0 if b.lean < -0.01 else -1.0
		foot_down = _still_time > cfg.stop_settle_time
	var stop_goal := 1.0 if foot_down else 0.0
	_stop = lerpf(_stop, stop_goal, Util.damp(5.0 if stop_goal > _stop else 9.0, dt)) if continuous else 0.0
	_cur[S_STOP] = _stop * _stop_side
	# Local vertical distance from the frame origin to the sampled foot support.
	if foot_down or _stop < 0.02:
		_foot_support_y = b.y + b.foot_ground_y
		var gradient := Basis(Vector3.UP, b.heading) * Vector3(b.bank_slope, 0.0, -b.grade_now)
		_cur[S_FOOT_GRADE_X] = gradient.x
		_cur[S_FOOT_GRADE_Z] = gradient.z
	else:
		_cur[S_FOOT_GRADE_X] = _prev[S_FOOT_GRADE_X]
		_cur[S_FOOT_GRADE_Z] = _prev[S_FOOT_GRADE_Z]
	_cur[S_FOOT_GROUND] = _foot_support_y - _cur[S_BODY_Y] if continuous else 0.0
	# 11.11: взгляд. После нескольких секунд спокойной езды голова время от времени поворачивается к обочине и
	# возвращается; на стоянке седок осматривается шире. Поворот, тормоз, удар и тяжёлая работа сразу возвращают взгляд.
	var calm := distress < 0.15 and backwards < 0.05 and continuous and idle_life and not b.airborne and braking < 0.1 and impact_priority < 0.1 and absf(look) < 0.08 and effort < 0.6
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
	# 12.11: в долгой спокойной езде по прямой седок изредка снимает руку с руля и встряхивает кисть (руки по очереди);
	# поворот, тормоз, удар, привставание, уклон и быстрая езда возвращают руку сразу.
	var cruise := calm and _stop < 0.01 and absf(b.speed) > 2.0 and absf(b.speed) < 9.0 and absf(_stand) < 0.15 and absf(b.steer) < 0.06 and absf(b.lean) < 0.05 and absf(slope) < 0.08
	_shake_time = _shake_time + dt if cruise else 0.0
	if _shake_time > _shake_next + 1.7:
		_shake_time = 0.0
		_shake_next = 13.0 + fmod(_gaze_phase * 7.3, 11.0)
		_shake_flip = true
	if _shake_flip and _shake < 0.01:
		_shake_side = -_shake_side
		_shake_flip = false
	var shake_goal := 1.0 if cruise and _shake_time > _shake_next else 0.0
	_shake = lerpf(_shake, shake_goal, Util.damp(6.0 if shake_goal > _shake else 12.0, dt)) if continuous else 0.0
	_cur[S_SHAKE] = _shake * _shake_side
	_cur[S_SHAKE_WIG] = sin(_gaze_phase * 21.0) * smoothstep(0.6, 1.0, _shake)
	# Плечи чуть сопровождают нажатие на педаль, таз отвечает встречным движением.
	var sway := sin(_cur[S_CRANK]) * active_effort * (0.055 + up * 0.06)
	# 12.11: на резком довороте плечи идут в поворот вместе с рулём (пружина корпуса сгладит), таз — чуть наружу
	sway -= clampf(steer_vel, -4.0, 4.0) * TURN_IN_SWAY * moving
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
	# 12.11: уставший седок опускает голову (после подъёма, рывка), отдышавшись — поднимает
	var head_nod_goal := clampf(-_fatigue * 0.03 * (1.0 - _landing) - _torso_shock - _jump_prep * 0.018 + _takeoff * 0.042 + air_look_pitch + rebound * 0.015 + sin(_cur[S_CRANK] * 2.0) * active_effort * 0.012, -0.08, 0.06)
	if continuous:
		var nod_step := _spring_step(_prev[S_HEAD_NOD], _head_nod_vel, head_nod_goal, 9.5, dt)
		_cur[S_HEAD_NOD] = nod_step.x
		_head_nod_vel = nod_step.y
	else:
		_cur[S_HEAD_NOD] = 0.0
		_head_nod_vel = 0.0
	# Движение экипировки (сумки) подчинено реальной нагрузке (разгон, удары, прыжок, приземление, крен и работа стоя)
	# и затухает без постоянного одинакового покачивания.
	var pack_pitch_goal := clampf(acceleration * 0.007 + _landing * 0.13 - _takeoff * 0.05 + (_hit_f * 0.05 - _hit_r * 0.04) + (fork_rate + rear_rate) * 0.008 * moving + absf(sway) * 0.18, -0.09, 0.14)
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
	_recovery = 0.0
	_prev_steer = b.steer
	_stop = 0.0
	_still_time = 0.0
	_coast_time = 0.0
	_calm_time = 0.0
	_gaze_amp = 0.0
	_gaze_phase = 0.0
	_rest = 0.0
	_shake = 0.0
	_shake_time = 0.0
	_shake_flip = false
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
	_heat_f = 0.0
	_heat_r = 0.0
	_absorb = 0.0
	_shudder_phase = 0.0
	_wobble_phase = 0.0
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
		var angular := i == S_HEADING or i == S_WHEEL or i == S_CRANK
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
	var stop_lean := STOP_LEAN * clampf(1.0 - (_mix[S_FOOT_GROUND] - _mix[S_SQUASH]) * 1.5, 0.3, 1.4)
	rotation = Vector3(_mix[S_TILT], _mix[S_HEADING], _mix[S_ROLL] + sin(_mix[S_CRANK]) * maxf(_mix[S_STAND], 0.0) * ROCK - stop_side * stop_amount * stop_lean)
	rear_wheel.position.y = WHEEL_Y + _mix[S_SQUASH_R]
	# Перёд — одно целое на оси рулевой: руль, вилка и колесо поворачиваются вокруг наклонной оси, штаны с колесом
	# ходят вдоль неё. Ход вдоль оси взят таким, чтобы колесо поднялось ровно на ход подвески и осталось на земле.
	var steer_axis := Basis(Vector3.RIGHT, FORK_RAKE).y
	var turn := Basis(steer_axis, -_mix[S_STEER] * STEER_VIEW + _mix[S_SHUDDER] * 0.014)
	var fork_travel := _mix[S_SQUASH_F] / steer_axis.y
	_steering.basis = turn
	front_wheel.position = STEERING_PIVOT + turn * (Vector3(0, WHEEL_Y, -BikeRide.HUB) + steer_axis * fork_travel - STEERING_PIVOT)
	front_wheel.basis = turn * Basis(Vector3.RIGHT, -_mix[S_WHEEL_F])
	for st: Strut in _front_struts:
		_stretch(st, _mix[S_SQUASH_F])
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
		# Небольшая группировка на скорости и работа корпусом при сжатии подвески.
		var tuck := _mix[S_TUCK] + clampf(_mix[S_SQUASH], 0.0, 0.12) * 0.4
		var grip_l := _steering.position + _steering.basis * (GRIP * Vector3(-1, 1, 1) - STEERING_PIVOT)
		var grip_r := _steering.position + _steering.basis * (GRIP - STEERING_PIVOT)
		var motion := Vector3(_mix[S_SHIFT], _mix[S_SIDE], _mix[S_CROUCH])
		# Solve the local sole height for the interpolated frame pitch and roll.
		var foot_ground := (_mix[S_FOOT_GROUND] - basis.x.y * stop_side * 0.27 + basis.z.y * 0.06) / maxf(0.1, basis.y.y)
		var ground_up := basis.inverse() * Vector3(-_mix[S_FOOT_GRADE_X], 1.0, -_mix[S_FOOT_GRADE_Z]).normalized() if stop_amount > 0.0 else Vector3.UP
		var watch := _mix[S_WATCH] if allow_watch else 0.0
		var gaze := Vector2(_mix[S_GAZE_YAW], _mix[S_GAZE_PITCH])
		rider.pose(_mix[S_CRANK], tuck, grip_l, grip_r, motion, _mix[S_LOOK], _mix[S_TILT], _mix[S_ROLL], _mix[S_SWAY], _mix[S_BREATH], _mix[S_BODY_LOOK] - _mix[S_LOOK], _mix[S_STAND], _mix[S_HEAD_NOD], _mix[S_EFFORT], _mix[S_BRAKE_POSE], _mix[S_FRONT_LOAD], _mix[S_REAR_LOAD],
				_mix[S_STOP], foot_ground, -rotation.z * stop_side, gaze, _mix[S_REST] * (1.0 - watch), Vector2(_mix[S_SHAKE] * (1.0 - watch), _mix[S_SHAKE_WIG]), watch, _mix[S_BALANCE], ground_up)
		if rider.procedural_pose:
			pedal_l.rotation.x += rider.pedal_pitch.x
			pedal_r.rotation.x += rider.pedal_pitch.y
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
