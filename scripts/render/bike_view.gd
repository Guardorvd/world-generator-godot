class_name BikeView
extends Node3D
## Велосипед с седоком, сцена scenes/bike.tscn: стилизованная модель со скелетным седоком, смотрит вдоль -Z.
## Повторяет состояние BikeRide: место, курс, наклон, крен, вращение колёс и педалей, ход подвески.
## С 7.1 колёса стоят на своих точках касания, а вилка и задние перья тянутся к осям: видно сжатие каждого колеса.
## Ноги седока ставятся на педали (два звена: бедро и голень). Езда считается тактами физики (60 в секунду),
## а кадров бывает и 800: между двумя последними тактами модель плавно переходит (draw), иначе дёргалась бы.

const WHEEL_Y := 0.34    # высота осей колёс над землёй
const STEER_VIEW := 0.35 # поворот переднего колеса в долях угла руля

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
const STATE_SIZE := 17

# состояние на двух последних тактах (индексы S_*)
var _prev := PackedFloat64Array()
var _cur := PackedFloat64Array()
var _mix := PackedFloat64Array() # буфер для draw, чтобы не выделять память на каждый кадр
var _riding := false
var _has_state := false
var _last_speed := 0.0
var _last_crank := 0.0
var _landing := 0.0
var _steering: Node3D
# перья, которые тянутся к оси колеса: [узел, неподвижный конец, конец у оси, длина]; передние — вилка
var _front_struts: Array = []
var _rear_struts: Array = []
## 10.4: фара на руле (F): видимый корпус со стеклом и два прожектора — дальний узкий луч и мягкая
## ближняя заливка. Поворачивается с рулём и наклоняется с рамой, как настоящая велофара
var lamp: Node3D
var _lens_on: StandardMaterial3D
var _lens_off: StandardMaterial3D
var _lens: MeshInstance3D
const LAMP_TILT := 0.045 # дальний луч чуть ниже горизонта, рад


func _ready() -> void:
	_prev.resize(STATE_SIZE)
	_cur.resize(STATE_SIZE)
	# Вилка, вынос и руль поворачиваются вместе; колесо отдельно вращается вокруг оси.
	_steering = Node3D.new()
	add_child(_steering)
	_steering.position = Vector3(0.0, 0.76, -0.415)
	for part: String in ["ForkL", "ForkR", "Stem", "Handlebar"]:
		get_node(part).reparent(_steering)
	var front_axle := Vector3(0.0, WHEEL_Y, -BikeRide.HUB) - _steering.position
	for part: String in ["ForkL", "ForkR"]:
		_front_struts.append(_strut(_steering.get_node(part), front_axle))
	for part: String in ["ChainStayL", "ChainStayR", "SeatStayL", "SeatStayR"]:
		_rear_struts.append(_strut(get_node(part), Vector3(0.0, WHEEL_Y, BikeRide.HUB)))
	_make_lamp()

@onready var rider: Node3D = $Rider
@onready var rear_wheel: Node3D = $RearWheel
@onready var front_wheel: Node3D = $FrontWheel
@onready var crank: Node3D = $Crank
@onready var pedal_l: Node3D = $Crank/PedalL
@onready var pedal_r: Node3D = $Crank/PedalR


