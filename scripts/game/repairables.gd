class_name Repairables
extends RefCounted
## Что в мире можно починить и в каком оно состоянии: смотровые лавки (место "bench"), туры на вершинах и причалы
## рыбацких домиков (место "fishing"). Без узлов сцены: модель показывает RepairLayer, шаг задания «починить» ведёт GameWorld.
## Объект — само место: его id (WorldData.place_id) и есть id объекта. Исходно сломан ли он, решает хеш сида мира и id
## (BROKEN_CHANCE), поэтому в сохранении лежат только починенные: необязательное поле "repairs" (формат сохранения прежний).

const BROKEN_CHANCE := 0.4
const HOLD_TIME := 4.0   # секунд удерживать «взаимодействие» у сломанного объекта

## Вид объекта по виду места; название — для подсказок и заданий (падежи: gen, acc)
const KINDS := {
	bench = {title = "лавка", gen = "лавки", acc = "лавку"},
	cairn = {title = "тур", gen = "тура", acc = "тур"},
	pier = {title = "причал", gen = "причала", acc = "причал"},
}

var seed_num := 0
var repaired := {}   # id -> true: починено игроком


func _init(seed_value := 0) -> void:
	seed_num = seed_value


## Вид объекта места place (запись Hud.all_places: kind, src) или "" — это не починяемое место
static func kind_of(place: Dictionary) -> String:
	match place.get("kind", ""):
		"peak":
			return "cairn"
		"site":
			var src: Variant = place.get("src")
			match "" if src == null else str(EntityCodec.value(src, "type", "")):
				"bench": return "bench"
				"fishing": return "pier"
	return ""


## Сломан ли объект id при создании мира (до ремонта)
static func initially_broken(seed_value: int, id: String) -> bool:
	return absi(hash("%d|%s|broken" % [seed_value, id])) % 1000 < int(BROKEN_CHANCE * 1000.0)


func is_broken(id: String) -> bool:
	return initially_broken(seed_num, id) and not repaired.has(id)


func repair(id: String) -> void:
	repaired[id] = true


func save_state() -> Dictionary:
	return {repaired = repaired.duplicate()}


func restore(state: Dictionary) -> void:
	repaired = state.get("repaired", {}).duplicate()


static func valid_save(state: Variant) -> bool:
	if not state is Dictionary or not state.get("repaired") is Dictionary:
		return false
	for key: Variant in state.repaired:
		if not key is String or state.repaired[key] != true:
			return false
	return true
