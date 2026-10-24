class_name EntityRecord
extends RefCounted
## Dictionary conversion is confined to cache/save and legacy fixture boundaries.
func to_dict() -> Dictionary:
	var out := {}
	for field: String in get_script().FIELDS:
		out[field] = EntityCodec.encode(get(field))
	return out

func duplicate(_deep: bool = true) -> Variant:
	var data := {}
	for field: String in get_script().FIELDS:
		if has(field):
			data[field] = EntityCodec.copy(get(field))
	return get_script().from_dict(data)

func is_empty() -> bool:
	return false

func has(field: String) -> bool:
	return field in get_script().FIELDS

func value(field: String, fallback: Variant = null) -> Variant:
	return get(field) if has(field) else fallback
