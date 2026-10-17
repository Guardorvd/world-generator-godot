class_name BikeView
extends Node3D
## Велосипед с седоком, сцена scenes/bike.tscn: модель из примитивов, смотрит вдоль -Z.
## Каждый кадр повторяет состояние BikeRide: место, курс, наклон, крен, вращение колёс и педалей,
## ход подвески. Ноги седока ставятся на педали (два звена: бедро и голень).

const WHEEL_Y := 0.34    # высота осей колёс над землёй
const CRANK_Y := 0.3     # высота каретки
const CRANK_R := 0.17    # длина шатуна
const PEDAL_X := 0.14
const HIP := Vector3(0.11, 0.95, 0.17)
const THIGH := 0.43
const SHIN := 0.43

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


func show_state(b: BikeRide) -> void:
	# рама и седок опускаются на ход подвески, колёса остаются на земле
	position = Vector3(b.x, b.y - b.squash, b.z)
	rotation = Vector3(b.tilt, b.heading, b.lean + b.sway)
	rear_wheel.position.y = WHEEL_Y + b.squash
	front_wheel.position.y = WHEEL_Y + b.squash
	rear_wheel.rotation.x = -b.wheel
	front_wheel.rotation.x = -b.wheel
	front_wheel.rotation.y = -b.steer * 0.35
	crank.rotation.x = -b.crank
	# педали держатся горизонтально
	pedal_l.rotation.x = b.crank
	pedal_r.rotation.x = b.crank
	rider.visible = b.riding
	if b.riding:
		var c := cos(-b.crank) * CRANK_R
		var s := sin(-b.crank) * CRANK_R
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
