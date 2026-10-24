class_name TunnelData
extends EntityRecord
const FIELDS := ["a", "b"]
var a: int = 0
var b: int = 0

func _init(start: int = 0, end: int = 0) -> void:
	a = start
	b = end

static func from_dict(data: Dictionary) -> TunnelData:
	var result := TunnelData.new()
	if data.has("a"):
		result.a = data["a"]
	if data.has("b"):
		result.b = data["b"]
	return result
