class_name SettlementData
extends EntityRecord
const FIELDS := ["x", "y", "i", "spacing", "importance", "name", "huts", "town", "homes", "style", "character", "connections", "id", "region", "net"]
var x: float = 0.0
var y: float = 0.0
var i: int = -1
var name: String = ""
var character: String = ""
var spacing: float = 129.6
var importance: float = 0.0
var town: bool = false
var homes: int = 6
var style: int = 0
var huts: Array[HutData] = []
var connections: Array = []
var id: String = ""
var net: String = ""
var region: Vector2i = Vector2i.ZERO

func _init(px: float = 0.0, py: float = 0.0, index: int = -1, title: String = "") -> void:
	x = px
	y = py
	i = index
	name = title

static func from_dict(data: Dictionary) -> SettlementData:
	var result := SettlementData.new()
	result.net = data.get("net", "")
	if data.has("x"):
		result.x = data["x"]
	if data.has("y"):
		result.y = data["y"]
	if data.has("i"):
		result.i = data["i"]
	if data.has("name"):
		result.name = data["name"]
	if data.has("character"):
		result.character = data["character"]
	if data.has("spacing"):
		result.spacing = data["spacing"]
	if data.has("importance"):
		result.importance = data["importance"]
	if data.has("town"):
		result.town = data["town"]
	if data.has("homes"):
		result.homes = data["homes"]
	if data.has("style"):
		result.style = data["style"]
	for hut: Variant in data.get("huts", []):
		result.huts.append(hut if hut is HutData else HutData.from_dict(hut))
	if data.has("connections"):
		result.connections = data["connections"].duplicate()
	if data.has("id"):
		result.id = data["id"]
	if data.has("region"):
		result.region = data["region"]
	return result



func to_dict() -> Dictionary:
	var out := super.to_dict()
	if id.is_empty():
		out.erase("id")
		out.erase("region")
	if net.is_empty():
		out.erase("net")
	if i < 0:
		out.erase("i")
	return out

func has(field: String) -> bool:
	if field == "i":
		return i >= 0
	if field == "id" or field == "region":
		return not id.is_empty()
	if field == "net":
		return not net.is_empty()
	return super.has(field)
