extends RefCounted
## Общая для миров лента. В файл попадают только JSON-совместимые итоговые данные.

const CONFIG = preload("res://resources/ride_journal.tres")
const VERSION := 1
const FORMAT_VERSION := 2
const DEFAULT_DIR := "user://ride_journal"
static var _thumb_lock := Mutex.new()
## 28.11: чтение и запись ленты в фоне (RideFeedWriter) не должны перемешаться с удалением заезда из интерфейса
static var _file_lock := Mutex.new()
static var _thumb_revisions := {}
static var _thumb_generation := 0
static var _thumb_jobs := {}
static var _thumb_listeners := {}
static var _thumb_listeners_lock := Mutex.new()

var directory: String
var config: Resource
var entries: Array[Dictionary] = [] # новые первыми
var deleted: Array[String] = [] # не переносить повторно удалённые старые заезды
var _writable := true
var _loaded := false


func _init(folder := DEFAULT_DIR, tuning: Resource = CONFIG) -> void:
	directory = folder.trim_suffix("/")
	config = tuning


static func accepts(entry: Dictionary, development := false) -> bool:
	return not development and (float(entry.get("session_time", entry.get("time", 0.0))) >= CONFIG.min_time \
		or float(entry.get("bike", 0.0)) + float(entry.get("foot", 0.0)) >= CONFIG.min_distance)


static func ride_id(template_id: String, seed: String, start: float) -> String:
	return "%s:%s:%s" % [template_id, seed, str(start)]


static func thumb_name(id: String) -> String:
	return id.sha256_text() + ".png"


func thumb_path(id: String) -> String:
	return directory.path_join("thumbs").path_join(thumb_name(id))


## Повреждённый или неизвестный файл остаётся на месте и не может быть перезаписан.
func load_feed() -> Error:
	_loaded = true
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
	if err != OK:
		_writable = false
		return ERR_FILE_CORRUPT
	if content is Dictionary and content.has("version"):
		var format: Variant = content.version
		if not (format is int or format is float) or not is_finite(float(format)) or float(format) < 0.0 or floorf(float(format)) != float(format):
			_writable = false
			return ERR_FILE_CORRUPT
		if float(format) > FORMAT_VERSION:
			_writable = false
			return ERR_FILE_UNRECOGNIZED
	if not (content is Array or (content is Dictionary and content.get("entries") is Array and content.get("deleted") is Array)):
		_writable = false
		return ERR_FILE_CORRUPT
	if content is Dictionary:
		for id: Variant in content.deleted:
			if not id is String:
				_writable = false
				deleted.clear()
				return ERR_FILE_CORRUPT
			if not id in deleted:
				deleted.append(id)
		content = content.entries
	var seen := {}
	for item: Variant in content:
		if item is Dictionary and (item.get("version") is int or item.get("version") is float) and is_finite(float(item.version)) and floorf(float(item.version)) == float(item.version) and float(item.version) > VERSION:
			_writable = false
			entries.clear()
			deleted.clear()
			return ERR_FILE_UNRECOGNIZED
		if not item is Dictionary or not _valid(item):
			_writable = false
			entries.clear()
			deleted.clear()
			return ERR_FILE_CORRUPT
		if seen.has(item.id):
			_writable = false
			entries.clear()
			deleted.clear()
			return ERR_FILE_CORRUPT
		seen[item.id] = true
		entries.append(item)
	_sort(entries)
	return OK


## Изменения видны в памяти только после успешной атомарной замены файла.
func upsert(entry: Dictionary) -> Error:
	if not _loaded:
		var load_error := load_feed()
		if load_error != OK:
			return load_error
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
	_thumb_lock.lock()
	var err := _save(next)
	if err == OK:
		entries = next
		for old: Dictionary in removed:
			_remove_thumb(str(old.id))
	_thumb_lock.unlock()
	return err


func erase(id: String) -> Error:
	_file_lock.lock()
	var err := _erase(id)
	_file_lock.unlock()
	return err


