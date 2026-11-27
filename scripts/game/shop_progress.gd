extends RefCounted
## Баланс, коллекция и выплаченные награды сохраняются одним снимком.

signal changed
signal equipment_changed(scheme: String)
signal tires_changed(id: String)
signal grips_changed(id: String)
signal pedals_changed(id: String)

const Palette := preload("res://scripts/render/bike_palette.gd")
const Files := preload("res://scripts/core/cache_file.gd")
const DEFAULT_SCHEME := "ember"
const DEFAULT_TIRES := Palette.STOCK_TIRES
const DEFAULT_GRIPS := Palette.STOCK_GRIPS
const DEFAULT_PEDALS := Palette.STOCK_PEDALS
enum Category { SCHEME, TIRES, GRIPS, PEDALS }
const DEFAULT_ITEMS := [DEFAULT_SCHEME, DEFAULT_TIRES, DEFAULT_GRIPS, DEFAULT_PEDALS]
const EQUIPMENT_FIELDS := ["equipped", "tires", "grips", "pedals"]
## 20.11: второй ряд — дорогие расцветки, чтобы очки работали дольше первых заданий
const PRICES := {"ember": 0, "glacier": 50, "moss": 50, "night": 50, "lingon": 120, "fog": 150, "copper": 200,
	"obsidian": 220, "heritage": 180, "pulse": 250, "salt": 230, "tide": 240, "ivory": 210,
	DEFAULT_TIRES: 0, "tires_rose": 70, "tires_sage": 70, "tires_blue": 70, "tires_sand": 70, "tires_ivory": 70,
	DEFAULT_GRIPS: 0, "grips_rose": 35, "grips_sage": 35, "grips_blue": 35, "grips_sand": 35, "grips_ivory": 35,
	DEFAULT_PEDALS: 0, "pedals_rose": 45, "pedals_sage": 45, "pedals_blue": 45, "pedals_sand": 45, "pedals_ivory": 45}
## Задания (вид до двоеточия) и, с 20.11, исследование: новая страница альбома (album), ночное явление в альбоме (sky),
## первый обзор с вышки или вершины (scan), ремонт по пути (fix; благодарность поселения платит как задание repair)
const REWARDS := {
	start = 20, supplies = 30, repair = 30, fragile = 40, beacons = 50, paint = 50,
	obelisks = 80, visit = 30, tour = 30, delivery = 30, photo = 30, chronicle = 30,
	album = 5, sky = 15, scan = 10, fix = 10,
}
const FORMAT := 1
const MAX_FILE_BYTES := 8 * 1024 * 1024
const DEFAULT_STATE := {
	format = FORMAT, balance = 0, owned = {DEFAULT_SCHEME: true, DEFAULT_TIRES: true, DEFAULT_GRIPS: true, DEFAULT_PEDALS: true},
	equipped = DEFAULT_SCHEME, tires = DEFAULT_TIRES, grips = DEFAULT_GRIPS, pedals = DEFAULT_PEDALS, paid = {},
	purchase_goal = "",
}

var balance: int:
	get: return _state.balance
var equipped: String:
	get: return _state.equipped
var equipped_tires: String:
	get: return _state.tires
var equipped_grips: String:
	get: return _state.grips
var equipped_pedals: String:
	get: return _state.pedals
var purchase_goal: String:
	get: return _state.purchase_goal
var load_error := OK
var _path := ""
var _from_backup := false
var _state := DEFAULT_STATE.duplicate(true)
var _pending := {}


func load_profile(path: String) -> void:
	_path = path
	_pending.clear()
	_from_backup = false
	var primary := _read(path)
	if not primary.is_empty():
		_state = primary
		load_error = OK
		return
	var backup := _read(path + ".bak")
	if not backup.is_empty():
		_state = backup
		_from_backup = true
		load_error = OK
		return
	_state = DEFAULT_STATE.duplicate(true)
	load_error = ERR_FILE_CORRUPT if FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak") else OK


func owns(id: String) -> bool:
	return _state.owned.has(id)


static func item_name(id: String) -> String:
	match category_for(id):
		Category.TIRES: return Palette.TIRE_NAMES[id]
		Category.GRIPS: return Palette.GRIP_NAMES[id]
		Category.PEDALS: return Palette.PEDAL_NAMES[id]
		_: return Palette.SCHEME_NAMES.get(id, id)


static func category_for(id: String) -> Category:
	if Palette.PEDAL_NAMES.has(id):
		return Category.PEDALS
	if Palette.GRIP_NAMES.has(id):
		return Category.GRIPS
	if Palette.TIRE_NAMES.has(id):
		return Category.TIRES
	return Category.SCHEME


func equipped_in(category: Category) -> String:
	return _state[EQUIPMENT_FIELDS[category]]


func equipped_for(id: String) -> String:
	return equipped_in(category_for(id))


func remaining(id: String) -> int:
	return maxi(0, int(PRICES.get(id, 0)) - balance)


func needs_first_purchase() -> bool:
	return _state.owned.size() == DEFAULT_ITEMS.size()


func first_purchase_unlocked(points_awarded: int) -> bool:
	if not needs_first_purchase():
		return false
	var first_price := balance + 1
	for id: String in PRICES:
		if not owns(id):
			first_price = mini(first_price, PRICES[id])
	return balance - points_awarded < first_price and balance >= first_price


