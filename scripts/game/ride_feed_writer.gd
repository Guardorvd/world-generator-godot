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
		finish()
	elif _task != -1 and WorkerThreadPool.is_task_completed(_task):
		finish()
	var entry := make_entry(snapshot, template_id, seed, names, photo_paths)
	var load_err: Error = feed.load_feed()
	if load_err != OK:
		return load_err
	if entry.id in feed.deleted:
		return OK
	var now := Time.get_ticks_msec() / 1000.0
	var make_thumb := map_image != null and _task == -1 and (force or now - _last_thumb >= Config.thumb_interval)
	var path: String = feed.thumb_path(entry.id)
	if make_thumb or _task != -1 or FileAccess.file_exists(path):
		entry.thumb = Feed.thumb_name(entry.id)
	var err: Error = feed.upsert(entry)
	if err != OK:
		return err
	if make_thumb:
		_last_thumb = now
		var frozen := snapshot.duplicate(true)
		var result := {error = OK}
		var folder: String = feed.directory
		var id: String = entry.id
		_result = result
		_task = WorkerThreadPool.add_task(func() -> void:
			var image: Image = Thumb.render(map_image, world_size, frozen)
			if image == null:
				result.error = ERR_INVALID_DATA
				return
			var temporary: String = path + ".tmp"
			result.error = image.save_png(temporary)
			if result.error == OK:
				result.error = Feed.publish_thumb(folder, id, temporary, path), false, "Превью заезда")
		if force:
			finish()
	return OK


func finish() -> void:
	if _task == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if _result.error != OK:
		push_warning("Не удалось записать превью заезда: " + error_string(_result.error))
	_result = {}