func _erase(id: String) -> Error:
	if not _loaded:
		var load_error := load_feed()
		if load_error != OK:
			return load_error
	var next: Array[Dictionary] = entries.duplicate(true)
	var found := false
	for i in range(next.size() - 1, -1, -1):
		if next[i].id == id:
			next.remove_at(i)
			found = true
	if not found:
		return ERR_DOES_NOT_EXIST
	_thumb_lock.lock()
	deleted.append(id)
	var err := _save(next)
	if err == OK:
		entries = next
		_remove_thumb(id)
	else:
		deleted.erase(id)
	_thumb_lock.unlock()
	return err


## Удаление записи и публикация готового PNG не должны обгонять друг друга.
static func publish_thumb(folder: String, id: String, temporary: String, path: String) -> Error:
	_thumb_lock.lock()
	var current = load("res://scripts/game/ride_feed.gd").new(folder)
	var err: Error = current.load_feed()
	var found := false
	if err == OK and not id in current.deleted:
		for entry: Dictionary in current.entries:
			if entry.id == id:
				found = true
				break
	if err == OK and found:
		err = DirAccess.rename_absolute(temporary, path)
		if err == OK:
			_thumb_generation += 1
			_thumb_revisions[path] = _thumb_generation
	elif FileAccess.file_exists(temporary):
		DirAccess.remove_absolute(temporary)
	_thumb_lock.unlock()
	if err == OK and found:
		_notify_thumb_listeners()
	return err


## Версии существуют только в процессе и меняются после атомарной публикации PNG.
static func thumb_generation() -> int:
	_thumb_lock.lock()
	var generation := _thumb_generation
	_thumb_lock.unlock()
	return generation


static func thumb_revision(path: String) -> int:
	_thumb_lock.lock()
	var revision: int = _thumb_revisions.get(path, 0)
	_thumb_lock.unlock()
	return revision


static func begin_thumb(path: String) -> void:
	_thumb_lock.lock()
	_thumb_jobs[path] = int(_thumb_jobs.get(path, 0)) + 1
	_thumb_generation += 1
	_thumb_lock.unlock()
	_notify_thumb_listeners()


static func end_thumb(path: String) -> void:
	_thumb_lock.lock()
	var remaining: int = int(_thumb_jobs.get(path, 0)) - 1
	if remaining <= 0:
		_thumb_jobs.erase(path)
	else:
		_thumb_jobs[path] = remaining
	_thumb_generation += 1
	_thumb_lock.unlock()
	_notify_thumb_listeners()


## Уведомление ставится в очередь главного потока, в том числе при записи превью из worker thread.
static func watch_thumbs(listener: Callable) -> void:
	_thumb_listeners_lock.lock()
	_thumb_listeners[listener] = true
	_thumb_listeners_lock.unlock()


static func unwatch_thumbs(listener: Callable) -> void:
	_thumb_listeners_lock.lock()
	_thumb_listeners.erase(listener)
	_thumb_listeners_lock.unlock()


static func _notify_thumb_listeners() -> void:
	_thumb_listeners_lock.lock()
	var listeners := _thumb_listeners.keys()
	_thumb_listeners_lock.unlock()
	for listener: Callable in listeners:
		if listener.is_valid():
			listener.call_deferred()


static func thumb_is_preparing(path: String) -> bool:
	_thumb_lock.lock()
	var preparing: bool = _thumb_jobs.has(path)
	_thumb_lock.unlock()
	return preparing


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
	_thumb_revisions.erase(path) # вызывается под _thumb_lock
	if FileAccess.file_exists(path):
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			push_warning("Не удалось удалить превью заезда: " + error_string(err))


static func _valid(entry: Dictionary) -> bool:
	if not entry.get("id") is String or str(entry.id).is_empty():
		return false
	var version: Variant = entry.get("version")
	var start: Variant = entry.get("start")
	return (version is int or version is float) and float(version) == VERSION \
		and (start is int or start is float) and is_finite(float(start))


static func _sort(list: Array[Dictionary]) -> void:
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a.start) == float(b.start):
			return str(a.id) < str(b.id)
		return float(a.start) > float(b.start))