## Фара под рулём перед выносом: кронштейн, корпус, стекло; свет выходит из стекла
func _make_lamp() -> void:
	lamp = Node3D.new()
	lamp.name = "Lamp"
	_steering.add_child(lamp)
	lamp.position = Vector3(0.0, 0.17, -0.1)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.12, 0.12, 0.13)
	body_mat.roughness = 0.45
	body_mat.metallic = 0.3
	var bracket := MeshInstance3D.new()
	var bracket_mesh := BoxMesh.new()
	bracket_mesh.size = Vector3(0.025, 0.06, 0.05)
	bracket.mesh = bracket_mesh
	bracket.material_override = body_mat
	bracket.position = Vector3(0.0, 0.035, 0.035)
	lamp.add_child(bracket)
	var body := MeshInstance3D.new()
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = 0.034
	body_mesh.bottom_radius = 0.03
	body_mesh.height = 0.085
	body_mesh.radial_segments = 12
	body_mesh.rings = 1
	body.mesh = body_mesh
	body.material_override = body_mat
	body.rotation = Vector3(-PI * 0.5, 0.0, 0.0) # ось цилиндра вдоль -Z, широкий край — вперёд
	lamp.add_child(body)
	_lens_off = StandardMaterial3D.new()
	_lens_off.albedo_color = Color(0.75, 0.78, 0.8)
	_lens_off.roughness = 0.1
	_lens_off.metallic = 0.6
	_lens_on = StandardMaterial3D.new()
	_lens_on.albedo_color = Color(1.0, 0.95, 0.85)
	_lens_on.emission_enabled = true
	_lens_on.emission = Color(1.0, 0.9, 0.72)
	_lens_on.emission_energy_multiplier = 6.0
	_lens = MeshInstance3D.new()
	var lens_mesh := CylinderMesh.new()
	lens_mesh.top_radius = 0.029
	lens_mesh.bottom_radius = 0.029
	lens_mesh.height = 0.006
	lens_mesh.radial_segments = 12
	lens_mesh.rings = 1
	_lens.mesh = lens_mesh
	_lens.material_override = _lens_off
	_lens.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	_lens.position = Vector3(0.0, 0.0, -0.044)
	lamp.add_child(_lens)
	# Дальний луч: узкий, далеко, медленно слабеет; мягкий край без резкой границы
	var beam := SpotLight3D.new()
	beam.name = "Beam"
	beam.light_color = Color(1.0, 0.93, 0.8)
	beam.light_energy = 14.0
	beam.light_specular = 0.25
	beam.spot_range = 60.0
	beam.spot_attenuation = 0.35
	beam.spot_angle = 16.0
	beam.spot_angle_attenuation = 1.4
	beam.shadow_enabled = false
	beam.position = Vector3(0.0, 0.0, -0.05)
	beam.rotation = Vector3(-LAMP_TILT, 0.0, 0.0)
	lamp.add_child(beam)
	# Ближняя заливка: широкая и слабая, рассеивает пятно под колесом и края луча
	var flood := SpotLight3D.new()
	flood.name = "Flood"
	flood.light_color = Color(1.0, 0.9, 0.76)
	flood.light_energy = 1.6
	flood.light_specular = 0.1
	flood.spot_range = 16.0
	flood.spot_attenuation = 0.8
	flood.spot_angle = 48.0
	flood.spot_angle_attenuation = 2.2
	flood.shadow_enabled = false
	flood.position = Vector3(0.0, 0.0, -0.05)
	flood.rotation = Vector3(-0.2, 0.0, 0.0)
	lamp.add_child(flood)
	set_lamp(false)


func set_lamp(on: bool) -> void:
	for light: Node in lamp.get_children():
		if light is SpotLight3D:
			light.visible = on
	_lens.material_override = _lens_on if on else _lens_off


func lamp_on() -> bool:
	return lamp.get_node("Beam").visible


## Запомнить состояние после такта физики
func tick(b: BikeRide, dt := 1.0 / 60.0, throttle := 0.0, boost := false) -> void:
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
	_cur[S_HEADING] = b.heading
	_cur[S_ROLL] = b.lean
	_cur[S_SQUASH] = b.squash
	_cur[S_SQUASH_F] = b.squash_f
	_cur[S_SQUASH_R] = b.squash_r
	_cur[S_WHEEL] = b.wheel
	_cur[S_STEER] = b.steer
	_cur[S_CRANK] = b.crank
	_cur[S_TUCK] = clampf(absf(b.speed) / GameConfig.BIKE_SPEED, 0.0, 1.0) * 0.08
	_update_rider(b, dt, throttle, boost)
	_riding = b.riding
	if not _has_state:
		_prev = _cur.duplicate()
		_has_state = true