## One goal survives world changes. An empty ID clears it.
func set_purchase_goal(id: String) -> Error:
	if id != "" and (not PRICES.has(id) or owns(id)):
		return ERR_INVALID_PARAMETER
	if id == purchase_goal:
		return OK
	var next := _state.duplicate()
	next.purchase_goal = id
	var err := _commit(next)
	if err == OK:
		changed.emit()
	return err


## wear — сразу надеть купленное (20.11: «Купить и надеть» — одна запись профиля, а не две)
func buy(id: String, wear := false) -> Error:
	if not PRICES.has(id) or owns(id) or balance < PRICES[id]:
		return ERR_INVALID_PARAMETER
	var next := _state.duplicate()
	next.owned = _state.owned.duplicate()
	next.balance -= PRICES[id]
	next.owned[id] = true
	if next.purchase_goal == id:
		next.purchase_goal = ""
	if wear:
		next[_equipment_field(id)] = id
	var err := _commit(next)
	if err == OK:
		if wear:
			_emit_equipped(id)
		changed.emit()
	return err


func equip(id: String) -> Error:
	if not PRICES.has(id) or not owns(id):
		return ERR_INVALID_PARAMETER
	if equipped_for(id) == id:
		return OK
	var next := _state.duplicate()
	next[_equipment_field(id)] = id
	var err := _commit(next)
	if err == OK:
		_emit_equipped(id)
		changed.emit()
	return err


static func _equipment_field(id: String) -> String:
	return EQUIPMENT_FIELDS[category_for(id)]


func _emit_equipped(id: String) -> void:
	match category_for(id):
		Category.TIRES:
			tires_changed.emit(id)
		Category.GRIPS:
			grips_changed.emit(id)
		Category.PEDALS:
			pedals_changed.emit(id)
		_:
			equipment_changed.emit(id)


func reward(seed_text: String, id: String) -> int:
	return _unpaid_points(_reward_key(seed_text.sha256_text(), id), id)


## Replaying a completion from an older slot is safe. Returns the points credited, or -1 on write failure.
func award(seed_text: String, ids: Array) -> int:
	var seed_hash := seed_text.sha256_text()
	for id: String in ids:
		var key := _reward_key(seed_hash, id)
		var points := _unpaid_points(key, id)
		if points > 0:
			_pending[key] = points
	return retry_rewards()


func retry_rewards() -> int:
	if _pending.is_empty():
		return 0
	var next := _state.duplicate()
	next.paid = _state.paid.duplicate()
	var points := 0
	for key: String in _pending:
		points += _pending[key]
		next.paid[key] = true
	next.balance += points
	if _commit(next) != OK:
		return -1
	_pending.clear()
	changed.emit()
	return points


func _unpaid_points(key: String, id: String) -> int:
	if id.get_slice(":", 1).is_empty() or _state.paid.has(key):
		return 0
	return REWARDS.get(id.get_slice(":", 0), 0)


static func _reward_key(seed_hash: String, id: String) -> String:
	return "start" if id.begins_with("start:") else seed_hash + ":" + id


func _commit(next: Dictionary) -> Error:
	if load_error != OK:
		return load_error
	if not _path.is_empty():
		var raw := var_to_bytes(next)
		if raw.size() + 64 > MAX_FILE_BYTES:
			return ERR_OUT_OF_MEMORY
		var bytes := raw.hex_encode().sha256_text().to_ascii_buffer()
		bytes.append_array(raw)
		var err := Files.replace(_path, bytes, _from_backup)
		if err != OK:
			# The primary may already have moved to the backup during a failed rotation.
			_from_backup = not _read(_path + ".bak").is_empty() and _read(_path).is_empty()
			return err
		_from_backup = false
	_state = next
	return OK


static func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= 64 or file.get_length() > MAX_FILE_BYTES:
		return {}
	var hash := file.get_buffer(64).get_string_from_ascii()
	var raw := file.get_buffer(file.get_length() - 64)
	if hash != raw.hex_encode().sha256_text():
		return {}
	var data: Variant = bytes_to_var(raw)
	if not data is Dictionary or data.get("format") != FORMAT \
			or not data.get("balance") is int or data.balance < 0 \
			or not data.get("owned") is Dictionary or not data.get("paid") is Dictionary \
			or not data.get("equipped") is String or not data.owned.has(DEFAULT_SCHEME):
		return {}
	for entries: Dictionary in [data.owned, data.paid]:
		for key: Variant in entries:
			if not key is String or key.is_empty() or not entries[key] is bool or not entries[key]:
				return {}
	if not Palette.SCHEMES.has(data.equipped) or not data.owned.has(data.equipped):
		data.equipped = DEFAULT_SCHEME
	for category in range(Category.TIRES, DEFAULT_ITEMS.size()):
		var field: String = EQUIPMENT_FIELDS[category]
		var stock: String = DEFAULT_ITEMS[category]
		data.owned[stock] = true
		var selected: Variant = data.get(field, stock)
		if not selected is String or not PRICES.has(selected) or category_for(selected) != category or not data.owned.has(selected):
			selected = stock
		data[field] = selected
	var target: Variant = data.get("purchase_goal", "")
	# The goal is optional in profiles from shop 1.0.
	data.purchase_goal = target if target is String and PRICES.has(target) and not data.owned.has(target) else ""
	return data
