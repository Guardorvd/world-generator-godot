class_name SiteData
extends EntityRecord
const FIELDS := ["x", "y", "i", "type", "rank", "name", "clear", "huts"]
var x: float = 0.0
var y: float = 0.0
var i: int = -1
var type: String = ""
var rank: int = 0
var name: String = ""
var clear: float = 0.0
var huts: Array[HutData] = []

func _init(px: float = 0.0, py: float = 0.0, index: int = -1, kind: String = "", significance: int = 0, title: String = "", clearing: float = 0.0, buildings: Array[HutData] = []) -> void:
	x = px
	y = py
	i = index
	type = kind
	rank = significance
	name = title
	clear = clearing
	huts = buildings

static func from_dict(data: Dictionary) -> SiteData:
	var result := SiteData.new()
	if data.has("x"):
		result.x = data["x"]
	if data.has("y"):
		result.y = data["y"]
	if data.has("i"):
		result.i = data["i"]
	if data.has("type"):
		result.type = data["type"]
	if data.has("rank"):
		result.rank = data["rank"]
	if data.has("name"):
		result.name = data["name"]
	if data.has("clear"):
		result.clear = data["clear"]
	for hut: Variant in data.get("huts", []):
		result.huts.append(hut if hut is HutData else HutData.from_dict(hut))
	return result


func is_empty() -> bool:
	return type.is_empty()
