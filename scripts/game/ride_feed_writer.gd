extends RefCounted
## Снимок данных пишется сразу, построение PNG — в рабочем потоке.

const Feed = preload("res://scripts/game/ride_feed.gd")
const Thumb = preload("res://scripts/ui/ride_thumb.gd")
const Config = preload("res://resources/ride_journal.tres")
const RideLog = preload("res://scripts/game/ride_log.gd")

var feed
var _task := -1
var _result := {}
var _last_thumb := -INF
var _task_id := "" # пусто у пакетного переноса
var _pending_thumb := {}


func _init(folder := Feed.DEFAULT_DIR) -> void:
	feed = Feed.new(folder)
	var err: Error = feed.load_feed()
	if err != OK:
		push_warning("Не удалось открыть журнал заездов: " + error_string(err))


## ID и сериализация общие для текущих и перенесённых заездов.
static func make_entry(snapshot: Dictionary, template_id: String, seed: String, names: Array, photo_paths: Array = []) -> Dictionary:
	var entry := snapshot.duplicate(true)
	if entry.has("session_time"):
		entry.time = entry.session_time
		entry.erase("session_time")
	entry.id = Feed.ride_id(template_id, seed, float(snapshot.get("start", 0.0)))
	entry.version = Feed.VERSION
	entry.template_id = template_id
	entry.seed = seed
	entry.world_title = seed
	entry.walk = float(entry.get("bike", 0.0)) < Config.walk_bike_distance
	entry.places = names.duplicate()
	entry.photo_paths = photo_paths.duplicate()
	entry.thumb = ""
	# Координаты без высот нужны, чтобы показать заезд этого мира на его большой карте.
	var tracks: Array = []
	for leg: PackedVector2Array in RideLog._thin(snapshot.get("legs", [])):
		var points: Array = []
		for point: Vector2 in leg:
			points.append([point.x, point.y])
		tracks.append(points)
	entry.track = tracks
	entry.erase("legs")
	return entry


## Старые заезды без новых полей остаются такими: интерфейс покажет прочерки.
func migrate(records: Array, template_id: String, seed: String, map_image: Image, world_size: Vector2) -> Error:
	finish()
	var err: Error = feed.load_feed()
	if err != OK:
		return err
	var jobs: Array = []
	for item: Dictionary in records:
		var snapshot: Dictionary = item.snapshot
		var entry := make_entry(snapshot, template_id, seed, item.names, item.photos)
		if entry.id in feed.deleted:
			continue
		var existing := false
		for saved: Dictionary in feed.entries:
			if saved.id == entry.id:
				existing = true
				break
		var path: String = feed.thumb_path(entry.id)
		if not existing:
			if entry.has("alt"):
				entry.alt_max = entry.alt
			entry.thumb = Feed.thumb_name(entry.id) if map_image != null else ""
			err = feed.upsert(entry)
			if err != OK:
				return err
			if not feed.entries.any(func(saved: Dictionary) -> bool: return saved.id == entry.id):
				continue
		if map_image != null and not FileAccess.file_exists(path):
			jobs.append({snapshot = snapshot.duplicate(true), path = path, id = entry.id})
	if not jobs.is_empty():
		var result := {error = OK}
		var folder: String = feed.directory
		_result = result
		_task_id = ""
		_task = WorkerThreadPool.add_task(func() -> void:
			for job: Dictionary in jobs:
				var image: Image = Thumb.render(map_image, world_size, job.snapshot)
				if image == null:
					result.error = ERR_INVALID_DATA
					continue
				var temporary: String = job.path + ".tmp"
				var save_err := image.save_png(temporary)
				if save_err == OK:
					save_err = Feed.publish_thumb(folder, str(job.id), temporary, job.path)
				if save_err != OK:
					result.error = save_err, false, "Превью прежних заездов")
	return OK


func submit(snapshot: Dictionary, template_id: String, seed: String, names: Array, photo_paths: Array, map_image: Image, world_size: Vector2, force := false, development := false) -> Error:
	if not Feed.accepts(snapshot, development):
		return OK
	if force:
		_pending_thumb.clear() # финальный снимок новее ожидающего
		finish()
	elif _task != -1 and WorkerThreadPool.is_task_completed(_task):
		poll()
	var entry := make_entry(snapshot, template_id, seed, names, photo_paths)
	var load_err: Error = feed.load_feed()
	if load_err != OK:
		return load_err
	if entry.id in feed.deleted:
		return OK
	var now := Time.get_ticks_msec() / 1000.0
	var wants_thumb := map_image != null and (force or now - _last_thumb >= Config.thumb_interval)
	var path: String = feed.thumb_path(entry.id)
	if wants_thumb or _task_id == entry.id or FileAccess.file_exists(path):
		entry.thumb = Feed.thumb_name(entry.id)
	var err: Error = feed.upsert(entry)
	if err != OK:
		return err
	if wants_thumb and feed.entries.any(func(saved: Dictionary) -> bool: return saved.id == entry.id):
		var job := {snapshot = snapshot.duplicate(true), image = map_image, world_size = world_size, id = str(entry.id), path = path}
		if _task == -1:
			_start_thumb(job)
		elif _task_id != entry.id:
			_pending_thumb = job
	if force:
		finish()
	return OK


func _start_thumb(job: Dictionary) -> void:
	_last_thumb = Time.get_ticks_msec() / 1000.0
	var result := {error = OK}
	var folder: String = feed.directory
	_result = result
	_task_id = job.id
	_task = WorkerThreadPool.add_task(func() -> void:
		var image: Image = Thumb.render(job.image, job.world_size, job.snapshot)
		if image == null:
			result.error = ERR_INVALID_DATA
			return
		var temporary: String = job.path + ".tmp"
		result.error = image.save_png(temporary)
		if result.error == OK:
			result.error = Feed.publish_thumb(folder, job.id, temporary, job.path), false, "Превью заезда")


func poll() -> void:
	if _task != -1 and WorkerThreadPool.is_task_completed(_task):
		_wait_task()
	if _task == -1 and not _pending_thumb.is_empty():
		var job := _pending_thumb
		_pending_thumb = {}
		_start_thumb(job)


func finish() -> void:
	_wait_task()
	if not _pending_thumb.is_empty():
		var job := _pending_thumb
		_pending_thumb = {}
		_start_thumb(job)
		_wait_task()


func _wait_task() -> void:
	if _task == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_task_id = ""
	if _result.error != OK:
		push_warning("Не удалось записать превью заезда: " + error_string(_result.error))
	_result = {}
