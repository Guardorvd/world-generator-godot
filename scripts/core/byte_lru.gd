extends RefCounted
## Insertion order is recency; only immutable CPU data, never nodes/native resources.
var limit := 64 * 1024 * 1024
var bytes := 0
var entries := {}

func get_value(key: Variant) -> Variant:
	if not entries.has(key): return null
	var entry: Dictionary = entries[key]
	entries.erase(key)
	entries[key] = entry
	return entry.value

func put(key: Variant, value: Variant) -> bool:
	erase(key)
	var n := size_of(value)
	if n > limit: return false
	while bytes + n > limit and not entries.is_empty(): erase(entries.keys()[0])
	entries[key] = {value = value, bytes = n}
	bytes += n
	return true

func erase(key: Variant) -> void:
	if not entries.has(key): return
	bytes -= entries[key].bytes
	entries.erase(key)

func clear() -> void:
	entries.clear()
	bytes = 0

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
