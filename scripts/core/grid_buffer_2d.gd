class_name GridBuffer2D
extends RefCounted
## Типизированные 2D-поля. Layout общий для контекстов, обратной ссылки на WorldData нет.
## data — единственный packed-буфер для массовых численных циклов и C#; get/set_cell — координатный API.

class Layout extends RefCounted:
	var width := 0
	var height := 0

	func contains(x: int, y: int) -> bool:
		return x >= 0 and y >= 0 and x < width and y < height

	func index(x: int, y: int) -> int:
		assert(contains(x, y), "Клетка за границей 2D-поля")
		return y * width + x

	func cell(i: int) -> Vector2i:
		assert(i >= 0 and i < width * height, "Индекс за границей 2D-поля")
		@warning_ignore("integer_division")
		return Vector2i(i % width, i / width)


class Float32 extends RefCounted:
	var layout: Layout
	var data := PackedFloat32Array()

	func _init(shape: Layout) -> void:
		layout = shape

	func resize() -> void:
		data.resize(layout.width * layout.height)

	func get_cell(x: int, y: int) -> float:
		return data[layout.index(x, y)]

	func set_cell(x: int, y: int, value: float) -> void:
		data[layout.index(x, y)] = value


class Byte extends RefCounted:
	var layout: Layout
	var data := PackedByteArray()

	func _init(shape: Layout) -> void:
		layout = shape

	func resize() -> void:
		data.resize(layout.width * layout.height)

	func get_cell(x: int, y: int) -> int:
		return data[layout.index(x, y)]

	func set_cell(x: int, y: int, value: int) -> void:
		data[layout.index(x, y)] = value


class Int32 extends RefCounted:
	var layout: Layout
	var data := PackedInt32Array()

	func _init(shape: Layout) -> void:
		layout = shape

	func resize() -> void:
		data.resize(layout.width * layout.height)

	func get_cell(x: int, y: int) -> int:
		return data[layout.index(x, y)]

	func set_cell(x: int, y: int, value: int) -> void:
		data[layout.index(x, y)] = value
