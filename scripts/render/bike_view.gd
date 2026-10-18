class_name BikeView
extends Node3D
## Велосипед с седоком, сцена scenes/bike.tscn: модель из примитивов, смотрит вдоль -Z.
## Повторяет состояние BikeRide: место, курс, наклон, крен, вращение колёс и педалей, ход подвески.
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

# индексы состояния в tick: x, высота рамы, z, наклон, курс, крен, подвеска, колёса, руль, педали
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

# состояние на двух последних тактах (индексы S_*)
var _prev := PackedFloat64Array()
var _cur := PackedFloat64Array()
var _mix := PackedFloat64Array() # буфер для draw, чтобы не выделять память на каждый кадр
var _riding := false

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


## Запомнить состояние после такта физики
func tick(b: BikeRide) -> void:
	_prev = _cur
	_cur = PackedFloat64Array([b.x, b.y - b.squash, b.z, b.tilt, b.heading, b.lean + b.sway, b.squash, b.wheel, b.steer, b.crank])
	_riding = b.riding
	if _prev.is_empty():
		_prev = _cur


## Перенестись в текущее состояние без перехода (поставили велосипед, сели или слезли)
func snap(b: BikeRide) -> void:
	tick(b)
	_prev = _cur


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
	rear_wheel.position.y = WHEEL_Y + _mix[S_SQUASH]
	front_wheel.position.y = WHEEL_Y + _mix[S_SQUASH]
	rear_wheel.rotation.x = -_mix[S_WHEEL]
	front_wheel.rotation.x = -_mix[S_WHEEL]
	front_wheel.rotation.y = -_mix[S_STEER] * STEER_VIEW
	crank.rotation.x = -_mix[S_CRANK]
	# педали держатся горизонтально
	pedal_l.rotation.x = _mix[S_CRANK]
	pedal_r.rotation.x = _mix[S_CRANK]
	rider.visible = _riding
	if _riding:
		var c := cos(-_mix[S_CRANK]) * CRANK_R
		var s := sin(-_mix[S_CRANK]) * CRANK_R
		_leg(thigh_r, shin_r, HIP, Vector3(PEDAL_X, CRANK_Y - c, -s))
		_leg(thigh_l, shin_l, Vector3(-HIP.x, HIP.y, HIP.z), Vector3(-PEDAL_X, CRANK_Y + c, s))


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
