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

# состояние на двух последних тактах: x, высота рамы, z, наклон, курс, крен, подвеска, колёса, руль, педали
var _prev := PackedFloat64Array()
var _cur := PackedFloat64Array()
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
	var v := PackedFloat64Array()
	v.resize(_cur.size())
	for i in _cur.size():
		# курс и углы колёс и педалей идут через полный оборот: переход по короткой дуге
		v[i] = lerp_angle(_prev[i], _cur[i], alpha) if i == 4 or i == 7 or i == 9 else lerpf(_prev[i], _cur[i], alpha)
	# рама и седок опускаются на ход подвески, колёса остаются на земле
	position = Vector3(v[0], v[1], v[2])
	rotation = Vector3(v[3], v[4], v[5])
	rear_wheel.position.y = WHEEL_Y + v[6]
	front_wheel.position.y = WHEEL_Y + v[6]
	rear_wheel.rotation.x = -v[7]
	front_wheel.rotation.x = -v[7]
	front_wheel.rotation.y = -v[8] * 0.35
	crank.rotation.x = -v[9]
	# педали держатся горизонтально
	pedal_l.rotation.x = v[9]
	pedal_r.rotation.x = v[9]
	rider.visible = _riding
	if _riding:
		var c := cos(-v[9]) * CRANK_R
		var s := sin(-v[9]) * CRANK_R
		_leg(thigh_r, shin_r, Vector3(HIP.x, HIP.y, HIP.z), Vector3(PEDAL_X, CRANK_Y - c, -s))
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
