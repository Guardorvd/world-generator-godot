class_name WorldGenerationState
extends RefCounted
## Временное состояние генерации, отдельно от сохраняемых предметных данных.
## Поток захватывает только входы шума, а не WorldData или этот объект.

var rng: WGRandom
var noise := {}
var scale := 1.0
var profile := {}
var base_heights: Heightfield
var _thread: Thread
var _fields := {}


func start_fields(width: int, height: int, definitions: Dictionary) -> void:
	clear_fields()
	var inputs := noise
	_thread = Thread.new()
	_thread.start(func() -> Dictionary:
		var out := {}
		for name: String in definitions:
			var p: Array = definitions[name]
			out[name] = Parallel.fbm_field(width, height, inputs[name], p[0], p[1])
		return out)


func field(name: String, width: int, height: int, definitions: Dictionary) -> PackedFloat64Array:
	if _thread != null:
		_fields = _thread.wait_to_finish()
		_thread = null
	if not _fields.has(name):
		var p: Array = definitions[name]
		_fields[name] = Parallel.fbm_field(width, height, noise[name], p[0], p[1])
	return _fields[name]


func clear_fields() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_fields.clear()


func _notification(what: int) -> void:
	# При нулевом refcount нельзя вызывать методы самого RefCounted; поток — отдельный объект.
	if what == NOTIFICATION_PREDELETE and _thread != null:
		_thread.wait_to_finish()
		_thread = null
