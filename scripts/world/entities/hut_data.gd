class_name HutData
extends EntityRecord
const FIELDS := ["x", "y", "v", "t", "a"]
var x: float = 0.0
var y: float = 0.0
var v: int = 0
var t: String = "house"
var a: float = 0.0
var has_angle := false

func _init(px: float = 0.0, py: float = 0.0, variant: int = 0, kind: String = "house", angle: float = NAN) -> void:
	x = px
	y = py
	v = variant
	t = kind
	has_angle = not is_nan(angle)
	a = angle if has_angle else 0.0

static func from_dict(data: Dictionary) -> HutData:
	var result := HutData.new()
	result.has_angle = data.has("a")
	if data.has("x"):
		result.x = data["x"]
	if data.has("y"):
		result.y = data["y"]
	if data.has("v"):
		result.v = data["v"]
	if data.has("t"):
		result.t = data["t"]
	if data.has("a"):
		result.a = data["a"]
	return result


func has(field: String) -> bool:
	return has_angle if field == "a" else super.has(field)

func to_dict() -> Dictionary:
	var out := super.to_dict()
	if not has_angle:
		out.erase("a")
	return out