## Реакции считаются только на тактах физики; draw лишь интерполирует готовую позу.
func _update_rider(b: BikeRide, dt: float, throttle: float, boost: bool) -> void:
	var continuous := _has_state and _riding and b.riding
	var acceleration := clampf((b.speed - _last_speed) / maxf(dt, 0.001), -9.0, 7.0) if continuous else 0.0
	var cadence := absf(angle_difference(_last_crank, b.crank)) / maxf(dt, 0.001) if continuous else 0.0
	_last_speed = b.speed
	_last_crank = b.crank
	var pedal := clampf(cadence / 4.0, 0.0, 1.0) if not b.airborne else 0.0
	var effort := pedal * (1.25 if boost else 1.0)
	var slope := clampf(b.tilt, -0.5, 0.5) if not b.airborne else 0.0
	var braking := maxf(-throttle, 0.0) * smoothstep(0.1, 2.0, b.speed)
	# Под нагрузкой подаёмся вперёд; при торможении и спуске уходим назад.
	var shift := clampf(-acceleration * 0.004 - slope * 0.09 - effort * 0.012 + braking * 0.025, -0.055, 0.055)
	var side := clampf(-b.lean * 0.12 + sin(b.crank) * effort * 0.009, -0.04, 0.04)
	_landing *= exp(-dt * 9.0)
	if continuous and b.land_impact > 0.0:
		_landing = maxf(_landing, clampf(b.land_impact / 10.0, 0.0, 1.0))
	# В полёте компактная стойка, при приземлении сгибаем колени и локти.
	# Два мягких импульса за оборот: корпус слегка пружинит при каждом нажатии.
	var pedal_bob := (1.0 - cos(b.crank * 2.0)) * effort * 0.003
	var crouch := (0.035 if b.airborne else 0.0) + _landing * 0.055 + braking * 0.012 + pedal_bob
	var look := -b.steer * smoothstep(0.2, 3.0, absf(b.speed)) * 0.22
	var blend := 1.0 - exp(-maxf(dt, 0.0) * 10.0)
	var targets := [shift, side, crouch, look]
	for j in targets.size():
		var index := S_SHIFT + j
		_cur[index] = lerpf(_prev[index], targets[j], blend) if continuous else targets[j]


## Перенестись в текущее состояние без перехода (поставили велосипед, сели или слезли)
func snap(b: BikeRide) -> void:
	# Не переносим ускорение и удар через посадку, спешивание или телепорт.
	_has_state = false
	_landing = 0.0
	tick(b)
	for i in STATE_SIZE:
		_prev[i] = _cur[i]


## Показать модель в доле alpha (0..1) пути от предпоследнего такта к последнему
func draw(alpha: float) -> void:
	_mix.resize(_cur.size())
	for i in _cur.size():
		# курс и углы колёс и педалей идут через полный оборот: переход по короткой дуге
		var angular := i == S_HEADING or i == S_WHEEL or i == S_CRANK
		_mix[i] = lerp_angle(_prev[i], _cur[i], alpha) if angular else lerpf(_prev[i], _cur[i], alpha)
	# рама и седок опускаются на ход подвески, колёса остаются на земле
	position = Vector3(_mix[S_X], _mix[S_BODY_Y], _mix[S_Z])
	rotation = Vector3(_mix[S_TILT], _mix[S_HEADING], _mix[S_ROLL])
	rear_wheel.position.y = WHEEL_Y + _mix[S_SQUASH_R]
	front_wheel.position.y = WHEEL_Y + _mix[S_SQUASH_F]
	for st: Array in _front_struts:
		_stretch(st, _mix[S_SQUASH_F])
	for st: Array in _rear_struts:
		_stretch(st, _mix[S_SQUASH_R])
	rear_wheel.rotation.x = -_mix[S_WHEEL]
	front_wheel.rotation.x = -_mix[S_WHEEL]
	front_wheel.rotation.y = -_mix[S_STEER] * STEER_VIEW
	_steering.rotation.y = front_wheel.rotation.y
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
		rider.pose(_mix[S_CRANK], tuck, grip_l, grip_r, motion, _mix[S_LOOK], _mix[S_TILT], _mix[S_ROLL])


## Ход подвески в последнем кадре draw (для камеры, без ступенек 60 Гц)
func view_squash() -> float:
	return _mix[S_SQUASH] if _mix.size() > S_SQUASH else 0.0


## Перо рамы (цилиндр вдоль местной Y): какой конец у оси колеса, какой неподвижен, и длина
func _strut(part: MeshInstance3D, axle: Vector3) -> Array:
	var half := part.basis.y.normalized() * (part.mesh as CylinderMesh).height * 0.5
	var a := part.position + half
	var b := part.position - half
	if absf(a.z - axle.z) + absf(a.y - axle.y) < absf(b.z - axle.z) + absf(b.y - axle.y):
		return [part, b, a, half.length() * 2.0]
	return [part, a, b, half.length() * 2.0]


## Перо от неподвижного конца до оси колеса, поднятой на ход подвески: вилка короче, задние перья поворачиваются
func _stretch(st: Array, travel: float) -> void:
	var fixed: Vector3 = st[1]
	var axle: Vector3 = st[2] + Vector3(0.0, travel, 0.0)
	var along := axle - fixed
	var basis := Basis(Quaternion(Vector3.UP, along.normalized())) * Basis.from_scale(Vector3(1.0, along.length() / st[3], 1.0))
	(st[0] as Node3D).transform = Transform3D(basis, (fixed + axle) * 0.5)
