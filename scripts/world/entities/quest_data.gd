class_name QuestData
extends EntityRecord
const FIELDS := ["id", "kind", "giver", "title", "text", "target", "steps", "step"]
var id: String = ""
var kind: String = ""
var giver: String = ""
var title: String = ""
var text: String = ""
var target: Dictionary = {}
var steps: Array[Dictionary] = []
var step: int = 0

func _init(quest_id: String = "", quest_kind: String = "", giver_id: String = "", destination: Dictionary = {}) -> void:
	id = quest_id
	kind = quest_kind
	giver = giver_id
	target = destination

static func from_dict(data: Dictionary) -> QuestData:
	var result := QuestData.new()
	if data.has("id"):
		result.id = data["id"]
	if data.has("kind"):
		result.kind = data["kind"]
	if data.has("giver"):
		result.giver = data["giver"]
	if data.has("title"):
		result.title = data["title"]
	if data.has("text"):
		result.text = data["text"]
	if data.has("target"):
		result.target = data["target"]
	for item: Dictionary in data.get("steps", []):
		result.steps.append(item.duplicate(true))
	if data.has("step"):
		result.step = data["step"]
	return result


func is_empty() -> bool:
	return id.is_empty()

func to_dict() -> Dictionary:
	return {} if is_empty() else super.to_dict()
