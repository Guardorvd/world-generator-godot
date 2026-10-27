extends RefCounted
## Прогресс отделён от расходного WorldCache. Авто- и ручной слот на зерно.
const FORMAT := 1
const MAX_BYTES := 4 * 1024 * 1024
static var dir := "user://saves"

static func path_for(seed_text: String, slot := "auto") -> String:
	return dir.path_join(seed_text.sha256_text() + "." + slot + ".save")

static func read_slot(seed_text: String, slot := "auto") -> Dictionary:
	var path := path_for(seed_text, slot)
	for candidate: String in [path, path + ".bak"]:
		var data := _read_file(candidate)
		if not data.is_empty() and data.seed == seed_text:
			return {data = data, backup = candidate.ends_with(".bak"), error = ""}
	return {data = {}, backup = false, error = "Сохранение отсутствует, повреждено или имеет неподдерживаемый формат."}

static func _read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path) or FileAccess.get_size(path) > MAX_BYTES:
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 76 or f.get_buffer(4).get_string_from_ascii() != "WGS1":
		return {}
	var length := f.get_64()
	var checksum := f.get_buffer(64).get_string_from_ascii()
	if length != f.get_length() - f.get_position():
		return {}
	var raw := f.get_buffer(length)
	f.close()
	if raw.hex_encode().sha256_text() != checksum:
		return {}
	var d: Variant = bytes_to_var(raw)
	return d if d is Dictionary and d.get("format") == FORMAT and valid(d) else {}

static func valid(d: Dictionary) -> bool:
	if d.get("format") != FORMAT:
		return false
	for key: String in ["visited", "quest", "player", "bike"]:
		if not d.get(key) is Dictionary:
			return false
	for key: String in ["signature", "goal", "seed"]:
		if not d.get(key) is String:
			return false
	for key: String in ["x", "z", "feet", "yaw", "pitch", "hour"]:
		if not _number(d.player.get(key)):
			return false
	for key: String in ["x", "z", "y", "heading"]:
		if not _number(d.bike.get(key)):
			return false
	if not d.bike.get("riding") is bool or not _number(d.get("saved_at")):
		return false
	if d.has("lamp") and not d.lamp is bool:
		return false
	for key: Variant in d.visited:
		if not key is String or d.visited[key] != true:
			return false
	return preload("res://scripts/game/quests.gd").valid_save(d.quest)

static func _number(v: Variant) -> bool:
	return (v is float or v is int) and is_finite(float(v))

static func write_slot(data: Dictionary, slot := "auto") -> Error:
	if not valid(data):
		return ERR_INVALID_DATA
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return err
	var path := path_for(data.seed, slot)
	var raw := var_to_bytes(EntityCodec.encode(data))
	if raw.size() + 76 > MAX_BYTES:
		return ERR_OUT_OF_MEMORY
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer("WGS1".to_ascii_buffer())
	f.store_64(raw.size())
	f.store_buffer(raw.hex_encode().sha256_text().to_ascii_buffer())
	f.store_buffer(raw)
	f.flush()
	err = f.get_error()
	f.close()
	if err != OK:
		return err
	# Битый основной файл не вытесняет исправную резервную копию.
	var old := read_slot(data.seed, slot)
	if FileAccess.file_exists(path) and not old.data.is_empty() and not old.backup:
		if FileAccess.file_exists(path + ".bak"):
			err = DirAccess.remove_absolute(path + ".bak")
			if err != OK:
				return err
		err = DirAccess.rename_absolute(path, path + ".bak")
		if err != OK:
			return err
	elif FileAccess.file_exists(path):
		err = DirAccess.remove_absolute(path)
		if err != OK:
			return err
	return DirAccess.rename_absolute(path + ".tmp", path)

static func seeds() -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for name: String in DirAccess.get_files_at(dir):
		if not (name.ends_with(".save") or name.ends_with(".save.bak")):
			continue
		var d := _read_file(dir.path_join(name))
		if not d.is_empty() and not d.seed in out:
			out.append(d.seed)
	return out

## Перемещаем старые слоты в архив, чтобы новый прогресс не перезаписал их.
static func archive_seed(seed_text: String) -> Error:
	var stamp := str(Time.get_unix_time_from_system()).replace(".", "_")
	for slot: String in ["auto", "manual"]:
		var path := path_for(seed_text, slot)
		for suffix: String in ["", ".bak"]:
			var source := path + suffix
			if FileAccess.file_exists(source):
				var target := source + ".archive." + stamp
				var err := DirAccess.rename_absolute(source, target)
				if err != OK:
					return err
	return OK

static func delete_seed(seed_text: String) -> Error:
	for slot: String in ["auto", "manual"]:
		var path := path_for(seed_text, slot)
		for suffix: String in ["", ".bak"]:
			if FileAccess.file_exists(path + suffix):
				var err := DirAccess.remove_absolute(path + suffix)
				if err != OK:
					return err
	return OK
