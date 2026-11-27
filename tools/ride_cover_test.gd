extends SceneTree
## Обложки ленты: фоновая загрузка, подмена отсутствующего файла и сохранность записи.

const Feed = preload("res://scripts/game/ride_feed.gd")
const View = preload("res://scripts/ui/ride_feed_view.gd")
var failures := 0

class Settings extends RefCounted:
	var show_walks := false
	func save_settings() -> Error:
		return OK

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	root.size = Vector2i(1280, 720)
	_run.call_deferred()

func _check(value: bool, message: String) -> void:
	print("PASS " if value else "FAIL ", message)
	if not value:
		failures += 1

func _run() -> void:
	var folder := "res://.godot/ride_cover_test/" + str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(folder)
	var photo := Image.create(800, 450, false, Image.FORMAT_RGB8)
	photo.fill(Color("#b77642"))
	var photo_path := ProjectSettings.globalize_path(folder.path_join("photo.png"))
	photo.save_png(photo_path)
	var missing_path := ProjectSettings.globalize_path(folder.path_join("missing.png"))
	var feed = Feed.new(folder)
	for item in [["with_photo", [photo_path]], ["missing_photo", [missing_path]], ["second_photo", [missing_path, photo_path]]]:
		var entry := {id = item[0], version = Feed.VERSION, start = 1795600000, time = 600,
			bike = 1500, falls = 0, seed = "test", template_id = WorldTemplate.DEFAULT_ID,
			walk = false, photo_paths = item[1], thumb = Feed.thumb_name(item[0])}
		_check(feed.upsert(entry) == OK, "подготовлена запись " + item[0])
		var map := Image.create(320, 200, false, Image.FORMAT_RGB8)
		map.fill(Color("#91a995"))
		map.save_png(feed.thumb_path(item[0]))
	var view := View.new()
	view.feed = Feed.new(folder)
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(view)
	view.setup(Settings.new(), "test", WorldTemplate.DEFAULT_ID, true)
	var deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline and (not view._cover_cache.has(photo_path) or not view._cover_cache.has(missing_path)):
		await process_frame
	_check(view._cover_cache.has(photo_path) and view._cover_cache[photo_path] != null, "снимок загружен в фоне")
	_check(view._cover_cache.has(missing_path) and view._cover_cache[missing_path] == null, "недоступный снимок не ломает ленту")
	_check(view._cards["with_photo"]._cover.visible, "снимок показан на карточке")
	_check(view._cards["second_photo"]._cover.visible, "если первый снимок недоступен, показан следующий")
	_check(not view._cards["missing_photo"]._cover.visible and view._cards["missing_photo"]._preview.texture != null,
		"вместо недоступного снимка остаётся карта")
	_check(feed.entries.size() == 3, "исходные данные поездок сохранены")
	view.queue_free()
	await process_frame
	quit(1 if failures else 0)
