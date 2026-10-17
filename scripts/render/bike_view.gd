class_name BikeView
extends Node3D
## Велосипед с седоком, сцена scenes/bike.tscn: модель из примитивов, смотрит вдоль -Z.
## Каждый кадр повторяет состояние BikeRide: место, курс, наклон, крен, вращение колёс.

@onready var rider: Node3D = $Rider
@onready var rear_wheel: Node3D = $RearWheel
@onready var front_wheel: Node3D = $FrontWheel


func show_state(b: BikeRide, ground: float) -> void:
	position = Vector3(b.x, ground, b.z)
	rotation = Vector3(b.tilt, b.heading, b.lean)
	rear_wheel.rotation.x = -b.wheel
	front_wheel.rotation.x = -b.wheel
	front_wheel.rotation.y = -b.steer * 0.35
	rider.visible = b.riding
