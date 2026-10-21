class_name BikeView
extends Node3D
## Велосипед с седоком, сцена scenes/bike.tscn: модель из примитивов, смотрит вдоль -Z.
## Повторяет состояние BikeRide: место, курс, наклон, крен, вращение колёс и педалей, ход подвески.
## С 7.1 колёса стоят на своих точках касания, а вилка и задние перья тянутся к осям: видно сжатие каждого колеса.
## Ноги седока ставятся на педали (два звена: бедро и голень). Езда считается тактами физики (60 в секунду),
## а кадров бывает и 800: между двумя последними тактами модель плавно переходит (draw), иначе дёргалась бы.

const WHEEL_Y := 0.34    # высота осей колёс над землёй
const CRANK_Y := 0.3     # высота каретки
const CRANK_R := 0.17    # длина шатуна
const PEDAL_X := 0.14
const HIP := Vector3(0.11, 0.95, 0.17)
const THIGH := 0.43
const SHIN := 0.43
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
const STATE_SIZE := 13

# состояние на двух последних тактах (индексы S_*)
var _prev := PackedFloat64Array()
var _cur := PackedFloat64Array()
var _mix := PackedFloat64Array() # буфер для draw, чтобы не выделять память на каждый кадр
var _riding := false
var _has_state := false
var _steering: Node3D
# перья, которые тянутся к оси колеса: [узел, неподвижный конец, конец у оси, длина]; передние — вилка
var _front_struts: Array = []
var _rear_struts: Array = []


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

@onready var rider: Node3D = $Rider
@onready var rear_wheel: Node3D = $RearWheel
@onready var front_wheel: Node3D = $FrontWheel
@onready var crank: Node3D = $Crank
@onready var pedal_l: Node3D = $Crank/PedalL
@onready var pedal_r: Node3D = $Crank/PedalR
@onready var thigh_l: Node3D = $Rider/ThighL
@onready var shin_l: Node3D = $Rider/ShinL
@onready var thigh_r: Node3D = $Rider/ThighR
@onready var shin_r: Node3D = $Rider/ShinR
@onready var torso: Node3D = $Rider/Torso
@onready var head: Node3D = $Rider/Head


## Запомнить состояние после такта физики
func tick(b: BikeRide) -> void:
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
	_riding = b.riding
	if not _has_state:
		_prev = _cur.duplicate()
		_has_state = true


## Перенестись в текущее состояние без перехода (поставили велосипед, сели или слезли)
func snap(b: BikeRide) -> void:
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
		torso.rotation.x = -0.5105 - tuck
		head.position = Vector3(0.0, 1.66 - tuck * 0.3, -0.17 - tuck * 0.3)
		var c := cos(-_mix[S_CRANK]) * CRANK_R
		var s := sin(-_mix[S_CRANK]) * CRANK_R
		_leg(thigh_r, shin_r, HIP, Vector3(PEDAL_X, CRANK_Y - c, -s))
		_leg(thigh_l, shin_l, Vector3(-HIP.x, HIP.y, HIP.z), Vector3(-PEDAL_X, CRANK_Y + c, s))


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


## Бедро от таза до колена и голень от колена до стопы; колено смотрит вперёд и вверх
func _leg(thigh: Node3D, shin: Node3D, hip: Vector3, foot: Vector3) -> void:
	var to_foot := foot - hip
	var d := clampf(to_foot.length(), 0.05, THIGH + SHIN - 0.001)
	var dir := to_foot.normalized()
	var ca := clampf((THIGH * THIGH + d * d - SHIN * SHIN) / (2.0 * THIGH * d), -1.0, 1.0)
	var bend := Vector3(0.0, 0.3, -1.0)
	bend = (bend - dir * bend.dot(dir)).normalized()
	var knee := hip + (dir * ca + bend * sqrt(1.0 - ca * ca)) * THIGH
	foot = hip + dir * d
	_place(thigh, hip, knee)
	_place(shin, knee, foot)


## Поставить цилиндр (ось — местная Y) между двумя точками
func _place(part: Node3D, a: Vector3, b: Vector3) -> void:
	part.transform = Transform3D(Basis(Quaternion(Vector3.UP, (b - a).normalized())), (a + b) * 0.5)
