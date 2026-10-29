extends RefCounted
## Insertion order is recency; only immutable CPU data, never nodes/native resources.
var limit := 64 * 1024 * 1024
var _bytes := 0
var budget: RefCounted
var bytes: int:
	get: return budget.owner_bytes(_owner_id) if budget != null else _bytes
var entries := {}
var _owner_id := get_instance_id()

func get_value(key: Variant) -> Variant:
	if budget != null: return budget.get_value(_owner_id, key)
	if not entries.has(key): return null
	var entry: Dictionary = entries[key]
	entries.erase(key)
	entries[key] = entry
	return entry.value

func put(key: Variant, value: Variant) -> bool:
	if budget != null: return budget.put(_owner_id, key, value, size_of(value), limit)
	erase(key)
	var n := size_of(value)
	if n > limit: return false
	while bytes + n > limit and not entries.is_empty(): erase(entries.keys()[0])
	entries[key] = {value = value, bytes = n}
	_bytes += n
	return true

func erase(key: Variant) -> void:
	if budget != null:
		budget.erase(_owner_id, key)
		return
	if not entries.has(key): return
	_bytes -= entries[key].bytes
	entries.erase(key)

func clear() -> void:
	if budget != null:
		budget.clear_owner(_owner_id)
		return
	entries.clear()
	_bytes = 0

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and budget != null: budget.clear_owner(_owner_id)

static func size_of(value: Variant) -> int:
	match typeof(value):
		TYPE_PACKED_BYTE_ARRAY: return value.size()
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY: return value.size() * 4
		TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_VECTOR2_ARRAY: return value.size() * 8
		TYPE_PACKED_VECTOR3_ARRAY: return value.size() * 12
		TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY: return value.size() * 16
		TYPE_DICTIONARY:
			var n := 64
			for key: Variant in value: n += 48 + size_of(key) + size_of(value[key])
			return n
		TYPE_ARRAY:
			var n := 32
			for item: Variant in value: n += 16 + size_of(item)
			return n
		TYPE_STRING, TYPE_STRING_NAME: return value.length() * 4 + 24
	return 32
