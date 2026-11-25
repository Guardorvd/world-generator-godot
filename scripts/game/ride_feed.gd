extends RefCounted
## Общая для миров лента. В файл попадают только JSON-совместимые итоговые данные.

const CONFIG = preload("res://resources/ride_journal.tres")
const VERSION := 1
const FORMAT_VERSION := 2
const DEFAULT_DIR := "user://ride_journal"

var directory: String
var config: Resource
var entries: Array[Dictionary] = [] # новые первыми
var deleted: Array[String] = [] # не переносить повторно удалённые старые заезды
var _writable := true


func _init(folder := DEFAULT_DIR, tuning: Resource = CONFIG) -> void:
	directory = folder.trim_suffix("/")
	config = tuning


static func accepts(entry: Dictionary, development := false) -> bool:
	return not development and (float(entry.get("time", 0.0)) >= CONFIG.min_time \
		or float(entry.get("bike", 0.0)) + float(entry.get("foot", 0.0)) >= CONFIG.min_distance)


static func ride_id(template_id: String, seed: String, start: float) -> String:
	return "%s:%s:%s" % [template_id, seed, str(start)]


static func thumb_name(id: String) -> String:
	return id.sha256_text() + ".png"


func thumb_path(id: String) -> String:
	return directory.path_join("thumbs").path_join(thumb_name(id))


## При повреждении сначала сохраняем оригинал. Если это не удалось, запись запрещена.
func load_feed() -> Error:
	entries.clear()
	deleted.clear()
	_writable = true
	var path := directory.path_join("feed.json")
	if not FileAccess.file_exists(path):
		return OK
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_writable = false
		return FileAccess.get_open_error()
	var parser := JSON.new()
	var err := parser.parse(file.get_as_text())
	file.close()
	var content: Variant = parser.data
	if err == OK and content is Dictionary and (content.get("version") is int or content.get("version") is float) and int(content.version) > FORMAT_VERSION:
		_writable = false
		return ERR_FILE_UNRECOGNIZED
	if err != OK or not (content is Array or (content is Dictionary and content.get("entries") is Array and content.get("deleted") is Array)):
		var bad := path + ".bad"
		var suffix := 1
		while FileAccess.file_exists(bad):
			bad = path + ".bad." + str(suffix)
			suffix += 1
		err = DirAccess.rename_absolute(path, bad)
		if err != OK:
			_writable = false
		return err
	if content is Dictionary:
		for id: Variant in content.deleted:
			if id is String and not id in deleted:
				deleted.append(id)
		content = content.entries
	var seen := {}
	for item: Variant in content:
		if not item is Dictionary or not _valid(item):
			continue
		if seen.has(item.id):
			continue
		seen[item.id] = true
		entries.append(item)
	_sort(entries)
	return OK


## Изменения видны в памяти только после успешной атомарной замены файла.
func upsert(entry: Dictionary) -> Error:
	if not _valid(entry):
		return ERR_INVALID_DATA
	if entry.id in deleted:
		return OK
	var next: Array[Dictionary] = entries.duplicate(true)
	for i in range(next.size() - 1, -1, -1):
		if next[i].id == entry.id:
			next.remove_at(i)
	next.append(entry.duplicate(true))
	_sort(next)
	var removed: Array[Dictionary] = []
	while next.size() > maxi(0, config.entries_limit):
		removed.append(next.pop_back())
	var err := _save(next)
	if err == OK:
		entries = next
		for old: Dictionary in removed:
			_remove_thumb(str(old.id))
	return err


func erase(id: String) -> Error:
	var next: Array[Dictionary] = entries.duplicate(true)
	var found := false
	for i in range(next.size() - 1, -1, -1):
		if next[i].id == id:
			next.remove_at(i)
			found = true
	if not found:
		return ERR_DOES_NOT_EXIST
	deleted.append(id)
	var err := _save(next)
	if err == OK:
		entries = next
		_remove_thumb(id)
	else:
		deleted.erase(id)
	return err


func _save(list: Array[Dictionary]) -> Error:
	if not _writable:
		return ERR_UNAUTHORIZED
	var err := DirAccess.make_dir_recursive_absolute(directory.path_join("thumbs"))
	if err != OK:
		return err
	var path := directory.path_join("feed.json")
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({version = FORMAT_VERSION, entries = list, deleted = deleted}))
	file.flush()
	err = file.get_error()
	file.close()
	if err != OK:
		return err
	return DirAccess.rename_absolute(temporary, path)


func _remove_thumb(id: String) -> void:
	var path := thumb_path(id)
	if FileAccess.file_exists(path):
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			push_warning("Не удалось удалить превью заезда: " + error_string(err))


static func _valid(entry: Dictionary) -> bool:
	if not entry.get("id") is String or str(entry.id).is_empty():
		return false
	var version: Variant = entry.get("version")
	var start: Variant = entry.get("start")
	return (version is int or version is float) and int(version) == VERSION \
		and (start is int or start is float) and is_finite(float(start))


static func _sort(list: Array[Dictionary]) -> void:
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a.start) == float(b.start):
			return str(a.id) < str(b.id)
		return float(a.start) > float(b.start))
